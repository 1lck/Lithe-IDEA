import Foundation
import Testing
@testable import Lithe

@Suite("Maven and runtime integration")
struct MavenRuntimeTests {
    @Test
    func mavenScanPayloadDecodesRustCamelCaseIdentifiers() throws {
        let json = #"""
        {
            "relativePath": "services/api",
            "groupId": "com.example",
            "artifactId": "root",
            "version": "1.0",
            "packaging": "pom",
            "modules": [{
                "relativePath": "module-a",
                "groupId": "com.example",
                "artifactId": "child",
                "version": "1.0",
                "packaging": "jar",
                "modules": []
            }],
            "profiles": [{"id": "dev", "isActiveByDefault": true}],
            "hasWrapper": true
        }
        """#
        let payload = try JSONDecoder().decode(
            RustCoreBridge.MavenScanPayload.self,
            from: Data(json.utf8)
        )

        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-maven-payload", isDirectory: true)
        let project = payload.makeProject(workspaceRootURL: workspaceRoot)
        let expectedRoot = URL(
            fileURLWithPath: workspaceRoot.path + "/services/api",
            isDirectory: true
        )
        #expect(project.rootURL == expectedRoot)
        #expect(!project.rootURL.absoluteString.contains("%2F"))
        #expect(project.pomURL == expectedRoot.appendingPathComponent("pom.xml"))
        #expect(project.groupID == "com.example")
        #expect(project.artifactID == "root")
        #expect(project.modules.count == 1)
        #expect(project.modules[0].groupID == "com.example")
        #expect(project.modules[0].artifactID == "child")
        #expect(project.modules[0].url == expectedRoot.appendingPathComponent("module-a"))
        #expect(project.profiles == [MavenProfile(id: "dev", isActiveByDefault: true)])
        #expect(project.hasWrapper)
    }

    @Test
    func nestedMavenRunConfigurationsUseWorkspaceRelativeModulePaths() {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-nested-maven-run-\(UUID().uuidString)", isDirectory: true)
        let mavenRoot = URL(
            fileURLWithPath: workspaceRoot.path + "/projects/demo",
            isDirectory: true
        )
        let moduleRoot = mavenRoot.appendingPathComponent("service", isDirectory: true)
        let module = MavenModule(
            relativePath: "service",
            url: moduleRoot,
            groupID: "com.example",
            artifactID: "service-api",
            version: "1.0",
            packaging: "jar",
            modules: []
        )
        let project = MavenProject(
            rootURL: mavenRoot,
            pomURL: mavenRoot.appendingPathComponent("pom.xml"),
            groupID: "com.example",
            artifactID: "demo",
            version: "1.0",
            packaging: "pom",
            modules: [module],
            profiles: [],
            hasWrapper: false
        )

        let modules = RustJavaMavenOperations(core: RustCoreBridge()).workspaceMavenModules(
            in: project,
            relativeTo: workspaceRoot
        )
        #expect(modules.map { $0.path } == ["projects/demo/service"])
        #expect(modules.map { $0.module.relativePath } == ["service"])
    }

    @Test
    @MainActor
    func projectRelativeJavaOverridesResolveAgainstProjectRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-project-relative-runtime", isDirectory: true)
            .standardizedFileURL
        let javaHome = root.appendingPathComponent("toolchains/jdk", isDirectory: true).standardizedFileURL
        let mavenJavaHome = root.appendingPathComponent("toolchains/maven-jdk", isDirectory: true).standardizedFileURL
        let service = ProjectRuntimeService(
            runtimeLocator: ProjectRelativeRuntimeLocator(validJavaHomes: [javaHome.path, mavenJavaHome.path]),
            store: EmptyKeyValueStore()
        )
        service.openProject(at: root)

        #expect(service.javaHomeURL(overridePath: "toolchains/jdk") == javaHome)
        #expect(service.mavenJavaHomeURL(overridePath: "toolchains/maven-jdk") == mavenJavaHome)
    }

    @Test
    @MainActor
    func canceledRuntimeDiscoveryClearsDiscoveringState() async throws {
        let locator = BlockingRuntimeLocator()
        defer { locator.release() }
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        let task = Task { @MainActor in
            await service.refreshAvailableRuntimes()
        }

        #expect(await locator.waitUntilStarted())
        #expect(service.isDiscovering)

        task.cancel()
        locator.release()
        await task.value

        #expect(!service.isDiscovering)
    }
}

private struct ProjectRelativeRuntimeLocator: RuntimeLocator {
    let validJavaHomes: Set<String>

    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? {
        validJavaHomes.contains(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func javaLanguageServerExecutable() -> URL? { nil }
}

private final class BlockingRuntimeLocator: RuntimeLocator, @unchecked Sendable {
    private let started = TestGate()
    private let releaseGate = TestGate()

    func release() {
        releaseGate.open()
    }

    func waitUntilStarted() async -> Bool {
        await started.waitUntilOpen()
    }

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        started.open()
        _ = releaseGate.waitSynchronously()
        return RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }

    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func javaLanguageServerExecutable() -> URL? { nil }
}

private struct EmptyKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
