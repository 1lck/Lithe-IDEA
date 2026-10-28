import Foundation
import LitheModuleAPI
import LitheCoreContracts

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

/// Picks the executable of a build-system run from the candidates Rust Core
/// ordered. Runtimes come first, so a tool found through them sees the
/// same `JAVA_HOME` and `PATH` its probe ran with.
///
/// Bare commands resolve through the host's tool discovery, never to a
/// project-local copy: only a declared `projectFile` candidate may run code
/// the repository ships, and it is never probed before the user runs it.
@MainActor
final class MacBuildToolResolver: BuildToolResolving {
    private static let probeTimeoutMilliseconds = 15_000

    private let runtime: ProjectRuntimeService
    private let processRunner: any ProcessRunner
    private let fileStorage: any FileStorage
    private let toolchains: RunToolchainRegistry
    /// Probe output by executable, arguments, and modification date, so a
    /// repeated run does not start the same probe again.
    private var probeOutputs: [String: String] = [:]

    init(runtime: ProjectRuntimeService, processRunner: any ProcessRunner, fileStorage: any FileStorage,
         toolchains: RunToolchainRegistry? = nil) {
        self.runtime = runtime
        self.processRunner = processRunner
        self.fileStorage = fileStorage
        self.toolchains = toolchains ?? .standard()
    }

    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        var environment = runtime.processEnvironment()
        var runtimeExecutables: [String: URL] = [:]
        for dependency in invocation.runtimeDependencies {
            runtimeExecutables[dependency.id] = try await resolveRuntime(
                dependency,
                invocation: invocation,
                workspaceURL: workspaceURL,
                environment: &environment,
                checkVersion: checkVersion
            )
        }

