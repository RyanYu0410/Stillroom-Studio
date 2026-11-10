import XCTest
@testable import Stillroom

final class ShotCraftTests:XCTestCase {
    func testDirectionKeepsActionAndCameraWithoutRepeatingTheStaticImageBrief() {
        var plan = ShotDirection()
        plan.camera = "Slow pullback";plan.light = "Warm practical light"
        plan.continuity = "The laptop stays flat on the table."
        plan.purpose = "She questions whether the memory is true."
        plan.sound = "Rain and a page turning."
        let prompt = plan.motionPrompt(action:"She raises her eyes toward the window.")
        XCTAssertTrue(prompt.contains("She raises her eyes toward the window."))
        XCTAssertTrue(prompt.contains("moves smoothly backward from the opening frame"))
        XCTAssertFalse(prompt.contains("laptop stays flat"))
        XCTAssertTrue(plan.imagePrompt().contains("laptop stays flat"))
        XCTAssertTrue(prompt.contains("warm practical light"))
        XCTAssertFalse(prompt.contains(plan.sound));XCTAssertFalse(prompt.contains(plan.purpose))
        XCTAssertFalse(prompt.contains("locked camera"))
    }
    func testDefaultDirectionDoesNotReintroduceStillnessOrForceAReferenceComposition() {
        let plan = ShotDirection(),action = "She turns and the camera moves with her."
        XCTAssertEqual(plan.motionPrompt(action:action),RegenerationDirection.prompt(change:action))
        XCTAssertFalse(plan.motionPrompt(action:action).contains("stationary"))
    }
    func testSelectedRangeChangesOnlyChosenSourceRangeAndPreservesEditWhenFitted() throws {
        let original = MediaAsset(name:"Original",path:"a.mp4",kind:.video,duration:12)
        let take = MediaAsset(name:"Take",path:"b.mp4",kind:.video,duration:8)
        var p = FilmProject();p.assets = [original,take];p.shots = [Shot(assetID:original.id,name:"Shot",sourceDuration:12)]
        p.subtitles = [Subtitle(start:2,end:4,text:"A fixed cue")]
        let before = p
        try p.useTake(take.id,for:p.shots[0].id,sourceIn:1,sourceOut:7)
        XCTAssertEqual(p.shots[0].sourceIn,1);XCTAssertEqual(p.shots[0].sourceDuration,6)
        XCTAssertEqual(p.shots[0].speed,0.5);XCTAssertEqual(p.duration,before.duration)
        XCTAssertEqual(p.subtitles,before.subtitles);XCTAssertEqual(p.assets,before.assets)
        try p.useTake(take.id,for:p.shots[0].id,keepTiming:false,sourceIn:2,sourceOut:5)
        XCTAssertEqual(p.shots[0].sourceIn,2);XCTAssertEqual(p.shots[0].duration,3);XCTAssertEqual(p.shots[0].speed,1)
        let selected = p
        for range in [(Double.nan,3.0),(-1,2),(0,10),(3,3),(4,2)] {
            XCTAssertThrowsError(try p.useTake(take.id,for:p.shots[0].id,sourceIn:range.0,sourceOut:range.1))
            XCTAssertEqual(p,selected)
        }
    }
    func testSampledMotionIsDescriptiveAndReadsNativeFrames() async throws {
        XCTAssertEqual(MotionSample.difference([[1,2],[1,2]]),0)
        XCTAssertEqual(MotionSample.difference([[0,0],[10,10],[20,20]]),10)
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo/Media/03-native.mp4")
        let file = FileManager.default.fileExists(atPath:local.path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo/Media/03-native.mp4")
        let report = try await MotionSample.read(file)
        XCTAssertEqual(report.frames.count,9);XCTAssertGreaterThan(report.meanDifference,0)
        XCTAssertEqual(report.frames.map(\.seconds),report.frames.map(\.seconds).sorted())
        XCTAssertNotEqual(report.frames[0].seconds,report.frames[8].seconds)
    }
    func testDirectionReviewAndReferenceProvenanceRoundTrip() throws {
        var asset = MediaAsset(name:"Take",path:"a.mp4",kind:.video,duration:4)
        asset.direction = ShotDirection(purpose:"A decision",camera:"Slow pullback",continuity:"Same room",sound:"Rain")
        asset.takeReview = TakeReview(sourceIn:0.5,sourceOut:3,faces:true,props:true,note:"Use the middle")
        asset.referenceRecipe = ReferenceRecipe(model:"local-image",seed:42,steps:12,prompt:"Frame",sourceAssetID:UUID())
        XCTAssertEqual(try JSONDecoder().decode(MediaAsset.self,from:JSONEncoder().encode(asset)),asset)
    }
}
