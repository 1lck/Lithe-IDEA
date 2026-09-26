import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// Agent panel settings state, driven by a controllable management service.
@MainActor
struct AgentManagementFeatureModelTests {
    @Test
    func refreshReportsDetectedRuntimeAndCatalog() async throws {
        let service = TestAgentManagementService()
        let feature = AgentManagementFeatureModel(service: service, dataDirectory: URL(fileURLWithPath: "/tmp/lithe-agents"))
        #expect(feature.phase == .idle, "nothing runs before the page asks")
        await feature.refresh()
        #expect(feature.phase == .ready)
        #expect(feature.status?.agents.map(\.id) == ["codex-acp", "claude-acp"])
        #expect(feature.status?.agents.first?.isInstalled == true)
        #expect(feature.status?.agents.last?.issues.first?.contains("Node.js 22") == true)
        #expect(await service.statusCalls == 1)

        await service.failStatus("Rust Core is unavailable")
        await feature.refresh()
        #expect(feature.phase == .failed("Rust Core is unavailable"))
    }

    @Test
    func installRunsOneOperationAndRefreshesAfterward() async throws {
        let service = TestAgentManagementService()
        let feature = AgentManagementFeatureModel(service: service, dataDirectory: URL(fileURLWithPath: "/tmp/lithe-agents"))
        await service.holdInstall()
        defer { Task { await service.releaseInstall() } }
        feature.install("claude-acp")
        #expect(feature.busyAgentID == "claude-acp")
        feature.uninstall("codex-acp")
        try await service.waitUntilInstallStarted()
        #expect(await service.uninstallCalls == 0, "a second operation waits for the first")

        await service.failInstall("npm could not install the adapter")
        await service.releaseInstall()
        try await waitUntilIdle(feature)
        #expect(feature.errors["claude-acp"] == "npm could not install the adapter")
        #expect(feature.phase == .ready, "the page refreshes after an operation")
    }

    @Test
    func progressIsVisibleDuringInstallAndClearedAfterFailure() async throws {
        let service = TestAgentManagementService()
        let feature = AgentManagementFeatureModel(service: service, dataDirectory: URL(fileURLWithPath: "/tmp/lithe-agents"))
        await service.holdInstall()
        defer { Task { await service.releaseInstall() } }
        feature.install("codex-acp")
        try await service.waitUntilInstallStarted()
        let progress = AgentInstallProgress(stage: .downloading, downloadedBytes: 1_000_000,
                                           bytesPerSecond: 50_000, elapsedMilliseconds: 20_000, idleMilliseconds: 0)
        await service.emitProgress(progress)
        let reported = await awaitChange(on: feature) { feature.installProgress == progress }
        #expect(reported, "live counters must appear before npm completes")
        #expect(feature.busyAgentID == "codex-acp")
        await service.failInstall("Download failed")
        await service.releaseInstall()
        try await waitUntilIdle(feature)
        #expect(feature.installProgress == nil)
        #expect(feature.operationStartedAt == nil)
        #expect(feature.errors["codex-acp"] == "Download failed")
    }

    @Test
    func cliUpgradePublishesProgressAndClearsItAfterSuccess() async throws {
        let service = TestAgentManagementService()
        let feature = AgentManagementFeatureModel(service: service, dataDirectory: URL(fileURLWithPath: "/tmp/lithe-agents"))
        await service.holdInstall()
        defer { Task { await service.releaseInstall() } }
        feature.installCli("codex-acp")
        try await service.waitUntilInstallStarted()
        let progress = AgentInstallProgress(stage: .installing, downloadedBytes: 1_000_000,
                                           bytesPerSecond: 0, elapsedMilliseconds: 20_000, idleMilliseconds: 1000)
        await service.emitProgress(progress)
        let reported = await awaitChange(on: feature) { feature.installProgress == progress }
        #expect(reported, "CLI upgrades use the same live progress path as adapter installs")
        await service.releaseInstall()
        try await waitUntilIdle(feature)
        #expect(feature.installProgress == nil)
        #expect(feature.operationStartedAt == nil)
        #expect(feature.errors.isEmpty)
        #expect(feature.cliUpdates["codex-acp"] == AgentCliUpdateResult(cliVersion: "0.156.1"))
    }

    @Test
    func recoveredCliUpgradeKeepsWarningSeparateFromErrorsAndClearsItOnRetry() async throws {
        let service = TestAgentManagementService()
        let result = AgentCliUpdateResult(cliVersion: "0.157.1", updaterWarning: "Download failed, retry succeeded")
        await service.setCliResult(result)
        let feature = AgentManagementFeatureModel(service: service, dataDirectory: URL(fileURLWithPath: "/tmp/lithe-agents"))
        feature.installCli("codex-acp")
        try await waitUntilIdle(feature)
        #expect(feature.errors.isEmpty)
        #expect(feature.cliUpdates["codex-acp"] == result)
        await feature.refresh()
        #expect(feature.cliUpdates["codex-acp"] == result, "refresh preserves the completed operation's warning")
        await service.failInstall("Update did not change the CLI")
        feature.installCli("codex-acp")
        #expect(feature.cliUpdates["codex-acp"] == nil, "a new attempt clears the previous result")
        try await waitUntilIdle(feature)
        #expect(feature.errors["codex-acp"] == "Update did not change the CLI")
        #expect(feature.cliUpdates["codex-acp"] == nil)
    }

