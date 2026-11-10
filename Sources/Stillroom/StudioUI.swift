import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

enum Ink {
    static let base = Color(nsColor:.windowBackgroundColor)
    static let panel = Color(nsColor:.controlBackgroundColor)
    static let raised = Color.primary.opacity(0.055)
    static let line = Color(nsColor:.separatorColor).opacity(0.55)
    static let text:Color = .primary
    static let quiet:Color = .secondary
    static let mint:Color = .accentColor
    static let amber:Color = .orange
}

extension View {
    @ViewBuilder func studioGlass(cornerRadius:CGFloat = 18)->some View {
        if #available(macOS 26.0,*) {self.glassEffect(.regular,in:RoundedRectangle(cornerRadius:cornerRadius))}
        else {self.background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:cornerRadius))}
    }
}

struct Hairline: View {var body:some View {Rectangle().fill(Ink.line).frame(height:1)}}
struct SmallLabel: View {
    let text: String
    var body:some View {Text(text.uppercased()).font(.system(size:10,weight:.semibold)).tracking(1.3).foregroundStyle(Ink.quiet)}
}
struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: ()->Void
    var body:some View {
        Button(action:action) {Image(systemName:symbol).font(.system(size:13,weight:.medium)).foregroundStyle(active ? Ink.mint : Ink.text).frame(width:30,height:28).contentShape(Rectangle())}
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
struct PrimaryButton: View {
    let title: String
    let symbol: String
    let action: ()->Void
    var body:some View {
        if #available(macOS 26.0,*) {
            Button(action:action) {Label(title,systemImage:symbol).font(.system(size:12,weight:.semibold))}.buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
        } else {
            Button(action:action) {Label(title,systemImage:symbol).font(.system(size:12,weight:.semibold))}.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

struct StudioView:View {
    @EnvironmentObject var store:StudioStore
    @AppStorage("layout.timelineHeight") private var timelineHeight:Double = 248
    @State private var resizeStart:Double?
    var body:some View {
        NavigationSplitView(columnVisibility:Binding(get:{store.showLibrary ? .all : .detailOnly},set:{store.showLibrary = $0 != .detailOnly})) {
            LibraryView().navigationSplitViewColumnWidth(min:210,ideal:236,max:300)
        } detail: {
            VStack(spacing:0) {
                VStack(spacing:0) {
                    ViewerView().frame(maxWidth:.infinity,maxHeight:.infinity)
                    if let shot = store.shot, let asset = store.project.assets.first(where:{$0.id == shot.assetID}) {
                        ClipComposerView(shot:shot,asset:asset).padding(.horizontal,18).padding(.bottom,12)
                    } else {
                        HStack {Image(systemName:"sparkles").foregroundStyle(Ink.mint);Text("Select a shot to describe a change and regenerate it.").font(.system(size:12)).foregroundStyle(Ink.quiet);Spacer();if let shot = store.project.shot(at:store.time) {Button("Select current shot"){store.selectShot(shot)}}}.padding(14)
                    }
                }.frame(maxHeight:.infinity)
                if store.showTimeline {
                    ZStack {Hairline();Capsule().fill(Ink.quiet.opacity(0.35)).frame(width:32,height:3)}.frame(height:10).contentShape(Rectangle()).help("Drag to resize the timeline")
                        .gesture(DragGesture(minimumDistance:1).onChanged {value in if resizeStart == nil {resizeStart = timelineHeight};timelineHeight = max(160,min(440,(resizeStart ?? timelineHeight)-value.translation.height))}.onEnded {_ in resizeStart = nil})
                    TimelineView().frame(height:timelineHeight)
                }
                statusBar
            }.background(Ink.base)
            .inspector(isPresented:$store.showInspector) {InspectorView().inspectorColumnWidth(min:280,ideal:320,max:400)}
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(store.project.name)
        .navigationSubtitle(store.dirty ? "Edited · recovered automatically" : "Stillroom Studio")
        .toolbar {
            ToolbarItemGroup(placement:.primaryAction) {
                Button {store.importPanel()} label:{Label("Import",systemImage:"plus")}.help("Import media · ⌘I")
                Button {store.showLab = true} label:{Label("Create",systemImage:"sparkles")}.help("Configure local creation")
                Button {store.showAssistant = true} label:{Label("Assistant",systemImage:"bubble.left.and.text.bubble.right")}.help("Finish the edit with a local AI assistant · ⇧⌘A")
                Button {store.showStoryboard = true} label:{Label("Storyboard",systemImage:"rectangle.on.rectangle.angled")}.help("Create and edit a storyboard · ⇧⌘B")
                Button {store.saveProject()} label:{Label("Save",systemImage:"square.and.arrow.down")}.help("Save portable project · ⌘S")
            }
            ToolbarItemGroup(placement:.automatic) {
                Button {withAnimation(.snappy){store.showTimeline.toggle()}} label:{Label("Timeline",systemImage:"rectangle.bottomthird.inset.filled")}.help("Show or hide timeline")
                Button {withAnimation(.snappy){store.showInspector.toggle()}} label:{Label("Inspector",systemImage:"sidebar.right")}.help("Show or hide inspector")
            }
            ToolbarItem(placement:.primaryAction) {
                PrimaryButton(title:store.exporting ? "Exporting…" : "Export",symbol:"arrow.up.right"){store.exportMovie()}.disabled(store.project.shots.isEmpty || store.exporting)
            }
        }
        .frame(minWidth:1140,minHeight:800)
        .sheet(isPresented:$store.showLab) {GenerationView().environmentObject(store).environmentObject(store.generation)}
        .sheet(isPresented:$store.showAssistant) {EditAssistantView(assistant:store.assistant,blender:store.blender).environmentObject(store)}
        .sheet(isPresented:$store.showStoryboard) {StoryboardView().environmentObject(store)}
        .alert("Stillroom",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error = nil}})) {Button("OK"){store.error = nil}} message:{Text(store.error ?? "")}
    }
    private var statusBar:some View {
        HStack(spacing:7) {
            Circle().fill(store.exporting ? Ink.amber : Ink.mint).frame(width:5,height:5)
            Text(store.status).font(.system(size:10)).lineLimit(1)
            if store.exporting {ProgressView(value:store.exportProgress).frame(width:100);Button("Cancel"){store.cancelExport()}.buttonStyle(.plain).font(.system(size:10))}
            Spacer()
            Text("\(store.project.width) × \(store.project.height)  ·  \(store.project.fps) fps").font(.system(size:10,design:.monospaced))
        }.foregroundStyle(Ink.quiet).padding(.horizontal,14).frame(height:27).background(.bar)
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: StudioStore
    @State private var search = ""
    @State private var kind = "All"
    var filtered:[MediaAsset] {store.project.assets.filter {a in
        (search.isEmpty || a.name.localizedCaseInsensitiveContains(search)) && (kind == "All" || a.kind.rawValue == kind)
    }}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                SmallLabel(text:"Workspace");Spacer()
                Menu {Button("New film"){store.newProject()};Button("Open project…"){store.openProjectPanel()};Button("Save as…"){store.saveAs()};Divider();Button("Load example film"){store.resetDemo()};Button("Show recovery files"){store.showRecovery()}} label:{Image(systemName:"ellipsis").frame(width:22,height:22)}.menuStyle(.borderlessButton).frame(width:22)
            }.padding(.horizontal,16).padding(.top,17).padding(.bottom,10)
            ForEach([("Media","square.grid.2x2"),("Captions","captions.bubble"),("Story","text.alignleft")],id:\.0) {name,symbol in
                Button {store.section = name} label:{HStack {Image(systemName:symbol).frame(width:17);Text(name);Spacer();if name == "Media" {Text("\(store.project.assets.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(Ink.quiet)}}.font(.system(size:12,weight:store.section == name ? .semibold : .regular)).padding(.horizontal,12).padding(.vertical,9).background(store.section == name ? Ink.raised : .clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain).padding(.horizontal,10)
            }
            Hairline().padding(.top,15)
            if store.section == "Media" {mediaContent}
            else if store.section == "Captions" {CaptionList()}
            else {storyContent}
            Spacer(minLength:0)
            Hairline()
            Button {store.showLab = true} label:{HStack(spacing:9) {Image(systemName:"sparkles").foregroundStyle(Ink.mint);VStack(alignment:.leading,spacing:3) {Text("Local creation").font(.system(size:12,weight:.medium));Text("MLX-Serve · ComfyUI").font(.system(size:10)).foregroundStyle(Ink.quiet)};Spacer();Image(systemName:"arrow.up.right").font(.system(size:10)).foregroundStyle(Ink.quiet)}.padding(16)}.buttonStyle(.plain)
        }.background(.clear)
        .onDrop(of:[UTType.fileURL],isTargeted:nil) {providers in
            for provider in providers {provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier) {data,_ in
                guard let data, let url = URL(dataRepresentation:data,relativeTo:nil) else {return}
                Task {@MainActor in await store.importURLs([url])}
            }}
            return !providers.isEmpty
        }
    }
    private var mediaContent:some View {
        VStack(spacing:12) {
            HStack {SmallLabel(text:"Source library");Spacer();ToolButton(symbol:"plus",help:"Import media"){store.importPanel()}}.padding(.top,8)
            HStack(spacing:6) {Image(systemName:"magnifyingglass").foregroundStyle(Ink.quiet);TextField("Find a source",text:$search).textFieldStyle(.plain).font(.system(size:11))}.padding(8).background(Ink.base,in:RoundedRectangle(cornerRadius:6))
            Picker("Filter",selection:$kind) {Text("All sources").tag("All");Text("Motion").tag("video");Text("Images").tag("image");Text("Sound").tag("audio");Text("Blender").tag("blender")}.labelsHidden().controlSize(.small)
            ScrollView {
                LazyVGrid(columns:[GridItem(.flexible(),spacing:8),GridItem(.flexible(),spacing:8)],spacing:14) {
                    ForEach(filtered) {media in MediaTile(media:media)}
                }.padding(.bottom,14)
                if filtered.isEmpty {Text("Import a reference image, a motion take or a sound recording.").font(.system(size:11)).foregroundStyle(Ink.quiet).padding(.vertical,24)}
            }
            Button {store.importPanel()} label:{Label("Import media",systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.bordered).controlSize(.small).padding(.bottom,14)
        }.padding(.horizontal,14)
    }
    private var storyContent:some View {
        VStack(alignment:.leading,spacing:12) {
            SmallLabel(text:"Film title")
            TextField("Film title",text:Binding(get:{store.project.name},set:{value in store.change({$0.name = value},rebuild:false)})).textFieldStyle(.roundedBorder)
            SmallLabel(text:"Creative direction")
            TextEditor(text:Binding(get:{store.project.brief},set:{value in store.change({$0.brief = value},rebuild:false)})).font(.system(size:12)).scrollContentBackground(.hidden).padding(7).background(Ink.base,in:RoundedRectangle(cornerRadius:6)).frame(minHeight:220)
            Text("Keep the action small. Give each shot a purpose. Use real silence and a patient ending.").font(.system(size:11)).foregroundStyle(Ink.quiet).lineSpacing(4)
            Spacer()
        }.padding(16)
    }
}

struct MediaTile: View {
    @EnvironmentObject var store: StudioStore
    let media:MediaAsset
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            ZStack(alignment:.bottomTrailing) {
                GeometryReader {geometry in ZStack {
                    Ink.base
                    if let image = store.thumbnails[media.id] {Image(nsImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:66).clipped()}
                    else {Image(systemName:media.kind.symbol).font(.system(size:22,weight:.ultraLight)).foregroundStyle(media.kind == .audio ? Ink.mint : Ink.quiet)}
                }.frame(width:geometry.size.width,height:66)}.frame(height:66).clipped()
                Text(media.kind == .image ? "STILL" : media.kind == .blender ? "3D" : String(format:"%.1fs",media.duration)).font(.system(size:8,weight:.medium,design:.monospaced)).foregroundStyle(.white).padding(4).background(.black.opacity(0.7)).padding(3)
            }.clipShape(RoundedRectangle(cornerRadius:5)).overlay(RoundedRectangle(cornerRadius:5).stroke(store.selectedAsset == media.id || store.shot?.assetID == media.id ? Ink.mint : .clear,lineWidth:1.5))
            HStack(alignment:.top,spacing:2) {
                Text(media.name).font(.system(size:10,weight:.medium)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                Button {store.append(media)} label:{Image(systemName:media.kind == .blender ? "arrow.up.right" : "plus.circle").font(.system(size:12)).foregroundStyle(Ink.mint)}.buttonStyle(.plain).help(media.kind == .blender ? "Open in Blender" : "Add to timeline")
            }
        }.contentShape(Rectangle()).onTapGesture {store.preview(media)}
            .onDrag {NSItemProvider(object:("asset:"+media.id.uuidString) as NSString)}
            .contextMenu {Button("Add to timeline"){store.append(media)};Button("Reveal source"){NSWorkspace.shared.activateFileViewerSelecting([store.url(media)])}}
    }
}

final class PlayerSurface: NSView {
    let video = AVPlayerLayer()
    override init(frame:NSRect) {super.init(frame:frame);wantsLayer = true;layer?.backgroundColor = NSColor.black.cgColor;layer?.addSublayer(video);video.videoGravity = .resizeAspect}
    required init?(coder:NSCoder) {fatalError()}
    override func layout() {super.layout();CATransaction.begin();CATransaction.setDisableActions(true);video.frame = bounds;CATransaction.commit()}
}
struct NativePlayer: NSViewRepresentable {
    let player:AVPlayer
    func makeNSView(context:Context)->PlayerSurface {let view = PlayerSurface();view.video.player = player;return view}
    func updateNSView(_ view:PlayerSurface,context:Context) {if view.video.player !== player {view.video.player = player}}
}

struct ViewerView: View {
    @EnvironmentObject var store: StudioStore
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text(store.sourcePreview ? "Source viewer" : "Viewer").font(.system(size:12,weight:.medium)).foregroundStyle(Ink.quiet)
                Spacer()
                if store.sourcePreview {Button("Return to edit"){store.returnToEdit()}.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Ink.mint)}
                else {Text("\(store.project.shots.count) SHOTS").font(.system(size:9,design:.monospaced)).foregroundStyle(Ink.quiet)}
            }.padding(.horizontal,22).frame(height:42)
            GeometryReader {geometry in
                let ratio = Double(store.project.width)/Double(store.project.height)
                let width = min(geometry.size.width-40,(geometry.size.height-16)*ratio)
                ZStack(alignment:.bottom) {
                    if let id = store.previewingTakeID,store.project.assets.first(where:{$0.id == id})?.kind == .image,let image = store.thumbnails[id] {Image(nsImage:image).resizable().scaledToFit().background(.black)}
                    else if store.previewingTakeID == nil,let asset = store.asset, store.selectedAsset != nil, asset.kind == .image, let image = store.thumbnails[asset.id] {Image(nsImage:image).resizable().scaledToFit().background(.black)}
                    else if store.project.shots.isEmpty && !store.sourcePreview {emptyViewer}
                    else {NativePlayer(player:store.player)}
                    if let caption = store.activeCaption {
                        Text(caption).font(.system(size:max(11,width*0.019),weight:.medium)).multilineTextAlignment(.center).foregroundStyle(.white).shadow(color:.black,radius:3,y:1).frame(maxWidth:width*0.76).padding(.bottom,width*0.033)
                    }
                    if store.preparing {HStack(spacing:8){ProgressView().controlSize(.small);Text("Preparing picture…").font(.system(size:11))}.padding(10).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:7)).frame(maxHeight:.infinity)}
                }.frame(width:max(1,width),height:max(1,width/ratio)).clipped().overlay(alignment:.topLeading) {
                    if !store.sourcePreview,let text = store.project.shot(at:store.time)?.indicator,!text.isEmpty {Text(text).font(.system(size:max(10,width*0.0146),weight:.medium)).foregroundStyle(.white).padding(.horizontal,10).padding(.vertical,5).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:6)).padding(width*0.04)}
                }.overlay(Rectangle().stroke(Ink.line,lineWidth:1)).position(x:geometry.size.width/2,y:geometry.size.height/2)
            }
            HStack(spacing:14) {
                Text(timecode(store.time,fps:store.project.fps)).font(.system(size:11,design:.monospaced)).foregroundStyle(Ink.mint).frame(width:100,alignment:.leading)
                Spacer()
                HStack(spacing:12) {
                    ToolButton(symbol:"backward.end",help:"Go to start"){store.seek(0)}
                    ToolButton(symbol:store.playing ? "pause.fill" : "play.fill",help:"Play or pause",active:true){store.togglePlay()}
                    ToolButton(symbol:"forward.end",help:"Go to end"){store.seek(max(0,store.project.duration-1/Double(store.project.fps)))}
                }.padding(.horizontal,12).padding(.vertical,4).studioGlass(cornerRadius:24)
                Spacer()
                Text(timecode(store.sourcePreview ? store.previewDuration : store.project.duration,fps:store.project.fps)).font(.system(size:11,design:.monospaced)).foregroundStyle(Ink.quiet).frame(width:100,alignment:.trailing)
            }.padding(.horizontal,22).frame(height:54)
        }.background(Ink.base)
    }
    private var emptyViewer:some View {
        VStack(spacing:16) {
            Image(systemName:"viewfinder").font(.system(size:36,weight:.ultraLight)).foregroundStyle(Ink.mint)
            Text("Every film starts with a frame.").font(.system(size:20,weight:.medium,design:.rounded))
            Text("Import a source. Add it to the timeline. Find the moment.").font(.system(size:12)).foregroundStyle(Ink.quiet)
            Button("Import media"){store.importPanel()}.buttonStyle(.bordered)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Ink.panel)
    }
}

