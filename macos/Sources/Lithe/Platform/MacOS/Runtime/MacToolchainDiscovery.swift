import Darwin
import Foundation
import LitheCoreContracts
import os
import LitheModuleAPI

/// Expands definition-owned discovery scans and runs declared version probes for the
/// settings pages. Core plans the scans and checks every home; this adapter only reads
/// native metadata and runs a probe on an executable Core returned after those checks.
/// Nothing is written: probe outputs stay in a process-local cache keyed by file identity.
struct MacToolchainDiscovery: Sendable {
    struct Request: Sendable {
        /// The opened root; Core refuses homes inside it, so they are never probed.
        let workspace: URL
        /// Enabled installed plugins; Core revalidates every manifest.
        let sources: [ToolchainSettingsPluginSource]
        /// The login-shell environment children receive; only declared variables reach Core.
        let environment: [String: String]
        /// Directories to ask providers about: the root and those with their own version file.
        var directories: [String] = ["."]
    }

    /// The identities a workspace `toolchains/query` carries; `nil` when no context is open.
    struct WorkspaceContext: Sendable {
        let contextID: String
        let generation: Int
        let rootID: String
    }

    struct Result: Equatable, Sendable {
        var detections: [String: ToolchainSettingsSnapshot.Detection] = [:]
        /// Tools whose candidate check Core refused, so their rows show no detection.
        var unchecked: [String] = []
        var diagnostics: [String] = []
        /// What providers require for a tool, by queried directory then tool.
        var requirements: [String: [String: [ToolchainSettingsSnapshot.Requirement]]] = [:]
        var globalRequirements: [String: [ToolchainSettingsSnapshot.Requirement]] = [:]
        /// Outcome of the latest queries, by qualified provider ID.
        var providerStates: [String: ToolchainSettingsSnapshot.Provider.QueryState] = [:]
        /// Native inputs providers named; a change revokes the whole snapshot.
        var watch: [String] = []
    }

    /// `discoveryPlan` bounds for scan roots and expanded directory entries.
    static let rootBudget = 256
    static let entryBudget = 4_096
    /// Core checks at most 8,192 facts and 512 installations per tool.
    static let factBudget = 8_192
    static let installationBudget = 512
    static let probeBudget = 64
    static let probeOutputLimit = 128 * 1_024
    /// Probes block their thread until the five-second process deadline.
    static let probeWidth = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    static let probeTimeBudget: Duration = .seconds(20)

    /// One provider query, as `queryProvider` replies must be bounded.
    static let queryTimeout: TimeInterval = 15
    /// Directories asked per provider; each is one upstream run.
    static let queryDirectoryBudget = 32

    private static let probeCache = MacRuntimeProbeCache()
    static let generations = OSAllocatedUnfairLock(initialState: UInt64(0))

    var homeDirectory: @Sendable () -> String = { NSHomeDirectory() }
    /// One `toolchains.*` command; `nil` when Core refuses the input.
    var core: @Sendable (String, [String: Any]) -> [String: Any]? = Self.callCore
    /// The output of a successful probe; failures are not cached and Core reports them.
    var probe: @Sendable (_ executable: String, _ arguments: [String]) -> String? = Self.runProbe
    /// Consumer probes inherit the exact environment selected for this operation.
    var consumerProbe: @Sendable (String, [String], [String: String]) -> String? = { executable, arguments, environment in
        let result = MacProcessRunner().run(ProcessRequest(executablePath: executable, arguments: arguments,
            environment: environment, timeoutMilliseconds: 5_000))
        guard result.succeeded, result.output.utf8.count <= probeOutputLimit else { return nil }
        return result.output
    }
    /// Asks a plugin's provider and returns `{ id, response }`; `nil` leaves providers unqueried.
    var queryProvider: (@Sendable (_ pluginID: String, _ providerID: String, _ params: ToolingJSONValue,
                                   _ timeout: TimeInterval) async throws -> ToolingJSONValue)? = nil
    var workspaceContext: @Sendable (_ workspace: URL, _ pluginID: String) async -> WorkspaceContext? = { _, _ in nil }
    /// `toolchains.decodeReply`, keeping a refusal's code and message.
    var decodeReply: @Sendable ([String: Any]) -> [String: Any]? = Self.callDecodeReply

