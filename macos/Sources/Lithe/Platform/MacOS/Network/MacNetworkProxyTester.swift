import CFNetwork
import Foundation
import LitheModuleAPI

/// Performs the settings page's connectivity check through a candidate proxy.
/// The check targets the same domains the marketplace and update metadata
/// use, so a success means plugin installs work through this proxy.
struct MacNetworkProxyTester: NetworkProxyChecking {
    private static let targetURL = URL(string: "https://github.com")!
    private static let timeout: TimeInterval = 10
    /// Resolves the drafted candidate into the normalized policy, exactly as
    /// the live session factory would.
    private let policyResolver: @Sendable (NetworkProxyConfiguration) -> RustCoreBridge.NetworkProxyPolicyPlan?

    private let sessionFactory: @Sendable (URLSessionConfiguration, RustCoreBridge.NetworkProxyPolicyPlan) -> MacNetworkSessionLease

    init(
        sessionFactory: @escaping @Sendable (URLSessionConfiguration, RustCoreBridge.NetworkProxyPolicyPlan) -> MacNetworkSessionLease = {
            MacNetworkSessionProvider.makeSession(configuration: $0, plan: $1)
        },
        policyResolver: @escaping @Sendable (NetworkProxyConfiguration) -> RustCoreBridge.NetworkProxyPolicyPlan?
    ) {
        self.sessionFactory = sessionFactory
        self.policyResolver = policyResolver
    }

    static func checkConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    func check(configuration: NetworkProxyConfiguration) async -> NetworkProxyCheckOutcome {
        // Validated before Core sees the request: an incomplete candidate is
        // a user-input problem, not a policy that silently bypasses the proxy.
        guard (1...65_535).contains(configuration.port), !configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NetworkProxyCheckOutcome(
                succeeded: false, elapsedMilliseconds: 0,
                detail: L10n.string("Enter a server address and a port between 1 and 65535 first.")
            )
        }
        guard let plan = policyResolver(configuration), plan.policy == .custom else {
            return NetworkProxyCheckOutcome(
                succeeded: false, elapsedMilliseconds: 0,
                detail: L10n.string("Enter a server address and a port between 1 and 65535 first.")
            )
        }
        let lease = sessionFactory(Self.checkConfiguration(), plan)
        let session = lease.session
        defer {
            session.invalidateAndCancel()
            withExtendedLifetime(lease) {}
        }

        var request = URLRequest(url: Self.targetURL)
        request.httpMethod = "HEAD"
        let startedAt = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            // Redirects still prove the proxy carries traffic.
            let succeeded = (200..<400).contains((response as? HTTPURLResponse)?.statusCode ?? -1)
            return NetworkProxyCheckOutcome(
                succeeded: succeeded,
                elapsedMilliseconds: elapsedMilliseconds,
                detail: succeeded
                    ? nil
                    : L10n.string("The proxy answered with HTTP \(String((response as? HTTPURLResponse)?.statusCode ?? -1)).")
            )
        } catch {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let reason = (error as? URLError).map { $0.localizedDescription } ?? error.localizedDescription
            return NetworkProxyCheckOutcome(
                succeeded: false, elapsedMilliseconds: elapsedMilliseconds, detail: reason
            )
        }
    }
}
