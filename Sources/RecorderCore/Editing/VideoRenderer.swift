import CoreImage
import Foundation

/// Composes video layers with Core Image. Pure: frames in, one image out.
///
/// Layout rects use the output frame with the origin at the top left, like `Layout`.
/// Core Image uses the bottom left, so rects are flipped here.
public enum VideoRenderer {
    public struct Layer {
        public var image: CIImage
        /// Area of the output frame given to this layer (origin top left).
        public var rect: CGRect
        public var adjustments: VideoAdjustments

        public init(image: CIImage, rect: CGRect, adjustments: VideoAdjustments) {
            self.image = image
            self.rect = rect
            self.adjustments = adjustments
        }
    }

    /// `layers` go from the bottom to the top.
    public static func compose(_ layers: [Layer], renderSize: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: renderSize)
        var output = CIImage(color: .black).cropped(to: frame)
        for layer in layers {
            output = render(layer, renderSize: renderSize).composited(over: output)
        }
        return output.cropped(to: frame)
    }

    static func render(_ layer: Layer, renderSize: CGSize) -> CIImage {
        let settings = layer.adjustments

        // Move the source to the origin, then keep the zoomed part.
        var image = layer.image.transformed(
            by: CGAffineTransform(translationX: -layer.image.extent.minX, y: -layer.image.extent.minY))
        let size = image.extent.size
        let crop = Layout.cropRect(
            sourceSize: size, zoom: settings.zoom, centerX: settings.centerX, centerY: settings.centerY)
        image = image.cropped(to: flip(crop, height: size.height))

        image = applyColor(settings, to: image)

        // Scale the kept part into the layer area, keeping its aspect ratio.
        let target = flip(Layout.fit(crop.size, in: layer.rect), height: renderSize.height)
        image =
            image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / crop.width, y: target.height / crop.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: target)

        let radius = min(target.width, target.height) * min(max(settings.cornerRadius, 0), 0.5)
        if radius > 0.5 {
            let mask = roundedRect(target, radius: radius, color: .white)
            image = image.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }

        let border = renderSize.width * min(max(settings.border, 0), 0.05)
        if border > 0.5 {
            let outline = roundedRect(
                target.insetBy(dx: -border, dy: -border), radius: radius > 0.5 ? radius + border : 0, color: .white)
            image = image.composited(over: outline)
        }
        return image
    }

    static func applyColor(_ settings: VideoAdjustments, to input: CIImage) -> CIImage {
        var image = input
        if settings.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        }
        if settings.contrast != 1 || settings.saturation != 1 {
            image = image.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputContrastKey: settings.contrast,
                    kCIInputSaturationKey: settings.saturation,
                    kCIInputBrightnessKey: 0,
                ])
        }
        if settings.temperature != 0 {
            // A source neutral above 6500 K makes the picture warmer (checked by a test).
            let neutral = 6500.0
            let source = neutral + min(max(settings.temperature, -1), 1) * 2500
            image = image.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": CIVector(x: source, y: 0),
                    "inputTargetNeutral": CIVector(x: neutral, y: 0),
                ])
        }
        if let name = settings.look.filterName {
            image = image.applyingFilter(name)
        }
        return image.cropped(to: input.extent)
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: color).cropped(to: rect)
        }
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(color, forKey: kCIInputColorKey)
        return filter.outputImage?.cropped(to: rect) ?? CIImage(color: color).cropped(to: rect)
    }

    /// Converts a rect between top-left and bottom-left origins.
    static func flip(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
