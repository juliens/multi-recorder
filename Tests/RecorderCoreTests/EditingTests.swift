import AVFoundation
import XCTest

@testable import RecorderCore

final class LayoutTests: XCTestCase {
    private let size = CGSize(width: 1920, height: 1080)

    func testFullUsesWholeFrame() {
        XCTAssertEqual(Layout.rect(for: .full, cornerScale: 0.3, renderSize: size), CGRect(origin: .zero, size: size))
        XCTAssertNil(Layout.rect(for: .hidden, cornerScale: 0.3, renderSize: size))
    }

    func testCornersKeepMargin() throws {
        let margin = 1920 * Layout.marginRatio
        let topLeft = try XCTUnwrap(Layout.rect(for: .topLeft, cornerScale: 0.25, renderSize: size))
        XCTAssertEqual(topLeft, CGRect(x: margin, y: margin, width: 480, height: 270))

        let bottomRight = try XCTUnwrap(Layout.rect(for: .bottomRight, cornerScale: 0.25, renderSize: size))
        XCTAssertEqual(bottomRight.maxX, 1920 - margin, accuracy: 0.001)
        XCTAssertEqual(bottomRight.maxY, 1080 - margin, accuracy: 0.001)
    }

    func testTransformFitsAndCenters() {
        // A 4:3 video in a 16:9 area is scaled to the area height and centered.
        let rect = CGRect(x: 100, y: 50, width: 1600, height: 900)
        let transform = Layout.transform(naturalSize: CGSize(width: 640, height: 480), into: rect)
        let drawn = CGRect(x: 0, y: 0, width: 640, height: 480).applying(transform)
        XCTAssertEqual(drawn.height, 900, accuracy: 0.001)
        XCTAssertEqual(drawn.width, 1200, accuracy: 0.001)
        XCTAssertEqual(drawn.midX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(drawn.midY, rect.midY, accuracy: 0.001)
    }

    func testCornersAreDrawnAboveFullScreen() {
        var full = EditTrack(id: "a.mov", kind: .video, name: "a")
        full.placement = .full
        var corner = EditTrack(id: "b.mov", kind: .video, name: "b")
        corner.placement = .topRight
        var hidden = EditTrack(id: "c.mov", kind: .video, name: "c")
        hidden.placement = .hidden

        XCTAssertEqual(Layout.drawingOrder([full, corner, hidden]).map(\.id), ["b.mov", "a.mov"])
    }
}

final class EditProjectTests: XCTestCase {
    func testDefaultTracks() {
        let tracks = EditProject.defaultTracks(fileNames: [
            "audio_ch02.wav", "cam1_A.mov", "combined.mov", "session.json", "cam2_B.mov", "audio_ch01.wav",
        ])
        XCTAssertEqual(
            tracks.map(\.id), ["cam1_A.mov", "cam2_B.mov", "audio_ch02.wav", "audio_ch01.wav"])
        XCTAssertEqual(tracks[0].placement, .full)
        XCTAssertEqual(tracks[1].placement, .bottomRight)
    }

    func testGainWithMuteAndSolo() {
        var a = EditTrack(id: "a.wav", kind: .audio, name: "a")
        a.volumeDB = -6
        var b = EditTrack(id: "b.wav", kind: .audio, name: "b")
        var project = EditProject(tracks: [a, b])
        XCTAssertEqual(project.gain(of: a), 0.501, accuracy: 0.001)
        XCTAssertEqual(project.gain(of: b), 1)

        b.solo = true
        project = EditProject(tracks: [a, b])
        XCTAssertEqual(project.gain(of: a), 0)
        XCTAssertEqual(project.gain(of: b), 1)

        b.muted = true
        project = EditProject(tracks: [a, b])
        XCTAssertEqual(project.gain(of: b), 0)
    }

