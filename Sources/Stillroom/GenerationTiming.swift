import Foundation

enum GenerationTiming {
    static let range = 1.0...10.0
    static func frameCount(seconds:Double)->Int {
        let seconds = seconds.isFinite ? min(range.upperBound,max(range.lowerBound,seconds)) : 3.375
        return min(257,max(17,8 * Int(((seconds * 24 - 1) / 8).rounded()) + 1))
    }
    static func actualSeconds(_ seconds:Double)->Double {Double(frameCount(seconds:seconds))/24}
}
