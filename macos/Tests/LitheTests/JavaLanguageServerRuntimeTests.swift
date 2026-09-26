import Foundation
import CryptoKit
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Java language server runtime")
struct JavaLanguageServerRuntimeTests {
    @Test
    func projectPreparationFixtureDecodesEverySharedStage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let snapshots: [ProjectPreparationSnapshot] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/lsp/project-preparation-v1.json")))
        #expect(fixture.snapshots.map(\.phase) == ["starting", "importing", "configuring", "building", "ready", "configuring", "stopped"])
        #expect(fixture.snapshots.filter { !$0.blocksRun }.map(\.phase) == ["ready", "configuring"])
        #expect(fixture.snapshots.filter { $0.status == "failed" }.allSatisfy { !$0.blocksRun })
    }

    @Test
    func mavenRuntimeFixtureDecodesStructuredTaskAndDistinctProjects() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable {
            let events: [RustCoreBridge.LspRuntimeEventPayload]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/lsp/maven-profile-events-v1.json")))
        #expect(fixture.events.first?.mavenProfileTask == "running")
        #expect(fixture.events.last?.mavenProfileTask == "partiallySucceeded")
        let results = fixture.events.compactMap(\.mavenProfileProject)
        #expect(results.map(\.status) == ["running", "failed", "succeeded"])
        #expect(Set(results.map(\.projectUri)).count == 2)
    }

    @Test
    func coreInitializationTimeoutCodesRemainUserVisibleTimeouts() {
        #expect(LanguageServerSessionFailure(code: "timed_out").isTimedOut)
        #expect(LanguageServerSessionFailure(code: "initializeTimeout").isTimedOut)
        #expect(LanguageServerSessionFailure(code: "serviceReadyTimeout").isTimedOut)
        #expect(!LanguageServerSessionFailure(code: "serverExited").isTimedOut)
    }

    @Test
    func macRuntimeLocatorSelectsJdkForRequestedProcessArchitecture() throws {
        let fileManager = FileManager.default
        let resources = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-jdk-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: resources) }
        for directory in ["jdk-arm64", "jdk-x86_64"] {
            let java = resources
                .appendingPathComponent("LanguageServers/\(directory)/bin/java")
            try fileManager.createDirectory(
                at: java.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: java)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        }

        let armHome = MacRuntimeLocator(
            resourceURL: resources,
            processArchitecture: .arm64
        ).bundledJdkHome()
        let intelHome = MacRuntimeLocator(
            resourceURL: resources,
            processArchitecture: .x86_64
        ).bundledJdkHome()

        #expect(armHome?.lastPathComponent == "jdk-arm64")
        #expect(intelHome?.lastPathComponent == "jdk-x86_64")
    }

    @Test
    func macRuntimeLocatorDoesNotUseLegacyJdkForIncompleteUniversalLayout() throws {
        let fileManager = FileManager.default
        let resources = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-jdk-incomplete-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: resources) }
        let languageServers = resources.appendingPathComponent("LanguageServers", isDirectory: true)
        let legacyJava = languageServers.appendingPathComponent("jdk/bin/java")
        try fileManager.createDirectory(
            at: legacyJava.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: legacyJava)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyJava.path)
        try fileManager.createDirectory(
            at: languageServers.appendingPathComponent("jdk-x86_64", isDirectory: true),
            withIntermediateDirectories: true
        )

        let home = MacRuntimeLocator(
            resourceURL: resources,
            processArchitecture: .arm64
        ).bundledJdkHome()

        #expect(home == nil)
    }

    @Test
    func macRuntimeLocatorSupportsSingleArchitectureJdkLayout() throws {
        let fileManager = FileManager.default
        let resources = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-jdk-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: resources) }
        let java = resources.appendingPathComponent("LanguageServers/jdk/bin/java")
        try fileManager.createDirectory(
            at: java.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: java)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)

        let home = MacRuntimeLocator(resourceURL: resources).bundledJdkHome()

        #expect(home?.lastPathComponent == "jdk")
    }

    @Test
    func macJdtlsResolverSelectsDirectLaunchResourcesDeterministically() throws {
        let fileManager = FileManager.default
        let appRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-jdtls-resolver-\(UUID().uuidString).app", isDirectory: true)
        let root = appRoot.appendingPathComponent(
            "Contents/Resources/LanguageServers/jdtls",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: appRoot) }
        for directory in [
            "bin", "plugins", "config_mac", "config_mac_arm", "lombok", "java-debug",
            "java-test/extensions", "java-test/runner"
        ] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let executable = root.appendingPathComponent("bin/jdtls")
        let firstLauncher = root.appendingPathComponent(
            "plugins/org.eclipse.equinox.launcher_1.0.0.jar"
        )
        for file in [
            executable,
            firstLauncher,
            root.appendingPathComponent("plugins/org.eclipse.equinox.launcher_2.0.0.jar"),
            root.appendingPathComponent("lombok/lombok.jar"),
            root.appendingPathComponent("java-debug/com.microsoft.java.debug.plugin-0.53.1.jar"),
            root.appendingPathComponent("java-test/extensions/org.opentest4j_1.2.0.jar"),
            root.appendingPathComponent("java-test/extensions/com.microsoft.java.test.plugin-0.42.0.jar"),
            root.appendingPathComponent(
                "java-test/runner/com.microsoft.java.test.runner-jar-with-dependencies.jar"
            ),
            root.appendingPathComponent("config_mac/config.ini"),
            root.appendingPathComponent("config_mac_arm/config.ini")
        ] {
            try Data().write(to: file)
        }
        let configurationCache = appRoot.deletingLastPathComponent()
            .appendingPathComponent("lithe-jdtls-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: configurationCache) }
        try Data().write(to: appRoot.appendingPathComponent("Contents/Resources/peer-resource"))
        let bundleSnapshotBeforeLaunch = try runtimeBundleSnapshot(at: appRoot)
        let resolver = MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: root,
            bundledAppRootURL: appRoot,
            configurationCacheDirectoryURL: configurationCache
        )

        guard case .direct(let resources) = resolver.resolve(for: executable) else {
            Issue.record("Expected complete bundled JDTLS resources to use direct Java launch")
            return
        }
        #expect(resources.launcherJarURL == firstLauncher.standardizedFileURL)
        #if arch(arm64)
        #expect(resources.configurationDirectoryURL.lastPathComponent.hasPrefix("config_mac_arm-"))
        #else
        #expect(resources.configurationDirectoryURL.lastPathComponent.hasPrefix("config_mac-"))
        #endif
        #expect(resources.configurationDirectoryURL.path.hasPrefix(configurationCache.path + "/"))
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent("config_mac_arm/config.ini").path))
        let generatedState = resources.configurationDirectoryURL
            .appendingPathComponent("org.eclipse.core.runtime", isDirectory: true)
        try fileManager.createDirectory(at: generatedState, withIntermediateDirectories: true)
        #expect(!fileManager.fileExists(
            atPath: root.appendingPathComponent("config_mac_arm/org.eclipse.core.runtime").path
        ))
        #expect(try runtimeBundleSnapshot(at: appRoot) == bundleSnapshotBeforeLaunch)
        #expect(resources.lombokAgentURL.lastPathComponent == "lombok.jar")
        #expect(
            resources.javaDebugBundleURL?.lastPathComponent
                == "com.microsoft.java.debug.plugin-0.53.1.jar"
        )
        #expect(resources.javaExtensionBundleURLs.map(\.lastPathComponent) == [
            "com.microsoft.java.debug.plugin-0.53.1.jar",
            "com.microsoft.java.test.plugin-0.42.0.jar",
            "org.opentest4j_1.2.0.jar"
        ])
        #expect(
            resources.javaTestRunnerURL?.lastPathComponent
                == "com.microsoft.java.test.runner-jar-with-dependencies.jar"
        )

        let symlinkRoot = appRoot.deletingLastPathComponent()
            .appendingPathComponent("lithe-jdtls-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: symlinkRoot) }
        try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: root)
        let symlinkResolver = MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: root,
            bundledAppRootURL: appRoot,
            configurationCacheDirectoryURL: configurationCache
        )
        guard case .direct(let symlinkResources) = symlinkResolver.resolve(
            for: symlinkRoot.appendingPathComponent("bin/jdtls")
        ) else {
            Issue.record("Expected a symlink to bundled JDTLS to keep using the external cache")
            return
        }
        #expect(symlinkResources.configurationDirectoryURL.path.hasPrefix(configurationCache.path + "/"))

        let invalidCacheResolver = MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: root,
            bundledAppRootURL: appRoot,
            configurationCacheDirectoryURL: appRoot.appendingPathComponent("Contents/Resources")
        )
        guard case .unavailable = invalidCacheResolver.resolve(for: executable) else {
            Issue.record("Expected a cache path inside the app bundle to be rejected")
            return
        }
        #expect(try runtimeBundleSnapshot(at: appRoot) == bundleSnapshotBeforeLaunch)

        let damagedCacheURL = resources.configurationDirectoryURL
        try fileManager.removeItem(at: damagedCacheURL.appendingPathComponent("config.ini"))
        let damagedResolver = MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: root,
            bundledAppRootURL: appRoot,
            configurationCacheDirectoryURL: configurationCache
        )
        guard case .unavailable = damagedResolver.resolve(for: executable) else {
            Issue.record("Expected an incomplete existing cache to be rejected")
            return
        }

        let symlinkedCache = configurationCache
            .deletingLastPathComponent()
            .appendingPathComponent("lithe-jdtls-cache-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: symlinkedCache) }
        try fileManager.createDirectory(at: symlinkedCache, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: symlinkedCache.appendingPathComponent("jdtls"),
            withDestinationURL: root
        )
        let symlinkedCacheResolver = MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: root,
            bundledAppRootURL: appRoot,
            configurationCacheDirectoryURL: symlinkedCache
        )
        guard case .unavailable = symlinkedCacheResolver.resolve(for: executable) else {
            Issue.record("Expected a cache subdirectory symlink into the app bundle to be rejected")
            return
        }
        #expect(try runtimeBundleSnapshot(at: appRoot) == bundleSnapshotBeforeLaunch)
    }

    private func runtimeBundleSnapshot(at root: URL) throws -> [String: String] {
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let urls = try #require(fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ))
        var snapshot: [String: String] = [:]
        for case let url as URL in urls {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            snapshot[relativePath] = digest
        }
        return snapshot
    }

    @Test
    func macJdtlsResolverFailsBundledButKeepsExternalWrapperFallback() {
        let bundledRoot = URL(fileURLWithPath: "/bundled/jdtls", isDirectory: true)
        let resolver = MacJDTLSLaunchResourceResolver(bundledJdtlsRootURL: bundledRoot)

        guard case .unavailable(let message) = resolver.resolve(
            for: bundledRoot.appendingPathComponent("bin/jdtls")
        ) else {
            Issue.record("Expected incomplete bundled JDTLS resources to fail")
            return
        }
        #expect(message.contains("Reinstall Lithe"))
        guard case .wrapperFallback = resolver.resolve(
            for: URL(fileURLWithPath: "/external/jdtls/bin/jdtls")
        ) else {
            Issue.record("Expected an external legacy JDTLS launcher to remain compatible")
            return
        }
    }

    @Test
    func macJdtlsResolverRejectsConfigurationForTheWrongArchitecture() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-jdtls-architecture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        for directory in [
            "bin", "plugins", "lombok", "java-debug", "java-test/extensions", "java-test/runner"
        ] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        #if arch(arm64)
        let wrongConfigurationName = "config_mac"
        #elseif arch(x86_64)
        let wrongConfigurationName = "config_mac_arm"
        #else
        Issue.record("Unsupported macOS test architecture")
        return
        #endif
        try fileManager.createDirectory(
            at: root.appendingPathComponent(wrongConfigurationName, isDirectory: true),
            withIntermediateDirectories: true
        )
        for file in [
            root.appendingPathComponent("bin/jdtls"),
            root.appendingPathComponent("plugins/org.eclipse.equinox.launcher_1.0.0.jar"),
            root.appendingPathComponent("lombok/lombok.jar"),
            root.appendingPathComponent("java-debug/com.microsoft.java.debug.plugin-0.53.1.jar"),
            root.appendingPathComponent("java-test/extensions/com.microsoft.java.test.plugin-0.42.0.jar"),
            root.appendingPathComponent(
                "java-test/runner/com.microsoft.java.test.runner-jar-with-dependencies.jar"
            )
        ] {
            try Data().write(to: file)
        }
        let resolver = MacJDTLSLaunchResourceResolver(bundledJdtlsRootURL: root)

        guard case .unavailable = resolver.resolve(
            for: root.appendingPathComponent("bin/jdtls")
        ) else {
            Issue.record("Expected bundled JDTLS with the wrong architecture configuration to fail")
            return
        }
    }

    @Test
    func parsesModernAndLegacyJavaVersions() {
        #expect(javaRuntime("/jdk-17", "17.0.18").majorVersion == 17)
        #expect(javaRuntime("/jdk-21", "21-ea").majorVersion == 21)
        #expect(javaRuntime("/jdk-8", "1.8.0_442").majorVersion == 8)
        #expect(javaRuntime("/jdk-unknown", "unknown").majorVersion == nil)
    }

    @Test
    func jdtlsCompatibilityRequiresJava21OrNewer() {
        #expect(!javaRuntime("/jdk-11", "11.0.26").supportsJDTLS)
        #expect(!javaRuntime("/jdk-17", "17.0.18").supportsJDTLS)
        #expect(javaRuntime("/jdk-21", "21.0.10").supportsJDTLS)
        #expect(javaRuntime("/jdk-25", "25.0.4").supportsJDTLS)
    }

    @Test
    @MainActor
    func bundledJdtlsRuntimeIgnoresProjectRunJDK() async {
        let projectRuntime = javaRuntime("/project/jdk-11", "11.0.26")
        let jdtlsRuntime = javaRuntime("/language-server/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [projectRuntime, jdtlsRuntime],
                bundledHomePath: jdtlsRuntime.homePath
            ),
            store: JavaLanguageServerTestStore()
        )

        #expect(
            service.javaHomeURL(overridePath: projectRuntime.homePath)?.path
                == projectRuntime.homePath
        )
        #expect(service.javaLanguageServerExecutableURL() == nil)
        await service.prepareJavaLanguageServerRuntime()
        #expect(
            service.javaLanguageServerExecutableURL()?.path
                == "/language-server/jdk-21/bin/java"
        )
    }

    @Test
    @MainActor
    func bundledJdtlsRuntimeRejectsNonJdk21() async {
        let unsupportedRuntime = javaRuntime("/jdk-17", "17.0.18")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [unsupportedRuntime],
                bundledHomePath: unsupportedRuntime.homePath
            ),
            store: JavaLanguageServerTestStore()
        )

        let result = await service.prepareJavaLanguageServerRuntime()

        #expect(service.javaLanguageServerExecutableURL() == nil)
        guard case .failed(let message) = result else {
            Issue.record("Expected the bundled JDK version check to fail")
            return
        }
        #expect(message.contains("JDK 21"))
    }

    @Test
    @MainActor
    func missingBundledJdtlsRuntimeDoesNotUseDiscoveredJDK() async {
        let discoveredRuntime = javaRuntime("/system/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [discoveredRuntime],
                bundledHomePath: nil
            ),
            store: JavaLanguageServerTestStore()
        )

        let result = await service.prepareJavaLanguageServerRuntime()

        #expect(service.javaLanguageServerExecutableURL() == nil)
        guard case .failed(let message) = result else {
            Issue.record("Expected a missing bundled JDK failure")
            return
        }
        #expect(message.contains("bundled Temurin JDK 21"))
    }

    @Test
    @MainActor
    func preparationOwnerCancelsAndReleasesItsTask() {
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            operationID: UUID()
        )
        let task = Task { @MainActor () -> Void in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
        }
        owner.task = task

        owner.cancel()

        #expect(task.isCancelled)
        #expect(owner.task == nil)
    }

    @Test
    @MainActor
    func preparationCoordinatorReplacesThePreviousTask() {
        let coordinator = JavaLanguageServerPreparationCoordinator()
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            operationID: UUID()
        )
        coordinator.schedule(for: owner) {}
        let previous = owner.task
        coordinator.schedule(for: owner) {}

        #expect(previous?.isCancelled == true)
        #expect(owner.task != nil)
        coordinator.cancel(owner)
        #expect(owner.task == nil)
    }

    @Test
    @MainActor
    func workspaceStateKeepsPreparationOperationIdentity() {
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let operationID = UUID()
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: workspaceURL,
            operationID: operationID
        )
        let state = JavaLanguageServerWorkspaceState.preparing(owner: owner)

        #expect(state.operationID == operationID)
        #expect(state.belongs(to: workspaceURL))
        #expect(!state.belongs(to: URL(fileURLWithPath: "/other", isDirectory: true)))
    }

    private func javaRuntime(_ homePath: String, _ version: String) -> JavaRuntimeCandidate {
        JavaRuntimeCandidate(homePath: homePath, version: version, vendor: "Test JDK")
    }
}

private struct JavaLanguageServerTestRuntimeLocator: RuntimeLocator {
    let runtimes: [JavaRuntimeCandidate]
    let bundledHomePath: String?

    init(
        runtimes: [JavaRuntimeCandidate],
        bundledHomePath: String? = nil
    ) {
        self.runtimes = runtimes
        self.bundledHomePath = bundledHomePath
    }

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        return RuntimeDiscoveryResult(javaRuntimes: runtimes, mavenRuntimes: [])
    }

    func validJavaHome(path: String) -> URL? {
        runtimes.contains(where: { $0.homePath == path })
            ? URL(fileURLWithPath: path, isDirectory: true)
            : nil
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        runtimes.first(where: { $0.homePath == homeURL.standardizedFileURL.path })
    }

    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func bundledJdkHome() -> URL? {
        bundledHomePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

private struct JavaLanguageServerTestStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
