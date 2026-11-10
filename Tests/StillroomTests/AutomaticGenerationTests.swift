import XCTest
@testable import Stillroom

final class ComfyGenerationProtocol:URLProtocol {
    static var root:URL!
    static var movie = Data()
    static var submitted:[String:Any] = [:]
    static var uploaded = false
    static var fail = false
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty,let stream = request.httpBodyStream {
                stream.open();defer {stream.close()}
                var bytes = [UInt8](repeating:0,count:8192)
                while stream.hasBytesAvailable {let count = stream.read(&bytes,maxLength:bytes.count);if count <= 0 {break};body.append(contentsOf:bytes.prefix(count))}
            }
            let path = request.url!.path
            var json:[String:Any] = [:]
            switch path {
            case "/system_stats":json = ["system":["argv":[Self.root.appendingPathComponent("main.py").path,"--base-directory",Self.root.path]]]
            case "/object_info/LTX2MLXGenerate":json = ["LTX2MLXGenerate":[:]]
            case "/object_info/LTX2MLXModelLoader":json = ["LTX2MLXModelLoader":[:]]
            case "/object_info/MissingMomentPinnedTake":json = ["MissingMomentPinnedTake":[:]]
            case "/upload/image":Self.uploaded = body.range(of:Data("Content-Disposition: form-data".utf8)) != nil;json = ["name":"actual-original.png","subfolder":""]
            case "/prompt":Self.submitted = try JSONSerialization.jsonObject(with:body) as? [String:Any] ?? [:];json = ["prompt_id":"stillroom-test-job"]
            case "/history":json = [:]
            case "/queue":json = ["queue_running":[],"queue_pending":[]]
            case "/history/stillroom-test-job":
                json = Self.fail ? ["stillroom-test-job":["status":["status_str":"error","messages":[["execution_error",["exception_message":"Model weights missing in fixture"]]]]]] : ["stillroom-test-job":["status":["completed":true],"outputs":["3":["images":[["filename":"take.mp4","subfolder":"Stillroom","type":"output"]]]]]]
            case "/view":break
            default:throw StudioError.message("Unexpected request: " + path)
            }
            let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:path == "/view" ? Self.movie : try JSONSerialization.data(withJSONObject:json))
            client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}

final class AutomaticGenerationTests:XCTestCase {
    @MainActor private func fixture(fail:Bool = false) async throws -> (LocalGeneration,StudioStore,FilmProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-engine-test-" + UUID().uuidString)
        let fm = FileManager.default
        for relative in ["venv/bin","models/ltx-2.3-mlx-q8","models/gemma-3-12b-it-4bit"] {try fm.createDirectory(at:root.appendingPathComponent(relative),withIntermediateDirectories:true)}
        for relative in ["main.py","venv/bin/python","models/ltx-2.3-mlx-q8/connector.safetensors","models/gemma-3-12b-it-4bit/config.json"] {try Data().write(to:root.appendingPathComponent(relative))}
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.appendingPathComponent("venv/bin/python").path)
        ComfyGenerationProtocol.root = root;ComfyGenerationProtocol.fail = fail;ComfyGenerationProtocol.uploaded = false;ComfyGenerationProtocol.submitted = [:]
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo/Media/03-native.mp4")
        let file = fm.fileExists(atPath:local.path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo/Media/03-native.mp4")
        ComfyGenerationProtocol.movie = try Data(contentsOf:file)
        var original = try await MediaEngine.inspect(file);original.prompt = "Original woman and room."
        original.direction = ShotDirection(camera:"Slow pullback",continuity:"The laptop stays on the table.")
        let store = StudioStore(sessionDirectory:root.appendingPathComponent("Session"),recoverSession:false)
        store.project.assets = [original];store.project.shots = [Shot(assetID:original.id,name:"Original",sourceDuration:4)]
        let before = store.project
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [ComfyGenerationProtocol.self]
        let generator = LocalGeneration(session:URLSession(configuration:configuration),outputDirectory:root.appendingPathComponent("Results"),engineDirectory:root.appendingPathComponent("Engine"))
        generator.backend = "Automatic";generator.durationSeconds = 5;generator.quality = "Cinema";generator.lockSeed = true;generator.seed = 246
        generator.requestRegeneration(shotID:store.project.shots[0].id,instructions:"A slow pullback.",store:store)
        let deadline = Date().addingTimeInterval(15)
        while generator.busy && Date() < deadline {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(generator.busy)
        return (generator,store,before)
    }
    @MainActor func testAutomaticRegenerationBuildsUploadsDownloadsAndImportsTake() async throws {
        let (generator,store,before) = try await fixture()
        XCTAssertEqual(generator.progress?.stage,.ready)
        XCTAssertEqual(generator.progress?.fraction(at:Date()),1)
        let id = try XCTUnwrap(generator.completedAssetID,generator.message)
        let take = try XCTUnwrap(store.project.assets.first {$0.id == id})
        XCTAssertEqual(store.project.shots,before.shots)
        XCTAssertEqual(take.parentAssetID,before.assets[0].id)
        XCTAssertEqual(take.recipe?.workflow,"LTX2MLXGenerate")
        XCTAssertEqual(take.recipe?.requestedDuration,5)
        XCTAssertEqual(take.recipe?.direction?.camera,"Slow pullback")
        XCTAssertEqual(take.direction?.continuity,"The laptop stays on the table.")
        XCTAssertEqual(take.recipe?.frames,121)
        XCTAssertNotNil(take.recipe?.colorHandling)
        XCTAssertTrue(ComfyGenerationProtocol.uploaded)
        let graph = try XCTUnwrap(ComfyGenerationProtocol.submitted["prompt"] as? [String:Any])
        let image = try XCTUnwrap((graph["1"] as? [String:Any])?["inputs"] as? [String:Any])
        XCTAssertEqual(image["image"] as? String,"actual-original.png")
        let motion = try XCTUnwrap((graph["3"] as? [String:Any])?["inputs"] as? [String:Any])
        XCTAssertEqual(motion["width"] as? Int,1280);XCTAssertEqual(motion["height"] as? Int,704)
        XCTAssertEqual(motion["seed"] as? Int,246)
        XCTAssertEqual(motion["num_frames"] as? Int,121)
        XCTAssertEqual((graph["3"] as? [String:Any])?["class_type"] as? String,"LTX2MLXGenerate")
        XCTAssertNil(motion["middle_strength"]);XCTAssertNil(motion["end_strength"])
        XCTAssertNil(motion["middle_image"]);XCTAssertNil(motion["end_image"])
        XCTAssertFalse((motion["prompt"] as? String ?? "").contains("Original woman and room."))
        XCTAssertEqual(take.recipe?.originalPrompt,"Original woman and room.")
        XCTAssertTrue((motion["prompt"] as? String ?? "").contains("A slow pullback."))
        XCTAssertFalse((motion["prompt"] as? String ?? "").contains("The laptop stays on the table."))
        XCTAssertTrue(FileManager.default.fileExists(atPath:take.path))
    }
    @MainActor func testEngineFailureShowsUsefulErrorAndKeepsOriginalEdit() async throws {
        let (generator,store,before) = try await fixture(fail:true)
        XCTAssertEqual(generator.progress?.stage,.failed)
        XCTAssertFalse(generator.progress?.active ?? true)
        XCTAssertNil(generator.completedAssetID)
        XCTAssertTrue(generator.message.contains("Model weights missing in fixture"),generator.message)
        XCTAssertEqual(store.project.shots,before.shots)
        XCTAssertEqual(store.project.assets.filter {$0.kind == .video}.count,1)
    }
}
