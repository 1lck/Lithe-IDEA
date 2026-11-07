import Foundation
import LitheModuleAPI
import LitheCoreContracts

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

/// Picks the executable of a build-system run from the candidates Rust Core
/// ordered. Runtimes come first, so a tool found through them sees the
/// same `PATH`, and the variables a selected tool definition exports, that
/// its probe ran with.
///
/// Bare commands resolve through the host's tool discovery, never to a
/// project-local copy: only a declared `projectFile` candidate may run code
/// the repository ships, and it is never probed before the user runs it.
@MainActor
final class MacBuildToolResolver: BuildToolResolving {
    private static let probeTimeoutMilliseconds = 15_000

    private let logSink: (any LogSink)?
    private let runtime: ProjectRuntimeService
    private let processRunner: any ProcessRunner
    private let fileStorage: any FileStorage
    private let toolchains: RunToolchainRegistry
    private let definedTools: (any DefinedToolchainResolving)?
    private let registry: RemoteWorkspaceRegistry?
    private let remoteFiles: (any RemoteBuildFileProbing)?
    private let remoteProcesses: (any RemoteProcessRunning)?
    /// Probe output by executable, arguments, and modification date, so a
    /// repeated run does not start the same probe again.
    private var probeOutputs: [String: String] = [:]

    init(runtime: ProjectRuntimeService, processRunner: any ProcessRunner, fileStorage: any FileStorage,
         toolchains: RunToolchainRegistry? = nil, registry: RemoteWorkspaceRegistry? = nil, remoteFiles: (any RemoteBuildFileProbing)? = nil,
         remoteProcesses: (any RemoteProcessRunning)? = nil, definedTools: (any DefinedToolchainResolving)? = nil, logSink: (any LogSink)? = nil) {
        self.logSink = logSink
        self.runtime = runtime
        self.processRunner = processRunner
        self.fileStorage = fileStorage
        self.registry = registry
        self.remoteFiles = remoteFiles
        self.remoteProcesses = remoteProcesses
        self.toolchains = toolchains ?? .standard()
        self.definedTools = definedTools
    }

    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        let referenced = Set((invocation.executables + invocation.runtimeDependencies.flatMap(\.executables)).compactMap { candidate -> String? in
            if case .toolchain(let id, _) = candidate { return id }; return nil
        })
        guard Set(invocation.toolSelections.keys).isSubset(of: referenced) else {
            throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
        }
        if registry?.contains(workspaceURL) == true {
            await runtime.ensureRuntimesDiscovered()
            try Task.checkCancellation()
            guard runtime.projectURL == workspaceURL.standardizedFileURL else { throw CancellationError() }
        }
        var environment = runtime.processEnvironment()
        // Variables the selected runtimes contribute, such as a tool
        // definition's exports, reach the provider even when the host
        // process already has the same value.
        var contributed: Set<String> = []
        var runtimeExecutables: [String: URL] = [:]
        for dependency in invocation.runtimeDependencies {
            runtimeExecutables[dependency.id] = try await resolveRuntime(
                dependency,
                invocation: invocation,
                workspaceURL: workspaceURL,
                environment: &environment,
                contributed: &contributed,
                checkVersion: checkVersion
            )
        }

