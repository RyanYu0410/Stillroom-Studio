import SwiftUI

struct GenerationProgressView:View {
    let progress:GenerationProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        SwiftUI.TimelineView(.animation(minimumInterval:reduceMotion ? 1 : 1.0/24,paused:!progress.active)) {timeline in
            let date = timeline.date
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:7) {
                    Image(systemName:progress.stage == .ready ? "checkmark.circle.fill" : "film.stack").foregroundStyle(Ink.mint)
                    Text(progress.title).font(.system(size:11,weight:.medium))
                    Spacer(minLength:6)
                    Text(GenerationProgress.clock(progress.elapsed(at:date)) + " elapsed")
                        .font(.system(size:10,design:.monospaced)).foregroundStyle(Ink.quiet).monospacedDigit()
                }
                FilmProgressTrack(fraction:progress.fraction(at:date),time:date.timeIntervalSince(progress.started),moving:progress.active && !reduceMotion)
                    .frame(height:16).accessibilityHidden(true)
                HStack(alignment:.firstTextBaseline) {
                    Text(progress.remaining(at:date)).font(.system(size:10)).foregroundStyle(Ink.quiet)
                    Spacer(minLength:4)
                    if progress.stage == .rendering,progress.expectedSeconds != nil {
                        Text("ESTIMATE").font(.system(size:8,weight:.medium)).tracking(1).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(11).background(Ink.raised,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Ink.line.opacity(0.45),lineWidth:0.5))
            .help(progress.basis + ". Queue and completion come from the engine. The fill and remaining time are estimates; complex motion and memory pressure can change rendering time.")
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("\(progress.title). \(progress.remaining(at:date)). \(GenerationProgress.clock(progress.elapsed(at:date))) elapsed.")
        }
    }
}

/// A tiny developing filmstrip: passing frames and a soft light sweep, clipped to the estimate.
private struct FilmProgressTrack:View {
    let fraction:Double?
    let time:Double
    let moving:Bool
    var body:some View {
        GeometryReader {geometry in
            let width = geometry.size.width
            let fill = fraction.map {width * $0} ?? width
            let travel = moving ? (time * 23).truncatingRemainder(dividingBy:44) : 0
            ZStack(alignment:.leading) {
                Capsule().fill(Ink.line.opacity(0.24))
                ZStack(alignment:.leading) {
                    Rectangle().fill(LinearGradient(colors:[Ink.mint.opacity(0.28),Ink.mint.opacity(0.72)],startPoint:.leading,endPoint:.trailing))
                    HStack(spacing:4) {
                        ForEach(0..<max(2,Int(width/44)+3),id:\.self) {_ in
                            RoundedRectangle(cornerRadius:2).stroke(.white.opacity(0.28),lineWidth:0.7).frame(width:36,height:8)
                        }
                    }.offset(x:travel-44)
                    if moving {
                        Rectangle().fill(LinearGradient(colors:[.clear,.white.opacity(0.34),.clear],startPoint:.leading,endPoint:.trailing))
                            .frame(width:96).offset(x:(time * 65).truncatingRemainder(dividingBy:max(1,width+96))-96)
                    }
                }.frame(width:max(0,fill),alignment:.leading).clipped()
                    .opacity(fraction == nil ? 0.55 : 1)
            }.clipShape(Capsule())
        }
    }
}