        var problems: [String] = []
        let resolver = candidateResolver(runtimeExecutables, workspaceURL: workspaceURL)
        for candidate in invocation.executables {
            switch resolver.resolve(candidate, workspaceURL: workspaceURL, environment: environment, environmentInputs: invocation.environmentInputs) {
            case .skip: continue
            case .terminalFailure(let message): throw BuildToolResolutionError(message, terminal: true)
            case .resolved(let choices):
                for choice in choices {
                    var selectedEnvironment = environment.merging(choice.environment) { _, selected in selected }
                    if choice.terminal {
                        selectedEnvironment["PATH"] = choice.url.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
                    }
                    if choice.executesProjectCode {
                        return resolved(choice.url, environment: selectedEnvironment, projectCode: true, version: nil)
                    }
                    do {
                        if let tool = try await accept(choice.url, invocation: invocation, environment: selectedEnvironment,
                                                       checkVersion: checkVersion, problems: &problems) { return tool }
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw BuildToolResolutionError(error.localizedDescription, terminal: choice.terminal) }
                    if choice.terminal { throw BuildToolResolutionError(Self.unavailableMessage(displayName, problems: problems), terminal: true) }
                }
            }
        }
        throw BuildToolResolutionError(Self.unavailableMessage(displayName, problems: problems))
    }

    /// Project import needs the installation path for global settings, but
    /// must not run build code or a version probe merely by opening a project.
    func languageImportExecutable(_ invocation: BuildInvocation, workspaceURL: URL) -> URL? {
        let environment = runtime.processEnvironment()
        let resolver = candidateResolver([:], workspaceURL: workspaceURL, passive: true)
        for candidate in invocation.executables {
            // No runtime selection or version probes during passive import.
            switch resolver.resolve(candidate, workspaceURL: workspaceURL, environment: environment, environmentInputs: invocation.environmentInputs) {
            case .skip: continue
            case .terminalFailure: return nil
            case .resolved(let choices): return choices.first?.url
            }
        }
        return nil
    }

    private func candidateResolver(_ runtimes: [String: URL], workspaceURL: URL, passive: Bool = false) -> ExecutableCandidateResolver {
        ExecutableCandidateResolver(fileExists: { [fileStorage] in fileStorage.fileExists(at: $0) },
            isExecutable: { [fileStorage] in fileStorage.metadata(for: $0)?.isDirectory == false && fileStorage.isExecutable(at: $0) },
            commands: { [self] in commandCandidates($0) }, runtimes: { runtimes[$0] },
            toolchains: { [self] id, root in
                guard runtime.reloadSettings() else { return .terminalFailure(runtime.settingsError ?? "") }
                let options = runtime.settings.overlay(onto: RunOptions(), workspaceRelativePath: root)
                let project = root == "." ? workspaceURL : workspaceURL.appendingPathComponent(root)
                do {
                    let tool: ResolvedRunToolchain
                    if passive {
                        guard let selected = try toolchains.resolvePassive(identifier: id, projectURL: project, options: options, runtimeService: runtime) else {
                            return .terminalFailure(L10n.string("The selected toolchain is unavailable."))
                        }
                        tool = selected
                    } else {
                        tool = try toolchains.resolve(identifier: id, projectURL: project, options: options, runtimeService: runtime)
                    }
                    guard fileStorage.isExecutable(at: tool.executableURL), fileStorage.metadata(for: tool.executableURL)?.isDirectory == false else {
                        return .terminalFailure(L10n.string("The configured build tool is not executable: \(tool.executableURL.path)"))
                    }
                    // A registry selection can still be a repository wrapper.
                    // Preserve its trust boundary even through a file alias.
                    let roots = [workspaceURL.standardizedFileURL, workspaceURL.resolvingSymlinksInPath()]
                    let paths = [tool.executableURL.standardizedFileURL, tool.executableURL.resolvingSymlinksInPath()]
                    let projectCode = paths.contains { path in roots.contains { path.path == $0.path || path.path.hasPrefix($0.path + "/") } }
                    return .resolved([ResolvedExecutableCandidate(url: tool.executableURL,
                        executesProjectCode: projectCode, terminal: true, environment: tool.environment)])
                } catch { return .terminalFailure(error.localizedDescription) }
            })
    }

    /// Keeps a candidate when the build tool declares no minimum version or
    /// its probe satisfies it.
    private func accept(
        _ url: URL,
        invocation: BuildInvocation,
        environment: [String: String],
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck,
        problems: inout [String]
    ) async throws -> ResolvedBuildTool? {
        guard let arguments = invocation.versionArguments, let minimum = invocation.minimumVersion else {
            return resolved(url, environment: environment, projectCode: false, version: nil)
        }
        let output = await probe(url, arguments: arguments, environment: environment)
        let check = try checkVersion(nil, output)
        guard check.satisfied else {
            problems.append(Self.tooOldMessage(url.path, found: check.version, minimum: minimum))
            return nil
        }
        return resolved(url, environment: environment, projectCode: false, version: check.version)
    }

    private func resolved(_ url: URL, environment: [String: String], projectCode: Bool, version: String?) -> ResolvedBuildTool {
        let base = runtime.processEnvironment()
        let inputs = environment.filter { key, value in key == "JAVA_HOME" || key == "PATH" || base[key] != value }
        return ResolvedBuildTool(executableURL: url, environment: environment, executesProjectCode: projectCode,
            version: version, providerEnvironment: inputs)
    }

    /// Resolves one runtime and puts it first on `PATH`. `java`, `node`, and
    /// `go` follow the user's runtime settings; any other runtime is found
    /// through the candidates it declares.
    private func resolveRuntime(
        _ dependency: BuildInvocation.RuntimeDependency,
        invocation: BuildInvocation,
        workspaceURL: URL,
        environment: inout [String: String],
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> URL {
        let name = dependency.displayName ?? dependency.id
        let javaHome = dependency.hostManaged && dependency.id == "java" && dependency.executables.isEmpty ? runtime.javaHomeURL() : nil
        let sources: [ExecutableCandidate] = dependency.hostManaged && dependency.executables.isEmpty
            ? (dependency.id == "java" ? [.runtime("java")] : [.command(dependency.id)])
            : dependency.executables
        let resolver = candidateResolver(javaHome.map { ["java": $0.appendingPathComponent("bin/java")] } ?? [:], workspaceURL: workspaceURL)
        var problems: [String] = []
        for source in sources {
            switch resolver.resolve(source, workspaceURL: workspaceURL, environment: environment, environmentInputs: invocation.environmentInputs) {
            case .skip: continue
            case .terminalFailure(let message): throw BuildToolResolutionError(message, terminal: true)
            case .resolved(let choices):
                for choice in choices {
                    // Probes and execution need the same PATH, including helpers
                    // next to a selected runtime. Failed candidates must not
                    // contribute their environment to the next choice.
                    var selectedEnvironment = environment.merging(choice.environment) { _, selected in selected }
                    if let javaHome { selectedEnvironment["JAVA_HOME"] = javaHome.path }
                    let directory = choice.url.deletingLastPathComponent().path
                    let path = selectedEnvironment["PATH"] ?? ""
                    selectedEnvironment["PATH"] = path.isEmpty ? directory : directory + ":" + path
                    if !choice.executesProjectCode,
                       let minimum = dependency.minimumVersion, let arguments = dependency.versionArguments {
                        let output = await probe(choice.url, arguments: arguments, environment: selectedEnvironment)
                        let check: BuildVersionCheck
                        do { check = try checkVersion(dependency.id, output) }
                        catch { throw BuildToolResolutionError(error.localizedDescription, terminal: choice.terminal) }
                        guard check.satisfied else {
                            problems.append(Self.tooOldMessage(choice.url.path, found: check.version, minimum: minimum))
                            if choice.terminal { throw BuildToolResolutionError(Self.unavailableMessage(name, problems: problems), terminal: true) }
                            continue
                        }
                    }
                    environment = selectedEnvironment
                    return choice.url
                }
            }
        }
        throw BuildToolResolutionError(Self.unavailableMessage(name, problems: problems))
    }

    private func commandCandidates(_ command: String) -> [URL] {
        runtime.executableCandidates(command)
            .filter { $0.source != .project }
            .map(\.executableURL)
    }

    private func probe(_ url: URL, arguments: [String], environment: [String: String]) async -> String {
        let modified = fileStorage.metadata(for: url)?.modificationDate?.timeIntervalSince1970 ?? 0
        let inputs = environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
        let key = ([url.path, String(modified)] + arguments + inputs).joined(separator: "\0")
        if let output = probeOutputs[key] { return output }
        let runner = processRunner
        let request = ProcessRequest(
            executablePath: url.path,
            arguments: arguments,
            environment: environment,
            timeoutMilliseconds: Self.probeTimeoutMilliseconds
        )
        let output = await Task.detached(priority: .userInitiated) { runner.run(request).output }.value
        probeOutputs[key] = output
        return output
    }

    private static func tooOldMessage(_ path: String, found: String?, minimum: String) -> String {
        if let found {
            return L10n.string("\(path) is version \(found); \(minimum) or newer is required.")
        }
        return L10n.string("\(path) did not report a version; \(minimum) or newer is required.")
    }

    private static func unavailableMessage(_ name: String, problems: [String]) -> String {
        let summary = L10n.string("\(name) is not available.")
        return ([summary] + problems).joined(separator: " ")
    }
}

