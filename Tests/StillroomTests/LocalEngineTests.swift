import XCTest
import AVFoundation
@testable import Stillroom

final class LocalEngineTests:XCTestCase {
    @MainActor func testAutomaticWorkflowUsesLocalWeightsAndSingleOriginalReference() throws {
        let install = LocalEngine.Installation(root:"/local/film",python:"/local/film/venv/bin/python",main:"/local/ComfyUI/main.py",weights:"/local/film/models/ltx-2.3-mlx-q8",gemma:"/local/film/models/gemma")
        let graph = LocalEngine.workflow(installation:install,width:1280,height:704,frames:81,seed:123)
        let loader = try XCTUnwrap((graph["2"] as? [String:Any])?["inputs"] as? [String:Any])
        XCTAssertEqual(loader["custom_model_dir"] as? String,install.weights)
        XCTAssertEqual(loader["pipeline_type"] as? String,"distilled")
        let take = try XCTUnwrap((graph["3"] as? [String:Any])?["inputs"] as? [String:Any])
        XCTAssertEqual(take["width"] as? Int,1280);XCTAssertEqual(take["height"] as? Int,704)
        XCTAssertEqual(take["num_frames"] as? Int,81);XCTAssertEqual(take["seed"] as? Int,123)
        XCTAssertEqual(take["frame_rate"] as? Double,24)
        XCTAssertNil(take["middle_image"]);XCTAssertNil(take["middle_strength"]);XCTAssertNil(take["end_strength"])
        XCTAssertEqual((graph["3"] as? [String:Any])?["class_type"] as? String,"LTX2MLXGenerate")
        XCTAssertNotNil(take["image"]);XCTAssertNil(take["end_image"],"A forced matching last frame would fight a camera pullback.")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:graph))
    }
    @MainActor func testLiveEngineCanStartOwnedWorker() async throws {
        guard ProcessInfo.processInfo.environment["STILLROOM_LIVE_ENGINE_TEST"] == "1" else {throw XCTSkip("Opt-in real local engine startup check")}
        let engine = LocalEngine()
        // Use the installation discovered from the existing production server, then test a cold worker.
        let reused = try await engine.ready(preferredAddress:"http://127.0.0.1:8188") {_ in}
        XCTAssertTrue(FileManager.default.fileExists(atPath:reused.installation.weights + "/connector.safetensors"))
        let started = try await engine.ready(preferredAddress:"http://127.0.0.1:8190",probeAddresses:[]) {_ in}
        XCTAssertEqual(started.address,"http://127.0.0.1:8190")
    }
    @MainActor func testLiveRegenerationReturnsRealVideoAndPreservesEdit() async throws {
        guard ProcessInfo.processInfo.environment["STILLROOM_LIVE_RENDER_TEST"] == "1" else {throw XCTSkip("Opt-in real LTX generation, takes several minutes")}
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo/Media/07-native.mp4")
        let file = FileManager.default.fileExists(atPath:local.path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo/Media/07-native.mp4")
        var original = try await MediaEngine.inspect(file)
        original.prompt = "A photographic live-action portrait of a woman with short dark wavy hair in an olive cardigan and ivory shirt, sitting at a wooden table, studying a dark laptop in the foreground left. Rainy window daylight, a warm practical lamp, walnut furniture and olive tones. Real skin texture and quiet, natural lighting."
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-live-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        let store = StudioStore(sessionDirectory:temporary,recoverSession:false)
        store.project.assets = [original]
        store.project.shots = [Shot(assetID:original.id,name:"Explaining a guess",sourceDuration:original.duration)]
        let before = store.project
        let generator = LocalGeneration(outputDirectory:temporary.appendingPathComponent("Generations"))
        generator.durationSeconds = 3.375
        generator.backend = "Automatic";generator.address = "http://127.0.0.1:8190";generator.quality = "Balanced";generator.seed = 913710;generator.lockSeed = true
        generator.requestRegeneration(shotID:store.project.shots[0].id,instructions:"Keep the same woman, clothing and room. Let her look up gently as the camera slowly pulls back. Preserve the quiet, natural light.",store:store)
        let deadline = Date().addingTimeInterval(1200)
        while generator.busy && Date() < deadline {try await Task.sleep(nanoseconds:500_000_000)}
        XCTAssertFalse(generator.busy)
        let id = try XCTUnwrap(generator.completedAssetID,generator.message)
        let take = try XCTUnwrap(store.project.assets.first {$0.id == id})
        XCTAssertEqual(take.parentAssetID,original.id)
        XCTAssertEqual(take.width,1024);XCTAssertEqual(take.height,576)
        XCTAssertEqual(take.duration,81.0/24,accuracy:0.05)
        XCTAssertEqual(take.recipe?.workflow,"LTX2MLXGenerate")
        XCTAssertEqual(take.recipe?.instructions,"Keep the same woman, clothing and room. Let her look up gently as the camera slowly pulls back. Preserve the quiet, natural light.")
        XCTAssertEqual(store.project.shots,before.shots);XCTAssertEqual(store.project.subtitles,before.subtitles);XCTAssertEqual(store.project.sounds,before.sounds)
        let result = temporary.appendingPathComponent("Regeneration-Example.mp4")
        if FileManager.default.fileExists(atPath:result.path) {try FileManager.default.removeItem(at:result)}
        try FileManager.default.copyItem(at:store.url(take),to:result)
        try JSONEncoder().encode(store.project).write(to:temporary.appendingPathComponent("Verified-project.json"),options:.atomic)
        print("LIVE_REGENERATION_VIDEO=" + result.path)
        try store.project.useTake(take.id,for:store.project.shots[0].id)
        XCTAssertEqual(store.project.duration,before.duration,accuracy:0.00001)
    }
}
