import AVFoundation
import CoreImage

/// What to draw for a time range: the video tracks, their areas and settings.
final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    struct Layer {
        let trackID: CMPersistentTrackID
        let rect: CGRect
        let adjustments: VideoAdjustments
        let preferredTransform: CGAffineTransform
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    /// From the bottom to the top.
    let layers: [Layer]
    let renderSize: CGSize

    init(timeRange: CMTimeRange, layers: [Layer], renderSize: CGSize) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

/// Renders every frame of the edit with Core Image (`VideoRenderer`).
/// Used by the preview player and by the export.
final class CoreImageCompositor: NSObject, AVVideoCompositing {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private let queue = DispatchQueue(label: "compositor", qos: .userInitiated)

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            Self.render(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Requests are short; let the queued ones finish.
    }

    private static func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: EngineError.writer("Cannot render the video frame."))
            return
        }

        let layers: [VideoRenderer.Layer] = instruction.layers.compactMap { layer in
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { return nil }
            let image = oriented(CIImage(cvPixelBuffer: buffer), by: layer.preferredTransform)
            return VideoRenderer.Layer(image: image, rect: layer.rect, adjustments: layer.adjustments)
        }

        let size = request.renderContext.size
        let image = VideoRenderer.compose(layers, renderSize: size)
        context.render(
            image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: outputColorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    /// Applies the rotation of a track (for example a phone filmed in portrait).
    static func oriented(_ image: CIImage, by transform: CGAffineTransform) -> CIImage {
        guard transform != .identity else { return image }
        let degrees = (atan2(transform.b, transform.a) * 180 / .pi).rounded()
        switch degrees {
        case 90: return image.oriented(.right)
        case -90: return image.oriented(.left)
        case 180, -180: return image.oriented(.down)
        default: return image
        }
    }
}
