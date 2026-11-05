import AVFoundation
import AppKit
import RecorderCore

@MainActor
final class RecorderModel: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case finishing
        case combining

        var isBusy: Bool { self != .idle }
    }

    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var enabledCameraIDs: Set<String> = []
    @Published private(set) var formatSelection: [String: Int] = [:]

    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var audioDeviceID: String?
    @Published var enabledChannels: Set<Int> = []
    @Published private(set) var levels: [Float] = []

    @Published private(set) var previews: [PreviewHandle] = []
    @Published var codec: VideoCodecChoice = .hevc
    @Published var combineAfterRecording = true
    @Published var outputRoot: URL

    @Published private(set) var state: State = .idle
    @Published private(set) var status: String?
    @Published private(set) var lastFolder: URL?
    @Published var permissionMissing = false

    private let engine = CaptureEngine()
    private var applyTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let movies =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        outputRoot = movies.appendingPathComponent("MultiRecorder")

        engine.onAudioLevels = { [weak self] levels in
            DispatchQueue.main.async { self?.levels = levels }
        }
        engine.onRuntimeError = { [weak self] message in
            DispatchQueue.main.async { self?.status = message }
        }

        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshDevices() }
                })
        }
    }

    // MARK: Setup

    func start() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        permissionMissing = !(video && audio)
        refreshDevices()
    }

    func refreshDevices() {
        let firstLoad = cameras.isEmpty && audioDevices.isEmpty
        cameras = DeviceCatalog.cameras()
        audioDevices = DeviceCatalog.audioDevices()

        let cameraIDs = Set(cameras.map(\.id))
        enabledCameraIDs.formIntersection(cameraIDs)
        for camera in cameras where formatSelection[camera.id] == nil {
            formatSelection[camera.id] = camera.activeFormatID ?? camera.formats.first?.id
        }
        if firstLoad {
            enabledCameraIDs = cameraIDs
        }

        if let id = audioDeviceID, !audioDevices.contains(where: { $0.id == id }) {
            audioDeviceID = nil
        }
        if firstLoad, audioDeviceID == nil,
            let device = audioDevices.max(by: { $0.channelCount < $1.channelCount })
        {
            selectAudioDevice(device.id)
            return
        }
        scheduleApply()
    }

    // MARK: Selection

    func setCamera(_ id: String, enabled: Bool) {
        if enabled { enabledCameraIDs.insert(id) } else { enabledCameraIDs.remove(id) }
        scheduleApply()
    }

    func setFormat(_ formatID: Int, for cameraID: String) {
        formatSelection[cameraID] = formatID
        scheduleApply()
    }

    func selectAudioDevice(_ id: String?) {
        audioDeviceID = id
        let count = audioDevices.first { $0.id == id }?.channelCount ?? 0
        enabledChannels = Set(0..<count)
        levels = []
        scheduleApply()
    }

    var selectedAudioDevice: AudioDeviceInfo? {
        audioDevices.first { $0.id == audioDeviceID }
    }

    private func scheduleApply() {
        guard !state.isBusy else { return }
        applyTask?.cancel()
        let requests =
            cameras
            .filter { enabledCameraIDs.contains($0.id) }
            .map { CameraRequest(deviceID: $0.id, formatID: formatSelection[$0.id]) }
        let audioID = audioDeviceID
        applyTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let result = try await engine.configure(cameras: requests, audioDeviceID: audioID)
                previews = result.previews
                status = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        switch state {
        case .idle: Task { await startRecording() }
        case .recording: Task { await stopRecording() }
        case .finishing, .combining: break
        }
    }

    private func startRecording() async {
        let options = RecordingOptions(codec: codec, audioChannels: enabledChannels.sorted())
        do {
            _ = try await engine.startRecording(into: outputRoot, options: options)
            state = .recording(since: Date())
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func stopRecording() async {
        state = .finishing
        guard var summary = await engine.stopRecording() else {
            state = .idle
            return
        }

        var problems = summary.tracks.compactMap { track in
            track.error.map { "\(track.source): \($0)" }
        }
        let dropped = summary.tracks.filter { $0.kind == .video }.reduce(0) { $0 + $1.samplesDropped }
        if dropped > 0 {
            problems.append("\(dropped) video frames dropped.")
        }

        if combineAfterRecording {
            state = .combining
            let inputs = summary.orderedTracks
                .filter { $0.error == nil }
                .map { summary.folder.appendingPathComponent($0.file) }
            do {
                try await Muxer.mux(
                    inputs: inputs,
                    to: summary.folder.appendingPathComponent(FileNaming.combinedFileName))
                summary.combinedFile = FileNaming.combinedFileName
            } catch {
                problems.append("Combine failed: \(error.localizedDescription)")
            }
        }

        do {
            try summary.writeManifest()
        } catch {
            problems.append("Cannot write manifest: \(error.localizedDescription)")
        }

        lastFolder = summary.folder
        state = .idle
        status =
            problems.isEmpty
            ? "Saved \(summary.tracks.count) tracks (\(Int(summary.durationSeconds.rounded())) s)."
            : problems.joined(separator: "\n")
        scheduleApply()
    }

    // MARK: Files

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputRoot
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url
        }
    }

    func revealLastFolder() {
        guard let lastFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFolder])
    }
}