        var problems: [String] = []
        let resolver = try await preparedResolver(runtimeExecutables, candidates: invocation.executables,
                                                  workspaceURL: workspaceURL, environment: environment, minimumVersion: invocation.minimumVersion,
                                                  selections: invocation.toolSelections, consumerID: invocation.toolConsumerID)
        for candidate in invocation.executables {
            switch resolver.resolve(candidate, workspaceURL: workspaceURL, environment: environment, environmentInputs: invocation.environmentInputs) {
            case .skip: continue
            case .terminalFailure(let message): throw BuildToolResolutionError(message, terminal: true)
            case .resolved(let choices):
                for choice in choices {
                    var selectedEnvironment = environment.merging(choice.environment) { _, selected in selected }
                    let selectedContributed = contributed.union(choice.environment.keys)
                    if choice.terminal {
                        let directory = choice.url.deletingLastPathComponent().path
                        let paths = (selectedEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
                        selectedEnvironment["PATH"] = ([directory] + paths.filter { $0 != directory }).joined(separator: ":")
                    }
                    if choice.executesProjectCode {
                        return resolved(choice.url, environment: selectedEnvironment, contributed: selectedContributed,
                                        projectCode: true, version: nil)
                    }
                    do {
                        if let tool = try await accept(choice.url, invocation: invocation, environment: selectedEnvironment,
                                                       contributed: selectedContributed, workspaceURL: workspaceURL,
                                                       checkVersion: checkVersion, problems: &problems) { return tool }
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw BuildToolResolutionError(error.localizedDescription, terminal: choice.terminal) }
                    if choice.terminal { throw BuildToolResolutionError(Self.unavailableMessage(displayName, problems: problems), terminal: true) }
                }
            }
        }
        throw BuildToolResolutionError(Self.unavailableMessage(displayName, problems: problems))
    }

