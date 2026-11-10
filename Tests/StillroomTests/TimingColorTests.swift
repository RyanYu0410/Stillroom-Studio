import XCTest
import AVFoundation
import ImageIO
@testable import Stillroom

final class TimingColorTests:XCTestCase {
    func testRequestedLengthUsesLegalFrameCountsAndDoesNotDependOnQuality() {
        XCTAssertEqual(GenerationTiming.frameCount(seconds:2),49)
        XCTAssertEqual(GenerationTiming.frameCount(seconds:5),121)
        XCTAssertEqual(GenerationTiming.frameCount(seconds:10),241)
        for seconds in [Double.nan,-1,1,2.5,5,8,10,100] {
            let frames = GenerationTiming.frameCount(seconds:seconds)
            XCTAssertEqual((frames-1)%8,0);XCTAssertTrue((17...257).contains(frames))
        }
    }
    func testUsingGeneratedLengthDoesNotSlowDownOrLoseTheOriginal() throws {
        let original = MediaAsset(name:"Original",path:"a.mp4",kind:.video,duration:12)
        var take = MediaAsset(name:"New",path:"b.mp4",kind:.video,duration:121.0/24);take.parentAssetID = original.id
        var project = FilmProject();project.assets = [original,take]
        project.shots = [Shot(assetID:original.id,name:"Shot",sourceDuration:12),Shot(assetID:original.id,name:"Next",sourceDuration:3)]
        project.subtitles = [Subtitle(start:13,end:14,text:"A fixed cue")]
        let captions = project.subtitles
        try project.useTake(take.id,for:project.shots[0].id,keepTiming:false)
        XCTAssertEqual(project.shots[0].speed,1);XCTAssertEqual(project.shots[0].duration,121.0/24,accuracy:0.00001)
        XCTAssertEqual(project.duration,121.0/24+3,accuracy:0.00001)
        XCTAssertEqual(project.subtitles,captions);XCTAssertEqual(project.assets.count,2)
    }
    private let colors:[[CGFloat]] = [[0.72,0.28,0.15,1],[0.18,0.58,0.3,1],[0.16,0.28,0.7,1],[0.4,0.4,0.4,1]]
    private func chart(space:CGColorSpace)->CGImage {
        let bitmap = CGContext(data:nil,width:768,height:432,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i,components) in colors.enumerated() {bitmap.setFillColor(CGColor(colorSpace:space,components:components)!);bitmap.fill(CGRect(x:i*192,y:0,width:192,height:432))}
        return bitmap.makeImage()!
    }
    private func pixels(_ image:CGImage)->[[Double]] {
        var bytes = [UInt8](repeating:0,count:image.width*image.height*4)
        bytes.withUnsafeMutableBytes {pointer in
            let bitmap = CGContext(data:pointer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:VideoColor.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return (0..<4).map {i in
            let offset = ((image.height/3)*image.width + i*(image.width/4)+image.width/8)*4
            return (0..<3).map {Double(bytes[offset+$0])/255}
        }
    }
    func testReferenceConversionChangesP3PixelsAndWritesSRGBProfile() throws {
        let p3 = CGColorSpace(name:CGColorSpace.displayP3)!
        let png = try VideoColor.referencePNG(chart(space:p3))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.colorSpace?.name,CGColorSpace.sRGB)
        let converted = pixels(image)
        for i in colors.indices {
            let expected = try XCTUnwrap(CGColor(colorSpace:p3,components:colors[i])?.converted(to:VideoColor.sRGB,intent:.defaultIntent,options:nil)?.components)
            for channel in 0..<3 {XCTAssertEqual(converted[i][channel],Double(expected[channel]),accuracy:0.012)}
        }
        XCTAssertGreaterThan(abs(converted[0][0]-Double(colors[0][0])),0.025,"Changing the profile label alone is not a color conversion.")
    }
    @MainActor func testEncodingAndCaptionedExportKeepChartColors() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-color-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let output = folder.appendingPathComponent("chart.mp4"),image = chart(space:VideoColor.sRGB)
        try await MediaEngine.writeFrames(to:output,width:768,height:432,fps:24,count:24) {_,context in context.draw(image,in:CGRect(x:0,y:0,width:768,height:432))}
        let tags = try await VideoColor.tags(of:output)
        XCTAssertEqual(tags.count,3)
        let original = try await MediaEngine.inspect(output)
        var project = FilmProject();project.width = 768;project.height = 432;project.assets = [original];project.shots = [Shot(assetID:original.id,name:"Chart",sourceDuration:1)]
        // Create an independently tagged Rec.709 source to test mixed transfer
        // functions, not just an sRGB-to-sRGB round trip.
        let rec709Film = try await MediaEngine.build(project,root:nil,forExport:true)
        rec709Film.video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        let rec709URL = folder.appendingPathComponent("rec709-source.mp4")
        let converter = try XCTUnwrap(AVAssetExportSession(asset:rec709Film.composition,presetName:AVAssetExportPresetHighestQuality))
        converter.outputURL = rec709URL;converter.outputFileType = .mp4;converter.videoComposition = rec709Film.video
        await converter.export();XCTAssertEqual(converter.status,.completed)
        let rec709Source = try await MediaEngine.inspect(rec709URL)
        project.subtitles = [Subtitle(start:0,end:1,text:"Color check")]
        for source in [original,rec709Source] {
        project.assets = [source];project.shots[0].assetID = source.id
        for captioned in [false,true] {
            project.captionsEnabled = captioned
            let film = try await MediaEngine.build(project,root:nil,forExport:true)
            let exported = folder.appendingPathComponent(source.name + (captioned ? "-captioned.mp4" : "-plain.mp4"))
            let session = try XCTUnwrap(AVAssetExportSession(asset:film.composition,presetName:AVAssetExportPresetHighestQuality))
            session.outputURL = exported;session.outputFileType = .mp4;session.videoComposition = film.video
            await session.export();XCTAssertEqual(session.status,.completed,session.error?.localizedDescription ?? "")
            let generator = AVAssetImageGenerator(asset:AVURLAsset(url:exported))
            let result = try await generator.image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
            let samples = pixels(result)
            let maximumError = colors.indices.flatMap {i in (0..<3).map {abs(samples[i][$0]-Double(colors[i][$0]))}}.max() ?? 0
            print("COLOR_CHART_MAX_RGB_ERROR_\(source.name)_\(captioned ? "CAPTION" : "PLAIN")=\(maximumError)")
            for i in colors.indices {for channel in 0..<3 {XCTAssertEqual(samples[i][channel],Double(colors[i][channel]),accuracy:0.025,"\(captioned ? "Caption" : "Plain") path changed patch \(i) channel \(channel)")}}
        }
        }
    }
    func testLTXMetadataRepairPreservesDurationAndDeclaresActualEncoding() async throws {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Demo/Media/07-native.mp4")
        let file = FileManager.default.fileExists(atPath:local.path) ? local : source.deletingLastPathComponent().appendingPathComponent("Stillroom Studio.app/Contents/Resources/Demo/Media/07-native.mp4")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-color-repair-" + UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at:file,to:copy)
        let before = try await AVURLAsset(url:copy).load(.duration)
        let result = try await VideoColor.tagLocalLTX(copy)
        XCTAssertTrue(result.contains("lossless metadata repair"))
        let tags = try await VideoColor.tags(of:copy)
        XCTAssertEqual(tags["primaries"],kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(tags["transfer"],kCVImageBufferTransferFunction_sRGB as String)
        XCTAssertEqual(tags["matrix"],kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        let after = try await AVURLAsset(url:copy).load(.duration)
        XCTAssertEqual(before.seconds,after.seconds,accuracy:0.0001)
        print("COLOR_REPAIR_TEST_FILE=" + copy.path)
    }
}
