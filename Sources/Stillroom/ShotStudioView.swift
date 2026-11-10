import SwiftUI

private struct ReferenceInspection:Identifiable {
    let id = UUID()
    let image:NSImage
}

struct ShotStudioView:View {
    @EnvironmentObject var store:StudioStore
    @EnvironmentObject var lab:LocalGeneration
    @Environment(\.dismiss) private var dismiss
    let shotID:UUID
    let assetID:UUID
    let initialTakeID:UUID?
    let initialTab:Int
    @StateObject private var references = LocalReference()
    @State private var direction = ShotDirection()
    @State private var action = ""
    @State private var tab = 0
    @State private var selectedTakeID:UUID?
    @State private var selectedReferenceID:UUID?
    @State private var originalImage:NSImage?
    @State private var report:MotionSample?
    @State private var review = TakeReview()
    @State private var verdict = "Unreviewed"
    @State private var reviewMessage = ""
    @State private var inspecting:ReviewFrame?
    @State private var inspectedReference:ReferenceInspection?
    var source:MediaAsset? {store.project.assets.first {$0.id == assetID}}
    var shot:Shot? {store.project.shots.first {$0.id == shotID}}
    var takes:[MediaAsset] {source.map {store.project.takes(for:$0)} ?? []}
    var take:MediaAsset? {store.project.assets.first {$0.id == selectedTakeID}}
    var selectedReference:MediaAsset? {store.project.assets.first {$0.id == selectedReferenceID && $0.kind == .image}}
    var blocked:Bool {lab.busy || references.busy || lab.referenceBusy}
    var validRange:Bool {
        guard let take else {return false}
        return review.sourceIn.isFinite && review.sourceOut.isFinite && review.sourceIn >= 0 && review.sourceOut <= take.duration+0.001 && review.sourceOut-review.sourceIn >= 1.0/Double(store.project.fps)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Shot Studio").font(.system(size:25,weight:.medium,design:.rounded))
                    Text(shot?.name ?? "Select a shot").font(.system(size:12)).foregroundStyle(Ink.quiet)
                }
                Spacer()
                Text("Compose → Direct → Review → Edit").font(.system(size:11)).foregroundStyle(Ink.quiet).padding(.top,8)
                ToolButton(symbol:"xmark",help:"Close Shot Studio"){dismiss()}.disabled(references.busy)
            }
            TabView(selection:$tab) {
                directionPane.tabItem {Label("Direct",systemImage:"viewfinder")}.tag(0)
                referencePane.tabItem {Label("Reference",systemImage:"photo.on.rectangle")}.tag(1)
                reviewPane.tabItem {Label("Review & select",systemImage:"film.stack")}.tag(2)
            }
        }.padding(24).frame(width:1040,height:790).background(.regularMaterial).foregroundStyle(Ink.text)
        .interactiveDismissDisabled(references.busy)
        .popover(item:$inspectedReference) {value in Image(nsImage:value.image).resizable().scaledToFit().frame(width:840,height:480).padding(16)}
        .task {
            guard let source else {return}
            direction = source.direction ?? ShotDirection();action = source.regenerationDraft ?? ""
            selectedTakeID = takes.first(where:{$0.id == initialTakeID})?.id ?? takes.last?.id
            selectedReferenceID = source.referenceAssetID ?? (source.kind == .image ? source.id : nil)
            tab = initialTab
            if let reference = selectedReference {originalImage = await MediaEngine.thumbnail(store.url(reference),kind:.image)}
            else {originalImage = await MediaEngine.thumbnail(store.url(source),kind:source.kind,at:shot?.sourceIn ?? 0)}
        }
        .onChange(of:references.candidateID) {_,id in if let id {selectedReferenceID = id}}
    }
    private var directionPane:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack(alignment:.top,spacing:20) {
                    referencePicture(originalImage,label:"Starting reference").frame(width:250)
                    VStack(alignment:.leading,spacing:12) {
                        field("Story beat",text:$direction.purpose,prompt:"What changes for the person in this shot?")
                        Text("Action over time").font(.system(size:11,weight:.semibold))
                        TextEditor(text:$action).font(.system(size:12)).scrollContentBackground(.hidden).padding(7).frame(height:82).background(Ink.base,in:RoundedRectangle(cornerRadius:9)).accessibilityLabel("Shot action")
                        Text("Give the subject one clear action. Use the camera choice below for one continuous camera path.").font(.system(size:10)).foregroundStyle(Ink.quiet)
                    }
                }
                HStack(spacing:18) {
                    choice("Camera",selection:$direction.camera,items:ShotDirection.cameras)
                    choice("Framing",selection:$direction.framing,items:ShotDirection.framings)
                    choice("Light",selection:$direction.light,items:ShotDirection.lights)
                }
                field("Continuity",text:$direction.continuity,prompt:"What must remain consistent? For example: the laptop stays on the table.")
                field("Sound cue",text:$direction.sound,prompt:"For example: continuous rain, a quiet breath, then a page turning.")
                Text("Sound cues are production notes. Add recordings to the editor’s Voice, Room tone, Foley and Score lanes.").font(.system(size:10)).foregroundStyle(Ink.quiet)
                DisclosureGroup("See the motion prompt") {
                    Text(direction.motionPrompt(action:action)).font(.system(size:11)).foregroundStyle(Ink.quiet).textSelection(.enabled).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Ink.base,in:RoundedRectangle(cornerRadius:8))
                }.font(.system(size:11))
                HStack {
                    Button("Save direction"){saveDirection()}.disabled(blocked)
                    Spacer()
                    Button("Test motion · 3.4s Draft"){start(final:false)}.disabled(blocked || action.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("Render Cinema take"){start(final:true)}.buttonStyle(.borderedProminent).disabled(blocked || action.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Text("A Draft test checks action and continuity. Cinema renders a larger picture using the same direction. Review each result before replacing the edit.").font(.system(size:10)).foregroundStyle(Ink.quiet)
            }.padding(18)
        }
    }
    private var referencePane:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                HStack(alignment:.top,spacing:20) {
                    referencePicture(originalImage,label:"Current starting frame")
                    referencePicture(selectedReference.flatMap {store.thumbnails[$0.id]},label:"Reference to review")
                }
                HStack {
                    Picker("Reference",selection:$selectedReferenceID) {
                        Text("Choose an image").tag(nil as UUID?)
                        ForEach(store.project.assets.filter {$0.kind == .image}) {media in Text(media.name).tag(Optional(media.id))}
                    }.disabled(blocked)
                    Button("Use this reference"){useReference()}.disabled(blocked || selectedReference == nil)
                }
                field("Art direction",text:$direction.referenceDirection,prompt:"Describe the composition or lighting change for the starting image.").disabled(blocked)
                HStack {
                    Picker("Image model",selection:$references.modelID) {
                        if references.models.isEmpty {Text("Check local models").tag("")}
                        ForEach(references.models) {model in Text(model.name).tag(model.id)}
                    }.frame(maxWidth:300).disabled(blocked)
                    Picker("Reference detail",selection:$references.detail) {Text("Quick").tag(false);Text("Detail").tag(true)}.pickerStyle(.segmented).labelsHidden().frame(width:160).disabled(blocked)
                    Button("Check models"){Task {await references.discover()}}.disabled(blocked)
                    Spacer()
                    if references.busy {ProgressView().controlSize(.small);SwiftUI.TimelineView(.periodic(from:.now,by:1)) {context in Text(GenerationProgress.clock(context.date.timeIntervalSince(references.started ?? context.date))).font(.system(size:10,design:.monospaced))};Button("Cancel"){references.cancel()}}
                    else {Button("Create reference variation"){
                        guard let source,let shot else {return};saveDirection()
                        references.generate(source:source,shot:shot,direction:direction,store:store,lab:lab)
                    }.buttonStyle(.borderedProminent).disabled(blocked || direction.referenceDirection.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || references.modelID.isEmpty)}
                }
                Text(references.message).font(.system(size:11)).foregroundStyle(Ink.quiet).textSelection(.enabled)
                Text("Creates a separate image using installed local models. Check identity, hands and props, then approve the image as the next take’s first frame. Your current reference and edit stay in place until you choose one.").font(.system(size:10)).foregroundStyle(Ink.quiet)
            }.padding(18)
        }.onAppear {if references.models.isEmpty {Task {await references.discover()}}}
    }
    private var reviewPane:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("Take",selection:$selectedTakeID) {
                    Text("Choose a take").tag(nil as UUID?)
                    ForEach(Array(takes.enumerated()),id:\.element.id) {index,media in Text("Take \(index+1) · \(String(format:"%.2f",media.duration)) s · \(media.review)").tag(Optional(media.id))}
                }.frame(maxWidth:410)
                Spacer()
                if let take {Button("Play at 1×"){store.previewTake(take);dismiss()}.disabled(references.busy)}
            }
            if let take {
                HStack(alignment:.top,spacing:18) {
                    VStack(alignment:.leading,spacing:10) {
                        if let report {
                            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:6),count:3),spacing:8) {
                                ForEach(report.frames) {frame in
                                    Button {inspecting = frame} label:{
                                        VStack(alignment:.leading,spacing:3) {
                                            Image(nsImage:frame.image).resizable().aspectRatio(contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:5))
                                            Text(String(format:"%.2f s",frame.seconds)).font(.system(size:9,design:.monospaced)).foregroundStyle(Ink.quiet)
                                        }
                                    }.buttonStyle(.plain).accessibilityLabel("Inspect frame at \(String(format:"%.2f",frame.seconds)) seconds")
                                }
                            }
                            Text(report.summary).font(.system(size:10)).foregroundStyle(Ink.quiet)
                        } else if !reviewMessage.isEmpty {Text(reviewMessage).font(.system(size:12)).frame(maxWidth:.infinity,minHeight:350)}
                        else {ProgressView("Reading nine native frames…").frame(maxWidth:.infinity,minHeight:350)}
                        Text("Frame samples reveal visible problems; they cannot certify identity, hands or artistic quality. Play at 1× before marking a take Keep.").font(.system(size:10)).foregroundStyle(Ink.quiet)
                    }.frame(maxWidth:.infinity)
                    VStack(alignment:.leading,spacing:12) {
                        Text("Choose the usable moment").font(.system(size:12,weight:.semibold))
                        HStack {Text("In");TextField("In seconds",value:$review.sourceIn,format:.number.precision(.fractionLength(0...3)));Text("Out");TextField("Out seconds",value:$review.sourceOut,format:.number.precision(.fractionLength(0...3)))}.textFieldStyle(.roundedBorder).font(.system(size:11))
                        Text(validRange ? "\(String(format:"%.2f",review.sourceOut-review.sourceIn)) s selected of \(String(format:"%.2f",take.duration)) s" : "Choose an in/out range within this take.").font(.system(size:10)).foregroundStyle(validRange ? Ink.quiet : .orange)
                        Divider()
                        Toggle("Faces & identity checked",isOn:$review.faces)
                        Toggle("Hands checked",isOn:$review.hands)
                        Toggle("Objects & room checked",isOn:$review.props)
                        Toggle("Action & camera checked",isOn:$review.movement)
                        Picker("Verdict",selection:$verdict) {Text("Unreviewed").tag("Unreviewed");Text("Keep").tag("Keep");Text("Reject").tag("Reject")}
                        TextField("Review notes",text:$review.note,axis:.vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
                        Button("Save review"){saveReview()}.disabled(!validRange || blocked)
                        Divider()
                        Button("Use selection at 1×"){applyRange(keepTiming:false)}.buttonStyle(.borderedProminent).disabled(!validRange || blocked)
                        if let shot,validRange {
                            let speed = (review.sourceOut-review.sourceIn)/shot.duration
                            Button("Fit to shot · \(String(format:"%.2f",speed))×"){applyRange(keepTiming:true)}.disabled(blocked || !(0.1...4).contains(speed))
                        }
                        Text("Using 1× changes this shot’s length. Caption and sound positions stay fixed; review them after the picture edit.").font(.system(size:9)).foregroundStyle(Ink.quiet)
                        Text(reviewMessage).font(.system(size:10)).foregroundStyle(Ink.quiet)
                    }.font(.system(size:11)).frame(width:255)
                }
            } else {ContentUnavailableView("Generate a take first",systemImage:"film.stack",description:Text("Return to Direct to test the shot, then review the result here."))}
            Spacer(minLength:0)
        }.padding(18)
        .task(id:selectedTakeID) {
            report = nil;reviewMessage = ""
            guard let take else {return}
            review = take.takeReview ?? TakeReview(sourceOut:take.duration);verdict = take.review
            if review.sourceOut <= review.sourceIn {review.sourceIn = 0;review.sourceOut = take.duration}
            do {let value = try await MotionSample.read(store.url(take));try Task.checkCancellation();report = value}
            catch {if !Task.isCancelled {reviewMessage = error.localizedDescription}}
        }
        .popover(item:$inspecting) {frame in
            VStack(alignment:.leading,spacing:8) {Image(nsImage:frame.image).resizable().scaledToFit().frame(width:720,height:405);Text(String(format:"Native frame at %.3f s",frame.seconds)).font(.system(size:11,design:.monospaced))}.padding(16)
        }
    }
    private func saveDirection() {
        guard let index = store.project.assets.firstIndex(where:{$0.id == assetID}) else {return}
        store.change({$0.assets[index].direction = direction;$0.assets[index].regenerationDraft = action},rebuild:false)
        store.status = "Shot direction saved"
    }
    private func start(final:Bool) {
        saveDirection();lab.quality = final ? "Cinema" : "Draft"
        if !final {lab.durationSeconds = 3.375}
        // Reuse the reviewed seed for a controlled final comparison; never change
        // global seed locking just because the user renders a final take.
        lab.requestRegeneration(shotID:shotID,instructions:action,store:store,seedOverride:final ? take?.recipe?.seed : nil)
        dismiss()
    }
    private func useReference() {
        guard let reference = selectedReference,let index = store.project.assets.firstIndex(where:{$0.id == assetID}) else {return}
        saveDirection()
        store.change({$0.assets[index].referenceAssetID = reference.id},rebuild:false)
        lab.referenceID = reference.id
        references.message = "Reference selected for this shot’s next generation. The picture edit is unchanged."
    }
    private func saveReview() {
        guard let id = selectedTakeID,let index = store.project.assets.firstIndex(where:{$0.id == id}),validRange else {return}
        store.change({$0.assets[index].takeReview = review;$0.assets[index].review = verdict},rebuild:false)
        reviewMessage = "Review and selected range saved."
    }
    private func applyRange(keepTiming:Bool) {
        guard let take,validRange else {return};saveReview()
        store.useTake(take,for:shotID,keepTiming:keepTiming,sourceIn:review.sourceIn,sourceOut:review.sourceOut)
        dismiss()
    }
    private func field(_ title:String,text:Binding<String>,prompt:String)->some View {
        VStack(alignment:.leading,spacing:5) {Text(title).font(.system(size:11,weight:.semibold));TextField(prompt,text:text,axis:.vertical).lineLimit(1...3).textFieldStyle(.roundedBorder).font(.system(size:12))}
    }
    private func choice(_ title:String,selection:Binding<String>,items:[String])->some View {
        VStack(alignment:.leading,spacing:5) {Text(title).font(.system(size:11,weight:.semibold));Picker(title,selection:selection) {ForEach(items,id:\.self){Text($0).tag($0)}}.labelsHidden()}.frame(maxWidth:.infinity)
    }
    private func referencePicture(_ image:NSImage?,label:String)->some View {
        VStack(alignment:.leading,spacing:6) {
            if let image {Button {inspectedReference = ReferenceInspection(image:image)} label:{Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:.infinity).frame(height:170).background(Ink.base,in:RoundedRectangle(cornerRadius:10))}.buttonStyle(.plain).accessibilityLabel("Inspect " + label)}
            else {Image(systemName:"photo").font(.system(size:30,weight:.ultraLight)).foregroundStyle(Ink.quiet).frame(maxWidth:.infinity).frame(height:170).background(Ink.base,in:RoundedRectangle(cornerRadius:10))}
            Text(label).font(.system(size:10)).foregroundStyle(Ink.quiet)
        }
    }
}
