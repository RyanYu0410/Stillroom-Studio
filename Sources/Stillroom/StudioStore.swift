import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class StudioStore: ObservableObject {
    @Published var project = FilmProject()
    @Published var selectedShot: UUID?
    @Published var selectedAsset: UUID?
    @Published var selectedSound: UUID?
    @Published var thumbnails: [UUID:NSImage] = [:]
    @Published var waveforms: [UUID:[Float]] = [:]
    @Published var time: Double = 0
    @Published var playing = false
    @Published var preparing = false
    @Published var exporting = false
    @Published var exportProgress: Float = 0
    @Published var status = "Ready"
    @Published var error: String?
    @Published var section = "Media"
    @Published var showLab = false
    @Published var showAssistant = false
    @Published var showStoryboard = false
    @Published var zoom: Double = 8
    @Published var sourcePreview = false
    @Published var dirty = false
    @Published var showInspector = true
    @Published var showLibrary = true
    @Published var showTimeline = true
    @Published var previewingTakeID: UUID?
    var documentID = UUID()
    let generation = LocalGeneration()
    let assistant = EditAssistant()
    let blender = BlenderAssist()
    let player = AVPlayer()
    var projectURL: URL?
    var root: URL?
    var undoStack: [FilmProject] = []
    var redoStack: [FilmProject] = []
    private var observer: Any?
    private var buildTask: Task<Void,Never>?
    private var exportSession: AVAssetExportSession?
    private var revision = 0
    private let autosave: URL

    init(sessionDirectory:URL? = nil,recoverSession:Bool = true) {
        let directory = sessionDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Stillroom")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        autosave = directory.appendingPathComponent("Session.json")
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:24),queue:.main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                self.playing = self.player.rate != 0
            }
        }
        NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.playing = false }
        }
        if recoverSession, let data = try? Data(contentsOf:autosave), let saved = try? JSONDecoder().decode(FilmProject.self,from:data), (try? saved.validated()) != nil {
            project = saved; status = "Recovered your last session"
        } else if recoverSession {loadDemo()}
        selectedShot = project.shots.first?.id
        refreshMedia(); scheduleBuild()
    }

    var shot: Shot? { project.shots.first {$0.id == selectedShot} }
    var asset: MediaAsset? {
        let id = selectedAsset ?? shot?.assetID
        return project.assets.first {$0.id == id}
    }
    var sound: SoundLayer? { project.sounds.first {$0.id == selectedSound} }
    var previewDuration:Double {project.assets.first {$0.id == previewingTakeID}?.duration ?? asset?.duration ?? 0}
    var activeCaption: String? {
        guard project.captionsEnabled, !sourcePreview else { return nil }
        return project.subtitles.first {time >= $0.start && time < $0.end}?.text
    }
    func url(_ asset: MediaAsset) -> URL { asset.url(relativeTo:root) }

    func change(_ action: (inout FilmProject)->Void, rebuild: Bool = true) {
        undoStack.append(project); if undoStack.count > 80 { undoStack.removeFirst() };redoStack = []
        action(&project);dirty = true; persist()
        if rebuild { scheduleBuild() }
    }
    func undo() {
        guard let old = undoStack.popLast() else { return }
        redoStack.append(project);project = old;dirty = true;persist();scheduleBuild()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project);project = next;dirty = true;persist();scheduleBuild()
    }
    func persist() {
        var copy = project
        for i in copy.assets.indices { copy.assets[i].path = url(copy.assets[i]).path }
        if let data = try? JSONEncoder().encode(copy) { try? data.write(to:autosave,options:.atomic) }
    }
    func updateShot(_ action: (inout Shot)->Void) {
        guard let id = selectedShot, let i = project.shots.firstIndex(where: {$0.id == id}) else { return }
        change { action(&$0.shots[i]) }
    }
    func updateAsset(_ action: (inout MediaAsset)->Void) {
        guard let id = asset?.id, let i = project.assets.firstIndex(where: {$0.id == id}) else { return }
        change({action(&$0.assets[i])},rebuild:false)
    }
    func updateSound(_ action: (inout SoundLayer)->Void) {
        guard let id = selectedSound, let i = project.sounds.firstIndex(where: {$0.id == id}) else { return }
        change {action(&$0.sounds[i])}
    }
    func selectShot(_ shot: Shot) {
        selectedShot = shot.id;selectedAsset = nil;selectedSound = nil
        previewingTakeID = nil
        if sourcePreview { sourcePreview = false; scheduleBuild() }
        seek(project.start(of:shot))
    }
    func seek(_ value: Double) {
        time = min(max(0,value),max(0,sourcePreview ? previewDuration : project.duration))
        player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
    }
    func togglePlay() {
        if playing { player.pause();playing = false }
        else {
            if time >= (sourcePreview ? previewDuration : project.duration)-0.1 {seek(0)}
            player.play();playing = true
        }
    }
    func scheduleBuild() {
        revision += 1;let rev = revision
        buildTask?.cancel()
        sourcePreview = false
        guard !project.shots.isEmpty else { player.pause();player.replaceCurrentItem(with:nil);time = 0;return }
        let project = project, root = root
        buildTask = Task {
            do {
                try await Task.sleep(nanoseconds:250_000_000)
                preparing = true
                let film = try await MediaEngine.build(project,root:root)
                try Task.checkCancellation()
                guard revision == rev else { return }
                let item = AVPlayerItem(asset:film.composition)
                item.videoComposition = film.video;item.audioMix = film.audio
                let cursor = min(time,max(0,project.duration-0.01))
                let resume = playing
                player.replaceCurrentItem(with:item)
                await player.seek(to:CMTime(seconds:cursor,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
                if resume {player.play()}
                preparing = false;status = "\(project.shots.count) shots · \(timecode(project.duration,fps:project.fps))"
            } catch is CancellationError {
                if revision == rev {preparing = false}
            } catch {
                if revision == rev {preparing = false;self.error = error.localizedDescription;status = "Media needs attention"}
            }
        }
    }
    func refreshMedia() {
        for media in project.assets {
            let url = url(media)
            Task {
                let image = await MediaEngine.thumbnail(url,kind:media.kind,at:media.kind == .video ? min(0.5,media.duration/2) : 0)
                if let image {thumbnails[media.id] = image}
                if media.kind == .audio && waveforms[media.id] == nil {waveforms[media.id] = await MediaEngine.waveform(url)}
            }
        }
    }
    func importPanel() {
        let panel = NSOpenPanel();panel.allowsMultipleSelection = true;panel.canChooseDirectories = false
        panel.message = "Choose videos, reference images, audio, or Blender files."
        panel.begin { [weak self] response in
            guard response == .OK else {return}
            Task {@MainActor in await self?.importURLs(panel.urls)}
        }
    }
    func importURLs(_ urls: [URL]) async {
        var imported: [MediaAsset] = []
        for url in urls {
            do {
                let media = try await MediaEngine.inspect(url)
                if !project.assets.contains(where:{self.url($0).standardizedFileURL == url.standardizedFileURL}) {imported.append(media)}
            } catch {self.error = error.localizedDescription}
        }
        if !imported.isEmpty {change({$0.assets += imported},rebuild:false);refreshMedia();status = "Imported \(imported.count) files"}
    }
    func append(_ media: MediaAsset) {
        if media.kind == .blender {NSWorkspace.shared.open(url(media));return}
        if media.kind == .audio {
            let sound = SoundLayer(assetID:media.id,name:media.name,start:time,duration:media.duration)
            change {$0.sounds.append(sound)};selectedSound = sound.id;selectedShot = nil;selectedAsset = media.id
        } else {
            let shot = Shot(assetID:media.id,name:media.name,sourceDuration:media.kind == .image ? 5 : media.duration)
            change {$0.shots.append(shot)};selectedShot = shot.id;selectedAsset = nil;selectedSound = nil
        }
    }
    func preview(_ media: MediaAsset) {
        selectedAsset = media.id;selectedShot = nil;selectedSound = nil
        player.pause();playing = false
        if media.kind == .video || media.kind == .audio {
            buildTask?.cancel();revision += 1;preparing = false;sourcePreview = true
            player.pause();player.replaceCurrentItem(with:AVPlayerItem(url:url(media)));time = 0;playing = false
        } else if media.kind == .blender {NSWorkspace.shared.open(url(media))}
    }
    func returnToEdit() {sourcePreview = false;previewingTakeID = nil;scheduleBuild()}
    func previewTake(_ media:MediaAsset) {
        guard [.image,.video].contains(media.kind) else {return}
        buildTask?.cancel();revision += 1;preparing = false;sourcePreview = true
        previewingTakeID = media.id
        player.pause();playing = false
        if media.kind == .video {
            player.replaceCurrentItem(with:AVPlayerItem(url:url(media)))
            player.playImmediately(atRate:1);playing = true
            status = "Playing take at 1× · " + media.name
        }
        time = 0
    }
    func useTake(_ media:MediaAsset,for shotID:UUID,keepTiming:Bool = true,sourceIn:Double = 0,sourceOut:Double? = nil) {
        do {
            var copy = project
            try copy.useTake(media.id,for:shotID,keepTiming:keepTiming,sourceIn:sourceIn,sourceOut:sourceOut)
            let at = copy.shots.first(where:{$0.id == shotID}).map {copy.start(of:$0)} ?? 0
            player.pause();playing = false;previewingTakeID = nil
            change {$0 = copy};selectedShot = shotID;selectedAsset = nil;selectedSound = nil;time = at
            status = keepTiming ? "Take applied · timing preserved · original kept in library" : "Take applied at its generated length · caption and sound positions unchanged"
        } catch {self.error = error.localizedDescription}
    }
    func split() {
        let id = selectedShot ?? project.shot(at:time)?.id
        guard let id else {return}
        var copy = project
        if copy.split(shotID:id,at:time) {change {$0 = copy};status = "Split at playhead"}
        else {status = "Place the playhead inside a shot to split"}
    }
    func removeSelected() {
        if let id = selectedShot {change {$0.shots.removeAll {$0.id == id}};selectedShot = nil}
        else if let id = selectedSound {change {$0.sounds.removeAll {$0.id == id}};selectedSound = nil}
    }
    func moveSelected(_ offset: Int) {
        guard let id = selectedShot, let i = project.shots.firstIndex(where:{$0.id == id}),project.shots.indices.contains(i+offset) else {return}
        change {$0.shots.swapAt(i,i+offset)}
    }
    func relink() {
        guard let media = asset else {return}
        let panel = NSOpenPanel();panel.message = "Choose the replacement for \(media.name)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {return}
            Task {@MainActor in
                guard let self else {return}
                do {
                    let replacement = try await MediaEngine.inspect(url)
                    guard replacement.kind == media.kind else {throw StudioError.message("Choose the same kind of media.")}
                    guard let i = self.project.assets.firstIndex(where:{$0.id == media.id}) else {return}
                    self.change {p in p.assets[i].path = url.path;p.assets[i].duration = replacement.duration;p.assets[i].width = replacement.width;p.assets[i].height = replacement.height}
                    self.waveforms[media.id] = nil;self.refreshMedia()
                } catch {self.error = error.localizedDescription}
            }
        }
    }
    func loadDemo() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Demo"), let data = try? Data(contentsOf:directory.appendingPathComponent("project.json")), let demo = try? JSONDecoder().decode(FilmProject.self,from:data) else {return}
        documentID = UUID();project = demo;root = directory;projectURL = nil;selectedShot = demo.shots.first?.id
        time = 0;dirty = false;status = "Example project · The Missing Moment"
    }
    func checkpoint() {
        guard dirty else {return}
        let folder = autosave.deletingLastPathComponent().appendingPathComponent("Recovery")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var copy = project
        for i in copy.assets.indices {copy.assets[i].path = url(copy.assets[i]).path}
        if let data = try? JSONEncoder().encode(copy) {try? data.write(to:folder.appendingPathComponent("Session-\(Int(Date().timeIntervalSince1970)).json"),options:.atomic)}
    }
    func showRecovery() {NSWorkspace.shared.open(autosave.deletingLastPathComponent().appendingPathComponent("Recovery"))}
    func resetDemo() {checkpoint();player.pause();playing = false;loadDemo();undoStack = [];redoStack = [];persist();refreshMedia();scheduleBuild()}
    func newProject() {
        checkpoint()
        documentID = UUID()
        project = FilmProject();root = nil;projectURL = nil;selectedShot = nil;selectedAsset = nil;selectedSound = nil
        undoStack = [];redoStack = [];time = 0;thumbnails = [:];persist();scheduleBuild();status = "New film · import your first reference"
    }
    func saveProject() {
        if let projectURL {Task {await writeProject(to:projectURL)};return}
        saveAs()
    }
    func saveAs() {
        let panel = NSSavePanel();panel.nameFieldStringValue = project.name + ".stillroom"
        panel.message = "A portable project includes copies of every linked source file."
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {return}
            Task {@MainActor in await self?.writeProject(to:url.pathExtension == "stillroom" ? url : url.appendingPathExtension("stillroom"))}
        }
    }
    func writeProject(to destination: URL) async {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at:destination.appendingPathComponent("Media"),withIntermediateDirectories:true)
            var copy = project
            for i in copy.assets.indices {
                let media = project.assets[i], source = url(media)
                let file = media.id.uuidString + "." + source.pathExtension
                let dest = destination.appendingPathComponent("Media/" + file)
                guard fm.fileExists(atPath:source.path) else {throw StudioError.message("Relink \(media.name) before saving a portable project.")}
                if source.standardizedFileURL != dest.standardizedFileURL {
                    if fm.fileExists(atPath:dest.path) {
                        let temp = destination.appendingPathComponent("Media/." + UUID().uuidString)
                        try fm.copyItem(at:source,to:temp);_ = try fm.replaceItemAt(dest,withItemAt:temp)
                    } else {try fm.copyItem(at:source,to:dest)}
                }
                copy.assets[i].path = "Media/" + file
            }
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(copy).write(to:destination.appendingPathComponent("project.json"),options:.atomic)
            project = copy;root = destination;projectURL = destination;dirty = false;persist();status = "Portable project saved"
        } catch {self.error = error.localizedDescription}
    }
    func openProjectPanel() {
        let panel = NSOpenPanel();panel.canChooseFiles = true;panel.canChooseDirectories = true
        panel.message = "Choose a .stillroom project or its project.json file."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else {return}
            Task {@MainActor in self?.openProject(url)}
        }
    }
    func openProject(_ url: URL) {
        do {
            let file = url.pathExtension == "json" ? url : url.appendingPathComponent("project.json")
            let value = try JSONDecoder().decode(FilmProject.self,from:Data(contentsOf:file));try value.validated()
            checkpoint();player.pause();playing = false
            documentID = UUID();project = value;root = file.deletingLastPathComponent();projectURL = root
            selectedShot = value.shots.first?.id;selectedAsset = nil;selectedSound = nil;time = 0;dirty = false
            undoStack = [];redoStack = [];thumbnails = [:];persist();refreshMedia();scheduleBuild()
        } catch {self.error = error.localizedDescription}
    }
    func importSubtitles() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [UTType(filenameExtension:"srt") ?? .plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let text = try? String(contentsOf:url) else {return}
            Task {@MainActor in
                guard let self else {return}
                let cues = SRT.parse(text)
                guard !cues.isEmpty else {self.error = "No valid captions found in this SRT file.";return}
                self.change({$0.subtitles = cues},rebuild:false);self.status = "Imported \(cues.count) captions"
            }
        }
    }
    func exportSRT() {
        let panel = NSSavePanel();panel.nameFieldStringValue = project.name + ".srt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {return}
            Task {@MainActor in
                guard let self else {return}
                do {try SRT.write(self.project.subtitles).write(to:url,atomically:true,encoding:.utf8)} catch {self.error = error.localizedDescription}
            }
        }
    }
    func exportMovie() {
        guard !exporting, !project.shots.isEmpty else {return}
        let panel = NSSavePanel();panel.allowedContentTypes = [.mpeg4Movie];panel.nameFieldStringValue = project.name + ".mp4"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else {return}
            Task {@MainActor in await self?.render(to:url)}
        }
    }
    func render(to url: URL) async {
        exporting = true;exportProgress = 0;player.pause();playing = false
        let snapshot = project, base = root
        let temp = url.deletingLastPathComponent().appendingPathComponent(".stillroom-" + UUID().uuidString + ".mp4")
        do {
            status = "Preparing export…"
            let film = try await MediaEngine.build(snapshot,root:base,forExport:true)
            guard let session = AVAssetExportSession(asset:film.composition,presetName:AVAssetExportPresetHighestQuality) else {throw StudioError.message("Cannot start an export on this Mac.")}
            exportSession = session
            session.outputURL = temp;session.outputFileType = .mp4;session.videoComposition = film.video;session.audioMix = film.audio
            session.shouldOptimizeForNetworkUse = true
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    exportProgress = session.progress
                    status = "Exporting \(Int(session.progress*100))%"
                    try? await Task.sleep(nanoseconds:250_000_000)
                }
            }
            await session.export()
            monitor.cancel()
            guard session.status == .completed else {throw session.error ?? StudioError.message(session.status == .cancelled ? "Export cancelled." : "Export failed.")}
            if FileManager.default.fileExists(atPath:url.path) {_ = try FileManager.default.replaceItemAt(url,withItemAt:temp)}
            else {try FileManager.default.moveItem(at:temp,to:url)}
            status = "Export complete · \(url.lastPathComponent)";exportProgress = 1
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {try? FileManager.default.removeItem(at:temp);self.error = error.localizedDescription;status = "Export stopped"}
        exportSession = nil;exporting = false
    }
    func cancelExport() {exportSession?.cancelExport()}
}
