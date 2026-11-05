import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension MacToolchainDiscovery {
    /// A fresh consumer resolution. Settings detections never grant launch authority.
    typealias Selection = ResolvedDefinedToolchain

    /// Captures native evidence, queries installed providers and lets Core apply the
    /// four layers. Extra homes contribute probe evidence, never automatic candidates.
    func resolve(_ request: Request, tool: String, directory: String, minimumVersion: String?,
                 local: ToolingJSONValue, projectCodeAllowed: Bool,
                 fixed: FixedToolchainSelection? = nil, requiresDirectLaunch: Bool = true) async throws -> Selection? {
        let registry = Self.registry(of: request.sources)
        guard let plan = core("toolchains.discoveryPlan", ["registry": registry, "platform": "macos"])?["plan"] as? [String: Any],
              let tools = plan["tools"] as? [[String: Any]] else { throw Self.unavailable() }
        guard let definition = tools.first(where: { $0["tool"] as? String == tool }) else { return nil }
        guard let root = Self.realpath(request.workspace.path) else { throw Self.unavailable() }
        let caseSensitive = (try? request.workspace.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        let generation = Self.generations.withLock { value -> UInt64 in value += 1; return value }
        let pin = core("toolchains.resolvePins", ["document": local.foundationObject, "directory": directory, "tool": tool])
        guard let pinResolution = pin?["resolution"] as? [String: Any] else { throw Self.unavailable() }
        let fixedHome: String?
        let fixedExecutable: String?
        switch fixed {
        case .installation(let home): fixedHome = home; fixedExecutable = nil
        case .executable(let path): fixedHome = nil; fixedExecutable = path
        case nil: fixedHome = (pinResolution["pin"] as? [String: Any])?["home"] as? String; fixedExecutable = nil
        }
        var queries: [[String: Any]] = []
        var reported: [[String: Any]] = []
        var context: [String: Any]?
        // Explicit pins do not depend on optional lower-layer providers.
        if fixedHome == nil && fixed == nil {
            let providers = Self.providers(of: [definition])
            guard providers.count <= 8 else { throw Self.unavailable() }
            for provider in providers {
                guard let current = await workspaceContext(request.workspace, provider.pluginID) else { throw Self.unavailable() }
                let identity: [String: Any] = ["contextID": current.contextID, "generation": current.generation]
                if let context, !NSDictionary(dictionary: context).isEqual(to: identity) { throw CancellationError() }
                context = identity
                switch await query(provider, operation: "toolchain-\(generation)", generation: generation,
                                   scope: (directory, current), registry: registry, tools: tools,
                                   root: root, caseSensitive: caseSensitive) {
                case .failure: throw Self.unavailable()
                case .unavailable(let input, let paths, _):
                    queries.append(input.merging(["filesystem": paths.map(Self.fact(of:))]) { $1 })
                case .success(let snapshot, let input, let paths):
                    queries.append(input.merging(["filesystem": paths.map(Self.fact(of:))]) { $1 })
                    reported += snapshot["installations"] as? [[String: Any]] ?? []
                }
            }
        }
        try Task.checkCancellation()
        // Only declared command names are searched. Core still checks the canonical
        // executable through the definition's layouts; PATH does not imply a home.
        let normalized = core("toolchains.registry", registry)?["registry"] as? [String: Any]
        let entry = (normalized?["definitions"] as? [[String: Any]])?.first {
            ($0["definition"] as? [String: Any])?["id"] as? String == tool
        }
        guard let declaration = entry?["definition"] as? [String: Any] else { throw Self.unavailable() }
        // Build's current tool context transports a program, not a template argv.
        // Dropping declared wrapper flags would change the plugin's semantics.
        guard !requiresDirectLaunch || declaration["launch"] as? [String] == ["${executable}", "${arguments}"] else { throw Self.unavailable() }
        let layouts = (definition["executableLayouts"] as? [[String: Any]] ?? []).filter(Self.applies)
            .compactMap { $0["path"] as? String }
        var commandHomes: [String: String] = [:]
        for command in (fixedHome != nil || fixed != nil ? [] : declaration["commands"] as? [String] ?? []) {
            for directory in (request.environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
                guard directory.hasPrefix("/") else { continue }
                let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
                guard let executable = Self.realpath(path), Self.fact(of: path)["executable"] as? Bool == true else { continue }
                if let layout = layouts.first(where: { executable.hasSuffix("/" + $0) }) {
                    commandHomes[command] = String(executable.dropLast(layout.count + 1))
                }
                break
            }
        }
        var scanner = Scanner(home: homeDirectory(), environment: request.environment, workspace: root, caseSensitive: caseSensitive)
        var consumerPlan = definition
        if fixedHome != nil || fixed != nil {
            consumerPlan["scans"] = []
            consumerPlan["environment"] = []
        }
        let input = scanner.input(tool: tool, plan: consumerPlan, reported: reported,
                                  additionalHomes: Array(commandHomes.values) + (fixedHome.map { [$0] } ?? []))
        var facts: [String: [String: Any]] = [:]
        func add(_ fact: [String: Any]) {
            guard let path = fact["path"] as? String else { return }
            facts[caseSensitive ? path : path.lowercased()] = fact
        }
        input.facts.forEach(add)
        if let fixedExecutable { add(Self.fact(of: fixedExecutable)) }
        for query in queries { (query["filesystem"] as? [[String: Any]] ?? []).forEach(add) }
        // Read project candidates and their markers at every exact ancestor.
        var ancestor = directory
        for _ in 0..<64 {
            let anchor = ancestor == "." ? root : root + "/" + ancestor
            for candidate in declaration["executables"] as? [[String: Any]] ?? [] where Self.applies(candidate) && fixedHome == nil && fixed == nil {
                guard candidate["kind"] as? String == "projectFile", let path = candidate["path"] as? String else { continue }
                add(Self.fact(of: anchor + "/" + path))
                for marker in candidate["requires"] as? [String] ?? [] { add(Self.fact(of: anchor + "/" + marker)) }
                if let home = candidate["home"] as? String { add(Self.fact(of: home == "." ? anchor : anchor + "/" + home)) }
            }
            if ancestor == "." { break }
            ancestor = ancestor.lastIndex(of: "/").map { String(ancestor[..<$0]) } ?? "."
        }
        guard facts.count <= Self.factBudget else { throw Self.unavailable() }
        let captured = facts.keys.sorted().compactMap { facts[$0] }
        let identities = captured.compactMap { $0["path"] as? String }.map {
            MacRuntimeProbeCache.key(executable: URL(fileURLWithPath: $0))
        }
        for index in queries.indices { queries[index]["filesystem"] = captured }
        var payload: [String: Any] = [
            "registry": registry, "tool": tool, "directory": directory, "operationID": "consumer-\(generation)",
            "generation": generation, "context": context as Any? ?? NSNull(), "platform": "macos",
            "filesystemCaseSensitive": caseSensitive, "workspaceRoot": root, "workspaceRoots": [root],
            "filesystem": captured, "local": local.foundationObject, "environment": input.environment,
            "commandHomes": commandHomes, "systemInstallations": input.installations, "queries": queries,
            "projectCodeAllowed": projectCodeAllowed, "probes": []
        ]
        if let minimumVersion { payload["minimumVersion"] = minimumVersion }
        var probeInput: [String: Any] = [
            "registry": registry, "tool": tool, "platform": "macos", "filesystemCaseSensitive": caseSensitive,
            "workspaceRoot": root, "filesystem": captured, "environment": input.environment,
            "systemInstallations": input.installations + (Array(commandHomes.values) + (fixedHome.map { [$0] } ?? [])).map { ["tool": tool, "home": $0] },
            "providerInstallations": input.reported, "probes": []
        ]
        if let fixed {
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixed))
            payload["fixed"] = value
            probeInput["fixed"] = value
            probeInput["projectCodeAllowed"] = projectCodeAllowed
        }
        guard let candidates = core("toolchains.candidates", probeInput)?["candidates"] as? [String: Any] else { throw Self.unavailable() }
        var targets = Self.probeTargets(candidates)
        if projectCodeAllowed {
            // Core first proves a project launcher without asking it for a version.
            // Only this explicit consumer action may probe that checked launcher;
            // the final resolution still enforces the original minimum version.
            var beforeVersion = payload
            beforeVersion.removeValue(forKey: "minimumVersion")
            let provisional = core("toolchains.resolve", beforeVersion)?["resolution"] as? [String: Any]
            let outcome = provisional?["outcome"] as? [String: Any]
            let selected = outcome?["selection"] as? [String: Any]
            if outcome?["kind"] as? String == "resolved", selected?["projectCode"] as? Bool == true,
               let executable = selected?["executable"] as? String {
                targets = minimumVersion == nil ? [] : [executable]
            }
        }
        guard targets.count <= Self.probeBudget else { throw Self.unavailable() }
        var probing = self
        let consumerProbe = self.consumerProbe
        probing.probe = { executable, arguments in consumerProbe(executable, arguments, request.environment) }
        let observed = await probing.probe(targets.map { Target(tool: tool, executable: $0, arguments: input.arguments) })
        try Task.checkCancellation()
        guard !observed.expired else { throw Self.unavailable() }
        if let context {
            for provider in Self.providers(of: [definition]) {
                guard let current = await workspaceContext(request.workspace, provider.pluginID),
                      current.contextID == context["contextID"] as? String,
                      current.generation == context["generation"] as? Int else { throw CancellationError() }
            }
        }
        payload["probes"] = observed.outputs.map { ["executable": $0.key.executable, "output": $0.value, "exitCode": 0] as [String: Any] }
        // Re-read native facts after asynchronous work. A changed path cannot retain
        // the earlier canonical-path or executable attestation.
        guard captured.allSatisfy({ fact in
            guard let path = fact["path"] as? String else { return false }
            return NSDictionary(dictionary: fact).isEqual(to: Self.fact(of: path))
        }), identities.allSatisfy({ MacRuntimeProbeCache.key(executable: URL(fileURLWithPath: $0.executablePath)) == $0 })
        else { throw CancellationError() }
        guard let resolution = core("toolchains.resolve", payload)?["resolution"] as? [String: Any],
              let outcome = resolution["outcome"] as? [String: Any] else { throw Self.unavailable() }
        guard outcome["kind"] as? String == "resolved", let selected = outcome["selection"] as? [String: Any],
              let executable = selected["executable"] as? String else { throw Self.unavailable() }
        var environment = request.environment.merging(selected["environment"] as? [String: String] ?? [:]) { _, new in new }
        let prepend = selected["pathPrepend"] as? [String] ?? []
        if !prepend.isEmpty { environment["PATH"] = (prepend + [environment["PATH"] ?? ""]).joined(separator: ":") }
        return Selection(executable: URL(fileURLWithPath: executable), environment: environment,
                         projectCode: selected["projectCode"] as? Bool == true, version: selected["version"] as? String,
                         home: selected["home"] as? String)
    }

    /// The tool registry Core reads: the enabled plugins that define tools or providers.
    static func registry(of sources: [ToolchainSettingsPluginSource]) -> [String: Any] {
        let plugins: [[String: Any]] = sources.filter(\.isEnabled).compactMap { source in
            guard let manifest = try? JSONSerialization.jsonObject(with: source.manifest) as? [String: Any],
                  manifest["toolDefinitions"] != nil || manifest["toolchainProviders"] != nil else { return nil }
            return ["manifest": manifest]
        }
        return ["plugins": plugins]
    }

    private static func unavailable() -> BuildToolResolutionError {
        BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
    }
}
