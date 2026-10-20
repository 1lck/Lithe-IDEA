import Foundation
import LitheCoreContracts

/// Localized, user-facing reasons an agent cannot be installed or started,
/// derived from the structured status so the panel can show them in the
/// interface language. Rust's `issues` list stays the machine truth for
/// whether an install is allowed.
enum AgentSetupDiagnostics {
    enum Issue: Equatable {
        case nodeMissing(minimumMajor: Int)
        case nodeTooOld(minimumMajor: Int, found: String)
        case npmMissing
        case cliMissing(name: String, installHint: String)
        case cliTooOld(name: String, minimumVersion: String, found: String)

        var message: String { message(bundle: .main) }

        func message(bundle: Bundle) -> String {
            switch self {
            case .nodeMissing(let minimum):
                String(format: String(localized: "Node.js %lld or later was not found. Install it, then check again.", bundle: bundle), minimum)
            case .nodeTooOld(let minimum, let found):
                String(format: String(localized: "Node.js %lld or later is required; found %@.", bundle: bundle), minimum, found)
            case .npmMissing:
                String(localized: "npm was not found. It is normally installed with Node.js.", bundle: bundle)
            case .cliMissing(let name, let hint):
                String(format: String(localized: "%@ was not found. Install it (for example `%@`), then check again.", bundle: bundle), name, hint)
            case .cliTooOld(let name, let minimum, let found):
                String(format: String(localized: "%@ %@ or later is required; found %@. Update it, then check again.", bundle: bundle), name, minimum, found)
            }
        }
    }

    static func issues(for agent: AgentCatalogStatus, environment: AgentRuntimeEnvironment) -> [Issue] {
        var issues: [Issue] = []
        switch environment.node.map({ majorVersion(of: $0.version) }) {
        case nil:
            issues.append(.nodeMissing(minimumMajor: agent.minimumNodeMajor))
        case let major? where major < agent.minimumNodeMajor:
            issues.append(.nodeTooOld(minimumMajor: agent.minimumNodeMajor, found: environment.node?.version ?? ""))
        default:
            break
        }
        if environment.npm == nil {
            issues.append(.npmMissing)
        }
        if let cli = agent.cli {
            if let detected = cli.detected {
                if !isVersion(detected.version, atLeast: cli.minimumVersion) {
                    issues.append(.cliTooOld(name: cli.name, minimumVersion: cli.minimumVersion, found: detected.version))
                }
            } else {
                issues.append(.cliMissing(name: cli.name, installHint: cli.installHint))
            }
        }
        return issues
    }

