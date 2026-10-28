import Foundation
import Testing
@testable import Lithe

/// Protects the proxy policy mapping and session lifecycle: every mode must
/// produce the documented CFNetwork dictionary (or none), sessions must be
/// reused while the configuration stays put and rebuilt when it changes, and
/// the authentication delegate must answer proxy challenges without looping.
@Suite("Network session provider")
struct MacNetworkSessionProviderTests {
    private func configuration(
        mode: NetworkProxyMode,
        type: NetworkProxyType = .http,
        host: String = "",
        port: Int = 0,
        username: String = "",
        password: String = "",
        exclusions: [String] = []
    ) -> NetworkProxyConfiguration {
        var configuration = NetworkProxyConfiguration()
        configuration.mode = mode
        configuration.type = type
        configuration.host = host
        configuration.port = port
        configuration.username = username
        configuration.password = password
        configuration.exclusions = exclusions
        return configuration
    }

    @Test
    func systemModeLeavesProxyResolutionToTheSystem() {
        let system = MacNetworkSessionProvider.proxyDictionary(for: configuration(mode: .system))
        #expect(system == nil)
        let unfinishedCustom = MacNetworkSessionProvider.proxyDictionary(for: configuration(mode: .custom))
        #expect(unfinishedCustom == nil)
    }

    @Test
    func directModeExplicitlyDisablesEveryProxy() {
        let dictionary = MacNetworkSessionProvider.proxyDictionary(for: configuration(mode: .direct))
        #expect(dictionary?.isEmpty == true)
    }

    @Test
    func httpModeCarriesBothPlainAndTunnelledTraffic() throws {
        let dictionary = try #require(
            MacNetworkSessionProvider.proxyDictionary(
                for: configuration(mode: .custom, type: .http, host: "127.0.0.1", port: 7890)
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
    func socksModeUsesTheSOCKSDictionaryKeys() throws {
        let dictionary = try #require(
            MacNetworkSessionProvider.proxyDictionary(
                for: configuration(mode: .custom, type: .socks5, host: "proxy.example", port: 1080)
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
                for: configuration(
                    mode: .custom, type: .http, host: "proxy.example", port: 3128,
                    username: "lithe", password: "secret",
                    exclusions: ["127.0.0.1", "*.internal.example"]
                )
            )
        )
        #expect(dictionary[kCFProxyUsernameKey as AnyHashable] as? String == "lithe")
        #expect(dictionary[kCFProxyPasswordKey as AnyHashable] as? String == "secret")
        #expect(dictionary[kCFNetworkProxiesExceptionsList as AnyHashable] as? [String] == ["127.0.0.1", "*.internal.example"])
    }

    @Test
    func anUnconfiguredCustomHostFallsBackToSystemResolution() {
        let emptyHost = MacNetworkSessionProvider.proxyDictionary(
            for: configuration(mode: .custom, host: "  ", port: 7890)
        )
        #expect(emptyHost == nil)
        let missingPort = MacNetworkSessionProvider.proxyDictionary(
            for: configuration(mode: .custom, host: "proxy.example", port: 0)
        )
        #expect(missingPort == nil)
    }

    @Test
    func sessionsAreReusedUntilTheConfigurationChanges() {
        let preferences = NetworkProxyPreferences()
        let provider = MacNetworkSessionProvider(preferences: preferences)
        preferences.update(configuration(mode: .direct))
        let first = provider.currentSession()
        #expect(provider.currentSession() === first)

        preferences.update(configuration(mode: .custom, type: .http, host: "proxy.example", port: 3128))
        let second = provider.currentSession()
        #expect(second !== first)

        // An identical configuration keeps the session built for it.
        #expect(provider.currentSession() === second)
    }

    @Test
    func providerSessionsCarryTheCurrentProxyPolicy() {
        let preferences = NetworkProxyPreferences()
        let provider = MacNetworkSessionProvider(preferences: preferences)
        preferences.update(configuration(mode: .direct))
        #expect(provider.currentSession().configuration.connectionProxyDictionary?.isEmpty == true)

        preferences.update(configuration(mode: .custom, type: .http, host: "proxy.example", port: 3128))
        let dictionary = provider.currentSession().configuration.connectionProxyDictionary
        #expect(dictionary?[kCFNetworkProxiesHTTPEnable as AnyHashable] as? Bool == true)

        preferences.update(configuration(mode: .system))
        #expect(provider.currentSession().configuration.connectionProxyDictionary == nil)
    }

    @Test
    func applyPolicySharesOneImplementationWithCallerOwnedConfigurations() {
        let preferences = NetworkProxyPreferences()
        let provider = MacNetworkSessionProvider(preferences: preferences)
        preferences.update(configuration(mode: .custom, type: .http, host: "proxy.example", port: 3128))

        let rollbackConfiguration = URLSessionConfiguration.ephemeral
        provider.applyPolicy(to: rollbackConfiguration)
        #expect(rollbackConfiguration.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy as AnyHashable] as? String == "proxy.example")

        preferences.update(configuration(mode: .system))
        let untouched = URLSessionConfiguration.ephemeral
        provider.applyPolicy(to: untouched)
        #expect(untouched.connectionProxyDictionary == nil)
    }

    @Test
    func proxyChallengesUseTheCapturedCredentialsWithoutLooping() {
        let delegate = MacProxySessionDelegate(username: "lithe", password: "secret")
        let space = URLProtectionSpace(
            proxyHost: "proxy.example", port: 3128, type: "http",
            realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
        let inertSession = URLSession(configuration: .ephemeral)
        let task = inertSession.dataTask(with: URL(string: "https://github.com")!)
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
        delegate.urlSession(inertSession, task: task, didReceive: challenge) {
            disposition = $0
            credential = $1
        }
        #expect(disposition == .useCredential)
        #expect(credential?.user == "lithe")
        #expect(credential?.password == "secret")

        // A second failure must not retry the same credentials forever.
        let repeated = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 1,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
        var repeatDisposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(inertSession, task: task, didReceive: repeated) { result, _ in
            repeatDisposition = result
        }
        #expect(repeatDisposition == .performDefaultHandling)
    }

    @Test
    func serverChallengesAndCredentialFreeSessionsKeepDefaultHandling() {
        let anonymous = MacProxySessionDelegate(username: "", password: "")
        let serverSpace = URLProtectionSpace(
            host: "github.com", port: 443, protocol: "https",
            realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let serverChallenge = URLAuthenticationChallenge(
            protectionSpace: serverSpace, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
        var disposition: URLSession.AuthChallengeDisposition?
        anonymous.urlSession(
            URLSession(configuration: .ephemeral),
            task: URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://github.com")!),
            didReceive: serverChallenge
        ) { result, _ in
            disposition = result
        }
        #expect(disposition == .performDefaultHandling)

        let authenticated = MacProxySessionDelegate(username: "lithe", password: "secret")
        disposition = nil
        authenticated.urlSession(
            URLSession(configuration: .ephemeral),
            task: URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://github.com")!),
            didReceive: serverChallenge
        ) { result, _ in
            disposition = result
        }
        #expect(disposition == .performDefaultHandling)
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