    func testPhoneClipsUseSyncFile() throws {
        let media = try TestMedia()
        defer { media.remove() }
        let names = FileNaming.phoneFileNames(index: 1, phoneName: "Pixel 8")
        for file in ["cam1.mov", "audio_ch01.wav", names.video, names.audio] {
            FileManager.default.createFile(atPath: media.url(file).path, contents: Data())
        }
        let placement = ClipPlacement(offset: 0.42, method: .audio, confidence: 20)
        try ClipPlacement.save([names.video: placement, names.audio: placement], folder: media.folder)

        let project = try EditProject.load(folder: media.folder)
        let video = try XCTUnwrap(project.tracks.first { $0.id == "phone1_Pixel-8.mp4" })
        let audio = try XCTUnwrap(project.tracks.first { $0.id == "phone1_Pixel-8.m4a" })
        XCTAssertEqual(video.offset, 0.42)
        XCTAssertEqual(audio.offset, 0.42)
        XCTAssertTrue(audio.muted, "the phone microphone starts muted")
        XCTAssertFalse(project.tracks.first { $0.id == "audio_ch01.wav" }!.muted)
        XCTAssertEqual(project.tracks.first { $0.id == "cam1.mov" }?.offset, 0)
    }

    func testSavedSettingsAreKept() throws {
        let media = try TestMedia()
        defer { media.remove() }
        FileManager.default.createFile(atPath: media.url("cam1.mov").path, contents: Data())

        var project = try EditProject.load(folder: media.folder)
        project.tracks[0].placement = .topLeft
        try project.save(folder: media.folder)

        XCTAssertEqual(try EditProject.load(folder: media.folder).tracks[0].placement, .topLeft)
    }
}

final class ExportTests: XCTestCase {
    private var media: TestMedia!

    override func setUpWithError() throws {
        media = try TestMedia()
    }

    override func tearDown() {
        media.remove()
    }

    func testExportComposesVideoAndMixesAudio() async throws {
        let start = CMTime(seconds: 5_000, preferredTimescale: 600)
        try await media.writeVideo("cam1.mov", start: start, width: 320, height: 180)
        try await media.writeVideo("cam2.mov", start: start)
        try media.writeTone("audio_ch01.wav")
        try media.writeTone("audio_ch02.wav")

        var project = try EditProject.load(folder: media.folder)
        let index = try XCTUnwrap(project.tracks.firstIndex { $0.id == "audio_ch02.wav" })
        project.tracks[index].muted = true

        let edit = try await EditComposition.load(folder: media.folder, project: project)
        XCTAssertTrue(edit.warnings.isEmpty, edit.warnings.joined())
        XCTAssertEqual(edit.duration.seconds, 1, accuracy: 0.05)
        XCTAssertEqual(edit.naturalRenderSize, CGSize(width: 320, height: 180))

        let output = media.url("export.mp4")
        let options = ExportOptions(renderSize: CGSize(width: 320, height: 180), codec: .h264, fileType: .mp4)
        try await Exporter.export(edit, folder: media.folder, project: project, options: options, to: output) { _ in
        }

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let naturalSize = try await video[0].load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(naturalSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(duration, 1, accuracy: 0.1)

        // The mono tracks must be heard on both stereo channels.
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
        try file.read(into: buffer)
        for channel in 0..<2 {
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1, "channel \(channel) is silent")
        }
    }

    func testOffsetMovesAVideoOnTheTimeline() async throws {
        try await media.writeVideo("cam1.mov")
        try await media.writeVideo("phone1_P.mp4")
        var project = try EditProject.load(folder: media.folder)
        project.tracks[1].offset = 0.5
        var edit = try await EditComposition.load(folder: media.folder, project: project)
        XCTAssertTrue(edit.warnings.isEmpty, edit.warnings.joined())
        XCTAssertEqual(edit.duration.seconds, 1.5, accuracy: 0.05)

        // A clip that started before the recording is cut at zero.
        project.tracks[1].offset = -0.25
        edit = try await EditComposition.load(folder: media.folder, project: project)
        XCTAssertEqual(edit.duration.seconds, 1, accuracy: 0.05)
        let phoneTrack = edit.composition.tracks(withMediaType: .video)[1]
        XCTAssertEqual(phoneTrack.timeRange.duration.seconds, 0.75, accuracy: 0.05)
    }

    func testWaveform() throws {
        try media.writeTone("tone.wav", amplitude: 0.5)
        let peaks = try MediaAnalysis.waveform(url: media.url("tone.wav"), buckets: 100)
        XCTAssertEqual(peaks.count, 100)
        XCTAssertEqual(peaks.max() ?? 0, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(peaks.min() ?? 0, 0.4)
    }
}
