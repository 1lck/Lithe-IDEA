import CoreFoundation
import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Temporary format adapter for saved Run v1/v2 Maven entries, never a launch path.
/// Remove with D-MIGRATION-REMOVAL before stable N+2; see the #1495 remaining plan.
/// Installed packages stay read-only; preferences may create a private workspace local document.
struct MacLegacyMavenRunConfigurationMigration {
    struct Write {
        let url: URL
        let original: Data?
        let replacement: Data
    }
    struct Plan {
        let writes: [Write]
        var teamDocument: Data? = nil
        var localDocument: Data? = nil
        var preferenceMarker: (key: String, state: Int)? = nil
        var absentPreferenceKeys: [String] = []
        var preferenceSources: [String: Data] = [:]
        var preferenceNamespace: (prefix: String, keys: [String])? = nil
        var sources: [(url: URL, bytes: Data?)] = []
    }
    let storage: any FileStorage
    let preferences: any KeyValueStore
    let immutableRoots: [URL]

    private static let frameworks = ["spring-boot.maven", "quarkus.maven", "micronaut.maven"]
    private static let mavenFields: Set<String> = ["module", "reactorPath", "mainClass", "jvmArguments", "programArguments", "profiles", "skipTests"]
    private static let limit = 2 * 1024 * 1024