    @Test
    func cliUpdateContractDecodesBothCleanAndRecoveredOutcomes() throws {
        struct Responses: Decodable {
            let installCli: AgentCliUpdateResult
            let installCliRecovered: AgentCliUpdateResult
        }
        struct Fixture: Decodable { let responses: Responses }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/agent-management-v1.json"))
        let results = try JSONDecoder().decode(Fixture.self, from: data).responses
        #expect(results.installCli == AgentCliUpdateResult(cliVersion: "0.156.1"))
        #expect(results.installCliRecovered == AgentCliUpdateResult(cliVersion: "0.157.1", updaterWarning: "Download failed; retry completed"))
    }

    @Test
    func cancelStopsProgressAndClearsTheBusyState() async throws {
        let service = TestAgentManagementService()
        let feature = AgentManagementFeatureModel(service: service, dataDirectory: URL(fileURLWithPath: "/tmp/lithe-agents"))
        await service.holdInstall()
        defer { Task { await service.releaseInstall() } }
        feature.install("codex-acp")
        try await service.waitUntilInstallStarted()
        feature.cancelOperation()
        #expect(feature.isCancelling)
        await service.emitProgress(.init(stage: .downloading, downloadedBytes: 99,
                                        bytesPerSecond: 99, elapsedMilliseconds: 99, idleMilliseconds: 0))
        await service.releaseInstall()
        try await waitUntilIdle(feature)
        #expect(feature.installProgress == nil)
        #expect(!feature.isCancelling)
        #expect(feature.errors.isEmpty, "cancellation must not become an install error")
    }

    private func waitUntilIdle(_ feature: AgentManagementFeatureModel) async throws {
        // The operation task publishes through the feature model, so wait on
        // its publications with a local deadline instead of polling.
        let idle = await awaitChange(on: feature) {
            feature.busyAgentID == nil && feature.phase != .checking
        }
        #expect(idle, "operation finished within the deadline")
    }
}

private actor TestAgentManagementService: AgentManagementService {
    private(set) var statusCalls = 0
    private(set) var uninstallCalls = 0
    private var statusFailure: String?
    private var installFailure: String?
    private var cliResult = AgentCliUpdateResult(cliVersion: "0.156.1")
    func setCliResult(_ result: AgentCliUpdateResult) { cliResult = result }
    private var installGate: CheckedContinuation<Void, Never>?
    private var holdsInstall = false
    private var installStarted = false
    private var onProgress: (@Sendable (AgentInstallProgress) -> Void)?
    func emitProgress(_ progress: AgentInstallProgress) { onProgress?(progress) }
    func install(agentID: String, dataDirectory: URL,
                 onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> String {
        self.onProgress = onProgress
        return try await install(agentID: agentID, dataDirectory: dataDirectory)
    }
    /// Test waiting for `install` to be entered; resumed once, by the install
    /// or by the deadline.
    private var installStartedWaiter: CheckedContinuation<Bool, Never>?
    private var installStartedDeadline: DispatchWorkItem?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func failStatus(_ message: String) { statusFailure = message }
    func failInstall(_ message: String) { installFailure = message }
    func holdInstall() { holdsInstall = true }

    func releaseInstall() {
        holdsInstall = false
        installGate?.resume()
        installGate = nil
    }

    func waitUntilInstallStarted() async throws {
        if !installStarted {
            let started = await withCheckedContinuation { continuation in
                installStartedWaiter = continuation
                // Deadline arm: the install task resumes the waiter first in
                // the normal case; the timer only fails a stuck test.
                let deadline = DispatchWorkItem {
                    Task { await self.resumeInstallStartedWaiter(false) }
                }
                installStartedDeadline = deadline
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: deadline)
            }
            #expect(started, "install started within the deadline")
        }
    }

    private func resumeInstallStartedWaiter(_ value: Bool) {
        guard let waiter = installStartedWaiter else { return }
        installStartedWaiter = nil
        installStartedDeadline?.cancel()
        installStartedDeadline = nil
        waiter.resume(returning: value)
    }

    func status(dataDirectory: URL) async throws -> AgentManagementStatus {
        statusCalls += 1
        if let statusFailure { throw Failure(message: statusFailure) }
        return AgentManagementStatus(
            environment: AgentRuntimeEnvironment(
                node: AgentRuntimeTool(version: "20.11.0", path: "/opt/example/bin/node"),
                npm: AgentRuntimeTool(version: "10.2.4", path: "/opt/example/bin/npm"),
                usedLoginShell: true
            ),
            agents: [
                AgentCatalogStatus(
                    id: "codex-acp", name: "Codex", description: "", package: "@agentclientprotocol/codex-acp",
                    version: "1.13.1", installedVersion: "1.13.1", protocol: "responses",
                    minimumNodeMajor: 20, verified: true, issues: []
                ),
                AgentCatalogStatus(
                    id: "claude-acp", name: "Claude", description: "", package: "@agentclientprotocol/claude-agent-acp",
                    version: "0.81.2", installedVersion: nil, protocol: "anthropicMessages",
                    minimumNodeMajor: 22, verified: false, issues: ["Claude needs Node.js 22 or later; found 20.11.0."]
                )
            ]
        )
    }

    func install(agentID: String, dataDirectory: URL) async throws -> String {
        installStarted = true
        resumeInstallStartedWaiter(true)
        if holdsInstall {
            await withCheckedContinuation { installGate = $0 }
        }
        if let installFailure { throw Failure(message: installFailure) }
        return "1.0.0"
    }

    func uninstall(agentID: String, dataDirectory: URL) async throws {
        uninstallCalls += 1
    }

    func installCli(agentID: String, dataDirectory: URL) async throws -> AgentCliUpdateResult { cliResult }
    func installCli(agentID: String, dataDirectory: URL,
                    onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> AgentCliUpdateResult {
        _ = try await install(agentID: agentID, dataDirectory: dataDirectory, onProgress: onProgress)
        return cliResult
    }
}