    func discover(_ request: Request) async -> Result {
        var result = Result()
        let plugins: [[String: Any]] = request.sources.compactMap { source in
            guard let manifest = try? JSONSerialization.jsonObject(with: source.manifest) as? [String: Any],
                  manifest["toolDefinitions"] != nil || manifest["toolchainProviders"] != nil
            else { return nil }
            return ["manifest": manifest, "verifiedOfficial": source.verifiedOfficial]
        }
        guard !plugins.isEmpty else { return result }
        let registry: [String: Any] = ["plugins": plugins]
        guard let plan = core("toolchains.discoveryPlan", ["registry": registry, "platform": "macos"])?["plan"]
                as? [String: Any],
              let tools = plan["tools"] as? [[String: Any]]
        else {
            result.diagnostics.append(L10n.string("Installed toolchain declarations could not be checked for discovery."))
            return result
        }
        guard let root = Self.realpath(request.workspace.path) else { return result }
        let caseSensitive = (try? request.workspace.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        var scanner = Scanner(home: homeDirectory(), environment: request.environment, workspace: root,
                              caseSensitive: caseSensitive)
        let answers = await queryProviders(
            request, registry: registry, tools: tools, root: root, caseSensitive: caseSensitive, into: &result)
        if Task.isCancelled { return result }
        var inputs: [Input] = []
        for tool in tools {
            guard let id = tool["tool"] as? String else { continue }
            inputs.append(scanner.input(tool: id, plan: tool, reported: answers.filter { $0["tool"] as? String == id }))
        }
        result.diagnostics += scanner.diagnostics

        var checked: [String: [String: Any]] = [:]
        var targets: [Target] = []
        for input in inputs {
            if Task.isCancelled { return result }
            guard let value = candidates(input, registry: registry, root: root, caseSensitive: caseSensitive, probes: [])
            else {
                result.unchecked.append(input.tool)
                continue
            }
            checked[input.tool] = value
            targets += Self.probeTargets(value).map { Target(tool: input.tool, executable: $0, arguments: input.arguments) }
        }
        if targets.count > Self.probeBudget {
            targets = Array(targets.prefix(Self.probeBudget))
            result.diagnostics.append(L10n.string("Only the first \(Self.probeBudget) installation versions were checked."))
        }
        let (outputs, expired) = await probe(targets)
        if expired { result.diagnostics.append(L10n.string("Some installation versions were not checked in time.")) }
        for input in inputs {
            if Task.isCancelled { return result }
            let probes = outputs.filter { $0.key.tool == input.tool }
                .map { ["executable": $0.key.executable, "output": $0.value, "exitCode": 0] as [String: Any] }
            if !probes.isEmpty {
                checked[input.tool] = candidates(input, registry: registry, root: root, caseSensitive: caseSensitive,
                                                 probes: probes)
                if checked[input.tool] == nil { result.unchecked.append(input.tool) }
            }
            if let value = checked[input.tool] { result.detections[input.tool] = Self.detection(value, locations: input.locations) }
        }
        return result
    }

    /// Native evidence for one tool: its scanned homes, the declared login-shell variables
    /// and the facts Core needs to check both.
    struct Input {
        let tool: String
        let arguments: [String]
        let installations: [[String: Any]]
        /// Homes `toolchains.decodeReply` accepted, with their qualified provider.
        let reported: [[String: Any]]
        let environment: [String: String]
        let facts: [[String: Any]]
        /// Canonical scanned entry by the canonical home Core reports, for homes below their entry.
        let locations: [String: String]
    }

    struct Target: Hashable {
        let tool: String
        let executable: String
        let arguments: [String]
    }

    private func candidates(
        _ input: Input, registry: [String: Any], root: String, caseSensitive: Bool, probes: [[String: Any]]
    ) -> [String: Any]? {
        let payload: [String: Any] = [
            "registry": registry, "tool": input.tool, "platform": "macos", "filesystemCaseSensitive": caseSensitive,
            "workspaceRoot": root, "filesystem": input.facts, "systemInstallations": input.installations,
            "providerInstallations": input.reported, "environment": input.environment, "probes": probes
        ]
        return core("toolchains.candidates", payload)?["candidates"] as? [String: Any]
    }

    /// Executables Core checked but could not version without a probe.
    static func probeTargets(_ value: [String: Any]) -> [String] {
        let rows = (value["skipped"] as? [[String: Any]] ?? []) + (value["shell"] as? [[String: Any]] ?? [])
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard row["reason"] as? String == "probeFailed", let executable = row["executable"] as? String,
                  seen.insert(executable).inserted
            else { return nil }
            return executable
        }
    }

