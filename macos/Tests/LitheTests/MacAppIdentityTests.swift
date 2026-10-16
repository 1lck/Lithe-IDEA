import Foundation
import Testing
@testable import Lithe

struct MacAppIdentityTests {
    private let stable = MacAppIdentity(bundleIdentifier: "app.lithe.desktop")
    private let development = MacAppIdentity(bundleIdentifier: "app.lithe.desktop.dev")

    @Test
    func stableKeepsHistoricalPathsWhileDevelopmentHasSeparateState() {
        let base = URL(fileURLWithPath: "/fixture/Library/Application Support", isDirectory: true)
        #expect(stable.storageRoot(base) == base)
        #expect(development.storageRoot(base) == base.appendingPathComponent("app.lithe.desktop.dev", isDirectory: true))
        #expect(MacAppIdentity(bundleIdentifier: nil).storageRoot(base) == base)
        #expect(MacAppIdentity(bundleIdentifier: "example.fixture").storageRoot(base) == base)
        #expect(stable.keychainService("database") == "app.lithe.desktop.database")
        #expect(development.keychainService("database") == "app.lithe.desktop.dev.database")
        #expect(stable.keychainService("github") != development.keychainService("github"))
        let stableStorage = MacFileStorage(identity: stable)
        let devStorage = MacFileStorage(identity: development)
        #expect(stableStorage.applicationSupportDirectory() != devStorage.applicationSupportDirectory())
        #expect(stableStorage.cacheDirectory() != devStorage.cacheDirectory())
        #expect(stableStorage.homeDirectory() == devStorage.homeDirectory())
        #expect(MacLogDirectoryProvider(identity: stable).defaultLogDirectory.path.hasSuffix("/Logs/Lithe"))
        #expect(MacLogDirectoryProvider(identity: development).defaultLogDirectory.path.hasSuffix("/Logs/app.lithe.desktop.dev/Lithe"))
    }

    @Test
    func developmentCredentialsNeverReadOrModifyTheStableSecretFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FixtureHomeFileManager(home: home)
        let stableStore = MacLocalSecretStore(fileManager: manager, identity: stable)
        let devStore = MacLocalSecretStore(fileManager: manager, identity: development)
        try stableStore.write("stable-secret", key: "provider")
        let stableFile = home.appendingPathComponent("Library/Application Support/Lithe/ai-secrets.json")
        let baseline = try Data(contentsOf: stableFile)
        #expect(devStore.read(key: "provider") == nil)
        try devStore.write("dev-secret", key: "provider")
        #expect(stableStore.read(key: "provider") == "stable-secret")
        #expect(MacLocalSecretStore(fileManager: manager, identity: development).read(key: "provider") == "dev-secret")
        try devStore.delete(key: "provider")
        #expect(try Data(contentsOf: stableFile) == baseline)
    }

    @Test
    func preferenceAndChannelChangesDoNotCrossDistributionDomains() {
        let suffix = ".fixture." + UUID().uuidString
        let stableName = stable.bundleIdentifier + suffix
        let devName = development.bundleIdentifier + suffix
        let stableDefaults = UserDefaults(suiteName: stableName)!
        let devDefaults = UserDefaults(suiteName: devName)!
        defer {
            stableDefaults.removePersistentDomain(forName: stableName)
            devDefaults.removePersistentDomain(forName: devName)
        }
        stableDefaults.set("stable-theme", forKey: "theme")
        devDefaults.set("dev-theme", forKey: "theme")
        devDefaults.set("autobuild", forKey: AppUpdateChannel.preferenceKey)
        #expect(stableDefaults.string(forKey: "theme") == "stable-theme")
        #expect(AppUpdateChannel.saved(in: stableDefaults) == .stable)
        stableDefaults.set("stable", forKey: AppUpdateChannel.preferenceKey)
        #expect(AppUpdateChannel.saved(in: devDefaults) == .autobuild)
    }
}

private final class FixtureHomeFileManager: FileManager, @unchecked Sendable {
    private let home: URL
    init(home: URL) { self.home = home; super.init() }
    override var homeDirectoryForCurrentUser: URL { home }
}
