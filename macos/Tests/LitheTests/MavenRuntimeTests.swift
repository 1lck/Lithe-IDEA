import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Maven and runtime integration")
struct MavenRuntimeTests {
    @Test
    @MainActor
    func automaticJavaUsesProjectMinimumAndPreservesExplicitSelections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Before the Run list is identified, Core reads the minimum from the project's declaration.
        let pom = root.appendingPathComponent("pom.xml")
        let old = JavaRuntimeCandidate(homePath: "/jdk/env", version: "1.8.0_402", vendor: "fixture")
        let current = JavaRuntimeCandidate(homePath: "/jdk/current", version: "21.0.4", vendor: "fixture")
        let locator = ChoiceRuntimeLocator(environmentValues: ["JAVA_HOME": old.homePath], validJavaHomes: [old.homePath, current.homePath], runtimeCandidates: [old, current])
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        service.openProject(at: root)
        func require(_ version: String) throws {
            try Data("<project><properties><maven.compiler.release>\(version)</maven.compiler.release></properties></project>".utf8).write(to: pom)
        }
        try require("17")
        let choice = service.chooseJavaHome(overridePath: nil) { [old, current] }
        #expect(choice?.url?.path == current.homePath)
        #expect(service.javaHomeURL()?.path == current.homePath)
        #expect(service.mavenJavaHomeURL()?.path == current.homePath)
        #expect(locator.discoverCalls == 1)
        #expect(service.chooseMavenJavaHome(overridePath: nil) { [old, current] }?.url == choice?.url)
        #expect(service.chooseJavaHome(overridePath: old.homePath) { [old, current] }?.url?.path == old.homePath)
        #expect(service.chooseJavaHome(overridePath: "/missing") { [old, current] } == .invalid("/missing"))
        try require("25")
        if case .warning(let url, _, let message)? = service.chooseJavaHome(overridePath: nil, detected: { [old, current] }) {
            #expect(url.path == old.homePath)
            #expect(message.contains("25"))
        } else { Issue.record("Expected an actionable fallback warning") }
        try FileManager.default.removeItem(at: pom)
        #expect(service.chooseJavaHome(overridePath: nil) { [current, old] }?.url?.path == old.homePath)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe").path))
        // Project switching cannot retain the previous workspace's requirement.
        service.closeProject()
        #expect(service.chooseJavaHome(overridePath: nil) { [current, old] }?.url?.path == old.homePath)
        #expect(locator.discoverCalls == 1)
    }

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
            #expect(MacLegacyMavenConfigurationMigration.storageIdentity(
                workspacePath: item.workspacePath,
                reactorPath: item.reactorPath
            ) == item.expectedIdentity)
        }
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
    func javaChoiceNamesTheLaunchedJDKAndItsSource() {
        // Settings shows this chain's answer in place of "automatic", so each
        // step must report where the JDK came from, and a pending discovery must
        // not be replaced by a synchronous probe.
        let locator = ChoiceRuntimeLocator(
            environmentValues: ["JAVA_HOME": "/jdk/env"],
            validJavaHomes: ["/jdk/env", "/jdk/detected", "/jdk/project"]
        )
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        service.openProject(at: URL(fileURLWithPath: "/workspace", isDirectory: true))

        #expect(describe(service.chooseJavaHome(overridePath: nil) { nil }) == "found /jdk/env javaHomeEnvironment")
        #expect(service.javaHomeURL()?.path == "/jdk/env")
        #expect(locator.discoverCalls == 0)
        #expect(describe(service.chooseJavaHome(overridePath: "/missing") { nil }) == "invalid /missing")
        #expect(describe(service.chooseJavaHome(overridePath: "/jdk/detected") { nil }) == "found /jdk/detected configured")

        var settings = service.settings
        settings.javaHomePath = "/jdk/project"
        service.updateSettings(settings)
        #expect(describe(service.chooseJavaHome(overridePath: nil) { nil }) == "found /jdk/project projectSetting")
        #expect(service.javaHomeURL()?.path == "/jdk/project")
        #expect(locator.discoverCalls == 0)
    }

    @Test
    @MainActor
    func automaticJavaChoiceWaitsForDiscoveryInsteadOfProbing() {
        let locator = ChoiceRuntimeLocator(environmentValues: [:], validJavaHomes: ["/jdk/detected"])
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        service.openProject(at: URL(fileURLWithPath: "/workspace", isDirectory: true))
        let detected = JavaRuntimeCandidate(homePath: "/jdk/detected", version: "21.0.4", vendor: "Temurin")

        #expect(service.chooseJavaHome(overridePath: nil) { nil } == nil)
        #expect(describe(service.chooseJavaHome(overridePath: nil) { [detected] }) == "found /jdk/detected detected")
        #expect(describe(service.chooseJavaHome(overridePath: nil) { [] }) == "notFound")
        #expect(locator.discoverCalls == 0)
    }

    @Test
    @MainActor
    func viewsShowingAutomaticRuntimesStartDiscoveryOnce() async {
        // The Run configuration editor can be opened without visiting the project
        // page, which used to be the only place that started discovery.
        let locator = ChoiceRuntimeLocator(environmentValues: [:], validJavaHomes: [])
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        await service.ensureRuntimesDiscovered()
        #expect(locator.discoverCalls == 0)

        service.openProject(at: URL(fileURLWithPath: "/workspace", isDirectory: true))
        #expect(!service.hasDiscoveredRuntimes)
        await service.ensureRuntimesDiscovered()
        #expect(service.hasDiscoveredRuntimes)
        await service.ensureRuntimesDiscovered()
        // One discovery in total: the environment report must reuse its result
        // instead of probing every JDK again on the main actor.
        #expect(locator.discoverCalls == 1)
        #expect(service.javaHomeURL() == nil)
        #expect(service.mavenJavaHomeURL() == nil)
        #expect(locator.discoverCalls == 1)
        service.closeProject()
        service.openProject(at: URL(fileURLWithPath: "/another-fixture-workspace", isDirectory: true))
        #expect(service.javaHomeURL() == nil)
        #expect(service.mavenJavaHomeURL() == nil)
        #expect(locator.discoverCalls == 2)
    }

    @Test
    @MainActor
    func mavenJavaChoiceReportsAFallbackInsteadOfHidingIt() {
        let locator = ChoiceRuntimeLocator(
            environmentValues: ["JAVA_HOME": "/jdk/env"],
            validJavaHomes: ["/jdk/env", "/jdk/maven"]
        )
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        service.openProject(at: URL(fileURLWithPath: "/workspace", isDirectory: true))

        #expect(describe(service.chooseMavenJavaHome(overridePath: nil) { [] }) == "found /jdk/env projectJDK")

        var settings = service.settings
        settings.mavenJavaHomePath = "/missing-maven-jdk"
        service.updateSettings(settings)
        // Launches keep falling back to the project JDK; Settings now says so.
        #expect(describe(service.chooseMavenJavaHome(overridePath: nil) { [] })
            == "fallback /missing-maven-jdk -> found /jdk/env javaHomeEnvironment")
        #expect(service.mavenJavaHomeURL()?.path == "/jdk/env")

        settings.mavenJavaHomePath = "/jdk/maven"
        service.updateSettings(settings)
        #expect(describe(service.chooseMavenJavaHome(overridePath: nil) { [] }) == "found /jdk/maven projectSetting")
        // A usable Maven JDK never walks the project chain, which may probe every JDK.
        #expect(locator.discoverCalls == 0)
    }

    @Test
    @MainActor
    func mavenChoiceNamesWrapperSystemAndInvalidSelections() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let wrapper = root.appendingPathComponent("mvnw")
        let system = URL(fileURLWithPath: "/usr/local/bin/mvn")
        let withWrapper = ProjectRuntimeService(
            runtimeLocator: ChoiceRuntimeLocator(executables: [wrapper.path], systemMaven: system),
            store: EmptyKeyValueStore()
        )
        #expect(describe(withWrapper.chooseMavenExecutable(at: root)) == "found /workspace/mvnw mavenWrapper")
        #expect(describe(withWrapper.chooseMavenExecutable(at: root, overridePath: "/missing")) == "invalid /missing")

        let systemOnly = ProjectRuntimeService(
            runtimeLocator: ChoiceRuntimeLocator(systemMaven: system),
            store: EmptyKeyValueStore()
        )
        #expect(describe(systemOnly.chooseMavenExecutable(at: root)) == "found /usr/local/bin/mvn systemMaven")
        let none = ProjectRuntimeService(runtimeLocator: ChoiceRuntimeLocator(), store: EmptyKeyValueStore())
        #expect(describe(none.chooseMavenExecutable(at: root)) == "notFound")
    }

    @Test
    @MainActor
    func runtimeSelectionsReadCurrentCanonicalDefaults() throws {
        let store = InMemoryProjectRuntimeSettingsStore()
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = ProjectRuntimeService(
            runtimeLocator: MavenOverrideRuntimeLocator(resolutions: [:]), settingsStore: store
        )
        service.openProject(at: root)
        let original = try store.load(at: root, migrateLegacy: false)
        var current = original.settings
        current.javaHomePath = "/fixture/run-jdk"
        current.mavenHomeSelection = .wrapper
        _ = try store.save(current, at: root, expecting: original)
        service.reloadSettings()
        #expect(service.settings.javaHomePath == "/fixture/run-jdk")
        #expect(service.settings.mavenHomeSelection == .wrapper)
        let saved = try store.load(at: root, migrateLegacy: false)
        _ = try store.save(ProjectRuntimeSettings(), at: root, expecting: saved)
        service.reloadSettings()
        #expect(service.settings.projectToolchainSelection() == ProjectToolchainSelection())
        store.failure = CocoaError(.fileReadCorruptFile)
        #expect(service.javaHomeURL() == nil)
        #expect(service.settingsError != nil)
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

    @Test(arguments: ["mvn", "mvnd"])
    @MainActor
    func macRuntimeDiscoveryDistinguishesMavenHomeFromExecutable(launcher: String) throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-maven-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let home = testRoot.appendingPathComponent("apache-maven", isDirectory: true)
        let homeExecutable = home.appendingPathComponent("bin/\(launcher)")
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

        // Exercise the real adapter through the service: POSIX execute permission
        // on a directory means traversal, not that it can be launched as Maven.
        let locator = MacRuntimeLocator()
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        #expect(!locator.isExecutable(at: home))
        #expect(locator.isExecutable(at: homeExecutable))
        #expect(service.mavenExecutable(at: testRoot, overridePath: home.path) == homeExecutable)
        #expect(service.mavenExecutable(at: testRoot, overridePath: "apache-maven") == homeExecutable)
        #expect(service.mavenExecutable(at: testRoot, overridePath: directExecutable.path) == directExecutable)
        #expect(service.mavenExecutable(at: testRoot, overridePath: invalidHome.path) == nil)

        if launcher == "mvnd" {
            let ordinaryMaven = home.appendingPathComponent("bin/mvn")
            try Data().write(to: ordinaryMaven)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ordinaryMaven.path)
            #expect(MacRuntimeDiscovery.mavenExecutable(forHomePath: home.path) == homeExecutable)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ordinaryMaven.path)
        }
        let binLink = testRoot.appendingPathComponent("bin-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: binLink, withDestinationURL: home.appendingPathComponent("bin"))
        #expect(service.mavenExecutable(at: testRoot, overridePath: binLink.path) == binLink.appendingPathComponent(launcher))
        let homeLink = testRoot.appendingPathComponent("maven-link", isDirectory: true)
        let executableLink = testRoot.appendingPathComponent("mvn-link")
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: home)
        try FileManager.default.createSymbolicLink(at: executableLink, withDestinationURL: homeExecutable)
        #expect(!locator.isExecutable(at: homeLink))
        #expect(service.mavenExecutable(at: testRoot, overridePath: homeLink.path) == homeLink.appendingPathComponent("bin/\(launcher)"))
        #expect(service.mavenExecutable(at: testRoot, overridePath: home.appendingPathComponent("bin").path) == homeExecutable)
        #expect(service.mavenExecutable(at: testRoot, overridePath: executableLink.path) == executableLink)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: homeExecutable.path)
        #expect(!locator.isExecutable(at: homeExecutable))
        #expect(service.mavenExecutable(at: testRoot, overridePath: home.path) == nil)
        #expect(service.mavenExecutable(at: testRoot, overridePath: homeExecutable.path) == nil)
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

