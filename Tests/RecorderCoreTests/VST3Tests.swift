import AVFoundation
import XCTest

@testable import RecorderCore

/// Runs with a free VST3 effect installed on the machine. Skipped when none is found.
final class VST3Tests: XCTestCase {
    private var media: TestMedia!

    override func setUpWithError() throws {
        media = try TestMedia()
        try media.writeTone("a.wav", amplitude: 0.25)
    }

    override func tearDown() {
        media.remove()
    }

    private func installedEffect() throws -> AudioEffect {
        let candidates = ["TDR Nova.vst3", "ValhallaSupermassive.vst3", "TDR Kotelnikov.vst3"]
        for name in candidates {
            let bundle = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: bundle.path),
                let effect = PluginCatalog.vst3Effects(in: bundle).first
            {
                return effect
            }
        }
        throw XCTSkip("No known free VST3 effect installed.")
    }

    func testCatalogListsInstalledVST3() throws {
        _ = try installedEffect()
        XCTAssertFalse(PluginCatalog.vst3Plugins().isEmpty)
    }

    func testLoadsAndRendersVST3() async throws {
        var track = EditTrack(id: "a.wav", kind: .audio, name: "a")
        track.effects = [try installedEffect().makeInstance()]
        let graph = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        XCTAssertTrue(graph.warnings.isEmpty, graph.warnings.joined(separator: "\n"))

        let effectID = track.effects[0].id
        XCTAssertNotNil(graph.unit(for: effectID))

        // The state holds the plug-in data and can be loaded again.
        let state = try XCTUnwrap(graph.captureStates()[effectID])
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any])
        XCTAssertNotNil(plist["vst3.component"] as? Data)
        track.effects[0].state = state
        let reloaded = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        XCTAssertTrue(reloaded.warnings.isEmpty, reloaded.warnings.joined(separator: "\n"))

        // Offline render through the plug-in gives sound.
        try graph.startOfflineRender(maximumFrameCount: 4096)
        defer { graph.finishOfflineRender() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graph.renderFormat, frameCapacity: 4096))
        var peak: Float = 0
        for _ in 0..<6 {
            XCTAssertEqual(try graph.engine.renderOffline(4096, to: buffer), .success)
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(buffer.frameLength) * 2 {
                peak = max(peak, abs(samples[index]))
            }
        }
        XCTAssertGreaterThan(peak, 0.01)
    }
}
