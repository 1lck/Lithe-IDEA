import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project runtime settings")
struct ProjectRuntimeSettingsTests {
    @Test
    func overlayPrefersRunConfigurationThenSubprojectThenProjectJDK() {
        var settings = ProjectRuntimeSettings(javaHomePath: "/jdk-21")
        settings.setOverride(path: "services/alpha", javaHomePath: "/jdk-17")

        #expect(
            settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/beta").javaHomePath
                == "/jdk-21"
        )
        #expect(
            settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/alpha").javaHomePath
                == "/jdk-17"
        )
        #expect(
            settings.overlay(
                onto: RunOptions(),
                workspaceRelativePath: "services/alpha/module-a"
            ).javaHomePath == "/jdk-17"
        )
        #expect(
            settings.overlay(
                onto: RunOptions(javaHomePath: "/jdk-8"),
                workspaceRelativePath: "services/alpha"
            ).javaHomePath == "/jdk-8"
        )
        #expect(
            settings.overlay(
                onto: RunOptions(javaHomePath: "/jdk-21"),
                workspaceRelativePath: "services/alpha"
            ).javaHomePath == "/jdk-17"
        )
    }

    @Test
    func emptySubprojectOverrideInheritsProjectMavenHome() {
        var settings = ProjectRuntimeSettings(
            mavenHomeSelection: .custom,
            mavenHomePath: "/opt/maven"
        )
        settings.setOverride(path: "services/alpha", javaHomePath: "/jdk-17")

        let options = settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/alpha")
        #expect(options.javaHomePath == "/jdk-17")
        #expect(options.mavenExecutablePath == "/opt/maven")
    }

    @Test
    func nestedSubprojectOverrideKeepsParentOverride() {
        var settings = ProjectRuntimeSettings(javaHomePath: "/jdk-21")
        settings.setOverride(path: "services/alpha", javaHomePath: "/jdk-17")
        settings.setOverride(path: "services/alpha/api", javaHomePath: "/jdk-11")

        #expect(settings.exactOverride(for: "services/alpha")?.javaHomePath == "/jdk-17")
        #expect(settings.exactOverride(for: "services/alpha/api")?.javaHomePath == "/jdk-11")
        #expect(
            settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/alpha").javaHomePath
                == "/jdk-17"
        )
        #expect(
            settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/alpha/api").javaHomePath
                == "/jdk-11"
        )
        #expect(
            settings.overlay(
                onto: RunOptions(),
                workspaceRelativePath: "services/alpha/api/impl"
            ).javaHomePath == "/jdk-11"
        )

        settings.setOverride(path: "services/alpha/api", javaHomePath: "")
        #expect(settings.exactOverride(for: "services/alpha/api") == nil)
        #expect(settings.exactOverride(for: "services/alpha")?.javaHomePath == "/jdk-17")
        #expect(
            settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/alpha/api").javaHomePath
                == "/jdk-17"
        )
    }

    @Test
    func inventoryListsIndependentBackendsAndFrontendRoots() {
        let root = URL(fileURLWithPath: "/workspace/shop", isDirectory: true)
        let alpha = MavenProject(
            rootURL: root.appendingPathComponent("services/alpha", isDirectory: true),
            pomURL: root.appendingPathComponent("services/alpha/pom.xml"),
            groupID: "shop",
            artifactID: "alpha",
            version: "1.0",
            packaging: "jar",
            modules: [
                MavenModule(
                    relativePath: "api",
                    url: root.appendingPathComponent("services/alpha/api", isDirectory: true),
                    groupID: "shop",
                    artifactID: "alpha-api",
                    version: "1.0",
                    packaging: "jar",
                    modules: []
                )
            ],
            profiles: [],
            hasWrapper: true
        )
        let files = [
            root.appendingPathComponent("services/alpha/pom.xml"),
            root.appendingPathComponent("services/alpha/api/pom.xml"),
            root.appendingPathComponent("services/beta/pom.xml"),
            root.appendingPathComponent("frontend/package.json")
        ]

        let subprojects = ProjectRuntimeInventory.subprojects(
            workspaceName: "shop",
            workspaceURL: root,
            files: files,
            mavenProject: alpha
        )

        #expect(subprojects.map(\.id) == [
            "project",
            "maven:services/alpha",
            "module:services/alpha/api",
            "maven:services/beta",
            "other:frontend"
        ])
        #expect(subprojects.first { $0.id == "maven:services/beta" }?.usesJava == true)
        #expect(subprojects.first { $0.id == "other:frontend" }?.usesJava == false)
        #expect(
            ProjectRuntimeInventory.workspaceRelativePath(
                modulePath: ".",
                workingDirectory: "services/beta"
            ) == "services/beta"
        )
    }

    @Test
    func settingsCategoryIncludesProjectBetweenKeymapAndTerminal() {
        let titles = SettingsCategory.allCases.map(\.rawValue)
        let keymap = titles.firstIndex(of: "Keymap")
        let project = titles.firstIndex(of: "Project")
        let terminal = titles.firstIndex(of: "Terminal")
        #expect(keymap != nil && project != nil && terminal != nil)
        #expect(project == keymap.map { $0 + 1 })
        #expect(terminal == project.map { $0 + 1 })
    }

    @Test
    @MainActor
    func persistedSettingsReloadForTheSameProject() {
        let store = ProjectRuntimeSettingsTestStore()
        let root = URL(fileURLWithPath: "/workspace/shop", isDirectory: true)
        let locator = ProjectRuntimeSettingsTestLocator()
        let service = ProjectRuntimeService(runtimeLocator: locator, store: store)
        service.openProject(at: root)
        var settings = ProjectRuntimeSettings(javaHomePath: "/Library/Java/jdk-21")
        settings.setOverride(path: "services/alpha", javaHomePath: "/Library/Java/jdk-17")
        service.updateSettings(settings)

        let reloaded = ProjectRuntimeService(runtimeLocator: locator, store: store)
        reloaded.openProject(at: root)
        #expect(reloaded.settings.javaHomePath == "/Library/Java/jdk-21")
        #expect(reloaded.settings.exactOverride(for: "services/alpha")?.javaHomePath == "/Library/Java/jdk-17")
        #expect(
            reloaded.overlayProjectRuntime(
                onto: RunOptions(),
                modulePath: ".",
                workingDirectory: "services/alpha"
            ).javaHomePath == "/Library/Java/jdk-17"
        )
    }

    @Test
    @MainActor
    func invalidConfiguredProjectJDKIsNotMaskedByDiscovery() async throws {
        let store = ProjectRuntimeSettingsTestStore()
        let root = URL(fileURLWithPath: "/workspace/shop", isDirectory: true)
        let discovered = JavaRuntimeCandidate(
            homePath: "/Library/Java/jdk-21",
            version: "21",
            vendor: "Test"
        )
        let locator = ProjectRuntimeSettingsTestLocator(
            validJavaHomes: ["/Library/Java/jdk-21"],
            discoveredJavaRuntimes: [discovered]
        )
        let service = ProjectRuntimeService(runtimeLocator: locator, store: store)
        service.openProject(at: root)
        service.updateSettings(ProjectRuntimeSettings(javaHomePath: "/missing-jdk"))
        await service.refreshAvailableRuntimes()

        let report = try #require(service.javaEnvironmentReport)
        #expect(report.status == .configuredJDKInvalid(path: "/missing-jdk"))
        #expect(report.status.blocksJavaRun)
        #expect(service.javaHomeURL() == nil)
        #expect(report.javaHomePath == "/missing-jdk")
    }
}

private final class ProjectRuntimeSettingsTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct ProjectRuntimeSettingsTestLocator: RuntimeLocator {
    var validJavaHomes: Set<String>?
    var discoveredJavaRuntimes: [JavaRuntimeCandidate] = []

    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: discoveredJavaRuntimes, mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? {
        if let validJavaHomes {
            return validJavaHomes.contains(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        JavaRuntimeCandidate(homePath: homeURL.path, version: "21", vendor: "Test")
    }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}
