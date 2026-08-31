import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Maven and runtime integration")
struct MavenRuntimeTests {
    @Test
    func mavenLifecyclePhasesMatchTheSharedPlatformContract() throws {
        let fixture = try Self.platformContractFixture()
        #expect(MavenLifecyclePhase.allCases.map(\.rawValue) == fixture.lifecyclePhases)
    }

    @Test
    func macMavenStorageIdentityMatchesTheSharedPlatformContract() throws {
        let fixture = try Self.platformContractFixture()
        let macCases = fixture.storageIdentityCases.filter { $0.platform == "macos" }
        #expect(macCases.count == 1)
        for item in macCases {
            #expect(MacMavenConfigurationStore.storageIdentity(
                workspacePath: item.workspacePath,
                reactorPath: item.reactorPath
            ) == item.expectedIdentity)
        }
    }

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
    func mavenLaunchPlanPayloadDecodesSharedCoreResponse() throws {
        let json = #"""
        {
            "version": 1,
            "executable": { "toolchain": "project-maven" },
            "arguments": ["-B", "-ntp", "verify"],
            "workingDirectory": "projects/demo",
            "configurationFingerprint": "sha256:fixture"
        }
        """#

        let payload = try JSONDecoder().decode(
            RustCoreBridge.MavenLaunchPlanPayload.self,
            from: Data(json.utf8)
        )
        let plan = payload.makeModel()

        #expect(plan.version == 1)
        #expect(plan.toolchain == "project-maven")
        #expect(plan.arguments == ["-B", "-ntp", "verify"])
        #expect(plan.workingDirectory == "projects/demo")
        #expect(plan.configurationFingerprint == "sha256:fixture")
    }

    @Test
    func mavenConfigurationSeparatesPortableAndLocalPaths() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-maven-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspace = testRoot.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let storage = MavenTestFileStorage(root: testRoot)
        let store = MacMavenConfigurationStore(storage: storage)
        let configuration = MavenStoredConfiguration(
            portable: MavenPortableConfiguration(
                selectedProfiles: ["dev", "qa"],
                customProfiles: ["qa"],
                skipTests: true
            ),
            local: MavenLocalConfiguration(
                settingsPath: "/private/settings.xml",
                mavenExecutablePath: "/private/apache-maven",
                javaHomePath: "/private/jdk"
            )
        )

        try store.saveMavenConfiguration(
            configuration,
            workspaceURL: workspace,
            reactorPath: "."
        )

        let portableURL = workspace.appendingPathComponent(".lithe/maven/config.json")
        let portableText = String(decoding: try Data(contentsOf: portableURL), as: UTF8.self)
        #expect(portableText.contains("\"selectedProfiles\""))
        #expect(!portableText.contains("/private/"))
        #expect(try store.loadMavenConfiguration(
            workspaceURL: workspace,
            reactorPath: "."
        ) == configuration)
        let localFiles = try FileManager.default.contentsOfDirectory(
            at: storage.applicationSupportDirectory().appendingPathComponent("Lithe/Maven"),
            includingPropertiesForKeys: nil
        )
        #expect(localFiles.count == 1)
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
    func mavenOverrideUsesRuntimeLocatorForHomeExecutableAndInvalidPaths() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let home = root.appendingPathComponent("toolchains/maven", isDirectory: true)
        let homeExecutable = home.appendingPathComponent("bin/mvn")
        let directExecutable = root.appendingPathComponent("toolchains/custom-mvn")
        let locator = MavenOverrideRuntimeLocator(resolutions: [
            home.standardizedFileURL.path: homeExecutable,
            directExecutable.standardizedFileURL.path: directExecutable
        ])
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())

        #expect(service.mavenExecutable(at: root, overridePath: "toolchains/maven") == homeExecutable)
        #expect(service.mavenExecutable(at: root, overridePath: directExecutable.path) == directExecutable)
        #expect(service.mavenExecutable(at: root, overridePath: "toolchains/missing") == nil)
    }

    @Test
    func macRuntimeDiscoveryDistinguishesMavenHomeFromExecutable() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-maven-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let home = testRoot.appendingPathComponent("apache-maven", isDirectory: true)
        let homeExecutable = home.appendingPathComponent("bin/mvn")
        let directExecutable = testRoot.appendingPathComponent("custom-mvn")
        let invalidHome = testRoot.appendingPathComponent("invalid-maven", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: invalidHome, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: homeExecutable.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: directExecutable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: homeExecutable.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directExecutable.path
        )

        #expect(MacRuntimeDiscovery.mavenExecutable(forHomePath: home.path) == homeExecutable)
        #expect(MacRuntimeDiscovery.mavenExecutable(forHomePath: directExecutable.path) == directExecutable)
        #expect(MacRuntimeDiscovery.mavenExecutable(forHomePath: invalidHome.path) == nil)
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

    private static func platformContractFixture() throws -> MavenPlatformContractFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared/fixtures/maven/platform-contract-v1.json"
        )
        return try JSONDecoder().decode(
            MavenPlatformContractFixture.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct MavenPlatformContractFixture: Decodable {
    struct StorageIdentityCase: Decodable {
        let platform: String
        let workspacePath: String
        let reactorPath: String
        let expectedIdentity: String
    }

    let lifecyclePhases: [String]
    let storageIdentityCases: [StorageIdentityCase]
}

private struct MavenTestFileStorage: FileStorage {
    let root: URL

    func homeDirectory() -> URL { root.appendingPathComponent("home", isDirectory: true) }
    func cacheDirectory() -> URL { root.appendingPathComponent("cache", isDirectory: true) }
    func applicationSupportDirectory() -> URL {
        root.appendingPathComponent("application-support", isDirectory: true)
    }
    func temporaryDirectory() -> URL { root.appendingPathComponent("temporary", isDirectory: true) }
    func metadata(for url: URL) -> FileMetadata? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey
        ]) else { return nil }
        return FileMetadata(
            byteCount: values.fileSize,
            modificationDate: values.contentModificationDate,
            isRegularFile: values.isRegularFile == true,
            isDirectory: values.isDirectory == true
        )
    }
    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func isExecutable(at url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }
    func listDirectory(at url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        Data(try Data(contentsOf: url).prefix(byteCount))
    }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data {
        try Data(contentsOf: url, options: options)
    }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
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

private struct MavenOverrideRuntimeLocator: RuntimeLocator {
    let resolutions: [String: URL]

    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool {
        resolutions[url.standardizedFileURL.path]?.standardizedFileURL == url.standardizedFileURL
    }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? {
        resolutions[URL(fileURLWithPath: path).standardizedFileURL.path]
    }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func systemJDBExecutable() -> URL? { nil }
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
