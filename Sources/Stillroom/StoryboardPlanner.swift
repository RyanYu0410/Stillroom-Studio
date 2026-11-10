import SwiftUI

@MainActor
final class StoryboardPlanner:ObservableObject {
    @Published var busy = false
    @Published var message = "Start with a premise, then create and edit the shot cards."
    @Published var draft:Storyboard?
    @Published var started:Date?
    @Published var shotCount = 9
    private var work:Task<Void,Never>?
    static func schema(count:Int)->[String:Any] {
        let strings = ["title","indicator","beat","action","narration","sound"]
        var fields = Dictionary(uniqueKeysWithValues:strings.map {($0,["type":"string"] as [String:Any])})
        fields["camera"] = ["type":"string","enum":ShotDirection.cameras]
        fields["framing"] = ["type":"string","enum":ShotDirection.framings]
        fields["duration"] = ["type":"number","minimum":2,"maximum":20]
        return ["type":"object","additionalProperties":false,"required":["title","cards"],"properties":["title":["type":"string"],"cards":["type":"array","minItems":count,"maxItems":count,"items":["type":"object","additionalProperties":false,"required":Array(fields.keys).sorted(),"properties":fields]]]]
    }
    func generate(store:StudioStore) {
        let lab = store.generation,assistant = store.assistant
        guard !busy,!lab.busy,!lab.referenceBusy,!store.blender.busy,let board = store.project.storyboard,!board.premise.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,let model = assistant.models.first(where:{$0.id == assistant.modelID}) else {return}
        let document = store.documentID,count = shotCount
        busy = true;lab.referenceBusy = true;started = Date();draft = nil;message = "Drafting the story, shot by shot…"
        work = Task {
            defer {busy = false;lab.referenceBusy = false}
            do {
                if let queue = try? await lab.json("queue"),!(queue["queue_running"] as? [[Any]] ?? []).isEmpty {throw StudioError.message("Let the local video render finish before drafting a storyboard.")}
                let system = """
                You are a concise film director and storyboard writer. Turn a premise into a coherent short film with a clear beginning, escalation and ending. Return only JSON with title and cards. Use exactly \(count) cards. Each card needs title, indicator, beat, action, camera, framing, narration, sound, duration. Use a specific visible action and a single camera move. Keep recurring characters and locations consistent. Give each shot a purpose and connect shots with match cuts or continuous sound. Narration should be conversational, sparse and fit its shot at 2 words/second with room to breathe. Do not put camera notes into narration. Indicators are short optional on-screen labels. Do not claim you generated footage or sound. The film is made with local image models, short AI motion takes and optional small Blender inserts. Avoid demanding long, complicated action or exact readable text inside generated images. For mathematical premises, check the sequence and make the baseline explicit. Camera must be an allowed value; framing must be an allowed value. All durations are between 2 and 20 seconds.
                """
                let user = "Premise: \(board.premise)\nVisual style: \(board.look)\nContinuity: \(board.continuity)\nAllowed cameras: \(ShotDirection.cameras.joined(separator:", "))\nAllowed framing: \(ShotDirection.framings.joined(separator:", "))\nWrite exactly \(count) cards."
                let reply = try await assistant.structuredReply(system:system,user:user,schema:Self.schema(count:count),model:model,maxTokens:6000)
                try Task.checkCancellation()
                struct Draft:Decodable {let title:String;let cards:[StoryboardCard]}
                let response = try JSONDecoder().decode(Draft.self,from:Data(reply.utf8))
                var result = board;result.title = response.title;result.cards = response.cards
                try result.validated()
                guard result.cards.count == count else {throw StudioError.message("The local model did not return the requested number of cards. Try again.")}
                guard store.documentID == document,store.project.storyboard == board else {throw StudioError.message("The storyboard changed while drafting. Your current cards were kept; draft again with the new premise.")}
                draft = result;message = "Draft ready · review it before replacing the board"
            } catch {message = Task.isCancelled ? "Draft cancelled. Your board is unchanged." : error.localizedDescription}
        }
    }
    func cancel() {work?.cancel()}
}