    /// Runs probes a few at a time; once the time budget is spent, no new probe starts.
    func probe(_ targets: [Target]) async -> (outputs: [Target: String], expired: Bool) {
        guard !targets.isEmpty else { return ([:], false) }
        let deadline = ContinuousClock.now + Self.probeTimeBudget
        let probe = self.probe
        return await withTaskGroup(of: (Target, String?).self) { group in
            var pending = targets[...]
            var outputs: [Target: String] = [:]
            var expired = false
            func start() {
                guard !Task.isCancelled, let target = pending.popFirst() else { return }
                group.addTask { (target, probe(target.executable, target.arguments)) }
            }
            for _ in 0..<Self.probeWidth { start() }
            while let next = await group.next() {
                let (target, output) = next
                if let output { outputs[target] = output }
                if ContinuousClock.now >= deadline {
                    expired = expired || !pending.isEmpty
                    pending.removeAll()
                }
                start()
            }
            return (outputs, expired)
        }
    }

    private static func detection(_ value: [String: Any], locations: [String: String]) -> ToolchainSettingsSnapshot.Detection {
        .init(
            shell: (value["shell"] as? [[String: Any]] ?? []).compactMap { row in
                guard let variable = row["variable"] as? String, let home = row["home"] as? String else { return nil }
                return .init(variable: variable, home: home, executable: row["executable"] as? String,
                             version: row["version"] as? String, reason: row["reason"] as? String)
            },
            installations: (value["installations"] as? [[String: Any]] ?? []).compactMap { row in
                guard let home = row["home"] as? String, let executable = row["executable"] as? String,
                      let version = row["version"] as? String, let provider = row["provider"] as? String
                else { return nil }
                return .init(home: home, executable: executable, version: version, provider: provider,
                             location: locations[home])
            },
            skipped: (value["skipped"] as? [[String: Any]] ?? []).compactMap { row in
                guard let home = row["home"] as? String, let reason = row["reason"] as? String else { return nil }
                return .init(home: home, reason: reason)
            },
            selected: value["selected"] as? String,
            conflict: !(value["conflicts"] as? [Any] ?? []).isEmpty)
    }

    /// Expands scans under shared budgets and records each path's native metadata once.
    struct Scanner {
        let home: String
        let environment: [String: String]
        let workspace: String
        let caseSensitive: Bool
        var roots = 0
        var entries = 0
        var diagnostics: [String] = []
        private var known: [String: [String: Any]] = [:]

        init(home: String, environment: [String: String], workspace: String, caseSensitive: Bool) {
            self.home = home
            self.environment = environment
            self.workspace = workspace
            self.caseSensitive = caseSensitive
        }

