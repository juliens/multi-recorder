import AVFoundation
import XCTest

@testable import RecorderCore

final class MuxerTests: XCTestCase {
    private var media: TestMedia!

    override func setUpWithError() throws {
        media = try TestMedia()
    }

    override func tearDown() {
        media.remove()
    }

    /// Camera files start at a large clock time (like the capture session clock).
    /// The combined movie must still start at zero and keep the same duration.
    func testCombinesVideoAndAudioFromSameStart() async throws {
        let start = CMTime(seconds: 5_000, preferredTimescale: 600)
        try await media.writeVideo("cam1.mov", start: start)
        try await media.writeVideo("cam2.mov", start: start)
        try media.writeTone("audio_ch01.wav")

        let output = media.url("combined.mov")
        try await Muxer.mux(
            inputs: [media.url("cam1.mov"), media.url("cam2.mov"), media.url("audio_ch01.wav")], to: output)

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 2)
        XCTAssertEqual(audioTracks.count, 1)

        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        for track in videoTracks + audioTracks {
            let range = try await track.load(.timeRange)
            XCTAssertEqual(range.start.seconds, 0, accuracy: 0.05)
        }
    }
}
