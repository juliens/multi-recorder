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
        WindowGroup("MultiRecorder") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 650)
                .task { await model.start() }
        }
    }
}
