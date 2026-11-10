import XCTest
import AVFoundation
@testable import Stillroom

final class TakePlaybackTests:XCTestCase {
    @MainActor func testPreviewActuallyPlaysAtNormalSpeedAndCanReplayAfterEnd() async throws {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo/Media/03-native.mp4")
        let file = FileManager.default.fileExists(atPath:local.path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo/Media/03-native.mp4")
        let take = try await MediaEngine.inspect(file)
        let store = StudioStore(sessionDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),recoverSession:false)
        store.project.assets = [take]
        let before = store.project
        store.previewTake(take)
        let deadline = Date().addingTimeInterval(5)
        while store.player.currentTime().seconds < 0.2 && Date() < deadline {try await Task.sleep(nanoseconds:30_000_000)}
        XCTAssertGreaterThan(store.player.currentTime().seconds,0.1,"Preview must advance through the video, not display a paused frame.")
        XCTAssertEqual(store.player.rate,1);XCTAssertTrue(store.sourcePreview)
        XCTAssertEqual(store.project,before)
        store.player.pause();store.playing = false
        await store.player.seek(to:CMTime(seconds:take.duration,preferredTimescale:600))
        store.time = take.duration
        store.togglePlay()
        try await Task.sleep(nanoseconds:250_000_000)
        XCTAssertLessThan(store.player.currentTime().seconds,1,"Play after the end restarts the source preview.")
        store.player.pause()
    }
}
