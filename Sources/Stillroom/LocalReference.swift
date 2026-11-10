import SwiftUI
import AVFoundation

@MainActor
final class LocalReference:ObservableObject {
    struct Model:Identifiable {
        let id:String
        let loaded:Bool
        var name:String {
            let value = id.lowercased()
            if value.contains("9b") {return "FLUX · 9B"}
            if value.contains("4b") {return "FLUX · 4B"}
            if value.contains("qwen") {return "Qwen Image"}
            return id.split(separator:"/").last.map(String.init) ?? id
        }
    }
    @Published var models:[Model] = []
    @Published var modelID = ""
    @Published var detail = true
    @Published var busy = false
    @Published var started:Date?
    @Published var message = "Uses image models already installed in MLX Core. No download or paid API."
    @Published var candidateID:UUID?
    private let session:URLSession
    private let outputDirectory:URL
    private var work:Task<Void,Never>?
    init(session:URLSession = .shared,outputDirectory:URL? = nil) {
        self.session = session
        self.outputDirectory = outputDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Stillroom/References")
    }
    private func request(_ path:String,body:[String:Any]? = nil) async throws -> [String:Any] {
        // Fixed loopback destination. Returned remote URLs are never followed.
        var request = URLRequest(url:URL(string:"http://127.0.0.1:11234/"+path)!)
        request.timeoutInterval = body == nil ? 10 : 1800
        if let body {request.httpMethod = "POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody = try JSONSerialization.data(withJSONObject:body,options:.withoutEscapingSlashes)}
        let (data,response) = try await session.data(for:request)
        let value = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode,(200...299).contains(status) else {
            let detail = (value["error"] as? [String:Any])?["message"] as? String ?? value["error"] as? String ?? String(data:data.prefix(300),encoding:.utf8) ?? ""
            throw StudioError.message("The local image engine could not finish. " + detail)
        }
        return value
    }
    func discover() async {
        guard !busy else {return}
        do {try await refreshModels();message = models.isEmpty ? "No local image models found. Open MLX Core and check the installed models." : "\(models.count) installed image models · local only"}
        catch {message = "Open MLX Core on this Mac, then Check models. " + error.localizedDescription}
    }
    private func refreshModels() async throws {
        let value = try await request("v1/models")
        models = (value["data"] as? [[String:Any]] ?? []).filter {($0["capabilities"] as? [String] ?? []).contains("image") && (($0["bytes_on_disk"] as? Double ?? 0) > 0 || $0["loaded"] as? Bool == true)}.compactMap {item in
            guard let id = item["id"] as? String else {return nil}
            return Model(id:id,loaded:item["loaded"] as? Bool ?? false)
        }
        if !models.contains(where:{$0.id == modelID}) {modelID = models.first(where:{$0.id.lowercased().contains("9b")})?.id ?? models.first?.id ?? ""}
    }
    static func body(model:String,prompt:String,image:Data,seed:Int,detail:Bool)->[String:Any] {
        let qwen = model.lowercased().contains("qwen")
        return ["model":model,"prompt":prompt,"image":image.base64EncodedString(),"mode":"edit","seed":seed,"steps":qwen ? (detail ? 40 : 20) : (detail ? 12 : 4),"size":detail ? "1344x768" : "768x448","stream":false,"response_format":"b64_json"]
    }
    func generate(source:MediaAsset,shot:Shot,direction:ShotDirection,store:StudioStore,lab:LocalGeneration) {
        guard !busy,!lab.busy,!lab.referenceBusy,!direction.referenceDirection.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
        started = Date();busy = true;lab.referenceBusy = true;candidateID = nil
        let documentID = store.documentID
        let sourceURL = store.url(source)
        let reference = source.referenceAssetID.flatMap {id in store.project.assets.first {$0.id == id && $0.kind == .image}}
        let referenceURL = reference.map {store.url($0)}
        let selected = modelID,quality = detail,seed = Int.random(in:0...999999)
        work = Task {
            var ownedModel:String?
            do {
                if let queue = try? await lab.json("queue"),!(queue["queue_running"] as? [[Any]] ?? []).isEmpty {throw StudioError.message("Let the running local video render finish before creating a reference.")}
                message = "Checking installed image model…"
                try await refreshModels()
                let id = selected.isEmpty ? modelID : selected
                guard let model = models.first(where:{$0.id == id}) else {throw StudioError.message("Choose an image model already installed on this Mac.")}
                let image:Data
                if let referenceURL {image = try VideoColor.referencePNG(at:referenceURL)}
                else if source.kind == .image {image = try VideoColor.referencePNG(at:sourceURL)}
                else {
                    let generator = AVAssetImageGenerator(asset:AVURLAsset(url:sourceURL));generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width:1920,height:1080)
                    generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                    image = try VideoColor.referencePNG(try await generator.image(at:CMTime(seconds:shot.sourceIn,preferredTimescale:600)).image)
                }
                try Task.checkCancellation()
                if !model.loaded {
                    message = "Loading \(model.name) from this Mac…"
                    // Only load a discovered model. Never change the serving default or download weights.
                    ownedModel = id
                    _ = try await request("v1/load-model",body:["model":id])
                }
                try Task.checkCancellation()
                message = "Composing the reference image locally…"
                let prompt = direction.imagePrompt(),body = Self.body(model:id,prompt:prompt,image:image,seed:seed,detail:quality)
                let response = try await request("v1/images/generations",body:body)
                try Task.checkCancellation()
                guard let item = (response["data"] as? [[String:Any]])?.first,let encoded = item["b64_json"] as? String,let data = Data(base64Encoded:encoded),let picture = NSImage(data:data),let cg = picture.cgImage(forProposedRect:nil,context:nil,hints:nil) else {throw StudioError.message("The local model returned no usable image.")}
                let png = try VideoColor.referencePNG(cg)
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                let output = outputDirectory.appendingPathComponent(UUID().uuidString+".png");try png.write(to:output,options:.atomic)
                guard store.documentID == documentID else {throw StudioError.message("The project changed. The reference is saved locally; generate again in the current project.")}
                var media = MediaAsset(name:"Reference variation · " + shot.name,path:output.path,kind:.image,width:cg.width,height:cg.height,origin:"Local image model",prompt:prompt,notes:"Review identity, framing, hands and props before using this reference.")
                media.parentAssetID = store.project.familyRoot(of:source);media.direction = direction
                media.referenceRecipe = ReferenceRecipe(model:id,seed:seed,steps:body["steps"] as? Int ?? 0,prompt:prompt,sourceAssetID:reference?.id ?? source.id)
                store.change({$0.assets.append(media)},rebuild:false);store.refreshMedia();candidateID = media.id
                message = "Reference variation ready. Compare it, then choose Use this reference."
            } catch {message = Task.isCancelled ? "Reference request cancelled. The current reference is unchanged." : error.localizedDescription}
            if let ownedModel {
                // Free only a model that this request loaded; preserve already-resident user models.
                let cleanup = Task {_ = try? await self.request("v1/unload-model",body:["model":ownedModel])}
                await cleanup.value
            }
            busy = false;lab.referenceBusy = false
        }
    }
    func cancel() {work?.cancel()}
    func createStoryboardFrame(cardID:UUID,store:StudioStore) {
        let lab = store.generation
        guard !busy,!lab.busy,!lab.referenceBusy,let board = store.project.storyboard,let card = board.cards.first(where:{$0.id == cardID}) else {return}
        let document = store.documentID,selected = modelID,quality = detail,seed = Int.random(in:0...999999)
        let reference = board.referenceAssetID.flatMap {id in store.project.assets.first {$0.id == id && $0.kind == .image}}
        let referenceURL = reference.map {store.url($0)}
        started = Date();busy = true;lab.referenceBusy = true;candidateID = nil
        work = Task {
            var ownedModel:String?
            do {
                if let queue = try? await lab.json("queue"),!(queue["queue_running"] as? [[Any]] ?? []).isEmpty {throw StudioError.message("Let the running local video render finish before creating a storyboard frame.")}
                message = "Checking the installed image model…";try await refreshModels()
                let id = selected.isEmpty ? modelID : selected
                guard let model = models.first(where:{$0.id == id}) else {throw StudioError.message("Choose an installed image model first.")}
                let prompt = board.framePrompt(for:card,hasReference:reference != nil)
                var body:[String:Any]
                if let referenceURL {body = Self.body(model:id,prompt:prompt,image:try VideoColor.referencePNG(at:referenceURL),seed:seed,detail:quality)}
                else {body = ["model":id,"prompt":prompt,"seed":seed,"steps":id.lowercased().contains("qwen") ? (quality ? 40 : 20) : (quality ? 12 : 4),"size":quality ? "1344x768" : "768x448","stream":false,"response_format":"b64_json"]}
                if !model.loaded {ownedModel = id;message = "Loading \(model.name) from this Mac…";_ = try await request("v1/load-model",body:["model":id])}
                try Task.checkCancellation();message = "Drawing the storyboard frame locally…"
                let response = try await request("v1/images/generations",body:body)
                try Task.checkCancellation()
                guard let item = (response["data"] as? [[String:Any]])?.first,let encoded = item["b64_json"] as? String,let data = Data(base64Encoded:encoded),let image = NSImage(data:data),let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {throw StudioError.message("The local model returned no usable storyboard frame.")}
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                let output = outputDirectory.appendingPathComponent(UUID().uuidString+".png");try VideoColor.referencePNG(cg).write(to:output,options:.atomic)
                guard store.documentID == document,store.project.storyboard?.id == board.id,let i = store.project.storyboard?.cards.firstIndex(where:{$0.id == cardID}) else {throw StudioError.message("The board changed. The frame remains saved locally, but was not attached to a different board.")}
                var media = MediaAsset(name:"Board frame · " + card.title,path:output.path,kind:.image,width:cg.width,height:cg.height,origin:"Local storyboard frame",prompt:prompt,notes:"Review character identity, limbs, markings and props before using as a motion reference.")
                media.direction = board.direction(for:card)
                media.referenceRecipe = ReferenceRecipe(model:id,seed:seed,steps:body["steps"] as? Int ?? 0,prompt:prompt,sourceAssetID:reference?.id)
                store.change({p in p.assets.append(media);p.storyboard?.cards[i].frameAssetID = media.id;if p.storyboard?.referenceAssetID == nil {p.storyboard?.referenceAssetID = media.id}},rebuild:false)
                store.refreshMedia();candidateID = media.id;message = "Frame ready · attached to the card. The first frame becomes the continuity reference until you choose another."
            } catch {message = Task.isCancelled ? "Frame cancelled. Existing references are unchanged." : error.localizedDescription}
            if let ownedModel {let cleanup = Task {_ = try? await self.request("v1/unload-model",body:["model":ownedModel])};await cleanup.value}
            busy = false;lab.referenceBusy = false
        }
    }
}
