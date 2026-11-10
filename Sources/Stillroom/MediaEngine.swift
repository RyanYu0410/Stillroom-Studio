import AppKit
import AVFoundation
import QuartzCore
import CryptoKit
import CoreText

struct BuiltFilm {
    let composition: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
}

enum MediaEngine {
    static let cache: URL = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Stillroom/Plates")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    static func inspect(_ url: URL) async throws -> MediaAsset {
        let ext = url.pathExtension.lowercased()
        if ext == "blend" { return MediaAsset(name: url.deletingPathExtension().lastPathComponent, path: url.path, kind: .blender, origin: "Blender") }
        if ["png","jpg","jpeg","heic","tiff","webp"].contains(ext) {
            guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw StudioError.message("Cannot read \(url.lastPathComponent).") }
            return MediaAsset(name: url.deletingPathExtension().lastPathComponent, path: url.path, kind: .image, width: cg.width, height: cg.height, origin: "Reference")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw StudioError.message("This file has no playable duration: \(url.lastPathComponent).") }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var media = MediaAsset(name: url.deletingPathExtension().lastPathComponent, path: url.path, kind: tracks.isEmpty ? .audio : .video, duration: duration)
        if let track = tracks.first {
            let size = try await track.load(.naturalSize)
            media.width = Int(size.width); media.height = Int(size.height)
        }
        return media
    }

    static func thumbnail(_ url: URL, kind: MediaKind, at seconds: Double = 0) async -> NSImage? {
        if kind == .image { return NSImage(contentsOf: url) }
        guard kind == .video else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    static func waveform(_ url:URL) async -> [Float] {
        let asset = AVURLAsset(url:url)
        guard let track = try? await asset.loadTracks(withMediaType:.audio).first,
              let reader = try? AVAssetReader(asset:asset) else {return []}
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:8000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
        guard reader.canAdd(output) else {return []};reader.add(output)
        guard reader.startReading() else {return []}
        var values:[Float] = [],sum:Float = 0,count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else {continue}
            var length = 0,total = 0;var pointer:UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:&length,totalLengthOut:&total,dataPointerOut:&pointer) == noErr,let pointer else {continue}
            pointer.withMemoryRebound(to:Float.self,capacity:total/4) {samples in
                for i in 0..<(total/4) {let value = samples[i];sum += value*value;count += 1;if count == 1024 {values.append(sqrt(sum/Float(count)));sum = 0;count = 0}}
            }
        }
        if count > 0 {values.append(sqrt(sum/Float(count)))}
        let peak = values.max() ?? 1
        return peak > 0 ? values.map {sqrt($0/peak)} : values
    }

    static func plate(_ url: URL, duration: Double, fps: Int, width: Int, height: Int) async throws -> URL {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "color-v2-\(url.path)-\(modified)-\(duration)-\(fps)-\(width)-\(height)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
        let dest = cache.appendingPathComponent(digest + ".mp4")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw StudioError.message("Cannot create a video plate for this image.") }
        try await writeFrames(to: dest, width: width, height: height, fps: fps, count: max(1, Int(ceil(duration*Double(fps))))) { _, context in
            context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x:0,y:0,width:width,height:height))
            let ratio = max(Double(width)/Double(image.width), Double(height)/Double(image.height))
            let w = Double(image.width)*ratio, h = Double(image.height)*ratio
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x:(Double(width)-w)/2,y:(Double(height)-h)/2,width:w,height:h))
        }
        return dest
    }

    static func writeFrames(to url: URL, width: Int, height: Int, fps: Int, count: Int, draw: (Int, CGContext) throws -> Void) async throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey:VideoColor.properties, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw StudioError.message("The Mac could not initialize the video encoder.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("Cannot start encoding.") }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<count {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? StudioError.message("Video encoder stopped.") }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                try autoreleasepool {
                    var buffer: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw StudioError.message("Cannot allocate a video frame.") }
                    VideoColor.attach(to:buffer,space:VideoColor.encodingSpace,transfer:VideoColor.transfer)
                    CVPixelBufferLockBaseAddress(buffer, [])
                    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: VideoColor.encodingSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw StudioError.message("Cannot draw this video frame.") }
                    try draw(frame, context)
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error ?? StudioError.message("Cannot encode this frame.") }
                }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: Int32(fps)))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? StudioError.message("Video encoding failed.") }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: temp); return }
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: temp); throw error
        }
    }

    @MainActor static func build(_ project: FilmProject, root: URL?, forExport: Bool = false) async throws -> BuiltFilm {
        try project.validated()
        guard !project.shots.isEmpty else { throw StudioError.message("Add a shot to the timeline first.") }
        let composition = AVMutableComposition()
        let video = AVMutableVideoComposition()
        let canvas = CGSize(width: project.width, height: project.height)
        video.renderSize = canvas
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = VideoColor.transfer
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        video.frameDuration = CMTime(value: 1, timescale: Int32(project.fps))
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []
        var cursor = CMTime.zero
        let overlays = forExport && ((project.captionsEnabled && !project.subtitles.isEmpty) || project.shots.contains {!($0.indicator ?? "").isEmpty})
        for shot in project.shots {
            try Task.checkCancellation()
            guard let media = project.assets.first(where: { $0.id == shot.assetID }) else { throw StudioError.message("A shot’s media is missing from the project.") }
            var url = media.url(relativeTo: root)
            guard FileManager.default.fileExists(atPath: url.path) else { throw StudioError.message("Missing media: \(media.name). Use Relink in the inspector.") }
            if media.kind == .image {
                url = try await plate(url, duration: shot.sourceIn + shot.sourceDuration + 0.1, fps: project.fps, width: project.width, height: project.height)
            }
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.message("No video track in \(media.name).") }
            let available = try await asset.load(.duration).seconds
            guard shot.sourceIn < available, shot.sourceIn + shot.sourceDuration <= available + 0.08 else { throw StudioError.message("The trim exceeds \(media.name)’s source duration. Relink or shorten this shot.") }
            let sourceRange = CMTimeRange(start: CMTime(seconds: shot.sourceIn, preferredTimescale:600), duration:CMTime(seconds:min(shot.sourceDuration, available-shot.sourceIn),preferredTimescale:600))
            let outputDuration = CMTime(seconds: shot.duration, preferredTimescale: 600)
            try target.insertTimeRange(sourceRange, of:source, at:cursor)
            target.scaleTimeRange(CMTimeRange(start:cursor,duration:sourceRange.duration), toDuration:outputDuration)
            let size = try await source.load(.naturalSize)
            let preferred = try await source.load(.preferredTransform)
            let bounds = CGRect(origin:.zero,size:size).applying(preferred)
            func transform(_ zoom: Double) -> CGAffineTransform {
                let scale = max(canvas.width/bounds.width, canvas.height/bounds.height)*zoom
                return preferred.concatenating(CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY))
                    .concatenating(CGAffineTransform(scaleX:scale,y:scale))
                    .concatenating(CGAffineTransform(translationX:(canvas.width-bounds.width*scale)/2,y:(canvas.height-bounds.height*scale)/2))
            }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start:cursor,duration:outputDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack:target)
            layer.setTransformRamp(fromStart:transform(shot.zoomStart), toEnd:transform(shot.zoomEnd), timeRange:instruction.timeRange)
            instruction.layerInstructions = [layer]
            if overlays {
                instructions.append(CaptionInstruction(range:instruction.timeRange,trackID:target.trackID,from:transform(shot.zoomStart),to:transform(shot.zoomEnd),captions:project.captionsEnabled ? project.subtitles : [],indicator:shot.indicator ?? ""))
            } else {instructions.append(instruction)}
            if shot.volume > 0, let sourceAudio = try await asset.loadTracks(withMediaType:.audio).first,
               let track = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(sourceRange,of:sourceAudio,at:cursor)
                track.scaleTimeRange(CMTimeRange(start:cursor,duration:sourceRange.duration),toDuration:outputDuration)
                let params = AVMutableAudioMixInputParameters(track:track)
                params.setVolume(Float(shot.volume),at:cursor);audioParams.append(params)
            }
            cursor = cursor + outputDuration
        }
        for sound in project.sounds where !sound.muted && sound.volume > 0 && sound.start < project.duration {
            guard let media = project.assets.first(where: {$0.id == sound.assetID}) else { continue }
            let url = media.url(relativeTo:root)
            guard FileManager.default.fileExists(atPath:url.path) else { throw StudioError.message("Missing sound: \(media.name).") }
            let asset = AVURLAsset(url:url)
            let available = try await asset.load(.duration).seconds - sound.sourceIn
            let length = min(sound.duration, available, project.duration-sound.start)
            guard length > 0, let source = try await asset.loadTracks(withMediaType:.audio).first,
                  let track = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { continue }
            let start = CMTime(seconds:sound.start,preferredTimescale:600)
            try track.insertTimeRange(CMTimeRange(start:CMTime(seconds:sound.sourceIn,preferredTimescale:600),duration:CMTime(seconds:length,preferredTimescale:600)),of:source,at:start)
            let params = AVMutableAudioMixInputParameters(track:track)
            params.setVolume(Float(sound.volume),at:start);audioParams.append(params)
        }
        video.instructions = instructions
        let mix = AVMutableAudioMix();mix.inputParameters = audioParams
        if overlays {video.customVideoCompositorClass = CaptionCompositor.self}
        return BuiltFilm(composition:composition,video:video,audio:mix)
    }
}
