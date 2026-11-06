import RecorderCore
import SwiftUI

private enum Metrics {
    static let headerWidth: CGFloat = 250
    static let rulerHeight: CGFloat = 24
    static let trackHeight: CGFloat = 84
    /// Lanes are drawn in tiles so only the visible part of a long recording is rendered.
    static let tileWidth: CGFloat = 1024
}

/// Track headers on the left, ruler and lanes on the right, with a playhead.
/// Click or drag in the lanes to move the playhead.
struct TracksTimeline: View {
    @EnvironmentObject private var model: EditorModel
    /// Loop being dragged in the ruler, in seconds. Applied when the drag ends.
    @State private var draggedLoop: (start: Double, end: Double)?

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: Metrics.rulerHeight)
                    Divider()
                    ForEach($model.project.tracks) { $track in
                        TrackHeader(track: $track)
                            .frame(height: Metrics.trackHeight)
                        Divider()
                    }
                }
                .frame(width: Metrics.headerWidth)

                Divider()

                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        lanes
                    }
                    .onAppear { model.viewportWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in model.viewportWidth = width }
                }
                .frame(
                    height: Metrics.rulerHeight + CGFloat(model.project.tracks.count) * (Metrics.trackHeight + 1) + 1)
            }
        }
    }

    private var timelineWidth: CGFloat {
        max(1, CGFloat(model.duration * model.pixelsPerSecond))
    }

    private var lanes: some View {
        let width = timelineWidth
        let scale = model.pixelsPerSecond
        return VStack(alignment: .leading, spacing: 0) {
            ruler(width: width, scale: scale)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.project.tracks) { track in
                    TrackLane(track: track, width: width)
                        .frame(height: Metrics.trackHeight)
                    Divider()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in model.seek(to: Double(value.location.x) / scale) }
            )
        }
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .topLeading) {
            loopOverlay(scale: scale)
        }
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5)
                .offset(x: CGFloat(model.currentTime * scale))
                .allowsHitTesting(false)
        }
    }

    /// Drag in the ruler to set the loop, click to move the playhead, double-click to loop everything.
    private func ruler(width: CGFloat, scale: Double) -> some View {
        TiledLane(width: width, height: Metrics.rulerHeight) { context, range in
            RulerDrawing.draw(in: &context, range: range, pixelsPerSecond: scale, height: Metrics.rulerHeight)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.clearLoopRange() }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    draggedLoop = (Double(value.startLocation.x) / scale, Double(value.location.x) / scale)
                }
                .onEnded { value in
                    draggedLoop = nil
                    model.setLoop(from: Double(value.startLocation.x) / scale, to: Double(value.location.x) / scale)
                }
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in model.seek(to: Double(value.location.x) / scale) }
        )
        .help("Drag to choose the looped part. Double-click to loop everything.")
    }

    @ViewBuilder
    private func loopOverlay(scale: Double) -> some View {
        let range: ClosedRange<Double>? =
            if let draggedLoop {
                min(draggedLoop.start, draggedLoop.end)...max(draggedLoop.start, draggedLoop.end)
            } else {
                model.loopRange
            }
        if let range {
            let active = draggedLoop != nil || model.isLooping
            let x = CGFloat(range.lowerBound * scale)
            let width = max(1, CGFloat((range.upperBound - range.lowerBound) * scale))
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.yellow.opacity(active ? 0.7 : 0.25))
                    .frame(height: Metrics.rulerHeight)
                Rectangle()
                    .fill(Color.yellow.opacity(active ? 0.08 : 0.03))
            }
            .frame(width: width)
            .offset(x: x)
            .allowsHitTesting(false)
        }
    }
}

// MARK: Headers

