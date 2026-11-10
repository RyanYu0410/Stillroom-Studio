import Foundation

/// Engine states are observed; the fill and remaining time are explicitly estimates.
struct GenerationProgress {
    enum Stage {case preparing, queued, rendering, finishing, ready, failed, cancelled}
    var stage:Stage = .preparing
    var started = Date()
    var renderStarted:Date?
    var ended:Date?
    var expectedSeconds:Double?
    var queuePosition:Int?
    var basis = "Learning this workflow"
    var title:String {
        switch stage {
        case .preparing:return "Preparing your take"
        case .queued:return "Waiting for the engine"
        case .rendering:return "Bringing the frame to life"
        case .finishing:return "Checking picture & color"
        case .ready:return "Your take is ready"
        case .failed:return "Generation stopped"
        case .cancelled:return "Request cancelled"
        }
    }
    var active:Bool {ended == nil}
    mutating func rendering(at date:Date = Date()) {
        guard stage == .queued || stage == .preparing else {return}
        stage = .rendering;renderStarted = date;queuePosition = nil
    }
    mutating func finish(_ stage:Stage,at date:Date = Date()) {self.stage = stage;ended = date}
    func elapsed(at date:Date)->Double {max(0,(ended ?? date).timeIntervalSince(started))}
    func renderElapsed(at date:Date)->Double {renderStarted.map {max(0,(ended ?? date).timeIntervalSince($0))} ?? 0}
    func fraction(at date:Date)->Double? {
        switch stage {
        case .ready:return 1
        case .finishing:return 0.97
        case .rendering:
            guard let expectedSeconds,expectedSeconds > 0 else {return nil}
            let ratio = renderElapsed(at:date)/expectedSeconds
            // The estimate keeps moving gently if a render runs late, never claiming completion.
            return 0.06 + 0.88 * (ratio <= 1 ? 0.90 * ratio : 0.90 + 0.10 * (1 - exp(-(ratio-1))))
        default:return nil
        }
    }
    func remaining(at date:Date)->String {
        switch stage {
        case .preparing:return "Finding models & preparing the frame"
        case .queued:return queuePosition.map {"Queue position \($0) · estimate starts when rendering begins"} ?? "Render time starts when your turn begins"
        case .rendering:
            guard let expectedSeconds else {return "Measuring this workflow · time remaining unavailable"}
            let elapsed = renderElapsed(at:date)
            guard elapsed < expectedSeconds * 1.3 else {return "Taking longer than estimated · still rendering"}
            let lower = max(10,expectedSeconds * 0.75 - elapsed)
            let upper = max(lower + 15,expectedSeconds * 1.3 - elapsed)
            if upper < 60 {return "Estimated · less than a minute left"}
            return "Estimated · about \(max(1,Int(ceil(lower/60))))–\(max(2,Int(ceil(upper/60)))) min left"
        case .finishing:return "Saving, checking color and adding your take"
        case .ready:return "Preview it before using it in your edit"
        case .failed:return "Your original edit is safe"
        case .cancelled:return "A running engine job may finish in the background"
        }
    }
    static func clock(_ seconds:Double)->String {
        let value = max(0,Int(seconds))
        return String(format:"%d:%02d",value/60,value%60)
    }
}

struct GenerationTimingSample:Codable {
    let signature:String
    let pixelsFrames:Double
    let seconds:Double
    static func signature(graph:[String:Any])->String? {
        guard graph.values.contains(where:{($0 as? [String:Any])?["class_type"] as? String == "MissingMomentPinnedTake" || ($0 as? [String:Any])?["class_type"] as? String == "LTX2MLXGenerate"}) else {return nil}
        // Only these built-in pipelines have a known workload. Custom graphs stay indeterminate.
        let allowed:Set<String> = ["LoadImage","LTX2MLXModelLoader","MissingMomentPinnedTake","LTX2MLXGenerate"]
        guard graph.values.allSatisfy({allowed.contains(($0 as? [String:Any])?["class_type"] as? String ?? "")}) else {return nil}
        var normalized = graph
        for key in graph.keys {
            guard var node = graph[key] as? [String:Any],var inputs = node["inputs"] as? [String:Any] else {return nil}
            for dynamic in ["prompt","seed","width","height","num_frames","filename_prefix"] {inputs.removeValue(forKey:dynamic)}
            if inputs["image"] is String {inputs["image"] = "reference.png"}
            node["inputs"] = inputs;normalized[key] = node
        }
        guard let data = try? JSONSerialization.data(withJSONObject:normalized,options:.sortedKeys) else {return nil}
        return String(data:data,encoding:.utf8)
    }
    static func workload(graph:[String:Any])->Double? {
        for value in graph.values {
            guard let node = value as? [String:Any],let inputs = node["inputs"] as? [String:Any],let w = inputs["width"] as? Int,let h = inputs["height"] as? Int,let f = inputs["num_frames"] as? Int,w > 0,h > 0,f > 0 else {continue}
            return Double(w)*Double(h)*Double(f)
        }
        return nil
    }
    static func fromHistory(_ history:[String:Any])->[Self] {
        history.values.compactMap {value in
            guard let entry = value as? [String:Any],let status = entry["status"] as? [String:Any],status["status_str"] as? String == "success",
                  let prompt = entry["prompt"] as? [Any],prompt.count > 2,let graph = prompt[2] as? [String:Any],
                  let signature = signature(graph:graph),let workload = workload(graph:graph),let messages = status["messages"] as? [[Any]] else {return nil}
            func timestamp(_ name:String)->Double? {messages.first {$0.first as? String == name}.flatMap {$0.count > 1 ? (($0[1] as? [String:Any])?["timestamp"] as? NSNumber)?.doubleValue : nil}}
            guard let start = timestamp("execution_start"),let end = timestamp("execution_success"),end-start >= 10_000 else {return nil}
            // Fully cached executions are too fast to predict a new model render.
            let cached = messages.first {$0.first as? String == "execution_cached"}.flatMap {$0.count > 1 ? ($0[1] as? [String:Any])?["nodes"] as? [String] : nil} ?? []
            guard !cached.contains(where:{id in let type = (graph[id] as? [String:Any])?["class_type"] as? String;return type == "MissingMomentPinnedTake" || type == "LTX2MLXGenerate"}) else {return nil}
            return Self(signature:signature,pixelsFrames:workload,seconds:(end-start)/1000)
        }
    }
    static func estimate(graph:[String:Any],samples:[Self])->Double? {
        guard let signature = signature(graph:graph),let workload = workload(graph:graph) else {return nil}
        let matches = samples.filter {$0.signature == signature && $0.seconds.isFinite && $0.seconds >= 10 && $0.pixelsFrames > 0 && (0.25...4).contains(workload/$0.pixelsFrames)}
            .sorted {abs(log(workload/$0.pixelsFrames)) < abs(log(workload/$1.pixelsFrames))}.prefix(3)
        let predictions = matches.map {$0.seconds * workload/$0.pixelsFrames}.sorted()
        guard !predictions.isEmpty else {return nil}
        return predictions[predictions.count/2]
    }
}
