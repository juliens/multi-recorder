import AVFoundation

/// The audio interface inside the shared capture session.
/// Computes channel levels all the time and writes one mono WAV file per selected channel.
final class AudioPipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let device: AVCaptureDevice
    let input: AVCaptureDeviceInput
    let output = AVCaptureAudioDataOutput()

    /// Peak level (linear, 0...1) per channel, called about 20 times per second on the audio queue.
    var onLevels: (([Float]) -> Void)?

    private let queue: DispatchQueue
    private var connection: AVCaptureConnection?
    private var attachedInput = false
    private var attachedOutput = false

    // Only touched on `queue`.
    private var converter: AVAudioConverter?
    private var cachedDescription: CMFormatDescription?
    private var cachedFormat: AVAudioFormat?
    private var peaks: [Float] = []
    private var lastLevelsTime: CFAbsoluteTime = 0
    private var job: AudioJob?

    init(device: AVCaptureDevice) throws {
        self.device = device
        input = try AVCaptureDeviceInput(device: device)
        queue = DispatchQueue(label: "audio.\(device.uniqueID)", qos: .userInteractive)
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    // MARK: Session wiring

    func attach(to session: AVCaptureSession) throws {
        let name = device.localizedName
        guard session.canAddInput(input) else { throw EngineError.cannotAdd(name) }
        session.addInputWithNoConnections(input)
        attachedInput = true

        guard session.canAddOutput(output) else {
            detach(from: session)
            throw EngineError.cannotAdd(name)
        }
        session.addOutputWithNoConnections(output)
        attachedOutput = true

        let ports = input.ports.filter { $0.mediaType == .audio }
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard !ports.isEmpty, session.canAddConnection(connection) else {
            detach(from: session)
            throw EngineError.cannotAdd(name)
        }
        session.addConnection(connection)
        self.connection = connection
    }

    func detach(from session: AVCaptureSession) {
        if let connection { session.removeConnection(connection) }
        connection = nil
        if attachedOutput { session.removeOutput(output) }
        if attachedInput { session.removeInput(input) }
        attachedOutput = false
        attachedInput = false
    }

    // MARK: Recording

    func begin(folder: URL, channels: [Int], start: CMTime) {
        let newJob = AudioJob(folder: folder, channels: channels, source: device.localizedName, start: start)
        queue.async { self.job = newJob }
    }

    func end(at end: CMTime, completion: @escaping ([RecordedTrack]) -> Void) {
        queue.async {
            guard let job = self.job else {
                completion([])
                return
            }
            job.end = end
            job.completion = completion
            self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.job === job else { return }
                self.finish(job)
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = floatBuffer(from: sampleBuffer) else { return }
        updateLevels(buffer)

        guard let job, job.error == nil else { return }

        let start = sampleBuffer.presentationTimeStamp
        let frames = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let range = Timing.frameRange(
            bufferStart: start, frameCount: frames, sampleRate: sampleRate,
            start: job.start, end: job.end)
        do {
            try job.write(buffer, range: range)
        } catch {
            job.error = error
        }

        if let end = job.end,
            Timing.bufferEnd(bufferStart: start, frameCount: frames, sampleRate: sampleRate) >= end
        {
            finish(job)
        }
    }

    private func finish(_ job: AudioJob) {
        guard self.job === job else { return }
        self.job = nil
        job.finish()
    }

    // MARK: Buffers and levels

    /// Converts the device buffer to non-interleaved Float32, keeping every channel.
    private func floatBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
            let sourceFormat = audioFormat(for: description)
        else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        source.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        if sourceFormat.commonFormat == .pcmFormatFloat32, !sourceFormat.isInterleaved {
            return source
        }

        if converter?.inputFormat != sourceFormat {
            converter = makeConverter(from: sourceFormat)
        }
        guard let converter,
            let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frames)
        else {
            return nil
        }
        do {
            try converter.convert(to: converted, from: source)
        } catch {
            return nil
        }
        return converted
    }

    /// Builds the format from the stream description.
    /// `AVAudioFormat(cmAudioFormatDescription:)` returns an invalid format for some
    /// multi-channel interfaces, so it is not used.
    private func audioFormat(for description: CMFormatDescription) -> AVAudioFormat? {
        if let cachedDescription, let cachedFormat, CFEqual(cachedDescription, description) {
            return cachedFormat
        }
        guard let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = pointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0 else { return nil }

        let format: AVAudioFormat?
        if let layout = Self.channelLayout(channels: asbd.mChannelsPerFrame) {
            format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
        } else {
            format = AVAudioFormat(streamDescription: &asbd)
        }
        cachedDescription = description
        cachedFormat = format
        return format
    }

    /// More than 2 channels need a layout. Discrete channels keep the interface order.
    private static func channelLayout(channels: AVAudioChannelCount) -> AVAudioChannelLayout? {
        guard channels > 2 else { return nil }
        return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
    }

    private func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        // Same layout on both sides, so the converter does not mix or reorder channels.
        let target: AVAudioFormat?
        if let layout = Self.channelLayout(channels: format.channelCount) {
            target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                interleaved: false, channelLayout: layout)
        } else {
            target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                channels: format.channelCount, interleaved: false)
        }
        guard let target else { return nil }
        return AVAudioConverter(from: format, to: target)
    }

    private func updateLevels(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if peaks.count != channels {
            peaks = Array(repeating: 0, count: channels)
        }
        for channel in 0..<channels {
            var peak = peaks[channel]
            let samples = data[channel]
            for index in 0..<frames {
                peak = max(peak, abs(samples[index]))
            }
            peaks[channel] = peak
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelsTime >= 0.05 {
            lastLevelsTime = now
            onLevels?(peaks)
            peaks = Array(repeating: 0, count: channels)
        }
    }
}

