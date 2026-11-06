import AVFoundation
import XCTest

@testable import RecorderCore

final class AudioGraphTests: XCTestCase {
    private var media: TestMedia!

    override func setUpWithError() throws {
        media = try TestMedia()
        try media.writeTone("a.wav", amplitude: 0.25)
    }

    override func tearDown() {
        media.remove()
    }

    private func appleDelay() -> AudioEffect {
        var effect = AudioEffect(kind: .audioUnit, name: "AUDelay", manufacturer: "Apple")
        effect.componentType = kAudioUnitType_Effect
        effect.componentSubType = kAudioUnitSubType_Delay
        effect.componentManufacturer = kAudioUnitManufacturer_Apple
        return effect
    }

    func testLoadsAudioUnitAndRestoresState() async throws {
        var track = EditTrack(id: "a.wav", kind: .audio, name: "a")
        track.effects = [appleDelay()]
        let graph = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        XCTAssertTrue(graph.warnings.isEmpty, graph.warnings.joined())

        let effectID = track.effects[0].id
        let unit = try XCTUnwrap(graph.unit(for: effectID))
        // Change a parameter, save the state, and load it in a new graph.
        let parameter = try XCTUnwrap(unit.auAudioUnit.parameterTree?.allParameters.first)
        parameter.value = parameter.minValue
        track.effects[0].state = try XCTUnwrap(graph.captureStates()[effectID])

        let reloaded = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        let reloadedUnit = try XCTUnwrap(reloaded.unit(for: effectID))
        let reloadedParameter = try XCTUnwrap(
            reloadedUnit.auAudioUnit.parameterTree?.parameter(withAddress: parameter.address))
        XCTAssertEqual(reloadedParameter.value, parameter.minValue, accuracy: 0.001)
    }

    func testRemovingEffectKeepsTheChainWorking() async throws {
        var track = EditTrack(id: "a.wav", kind: .audio, name: "a")
        track.effects = [appleDelay()]
        let graph = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        await graph.setEffects([], for: "a.wav")
        XCTAssertNil(graph.unit(for: track.effects[0].id))
        XCTAssertEqual(try renderPeak(graph), 0.25, accuracy: 0.02)
    }

    func testVolumeAboveZeroDB() async throws {
        var track = EditTrack(id: "a.wav", kind: .audio, name: "a")
        track.volumeDB = 6
        let graph = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        // +6 dB doubles the amplitude.
        XCTAssertEqual(try renderPeak(graph), 0.5, accuracy: 0.03)
    }

    func testMutedTrackIsSilent() async throws {
        var track = EditTrack(id: "a.wav", kind: .audio, name: "a")
        track.muted = true
        let graph = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        XCTAssertEqual(try renderPeak(graph), 0, accuracy: 0.0001)
    }

    func testOffsetDelaysTheTrack() async throws {
        var track = EditTrack(id: "a.wav", kind: .audio, name: "a")
        track.offset = 0.5
        let graph = await AudioGraph(folder: media.folder, project: EditProject(tracks: [track]))
        XCTAssertEqual(graph.duration, 1.5, accuracy: 0.01)
        // About 0.5 s of silence, then the tone.
        try graph.startOfflineRender(maximumFrameCount: 4096)
        defer { graph.finishOfflineRender() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graph.renderFormat, frameCapacity: 4096))
        var peaks: [Float] = []
        for _ in 0..<12 {
            XCTAssertEqual(try graph.engine.renderOffline(4096, to: buffer), .success)
            var peak: Float = 0
            for index in stride(from: 0, to: Int(buffer.frameLength) * 2, by: 2) {
                peak = max(peak, abs(buffer.floatChannelData![0][index]))
            }
            peaks.append(peak)
        }
        // Blocks of 4096 frames at 48 kHz: block 5 ends at 0.512 s.
        XCTAssertEqual(peaks[0...4].max() ?? 1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(peaks[7], 0.2)
    }

    /// Renders half a second offline and returns the peak of the left channel.
    private func renderPeak(_ graph: AudioGraph) throws -> Float {
        try graph.startOfflineRender(maximumFrameCount: 4096)
        defer { graph.finishOfflineRender() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graph.renderFormat, frameCapacity: 4096))
        var peak: Float = 0
        for _ in 0..<6 {
            XCTAssertEqual(try graph.engine.renderOffline(4096, to: buffer), .success)
            // Interleaved stereo: left samples are at even indexes.
            let samples = buffer.floatChannelData![0]
            for index in stride(from: 0, to: Int(buffer.frameLength) * 2, by: 2) {
                peak = max(peak, abs(samples[index]))
            }
        }
        return peak
    }
}