    private func preparedResolver(
        _ runtimes: [String: URL], candidates: [ExecutableCandidate], workspaceURL: URL,
        environment: [String: String], minimumVersion: String? = nil,
        selections: [String: FixedToolchainSelection] = [:], use: DefinedToolchainUse = .executable, consumerID: String? = nil
    ) async throws -> ExecutableCandidateResolver {
        var definitions: [String: ExecutableResolution] = [:]
        for candidate in candidates {
            if case .toolchain(let id, _) = candidate, selections[id] != nil, toolchains.contains(identifier: id) {
                throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
            }
        }
        for candidate in candidates {
            guard case .toolchain(let id, let root) = candidate, !toolchains.contains(identifier: id) else { continue }
            guard registry?.contains(workspaceURL) != true, let definedTools,
                  let selected = try await definedTools.resolve(tool: id, directory: root, workspace: workspaceURL,
                      environment: environment, minimumVersion: minimumVersion, projectCodeAllowed: true, fixed: selections[id], use: use, consumerID: consumerID) else {
                throw BuildToolResolutionError(L10n.string("The selected toolchain is unavailable."), terminal: true)
            }
            // The choice carries only what the selection added. Its full
            // environment is the caller's plus these exports, so merging the
            // exports back reproduces it without marking every variable the
            // host process already had as contributed by the tool.
            definitions[id + "\n" + root] = .resolved([.init(url: selected.executable,
                executesProjectCode: selected.projectCode, terminal: true, environment: selected.exports)])
        }
        guard let binding = registry?.resolve(workspaceURL)?.binding else {
            return candidateResolver(runtimes, workspaceURL: workspaceURL, definitions: definitions)
        }
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
            case .toolchain: break // The workspace runtime's prepared snapshot owns these paths.
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
            isExecutable: { files[$0]?.isExecutable == true }, commands: { commands[$0] ?? [] }, runtimes: { runtimes[$0] },
            toolchains: candidateResolver(runtimes, workspaceURL: workspaceURL).toolchains)
    }

    private func candidateResolver(_ runtimes: [String: URL], workspaceURL: URL, passive: Bool = false,
                                   definitions: [String: ExecutableResolution] = [:]) -> ExecutableCandidateResolver {
        ExecutableCandidateResolver(fileExists: { [fileStorage] in fileStorage.fileExists(at: $0) },
            isExecutable: { [fileStorage] in fileStorage.metadata(for: $0)?.isDirectory == false && fileStorage.isExecutable(at: $0) },
            commands: { [self] in commandCandidates($0) }, runtimes: { runtimes[$0] },
            toolchains: { [self] id, root in
                if let selected = definitions[id + "\n" + root] { return selected }
                // Per-tool choices come from plugin-defined tool definitions and
                // the Run document; the host keeps no language-specific defaults.
                let options = RunOptions()
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
                    // log-exempt: 同一次失败已经记录过：错误原样转为 terminalFailure 抛给调用方，由 BuildSystemService 的准备边界记录 run.preparation.failed
                } catch { return .terminalFailure(error.localizedDescription) }
            })
    }

    /// Keeps a candidate when the build tool declares no minimum version or
    /// its probe satisfies it.
    private func accept(
        _ url: URL,
        invocation: BuildInvocation,
        environment: [String: String],
        contributed: Set<String>,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck,
        problems: inout [String]
    ) async throws -> ResolvedBuildTool? {
        guard let arguments = invocation.versionArguments, let minimum = invocation.minimumVersion else {
            return resolved(url, environment: environment, contributed: contributed, projectCode: false, version: nil)
        }
        let output = try await probe(url, arguments: arguments, environment: environment, workspaceURL: workspaceURL)
        let check = try checkVersion(nil, output)
        guard check.satisfied else {
            problems.append(Self.tooOldMessage(url.path, found: check.version, minimum: minimum))
            return nil
        }
        return resolved(url, environment: environment, contributed: contributed, projectCode: false, version: check.version)
    }

    private func resolved(
        _ url: URL, environment: [String: String], contributed: Set<String>, projectCode: Bool, version: String?
    ) -> ResolvedBuildTool {
        let base = runtime.processEnvironment()
        let inputs = environment.filter { key, value in key == "PATH" || contributed.contains(key) || base[key] != value }
        return ResolvedBuildTool(executableURL: url, environment: environment, executesProjectCode: projectCode,
            version: version, providerEnvironment: inputs)
    }

    /// Resolves one runtime and puts it first on `PATH`. Host-managed
    /// runtimes follow the user's runtime settings. A runtime the plugin does
    /// not describe arrives from Core as the toolchain candidate of the tool
    /// definition with its ID, which checks `minimumVersion` and whose
    /// exports join the environment; any other runtime is found through the
    /// candidates it declares.
    private func resolveRuntime(
        _ dependency: BuildInvocation.RuntimeDependency,
        invocation: BuildInvocation,
        workspaceURL: URL,
        environment: inout [String: String],
        contributed: inout Set<String>,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> URL {
        let name = dependency.displayName ?? dependency.id
        let sources: [ExecutableCandidate] = dependency.hostManaged && dependency.executables.isEmpty
            ? [.command(dependency.id)]
            : dependency.executables
        let resolver = try await preparedResolver([:],
            candidates: sources, workspaceURL: workspaceURL, environment: environment, minimumVersion: dependency.minimumVersion,
            selections: invocation.toolSelections, use: .installation, consumerID: invocation.toolConsumerID)
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
                    let directory = choice.url.deletingLastPathComponent().path
                    let path = selectedEnvironment["PATH"] ?? ""
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
                    contributed.formUnion(choice.environment.keys)
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
            let runner = MacRemoteBuildCommandRunner(logSink: logSink, local: MacBuildCommandRunner(logSink: logSink), registry: registry, host: remoteProcesses)
            let captured = RemoteBuildProbeOutput()
            let result = try await runner.run(BuildCommandRequest(executableURL: url, arguments: arguments,
                workingDirectory: workspaceURL, environment: environment, timeout: .milliseconds(Self.probeTimeoutMilliseconds))) {
                captured.append($0)
            }
            guard case .exited(0) = result.termination else { return "" }
            return try captured.value()
        }
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

/// `${workspaceStateDir}` and `${outputFile}` of build-system runs, under the
/// plugin's state directory in Application Support. The app bundle and the
/// installed plugin package stay read-only; the directory goes away with
/// the plugin.
struct MacBuildSystemStateLocator: BuildSystemStateLocating {
    let directories: MacPluginStateDirectories
    let fileStorage: any FileStorage
    var logSink: (any LogSink)? = nil

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
        do { try fileStorage.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { /* No output was produced. */ }
        catch { logSink?.emit(RunBuildScratchCleanupFailed(error: error, stage: "provider-output")) }
    }
}
