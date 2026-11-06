import AVFoundation

/// The video files of a recording placed on one timeline, and how they are composed.
/// The same composition drives the preview player and the export,
/// so what you see is what you export. Audio goes through `AudioGraph`.
public final class EditComposition: @unchecked Sendable {
    public let composition = AVMutableComposition()
    public private(set) var duration: CMTime = .zero
    /// Size of the first video track, used as the default output size.
    public private(set) var naturalRenderSize = CGSize(width: 1920, height: 1080)
    public private(set) var frameDuration = CMTime(value: 1, timescale: 30)
    /// Tracks that could not be loaded, with the reason.
    public private(set) var warnings: [String] = []

    private struct VideoSource {
        let track: AVMutableCompositionTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
    }

    private var videoSources: [String: VideoSource] = [:]

    private init() {}

    public static func load(folder: URL, project: EditProject) async throws -> EditComposition {
        let edit = EditComposition()
        var frameRate: Float = 0
        var sizeIsSet = false

        for track in project.videoTracks {
            let url = folder.appendingPathComponent(track.id)
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            do {
                guard let source = try await asset.loadTracks(withMediaType: .video).first,
                    let target = edit.composition.addMutableTrack(
                        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else {
                    edit.warnings.append("\(track.id): no video track.")
                    continue
                }
                // Every file of a recording starts at the same instant, so keep the original times,
                // moved by the track offset (clips from phones). A part before zero is cut.
                let range = try await source.load(.timeRange)
                var sourceRange = range
                var at = range.start + CMTime(seconds: track.offset, preferredTimescale: 90_000)
                if at < .zero {
                    let cut = CMTime.zero - at
                    sourceRange = CMTimeRange(start: range.start + cut, duration: range.duration - cut)
                    at = .zero
                }
                guard sourceRange.duration > .zero else {
                    edit.warnings.append("\(track.id): the offset moves the whole clip before the start.")
                    continue
                }
                try target.insertTimeRange(sourceRange, of: source, at: at)
                edit.duration = max(edit.duration, at + sourceRange.duration)

                let (size, transform, rate) = try await source.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate)
                edit.videoSources[track.id] = VideoSource(
                    track: target, naturalSize: size, preferredTransform: transform)
                frameRate = max(frameRate, rate)
                if !sizeIsSet {
                    let oriented = CGRect(origin: .zero, size: size).applying(transform)
                    edit.naturalRenderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                    sizeIsSet = true
                }
            } catch {
                edit.warnings.append("\(track.id): \(error.localizedDescription)")
            }
        }

        if frameRate > 0 {
            let rate = Int32(min(max(frameRate.rounded(), 24), 60))
            edit.frameDuration = CMTime(value: 1, timescale: rate)
        }
        return edit
    }

    public var hasVideo: Bool { !videoSources.isEmpty }

    /// How video tracks are placed in the output frame.
    public func videoComposition(for project: EditProject, renderSize: CGSize? = nil) -> AVMutableVideoComposition? {
        guard hasVideo else { return nil }
        let size = renderSize ?? naturalRenderSize

        // Drawing order is top first; the renderer draws bottom first.
        let layers: [CompositionInstruction.Layer] = Layout.drawingOrder(project.tracks).reversed().compactMap {
            track in
            guard let source = videoSources[track.id],
                let rect = Layout.rect(for: track.placement, cornerScale: track.cornerScale, renderSize: size)
            else { return nil }
            return CompositionInstruction.Layer(
                trackID: source.track.trackID, rect: rect, adjustments: track.adjustments,
                preferredTransform: source.preferredTransform)
        }

        let instruction = CompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration), layers: layers, renderSize: size)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CoreImageCompositor.self
        videoComposition.renderSize = size
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    var compositionVideoTracks: [AVAssetTrack] { composition.tracks(withMediaType: .video) }
}
