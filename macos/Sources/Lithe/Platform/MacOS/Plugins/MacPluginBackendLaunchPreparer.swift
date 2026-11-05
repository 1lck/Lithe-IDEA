import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI

// Note: 插件自有语言服务器会话与后端决定启动方式见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

/// Prepares the process of a plugin-owned language server whose plugin
/// backend decides what to start (`serverProcess` 3). Two steps surround the
/// backend call, and Rust Core does both: it builds the question, and it
/// bounds and checks the answer. This class only moves them between the
/// plugin's backend, the file system and the tool resolver.
///
/// The scratch directory of one start lives in the temporary area. The
/// returned `release` removes it once the process ends, and a failed start
/// removes it here, so no start leaves files behind. Nothing is written
/// into the app bundle or the plugin package.
@MainActor
final class MacPluginBackendLaunchPreparer {
    enum PrepareError: LocalizedError, Equatable {
        case workspaceNotOpen
        case toolRunsProjectCode(String)

        var errorDescription: String? {
            switch self {
            case .workspaceNotOpen:
                L10n.string("No open window shows this workspace, so the plugin cannot choose how to start its language server.")
            case .toolRunsProjectCode(let tool):
                L10n.string("\(tool) resolves to a program inside the project, which a language server cannot start.")
            }
        }
    }

    private let backends: any PluginBackendRequesting
    private let contexts: PluginWorkspaceContexts
    private let resolver: MacPluginLanguageServerLaunchResolver
    private let tools: any BuildToolResolving
    private let runtime: any LanguageToolRuntimePort
    private let core: any LanguageServerRuntimeCore
    private let workspaceState: MacPluginLanguageServerWorkspaceState?

    init(
        backends: any PluginBackendRequesting,
        contexts: PluginWorkspaceContexts,
        resolver: MacPluginLanguageServerLaunchResolver,
        tools: any BuildToolResolving,
        runtime: any LanguageToolRuntimePort,
        core: any LanguageServerRuntimeCore,
        workspaceState: MacPluginLanguageServerWorkspaceState? = nil
    ) {
        self.backends = backends
        self.contexts = contexts
        self.resolver = resolver
        self.tools = tools
        self.runtime = runtime
        self.core = core
        self.workspaceState = workspaceState
    }

    func prepare(
        _ source: DeclarativeLanguageServerLaunchSource,
        workspaceURL: URL
    ) async throws -> PreparedLanguageServerProcess {
        guard let context = contexts.localContext(forFolder: workspaceURL) else {
            throw PrepareError.workspaceNotOpen
        }
        let question = try resolver.backendLaunchQuestion(for: source, workspaceRootURL: workspaceURL)
        maintainState(of: source, workspaceURL: workspaceURL)
        do {
            let process = try await decide(source, question: question, context: context)
            let target = try await resolveTarget(of: process.program, workspaceURL: workspaceURL)
            // The backend call and the tool lookup take time; a workspace
            // that changed meanwhile must not start this process.
            try ensureCurrent(context)
            let scratch = question.scratchDirectory
            return PreparedLanguageServerProcess(
                executableURL: target.url,
                environment: target.environment.merging(process.environment) { _, planned in planned },
                launch: process.launch,
                core: core,
                release: { Self.removeScratch(scratch) }
            )
        } catch {
            Self.removeScratch(question.scratchDirectory)
            throw error
        }
    }

    /// Asks the plugin's backend and lets Rust Core check the answer.
    private func decide(
        _ source: DeclarativeLanguageServerLaunchSource,
        question: MacPluginLanguageServerLaunchResolver.BackendLaunchQuestion,
        context: PluginWorkspaceContext
    ) async throws -> MacPluginLanguageServerLaunchResolver.BackendLaunchProcess {
        let answer = try await backends.invokePluginFunction(
            question.function,
            params: .object(question.resolveParams),
            ofPlugin: source.pluginID,
            context: context.reference,
            timeout: .milliseconds(question.timeoutMilliseconds),
            progress: { _ in }
        )
        try Task.checkCancellation()
        try ensureCurrent(context)
        return try resolver.backendLaunchProcess(for: source, question: question, answer: answer)
    }

    /// The program to start and the environment the host gives it.
    private struct Target {
        let url: URL
        let environment: [String: String]
    }

    private func resolveTarget(
        of program: MacPluginLanguageServerLaunchResolver.BackendLaunchProcess.Program,
        workspaceURL: URL
    ) async throws -> Target {
        switch program {
        case .file(let url):
            return Target(url: url, environment: runtime.languageToolProcessEnvironment())
        case .tool(let tool):
            return try await resolveTool(tool, workspaceURL: workspaceURL)
        }
    }

    /// A tool of the plugin's own definitions, found the way every other
    /// plugin tool is: the user's choice, then discovery. A program inside
    /// the project is refused, since opening a project must not run it.
    private func resolveTool(_ tool: String, workspaceURL: URL) async throws -> Target {
        let resolved = try await tools.resolve(
            BuildInvocation(executables: [.toolchain(id: tool, root: ".")]),
            displayName: tool,
            workspaceURL: workspaceURL,
            checkVersion: { _, _ in BuildVersionCheck(satisfied: true, version: nil) }
        )
        guard !resolved.executesProjectCode else {
            throw PrepareError.toolRunsProjectCode(tool)
        }
        return Target(url: resolved.executableURL, environment: resolved.environment)
    }

    /// Marks this workspace's state as used and deletes the state of
    /// workspaces the plugin's retention lets go. Removing an old index can
    /// take long, so it runs in the background and never delays the start. It
    /// only frees disk space, so a failure does not stop the server either.
    private func maintainState(of source: DeclarativeLanguageServerLaunchSource, workspaceURL: URL) {
        guard let workspaceState else { return }
        let open = contexts.contexts
            .filter { $0.authority == .local }
            .flatMap { $0.folders.map(\.localURL) } + [workspaceURL]
        Task.detached(priority: .utility) {
            do {
                try workspaceState.markUsed(source, workspaceRootURL: workspaceURL)
                try workspaceState.prune(source, openWorkspaceURLs: open)
            } catch {
                // log-exempt: 状态清理只回收磁盘空间，失败不影响本次启动，下次启动会重新清理
            }
        }
    }

    private func ensureCurrent(_ context: PluginWorkspaceContext) throws {
        guard case .success = contexts.resolve(context.reference) else { throw CancellationError() }
    }

    private nonisolated static func removeScratch(_ directory: URL) {
        // log-exempt: 临时目录位于系统临时区，删不掉只占用磁盘，系统会自行回收
        try? FileManager.default.removeItem(at: directory)
    }
}
