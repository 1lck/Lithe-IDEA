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
    private let definedTools: any DefinedToolchainResolving
    private let runtime: any LanguageToolRuntimePort
    private let core: any LanguageServerRuntimeCore
    private let workspaceState: MacPluginLanguageServerWorkspaceState?

    init(
        backends: any PluginBackendRequesting,
        contexts: PluginWorkspaceContexts,
        resolver: MacPluginLanguageServerLaunchResolver,
        tools: any BuildToolResolving,
        definedTools: any DefinedToolchainResolving,
        runtime: any LanguageToolRuntimePort,
        core: any LanguageServerRuntimeCore,
        workspaceState: MacPluginLanguageServerWorkspaceState? = nil
    ) {
        self.backends = backends
        self.contexts = contexts
        self.resolver = resolver
        self.tools = tools
        self.definedTools = definedTools
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
            let process = try await decide(source, question: question, context: context, workspaceURL: workspaceURL)
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

    /// Asks the plugin's backend and lets Rust Core check the answer. The
    /// question carries `tools`, the installations the user's choice and
    /// discovery select for the tools the manifest requires, so the backend
    /// can configure its server for the same tools the host runs.
    private func decide(
        _ source: DeclarativeLanguageServerLaunchSource,
        question: MacPluginLanguageServerLaunchResolver.BackendLaunchQuestion,
        context: PluginWorkspaceContext,
        workspaceURL: URL
    ) async throws -> MacPluginLanguageServerLaunchResolver.BackendLaunchProcess {
        var params = question.resolveParams
        let tools = await resolvedRequiredTools(of: source, workspaceURL: workspaceURL)
        if !tools.isEmpty {
            params["tools"] = .object(tools)
        }
        let answer = try await backends.invokePluginFunction(
            question.function,
            params: .object(params),
            ofPlugin: source.pluginID,
            context: context.reference,
            timeout: .milliseconds(question.timeoutMilliseconds),
            progress: { _ in }
        )
        try Task.checkCancellation()
        try ensureCurrent(context)
        return try resolver.backendLaunchProcess(for: source, question: question, answer: answer)
    }

    /// `{<toolID>: {executable, home, version}}` for every tool the manifest
    /// lists in `requiresTools` that resolves to an installation outside the
    /// project. A tool that is missing, unusable, or inside the project is
    /// left out: the contract promises only the tools the host could find,
    /// and opening a project must not run its code.
    private func resolvedRequiredTools(
        of source: DeclarativeLanguageServerLaunchSource, workspaceURL: URL
    ) async -> [String: ToolingJSONValue] {
        var tools: [String: ToolingJSONValue] = [:]
        let environment = runtime.languageToolProcessEnvironment()
        for tool in Self.requiredTools(of: source.manifest) {
            // log-exempt: 找不到或不可用的工具按契约直接省略，后端自行决定缺省行为
            guard let selected = try? await definedTools.resolve(
                tool: tool, directory: ".", workspace: workspaceURL, environment: environment,
                minimumVersion: nil, projectCodeAllowed: false, fixed: nil, use: .installation, consumerID: nil
            ), !selected.projectCode else { continue }
            var fields: [String: ToolingJSONValue] = ["executable": .string(selected.executable.path)]
            if let home = selected.home { fields["home"] = .string(home) }
            if let version = selected.version { fields["version"] = .string(version) }
            tools[tool] = .object(fields)
        }
        return tools
    }

    /// The `requiresTools` of the normalized manifest, in manifest order.
    private static func requiredTools(of manifest: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let tools = object["requiresTools"] as? [String] else { return [] }
        return tools
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