    func prepare(workspace: URL, projects: [RunProjectOwnership], runs: [RunProviderConfiguration],
                 models: [BuildModel] = [], generatedDocument: Data? = nil, lease: RunConfigurationGenerationLease) throws -> Plan {
        try lease.check()
        let candidates = runs.filter { $0.reference.pluginID == "io.github.lithe-idea.maven-build" && $0.reference.buildSystemID == "maven" }
        guard !candidates.isEmpty else { return Plan(writes: []) }
        var sources = try ["configurations.json", "local.json"].map { name -> (URL, Data?, [String: Any]) in
            let url = workspace.appendingPathComponent(".lithe/run/" + name)
            let data = try read(url, workspace: workspace)
            let document: [String: Any]
            if let data {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unsupported() }
                document = try normalizedDocument(parsed)
            } else { document = ["version": 2, "configurations": []] }
            return (url, data, document)
        }
        let aliases = legacyAliases(projects: projects, runs: candidates)
        let projectKey = workspace.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        let markerKey = "lithe.run-configuration-migrated.\(projectKey)"
        let marker = try preferenceMarker(markerKey)
        let storedIDs = sources.flatMap { ($0.2["configurations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        let prefix = "lithe.java-run-options.\(projectKey)."
        let listedKeys = marker == 2 ? nil : preferences.keys(withPrefix: prefix)
        let preferenceKeys = marker == 2 ? [] : Set(aliases.keys).union(storedIDs).map { prefix + $0 } + (listedKeys ?? [])
        guard preferenceKeys.count <= 10_000 else { throw unsupported() }
        var preferenceSources: [String: Data] = [:], absentKeys: [String] = []
        var preferenceByteCount = 0
        for key in Set(preferenceKeys).sorted() {
            guard let value = preferences.object(forKey: key) else { absentKeys.append(key); continue }
            guard let bytes = value as? Data, bytes.count <= Self.limit else { throw unsupported() }
            preferenceByteCount += bytes.count
            guard preferenceByteCount <= Self.limit else { throw unsupported() }
            preferenceSources[key] = bytes
        }
        let imported = try importPreferences(preferenceSources, prefix: prefix, sources: sources, aliases: aliases,
            models: models, generatedDocument: generatedDocument, workspace: workspace, canEnumerate: listedKeys != nil)
        sources[1].2 = imported.document
        if imported.changed, sources[1].1 == nil {
            let runtimeKey = "lithe.project-runtime.\(projectKey)"
            if let raw = preferences.object(forKey: runtimeKey) {
                guard let bytes = raw as? Data, bytes.count <= Self.limit else { throw unsupported() }
                let settings = try JSONDecoder().decode(ProjectRuntimeSettings.self, from: bytes)
                guard settings.javaHomePath.isEmpty, settings.mavenJavaHomePath.isEmpty,
                      settings.mavenHomeSelection == .automatic else { throw unsupported() }
                preferenceSources[runtimeKey] = bytes
            } else { absentKeys.append(runtimeKey) }
        }
        var cumulative: [String: [String: Any]] = [:]
        var writes: [Write] = []
        for (index, source) in sources.enumerated() {
            let (url, bytes, original) = source
            try lease.check()
            guard let items = original["configurations"] as? [[String: Any]], items.count <= 10_000 else { throw unsupported() }
            var document = original, transformed: [[String: Any]] = [], changed = index == 1 && imported.changed
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
                guard effective["command"] == nil else { throw unsupported() }
                guard ext["maven"] == nil || ext["maven"] is [String: Any] else { throw unsupported() }
                let maven = ext["maven"] as? [String: Any] ?? [:]
                guard Set(maven.keys).isSubset(of: Self.mavenFields) else { throw unsupported() }
                for field in ["module", "reactorPath", "mainClass"] {
                    if let value = maven[field], !(value is NSNull), !(value is String) { throw unsupported() }
                }
                try validateLegacyTools(effective, extensions: ext)
                // Linked project defaults need their own consumer model. Do not
                // silently discard them merely because this Run can be renamed.
                try rejectUnmigratedDefaults(sources[1].2)
                for runtimeKey in ["lithe.project-runtime.", "lithe.project-runtime-settings."].map({ $0 + projectKey }) {
                    if let raw = preferences.object(forKey: runtimeKey) {
                        guard let bytes = raw as? Data, bytes.count <= Self.limit else { throw unsupported() }
                        let settings = try JSONDecoder().decode(ProjectRuntimeSettings.self, from: bytes)
                        guard settings.javaHomePath.isEmpty, settings.mavenJavaHomePath.isEmpty,
                              settings.mavenHomeSelection == .automatic, settings.moduleOverrides.isEmpty else { throw unsupported() }
                        preferenceSources[runtimeKey] = bytes
                    } else { absentKeys.append(runtimeKey) }
                }
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
                // Keep even empty goals or unsupported runtime choices as data.
                // The provider owns their meaning and validation, never this adapter.
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
                if let ownJava = (item["extensions"] as? [String: Any])?["java"] as? [String: String] {
                    var tools: [String: Any] = [:]
                    for (field, id, key) in [("mavenExecutablePath", "io.github.lithe-idea.maven-build:maven", "executable"),
                                              ("mavenJavaHomePath", "java", "home")] {
                        if let value = ownJava[field] {
                            tools[id] = value.isEmpty ? NSNull() : [key: value]
                        }
                    }
                    if !tools.isEmpty { choices["tools"] = tools }
                }
                choices["options"] = options
                resultExtensions["build-run"] = choices
                result["extensions"] = resultExtensions
                transformed.append(result); changed = true
            }
            if changed {
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
            plan.absentPreferenceKeys = absentKeys
            plan.preferenceSources = preferenceSources
            plan.preferenceNamespace = listedKeys.map { (prefix, $0.sorted()) }
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
        var createdDirectories: [URL] = []
        do {
            for write in plan.writes {
                try lease.check()
                try verifyPreferences(plan)
                try verifySources(plan, completed: completed, workspace: workspace)
                try validate(write.url, workspace: workspace)
                if write.original == nil {
                    for path in [".lithe", ".lithe/run"] {
                        let directory = workspace.appendingPathComponent(path)
                        try validate(directory, workspace: workspace)
                        if mkdir(directory.path, 0o700) == 0 { createdDirectories.append(directory) }
                        else if errno != EEXIST { throw CocoaError(.fileWriteNoPermission) }
                        guard storage.metadata(for: directory)?.isDirectory == true else { throw unsupported() }
                    }
                    try lease.check()
                    try verifySources(plan, completed: completed, workspace: workspace)
                }
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
                    let restored = try write.original.map { try storage.replaceDataPreservingMetadata($0, at: write.url, expecting: write.replacement) }
                        ?? storage.removeData(at: write.url, expecting: write.replacement)
                    if restored {
                        MacFileWriteEventSuppression.markWritten(write.url)
                    } else { rollbackFailed = true }
                } catch { rollbackFailed = true }
            }
            for directory in createdDirectories.reversed() {
                // rmdir removes only an empty directory; another writer's files survive.
                if (try? validate(directory, workspace: workspace)) != nil { _ = rmdir(directory.path) }
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
                  plan.absentPreferenceKeys.allSatisfy({ preferences.object(forKey: $0) == nil }),
                  plan.preferenceSources.allSatisfy({ preferences.data(forKey: $0.key) == $0.value }) else { throw conflict() }
            if let namespace = plan.preferenceNamespace {
                guard preferences.keys(withPrefix: namespace.prefix)?.sorted() == namespace.keys else { throw conflict() }
            }
        }
    }

    /// Import all observable active preferences before creating local.json; the
    /// old importer uses that file's existence as its cutover boundary, including
    /// for Java entries. Existing local fields always win over retired values.
    private func importPreferences(_ values: [String: Data], prefix: String,
                                   sources: [(URL, Data?, [String: Any])], aliases: [String: [RunProviderConfiguration]],
                                   models: [BuildModel], generatedDocument: Data?, workspace: URL,
                                   canEnumerate: Bool) throws -> (document: [String: Any], changed: Bool) {
        var records: [String: [String: Any]] = [:]
        for source in sources {
            for item in source.2["configurations"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { throw unsupported() }
                records[id] = try merge(records[id] ?? [:], item)
            }
        }
        let legacyRecord = records.values.contains { item in
            let provider = item["provider"] as? String
            return provider == "maven.module" || Self.frameworks.contains(provider ?? "")
                || (provider == nil && aliases[item["id"] as? String ?? ""] != nil)
        }
        let hasLegacyPreference = values.keys.contains { key in
            let id = String(key.dropFirst(prefix.count))
            return aliases[id] != nil && records[id]?["provider"] as? String != "build.provider"
        }
        guard legacyRecord || hasLegacyPreference, !values.isEmpty else { return (sources[1].2, false) }
        if sources[1].1 == nil && !canEnumerate { throw unsupported() }
        var generated: [String: [String: Any]] = [:]
        if let generatedDocument {
            guard let parsed = try JSONSerialization.jsonObject(with: generatedDocument) as? [String: Any],
                  let entries = parsed["configurations"] as? [[String: Any]] else { throw unsupported() }
            for item in entries { if let id = item["id"] as? String { generated[id] = item } }
        }
        var document = sources[1].2
        var local = document["configurations"] as? [[String: Any]] ?? []
        var changed = false
        for key in values.keys.sorted() {
            let id = String(key.dropFirst(prefix.count))
            guard records[id]?["provider"] as? String != "build.provider" else { continue }
            var record = records[id] ?? generated[id] ?? [:]
            if record["provider"] == nil, let choices = aliases[id] {
                guard choices.count == 1, let target = choices.first else { throw unsupported() }
                let targets = models.flatMap { $0.targets }.filter { $0.projectID == target.reference.projectID && $0.id == target.reference.targetID }
                guard targets.count == 1, let provider = targets.first?.name, Self.frameworks.contains(provider) else { throw unsupported() }
                let root = target.reference.root
                let module = target.projectPath == root ? "." : root == "." ? target.projectPath : String(target.projectPath.dropFirst(root.count + 1))
                record = ["id": id, "name": target.name, "provider": provider, "execution": "service", "cwd": root,
                          "extensions": ["maven": ["reactorPath": root, "module": module]]]
            }
            guard let provider = record["provider"] as? String else { throw unsupported() }
            let isMaven = provider == "maven.module" || Self.frameworks.contains(provider)
            let options = try legacyPreference(values[key]!)
            if isMaven, !options.javaHomePath.isEmpty { throw unsupported() }
            var patch: [String: Any] = ["id": id, "env": options.environment]
            if !options.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let raw = options.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let directory = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : workspace.appendingPathComponent(raw)).resolvingSymlinksInPath().standardizedFileURL
                let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
                guard storage.metadata(for: directory)?.isDirectory == true,
                      directory.path == root || directory.path.hasPrefix(root + "/") else { throw unsupported() }
                patch["cwd"] = directory.path == root ? "." : String(directory.path.dropFirst(root.count + 1))
            }
            var java: [String: String] = [:]
            for (field, value) in [("homePath", options.javaHomePath), ("mavenExecutablePath", options.mavenExecutablePath), ("mavenJavaHomePath", options.mavenJavaHomePath)] where !value.isEmpty { java[field] = value }
            var extensions: [String: Any] = java.isEmpty ? [:] : ["java": java]
            if isMaven || ["java.main", "java.current-file"].contains(provider) {
                var maven: [String: Any] = ["jvmArguments": legacyArguments(options.vmArguments), "programArguments": legacyArguments(options.programArguments),
                                            "profiles": options.activeProfiles.sorted()]
                if let skip = options.mavenSkipTests { maven["skipTests"] = skip }
                extensions["maven"] = maven
            } else { patch["args"] = legacyArguments(options.programArguments) }
            if !extensions.isEmpty { patch["extensions"] = extensions }
            // A preference-only Maven record needs its current, proven identity.
            if isMaven, records[id] == nil { patch = try merge(record, patch) }
            if let index = local.firstIndex(where: { $0["id"] as? String == id }) {
                local[index] = try merge(patch, local[index])
            } else { local.append(patch) }
            changed = true
        }
        document["configurations"] = local
        return (document, changed)
    }

    private func legacyPreference(_ bytes: Data) throws -> RunOptions {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(value.keys).isSubset(of: ["workingDirectoryPath", "arguments", "programArguments", "environment", "java", "javaHomePath", "vmArguments", "activeProfiles"]) else { throw unsupported() }
        if let java = value["java"], !(java is NSNull) {
            guard let object = java as? [String: Any], Set(object.keys).isSubset(of: ["homePath", "mavenExecutablePath", "mavenJavaHomePath", "vmArguments", "activeMavenProfiles", "skipTests"]) else { throw unsupported() }
        }
        return try JSONDecoder().decode(RunOptions.self, from: bytes)
    }

    /// The retired preference writer used this text grammar, including dropping
    /// empty quoted tokens. It performs no expansion or shell execution.
    private func legacyArguments(_ text: String) -> [String] {
        var result: [String] = [], current = "", quote: Character?, escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" && quote != "'" { escaped = true }
            else if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(character) }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
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

    private func validateLegacyTools(_ item: [String: Any], extensions: [String: Any]) throws {
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
                  values["homePath", default: ""].isEmpty else { throw unsupported() }
            // Validate the inert choice through its typed decoder. Core's full
            // preflight validates the lexical absolute path before publication.
            for (field, key) in [("mavenExecutablePath", "executable"), ("mavenJavaHomePath", "home")] {
                if let value = values[field], !value.isEmpty {
                    guard value.utf8.count <= 4096, !value.contains(where: \.isNewline) else { throw unsupported() }
                    _ = try JSONDecoder().decode(FixedToolchainSelection.self,
                        from: JSONSerialization.data(withJSONObject: [key: value]))
                }
            }
        }
    }

