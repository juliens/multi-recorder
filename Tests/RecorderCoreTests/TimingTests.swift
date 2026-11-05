import CoreMedia
import XCTest

@testable import RecorderCore

final class TimingTests: XCTestCase {
    private let rate = 48_000.0

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    func testBufferInsideRecordingIsKept() {
        let range = Timing.frameRange(
            bufferStart: time(10), frameCount: 512, sampleRate: rate,
            start: time(9), end: nil)
        XCTAssertEqual(range, 0..<512)
    }

    func testBufferBeforeStartIsDropped() {
        let range = Timing.frameRange(
            bufferStart: time(8), frameCount: 512, sampleRate: rate,
            start: time(9), end: nil)
        XCTAssertTrue(range.isEmpty)
    }

    func testStartInsideBufferTrimsHead() {
        // Start is 100 frames after the buffer start.
        let range = Timing.frameRange(
            bufferStart: time(10), frameCount: 512, sampleRate: rate,
            start: time(10 + 100 / rate), end: nil)
        XCTAssertEqual(range, 100..<512)
    }

    func testEndInsideBufferTrimsTail() {
        let range = Timing.frameRange(
            bufferStart: time(10), frameCount: 512, sampleRate: rate,
            start: time(9), end: time(10 + 300 / rate))
        XCTAssertEqual(range, 0..<300)
    }

    func testBufferAfterEndIsDropped() {
        let range = Timing.frameRange(
            bufferStart: time(12), frameCount: 512, sampleRate: rate,
            start: time(9), end: time(11))
        XCTAssertTrue(range.isEmpty)
    }

    func testStartAndEndInSameBuffer() {
        let range = Timing.frameRange(
            bufferStart: time(10), frameCount: 512, sampleRate: rate,
            start: time(10 + 10 / rate), end: time(10 + 20 / rate))
        XCTAssertEqual(range, 10..<20)
    }

    func testBufferEnd() {
        let end = Timing.bufferEnd(bufferStart: time(10), frameCount: 480, sampleRate: rate)
        XCTAssertEqual(end.seconds, 10.01, accuracy: 1e-9)
    }
}

final class FileNamingTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(FileNaming.sanitize("FaceTime HD Camera (Built-in)"), "FaceTime-HD-Camera-Built-in")
        XCTAssertEqual(FileNaming.sanitize("///"), "device")
    }

    func testCameraFileName() {
        XCTAssertEqual(FileNaming.cameraFileName(index: 2, deviceName: "Logitech BRIO"), "cam2_Logitech-BRIO.mov")
    }

    func testAudioFileNameIsOneBased() {
        XCTAssertEqual(FileNaming.audioFileName(channel: 0), "audio_ch01.wav")
        XCTAssertEqual(FileNaming.audioFileName(channel: 11), "audio_ch12.wav")
    }

    func testSessionFolderName() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            FileNaming.sessionFolderName(date: date, timeZone: TimeZone(identifier: "UTC")!),
            "1970-01-01_00-00-00")
    }
}
