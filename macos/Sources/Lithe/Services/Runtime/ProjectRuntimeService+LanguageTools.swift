import Foundation
import LitheCoreContracts

extension ProjectRuntimeService: LanguageToolRuntimePort {
    package func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] {
        var environment = processEnvironment()
        // Node-based language servers (Intelephense, TypeScript, …) start
        // through launchers that read LITHE_NODE_PATH. An app opened from the
        // Dock inherits launchd's PATH, which omits Homebrew and Node version
        // managers, so pass the discovered executable explicitly.
        // Language servers start automatically when a file opens, so a
        // project-provided `node` must never be chosen here: an untrusted
        // repository could otherwise run its own program.
        if environment["LITHE_NODE_PATH"]?.isEmpty ?? true,
           let node = executableCandidates("node").first(where: { $0.source != .project }) {
            environment["LITHE_NODE_PATH"] = node.executableURL.path
        }
        // Declared runtime dependencies are also put on PATH because servers
        // such as gopls run the tool themselves and cannot be pointed at it
        // through a launcher variable. The same project-local exclusion applies.
        var searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for tool in runtimeTools {
            let key = Self.runtimeToolEnvironmentKey(tool)
            if environment[key]?.isEmpty ?? true,
               let candidate = executableCandidates(tool).first(where: { $0.source != .project }) {
                environment[key] = candidate.executableURL.path
            }
            guard let configured = environment[key], configured.hasPrefix("/") else { continue }
            let directory = URL(fileURLWithPath: configured).deletingLastPathComponent().path
            if !searchPath.contains(directory) {
                searchPath.insert(directory, at: 0)
            }
        }
        if !runtimeTools.isEmpty {
            environment["PATH"] = searchPath.joined(separator: ":")
        }
        return environment
    }

    static func runtimeToolEnvironmentKey(_ tool: String) -> String {
        LanguageToolEnvironment.runtimeToolKey(tool)
    }

    package func missingLanguageToolMessage(_ name: String) -> String {
        missingToolMessage(name)
    }
}

/// Looks up tools and the process environment for the open project, locally or
/// on a remote host. It knows no language: which tools exist and how they are
/// chosen comes from plugin-defined tool definitions (`DefinedToolchains`).
@MainActor
final class ProjectRuntimeService: ObservableObject {
    @Published private(set) var projectURL: URL?
    private var isDiscovering = false

    private let localRuntimeLocator: any RuntimeLocator
    private var runtimeLocator: any RuntimeLocator
    private let localToolDiscovery: any RuntimeToolDiscovery
    private var toolDiscovery: any RuntimeToolDiscovery
    private let workspaceRuntime: ((URL) -> (any RuntimeLocator, any RuntimeToolDiscovery)?)?
    private var discoveryTask: Task<Void, Never>?
    private var activeDiscoveryID: UUID?
    /// Project whose host snapshot the locator currently holds.
    private var discoveredProjectURL: URL?

    init(
        runtimeLocator: any RuntimeLocator,
        toolDiscovery: (any RuntimeToolDiscovery)? = nil,
        workspaceRuntime: ((URL) -> (any RuntimeLocator, any RuntimeToolDiscovery)?)? = nil
    ) {
        self.runtimeLocator = runtimeLocator
        self.localRuntimeLocator = runtimeLocator
        self.toolDiscovery = toolDiscovery ?? DefaultRuntimeToolDiscovery()
        self.localToolDiscovery = toolDiscovery ?? DefaultRuntimeToolDiscovery()
        self.workspaceRuntime = workspaceRuntime
    }

    deinit {
        discoveryTask?.cancel()
    }

    func openProject(at url: URL) {
        discoveryTask?.cancel()
        activeDiscoveryID = nil
        let normalizedURL = url.standardizedFileURL
        projectURL = normalizedURL
        let selected = workspaceRuntime?(normalizedURL)
        runtimeLocator = selected?.0 ?? localRuntimeLocator
        toolDiscovery = selected?.1 ?? localToolDiscovery
        discoveredProjectURL = nil
        discoveryTask = nil
        // The superseded probe no longer owns the flag (its ID was cleared above).
        isDiscovering = false
    }

