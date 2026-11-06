import AppKit
import SwiftUI

@main
struct MultiRecorderApp: App {
    @StateObject private var model = RecorderModel()

    init() {
        // Needed when the binary runs outside an .app bundle (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("MultiRecorder", id: "recorder") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 650)
                .task { await model.start() }
        }
        .commands {
            OpenRecordingCommands(defaultFolder: model.outputRoot)
        }

        WindowGroup("Editor", id: EditorWindow.id, for: URL.self) { $folder in
            if let folder {
                EditorView(folder: folder)
            }
        }
    }
}

enum EditorWindow {
    static let id = "editor"

    /// Asks for a recording folder.
    @MainActor
    static func chooseFolder(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose a recording folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct OpenRecordingCommands: Commands {
    let defaultFolder: URL
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Recording…") {
                if let folder = EditorWindow.chooseFolder(startingAt: defaultFolder) {
                    openWindow(id: EditorWindow.id, value: folder)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
