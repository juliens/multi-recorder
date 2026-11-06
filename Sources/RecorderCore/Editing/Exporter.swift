import AVFoundation

public enum ExportCodec: String, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        }
    }
}

public struct ExportOptions: Sendable {
    public var renderSize: CGSize
    public var codec: ExportCodec
    public var fileType: AVFileType

    public init(renderSize: CGSize, codec: ExportCodec, fileType: AVFileType) {
        self.renderSize = renderSize
        self.codec = codec
        self.fileType = fileType
    }
}

/// Renders the edit to one file: the composed picture, and the audio tracks rendered
/// through their effects and mixed to stereo.
public enum Exporter {
    static let audioBlockSize: AVAudioFrameCount = 4096

    /// `edit` gives the video. The audio is rendered offline by a new `AudioGraph`
    /// built from `project`, so effect states must be saved in `project` before.
    public static func export(
        _ edit: EditComposition, folder: URL, project: EditProject, options: ExportOptions, to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let graph = await AudioGraph(folder: folder, project: project)
        guard edit.hasVideo || graph.hasAudio else { throw EngineError.writer("Nothing to export.") }

        let duration = max(edit.duration.seconds, graph.duration)
        let writer = try AVAssetWriter(outputURL: url, fileType: options.fileType)
        var pairs: [SampleCopier.Pair] = []
        var videoReaderIfAny: AVAssetReader?
        let cancelled = Flag()

        let size = evenSize(options.renderSize)
        if let videoComposition = edit.videoComposition(for: project, renderSize: size) {
            let videoReader = try AVAssetReader(asset: edit.composition)
            videoReader.timeRange = CMTimeRange(start: .zero, duration: edit.duration)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: edit.compositionVideoTracks,
                videoSettings: [
                    // Same format as the Core Image compositor output.
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
            output.videoComposition = videoComposition
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: .video, outputSettings: videoSettings(options.codec, size: size, edit: edit))
            guard videoReader.canAdd(output) else { throw EngineError.writer("Cannot read the video.") }
            videoReader.add(output)
            try add(input, to: writer)
            pairs.append(SampleCopier.Pair(output: output, input: input))
            videoReaderIfAny = videoReader
        }

        if graph.hasAudio {
            try graph.startOfflineRender(maximumFrameCount: audioBlockSize)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: graph.format.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000,
                ])
            try add(input, to: writer)
            let totalFrames = AVAudioFramePosition(duration * graph.format.sampleRate)
            pairs.append(SampleCopier.Pair(input: input, next: audioSource(graph, totalFrames, cancelled)))
        }

        let reader = videoReaderIfAny
        if let reader, !reader.startReading() {
            throw reader.error ?? EngineError.writer("Cannot read the video.")
        }
        guard writer.startWriting() else {
            throw writer.error ?? EngineError.writer("Cannot start the export.")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration, 0.001)
        let throttle = ProgressThrottle(report: progress)
        await withTaskCancellationHandler {
            await SampleCopier.copyAll(pairs) { sample in
                let time = sample.presentationTimeStamp.seconds
                if time.isFinite {
                    throttle.update(min(1, time / total))
                }
            }
        } onCancel: {
            cancelled.set()
            reader?.cancelReading()
        }
        if graph.hasAudio {
            graph.finishOfflineRender()
        }

        if Task.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if let reader, reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? EngineError.writer("Reading the video failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? EngineError.writer("Writing the export failed.")
        }
        progress(1)
    }

    private static func add(_ input: AVAssetWriterInput, to writer: AVAssetWriter) throws {
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw EngineError.writer("Cannot set up the export for \(input.mediaType.rawValue).")
        }
        writer.add(input)
    }

    /// Pulls blocks from the offline engine and wraps them as sample buffers.
    private static func audioSource(
        _ graph: AudioGraph, _ totalFrames: AVAudioFramePosition, _ cancelled: Flag
    ) -> () -> CMSampleBuffer? {
        let format = graph.renderFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: audioBlockSize)!
        var position: AVAudioFramePosition = 0

        return {
            guard !cancelled.isSet, position < totalFrames else { return nil }
            let count = AVAudioFrameCount(min(AVAudioFramePosition(audioBlockSize), totalFrames - position))
            guard (try? graph.engine.renderOffline(count, to: buffer)) == .success,
                let sample = makeSampleBuffer(buffer, at: position)
            else { return nil }
            position += AVAudioFramePosition(buffer.frameLength)
            return sample
        }
    }

    /// Copies a PCM buffer into a new sample buffer stamped at `position` (in frames).
    static func makeSampleBuffer(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition) -> CMSampleBuffer? {
        let sampleRate = CMTimeScale(buffer.format.sampleRate)
        var description: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: position, timescale: sampleRate),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: description, sampleCount: CMItemCount(buffer.frameLength),
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
            let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }

    private static func videoSettings(_ codec: ExportCodec, size: CGSize, edit: EditComposition) -> [String: Any] {
        let frameRate = 1 / edit.frameDuration.seconds
        let bitsPerPixel = codec == .h264 ? 0.15 : 0.1
        return [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * frameRate * bitsPerPixel),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((frameRate * 2).rounded()),
            ],
        ]
    }

    /// Encoders need even dimensions.
    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, Int(size.width) / 2 * 2), height: max(2, Int(size.height) / 2 * 2))
    }
}

/// A flag set from one thread and read from another.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Reports progress only when it moved enough, from any thread.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (Double) -> Void
    private var last = -1.0

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func update(_ value: Double) {
        let shouldReport = lock.withLock {
            guard value - last >= 0.005 else { return false }
            last = value
            return true
        }
        if shouldReport {
            report(value)
        }
    }
}
