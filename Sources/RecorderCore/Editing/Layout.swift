import CoreGraphics

/// Geometry of video tracks in the output frame. The origin is the top left corner.
public enum Layout {
    /// Space between a corner picture and the frame edges, relative to the frame width.
    static let marginRatio = 0.03

    /// Area reserved for a track. `nil` when the track is not drawn.
    public static func rect(for placement: VideoPlacement, cornerScale: Double, renderSize: CGSize) -> CGRect? {
        let frame = CGRect(origin: .zero, size: renderSize)
        let scale = min(max(cornerScale, 0.05), 1)
        let width = renderSize.width * scale
        let height = renderSize.height * scale
        let margin = renderSize.width * marginRatio

        switch placement {
        case .hidden:
            return nil
        case .full:
            return frame
        case .topLeft:
            return CGRect(x: margin, y: margin, width: width, height: height)
        case .topRight:
            return CGRect(x: frame.maxX - margin - width, y: margin, width: width, height: height)
        case .bottomLeft:
            return CGRect(x: margin, y: frame.maxY - margin - height, width: width, height: height)
        case .bottomRight:
            return CGRect(
                x: frame.maxX - margin - width, y: frame.maxY - margin - height, width: width, height: height)
        }
    }

    /// Transform that draws a video of `naturalSize` (after `preferredTransform`)
    /// centered in `rect`, keeping its aspect ratio.
    public static func transform(
        naturalSize: CGSize, preferredTransform: CGAffineTransform = .identity, into rect: CGRect
    ) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { return preferredTransform }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let x = rect.minX + (rect.width - drawn.width) / 2
        let y = rect.minY + (rect.height - drawn.height) / 2

        // Move the oriented video back to the origin, scale it, then move it into place.
        return
            preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    /// Part of the source picture kept for a zoom and a center, in source coordinates
    /// (origin top left). `centerX` and `centerY` go from -1 (left / top) to 1 (right / bottom).
    public static func cropRect(sourceSize: CGSize, zoom: Double, centerX: Double, centerY: Double) -> CGRect {
        let scale = min(max(zoom, 1), 8)
        let width = sourceSize.width / scale
        let height = sourceSize.height / scale
        let x = (sourceSize.width - width) / 2 * (1 + min(max(centerX, -1), 1))
        let y = (sourceSize.height - height) / 2 * (1 + min(max(centerY, -1), 1))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Largest rect with the aspect ratio of `size`, centered in `rect`.
    public static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// Drawing order, from the top layer to the bottom one: corner pictures above full screen tracks,
    /// and inside each group the first track in the list is on top.
    public static func drawingOrder(_ tracks: [EditTrack]) -> [EditTrack] {
        let visible = tracks.filter { $0.kind == .video && $0.placement != .hidden }
        return visible.filter { $0.placement.isCorner } + visible.filter { $0.placement == .full }
    }
}
