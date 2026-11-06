import AVFoundation

/// The audio of an edit. Each track is a chain:
/// file player → upmix to stereo → insert effects → gain → pan and mute → stereo mix.
/// The same graph plays live in the editor and renders offline for the export.
///
/// Not thread safe: use one graph from one thread (the main actor for playback,
/// the export queue for an offline render).
public final class AudioGraph: @unchecked Sendable {
    public let engine = AVAudioEngine()
    /// End of the last audio file on the timeline, in seconds.
    public var duration: Double {
        chains.values.map { $0.offset + Double($0.file.length) / $0.file.processingFormat.sampleRate }.max() ?? 0
    }
    public private(set) var warnings: [String] = []
    /// Stereo format used inside the chains.
    public let format: AVAudioFormat

    private final class Chain {
        let file: AVAudioFile
        let player = AVAudioPlayerNode()
        let upmix = AVAudioMixerNode()
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        let output = AVAudioMixerNode()
        var effects: [(id: UUID, unit: AVAudioUnit)] = []
        /// Timeline time = file time + offset, in seconds.
        var offset: Double = 0

        init(file: AVAudioFile) {
            self.file = file
        }
    }

    private var chains: [String: Chain] = [:]

    public var hasAudio: Bool { !chains.isEmpty }

    public init(folder: URL, project: EditProject) async {
        var files: [(EditTrack, AVAudioFile)] = []
        var warnings: [String] = []
        for track in project.audioTracks {
            do {
                files.append((track, try AVAudioFile(forReading: folder.appendingPathComponent(track.id))))
            } catch {
                warnings.append("\(track.id): \(error.localizedDescription)")
            }
        }
        let sampleRate = files.first?.1.processingFormat.sampleRate ?? 48_000
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        self.warnings = warnings

        for (track, file) in files {
            let chain = Chain(file: file)
            for node in [chain.player, chain.upmix, chain.gain, chain.output] as [AVAudioNode] {
                engine.attach(node)
            }
            engine.connect(chain.player, to: chain.upmix, format: file.processingFormat)
            engine.connect(chain.output, to: engine.mainMixerNode, format: format)
            chain.offset = track.offset
            chains[track.id] = chain

            await setEffects(track.effects, for: track.id)
        }
        apply(project)
    }

    // MARK: Settings

    /// Applies volume, pan, mute, solo and bypass. Does not add or remove effects.
    public func apply(_ project: EditProject) {
        for track in project.audioTracks {
            guard let chain = chains[track.id] else { continue }
            chain.offset = track.offset
            chain.gain.globalGain = Float(min(max(track.volumeDB, -96), 24))
            chain.output.pan = Float(min(max(track.pan, -1), 1))
            chain.output.outputVolume = project.isAudible(track) ? 1 : 0
            for effect in track.effects {
                if let unit = chain.effects.first(where: { $0.id == effect.id })?.unit {
                    setBypass(effect.bypassed, on: unit)
                }
            }
        }
    }

    /// Makes the chain of a track match `effects`: keeps the units that are still there,
    /// loads the new ones and removes the others. Effects that fail to load are skipped
    /// and reported in the returned warnings.
    @discardableResult
    public func setEffects(_ effects: [AudioEffect], for trackID: String) async -> [String] {
        guard let chain = chains[trackID] else { return [] }
        var problems: [String] = []
        var updated: [(id: UUID, unit: AVAudioUnit)] = []

        for effect in effects {
            if let existing = chain.effects.first(where: { $0.id == effect.id }) {
                updated.append(existing)
                continue
            }
            do {
                let unit = try await PluginFactory.instantiate(effect)
                try prepareFormat(of: unit)
                engine.attach(unit)
                setBypass(effect.bypassed, on: unit)
                updated.append((effect.id, unit))
            } catch {
                problems.append("\(effect.name): \(error.localizedDescription)")
            }
        }

        let kept = Set(updated.map(\.id))
        for old in chain.effects where !kept.contains(old.id) {
            engine.detach(old.unit)
        }
        chain.effects = updated
        connect(chain)

        warnings += problems
        return problems
    }

