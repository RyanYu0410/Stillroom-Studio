import Foundation

enum MediaKind: String, Codable, CaseIterable {
    case video, image, audio, blender
    var symbol: String {
        switch self { case .video: return "film"; case .image: return "photo"; case .audio: return "waveform"; case .blender: return "cube.transparent" }
    }
}

struct MediaAsset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var kind: MediaKind
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var origin: String = "Imported"
    var prompt: String = ""
    var review: String = "Unreviewed"
    var notes: String = ""
    var parentAssetID: UUID? = nil
    var referenceAssetID: UUID? = nil
    var regenerationDraft: String? = nil
    var recipe: GenerationRecipe? = nil
    var direction:ShotDirection? = nil
    var takeReview:TakeReview? = nil
    var motionEvidence:MotionEvidence? = nil
    var referenceRecipe:ReferenceRecipe? = nil
    func url(relativeTo root: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (root ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
    }
}

struct GenerationRecipe: Codable, Equatable {
    var backend: String
    var model: String
    var seed: Int
    var frames: Int
    var width: Int
    var height: Int
    var steps: Int
    var instructions: String
    var originalPrompt: String
    var referenceTime: Double
    var workflow: String? = nil
    var requestedDuration: Double? = nil
    var colorHandling: String? = nil
    var direction:ShotDirection? = nil
}

enum RegenerationDirection {
    static func prompt(change:String)->String {
        // The image carries appearance. Repeating an older prompt can bring back
        // locked-camera and micro-movement instructions that contradict this take.
        return """
        One continuous cinematic video, starting from the supplied original image.
        Action and camera direction: \(change.trimmingCharacters(in:.whitespacesAndNewlines))
        The reference image establishes the starting subject, appearance, setting and lighting. Keep the subject recognizable and the scene coherent as the requested action unfolds. Preserve the reference’s visual style. Show continuous physical movement and natural transitions throughout the take.
        """
    }
}

struct Shot: Identifiable, Codable, Equatable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var sourceIn: Double = 0
    var sourceDuration: Double = 5
    var speed: Double = 1
    var zoomStart: Double = 1
    var zoomEnd: Double = 1
    var volume: Double = 0
    var note: String = ""
    var indicator:String? = nil
    var duration: Double { sourceDuration / max(0.1, speed) }
}

struct SoundLayer: Identifiable, Codable, Equatable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var start: Double = 0
    var sourceIn: Double = 0
    var duration: Double = 0
    var volume: Double = 1
    var muted: Bool = false
}

