import XCTest
import AVFoundation
@testable import Stillroom

final class AssistantProtocol:URLProtocol {
    static var answer = ""
    static var truncated = false
    static var bodies:[[String:Any]] = []
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let path = request.url!.path
        var json:[String:Any] = [:]
        switch path {
        case "/v1/models":json = ["data":[["id":"flux-image","capabilities":["image"],"bytes_on_disk":1000]]]
        case "/api/tags":json = ["models":[["name":"qwen2.5:14b","size":1000],["name":"remote:cloud","size":1000],["name":"nomic-embed","size":1000]]]
        case "/api/ps":json = ["models":[]]
        case "/api/chat":
            var data = request.httpBody ?? Data()
            if data.isEmpty,let stream = request.httpBodyStream {
                stream.open();defer {stream.close()};var bytes = [UInt8](repeating:0,count:8192)
                while stream.hasBytesAvailable {let n = stream.read(&bytes,maxLength:bytes.count);if n <= 0 {break};data.append(contentsOf:bytes.prefix(n))}
            }
            Self.bodies.append((try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:])
            json = ["done":true,"done_reason":Self.truncated ? "length" : "stop","message":["content":Self.answer]]
        case "/queue":json = ["queue_running":[],"queue_pending":[]]
        default:break
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EditAssistantTests:XCTestCase {
    func project()->FilmProject {
        let image = MediaAsset(name:"A photograph",path:"/fixture.png",kind:.image)
        let take = MediaAsset(name:"A candidate",path:"/fixture.mp4",kind:.video,duration:2.65)
        let audio = MediaAsset(name:"Voice",path:"/fixture.m4a",kind:.audio,duration:30)
        return FilmProject(assets:[image,take,audio],shots:[Shot(assetID:image.id,name:"Opening",sourceDuration:334.0/24),Shot(assetID:image.id,name:"Ending",sourceDuration:5)],sounds:[SoundLayer(assetID:audio.id,name:"Voice",duration:18)],subtitles:[Subtitle(start:1,end:3,text:"A moment.")])
    }
    func suggestion(_ kind:EditSuggestion.Kind,target:UUID,source:String = "",text:String = "",value:Double = 0,value2:Double = 0,camera:String = "")->EditSuggestion {
        EditSuggestion(kind:kind,target:target.uuidString,source:source,title:"A considered edit",reason:"A clearer moment.",text:text,value:value,value2:value2,camera:camera)
    }
    @MainActor func testChangesAreAtomicUndoableAndPreserveAllTiming() throws {
        let before = project(),assistant = EditAssistant()
        let store = StudioStore(sessionDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),recoverSession:false);store.project = before
        let items = [suggestion(.direction,target:before.shots[0].id,text:"She lifts her eyes.",camera:"Locked camera"),suggestion(.caption,target:before.subtitles[0].id,text:"One small moment."),suggestion(.sound,target:before.sounds[0].id,value:0.8),suggestion(.camera,target:before.shots[1].id,value:1.08,value2:1),suggestion(.take,target:before.shots[0].id,source:before.assets[1].id.uuidString)]
        assistant.plan = EditPlan(summary:"A plan",suggestions:items);assistant.base = before;assistant.selected = Set(items.map(\.id))
        assistant.apply(store:store)
        XCTAssertEqual(store.undoStack.count,1)
        XCTAssertEqual(store.project.shots.map(\.duration),before.shots.map(\.duration))
        XCTAssertEqual(store.project.shots[0].speed,0.1904191616766467,accuracy:1e-12)
        XCTAssertEqual(store.project.subtitles.map(\.start),before.subtitles.map(\.start));XCTAssertEqual(store.project.subtitles.map(\.end),before.subtitles.map(\.end))
        XCTAssertEqual(store.project.sounds.map(\.start),before.sounds.map(\.start));XCTAssertEqual(store.project.sounds.map(\.duration),before.sounds.map(\.duration))
        XCTAssertEqual(store.project.subtitles[0].text,"One small moment.")
        store.undo();XCTAssertEqual(store.project,before)
        assistant.apply(store:store);XCTAssertEqual(store.project,before,"Undo makes the old plan stale; it must not be silently reapplied.")
    }
    @MainActor func testInvalidAndStaleProposalsLeaveTheEditUntouched() throws {
        let before = project(),assistant = EditAssistant()
        let store = StudioStore(sessionDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),recoverSession:false);store.project = before
        let valid = suggestion(.caption,target:before.subtitles[0].id,text:"Updated")
        let bad = suggestion(.sound,target:UUID(),value:0.8)
        assistant.plan = EditPlan(summary:"Bad plan",suggestions:[valid,bad]);assistant.base = before;assistant.selected = [valid.id,bad.id]
        assistant.apply(store:store);XCTAssertEqual(store.project,before);XCTAssertTrue(store.undoStack.isEmpty)
        store.project.name = "Changed"
        assistant.apply(store:store);XCTAssertEqual(store.project.name,"Changed");XCTAssertEqual(store.project.subtitles,before.subtitles)
        XCTAssertThrowsError(try suggestion(.camera,target:before.shots[0].id,value:0.5,value2:1).applying(to:&store.project))
    }
    @MainActor func testLocalModelDiscoveryAndStructuredPlanDoNotApplyEdits() async throws {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [AssistantProtocol.self]
        let assistant = EditAssistant(session:URLSession(configuration:config)),before = project()
        AssistantProtocol.truncated = false;AssistantProtocol.bodies = []
        AssistantProtocol.answer = String(decoding:try JSONEncoder().encode(EditPlan(summary:"Try a subtle ending.",suggestions:[suggestion(.camera,target:before.shots[1].id,value:1.08,value2:1)])),as:UTF8.self)
        let store = StudioStore(sessionDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),recoverSession:false);store.project = before
        await assistant.discover();XCTAssertEqual(assistant.models.map(\.name),["qwen2.5:14b"])
        assistant.ask(store:store)
        let deadline = Date().addingTimeInterval(8)
        while assistant.busy && Date() < deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotNil(assistant.plan,assistant.message);XCTAssertEqual(store.project,before);XCTAssertFalse(store.generation.referenceBusy)
        let body = try XCTUnwrap(AssistantProtocol.bodies.first)
        XCTAssertNotNil(body["format"] as? [String:Any]);XCTAssertEqual(body["keep_alive"] as? Int,0)
        XCTAssertFalse(String(describing:body).contains("/fixture.png"),"The local prompt needs media IDs and metadata, not filesystem paths.")
        AssistantProtocol.truncated = true;assistant.ask(store:store)
        while assistant.busy && Date() < deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNil(assistant.plan);XCTAssertEqual(store.project,before)
    }
    func testBlenderUsesFixedSceneAndExactFrameCounts() throws {
        XCTAssertEqual(try BlenderAssist.frames(duration:334.0/24,fps:24),334)
        XCTAssertThrowsError(try BlenderAssist.frames(duration:.nan,fps:24))
        XCTAssertThrowsError(try BlenderAssist.frames(duration:61,fps:24))
        let before = project();var copy = before
        try suggestion(.blender,target:before.shots[0].id,source:before.assets[0].id.uuidString,camera:"Slow pullback").applying(to:&copy)
        XCTAssertEqual(copy,before,"Planning a Blender render must not modify the timeline.")
        XCTAssertThrowsError(try suggestion(.blender,target:before.shots[0].id,camera:"exec user code").applying(to:&copy))
    }
    @MainActor func testGenerationSchemaConstrainsEachActionToRealProjectTargets() throws {
        let before = project(),schema = EditAssistant.schema(project:before)
        let properties = try XCTUnwrap(schema["properties"] as? [String:Any])
        let list = try XCTUnwrap(properties["suggestions"] as? [String:Any])
        let item = try XCTUnwrap(list["items"] as? [String:Any])
        let variants = try XCTUnwrap(item["oneOf"] as? [[String:Any]])
        for variant in variants {
            let fields = try XCTUnwrap(variant["properties"] as? [String:[String:Any]])
            let kind = try XCTUnwrap((fields["kind"]?["enum"] as? [String])?.first)
            let targets = try XCTUnwrap(fields["target"]?["enum"] as? [String])
            if kind == "caption" {XCTAssertEqual(targets,before.subtitles.map {$0.id.uuidString})}
            else if kind == "sound" {XCTAssertEqual(targets,before.sounds.map {$0.id.uuidString})}
            else if kind == "note" {XCTAssertEqual(targets,[""])}
            else {XCTAssertEqual(targets,before.shots.map {$0.id.uuidString})}
            if kind == "blender" {XCTAssertEqual(fields["source"]?["enum"] as? [String],["",before.assets[0].id.uuidString])}
        }
    }
    @MainActor func testInstalledBlenderProducesAPackedSceneAndPlayableTake() async throws {
        guard let executable = ProcessInfo.processInfo.environment["STILLROOM_TEST_BLENDER"],let reference = ProcessInfo.processInfo.environment["STILLROOM_TEST_BLENDER_IMAGE"],let destination = ProcessInfo.processInfo.environment["STILLROOM_TEST_BLENDER_OUTPUT"] else {throw XCTSkip("Opt-in installed Blender integration test.")}
        let root = URL(fileURLWithPath:destination)
        let media = try await MediaEngine.inspect(URL(fileURLWithPath:reference))
        let store = StudioStore(sessionDirectory:root.appendingPathComponent("Session"),recoverSession:false)
        store.project = FilmProject(assets:[media],shots:[Shot(assetID:media.id,name:"A missing memory",sourceDuration:2)])
        let before = store.project
        let blender = BlenderAssist(executable:executable,directory:root.appendingPathComponent("Renders"))
        blender.render(suggestion(.blender,target:before.shots[0].id,source:media.id.uuidString,camera:"Slow pullback"),store:store)
        let deadline = Date().addingTimeInterval(360)
        while blender.busy && Date() < deadline {try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertFalse(blender.busy)
        let result = try XCTUnwrap(store.project.assets.first {$0.id == blender.candidateID},blender.message)
        XCTAssertEqual(result.duration,2,accuracy:1.0/24);XCTAssertEqual(result.width,960);XCTAssertEqual(result.height,540)
        XCTAssertEqual(store.project.shots,before.shots);XCTAssertEqual(store.project.subtitles,before.subtitles);XCTAssertEqual(store.project.sounds,before.sounds)
        let scene = try XCTUnwrap(store.project.assets.first {$0.id == blender.projectID})
        XCTAssertTrue(FileManager.default.fileExists(atPath:scene.path))
        let motion = try await MotionSample.read(URL(fileURLWithPath:result.path))
        XCTAssertGreaterThan(motion.meanDifference,0.5)
        let tags = try await VideoColor.tags(of:URL(fileURLWithPath:result.path));XCTAssertEqual(tags["matrix"],"ITU_R_709_2")
        print("BLENDER_INTEGRATION_MOVIE=\(result.path)")
        print("BLENDER_INTEGRATION_SCENE=\(scene.path)")
    }
}
