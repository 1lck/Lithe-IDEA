import Foundation

extension RustCoreBridge {
    /// The normalized proxy policy Rust Core computed from the stored
    /// settings. `policy == .custom` is the only kind that carries
    /// credentials; system and direct leave them empty by contract.
    struct NetworkProxyPolicyPlan: Decodable, Equatable, Sendable {
        enum PolicyKind: String, Decodable, Sendable {
            case system
            case direct
            case custom
        }

        enum ProxyType: String, Decodable, Sendable {
            case http
            case socks5
        }

        let policy: PolicyKind
        let proxyType: ProxyType
        let host: String
        let port: Int
        let username: String
        let password: String
        let exclusions: [String]
        let configured: Bool
    }

    private struct NetworkProxyPolicyRequest: Encodable {
        let mode: String
        let proxyType: String
        let host: String
        let port: Int
        let username: String
        let password: String
        let passwordIdentity: NetworkProxyIdentity?
        let exclusions: [String]
    }

    /// Resolves the stored proxy settings into the normalized policy via
    /// `network.proxyPolicy`. Returns `nil` when Core rejects the request;
    /// callers must then keep the system behavior instead of guessing.
    func networkProxyPolicy(from configuration: NetworkProxyConfiguration) -> NetworkProxyPolicyPlan? {
        let call: Result<NetworkProxyPolicyPlan, CoreCallError> = executeResult(
            command: "network.proxyPolicy",
            payload: NetworkProxyPolicyRequest(
                mode: configuration.mode.rawValue,
                proxyType: configuration.type.rawValue,
                host: configuration.host,
                port: configuration.port,
                username: configuration.username,
                password: configuration.password,
                passwordIdentity: configuration.passwordIdentity,
                exclusions: configuration.exclusions
            )
        )
        guard case .success(let plan) = call else { return nil }
        return plan
    }
}
