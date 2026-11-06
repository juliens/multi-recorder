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
        case importingPhones

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

    /// Phones running MultiRecorder Phone on the local network.
    @Published private(set) var phones: [PhoneEndpoint] = []
    @Published private(set) var enabledPhoneIDs: Set<String> = []
    @Published private(set) var phonePreviews: [String: NSImage] = [:]
    @Published var phoneQuality: PhoneQuality = .fhd
    /// Download of phone clips, 0...1.
    @Published private(set) var phoneProgress: Double?
    /// Why phones cannot be found, for example local network access is off.
    @Published private(set) var phoneProblem: String?

    private let engine = CaptureEngine()
    private let phoneBrowser = PhoneBrowser()
    private let panels = ToolPanels()
    private var previewTask: Task<Void, Never>?
    private var activePhones: [ActivePhone] = []
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
        startPhoneDiscovery()
    }

    // MARK: Phones

    private struct ActivePhone {
        let client: PhoneClient
        let clockOffset: Double
        var clip: PhoneClip?
    }

    private func startPhoneDiscovery() {
        phoneBrowser.onChange = { [weak self] list in
            MainActor.assumeIsolated { self?.phonesChanged(list) }
        }
        phoneBrowser.onProblem = { [weak self] problem in
            MainActor.assumeIsolated { self?.phoneProblem = problem }
        }
        phoneBrowser.start()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPhonePreviews()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func phonesChanged(_ list: [PhoneEndpoint]) {
        let known = Set(phones.map(\.id))
        phones = list
        // New phones are used by default, like cameras.
        for phone in list where !known.contains(phone.id) {
            enabledPhoneIDs.insert(phone.id)
        }
        let ids = Set(list.map(\.id))
        if !state.isBusy {
            enabledPhoneIDs.formIntersection(ids)
        }
        phonePreviews = phonePreviews.filter { ids.contains($0.key) }
    }

    /// Opens or closes the camera controls of a phone.
    func togglePhoneCamera(_ phone: PhoneEndpoint) {
        panels.toggle("phone|\(phone.id)", title: "Camera – \(phone.name)") {
            PhoneCameraPanel(endpoint: phone)
        }
    }

    func setPhone(_ id: String, enabled: Bool) {
        if enabled { enabledPhoneIDs.insert(id) } else { enabledPhoneIDs.remove(id) }
    }

    private var enabledPhones: [PhoneEndpoint] {
        phones.filter { enabledPhoneIDs.contains($0.id) }
    }

    private func refreshPhonePreviews() async {
        for phone in enabledPhones {
            if let data = try? await PhoneClient(endpoint: phone).preview(), let image = NSImage(data: data) {
                phonePreviews[phone.id] = image
            }
        }
    }

    /// Measures the clock of every selected phone. Phones that do not answer are skipped.
    private func preparePhones() async -> (ready: [ActivePhone], problems: [String]) {
        await withTaskGroup(of: (ActivePhone?, String?).self) { group in
            for phone in enabledPhones {
                group.addTask {
                    let client = PhoneClient(endpoint: phone)
                    do {
                        let clock = try await client.clockOffset()
                        return (ActivePhone(client: client, clockOffset: clock.offset), nil)
                    } catch {
                        return (nil, "\(phone.name): \(error.localizedDescription)")
                    }
                }
            }
            var ready: [ActivePhone] = []
            var problems: [String] = []
            for await (phone, problem) in group {
                if let phone { ready.append(phone) }
                if let problem { problems.append(problem) }
            }
            ready.sort { $0.client.endpoint.name < $1.client.endpoint.name }
            return (ready, problems)
        }
    }

    private func startPhones(_ phones: [ActivePhone], quality: String) async -> (
        started: [ActivePhone], problems: [String]
    ) {
        await withTaskGroup(of: (Int, PhoneClip?, String?).self) { group in
            for (index, phone) in phones.enumerated() {
                group.addTask {
                    do {
                        return (index, try await phone.client.startRecording(quality: quality), nil)
                    } catch {
                        return (index, nil, "\(phone.client.endpoint.name): \(error.localizedDescription)")
                    }
                }
            }
            var started = phones
            var problems: [String] = []
            for await (index, clip, problem) in group {
                started[index].clip = clip
                if let problem { problems.append(problem) }
            }
            return (started.filter { $0.clip != nil }, problems)
        }
    }

    private func stopPhones(_ phones: [ActivePhone]) async -> (stopped: [ActivePhone], problems: [String]) {
        await withTaskGroup(of: (Int, PhoneClip?, String?).self) { group in
            for (index, phone) in phones.enumerated() {
                group.addTask {
                    do {
                        return (index, try await phone.client.stopRecording(), nil)
                    } catch {
                        return (index, nil, "\(phone.client.endpoint.name): \(error.localizedDescription)")
                    }
                }
            }
            var stopped = phones
            var problems: [String] = []
            for await (index, clip, problem) in group {
                // The start reply holds the start time; keep it, the stop reply has the same clip.
                if clip == nil { stopped[index].clip = nil }
                if let problem { problems.append(problem) }
            }
            return (stopped.filter { $0.clip != nil }, problems)
        }
    }

    /// Downloads the clips one by one and places them on the timeline.
    private func importPhones(_ phones: [ActivePhone], summary: inout RecordingSummary) async -> [String] {
        guard let hostStart = summary.hostStartSeconds else { return ["Phones: the recording start time is unknown."] }
        var messages: [String] = []
        let references = summary.tracks
            .filter { $0.kind == .audio && $0.error == nil }
            .map { summary.folder.appendingPathComponent($0.file) }

        for (index, phone) in phones.enumerated() {
            guard let clip = phone.clip else { continue }
            let total = Double(phones.count)
            phoneProgress = Double(index) / total
            do {
                let result = try await PhoneImport.importClip(
                    clip, from: phone.client, index: index + 1, clockOffset: phone.clockOffset,
                    recordingStart: hostStart, folder: summary.folder, references: references
                ) { value in
                    Task { @MainActor [weak self] in self?.phoneProgress = (Double(index) + value) / total }
                }
                summary.tracks.append(
                    RecordedTrack(
                        kind: .video, order: 100 + index + 1, source: phone.client.endpoint.name,
                        file: result.videoFile, samplesWritten: 0, samplesDropped: 0, error: nil))
                let how =
                    result.placement.method == .audio
                    ? "synced on the sound" : "placed with the network clock (sound did not match)"
                messages.append(
                    "\(phone.client.endpoint.name): \(how), offset \(String(format: "%+.3f", result.placement.offset)) s."
                )
            } catch {
                messages.append("\(phone.client.endpoint.name): \(error.localizedDescription)")
            }
        }
        phoneProgress = nil
        return messages
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
        case .finishing, .combining, .importingPhones: break
        }
    }

    private func startRecording() async {
        let options = RecordingOptions(codec: codec, audioChannels: enabledChannels.sorted())
        // Measure the phone clocks first, so the recording starts without waiting for the network.
        let prepared = await preparePhones()
        do {
            _ = try await engine.startRecording(into: outputRoot, options: options)
            state = .recording(since: Date())
        } catch {
            status = error.localizedDescription
            return
        }
        let started = await startPhones(prepared.ready, quality: phoneQuality.rawValue)
        activePhones = started.started
        let problems = prepared.problems + started.problems
        status = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func stopRecording() async {
        state = .finishing
        async let stoppedPhones = stopPhones(activePhones)
        guard var summary = await engine.stopRecording() else {
            _ = await stoppedPhones
            activePhones = []
            state = .idle
            return
        }
        let phones = await stoppedPhones
        activePhones = []

        var problems =
            phones.problems
            + summary.tracks.compactMap { track in
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

        var notes: [String] = []
        if !phones.stopped.isEmpty {
            state = .importingPhones
            notes = await importPhones(phones.stopped, summary: &summary)
        }

        do {
            try summary.writeManifest()
        } catch {
            problems.append("Cannot write manifest: \(error.localizedDescription)")
        }

        lastFolder = summary.folder
        state = .idle
        let saved = "Saved \(summary.tracks.count) tracks (\(Int(summary.durationSeconds.rounded())) s)."
        status = ([problems.isEmpty ? saved : problems.joined(separator: "\n")] + notes).joined(separator: "\n")
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
