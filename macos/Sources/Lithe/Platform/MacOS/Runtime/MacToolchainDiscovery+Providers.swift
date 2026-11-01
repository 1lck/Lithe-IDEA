import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 查询、失效与过期结果的决策见 .agents/notes/proposed/architecture/2026-10-31-plugin-injected-toolchains.md

/// Queries the enabled providers for the settings pages. A global query always runs, so
/// an unusable project still lists installations; each directory then gets its own query.
/// Every reply passes `toolchains.decodeReply` with native facts read here, so a provider
/// never decides what a path is. Providers are only asked; nothing here installs or trusts.
extension MacToolchainDiscovery {
    struct Provider {
        let pluginID: String
        let id: String
        let tools: [String]
        var qualified: String { "\(pluginID):\(id)" }
    }

    /// Returns accepted installations, each `{tool, home, provider}`.
    func queryProviders(
        _ request: Request, registry: [String: Any], tools: [[String: Any]], root: String, caseSensitive: Bool,
        into result: inout Result
    ) async -> [[String: Any]] {
        guard queryProvider != nil else { return [] }
        let providers = Self.providers(of: tools)
        var directories = Array(request.directories.prefix(Self.queryDirectoryBudget))
        if request.directories.count > directories.count, !providers.isEmpty {
            result.diagnostics.append(L10n.string("Only the first \(Self.queryDirectoryBudget) directories were queried."))
        }
        if !directories.contains(".") { directories.insert(".", at: 0) }
        var installations: [String: [String: Any]] = [:]
        var watch: Set<String> = []
        for provider in providers {
            let context = await workspaceContext(request.workspace, provider.pluginID)
            var failure: String?
            let started = ContinuousClock.now
            for directory in [nil] + directories.map(Optional.some) where directory == nil || context != nil {
                if Task.isCancelled { return [] }
                let scope = directory.flatMap { directory in context.map { (directory, $0) } }
                switch await query(provider, scope: scope, registry: registry, tools: tools, root: root,
                                   caseSensitive: caseSensitive) {
                case .failure(let message):
                    failure = failure ?? message
                case .unavailable(let message, _):
                    failure = failure ?? message
                case .success(let snapshot, _):
                    for row in snapshot["installations"] as? [[String: Any]] ?? [] {
                        guard let tool = row["tool"] as? String, let home = row["home"] as? String else { continue }
                        installations["\(tool)\n\(home)"] = ["tool": tool, "home": home, "provider": provider.qualified]
                    }
                    let versions = Self.versions(snapshot)
                    for row in snapshot["statements"] as? [[String: Any]] ?? [] {
                        guard let requirement = Self.requirement(row, versions: versions, provider: provider) else { continue }
                        let tool = row["tool"] as? String ?? ""
                        if row["scope"] as? String == "global" {
                            if !(result.globalRequirements[tool] ?? []).contains(requirement) {
                                result.globalRequirements[tool, default: []].append(requirement)
                            }
                        } else if let directory {
                            result.requirements[directory, default: [:]][tool, default: []].append(requirement)
                        }
                    }
                    watch.formUnion(snapshot["watch"] as? [String] ?? [])
                }
            }
            if context == nil {
                failure = failure ?? L10n.string("This workspace is not open in a window, so only global versions were read.")
            }
            let elapsed = started.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            result.providerStates[provider.qualified] = failure.map { .failed($0) } ?? .answered(milliseconds: milliseconds)
            if let failure { result.diagnostics.append(L10n.string("\(provider.id) did not answer: \(failure)")) }
        }
        result.watch = watch.sorted()
        return installations.keys.sorted().compactMap { installations[$0] }
    }

    enum Outcome {
        case success([String: Any], validation: [String: Any])
        /// A checked protocol failure may leave lower layers usable.
        case unavailable(String, validation: [String: Any])
        case failure(String)
    }

