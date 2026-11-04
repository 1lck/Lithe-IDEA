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

    /// The host context a workspace query carries; equal for every plugin of one window.
    struct RoundContext: Equatable {
        let id: String
        let generation: Int
        var json: [String: Any] { ["contextID": id, "generation": generation] }
    }

    /// One directory's query round. Every provider is asked with the round's generation, as
    /// the protocol requires, so `toolchains.resolve` can check their replies together.
    struct Round {
        let generation: UInt64
        /// The context of the first provider that had one; a reply under another is left out.
        var context: RoundContext?
        /// Complete `decodeReply` inputs without `filesystem`: resolve gives them one shared snapshot.
        var queries: [[String: Any]] = []
        /// Native paths the queries named, read again into that snapshot.
        var paths: [String] = []
    }

    struct Answers {
        /// Accepted installations, each `{tool, home, provider}`.
        var installations: [[String: Any]] = []
        /// Rounds by workspace-relative directory; global-only queries are not a round.
        var rounds: [String: Round] = [:]

        /// Adds one query to its directory round unless the round already holds another context.
        @discardableResult
        mutating func join(_ directory: String, context: WorkspaceContext, input: [String: Any], paths: [String]) -> Bool {
            guard var round = rounds[directory] else { return false }
            let joined = RoundContext(id: context.contextID, generation: context.generation)
            if round.context == nil { round.context = joined }
            guard round.context == joined else { return false }
            round.queries.append(input)
            round.paths += paths
            rounds[directory] = round
            return true
        }
    }

    /// The directories asked and resolved: the request's within the budget, always with the root.
    static func queriedDirectories(_ request: Request) -> [String] {
        var directories = Array(request.directories.prefix(queryDirectoryBudget))
        if !directories.contains(".") { directories.insert(".", at: 0) }
        return directories
    }

    func queryProviders(
        _ request: Request, registry: [String: Any], tools: [[String: Any]], root: String, caseSensitive: Bool,
        into result: inout Result
    ) async -> Answers {
        var answers = Answers()
        guard queryProvider != nil else { return answers }
        let providers = Self.providers(of: tools)
        let directories = Self.queriedDirectories(request)
        if request.directories.count > Self.queryDirectoryBudget, !providers.isEmpty {
            result.diagnostics.append(L10n.string("Only the first \(Self.queryDirectoryBudget) directories were queried."))
        }
        let global = Self.nextGeneration()
        for directory in directories { answers.rounds[directory] = Round(generation: Self.nextGeneration()) }
        var installations: [String: [String: Any]] = [:]
        var watch: Set<String> = []
        for (index, provider) in providers.enumerated() {
            let context = await workspaceContext(request.workspace, provider.pluginID)
            var failure: String?
            let started = ContinuousClock.now
            for directory in [nil] + directories.map(Optional.some) where directory == nil || context != nil {
                if Task.isCancelled { return Answers() }
                let scope = directory.flatMap { directory in context.map { (directory, $0) } }
                let generation = directory.flatMap { answers.rounds[$0]?.generation } ?? global
                switch await query(provider, operation: "toolchain-\(generation)-\(index)", generation: generation,
                                   scope: scope, registry: registry, tools: tools, root: root,
                                   caseSensitive: caseSensitive) {
                case .failure(let message):
                    failure = failure ?? message
                case .unavailable(let input, let paths, let message):
                    // Core keeps the provider as `providerUnavailable` while lower sources resolve.
                    failure = failure ?? message
                    if let directory, let context {
                        answers.join(directory, context: context, input: input, paths: paths)
                    }
                case .success(let snapshot, let input, let paths):
                    // A reply under another context stays out of its round, so Core never
                    // resolves it; its project requirements are not shown either.
                    var inRound = false
                    if let directory, let context {
                        inRound = answers.join(directory, context: context, input: input, paths: paths)
                    }
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
                        } else if let directory, inRound {
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
        answers.installations = installations.keys.sorted().compactMap { installations[$0] }
        return answers
    }

    /// A monotonic round generation, unique in this process.
    static func nextGeneration() -> UInt64 {
        generations.withLock { value -> UInt64 in
            value += 1
            return value
        }
    }

    enum Outcome {
        /// The decoded snapshot, its `decodeReply` input without `filesystem`, and the paths read for it.
        case success([String: Any], input: [String: Any], paths: [String])
        /// No answer in time, or no backend to answer: the error reply's `decodeReply` input,
        /// which `toolchains.resolve` reads as this provider being unavailable.
        case unavailable(input: [String: Any], paths: [String], message: String)
        case failure(String)
    }

    /// One query and its validation. `scope` is `nil` for a global-only query.
    func query(
        _ provider: Provider, operation: String, generation: UInt64,
        scope: (directory: String, context: WorkspaceContext)?, registry: [String: Any],
        tools: [[String: Any]], root: String, caseSensitive: Bool
    ) async -> Outcome {
        guard let queryProvider else { return .failure("") }
        let params: [String: Any] = [
            "operationID": operation, "generation": generation, "providerID": provider.id,
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
        // Why the host answered for the provider; a provider's own error keeps its message.
        var hostFailure: String?
        do {
            let value = try await queryProvider(provider.pluginID, provider.id, wire, Self.queryTimeout)
            guard let object = value.foundationObject as? [String: Any], (object["id"] is NSNumber || object["id"] is String),
                  let response = object["response"] as? [String: Any]
            else { return .failure(L10n.string("The reply could not be read.")) }
            reply = ["id": object["id"]!, "response": response]
        } catch {
            // A cancelled discovery discards its results; it is not a provider that could not answer.
            if error is CancellationError || Task.isCancelled { return .failure(error.localizedDescription) }
            let timedOut = error is QueryTimeout
            guard let failure = core("toolchains.failureReply", [
                "params": params,
                "code": timedOut ? "plugin.toolchain.timeout" : "plugin.toolchain.providerUnavailable",
            ])?["reply"] as? [String: Any], failure["id"] is NSNumber, failure["response"] is [String: Any]
            else { return .failure(error.localizedDescription) }
            reply = failure
            hostFailure = timedOut ? L10n.string("No answer within \(Int(Self.queryTimeout)) s")
                : error.localizedDescription
        }
        var facts = Self.FactList(caseSensitive: caseSensitive)
        facts.add(root)
        if let directory = scope?.directory, directory != "." { facts.add(root + "/" + directory) }
        Self.addFacts(of: reply["response"] as? [String: Any] ?? [:], tools: tools, to: &facts)
        let input: [String: Any] = [
            "registry": registry, "pluginID": provider.pluginID,
            "request": ["jsonrpc": "2.0", "id": reply["id"]!, "method": "toolchains/query", "params": params],
            "response": reply["response"]!, "currentGeneration": generation,
            "platform": "macos", "filesystemCaseSensitive": caseSensitive, "workspaceRoots": [root],
        ]
        let outcome = decodeReply(input.merging(["filesystem": facts.values]) { $1 })
        if outcome?["status"] as? String == "ok", let snapshot = outcome?["snapshot"] as? [String: Any] {
            return .success(snapshot, input: input, paths: facts.paths)
        }
        let error = outcome?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? L10n.string("The reply could not be read.")
        // Only these two codes leave lower sources usable; every other refusal stays a failure.
        if ["plugin.toolchain.timeout", "plugin.toolchain.providerUnavailable"].contains(error?["code"] as? String) {
            return .unavailable(input: input, paths: facts.paths, message: hostFailure ?? message)
        }
        return .failure(message)
    }

    private struct FactList {
        let caseSensitive: Bool
        var values: [[String: Any]] = []
        var paths: [String] = []
        private var keys: Set<String> = []

        init(caseSensitive: Bool) { self.caseSensitive = caseSensitive }

        mutating func add(_ path: String) {
            guard path.hasPrefix("/"), path.utf8.count <= 4_096, values.count < MacToolchainDiscovery.factBudget,
                  keys.insert(caseSensitive ? path : path.lowercased()).inserted
            else { return }
            paths.append(path)
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
