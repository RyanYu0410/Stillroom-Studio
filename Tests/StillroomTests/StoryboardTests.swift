import XCTest
import AppKit
import AVFoundation
import Vision
@testable import Stillroom

final class StoryboardTests:XCTestCase {
    func fixture()->FilmProject {
        let frame = MediaAsset(name:"Miso",path:"/frame.png",kind:.image)
        var board = Storyboard();board.title = "Seven Days Faster";board.premise = "A cat’s movement speed doubles daily for seven days."
        var first = StoryboardCard();first.title = "An ordinary morning";first.duration = 4;first.frameAssetID = frame.id;first.narration = "This is Miso.\nToday is ordinary.";first.indicator = "Day 0 · 1×"
        var last = StoryboardCard();last.title = "Still your cat";last.duration = 6;last.frameAssetID = frame.id;last.narration = "She can still choose to stop.";last.indicator = "Day 7 · 128×"
        board.cards = [first,last];board.referenceAssetID = frame.id
        return FilmProject(assets:[frame],storyboard:board)
    }
    func testOldProjectDecodesAndBoardSurvivesPortableJSONRoundTrip() throws {
        let old = Data(#"{"version":1,"name":"Old","brief":"","width":1920,"height":1080,"fps":24,"assets":[],"shots":[],"sounds":[],"subtitles":[],"captionsEnabled":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FilmProject.self,from:old).storyboard)
        let before = fixture(),after = try JSONDecoder().decode(FilmProject.self,from:JSONEncoder().encode(before))
        XCTAssertEqual(after,before);XCTAssertEqual(after.storyboard?.referenceAssetID,after.assets[0].id)
    }
    func testAssemblyCreatesLinkedShotsIndicatorsAndOrderedCaptionCues() throws {
        var project = fixture();try project.assembleStoryboard()
        XCTAssertEqual(project.name,"Seven Days Faster");XCTAssertEqual(project.duration,10)
        XCTAssertEqual(project.shots.map(\.id),project.storyboard?.cards.map(\.id))
        XCTAssertEqual(project.shots.map(\.indicator),["Day 0 · 1×","Day 7 · 128×"])
        XCTAssertEqual(project.subtitles.map(\.text),["This is Miso.","Today is ordinary.","She can still choose to stop."])
        XCTAssertEqual(project.subtitles[0].start,0);XCTAssertEqual(project.subtitles[1].end,4);XCTAssertEqual(project.subtitles[2].start,4);XCTAssertEqual(project.subtitles[2].end,10)
        try project.validated()
    }
    func testOpeningPoseIsBackwardCompatibleAndDoesNotReplaceMotionDirection() throws {
        let legacy = try JSONDecoder().decode(StoryboardCard.self,from:Data(#"{"title":"Cat","action":"Miso runs across the room."}"#.utf8))
        XCTAssertEqual(legacy.openingFrame,"")
        var card = legacy;card.openingFrame = "Miso crouches at the left edge."
        let board = Storyboard()
        XCTAssertTrue(board.framePrompt(for:card,hasReference:true).contains(card.openingFrame))
        XCTAssertFalse(board.framePrompt(for:card,hasReference:true).contains(card.action))
        XCTAssertEqual(board.direction(for:card).referenceDirection,card.action)
        XCTAssertEqual(try JSONDecoder().decode(StoryboardCard.self,from:JSONEncoder().encode(card)),card)
    }
    func testMissingFramesAndUnrelatedEditsAreRejectedAtomically() throws {
        var p = fixture();p.storyboard?.cards[1].frameAssetID = nil
        let before = p;XCTAssertThrowsError(try p.assembleStoryboard());XCTAssertEqual(p,before)
        p = fixture();p.shots = [Shot(assetID:p.assets[0].id,name:"Existing independent edit")]
        let edit = p;XCTAssertThrowsError(try p.assembleStoryboard());XCTAssertEqual(p,edit)
        p = fixture();p.sounds = [SoundLayer(assetID:p.assets[0].id,name:"Existing mix",duration:5)]
        let mix = p;XCTAssertThrowsError(try p.assembleStoryboard());XCTAssertEqual(p,mix)
    }
    func testReorderedBoardUsesFrameAlignedDurationsAndFittedTakes() throws {
        var p = fixture();let take = MediaAsset(name:"Motion",path:"/take.mp4",kind:.video,duration:5)
        p.assets.append(take);p.storyboard?.cards[0].takeAssetID = take.id;p.storyboard?.cards[0].duration = 8.333
        p.storyboard?.cards.swapAt(0,1);try p.assembleStoryboard()
        XCTAssertEqual(p.shots[0].name,"Still your cat");XCTAssertEqual(p.shots[1].duration,200.0/24,accuracy:1e-9)
        XCTAssertEqual(p.shots[1].speed,0.6,accuracy:1e-9)
        XCTAssertEqual(try XCTUnwrap(p.subtitles.last?.end),p.duration,accuracy:1e-9)
    }
    @MainActor func testNewFrameUsesTextGenerationThenAnchorsLaterFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let c = CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:VideoColor.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red:0.8,green:0.4,blue:0.2,alpha:1));c.fill(CGRect(x:0,y:0,width:64,height:64))
        ReferenceProtocol.png = try VideoColor.referencePNG(c.makeImage()!);ReferenceProtocol.loaded = false;ReferenceProtocol.fail = false;ReferenceProtocol.movieBusy = false;ReferenceProtocol.paths = []
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReferenceProtocol.self];let session = URLSession(configuration:config)
        let store = StudioStore(sessionDirectory:root.appendingPathComponent("Session"),recoverSession:false)
        store.project = fixture();store.project.assets = [];store.project.storyboard?.referenceAssetID = nil;store.project.storyboard?.cards[0].frameAssetID = nil
        let beforeShots = store.project.shots
        let images = LocalReference(session:session,outputDirectory:root.appendingPathComponent("Frames"))
        let cardID = store.project.storyboard!.cards[0].id
        images.createStoryboardFrame(cardID:cardID,store:store)
        var deadline = Date().addingTimeInterval(8)
        while images.busy && Date() < deadline {try await Task.sleep(nanoseconds:10_000_000)}
        let id = try XCTUnwrap(images.candidateID,images.message)
        XCTAssertNil(ReferenceProtocol.body["image"]);XCTAssertEqual(store.project.storyboard?.referenceAssetID,id);XCTAssertEqual(store.project.storyboard?.cards[0].frameAssetID,id);XCTAssertEqual(store.project.shots,beforeShots)
        XCTAssertNil(store.project.assets.last?.referenceRecipe?.sourceAssetID)
        images.createStoryboardFrame(cardID:store.project.storyboard!.cards[1].id,store:store)
        deadline = Date().addingTimeInterval(8)
        while images.busy && Date() < deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotNil(ReferenceProtocol.body["image"]);XCTAssertEqual(ReferenceProtocol.body["mode"] as? String,"edit")
        XCTAssertEqual(store.project.assets.last?.referenceRecipe?.sourceAssetID,id)
        XCTAssertFalse(store.generation.referenceBusy)
    }
    @MainActor func testLocalDraftRequiresReviewAndDoesNotReplaceExistingCards() async throws {
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [AssistantProtocol.self]
        let assistant = EditAssistant(session:URLSession(configuration:configuration));await assistant.discover()
        // Exercise the actual draft reply transport and schema, leaving adoption to the UI.
        AssistantProtocol.truncated = false
        let board = fixture().storyboard!
        struct Response:Encodable {let title:String;let cards:[StoryboardCard]}
        AssistantProtocol.answer = String(decoding:try JSONEncoder().encode(Response(title:board.title,cards:board.cards)),as:UTF8.self)
        let reply = try await assistant.structuredReply(system:"Draft a film",user:board.premise,schema:StoryboardPlanner.schema(count:2),model:assistant.models[0])
        XCTAssertTrue(reply.contains("Seven Days Faster"));XCTAssertEqual(board.cards.count,2)
        let body = try XCTUnwrap(AssistantProtocol.bodies.last);XCTAssertNotNil(body["format"] as? [String:Any])
    }
    @MainActor func testIndicatorIsActuallyExportedWhenSubtitlesAreDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source = root.appendingPathComponent("Source.mp4"),output = root.appendingPathComponent("Export.mp4")
        try await MediaEngine.writeFrames(to:source,width:1280,height:720,fps:24,count:24) {_,context in context.setFillColor(CGColor(gray:0.4,alpha:1));context.fill(CGRect(x:0,y:0,width:1280,height:720))}
        let media = try await MediaEngine.inspect(source)
        var p = FilmProject(assets:[media],shots:[Shot(assetID:media.id,name:"Day seven",sourceDuration:1,indicator:"DAY 7 · 128×")],captionsEnabled:false)
        p.width = 1280;p.height = 720
        let film = try await MediaEngine.build(p,root:nil,forExport:true)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset:film.composition,presetName:AVAssetExportPresetHighestQuality));exporter.outputURL = output;exporter.outputFileType = .mp4;exporter.videoComposition = film.video
        await exporter.export();XCTAssertEqual(exporter.status,.completed,exporter.error?.localizedDescription ?? "")
        let image = try await AVAssetImageGenerator(asset:AVURLAsset(url:output)).image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
        let request = VNRecognizeTextRequest();request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage:image).perform([request])
        let text = (request.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined(separator:" ")
        XCTAssertTrue(text.contains("128"),"The day/speed indicator must be present in exported picture pixels: \(text)")
    }
}
