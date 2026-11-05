import AVFoundation

public struct VideoFormatInfo: Identifiable, Hashable, Sendable {
    /// Index in `AVCaptureDevice.formats`.
    public let id: Int
    public let width: Int
    public let height: Int
    public let maxFrameRate: Double

    public var label: String {
        "\(width)×\(height) @ \(Int(maxFrameRate.rounded())) fps"
    }

    var key: String { "\(width)x\(height)@\(Int(maxFrameRate.rounded()))" }
}

public struct CameraInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let formats: [VideoFormatInfo]
    public let activeFormatID: Int?
}

public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let channelCount: Int
    public let sampleRate: Double
}

public enum DeviceCatalog {
    public static func cameras() -> [CameraInfo] {
        videoDevices().map(cameraInfo)
    }

    public static func audioDevices() -> [AudioDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { device in
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
            return AudioDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                channelCount: Int(asbd?.mChannelsPerFrame ?? 0),
                sampleRate: asbd?.mSampleRate ?? 0
            )
        }
    }

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func cameraInfo(_ device: AVCaptureDevice) -> CameraInfo {
        var seen = Set<String>()
        var formats: [VideoFormatInfo] = []
        for (index, format) in device.formats.enumerated() {
            let info = formatInfo(format, id: index)
            if seen.insert(info.key).inserted {
                formats.append(info)
            }
        }
        formats.sort {
            ($0.width * $0.height, $0.maxFrameRate) > ($1.width * $1.height, $1.maxFrameRate)
        }

        var activeID: Int?
        if let activeIndex = device.formats.firstIndex(of: device.activeFormat) {
            let key = formatInfo(device.activeFormat, id: activeIndex).key
            activeID = formats.first { $0.key == key }?.id
        }

        return CameraInfo(id: device.uniqueID, name: device.localizedName, formats: formats, activeFormatID: activeID)
    }

    private static func formatInfo(_ format: AVCaptureDevice.Format, id: Int) -> VideoFormatInfo {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return VideoFormatInfo(id: id, width: Int(dims.width), height: Int(dims.height), maxFrameRate: fps)
    }
}
