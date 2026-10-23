import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct McpToolsFeatureTests {
    @Test func explicitDetectionPublishesRealInventoryAndKeepsAgentsIndependent() async throws {
        let service = ToolStub()
        let feature = McpToolsFeatureModel(service: service)
        let row = ToolStub.row()
        #expect(service.probes == 0)
        let finished = TestGate()
        let observer = feature.$states.sink { state in if state[row.id]?.isReady == true { finished.open() } }
        defer { observer.cancel(); feature.leavePage() }
        let task = try #require(feature.detect(row))
        #expect(await finished.waitUntilOpen())
        await task.value
        #expect(service.probes == 1)
        #expect(feature.state(for: row).tools.map(\.name) == ["read"])
        feature.setEnabled(false, tool: "read", agent: .codex, row: row)
        #expect(feature.state(for: row).policies[.codex]?.tools.first?.enabled == false)
        #expect(feature.state(for: row).policies[.claudeCode]?.tools.first?.enabled == true)
        service.fails = true
        feature.setEnabled(false, tool: "read", agent: .claudeCode, row: row)
        #expect(feature.state(for: row).error != nil)
        #expect(feature.state(for: row).policies[.claudeCode]?.tools.first?.enabled == true)
    }

    @Test func leavingPageCancelsTheProbeAndRejectsItsLateInventory() async throws {
        let service = ToolStub(); service.waits = true
        let feature = McpToolsFeatureModel(service: service)
        let row = ToolStub.row()
        let task = try #require(feature.detect(row))
        defer { service.release.open(); task.cancel(); feature.leavePage() }
        #expect(await service.started.waitUntilOpen())
        feature.leavePage()
        service.release.open()
        await task.value
        #expect(feature.states.isEmpty)
        #expect(service.policies == 0)
    }

    @Test func registrationChangesReloadLocalPoliciesAndReleaseOldSnapshotsWithoutProbing() async throws {
        let service = ToolStub()
        let feature = McpToolsFeatureModel(service: service)
        defer { feature.leavePage() }
        let codex = ToolStub.row(agents: [.codex])
        let task = try #require(feature.detect(codex))
        await task.value
        let original = try #require(feature.state(for: codex).policies[.codex])
        let both = ToolStub.row()
        #expect(codex.id == both.id)
        feature.reconcile([both])
        let combined = feature.state(for: both)
        #expect(combined.isReady && combined.error == nil)
        #expect(Set(combined.policies.keys) == Set(McpAgent.allCases))
        #expect(combined.policies[.claudeCode]?.tools.first?.enabled == true)
        #expect(combined.policies[.claudeCode]?.tools.first?.editable == true)
        #expect(service.released.contains(original.id))
        let claude = try #require(combined.policies[.claudeCode])
        feature.reconcile([codex])
        #expect(Set(feature.state(for: codex).policies.keys) == [.codex])
        #expect(service.released.contains(claude.id))
        let calls = service.policies
        feature.reconcile([codex])
        #expect(service.policies == calls, "unchanged sources do not reload")
        #expect(service.probes == 1)
        #expect(feature.state(for: codex).tools.map(\.name) == ["read"])
    }

    @Test func registrationChangesDuringDetectionUseTheLatestSources() async throws {
        let service = ToolStub(); service.waits = true
        let feature = McpToolsFeatureModel(service: service)
        let task = try #require(feature.detect(ToolStub.row(agents: [.codex])))
        defer { service.release.open(); task.cancel(); feature.leavePage() }
        #expect(await service.started.waitUntilOpen())
        let both = ToolStub.row()
        feature.reconcile([both])
        service.release.open()
        await task.value
        #expect(Set(feature.state(for: both).policies.keys) == Set(McpAgent.allCases))
        #expect(feature.state(for: both).error == nil)
        #expect(service.probes == 1)
    }

    @Test func changedRegistrationPolicyFailuresAreVisibleAndKeepOtherAgentsUsable() async throws {
        let service = ToolStub()
        let feature = McpToolsFeatureModel(service: service)
        defer { feature.leavePage() }
        let codex = ToolStub.row(agents: [.codex])
        let task = try #require(feature.detect(codex))
        await task.value
        service.policyFailure = .claudeCode
        let both = ToolStub.row()
        feature.reconcile([both])
        #expect(feature.state(for: both).error != nil)
        #expect(feature.state(for: both).policies[.codex]?.tools.first?.enabled == true)
        #expect(feature.state(for: both).policies[.claudeCode] == nil)
        service.policyFailure = nil
        feature.loadPolicies(both)
        #expect(feature.state(for: both).error == nil)
        #expect(feature.state(for: both).policies[.claudeCode]?.tools.first?.editable == true)
        #expect(service.probes == 1)
    }

    @Test func nativeToolPanelFitsWideAndNarrowDarkAndLightLayouts() async throws {
        let service = ToolStub(); let feature = McpToolsFeatureModel(service: service); let row = ToolStub.row()
        let ready = TestGate()
        let observer = feature.$states.sink { states in if states[row.id]?.isReady == true { ready.open() } }
        defer { observer.cancel(); feature.leavePage() }
        let task = try #require(feature.detect(row)); #expect(await ready.waitUntilOpen()); await task.value
        let directory = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/test-stability/mcp-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width: CGFloat in [420, 760] {
            for dark in [false, true] {
                let view = McpToolsPanel(feature: feature, row: row).padding(16).frame(width: width)
                    .environment(\.colorScheme, dark ? .dark : .light).background(LitheTheme.settingsSurface)
                let host = NSHostingView(rootView: view); host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize; #expect(abs(size.width - width) < 1)
                host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("tools-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
    }
}

@MainActor
private final class ToolStub: McpToolsManaging {
    let started = TestGate(), release = TestGate()
    var waits = false, fails = false
    var probes = 0, policies = 0
    var policyFailure: McpAgent?
    var released: [UUID] = []
    func probe(_ definition: McpServerDefinition) async throws -> McpProbeResult {
        probes += 1; started.open()
        if waits { _ = await release.waitUntilOpen() }
        return McpProbeResult(tools: [McpToolDescription(name: "read", description: "Read the current library documentation.")])
    }
    func policy(for target: McpToolTarget, agent: McpAgent, tools: [String]) throws -> McpToolPolicySnapshot {
        policies += 1
        if policyFailure == agent { throw CocoaError(.fileReadUnknown) }
        return McpToolPolicySnapshot(id: UUID(), agent: agent, tools: tools.map { McpToolPermission(name: $0, enabled: true, editable: true) }, previousSourceHash: nil, sourceHash: nil)
    }
    func setEnabled(_ enabled: Bool, tool: String, target: McpToolTarget, snapshot: McpToolPolicySnapshot) throws -> McpToolPolicySnapshot {
        if fails { throw CocoaError(.fileWriteUnknown) }
        return McpToolPolicySnapshot(id: UUID(), agent: snapshot.agent, tools: [McpToolPermission(name: tool, enabled: enabled, editable: true)], previousSourceHash: nil, sourceHash: nil)
    }
    func release(_ snapshots: [McpToolPolicySnapshot]) { released += snapshots.map(\.id) }
    func commandLine(command: String, args: [String]) throws -> String { command }
    func parseCommandLine(_ line: String) throws -> (command: String, args: [String]) { (line, []) }
    static func row(agents: Set<McpAgent> = Set(McpAgent.allCases)) -> McpServerRow {
        let server = McpServerDefinition(name: "docs", transport: .http, command: nil, args: [], env: [], url: "https://example.invalid/mcp", headers: [], definitionHash: "fixture")
        let sources = McpAgent.allCases.filter { agents.contains($0) }.map { agent in McpServerSource(file: McpConfigurationFile(agent: agent, scope: .global,
            url: URL(fileURLWithPath: "/fixture/\(agent.rawValue)"), projectPath: nil), definitionHash: "fixture", isOwnedByLithe: false) }
        return McpServerRow(id: server.id, definition: server, sources: sources, hasDefinitionConflict: false)
    }
}