struct InspectorView: View {
    @EnvironmentObject var store: StudioStore
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("Inspector").font(.system(size:13,weight:.semibold));Spacer()
                Menu {
                    Button("Collapse all sections"){setFolds(false)}
                    Button("Expand all sections"){setFolds(true)}
                } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:24)
            }.padding(.horizontal,17).frame(height:42)
            Hairline()
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if let sound = store.sound {soundControls(sound)}
                    else if let shot = store.shot {shotControls(shot)}
                    else if store.asset == nil {projectControls}
                    if let asset = store.asset {assetControls(asset)}
                }.padding(17)
            }
        }.background(.clear)
    }
    private func shotValue(_ get:@escaping(Shot)->Double,_ set:@escaping(inout Shot,Double)->Void)->Binding<Double> {
        Binding(get:{store.shot.map(get) ?? 0},set:{value in store.updateShot {set(&$0,value)}})
    }
    private func setFolds(_ value:Bool) {
        for key in ["timing","camera","sourceAudio","source","direction","notes","soundTiming","soundLevel"] {UserDefaults.standard.set(value,forKey:"fold." + key)}
    }
    private func shotControls(_ shot:Shot)->some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:7) {
                Text("Selected shot").font(.system(size:11)).foregroundStyle(Ink.quiet)
                TextField("Shot name",text:Binding(get:{store.shot?.name ?? ""},set:{v in store.updateShot {$0.name = v}})).textFieldStyle(.plain).font(.system(size:18,weight:.semibold))
                HStack {Text("\(String(format:"%.2f",shot.duration)) seconds");Spacer();Text("\(Int((shot.duration*Double(store.project.fps)).rounded())) frames")}.font(.system(size:10,design:.monospaced)).foregroundStyle(Ink.quiet)
            }
            Divider()
            FoldSection("Timing",symbol:"clock",key:"timing") {
                NumberRow(title:"Source in",suffix:"s",value:shotValue({$0.sourceIn},{s,v in s.sourceIn = max(0,min(v,(store.asset?.duration ?? 99999)-s.sourceDuration))}))
                NumberRow(title:store.asset?.kind == .image ? "Hold duration" : "Source length",suffix:"s",value:shotValue({$0.sourceDuration},{s,v in s.sourceDuration = max(1/Double(store.project.fps),min(v,(store.asset?.kind == .image ? 600 : store.asset?.duration ?? 600)-s.sourceIn))}))
                HStack {Text("Speed");Spacer();Text(String(format:"%.2f×",shot.speed)).monospacedDigit().foregroundStyle(Ink.mint)}.font(.system(size:12))
                Slider(value:shotValue({$0.speed},{$0.speed = $1}),in:0.1...4,step:0.05).tint(Ink.mint)
            }
            Divider()
            FoldSection("Camera",symbol:"video",key:"camera") {
                NumberRow(title:"Start zoom",suffix:"×",value:shotValue({$0.zoomStart},{$0.zoomStart = max(1,min(2,$1))}))
                NumberRow(title:"End zoom",suffix:"×",value:shotValue({$0.zoomEnd},{$0.zoomEnd = max(1,min(2,$1))}))
                HStack {Button("Slow push"){store.updateShot {$0.zoomStart = 1;$0.zoomEnd = 1.08}};Button("Pull back"){store.updateShot {$0.zoomStart = 1.12;$0.zoomEnd = 1}}}.font(.system(size:11)).controlSize(.small)
                Text("1.00× shows the full frame. Pull back gradually widens the shot.").font(.system(size:11)).foregroundStyle(Ink.quiet)
            }
            Divider()
            FoldSection("Source audio",symbol:"speaker.wave.2",key:"sourceAudio",open:false) {
                Slider(value:shotValue({$0.volume},{$0.volume = $1}),in:0...2).tint(Ink.mint)
                Text(shot.volume == 0 ? "Muted. Voices and room tone stay on their own lanes." : "\(Int(shot.volume*100))% · source audio follows the clip speed").font(.system(size:11)).foregroundStyle(Ink.quiet)
            }
            HStack {ToolButton(symbol:"arrow.left",help:"Move shot earlier"){store.moveSelected(-1)};ToolButton(symbol:"arrow.right",help:"Move shot later"){store.moveSelected(1)};Spacer();ToolButton(symbol:"scissors",help:"Split at playhead"){store.split()};ToolButton(symbol:"trash",help:"Remove shot"){store.removeSelected()}}
        }
    }
    private func soundControls(_ sound:SoundLayer)->some View {
        VStack(alignment:.leading,spacing:14) {
            SmallLabel(text:"Sound layer");Text(sound.name).font(.system(size:16,weight:.medium))
            NumberRow(title:"Timeline start",suffix:"s",value:Binding(get:{store.sound?.start ?? 0},set:{v in store.updateSound {$0.start = max(0,v)}}))
            NumberRow(title:"Source in",suffix:"s",value:Binding(get:{store.sound?.sourceIn ?? 0},set:{v in store.updateSound {$0.sourceIn = max(0,min(v,(store.asset?.duration ?? 0)-0.05))}}))
            NumberRow(title:"Duration",suffix:"s",value:Binding(get:{store.sound?.duration ?? 0},set:{v in store.updateSound {$0.duration = max(0.05,v)}}))
            Toggle("Mute",isOn:Binding(get:{store.sound?.muted ?? false},set:{v in store.updateSound {$0.muted = v}})).font(.system(size:11))
            HStack {Text("Level");Spacer();Text("\(Int(sound.volume*100))%").foregroundStyle(Ink.mint)}.font(.system(size:11))
            Slider(value:Binding(get:{store.sound?.volume ?? 1},set:{v in store.updateSound {$0.volume = v}}),in:0...2).tint(Ink.mint)
            Button("Remove sound layer"){store.removeSelected()}.controlSize(.small)
        }
    }
    private func assetControls(_ asset:MediaAsset)->some View {
        VStack(alignment:.leading,spacing:16) {
            Divider()
            FoldSection("Source details",symbol:asset.kind.symbol,key:"source") {
                HStack {Text(asset.origin);Spacer();if asset.width > 0 {Text("\(asset.width) × \(asset.height)")}}.font(.system(size:11)).foregroundStyle(Ink.quiet)
                Picker("Review",selection:Binding(get:{store.asset?.review ?? "Unreviewed"},set:{v in store.updateAsset {$0.review = v}})) {Text("Unreviewed").tag("Unreviewed");Text("Keep").tag("Keep");Text("Reject").tag("Reject")}.font(.system(size:12)).controlSize(.small)
                HStack {Button("Reveal source"){NSWorkspace.shared.activateFileViewerSelecting([store.url(asset)])};Button("Relink…"){store.relink()}}.controlSize(.small).font(.system(size:11))
            }
            Divider()
            FoldSection("Original direction",symbol:"text.alignleft",key:"direction",open:false) {
                TextEditor(text:Binding(get:{store.asset?.prompt ?? ""},set:{v in store.updateAsset {$0.prompt = v}})).font(.system(size:12)).scrollContentBackground(.hidden).padding(7).frame(height:130).background(Ink.base,in:RoundedRectangle(cornerRadius:9))
            }
            Divider()
            FoldSection("Take notes",symbol:"note.text",key:"notes",open:false) {
                TextEditor(text:Binding(get:{store.asset?.notes ?? ""},set:{v in store.updateAsset {$0.notes = v}})).font(.system(size:12)).scrollContentBackground(.hidden).padding(7).frame(height:100).background(Ink.base,in:RoundedRectangle(cornerRadius:9))
            }
        }
    }
    private var projectControls:some View {
        VStack(alignment:.leading,spacing:15) {
            Text("Room for a good idea.").font(.system(size:19,weight:.medium,design:.rounded))
            Text("Select a shot to shape its timing and camera. Keep the references and prompts that made it.").font(.system(size:12)).foregroundStyle(Ink.quiet).lineSpacing(5)
            Hairline();SmallLabel(text:"Canvas")
            Text("\(store.project.width) × \(store.project.height)").font(.system(size:14,design:.monospaced))
            Text("24 fps · landscape · H.264 export").font(.system(size:10)).foregroundStyle(Ink.quiet)
            Button("Import a source"){store.importPanel()}.controlSize(.small)
        }
    }
}

