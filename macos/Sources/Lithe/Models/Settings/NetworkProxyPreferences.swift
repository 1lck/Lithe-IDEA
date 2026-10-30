import Foundation
import LitheModuleAPI

/// How the application's own HTTP traffic reaches the internet. The mode is
/// the only setting that applies unconditionally; the remaining fields only
/// matter for `.custom`.
enum NetworkProxyMode: String, CaseIterable, Identifiable, Codable, Sendable {
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
enum NetworkProxyType: String, CaseIterable, Identifiable, Codable, Sendable {
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
/// Values are carried as entered: normalization and validation live in Rust
/// Core (`network.proxyPolicy`). The password never passes through the
/// settings store; the composition root loads it from the Keychain and pushes
/// it into the snapshot separately.
struct NetworkProxyConfiguration: Equatable, Sendable {
    var mode: NetworkProxyMode = .system
    var type: NetworkProxyType = .http
    var host: String = ""
    var port: Int = 0
    var username: String = ""
    var password: String = ""
    /// Present for restored credentials; explicit password drafts are unbound.
    var passwordIdentity: NetworkProxyIdentity? = nil
    /// Hosts that should bypass a custom proxy, one entry per element; the
    /// settings page edits them as one comma-separated string.
    var exclusions: [String] = []
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

/// Stored alongside the password in Keychain, never reconstructed from mutable
/// preferences on relaunch. Rust owns normalization and identity matching.
struct NetworkProxyIdentity: Codable, Equatable, Sendable {
    let proxyType: NetworkProxyType
    let host: String
    let port: Int
    let username: String

    init(configuration: NetworkProxyConfiguration) {
        proxyType = configuration.type
        host = configuration.host
        port = configuration.port
        username = configuration.username
    }
}

struct NetworkProxyCredential: Codable, Equatable, Sendable {
    let identity: NetworkProxyIdentity
    let password: String

    static func load(from store: any SecureStore, key: String) -> Self? {
        guard let stored = store.read(key: key) else { return nil }
        // Unscoped legacy values cannot safely be rebound to today's endpoint.
        return try? JSONDecoder().decode(Self.self, from: Data(stored.utf8))
    }

    func save(to store: any SecureStore, key: String) throws {
        let data = try JSONEncoder().encode(self)
        try store.write(String(decoding: data, as: UTF8.self), key: key)
    }
}
