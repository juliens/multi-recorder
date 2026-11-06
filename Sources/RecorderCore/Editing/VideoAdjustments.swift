import CoreGraphics
import Foundation

/// A ready-made Core Image look.
public enum VideoLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case mono
    case noir
    case tonal
    case fade
    case chrome
    case instant
    case process
    case transfer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .mono: "Black & white"
        case .noir: "Noir"
        case .tonal: "Tonal"
        case .fade: "Fade"
        case .chrome: "Chrome"
        case .instant: "Instant"
        case .process: "Process"
        case .transfer: "Transfer"
        }
    }

    var filterName: String? {
        switch self {
        case .none: nil
        case .mono: "CIPhotoEffectMono"
        case .noir: "CIPhotoEffectNoir"
        case .tonal: "CIPhotoEffectTonal"
        case .fade: "CIPhotoEffectFade"
        case .chrome: "CIPhotoEffectChrome"
        case .instant: "CIPhotoEffectInstant"
        case .process: "CIPhotoEffectProcess"
        case .transfer: "CIPhotoEffectTransfer"
        }
    }
}

/// Picture settings of a video track, rendered with Core Image.
public struct VideoAdjustments: Codable, Hashable, Sendable {
    /// Exposure in EV, -2...2.
    public var exposure: Double = 0
    /// 0.5...1.5, 1 is unchanged.
    public var contrast: Double = 1
    /// 0...2, 1 is unchanged, 0 is gray.
    public var saturation: Double = 1
    /// -1 (cooler) ... 1 (warmer).
    public var temperature: Double = 0
    public var look: VideoLook = .none

    /// 1...4. Keeps the center part of the picture.
    public var zoom: Double = 1
    /// -1...1. Moves the kept part when zoomed in. -1 is left / top.
    public var centerX: Double = 0
    public var centerY: Double = 0

    /// Corner radius, relative to the short side of the drawn picture (0...0.5).
    public var cornerRadius: Double = 0
    /// Border width, relative to the output width (0...0.03).
    public var border: Double = 0

    public init() {}

    public static let identity = VideoAdjustments()

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, look, zoom, centerX, centerY, cornerRadius, border
    }

    /// Every field is optional, so new settings do not break older `edit.json` files.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        look = try container.decodeIfPresent(VideoLook.self, forKey: .look) ?? .none
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        centerX = try container.decodeIfPresent(Double.self, forKey: .centerX) ?? 0
        centerY = try container.decodeIfPresent(Double.self, forKey: .centerY) ?? 0
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        border = try container.decodeIfPresent(Double.self, forKey: .border) ?? 0
    }
}
