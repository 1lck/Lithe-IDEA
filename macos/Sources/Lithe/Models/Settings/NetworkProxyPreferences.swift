import Foundation

/// How the application's own HTTP traffic reaches the internet. The mode is
/// the only setting that applies unconditionally; the remaining fields only
/// matter for `.custom`.
enum NetworkProxyMode: String, CaseIterable, Identifiable {
    /// Resolve proxies the way macOS system settings configure them.
    case system
    /// Contact every host directly, ignoring configured system proxies.
    case direct
    /// Tunnel requests through the user-configured proxy server.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Follow system proxy"
        case .direct: "No proxy"
        case .custom: "Custom proxy server"
        }
    }
}

/// The protocol a custom proxy server speaks. An HTTP proxy also carries
/// HTTPS requests through CONNECT; SOCKS5 tunnels every protocol and port.
enum NetworkProxyType: String, CaseIterable, Identifiable {
    case http
    case socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        }
    }
}

/// An immutable snapshot of the proxy settings the network layer reads.
/// The password never passes through the settings store; the composition
/// root loads it from the Keychain and pushes it into the snapshot separately.
struct NetworkProxyConfiguration: Equatable, Sendable {
    var mode: NetworkProxyMode = .system
    var type: NetworkProxyType = .http
    var host: String = ""
    var port: Int = 0
    var username: String = ""
    var password: String = ""
    /// Hosts that bypass the custom proxy, already split and trimmed.
    var exclusions: [String] = []

    /// A custom proxy without a host and port keeps the system behavior
    /// instead of silently breaking every request.
    var isCustomConfigured: Bool {
        mode == .custom
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port > 0
    }
}

/// Thread-safe holder for the live proxy configuration. Settings writes and
/// network reads happen on different actors: `AppSettings` pushes updates and
/// `MacNetworkSessionProvider` reads snapshots when building sessions.
final class NetworkProxyPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = NetworkProxyConfiguration()

    var snapshot: NetworkProxyConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    func update(_ configuration: NetworkProxyConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        self.configuration = configuration
    }
}
