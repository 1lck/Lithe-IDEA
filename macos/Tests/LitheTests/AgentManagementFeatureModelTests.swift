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

    private func waitUntilIdle(_ feature: AgentManagementFeatureModel) async throws {
        // Bounded by wall-clock time, not by a yield count: under CI load a
        // fixed number of yields is not enough for the operation task to run.
        let deadline = ContinuousClock.now + .seconds(2)
        while feature.busyAgentID != nil || feature.phase == .checking, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(feature.busyAgentID == nil, "operation finished within the deadline")
    }
}

private actor TestAgentManagementService: AgentManagementService {
    private(set) var statusCalls = 0
    private(set) var uninstallCalls = 0
    private var statusFailure: String?
    private var installFailure: String?
    private var installGate: CheckedContinuation<Void, Never>?
    private var holdsInstall = false
    private var installStarted = false

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
        let deadline = ContinuousClock.now + .seconds(2)
        while !installStarted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(installStarted, "install started within the deadline")
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
        if holdsInstall {
            await withCheckedContinuation { installGate = $0 }
        }
        if let installFailure { throw Failure(message: installFailure) }
        return "1.0.0"
    }

    func uninstall(agentID: String, dataDirectory: URL) async throws {
        uninstallCalls += 1
    }

    func installCli(agentID: String, dataDirectory: URL) async throws -> String { "0.156.1" }
}