struct NumberRow:View {
    let title:String
    let suffix:String
    @Binding var value:Double
    var body:some View {
        HStack {Text(title).font(.system(size:11));Spacer();TextField(title,value:$value,format:.number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced)).multilineTextAlignment(.trailing).frame(width:70);Text(suffix).font(.system(size:10)).foregroundStyle(Ink.quiet).frame(width:10)}
    }
}

struct CaptionList:View {
    @EnvironmentObject var store:StudioStore
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle("Show subtitles",isOn:Binding(get:{store.project.captionsEnabled},set:{v in store.change({$0.captionsEnabled = v},rebuild:false)})).font(.system(size:11)).tint(Ink.mint)
            HStack {Button("Import SRT"){store.importSubtitles()};Button("Export SRT"){store.exportSRT()}}.controlSize(.small).font(.system(size:10))
            ScrollView {
                LazyVStack(alignment:.leading,spacing:18) {
                    ForEach(store.project.subtitles) {cue in CaptionRow(cue:cue)}
                }
            }
            Button {store.change({$0.subtitles.append(Subtitle(start:store.time,end:min(store.time+3,max(store.time+0.2,store.project.duration)),text:"New caption"))},rebuild:false)} label:{Label("Caption at playhead",systemImage:"plus")}.controlSize(.small)
        }.padding(14)
    }
}
struct CaptionRow:View {
    @EnvironmentObject var store:StudioStore
    let cue:Subtitle
    func update(_ action:(inout Subtitle)->Void) {
        guard let i = store.project.subtitles.firstIndex(where:{$0.id == cue.id}) else {return}
        store.change({action(&$0.subtitles[i])},rebuild:false)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {Button {store.seek(cue.start)} label:{Text(timecode(cue.start)).font(.system(size:9,design:.monospaced)).foregroundStyle(Ink.mint)}.buttonStyle(.plain);Spacer();Button {store.change({$0.subtitles.removeAll {$0.id == cue.id}},rebuild:false)} label:{Image(systemName:"xmark").font(.system(size:8))}.buttonStyle(.plain).foregroundStyle(Ink.quiet)}
            TextField("Caption",text:Binding(get:{store.project.subtitles.first {$0.id == cue.id}?.text ?? cue.text},set:{v in update {$0.text = v}}),axis:.vertical).textFieldStyle(.plain).font(.system(size:11)).lineSpacing(3)
            HStack {TextField("In",value:Binding(get:{cue.start},set:{v in update {$0.start = max(0,min(v,$0.end-0.05))}}),format:.number.precision(.fractionLength(2)));Text("–");TextField("Out",value:Binding(get:{cue.end},set:{v in update {$0.end = max($0.start+0.05,v)}}),format:.number.precision(.fractionLength(2)))}.font(.system(size:9,design:.monospaced)).textFieldStyle(.roundedBorder).foregroundStyle(Ink.quiet)
            Hairline()
        }
    }
}

