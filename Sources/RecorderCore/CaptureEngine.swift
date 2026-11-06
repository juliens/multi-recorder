import AVFoundation

/// Owns one capture session with every camera and the audio interface.
/// All sample timestamps come from the session clock, so every file can be cut
/// at the same start and end instants.
public final class CaptureEngine: @unchecked Sendable {
    public let session = AVCaptureSession()

    /// Peak level per audio channel (linear). Set it before `configure`.
    public var onAudioLevels: (([Float]) -> Void)?
    /// Runtime errors reported by the capture session.
    public var onRuntimeError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "capture.engine")
    private var cameras: [String: CameraPipeline] = [:]
    private var cameraOrder: [String] = []
    private var audio: AudioPipeline?
    private var recording: ActiveRecording?
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onRuntimeError?(error?.localizedDescription ?? "Capture session error.")
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Configuration

    /// Adds, removes and configures devices so the session matches the request.
    public func configure(cameras requests: [CameraRequest], audioDeviceID: String?) async throws -> ConfigureResult {
        try await run { try self.configureSync(requests, audioDeviceID) }
    }

    private func configureSync(_ requests: [CameraRequest], _ audioDeviceID: String?) throws -> ConfigureResult {
        guard recording == nil else { throw EngineError.busy }
        var warnings: [String] = []
        let wanted = Set(requests.map(\.deviceID))

        session.beginConfiguration()

        for (id, pipeline) in cameras where !wanted.contains(id) {
            pipeline.detach(from: session)
            cameras[id] = nil
        }
        for request in requests where cameras[request.deviceID] == nil {
            guard let device = AVCaptureDevice(uniqueID: request.deviceID) else {
                warnings.append("Camera not found: \(request.deviceID)")
                continue
            }
            do {
                let pipeline = try CameraPipeline(device: device)
                try pipeline.attach(to: session)
                cameras[request.deviceID] = pipeline
            } catch {
                warnings.append(error.localizedDescription)
            }
        }

        if audio?.device.uniqueID != audioDeviceID {
            audio?.detach(from: session)
            audio = nil
            if let audioDeviceID {
                if let device = AVCaptureDevice(uniqueID: audioDeviceID) {
                    do {
                        let pipeline = try AudioPipeline(device: device)
                        pipeline.onLevels = onAudioLevels
                        try pipeline.attach(to: session)
                        audio = pipeline
                    } catch {
                        warnings.append(error.localizedDescription)
                    }
                } else {
                    warnings.append("Audio device not found: \(audioDeviceID)")
                }
            }
        }

        applyFormats(requests)
        session.commitConfiguration()

        let hasDevices = !cameras.isEmpty || audio != nil
        if hasDevices, !session.isRunning {
            session.startRunning()
        } else if !hasDevices, session.isRunning {
            session.stopRunning()
        }
        // The session may pick its own format when it starts, so set ours again.
        applyFormats(requests)

        cameraOrder = requests.map(\.deviceID).filter { cameras[$0] != nil }
        let previews = cameraOrder.compactMap { id -> PreviewHandle? in
            guard let pipeline = cameras[id] else { return nil }
            return PreviewHandle(id: id, name: pipeline.device.localizedName, layer: pipeline.previewLayer)
        }
        return ConfigureResult(previews: previews, warnings: warnings)
    }

    private func applyFormats(_ requests: [CameraRequest]) {
        for request in requests {
            cameras[request.deviceID]?.applyFormat(id: request.formatID)
        }
    }

    // MARK: Recording

    /// Starts every writer at the same instant. Returns the session folder.
    public func startRecording(into root: URL, options: RecordingOptions) async throws -> URL {
        try await run { try self.startSync(root, options) }
    }

    private func startSync(_ root: URL, _ options: RecordingOptions) throws -> URL {
        guard recording == nil else { throw EngineError.busy }
        let recordAudio = audio != nil && !options.audioChannels.isEmpty
        guard !cameraOrder.isEmpty || recordAudio else { throw EngineError.nothingToRecord }

        let date = Date()
        let folder = uniqueFolder(root.appendingPathComponent(FileNaming.sessionFolderName(date: date)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let start = CMClockGetTime(clock)

        for (index, id) in cameraOrder.enumerated() {
            guard let camera = cameras[id] else { continue }
            let url = folder.appendingPathComponent(
                FileNaming.cameraFileName(
                    index: index + 1,
                    deviceName: camera.device.localizedName))
            camera.begin(url: url, codec: options.codec, order: index + 1, start: start)
        }
        if recordAudio {
            audio?.begin(folder: folder, channels: options.audioChannels, start: start)
        }

        let hostStart = CMSyncConvertTime(start, from: clock, to: CMClockGetHostTimeClock())
        recording = ActiveRecording(
            folder: folder, clock: clock, start: start, hostStart: hostStart.seconds, startedAt: date,
            cameraIDs: cameraOrder, recordsAudio: recordAudio)
        return folder
    }

    /// Stops every writer at the same instant and waits for the files to be closed.
    public func stopRecording() async -> RecordingSummary? {
        await withCheckedContinuation { continuation in
            queue.async { self.stopSync { continuation.resume(returning: $0) } }
        }
    }

    private func stopSync(_ done: @escaping (RecordingSummary?) -> Void) {
        guard let recording else {
            done(nil)
            return
        }
        let end = CMClockGetTime(recording.clock)
        let group = DispatchGroup()
        let lock = NSLock()
        var tracks: [RecordedTrack] = []

        for id in recording.cameraIDs {
            guard let camera = cameras[id] else { continue }
            group.enter()
            camera.end(at: end) { track in
                lock.withLock { tracks.append(track) }
                group.leave()
            }
        }
        if recording.recordsAudio, let audio {
            group.enter()
            audio.end(at: end) { audioTracks in
                lock.withLock { tracks.append(contentsOf: audioTracks) }
                group.leave()
            }
        }

        group.notify(queue: queue) {
            self.recording = nil
            let summary = RecordingSummary(
                folder: recording.folder,
                startedAt: recording.startedAt,
                durationSeconds: (end - recording.start).seconds,
                syncStartSeconds: recording.start.seconds,
                hostStartSeconds: recording.hostStart,
                tracks: lock.withLock { tracks },
                combinedFile: nil
            )
            done(summary)
        }
    }

    // MARK: Helpers

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func uniqueFolder(_ url: URL) -> URL {
        var candidate = url
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)_\(suffix)")
            suffix += 1
        }
        return candidate
    }
}

private struct ActiveRecording {
    let folder: URL
    let clock: CMClock
    let start: CMTime
    /// `start` on the host clock, in seconds.
    let hostStart: Double
    let startedAt: Date
    let cameraIDs: [String]
    let recordsAudio: Bool
}
