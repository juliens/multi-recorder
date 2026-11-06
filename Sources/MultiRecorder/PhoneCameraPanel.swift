import AppKit
import RecorderCore
import SwiftUI

/// Live state of one phone camera, shown in its control panel.
@MainActor
final class PhoneCameraModel: ObservableObject {
    let client: PhoneClient
    @Published private(set) var state: PhoneCameraState?
    @Published private(set) var preview: NSImage?
    @Published private(set) var problem: String?
    /// Last point clicked in the preview, 0...1.
    @Published private(set) var focusPoint: CGPoint?
    @Published private(set) var isApplying = false

    /// Changes waiting to be sent. Slider moves are merged so the phone is not flooded.
    private var pending: [String: any Sendable] = [:]
    private var sending = false

    init(endpoint: PhoneEndpoint) {
        client = PhoneClient(endpoint: endpoint)
    }

    /// Runs while the panel is open.
    func run() async {
        await refresh()
        var tick = 0
        while !Task.isCancelled {
            if let data = try? await client.preview(), let image = NSImage(data: data) {
                preview = image
            }
            tick += 1
            // The recording state can change from the recorder window.
            if tick % 20 == 0, pending.isEmpty, !sending {
                await refresh()
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    func refresh() async {
        do {
            state = try await client.cameraState()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Updates the local value at once and sends it to the phone.
    func set<Value: Sendable>(_ key: String, _ value: Value, local: (inout PhoneCameraState) -> Void) {
        if var updated = state {
            local(&updated)
            state = updated
        }
        pending[key] = value
        sendPending()
    }

    private func sendPending() {
        guard !sending, !pending.isEmpty else { return }
        sending = true
        let changes = pending
        pending = [:]
        let needsRebind = changes.keys.contains { ["front", "orientation", "fps", "stabilization"].contains($0) }
        if needsRebind { isApplying = true }
        Task {
            do {
                let updated = try await client.updateCamera(changes)
                // Keep values the user moved since this request left.
                if pending.isEmpty { state = updated }
                problem = nil
            } catch {
                problem = error.localizedDescription
                await refresh()
            }
            if needsRebind {
                isApplying = false
                focusPoint = nil
            }
            sending = false
            sendPending()
        }
    }

    func focus(at point: CGPoint?) {
        focusPoint = point
        Task {
            do {
                state = try await client.focus(at: point)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Remote control of a phone camera: preview (click to focus), lens, orientation, zoom and picture.
struct PhoneCameraPanel: View {
    @StateObject private var model: PhoneCameraModel
    private let name: String

    init(endpoint: PhoneEndpoint) {
        _model = StateObject(wrappedValue: PhoneCameraModel(endpoint: endpoint))
        name = endpoint.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewArea
                .frame(width: 400, height: 260)

            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            if let state = model.state {
                controls(state)
            } else if model.problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 428)
        .task { await model.run() }
    }

    // MARK: Preview

    private var previewArea: some View {
        GeometryReader { geometry in
            let image = model.preview
            let area = Self.fittedRect(image?.size ?? CGSize(width: 16, height: 9), in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let point = model.focusPoint {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                        .offset(x: area.minX + point.x * area.width - 22, y: area.minY + point.y * area.height - 22)
                        .allowsHitTesting(false)
                }
                if model.isApplying {
                    Text("Applying…")
                        .font(.caption)
                        .padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard image != nil, area.contains(location) else { return }
                model.focus(
                    at: CGPoint(x: (location.x - area.minX) / area.width, y: (location.y - area.minY) / area.height))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("Click to focus and expose on a point.")
    }

    private static func fittedRect(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ state: PhoneCameraState) -> some View {
        let locked = state.recording
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                label("Camera")
                Picker("", selection: binding(\.front, key: "front")) {
                    Text("Back").tag(false)
                    Text("Front").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!state.hasFront || locked)
            }
            GridRow {
                label("Orientation")
                Picker("", selection: binding(\.orientation, key: "orientation", send: \.rawValue)) {
                    ForEach(PhoneOrientation.allCases) { Text($0.label).tag($0) }
                }
                .disabled(locked)
            }
            GridRow {
                label("Frame rate")
                HStack {
                    Picker("", selection: binding(\.fps, key: "fps")) {
                        ForEach(frameRates(state), id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .frame(width: 110)
                    if state.hasStabilization {
                        Toggle("Stabilization", isOn: binding(\.stabilization, key: "stabilization"))
                    }
                }
                .disabled(locked)
            }
            if locked {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("Camera, orientation and frame rate are locked while recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().gridCellColumns(2)

            GridRow {
                label("Zoom")
                zoomControl(state)
            }
            GridRow {
                label("Exposure")
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(model.state?.exposure ?? 0) },
                            set: { value in
                                let index = Int(value.rounded())
                                model.set("exposure", index) { $0.exposure = index }
                            }),
                        in: Double(state.minExposure)...Double(max(state.maxExposure, state.minExposure + 1)))
                    Text(String(format: "%+.1f EV", Double(state.exposure) * state.exposureStep))
                        .font(.caption.monospacedDigit())
                        .frame(width: 58, alignment: .trailing)
                        .onTapGesture(count: 2) { model.set("exposure", 0) { $0.exposure = 0 } }
                }
                .disabled(state.maxExposure <= state.minExposure)
            }
            GridRow {
                label("White balance")
                Picker("", selection: binding(\.whiteBalance, key: "whiteBalance", send: \.rawValue)) {
                    ForEach(PhoneWhiteBalance.allCases) { Text($0.label).tag($0) }
                }
            }
            GridRow {
                label("Lock")
                HStack {
                    Toggle("Exposure", isOn: binding(\.exposureLock, key: "exposureLock"))
                    Toggle("White balance", isOn: binding(\.whiteBalanceLock, key: "whiteBalanceLock"))
                }
            }
            GridRow {
                label("Focus")
                HStack {
                    Text(state.focusSet ? "On the clicked point" : "Automatic")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Automatic") { model.focus(at: nil) }
                        .disabled(!state.focusSet && model.focusPoint == nil)
                }
            }
            if state.hasTorch {
                GridRow {
                    label("Light")
                    Toggle("Torch", isOn: binding(\.torch, key: "torch"))
                }
            }
        }
        .controlSize(.small)
    }

    private func zoomControl(_ state: PhoneCameraState) -> some View {
        let low = max(state.minZoom, 0.1)
        let high = max(state.maxZoom, low + 0.01)
        let presets = [0.5, 1, 2, 5, 10].filter { $0 >= low - 0.001 && $0 <= high + 0.001 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Logarithmic: each doubling takes the same slider length.
                Slider(
                    value: Binding(
                        get: { log(max(model.state?.zoom ?? 1, low)) },
                        set: { value in
                            let zoom = (exp(value) * 100).rounded() / 100
                            model.set("zoom", zoom) { $0.zoom = zoom }
                        }),
                    in: log(low)...log(high))
                Text(String(format: "%.1f×", state.zoom))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 4) {
                ForEach(presets, id: \.self) { value in
                    Button(value < 1 ? String(format: "%.1f×", value) : "\(Int(value))×") {
                        model.set("zoom", value) { $0.zoom = value }
                    }
                }
            }
        }
    }

    private func frameRates(_ state: PhoneCameraState) -> [Int] {
        let rates = Set(state.frameRates + [state.fps]).filter { [24, 25, 30, 60].contains($0) || $0 == state.fps }
        return rates.sorted()
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func binding<Value: Sendable>(_ path: WritableKeyPath<PhoneCameraState, Value>, key: String)
        -> Binding<Value>
    {
        binding(path, key: key, send: { $0 })
    }

    /// A binding on one setting that sends `send(value)` to the phone under `key`.
    private func binding<Value, Sent: Sendable>(
        _ path: WritableKeyPath<PhoneCameraState, Value>, key: String, send: @escaping (Value) -> Sent
    ) -> Binding<Value> {
        Binding(
            get: { model.state![keyPath: path] },
            set: { value in model.set(key, send(value)) { $0[keyPath: path] = value } })
    }
}
