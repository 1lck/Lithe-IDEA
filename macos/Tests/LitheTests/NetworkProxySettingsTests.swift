import Foundation
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
        settings.updateNetworkProxyPassword("secret")
        #expect(settings.networkProxyPreferences.snapshot.password == "secret")
        #expect(settings.networkProxyHasSavedPassword)
        for (key, value) in store.storedValues {
            guard let value = value as? String else { continue }
            #expect(!value.contains("secret"), "the password leaked through \(key)")
        }

        settings.updateNetworkProxyPassword("")
        #expect(settings.networkProxyPreferences.snapshot.password.isEmpty)
        #expect(!settings.networkProxyHasSavedPassword)
    }

    /// Regression for the review P2: after a save clears the password field,
    /// the connectivity check must still verify the saved password instead of
    /// authenticating with an empty one.
    @Test
    func effectivePasswordPrefersTheDraftAndFallsBackToTheSavedOne() {
        let settings = AppSettings(store: NetworkProxyTestStore())
        settings.updateNetworkProxyPassword("saved-secret")

        #expect(settings.effectiveNetworkProxyPassword(draft: "") == "saved-secret")
        #expect(settings.effectiveNetworkProxyPassword(draft: "typed-secret") == "typed-secret")
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
