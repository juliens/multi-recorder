import CoreMedia
import Foundation

/// A phone running the MultiRecorder Phone app, found on the local network.
public struct PhoneEndpoint: Identifiable, Hashable, Sendable {
    /// Bonjour service name, stable for one phone.
    public let id: String
    public let host: String
    public let port: Int

    public init(id: String, host: String, port: Int) {
        self.id = id
        self.host = host
        self.port = port
    }

    /// Name shown in the app, without the "MultiRecorder " prefix of the service.
    public var name: String {
        id.hasPrefix("MultiRecorder ") ? String(id.dropFirst("MultiRecorder ".count)) : id
    }

    var baseURL: URL {
        let address = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(address):\(port)")!
    }
}

/// The clip a phone recorded. Times are on the phone clock, in seconds.
public struct PhoneClip: Sendable {
    public let id: String
    public let startSeconds: Double
    public let size: Int64
}

/// Talks to the phone app over HTTP. See `PhoneServer.kt` for the other side.
public struct PhoneClient: Sendable {
    public let endpoint: PhoneEndpoint

    public init(endpoint: PhoneEndpoint) {
        self.endpoint = endpoint
    }

    public struct Info: Decodable, Sendable {
        public let name: String
        public let recording: Bool
        public let preview: Bool?
    }

    public func info() async throws -> Info {
        try await request("GET", "/info", timeout: 3)
    }

    /// Offset of the phone clock against the host clock (`phone - host`), in seconds.
    /// Takes the exchange with the shortest round trip, as NTP does.
    public func clockOffset(samples: Int = 8) async throws -> (offset: Double, roundTrip: Double) {
        struct Time: Decodable { let t: Int64 }
        var best: (offset: Double, roundTrip: Double)?
        for _ in 0..<samples {
            let sent = Self.hostSeconds()
            let time: Time = try await request("GET", "/time", timeout: 2)
            let received = Self.hostSeconds()
            let roundTrip = received - sent
            let offset = Double(time.t) / 1e9 - (sent + received) / 2
            if best == nil || roundTrip < best!.roundTrip {
                best = (offset, roundTrip)
            }
        }
        return best!
    }

    public func startRecording(quality: String) async throws -> PhoneClip {
        try await clip(request("POST", "/start", body: ["quality": quality], timeout: 15))
    }

    public func stopRecording() async throws -> PhoneClip {
        try await clip(request("POST", "/stop", timeout: 40))
    }

    /// Small JPEG of what the phone camera sees.
    public func preview() async throws -> Data {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("preview.jpg"), timeoutInterval: 2)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return data
    }

    /// Downloads a clip to `destination`. `progress` gets 0...1.
    public func download(
        clipID: String, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let url = endpoint.baseURL.appendingPathComponent("clips").appendingPathComponent(clipID)
        let delegate = DownloadProgress(report: progress)
        let (temporary, response) = try await URLSession.shared.download(
            for: URLRequest(url: url, timeoutInterval: 60), delegate: delegate)
        try Self.check(response, Data())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
    }

    // MARK: Helpers

    private struct ClipReply: Decodable {
        let id: String
        let startNanos: Int64
        let size: Int64
    }

    private func clip(_ reply: ClipReply) -> PhoneClip {
        PhoneClip(id: reply.id, startSeconds: Double(reply.startNanos) / 1e9, size: reply.size)
    }

    private func request<T: Decodable>(
        _ method: String, _ path: String, body: [String: String]? = nil, timeout: TimeInterval
    ) async throws -> T {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw EngineError.writer("Phone: \(message)")
        }
    }

    /// Host clock in seconds, the clock of the capture session.
    public static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
}

/// Video quality asked from the phones.
public enum PhoneQuality: String, CaseIterable, Identifiable, Sendable {
    case uhd
    case fhd
    case hd

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .uhd: "4K (2160p)"
        case .fhd: "1080p"
        case .hd: "720p"
        }
    }
}

/// Camera settings of a phone, and what it supports. See `CameraRecorder.state()`.
public struct PhoneCameraState: Codable, Equatable, Sendable {
    public var front: Bool
    public var hasFront: Bool
    public var orientation: PhoneOrientation
    public var fps: Int
    public var frameRates: [Int]
    public var stabilization: Bool
    public var hasStabilization: Bool
    public var quality: String
    public var zoom: Double
    public var minZoom: Double
    public var maxZoom: Double
    public var exposure: Int
    public var minExposure: Int
    public var maxExposure: Int
    public var exposureStep: Double
    public var whiteBalance: PhoneWhiteBalance
    public var exposureLock: Bool
    public var whiteBalanceLock: Bool
    public var torch: Bool
    public var hasTorch: Bool
    public var focusSet: Bool
    public var recording: Bool
}

public enum PhoneOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape
    case portrait
    case landscapeFlipped
    case portraitFlipped

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .landscapeFlipped: "Landscape, upside down"
        case .portraitFlipped: "Portrait, upside down"
        }
    }
}

public enum PhoneWhiteBalance: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case daylight
    case cloudy
    case shade
    case incandescent
    case fluorescent

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .daylight: "Daylight"
        case .cloudy: "Cloudy"
        case .shade: "Shade"
        case .incandescent: "Tungsten"
        case .fluorescent: "Fluorescent"
        }
    }
}

extension PhoneClient {
    public func cameraState() async throws -> PhoneCameraState {
        try await send("GET", "/camera", body: nil, timeout: 3)
    }

    /// Changes only the given fields, for example `["zoom": 2.0]`.
    public func updateCamera(_ changes: [String: any Sendable]) async throws -> PhoneCameraState {
        try await send("POST", "/camera", body: changes, timeout: 10)
    }

    /// Focus and exposure on a point of the preview picture (0...1, origin at the top left).
    /// Nil goes back to automatic focus.
    public func focus(at point: CGPoint?) async throws -> PhoneCameraState {
        let body: [String: any Sendable] = point.map { ["x": Double($0.x), "y": Double($0.y)] } ?? [:]
        return try await send("POST", "/focus", body: body, timeout: 5)
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, body: [String: any Sendable]?, timeout: TimeInterval
    ) async throws -> T {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(PhoneFailure.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw EngineError.writer(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct PhoneFailure: Decodable {
    let error: String
}
