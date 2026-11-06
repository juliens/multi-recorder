import AVFoundation
import CoreImage
import XCTest

@testable import RecorderCore

/// RGB of one pixel, 0...255, read with the origin at the top left.
private struct Pixel {
    let red: Int
    let green: Int
    let blue: Int
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw the image so that pixel (x, y) from the top lands on the single pixel.
    context.draw(
        image,
        in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return Pixel(red: Int(data[0]), green: Int(data[1]), blue: Int(data[2]))
}

final class VideoRendererTests: XCTestCase {
    private let size = CGSize(width: 400, height: 225)
    private let context = CIContext()

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, size: CGSize = CGSize(width: 160, height: 90))
        -> CIImage
    {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func render(_ layers: [VideoRenderer.Layer]) -> CGImage {
        let image = VideoRenderer.compose(layers, renderSize: size)
        return context.createCGImage(image, from: CGRect(origin: .zero, size: size))!
    }

    private func layer(
        _ image: CIImage, _ placement: VideoPlacement, scale: Double = 0.25,
        _ adjustments: VideoAdjustments = .identity
    ) -> VideoRenderer.Layer {
        VideoRenderer.Layer(
            image: image, rect: Layout.rect(for: placement, cornerScale: scale, renderSize: size)!,
            adjustments: adjustments)
    }

    func testCornerPictureIsAtTheTopLeft() {
        let image = render([layer(solid(1, 0, 0), .full), layer(solid(0, 0, 1), .topLeft)])
        let corner = Layout.rect(for: .topLeft, cornerScale: 0.25, renderSize: size)!

        let inCorner = pixel(image, x: Int(corner.midX), y: Int(corner.midY))
        XCTAssertGreaterThan(inCorner.blue, 200)
        XCTAssertLessThan(inCorner.red, 50)

        let center = pixel(image, x: 200, y: 112)
        XCTAssertGreaterThan(center.red, 200)
        XCTAssertLessThan(center.blue, 50)

        // Same height at the bottom left must still be the full screen picture.
        let bottomLeft = pixel(image, x: Int(corner.midX), y: Int(size.height - corner.midY))
        XCTAssertGreaterThan(bottomLeft.red, 200)
    }

    func testSaturationZeroGivesGray() {
        var settings = VideoAdjustments()
        settings.saturation = 0
        let value = pixel(render([layer(solid(1, 0, 0), .full, settings)]), x: 200, y: 112)
        XCTAssertEqual(value.red, value.green, accuracy: 8)
        XCTAssertEqual(value.green, value.blue, accuracy: 8)
    }

    func testWarmTemperature() {
        var settings = VideoAdjustments()
        settings.temperature = 1
        let value = pixel(render([layer(solid(0.5, 0.5, 0.5), .full, settings)]), x: 200, y: 112)
        XCTAssertGreaterThan(value.red, value.blue + 10)
    }

    func testExposure() {
        var settings = VideoAdjustments()
        settings.exposure = 1
        let normal = pixel(render([layer(solid(0.3, 0.3, 0.3), .full)]), x: 200, y: 112)
        let brighter = pixel(render([layer(solid(0.3, 0.3, 0.3), .full, settings)]), x: 200, y: 112)
        XCTAssertGreaterThan(brighter.red, normal.red + 20)
    }

    func testZoomKeepsTheLeftPart() {
        // Left half red, right half blue.
        let source = solid(1, 0, 0, size: CGSize(width: 80, height: 90))
            .composited(
                over: solid(0, 0, 1)
            )
        var settings = VideoAdjustments()
        settings.zoom = 2
        settings.centerX = -1
        let image = render([layer(source, .full, settings)])
        // The whole visible picture comes from the left half.
        XCTAssertGreaterThan(pixel(image, x: 300, y: 112).red, 200)
        XCTAssertLessThan(pixel(image, x: 300, y: 112).blue, 50)
    }

    func testRoundedCornersAndBorder() {
        var settings = VideoAdjustments()
        settings.cornerRadius = 0.3
        settings.border = 0.01
        let image = render([layer(solid(1, 0, 0), .topLeft, settings)])
        let rect = Layout.rect(for: .topLeft, cornerScale: 0.25, renderSize: size)!

        // The exact corner is cut off: background shows.
        let corner = pixel(image, x: Int(rect.minX) + 1, y: Int(rect.minY) + 1)
        XCTAssertLessThan(corner.red, 100)
        // The border is white just outside the middle of the left edge.
        let border = pixel(image, x: Int(rect.minX) - 2, y: Int(rect.midY))
        XCTAssertGreaterThan(border.green, 200)
        XCTAssertGreaterThan(pixel(image, x: Int(rect.midX), y: Int(rect.midY)).red, 200)
    }

    func testCropRect() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            Layout.cropRect(sourceSize: size, zoom: 1, centerX: 0.7, centerY: 0), CGRect(origin: .zero, size: size))
        XCTAssertEqual(
            Layout.cropRect(sourceSize: size, zoom: 2, centerX: 0, centerY: 0),
            CGRect(x: 50, y: 25, width: 100, height: 50))
        XCTAssertEqual(
            Layout.cropRect(sourceSize: size, zoom: 2, centerX: 1, centerY: -1),
            CGRect(x: 100, y: 0, width: 100, height: 50))
    }
}

final class CompositorExportTests: XCTestCase {
    func testExportAppliesAdjustments() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        try await media.writeVideo("cam1.mov", width: 320, height: 180, color: (220, 30, 30))

        var project = try EditProject.load(folder: media.folder)
        project.tracks[0].adjustments.saturation = 0

        let edit = try await EditComposition.load(folder: media.folder, project: project)
        let output = media.url("export.mov")
        let options = ExportOptions(renderSize: CGSize(width: 320, height: 180), codec: .h264, fileType: .mov)
        try await Exporter.export(edit, folder: media.folder, project: project, options: options, to: output) { _ in
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        let value = pixel(frame, x: 160, y: 90)
        XCTAssertGreaterThan(value.red, 40, "frame is black")
        XCTAssertEqual(value.red, value.green, accuracy: 12)
        XCTAssertEqual(value.green, value.blue, accuracy: 12)
    }
}