/// Flattens a runtime choice for readable expectations.
private func describe(_ choice: RuntimeChoice?) -> String {
    switch choice {
    case nil: "detecting"
    case .found(let url, let source)?: "found \(url.path) \(source)"
    case .invalid(let path)?: "invalid \(path)"
    case .fallback(let path, let replacement)?: "fallback \(path) -> \(describe(replacement))"
    case .warning(let url, _, let message)?: "warning \(url.path) \(message)"
    case .unavailable(let message)?: "unavailable \(message)"
    case .notFound?: "notFound"
    }
}

/// Runtime locator with fixed answers that counts synchronous discoveries.
private final class ChoiceRuntimeLocator: RuntimeLocator, @unchecked Sendable {
    private let environmentValues: [String: String]
    private let validJavaHomes: Set<String>
    private let executables: Set<String>
    private let systemMaven: URL?
    private let runtimeCandidates: [JavaRuntimeCandidate]
    private(set) var discoverCalls = 0

    init(
        environmentValues: [String: String] = [:],
        validJavaHomes: Set<String> = [],
        executables: Set<String> = [],
        systemMaven: URL? = nil,
        runtimeCandidates: [JavaRuntimeCandidate] = []
    ) {
        self.environmentValues = environmentValues
        self.validJavaHomes = validJavaHomes
        self.executables = executables
        self.systemMaven = systemMaven
        self.runtimeCandidates = runtimeCandidates
    }

    func environment() -> [String: String] { environmentValues }
    func discover() -> RuntimeDiscoveryResult {
        discoverCalls += 1
        return RuntimeDiscoveryResult(javaRuntimes: runtimeCandidates, mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? {
        validJavaHomes.contains(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { executables.contains(url.standardizedFileURL.path) }
    func systemMavenExecutable() -> URL? { systemMaven }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}