    public func unit(for effectID: UUID) -> AVAudioUnit? {
        for chain in chains.values {
            if let unit = chain.effects.first(where: { $0.id == effectID })?.unit {
                return unit
            }
        }
        return nil
    }

    /// Current state of every loaded effect, by effect id.
    public func captureStates() -> [UUID: Data] {
        var states: [UUID: Data] = [:]
        for chain in chains.values {
            for effect in chain.effects {
                states[effect.id] = PluginFactory.captureState(of: effect.unit)
            }
        }
        return states
    }

    private func connect(_ chain: Chain) {
        engine.disconnectNodeOutput(chain.upmix)
        engine.disconnectNodeOutput(chain.gain)
        for effect in chain.effects {
            engine.disconnectNodeOutput(effect.unit)
        }

        var previous: AVAudioNode = chain.upmix
        for effect in chain.effects {
            engine.connect(previous, to: effect.unit, format: format)
            previous = effect.unit
        }
        engine.connect(previous, to: chain.gain, format: format)
        engine.connect(chain.gain, to: chain.output, format: format)
    }

    /// Checks that the effect accepts stereo at our sample rate. Connecting a unit that
    /// refuses the format would raise an exception, so this is done before.
    private func prepareFormat(of unit: AVAudioUnit) throws {
        let audioUnit = unit.auAudioUnit
        guard audioUnit.inputBusses.count > 0, audioUnit.outputBusses.count > 0 else {
            throw EngineError.plugin("This effect has no audio input or output.")
        }
        do {
            try audioUnit.inputBusses[0].setFormat(format)
            try audioUnit.outputBusses[0].setFormat(format)
        } catch {
            throw EngineError.plugin("This effect does not support stereo at \(Int(format.sampleRate)) Hz.")
        }
    }

    private func setBypass(_ bypassed: Bool, on unit: AVAudioUnit) {
        if let effect = unit as? AVAudioUnitEffect {
            effect.bypass = bypassed
        } else {
            unit.auAudioUnit.shouldBypassEffect = bypassed
        }
    }

    // MARK: Live playback

    /// Time between a sample leaving the engine and being heard.
    public var outputLatency: TimeInterval {
        engine.outputNode.presentationLatency
    }

    public func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Plays every track from `seconds`, starting at `hostTime` (mach absolute time).
    public func play(from seconds: Double, atHostTime hostTime: UInt64) {
        let when = AVAudioTime(hostTime: hostTime)
        for chain in chains.values {
            if schedule(chain, from: seconds) {
                chain.player.play(at: when)
            }
        }
    }

    /// Stops the players and clears effect tails, so a new start is clean.
    public func stop() {
        for chain in chains.values {
            chain.player.stop()
            for effect in chain.effects {
                effect.unit.auAudioUnit.reset()
            }
        }
    }

    private func schedule(_ chain: Chain, from seconds: Double) -> Bool {
        chain.player.stop()
        let sampleRate = chain.file.processingFormat.sampleRate
        let fileTime = max(0, seconds) - chain.offset
        let start = AVAudioFramePosition(max(0, fileTime) * sampleRate)
        guard start < chain.file.length else { return false }
        // A file placed later on the timeline starts after a delay, in player time.
        let delay =
            fileTime < 0
            ? AVAudioTime(sampleTime: AVAudioFramePosition(-fileTime * sampleRate), atRate: sampleRate) : nil
        chain.player.scheduleSegment(
            chain.file, startingFrame: start, frameCount: AVAudioFrameCount(chain.file.length - start), at: delay)
        return true
    }

    // MARK: Offline render

    /// Interleaved stereo float, the format given to the AAC encoder.
    public var renderFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 2, interleaved: true)!
    }

    /// Switches the engine to offline rendering and starts every track at zero.
    public func startOfflineRender(maximumFrameCount: AVAudioFrameCount) throws {
        engine.stop()
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maximumFrameCount)
        try engine.start()
        for chain in chains.values where schedule(chain, from: 0) {
            chain.player.play()
        }
    }

    public func finishOfflineRender() {
        engine.stop()
        engine.disableManualRenderingMode()
    }
}
