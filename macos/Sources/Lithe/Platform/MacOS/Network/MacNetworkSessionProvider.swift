import CFNetwork
import Foundation

/// Builds the URL sessions used by the app's own HTTP traffic, applying the
/// user's proxy policy from `NetworkProxyPreferences`. Sessions are cached per
/// configuration and rebuilt when settings change; in-flight tasks of a
/// replaced session finish instead of being cancelled mid-transfer.
final class MacNetworkSessionProvider: @unchecked Sendable {
    private let preferences: NetworkProxyPreferences
    private let lock = NSLock()
    private var cachedConfiguration: NetworkProxyConfiguration?
    private var cachedSession: URLSession?

    init(preferences: NetworkProxyPreferences) {
        self.preferences = preferences
    }

    /// A session whose configuration reflects the current snapshot. Callers
    /// resolve it per request; a settings change swaps in a new session on
    /// the next call.
    func currentSession() -> URLSession {
        let configuration = preferences.snapshot
        lock.lock()
        defer { lock.unlock() }
        if let cachedSession, cachedConfiguration == configuration {
            return cachedSession
        }
        cachedSession?.finishTasksAndInvalidate()
        let delegate = MacProxySessionDelegate(
            username: configuration.username,
            password: configuration.password
        )
        let session = URLSession(
            configuration: Self.makeConfiguration(configuration),
            delegate: delegate,
            delegateQueue: nil
        )
        cachedSession = session
        cachedConfiguration = configuration
        return session
    }

    /// Applies the proxy policy to a configuration the caller owns, so flows
    /// that need their own timeouts (the stable rollback downloader) share
    /// one policy implementation.
    func applyPolicy(to configuration: URLSessionConfiguration) {
        let snapshot = preferences.snapshot
        if let proxyDictionary = Self.proxyDictionary(for: snapshot) {
            configuration.connectionProxyDictionary = proxyDictionary
        }
    }

    private static func makeConfiguration(_ configuration: NetworkProxyConfiguration) -> URLSessionConfiguration {
        let sessionConfiguration = URLSessionConfiguration.default
        if let proxyDictionary = proxyDictionary(for: configuration) {
            sessionConfiguration.connectionProxyDictionary = proxyDictionary
        }
        return sessionConfiguration
    }

    /// The CFNetwork proxy dictionary for a snapshot. `nil` leaves the system
    /// default resolution in place; an empty dictionary explicitly disables
    /// every proxy.
    static func proxyDictionary(for configuration: NetworkProxyConfiguration) -> [AnyHashable: Any]? {
        switch configuration.mode {
        case .system:
            return nil
        case .direct:
            return [:]
        case .custom:
            guard configuration.isCustomConfigured else { return nil }
            let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
            var dictionary: [AnyHashable: Any]
            switch configuration.type {
            case .http:
                // One HTTP proxy also carries HTTPS requests via CONNECT.
                dictionary = [
                    kCFNetworkProxiesHTTPEnable as AnyHashable: true,
                    kCFNetworkProxiesHTTPProxy as AnyHashable: host,
                    kCFNetworkProxiesHTTPPort as AnyHashable: configuration.port,
                    kCFNetworkProxiesHTTPSEnable as AnyHashable: true,
                    kCFNetworkProxiesHTTPSProxy as AnyHashable: host,
                    kCFNetworkProxiesHTTPSPort as AnyHashable: configuration.port,
                ]
            case .socks5:
                dictionary = [
                    kCFNetworkProxiesSOCKSEnable as AnyHashable: true,
                    kCFNetworkProxiesSOCKSProxy as AnyHashable: host,
                    kCFNetworkProxiesSOCKSPort as AnyHashable: configuration.port,
                ]
            }
            if !configuration.username.isEmpty {
                dictionary[kCFProxyUsernameKey as AnyHashable] = configuration.username
                dictionary[kCFProxyPasswordKey as AnyHashable] = configuration.password
            }
            if !configuration.exclusions.isEmpty {
                dictionary[kCFNetworkProxiesExceptionsList as AnyHashable] = configuration.exclusions
            }
            return dictionary
        }
    }
}

/// Answers proxy authentication challenges with the credentials captured when
/// the session was built. Wrong credentials must not loop: the second failure
/// falls back to default handling.
final class MacProxySessionDelegate: NSObject, URLSessionTaskDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        // NSObject.isProxy() shadows URLProtectionSpace's proxy flag in Swift;
        // proxyType is non-nil only for proxy protection spaces.
        let isProxySpace = challenge.protectionSpace.proxyType != nil
        let isProxyCredentialChallenge = isProxySpace
            && !username.isEmpty
            && challenge.previousFailureCount == 0
            && (method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodNTLM)
        guard isProxyCredentialChallenge else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(user: username, password: password, persistence: .forSession)
        )
    }
}
