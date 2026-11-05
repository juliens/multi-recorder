import AVFoundation
import XCTest

@testable import RecorderCore

final class MuxerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Camera files start at a large clock time (like the capture session clock).
    /// The combined movie must still start at zero and keep the same duration.
    func testCombinesVideoAndAudioFromSameStart() async throws {
        let start = CMTime(seconds: 5_000, preferredTimescale: 600)
        let video1 = folder.appendingPathComponent("cam1.mov")
        let video2 = folder.appendingPathComponent("cam2.mov")
        let audio = folder.appendingPathComponent("audio_ch01.wav")
        try await writeVideo(to: video1, start: start, seconds: 1)
        try await writeVideo(to: video2, start: start, seconds: 1)
        try writeTone(to: audio, seconds: 1)

        let output = folder.appendingPathComponent("combined.mov")
        try await Muxer.mux(inputs: [video1, video2, audio], to: output)

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

    private func writeVideo(to url: URL, start: CMTime, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: start)

        let fps = 30
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let time = start + CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(buffer!, withPresentationTime: time))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: start + CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func writeTone(to url: URL, seconds: Int) throws {
        let rate = 48_000.0
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate) * AVAudioFrameCount(seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / rate)) * 0.5
        }
        try file.write(from: buffer)
    }
}
