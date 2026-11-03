import Foundation
import LitheModuleAPI
import Testing
@testable import Lithe

/// Protects the network proxy settings: persistence across relaunch must
/// restore the snapshot the network layer reads (not just the published
/// fields), the effective password resolution, and the Keychain boundary.
@Suite("Network proxy settings")
@MainActor
struct NetworkProxySettingsTests {
    private func configuredSettings(store: KeyValueStore) -> AppSettings {
        let settings = AppSettings(store: store)
        settings.networkProxyMode = .custom
        settings.networkProxyType = .socks5
        settings.networkProxyHost = "127.0.0.1"
        settings.networkProxyPort = 7890
        settings.networkProxyUsername = "lithe"
        settings.networkProxyExclusions = ["127.0.0.1", "localhost"]
        return settings
    }

    /// Regression for the review P1: initialization assignments do not fire
    /// didSet, so a reload must sync the snapshot explicitly or the network
    /// layer keeps the system policy while the UI shows the saved one.
    @Test
    func relaunchRestoresTheSnapshotTheNetworkLayerReads() {
        let store = NetworkProxyTestStore()
        let saved = configuredSettings(store: store)
        #expect(saved.networkProxyPreferences.snapshot.mode == .custom)

        let reloaded = AppSettings(store: store)
        let snapshot = reloaded.networkProxyPreferences.snapshot
        #expect(snapshot.mode == .custom)
        #expect(snapshot.type == .socks5)
        #expect(snapshot.host == "127.0.0.1")
        #expect(snapshot.port == 7890)
        #expect(snapshot.username == "lithe")
        #expect(snapshot.exclusions == ["127.0.0.1", "localhost"])
    }

    @Test
    func proxyFieldsPersistAcrossRelaunchAndRestoreDefaults() {
        let store = NetworkProxyTestStore()
        let settings = configuredSettings(store: store)

        let reloaded = AppSettings(store: store)
        #expect(reloaded.networkProxyMode == .custom)
        #expect(reloaded.networkProxyType == .socks5)
        #expect(reloaded.networkProxyHost == "127.0.0.1")
        #expect(reloaded.networkProxyPort == 7890)
        #expect(reloaded.networkProxyUsername == "lithe")
        #expect(reloaded.networkProxyExclusions == ["127.0.0.1", "localhost"])

        reloaded.restoreDefaults()
        #expect(reloaded.networkProxyMode == .system)
        #expect(reloaded.networkProxyType == .http)
        #expect(AppSettings(store: store).networkProxyHost.isEmpty)
    }

    @Test
    func editsReachTheLiveSnapshot() {
        let settings = AppSettings(store: NetworkProxyTestStore())
        settings.networkProxyMode = .custom
        settings.networkProxyType = .socks5
        settings.networkProxyHost = "proxy.internal.example"
        settings.networkProxyPort = 1080
        settings.networkProxyUsername = "lithe"
        settings.networkProxyExclusions = ["127.0.0.1", "", "localhost"]

        let snapshot = settings.networkProxyPreferences.snapshot
        #expect(snapshot.mode == .custom)
        #expect(snapshot.type == .socks5)
        #expect(snapshot.host == "proxy.internal.example")
        #expect(snapshot.port == 1080)
        #expect(snapshot.username == "lithe")
        // The snapshot carries values as entered; trimming and dropping empty
        // exclusions belong to Rust Core's `network.proxyPolicy`.
        #expect(snapshot.exclusions == ["127.0.0.1", "", "localhost"])
    }

    @Test
    func passwordNeverEntersTheKeyValueStoreButReachesTheSnapshot() {
        let store = NetworkProxyTestStore()
        let settings = AppSettings(store: store)
        settings.updateNetworkProxyCredential(NetworkProxyCredential(
            identity: NetworkProxyIdentity(configuration: settings.networkProxyPreferences.snapshot), password: "secret"
        ))
        #expect(settings.networkProxyPreferences.snapshot.password == "secret")
        #expect(settings.networkProxyHasSavedPassword)
        for (key, value) in store.storedValues {
            guard let value = value as? String else { continue }
            #expect(!value.contains("secret"), "the password leaked through \(key)")
        }

        settings.updateNetworkProxyCredential(nil)
        #expect(settings.networkProxyPreferences.snapshot.password.isEmpty)
        #expect(!settings.networkProxyHasSavedPassword)
    }

