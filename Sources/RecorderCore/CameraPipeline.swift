import AVFoundation

/// One camera inside the shared capture session: preview, frame output and movie writer.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let device: AVCaptureDevice
    let input: AVCaptureDeviceInput
    let output = AVCaptureVideoDataOutput()
    /// Shows the frames received by `output`, so the preview is exactly what gets recorded.
    let previewLayer = AVSampleBufferDisplayLayer()

    private let queue: DispatchQueue
    private var connections: [AVCaptureConnection] = []
    private var attachedInput = false
    private var attachedOutput = false

    /// Only touched on `queue`.
    private var job: VideoJob?

    init(device: AVCaptureDevice) throws {
        self.device = device
        input = try AVCaptureDeviceInput(device: device)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        queue = DispatchQueue(label: "camera.\(device.uniqueID)", qos: .userInitiated)
        super.init()

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    // MARK: Session wiring (called inside begin/commitConfiguration)

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

        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            detach(from: session)
            throw EngineError.cannotAdd(name)
        }

        let dataConnection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(dataConnection) else {
            detach(from: session)
            throw EngineError.cannotAdd(name)
        }
        session.addConnection(dataConnection)
        connections.append(dataConnection)
    }

    func detach(from session: AVCaptureSession) {
        connections.forEach(session.removeConnection)
        connections.removeAll()
        if attachedOutput { session.removeOutput(output) }
        if attachedInput { session.removeInput(input) }
        attachedOutput = false
        attachedInput = false
    }

    /// Sets the device format and its highest frame rate.
    func applyFormat(id: Int?) {
        guard let id, device.formats.indices.contains(id) else { return }
        let format = device.formats[id]
        guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return
        }
        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
        } catch {
            // The camera keeps its current format.
        }
    }

    // MARK: Recording

    func begin(url: URL, codec: VideoCodecChoice, order: Int, start: CMTime) {
        let seconds = device.activeVideoMinFrameDuration.seconds
        let frameRate = seconds.isFinite && seconds > 0 ? 1 / seconds : 30
        let newJob = VideoJob(
            url: url, codec: codec, order: order, source: device.localizedName,
            start: start, frameRate: frameRate)
        queue.async { self.job = newJob }
    }

    /// Stops at `end`. Frames captured before `end` may still be in flight, so the writer
    /// closes on the first frame at or after `end`, or after a short timeout.
    func end(at end: CMTime, completion: @escaping (RecordedTrack) -> Void) {
        queue.async {
            guard let job = self.job else {
                completion(
                    RecordedTrack(
                        kind: .video, order: 0, source: self.device.localizedName, file: "",
                        samplesWritten: 0, samplesDropped: 0,
                        error: EngineError.notRecording.localizedDescription))
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
        showPreview(sampleBuffer)

        guard let job, job.error == nil else { return }

        let pts = sampleBuffer.presentationTimeStamp
        if pts < job.start { return }
        if let end = job.end, pts >= end {
            finish(job)
            return
        }

        do {
            try job.append(sampleBuffer)
        } catch {
            job.error = error
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        job?.dropped += 1
    }

    private func finish(_ job: VideoJob) {
        guard self.job === job else { return }
        self.job = nil
        job.finish()
    }

    private func showPreview(_ sampleBuffer: CMSampleBuffer) {
        let renderer = previewLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }

        // Live preview: show each frame now instead of waiting for its timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sampleBuffer)
    }
}

/// State of one movie file being written. Only used on the camera queue.
private final class VideoJob {
    let url: URL
    let codec: VideoCodecChoice
    let order: Int
    let source: String
    let start: CMTime
    let frameRate: Double

    var end: CMTime?
    var completion: ((RecordedTrack) -> Void)?
    var error: Error?
    var written = 0
    var dropped = 0

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    init(url: URL, codec: VideoCodecChoice, order: Int, source: String, start: CMTime, frameRate: Double) {
        self.url = url
        self.codec = codec
        self.order = order
        self.source = source
        self.start = start
        self.frameRate = frameRate
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        if writer == nil {
            try makeWriter(for: sampleBuffer)
        }
        guard let input else { return }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            written += 1
        } else {
            dropped += 1
            if let writer, writer.status == .failed {
                throw writer.error ?? EngineError.writer("Video writer failed.")
            }
        }
    }

    /// The writer is created on the first frame so it uses the real frame size.
    private func makeWriter(for sampleBuffer: CMSampleBuffer) throws {
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            throw EngineError.writer("Frame without image buffer.")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if let bitRate = codec.averageBitRate(width: width, height: height, frameRate: frameRate) {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((frameRate * 2).rounded()),
            ]
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw EngineError.writer("Cannot write \(codec.label) at \(width)×\(height).")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? EngineError.writer("Cannot start video writer.")
        }
        // All files share the same start instant, even if this camera's first frame comes later.
        writer.startSession(atSourceTime: start)

        self.writer = writer
        self.input = input
    }

    func finish() {
        let completion = completion
        func report(_ error: Error?) {
            completion?(
                RecordedTrack(
                    kind: .video, order: order, source: source, file: url.lastPathComponent,
                    samplesWritten: written, samplesDropped: dropped, error: error?.localizedDescription
                ))
        }

        guard let writer, let input, writer.status == .writing else {
            report(error ?? writer?.error ?? EngineError.noSamples)
            return
        }
        input.markAsFinished()
        if let end {
            writer.endSession(atSourceTime: end)
        }
        let previousError = error
        writer.finishWriting {
            report(previousError ?? writer.error)
        }
    }
}
