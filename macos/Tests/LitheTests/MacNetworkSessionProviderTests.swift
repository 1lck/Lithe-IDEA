import CFNetwork
import Foundation
import Testing
@testable import Lithe

/// Protects the proxy policy mapping and session lifecycle: the normalized
/// plan from Rust Core is the single source of truth, sessions are reused
/// while the plan stays put and rebuilt when it changes, and the
/// authentication delegate answers only the challenges of its own proxy
/// without looping on wrong credentials.
@Suite("Network session provider")
struct MacNetworkSessionProviderTests {
    private func plan(
        policy: RustCoreBridge.NetworkProxyPolicyPlan.PolicyKind,
        proxyType: RustCoreBridge.NetworkProxyPolicyPlan.ProxyType = .http,
        host: String = "",
        port: Int = 0,
        username: String = "",
        password: String = "",
        exclusions: [String] = [],
        configured: Bool
    ) -> RustCoreBridge.NetworkProxyPolicyPlan {
        .init(
            policy: policy,
            proxyType: proxyType,
            host: host,
            port: port,
            username: username,
            password: password,
            exclusions: exclusions,
            configured: configured
        )
    }

    private func provider(preferences: NetworkProxyPreferences, plan: RustCoreBridge.NetworkProxyPolicyPlan) -> MacNetworkSessionProvider {
        MacNetworkSessionProvider(preferences: preferences, policyResolver: { _ in plan })
    }

    @Test
    func systemPlanLeavesProxyResolutionToTheSystem() {
        let dictionary = MacNetworkSessionProvider.proxyDictionary(
            for: plan(policy: .system, configured: false)
        )
        #expect(dictionary == nil)
    }

    @Test
    func directPlanExplicitlyDisablesEveryProxy() {
        let dictionary = MacNetworkSessionProvider.proxyDictionary(
            for: plan(policy: .direct, configured: true)
        )
        #expect(dictionary?.isEmpty == true)
    }

    @Test
    func unconfiguredCustomPlanKeepsSystemResolution() {
        let dictionary = MacNetworkSessionProvider.proxyDictionary(
            for: plan(policy: .custom, host: "proxy.example", port: 3128, configured: false)
        )
        #expect(dictionary == nil)
    }