struct TrackHeader: View {
    @EnvironmentObject private var model: EditorModel
    @Binding var track: EditTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: track.kind == .video ? "video.fill" : "waveform")
                    .foregroundStyle(.secondary)
                Text(track.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(track.id)
                if track.offset != 0 {
                    Text(String(format: "%+.3f s", track.offset))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Position on the timeline. Right-click the track to move it.")
                }
                Spacer(minLength: 0)
                if track.kind == .video {
                    Button {
                        model.togglePicturePanel(for: track.id)
                    } label: {
                        Image(systemName: "camera.filters")
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .frame(height: 16)
                            .background(
                                track.adjustments == .identity
                                    ? Color.gray.opacity(0.25) : Color.accentColor.opacity(0.8),
                                in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help("Picture: color, look, crop and frame")
                }
                if track.kind == .audio {
                    Button {
                        model.toggleEffectsPanel(for: track.id)
                    } label: {
                        Text(track.effects.isEmpty ? "FX" : "FX \(track.effects.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 4)
                            .frame(height: 16)
                            .background(
                                track.effects.isEmpty ? Color.gray.opacity(0.25) : Color.accentColor.opacity(0.8),
                                in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help("Effects")
                    ToggleChip(title: "M", isOn: $track.muted, color: .orange)
                        .help("Mute")
                    ToggleChip(title: "S", isOn: $track.solo, color: .yellow)
                        .help("Solo")
                }
            }

            switch track.kind {
            case .video:
                Picker("Placement", selection: $track.placement) {
                    ForEach(VideoPlacement.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                if track.placement.isCorner {
                    HStack {
                        Text("Size").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $track.cornerScale, in: 0.1...0.6)
                            .controlSize(.small)
                        Text("\(Int(track.cornerScale * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            case .audio:
                HStack {
                    Text("Vol").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                    Slider(value: $track.volumeDB, in: EditProject.minimumVolumeDB...EditProject.maximumVolumeDB)
                        .controlSize(.small)
                    Text(volumeLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                        .onTapGesture(count: 2) { track.volumeDB = 0 }
                }
                .help("Volume. Double-click the value to reset to 0 dB.")
                HStack {
                    Text("Pan").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                    Slider(value: $track.pan, in: -1...1)
                        .controlSize(.small)
                    Text(panLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                        .onTapGesture(count: 2) { track.pan = 0 }
                }
                .help("Pan. Double-click the value to center.")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Section("Move on the timeline") {
                Button("10 ms earlier") { model.shiftTrack(track.id, by: -0.01) }
                Button("10 ms later") { model.shiftTrack(track.id, by: 0.01) }
                Button("100 ms earlier") { model.shiftTrack(track.id, by: -0.1) }
                Button("100 ms later") { model.shiftTrack(track.id, by: 0.1) }
                Button("1 s earlier") { model.shiftTrack(track.id, by: -1) }
                Button("1 s later") { model.shiftTrack(track.id, by: 1) }
            }
            if track.id.hasPrefix(FileNaming.phonePrefix) {
                Button("Sync Again on the Sound") { model.resyncPhoneTrack(track.id) }
            }
            Button("Reset position") { model.setOffset(0, of: track.id) }
                .disabled(track.offset == 0)
        }
    }

    private var volumeLabel: String {
        if track.volumeDB <= EditProject.minimumVolumeDB { return "-∞ dB" }
        return String(format: "%+.1f dB", track.volumeDB)
    }

    private var panLabel: String {
        let percent = Int((track.pan * 100).rounded())
        if percent == 0 { return "C" }
        return percent < 0 ? "L \(-percent)" : "R \(percent)"
    }
}

// MARK: Effects

/// The effect chain of one audio track: bypass, open, reorder, remove, and add.
struct EffectsPopover: View {
    @EnvironmentObject private var model: EditorModel
    let trackID: String

    private var track: EditTrack? {
        model.project.tracks.first { $0.id == trackID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let track, !track.effects.isEmpty {
                ForEach(Array(track.effects.enumerated()), id: \.element.id) { index, effect in
                    effectRow(effect, index: index, count: track.effects.count)
                }
            } else {
                Text("No effect. Audio goes straight to the mix.")
                    .foregroundStyle(.secondary)
            }

            Divider()
            addMenu
        }
        .padding(12)
        .frame(width: 360)
    }

    private func effectRow(_ effect: AudioEffect, index: Int, count: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                setBypass(!effect.bypassed, for: effect.id)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(effect.bypassed ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
            .help(effect.bypassed ? "Turn on" : "Bypass")

            Button {
                model.openEffectWindow(effect.id)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(effect.name).lineLimit(1)
                    Text(effect.kind == .vst3 ? "VST3 · \(effect.manufacturer)" : "AU · \(effect.manufacturer)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isEffectLoaded(effect.id))
            .help(model.isEffectLoaded(effect.id) ? "Open the plug-in window" : "This effect could not be loaded")

            Button {
                model.moveEffect(effect.id, in: trackID, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                model.moveEffect(effect.id, in: trackID, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == count - 1)

            Button {
                model.removeEffect(effect.id, from: trackID)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    private var addMenu: some View {
        let audioUnits = model.availableEffects.filter { $0.kind == .audioUnit }
        let vst3 = model.availableEffects.filter { $0.kind == .vst3 }
        return Menu("Add effect") {
            if model.availableEffects.isEmpty {
                Text("Looking for plug-ins…")
            }
            if !audioUnits.isEmpty {
                pluginMenu("Audio Units", audioUnits)
            }
            if !vst3.isEmpty {
                pluginMenu("VST3", vst3)
            }
        }
    }

    private func pluginMenu(_ title: String, _ effects: [AudioEffect]) -> some View {
        let byManufacturer = Dictionary(grouping: effects) { $0.manufacturer.isEmpty ? "Other" : $0.manufacturer }
        return Menu(title) {
            ForEach(byManufacturer.keys.sorted(), id: \.self) { manufacturer in
                Menu(manufacturer) {
                    ForEach(byManufacturer[manufacturer] ?? []) { effect in
                        Button(effect.name) { model.addEffect(effect, to: trackID) }
                    }
                }
            }
        }
    }

    private func setBypass(_ bypassed: Bool, for effectID: UUID) {
        guard let trackIndex = model.project.tracks.firstIndex(where: { $0.id == trackID }),
            let effectIndex = model.project.tracks[trackIndex].effects.firstIndex(where: { $0.id == effectID })
        else { return }
        model.project.tracks[trackIndex].effects[effectIndex].bypassed = bypassed
    }
}

struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.caption.bold())
                .frame(width: 18, height: 16)
                .background(isOn ? color : Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(isOn ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Lanes

struct TrackLane: View {
    @EnvironmentObject private var model: EditorModel
    let track: EditTrack
    let width: CGFloat

    var body: some View {
        let scale = model.pixelsPerSecond
        let duration = model.duration
        switch track.kind {
        case .video:
            let images = model.thumbnails[track.id] ?? []
            let length = model.fileDurations[track.id] ?? duration
            let offset = track.offset
            TiledLane(width: width, height: Metrics.trackHeight) { context, range in
                ThumbnailDrawing.draw(
                    in: &context, range: range, images: images, fileDuration: length, offset: offset,
                    pixelsPerSecond: scale, height: Metrics.trackHeight)
            }
            .opacity(track.placement == .hidden ? 0.35 : 1)
        case .audio:
            let peaks = model.waveforms[track.id] ?? []
            let gain = model.project.gain(of: track)
            let length = model.fileDurations[track.id] ?? duration
            let offset = track.offset
            TiledLane(width: width, height: Metrics.trackHeight) { context, range in
                WaveformDrawing.draw(
                    in: &context, range: range, peaks: peaks, fileDuration: length, offset: offset,
                    pixelsPerSecond: scale, gain: gain, height: Metrics.trackHeight)
            }
        }
    }
}

/// A lane split into canvases. `LazyHStack` only builds the tiles that are on screen.
struct TiledLane: View {
    let width: CGFloat
    let height: CGFloat
    /// Draws the part of the lane between `range.lowerBound` and `range.upperBound`,
    /// in tile coordinates (x = 0 is `range.lowerBound`).
    let draw: (inout GraphicsContext, ClosedRange<CGFloat>) -> Void

    var body: some View {
        let count = max(1, Int((width / Metrics.tileWidth).rounded(.up)))
        LazyHStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let start = CGFloat(index) * Metrics.tileWidth
                let end = min(width, start + Metrics.tileWidth)
                Canvas { context, _ in
                    draw(&context, start...end)
                }
                .frame(width: max(1, end - start), height: height)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }
}

// MARK: Drawing

enum RulerDrawing {
    static func draw(
        in context: inout GraphicsContext, range: ClosedRange<CGFloat>, pixelsPerSecond: Double, height: CGFloat
    ) {
        let steps: [Double] = [0.1, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { $0 * pixelsPerSecond >= 70 } ?? 3600

        var seconds = (Double(range.lowerBound) / pixelsPerSecond / step).rounded(.down) * step
        while CGFloat(seconds * pixelsPerSecond) <= range.upperBound {
            let x = CGFloat(seconds * pixelsPerSecond) - range.lowerBound
            var line = Path()
            line.move(to: CGPoint(x: x, y: height * 0.5))
            line.addLine(to: CGPoint(x: x, y: height))
            context.stroke(line, with: .color(.secondary), lineWidth: 1)
            let label = step < 1 ? String(format: "%.1f", seconds) : TimeFormat.short(seconds)
            context.draw(
                Text(label).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
            seconds += step
        }
    }
}

enum ThumbnailDrawing {
    static func draw(
        in context: inout GraphicsContext, range: ClosedRange<CGFloat>, images: [CGImage], fileDuration: Double,
        offset: Double, pixelsPerSecond: Double, height: CGFloat
    ) {
        // Only the part of the timeline covered by the file.
        let fileStart = max(range.lowerBound, CGFloat(offset * pixelsPerSecond))
        let fileEnd = min(range.upperBound, CGFloat((offset + fileDuration) * pixelsPerSecond))
        guard fileEnd > fileStart else { return }
        let area = CGRect(x: fileStart - range.lowerBound, y: 0, width: fileEnd - fileStart, height: height)
        context.fill(Path(area), with: .color(Color.blue.opacity(0.15)))
        guard !images.isEmpty, fileDuration > 0 else { return }

        context.clip(to: Path(area))
        let slotWidth = height * 16 / 9
        let origin = CGFloat(offset * pixelsPerSecond)
        var slotStart = ((fileStart - origin) / slotWidth).rounded(.down) * slotWidth + origin
        while slotStart < fileEnd {
            let time = Double(slotStart + slotWidth / 2) / pixelsPerSecond - offset
            let index = min(images.count - 1, max(0, Int(time / fileDuration * Double(images.count))))
            let rect = CGRect(x: slotStart - range.lowerBound, y: 2, width: slotWidth - 2, height: height - 4)
            context.draw(Image(decorative: images[index], scale: 1), in: rect)
            slotStart += slotWidth
        }
    }
}

enum WaveformDrawing {
    static func draw(
        in context: inout GraphicsContext, range: ClosedRange<CGFloat>, peaks: [Float], fileDuration: Double,
        offset: Double, pixelsPerSecond: Double, gain: Float, height: CGFloat
    ) {
        let width = range.upperBound - range.lowerBound
        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(Color.green.opacity(0.08)))

        let middle = height / 2
        var centerLine = Path()
        centerLine.move(to: CGPoint(x: 0, y: middle))
        centerLine.addLine(to: CGPoint(x: width, y: middle))
        context.stroke(centerLine, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
        guard !peaks.isEmpty, fileDuration > 0, pixelsPerSecond > 0 else { return }

        // Peak index of a timeline position, in pixels from the start of the timeline.
        let peaksPerPixel = Double(peaks.count) / (fileDuration * pixelsPerSecond)
        let origin = offset * pixelsPerSecond
        var shape = Path()
        var x: CGFloat = 0
        while x < width {
            let position = Double(range.lowerBound + x) - origin
            guard position + 1 > 0, position < fileDuration * pixelsPerSecond else {
                x += 1
                continue
            }
            let start = Int(position * peaksPerPixel)
            let end = Int((position + 1) * peaksPerPixel)
            var peak: Float = 0
            for index in max(0, start)...min(peaks.count - 1, max(start, end)) {
                peak = max(peak, peaks[index])
            }
            let amplitude = CGFloat(min(1, peak * gain)) * (middle - 2)
            shape.addRect(CGRect(x: x, y: middle - amplitude, width: 1, height: max(0.5, amplitude * 2)))
            x += 1
        }
        context.fill(shape, with: .color(gain > 0 ? Color.green : Color.gray))
    }
}
