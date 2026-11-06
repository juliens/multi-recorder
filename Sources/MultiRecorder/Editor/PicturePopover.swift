import RecorderCore
import SwiftUI

/// Picture settings of the track `trackID`, shown in a floating panel.
struct PicturePanel: View {
    @EnvironmentObject private var model: EditorModel
    let trackID: String

    var body: some View {
        if let index = model.project.tracks.firstIndex(where: { $0.id == trackID }) {
            PicturePopover(track: $model.project.tracks[index])
        }
    }
}

/// Core Image settings of one video track. Changes show at once in the preview.
struct PicturePopover: View {
    @Binding var track: EditTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button("Reset") { track.adjustments = .identity }
                    .disabled(track.adjustments == .identity)
            }

            section("Color") {
                SettingSlider(
                    title: "Exposure", value: $track.adjustments.exposure, range: -2...2, neutral: 0,
                    format: { String(format: "%+.1f EV", $0) })
                SettingSlider(
                    title: "Contrast", value: $track.adjustments.contrast, range: 0.5...1.5, neutral: 1,
                    format: percent)
                SettingSlider(
                    title: "Saturation", value: $track.adjustments.saturation, range: 0...2, neutral: 1,
                    format: percent)
                SettingSlider(
                    title: "Temperature", value: $track.adjustments.temperature, range: -1...1, neutral: 0,
                    format: { $0 == 0 ? "0" : String(format: "%+.0f", $0 * 100) })
                Picker("Look", selection: $track.adjustments.look) {
                    ForEach(VideoLook.allCases) { Text($0.label).tag($0) }
                }
            }

            section("Crop") {
                SettingSlider(
                    title: "Zoom", value: $track.adjustments.zoom, range: 1...4, neutral: 1,
                    format: { String(format: "%.2f×", $0) })
                SettingSlider(
                    title: "Horizontal", value: $track.adjustments.centerX, range: -1...1, neutral: 0,
                    format: position
                )
                .disabled(track.adjustments.zoom <= 1)
                SettingSlider(
                    title: "Vertical", value: $track.adjustments.centerY, range: -1...1, neutral: 0,
                    format: position
                )
                .disabled(track.adjustments.zoom <= 1)
            }

            section("Frame") {
                SettingSlider(
                    title: "Corners", value: $track.adjustments.cornerRadius, range: 0...0.5, neutral: 0,
                    format: percent)
                SettingSlider(
                    title: "Border", value: $track.adjustments.border, range: 0...0.03, neutral: 0,
                    format: { String(format: "%.1f%%", $0 * 100) })
            }
            Text("Double-click a value to reset it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func position(_ value: Double) -> String {
        value == 0 ? "Center" : String(format: "%+.0f", value * 100)
    }
}

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
                .frame(width: 82, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
                .onTapGesture(count: 2) { value = neutral }
        }
    }
}
