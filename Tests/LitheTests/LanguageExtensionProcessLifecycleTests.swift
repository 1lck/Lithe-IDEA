import Darwin
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheGoSupportModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Language extension process lifecycle")
@MainActor
struct LanguageExtensionProcessLifecycleTests {
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
        try runtime.register(ModuleFactory(manifest: GoExecutionModule.moduleManifest) {
            GoExecutionModule(executionHost: executionHost)
        })

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
        let moduleID = GoExecutionModule.moduleManifest.id
        let pid = try #require(processRegistry.processIDs(for: moduleID).first)
        #expect(Darwin.kill(pid, 0) == 0)

        try await runtime.setEnabled(false, for: moduleID)

        #expect(processRegistry.processIDs(for: moduleID).isEmpty)
        #expect(try runtime.snapshot(for: moduleID).state == .disabled)
        #expect(await processExited(pid))
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
