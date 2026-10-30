import CFNetwork
import Foundation

/// A request keeps its lease through response consumption. The cache may
/// replace its entry, but the old session only retires after its last user.
final class MacNetworkSessionLease: @unchecked Sendable {
    let session: URLSession
    private let owner: MacNetworkSessionEntry?

    fileprivate init(entry: MacNetworkSessionEntry) {
        session = entry.session
        owner = entry
    }

    /// Non-owning wrapper for the system shared session or a test-owned session.
    init(session: URLSession = .shared) {
        self.session = session
        owner = nil
    }
}

fileprivate final class MacNetworkSessionEntry: @unchecked Sendable {
    let session: URLSession
    init(session: URLSession) { self.session = session }
    deinit { session.finishTasksAndInvalidate() }
}

/// Rust resolves the policy; this adapter owns session caching and native
/// authentication. ARC leases keep replacement atomic with request ownership.
final class MacNetworkSessionProvider: @unchecked Sendable {
    private let preferences: NetworkProxyPreferences
    private let policyResolver: @Sendable (NetworkProxyConfiguration) -> RustCoreBridge.NetworkProxyPolicyPlan?
    private let lock = NSLock()
    private var cachedPlan: RustCoreBridge.NetworkProxyPolicyPlan?
    private var cachedEntry: MacNetworkSessionEntry?

    init(
        preferences: NetworkProxyPreferences,
        policyResolver: @escaping @Sendable (NetworkProxyConfiguration) -> RustCoreBridge.NetworkProxyPolicyPlan?
    ) {
        self.preferences = preferences
        self.policyResolver = policyResolver
    }

    func acquireSession() -> MacNetworkSessionLease {
        lock.lock()
        defer { lock.unlock() }
        let plan = policyResolver(preferences.snapshot)
        if let cachedEntry, cachedPlan == plan {
            return MacNetworkSessionLease(entry: cachedEntry)
        }
        let entry = Self.makeEntry(configuration: .default, plan: plan)
        cachedEntry = entry
        cachedPlan = plan
        return MacNetworkSessionLease(entry: entry)
    }

    /// Caller-owned timeouts, identical proxy and authentication policy. Used
    /// by rollback downloads; the lease owns this uncached session's cleanup.
    func makeSession(configuration: URLSessionConfiguration) -> MacNetworkSessionLease {
        Self.makeSession(configuration: configuration, plan: policyResolver(preferences.snapshot))
    }

    static func makeSession(configuration: URLSessionConfiguration,
                            plan: RustCoreBridge.NetworkProxyPolicyPlan?) -> MacNetworkSessionLease {
        MacNetworkSessionLease(entry: makeEntry(configuration: configuration, plan: plan))
    }

    private static func makeEntry(configuration: URLSessionConfiguration,
                                  plan: RustCoreBridge.NetworkProxyPolicyPlan?) -> MacNetworkSessionEntry {
        configuration.connectionProxyDictionary = plan.flatMap { proxyDictionary(for: $0) }
        let delegate: MacProxySessionDelegate?
        if let plan, plan.policy == .custom, plan.configured, !plan.username.isEmpty {
            delegate = MacProxySessionDelegate(
                expectedProxyHost: plan.host, expectedProxyPort: plan.port,
                username: plan.username, password: plan.password
            )
            // Custom credentials must not survive in a process-wide store.
            configuration.urlCredentialStorage = nil
        } else {
            delegate = nil
        }
        return MacNetworkSessionEntry(session: URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil
        ))
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
            space.host.caseInsensitiveCompare(bound.host) == .orderedSame && space.port == bound.port
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
            URLCredential(user: credential.username, password: credential.password, persistence: .none)
        )
    }
}
