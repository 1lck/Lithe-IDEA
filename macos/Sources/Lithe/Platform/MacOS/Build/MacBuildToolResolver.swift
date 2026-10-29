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
    private let registry: RemoteWorkspaceRegistry?
    private let remoteFiles: (any RemoteBuildFileProbing)?
    private let remoteProcesses: (any RemoteProcessRunning)?
    /// Probe output by executable, arguments, and modification date, so a
    /// repeated run does not start the same probe again.
    private var probeOutputs: [String: String] = [:]

    init(runtime: ProjectRuntimeService, processRunner: any ProcessRunner, fileStorage: any FileStorage,
         registry: RemoteWorkspaceRegistry? = nil, remoteFiles: (any RemoteBuildFileProbing)? = nil,
         remoteProcesses: (any RemoteProcessRunning)? = nil) {
        self.runtime = runtime
        self.processRunner = processRunner
        self.fileStorage = fileStorage
        self.registry = registry
        self.remoteFiles = remoteFiles
        self.remoteProcesses = remoteProcesses
    }

    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        if registry?.contains(workspaceURL) == true {
            await runtime.ensureRuntimesDiscovered()
            try Task.checkCancellation()
            guard runtime.projectURL == workspaceURL.standardizedFileURL else { throw CancellationError() }
        }
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
        let resolver = try await preparedResolver(runtimeExecutables, candidates: invocation.executables,
                                                  workspaceURL: workspaceURL, environment: environment)
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
                                                       workspaceURL: workspaceURL, checkVersion: checkVersion, problems: &problems) { return tool }
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
        guard registry?.contains(workspaceURL) != true else { return nil }
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

    func prepareLanguageImportExecutable(_ invocation: BuildInvocation, workspaceURL: URL) async throws -> URL? {
        guard registry?.contains(workspaceURL) == true else {
            return languageImportExecutable(invocation, workspaceURL: workspaceURL)
        }
        try Task.checkCancellation()
        guard runtime.projectURL == workspaceURL.standardizedFileURL else { throw CancellationError() }
        let environment = runtime.processEnvironment()
        let resolver = try await preparedResolver([:], candidates: invocation.executables,
                                                  workspaceURL: workspaceURL, environment: environment)
        for candidate in invocation.executables {
            switch resolver.resolve(candidate, workspaceURL: workspaceURL, environment: environment,
                                    environmentInputs: invocation.environmentInputs) {
            case .skip: continue
            case .terminalFailure: return nil
            case .resolved(let choices): return choices.first?.url
            }
        }
        return nil
    }

    private func preparedResolver(
        _ runtimes: [String: URL], candidates: [ExecutableCandidate], workspaceURL: URL,
        environment: [String: String]
    ) async throws -> ExecutableCandidateResolver {
        guard let binding = registry?.resolve(workspaceURL)?.binding else { return candidateResolver(runtimes) }
        guard let remoteFiles else { throw CocoaError(.featureUnsupported) }
        var paths = Set<URL>()
        var commands: [String: [URL]] = [:]
        for candidate in candidates {
            switch candidate {
            case .projectFile(let path, let requires):
                paths.insert(workspaceURL.appendingPathComponent(path).standardizedFileURL)
                requires.forEach { paths.insert(workspaceURL.appendingPathComponent($0).standardizedFileURL) }
            case .environment(let variable, let path):
                if let base = environment[variable], base.hasPrefix("/") {
                    paths.insert(URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL)
                }
            case .command(let command):
                let found = commandCandidates(command)
                commands[command] = found
                paths.formUnion(found)
            case .runtime(let id): if let url = runtimes[id] { paths.insert(url) }
            case .setting(_, let path): if let path, path.hasPrefix("/") { paths.insert(URL(fileURLWithPath: path)) }
            }
        }
        let requested = paths.sorted { $0.path < $1.path }.map { url in
            let root = binding.root.path
            let path = url.path == root ? binding.remoteRoot : url.path.hasPrefix(root + "/")
                ? binding.remoteRoot + url.path.dropFirst(root.count) : url.path
            return (url, path)
        }
        let files: [URL: RemoteBuildFileMetadata] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    var files: [URL: RemoteBuildFileMetadata] = [:]
                    for (url, path) in requested {
                        if let metadata = try remoteFiles.buildFileMetadata(path, session: binding.sessionID) {
                            files[url] = metadata
                        }
                    }
                    return files
                })
            }
        }
        try Task.checkCancellation()
        return ExecutableCandidateResolver(fileExists: { files[$0] != nil },
            isExecutable: { files[$0]?.isExecutable == true }, commands: { commands[$0] ?? [] }, runtimes: { runtimes[$0] })
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
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck,
        problems: inout [String]
    ) async throws -> ResolvedBuildTool? {
        guard let arguments = invocation.versionArguments, let minimum = invocation.minimumVersion else {
            return ResolvedBuildTool(executableURL: url, environment: environment, executesProjectCode: false, version: nil)
        }
        let output = try await probe(url, arguments: arguments, environment: environment, workspaceURL: workspaceURL)
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
        let resolver = try await preparedResolver(javaHome.map { ["java": $0.appendingPathComponent("bin/java")] } ?? [:],
            candidates: sources, workspaceURL: workspaceURL, environment: environment)
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
                        let output = try await probe(choice.url, arguments: arguments, environment: selectedEnvironment, workspaceURL: workspaceURL)
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

    private func probe(_ url: URL, arguments: [String], environment: [String: String], workspaceURL: URL) async throws -> String {
        if let registry, registry.contains(workspaceURL) {
            guard let remoteProcesses else { throw CocoaError(.featureUnsupported) }
            let runner = MacRemoteBuildCommandRunner(local: MacBuildCommandRunner(), registry: registry, host: remoteProcesses)
            let captured = RemoteBuildProbeOutput()
            let result = try await runner.run(BuildCommandRequest(executableURL: url, arguments: arguments,
                workingDirectory: workspaceURL, environment: environment, timeout: .milliseconds(Self.probeTimeoutMilliseconds))) {
                captured.append($0)
            }
            guard case .exited(0) = result.termination else { return "" }
            return try captured.value()
        }
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
            return L10n.string("\(path) is version \(found); \(minimum) or newer is required.")
        }
        return L10n.string("\(path) did not report a version; \(minimum) or newer is required.")
    }

    private static func unavailableMessage(_ name: String, problems: [String]) -> String {
        let summary = L10n.string("\(name) is not available.")
        return ([summary] + problems).joined(separator: " ")
    }
}

private final class RemoteBuildProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var overflowed = false
    func append(_ text: String) {
        lock.withLock {
            guard !overflowed else { return }
            guard output.utf8.count + text.utf8.count <= 262_144 else {
                overflowed = true
                output = ""
                return
            }
            output += text
        }
    }
    func value() throws -> String {
        try lock.withLock {
            guard !overflowed else { throw CocoaError(.fileReadTooLarge) }
            return output
        }
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
