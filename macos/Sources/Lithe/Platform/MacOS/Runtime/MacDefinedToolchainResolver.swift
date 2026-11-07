import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Launch-only adapter for installed definitions. It owns no saved preferences and
/// never promotes a settings-page detection into execution authority.
@MainActor
final class MacDefinedToolchainResolver: DefinedToolchainResolving {
    var sources: @MainActor () -> [ToolchainSettingsPluginSource] = { [] }
    var discovery = MacToolchainDiscovery()

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool) async throws -> MacToolchainDiscovery.Selection? {
        try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                          minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed, fixed: nil)
    }

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?) async throws -> MacToolchainDiscovery.Selection? {
        try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                          minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed, fixed: fixed, use: .executable)
    }

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?, use: DefinedToolchainUse) async throws -> MacToolchainDiscovery.Selection? {
        try await resolve(tool: tool, directory: directory, workspace: workspace, environment: environment,
                          minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed, fixed: fixed, use: use, consumerID: nil)
    }

    func resolve(tool: String, directory: String, workspace: URL, environment: [String: String],
                 minimumVersion: String?, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection?, use: DefinedToolchainUse, consumerID: String?) async throws -> MacToolchainDiscovery.Selection? {
        let installed = sources()
        let discovery = self.discovery
        let localURL = workspace.appendingPathComponent(".lithe/toolchains/local.json")
        let preferencesURL = workspace.appendingPathComponent(".lithe/run/local.json")
        let worker = Task.detached(priority: .userInitiated) {
            let bytes = try MacToolchainSettingsLoader.safeNativeRead(localURL)
            let preferencesBytes = try Self.readPreferences(preferencesURL, workspace: workspace)
            let runDocument = try preferencesBytes.map { try JSONDecoder().decode(ToolingJSONValue.self, from: $0) }
            if let runDocument {
                guard case .object(let document) = runDocument, let version = document["version"],
                      [ToolingJSONValue.integer(1), .integer(2), .number(1), .number(2)].contains(version) else {
                    throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
                }
            }
            let preferences: ToolingJSONValue
            if case .object(let document) = runDocument, case .object(let toolchain) = document["toolchain"] {
                preferences = toolchain["preferences"] ?? .object(["version": .number(1)])
            } else if runDocument == nil {
                preferences = .object(["version": .number(1)])
            } else if case .object(let document) = runDocument, document["toolchain"] == nil {
                preferences = .object(["version": .number(1)])
            } else { throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true) }
            let chosen = try Self.consumerChoice(document: preferences, tool: tool, directory: directory, consumerID: consumerID, fixed: fixed)
            let local: ToolingJSONValue
            if let bytes {
                local = try JSONDecoder().decode(ToolingJSONValue.self, from: bytes)
            } else {
                local = .object(["version": .number(1), "toolchains": .object([:])])
            }
            let result = try await discovery.resolve(.init(workspace: workspace, sources: installed, environment: environment),
                tool: tool, directory: directory, minimumVersion: minimumVersion, local: local,
                projectCodeAllowed: projectCodeAllowed, fixed: chosen, requiresDirectLaunch: use == .executable)
            guard try MacToolchainSettingsLoader.safeNativeRead(localURL) == bytes else { throw CancellationError() }
            guard try Self.readPreferences(preferencesURL, workspace: workspace) == preferencesBytes else { throw CancellationError() }
            return result
        }
        let selected = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard sources() == installed else { throw CancellationError() }
        return selected
    }

    nonisolated private static func readPreferences(_ url: URL, workspace: URL) throws -> Data? {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let source = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard source.hasPrefix(root + "/") else {
            throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
        }
        return try MacToolchainSettingsLoader.safeNativeRead(url, maximumBytes: 2_097_152)
    }

    /// Core retains inheritance semantics; this adapter supplies captured bytes
    /// and decodes one inert input before the existing native proof pipeline.
    nonisolated static func consumerChoice(document: ToolingJSONValue, tool: String, directory: String,
                                           consumerID: String?, fixed: FixedToolchainSelection?) throws -> FixedToolchainSelection? {
        var payload: [String: Any] = ["document": document.foundationObject, "tool": tool, "directory": directory,
                                      "consumer": consumerID as Any? ?? NSNull()]
        if let fixed { payload["fixed"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixed)) }
        guard let data = MacToolchainDiscovery().core("toolchains.resolveConsumerPreferences", payload),
              data["status"] as? String == "ok", let value = data["preferences"] as? [String: Any] else {
            throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
        }
        guard let fixed = value["fixed"], !(fixed is NSNull) else { return nil }
        return try JSONDecoder().decode(FixedToolchainSelection.self, from: JSONSerialization.data(withJSONObject: fixed))
    }
}

extension MacDefinedToolchainResolver: DefinedToolLaunching {
    /// Core expands the template; this adapter only supplies the registry of the
    /// installed definitions and the installation the user's layers selected.
    func launch(of selection: ResolvedDefinedToolchain, tool: String, arguments: [String]) throws -> DefinedToolLaunch {
        try launch(of: selection, tool: tool, entry: nil, runtimeArguments: [], arguments: arguments)
    }

