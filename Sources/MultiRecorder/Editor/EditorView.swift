import AVFoundation
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @StateObject private var model: EditorModel
    @State private var showExport = false

    init(folder: URL) {
        _model = StateObject(wrappedValue: EditorModel(folder: folder))
    }

    var body: some View {
        VSplitView {
            PlayerView(player: model.player)
                .frame(minHeight: 200, idealHeight: 380)
            VStack(spacing: 0) {
                TransportBar(showExport: $showExport)
                Divider()
                TracksTimeline()
            }
            .frame(minHeight: 220)
        }
        .environmentObject(model)
        .navigationTitle(model.folder.lastPathComponent)
        .frame(minWidth: 900, minHeight: 600)
        .task { await model.load() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showExport) {
            ExportSheet().environmentObject(model)
        }
    }
}

// MARK: Player

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.show(layer)
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {}
}

// MARK: Transport

struct TransportBar: View {
    @EnvironmentObject private var model: EditorModel
    @Binding var showExport: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.seek(to: 0)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Go to start")

            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            Button(action: model.toggleLoop) {
                Image(systemName: "repeat")
                    .foregroundStyle(model.isLooping ? Color.accentColor : Color.primary)
            }
            .keyboardShortcut("l", modifiers: [])
            .help("Loop (L). Drag in the ruler to choose the looped part, double-click it to loop everything.")

            // Invisible buttons give the arrow keys a one second step.
            Button("") { model.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
            Button("") { model.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)

            Text("\(TimeFormat.long(model.currentTime)) / \(TimeFormat.long(model.duration))")
                .font(.system(.body, design: .monospaced))

            Spacer()

            if let status = model.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let progress = model.exportProgress {
                ProgressView(value: progress)
                    .frame(width: 140)
                Button("Cancel", action: model.cancelExport)
            }

            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { log(model.pixelsPerSecond) },
                    set: { model.pixelsPerSecond = exp($0) }
                ),
                in: log(EditorModel.minPixelsPerSecond)...log(EditorModel.maxPixelsPerSecond)
            )
            .frame(width: 140)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
            Button("Fit", action: model.fitToWindow)

            Button("Export…") { showExport = true }
                .disabled(!model.canExport)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

enum TimeFormat {
    /// "01:02.50" or "1:02:03.50".
    static func long(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let hundredths = Int((value * 100).rounded(.down)) % 100
        let total = Int(value)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d.%02d", total / 3600, total / 60 % 60, total % 60, hundredths)
        }
        return String(format: "%02d:%02d.%02d", total / 60, total % 60, hundredths)
    }

    /// "0:05", "1:30" or "1:00:00" for ruler labels.
    static func short(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Export

struct ExportSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var sizeChoice = 0
    @State private var codec: ExportCodec = .h264
    @State private var useMP4 = true

    private var sizes: [(label: String, size: CGSize)] {
        let source = model.sourceSize
        return [
            ("Source (\(Int(source.width))×\(Int(source.height)))", source),
            ("3840×2160", CGSize(width: 3840, height: 2160)),
            ("1920×1080", CGSize(width: 1920, height: 1080)),
            ("1280×720", CGSize(width: 1280, height: 720)),
        ]
    }

    var body: some View {
        Form {
            Picker("Size", selection: $sizeChoice) {
                ForEach(sizes.indices, id: \.self) { Text(sizes[$0].label).tag($0) }
            }
            Picker("Codec", selection: $codec) {
                ForEach(ExportCodec.allCases) { Text($0.label).tag($0) }
            }
            Picker("Format", selection: $useMP4) {
                Text("MP4").tag(true)
                Text("QuickTime (.mov)").tag(false)
            }
            Text("Audio is mixed to stereo AAC with the track volumes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export…", action: chooseFileAndExport)
            }
        }
    }

    private func chooseFileAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [useMP4 ? .mpeg4Movie : .quickTimeMovie]
        panel.directoryURL = model.folder
        panel.nameFieldStringValue = "\(model.folder.lastPathComponent)_edit.\(useMP4 ? "mp4" : "mov")"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let options = ExportOptions(
            renderSize: sizes[sizeChoice].size, codec: codec, fileType: useMP4 ? .mp4 : .mov)
        model.export(options: options, to: url)
        dismiss()
    }
}
