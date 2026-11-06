import AVFoundation

/// Brings the clip of a phone into a recording folder: downloads it, takes its sound out
/// as an audio track, and finds where it sits on the timeline.
public enum PhoneImport {
    public struct Result: Sendable {
        public let videoFile: String
        public let audioFile: String?
        public let placement: ClipPlacement
    }

    /// - Parameters:
    ///   - clockOffset: phone clock minus host clock, in seconds.
    ///   - recordingStart: start of the recording on the host clock, in seconds.
    ///   - references: audio files of the recording, used to match the sound.
    public static func importClip(
        _ clip: PhoneClip, from client: PhoneClient, index: Int, clockOffset: Double, recordingStart: Double,
        folder: URL, references: [URL], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        let names = FileNaming.phoneFileNames(index: index, phoneName: client.endpoint.name)
        let videoURL = folder.appendingPathComponent(names.video)
        try await client.download(clipID: clip.id, to: videoURL, progress: progress)

        let audioURL = folder.appendingPathComponent(names.audio)
        let hasAudio = try await extractAudio(from: videoURL, to: audioURL)

        let guess = clip.startSeconds - clockOffset - recordingStart
        var placement = ClipPlacement(offset: guess, method: .network, networkOffset: guess)
        if hasAudio, let match = await AudioSync.vote(references: references, clip: videoURL, guess: guess) {
            placement = ClipPlacement(
                offset: match.offset, method: .audio, confidence: match.confidence, networkOffset: guess)
        }

        var placements = [names.video: placement]
        if hasAudio {
            placements[names.audio] = placement
        }
        try ClipPlacement.save(placements, folder: folder)
        return Result(videoFile: names.video, audioFile: hasAudio ? names.audio : nil, placement: placement)
    }

    /// Copies the sound of a movie to an .m4a file, without re-encoding.
    /// Returns false when the movie has no sound.
    static func extractAudio(from movie: URL, to output: URL) async throws -> Bool {
        let asset = AVURLAsset(url: movie)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else { return false }
        let composition = AVMutableComposition()
        guard
            let target = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return false }
        let range = try await source.load(.timeRange)
        try target.insertTimeRange(range, of: source, at: range.start)

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { return false }
        session.outputURL = output
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed {
            throw session.error ?? EngineError.writer("Cannot extract the sound of \(movie.lastPathComponent).")
        }
        return true
    }
}