    /// Expands the definition's `launch` template with an entry and runtime
    /// arguments as well. Core alone places each part, so the host adds no
    /// argument of its own and a template that cannot take a part refuses it.
    func launch(of selection: ResolvedDefinedToolchain, tool: String, entry: String?,
                runtimeArguments: [String], arguments: [String]) throws -> DefinedToolLaunch {
        struct Payload: Encodable {
            let registry: ToolingJSONValue
            let tool: String
            let executable: String
            let home: String?
            let entry: String?
            let runtimeArguments: [String]
            let arguments: [String]
        }
        struct Expansion: Decodable {
            struct Launch: Decodable { let executable: String; let arguments: [String] }
            struct Rejection: Decodable { let code: String; let message: String }
            let launch: Launch?
            let error: Rejection?
        }
        guard let registry = ToolingJSONValue.fromFoundation(MacToolchainDiscovery.registry(of: sources())) else {
            throw DefinedToolLaunchRejection(code: "plugin.toolchain.invalidParams", message: "The tool registry is invalid.")
        }
        let payload = Payload(registry: registry, tool: tool, executable: selection.executable.path,
                              home: selection.home, entry: entry, runtimeArguments: runtimeArguments, arguments: arguments)
        let expansion: Expansion = try RustCoreBridge().executeResult(
            command: "toolchains.instantiateLaunch", payload: payload).get()
        if let launch = expansion.launch {
            return DefinedToolLaunch(executable: launch.executable, arguments: launch.arguments)
        }
        let error = expansion.error
        throw DefinedToolLaunchRejection(code: error?.code ?? "plugin.toolchain.invalidParams",
                                         message: error?.message ?? "The tool launch could not be expanded.")
    }
}

/// A process whose launch plan names a tool definition (`launch.kind` `tool`),
/// with the package paths already checked.
struct DefinedToolProcessLaunch: Equatable, Sendable {
    /// Tool, entry, runtime arguments and minimum version from Rust Core's plan.
    let launch: DeclarativeLanguageServerLaunchPlan.ToolLaunch
    /// The runtime the plugin ships, checked to be an executable file inside
    /// the package; the host runs it as the tool and never looks the tool up.
    let packagedRuntimeURL: URL?
    /// Every tool the plan's `runtimeRequirements` asks the host to resolve.
    /// Their exports and `PATH` entries join the process environment.
    let requirements: [DeclarativeLanguageServerLaunchPlan.RuntimeRequirement]
}

/// The command line and environment that start a tool-definition launch.
struct DefinedToolCommand: Equatable, Sendable {
    let executableURL: URL
    /// Every argument after the executable, in the order of the definition's
    /// `launch` template.
    let arguments: [String]
    let environment: [String: String]
}

extension MacDefinedToolchainResolver {
    /// Resolves the tools a process needs through the four layers, then lets
    /// Core place the entry, runtime arguments and `arguments` by the launch
    /// template. `arguments` are the plugin's own and fill `${arguments}`.
    ///
    /// A tool no layer resolves is `plugin.host.toolUnresolved`; a template
    /// that cannot carry the parts keeps Core's own code.
    func command(
        for process: DefinedToolProcessLaunch,
        arguments: [String],
        workspace: URL,
        directory: String = ".",
        environment: [String: String],
        projectCodeAllowed: Bool
    ) async throws -> DefinedToolCommand {
        let tool = process.launch.tool
        var environment = environment
        // Each selection's environment already holds the one it was given, so
        // resolving in order chains every tool's exports and `PATH` entries.
        for requirement in process.requirements where requirement.tool != tool {
            environment = try await installation(
                of: requirement.tool, minimumVersion: requirement.minimumVersion, workspace: workspace,
                directory: directory, environment: environment, projectCodeAllowed: projectCodeAllowed
            ).environment
        }
        let selection: ResolvedDefinedToolchain
        if let packaged = process.packagedRuntimeURL {
            selection = ResolvedDefinedToolchain(executable: packaged, environment: environment,
                                                 projectCode: false, version: nil)
        } else {
            selection = try await installation(
                of: tool, minimumVersion: process.launch.minimumVersion, workspace: workspace,
                directory: directory, environment: environment, projectCodeAllowed: projectCodeAllowed
            )
        }
        let expanded: DefinedToolLaunch
        do {
            expanded = try launch(of: selection, tool: tool, entry: process.launch.entry,
                                  runtimeArguments: process.launch.runtimeArguments, arguments: arguments)
        } catch let rejection as DefinedToolLaunchRejection {
            throw DeclarativePluginRejection(code: rejection.code, message: rejection.message)
        }
        return DefinedToolCommand(executableURL: URL(fileURLWithPath: expanded.executable),
                                  arguments: expanded.arguments, environment: selection.environment)
    }

    /// One tool's installation, read without its entry recipe, which `command`
    /// expands itself.
    private func installation(
        of tool: String,
        minimumVersion: String?,
        workspace: URL,
        directory: String,
        environment: [String: String],
        projectCodeAllowed: Bool
    ) async throws -> ResolvedDefinedToolchain {
        let selected: ResolvedDefinedToolchain?
        do {
            selected = try await resolve(
                tool: tool, directory: directory, workspace: workspace, environment: environment,
                minimumVersion: minimumVersion, projectCodeAllowed: projectCodeAllowed,
                fixed: nil, use: .installation, consumerID: nil
            )
        } catch is BuildToolResolutionError {
            let requirement = minimumVersion.map { " at version \($0) or later" } ?? ""
            throw DeclarativePluginRejection(
                code: "plugin.host.toolUnresolved",
                message: "No usable installation of the tool \(tool)\(requirement) was found (unusable)."
            )
        }
        guard let selected else {
            throw DeclarativePluginRejection(
                code: "plugin.host.toolUnresolved",
                message: "No enabled plugin defines the tool \(tool) (notFound)."
            )
        }
        return selected
    }
}
