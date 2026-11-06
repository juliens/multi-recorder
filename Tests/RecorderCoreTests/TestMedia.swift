import AVFoundation
import XCTest

/// Small media files written for tests, in a temporary folder.
final class TestMedia {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    func url(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// Writes a 30 fps H.264 movie whose session starts at `start`, like the recorder does.
    func writeVideo(
        _ name: String, start: CMTime = .zero, seconds: Int = 1, width: Int = 160, height: Int = 90,
        color: (red: UInt8, green: UInt8, blue: UInt8) = (0, 0, 0)
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url(name), fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
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
            fill(buffer!, color: color)
            let time = start + CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(buffer!, withPresentationTime: time))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: start + CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func fill(_ buffer: CVPixelBuffer, color: (red: UInt8, green: UInt8, blue: UInt8)) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = color.blue
                pixel[1] = color.green
                pixel[2] = color.red
                pixel[3] = 255
            }
        }
    }

    /// Writes a mono 48 kHz, 24-bit WAV file with a 440 Hz sine wave.
    func writeTone(_ name: String, seconds: Int = 1, amplitude: Float = 0.5) throws {
        let rate = 48_000.0
        let file = try AVAudioFile(
            forWriting: url(name),
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate) * AVAudioFrameCount(seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / rate)) * amplitude
        }
        try file.write(from: buffer)
    }
}