struct TimelineView:View {
    @EnvironmentObject var store:StudioStore
    var totalWidth:Double {max(700,store.project.duration*store.zoom+90)}
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                SmallLabel(text:"The edit").padding(.trailing,10)
                ToolButton(symbol:"arrow.uturn.backward",help:"Undo"){store.undo()}
                ToolButton(symbol:"arrow.uturn.forward",help:"Redo"){store.redo()}
                Rectangle().fill(Ink.line).frame(width:1,height:16).padding(.horizontal,5)
                ToolButton(symbol:"scissors",help:"Split at playhead"){store.split()}
                ToolButton(symbol:"trash",help:"Remove selected"){store.removeSelected()}
                Spacer()
                Text("Drag sources in · drag shots to reorder").font(.system(size:10)).foregroundStyle(Ink.quiet)
                Image(systemName:"minus.magnifyingglass").font(.system(size:10)).foregroundStyle(Ink.quiet).padding(.leading,14)
                Slider(value:$store.zoom,in:3...30).frame(width:94).tint(Ink.quiet)
                Image(systemName:"plus.magnifyingglass").font(.system(size:10)).foregroundStyle(Ink.quiet)
            }.padding(.horizontal,16).frame(height:40)
            Hairline()
            ScrollView(.vertical) {
                HStack(alignment:.top,spacing:0) {
                    trackNames.frame(width:96)
                    ScrollView(.horizontal) {
                        ZStack(alignment:.topLeading) {
                            VStack(alignment:.leading,spacing:4) {
                                ruler.frame(height:26)
                                shotTrack.frame(height:60)
                                captionTrack.frame(height:23)
                                ForEach(Array(store.project.sounds.enumerated()),id:\.element.id) {index,sound in soundTrack(sound,index:index).frame(height:35)}
                                if store.project.sounds.isEmpty {Text("Drop an audio source here to build the room.").font(.system(size:10)).foregroundStyle(Ink.quiet).padding(.leading,12).frame(height:38)}
                            }.frame(width:totalWidth,alignment:.leading)
                            Rectangle().fill(Ink.mint).frame(width:1,height:CGFloat(123+max(1,store.project.sounds.count)*39)).offset(x:store.time*store.zoom)
                            Image(systemName:"arrowtriangle.down.fill").font(.system(size:9)).foregroundStyle(Ink.mint).offset(x:store.time*store.zoom-4,y:0)
                        }.padding(.trailing,18)
                    }
                }
            }.background(Ink.base)
        }.background(Ink.panel)
    }
    private var trackNames:some View {
        VStack(alignment:.leading,spacing:4) {
            Text("TIMELINE").font(.system(size:8,weight:.medium,design:.monospaced)).foregroundStyle(Ink.quiet).frame(height:26)
            Label("Picture",systemImage:"film").frame(height:60)
            Label("Captions",systemImage:"captions.bubble").frame(height:23)
            ForEach(Array(store.project.sounds.enumerated()),id:\.element.id) {index,sound in
                Button {store.selectedSound = sound.id;store.selectedShot = nil;store.selectedAsset = sound.assetID} label:{HStack(spacing:5){Image(systemName:sound.muted ? "speaker.slash" : "waveform");Text(sound.name).lineLimit(1)}}.buttonStyle(.plain).frame(height:35)
            }
        }.font(.system(size:10)).foregroundStyle(Ink.quiet).padding(.leading,13).frame(maxWidth:.infinity,alignment:.leading)
    }
    private var ruler:some View {
        Canvas {context,size in
            let step = store.zoom < 6 ? 20 : store.zoom < 15 ? 10 : 5
            for second in stride(from:0,through:Int(totalWidth/store.zoom),by:step) {
                let x = Double(second)*store.zoom
                var path = Path();path.move(to:CGPoint(x:x,y:19));path.addLine(to:CGPoint(x:x,y:26));context.stroke(path,with:.color(Ink.quiet.opacity(0.5)),lineWidth:1)
                let text = Text(String(format:"%02d:%02d",second/60,second%60)).font(.system(size:9,design:.monospaced)).foregroundColor(Ink.quiet)
                context.draw(text,at:CGPoint(x:x+2,y:8),anchor:.leading)
            }
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {store.seek($0.location.x/store.zoom)})
    }
    private var shotTrack:some View {
        HStack(spacing:0) {
            ForEach(Array(store.project.shots.enumerated()),id:\.element.id) {index,shot in
                ShotBlock(shot:shot,index:index).frame(width:max(1,shot.duration*store.zoom),height:60)
            }
            Color.clear.frame(maxWidth:.infinity)
        }.background(Ink.panel)
        .onDrop(of:[UTType.text],isTargeted:nil) {providers in receive(providers,before:nil)}
    }
    private var captionTrack:some View {
        ZStack(alignment:.leading) {
            Ink.panel.opacity(0.5)
            ForEach(store.project.subtitles) {cue in
                Text(cue.text).font(.system(size:8)).lineLimit(1).padding(.horizontal,5).frame(width:max(1,(cue.end-cue.start)*store.zoom),height:20,alignment:.leading).foregroundStyle(Ink.amber).background(Ink.amber.opacity(0.12),in:RoundedRectangle(cornerRadius:3)).offset(x:cue.start*store.zoom).onTapGesture {store.section = "Captions";store.seek(cue.start)}
            }
        }.opacity(store.project.captionsEnabled ? 1 : 0.3).clipped()
    }
    private func soundTrack(_ sound:SoundLayer,index:Int)->some View {
        ZStack(alignment:.leading) {
            Ink.panel.opacity(0.4)
            if let samples = store.waveforms[sound.assetID],let media = store.project.assets.first(where:{$0.id == sound.assetID}) {
                Canvas {context,size in
                    guard !samples.isEmpty else {return}
                    var path = Path()
                    let width = min(sound.duration,max(0,store.project.duration-sound.start))*store.zoom
                    for x in stride(from:0.0,to:width,by:3) {
                        let position = sound.sourceIn + x/store.zoom
                        let i = min(samples.count-1,max(0,Int(position/max(0.01,media.duration)*Double(samples.count))))
                        let amplitude = CGFloat(samples[i])*12
                        path.move(to:CGPoint(x:x,y:16-amplitude));path.addLine(to:CGPoint(x:x,y:16+amplitude))
                    }
                    context.stroke(path,with:.color(Ink.mint.opacity(sound.muted ? 0.08 : 0.25)),lineWidth:1)
                }.offset(x:sound.start*store.zoom)
            }
            HStack(spacing:8) {
                Image(systemName:sound.muted ? "speaker.slash.fill" : "waveform").font(.system(size:11))
                Text(sound.name).font(.system(size:9)).lineLimit(1)
                Spacer(minLength:0)
                Text("\(Int(sound.volume*100))%").font(.system(size:9,design:.monospaced))
            }.padding(.horizontal,10).frame(width:max(1,min(sound.duration,max(0,store.project.duration-sound.start))*store.zoom),height:32).foregroundStyle(Ink.mint.opacity(sound.muted ? 0.35 : 0.8)).background(Ink.mint.opacity(0.08),in:RoundedRectangle(cornerRadius:4)).overlay(RoundedRectangle(cornerRadius:4).stroke(store.selectedSound == sound.id ? Ink.mint : Ink.mint.opacity(0.12),lineWidth:1)).offset(x:sound.start*store.zoom)
        }.clipped().contentShape(Rectangle()).onTapGesture {store.selectedSound = sound.id;store.selectedShot = nil;store.selectedAsset = sound.assetID}
    }
    func receive(_ providers:[NSItemProvider],before:UUID?)->Bool {
        guard let provider = providers.first else {return false}
        _ = provider.loadObject(ofClass:NSString.self) {object,_ in
            guard let value = object as? String else {return}
            Task {@MainActor in
                if value.hasPrefix("asset:"),let id = UUID(uuidString:String(value.dropFirst(6))),let asset = store.project.assets.first(where:{$0.id == id}) {store.append(asset);if let before,let id = store.selectedShot {store.change {$0.moveShot(id,before:before)}}}
                else if value.hasPrefix("shot:"),let id = UUID(uuidString:String(value.dropFirst(5))),let before {store.change {$0.moveShot(id,before:before)}}
            }
        }
        return true
    }
}
struct ShotBlock:View {
    @EnvironmentObject var store:StudioStore
    let shot:Shot
    let index:Int
    var body:some View {
        GeometryReader {geometry in ZStack(alignment:.bottomLeading) {
            Ink.raised
            if let image = store.thumbnails[shot.assetID] {Image(nsImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped().opacity(0.65)}
            LinearGradient(colors:[.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom)
            HStack(spacing:4){Text(String(format:"%02d",index+1)).foregroundStyle(Ink.mint);Text(shot.name).foregroundStyle(.white).lineLimit(1)}.font(.system(size:9,weight:.medium)).padding(6)
        }.frame(width:geometry.size.width,height:geometry.size.height).clipped()}.overlay(RoundedRectangle(cornerRadius:4).stroke(store.selectedShot == shot.id ? Ink.mint : Ink.base,lineWidth:store.selectedShot == shot.id ? 2 : 1)).clipShape(RoundedRectangle(cornerRadius:4)).padding(.horizontal,1)
            .onTapGesture {store.selectShot(shot)}.help("\(shot.name) · \(String(format:"%.2f",shot.duration))s")
            .onDrag {NSItemProvider(object:("shot:"+shot.id.uuidString) as NSString)}
            .onDrop(of:[UTType.text],isTargeted:nil) {receive($0)}
    }
    func receive(_ providers:[NSItemProvider])->Bool {
        guard let provider = providers.first else {return false}
        _ = provider.loadObject(ofClass:NSString.self) {object,_ in
            guard let value = object as? String else {return}
            Task {@MainActor in
                if value.hasPrefix("shot:"),let id = UUID(uuidString:String(value.dropFirst(5))) {store.change {$0.moveShot(id,before:shot.id)}}
                if value.hasPrefix("asset:"),let id = UUID(uuidString:String(value.dropFirst(6))),let asset = store.project.assets.first(where:{$0.id == id}) {store.append(asset);if let added = store.selectedShot {store.change {$0.moveShot(added,before:shot.id)}}}
            }
        }
        return true
    }
}

struct GenerationView:View {
    @EnvironmentObject var store:StudioStore
    @EnvironmentObject var lab:LocalGeneration
    @Environment(\.dismiss) var dismiss
    var creationText:Binding<String> {Binding(get:{lab.pendingRegeneration?.instructions ?? lab.prompt},set:{value in
        if var pending = lab.pendingRegeneration {pending.instructions = value;lab.pendingRegeneration = pending}
        else {lab.prompt = value}
    })}
    var pendingSource:UUID? {lab.pendingRegeneration.flatMap {pending in store.project.shots.first {$0.id == pending.shotID}?.assetID}}
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {VStack(alignment:.leading,spacing:7){Text(lab.pendingRegeneration == nil ? "Local creation" : "Regenerate clip").font(.system(size:25,weight:.medium,design:.rounded));Text(lab.pendingRegeneration == nil ? "A reference. A small action. One continuous take." : "Change the action or camera while keeping the original reference.").font(.system(size:12)).foregroundStyle(Ink.quiet)};Spacer();ToolButton(symbol:"xmark",help:"Close creation panel"){dismiss()}}
            Hairline()
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:12) {
                    Image(systemName:"desktopcomputer").font(.system(size:24,weight:.light)).foregroundStyle(Ink.mint)
                    VStack(alignment:.leading,spacing:4) {
                        Text(lab.backend == "Automatic" ? "On this Mac · LTX video" : "Custom local engine").font(.system(size:13,weight:.semibold))
                        Text("Finds the installed models, starts the engine and prepares each take.").font(.system(size:11)).foregroundStyle(Ink.quiet)
                    }
                    Spacer()
                    if lab.backend == "Automatic" {Picker("Quality",selection:$lab.quality) {Text("Draft · faster").tag("Draft");Text("Balanced").tag("Balanced");Text("Cinema").tag("Cinema")}.frame(width:180)}
                }
                DisclosureGroup("Engine options") {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Picker("Engine",selection:$lab.backend) {Text("Automatic").tag("Automatic");Text("MLX-Serve").tag("MLX-Serve");Text("ComfyUI workflow").tag("ComfyUI")}.frame(width:260).onChange(of:lab.backend) {_,value in lab.address = value == "MLX-Serve" ? "http://127.0.0.1:11234" : "http://127.0.0.1:8188";lab.models = []}
                            Spacer()
                            if lab.backend == "Automatic" {Button("Choose engine folder…"){lab.chooseEngine()};Button("Check engine"){lab.connect()}}
                            else {Button("Connect"){lab.connect()}}
                        }
                        if lab.backend != "Automatic" {
                            TextField("Server address",text:$lab.address).textFieldStyle(.roundedBorder)
                            if lab.backend == "MLX-Serve" {
                                HStack {Text("Video model").font(.system(size:11));TextField("Loaded video model ID",text:$lab.model).textFieldStyle(.roundedBorder);if !lab.models.isEmpty {Menu("Choose"){ForEach(lab.models,id:\.self) {id in Button(id){lab.model = id}}}}}
                            } else {
                                HStack {Button("Choose API workflow…"){lab.chooseWorkflow()};Text(lab.workflowName).font(.system(size:10)).foregroundStyle(Ink.quiet);Spacer();TextField("Prompt node ID",text:$lab.promptNode).textFieldStyle(.roundedBorder).frame(width:100)}
                            }
                        }
                        HStack {Text("Uses existing local model files. No download or paid service.").font(.system(size:10)).foregroundStyle(Ink.quiet);Spacer();Button("Show engine log"){lab.revealEngineLog()}.controlSize(.small)}
                    }.padding(.top,10)
                }.font(.system(size:11))
            }.padding(14).background(Ink.base.opacity(0.6),in:RoundedRectangle(cornerRadius:12)).disabled(lab.busy)
            HStack(alignment:.top,spacing:20) {
                VStack(alignment:.leading,spacing:10) {
                    SmallLabel(text:"First-frame reference")
                    if lab.pendingRegeneration != nil {Text("Original clip at its trim point").font(.system(size:11)).foregroundStyle(Ink.quiet)}
                    else {Picker("Reference",selection:$lab.referenceID) {Text("No reference").tag(nil as UUID?);ForEach(store.project.assets.filter {$0.kind == .image}) {media in Text(media.name).tag(Optional(media.id))}}.labelsHidden()}
                    if let id = pendingSource ?? lab.referenceID,let image = store.thumbnails[id] {Image(nsImage:image).resizable().scaledToFit().frame(width:200,height:130).background(Ink.base,in:RoundedRectangle(cornerRadius:6))}
                    else {Image(systemName:"photo").font(.system(size:28,weight:.ultraLight)).foregroundStyle(Ink.quiet).frame(width:200,height:130).background(Ink.base,in:RoundedRectangle(cornerRadius:6))}
                    Text("Use the same cast, wardrobe and light across your reference frames.").font(.system(size:10)).foregroundStyle(Ink.quiet).frame(width:200,alignment:.leading).lineSpacing(3)
                }.frame(width:200)
                VStack(alignment:.leading,spacing:10) {
                    SmallLabel(text:lab.pendingRegeneration == nil ? "Motion direction" : "Requested change")
                    TextEditor(text:creationText).font(.system(size:12)).scrollContentBackground(.hidden).padding(8).frame(height:145).background(Ink.base,in:RoundedRectangle(cornerRadius:7))
                    HStack {
                        Stepper("Seed \(lab.seed)",value:$lab.seed,in:0...999999).font(.system(size:10))
                        Toggle("Keep seed",isOn:$lab.lockSeed).font(.system(size:10)).help("Keep the same seed while comparing prompt changes. Otherwise regeneration uses a new seed.")
                        Spacer()
                        if lab.backend == "Automatic" || lab.backend == "MLX-Serve" {GenerationLengthControl()}
                    }
                    if lab.backend == "MLX-Serve" {
                        HStack {Picker("Size",selection:$lab.width){Text("768 × 448").tag(768);Text("1280 × 704").tag(1280)}.onChange(of:lab.width){_,v in lab.height = v == 768 ? 448 : 704};Stepper("\(lab.steps) steps",value:$lab.steps,in:4...30)}.font(.system(size:11))
                    } else {Text(lab.backend == "Automatic" ? "Draft: 768 × 448. Balanced: 1024 × 576. Cinema: 1280 × 704. Choose 1–10 seconds. Generated length ≈ \(String(format:"%.2f",GenerationTiming.actualSeconds(lab.durationSeconds))) s at 24 fps. References are converted to sRGB; output color metadata is checked." : "Resolution and duration come from your workflow. All LoadImage nodes use this reference.").font(.system(size:10)).foregroundStyle(Ink.quiet)}
                }
            }.disabled(lab.busy)
            Hairline()
            if let progress = lab.progress,lab.busy || progress.stage == .ready {GenerationProgressView(progress:progress)}
            HStack(spacing:10) {if lab.busy && lab.progress == nil {ProgressView().controlSize(.small)};Text(lab.message).font(.system(size:11)).foregroundStyle(Ink.quiet).lineLimit(4);Spacer();if lab.busy {Button("Cancel request"){lab.cancel()}} else {PrimaryButton(title:lab.pendingRegeneration == nil ? "Generate take" : "Regenerate clip",symbol:"sparkles"){
                if lab.pendingRegeneration != nil {lab.resumeRegeneration(store:store)} else {lab.generate(into:store)}
            }.disabled(lab.referenceBusy || !lab.configured || creationText.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}
            Text("Original frame → local AI motion → a separate take. Preview before using it; your edit and sound remain in place. Larger takes can take several minutes.").font(.system(size:9)).foregroundStyle(Ink.quiet)
        }.padding(28).frame(width:760).background(.regularMaterial).foregroundStyle(Ink.text).interactiveDismissDisabled(lab.busy).onDisappear {lab.saveSettings();if !lab.busy {lab.pendingRegeneration = nil}}
    }
}
