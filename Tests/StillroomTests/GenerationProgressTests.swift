import XCTest
@testable import Stillroom

final class GenerationProgressTests:XCTestCase {
    private func graph(frames:Int = 81,model:String = "local/weights",seed:Int = 1)->[String:Any] {
        ["2":["class_type":"LTX2MLXModelLoader","inputs":["custom_model_dir":model,"pipeline_type":"distilled"]],
         "3":["class_type":"MissingMomentPinnedTake","inputs":["width":1024,"height":576,"num_frames":frames,"seed":seed,"prompt":"Motion","pipeline":["2",0]]]]
    }
    func testQueueTimeDoesNotConsumeRenderEstimateAndCompletionIsReal() {
        let start = Date(timeIntervalSince1970:1000)
        var progress = GenerationProgress(started:start,expectedSeconds:120)
        progress.stage = .queued
        XCTAssertNil(progress.fraction(at:start.addingTimeInterval(300)))
        progress.rendering(at:start.addingTimeInterval(300))
        XCTAssertEqual(progress.elapsed(at:start.addingTimeInterval(360)),360)
        XCTAssertEqual(progress.renderElapsed(at:start.addingTimeInterval(360)),60)
        let values = stride(from:0.0,through:1000,by:10).map {progress.fraction(at:start.addingTimeInterval(300+$0))!}
        XCTAssertEqual(values,values.sorted());XCTAssertTrue(values.allSatisfy {$0 < 0.95})
        XCTAssertTrue(progress.remaining(at:start.addingTimeInterval(800)).contains("longer than estimated"))
        progress.stage = .finishing
        XCTAssertEqual(progress.fraction(at:start),0.97)
        progress.finish(.ready,at:start.addingTimeInterval(900))
        XCTAssertEqual(progress.fraction(at:start),1);XCTAssertEqual(progress.elapsed(at:start.addingTimeInterval(2000)),900)
    }
    func testOnlyMatchingEngineWorkflowSettingsPredictAndWorkloadScales() throws {
        let original = graph()
        let signature = try XCTUnwrap(GenerationTimingSample.signature(graph:original))
        let workload = try XCTUnwrap(GenerationTimingSample.workload(graph:original))
        let samples = [GenerationTimingSample(signature:signature,pixelsFrames:workload,seconds:240)]
        XCTAssertEqual(GenerationTimingSample.estimate(graph:graph(seed:42),samples:samples),240)
        XCTAssertEqual(try XCTUnwrap(GenerationTimingSample.estimate(graph:graph(frames:161),samples:samples)),240*161/81,accuracy:0.001)
        XCTAssertNil(GenerationTimingSample.estimate(graph:graph(model:"different/weights"),samples:samples))
        XCTAssertNil(GenerationTimingSample.estimate(graph:graph(frames:1000),samples:samples))
        XCTAssertNil(GenerationTimingSample.estimate(graph:["1":["class_type":"CustomNode","inputs":[:]]],samples:samples))
    }
    func testHistoryUsesExecutionTimestampsAndRejectsFailedOrCachedModelRuns() {
        func entry(_ status:String = "success",cached:[String] = ["2"])->[String:Any] {
            ["prompt":[0,"job",graph()],"status":["status_str":status,"messages":[
                ["execution_start",["timestamp":100_000]],
                ["execution_cached",["nodes":cached]],
                ["execution_success",["timestamp":340_000]]]]]
        }
        let samples = GenerationTimingSample.fromHistory(["good":entry(),"bad":entry("error"),"cached":entry(cached:["2","3"])])
        XCTAssertEqual(samples.count,1);XCTAssertEqual(samples.first?.seconds,240)
    }
    func testUnknownAndCancelledNeverPretendToComplete() {
        var progress = GenerationProgress()
        progress.rendering()
        XCTAssertNil(progress.fraction(at:Date()))
        XCTAssertTrue(progress.remaining(at:Date()).contains("unavailable"))
        progress.finish(.cancelled)
        XCTAssertFalse(progress.active);XCTAssertNil(progress.fraction(at:Date()))
    }
}
