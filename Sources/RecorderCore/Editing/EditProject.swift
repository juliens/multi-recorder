import Foundation

/// Where a video track is drawn in the output frame.
public enum VideoPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case hidden

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .full: "Full screen"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .hidden: "Hidden"
        }
    }

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        case .full, .hidden: false
        }
    }
}

public struct EditTrack: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
        case audio
    }

    /// File name inside the recording folder.
    public let id: String
    public let kind: Kind
    public var name: String

    /// Position of the file on the timeline, in seconds: timeline time = file time + offset.
    /// Zero for files of the recording itself; set for clips filmed on a phone.
    public var offset: Double = 0

    // Video settings.
    public var placement: VideoPlacement = .full
    /// Size of a corner picture, relative to the output frame.
    public var cornerScale: Double = 0.3
    /// Color, crop and frame settings.
    public var adjustments = VideoAdjustments()

    // Audio settings.
    public var volumeDB: Double = 0
    /// -1 is full left, 1 is full right.
    public var pan: Double = 0
    public var muted = false
    public var solo = false
    /// Insert effects, in processing order.
    public var effects: [AudioEffect] = []

    public init(id: String, kind: Kind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, offset, placement, cornerScale, adjustments, volumeDB, pan, muted, solo, effects
    }

    /// Fields added later are optional, so older `edit.json` files still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        offset = try container.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        placement = try container.decodeIfPresent(VideoPlacement.self, forKey: .placement) ?? .full
        cornerScale = try container.decodeIfPresent(Double.self, forKey: .cornerScale) ?? 0.3
        adjustments = try container.decodeIfPresent(VideoAdjustments.self, forKey: .adjustments) ?? .identity
        volumeDB = try container.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try container.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        effects = try container.decodeIfPresent([AudioEffect].self, forKey: .effects) ?? []
    }
}

/// The edit of one recording folder. Saved as `edit.json` next to the media files.
public struct EditProject: Codable, Sendable {
    public static let fileName = "edit.json"
    public static let minimumVolumeDB = -60.0
    public static let maximumVolumeDB = 12.0

    public var tracks: [EditTrack]

    public init(tracks: [EditTrack]) {
        self.tracks = tracks
    }

    public var videoTracks: [EditTrack] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [EditTrack] { tracks.filter { $0.kind == .audio } }

    /// False when the track is muted, below the minimum volume, or another track is solo.
    public func isAudible(_ track: EditTrack) -> Bool {
        let anySolo = audioTracks.contains { $0.solo }
        return !track.muted && !(anySolo && !track.solo) && track.volumeDB > Self.minimumVolumeDB
    }

    /// Linear gain of an audio track, with mute and solo applied.
    public func gain(of track: EditTrack) -> Float {
        guard isAudible(track) else { return 0 }
        return Float(pow(10, min(track.volumeDB, Self.maximumVolumeDB) / 20))
    }

    // MARK: Loading

    /// Finds the media files of a recording folder and applies the saved edit if there is one.
    public static func load(folder: URL) throws -> EditProject {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        var project = EditProject(tracks: defaultTracks(fileNames: files))
        let placements = ClipPlacement.load(folder: folder)
        for index in project.tracks.indices {
            if let placement = placements[project.tracks[index].id] {
                project.tracks[index].offset = placement.offset
            }
        }

        let saved = folder.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: saved),
            let previous = try? JSONDecoder().decode(EditProject.self, from: data)
        {
            project.apply(previous)
        }
        return project
    }

    public func save(folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Video files first, then audio files. The first camera is full screen,
    /// the next ones go to the corners.
    static func defaultTracks(fileNames: [String]) -> [EditTrack] {
        let corners: [VideoPlacement] = [.bottomRight, .bottomLeft, .topRight, .topLeft]
        var tracks: [EditTrack] = []

        let videos = fileNames.filter {
            ["mov", "mp4", "m4v"].contains(($0 as NSString).pathExtension.lowercased())
                && $0 != FileNaming.combinedFileName && !$0.hasPrefix(".")
        }
        for (index, file) in videos.enumerated() {
            var track = EditTrack(id: file, kind: .video, name: displayName(file))
            track.placement = index == 0 ? .full : corners[(index - 1) % corners.count]
            tracks.append(track)
        }

        let audios = fileNames.filter {
            ["wav", "aif", "aiff", "caf", "m4a"].contains(($0 as NSString).pathExtension.lowercased())
                && !$0.hasPrefix(".")
        }
        tracks += audios.map { file in
            var track = EditTrack(id: file, kind: .audio, name: displayName(file))
            // The phone microphone is a backup: it would echo the real microphones.
            track.muted = file.hasPrefix(FileNaming.phonePrefix)
            return track
        }
        return tracks
    }

    /// Keeps the settings of tracks that still exist.
    mutating func apply(_ saved: EditProject) {
        let byID = Dictionary(saved.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tracks = tracks.map { track in
            guard let previous = byID[track.id], previous.kind == track.kind else { return track }
            return previous
        }
    }

    private static func displayName(_ file: String) -> String {
        (file as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }
}
