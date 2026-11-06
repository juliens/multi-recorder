import AVFoundation
import XCTest

@testable import RecorderCore

final class AudioSyncTests: XCTestCase {
    /// Bursts of noise with silences, like speech.
    private func signal(seconds: Double, rate: Double, seed: UInt64) -> [Float] {
        var generator = SplitMix(seed: seed)
        let count = Int(seconds * rate)
        return (0..<count).map { index in
            let time = Double(index) / rate
            let envelope: Float = sin(time * 2.3) + sin(time * 0.7) > 0.4 ? 1 : 0.05
            return envelope * (Float(generator.next() % 2000) / 1000 - 1) * 0.4
        }
    }

    private func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }

    func testFindsTheOffsetOfAClip() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let rate = 48_000.0
        let reference = signal(seconds: 20, rate: rate, seed: 7)

        // The clip starts 2.345 s into the recording, with another gain and some room noise.
        let start = Int(2.345 * rate)
        var noise = SplitMix(seed: 99)
        let clip = reference[start..<(start + Int(12 * rate))].map {
            $0 * 0.6 + (Float(noise.next() % 2000) / 1000 - 1) * 0.02
        }
        try write(reference, rate: rate, to: media.url("audio_ch01.wav"))
        try write(Array(clip), rate: rate, to: media.url("phone.wav"))

        // The network guess is 0.8 s wrong.
        let match = try await AudioSync.findOffset(
            references: [media.url("audio_ch01.wav")], clip: media.url("phone.wav"), guess: 3.1)
        let found = try XCTUnwrap(match)
        XCTAssertEqual(found.offset, 2.345, accuracy: 0.002)
        XCTAssertGreaterThan(found.confidence, AudioSync.minimumConfidence)
    }

    func testUnrelatedAudioHasLowConfidence() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let rate = 48_000.0
        try write(signal(seconds: 15, rate: rate, seed: 1), rate: rate, to: media.url("a.wav"))
        try write(signal(seconds: 10, rate: rate, seed: 2), rate: rate, to: media.url("b.wav"))

        let match = try await AudioSync.findOffset(
            references: [media.url("a.wav")], clip: media.url("b.wav"), guess: 1)
        XCTAssertLessThan(try XCTUnwrap(match).confidence, AudioSync.minimumConfidence)
    }
}

/// Small deterministic random numbers for tests.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

final class AudioSyncVoteTests: XCTestCase {
    func testMostReferencesWin() {
        let matches = [
            AudioSync.Match(offset: 2.22, confidence: 49),
            AudioSync.Match(offset: 0.203, confidence: 24),
            AudioSync.Match(offset: 0.21, confidence: 20),
            AudioSync.Match(offset: 0.205, confidence: 18),
        ]
        XCTAssertEqual(AudioSync.choose(matches)?.offset, 0.203)
        XCTAssertNil(AudioSync.choose([]))
    }
}
