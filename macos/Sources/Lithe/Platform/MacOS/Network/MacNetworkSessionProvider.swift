import CFNetwork
import Foundation

/// Builds the URL sessions used by the app's own HTTP traffic, applying the
/// proxy policy Rust Core normalizes from `NetworkProxyPreferences`. Sessions
/// are cached per resolved plan and rebuilt when settings change; in-flight
/// tasks of a replaced session finish instead of being cancelled.
final class MacNetworkSessionProvider: @unchecked Sendable {
    private let preferences: NetworkProxyPreferences
    /// Resolves the snapshot into the normalized policy. Production wires
    /// this to `RustCoreBridge.networkProxyPolicy`; tests inject plans.
    private let policyResolver: @Sendable (NetworkProxyConfiguration) -> RustCoreBridge.NetworkProxyPolicyPlan?
    private let lock = NSLock()
    private var cachedPlan: RustCoreBridge.NetworkProxyPolicyPlan?
    private var cachedSession: URLSession?

    init(
        preferences: NetworkProxyPreferences,
        policyResolver: @escaping @Sendable (NetworkProxyConfiguration) -> RustCoreBridge.NetworkProxyPolicyPlan?
    ) {
        self.preferences = preferences
        self.policyResolver = policyResolver
    }

    /// A session whose configuration reflects the resolved plan. Callers
    /// resolve it per request; a settings change swaps in a new session on
    /// the next call.
    func currentSession() -> URLSession {
        guard let plan = policyResolver(preferences.snapshot) else {
            // Without a plan (Core rejected the request) the only safe
            // behavior is the system default resolution.
            return .shared
        }
        lock.lock()
        defer { lock.unlock() }
        if let cachedSession, cachedPlan == plan {
            return cachedSession
        }
        cachedSession?.finishTasksAndInvalidate()
        let session = URLSession(
            configuration: Self.makeConfiguration(plan),
            delegate: Self.makeDelegate(plan),
            delegateQueue: nil
        )
        cachedSession = session
        cachedPlan = plan
        return session
    }

    /// Applies the resolved policy to a configuration the caller owns, so
    /// flows that need their own timeouts (the stable rollback downloader)
    /// share one policy implementation.
    func applyPolicy(to configuration: URLSessionConfiguration) {
        guard let plan = policyResolver(preferences.snapshot) else { return }
        if let proxyDictionary = Self.proxyDictionary(for: plan) {
            configuration.connectionProxyDictionary = proxyDictionary
        }
    }

    private static func makeConfiguration(_ plan: RustCoreBridge.NetworkProxyPolicyPlan) -> URLSessionConfiguration {
        let sessionConfiguration = URLSessionConfiguration.default
        if let proxyDictionary = proxyDictionary(for: plan) {
            sessionConfiguration.connectionProxyDictionary = proxyDictionary
        }
        return sessionConfiguration
    }

    private static func makeDelegate(_ plan: RustCoreBridge.NetworkProxyPolicyPlan) -> MacProxySessionDelegate? {
        guard plan.policy == .custom, plan.configured, !plan.username.isEmpty else {
            // System and direct modes must never answer a proxy challenge:
            // stored custom credentials belong to their own server only.
            return nil
        }
        return MacProxySessionDelegate(
            expectedProxyHost: plan.host,
            expectedProxyPort: plan.port,
            username: plan.username,
            password: plan.password
        )
    }

    /// The CFNetwork proxy dictionary for a normalized plan. `nil` leaves the
    /// system default resolution in place; an empty dictionary explicitly
    /// disables every proxy.
    static func proxyDictionary(for plan: RustCoreBridge.NetworkProxyPolicyPlan) -> [AnyHashable: Any]? {
        switch plan.policy {
        case .system:
            return nil
        case .direct:
            return [:]
        case .custom:
            guard plan.configured else { return nil }
            var dictionary: [AnyHashable: Any]
            switch plan.proxyType {
            case .http:
                // One HTTP proxy also carries HTTPS requests via CONNECT.
                dictionary = [
                    kCFNetworkProxiesHTTPEnable as AnyHashable: true,
                    kCFNetworkProxiesHTTPProxy as AnyHashable: plan.host,
                    kCFNetworkProxiesHTTPPort as AnyHashable: plan.port,
                    kCFNetworkProxiesHTTPSEnable as AnyHashable: true,
                    kCFNetworkProxiesHTTPSProxy as AnyHashable: plan.host,
                    kCFNetworkProxiesHTTPSPort as AnyHashable: plan.port,
                ]
            case .socks5:
                dictionary = [
                    kCFNetworkProxiesSOCKSEnable as AnyHashable: true,
                    kCFNetworkProxiesSOCKSProxy as AnyHashable: plan.host,
                    kCFNetworkProxiesSOCKSPort as AnyHashable: plan.port,
                ]
            }
            if !plan.username.isEmpty {
                dictionary[kCFProxyUsernameKey as AnyHashable] = plan.username
                dictionary[kCFProxyPasswordKey as AnyHashable] = plan.password
            }
            if !plan.exclusions.isEmpty {
                dictionary[kCFNetworkProxiesExceptionsList as AnyHashable] = plan.exclusions
            }
            return dictionary
        }
    }
}

/// Answers proxy authentication challenges with the credentials of one
/// specific proxy. The challenge must target that exact proxy host and port,
/// and wrong credentials must not loop: the second failure falls back to
/// default handling.
final class MacProxySessionDelegate: NSObject, URLSessionTaskDelegate {
    struct ProxyCredential: Equatable, Sendable {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    private let credential: ProxyCredential?

    init(credential: ProxyCredential?) {
        self.credential = credential
    }

    /// Convenience for a delegate bound to one custom proxy's credentials.
    convenience init(expectedProxyHost: String, expectedProxyPort: Int, username: String, password: String) {
        self.init(credential: ProxyCredential(
            host: expectedProxyHost,
            port: expectedProxyPort,
            username: username,
            password: password
        ))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let method = space.authenticationMethod
        // NSObject.isProxy() shadows URLProtectionSpace's proxy flag in Swift;
        // proxyType is non-nil only for proxy protection spaces.
        let isProxySpace = space.proxyType != nil
        // Credentials must only reach the proxy they belong to, never another
        // system proxy that happens to challenge in the same process.
        let matchesBoundProxy = credential.map { bound in
            space.host == bound.host && space.port == bound.port
        } ?? false
        let isProxyCredentialChallenge = isProxySpace
            && matchesBoundProxy
            && challenge.previousFailureCount == 0
            && (method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodNTLM)
        guard isProxyCredentialChallenge, let credential else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(user: credential.username, password: credential.password, persistence: .forSession)
        )
    }
}
