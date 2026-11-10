import SwiftUI

struct EditAssistantView:View {
    @EnvironmentObject var store:StudioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var assistant:EditAssistant
    @ObservedObject var blender:BlenderAssist
    var blocked:Bool {assistant.busy || blender.busy || store.generation.busy || store.generation.referenceBusy}
    var stale:Bool {assistant.base != nil && assistant.base != store.project}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Edit assistant").font(.system(size:25,weight:.medium,design:.rounded))
                    Text("\(store.project.shots.count) shots · \(store.project.subtitles.count) captions · \(store.project.sounds.count) sound layers · local only").font(.system(size:11)).foregroundStyle(Ink.quiet)
                }
                Spacer()
                Label("Timing protected",systemImage:"lock").font(.system(size:11)).foregroundStyle(Ink.mint).padding(.top,8)
                ToolButton(symbol:"xmark",help:"Close edit assistant"){dismiss()}.disabled(assistant.busy || blender.busy)
            }
            HStack(alignment:.top,spacing:18) {
                VStack(alignment:.leading,spacing:12) {
                    SmallLabel(text:"What should we work on?")
                    TextEditor(text:$assistant.prompt).font(.system(size:13)).scrollContentBackground(.hidden).padding(10).frame(height:145).background(Ink.base,in:RoundedRectangle(cornerRadius:12)).accessibilityLabel("Edit assistant request").disabled(blocked)
                    HStack {
                        preset("Check the edit","Read this edit and identify the most useful next steps to finish it. Give me a few concrete changes or notes. Preserve every shot duration and all caption and sound timing.")
                        preset("Stronger ending","Help the ending feel more deliberate. Suggest a subtle zoom out for the final shot and any useful direction for a future take. Preserve the existing edit length, speed, caption and sound timing.")
                    }
                    preset("Plan a Blender insert","Propose one small Blender photo-card insert for the selected shot, using its current reference and a slow pullback. Explain where this helps and where a new AI performance would be more appropriate. Keep all existing timing.")
                    Divider()
                    Picker("Local chat model",selection:$assistant.modelID) {
                        if assistant.models.isEmpty {Text("Check installed models").tag("")}
                        ForEach(assistant.models) {model in Text(model.name+" · "+model.provider).tag(model.id)}
                    }.font(.system(size:11)).disabled(blocked)
                    HStack {
                        Button("Check models"){Task {await assistant.discover()}}.disabled(blocked)
                        Spacer()
                        if assistant.busy {Button("Cancel"){assistant.cancel()}}
                        else {Button("Prepare edit plan"){assistant.ask(store:store)}.buttonStyle(.borderedProminent).disabled(blocked || assistant.modelID.isEmpty || assistant.prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                    }
                    if assistant.busy {
                        HStack(spacing:8) {ProgressView().controlSize(.small);SwiftUI.TimelineView(.periodic(from:.now,by:1)) {context in Text("Thinking · "+GenerationProgress.clock(context.date.timeIntervalSince(assistant.started ?? context.date))).font(.system(size:11,design:.monospaced))}}
                    }
                    Text(assistant.message).font(.system(size:11)).foregroundStyle(Ink.quiet).textSelection(.enabled)
                    Text("The assistant reads names, notes, prompts and timing. It does not watch footage or listen to the mix. Proposed edits keep every slot, caption cue and sound position; apply them after review.").font(.system(size:10)).foregroundStyle(Ink.quiet).lineSpacing(3)
                    Spacer(minLength:0)
                    blenderSettings
                }.frame(width:350)
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        SmallLabel(text:"Proposed edits")
                        Spacer()
                        if let plan = assistant.plan {
                            Text("\(plan.suggestions.count) suggestions").font(.system(size:10)).foregroundStyle(Ink.quiet)
                        }
                    }
                    if let plan = assistant.plan {
                        ScrollView {
                            VStack(alignment:.leading,spacing:12) {
                                Text(plan.summary).font(.system(size:13)).lineSpacing(4).textSelection(.enabled)
                                if stale {Label("The timeline changed. Prepare a fresh plan before applying edits.",systemImage:"arrow.clockwise").font(.system(size:11)).foregroundStyle(.orange)}
                                ForEach(plan.suggestions) {suggestion in suggestionCard(suggestion)}
                            }.padding(.trailing,4)
                        }
                        HStack {
                            Text("One Undo reverses an applied group.").font(.system(size:10)).foregroundStyle(Ink.quiet)
                            Spacer()
                            Button("Apply selected edits"){assistant.apply(store:store)}.buttonStyle(.borderedProminent).disabled(blocked || stale || assistant.selected.isEmpty)
                        }
                    } else {
                        ContentUnavailableView("A collaborator for the unfinished edit",systemImage:"bubble.left.and.text.bubble.right",description:Text("Ask for a clearer ending, a shot direction, a caption revision or a small Blender insert. Review a concrete plan before the edit changes."))
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
        }.padding(24).frame(width:1050,height:790).background(.regularMaterial)
        .interactiveDismissDisabled(assistant.busy || blender.busy)
        .task {if assistant.models.isEmpty {await assistant.discover()}}
    }
    private func preset(_ title:String,_ prompt:String)->some View {
        Button(title){assistant.prompt = prompt}.font(.system(size:10)).disabled(blocked)
    }
    private func suggestionCard(_ item:EditSuggestion)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top) {
                if item.editable {
                    Toggle(isOn:Binding(get:{assistant.selected.contains(item.id)},set:{value in if value {assistant.selected.insert(item.id)} else {assistant.selected.remove(item.id)}})) {Text(item.title).font(.system(size:12,weight:.semibold))}.toggleStyle(.checkbox).disabled(blocked || stale || assistant.applied.contains(item.id))
                } else {Label(item.title,systemImage:item.kind == .blender ? "cube.transparent" : "text.bubble").font(.system(size:12,weight:.semibold))}
                Spacer()
                if assistant.applied.contains(item.id) {Label("Applied",systemImage:"checkmark").font(.system(size:10)).foregroundStyle(Ink.mint)}
            }
            Text(item.reason).font(.system(size:11)).foregroundStyle(Ink.quiet).lineSpacing(2).textSelection(.enabled)
            Text(item.preview(in:assistant.base ?? store.project)).font(.system(size:11)).lineSpacing(2).textSelection(.enabled)
            if item.kind == .blender {
                HStack {
                    Text(blender.detail ? "1080p · separate take" : "540p preview · separate take").font(.system(size:10)).foregroundStyle(Ink.quiet)
                    Spacer()
                    Button("Render Blender insert"){blender.render(item,store:store)}.disabled(blocked || stale || !blender.available)
                }
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Ink.base,in:RoundedRectangle(cornerRadius:12))
    }
    private var blenderSettings:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {Label("Blender assist",systemImage:"cube.transparent").font(.system(size:12,weight:.medium));Spacer();Button(blender.available ? "Change…" : "Connect Blender…"){blender.choose()}.font(.system(size:10)).disabled(blocked)}
            Toggle("Render at 1080p",isOn:$blender.detail).font(.system(size:11)).disabled(blocked)
            if blender.busy {ProgressView(value:blender.progress);Button("Cancel Blender render"){blender.cancel()}.font(.system(size:10))}
            Text(blender.message).font(.system(size:10)).foregroundStyle(Ink.quiet).lineLimit(4).textSelection(.enabled)
            if let id = blender.candidateID,let media = store.project.assets.first(where:{$0.id == id}) {
                HStack {
                    Button("Review render"){store.previewTake(media);dismiss()}
                    if let shotID = blender.resultShotID,store.project.shots.contains(where:{$0.id == shotID}) {
                        Button("Use render · keep timing"){store.useTake(media,for:shotID,keepTiming:true);dismiss()}
                    }
                }.font(.system(size:10)).disabled(blocked)
            }
        }.padding(12).background(Ink.base,in:RoundedRectangle(cornerRadius:12))
    }
}
