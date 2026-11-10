import SwiftUI
import AppKit

@MainActor
final class ApplicationDelegate:NSObject,NSApplicationDelegate {
    weak var store:StudioStore?
    private var keys:Any?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        keys = NSEvent.addLocalMonitorForEvents(matching:.keyDown) {[weak self] event in
            guard let self,let store = self.store,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !event.modifierFlags.contains(.command),!event.modifierFlags.contains(.option),!event.modifierFlags.contains(.control),
                  NSApp.keyWindow?.sheetParent == nil,NSApp.keyWindow?.attachedSheet == nil else {return event}
            switch event.keyCode {
            case 49:store.togglePlay();return nil
            case 123:store.seek(store.time - (event.modifierFlags.contains(.shift) ? 1 : 1/Double(store.project.fps)));return nil
            case 124:store.seek(store.time + (event.modifierFlags.contains(.shift) ? 1 : 1/Double(store.project.fps)));return nil
            case 51:store.removeSelected();return nil
            default:return event
            }
        }
    }
    func applicationWillTerminate(_ notification:Notification) {store?.persist()}
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        if let file = filenames.first {store?.openProject(URL(fileURLWithPath:file))}
        sender.reply(toOpenOrPrint:.success)
    }
}

@main
struct StillroomApp:App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var store = StudioStore()
    var body:some Scene {
        WindowGroup("Stillroom Studio") {
            StudioView().environmentObject(store).environmentObject(store.generation).onAppear {delegate.store = store}
        }
        .windowStyle(.titleBar)
        .defaultSize(width:1500,height:980)
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("New Film"){store.newProject()}.keyboardShortcut("n")
                Button("Open Project…"){store.openProjectPanel()}.keyboardShortcut("o")
                Button("Load Example Film"){store.resetDemo()}
                Button("Show Recovery Files"){store.showRecovery()}
            }
            CommandGroup(replacing:.saveItem) {
                Button("Save Portable Project"){store.saveProject()}.keyboardShortcut("s")
                Button("Save Project As…"){store.saveAs()}.keyboardShortcut("s",modifiers:[.command,.shift])
                Button("Export Film…"){store.exportMovie()}.keyboardShortcut("e")
            }
            CommandGroup(replacing:.undoRedo) {
                Button("Undo Edit"){store.undo()}.keyboardShortcut("z")
                Button("Redo Edit"){store.redo()}.keyboardShortcut("z",modifiers:[.command,.shift])
            }
            CommandMenu("Film") {
                Button("Import Media…"){store.importPanel()}.keyboardShortcut("i")
                Button("Split at Playhead"){store.split()}.keyboardShortcut("b")
                Button("Local Creation…"){store.showLab = true}.keyboardShortcut("g")
                Button("Edit Assistant…"){store.showAssistant = true}.keyboardShortcut("a",modifiers:[.command,.shift])
                Button("Storyboard…"){store.showStoryboard = true}.keyboardShortcut("b",modifiers:[.command,.shift])
                Divider()
                Button("Import Captions…"){store.importSubtitles()}
                Button("Export Captions…"){store.exportSRT()}
            }
            CommandMenu("Workspace") {
                Toggle("Show Library",isOn:$store.showLibrary).keyboardShortcut("1",modifiers:[.command,.option])
                Toggle("Show Inspector",isOn:$store.showInspector).keyboardShortcut("2",modifiers:[.command,.option])
                Toggle("Show Timeline",isOn:$store.showTimeline).keyboardShortcut("3",modifiers:[.command,.option])
            }
        }
    }
}