    @Test
    func keychainRecordKeepsIdentityAndRejectsUnscopedLegacySecrets() throws {
        let store = ProxyCredentialTestStore()
        let settings = configuredSettings(store: NetworkProxyTestStore())
        let credential = NetworkProxyCredential(
            identity: NetworkProxyIdentity(configuration: settings.networkProxyPreferences.snapshot), password: "sample-value"
        )
        try credential.save(to: store, key: AppSettings.networkProxyPasswordKey)
        #expect(NetworkProxyCredential.load(from: store, key: AppSettings.networkProxyPasswordKey) == credential)
        store.rejectWrites = true
        #expect(throws: ProxyCredentialTestStore.WriteFailure.self) {
            try NetworkProxyCredential(identity: credential.identity, password: "replacement").save(
                to: store, key: AppSettings.networkProxyPasswordKey
            )
        }
        #expect(NetworkProxyCredential.load(from: store, key: AppSettings.networkProxyPasswordKey) == credential)
        store.value = "legacy-unbound-secret"
        #expect(NetworkProxyCredential.load(from: store, key: AppSettings.networkProxyPasswordKey) == nil)
    }

    @Test
    func savedPasswordOnlyFollowsItsOriginalProxyIdentity() throws {
        let settings = configuredSettings(store: NetworkProxyTestStore())
        let credential = NetworkProxyCredential(
            identity: NetworkProxyIdentity(configuration: settings.networkProxyPreferences.snapshot), password: "saved-secret"
        )
        settings.updateNetworkProxyCredential(credential)
        let bridge = RustCoreBridge()
        func candidate(host: String = "127.0.0.1", port: Int = 7890,
                       username: String = "lithe", type: NetworkProxyType = .socks5,
                       draft: String = "") -> NetworkProxyConfiguration {
            settings.networkProxyCandidate(type: type, host: host, port: port, username: username, passwordDraft: draft)
        }
        #expect(bridge.networkProxyPolicy(from: candidate())?.password == credential.password)
        for changed in [candidate(host: "other.example"), candidate(port: 8080),
                        candidate(username: "other"), candidate(type: .http)] {
            #expect(bridge.networkProxyPolicy(from: changed)?.password == "")
        }
        #expect(bridge.networkProxyPolicy(from: candidate(host: "other.example", draft: "new-secret"))?.password == "new-secret")

        // Saving an endpoint without a new secret must not rebind the saved
        // password, either immediately or after restoring the Keychain record.
        settings.networkProxyHost = "other.example"
        #expect(bridge.networkProxyPolicy(from: settings.networkProxyPreferences.snapshot)?.password == "")
        let restored = AppSettings(store: NetworkProxyTestStore())
        restored.networkProxyMode = .custom
        restored.networkProxyType = .socks5
        restored.networkProxyHost = "other.example"
        restored.networkProxyPort = 7890
        restored.networkProxyUsername = "lithe"
        restored.updateNetworkProxyCredential(try JSONDecoder().decode(
            NetworkProxyCredential.self, from: JSONEncoder().encode(credential)
        ))
        #expect(bridge.networkProxyPolicy(from: restored.networkProxyPreferences.snapshot)?.password == "")
        restored.networkProxyHost = "127.0.0.1"
        #expect(bridge.networkProxyPolicy(from: restored.networkProxyPreferences.snapshot)?.password == credential.password)
    }

}

private final class NetworkProxyTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    var storedValues: [String: Any] { values }

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class ProxyCredentialTestStore: SecureStore, @unchecked Sendable {
    struct WriteFailure: Error {}
    var value: String?
    var rejectWrites = false
    func read(key: String) -> String? { value }
    func write(_ value: String, key: String) throws {
        if rejectWrites { throw WriteFailure() }
        self.value = value
    }
    func delete(key: String) throws { value = nil }
}
