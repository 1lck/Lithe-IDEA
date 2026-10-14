import Darwin
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Language extension process lifecycle")
@MainActor
struct LanguageExtensionProcessLifecycleTests {
    /// The declarative Go plugin's execution module is host-owned, so
    /// disabling it must still terminate the process it started.
    @Test
    func disablingGoExecutionTerminatesItsOwnedMacProcess() async throws {
        let sleepURL = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepURL.path) else { return }

        let processRegistry = ManagedProcessRegistry()
        let executionHost = MacLanguageExecutionHost(processRegistry: processRegistry)
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            ProcessLifecycleWorkspaceModule(manifest: workspace)
        })
        for factory in try DeclarativePluginTestSupport.officialFactories(
            "GoSupport",
            executionHost: executionHost
        ) {
            try runtime.register(factory)
        }
        try await runtime.setEnabled(true, for: .languageExecutionExtension("go"))

        let capability = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("go"))
                as? any LanguageRunExtensionProviding
        )
        let executionSession = capability.makeExecutionSession()
        try executionSession.start(LanguageExecutionProcessRequest(
            operationID: "go-process-lifecycle-test",
            executablePath: sleepURL.path,
            arguments: ["30"]
        ))
        let moduleID = ModuleID.languageExecutionExtension("go")
        let pid = try #require(processRegistry.processIDs(for: moduleID).first)
        #expect(Darwin.kill(pid, 0) == 0)

        try await runtime.setEnabled(false, for: moduleID)

        #expect(processRegistry.processIDs(for: moduleID).isEmpty)
        #expect(try runtime.snapshot(for: moduleID).state == .disabled)
        #expect(await processExited(pid))
    }

    /// gopls runs `go` itself, so the declared runtime must reach the
    /// launch configuration the host uses to build the server's PATH.
    @Test
    func goLanguageServerDeclaresTheGoRuntime() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            ProcessLifecycleWorkspaceModule(manifest: workspace)
        })
        for factory in try DeclarativePluginTestSupport.officialFactories(
            "GoSupport",
            executionHost: MacLanguageExecutionHost(processRegistry: ManagedProcessRegistry())
        ) {
            try runtime.register(factory)
        }
        let moduleID = ModuleID.languageServerExtension("go")
        try await runtime.setEnabled(true, for: moduleID)

        let provider = try #require(
            try await runtime.activateCapability(.languageServerExtension("go"))
                as? any LanguageServerExtensionProviding
        )

        #expect(provider.configuration.executableNames == ["gopls"])
        #expect(provider.configuration.validationArguments == ["version"])
        #expect(provider.configuration.runtimeTools == ["go"])
        try await runtime.setEnabled(false, for: moduleID)
    }

    /// Two plugins may ship a server with the same file name. Each must be
    /// pinned to the executable inside its own package, never found by name.
    @Test
    func packagedServersArePinnedToTheirOwnPackage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-packaged-servers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            ProcessLifecycleWorkspaceModule(manifest: workspace)
        })
        var packages: [String: URL] = [:]
        var installed: [InstalledPluginPackage] = []
        for language in ["alpha", "beta"] {
            let manifest = DeclarativePluginTestSupport.manifestObject(
                id: "dev.example.\(language)",
                version: PluginVersion(major: 1, minor: 0, patch: 0),
                languageID: language,
                packagedLauncher: "bin/language-server"
            )
            let packageURL = try DeclarativePluginTestSupport.writePackage(
                at: root.appendingPathComponent(language, isDirectory: true),
                manifest: manifest
            )
            let descriptor = try DeclarativePluginTestSupport.descriptor(manifest)
            packages[language] = packageURL
            installed.append(InstalledPluginPackage(
                descriptor: descriptor,
                installation: PluginInstallationRecord(
                    pluginID: descriptor.id,
                    activeVersion: descriptor.pluginManifest.version,
                    origin: .localDevelopment
                ),
                packageURL: packageURL
            ))
        }
        for factory in MacServiceContainer.declarativePluginFactories(
            installed,
            executionHost: MacLanguageExecutionHost(processRegistry: ManagedProcessRegistry()),
            planner: DeclarativePluginTestSupport.operations
        ) {
            try runtime.register(factory)
        }

        for language in ["alpha", "beta"] {
            let moduleID = ModuleID.languageServerExtension(language)
            try await runtime.setEnabled(true, for: moduleID)
            let provider = try #require(
                try await runtime.activateCapability(.languageServerExtension(language))
                    as? any LanguageServerExtensionProviding
            )
            let expected = try #require(packages[language])
                .appendingPathComponent("bin/language-server").standardizedFileURL
            #expect(provider.configuration.executableURL == expected)
            #expect(provider.configuration.executableNames == ["language-server"])
            try await runtime.setEnabled(false, for: moduleID)
        }
    }

    /// The module the host registers for a plugin API 2 package must carry
    /// everything a runtime launch needs: the runtime the plugin ships,
    /// pinned inside its own package, and the declaration the templates are
    /// expanded from.
    @Test
    func apiLevelTwoPackageConfiguresARuntimeLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-runtime-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/java-support.plugin.json")))
        let packageURL = root.appendingPathComponent("package", isDirectory: true)
        let installed = InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .localDevelopment
            ),
            packageURL: packageURL
        )
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            ProcessLifecycleWorkspaceModule(manifest: workspace)
        })
        for factory in MacServiceContainer.declarativePluginFactories(
            [installed],
            executionHost: MacLanguageExecutionHost(processRegistry: ManagedProcessRegistry()),
            planner: operations,
            launchResolver: MacPluginLanguageServerLaunchResolver(
                planner: operations,
                directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true)),
                settings: InMemoryPluginSettings()
            )
        ) {
            try runtime.register(factory)
        }
        let moduleID = ModuleID.languageServerExtension("java")
        try await runtime.setEnabled(true, for: moduleID)

        let provider = try #require(
            try await runtime.activateCapability(.languageServerExtension("java"))
                as? any LanguageServerExtensionProviding
        )
        let configuration = provider.configuration

        // The shipped runtime is the only executable; the tool name is for
        // display and is never looked up on the machine.
        #expect(configuration.executableNames == ["java"])
        #expect(configuration.executableURL == packageURL.appendingPathComponent(
            "runtime/\(MacPluginLanguageServerLaunchResolver.hostArchitecture)/bin/java"
        ).standardizedFileURL)
        #expect(configuration.launchSource?.packageURL == packageURL)
        #expect(configuration.launchSource?.languageID == "java")
        #expect(configuration.executableVersionRequirement == nil)
        // Activating the module must not create plugin state.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state").path))
        try await runtime.setEnabled(false, for: moduleID)
    }

    private func processExited(_ pid: Int32) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }
}

@MainActor
private final class ProcessLifecycleWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private var capability: ProcessLifecycleWorkspaceCapability?

    init(manifest: ModuleManifest) {
        self.manifest = manifest
    }

    func activate(context _: ModuleContext) async throws {
        capability = ProcessLifecycleWorkspaceCapability()
    }
    func prepareForSleep() async throws {}
    func sleep() async { capability = nil }
    func shutdown() async { capability = nil }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.workspaceFoundation: $0] } ?? [:]
    }
}

private final class ProcessLifecycleWorkspaceCapability {}
