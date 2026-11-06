import AVFoundation
import Accelerate

/// Finds where a clip filmed on another device sits on the recording timeline,
/// by comparing its sound with the sound of the recording.
///
/// Uses a generalized cross-correlation with phase transform (GCC-PHAT): it only keeps
/// the phase of the spectrum, so different microphones and rooms still line up.
public enum AudioSync {
    public static let analysisRate = 8000.0

    public struct Match: Sendable, Equatable {
        /// Timeline time = clip time + offset, in seconds.
        public let offset: Double
        /// Peak of the correlation against its average level. Above about 8 is a clear match.
        public let confidence: Double
    }

    public static let minimumConfidence = 8.0

    /// How far the network clocks can be from the truth. The phone reports the start of its
    /// recording a little late or early, but not by a second.
    public static let networkWindow = 1.0

    /// Matches the clip against each reference on its own, then keeps the offset most
    /// references agree on. One channel with a loud unrelated sound cannot win alone.
    public static func vote(references: [URL], clip: URL, guess: Double, window: Double = networkWindow) async
        -> Match?
    {
        var matches: [Match] = []
        for reference in references {
            if let match = try? await findOffset(references: [reference], clip: clip, guess: guess, window: window),
                match.confidence >= minimumConfidence
            {
                matches.append(match)
            }
        }
        return choose(matches)
    }

    /// Groups matches closer than 20 ms (microphones a few meters apart) and returns the best
    /// match of the group with the highest total confidence.
    static func choose(_ matches: [Match]) -> Match? {
        var best: (score: Double, match: Match)?
        for candidate in matches {
            let group = matches.filter { abs($0.offset - candidate.offset) <= 0.02 }
            let score = group.reduce(0) { $0 + $1.confidence }
            let top = group.max { $0.confidence < $1.confidence }!
            if best == nil || score > best!.score {
                best = (score, top)
            }
        }
        return best?.match
    }

    /// - Parameters:
    ///   - references: audio files that start at timeline zero (the recorded channels).
    ///   - clip: the file to place.
    ///   - guess: offset estimated another way (for example from the network clocks).
    ///   - window: how far from `guess` the real offset can be, in seconds.
    ///   - length: how much of the clip to compare, in seconds.
    /// - Returns: nil when there is no audio to compare.
    public static func findOffset(
        references: [URL], clip: URL, guess: Double, window: Double = 3, length: Double = 60
    ) async throws -> Match? {
        guard !references.isEmpty else { return nil }
        let clipDuration = try await audioDuration(clip)
        // Skip the first second: phones often start with a short glitch.
        let clipStart = min(1, clipDuration * 0.1)
        let clipLength = min(length, clipDuration - clipStart)
        guard clipLength > 1 else { return nil }

        let x = try await samples(url: clip, start: clipStart, duration: clipLength)
        let referenceStart = max(0, clipStart + guess - window)
        var y: [Float] = []
        for url in references {
            let part = try await samples(url: url, start: referenceStart, duration: clipLength + 2 * window)
            if y.isEmpty {
                y = part
            } else {
                let count = min(y.count, part.count)
                y = Array(y.prefix(count))
                vDSP_vadd(y, 1, part, 1, &y, 1, vDSP_Length(count))
            }
        }
        guard x.count > Int(analysisRate), y.count > Int(analysisRate) else { return nil }

        // y(m) ≈ x(m - lag) where lag = clipStart + offset - referenceStart.
        let minLag = Int(((guess - window) + clipStart - referenceStart) * analysisRate)
        let maxLag = Int(((guess + window) + clipStart - referenceStart) * analysisRate)
        guard let (lag, confidence) = correlate(x, y, lags: minLag...maxLag) else { return nil }
        let offset = referenceStart + Double(lag) / analysisRate - clipStart
        return Match(offset: offset, confidence: confidence)
    }

    /// Lag of `y` against `x` with the highest GCC-PHAT score, and its confidence.
    static func correlate(_ x: [Float], _ y: [Float], lags: ClosedRange<Int>) -> (Int, Double)? {
        let log2n = vDSP_Length(ceil(log2(Double(x.count + y.count))))
        let n = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var (xr, xi) = forward(x, n: n, log2n: log2n, setup: setup)
        var (yr, yi) = forward(y, n: n, log2n: log2n, setup: setup)
        let half = n / 2

        // R = Y · conj(X), keeping only the phase. Bin 0 holds DC (real) and Nyquist (imag).
        var rr = [Float](repeating: 0, count: half)
        var ri = [Float](repeating: 0, count: half)
        rr[0] = yr[0] * xr[0] >= 0 ? 1 : -1
        ri[0] = yi[0] * xi[0] >= 0 ? 1 : -1
        for k in 1..<half {
            let re = yr[k] * xr[k] + yi[k] * xi[k]
            let im = yi[k] * xr[k] - yr[k] * xi[k]
            let magnitude = (re * re + im * im).squareRoot() + 1e-12
            rr[k] = re / magnitude
            ri[k] = im / magnitude
        }
        xr = []
        xi = []
        yr = []
        yi = []

        var output = [Float](repeating: 0, count: n)
        rr.withUnsafeMutableBufferPointer { real in
            ri.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                output.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }

        // Lags outside of what the buffers can hold are not meaningful.
        let low = max(lags.lowerBound, -(x.count - 1))
        let high = min(lags.upperBound, y.count - 1)
        guard low <= high else { return nil }

        var best = low
        var bestValue = -Float.infinity
        var sum: Double = 0
        for lag in low...high {
            let value = output[(lag % n + n) % n]
            sum += Double(abs(value))
            if value > bestValue {
                bestValue = value
                best = lag
            }
        }
        let mean = sum / Double(high - low + 1)
        return (best, mean > 0 ? Double(bestValue) / mean : 0)
    }

    private static func forward(_ signal: [Float], n: Int, log2n: vDSP_Length, setup: FFTSetup) -> ([Float], [Float]) {
        var padded = [Float](repeating: 0, count: n)
        padded.replaceSubrange(0..<min(signal.count, n), with: signal.prefix(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                padded.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (real, imag)
    }

    // MARK: Reading

    static func audioDuration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EngineError.writer("\(url.lastPathComponent) has no audio.")
        }
        let range = try await track.load(.timeRange)
        return range.end.seconds
    }

    /// Mono float samples at `analysisRate`.
    static func samples(url: URL, start: Double, duration: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EngineError.writer("\(url.lastPathComponent) has no audio.")
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, start), preferredTimescale: 48_000),
            duration: CMTime(seconds: max(0, duration), preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: analysisRate,
                AVNumberOfChannelsKey: 1,
            ])
        guard reader.canAdd(output) else { throw EngineError.writer("Cannot read \(url.lastPathComponent).") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? EngineError.writer("Cannot read \(url.lastPathComponent).")
        }

        var result: [Float] = []
        result.reserveCapacity(Int(duration * analysisRate))
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            floats.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            result += floats
        }
        if reader.status == .failed {
            throw reader.error ?? EngineError.writer("Cannot read \(url.lastPathComponent).")
        }
        return result
    }
}
