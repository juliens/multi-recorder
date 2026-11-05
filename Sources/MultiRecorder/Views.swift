import AVFoundation
import RecorderCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        HSplitView {
            SettingsView()
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            VStack(spacing: 0) {
                PreviewGrid(previews: model.previews)
                Divider()
                AudioMetersView()
                Divider()
                ControlBar()
            }
            .frame(minWidth: 600)
        }
        .alert(
            "Camera or microphone access is missing",
            isPresented: $model.permissionMissing
        ) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        } message: {
            Text("Allow MultiRecorder in System Settings > Privacy & Security, then restart the app.")
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        Form {
            Section("Cameras") {
                if model.cameras.isEmpty {
                    Text("No camera found.").foregroundStyle(.secondary)
                }
                ForEach(model.cameras) { camera in
                    CameraRow(camera: camera)
                }
            }

            Section("Audio") {
                Picker(
                    "Device",
                    selection: Binding(
                        get: { model.audioDeviceID },
                        set: { model.selectAudioDevice($0) }
                    )
                ) {
                    Text("None").tag(String?.none)
                    ForEach(model.audioDevices) { device in
                        Text("\(device.name) (\(device.channelCount) ch)").tag(Optional(device.id))
                    }
                }
                if let device = model.selectedAudioDevice {
                    Text("\(device.channelCount) channels, \(Int(device.sampleRate)) Hz")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recording") {
                Picker("Video codec", selection: $model.codec) {
                    ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Also create combined.mov", isOn: $model.combineAfterRecording)
                LabeledContent("Folder") {
                    Text(model.outputRoot.path(percentEncoded: false))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose…") { model.chooseOutputFolder() }
                    Button("Refresh devices") { model.refreshDevices() }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.state.isBusy)
    }
}

struct CameraRow: View {
    @EnvironmentObject private var model: RecorderModel
    let camera: CameraInfo

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(
                camera.name,
                isOn: Binding(
                    get: { model.enabledCameraIDs.contains(camera.id) },
                    set: { model.setCamera(camera.id, enabled: $0) }
                ))
            if model.enabledCameraIDs.contains(camera.id), !camera.formats.isEmpty {
                Picker(
                    "Format",
                    selection: Binding(
                        get: { model.formatSelection[camera.id] ?? camera.formats[0].id },
                        set: { model.setFormat($0, for: camera.id) }
                    )
                ) {
                    ForEach(camera.formats) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
            }
        }
    }
}

// MARK: Previews

struct PreviewGrid: View {
    let previews: [PreviewHandle]

    var body: some View {
        GeometryReader { geometry in
            if previews.isEmpty {
                Text("No camera selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let columns = Int(Double(previews.count).squareRoot().rounded(.up))
                let rows = Int((Double(previews.count) / Double(columns)).rounded(.up))
                let height = max(80, (geometry.size.height - CGFloat(rows + 1) * 8) / CGFloat(rows))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    ForEach(previews) { preview in
                        CameraPreviewView(layer: preview.layer)
                            .frame(height: height)
                            .overlay(alignment: .topLeading) {
                                Text(preview.name)
                                    .font(.caption)
                                    .padding(4)
                                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.white)
                                    .padding(6)
                            }
                    }
                }
                .padding(8)
            }
        }
        .background(Color.black.opacity(0.9))
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.show(layer)
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        view.show(layer)
    }
}

final class PreviewHostView: NSView {
    private var preview: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ newLayer: CALayer) {
        guard newLayer !== preview else { return }
        preview?.removeFromSuperlayer()
        newLayer.frame = bounds
        newLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(newLayer)
        preview = newLayer
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: Audio meters

struct AudioMetersView: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        let count = model.selectedAudioDevice?.channelCount ?? 0
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                if count == 0 {
                    Text("No audio device").foregroundStyle(.secondary)
                }
                ForEach(0..<count, id: \.self) { channel in
                    ChannelMeter(
                        channel: channel,
                        level: channel < model.levels.count ? model.levels[channel] : 0,
                        enabled: Binding(
                            get: { model.enabledChannels.contains(channel) },
                            set: { isOn in
                                if isOn {
                                    model.enabledChannels.insert(channel)
                                } else {
                                    model.enabledChannels.remove(channel)
                                }
                            }
                        )
                    )
                    .disabled(model.state.isBusy)
                }
            }
            .padding(10)
        }
        .frame(height: 150)
    }
}

struct ChannelMeter: View {
    let channel: Int
    let level: Float
    @Binding var enabled: Bool

    private var decibels: Double {
        level > 0 ? 20 * log10(Double(level)) : -120
    }

    /// 0...1, with -60 dBFS at the bottom.
    private var fill: Double {
        min(1, max(0, (decibels + 60) / 60))
    }

    private var color: Color {
        if decibels > -3 { return .red }
        if decibels > -12 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.25))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(enabled ? 1 : 0.35))
                        .frame(height: geometry.size.height * fill)
                }
            }
            .frame(width: 18)
            Toggle("\(channel + 1)", isOn: $enabled)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }
}

// MARK: Controls

struct ControlBar: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        HStack(spacing: 16) {
            Button(action: model.toggleRecording) {
                HStack {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                    Text(buttonTitle)
                }
                .frame(minWidth: 110)
            }
            .controlSize(.large)
            .tint(isRecording ? .gray : .red)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.state == .finishing || model.state == .combining)

            if case let .recording(since) = model.state {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.format(context.date.timeIntervalSince(since)))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            if let status = model.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            Spacer()

            if model.lastFolder != nil {
                Button("Show in Finder") { model.revealLastFolder() }
                    .disabled(model.state.isBusy)
            }
        }
        .padding(12)
    }

    private var isRecording: Bool {
        if case .recording = model.state { return true }
        return false
    }

    private var buttonTitle: String {
        switch model.state {
        case .idle: "Record"
        case .recording: "Stop"
        case .finishing: "Finishing…"
        case .combining: "Combining…"
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
