import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

struct AgentSetupDiagnosticsTests {
    @Test
    func versionComparisonIgnoresPrefixesAndPreReleaseSuffixes() {
        #expect(AgentSetupDiagnostics.isVersion("0.156.1", atLeast: "0.156.0"))
        #expect(!AgentSetupDiagnostics.isVersion("0.144.1", atLeast: "0.156.0"))
        #expect(AgentSetupDiagnostics.isVersion("v2.1.280-beta", atLeast: "2.1.280"))
        #expect(AgentSetupDiagnostics.isVersion("2.2", atLeast: "2.1.280"))
        #expect(AgentSetupDiagnostics.majorVersion(of: "v24.14.0") == 24)
    }

    @Test
    func issuesMirrorTheRuntimeAndCliChecksTheHostPerforms() {
        let node = AgentRuntimeTool(version: "20.11.0", path: "/opt/node/bin/node")
        let agent = AgentCatalogStatus(
            id: "claude-acp", name: "Claude", description: "", package: "pkg", version: "1",
            installedVersion: nil, protocol: "anthropicMessages", minimumNodeMajor: 22, verified: false,
            cli: AgentCliStatus(
                name: "Claude Code", command: "claude", minimumVersion: "2.1.280", installHint: "npm i",
                detected: AgentRuntimeTool(version: "2.1.260", path: "/usr/local/bin/claude")
            ),
            issues: ["x", "y"]
        )
        let issues = AgentSetupDiagnostics.issues(
            for: agent,
            environment: AgentRuntimeEnvironment(node: node, npm: nil, usedLoginShell: true)
        )
        #expect(issues == [
            .nodeTooOld(minimumMajor: 22, found: "20.11.0"),
            .npmMissing,
            .cliTooOld(name: "Claude Code", minimumVersion: "2.1.280", found: "2.1.260")
        ])
        #expect(issues.allSatisfy { !$0.message.isEmpty })

        let healthy = AgentSetupDiagnostics.issues(
            for: agent,
            environment: AgentRuntimeEnvironment(
                node: AgentRuntimeTool(version: "22.0.0", path: ""),
                npm: AgentRuntimeTool(version: "10", path: ""),
                usedLoginShell: true
            )
        )
        #expect(healthy == [.cliTooOld(name: "Claude Code", minimumVersion: "2.1.280", found: "2.1.260")])
    }
}

extension AgentSetupDiagnosticsTests {
    @Test
    func preflightListsRuntimeCliAdapterAndProviderInAFixedOrder() {
        let agent = AgentCatalogStatus(
            id: "codex-acp", name: "Codex", description: "", package: "@agentclientprotocol/codex-acp",
            version: "1.13.1", installedVersion: "1.12.0", protocol: "responses", minimumNodeMajor: 20, verified: true,
            cli: AgentCliStatus(name: "Codex CLI", command: "codex", minimumVersion: "0.156.0",
                                installHint: "npm install -g @openai/codex", detected: nil),
            issues: []
        )
        let environment = AgentRuntimeEnvironment(
            node: AgentRuntimeTool(version: "24.14.0", path: "/opt/node/bin/node"),
            npm: AgentRuntimeTool(version: "11.9.0", path: "/opt/node/bin/npm"),
            usedLoginShell: true
        )
        let checks = AgentSetupDiagnostics.preflight(for: agent, environment: environment, hasProvider: false)
        #expect(checks.map(\.id) == ["node", "npm", "cli", "adapter", "provider"])
        #expect(checks.map(\.status) == [.pass, .pass, .fail, .warn, .fail])
        #expect(checks[2].fix == .installCli)
        #expect(checks[3].fix == .update)
        #expect(checks[4].fix == .fetchLocalConfiguration)
        #expect(AgentSetupDiagnostics.summary(of: checks) == .fail)

        // An install is offered only when Node.js and npm are usable; an
        // outdated CLI does not block installing the adapter.
        let blocked = AgentCatalogStatus(
            id: "claude-acp", name: "Claude", description: "", package: "pkg", version: "0.81.2",
            installedVersion: nil, protocol: "anthropicMessages", minimumNodeMajor: 22, verified: false,
            cli: nil, issues: ["Node too old"]
        )
        let oldNode = AgentRuntimeEnvironment(node: AgentRuntimeTool(version: "20.0.0", path: ""), npm: environment.npm, usedLoginShell: true)
        let blockedChecks = AgentSetupDiagnostics.preflight(for: blocked, environment: oldNode, hasProvider: true)
        #expect(blockedChecks.map(\.id) == ["node", "npm", "adapter", "provider"])
        #expect(blockedChecks.first { $0.id == "adapter" }?.fix == nil)
        #expect(!AgentSetupDiagnostics.canInstallAdapter(blockedChecks))
        #expect(AgentSetupDiagnostics.canInstallAdapter(checks))
        #expect(AgentSetupDiagnostics.summary(of: []) == nil)
    }
}
