import SwiftUI

struct GenerationLengthControl:View {
    @EnvironmentObject var lab:LocalGeneration
    var body:some View {
        HStack(spacing:4) {
            Text("Length").foregroundStyle(.secondary)
            TextField("Seconds",value:$lab.durationSeconds,format:.number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width:46).multilineTextAlignment(.trailing)
                .accessibilityLabel("Generated clip length in seconds")
                .onSubmit {lab.durationSeconds = min(10,max(1,lab.durationSeconds));lab.saveSettings()}
            Text("s").foregroundStyle(.secondary)
            Stepper("Length",value:$lab.durationSeconds,in:GenerationTiming.range,step:1).labelsHidden().fixedSize()
        }.font(.system(size:11)).controlSize(.small)
        .help("Generate 1–10 seconds. Closest supported duration: \(String(format:"%.2f",GenerationTiming.actualSeconds(lab.durationSeconds))) s. Quality changes picture size, not length.")
        .onChange(of:lab.durationSeconds) {_,_ in lab.saveSettings()}
    }
}

struct FoldSection<Content:View>:View {
    let title:String
    let symbol:String
    @AppStorage private var expanded:Bool
    let content:Content
    init(_ title:String,symbol:String,key:String,open:Bool = true,@ViewBuilder content:()->Content) {
        self.title = title;self.symbol = symbol
        _expanded = AppStorage(wrappedValue:open,"fold." + key)
        self.content = content()
    }
    var body:some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:12) {content}.padding(.top,10).padding(.bottom,4).frame(maxWidth:.infinity,alignment:.leading)
        } label:{Label(title,systemImage:symbol).font(.system(size:12,weight:.semibold)).foregroundStyle(Ink.text)}
        .tint(Ink.quiet).animation(.smooth(duration:0.18),value:expanded)
    }
}

private struct ShotStudioRequest:Identifiable {
    let id = UUID()
    let tab:Int
    let takeID:UUID?
}

