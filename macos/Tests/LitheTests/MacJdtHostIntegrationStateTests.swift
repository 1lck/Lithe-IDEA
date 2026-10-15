import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import Testing

/// What happens to the JDT LS state in the host cache when the plugin that
/// declares the `jdt` integration goes away. The state sits next to other
/// language servers' caches, outside the plugin's own state directory, so the
/// integration has to discard it itself.
@Suite("macOS JDT LS plugin state removal")
@MainActor
struct MacJdtHostIntegrationStateTests {
    @Test
    func removedJavaSupportTakesItsIndexesAndEquinoxAreasWithIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let javaSupport = try installedJavaSupport(status: .removed)

        fixture.integration.pluginsDidLoad([], installed: [javaSupport])
        await fixture.integration.stateRemoval?.value

        #expect(!FileManager.default.fileExists(atPath: fixture.workspaceIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.equinoxAreaURL.path))
        // Other servers' caches in the same host directory are not JDT's.
        #expect(FileManager.default.fileExists(atPath: fixture.unrelatedCacheURL.path))
    }

    @Test
    func uninstalledJavaSupportTakesItsStateWithIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        fixture.integration.pluginsDidLoad([], installed: [])
        await fixture.integration.stateRemoval?.value

        #expect(!FileManager.default.fileExists(atPath: fixture.workspaceIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.equinoxAreaURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.unrelatedCacheURL.path))
    }

    @Test
    func installedJavaSupportKeepsItsStateEvenWhileDisabledOrRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let javaSupport = try installedJavaSupport(status: .installed)

        // Accepted (a disabled plugin is accepted too).
        fixture.integration.pluginsDidLoad([javaSupport], installed: [javaSupport])
        await fixture.integration.stateRemoval?.value
        // Installed but rejected at startup: not registered, still installed.
        fixture.integration.pluginsDidLoad([], installed: [javaSupport])
        await fixture.integration.stateRemoval?.value

        #expect(FileManager.default.fileExists(atPath: fixture.workspaceIndexURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.equinoxAreaURL.path))
    }

    @Test
    func aFailedPluginScanNeverDeletesState() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        fixture.integration.pluginsDidLoad([], installed: nil)
        await fixture.integration.stateRemoval?.value

        #expect(fixture.integration.stateRemoval == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.workspaceIndexURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.equinoxAreaURL.path))
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let integration: MacJdtHostIntegration
        /// `<cache>/jdtls/<workspace key>`: JDT LS's `-data` directory.
        let workspaceIndexURL: URL
        /// `<cache>/jdtls-configuration/<hash>/configuration`: Equinox area.
        let equinoxAreaURL: URL
        let unrelatedCacheURL: URL

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-jdt-state-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = root.appendingPathComponent("language-servers", isDirectory: true)
        let key = String(repeating: "a", count: 64)
        let workspaceIndexURL = cacheURL.appendingPathComponent("jdtls/\(key)", isDirectory: true)
        let equinoxAreaURL = cacheURL
            .appendingPathComponent("jdtls-configuration/\(key)/configuration", isDirectory: true)
        let unrelatedCacheURL = cacheURL.appendingPathComponent("other-server", isDirectory: true)
        for directory in [workspaceIndexURL, equinoxAreaURL, unrelatedCacheURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("state".utf8).write(to: directory.appendingPathComponent("marker"))
        }

        let directories = MacPluginStateDirectories(rootURL: root.appendingPathComponent("plugin-state"))
        let integration = MacJdtHostIntegration(
            launchResolver: MacPluginLanguageServerLaunchResolver(
                planner: DeclarativePluginTestSupport.operations,
                directories: directories,
                settings: InMemoryPluginSettings()
            ),
            runtimeService: ProjectRuntimeService(
                runtimeLocator: EmptyRuntimeLocator(),
                store: DiscardingKeyValueStore()
            ),
            workspaceState: MacJdtWorkspaceState(
                cacheDirectoryURL: cacheURL,
                workspaceKeyResolver: { _, _ in key }
            )
        )
        return Fixture(
            root: root,
            integration: integration,
            workspaceIndexURL: workspaceIndexURL,
            equinoxAreaURL: equinoxAreaURL,
            unrelatedCacheURL: unrelatedCacheURL
        )
    }

    private func installedJavaSupport(status: PluginInstallationStatus) throws -> InstalledPluginPackage {
        let descriptor = try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")
        return InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .bundled,
                status: status
            ),
            packageURL: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("Plugins/mac/Official/JavaSupport")
        )
    }
}

private struct EmptyRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private struct DiscardingKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
