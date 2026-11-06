import AVFoundation
import AppKit
import RecorderCore

@MainActor
final class EditorModel: ObservableObject {
    let folder: URL
    /// Plays the composed video only. Its sound is muted: audio comes from `audio`.
    let player = AVPlayer()

    @Published var project = EditProject(tracks: []) {
        didSet { projectChanged(from: oldValue) }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoaded = false

    /// Playback starts again at the loop start when it reaches the loop end.
    @Published var isLooping = false {
        didSet { if isPlaying, isLooping != oldValue { restartPlayback() } }
    }
    /// Part of the timeline to loop. Nil loops the whole timeline.
    @Published var loopRange: ClosedRange<Double>? {
        didSet { if isPlaying, isLooping, loopRange != oldValue { restartPlayback() } }
    }

    /// Horizontal zoom of the timeline.
    @Published var pixelsPerSecond: Double = 20
    /// Width of the visible timeline area, used by "Fit".
    var viewportWidth: Double = 800

    @Published private(set) var waveforms: [String: [Float]] = [:]
    @Published private(set) var thumbnails: [String: [CGImage]] = [:]
    /// Length of each file, in seconds, to draw it at its place on the timeline.
    @Published private(set) var fileDurations: [String: Double] = [:]
    /// Effects installed on this Mac.
    @Published private(set) var availableEffects: [AudioEffect] = []

    @Published private(set) var status: String?
    @Published private(set) var exportProgress: Double?

    private var edit: EditComposition?
    private var audio: AudioGraph?
    private let pluginWindows = PluginWindows()
    private let toolPanels = ToolPanels()

    private var clock: Timer?
    private var loopTimer: Timer?
    private var playStartHostTime: UInt64 = 0
    private var playStartTime: Double = 0

    private var saveTask: Task<Void, Never>?
    private var effectsTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// Effect whose window opens once it is loaded.
    private var effectToOpen: UUID?

    static let minPixelsPerSecond = 1.0
    static let maxPixelsPerSecond = 400.0

    init(folder: URL) {
        self.folder = folder
        player.isMuted = true
        player.actionAtItemEnd = .pause
        // Needed to start the video at an exact host time, in sync with the audio.
        player.automaticallyWaitsToMinimizeStalling = false
        pluginWindows.onClose = { [weak self] _ in self?.saveNow() }
    }

    // MARK: Loading

    func load() async {
        guard !isLoaded else { return }
        do {
            let loaded = try EditProject.load(folder: folder)
            let edit = try await EditComposition.load(folder: folder, project: loaded)
            let audio = await AudioGraph(folder: folder, project: loaded)
            self.edit = edit
            self.audio = audio
            duration = max(edit.duration.seconds, audio.duration)
            project = loaded

            if edit.hasVideo {
                let item = AVPlayerItem(asset: edit.composition)
                item.videoComposition = edit.videoComposition(for: project)
                player.replaceCurrentItem(with: item)
            }
            try audio.start()

            let warnings = edit.warnings + audio.warnings
            status = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            isLoaded = true
            fitToWindow()
            loadTrackPictures()
            loadAvailableEffects()
        } catch {
            status = "Cannot open \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Waveforms and thumbnails are computed in the background, track by track.
    private func loadTrackPictures() {
        let duration = duration
        for track in project.tracks {
            let url = folder.appendingPathComponent(track.id)
            let id = track.id
            switch track.kind {
            case .audio:
                let buckets = Int(min(max(duration * 50, 200), 50_000))
                Task.detached(priority: .utility) {
                    let length = (try? AVAudioFile(forReading: url)).map {
                        Double($0.length) / $0.processingFormat.sampleRate
                    }
                    let peaks = (try? MediaAnalysis.waveform(url: url, buckets: buckets)) ?? []
                    await MainActor.run { [weak self] in
                        self?.fileDurations[id] = length
                        self?.waveforms[id] = peaks
                    }
                }
            case .video:
                let count = Int(min(max(duration / 2, 10), 300))
                Task.detached(priority: .utility) {
                    let length = try? await AVURLAsset(url: url).load(.duration).seconds
                    await MainActor.run { [weak self] in self?.fileDurations[id] = length }
                    let images = await MediaAnalysis.thumbnails(url: url, count: count, maxHeight: 90)
                    await MainActor.run { [weak self] in self?.thumbnails[id] = images }
                }
            }
        }
    }

    private func loadAvailableEffects() {
        Task.detached(priority: .utility) {
            let effects = PluginCatalog.audioUnits() + PluginCatalog.vst3Plugins()
            await MainActor.run { [weak self] in self?.availableEffects = effects }
        }
    }

    // MARK: Settings

    private func projectChanged(from old: EditProject) {
        guard isLoaded else { return }

        if Self.offsets(old) != Self.offsets(project) {
            audio?.apply(project)
            rebuildComposition()
        } else if Self.videoSettings(old) != Self.videoSettings(project), let edit, let item = player.currentItem {
            item.videoComposition = edit.videoComposition(for: project)
            if !isPlaying {
                // Redraw the paused frame with the new layout.
                seek(to: currentTime)
            }
        }
        if Self.effectLists(old) != Self.effectLists(project) {
            updateEffects()
        }
        audio?.apply(project)
        scheduleSave()
    }

    private static func videoSettings(_ project: EditProject) -> [String] {
        project.videoTracks.map { "\($0.id)|\($0.placement.rawValue)|\($0.cornerScale)|\($0.adjustments)" }
    }

    private static func offsets(_ project: EditProject) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0.offset) })
    }

    private var rebuildTask: Task<Void, Never>?

    /// Places the video files again after an offset changed.
    private func rebuildComposition() {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        rebuildTask?.cancel()
        let project = project
        let folder = folder
        rebuildTask = Task {
            guard let rebuilt = try? await EditComposition.load(folder: folder, project: project),
                !Task.isCancelled
            else { return }
            edit = rebuilt
            if rebuilt.hasVideo {
                let item = AVPlayerItem(asset: rebuilt.composition)
                item.videoComposition = rebuilt.videoComposition(for: self.project)
                player.replaceCurrentItem(with: item)
            } else {
                player.replaceCurrentItem(with: nil)
            }
            duration = max(rebuilt.duration.seconds, audio?.duration ?? 0)
            if wasPlaying {
                play()
            } else {
                seek(to: currentTime)
            }
        }
    }

    /// Moves a track on the timeline, for example to fix the sync of a phone clip.
    /// The video and the sound of a phone clip move together.
    func shiftTrack(_ trackID: String, by seconds: Double) {
        guard let track = project.tracks.first(where: { $0.id == trackID }) else { return }
        setOffset(((track.offset + seconds) * 1000).rounded() / 1000, of: trackID)
    }

    func setOffset(_ seconds: Double, of trackID: String) {
        var tracks = project.tracks
        for index in tracks.indices
        where tracks[index].id == trackID || tracks[index].id == pairedTrack(of: trackID)?.id {
            tracks[index].offset = seconds
        }
        project.tracks = tracks
    }

    /// Finds the position of a phone clip again by matching its sound with the recorded channels.
    func resyncPhoneTrack(_ trackID: String) {
        guard trackID.hasPrefix(FileNaming.phonePrefix) else { return }
        let folder = folder
        let placements = ClipPlacement.load(folder: folder)
        // Phones start just after the Mac, so without a network estimate look near zero.
        let guess =
            placements[trackID]?.networkOffset ?? pairedTrack(of: trackID).flatMap {
                placements[$0.id]?.networkOffset
            } ?? 0.3
        let clip = folder.appendingPathComponent(trackID)
        let references = project.audioTracks
            .filter { !$0.id.hasPrefix(FileNaming.phonePrefix) }
            .map { folder.appendingPathComponent($0.id) }
        let pair = pairedTrack(of: trackID)?.id
        status = "Matching the sound of \(trackID)…"
        Task {
            guard let match = await AudioSync.vote(references: references, clip: clip, guess: guess) else {
                status = "The sound of \(trackID) does not match the recorded channels."
                return
            }
            setOffset(match.offset, of: trackID)
            let placement = ClipPlacement(
                offset: match.offset, method: .audio, confidence: match.confidence,
                networkOffset: placements[trackID]?.networkOffset)
            var updated = [trackID: placement]
            if let pair { updated[pair] = placement }
            try? ClipPlacement.save(updated, folder: folder)
            status = String(format: "Synced on the sound: offset %+.3f s.", match.offset)
        }
    }

    /// The video and the sound of the same phone clip share a name, with another extension.
    func pairedTrack(of trackID: String) -> EditTrack? {
        guard trackID.hasPrefix(FileNaming.phonePrefix) else { return nil }
        let base = (trackID as NSString).deletingPathExtension
        return project.tracks.first { $0.id != trackID && ($0.id as NSString).deletingPathExtension == base }
    }

    private static func effectLists(_ project: EditProject) -> [String: [UUID]] {
        Dictionary(uniqueKeysWithValues: project.audioTracks.map { ($0.id, $0.effects.map(\.id)) })
    }

    /// Loads new effects and removes old ones. Playback stops while the chains change.
    private func updateEffects() {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        let previous = effectsTask
        effectsTask = Task {
            await previous?.value
            guard let audio else { return }
            var problems: [String] = []
            for track in project.audioTracks {
                problems += await audio.setEffects(track.effects, for: track.id)
            }
            audio.apply(project)
            if !problems.isEmpty {
                status = problems.joined(separator: "\n")
            }
            if let id = effectToOpen {
                effectToOpen = nil
                openEffectWindow(id)
            }
            if wasPlaying { play() }
        }
    }

    /// The project with the current state of every loaded effect.
    private func projectWithEffectStates() -> EditProject {
        guard let audio else { return project }
        let states = audio.captureStates()
        var copy = project
        for trackIndex in copy.tracks.indices {
            for effectIndex in copy.tracks[trackIndex].effects.indices {
                let id = copy.tracks[trackIndex].effects[effectIndex].id
                if let state = states[id] {
                    copy.tracks[trackIndex].effects[effectIndex].state = state
                }
            }
        }
        return copy
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard isLoaded else { return }
        do {
            try projectWithEffectStates().save(folder: folder)
        } catch {
            status = "Cannot save the edit: \(error.localizedDescription)"
        }
    }

    // MARK: Effects

    func addEffect(_ template: AudioEffect, to trackID: String) {
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let effect = template.makeInstance()
        effectToOpen = effect.id
        project.tracks[index].effects.append(effect)
    }

    func removeEffect(_ effectID: UUID, from trackID: String) {
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        pluginWindows.close(effectID)
        project.tracks[index].effects.removeAll { $0.id == effectID }
    }

    func moveEffect(_ effectID: UUID, in trackID: String, by offset: Int) {
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }),
            let from = project.tracks[index].effects.firstIndex(where: { $0.id == effectID })
        else { return }
        let to = from + offset
        guard project.tracks[index].effects.indices.contains(to) else { return }
        project.tracks[index].effects.swapAt(from, to)
    }

    func isEffectLoaded(_ effectID: UUID) -> Bool {
        audio?.unit(for: effectID) != nil
    }

    func openEffectWindow(_ effectID: UUID) {
        guard let unit = audio?.unit(for: effectID),
            let track = project.tracks.first(where: { $0.effects.contains { $0.id == effectID } }),
            let effect = track.effects.first(where: { $0.id == effectID })
        else { return }
        pluginWindows.open(effectID: effectID, unit: unit, title: "\(effect.name) – \(track.name)")
    }

    // MARK: Tool panels

    func toggleEffectsPanel(for trackID: String) {
        let name = project.tracks.first { $0.id == trackID }?.name ?? ""
        toolPanels.toggle("fx|\(trackID)", title: "Effects – \(name)") {
            EffectsPopover(trackID: trackID).environmentObject(self)
        }
    }

    func togglePicturePanel(for trackID: String) {
        let name = project.tracks.first { $0.id == trackID }?.name ?? ""
        toolPanels.toggle("picture|\(trackID)", title: "Picture – \(name)") {
            PicturePanel(trackID: trackID).environmentObject(self)
        }
    }

    // MARK: Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// The looped part, or nil when the loop is off.
    var activeLoop: ClosedRange<Double>? {
        guard isLooping, duration > 0 else { return nil }
        let range = loopRange ?? 0...duration
        let start = min(max(range.lowerBound, 0), duration)
        let end = min(max(range.upperBound, 0), duration)
        return end - start >= Self.minimumLoopLength ? start...end : 0...duration
    }

    static let minimumLoopLength = 0.1

    func play() {
        guard let audio, !isPlaying else { return }
        if let loop = activeLoop {
            if !loop.contains(currentTime) || currentTime >= loop.upperBound - 0.05 {
                currentTime = loop.lowerBound
            }
        } else if currentTime >= duration - 0.05 {
            currentTime = 0
        }
        let start = currentTime
        // Start a little later so the audio and the video can both be ready at that instant.
        let hostStart = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.12)
        let latency = AVAudioTime.hostTime(forSeconds: audio.outputLatency)
        audio.play(from: start, atHostTime: hostStart > latency ? hostStart - latency : hostStart)
        if player.currentItem != nil {
            player.setRate(
                1, time: CMTime(seconds: start, preferredTimescale: 600),
                atHostTime: CMClockMakeHostTimeFromSystemUnits(hostStart))
        }

        playStartHostTime = hostStart
        playStartTime = start
        isPlaying = true
        clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let loop = activeLoop {
            // A dedicated timer ends the loop on time; the 30 Hz clock could be 33 ms late.
            let now = mach_absolute_time()
            let lead = hostStart > now ? AVAudioTime.seconds(forHostTime: hostStart - now) : 0
            let delay = lead + loop.upperBound - start
            loopTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.loopAround() }
            }
        }
    }

    private func loopAround() {
        guard isPlaying, let loop = activeLoop else { return }
        stopPlayback()
        currentTime = loop.lowerBound
        play()
    }

    /// Applies a new loop setting while playing.
    private func restartPlayback() {
        let time = playheadTime()
        stopPlayback()
        currentTime = min(max(time, 0), duration)
        play()
    }

    func toggleLoop() {
        isLooping.toggle()
    }

    /// Sets the looped part from two times in any order, and turns the loop on.
    func setLoop(from first: Double, to second: Double) {
        let start = min(max(min(first, second), 0), duration)
        let end = min(max(max(first, second), 0), duration)
        guard end - start >= Self.minimumLoopLength else { return }
        loopRange = start...end
        isLooping = true
    }

    func clearLoopRange() {
        loopRange = nil
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = min(playheadTime(), duration)
        stopPlayback()
    }

    private func stopPlayback() {
        clock?.invalidate()
        clock = nil
        loopTimer?.invalidate()
        loopTimer = nil
        audio?.stop()
        player.pause()
        isPlaying = false
    }

    private func playheadTime() -> Double {
        let now = mach_absolute_time()
        guard now > playStartHostTime else { return playStartTime }
        return playStartTime + AVAudioTime.seconds(forHostTime: now - playStartHostTime)
    }

    private func tick() {
        let time = playheadTime()
        if let loop = activeLoop, time >= loop.upperBound {
            loopAround()
        } else if time >= duration {
            currentTime = duration
            stopPlayback()
        } else {
            currentTime = time
        }
    }

    func seek(to seconds: Double) {
        let time = min(max(seconds, 0), duration)
        if isPlaying {
            stopPlayback()
            currentTime = time
            play()
        } else {
            currentTime = time
            player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func step(by seconds: Double) {
        seek(to: (isPlaying ? playheadTime() : currentTime) + seconds)
    }

    func fitToWindow() {
        guard duration > 0 else { return }
        pixelsPerSecond = min(
            max((viewportWidth - 20) / duration, Self.minPixelsPerSecond), Self.maxPixelsPerSecond)
    }

    // MARK: Export

    var sourceSize: CGSize { edit?.naturalRenderSize ?? CGSize(width: 1920, height: 1080) }

    var canExport: Bool {
        guard let edit, let audio else { return false }
        return (edit.hasVideo || audio.hasAudio) && exportProgress == nil
    }

    func export(options: ExportOptions, to url: URL) {
        guard let edit else { return }
        pause()
        exportProgress = 0
        status = nil
        let project = projectWithEffectStates()
        let folder = folder
        exportTask = Task {
            do {
                try await Exporter.export(edit, folder: folder, project: project, options: options, to: url) {
                    value in
                    Task { @MainActor [weak self] in
                        if self?.exportProgress != nil { self?.exportProgress = value }
                    }
                }
                status = "Exported \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                status = "Export cancelled."
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
            exportProgress = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// Called when the editor window closes.
    func stop() {
        pause()
        saveTask?.cancel()
        saveNow()
        pluginWindows.closeAll()
        toolPanels.closeAll()
        audio?.engine.stop()
    }
}