struct ClipComposerView:View {
    @EnvironmentObject var store:StudioStore
    @EnvironmentObject var lab:LocalGeneration
    let shot:Shot
    let asset:MediaAsset
    @AppStorage("fold.composer") private var expanded = true
    @State private var candidateID:UUID?
    @State private var studioRequest:ShotStudioRequest?
    var draft:Binding<String> {Binding(get:{store.project.assets.first {$0.id == asset.id}?.regenerationDraft ?? ""},set:{value in
        guard let i = store.project.assets.firstIndex(where:{$0.id == asset.id}) else {return}
        store.change({$0.assets[i].regenerationDraft = value},rebuild:false)
    })}
    var original:MediaAsset {store.project.assets.first {$0.id == store.project.familyRoot(of:asset)} ?? asset}
    var referenceID:UUID {asset.referenceAssetID ?? asset.id}
    var takes:[MediaAsset] {store.project.takes(for:asset)}
    var candidate:MediaAsset? {store.project.assets.first {$0.id == candidateID}}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Button {withAnimation(.smooth){expanded.toggle()}} label:{HStack(spacing:7) {Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:9,weight:.semibold));Image(systemName:"sparkles").foregroundStyle(Ink.mint);Text("Regenerate clip").font(.system(size:12,weight:.semibold))}}.buttonStyle(.plain).help("Expand or collapse clip prompt")
                Text(shot.name).font(.system(size:11)).foregroundStyle(Ink.quiet).lineLimit(1)
                Spacer()
                if !takes.isEmpty {Text("\(takes.count) \(takes.count == 1 ? "take" : "takes")").font(.system(size:10)).foregroundStyle(Ink.quiet)}
                Button {studioRequest = ShotStudioRequest(tab:0,takeID:candidateID)} label:{Label("Shot Studio",systemImage:"viewfinder")}.controlSize(.small).help("Compose references, direct the action and review native frames")
                Button {store.showLab = true} label:{Image(systemName:"slider.horizontal.3")}.buttonStyle(.plain).help("Local engine and generation settings").accessibilityLabel("Generation settings")
            }
            if !expanded,lab.busy,let progress = lab.progress {GenerationProgressView(progress:progress)}
            if expanded {
                HStack(alignment:.top,spacing:12) {
                    VStack(spacing:5) {
                        if let image = store.thumbnails[referenceID] {Image(nsImage:image).resizable().scaledToFill().frame(width:64,height:43).clipped().clipShape(RoundedRectangle(cornerRadius:6))}
                        else {Image(systemName:"film").foregroundStyle(Ink.quiet).frame(width:64,height:43).background(Ink.raised,in:RoundedRectangle(cornerRadius:6))}
                        Text("Reference").font(.system(size:9)).foregroundStyle(Ink.quiet)
                    }
                    ZStack(alignment:.topLeading) {
                        if draft.wrappedValue.isEmpty {Text("Describe a visible action and camera move: she lifts her gaze as the camera pulls back to reveal the room…").font(.system(size:12)).foregroundStyle(.tertiary).padding(.horizontal,5).padding(.top,7).allowsHitTesting(false)}
                        TextEditor(text:draft).font(.system(size:12)).scrollContentBackground(.hidden).frame(minHeight:52,maxHeight:76).accessibilityLabel("Clip regeneration prompt")
                    }.padding(5).background(Ink.base.opacity(0.8),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(Ink.line,lineWidth:0.5)).disabled(lab.busy)
                }
                if let progress = lab.progress,lab.busy || (lab.targetShotID == shot.id && progress.stage == .ready) {GenerationProgressView(progress:progress)}
                HStack(spacing:8) {
                    if lab.busy && lab.targetShotID == shot.id {if lab.progress == nil {ProgressView().controlSize(.small)};Text(lab.message).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(2)}
                    else {Label("Original frame + motion direction",systemImage:"link").font(.system(size:10)).foregroundStyle(Ink.quiet)}
                    Spacer(minLength:8)
                    if !lab.busy,lab.backend == "Automatic" || lab.backend == "MLX-Serve" {GenerationLengthControl()}
                    if !lab.busy,lab.backend == "Automatic" {
                        Picker("Take quality",selection:$lab.quality) {Text("Draft").tag("Draft");Text("Balanced").tag("Balanced");Text("Cinema").tag("Cinema")}.labelsHidden().controlSize(.small).frame(width:105).help("Draft for quick prompt tests; Cinema for the final take")
                    }
                    if lab.busy {Button("Cancel"){lab.cancel()}.controlSize(.small)}
                    else {PrimaryButton(title:"Regenerate",symbol:"arrow.trianglehead.2.clockwise.rotate.90"){
                        lab.requestRegeneration(shotID:shot.id,instructions:draft.wrappedValue,store:store)
                    }.disabled(lab.referenceBusy || draft.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).keyboardShortcut(.return,modifiers:.command)}
                }
                if !lab.busy, lab.targetShotID == shot.id, lab.progress?.stage != .ready, !lab.message.isEmpty {
                    Text(lab.message).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(3).textSelection(.enabled)
                }
                if !takes.isEmpty {
                    Divider()
                    HStack(spacing:7) {
                        Button("Original"){candidateID = original.id;store.previewTake(original)}.controlSize(.small)
                        Picker("Compare take",selection:Binding(get:{candidateID},set:{value in candidateID = value;if let value,let media = store.project.assets.first(where:{$0.id == value}) {store.previewTake(media)}})) {
                            Text("Choose a take").tag(nil as UUID?)
                            Text("Original").tag(Optional(original.id))
                            ForEach(Array(takes.enumerated()),id:\.element.id) {i,take in Text("Take \(i+1) · \(String(format:"%.1f",take.duration))s").tag(Optional(take.id))}
                        }.labelsHidden().controlSize(.small).frame(maxWidth:180)
                        if let candidate {Button(candidate.kind == .video ? "Play take · 1×" : "Preview"){store.previewTake(candidate)}.controlSize(.small)}
                        if let candidate,candidate.kind == .video {Button("Review frames"){studioRequest = ShotStudioRequest(tab:2,takeID:candidateID)}.controlSize(.small)}
                        Spacer()
                        if let candidate,candidate.kind == .video {
                            Menu {
                                Button("Fit to current shot · \(String(format:"%.2f",shot.duration)) s"){store.useTake(candidate,for:shot.id)}
                                Button("Use generated length at 1× · \(String(format:"%.2f",candidate.duration)) s"){store.useTake(candidate,for:shot.id,keepTiming:false)}
                            } label:{Image(systemName:"clock")}.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Take length options").help("Use generated length changes this shot’s duration. Caption and sound positions stay fixed.")
                        }
                        if let candidate, candidate.id != shot.assetID {Button(candidate.id == original.id ? "Restore original" : "Use take"){store.useTake(candidate,for:shot.id)}.buttonStyle(.borderedProminent).controlSize(.small)}
                    }
                    if let evidence = candidate?.motionEvidence {Text(evidence.label).font(.system(size:9)).foregroundStyle(Ink.quiet)}
                    if let candidate,candidate.kind == .video,shot.duration > 0,candidate.duration/shot.duration < 0.75 {
                        Text("Fit to shot plays at \(String(format:"%.2f",candidate.duration/shot.duration))×. The clock menu’s generated-length option keeps natural 1× motion.")
                            .font(.system(size:9)).foregroundStyle(Ink.quiet)
                    }
                }
            }
        }.padding(14).studioGlass(cornerRadius:18)
        .sheet(item:$studioRequest) {request in ShotStudioView(shotID:shot.id,assetID:asset.id,initialTakeID:request.takeID,initialTab:request.tab).environmentObject(store).environmentObject(lab)}
        .onChange(of:shot.id) {_,_ in candidateID = nil}
        .onChange(of:lab.completedAssetID) {_,id in if let id,takes.contains(where:{$0.id == id}) {candidateID = id}}
        .onChange(of:lab.quality) {_,_ in lab.saveSettings()}
    }
}