    @Test
    func httpPlanCarriesBothPlainAndTunnelledTraffic() throws {
        let dictionary = try #require(
            MacNetworkSessionProvider.proxyDictionary(
                for: plan(policy: .custom, proxyType: .http, host: "127.0.0.1", port: 7890, configured: true)
            )
        )
        #expect(dictionary[kCFNetworkProxiesHTTPEnable as AnyHashable] as? Bool == true)
        #expect(dictionary[kCFNetworkProxiesHTTPProxy as AnyHashable] as? String == "127.0.0.1")
        #expect(dictionary[kCFNetworkProxiesHTTPPort as AnyHashable] as? Int == 7890)
        #expect(dictionary[kCFNetworkProxiesHTTPSEnable as AnyHashable] as? Bool == true)
        #expect(dictionary[kCFNetworkProxiesHTTPSProxy as AnyHashable] as? String == "127.0.0.1")
        #expect(dictionary[kCFNetworkProxiesHTTPSPort as AnyHashable] as? Int == 7890)
        #expect(dictionary[kCFProxyUsernameKey as AnyHashable] == nil)
    }

    @Test
    func socksPlanUsesTheSOCKSDictionaryKeys() throws {
        let dictionary = try #require(
            MacNetworkSessionProvider.proxyDictionary(
                for: plan(policy: .custom, proxyType: .socks5, host: "proxy.example", port: 1080, configured: true)
            )
        )
        #expect(dictionary[kCFNetworkProxiesSOCKSEnable as AnyHashable] as? Bool == true)
        #expect(dictionary[kCFNetworkProxiesSOCKSProxy as AnyHashable] as? String == "proxy.example")
        #expect(dictionary[kCFNetworkProxiesSOCKSPort as AnyHashable] as? Int == 1080)
        #expect(dictionary[kCFNetworkProxiesHTTPEnable as AnyHashable] == nil)
    }

    @Test
    func credentialsAndExclusionsJoinTheDictionary() throws {
        let dictionary = try #require(
            MacNetworkSessionProvider.proxyDictionary(
                for: plan(
                    policy: .custom, proxyType: .http, host: "proxy.example", port: 3128,
                    username: "lithe", password: "secret",
                    exclusions: ["127.0.0.1", "*.internal.example"],
                    configured: true
                )
            )
        )
        #expect(dictionary[kCFProxyUsernameKey as AnyHashable] as? String == "lithe")
        #expect(dictionary[kCFProxyPasswordKey as AnyHashable] as? String == "secret")
        #expect(dictionary[kCFNetworkProxiesExceptionsList as AnyHashable] as? [String] == ["127.0.0.1", "*.internal.example"])
    }

    // A mutable plan holder the @Sendable resolver can read through: @Sendable
    // closures capture values by copy, so tests mutate through the box.
    private final class PlanBox: @unchecked Sendable {
        var value: RustCoreBridge.NetworkProxyPolicyPlan
        init(_ value: RustCoreBridge.NetworkProxyPolicyPlan) { self.value = value }
    }

    @Test
    func sessionsAreReusedUntilThePlanChanges() {
        let preferences = NetworkProxyPreferences()
        let current = PlanBox(plan(policy: .system, configured: false))
        let provider = MacNetworkSessionProvider(preferences: preferences) { _ in current.value }
        let first = provider.currentSession()
        #expect(provider.currentSession() === first)

        current.value = plan(policy: .custom, proxyType: .http, host: "proxy.example", port: 3128, configured: true)
        let second = provider.currentSession()
        #expect(second !== first)

        // An identical plan keeps the session built for it.
        #expect(provider.currentSession() === second)
    }

    @Test
    func providerSessionsCarryTheCurrentProxyPolicy() {
        let preferences = NetworkProxyPreferences()
        let current = PlanBox(plan(policy: .direct, configured: true))
        let provider = MacNetworkSessionProvider(preferences: preferences) { _ in current.value }
        #expect(provider.currentSession().configuration.connectionProxyDictionary?.isEmpty == true)

        current.value = plan(policy: .custom, proxyType: .http, host: "proxy.example", port: 3128, configured: true)
        let dictionary = provider.currentSession().configuration.connectionProxyDictionary
        #expect(dictionary?[kCFNetworkProxiesHTTPEnable as AnyHashable] as? Bool == true)

        current.value = plan(policy: .system, configured: false)
        #expect(provider.currentSession().configuration.connectionProxyDictionary == nil)
    }

    @Test
    func applyPolicySharesOneImplementationWithCallerOwnedConfigurations() {
        let preferences = NetworkProxyPreferences()
        let current = PlanBox(plan(policy: .custom, proxyType: .http, host: "proxy.example", port: 3128, configured: true))
        let provider = MacNetworkSessionProvider(preferences: preferences) { _ in current.value }

        let rollbackConfiguration = URLSessionConfiguration.ephemeral
        provider.applyPolicy(to: rollbackConfiguration)
        #expect(rollbackConfiguration.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy as AnyHashable] as? String == "proxy.example")

        current.value = plan(policy: .system, configured: false)
        let untouched = URLSessionConfiguration.ephemeral
        provider.applyPolicy(to: untouched)
        #expect(untouched.connectionProxyDictionary == nil)
    }

    // MARK: Credential scoping (review P1)

    private func proxyChallenge(host: String, port: Int, previousFailureCount: Int = 0) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            proxyHost: host, port: port, type: "http",
            realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: previousFailureCount,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
    }

    private func disposition(
        _ delegate: MacProxySessionDelegate,
        for challenge: URLAuthenticationChallenge
    ) -> URLSession.AuthChallengeDisposition {
        let inertSession = URLSession(configuration: .ephemeral)
        let task = inertSession.dataTask(with: URL(string: "https://github.com")!)
        var observed: URLSession.AuthChallengeDisposition?
        delegate.urlSession(inertSession, task: task, didReceive: challenge) { result, _ in
            observed = result
        }
        return observed ?? .performDefaultHandling
    }

    /// Regression for the review P1: stored credentials belong to one proxy.
    /// A different system proxy challenging in the same process must never
    /// receive them.
    @Test
    func credentialsOnlyReachTheirOwnProxy() {
        let delegate = MacProxySessionDelegate(
            expectedProxyHost: "proxy.example", expectedProxyPort: 3128,
            username: "lithe", password: "secret"
        )
        let own = disposition(delegate, for: proxyChallenge(host: "proxy.example", port: 3128))
        #expect(own == .useCredential)

        let otherHost = disposition(delegate, for: proxyChallenge(host: "other.example", port: 3128))
        #expect(otherHost == .performDefaultHandling)

        let otherPort = disposition(delegate, for: proxyChallenge(host: "proxy.example", port: 8080))
        #expect(otherPort == .performDefaultHandling)
    }

    @Test
    func wrongCredentialsFallBackAfterTheFirstFailure() {
        let delegate = MacProxySessionDelegate(
            expectedProxyHost: "proxy.example", expectedProxyPort: 3128,
            username: "lithe", password: "secret"
        )
        let repeated = disposition(
            delegate,
            for: proxyChallenge(host: "proxy.example", port: 3128, previousFailureCount: 1)
        )
        #expect(repeated == .performDefaultHandling)
    }

    @Test
    func serverChallengesAndCredentialFreeSessionsKeepDefaultHandling() {
        let anonymous = MacProxySessionDelegate(credential: nil)
        let serverSpace = URLProtectionSpace(
            host: "github.com", port: 443, protocol: "https",
            realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let serverChallenge = URLAuthenticationChallenge(
            protectionSpace: serverSpace, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
        let observed = disposition(anonymous, for: serverChallenge)
        #expect(observed == .performDefaultHandling)

        let authenticated = MacProxySessionDelegate(
            expectedProxyHost: "proxy.example", expectedProxyPort: 3128,
            username: "lithe", password: "secret"
        )
        #expect(disposition(authenticated, for: serverChallenge) == .performDefaultHandling)
    }

    /// Regression for the review P1 companion: the provider must not even
    /// attach a credential-answering delegate once the policy leaves custom
    /// mode, so no challenge can pull the stored credentials.
    @Test
    func nonCustomPlansBuildSessionsWithoutACredentialDelegate() {
        let preferences = NetworkProxyPreferences()
        let current = PlanBox(plan(
            policy: .custom, proxyType: .http, host: "proxy.example", port: 3128,
            username: "lithe", password: "secret", configured: true
        ))
        let provider = MacNetworkSessionProvider(preferences: preferences) { _ in current.value }
        _ = provider.currentSession()

        current.value = plan(policy: .system, configured: false)
        let systemSession = provider.currentSession()
        #expect(systemSession.configuration.connectionProxyDictionary == nil)
    }
}

/// Inert challenge sender: the delegate under test never calls back into it.
private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
