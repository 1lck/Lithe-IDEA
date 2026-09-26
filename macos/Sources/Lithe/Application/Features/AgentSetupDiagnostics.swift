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

        var message: String {
            switch self {
            case .nodeMissing(let minimum):
                String(format: String(localized: "Node.js %lld or later was not found. Install it, then check again."), minimum)
            case .nodeTooOld(let minimum, let found):
                String(format: String(localized: "Node.js %lld or later is required; found %@."), minimum, found)
            case .npmMissing:
                String(localized: "npm was not found. It is normally installed with Node.js.")
            case .cliMissing(let name, let hint):
                String(format: String(localized: "%@ was not found. Install it (for example `%@`), then check again."), name, hint)
            case .cliTooOld(let name, let minimum, let found):
                String(format: String(localized: "%@ %@ or later is required; found %@. Update it, then check again."), name, minimum, found)
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
}

extension AgentSetupDiagnostics {
    /// Preflight rows for `agent`: runtime, the user's CLI, the adapter
    /// install, and the provider assignment. Order is fixed so the list does
    /// not jump between refreshes.
    static func preflight(
        for agent: AgentCatalogStatus,
        environment: AgentRuntimeEnvironment,
        hasProvider: Bool
    ) -> [AgentPreflightCheck] {
        var checks: [AgentPreflightCheck] = []

        let nodeTitle = String(format: String(localized: "Node.js %lld or later"), agent.minimumNodeMajor)
        switch environment.node {
        case nil:
            checks.append(.init(id: "node", title: nodeTitle, status: .fail,
                                message: Issue.nodeMissing(minimumMajor: agent.minimumNodeMajor).message))
        case let node? where majorVersion(of: node.version) < agent.minimumNodeMajor:
            checks.append(.init(id: "node", title: nodeTitle, status: .fail,
                                message: Issue.nodeTooOld(minimumMajor: agent.minimumNodeMajor, found: node.version).message))
        case let node?:
            checks.append(.init(id: "node", title: nodeTitle, status: .pass, message: "\(node.version) · \(node.path)"))
        }

        if let npm = environment.npm {
            checks.append(.init(id: "npm", title: "npm", status: .pass, message: "\(npm.version) · \(npm.path)"))
        } else {
            checks.append(.init(id: "npm", title: "npm", status: .fail, message: Issue.npmMissing.message))
        }

        if let cli = agent.cli {
            let title = String(format: String(localized: "%@ %@ or later"), cli.name, cli.minimumVersion)
            if let detected = cli.detected {
                if isVersion(detected.version, atLeast: cli.minimumVersion) {
                    checks.append(.init(id: "cli", title: title, status: .pass, message: "\(detected.version) · \(detected.path)"))
                } else {
                    checks.append(.init(id: "cli", title: title, status: .warn,
                                        message: Issue.cliTooOld(name: cli.name, minimumVersion: cli.minimumVersion, found: detected.version).message,
                                        fix: .updateCli))
                }
            } else {
                checks.append(.init(id: "cli", title: title, status: .fail,
                                    message: Issue.cliMissing(name: cli.name, installHint: cli.installHint).message,
                                    fix: .installCli))
            }
        }

        // The adapter only needs Node.js and npm; the user's CLI is checked
        // separately and does not block installing the adapter.
        let canInstallAdapter = !checks.contains { ($0.id == "node" || $0.id == "npm") && $0.status == .fail }
        let adapterTitle = String(localized: "ACP adapter")
        switch agent.installedVersion {
        case nil:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .fail,
                                message: String(format: String(localized: "%@ is not installed. Lithe installs it with your npm into its application data."), "\(agent.package)@\(agent.version)"),
                                fix: canInstallAdapter ? .install : nil))
        case let installed? where installed != agent.version:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .warn,
                                message: String(format: String(localized: "Installed %@ · update to %@ available"), installed, agent.version),
                                fix: canInstallAdapter ? .update : nil))
        case let installed?:
            checks.append(.init(id: "adapter", title: adapterTitle, status: .pass,
                                message: String(format: String(localized: "Installed %@"), installed)))
        }

        checks.append(.init(
            id: "provider",
            title: String(localized: "Local configuration"),
            status: hasProvider ? .pass : .fail,
            message: hasProvider
                ? String(localized: "Signed in through the ACP gateway with the API key from your local configuration.")
                : String(localized: "Fetch your local configuration so the Agent can sign in."),
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
