import XCTest
import AVFoundation
import Vision
@testable import Stillroom

final class ProjectTests:XCTestCase {
    func fixture()->(FilmProject,UUID) {
        let media = MediaAsset(name:"A",path:"/tmp/a.mp4",kind:.video,duration:12)
        var p = FilmProject();p.assets = [media]
        p.shots = [Shot(assetID:media.id,name:"A",sourceIn:1,sourceDuration:10,speed:1.25,zoomStart:1.12,zoomEnd:1)]
        return (p,p.shots[0].id)
    }
    func testSplitPreservesDurationSourceAndCamera() {
        var (p,id) = fixture();let old = p.shots[0]
        XCTAssertTrue(p.split(shotID:id,at:3))
        XCTAssertEqual(p.duration,8,accuracy:0.00001)
        XCTAssertEqual(p.shots[1].sourceIn,4.75,accuracy:0.00001)
        XCTAssertEqual(p.shots[0].sourceDuration+p.shots[1].sourceDuration,old.sourceDuration)
        XCTAssertEqual(p.shots[0].zoomEnd,p.shots[1].zoomStart)
        XCTAssertEqual(p.shots[1].zoomEnd,1)
    }
    func testBoundarySplitDoesNotCreateEmptyShot() {
        var (p,id) = fixture()
        XCTAssertFalse(p.split(shotID:id,at:0));XCTAssertFalse(p.split(shotID:id,at:8));XCTAssertEqual(p.shots.count,1)
    }
    func testReorderUsesDestinationAfterRemoval() {
        var (p,_) = fixture();let a = p.shots[0]
        var b = a;b.id = UUID();b.name = "B"
        var c = a;c.id = UUID();c.name = "C"
        p.shots = [a,b,c];p.moveShot(a.id,before:c.id)
        XCTAssertEqual(p.shots.map(\.name),["B","A","C"])
    }
    func testProjectRoundTripPreservesNotesAndCaptions() throws {
        var (p,_) = fixture();p.subtitles = [Subtitle(start:1,end:3,text:"Memory is not evidence.")]
        p.assets[0].prompt = "Preserve the face.";p.assets[0].notes = "Reject a flash."
        let decoded = try JSONDecoder().decode(FilmProject.self,from:JSONEncoder().encode(p))
        XCTAssertEqual(decoded,p);try decoded.validated()
    }
    func testRejectsInvalidTimingAndMissingReferences() {
        var (p,_) = fixture();p.shots[0].speed = 0;XCTAssertThrowsError(try p.validated())
        p.shots[0].speed = 1;p.assets = [];XCTAssertThrowsError(try p.validated())
    }
    func testSRTRoundTripAndMalformedInput() {
        let text = "1\r\n00:00:01,250 --> 00:00:03,600\r\nFirst line\r\nSecond line\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nA garden.\r\n"
        let cues = SRT.parse(text);XCTAssertEqual(cues.count,2);XCTAssertEqual(cues[0].start,1.25);XCTAssertEqual(cues[0].text,"First line\nSecond line")
        let reloaded = SRT.parse(SRT.write(cues));XCTAssertEqual(reloaded.map(\.text),cues.map(\.text));XCTAssertEqual(reloaded.map(\.end),cues.map(\.end))
        XCTAssertEqual(SRT.parse("bad\n00:00:05,000 --> 00:00:01,000\nBackward").count,0)
        XCTAssertNil(SRT.seconds("00:99:12,000"))
    }
    func testPortableRelativeAssetResolution() {
        let a = MediaAsset(name:"Plate",path:"Media/plate.png",kind:.image)
        XCTAssertEqual(a.url(relativeTo:URL(fileURLWithPath:"/tmp/test.stillroom")).path,"/tmp/test.stillroom/Media/plate.png")
    }
    func testActualDemoAndNativeExport() async throws {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo")
        let root = FileManager.default.fileExists(atPath:local.appendingPathComponent("Media").path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo")
        var p = try JSONDecoder().decode(FilmProject.self,from:Data(contentsOf:root.appendingPathComponent("project.json")))
        try p.validated();XCTAssertEqual(p.shots.count,12);XCTAssertEqual(p.subtitles.count,27)
        XCTAssertEqual(p.duration,3631.0/24,accuracy:0.001)
        // Exercise a still, a real Blender shot, native AI video, a speed change, a camera ramp, audio, and burnt captions.
        let image = p.shots[0], blender = p.shots[1], motion = p.shots[2]
        p.shots = [image,blender,motion]
        for i in p.shots.indices {p.shots[i].sourceDuration = 1;p.shots[i].speed = i == 2 ? 1.25 : 1;p.shots[i].zoomStart = 1.12;p.shots[i].zoomEnd = 1}
        p.subtitles = [Subtitle(start:0.2,end:1.6,text:"An editable memory.")]
        p.sounds = Array(p.sounds.prefix(2))
        let film = try await MediaEngine.build(p,root:root,forExport:true)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-native-export-test-\(UUID().uuidString).mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset:film.composition,presetName:AVAssetExportPresetHighestQuality))
        session.outputURL = dest;session.outputFileType = .mp4;session.videoComposition = film.video;session.audioMix = film.audio
        await session.export()
        XCTAssertEqual(session.status,.completed,session.error?.localizedDescription ?? "")
        if session.status == .completed {
            let asset = AVURLAsset(url:dest);let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration,2.8,accuracy:0.05)
            let video = try await asset.loadTracks(withMediaType:.video);let audio = try await asset.loadTracks(withMediaType:.audio)
            XCTAssertEqual(video.count,1);XCTAssertEqual(audio.count,1)
            let generator = AVAssetImageGenerator(asset:asset)
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
            XCTAssertEqual(image.width,1920);XCTAssertEqual(image.height,1080)
            let request = VNRecognizeTextRequest();request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage:image).perform([request])
            let text = (request.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined(separator:" ")
            XCTAssertTrue(text.localizedCaseInsensitiveContains("editable memory"),"The subtitle must be visible in the encoded pixels: \(text)")
            let after = try await generator.image(at:CMTime(seconds:2.3,preferredTimescale:600)).image
            let afterRequest = VNRecognizeTextRequest();afterRequest.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage:after).perform([afterRequest])
            XCTAssertFalse((afterRequest.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined().contains("editable memory"))
            print("NATIVE_EXPORT_TEST_FILE=\(dest.path)")
        }
    }
}
