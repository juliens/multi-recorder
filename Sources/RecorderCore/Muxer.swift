import AVFoundation

/// Copies the tracks of several files into one multi-track QuickTime movie, without re-encoding.
public enum Muxer {
    public static func mux(inputs: [URL], to output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var readers: [AVAssetReader] = []
        var pairs: [SampleCopier.Pair] = []

        for url in inputs {
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
                let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                trackOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(trackOutput) else { continue }
                reader.add(trackOutput)

                let formatHint = try await track.load(.formatDescriptions).first
                let writerInput = AVAssetWriterInput(
                    mediaType: track.mediaType, outputSettings: nil,
                    sourceFormatHint: formatHint)
                writerInput.expectsMediaDataInRealTime = false
                if track.mediaType == .video {
                    writerInput.transform = try await track.load(.preferredTransform)
                }
                guard writer.canAdd(writerInput) else {
                    throw EngineError.writer("Cannot add a track from \(url.lastPathComponent).")
                }
                writer.add(writerInput)
                pairs.append(SampleCopier.Pair(output: trackOutput, input: writerInput))
            }
            readers.append(reader)
        }

        guard !pairs.isEmpty else { throw EngineError.writer("Nothing to combine.") }
        for reader in readers where !reader.startReading() {
            throw reader.error ?? EngineError.writer("Cannot read source file.")
        }
        guard writer.startWriting() else {
            throw writer.error ?? EngineError.writer("Cannot start combined writer.")
        }
        // Source files all start at the recording start, so their timelines begin at zero.
        writer.startSession(atSourceTime: .zero)

        await SampleCopier.copyAll(pairs)

        if let failed = readers.first(where: { $0.status == .failed }) {
            writer.cancelWriting()
            throw failed.error ?? EngineError.writer("Reading a source file failed.")
        }
        if writer.status == .failed {
            throw writer.error ?? EngineError.writer("Writing the combined file failed.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? EngineError.writer("Writing the combined file failed.")
        }
    }
}
