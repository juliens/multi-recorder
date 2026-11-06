import Foundation
import Network

/// Finds phones running the MultiRecorder Phone app with Bonjour.
public final class PhoneBrowser: @unchecked Sendable {
    public static let serviceType = "_mrecphone._tcp"

    /// Called on the main queue with the current list, sorted by name.
    public var onChange: (([PhoneEndpoint]) -> Void)?
    /// Called on the main queue with a problem to show, or nil when browsing works.
    public var onProblem: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "phone.browser")
    private var browser: NWBrowser?
    private var resolved: [String: PhoneEndpoint] = [:]
    private var resolving: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
            for connection in self.resolving.values { connection.cancel() }
            self.resolving = [:]
        }
    }

    private func startOnQueue() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .waiting(error), let .failed(error):
                self?.report(Self.describe(error))
            case .ready:
                self?.report(nil)
            default:
                break
            }
            if case .failed = state {
                // Retry later, for example after the local network permission was given.
                self?.queue.asyncAfter(deadline: .now() + 3) {
                    self?.browser?.cancel()
                    self?.browser = nil
                    self?.startOnQueue()
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var names = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            names.insert(name)
            if resolved[name] == nil, resolving[name] == nil {
                resolve(name: name, endpoint: result.endpoint)
            }
        }
        for name in resolved.keys where !names.contains(name) {
            resolved[name] = nil
        }
        for (name, connection) in resolving where !names.contains(name) {
            connection.cancel()
            resolving[name] = nil
        }
        publish()
    }

    /// Opens a connection to learn the address and port, then closes it.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                    let address = Self.describe(host)
                    self.resolved[name] = PhoneEndpoint(id: name, host: address, port: Int(port.rawValue))
                    self.publish()
                }
                connection.cancel()
                self.resolving[name] = nil
            case .failed, .cancelled:
                self.resolving[name] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address): "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case let .ipv6(address): "\(address)"
        case let .name(name, _): name
        @unknown default: "\(host)"
        }
    }

    private func report(_ problem: String?) {
        DispatchQueue.main.async { self.onProblem?(problem) }
    }

    private static func describe(_ error: NWError) -> String {
        // kDNSServiceErr_PolicyDenied: the user did not allow local network access.
        if case let .dns(code) = error, code == -65570 {
            return "Local network access is off. Allow MultiRecorder in System Settings > "
                + "Privacy & Security > Local Network, then restart the app."
        }
        return "Cannot look for phones: \(error.localizedDescription)"
    }

    private func publish() {
        let list = resolved.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.onChange?(list) }
    }
}
