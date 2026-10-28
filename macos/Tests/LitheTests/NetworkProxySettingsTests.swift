import Foundation
import Testing
@testable import Lithe

/// Protects the network proxy settings: persistence across relaunch, default
/// values, exclusion parsing, and the live snapshot the session provider
/// reads. The password never touches the KeyValueStore; it is pushed into the
/// snapshot through the Keychain-merging entry point.
@Suite("Network proxy settings")
@MainActor
struct NetworkProxySettingsTests {
    @Test
    func proxyConfigurationPersistsAcrossRelaunchAndRestoresDefaults() {
        let store = NetworkProxyTestStore()
        let settings = AppSettings(store: store)
        #expect(settings.networkProxyMode == .system)
        #expect(settings.networkProxyType == .http)
        #expect(settings.networkProxyHost.isEmpty)
        #expect(settings.networkProxyPort == 0)
        #expect(settings.networkProxyUsername.isEmpty)
        #expect(settings.networkProxyExclusions.isEmpty)

        settings.networkProxyMode = .custom
        settings.networkProxyType = .socks5
        settings.networkProxyHost = "127.0.0.1"
        settings.networkProxyPort = 7890
        settings.networkProxyUsername = "lithe"
        settings.networkProxyExclusions = ["127.0.0.1", "localhost"]

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
    func editsPushIntoTheLiveSnapshotTheNetworkLayerReads() {
        let settings = AppSettings(store: NetworkProxyTestStore())
        settings.networkProxyMode = .custom
        settings.networkProxyType = .socks5
        settings.networkProxyHost = " proxy.internal.example "
        settings.networkProxyPort = 1080
        settings.networkProxyUsername = "lithe"
        settings.networkProxyExclusions = [" 127.0.0.1 ", "", "localhost"]

        let snapshot = settings.networkProxyPreferences.snapshot
        #expect(snapshot.mode == .custom)
        #expect(snapshot.type == .socks5)
        #expect(snapshot.host == "proxy.internal.example")
        #expect(snapshot.port == 1080)
        #expect(snapshot.username == "lithe")
        // Trimming and empty entries are normalized once, where they are set.
        #expect(snapshot.exclusions == ["127.0.0.1", "localhost"])
        #expect(snapshot.isCustomConfigured)
        #expect(!settings.networkProxyHasSavedPassword)
    }

    @Test
    func passwordNeverEntersTheKeyValueStoreButReachesTheSnapshot() {
        let store = NetworkProxyTestStore()
        let settings = AppSettings(store: store)
        settings.updateNetworkProxyPassword("secret")
        #expect(settings.networkProxyPreferences.snapshot.password == "secret")
        #expect(settings.networkProxyHasSavedPassword)
        #expect(store.string(forKey: "settings.networkProxyUsername") != "secret")
        for (key, value) in store.storedValues {
            guard let value = value as? String else { continue }
            #expect(!value.contains("secret"), "the password leaked through \(key)")
        }

        settings.updateNetworkProxyPassword("")
        #expect(settings.networkProxyPreferences.snapshot.password.isEmpty)
        #expect(!settings.networkProxyHasSavedPassword)
    }

    @Test
    func exclusionParsingTrimsAndDropsEmptyEntries() {
        #expect(AppSettings.parsedNetworkProxyExclusions([]).isEmpty)
        #expect(AppSettings.parsedNetworkProxyExclusions(["  a.example  ", "", "b.example"]) == ["a.example", "b.example"])
    }

    @Test
    func anUnfinishedCustomServerKeepsSystemBehavior() {
        let settings = AppSettings(store: NetworkProxyTestStore())
        settings.networkProxyMode = .custom
        // No host and port yet: the snapshot must not look configured, so the
        // session provider keeps resolving proxies the system way.
        #expect(!settings.networkProxyPreferences.snapshot.isCustomConfigured)
        settings.networkProxyHost = "proxy.example"
        settings.networkProxyPort = 0
        #expect(!settings.networkProxyPreferences.snapshot.isCustomConfigured)
        settings.networkProxyPort = 8080
        #expect(settings.networkProxyPreferences.snapshot.isCustomConfigured)
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
