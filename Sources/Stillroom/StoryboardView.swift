import SwiftUI
import UniformTypeIdentifiers

struct StoryboardView:View {
    @EnvironmentObject var store:StudioStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var planner = StoryboardPlanner()
    @StateObject private var images = LocalReference()
    @State private var selected:UUID?
    @State private var planning = true
    @State private var dragged:UUID?
    @State private var message = ""
    @State private var motionLength:Double = 5
    @State private var motionQuality = "Balanced"
    var board:Storyboard {store.project.storyboard ?? Storyboard()}
    var card:StoryboardCard? {board.cards.first {$0.id == selected}}
    var blocked:Bool {planner.busy || images.busy || store.generation.busy || store.generation.referenceBusy || store.blender.busy}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            header
            DisclosureGroup("Film premise & AI draft",isExpanded:$planning) {planningPane.padding(.top,8)}.font(.system(size:12,weight:.medium))
            Divider()
            HStack(alignment:.top,spacing:18) {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        SmallLabel(text:"Shot cards")
                        Text("\(board.cards.count) · \(String(format:"%.1f",board.duration)) seconds").font(.system(size:10)).foregroundStyle(Ink.quiet)
                        Spacer()
                        Button {add()} label:{Label("Add shot",systemImage:"plus")}.disabled(blocked)
                    }
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.flexible(),spacing:12),GridItem(.flexible(),spacing:12)],spacing:14) {
                            ForEach(Array(board.cards.enumerated()),id:\.element.id) {index,item in tile(item,index:index)}
                        }.padding(3)
                        if board.cards.isEmpty {ContentUnavailableView("Build the story before the edit",systemImage:"rectangle.on.rectangle.angled",description:Text("Draft cards with the local AI, add a shot, or start from the current timeline."))}
                    }
                    HStack {
                        Text(message.isEmpty ? planner.message : message).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(2)
                        Spacer()
                        Button("Build timeline"){assemble()}.buttonStyle(.borderedProminent).disabled(blocked || board.cards.isEmpty)
                    }
                }.frame(maxWidth:.infinity)
                Divider()
                inspector.frame(width:355)
            }.frame(maxHeight:.infinity)
        }.padding(24).frame(width:1120,height:840).background(.regularMaterial)
        .interactiveDismissDisabled(blocked)
        .task {
            if store.project.storyboard == nil {var b = Storyboard();b.title = store.project.name;b.premise = store.project.brief;store.change({$0.storyboard = b},rebuild:false)}
            selected = board.cards.first?.id
            await store.assistant.discover();await images.discover()
        }
        .sheet(item:$planner.draft) {draft in
            VStack(alignment:.leading,spacing:16) {
                Text("Review the AI draft").font(.system(size:23,weight:.medium,design:.rounded))
                Text(draft.title).font(.system(size:14,weight:.semibold))
                ScrollView {VStack(alignment:.leading,spacing:14) {ForEach(Array(draft.cards.enumerated()),id:\.element.id) {i,c in
                    VStack(alignment:.leading,spacing:5) {Text("\(i+1). \(c.title) · \(String(format:"%.1f",c.duration)) s").font(.system(size:13,weight:.semibold));Text(c.beat);Text(c.action).foregroundStyle(Ink.quiet);Text("Narration: "+c.narration);if !c.indicator.isEmpty {Text("Label: "+c.indicator).foregroundStyle(Ink.mint)}}.font(.system(size:11)).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Ink.base,in:RoundedRectangle(cornerRadius:10))
                }}}
                HStack {Button("Keep current board"){planner.draft = nil};Spacer();Button("Use this draft"){store.change({$0.storyboard = draft},rebuild:false);selected = draft.cards.first?.id;planner.draft = nil;planning = false;message = "AI draft adopted. Edit the cards, then create or attach reference frames."}.buttonStyle(.borderedProminent)}
            }.padding(24).frame(width:800,height:720)
        }
    }
    private var header:some View {
        HStack(alignment:.top) {
            VStack(alignment:.leading,spacing:4) {Text("Storyboard").font(.system(size:25,weight:.medium,design:.rounded));Text("Premise → Cards → Frames → Motion → Edit").font(.system(size:11)).foregroundStyle(Ink.quiet)}
            Spacer()
            if store.generation.busy {Button("Cancel motion"){store.generation.cancel()}.font(.system(size:11))}
            Menu("Board") {
                Button("Import storyboard…"){importBoard()}.disabled(blocked)
                Button("Export storyboard JSON…"){exportBoard(outline:false)}
                Button("Export shot list…"){exportBoard(outline:true)}
                Divider()
                Button("From current timeline"){fromTimeline()}.disabled(blocked || store.project.shots.isEmpty)
            }.frame(width:100)
            ToolButton(symbol:"xmark",help:"Close storyboard"){dismiss()}.disabled(blocked)
        }
    }
    private var planningPane:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:5) {
                    TextField("Film title",text:boardValue(\.title)).textFieldStyle(.roundedBorder).accessibilityLabel("Storyboard title")
                    TextEditor(text:boardValue(\.premise)).font(.system(size:12)).scrollContentBackground(.hidden).padding(7).frame(height:65).background(Ink.base,in:RoundedRectangle(cornerRadius:8)).accessibilityLabel("Storyboard premise")
                }
                VStack(alignment:.leading,spacing:8) {
                    TextField("Visual style",text:boardValue(\.look),axis:.vertical).lineLimit(1...2).textFieldStyle(.roundedBorder).accessibilityLabel("Storyboard visual style")
                    TextField("Character and setting continuity",text:boardValue(\.continuity),axis:.vertical).lineLimit(1...2).textFieldStyle(.roundedBorder).accessibilityLabel("Storyboard continuity")
                }.frame(width:470)
            }.disabled(blocked)
            HStack {
                Picker("Chat model",selection:Binding(get:{store.assistant.modelID},set:{store.assistant.modelID = $0})) {if store.assistant.models.isEmpty {Text("Check models").tag("")};ForEach(store.assistant.models) {model in Text(model.name).tag(model.id)}}.frame(width:270)
                Stepper("\(planner.shotCount) shots",value:$planner.shotCount,in:3...16).frame(width:140)
                Button("Check models"){Task {await store.assistant.discover()}}
                Spacer()
                if planner.busy {ProgressView().controlSize(.small);Button("Cancel draft"){planner.cancel()}}
                else {Button("Draft with local AI"){message = "";planner.generate(store:store)}.buttonStyle(.borderedProminent).disabled(store.assistant.modelID.isEmpty || board.premise.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
            }.font(.system(size:11)).disabled(blocked && !planner.busy)
            if planner.busy {SwiftUI.TimelineView(.periodic(from:.now,by:1)) {value in Text(planner.message+" · "+GenerationProgress.clock(value.date.timeIntervalSince(planner.started ?? value.date))).font(.system(size:10)).foregroundStyle(Ink.quiet)}}
        }
    }
    private func tile(_ item:StoryboardCard,index:Int)->some View {
        VStack(alignment:.leading,spacing:7) {
            ZStack(alignment:.topLeading) {
                if let id = item.takeAssetID ?? item.frameAssetID,let image = store.thumbnails[id] {Image(nsImage:image).resizable().scaledToFill().frame(height:125).clipped()}
                else {Rectangle().fill(Ink.raised).frame(height:125).overlay(Image(systemName:"viewfinder").font(.system(size:24,weight:.ultraLight)).foregroundStyle(Ink.quiet))}
                Text(String(format:"%02d",index+1)).font(.system(size:10,weight:.medium,design:.monospaced)).foregroundStyle(.white).padding(6).background(.black.opacity(0.6),in:RoundedRectangle(cornerRadius:5)).padding(7)
            }.clipShape(RoundedRectangle(cornerRadius:9))
            HStack {Text(item.title).font(.system(size:12,weight:.semibold)).lineLimit(1);Spacer();Text(String(format:"%.1fs",item.duration)).font(.system(size:10,design:.monospaced)).foregroundStyle(Ink.quiet)}
            if !item.indicator.isEmpty {Text(item.indicator).font(.system(size:10,weight:.medium)).foregroundStyle(Ink.mint)}
            Text(item.beat.isEmpty ? "Describe what changes in this shot." : item.beat).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(2).frame(height:27,alignment:.topLeading)
        }.padding(10).background(Ink.base,in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(selected == item.id ? Ink.mint : .clear,lineWidth:2)).contentShape(Rectangle())
        .onTapGesture {selected = item.id}
        .onDrag {dragged = item.id;return NSItemProvider(object:item.id.uuidString as NSString)}
        .onDrop(of:[UTType.text],isTargeted:nil) {_ in guard !blocked,let dragged,dragged != item.id else {return false};reorder(dragged,before:item.id);self.dragged = nil;return true}
        .accessibilityElement(children:.combine).accessibilityLabel("Shot \(index+1), \(item.title), \(item.indicator), \(String(format:"%.1f",item.duration)) seconds")
    }
    private var inspector:some View {
        ScrollView {
            if let card {
                VStack(alignment:.leading,spacing:11) {
                    HStack {SmallLabel(text:"Selected shot");Spacer();Button {duplicate(card)} label:{Image(systemName:"plus.square.on.square")}.help("Duplicate storyboard card").disabled(blocked);Button {remove(card)} label:{Image(systemName:"trash")}.help("Remove storyboard card").disabled(blocked)}
                    TextField("Shot title",text:cardValue(\.title,fallback:"")).textFieldStyle(.roundedBorder).disabled(blocked)
                    HStack {Text("Duration");TextField("Seconds",value:cardValue(\.duration,fallback:6),format:.number.precision(.fractionLength(0...2))).frame(width:65).textFieldStyle(.roundedBorder);Text("s");Spacer();moveButton(card,offset:-1);moveButton(card,offset:1)}.font(.system(size:11)).disabled(blocked)
                    field("On-screen indicator",\.indicator,"For example: Day 3 · 8×")
                    field("Story beat",\.beat,"What changes in this shot?")
                    field("Visible action",\.action,"One clear action over time.")
                    HStack {
                        Picker("Camera",selection:cardValue(\.camera,fallback:"From prompt")) {ForEach(ShotDirection.cameras,id:\.self){Text($0).tag($0)}}
                        Picker("Framing",selection:cardValue(\.framing,fallback:"Keep reference")) {ForEach(ShotDirection.framings,id:\.self){Text($0).tag($0)}}
                    }.font(.system(size:10)).disabled(blocked)
                    field("Narration / small subtitles",\.narration,"Spoken words. Put separate subtitle cues on separate lines.")
                    field("Sound cue",\.sound,"Room tone, foley or a purposeful pause.")
                    Divider()
                    frameControls(card)
                    Divider()
                    motionControls(card)
                }.font(.system(size:12)).id(card.id)
            } else {ContentUnavailableView("Select a card",systemImage:"rectangle.on.rectangle",description:Text("Edit its purpose, action, camera, timing and narration here."))}
        }
    }
    private func frameControls(_ card:StoryboardCard)->some View {
        VStack(alignment:.leading,spacing:8) {
            SmallLabel(text:"Reference frame")
            Picker("Card frame",selection:cardValue(\.frameAssetID,fallback:nil)) {Text("Choose a frame").tag(nil as UUID?);ForEach(store.project.assets.filter {$0.kind == .image}) {media in Text(media.name).tag(Optional(media.id))}}.font(.system(size:11)).disabled(blocked)
            Picker("Continuity reference",selection:boardValue(\.referenceAssetID)) {Text("No image reference yet").tag(nil as UUID?);ForEach(store.project.assets.filter {$0.kind == .image}) {media in Text(media.name).tag(Optional(media.id))}}.font(.system(size:11)).disabled(blocked)
            Picker("Image model",selection:$images.modelID) {if images.models.isEmpty {Text("Check image models").tag("")};ForEach(images.models) {model in Text(model.name).tag(model.id)}}.font(.system(size:11)).disabled(blocked)
            HStack {
                Picker("Frame detail",selection:$images.detail) {Text("Quick").tag(false);Text("Detail").tag(true)}.pickerStyle(.segmented).labelsHidden().frame(width:130).disabled(blocked)
                Button("Check"){Task {await images.discover()}}.disabled(blocked)
                Spacer()
                if images.busy {ProgressView().controlSize(.small);Button("Cancel"){images.cancel()}}
                else {Button("Create frame"){images.createStoryboardFrame(cardID:card.id,store:store)}.disabled(blocked || images.modelID.isEmpty || card.action.isEmpty)}
            }.font(.system(size:10))
            Text(images.message).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(3)
        }
    }
    private func motionControls(_ card:StoryboardCard)->some View {
        let shot = store.project.shots.first {$0.id == card.id}
        let source = shot.flatMap {s in store.project.assets.first {$0.id == s.assetID}}
        let take = source.flatMap {store.project.takes(for:$0).last}
        return VStack(alignment:.leading,spacing:8) {
            SmallLabel(text:"Motion take")
            HStack {
                TextField("Motion seconds",value:$motionLength,format:.number.precision(.fractionLength(0...2))).frame(width:60).textFieldStyle(.roundedBorder).accessibilityLabel("Storyboard motion length")
                Text("s")
                Picker("Motion quality",selection:$motionQuality) {Text("Draft").tag("Draft");Text("Balanced").tag("Balanced");Text("Cinema").tag("Cinema")}.labelsHidden()
                Button("Generate motion"){
                    guard let shot else {return}
                    if let i = store.project.assets.firstIndex(where:{$0.id == shot.assetID}) {let direction = board.direction(for:card);store.change({$0.assets[i].direction = direction;if let frame = card.frameAssetID,frame != shot.assetID {$0.assets[i].referenceAssetID = frame}},rebuild:false)}
                    store.generation.quality = motionQuality;store.generation.durationSeconds = motionLength;store.generation.requestRegeneration(shotID:shot.id,instructions:card.action,store:store)
                }.disabled(blocked || shot == nil || !(1...10).contains(motionLength) || card.action.isEmpty)
            }.font(.system(size:10)).disabled(blocked)
            if store.generation.busy,store.generation.targetShotID == card.id,let progress = store.generation.progress {GenerationProgressView(progress:progress)}
            if let take,let shot {
                HStack {
                    Button("Review latest take"){store.previewTake(take);dismiss()}
                    Button("Use take · fit timing"){store.useTake(take,for:shot.id,keepTiming:true);updateCard {c in c.takeAssetID = take.id};message = "Motion take applied to this shot; the edit’s timing is preserved."}.disabled(blocked)
                }.font(.system(size:10))
            }
            Text(shot == nil ? "Build the timeline after attaching a frame to each card, then generate motion here." : "Motion creates a separate candidate. Fitting a short take to a long card slows it down. Review before using.").font(.system(size:10)).foregroundStyle(Ink.quiet)
            if store.generation.targetShotID == card.id {Text(store.generation.message).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(3)}
        }
    }
    private func boardValue<T>(_ path:WritableKeyPath<Storyboard,T>)->Binding<T> {Binding(get:{board[keyPath:path]},set:{value in store.change({$0.storyboard?[keyPath:path] = value},rebuild:false)})}
    private func cardValue<T>(_ path:WritableKeyPath<StoryboardCard,T>,fallback:T)->Binding<T> {Binding(get:{card?[keyPath:path] ?? fallback},set:{value in updateCard {$0[keyPath:path] = value}})}
    private func updateCard(_ action:(inout StoryboardCard)->Void) {guard let selected,let i = board.cards.firstIndex(where:{$0.id == selected}) else {return};store.change({if $0.storyboard != nil {action(&$0.storyboard!.cards[i])}},rebuild:false)}
    private func field(_ title:String,_ path:WritableKeyPath<StoryboardCard,String>,_ placeholder:String)->some View {VStack(alignment:.leading,spacing:4) {Text(title).font(.system(size:10,weight:.medium)).foregroundStyle(Ink.quiet);TextField(placeholder,text:cardValue(path,fallback:""),axis:.vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).disabled(blocked)}}
    private func add() {var item = StoryboardCard();item.title = "Shot \(board.cards.count+1)";store.change({$0.storyboard?.cards.append(item)},rebuild:false);selected = item.id;planning = false}
    private func duplicate(_ card:StoryboardCard) {guard board.cards.count < 32,let i = board.cards.firstIndex(where:{$0.id == card.id}) else {return};var next = card;next.id = UUID();next.title += " · copy";next.takeAssetID = nil;store.change({$0.storyboard?.cards.insert(next,at:i+1)},rebuild:false);selected = next.id}
    private func remove(_ card:StoryboardCard) {store.change({$0.storyboard?.cards.removeAll {$0.id == card.id}},rebuild:false);selected = board.cards.first?.id}
    private func reorder(_ id:UUID,before target:UUID) {store.change({p in guard let i = p.storyboard?.cards.firstIndex(where:{$0.id == id}) else {return};let item = p.storyboard!.cards.remove(at:i);let j = p.storyboard!.cards.firstIndex(where:{$0.id == target}) ?? p.storyboard!.cards.endIndex;p.storyboard!.cards.insert(item,at:j)},rebuild:false)}
    private func moveButton(_ card:StoryboardCard,offset:Int)->some View {Button {guard let i = board.cards.firstIndex(where:{$0.id == card.id}),board.cards.indices.contains(i+offset) else {return};store.change({$0.storyboard?.cards.swapAt(i,i+offset)},rebuild:false)} label:{Image(systemName:offset < 0 ? "arrow.left" : "arrow.right")}.disabled(blocked)}
    private func assemble() {do {var copy = store.project;try copy.assembleStoryboard();store.change {$0 = copy};store.refreshMedia();message = "Timeline built from the board. Subtitle timing is provisional until narration is recorded.";if let shot = store.project.shots.first {store.selectShot(shot)}} catch {message = error.localizedDescription}}
    private func fromTimeline() {
        var next = Storyboard();next.title = store.project.name;next.premise = store.project.brief
        next.cards = store.project.shots.map {s in let a = store.project.assets.first {$0.id == s.assetID};var c = StoryboardCard();c.id = s.id;c.title = s.name;c.indicator = s.indicator ?? "";c.duration = s.duration;c.narration = s.note;c.beat = a?.direction?.purpose ?? "";c.action = a?.regenerationDraft ?? "";c.camera = a?.direction?.camera ?? "From prompt";c.framing = a?.direction?.framing ?? "Keep reference";c.sound = a?.direction?.sound ?? "";c.frameAssetID = a?.kind == .image ? a?.id : a?.referenceAssetID;c.takeAssetID = a?.kind == .video ? a?.id : nil;return c}
        store.change({$0.storyboard = next},rebuild:false);selected = next.cards.first?.id;planning = false
    }
    private func importBoard() {let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.begin {response in guard response == .OK,let url = panel.url else {return};Task {@MainActor in do {let next = try JSONDecoder().decode(Storyboard.self,from:Data(contentsOf:url));try next.validated();store.change({$0.storyboard = next},rebuild:false);selected = next.cards.first?.id;planning = false;message = "Storyboard imported; the picture edit is unchanged."} catch {message = error.localizedDescription}}}}
    private func exportBoard(outline:Bool) {let panel = NSSavePanel();panel.nameFieldStringValue = board.title+(outline ? ".md" : ".json");let snapshot = board;panel.begin {response in guard response == .OK,let url = panel.url else {return};do {if outline {try snapshot.outline().write(to:url,atomically:true,encoding:.utf8)} else {let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];try encoder.encode(snapshot).write(to:url,options:.atomic)}} catch {Task {@MainActor in message = error.localizedDescription}}}}
}