    /// One query and its validation. `scope` is `nil` for a global-only query.
    func query(
        _ provider: Provider, scope: (directory: String, context: WorkspaceContext)?, registry: [String: Any],
        tools: [[String: Any]], root: String, caseSensitive: Bool, generation suppliedGeneration: UInt64? = nil
    ) async -> Outcome {
        guard let queryProvider else { return .failure("") }
        let generation = suppliedGeneration ?? Self.generations.withLock { value -> UInt64 in
            value += 1
            return value
        }
        let params: [String: Any] = [
            "operationID": "toolchain-\(generation)", "generation": generation, "providerID": provider.id,
            "authority": ["kind": "local"],
            "context": scope.map { ["contextID": $0.context.contextID, "generation": $0.context.generation] as [String: Any] }
                ?? NSNull(),
            "workspace": scope.map { ["rootID": $0.context.rootID, "root": root, "directory": $0.directory] as [String: Any] }
                ?? NSNull(),
            "tools": provider.tools,
        ]
        guard let wire = ToolingJSONValue.fromFoundation(params) else {
            return .failure(L10n.string("The toolchain query could not be built."))
        }
        let reply: [String: Any]
        do {
            let value = try await queryProvider(provider.pluginID, provider.id, wire, Self.queryTimeout)
            guard let object = value.foundationObject as? [String: Any], object["id"] is NSNumber,
                  let response = object["response"] as? [String: Any]
            else { return .failure(L10n.string("The reply could not be read.")) }
            reply = ["id": object["id"]!, "response": response]
        } catch {
            return .failure(error.localizedDescription)
        }
        var facts = Self.FactList(caseSensitive: caseSensitive)
        facts.add(root)
        if let directory = scope?.directory, directory != "." { facts.add(root + "/" + directory) }
        Self.addFacts(of: reply["response"] as? [String: Any] ?? [:], tools: tools, to: &facts)
        let validation: [String: Any] = [
            "registry": registry, "pluginID": provider.pluginID,
            "request": ["jsonrpc": "2.0", "id": reply["id"]!, "method": "toolchains/query", "params": params],
            "response": reply["response"]!, "currentGeneration": generation, "filesystem": facts.values,
            "platform": "macos", "filesystemCaseSensitive": caseSensitive, "workspaceRoots": [root],
        ]
        let outcome = decodeReply(validation)
        if outcome?["status"] as? String == "ok", let snapshot = outcome?["snapshot"] as? [String: Any] {
            return .success(snapshot, validation: validation)
        }
        let error = outcome?["error"] as? [String: Any]
        if let code = error?["code"] as? String,
           ["plugin.toolchain.timeout", "plugin.toolchain.providerUnavailable"].contains(code) {
            return .unavailable(error?["message"] as? String ?? L10n.string("The reply could not be read."), validation: validation)
        }
        return .failure(error?["message"] as? String ?? L10n.string("The reply could not be read."))
    }

    private struct FactList {
        let caseSensitive: Bool
        var values: [[String: Any]] = []
        private var keys: Set<String> = []

        init(caseSensitive: Bool) { self.caseSensitive = caseSensitive }

        mutating func add(_ path: String) {
            guard path.hasPrefix("/"), path.utf8.count <= 4_096, values.count < MacToolchainDiscovery.factBudget,
                  keys.insert(caseSensitive ? path : path.lowercased()).inserted
            else { return }
            values.append(MacToolchainDiscovery.fact(of: path))
        }
    }

    /// Reads the paths a reply names. An unreadable shape adds nothing, and Core refuses it.
    private static func addFacts(of response: [String: Any], tools: [[String: Any]], to facts: inout FactList) {
        guard let result = response["result"] as? [String: Any] else { return }
        // Executable layouts and `${home}` prepends: what resolving a provider home reads.
        let layouts = Dictionary(tools.compactMap { tool -> (String, [String])? in
            guard let id = tool["tool"] as? String else { return nil }
            let executables = (tool["executableLayouts"] as? [[String: Any]] ?? []).filter(applies)
                .compactMap { $0["path"] as? String }
            let prepends = (tool["pathPrepend"] as? [String] ?? []).compactMap { template -> String? in
                guard template.hasPrefix("${home}/") else { return nil }
                return String(template.dropFirst("${home}/".count))
            }
            return (id, executables + prepends)
        }, uniquingKeysWith: { first, _ in first })
        for row in result["installations"] as? [[String: Any]] ?? [] {
            guard let home = row["home"] as? String else { continue }
            facts.add(home)
            for layout in layouts[row["tool"] as? String ?? ""] ?? [] { facts.add(home + "/" + layout) }
        }
        for row in result["statements"] as? [[String: Any]] ?? [] {
            if let source = row["source"] as? String { facts.add(source) }
        }
        for path in result["watch"] as? [String] ?? [] { facts.add(path) }
    }

    /// Providers of enabled definitions, each with the sorted tools it may be asked about.
    static func providers(of tools: [[String: Any]]) -> [Provider] {
        var byProvider: [String: Set<String>] = [:]
        for tool in tools {
            guard let id = tool["tool"] as? String else { continue }
            for provider in tool["providers"] as? [String] ?? [] { byProvider[provider, default: []].insert(id) }
        }
        return byProvider.keys.sorted().compactMap { qualified in
            guard let (plugin, provider) = qualified.lastColonSplit, let tools = byProvider[qualified] else { return nil }
            return Provider(pluginID: plugin, id: provider, tools: tools.sorted())
        }
    }

    private static func versions(_ snapshot: [String: Any]) -> [String: String] {
        var versions: [String: String] = [:]
        for row in snapshot["installations"] as? [[String: Any]] ?? [] {
            if let home = row["home"] as? String, let version = row["version"] as? String { versions[home] = version }
        }
        return versions
    }

    private static func requirement(
        _ row: [String: Any], versions: [String: String], provider: Provider
    ) -> ToolchainSettingsSnapshot.Requirement? {
        guard let request = row["request"] as? String, let source = row["source"] as? String else { return nil }
        let home = row["installation"] as? String
        return .init(request: request, source: source, providerID: provider.qualified, home: home,
                     version: home.flatMap { versions[$0] })
    }
}

private extension String {
    var lastColonSplit: (String, String)? {
        guard let index = lastIndex(of: ":") else { return nil }
        return (String(self[..<index]), String(self[self.index(after: index)...]))
    }
}
