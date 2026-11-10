import XCTest
import AVFoundation
@testable import Stillroom

final class RecordingGenerationProtocol:URLProtocol {
    static var received:[String:Any] = [:]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty,let stream = request.httpBodyStream {
                stream.open();defer {stream.close()}
                var buffer = [UInt8](repeating:0,count:8192)
                while stream.hasBytesAvailable {let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 {break};data.append(contentsOf:buffer.prefix(n))}
            }
            Self.received = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
            let body:[String:Any] = ["format":"rgb8","width":64,"height":64,"frames":9,"fps":24,"data":Data(repeating:120,count:64*64*3*9).base64EncodedString()]
            let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:body))
            client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}

final class RegenerationTests:XCTestCase {
    func testMotionPromptPrioritizesRequestedActionWithoutOldStillnessInstructions() {
        let prompt = RegenerationDirection.prompt(change:"Pull back, and let her look up.")
        XCTAssertTrue(prompt.contains("Pull back, and let her look up."))
        XCTAssertFalse(prompt.contains("reference image"))
        XCTAssertFalse(prompt.contains("restrained"));XCTAssertFalse(prompt.contains("locked"))
        XCTAssertFalse(prompt.contains("micro-movement"))
    }
    func testUseTakePreservesTimingOtherShotsCaptionsAndSound() throws {
        let original = MediaAsset(name:"Original",path:"a.mp4",kind:.video,duration:10)
        var new = MediaAsset(name:"New",path:"b.mp4",kind:.video,duration:4);new.parentAssetID = original.id
        var p = FilmProject();p.assets = [original,new]
        p.shots = [Shot(assetID:original.id,name:"First",sourceDuration:8),Shot(assetID:original.id,name:"Second",sourceDuration:5)]
        p.subtitles = [Subtitle(start:9,end:11,text:"The timing stays.")]
        p.sounds = [SoundLayer(assetID:original.id,name:"Voice",duration:10)]
        let duration = p.duration,secondStart = p.start(of:p.shots[1]),captions = p.subtitles,sounds = p.sounds
        try p.useTake(new.id,for:p.shots[0].id)
        XCTAssertEqual(p.duration,duration,accuracy:0.00001);XCTAssertEqual(p.start(of:p.shots[1]),secondStart,accuracy:0.00001)
        XCTAssertEqual(p.shots[0].speed,0.5);XCTAssertEqual(p.subtitles,captions);XCTAssertEqual(p.sounds,sounds)
        XCTAssertTrue(p.assets.contains {$0.id == original.id})
    }
    func testShortTakeIsRejectedWithoutChangingProject() {
        let original = MediaAsset(name:"Original",path:"a.mp4",kind:.video,duration:100)
        let new = MediaAsset(name:"New",path:"b.mp4",kind:.video,duration:1)
        var p = FilmProject();p.assets = [original,new];p.shots = [Shot(assetID:original.id,name:"Long shot",sourceDuration:100)]
        let before = p
        XCTAssertThrowsError(try p.useTake(new.id,for:p.shots[0].id));XCTAssertEqual(p,before)
    }
    func testTakeFamilyAndOriginalImageRestore() throws {
        let image = MediaAsset(name:"Original",path:"image.png",kind:.image)
        var take = MediaAsset(name:"Take",path:"take.mp4",kind:.video,duration:4);take.parentAssetID = image.id
        var next = take;next.id = UUID();next.parentAssetID = take.id
        var p = FilmProject();p.assets = [image,take,next];p.shots = [Shot(assetID:take.id,name:"Shot",sourceDuration:4,speed:0.5)]
        XCTAssertEqual(p.takes(for:next).map(\.id),[take.id,next.id])
        try p.useTake(image.id,for:p.shots[0].id)
        XCTAssertEqual(p.shots[0].duration,8);XCTAssertEqual(p.shots[0].assetID,image.id)
    }
    func testOldProjectsDecodeWithoutNewMetadata() throws {
        let media = MediaAsset(name:"Old",path:"old.mp4",kind:.video,duration:5)
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(media)) as! [String:Any]
        for key in ["parentAssetID","referenceAssetID","regenerationDraft","recipe"] {json.removeValue(forKey:key)}
        let decoded = try JSONDecoder().decode(MediaAsset.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(decoded.id,media.id);XCTAssertNil(decoded.recipe);XCTAssertNil(decoded.parentAssetID)
    }
    @MainActor func testRegenerationSendsActualSourceFrameAndKeepsOriginal() async throws {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo/Media/03-native.mp4")
        let file = FileManager.default.fileExists(atPath:local.path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo/Media/03-native.mp4")
        var media = try await MediaEngine.inspect(file)
        media.prompt = "Same woman in an olive cardigan, working at her laptop."
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-regeneration-" + UUID().uuidString)
        let store = StudioStore(sessionDirectory:temporary,recoverSession:false)
        store.project.assets = [media];store.project.shots = [Shot(assetID:media.id,name:"Laptop",sourceIn:1,sourceDuration:3)]
        let shot = store.project.shots[0];store.selectedShot = shot.id
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [RecordingGenerationProtocol.self]
        let generator = LocalGeneration(session:URLSession(configuration:config),outputDirectory:temporary.appendingPathComponent("Generations"))
        generator.backend = "MLX-Serve";generator.address = "http://127.0.0.1:11234";generator.model = "fixture-video-model";generator.seed = 16;generator.lockSeed = false
        // Model setup must not turn a requested clip regeneration into an unrelated text-to-video job.
        generator.pendingRegeneration = LocalGeneration.PendingRegeneration(shotID:shot.id,documentID:store.documentID,instructions:"Make the camera pull back.",seedOverride:72)
        generator.resumeRegeneration(store:store)
        let deadline = Date().addingTimeInterval(10)
        while generator.busy && Date() < deadline {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(generator.busy)
        XCTAssertNil(generator.pendingRegeneration)
        XCTAssertFalse(generator.lockSeed,"A controlled final seed must not change the user’s seed-lock preference.")
        let id = try XCTUnwrap(generator.completedAssetID,generator.message)
        let result = try XCTUnwrap(store.project.assets.first {$0.id == id})
        XCTAssertEqual(result.parentAssetID,media.id);XCTAssertEqual(result.recipe?.referenceTime,1);XCTAssertEqual(result.recipe?.seed,72)
        let reference = try XCTUnwrap(store.project.assets.first {$0.id == result.referenceAssetID})
        let sent = try XCTUnwrap(RecordingGenerationProtocol.received["first_frame_image"] as? String)
        XCTAssertEqual(Data(base64Encoded:sent),try Data(contentsOf:store.url(reference)))
        let prompt = try XCTUnwrap(RecordingGenerationProtocol.received["prompt"] as? String)
        XCTAssertFalse(prompt.contains(media.prompt));XCTAssertTrue(prompt.contains("Make the camera pull back."))
        XCTAssertEqual(result.recipe?.originalPrompt,media.prompt,"Original direction remains in provenance, without fighting new motion.")
        XCTAssertEqual(store.project.shots[0],shot,"Generating should never replace the timeline automatically.")
        XCTAssertEqual(store.selectedShot,shot.id)
        try store.project.useTake(result.id,for:shot.id)
        XCTAssertEqual(store.project.duration,3,accuracy:0.00001)
        XCTAssertTrue(store.project.assets.contains {$0.id == media.id})
        // Generated video here is a deterministic transport fixture, not a model quality test.
    }
}
