import AVFoundation

public enum VideoCodecChoice: String, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc
    case proRes422

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .proRes422: "ProRes 422"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
    }

    /// Target bitrate for long GOP codecs. ProRes is intra-only and picks its own rate.
    func averageBitRate(width: Int, height: Int, frameRate: Double) -> Int? {
        let bitsPerPixel: Double
        switch self {
        case .h264: bitsPerPixel = 0.2
        case .hevc: bitsPerPixel = 0.12
        case .proRes422: return nil
        }
        return Int(Double(width * height) * frameRate * bitsPerPixel)
    }
}

public struct CameraRequest: Hashable, Sendable {
    public let deviceID: String
    public let formatID: Int?

    public init(deviceID: String, formatID: Int?) {
        self.deviceID = deviceID
        self.formatID = formatID
    }
}

public struct RecordingOptions: Sendable {
    public var codec: VideoCodecChoice
    /// 0-based channels of the audio device to record, one WAV file each.
    public var audioChannels: [Int]

    public init(codec: VideoCodecChoice, audioChannels: [Int]) {
        self.codec = codec
        self.audioChannels = audioChannels
    }
}

public struct PreviewHandle: Identifiable {
    public let id: String
    public let name: String
    public let layer: AVSampleBufferDisplayLayer
}

public struct ConfigureResult {
    public let previews: [PreviewHandle]
    public let warnings: [String]
}

public struct RecordedTrack: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
        case audio
    }

    public let kind: Kind
    public let order: Int
    public let source: String
    public let file: String
    public let samplesWritten: Int
    public let samplesDropped: Int
    public let error: String?

    public init(
        kind: Kind, order: Int, source: String, file: String, samplesWritten: Int, samplesDropped: Int,
        error: String?
    ) {
        self.kind = kind
        self.order = order
        self.source = source
        self.file = file
        self.samplesWritten = samplesWritten
        self.samplesDropped = samplesDropped
        self.error = error
    }
}

public struct RecordingSummary: Codable, Sendable {
    public let folder: URL
    public let startedAt: Date
    public let durationSeconds: Double
    /// Start instant on the capture session clock. Every track starts here.
    public let syncStartSeconds: Double
    /// Start instant on the host clock (mach time), in seconds. Used to place phone clips.
    public var hostStartSeconds: Double?
    public var tracks: [RecordedTrack]
    public var combinedFile: String?

    /// Video tracks first, then audio, each in capture order.
    public var orderedTracks: [RecordedTrack] {
        tracks.sorted { ($0.kind == .video ? 0 : 1, $0.order) < ($1.kind == .video ? 0 : 1, $1.order) }
    }

    public func writeManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: folder.appendingPathComponent(FileNaming.manifestFileName))
    }
}

public enum EngineError: LocalizedError {
    case busy
    case nothingToRecord
    case notRecording
    case noSamples
    case cannotAdd(String)
    case writer(String)
    case plugin(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "A recording is in progress."
        case .nothingToRecord: "Select at least one camera or audio channel."
        case .notRecording: "Not recording."
        case .noSamples: "No samples received during the recording."
        case let .cannotAdd(name): "Cannot add \(name) to the capture session."
        case let .writer(message): message
        case let .plugin(message): message
        }
    }
}