    /// Leading integer of a version such as `v20.11.0` or `20`.
    static func majorVersion(of version: String) -> Int {
        let digits = version.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    /// Numeric dotted comparison; missing components count as zero, and a
    /// pre-release suffix is ignored.
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        let lhs = components(of: version)
        let rhs = components(of: minimum)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    private static func components(of version: String) -> [Int] {
        version.drop { !$0.isNumber }
            .prefix { $0.isNumber || $0 == "." }
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

/// One row of the per-agent preflight checklist shown in the Agent panel
/// settings, mirroring the structured status the host reports.
struct AgentPreflightCheck: Identifiable, Equatable {
    enum Status: Int, Comparable {
        case pass
        case warn
        case fail

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One labelled fact from a passing check, such as the detected version or
    /// the executable path. The settings page draws these as rows instead of
    /// one long `version · path` string.
    struct Detail: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }

    /// What the user can do about a failing check, if anything.
    enum Fix: Equatable {
        case install
        case update
        case installCli
        case updateCli
        case fetchLocalConfiguration
    }

    let id: String
    let title: String
    let status: Status
    let message: String
    var fix: Fix?
    /// Structured facts to show above `guidance`; `message` remains the
    /// plain-text source used by diagnostics and tests.
    var details: [Detail] = []
    /// Extra guidance that is not a single labelled fact, such as an update
    /// hint or an explanation of a failed check.
    var guidance: String?
}

extension AgentSetupDiagnostics {
    /// Preflight rows for `agent`: runtime, the user's CLI, the adapter
    /// install, and the provider assignment. Order is fixed so the list does
    /// not jump between refreshes.
    static func preflight(
        for agent: AgentCatalogStatus,
        environment: AgentRuntimeEnvironment,
        hasProvider: Bool,
        bundle: Bundle = .main
    ) -> [AgentPreflightCheck] {
        var checks: [AgentPreflightCheck] = []

        let nodeTitle = String(format: String(localized: "Node.js %lld or later", bundle: bundle), agent.minimumNodeMajor)
        switch environment.node {
        case nil:
            checks.append(.init(id: "node", title: nodeTitle, status: .fail,
                                message: Issue.nodeMissing(minimumMajor: agent.minimumNodeMajor).message(bundle: bundle)))
        case let node? where majorVersion(of: node.version) < agent.minimumNodeMajor:
            checks.append(.init(id: "node", title: nodeTitle, status: .fail,
                                message: Issue.nodeTooOld(minimumMajor: agent.minimumNodeMajor, found: node.version).message(bundle: bundle)))
        case let node?:
            checks.append(.init(id: "node", title: nodeTitle, status: .pass, message: "\(node.version) · \(node.path)",
                                details: [
                                    .init(id: "version", label: String(localized: "Version", bundle: bundle), value: node.version),
                                    .init(id: "path", label: String(localized: "Path", bundle: bundle), value: node.path)
                                ]))
        }

        if let npm = environment.npm {
            checks.append(.init(id: "npm", title: "npm", status: .pass, message: "\(npm.version) · \(npm.path)",
                                details: [
                                    .init(id: "version", label: String(localized: "Version", bundle: bundle), value: npm.version),
                                    .init(id: "path", label: String(localized: "Path", bundle: bundle), value: npm.path)
                                ]))
        } else {
            checks.append(.init(id: "npm", title: "npm", status: .fail, message: Issue.npmMissing.message(bundle: bundle)))
        }

        if let cli = agent.cli {
            let title = String(format: String(localized: "%@ %@ or later", bundle: bundle), cli.name, cli.minimumVersion)
            let canUpdate = cli.installation?.canUpdate ?? true
            if let detected = cli.detected {
                // Compatibility does not mean the CLI has the latest model catalog.
                let compatible = isVersion(detected.version, atLeast: cli.minimumVersion)
                let updateAvailable = cli.installation?.updateAvailable == true
                var statusTitle = "\(cli.name) · \(detected.version)"
                if updateAvailable {
                    statusTitle += " → " + (cli.installation?.availableVersion ?? String(localized: "Could not confirm", bundle: bundle))
                }
                var details: [AgentPreflightCheck.Detail] = [
                    .init(id: "version", label: String(localized: "Current version", bundle: bundle), value: detected.version),
                    .init(id: "path", label: String(localized: "Path", bundle: bundle), value: detected.path),
                ]
                details.insert(.init(id: "minimum-version", label: String(localized: "Minimum version", bundle: bundle), value: cli.minimumVersion), at: 1)
                if updateAvailable {
                    details.insert(.init(id: "available-version", label: String(localized: "Update to", bundle: bundle),
                        value: cli.installation?.availableVersion ?? String(localized: "Could not confirm", bundle: bundle)), at: 1)
                }
                var guidance: [String] = []
                var messageLines: [String] = []
                if !compatible {
                    messageLines.append(Issue.cliTooOld(name: cli.name, minimumVersion: cli.minimumVersion, found: detected.version).message(bundle: bundle))
                }
                messageLines.append("\(detected.version) · \(detected.path)")
                if compatible {
                    switch cli.installation?.updateAvailable {
                    case false?:
                        if cli.installation?.source == .homebrew {
                            statusTitle += " · " + String(localized: "No updates found in the local Homebrew index.", bundle: bundle)
                            let manualUpdate = String(localized: "Run `brew update` manually, then check again for updates.", bundle: bundle)
                            guidance.append(manualUpdate)
                            messageLines.append(manualUpdate)
                        } else {
                            statusTitle += " · " + String(localized: "Up to date.", bundle: bundle)
                        }
                    case nil:
                        let couldNotCheck = String(localized: "Could not check for updates.", bundle: bundle)
                        guidance.append(couldNotCheck)
                        messageLines.append(couldNotCheck)
                    case true?: break
                    }
                }
                if let reason = cli.installation?.updateCheckError {
                    guidance.append(reason)
                    messageLines.append(reason)
                }
                if let installation = cli.installation {
                    let source: String = switch installation.source {
                    case .npm: "npm"
                    case .homebrew: "Homebrew"
                    case .native: String(localized: "Native installer", bundle: bundle)
                    case .missing: String(localized: "Not installed", bundle: bundle)
                    case .unknown: String(localized: "Unknown source", bundle: bundle)
                    }
                    details.append(.init(id: "source", label: String(localized: "Installation", bundle: bundle), value: source))
                    let provenance = String(
                        format: String(localized: "Installation: %@", bundle: bundle),
                        source
                    )
                    messageLines.append(provenance)
                    let hint = NSLocalizedString(installation.updateHint, bundle: bundle, comment: "CLI update guidance")
                    let showHint = installation.updateAvailable != false || !compatible
                    if showHint {
                        guidance.append(hint)
                        messageLines.append(hint)
                    }
                }
                checks.append(.init(
                    id: "cli",
                    title: statusTitle,
                    status: compatible && cli.installation?.updateCheckError == nil ? .pass : .warn,
                    message: messageLines.joined(separator: "\n"),
                    fix: canUpdate && updateAvailable ? .updateCli : nil,
                    details: details,
                    guidance: guidance.isEmpty ? nil : guidance.joined(separator: "\n")
                ))
            } else {
                checks.append(.init(id: "cli", title: title, status: .fail,
                                    message: Issue.cliMissing(name: cli.name, installHint: cli.installHint).message(bundle: bundle),
                                    fix: canUpdate ? .installCli : nil))
            }
        }

        // The adapter only needs Node.js and npm; the user's CLI is checked
        // separately and does not block installing the adapter.
        let canInstallAdapter = !checks.contains { ($0.id == "node" || $0.id == "npm") && $0.status == .fail }
        let adapterTitle = String(localized: "ACP adapter", bundle: bundle)
        switch agent.installedVersion {
        case nil:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .fail,
                                message: String(format: String(localized: "%@ is not installed. Lithe installs it with your npm into its application data.", bundle: bundle), "\(agent.package)@\(agent.version)"),
                                fix: canInstallAdapter ? .install : nil))
        case let installed? where agent.needsUpdate:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .warn,
                                message: String(format: String(localized: "Installed %@ · update to %@ available", bundle: bundle), installed, agent.version),
                                fix: canInstallAdapter ? .update : nil))
        case _? where agent.updateAvailable == nil:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .warn,
                                message: String(localized: "Could not compare the local adapter with the verified version.", bundle: bundle)))
        case let installed?:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .pass,
                                message: String(format: String(localized: "Installed %@", bundle: bundle), installed)))
        }

        checks.append(.init(
            id: "provider",
            title: String(localized: "Agent provider", bundle: bundle),
            status: hasProvider ? .pass : .fail,
            message: hasProvider
                ? String(localized: "Signed in through the ACP gateway with the API key from your local configuration.", bundle: bundle)
                : String(localized: "Choose a local or custom provider so the Agent can sign in.", bundle: bundle),
            fix: hasProvider ? nil : .fetchLocalConfiguration
        ))
        return checks
    }

    /// Whether the adapter may be installed: only Node.js and npm gate it.
    static func canInstallAdapter(_ checks: [AgentPreflightCheck]) -> Bool {
        !checks.contains { ($0.id == "node" || $0.id == "npm") && $0.status == .fail }
    }

    /// Worst status across the checklist; `nil` when there are no checks.
    static func summary(of checks: [AgentPreflightCheck]) -> AgentPreflightCheck.Status? {
        checks.map(\.status).max()
    }
}
