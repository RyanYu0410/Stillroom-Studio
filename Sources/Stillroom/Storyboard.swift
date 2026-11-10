import Foundation

struct StoryboardCard:Identifiable,Codable,Equatable {
    var id = UUID()
    var title = "New shot"
    var indicator = ""
    var beat = ""
    var action = ""
    var openingFrame = ""
    var camera = "From prompt"
    var framing = "Keep reference"
    var narration = ""
    var sound = ""
    var duration:Double = 6
    var frameAssetID:UUID?
    var takeAssetID:UUID?
    enum CodingKeys:String,CodingKey {case id,title,indicator,beat,action,openingFrame,camera,framing,narration,sound,duration,frameAssetID,takeAssetID}
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID()
        title = try c.decodeIfPresent(String.self,forKey:.title) ?? "New shot"
        indicator = try c.decodeIfPresent(String.self,forKey:.indicator) ?? ""
        beat = try c.decodeIfPresent(String.self,forKey:.beat) ?? ""
        action = try c.decodeIfPresent(String.self,forKey:.action) ?? ""
        openingFrame = try c.decodeIfPresent(String.self,forKey:.openingFrame) ?? ""
        camera = try c.decodeIfPresent(String.self,forKey:.camera) ?? "From prompt"
        framing = try c.decodeIfPresent(String.self,forKey:.framing) ?? "Keep reference"
        narration = try c.decodeIfPresent(String.self,forKey:.narration) ?? ""
        sound = try c.decodeIfPresent(String.self,forKey:.sound) ?? ""
        duration = try c.decodeIfPresent(Double.self,forKey:.duration) ?? 6
        frameAssetID = try c.decodeIfPresent(UUID.self,forKey:.frameAssetID)
        takeAssetID = try c.decodeIfPresent(UUID.self,forKey:.takeAssetID)
    }
}

struct Storyboard:Identifiable,Codable,Equatable {
    var id = UUID()
    var title = "Untitled storyboard"
    var premise = ""
    var look = "Cinematic, natural light, considered composition, one consistent visual style."
    var continuity = "Keep the same characters, wardrobe, locations and key objects between shots."
    var referenceAssetID:UUID?
    var cards:[StoryboardCard] = []
    var duration:Double {cards.reduce(0){$0+$1.duration}}
    func validated() throws {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count <= 200,premise.count <= 6000,look.count <= 3000,continuity.count <= 3000,cards.count <= 32,Set(cards.map(\.id)).count == cards.count else {throw StudioError.message("The storyboard needs a title, unique cards and at most 32 shots.")}
        for card in cards {
            guard card.duration.isFinite,(1...60).contains(card.duration),card.title.count <= 200,card.indicator.count <= 100,card.beat.count <= 2000,card.action.count <= 3000,card.openingFrame.count <= 3000,card.narration.count <= 2000,card.sound.count <= 1000,ShotDirection.cameras.contains(card.camera),ShotDirection.framings.contains(card.framing) else {throw StudioError.message("Check the storyboard card’s duration, text and camera choices.")}
        }
    }
    func direction(for card:StoryboardCard)->ShotDirection {
        ShotDirection(purpose:card.beat,camera:card.camera,framing:card.framing,continuity:continuity,sound:card.sound,referenceDirection:card.action)
    }
    func framePrompt(for card:StoryboardCard,hasReference:Bool)->String {
        """
        Create one finished cinematic storyboard frame, a single uninterrupted image without panels, captions, typography, logos or watermarks.
        Visual style: \(look)
        Continuity: \(continuity)
        Shot: \(card.title). \(card.beat)
        Opening pose: \(card.openingFrame.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? card.action : card.openingFrame)
        Composition: \(card.framing). Depict only one instant at the beginning of this shot. Each subject appears once, in one pose; do not combine successive stages of movement into the image.
        \(hasReference ? "The supplied image is the character and setting reference. Keep recognizable identity, markings, clothing and materials while composing the requested new shot." : "Establish a specific, memorable subject and setting that can remain consistent in the rest of the film.")
        """
    }
    func outline()->String {
        var lines = ["# "+title,"",premise,"","Visual style: "+look,"Continuity: "+continuity,""]
        for (i,c) in cards.enumerated() {
            lines += ["## \(i+1). \(c.title) · \(String(format:"%.2f",c.duration)) s",c.indicator,"Beat: "+c.beat,"Opening frame: "+c.openingFrame,"Action: "+c.action,"Camera: \(c.camera) · \(c.framing)","Narration: "+c.narration,"Sound: "+c.sound,""]
        }
        return lines.joined(separator:"\n")
    }
}

extension FilmProject {
    mutating func assembleStoryboard() throws {
        var copy = self
        try copy.buildStoryboardEdit()
        self = copy
    }
    private mutating func buildStoryboardEdit() throws {
        guard let board = storyboard,!board.cards.isEmpty else {throw StudioError.message("Add storyboard cards first.")}
        try board.validated()
        // A rebuild replaces only a picture edit previously made from this board.
        // Unrelated edits and sound recordings are never silently overwritten.
        let ids = Set(board.cards.map(\.id))
        guard shots.isEmpty || shots.allSatisfy({ids.contains($0.id)}),sounds.isEmpty else {throw StudioError.message("This film already has an independent edit or sound mix. Start a new film to build a different storyboard, or continue editing the linked shots in the timeline.")}
        var next:[Shot] = [],cues:[Subtitle] = [],at = 0.0
        for card in board.cards {
            guard let asset = assets.first(where:{$0.id == (card.takeAssetID ?? card.frameAssetID)}),[.image,.video].contains(asset.kind) else {throw StudioError.message("Choose a reference frame or take for “\(card.title)” before building the timeline.")}
            let duration = (card.duration*Double(fps)).rounded()/Double(fps)
            let sourceLength = asset.kind == .image ? duration : asset.duration
            let rate = asset.kind == .image ? 1 : sourceLength/duration
            guard sourceLength > 0,(0.1...4).contains(rate) else {throw StudioError.message("The selected take cannot fill “\(card.title)” at a supported speed.")}
            next.append(Shot(id:card.id,assetID:asset.id,name:card.title,sourceDuration:sourceLength,speed:rate,note:card.narration,indicator:card.indicator.isEmpty ? nil : card.indicator))
            let sentences = card.narration.split(whereSeparator:{$0 == "\n"}).map(String.init).filter {!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
            if !sentences.isEmpty {
                let words = sentences.map {max(1,$0.split(separator:" ").count)},total = Double(words.reduce(0,+))
                var cursor = at
                for (text,weight) in zip(sentences,words) {
                    let end = cursor+duration*Double(weight)/total
                    cues.append(Subtitle(start:cursor,end:end,text:text));cursor = end
                }
            }
            if let i = assets.firstIndex(where:{$0.id == asset.id}) {
                assets[i].direction = board.direction(for:card);assets[i].regenerationDraft = card.action
                if let frame = card.frameAssetID,frame != asset.id {assets[i].referenceAssetID = frame}
            }
            at += duration
        }
        shots = next;subtitles = cues;name = board.title;brief = board.premise
    }
}
