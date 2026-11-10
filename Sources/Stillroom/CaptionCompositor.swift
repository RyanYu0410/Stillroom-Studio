import AVFoundation
import CoreImage
import CoreText

final class CaptionInstruction:NSObject,AVVideoCompositionInstructionProtocol,@unchecked Sendable {
    let timeRange:CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs:[NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID:CMPersistentTrackID
    let from:CGAffineTransform
    let to:CGAffineTransform
    let captions:[Subtitle]
    let indicator:String
    init(range:CMTimeRange,trackID:CMPersistentTrackID,from:CGAffineTransform,to:CGAffineTransform,captions:[Subtitle],indicator:String = "") {
        self.timeRange = range;self.trackID = trackID;self.from = from;self.to = to;self.captions = captions
        requiredSourceTrackIDs = [NSNumber(value:trackID)]
        self.indicator = indicator
    }
}

// Render captions into the same pixels as the transformed picture. This keeps
// exported subtitles independent of Core Animation's offscreen animation clock.
final class CaptionCompositor:NSObject,AVVideoCompositing {
    var sourcePixelBufferAttributes:[String:any Sendable]? {[kCVPixelBufferPixelFormatTypeKey as String:[kCVPixelFormatType_32BGRA,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]]}
    var requiredPixelBufferAttributesForRenderContext:[String:any Sendable] {[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]}
    // Preserve each source's color description instead of accepting an implicit
    // narrow-color conversion before Core Image performs its own conversion.
    var supportsWideColorSourceFrames:Bool {true}
    var canConformColorOfSourceFrames:Bool {true}
    private let queue = DispatchQueue(label:"studio.stillroom.caption-render")
    private let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
    private var renderContext:AVVideoCompositionRenderContext?
    private var lastKey = ""
    private var lastCaption:CIImage?
    private var lastIndicatorKey = ""
    private var lastIndicator:CIImage?
    func renderContextChanged(_ newRenderContext:AVVideoCompositionRenderContext) {queue.sync {renderContext = newRenderContext}}
    func startRequest(_ request:AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? CaptionInstruction,
                  let source = request.sourceFrame(byTrackID:instruction.trackID),let target = renderContext?.newPixelBuffer() else {
                request.finish(with:StudioError.message("Cannot prepare a captioned video frame."));return
            }
            let seconds = request.compositionTime.seconds
            let fraction = max(0,min(1,(seconds-instruction.timeRange.start.seconds)/instruction.timeRange.duration.seconds))
            let a = instruction.from,b = instruction.to
            func blend(_ x:CGFloat,_ y:CGFloat)->CGFloat {x+(y-x)*fraction}
            let transform = CGAffineTransform(a:blend(a.a,b.a),b:blend(a.b,b.b),c:blend(a.c,b.c),d:blend(a.d,b.d),tx:blend(a.tx,b.tx),ty:blend(a.ty,b.ty))
            let bounds = CGRect(x:0,y:0,width:CVPixelBufferGetWidth(target),height:CVPixelBufferGetHeight(target))
            var image = CIImage(cvPixelBuffer:source).transformed(by:transform).composited(over:CIImage(color:.black).cropped(to:bounds)).cropped(to:bounds)
            if let caption = instruction.captions.first(where:{$0.start <= seconds && seconds < $0.end}) {
                let key = "\(Int(bounds.width))x\(Int(bounds.height)):\(caption.text)"
                if lastKey != key {lastKey = key;lastCaption = captionImage(caption.text,size:bounds.size)}
                if let overlay = lastCaption {image = overlay.composited(over:image)}
            }
            if !instruction.indicator.isEmpty {
                let key = "\(Int(bounds.width))x\(Int(bounds.height)):\(instruction.indicator)"
                if lastIndicatorKey != key {lastIndicatorKey = key;lastIndicator = indicatorImage(instruction.indicator,size:bounds.size)}
                if let overlay = lastIndicator {image = overlay.composited(over:image)}
            }
            VideoColor.attach(to:target,space:VideoColor.encodingSpace,transfer:VideoColor.transfer)
            context.render(image,to:target,bounds:bounds,colorSpace:VideoColor.encodingSpace)
            request.finish(withComposedVideoFrame:target)
        }}
    }
    func cancelAllPendingVideoCompositionRequests() {queue.sync {}}
    private func captionImage(_ text:String,size:CGSize)->CIImage? {
        guard let bitmap = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:VideoColor.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString,size.height*0.031,nil)
        var alignment = CTTextAlignment.center
        let paragraph:CTParagraphStyle = withUnsafePointer(to:&alignment) {pointer in
            var setting = CTParagraphStyleSetting(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:pointer)
            return CTParagraphStyleCreate(&setting,1)
        }
        let attributes:[NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1),NSAttributedString.Key(kCTParagraphStyleAttributeName as String):paragraph]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes))
        let path = CGPath(rect:CGRect(x:size.width*0.12,y:size.height*0.034,width:size.width*0.76,height:size.height*0.085),transform:nil)
        bitmap.setShadow(offset:CGSize(width:0,height:-1),blur:4,color:CGColor(gray:0,alpha:1))
        CTFrameDraw(CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),path,nil),bitmap)
        guard let image = bitmap.makeImage() else {return nil}
        return CIImage(cgImage:image)
    }
    private func indicatorImage(_ text:String,size:CGSize)->CIImage? {
        guard let bitmap = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:VideoColor.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString,size.height*0.026,nil)
        let attributes:[NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:String(text.prefix(100)),attributes:attributes))
        let width = min(size.width*0.8,CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))+size.height*0.04)
        let rect = CGRect(x:size.width*0.04,y:size.height*0.9,width:width,height:size.height*0.055)
        bitmap.setFillColor(CGColor(gray:0.03,alpha:0.65));bitmap.addPath(CGPath(roundedRect:rect,cornerWidth:size.height*0.012,cornerHeight:size.height*0.012,transform:nil));bitmap.fillPath()
        bitmap.saveGState();bitmap.clip(to:rect);bitmap.textPosition = CGPoint(x:rect.minX+size.height*0.02,y:rect.minY+size.height*0.018);CTLineDraw(line,bitmap);bitmap.restoreGState()
        return bitmap.makeImage().map {CIImage(cgImage:$0)}
    }
}
