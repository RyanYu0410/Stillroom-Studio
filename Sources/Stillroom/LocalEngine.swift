import Foundation
import AppKit

/// Reuses the production environment, without copying weights or installing packages.
@MainActor
final class LocalEngine {
    struct Installation:Codable,Equatable,Sendable {
        var root:String
        var python:String
        var main:String
        var weights:String
        var gemma:String
    }
    struct Ready {
        let address:String
        let installation:Installation
    }
    private var process:Process?
    private var log:FileHandle?
    private let session:URLSession
    private let directory:URL
    var logURL:URL {directory.appendingPathComponent("Engine.log")}
    private nonisolated var manifest:URL {directory.appendingPathComponent("Engine.json")}
    init(session:URLSession = .shared,directory:URL? = nil) {
        self.session = session
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Stillroom")
    }
    func remember(_ installation:Installation) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(installation).write(to:manifest,options:.atomic)
    }
    private func object(_ path:String,at address:String) async throws -> [String:Any] {
        guard let base = URL(string:address),base.scheme == "http",["localhost","127.0.0.1","::1","[::1]"].contains(base.host ?? "") else {throw StudioError.message("The engine must run on this Mac.")}
        var request = URLRequest(url:base.appendingPathComponent(path));request.timeoutInterval = 2
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,let json = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw StudioError.message("Local engine is not ready.")}
        return json
    }
    nonisolated static func inspect(root:URL,main:URL)->Installation? {
        let fm = FileManager.default
        let python = ["venv/bin/python",".venv/bin/python"].map {root.appendingPathComponent($0)}.first {fm.isExecutableFile(atPath:$0.path)}
        let models = root.appendingPathComponent("models")
        let known = ["ltx-2.3-mlx-q8","ltx-2.3-mlx-q4","ltx-2.3-mlx","gemma-3-12b-it-4bit"].map {models.appendingPathComponent($0)}
        let children = known + ((try? fm.contentsOfDirectory(at:models,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [])
        let weights = children.first {$0.lastPathComponent.hasPrefix("ltx") && fm.fileExists(atPath:$0.appendingPathComponent("connector.safetensors").path)}
        let gemma = children.first {$0.lastPathComponent.lowercased().contains("gemma") && fm.fileExists(atPath:$0.appendingPathComponent("config.json").path)}
        guard let python,let weights,let gemma,fm.fileExists(atPath:main.path) else {return nil}
        return Installation(root:root.path,python:python.path,main:main.path,weights:weights.path,gemma:gemma.path)
    }
    private nonisolated func valid(_ value:Installation)->Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath:value.python) && [value.main,value.weights + "/connector.safetensors",value.gemma + "/config.json"].allSatisfy {fm.fileExists(atPath:$0)}
    }
    private nonisolated func mainCandidates(root:URL)->[URL] {
        var mains = [root.appendingPathComponent("main.py"),root.appendingPathComponent("ComfyUI/main.py")]
        let installs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ComfyUI-Installs")
        for item in (try? FileManager.default.contentsOfDirectory(at:installs,includingPropertiesForKeys:nil)) ?? [] {
            mains += [item.appendingPathComponent("ComfyUI/main.py"),item.appendingPathComponent("main.py")]
        }
        return mains
    }
    func chooseInstallation() async throws -> Installation? {
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true
        panel.message = "Choose the local video engine folder containing venv, models and custom_nodes. No models will be downloaded."
        guard panel.runModal() == .OK,let root = panel.url else {return nil}
        let selected = await Task.detached { () -> Installation? in
            for main in self.mainCandidates(root:root) {if let value = Self.inspect(root:root,main:main) {return value}}
            return nil
        }.value
        if let selected {try remember(selected);return selected}
        throw StudioError.message("This folder needs a Python venv, local LTX video weights, local Gemma weights and a ComfyUI installation. Choose the original production engine folder.")
    }
    private nonisolated func discover(stats:[String:Any]? = nil)->Installation? {
        if let data = try? Data(contentsOf:manifest),let saved = try? JSONDecoder().decode(Installation.self,from:data),valid(saved) {return saved}
        if let system = stats?["system"] as? [String:Any],let argv = system["argv"] as? [String],let main = argv.first,
           let index = argv.firstIndex(of:"--base-directory"),argv.indices.contains(index+1),
           let value = Self.inspect(root:URL(fileURLWithPath:argv[index+1]),main:URL(fileURLWithPath:main)) {return value}
        var ancestor = Bundle.main.bundleURL
        for _ in 0..<7 {
            for relative in ["work/comfy-film","comfy-film",""] {
                let root = relative.isEmpty ? ancestor : ancestor.appendingPathComponent(relative)
                for main in mainCandidates(root:root) {if let value = Self.inspect(root:root,main:main) {return value}}
            }
            ancestor.deleteLastPathComponent()
        }
        return nil
    }
    private func checkNodes(at address:String) async throws {
        let info = try await object("object_info/LTX2MLXGenerate",at:address)
        let loader = try await object("object_info/LTX2MLXModelLoader",at:address)
        guard info["LTX2MLXGenerate"] != nil,loader["LTX2MLXModelLoader"] != nil else {
            throw StudioError.message("This ComfyUI installation needs the LTX2 MLX video nodes used by the production engine.")
        }
    }
    func ready(preferredAddress:String,probeAddresses:[String]? = nil,update:(String)->Void) async throws -> Ready {
        update("Finding the local video engine…")
        var addresses = probeAddresses ?? [preferredAddress,"http://127.0.0.1:8188","http://127.0.0.1:8190"]
        var seen = Set<String>();addresses = addresses.filter {seen.insert($0).inserted}
        for address in addresses {
            try Task.checkCancellation()
            if let stats = try? await object("system_stats",at:address),let installation = await Task.detached(operation:{self.discover(stats:stats)}).value,
               (try? await checkNodes(at:address)) != nil {
                try remember(installation)
                update("Local LTX video engine ready")
                return Ready(address:address,installation:installation)
            }
        }
        guard let installation = await Task.detached(operation:{self.discover()}).value else {
            throw StudioError.message("Local video engine not found. Open Generation settings → Choose engine folder, and select the installed production environment. No paid service is required.")
        }
        try remember(installation)
        // Never replace a process using the standard port. Our own worker uses 8190.
        let address = "http://127.0.0.1:8190"
        if process?.isRunning != true {
            update("Starting the local video engine…")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            FileManager.default.createFile(atPath:logURL.path,contents:nil)
            log = try FileHandle(forWritingTo:logURL)
            let worker = Process();worker.executableURL = URL(fileURLWithPath:installation.python)
            worker.arguments = [installation.main,"--base-directory",installation.root,"--listen","127.0.0.1","--port","8190","--output-directory",directory.appendingPathComponent("Engine-renders").path,"--preview-method","none"]
            var environment = ProcessInfo.processInfo.environment
            environment.merge(["HF_HUB_OFFLINE":"1","HF_HUB_DISABLE_XET":"1","HF_HUB_DISABLE_TELEMETRY":"1","HF_HUB_DISABLE_IMPLICIT_TOKEN":"1","HF_HOME":installation.root + "/hf-cache","LTX2_GEMMA_MAX_LENGTH":"256","LTX_FILM_GEMMA_DIR":installation.gemma,"LTX_FILM_NO_AUDIO":"1","PYTHONUNBUFFERED":"1"]) {_,new in new}
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            worker.environment = environment;worker.currentDirectoryURL = URL(fileURLWithPath:installation.root)
            worker.standardOutput = log;worker.standardError = log
            try worker.run();process = worker
        }
        for _ in 0..<90 {
            try Task.checkCancellation()
            if (try? await object("system_stats",at:address)) != nil {
                try await checkNodes(at:address)
                update("Local LTX video engine ready")
                return Ready(address:address,installation:installation)
            }
            if process?.isRunning == false {break}
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        let detail = (try? String(contentsOf:logURL,encoding:.utf8))?.suffix(800) ?? ""
        throw StudioError.message("The local video engine could not start. Open the engine log in Generation settings. \(detail)")
    }
    static func workflow(installation:Installation,width:Int,height:Int,frames:Int,seed:Int)->[String:Any] {
        // Anchor frame zero only. Reusing the same still in the middle/end makes
        // the motion return to the starting pose and fights continuous camera moves.
        ["1":["class_type":"LoadImage","inputs":["image":"stillroom-reference.png"]],
         "2":["class_type":"LTX2MLXModelLoader","inputs":["model_dir":"dgrauet/ltx-2.3-mlx-q8","custom_model_dir":installation.weights,"pipeline_type":"distilled","low_ram":ProcessInfo.processInfo.physicalMemory < 48*1024*1024*1024]],
         "3":["class_type":"LTX2MLXGenerate","inputs":["pipeline":["2",0],"image":["1",0],"prompt":"","width":width,"height":height,"num_frames":frames,"seed":seed,"cfg_scale":3.0,"frame_rate":24.0,"filename_prefix":"Stillroom/take"]]]
    }
}