    private func rejectUnmigratedDefaults(_ document: [String: Any]) throws {
        guard let raw = document["toolchain"] else { return }
        guard let tools = raw as? [String: Any] else { throw unsupported() }
        for (namespace, fields) in [("java", ["homePath"]), ("maven", ["executablePath", "javaHomePath"])] {
            if let raw = tools[namespace] {
                guard let values = raw as? [String: String], fields.allSatisfy({ values[$0, default: ""].isEmpty }) else { throw unsupported() }
            }
        }
        if let raw = tools["pathOverrides"] {
            guard let overrides = raw as? [String: [String: String]],
                  overrides.values.allSatisfy({ $0.values.allSatisfy(\.isEmpty) }) else { throw unsupported() }
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

    /// Retired v1 fields are a private saved format. Convert the whole document
    /// when one Maven record changes, so unrelated Java records remain readable.
    private func normalizedDocument(_ original: [String: Any]) throws -> [String: Any] {
        guard let version = original["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version == 1 || version == 2 else { throw unsupported() }
        guard version == 1 else { return original }
        guard let items = original["configurations"] as? [[String: Any]], items.count <= 10_000 else { throw unsupported() }
        var document = original
        document["version"] = 2
        document["configurations"] = try items.map { item in
            guard item["provider"] == nil, item["cwd"] == nil else { throw unsupported() }
            var result = item
            var extensions = item["extensions"] as? [String: Any] ?? [:]
            guard item["extensions"] == nil || item["extensions"] is [String: Any],
                  extensions["maven"] == nil else { throw unsupported() }
            var maven: [String: Any] = [:]
            for (old, current) in [("module", "module"), ("mainClass", "mainClass"), ("jvmArguments", "jvmArguments"),
                                   ("programArguments", "programArguments"), ("mavenProfiles", "profiles")] {
                if let value = result.removeValue(forKey: old), !(value is NSNull), !((value as? [Any])?.isEmpty == true) {
                    maven[current] = value
                }
            }
            if !maven.isEmpty { extensions["maven"] = maven }
            if !extensions.isEmpty { result["extensions"] = extensions }
            if let cwd = result.removeValue(forKey: "workingDirectory") { result["cwd"] = cwd }
            if let raw = result.removeValue(forKey: "type") {
                guard let provider = raw as? String, !provider.isEmpty else { throw unsupported() }
                result["provider"] = provider
                result["execution"] = provider == "java.current-file" || provider == "java.main" ? "application"
                    : Self.frameworks.contains(provider) ? "service" : "task"
                result["confidence"] = "native"
                if result["debug"] == nil { result["debug"] = ["adapter": "jdwp"] }
            }
            return result
        }
        return document
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