/// Mono WAV files being written. Only used on the audio queue.
private final class AudioJob {
    let folder: URL
    let channels: [Int]
    let source: String
    let start: CMTime

    var end: CMTime?
    var completion: (([RecordedTrack]) -> Void)?
    var error: Error?

    private var files: [Int: AVAudioFile] = [:]
    private var written: [Int: Int] = [:]
    private var mono: AVAudioPCMBuffer?

    init(folder: URL, channels: [Int], source: String, start: CMTime) {
        self.folder = folder
        self.channels = channels
        self.source = source
        self.start = start
    }

    func write(_ buffer: AVAudioPCMBuffer, range: Range<Int>) throws {
        guard !range.isEmpty, let data = buffer.floatChannelData else { return }
        let sampleRate = buffer.format.sampleRate
        if files.isEmpty {
            try openFiles(sampleRate: sampleRate, availableChannels: Int(buffer.format.channelCount))
        }

        let count = range.count
        if mono == nil || mono!.frameCapacity < AVAudioFrameCount(count) || mono!.format.sampleRate != sampleRate {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: 1, interleaved: false)!
            mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(count, 4096)))
        }
        guard let mono, let target = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(count)

        for (channel, file) in files {
            target.update(from: data[channel] + range.lowerBound, count: count)
            try file.write(from: mono)
            written[channel, default: 0] += count
        }
    }

    private func openFiles(sampleRate: Double, availableChannels: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        for channel in channels where channel < availableChannels {
            let url = folder.appendingPathComponent(FileNaming.audioFileName(channel: channel))
            files[channel] = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    func finish() {
        // Releasing the files closes them and writes the WAV headers.
        files.removeAll()
        let errorText = error?.localizedDescription
        let tracks = channels.map { channel in
            let count = written[channel] ?? 0
            return RecordedTrack(
                kind: .audio, order: channel, source: "\(source) ch\(channel + 1)",
                file: FileNaming.audioFileName(channel: channel),
                samplesWritten: count, samplesDropped: 0,
                error: errorText ?? (count == 0 ? EngineError.noSamples.localizedDescription : nil)
            )
        }
        completion?(tracks)
    }
}
