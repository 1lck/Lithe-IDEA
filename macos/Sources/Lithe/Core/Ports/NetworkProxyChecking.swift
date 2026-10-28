import Foundation

/// Result of a user-initiated connectivity check through a candidate proxy.
struct NetworkProxyCheckOutcome: Equatable, Sendable {
    let succeeded: Bool
    let elapsedMilliseconds: Int
    /// The failure reason, already fit to show in the settings page; `nil`
    /// when the check succeeded.
    let detail: String?
}

/// Checks whether a draft proxy configuration can reach the network, so the
/// settings page can validate a server before saving it.
protocol NetworkProxyChecking: Sendable {
    /// Performs one bounded request through the given proxy settings. The
    /// check never throws; failures come back as outcomes.
    func check(
        type: NetworkProxyType,
        host: String,
        port: Int,
        username: String,
        password: String
    ) async -> NetworkProxyCheckOutcome
}
