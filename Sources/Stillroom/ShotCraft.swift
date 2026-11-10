import Foundation
import AVFoundation
import AppKit

struct ShotDirection:Codable,Equatable {
    var purpose = ""
    var camera = "From prompt"
    var framing = "Keep reference"
    var light = "Keep reference"
    var continuity = ""
    var sound = ""
    var referenceDirection = ""
    static let cameras = ["From prompt","Locked camera","Slow pullback","Slow push in","Gentle lateral move"]
    static let framings = ["Keep reference","Intimate portrait","Medium shot","Wide establishing shot"]
    static let lights = ["Keep reference","Soft window light","Warm practical light","Overcast daylight"]
    func motionPrompt(action:String)->String {
        var lines = [RegenerationDirection.prompt(change:action)]
        let cameraDirections = ["Locked camera":"The camera remains stationary while the subject performs the action.","Slow pullback":"The camera moves smoothly backward from the opening frame, gradually revealing more of the scene with natural depth and parallax.","Slow push in":"The camera moves smoothly closer to the subject throughout the take, with natural depth and parallax.","Gentle lateral move":"The camera tracks gently sideways along one continuous path, with natural foreground and background parallax."]
        if let direction = cameraDirections[camera] {lines.append(direction)}
        if framing != "Keep reference" {lines.append("A continuous \(framing.lowercased()).")}
        if light != "Keep reference" {lines.append("Lighting: \(light.lowercased()), natural colors and soft highlight detail.")}
        // The actual reference pixels carry static identity and setting. Repeating
        // an image brief here can make the video model animate a photograph.
        return lines.joined(separator:" ")
    }
    func imagePrompt()->String {
        var lines = ["Create a cinematic live-action production still based on the supplied reference image.",referenceDirection.trimmingCharacters(in:.whitespacesAndNewlines),"Keep the same recognizable people, wardrobe and physical setting. Use believable skin texture, considered composition and natural photographic detail."]
        if framing != "Keep reference" {lines.append("Framing: " + framing.lowercased() + ".")}
        if light != "Keep reference" {lines.append("Lighting: " + light.lowercased() + ".")}
        if !continuity.isEmpty {lines.append("Continuity: " + continuity)}
        return lines.filter {!$0.isEmpty}.joined(separator:"\n")
    }
}

struct ReferenceRecipe:Codable,Equatable {
    var model:String
    var seed:Int
    var steps:Int
    var prompt:String
    var sourceAssetID:UUID?
}

struct TakeReview:Codable,Equatable {
    var sourceIn:Double = 0
    var sourceOut:Double = 0
    var faces = false
    var hands = false
    var props = false
    var movement = false
    var note = ""
}

struct MotionEvidence:Codable,Equatable {
    let samples:Int
    let meanDifference:Double
    var label:String {
        if meanDifference < 2 {return "Low sampled motion · review the action at 1×"}
        if meanDifference > 35 {return "Large sampled changes · check cuts, flashes and continuity"}
        return "Motion sampled · review identity, hands and objects"
    }
}

struct ReviewFrame:Identifiable {
    let id:Int
    let seconds:Double
    let image:NSImage
}

struct MotionSample {
    let frames:[ReviewFrame]
    let meanDifference:Double
    var summary:String {
        if meanDifference < 2 {return "Very little change between sampled frames. Play at 1× and check whether the intended action happens."}
        if meanDifference > 35 {return "Large changes between sampled frames. Check for a cut, a flash or changes to the person and objects."}
        return "Motion is visible between sampled frames. Check faces, hands, objects and the camera path at 1×."
    }
    static func difference(_ images:[[UInt8]])->Double {
        guard images.count > 1 else {return 0}
        let values = zip(images,images.dropFirst()).compactMap {a,b -> Double? in
            guard !a.isEmpty,a.count == b.count else {return nil}
            return zip(a,b).reduce(0.0) {$0 + abs(Double($1.0)-Double($1.1))}/Double(a.count)
        }
        return values.isEmpty ? 0 : values.reduce(0,+)/Double(values.count)
    }
    private static func luma(_ image:CGImage)->[UInt8] {
        var bytes = [UInt8](repeating:0,count:64*36*4)
        bytes.withUnsafeMutableBytes {buffer in
            guard let context = CGContext(data:buffer.baseAddress,width:64,height:36,bitsPerComponent:8,bytesPerRow:64*4,space:VideoColor.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return}
            context.interpolationQuality = .high;context.draw(image,in:CGRect(x:0,y:0,width:64,height:36))
        }
        var values:[UInt8] = []
        for i in stride(from:0,to:bytes.count,by:4) {
            let red = Double(bytes[i])*0.2126
            let green = Double(bytes[i+1])*0.7152
            let blue = Double(bytes[i+2])*0.0722
            values.append(UInt8(min(255,max(0,(red+green+blue).rounded()))))
        }
        return values
    }
    static func read(_ url:URL) async throws -> MotionSample {
        let asset = AVURLAsset(url:url),duration = try await asset.load(.duration).seconds
        guard duration.isFinite,duration > 0 else {throw StudioError.message("This take has no playable picture.")}
        let generator = AVAssetImageGenerator(asset:asset)
        generator.appliesPreferredTrackTransform = true;generator.maximumSize = CGSize(width:1920,height:1080)
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        var frames:[ReviewFrame] = [],pixels:[[UInt8]] = []
        for index in 0..<9 {
            try Task.checkCancellation()
            let at = max(0,duration-1.0/24)*Double(index)/8
            let result = try await generator.image(at:CMTime(seconds:at,preferredTimescale:600))
            frames.append(ReviewFrame(id:index,seconds:result.actualTime.seconds,image:NSImage(cgImage:result.image,size:.zero)))
            pixels.append(luma(result.image))
        }
        return MotionSample(frames:frames,meanDifference:difference(pixels))
    }
}