        mutating func input(tool: String, plan: [String: Any], reported: [[String: Any]], additionalHomes: [String] = []) -> Input {
            var facts = FactSet(caseSensitive: caseSensitive)
            facts.add(fact(workspace))
            let layouts = (plan["executableLayouts"] as? [[String: Any]] ?? []).filter(MacToolchainDiscovery.applies)
                .compactMap { $0["path"] as? String }
            let prepend = (plan["pathPrepend"] as? [String] ?? []).compactMap { template -> String? in
                template.hasPrefix("${home}") ? String(template.dropFirst("${home}".count)) : nil
            }
            var homes: [String] = []
            var seen: Set<String> = []
            var locations: [String: String] = [:]
            let homeLayouts = (plan["homeLayouts"] as? [[String: Any]] ?? []).filter(MacToolchainDiscovery.applies)
            for scan in plan["scans"] as? [[String: Any]] ?? [] {
                for entry in expand(scan) {
                    guard let home = Self.home(of: entry, layouts: homeLayouts), seen.insert(home).inserted else { continue }
                    homes.append(home)
                    if home != entry, let canonical = MacToolchainDiscovery.realpath(home),
                       let named = MacToolchainDiscovery.realpath(entry) {
                        locations[canonical] = named
                    }
                }
            }
            if homes.count > MacToolchainDiscovery.installationBudget {
                homes = Array(homes.prefix(MacToolchainDiscovery.installationBudget))
                diagnostics.append(L10n.string("Only the first \(MacToolchainDiscovery.installationBudget) installations of a tool were checked."))
            }
            var variables: [String: String] = [:]
            for candidate in plan["environment"] as? [[String: Any]] ?? [] {
                guard let variable = candidate["variable"] as? String, let value = environment[variable],
                      value.hasPrefix("/"), value.utf8.count <= 4_096
                else { continue }
                variables[variable] = value
            }
            let reportedHomes = reported.compactMap { $0["home"] as? String }
            for home in homes + reportedHomes + variables.values.map(Self.normalized) + additionalHomes {
                let found = fact(home)
                facts.add(found)
                let canonical = found["kind"] as? String == "directory" ? found["canonicalPath"] as? String : nil
                for layout in layouts {
                    facts.add(self.fact(Self.join(home, layout)))
                    if let canonical, canonical != home { facts.add(self.fact(Self.join(canonical, layout))) }
                }
                for suffix in prepend {
                    if let canonical { facts.add(self.fact(Self.normalized(canonical + suffix))) }
                }
            }
            if facts.truncated {
                diagnostics.append(L10n.string("Too many files to check for one tool; some installations were skipped."))
            }
            let version = plan["version"] as? [String: Any]
            return Input(tool: tool, arguments: version?["arguments"] as? [String] ?? [],
                         installations: homes.map { ["tool": tool, "home": $0] },
                         reported: reported.map { ["tool": tool, "home": $0["home"] ?? "", "provider": $0["provider"] ?? ""] },
                         environment: variables,
                         facts: facts.values, locations: locations)
        }

        /// The directories one scan names, following links; entries inside the workspace are skipped.
        private mutating func expand(_ scan: [String: Any]) -> [String] {
            guard let root = root(scan["root"] as? [String: Any]), let pattern = scan["pattern"] as? String else {
                return []
            }
            roots += 1
            if roots > MacToolchainDiscovery.rootBudget {
                if roots == MacToolchainDiscovery.rootBudget + 1 {
                    diagnostics.append(L10n.string("Only the first \(MacToolchainDiscovery.rootBudget) discovery locations were scanned."))
                }
                return []
            }
            var current = [root]
            for component in pattern.split(separator: "/").map(String.init) {
                var next: [String] = []
                for directory in current {
                    if component.contains("*") {
                        next += names(in: directory)
                            .filter { (!$0.hasPrefix(".") || component.hasPrefix(".")) && MacToolchainDiscovery.matches(component, $0) }
                            .map { Self.join(directory, $0) }
                    } else {
                        next.append(Self.join(directory, component))
                    }
                }
                current = next
            }
            return current.filter { entry in
                guard let canonical = MacToolchainDiscovery.realpath(entry), fact(entry)["kind"] as? String == "directory" else { return false }
                return !Self.within(canonical, workspace, caseSensitive: caseSensitive)
            }
        }

        private func root(_ value: [String: Any]?) -> String? {
            let path: String? = switch value?["kind"] as? String {
            case "home": home
            case "environment": (value?["variable"] as? String).flatMap { environment[$0] }
            case "absolute": value?["path"] as? String
            default: nil
            }
            guard let path, path.hasPrefix("/") else { return nil }
            return Self.normalized(path)
        }

        private mutating func names(in directory: String) -> [String] {
            let remaining = MacToolchainDiscovery.entryBudget - entries
            guard remaining > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                return []
            }
            entries += min(names.count, remaining)
            if names.count > remaining {
                diagnostics.append(L10n.string("Only the first \(MacToolchainDiscovery.entryBudget) discovered entries were checked."))
            }
            return Array(names.sorted().prefix(remaining))
        }

        /// Metadata of the object a path resolves to, as `execve` and Core's canonical form see it.
        private mutating func fact(_ path: String) -> [String: Any] {
            if let fact = known[path] { return fact }
            let fact = MacToolchainDiscovery.fact(of: path)
            known[path] = fact
            return fact
        }

        /// The home inside a scanned entry: the first applicable `match`, or the entry itself
        /// when the definition declares no layouts. An unmatched entry is not an installation.
        static func home(of entry: String, layouts: [[String: Any]]) -> String? {
            guard !layouts.isEmpty else { return entry }
            let name = (entry as NSString).lastPathComponent
            guard let layout = layouts.first(where: { MacToolchainDiscovery.matches($0["match"] as? String ?? "", name) }),
                  let home = layout["home"] as? String
            else { return nil }
            return home == "." ? entry : join(entry, home)
        }

