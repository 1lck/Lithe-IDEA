import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

struct AgentSetupDiagnosticsTests {
    @Test(arguments: ["0.142.5", "0.157.1", "0.159.1"])
    func cliOwnershipControlsAutomaticUpdateAndProvidesManualGuidance(version: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/agent-management-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let installations = try #require(fixture["cliInstallations"] as? [String: Any])
        let environment = AgentRuntimeEnvironment(node: nil, npm: nil, usedLoginShell: true)
        for name in ["homebrew", "npm", "native", "unknown", "npmEnvironmentMismatch"] {
            let installation = try JSONDecoder().decode(AgentCliInstallation.self,
                from: JSONSerialization.data(withJSONObject: try #require(installations[name])))
            let agent = AgentCatalogStatus(id: "codex-acp", name: "Codex", description: "", package: "adapter",
                version: "1", installedVersion: "1", protocol: "responses", minimumNodeMajor: 20, verified: true,
                cli: .init(name: "Codex CLI", command: "codex", minimumVersion: "0.156.0", installHint: "npm install",
                           detected: .init(version: version, path: "/example/bin/codex"), installation: installation), issues: [])
            let check = try #require(AgentSetupDiagnostics.preflight(for: agent, environment: environment, hasProvider: true).first { $0.id == "cli" })
            let compatible = AgentSetupDiagnostics.isVersion(version, atLeast: "0.156.0")
            #expect(check.fix == (installation.canUpdate && installation.updateAvailable == true ? .updateCli : nil))
            #expect(check.status == (compatible ? .pass : .warn),
                    "Manual update availability must not change the compatibility result")
            #expect(check.message.contains(installation.source == .homebrew ? "Homebrew" :
                NSLocalizedString(installation.updateHint, comment: "")))
            if installation.source == .homebrew {
                #expect(check.message.contains("brew upgrade --cask codex"))
                #expect(!check.message.contains("npm install"))
            }
        }
    }

    @Test(arguments: [false, true, nil] as [Bool?], ["0.159.3", "0.142.5"])
    func everyCliOnlyOffersConfirmedUpdate(updateAvailable: Bool?, version: String) throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        for command in ["codex", "claude", "future-agent"] {
            for source in [AgentCliInstallation.Source.npm, .homebrew, .native, .unknown] {
                for language in ["en", "zh-Hans"] {
                    let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
                    let chinese = language == "zh-Hans"
                    let hint: String = switch source {
                    case .npm: "npm install -g @example/\(command)"
                    case .homebrew: "brew upgrade --cask \(command)"
                    case .native: "\(command) update"
                    default: "Update this CLI using its original installer, then check again."
                    }
                    let localizedHint = NSLocalizedString(hint, bundle: bundle, comment: "")
                    let installation = AgentCliInstallation(source: source, canUpdate: true,
                        updateHint: hint,
                        updateAvailable: updateAvailable, availableVersion: updateAvailable == true ? "0.160.0" : nil)
                    let agent = AgentCatalogStatus(id: "example-acp", name: "Example", description: "", package: "adapter",
                        version: "1", installedVersion: "1", protocol: "responses", minimumNodeMajor: 20, verified: true,
                        cli: .init(name: "Example CLI", command: command, minimumVersion: "0.156.0", installHint: "npm install",
                            detected: .init(version: version, path: "/example/bin/\(command)"), installation: installation), issues: [])
                    let environment = AgentRuntimeEnvironment(node: nil, npm: nil, usedLoginShell: true)
                    let check = try #require(AgentSetupDiagnostics.preflight(for: agent, environment: environment,
                        hasProvider: true, bundle: bundle).first { $0.id == "cli" })
                    let compatible = AgentSetupDiagnostics.isVersion(version, atLeast: "0.156.0")
                    #expect(check.status == (compatible ? .pass : .warn))
                    #expect(check.fix == (updateAvailable == true ? .updateCli : nil))
                    #expect(check.title.contains(version), "The collapsed row shows the installed version")
                    #expect(check.details.first { $0.id == "version" }?.label == (chinese ? "当前版本" : "Current version"))
                    if updateAvailable == true {
                        #expect(check.title.contains("\(version) → 0.160.0"))
                        #expect(check.details.first { $0.id == "available-version" }?.value == "0.160.0")
                        #expect(check.details.first { $0.id == "available-version" }?.label == (chinese ? "可更新至" : "Update to"))
                    } else {
                        #expect(check.details.first { $0.id == "available-version" } == nil)
                    }
                    if compatible && updateAvailable == false {
                        let expected = source == .homebrew
                            ? (chinese ? "当前 Homebrew 索引未发现更新。" : "No updates found in the local Homebrew index.")
                            : (chinese ? "已是最新版本。" : "Up to date.")
                        #expect(check.title.hasSuffix(expected))
                        #expect(!check.message.contains(localizedHint))
                        #expect(check.details.first { $0.id == "minimum-version" }?.value == "0.156.0")
                        if source == .homebrew {
                            #expect(!check.title.contains(chinese ? "已是最新版本" : "Up to date"))
                            #expect(check.message.contains(chinese
                                ? "请手动运行 `brew update`，然后重新检查更新。"
                                : "Run `brew update` manually, then check again for updates."))
                        }
                    }
                    if compatible && updateAvailable == nil {
                        #expect(check.message.contains(chinese ? "无法检查更新。" : "Could not check for updates."))
                        #expect(check.message.contains(localizedHint))
                    }
                    if !compatible { #expect(check.message.contains(localizedHint)) }
                }
            }
        }
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func allAdapterActionsUseConfirmedAvailability(updateAvailable: Bool?) throws {
        for id in ["codex-acp", "claude-acp", "future-acp"] {
            let agent = AgentCatalogStatus(id: id, name: id, description: "", package: "@example/adapter",
                version: "2.0.0", installedVersion: updateAvailable == true ? "1.0.0" : "3.0.0", protocol: "responses", minimumNodeMajor: 20,
                verified: true, issues: [], updateAvailable: updateAvailable)
            let tool = AgentRuntimeTool(version: "24.0.0", path: "/example/bin/tool")
            let check = try #require(AgentSetupDiagnostics.preflight(for: agent,
                environment: .init(node: tool, npm: tool, usedLoginShell: true), hasProvider: true)
                .first { $0.id == "adapter" })
            #expect(agent.needsUpdate == (updateAvailable == true))
            #expect(check.fix == (updateAvailable == true ? .update : nil))
        }
    }

    @Test(arguments: ["1.0.0", "10.0.0"])
    func cliProbeFailureRetainsItsReasonAndNeverOffersAnUpdate(version: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/agent/agent-management-v1.json"))) as? [String: Any])
        let installations = try #require(fixture["cliInstallations"] as? [String: Any])
        let installation = try JSONDecoder().decode(AgentCliInstallation.self,
            from: JSONSerialization.data(withJSONObject: try #require(installations["npmCheckFailed"])))
        for id in ["codex", "claude", "future-agent"] {
            let agent = AgentCatalogStatus(id: id, name: id, description: "", package: "adapter",
                version: "1.0.0", installedVersion: "1.0.0", protocol: "responses", minimumNodeMajor: 20,
                verified: true, cli: .init(name: id, command: id, minimumVersion: "9.0.0", installHint: "",
                    detected: .init(version: version, path: "/example/bin/cli"), installation: installation), issues: [])
            let check = try #require(AgentSetupDiagnostics.preflight(for: agent,
                environment: .init(node: nil, npm: nil, usedLoginShell: true), hasProvider: true)
                .first { $0.id == "cli" })
            #expect(check.fix == nil)
            #expect(check.status == .warn)
            #expect(check.guidance?.contains("connection refused") == true)
        }
    }

    @Test
    func unavailableTargetIsNeverGuessedFromTheInstalledVersion() throws {
        let agent = AgentCatalogStatus(id: "future-acp", name: "Future", description: "", package: "adapter",
            version: "1.0.0", installedVersion: "1.0.0", protocol: "responses", minimumNodeMajor: 20,
            verified: true, cli: .init(name: "Future CLI", command: "future", minimumVersion: "1.0.0", installHint: "",
                detected: .init(version: "2.0.0", path: "/example/bin/future"),
                installation: .init(source: .homebrew, canUpdate: true, updateHint: "", updateAvailable: true)), issues: [])
        let check = try #require(AgentSetupDiagnostics.preflight(for: agent,
            environment: .init(node: nil, npm: nil, usedLoginShell: true), hasProvider: true)
            .first { $0.id == "cli" })
        #expect(check.details.first { $0.id == "available-version" }?.value == String(localized: "Could not confirm"))
    }

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
            issues: [], updateAvailable: true
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