/// Stored option values. They follow the build-system ID, as `build.detect`
/// takes them, so a plugin update keeps the user's choices.
@MainActor
final class MacBuildOptionsStore: BuildOptionsStoring {
    private static let keyPrefix = "BuildSystems.Options."
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func options(workspaceURL: URL, buildSystemID: String) -> [String: ToolingJSONValue] {
        guard let data = store.data(forKey: Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID)),
              let options = try? JSONDecoder().decode([String: ToolingJSONValue].self, from: data) else {
            return [:]
        }
        return options
    }

    func setOptions(_ options: [String: ToolingJSONValue], workspaceURL: URL, buildSystemID: String) {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        guard !options.isEmpty else {
            store.set(nil, forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        store.set(try? encoder.encode(options), forKey: key)
    }

    func instanceOptions(workspaceURL: URL, buildSystemID: String) -> [String: [String: ToolingJSONValue]] {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".Instances"
        guard let data = store.data(forKey: key),
              let options = try? JSONDecoder().decode([String: [String: ToolingJSONValue]].self, from: data) else { return [:] }
        return options
    }

    func setInstanceOptions(_ options: [String: [String: ToolingJSONValue]], workspaceURL: URL, buildSystemID: String) {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".Instances"
        let nonempty = options.filter { !$0.value.isEmpty }
        guard !nonempty.isEmpty else { store.set(nil, forKey: key); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        store.set(try? encoder.encode(nonempty), forKey: key)
    }

    func emptyMultiSelectOptions(workspaceURL: URL, buildSystemID: String) -> [String: Set<String>] {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".EmptyMultiSelect"
        guard let data = store.data(forKey: key),
              let options = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return options.mapValues { Set($0) }
    }

    func setEmptyMultiSelectOptions(_ options: [String: Set<String>], workspaceURL: URL, buildSystemID: String) {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".EmptyMultiSelect"
        let nonempty = options.filter { !$0.value.isEmpty }
        guard !nonempty.isEmpty else {
            store.set(nil, forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        store.set(try? encoder.encode(nonempty.mapValues { $0.sorted() }), forKey: key)
    }

    private static func key(workspaceURL: URL, buildSystemID: String) -> String {
        keyPrefix + buildSystemID + "." + MacPluginStateDirectories.workspaceDigest(workspaceURL)
    }
}

/// `${workspaceStateDir}` and `${outputFile}` of build-system runs, under the
/// plugin's state directory in Application Support. The app bundle and the
/// installed plugin package stay read-only; the directory goes away with
/// the plugin.
struct MacBuildSystemStateLocator: BuildSystemStateLocating {
    let directories: MacPluginStateDirectories
    let fileStorage: any FileStorage

    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL {
        let url = directories.buildSystemWorkspaceStateDirectory(
            pluginID: pluginID,
            buildSystemID: buildSystemID,
            workspaceRootURL: workspaceURL
        )
        try fileStorage.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL {
        let outputs = workspaceStateDirectory.appendingPathComponent("outputs", isDirectory: true)
        try fileStorage.createDirectory(at: outputs, withIntermediateDirectories: true)
        return outputs.appendingPathComponent(UUID().uuidString + ".json")
    }

    func removeOutputFile(_ url: URL) {
        try? fileStorage.removeItem(at: url)
    }
}