        static func join(_ directory: String, _ path: String) -> String {
            normalized(directory == "/" ? "/" + path : directory + "/" + path)
        }

        static func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }

        static func within(_ path: String, _ root: String, caseSensitive: Bool) -> Bool {
            let (path, root) = caseSensitive ? (path, root) : (path.lowercased(), root.lowercased())
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }

    /// Metadata of the object a path resolves to, as `execve` and Core's canonical form see it.
    static func fact(of path: String) -> [String: Any] {
        var status = stat()
        guard stat(path, &status) == 0, let canonical = realpath(path) else {
            return ["path": path, "canonicalPath": path, "kind": "missing"]
        }
        return status.st_mode & S_IFMT == S_IFDIR
            ? ["path": path, "canonicalPath": canonical, "kind": "directory"]
            : ["path": path, "canonicalPath": canonical, "kind": "file",
               "executable": status.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0]
    }

    /// Facts sent to Core: one per path under the platform's case policy, within its limit.
    private struct FactSet {
        let caseSensitive: Bool
        var values: [[String: Any]] = []
        var truncated = false
        private var keys: Set<String> = []

        init(caseSensitive: Bool) { self.caseSensitive = caseSensitive }

        mutating func add(_ fact: [String: Any]) {
            guard let path = fact["path"] as? String,
                  keys.insert(caseSensitive ? path : path.lowercased()).inserted
            else { return }
            guard values.count < MacToolchainDiscovery.factBudget else {
                truncated = true
                return
            }
            values.append(fact)
        }
    }

    static func applies(_ value: [String: Any]) -> Bool {
        (value["platforms"] as? [String]).map { $0.contains("macos") } ?? true
    }

    /// A single path component against a `*` glob, as Core matches declared patterns.
    static func matches(_ pattern: String, _ value: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        var remaining = Substring(value)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                guard remaining.hasPrefix(part) else { return false }
                remaining = remaining.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return remaining.hasSuffix(part)
            } else if let range = remaining.range(of: part) {
                remaining = remaining[range.upperBound...]
            } else {
                return false
            }
        }
        return remaining.isEmpty
    }

    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Sendable static func callCore(_ command: String, _ payload: [String: Any]) -> [String: Any]? {
        guard let value = ToolingJSONValue.fromFoundation(payload) else { return nil }
        let outcome: Swift.Result<ToolingJSONValue, RustCoreBridge.CoreCallError> = RustCoreBridge()
            .executeResult(command: command, payload: value)
        guard case let .success(data) = outcome, let object = data.foundationObject as? [String: Any],
              object["status"] as? String == "ok"
        else { return nil }
        return object
    }

    @Sendable static func callDecodeReply(_ payload: [String: Any]) -> [String: Any]? {
        guard let value = ToolingJSONValue.fromFoundation(payload) else { return nil }
        let outcome: Swift.Result<ToolingJSONValue, RustCoreBridge.CoreCallError> = RustCoreBridge()
            .executeResult(command: "toolchains.decodeReply", payload: value)
        guard case let .success(data) = outcome else { return nil }
        return data.foundationObject as? [String: Any]
    }

    /// Runs the definition's version arguments without a shell, outside the workspace, with
    /// a five-second deadline. The cache key includes the arguments and the file identity.
    @Sendable static func runProbe(_ executable: String, _ arguments: [String]) -> String? {
        let identity = MacRuntimeProbeCache.key(executable: URL(fileURLWithPath: executable))
        let key = MacRuntimeProbeCache.Key(executablePath: identity.executablePath,
                                           identity: identity.identity + "\n" + arguments.joined(separator: "\u{1F}"))
        return probeCache.value(for: key) {
            let result = MacProcessRunner().run(ProcessRequest(
                executablePath: executable, arguments: arguments, timeoutMilliseconds: 5_000))
            guard result.succeeded else { return nil }
            // Core accepts 128 KiB; a cut scalar becomes one replacement character.
            return result.output.utf8.count <= probeOutputLimit ? result.output
                : String(decoding: result.output.utf8.prefix(probeOutputLimit - 3), as: UTF8.self)
        }
    }
}
