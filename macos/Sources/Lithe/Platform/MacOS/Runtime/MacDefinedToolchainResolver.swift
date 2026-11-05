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
        struct Payload: Encodable {
            let registry: ToolingJSONValue
            let tool: String
            let executable: String
            let home: String?
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
                              home: selection.home, runtimeArguments: [], arguments: arguments)
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