struct Subtitle: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct FilmProject: Codable, Equatable {
    var version: Int = 1
    var name: String = "Untitled film"
    var brief: String = "What changes for the person in this scene?"
    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 24
    var assets: [MediaAsset] = []
    var shots: [Shot] = []
    var sounds: [SoundLayer] = []
    var subtitles: [Subtitle] = []
    var captionsEnabled: Bool = true
    var storyboard:Storyboard? = nil
    var duration: Double { shots.reduce(0) { $0 + $1.duration } }
    func start(of shot: Shot) -> Double {
        shots.prefix(while: { $0.id != shot.id }).reduce(0) { $0 + $1.duration }
    }
    func shot(at seconds: Double) -> Shot? {
        var at = 0.0
        for shot in shots {
            if seconds >= at && seconds < at + shot.duration { return shot }
            at += shot.duration
        }
        return shots.last
    }
    func familyRoot(of asset: MediaAsset) -> UUID {
        var item = asset
        var seen: Set<UUID> = []
        while let parent = item.parentAssetID, let next = assets.first(where:{$0.id == parent}), !seen.contains(parent) {
            seen.insert(item.id);item = next
        }
        return item.id
    }
    func takes(for asset: MediaAsset) -> [MediaAsset] {
        let root = familyRoot(of:asset)
        return assets.filter { $0.kind == .video && $0.parentAssetID != nil && familyRoot(of:$0) == root }
    }
    mutating func useTake(_ assetID: UUID, for shotID: UUID, keepTiming:Bool = true,sourceIn:Double = 0,sourceOut:Double? = nil) throws {
        guard let i = shots.firstIndex(where:{$0.id == shotID}), let media = assets.first(where:{$0.id == assetID}), [.image,.video].contains(media.kind) else {throw StudioError.message("Select a picture source and a timeline shot.")}
        if media.kind == .image {
            let duration = shots[i].duration
            shots[i].assetID = assetID;shots[i].sourceIn = 0;shots[i].sourceDuration = duration;shots[i].speed = 1
            return
        }
        let end = sourceOut ?? media.duration
        guard sourceIn.isFinite,end.isFinite,sourceIn >= 0,end <= media.duration + 0.001,end-sourceIn >= 1.0/Double(fps) else {throw StudioError.message("Choose a valid in/out range within this take.")}
        let selectedDuration = min(end,media.duration)-sourceIn
        let rate = keepTiming ? selectedDuration / shots[i].duration : 1
        guard media.duration.isFinite, media.duration > 0, rate >= 0.1, rate <= 4 else {throw StudioError.message("This take cannot fill the shot at a supported speed. Generate a longer take or shorten the shot first.")}
        shots[i].assetID = assetID
        shots[i].sourceIn = sourceIn
        shots[i].sourceDuration = selectedDuration
        shots[i].speed = rate
    }
    mutating func split(shotID: UUID, at seconds: Double) -> Bool {
        guard let i = shots.firstIndex(where: { $0.id == shotID }) else { return false }
        let original = shots[i]
        let local = seconds - start(of: original)
        guard local >= 1.0 / Double(fps), original.duration - local >= 1.0 / Double(fps) else { return false }
        let fraction = local / original.duration
        let zoom = original.zoomStart + (original.zoomEnd - original.zoomStart) * fraction
        var left = original
        left.sourceDuration = local * original.speed
        left.zoomEnd = zoom
        var right = original
        right.id = UUID()
        right.name += " · B"
        right.sourceIn += left.sourceDuration
        right.sourceDuration -= left.sourceDuration
        right.zoomStart = zoom
        shots.replaceSubrange(i...i, with: [left, right])
        return true
    }
    mutating func moveShot(_ id: UUID, before target: UUID) {
        guard id != target, let from = shots.firstIndex(where: { $0.id == id }) else { return }
        let item = shots.remove(at: from)
        let to = shots.firstIndex(where: { $0.id == target }) ?? shots.endIndex
        shots.insert(item, at: to)
    }
    func validated() throws {
        try storyboard?.validated()
        guard version == 1, [24,25,30,60].contains(fps), width >= 320, height >= 240, width <= 4096, height <= 4096 else { throw StudioError.message("Unsupported project format or canvas.") }
        let ids = Set(assets.map(\.id))
        guard ids.count == assets.count, Set(shots.map(\.id)).count == shots.count,
              Set(sounds.map(\.id)).count == sounds.count, Set(subtitles.map(\.id)).count == subtitles.count else { throw StudioError.message("The project contains duplicate identifiers.") }
        for s in shots {
            guard ids.contains(s.assetID), let a = assets.first(where: {$0.id == s.assetID}), [.image,.video].contains(a.kind),
                  [s.sourceIn,s.sourceDuration,s.speed,s.zoomStart,s.zoomEnd,s.volume].allSatisfy(\.isFinite),
                  s.sourceIn >= 0, s.sourceDuration > 0, s.speed >= 0.1, s.speed <= 4,
                  s.zoomStart >= 1, s.zoomEnd >= 1, s.zoomStart <= 2, s.zoomEnd <= 2,
                  s.volume >= 0, s.volume <= 2,(s.indicator?.count ?? 0) <= 100 else { throw StudioError.message("A shot has invalid media or timing.") }
        }
        for s in sounds {
            guard ids.contains(s.assetID), [s.start,s.sourceIn,s.duration,s.volume].allSatisfy(\.isFinite), s.start >= 0, s.sourceIn >= 0, s.duration > 0, s.volume >= 0, s.volume <= 2 else { throw StudioError.message("A sound layer has invalid timing.") }
        }
        for c in subtitles {
            guard c.start.isFinite, c.end.isFinite, c.start >= 0, c.end > c.start else { throw StudioError.message("A caption has an invalid time range.") }
        }
    }
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum SRT {
    static func parse(_ source: String) -> [Subtitle] {
        let clean = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return clean.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]), end > start else { return nil }
            let text = lines.dropFirst(index+1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Subtitle(start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }
    static func seconds(_ text: String) -> Double? {
        let tokens = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).first ?? ""
        let parts = tokens.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy(\.isFinite), parts[0] >= 0, parts[1] >= 0, parts[1] < 60, parts[2] >= 0, parts[2] < 60 else { return nil }
        return parts[0]*3600 + parts[1]*60 + parts[2]
    }
    static func stamp(_ seconds: Double) -> String {
        let n = max(0, Int((seconds*1000).rounded()))
        return String(format:"%02d:%02d:%02d,%03d", n/3600000, (n/60000)%60, (n/1000)%60, n%1000)
    }
    static func write(_ cues: [Subtitle]) -> String {
        cues.sorted { $0.start < $1.start }.enumerated().map { "\($0.offset+1)\n\(stamp($0.element.start)) --> \(stamp($0.element.end))\n\($0.element.text)" }.joined(separator:"\n\n") + "\n"
    }
}

func timecode(_ seconds: Double, fps: Int = 24) -> String {
    let total = max(0, Int((seconds * Double(fps)).rounded()))
    return String(format:"%02d:%02d:%02d:%02d",total/(fps*3600),(total/(fps*60))%60,(total/fps)%60,total%fps)
}
