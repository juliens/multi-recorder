import Foundation

/// Where a file that was not recorded by the capture session sits on the timeline.
/// Saved in `sync.json` in the recording folder, by file name. The editor uses it
/// for the default track offsets.
public struct ClipPlacement: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// Matched on the sound of the recording.
        case audio
        /// From the phone clock, measured over the network. Less precise.
        case network
    }

    public static let fileName = "sync.json"

    /// Timeline time = file time + offset, in seconds.
    public var offset: Double
    public var method: Method
    public var confidence: Double?
    /// The offset given by the network clocks, kept to check the sound match.
    public var networkOffset: Double?

    public init(offset: Double, method: Method, confidence: Double? = nil, networkOffset: Double? = nil) {
        self.offset = offset
        self.method = method
        self.confidence = confidence
        self.networkOffset = networkOffset
    }

    public static func load(folder: URL) -> [String: ClipPlacement] {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ClipPlacement].self, from: data)) ?? [:]
    }

    /// Adds or replaces entries, keeping the others.
    public static func save(_ placements: [String: ClipPlacement], folder: URL) throws {
        var all = load(folder: folder)
        all.merge(placements) { _, new in new }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
}
