import Foundation
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
    /// Probe output by executable, arguments, and modification date, so a
    /// repeated run does not start the same probe again.
    private var probeOutputs: [String: String] = [:]

    init(runtime: ProjectRuntimeService, processRunner: any ProcessRunner, fileStorage: any FileStorage) {
        self.runtime = runtime
        self.processRunner = processRunner
        self.fileStorage = fileStorage
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
        let resolver = candidateResolver(runtimeExecutables)
        for candidate in invocation.executables {
            switch resolver.resolve(candidate, workspaceURL: workspaceURL, environment: environment, environmentInputs: invocation.environmentInputs) {
            case .skip: continue
            case .terminalFailure(let message): throw BuildToolResolutionError(message, terminal: true)
            case .resolved(let choices):
                for choice in choices {
                    var selectedEnvironment = environment
                    if choice.terminal {
                        selectedEnvironment["PATH"] = choice.url.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
                    }
                    if choice.executesProjectCode {
                        return ResolvedBuildTool(executableURL: choice.url, environment: selectedEnvironment, executesProjectCode: true, version: nil)
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
        let resolver = candidateResolver([:])
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

    private func candidateResolver(_ runtimes: [String: URL]) -> ExecutableCandidateResolver {
        ExecutableCandidateResolver(fileExists: { [fileStorage] in fileStorage.fileExists(at: $0) },
            isExecutable: { [fileStorage] in fileStorage.metadata(for: $0)?.isDirectory == false && fileStorage.isExecutable(at: $0) },
            commands: { [self] in commandCandidates($0) }, runtimes: { runtimes[$0] })
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
            return ResolvedBuildTool(executableURL: url, environment: environment, executesProjectCode: false, version: nil)
        }
        let output = await probe(url, arguments: arguments, environment: environment)
        let check = try checkVersion(nil, output)
        guard check.satisfied else {
            problems.append(Self.tooOldMessage(url.path, found: check.version, minimum: minimum))
            return nil
        }
        return ResolvedBuildTool(executableURL: url, environment: environment, executesProjectCode: false, version: check.version)
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
        let javaHome = dependency.hostManaged && dependency.id == "java" ? runtime.javaHomeURL() : nil
        let sources: [ExecutableCandidate] = dependency.hostManaged
            ? (dependency.id == "java" ? [.runtime("java")] : [.command(dependency.id)])
            : dependency.executables
        let resolver = candidateResolver(javaHome.map { ["java": $0.appendingPathComponent("bin/java")] } ?? [:])
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
                    var selectedEnvironment = environment
                    if let javaHome { selectedEnvironment["JAVA_HOME"] = javaHome.path }
                    let directory = choice.url.deletingLastPathComponent().path
                    let path = environment["PATH"] ?? ""
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
        let key = ([url.path, String(modified)] + arguments).joined(separator: "\u{1F}")
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
            return String(localized: "\(path) is version \(found); \(minimum) or newer is required.")
        }
        return String(localized: "\(path) did not report a version; \(minimum) or newer is required.")
    }

    private static func unavailableMessage(_ name: String, problems: [String]) -> String {
        let summary = String(localized: "\(name) is not available.")
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