    func closeProject() {
        discoveryTask?.cancel()
        discoveryTask = nil
        activeDiscoveryID = nil
        projectURL = nil
        runtimeLocator = localRuntimeLocator
        toolDiscovery = localToolDiscovery
        discoveredProjectURL = nil
        isDiscovering = false
    }

    /// Reads the host snapshot for the open project unless it already ran or is
    /// running. A local host answers synchronously, so this matters only for a
    /// remote workspace whose environment and PATH must be fetched first.
    func ensureRuntimesDiscovered() async {
        guard projectURL != nil, !hasDiscoveredRuntimes, !isDiscovering else { return }
        await performRuntimeRefresh()
    }

    func refreshAvailableRuntimes() async {
        runtimeLocator.invalidateProbeCache()
        discoveryTask?.cancel()
        discoveryTask = nil
        await performRuntimeRefresh()
    }

    private func performRuntimeRefresh() async {
        let targetProjectURL = projectURL
        let discoveryID = UUID()
        activeDiscoveryID = discoveryID
        isDiscovering = true
        defer {
            if activeDiscoveryID == discoveryID {
                activeDiscoveryID = nil
                isDiscovering = false
            }
        }
        let runtimeLocator = runtimeLocator
        await Self.backgroundProbe { cancelled in
            runtimeLocator.probeHost(isCancelled: cancelled)
        }
        guard !Task.isCancelled,
              projectURL == targetProjectURL,
              activeDiscoveryID == discoveryID else { return }
        discoveredProjectURL = targetProjectURL
    }

    /// Whether the host snapshot has been read for the open project.
    private var hasDiscoveredRuntimes: Bool { discoveredProjectURL == projectURL && projectURL != nil }

    /// Base environment for launching processes. Overrides are layered on top.
    func processEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        runtimeLocator.environment().merging(overrides) { _, override in override }
    }

    func defaultExecutableSearchPath() -> String? {
        runtimeLocator.defaultExecutableSearchPath()
    }

    /// Returns all known candidates in preference order.  The platform
    /// adapter can add project-local, Homebrew, Xcode, or registry sources;
    /// the locator fallback keeps existing non-platform implementations fully
    /// compatible.
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
        guard !command.isEmpty, !command.contains("/") else { return [] }
        let environment = runtimeLocator.environment()
        let discovered = toolDiscovery.candidates(
            for: command,
            projectURL: projectURL,
            environment: environment
        )
        var candidates = discovered
        var seen = Set(discovered.map { $0.executableURL.standardizedFileURL.path })
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidateURL = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(command)
                .standardizedFileURL
            guard runtimeLocator.isExecutable(at: candidateURL),
                  seen.insert(candidateURL.path).inserted else { continue }
            candidates.append(RuntimeToolCandidate(
                command: command,
                executableURL: candidateURL,
                source: .path,
                detail: String(directory)
            ))
        }
        return candidates
    }

    func toolGuidance(_ command: String) -> RuntimeToolGuidance {
        toolDiscovery.guidance(
            for: command,
            projectURL: projectURL,
            environment: runtimeLocator.environment()
        )
    }

    func missingToolMessage(_ command: String) -> String {
        let guidance = toolGuidance(command)
        return guidance.message
    }

    /// Resolves a bare program name without starting a process. Returns nil
    /// when no candidate is executable.
    func executableOnPath(_ command: String) -> URL? {
        executableCandidates(command).first?.executableURL
    }

    func executableURL(at path: String) -> URL? {
        let normalized = normalizedOverridePath(path)
        guard !normalized.isEmpty else { return nil }
        let url = URL(fileURLWithPath: normalized).standardizedFileURL
        return runtimeLocator.isExecutable(at: url) ? url : nil
    }

    /// Blocking platform probes run on a worker queue, never a cooperative executor.
    private static func backgroundProbe<Value: Sendable>(
        _ operation: @escaping @Sendable (@Sendable () -> Bool) -> Value
    ) async -> Value {
        let cancellation = RuntimeProbeCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: operation { cancellation.isCancelled })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func normalizedOverridePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }
        return runtimeLocator.normalizedPath(trimmedPath, relativeTo: projectURL)
    }
}

/// Shared only with the owned blocking worker; cancellation stops later probes.
private final class RuntimeProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}
