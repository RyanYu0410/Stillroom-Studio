import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum VideoColor {
    static let sRGB = CGColorSpace(name:CGColorSpace.sRGB)!
    static let rec709 = CGColorSpace(name:CGColorSpace.itur_709)!
    static var encodingSpace:CGColorSpace {if #available(macOS 15,*) {return sRGB};return rec709}
    static var transfer:String {if #available(macOS 15,*) {return AVVideoTransferFunction_IEC_sRGB};return AVVideoTransferFunction_ITU_R_709_2}
    static var properties:[String:Any] {[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:transfer,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]}
    static func attach(to buffer:CVPixelBuffer,space:CGColorSpace,transfer:String) {
        CVBufferSetAttachment(buffer,kCVImageBufferCGColorSpaceKey,space,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,transfer as CFString,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
    }
    static func referencePNG(_ image:CGImage) throws -> Data {
        // ComfyUI reads PNG channel values without applying an ICC transform.
        // Convert the pixels, rather than just changing or discarding their tag.
        guard let bitmap = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw StudioError.message("Cannot prepare the reference colors.")}
        bitmap.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let converted = bitmap.makeImage() else {throw StudioError.message("Cannot convert the reference to sRGB.")}
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {throw StudioError.message("Cannot encode the reference image.")}
        CGImageDestinationAddImage(destination,converted,nil)
        guard CGImageDestinationFinalize(destination) else {throw StudioError.message("Cannot finish the reference image.")}
        return data as Data
    }
    static func referencePNG(at url:URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {throw StudioError.message("Cannot read the reference image.")}
        if url.pathExtension.lowercased() == "png",image.colorSpace?.name == CGColorSpace.sRGB {return try Data(contentsOf:url)}
        return try referencePNG(image)
    }
    static func tags(of url:URL) async throws -> [String:String] {
        guard let track = try await AVURLAsset(url:url).loadTracks(withMediaType:.video).first,
              let format = try await track.load(.formatDescriptions).first else {throw StudioError.message("The generated file has no video format.")}
        let keys:[String:CFString] = ["primaries":kCMFormatDescriptionExtension_ColorPrimaries,"transfer":kCMFormatDescriptionExtension_TransferFunction,"matrix":kCMFormatDescriptionExtension_YCbCrMatrix]
        var result:[String:String] = [:]
        for (name,key) in keys {if let value = CMFormatDescriptionGetExtension(format,extensionKey:key) as? String {result[name] = value}}
        return result
    }
    static func tagLocalLTX(_ url:URL) async throws -> String {
        let before = try await tags(of:url)
        guard before.isEmpty else {return "Existing video color metadata preserved"}
        guard let track = try await AVURLAsset(url:url).loadTracks(withMediaType:.video).first,
              let format = try await track.load(.formatDescriptions).first,CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {return "Color metadata unavailable; review the take"}
        let temporary = url.deletingLastPathComponent().appendingPathComponent("Color-" + UUID().uuidString + ".mp4")
        // The installed LTX encoder uses libswscale's RGB→limited-range 601
        // matrix and writes no color description. Declare those actual values;
        // do not relabel its pixels as a different matrix or grade saturation.
        try await Task.detached {
            let fm = FileManager.default
            guard let executable = ["/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg"].first(where:{fm.isExecutableFile(atPath:$0)}) else {throw StudioError.message("The local engine’s FFmpeg is needed to finish color-safe video. Its usual location is /opt/homebrew/bin/ffmpeg.")}
            let process = Process();process.executableURL = URL(fileURLWithPath:executable)
            process.arguments = ["-v","error","-y","-i",url.path,"-map","0","-c","copy","-bsf:v","h264_metadata=colour_primaries=1:transfer_characteristics=13:matrix_coefficients=6:video_full_range_flag=0","-color_primaries","bt709","-color_trc","iec61966-2-1","-colorspace","smpte170m","-color_range","tv","-movflags","+faststart",temporary.path]
            let pipe = Pipe();process.standardError = pipe;process.standardOutput = FileHandle.nullDevice
            try process.run();let error = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus == 0 else {throw StudioError.message("Cannot finish video color metadata. " + (String(data:error.prefix(600),encoding:.utf8) ?? ""))}
        }.value
        defer {try? FileManager.default.removeItem(at:temporary)}
        try Task.checkCancellation()
        let after = try await tags(of:temporary)
        guard after.count == 3 else {throw StudioError.message("The local video’s color metadata could not be verified.")}
        _ = try FileManager.default.replaceItemAt(url,withItemAt:temporary)
        return "sRGB reference pixels · explicit sRGB transfer, 709 primaries and 601 matrix · lossless metadata repair"
    }
}
