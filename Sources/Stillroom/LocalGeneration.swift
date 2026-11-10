import SwiftUI
import AppKit
import AVFoundation

@MainActor
final class LocalGeneration: ObservableObject {
    struct PendingRegeneration {
        let shotID:UUID
        let documentID:UUID
        var instructions:String
        var seedOverride:Int? = nil
    }
    @Published var backend = "Automatic"
    @Published var address = "http://127.0.0.1:8188"
    @Published var model = ""
    @Published var models: [String] = []
    @Published var prompt = "One continuous cinematic shot. A quiet breath, a natural blink, a slight shift of gaze. Preserve the person, clothing, room and light. The camera slowly pulls back."
    @Published var seed = 42
    @Published var lockSeed = false
    @Published var frames = 81
    @Published var width = 768
    @Published var height = 448
    @Published var steps = 8
    @Published var referenceID: UUID?
    @Published var workflow: [String:Any]?
    @Published var workflowName = "No API workflow selected"
    @Published var promptNode = ""
    @Published var busy = false
    @Published var referenceBusy = false
    @Published var progress:GenerationProgress?
    @Published var completedAssetID: UUID?
    @Published var targetShotID: UUID?
    @Published var pendingRegeneration:PendingRegeneration?
    @Published var quality = "Balanced"
    @Published var durationSeconds = 3.375
    private let engine:LocalEngine
    private var queuedJob:(id:String,address:String)?
    private let session: URLSession
    private let outputDirectory:URL
    init(session:URLSession = .shared,outputDirectory:URL? = nil,engineDirectory:URL? = nil) {
        self.session = session
        self.engine = LocalEngine(session:session,directory:engineDirectory)
        self.outputDirectory = outputDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Stillroom/Generations")
        let defaults = UserDefaults.standard
        backend = defaults.string(forKey:"generation.backend") ?? "Automatic"
        address = defaults.string(forKey:"generation.address") ?? "http://127.0.0.1:8188"
        model = defaults.string(forKey:"generation.model") ?? ""
        quality = defaults.string(forKey:"generation.quality") ?? "Balanced"
        durationSeconds = defaults.object(forKey:"generation.duration") == nil ? 3.375 : defaults.double(forKey:"generation.duration")
        if backend == "MLX-Serve" && model.isEmpty {backend = "Automatic";address = "http://127.0.0.1:8188"}
        lockSeed = defaults.bool(forKey:"generation.lockSeed")
        promptNode = defaults.string(forKey:"generation.promptNode") ?? ""
        if let data = defaults.data(forKey:"generation.workflow"),let graph = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            workflow = graph;workflowName = defaults.string(forKey:"generation.workflowName") ?? "Saved workflow"
        }
    }
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(durationSeconds,forKey:"generation.duration")
        defaults.set(quality,forKey:"generation.quality")
        defaults.set(backend,forKey:"generation.backend");defaults.set(address,forKey:"generation.address")
        defaults.set(model,forKey:"generation.model");defaults.set(promptNode,forKey:"generation.promptNode")
        defaults.set(lockSeed,forKey:"generation.lockSeed")
        defaults.set(workflowName,forKey:"generation.workflowName")
        if let workflow,let data = try? JSONSerialization.data(withJSONObject:workflow) {defaults.set(data,forKey:"generation.workflow")}
    }
    @Published var message = "Ready to find your local video engine. No cloud account or paid API."
    private var work: Task<Void,Never>?

    func base(_ value:String? = nil) throws -> URL {
        guard let url = URL(string:value ?? address), url.scheme == "http", ["localhost","127.0.0.1","[::1]","::1"].contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil else {throw StudioError.message("Use an HTTP server on this Mac, for example http://127.0.0.1:11234.")}
        return url
    }
    func endpoint(_ path: String,address:String? = nil) throws -> URL {try base(address).appendingPathComponent(path)}
    func json(_ path: String, body: [String:Any]? = nil, address:String? = nil, query:[URLQueryItem] = []) async throws -> [String:Any] {
        var components = URLComponents(url:try endpoint(path,address:address),resolvingAgainstBaseURL:false)!
        if !query.isEmpty {components.queryItems = query}
        var request = URLRequest(url:components.url!);request.timeoutInterval = body == nil ? 10 : 3600
        if let body {request.httpMethod = "POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody = try JSONSerialization.data(withJSONObject:body)}
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {throw StudioError.message("The local server returned an error. \(String(data:data.prefix(400),encoding:.utf8) ?? "")")}
        guard let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw StudioError.message("The local server returned an unsupported response.")}
        return value
    }
    func chooseEngine() {
        guard !busy,!referenceBusy else {return}
        Task {
            do {if let _ = try await engine.chooseInstallation() {message = "Engine folder saved. Regenerate will start it automatically."}}
            catch {message = error.localizedDescription}
        }
    }
    func revealEngineLog() {NSWorkspace.shared.activateFileViewerSelecting([engine.logURL])}
    private func prepareEngine() async throws {
        if backend == "Automatic" || backend == "MLX-Serve" {
            guard durationSeconds.isFinite,GenerationTiming.range.contains(durationSeconds) else {throw StudioError.message("Choose a generated clip length from 1 to 10 seconds.")}
            frames = GenerationTiming.frameCount(seconds:durationSeconds)
        }
        guard backend == "Automatic" else {return}
        let ready = try await engine.ready(preferredAddress:address) {self.message = $0}
        address = ready.address
        switch quality {
        case "Draft":width = 768;height = 448
        case "Cinema":width = 1280;height = 704
        default:width = 1024;height = 576
        }
        steps = 8;model = URL(fileURLWithPath:ready.installation.weights).lastPathComponent
        workflow = LocalEngine.workflow(installation:ready.installation,width:width,height:height,frames:frames,seed:seed)
        workflowName = "Built-in continuous take";promptNode = "3"
        saveSettings()
    }
    func connect() {
        guard !busy,!referenceBusy else {return}
        progress = nil;busy = true
        work = Task {
            defer {busy = false}
            do {
                if backend == "Automatic" {try await prepareEngine();return}
                let response = try await json(backend == "MLX-Serve" ? "v1/models" : "system_stats")
                if backend == "MLX-Serve" {
                    models = (response["data"] as? [[String:Any]] ?? []).filter {item in
                        let capabilities = item["capabilities"] as? [String] ?? []
                        let id = (item["id"] as? String ?? "").lowercased()
                        return capabilities.contains("video") || id.contains("ltx") || id.contains("minimax-h3")
                    }.compactMap {$0["id"] as? String}
                    if model.isEmpty {model = models.first(where:{$0.lowercased().contains("ltx")}) ?? models.first ?? ""}
                    message = models.isEmpty ? "Connected. No video model is available yet. Load a video model in MLX-Serve, then Connect again." : "Connected · \(models.count) video models available. Load your chosen model in MLX-Serve before generating."
                    if !models.contains(model) {model = models.first ?? ""}
                } else {message = "Connected to ComfyUI. Choose an API-format workflow with a video-save node."}
                saveSettings()
            } catch {message = "Could not connect. Start \(backend) on this Mac and check the port. \(error.localizedDescription)"}
        }
    }
    func chooseWorkflow() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json]
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else {return}
            Task {@MainActor in
                guard let self else {return}
                do {
                    guard let graph = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any], !graph.isEmpty,
                          graph.values.allSatisfy({($0 as? [String:Any])?["class_type"] is String}) else {throw StudioError.message("Use ComfyUI’s Export (API) JSON, rather than its canvas workflow format.")}
                    self.workflow = graph;self.workflowName = url.lastPathComponent
                    self.promptNode = graph.keys.sorted().first {key in
                        guard let node = graph[key] as? [String:Any], let inputs = node["inputs"] as? [String:Any] else {return false}
                        return inputs["prompt"] is String
                    } ?? ""
                    self.message = "Workflow loaded. Confirm the positive prompt node ID. Node settings and checkpoint paths stay as supplied."
                    self.saveSettings()
                } catch {self.message = error.localizedDescription}
            }
        }
    }
    private struct Job {
        let backend:String, address:String, model:String, prompt:String
        let seed:Int, frames:Int, width:Int, height:Int, steps:Int
        let referenceID:UUID?, workflow:[String:Any]?, promptNode:String
        let parentID:UUID?, recipe:GenerationRecipe?, shotName:String?
    }
    private func job(parentID:UUID? = nil,recipe:GenerationRecipe? = nil,shotName:String? = nil)->Job {
        Job(backend:backend,address:address,model:model,prompt:prompt,seed:seed,frames:frames,width:width,height:height,steps:steps,referenceID:referenceID,workflow:workflow,promptNode:promptNode,parentID:parentID,recipe:recipe,shotName:shotName)
    }
    var configured:Bool {backend == "Automatic" || (backend == "MLX-Serve" ? !model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty : workflow != nil && !promptNode.isEmpty)}
    func requestRegeneration(shotID:UUID,instructions:String,store:StudioStore,seedOverride:Int? = nil) {
        guard !busy,!referenceBusy else {return}
        if configured {pendingRegeneration = nil;regenerate(shotID:shotID,instructions:instructions,store:store,seedOverride:seedOverride)}
        else {
            pendingRegeneration = PendingRegeneration(shotID:shotID,documentID:store.documentID,instructions:instructions,seedOverride:seedOverride)
            targetShotID = shotID;store.showLab = true;connect()
        }
    }
    func resumeRegeneration(store:StudioStore) {
        guard let pending = pendingRegeneration else {return}
        guard store.documentID == pending.documentID else {pendingRegeneration = nil;message = "Select the shot again in the current project.";return}
        guard configured else {message = "Choose a compatible video model or ComfyUI workflow first.";return}
        pendingRegeneration = nil
        regenerate(shotID:pending.shotID,instructions:pending.instructions,store:store,seedOverride:pending.seedOverride)
    }
    func generate(into store: StudioStore) {
        guard !busy,!referenceBusy, !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
        if let referenceID,!store.project.assets.contains(where:{$0.id == referenceID && $0.kind == .image}) {self.referenceID = nil}
        saveSettings();progress = GenerationProgress();busy = true;targetShotID = nil
        let documentID = store.documentID
        work = Task {
            do {
                try await prepareEngine();try Task.checkCancellation()
                guard store.documentID == documentID else {throw StudioError.message("The project changed. Generate again in the current project.")}
                if !lockSeed {seed = Int.random(in:0...999999)}
                await execute(into:store,job:job(),documentID:documentID)
            } catch {progress?.finish(Task.isCancelled ? .cancelled : .failed);message = Task.isCancelled ? "Cancelled. The original edit is unchanged." : error.localizedDescription;busy = false}
        }
    }
    func regenerate(shotID:UUID,instructions:String,store:StudioStore,seedOverride:Int? = nil) {
        guard !busy,!referenceBusy,!instructions.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let shot = store.project.shots.first(where:{$0.id == shotID}),
              let source = store.project.assets.first(where:{$0.id == shot.assetID}) else {return}
        if let i = store.project.assets.firstIndex(where:{$0.id == source.id}), source.regenerationDraft != instructions {
            store.change({$0.assets[i].regenerationDraft = instructions},rebuild:false)
        }
        saveSettings();progress = GenerationProgress();busy = true;targetShotID = shotID;completedAssetID = nil
        if let seedOverride {seed = seedOverride}
        else if !lockSeed {seed = Int.random(in:0...999999)}
        let documentID = store.documentID
        let family = store.project.familyRoot(of:source)
        let originalPrompt = source.recipe?.originalPrompt ?? source.prompt
        let shotDirection = source.direction ?? ShotDirection()
        let direction = shotDirection.motionPrompt(action:instructions)
        let originalURL = store.url(source)
        let reference = source.referenceAssetID.flatMap {id in store.project.assets.first {$0.id == id && $0.kind == .image}}
        let referenceTime = shot.sourceIn
        work = Task {
            do {
                try await prepareEngine();try Task.checkCancellation()
                let settings = job()
                message = "Preparing the original frame…"
                var anchor:MediaAsset
                if let reference {anchor = reference}
                else if source.kind == .image {anchor = source}
                else {
                    let generator = AVAssetImageGenerator(asset:AVURLAsset(url:originalURL))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width:1920,height:1920)
                    generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                    let image = try await generator.image(at:CMTime(seconds:referenceTime,preferredTimescale:600)).image
                    try Task.checkCancellation()
                    let directory = outputDirectory
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    let url = directory.appendingPathComponent("Reference-" + UUID().uuidString + ".png")
                    let png = try VideoColor.referencePNG(image)
                    try png.write(to:url,options:.atomic)
                    anchor = MediaAsset(name:"Reference · " + source.name,path:url.path,kind:.image,width:image.width,height:image.height,origin:"Original clip frame",prompt:originalPrompt,notes:"Exact source frame at \(String(format:"%.3f",referenceTime)) seconds from \(source.name).")
                }
                guard store.documentID == documentID else {throw StudioError.message("The project changed. Select the original shot and try again.")}
                if !store.project.assets.contains(where:{$0.id == anchor.id}) {
                    store.change({$0.assets.append(anchor)},rebuild:false);store.refreshMedia()
                }
                if let i = store.project.assets.firstIndex(where:{$0.id == source.id}) {store.change({$0.assets[i].referenceAssetID = anchor.id},rebuild:false)}
                referenceID = anchor.id;prompt = direction
                var recipe = GenerationRecipe(backend:settings.backend,model:settings.model,seed:settings.seed,frames:settings.frames,width:settings.width,height:settings.height,steps:settings.steps,instructions:instructions,originalPrompt:originalPrompt,referenceTime:referenceTime)
                recipe.direction = shotDirection
                recipe.requestedDuration = durationSeconds
                recipe.workflow = (settings.workflow?[settings.promptNode] as? [String:Any])?["class_type"] as? String
                let request = Job(backend:settings.backend,address:settings.address,model:settings.model,prompt:direction,seed:settings.seed,frames:settings.frames,width:settings.width,height:settings.height,steps:settings.steps,referenceID:anchor.id,workflow:settings.workflow,promptNode:settings.promptNode,parentID:family,recipe:recipe,shotName:shot.name)
                await execute(into:store,job:request,documentID:documentID)
            } catch {progress?.finish(Task.isCancelled ? .cancelled : .failed);message = Task.isCancelled ? "Cancelled. The original edit is unchanged." : error.localizedDescription;busy = false}
        }
    }
    private func execute(into store:StudioStore,job:Job,documentID:UUID) async {
        let backend = job.backend,address = job.address,model = job.model,prompt = job.prompt
        let seed = job.seed,frames = job.frames,width = job.width,height = job.height,steps = job.steps
        let referenceID = job.referenceID,workflow = job.workflow,promptNode = job.promptNode
        defer {busy = false}
            do {
                let directory = outputDirectory
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                let reference = store.project.assets.first {$0.id == referenceID}
                if backend == "MLX-Serve" {
                    guard !model.isEmpty else {throw StudioError.message("Select a video model already loaded in MLX-Serve first.")}
                    var body: [String:Any] = ["model":model,"prompt":prompt,"num_frames":frames,"width":width,"height":height,"steps":steps,"seed":seed,"stream":false]
                    if let reference {body["first_frame_image"] = try VideoColor.referencePNG(at:store.url(reference)).base64EncodedString()}
                    progress?.rendering()
                    message = "Generating locally… This may take several minutes."
                    let response = try await json("v1/video/generations",body:body,address:address)
                    guard response["format"] as? String == "rgb8", let w = response["width"] as? Int, let h = response["height"] as? Int,
                          let count = response["frames"] as? Int, let base64 = response["data"] as? String, let rgb = Data(base64Encoded:base64),
                          w > 0, w <= 4096, h > 0, h <= 4096, count > 0, count <= 1000, rgb.count == w*h*3*count else {throw StudioError.message("Expected MLX-Serve’s rgb8 video response. Check the server version and video model.")}
                    let fps = response["fps"] as? Int ?? 24
                    guard fps > 0, fps <= 120 else {throw StudioError.message("The server returned an invalid frame rate.")}
                    progress?.stage = .finishing
                    message = "Encoding the generated picture…"
                    try await MediaEngine.writeFrames(to:output,width:w,height:h,fps:fps,count:count) {index,context in
                        let frame = rgb.subdata(in:index*w*h*3..<(index+1)*w*h*3)
                        guard let provider = CGDataProvider(data:frame as CFData), let image = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:w*3,space:VideoColor.sRGB,bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw StudioError.message("Cannot decode the generated frame.")}
                        context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
                    }
                    // This editor intentionally imports the picture only. Speech and music have their own editable lanes.
                } else {
                    guard var graph = workflow else {throw StudioError.message("Choose an API-format ComfyUI workflow first.")}
                    guard !promptNode.isEmpty, var node = graph[promptNode] as? [String:Any], var inputs = node["inputs"] as? [String:Any] else {throw StudioError.message("Enter the node ID containing your positive prompt.")}
                    if inputs["prompt"] is String {inputs["prompt"] = prompt}
                    else if inputs["text"] is String {inputs["text"] = prompt}
                    else {throw StudioError.message("The chosen prompt node needs a text or prompt input.")}
                    node["inputs"] = inputs;graph[promptNode] = node
                    if reference == nil, backend == "Automatic" {graph.removeValue(forKey:"1");if var item = graph["3"] as? [String:Any],var values = item["inputs"] as? [String:Any] {values.removeValue(forKey:"image");item["inputs"] = values;graph["3"] = item}}
                    if let reference {
                        let boundary = UUID().uuidString
                        var request = URLRequest(url:try endpoint("upload/image",address:address));request.httpMethod = "POST"
                        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
                        let source = store.url(reference), filename = "stillroom-\(UUID().uuidString).png"
                        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: image/png\r\n\r\n".utf8)
                        data.append(try VideoColor.referencePNG(at:source));data.append(Data("\r\n--\(boundary)--\r\n".utf8));request.httpBody = data
                        let (reply,response) = try await session.data(for:request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200, let result = try JSONSerialization.jsonObject(with:reply) as? [String:Any], let name = result["name"] as? String else {throw StudioError.message("ComfyUI could not upload the reference image.")}
                        let folder = result["subfolder"] as? String ?? ""
                        for key in graph.keys {
                            guard var item = graph[key] as? [String:Any], item["class_type"] as? String == "LoadImage", var values = item["inputs"] as? [String:Any] else {continue}
                            values["image"] = folder.isEmpty ? name : folder + "/" + name;item["inputs"] = values;graph[key] = item
                        }
                    }
                    for key in graph.keys {
                        guard var item = graph[key] as? [String:Any], var values = item["inputs"] as? [String:Any] else {continue}
                        if values["seed"] != nil {values["seed"] = seed}
                        item["inputs"] = values;graph[key] = item
                    }
                    // The server timestamps execution separately from queue wait. Only matching
                    // built-in workflows on this same engine contribute to the estimate.
                    if let history = try? await json("history",address:address,query:[URLQueryItem(name:"max_items",value:"32")]) {
                        progress?.expectedSeconds = GenerationTimingSample.estimate(graph:graph,samples:GenerationTimingSample.fromHistory(history))
                        if progress?.expectedSeconds != nil {progress?.basis = "Based on similar renders on this engine"}
                    }
                    try Task.checkCancellation()
                    progress?.stage = .queued
                    let response = try await json("prompt",body:["prompt":graph,"client_id":UUID().uuidString],address:address)
                    guard let id = response["prompt_id"] as? String else {throw StudioError.message("ComfyUI rejected the workflow. Check its model paths and custom nodes.")}
                    queuedJob = (id,address)
                    defer {queuedJob = nil}
                    let started = Date()
                    message = "Take queued on this Mac…"
                    var found: [String:Any]?
                    for _ in 0..<3600 {
                        try await Task.sleep(nanoseconds:2_000_000_000)
                        let history = try await json("history/"+id,address:address)
                        let elapsed = Int(Date().timeIntervalSince(started))
                        if let queue = try? await json("queue",address:address) {
                            let running = (queue["queue_running"] as? [[Any]] ?? []).contains {$0.count > 1 && $0[1] as? String == id}
                            if running {progress?.rendering()}
                            else if progress?.stage == .queued {
                                progress?.queuePosition = (queue["queue_pending"] as? [[Any]] ?? []).firstIndex {$0.count > 1 && $0[1] as? String == id}.map {$0+1}
                            }
                            message = running ? "Rendering on this Mac · \(elapsed/60)m \(elapsed%60)s · \(width) × \(height)" : "Waiting for the local engine · \(elapsed/60)m \(elapsed%60)s"
                        }
                        guard let entry = history[id] as? [String:Any] else {continue}
                        if let status = entry["status"] as? [String:Any],status["status_str"] as? String == "error" {
                            let details = (status["messages"] as? [[Any]] ?? []).compactMap {row -> String? in
                                guard row.count > 1,let detail = row[1] as? [String:Any] else {return nil};return detail["exception_message"] as? String
                            }.joined(separator:" ")
                            throw StudioError.message("The video engine could not finish this take. " + details)
                        }
                        if let outputs = entry["outputs"] as? [String:Any] {
                            for value in outputs.values {
                                guard let value = value as? [String:Any] else {continue}
                                for key in ["videos","gifs","images"] {
                                    if let file = (value[key] as? [[String:Any]])?.first(where:{(($0["filename"] as? String) ?? "").lowercased().hasSuffix(".mp4") || (($0["filename"] as? String) ?? "").lowercased().hasSuffix(".mov")}) {found = file;break}
                                }
                            }
                        }
                        if found != nil {break}
                        if (entry["status"] as? [String:Any])?["completed"] as? Bool == true {throw StudioError.message("The workflow finished without an MP4 or MOV output. Add a compatible video-save node.")}
                    }
                    guard let found, let filename = found["filename"] as? String else {throw StudioError.message("Timed out waiting for ComfyUI. The job may still be running on the server.")}
                    progress?.stage = .finishing
                    var components = URLComponents(url:try endpoint("view",address:address),resolvingAgainstBaseURL:false)!
                    components.queryItems = ["filename":filename,"subfolder":found["subfolder"] as? String ?? "","type":found["type"] as? String ?? "output"].map {URLQueryItem(name:$0.key,value:$0.value)}
                    let (data,downloadResponse) = try await session.data(from:components.url!)
                    guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {throw StudioError.message("Cannot retrieve the rendered video from ComfyUI.")}
                    try data.write(to:output,options:.atomic)
                }
                try Task.checkCancellation()
                progress?.stage = .finishing
                var colorHandling = "Explicit native video color metadata"
                if backend == "Automatic" {message = "Checking reference and video colors…";colorHandling = try await VideoColor.tagLocalLTX(output)}
                var media = try await MediaEngine.inspect(output)
                guard media.kind == .video,media.duration > 0 else {throw StudioError.message("The engine returned a file without playable video. The original edit is unchanged.")}
                message = "Sampling motion and checking the finished take…"
                if let sample = try? await MotionSample.read(output) {media.motionEvidence = MotionEvidence(samples:sample.frames.count,meanDifference:sample.meanDifference)}
                try Task.checkCancellation()
                guard store.documentID == documentID else {throw StudioError.message("Take saved locally. Open the original project to import it; the project changed while it was generating.")}
                media.name = (job.shotName ?? "Take") + " · " + Date().formatted(date:.omitted,time:.shortened)
                media.origin = backend == "Automatic" ? "Local LTX · Stillroom" : backend;media.prompt = prompt;media.notes = "Seed \(seed). Review identity, continuity, hands and the first/last frames before using this take."
                media.parentAssetID = job.parentID;media.referenceAssetID = referenceID
                media.direction = job.recipe?.direction
                media.recipe = job.recipe;media.recipe?.colorHandling = colorHandling;media.regenerationDraft = job.recipe?.instructions
                media.notes += " " + colorHandling + "."
                store.change({$0.assets.append(media)},rebuild:false)
                completedAssetID = media.id
                if job.parentID == nil {store.selectedAsset = media.id}
                store.refreshMedia()
                progress?.finish(.ready)
                message = "New take ready. Play at 1× to review motion. Use take fits the current shot; the clock menu keeps normal speed."
                store.status = "New take ready · " + media.name
            } catch is CancellationError {progress?.finish(.cancelled);message = "Cancelled. The original edit is unchanged. A running local render may finish in the background."}
            catch {progress?.finish(Task.isCancelled ? .cancelled : .failed);message = Task.isCancelled ? "Cancelled. The original edit is unchanged. A running local render may finish in the background." : error.localizedDescription}
    }
    func cancel() {
        let queued = queuedJob
        work?.cancel()
        if let queued {
            // Only remove this prompt; never clear somebody else’s local queue.
            Task {
                var request = URLRequest(url:try endpoint("queue",address:queued.address));request.httpMethod = "POST"
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject:["delete":[queued.id]])
                _ = try? await session.data(for:request)
            }
        }
    }
}
