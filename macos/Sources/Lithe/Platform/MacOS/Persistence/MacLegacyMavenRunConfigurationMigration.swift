import CoreFoundation
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Temporary format adapter for saved Run v2 Maven entries only, never a launch path.
/// Remove with D-MIGRATION-REMOVAL before stable N+2; see the #1495 remaining plan.
/// Installed packages stay read-only; only existing workspace Run documents are replaced.
struct MacLegacyMavenRunConfigurationMigration {
    struct Write {
        let url: URL
        let original: Data
        let replacement: Data
    }
    struct Plan {
        let writes: [Write]
        var teamDocument: Data? = nil
        var localDocument: Data? = nil
        var preferenceMarker: (key: String, state: Int)? = nil
        var absentPreferenceKeys: [String] = []
        var sources: [(url: URL, bytes: Data?)] = []
    }
    let storage: any FileStorage
    let preferences: any KeyValueStore
    let immutableRoots: [URL]

    private static let frameworks = ["spring-boot.maven", "quarkus.maven", "micronaut.maven"]
    private static let mavenFields: Set<String> = ["module", "reactorPath", "mainClass", "jvmArguments", "programArguments", "profiles", "skipTests"]
    private static let limit = 2 * 1024 * 1024

    func prepare(workspace: URL, projects: [RunProjectOwnership], runs: [RunProviderConfiguration],
                 models: [BuildModel] = [], lease: RunConfigurationGenerationLease) throws -> Plan {
        try lease.check()
        let candidates = runs.filter { $0.reference.pluginID == "io.github.lithe-idea.maven-build" && $0.reference.buildSystemID == "maven" }
        guard !candidates.isEmpty else { return Plan(writes: []) }
        let sources = try ["configurations.json", "local.json"].map { name -> (URL, Data?, [String: Any]) in
            let url = workspace.appendingPathComponent(".lithe/run/" + name)
            let data = try read(url, workspace: workspace)
            let document: [String: Any]
            if let data {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unsupported() }
                document = parsed
            } else { document = ["version": 2, "configurations": []] }
            return (url, data, document)
        }
        let aliases = legacyAliases(projects: projects, runs: candidates)
        let projectKey = workspace.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        let markerKey = "lithe.run-configuration-migrated.\(projectKey)"
        let marker = try preferenceMarker(markerKey)
        let storedIDs = sources.flatMap { ($0.2["configurations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        let preferenceKeys = marker == 2 ? [] : Set(aliases.keys).union(storedIDs).sorted().map { "lithe.java-run-options.\(projectKey).\($0)" }
        // Saved IDs can differ from old generated aliases. Do not migrate over
        // active retired choices; recheck their absence throughout publication.
        guard preferenceKeys.allSatisfy({ preferences.object(forKey: $0) == nil }) else { throw unsupported() }
        var cumulative: [String: [String: Any]] = [:]
        var writes: [Write] = []
        for (url, bytes, original) in sources {
            try lease.check()
            guard let items = original["configurations"] as? [[String: Any]], items.count <= 10_000 else { throw unsupported() }
            var document = original, transformed: [[String: Any]] = [], changed = false
            var seen = Set<String>()
            for item in items {
                guard let id = item["id"] as? String, seen.insert(id).inserted else { throw unsupported() }
                let previous = cumulative[id]
                let effective = try merge(previous ?? [:], item)
                cumulative[id] = effective
                let provider = effective["provider"] as? String ?? effective["type"] as? String
                if provider == nil && Self.frameworks.contains(where: { id.hasPrefix($0 + ":") }) && aliases[id] == nil { throw unsupported() }
                if provider == "build.provider", ((effective["extensions"] as? [String: Any])?["build"] as? [String: Any])?["pluginID"] as? String == "io.github.lithe-idea.maven-build",
                   ((item["extensions"] as? [String: Any])?["maven"]) != nil { throw unsupported() }
                let legacy = provider == "maven.module" || Self.frameworks.contains(provider ?? "") || (provider == nil && aliases[id] != nil)
                guard legacy else { transformed.append(item); continue }
                let ext = effective["extensions"] as? [String: Any] ?? [:]
                if let java = ext["java"] as? [String: Any], let source = java["source"] as? String, source.lowercased().hasSuffix(".java") {
                    transformed.append(item); continue // JDT-owned Java entries remain stage E.
                }
                guard let version = original["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 2,
                      effective["command"] == nil else { throw unsupported() }
                guard ext["maven"] == nil || ext["maven"] is [String: Any] else { throw unsupported() }
                let maven = ext["maven"] as? [String: Any] ?? [:]
                guard Set(maven.keys).isSubset(of: Self.mavenFields) else { throw unsupported() }
                for field in ["module", "reactorPath", "mainClass"] {
                    if let value = maven[field], !(value is NSNull), !(value is String) { throw unsupported() }
                }
                try rejectToolOverrides(effective, extensions: ext)
                let execution: BuildExecution = provider == "maven.module" ? .task : .service
                var matches = aliases[id] ?? candidates.filter { $0.reference.execution == execution }
                matches = matches.filter { candidate in
                    if let root = maven["reactorPath"] as? String, root != candidate.reference.root { return false }
                    if let module = maven["module"] as? String {
                        let path = module == "." ? candidate.reference.root : candidate.reference.root == "." ? module : candidate.reference.root + "/" + module
                        if path != candidate.projectPath { return false }
                    }
                    return candidate.reference.execution == execution
                }
                guard matches.count == 1, let target = matches.first else { throw unsupported() }
                let expectedProvider = provider ?? Self.frameworks.first { id.hasPrefix($0 + ":") }
                let modelTargets = models.flatMap { model -> [BuildModel.Target] in
                    guard model.projects.contains(where: { $0.id == target.reference.projectID && $0.path == target.projectPath }) else { return [] }
                    return model.targets.filter { $0.projectID == target.reference.projectID && $0.id == target.reference.targetID }
                }
                guard modelTargets.count == 1, modelTargets.first?.name == expectedProvider else { throw unsupported() }
                var result = item
                result["provider"] = "build.provider"
                result["name"] = effective["name"] as? String ?? target.name
                result["execution"] = execution.rawValue
                if result["cwd"] == nil && previous == nil { result["cwd"] = target.reference.root }
                result.removeValue(forKey: "toolchains"); result.removeValue(forKey: "debug")
                let arguments = try strings(maven["programArguments"])
                let effectiveArguments = execution == .task ? try strings(effective["args"]) + arguments : arguments
                // Old application-style module entries need provider-owned migration;
                // do not turn a class launch or an implicit goal into another command.
                if execution == .task {
                    guard !effectiveArguments.isEmpty, try strings(maven["jvmArguments"]).isEmpty,
                          (maven["mainClass"] as? String ?? "").isEmpty else { throw unsupported() }
                }
                result["args"] = effectiveArguments
                var resultExtensions = item["extensions"] as? [String: Any] ?? [:]
                guard resultExtensions["build"] == nil, resultExtensions["build-run"] == nil else { throw unsupported() }
                resultExtensions.removeValue(forKey: "maven"); resultExtensions.removeValue(forKey: "java")
                resultExtensions["build"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target.reference))
                var choices: [String: Any] = [:], options: [String: Any] = [:]
                if let own = (item["extensions"] as? [String: Any])?["maven"] as? [String: Any] {
                    if own.keys.contains("jvmArguments") { choices["runtimeArguments"] = try strings(own["jvmArguments"]) }
                    if own.keys.contains("mainClass") {
                        guard own["mainClass"] == nil || own["mainClass"] is NSNull || own["mainClass"] is String else { throw unsupported() }
                        choices["entrypoint"] = own["mainClass"] as? String ?? ""
                    }
                }
                let profiles = try strings(maven["profiles"])
                if !profiles.isEmpty { options["profiles"] = profiles }
                if let skip = maven["skipTests"], !(skip is NSNull) {
                    guard let bool = skip as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { throw unsupported() }
                    options["skipTests"] = bool
                }
                choices["options"] = options
                resultExtensions["build-run"] = choices
                result["extensions"] = resultExtensions
                transformed.append(result); changed = true
            }
            if changed, let bytes {
                try validate(url, workspace: workspace)
                document["configurations"] = transformed
                let replacement = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
                guard replacement.count <= Self.limit else { throw unsupported() }
                writes.append(Write(url: url, original: bytes, replacement: replacement))
            }
        }
        var plan = Plan(writes: writes)
        if !writes.isEmpty {
            plan.sources = sources.map { (url: $0.0, bytes: $0.1) }
            plan.preferenceMarker = (markerKey, marker)
            plan.absentPreferenceKeys = preferenceKeys
            plan.teamDocument = try writes.first { $0.url == sources[0].0 }?.replacement ?? sources[0].1
                ?? JSONSerialization.data(withJSONObject: sources[0].2)
            plan.localDocument = try writes.first { $0.url == sources[1].0 }?.replacement ?? sources[1].1
                ?? JSONSerialization.data(withJSONObject: sources[1].2)
        }
        return plan
    }

    /// All plans are prepared before the first write; every publication and rollback uses CAS.
    func apply(_ plan: Plan, workspace: URL, lease: RunConfigurationGenerationLease) throws {
        try lease.check()
        try verifyPreferences(plan)
        try verifySources(plan, completed: [], workspace: workspace)
        var completed: [Write] = []
        do {
            for write in plan.writes {
                try lease.check()
                try verifyPreferences(plan)
                try verifySources(plan, completed: completed, workspace: workspace)
                try validate(write.url, workspace: workspace)
                guard try storage.replaceDataPreservingMetadata(write.replacement, at: write.url, expecting: write.original) else { throw conflict() }
                completed.append(write)
                MacFileWriteEventSuppression.markWritten(write.url)
            }
            try lease.check()
            try verifyPreferences(plan)
            try verifySources(plan, completed: completed, workspace: workspace)
        } catch {
            var rollbackFailed = false
            for write in completed.reversed() {
                // Another writer's bytes always win; keep trying the other files
                // even when one destination can no longer be rolled back.
                do {
                    try validate(write.url, workspace: workspace)
                    if try storage.replaceDataPreservingMetadata(write.original, at: write.url, expecting: write.replacement) {
                        MacFileWriteEventSuppression.markWritten(write.url)
                    } else { rollbackFailed = true }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw conflict() }
            throw error
        }
    }

    private func verifySources(_ plan: Plan, completed: [Write], workspace: URL) throws {
        for source in plan.sources {
            let expected = completed.first(where: { $0.url == source.url })?.replacement ?? source.bytes
            guard try read(source.url, workspace: workspace) == expected else { throw conflict() }
        }
    }

    private func preferenceMarker(_ key: String) throws -> Int {
        guard let raw = preferences.object(forKey: key) else { return 0 }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw unsupported() }
        return value.boolValue ? 2 : 1
    }
    private func verifyPreferences(_ plan: Plan) throws {
        if let marker = plan.preferenceMarker {
            guard try preferenceMarker(marker.key) == marker.state,
                  plan.absentPreferenceKeys.allSatisfy({ preferences.object(forKey: $0) == nil }) else { throw conflict() }
        }
    }

    private func legacyAliases(projects: [RunProjectOwnership], runs: [RunProviderConfiguration]) -> [String: [RunProviderConfiguration]] {
        var result: [String: [RunProviderConfiguration]] = [:]
        for run in runs where run.reference.execution == .service {
            guard let owner = projects.first(where: { $0.path == run.projectPath }), let name = owner.name else { continue }
            let root = run.reference.root
            guard root == "." || run.projectPath == root || run.projectPath.hasPrefix(root + "/") else { continue }
            let module = run.projectPath == root ? "." : root == "." ? run.projectPath : String(run.projectPath.dropFirst(root.count + 1))
            // Retired generators used the label or module path. Keep both
            // spellings, and reject any collision instead of guessing a root.
            for label in Set([name, module]) {
                for framework in Self.frameworks {
                    let id = framework + ":" + (root == "." ? "" : root + "/") + label
                    result[id, default: []].append(run)
                }
            }
        }
        return result
    }

    private func rejectToolOverrides(_ item: [String: Any], extensions: [String: Any]) throws {
        if let debug = item["debug"], !(debug is NSNull) {
            guard let values = debug as? [String: String], values == ["adapter": "jdwp"] else { throw unsupported() }
        }
        if let tools = item["toolchains"] {
            guard let values = tools as? [String: String], values.allSatisfy({ key, value in
                (key == "java" && value == "project-jdk") || (key == "maven" && value == "project-maven")
            }) else { throw unsupported() }
        }
        if let java = extensions["java"] {
            guard let values = java as? [String: String], Set(values.keys).isSubset(of: ["homePath", "mavenExecutablePath", "mavenJavaHomePath"]),
                  values.values.allSatisfy(\.isEmpty) else { throw unsupported() }
        }
    }

    private func merge(_ base: [String: Any], _ patch: [String: Any]) throws -> [String: Any] {
        var result = base.merging(patch) { _, value in value }
        if let raw = patch["extensions"] {
            guard let incoming = raw as? [String: Any], base["extensions"] == nil || base["extensions"] is [String: Any] else { throw unsupported() }
            var extensions = base["extensions"] as? [String: Any] ?? [:]
            for (namespace, value) in incoming {
                if let old = extensions[namespace] as? [String: Any], let values = value as? [String: Any] {
                    extensions[namespace] = old.merging(values) { _, next in next }
                } else { extensions[namespace] = value }
            }
            result["extensions"] = extensions
        }
        return result
    }

    private func strings(_ value: Any?) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let strings = value as? [String], strings.count <= 1024, strings.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65536 }) else { throw unsupported() }
        return strings
    }

    private func validate(_ url: URL, workspace: URL, writable: Bool = true) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/"), !writable || !immutableRoots.contains(where: {
            let immutable = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return path == immutable || path.hasPrefix(immutable + "/")
        }) else { throw unsupported() }
    }
    private func read(_ url: URL, workspace: URL) throws -> Data? {
        try validate(url, workspace: workspace, writable: false)
        guard storage.fileExists(at: url) else { return nil }
        guard let metadata = storage.metadata(for: url), metadata.isRegularFile, let size = metadata.byteCount, size <= Self.limit else { throw unsupported() }
        let data = try storage.readData(from: url, options: [])
        guard data.count <= Self.limit else { throw unsupported() }
        return data
    }
    private func unsupported() -> any Error {
        MacRunConfigurationStoreError.invalidConfiguration(L10n.string("Some saved run configurations cannot be migrated yet. Keep the existing files and retry after updating Lithe and its build plugin."))
    }
    private func conflict() -> any Error {
        MacRunConfigurationStoreError.invalidConfiguration(L10n.string("Run configuration changed while saving. Reload and try again."))
    }
}
