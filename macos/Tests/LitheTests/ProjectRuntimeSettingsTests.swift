import Foundation
import LitheModuleAPI
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
    func inventoryUsesProviderHierarchyAndDeclarationsInsteadOfGuessingFromFileNames() {
        let root = URL(fileURLWithPath: "/workspace/fixture")
        let files = ["engine.marker", "ghost/engine.marker", "pom.xml", "package.json"].map { root.appendingPathComponent($0) }
        let language = LanguageSupportDeclaration(id: "java", displayName: "Java", projectFileNames: ["engine.marker"])
        let model = BuildModel(projects: [
            .init(id: "root", path: ".", name: "Root"),
            .init(id: "library", path: "active/library", name: "Engine library", parentID: "root"),
            .init(id: "nested", path: "active/library/nested", name: "Engine child", parentID: "library")
        ])
        let sources: [ProjectRuntimeInventory.BuildSource] = [.init(id: "generic:root", root: ".", displayName: "Generic", usesJava: true, model: model)]
        let rows = ProjectRuntimeInventory.subprojects(workspaceName: "fixture", workspaceURL: root, files: files,
            buildSources: sources, languageSupports: [language])
        #expect(rows.map(\.id) == ["project", "path:active/library", "path:active/library/nested"])
        #expect(rows.last?.parentID == "path:active/library")
        #expect(rows.last?.title == "Engine child")
        #expect(rows.allSatisfy { $0.usesJava })
        #expect(ProjectRuntimeInventory.subprojects(workspaceName: "fixture", workspaceURL: root, files: files,
            buildSources: [], languageSupports: []).map(\.id) == ["project"])
        let passive = ProjectRuntimeInventory.subprojects(workspaceName: "fixture", workspaceURL: root, files: files,
            buildSources: [], languageSupports: [language])
        #expect(passive.map(\.id) == ["project", "path:ghost"])
        #expect(passive.last?.kind == .other)
    }

    @Test
    func overlappingSourcesShareOneDirectoryAndDoNotExposeOutsideFiles() {
        let root = URL(fileURLWithPath: "/workspace/fixture")
        let model = BuildModel(projects: [.init(id: "library", path: "services/library", name: "Library")])
        let rows = ProjectRuntimeInventory.subprojects(workspaceName: "fixture", workspaceURL: root,
            files: [URL(fileURLWithPath: "/outside/engine.marker")],
            buildSources: [
                .init(id: "first", root: "services/library", displayName: "First", usesJava: false, model: model),
                .init(id: "second", root: "services/library", displayName: "Second", usesJava: true, model: nil),
                .init(id: "outside", root: "../outside", displayName: "Outside", usesJava: false, model: nil)
            ], languageSupports: [.init(id: "java", displayName: "Java", projectFileNames: ["engine.marker"])])
        #expect(rows.map(\.id) == ["project", "path:services/library"])
        #expect(rows.last?.usesJava == true)
    }

    @Test
    func inventoryListsIndependentBackendsAndFrontendRoots() {
        let root = URL(fileURLWithPath: "/workspace/shop", isDirectory: true)
        let alpha = BuildModel(projects: [
            .init(id: "alpha", path: "services/alpha", name: "alpha"),
            .init(id: "api", path: "services/alpha/api", name: "alpha-api", parentID: "alpha")
        ])
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
            buildSources: [.init(id: "sample:alpha", root: "services/alpha", displayName: "Build root", usesJava: true, model: alpha)],
            languageSupports: [
                LanguageSupportDeclaration(id: "java", displayName: "Java", projectFileNames: ["pom.xml"]),
                LanguageSupportDeclaration(id: "frontend", displayName: "Frontend", projectFileNames: ["package.json"])
            ]
        )

        #expect(subprojects.map(\.id) == [
            "project",
            "path:services/alpha",
            "path:services/alpha/api",
            "path:frontend",
            "path:services/beta"
        ])
        #expect(subprojects.first { $0.id == "path:services/beta" }?.usesJava == true)
        #expect(subprojects.first { $0.id == "path:frontend" }?.usesJava == false)
        #expect(
            ProjectRuntimeInventory.workspaceRelativePath(
                modulePath: ".",
                workingDirectory: "services/beta"
            ) == "services/beta"
        )
    }

    @Test
    func settingsCategoryPlacesProjectAndRunBetweenKeymapAndTerminal() {
        // Run configurations sit next to the project environment they inherit.
        let titles = SettingsCategory.allCases.map(\.rawValue)
        let keymap = titles.firstIndex(of: "Keymap")
        let project = titles.firstIndex(of: "Project")
        let run = titles.firstIndex(of: "Run configurations")
        let terminal = titles.firstIndex(of: "Terminal")
        #expect(keymap != nil && project != nil && run != nil && terminal != nil)
        #expect(project == keymap.map { $0 + 1 })
        #expect(run == project.map { $0 + 1 })
        #expect(terminal == run.map { $0 + 1 })
    }

    @Test
    @MainActor
    func persistedSettingsReloadForTheSameProject() {
        let store = InMemoryProjectRuntimeSettingsStore()
        let root = URL(fileURLWithPath: "/workspace/shop", isDirectory: true)
        let locator = ProjectRuntimeSettingsTestLocator()
        let service = ProjectRuntimeService(runtimeLocator: locator, settingsStore: store)
        service.openProject(at: root)
        var settings = ProjectRuntimeSettings(javaHomePath: "/Library/Java/jdk-21")
        settings.setOverride(path: "services/alpha", javaHomePath: "/Library/Java/jdk-17")
        service.updateSettings(settings)

        let reloaded = ProjectRuntimeService(runtimeLocator: locator, settingsStore: store)
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
        let store = InMemoryProjectRuntimeSettingsStore()
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
        let service = ProjectRuntimeService(runtimeLocator: locator, settingsStore: store)
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

struct ProjectRuntimeSettingsTestLocator: RuntimeLocator {
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
