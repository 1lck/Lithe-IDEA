//! Versioned command requests and the stable set of dispatcher command names.

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Versioned request envelope accepted by every shared Core entry point.
pub struct CoreRequest {
    /// Caller-provided correlation identifier copied to the response.
    #[serde(default)]
    pub id: Option<String>,
    /// Identifier used for cooperative cancellation and stale-result handling.
    #[serde(default)]
    pub operation_id: Option<String>,
    /// Optional deadline applied by operations that support bounded execution.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
    /// Host-owned Git preferences, scoped to this request only.
    #[serde(default)]
    pub git_execution: Option<crate::git::execution_policy::GitExecutionOptions>,
    /// Stable compatibility name resolved by [`CoreCommand::parse`].
    pub command: String,
    /// Command-specific JSON object; omitted payloads deserialize as JSON null.
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Clone)]
/// Typed form of the stable command names accepted by the dispatcher.
///
/// Variants are grouped by domain, but their serialized compatibility names
/// live only in [`CoreCommand::parse`] so every host uses one mapping.
pub enum CoreCommand {
    /// Controls the native IDE capability broker (`ideHost.control`).
    IdeHostControl,
    /// Reports the Core and protocol versions (`core.ping`).
    Ping,
    /// Detects Node.js and npm and lists catalog agent installs (`agent.status`).
    AgentStatus,
    /// Installs a catalog ACP adapter with the user's npm (`agent.install`).
    AgentInstall,
    /// Removes a Lithe-managed ACP adapter install (`agent.uninstall`).
    AgentUninstall,
    /// Installs or updates an agent's CLI through its installation owner (`agent.installCli`).
    AgentInstallCli,
    /// Parses credential-free Agent provider metadata (`agent.parseProviderConfiguration`).
    AgentParseProviderConfiguration,
    /// Parses one Agent MCP configuration file into normalized servers (`mcp.parseConfiguration`).
    McpParseConfiguration,
    /// Plans a format-preserving MCP entry write or removal (`mcp.planWrite`).
    McpPlanWrite,
    /// Validates and normalizes a declarative plugin manifest (`plugins.declarative.validate`).
    PluginsDeclarativeValidate,
    /// Expands a declarative plugin's run template (`plugins.declarative.runPlan`).
    PluginsDeclarativeRunPlan,
    /// Lists a declarative plugin's workspace and file tests (`plugins.declarative.discoverTests`).
    PluginsDeclarativeDiscoverTests,
    /// Expands a declarative plugin's test template (`plugins.declarative.testPlan`).
    PluginsDeclarativeTestPlan,
    /// Expands a declarative plugin's language-server launch (`plugins.declarative.languageServerLaunchPlan`).
    PluginsDeclarativeLanguageServerLaunchPlan,
    /// Compares a launch runtime's version output with its requirement (`plugins.declarative.checkRuntimeVersion`).
    PluginsDeclarativeCheckRuntimeVersion,
    /// Finds the build-system instances of a workspace (`build.detect`).
    BuildDetect,
    /// Lists a build system's executable candidates and version probes (`build.invocationPlan`).
    BuildInvocationPlan,
    /// Compares a build tool's or runtime's version output with its minimum (`build.checkToolVersion`).
    BuildCheckToolVersion,
    /// Resolves stored build options against the declaration (`build.resolveOptions`).
    BuildResolveOptions,
    /// Expands the command that prints a build model (`build.modelPlan`).
    BuildModelPlan,
    /// Expands one build task into an argv plan (`build.taskPlan`).
    BuildTaskPlan,
    /// Expands a build test run and its result location (`build.testPlan`).
    BuildTestPlan,
    /// Expands the command that prints a project's dependencies (`build.dependencyPlan`).
    BuildDependencyPlan,
    /// Normalizes a build model and derives its run entries (`build.decodeModel`).
    BuildDecodeModel,
    /// Normalizes build test results (`build.decodeTestResults`).
    BuildDecodeTestResults,
    /// Normalizes build diagnostics from process output (`build.decodeDiagnostics`).
    BuildDecodeDiagnostics,
    /// Normalizes a project's dependency tree (`build.decodeDependencies`).
    BuildDecodeDependencies,
    /// Digests the files a build model depends on (`build.syncFingerprint`).
    BuildSyncFingerprint,
    /// Maps build options to the Java language server's project import (`build.languageImport`).
    BuildLanguageImport,
    /// Validates and filters a marketplace index (`plugins.marketplace.validateIndex`).
    PluginsMarketplaceValidateIndex,
    /// Resolves a user-entered marketplace source URL (`plugins.marketplace.resolveSource`).
    PluginsMarketplaceResolveSource,
    /// Lists a package's permissions and programs before installation (`plugins.marketplace.installReview`).
    PluginsMarketplaceInstallReview,
    /// Starts a Discourse user API key authorization (`community.discourse.auth.begin`).
    CommunityDiscourseAuthBegin,
    /// Decrypts and verifies a Discourse authorization callback (`community.discourse.auth.complete`).
    CommunityDiscourseAuthComplete,
    /// Lists normalized latest or top Discourse topics (`community.discourse.topics`).
    CommunityDiscourseTopics,
    /// Reads one normalized Discourse topic (`community.discourse.topic`).
    CommunityDiscourseTopic,
    /// Lists normalized Discourse categories (`community.discourse.categories`).
    CommunityDiscourseCategories,
    /// Searches Discourse topics and posts (`community.discourse.search`).
    CommunityDiscourseSearch,
    /// Revokes the current Discourse user API key (`community.discourse.auth.revoke`).
    CommunityDiscourseAuthRevoke,
    /// Builds the visible project tree (`workspace.snapshot`).
    WorkspaceSnapshot,
    /// Lists the visible children of project directories (`workspace.listDirectories`).
    WorkspaceListDirectories,
    /// Finds Git repositories that belong to an opened workspace (`workspace.repositories`).
    WorkspaceRepositories,
    /// Builds or reuses the workspace search index (`workspace.searchIndex.warm`).
    WorkspaceSearchIndexWarm,
    /// Applies changed paths to the search index (`workspace.searchIndex.update`).
    WorkspaceSearchIndexUpdate,
    /// Drops a workspace's cached search index (`workspace.searchIndex.invalidate`).
    WorkspaceSearchIndexInvalidate,
    /// Searches visible file paths and contents (`workspace.search`).
    WorkspaceSearch,
    /// Searches file paths, contents, and symbols (`workspace.searchEverywhere`).
    WorkspaceSearchEverywhere,
    /// Previews replacements without writing files (`workspace.replacePreview`).
    WorkspaceReplacePreview,
    /// Reads one workspace-relative UTF-8 file (`file.read`).
    FileRead,
    /// Replaces one workspace-relative UTF-8 file (`file.write`).
    FileWrite,
    /// Reduces one shared document persistence event (`document.lifecycle`).
    DocumentLifecycle,
    /// Classifies decoded Unicode text independently of its filename (`document.classifyText`).
    DocumentClassifyText,
    /// Records one local-history snapshot (`history.record`).
    HistoryRecord,
    /// Lists retained local-history metadata (`history.entries`).
    HistoryEntries,
    /// Reads the contents of one history snapshot (`history.content`).
    HistoryContent,
    /// Moves history after a workspace path relocation (`history.relocate`).
    HistoryRelocate,
    /// Changes the optional label of a history snapshot (`history.rename`).
    HistoryRename,
    /// Deletes one history snapshot (`history.delete`).
    HistoryDelete,
    /// Inspects a declared Maven reactor (`maven.scan`).
    MavenScan,
    /// Produces a deterministic Maven invocation (`maven.launchPlan`).
    MavenLaunchPlan,
    /// Shortens an oversized Java launch using a JDK argument file when needed.
    ExecutionPlanLaunchCommand,
    /// Decides how each Lithe-owned process ends (`processLifecycle.resolve`).
    ProcessLifecycleResolve,
    /// Classifies a process snapshot into lifecycle items (`processLifecycle.inventory`).
    ProcessLifecycleInventory,
    /// Turns a plan and the user's answers into what ends (`processLifecycle.settle`).
    ProcessLifecycleSettle,
    /// Produces a bounded Maven dependency-tree invocation (`maven.dependencyPlan`).
    MavenDependencyPlan,
    /// Normalizes Maven dependency-tree output (`maven.dependencies`).
    MavenDependencies,
    /// Normalizes diagnostics from Maven output (`maven.diagnostics`).
    MavenDiagnostics,
    /// Normalizes JUnit/Surefire results from Maven output (`maven.testResults`).
    MavenTestResults,
    /// Renders and sanitizes shared Markdown (`markdown.render`).
    MarkdownRender,
    /// Creates one transport-neutral Debug Adapter Protocol session (`debug.createSession`).
    DebugCreateSession,
    /// Queues a launch or attach request for a debug session (`debug.launch`).
    DebugLaunch,
    /// Creates a Java test launch configuration from JDT LS metadata (`debug.javaTestLaunch`).
    DebugJavaTestLaunch,
    /// Returns or normalizes portable stepping filters (`debug.steppingFilters`).
    DebugSteppingFilters,
    /// Moves source breakpoints across one UTF-16 editor mutation (`debug.relocateBreakpoints`).
    DebugRelocateBreakpoints,
    /// Replaces breakpoints for one source file (`debug.setBreakpoints`).
    DebugSetBreakpoints,
    /// Replaces exception filters for one debug session (`debug.setExceptionBreakpoints`).
    DebugSetExceptionBreakpoints,
    /// Replaces named function breakpoints for one debug session (`debug.setFunctionBreakpoints`).
    DebugSetFunctionBreakpoints,
    /// Resolves one adapter-owned data breakpoint identity (`debug.dataBreakpointInfo`).
    DebugDataBreakpointInfo,
    /// Replaces data breakpoints for one debug session (`debug.setDataBreakpoints`).
    DebugSetDataBreakpoints,
    /// Replaces one visible variable value (`debug.setVariable`).
    DebugSetVariable,
    /// Cancels or times out one pending debug operation (`debug.cancelOperation`).
    DebugCancelOperation,
    /// Queues continue, pause, or stepping control (`debug.execute`).
    DebugExecute,
    /// Queues one normalized debugger inspection request (`debug.inspect`).
    DebugInspect,
    /// Reduces bytes received from a platform-owned DAP transport (`debug.receive`).
    DebugReceive,
    /// Completes one adapter-requested terminal launch (`debug.runInTerminalResponse`).
    DebugRunInTerminalResponse,
    /// Begins the DAP disconnect handshake (`debug.disconnect`).
    DebugDisconnect,
    /// Removes all state for a debug session (`debug.destroySession`).
    DebugDestroySession,
    /// Applies validated UTF-16 LSP text edits (`lsp.applyTextEdits`).
    LspApplyTextEdits,
    /// Applies a deterministic line-level editing transform
    /// (`editor.lineEdit`).
    EditorLineEdit,
    /// Resolves the line comment token for a file extension
    /// (`editor.lineCommentToken`).
    EditorLineCommentToken,
    /// Reduces an LSP snippet to insertion text (`lsp.plainSnippet`).
    LspPlainSnippet,
    /// Provides same-document fallback completions (`lsp.builtinCompletions`).
    LspBuiltinCompletions,
    /// Provides a same-document fallback hover (`lsp.builtinHover`).
    LspBuiltinHover,
    /// Provides same-document fallback navigation (`lsp.builtinNavigation`).
    LspBuiltinNavigation,
    /// Starts and initializes a managed language server (`lsp.startServer`).
    LspStartServer,
    /// Derives the durable JDT LS workspace directory key (`lsp.jdtWorkspaceKey`).
    LspJdtWorkspaceKey,
    /// Plans Java workspace activation and change handling (`java.workspacePolicy`).
    JavaWorkspacePolicy,
    /// Projects JDT main/test discovery and test outcomes into editor Run markers (`java.runMarkers`).
    JavaRunMarkers,
    /// Selects expired inactive JDT LS workspace caches (`java.jdtCacheRetention`).
    JavaJdtCacheRetention,
    /// Derives a JDT LS workspace fingerprint from platform observations (`java.jdtWorkspaceFingerprint`).
    JavaJdtWorkspaceFingerprint,
    /// Gracefully shuts down a managed server (`lsp.stopServer`).
    LspStopServer,
    /// Retries Maven profile application for an existing Java session.
    LspRetryMavenProfiles,
    /// Sends a changed Maven configuration to a running Java session
    /// (`lsp.updateMavenConfiguration`).
    LspUpdateMavenConfiguration,
    /// Opens or updates a synchronized document (`lsp.syncDocument`).
    LspSyncDocument,
    /// Publishes external workspace file changes (`lsp.workspaceFilesChanged`).
    LspWorkspaceFilesChanged,
    /// Closes a synchronized document (`lsp.closeDocument`).
    LspCloseDocument,
    /// Queues one semantic server request (`lsp.request`).
    LspRequest,
    /// Queues one build-provider request (`lsp.buildRequest`).
    LspBuildRequest,
    /// Invokes one plugin function (`lsp.functionRequest`).
    LspFunctionRequest,
    /// Queues shared Java gutter marker resolution (`java.navigationMarkers`).
    JavaNavigationMarkers,
    /// Queues click-time Java navigation resolution (`java.resolveNavigation`).
    JavaResolveNavigation,
    /// Cancels one pending semantic request (`lsp.cancelOperation`).
    LspCancelOperation,
    /// Drains queued session events (`lsp.pollEvents`).
    LspPollEvents,
    /// Waits for queued session events (`lsp.waitEvents`).
    LspWaitEvents,
    /// Stops and removes a server session (`lsp.destroyServer`).
    LspDestroyServer,
    /// Validates layered run-configuration documents (`runConfig.inspect`).
    RunConfigInspect,
    /// Selects an automatic project JDK (`runConfig.selectJava`).
    RunConfigSelectJava,
    /// Regenerates detected run configurations (`runConfig.generate`).
    RunConfigGenerate,
    /// Merges configuration layers and toolchains (`runConfig.resolve`).
    RunConfigResolve,
    /// Persists editable run options (`runConfig.updateOptions`).
    RunConfigUpdateOptions,
    /// Prepares one complete run-configuration editor save (`runConfig.saveEditorChanges`).
    RunConfigSaveEditorChanges,
    /// Adds a user-authored run configuration (`runConfig.createUserConfiguration`).
    RunConfigCreateUserConfiguration,
    /// Produces the process plan for one configuration (`runConfig.createLaunchPlan`).
    RunConfigCreateLaunchPlan,
    /// Counts workspace uses of Java declarations (`java.codeVision`).
    JavaCodeVision,
    /// Resolves a package-qualified Java class name (`java.className`).
    JavaClassName,
    /// Finds a Java type or member declaration (`java.sourceDefinition`).
    JavaSourceDefinition,
    /// Reads a Spring server port from configuration (`java.serverPort`).
    JavaServerPort,
    /// Computes lightweight Java structure features (`java.structure`).
    JavaStructure,
    /// Builds Spring configuration, bean, injection, and endpoint indexes (`spring.index`).
    SpringIndex,
    /// Builds MyBatis mapper-interface and XML statement indexes (`mybatis.index`).
    MybatisIndex,
    /// Reads normalized repository and working-tree state (`git.status`).
    GitStatus,
    /// Reads HEAD and index preconditions for workspace commits (`git.commitState`).
    GitCommitState,
    /// Builds a reviewed multi-repository plan (`git.workspaceCommitPrepare`).
    GitWorkspaceCommitPrepare,
    /// Executes one guarded workspace commit/push (`git.workspaceCommitStep`).
    GitWorkspaceCommitStep,
    /// Resolves paths a Git-aware watcher must observe (`git.watchContext`).
    GitWatchContext,
    /// Lists worktrees registered for the repository (`git.worktrees`).
    GitWorktrees,
    /// Describes the checked-out branch or detached worktree for PR creation (`git.pullRequestContext`).
    GitPullRequestContext,
    /// Executes a caller-supplied argument vector without a shell (`git.command`).
    GitCommand,
    /// Resolves the containing repository root without acquiring a write lease (`git.repositoryRoot`).
    GitRepositoryRoot,
    /// Performs one supported Git mutation (`git.write`).
    GitWrite,
    /// Projects retained Git console records without executing Git (`git.consolePresentation`).
    GitConsolePresentation,
    /// Reads an optional remote URL without a visible command (`git.remoteUrl`).
    GitRemoteUrl,
    /// Plans Fetch arguments without launching Git or changing configuration (`git.fetchPlan`).
    GitFetchPlan,
    /// Resolves the executable Git will run without requiring a repository (`git.executable`).
    GitExecutable,
    /// Inspects Git configuration and its sources (`git.executionInspect`).
    GitExecutionInspect,
    /// Saves one explicitly selected configuration field (`git.executionConfigure`).
    GitExecutionConfigure,
    /// Answers a currently owned authentication prompt (`git.authRespond`).
    GitAuthRespond,
    /// Inspects repository initialization and scoped commit identity.
    GitRepositorySetup,
    /// Initializes an existing folder outside any repository.
    GitInitialize,
    /// Writes or clears one explicitly scoped commit identity field.
    GitConfigureIdentity,
    /// Reviews a local history mutation and its immutable checkout snapshot (`git.historyRewritePreview`).
    GitHistoryRewritePreview,
    /// Preview a linear local range after an unchanged base commit.
    GitRebasePreview,
    /// Start a reviewed native interactive rebase with a durable session.
    GitRebaseStart,
    /// Read the current checkout's last owned interactive rebase session.
    GitRebaseSession,
    /// Continue, skip, or abort an identified native rebase session.
    GitRebaseControl,
    /// Exports a lossless UTF-8 exchange patch (`git.patchExport`).
    GitPatchExport,
    /// Reviews a patch with a forward applicability check (`git.patchPreview`).
    GitPatchPreview,
    /// Applies a patch tied to its reviewed snapshot (`git.patchApply`).
    GitPatchApply,
    /// Builds a structured Git diff (`git.diff`).
    GitDiff,
    /// Applies a patch to the index or working tree (`git.apply`).
    GitApply,
    /// Lists references and bounded commit history (`git.history`).
    GitHistory,
    /// Lists Git references without repeating commit history (`git.references`).
    GitReferences,
    /// Returns one cursor-based commit page (`git.historyPage`).
    GitHistoryPage,
    /// Releases an incremental history cursor (`git.historyCursorClose`).
    GitHistoryCursorClose,
    /// Resolves the destination and commits for a branch push (`git.pushPreview`).
    GitPushPreview,
    /// Resolves metadata for one commit (`git.commit`).
    GitCommit,
    /// Lists paths changed by one commit (`git.commitFiles`).
    GitCommitFiles,
    /// Compares a reference with the current checkout (`git.comparison`).
    GitComparison,
    /// Lists repository stashes (`git.stashes`).
    GitStashes,
    /// Finds edits that would block checkout (`git.checkoutPreflight`).
    GitCheckoutPreflight,
    /// Reports whether the tracked branch can fast-forward (`git.pullPreflight`).
    GitPullPreflight,
    /// Finds state that blocks merge, rebase, cherry-pick, or revert (`git.integrationPreflight`).
    GitIntegrationPreflight,
    /// Finds staged files containing conflict markers (`git.conflictMarkers`).
    GitConflictMarkers,
    /// Inspects an interrupted sequential Git operation (`git.operationState`).
    GitOperationState,
    /// Returns normalized line attribution (`git.blame`).
    GitBlame,
    /// Traces which commits touched a snapshot line range (`git.lineHistory`).
    GitLineHistory,
    /// Parses a GitHub repository identity from a Git remote URL (`github.parseRemote`).
    GitHubParseRemote,
    /// Builds a platform-executable GitHub HTTP request (`github.requestPlan`).
    GitHubRequestPlan,
    /// Normalizes a GitHub HTTP response into the shared contract (`github.normalizeResponse`).
    GitHubNormalizeResponse,
    /// Redacts credentials, tokens, and home-directory paths from diagnostic text (`diagnostics.redactText`).
    DiagnosticsRedactText,
    /// Normalizes a bounded, redacted application log event (`diagnostics.prepareLogEvent`).
    DiagnosticsPrepareLogEvent,
    /// Filters and merges bounded host-collected log tails (`diagnostics.queryLogs`).
    DiagnosticsQueryLogs,
    /// Shapes a deterministic diagnostic bundle manifest from host-gathered facts (`diagnostics.buildManifest`).
    DiagnosticsBuildManifest,
}

impl CoreCommand {
    /// Resolves a compatibility command name without accepting aliases or
    /// case variations that could behave differently across hosts.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "core.ping" => Some(Self::Ping),
            "ideHost.control" => Some(Self::IdeHostControl),
            "agent.status" => Some(Self::AgentStatus),
            "agent.install" => Some(Self::AgentInstall),
            "agent.uninstall" => Some(Self::AgentUninstall),
            "agent.installCli" => Some(Self::AgentInstallCli),
            "agent.parseProviderConfiguration" => Some(Self::AgentParseProviderConfiguration),
            "mcp.parseConfiguration" => Some(Self::McpParseConfiguration),
            "mcp.planWrite" => Some(Self::McpPlanWrite),
            "plugins.declarative.validate" => Some(Self::PluginsDeclarativeValidate),
            "plugins.declarative.runPlan" => Some(Self::PluginsDeclarativeRunPlan),
            "plugins.declarative.discoverTests" => Some(Self::PluginsDeclarativeDiscoverTests),
            "plugins.declarative.testPlan" => Some(Self::PluginsDeclarativeTestPlan),
            "plugins.declarative.languageServerLaunchPlan" => {
                Some(Self::PluginsDeclarativeLanguageServerLaunchPlan)
            }
            "plugins.declarative.checkRuntimeVersion" => {
                Some(Self::PluginsDeclarativeCheckRuntimeVersion)
            }
            "build.detect" => Some(Self::BuildDetect),
            "build.invocationPlan" => Some(Self::BuildInvocationPlan),
            "build.checkToolVersion" => Some(Self::BuildCheckToolVersion),
            "build.resolveOptions" => Some(Self::BuildResolveOptions),
            "build.modelPlan" => Some(Self::BuildModelPlan),
            "build.taskPlan" => Some(Self::BuildTaskPlan),
            "build.testPlan" => Some(Self::BuildTestPlan),
            "build.dependencyPlan" => Some(Self::BuildDependencyPlan),
            "build.decodeModel" => Some(Self::BuildDecodeModel),
            "build.decodeTestResults" => Some(Self::BuildDecodeTestResults),
            "build.decodeDiagnostics" => Some(Self::BuildDecodeDiagnostics),
            "build.decodeDependencies" => Some(Self::BuildDecodeDependencies),
            "build.syncFingerprint" => Some(Self::BuildSyncFingerprint),
            "build.languageImport" => Some(Self::BuildLanguageImport),
            "plugins.marketplace.validateIndex" => Some(Self::PluginsMarketplaceValidateIndex),
            "plugins.marketplace.resolveSource" => Some(Self::PluginsMarketplaceResolveSource),
            "plugins.marketplace.installReview" => Some(Self::PluginsMarketplaceInstallReview),
            "community.discourse.auth.begin" => Some(Self::CommunityDiscourseAuthBegin),
            "community.discourse.auth.complete" => Some(Self::CommunityDiscourseAuthComplete),
            "community.discourse.topics" => Some(Self::CommunityDiscourseTopics),
            "community.discourse.topic" => Some(Self::CommunityDiscourseTopic),
            "community.discourse.categories" => Some(Self::CommunityDiscourseCategories),
            "community.discourse.search" => Some(Self::CommunityDiscourseSearch),
            "community.discourse.auth.revoke" => Some(Self::CommunityDiscourseAuthRevoke),
            "workspace.snapshot" => Some(Self::WorkspaceSnapshot),
            "workspace.listDirectories" => Some(Self::WorkspaceListDirectories),
            "workspace.repositories" => Some(Self::WorkspaceRepositories),
            "workspace.searchIndex.warm" => Some(Self::WorkspaceSearchIndexWarm),
            "workspace.searchIndex.update" => Some(Self::WorkspaceSearchIndexUpdate),
            "workspace.searchIndex.invalidate" => Some(Self::WorkspaceSearchIndexInvalidate),
            "workspace.search" => Some(Self::WorkspaceSearch),
            "workspace.searchEverywhere" => Some(Self::WorkspaceSearchEverywhere),
            "workspace.replacePreview" => Some(Self::WorkspaceReplacePreview),
            "file.read" => Some(Self::FileRead),
            "file.write" => Some(Self::FileWrite),
            "document.lifecycle" => Some(Self::DocumentLifecycle),
            "document.classifyText" => Some(Self::DocumentClassifyText),
            "history.record" => Some(Self::HistoryRecord),
            "history.entries" => Some(Self::HistoryEntries),
            "history.content" => Some(Self::HistoryContent),
            "history.relocate" => Some(Self::HistoryRelocate),
            "history.rename" => Some(Self::HistoryRename),
            "history.delete" => Some(Self::HistoryDelete),
            "maven.scan" => Some(Self::MavenScan),
            "maven.launchPlan" => Some(Self::MavenLaunchPlan),
            "execution.planLaunchCommand" => Some(Self::ExecutionPlanLaunchCommand),
            "processLifecycle.resolve" => Some(Self::ProcessLifecycleResolve),
            "processLifecycle.inventory" => Some(Self::ProcessLifecycleInventory),
            "processLifecycle.settle" => Some(Self::ProcessLifecycleSettle),
            "maven.dependencyPlan" => Some(Self::MavenDependencyPlan),
            "maven.dependencies" => Some(Self::MavenDependencies),
            "maven.diagnostics" => Some(Self::MavenDiagnostics),
            "maven.testResults" => Some(Self::MavenTestResults),
            "markdown.render" => Some(Self::MarkdownRender),
            "debug.createSession" => Some(Self::DebugCreateSession),
            "debug.launch" => Some(Self::DebugLaunch),
            "debug.javaTestLaunch" => Some(Self::DebugJavaTestLaunch),
            "debug.steppingFilters" => Some(Self::DebugSteppingFilters),
            "debug.relocateBreakpoints" => Some(Self::DebugRelocateBreakpoints),
            "debug.setBreakpoints" => Some(Self::DebugSetBreakpoints),
            "debug.setExceptionBreakpoints" => Some(Self::DebugSetExceptionBreakpoints),
            "debug.setFunctionBreakpoints" => Some(Self::DebugSetFunctionBreakpoints),
            "debug.dataBreakpointInfo" => Some(Self::DebugDataBreakpointInfo),
            "debug.setDataBreakpoints" => Some(Self::DebugSetDataBreakpoints),
            "debug.setVariable" => Some(Self::DebugSetVariable),
            "debug.cancelOperation" => Some(Self::DebugCancelOperation),
            "debug.execute" => Some(Self::DebugExecute),
            "debug.inspect" => Some(Self::DebugInspect),
            "debug.receive" => Some(Self::DebugReceive),
            "debug.runInTerminalResponse" => Some(Self::DebugRunInTerminalResponse),
            "debug.disconnect" => Some(Self::DebugDisconnect),
            "debug.destroySession" => Some(Self::DebugDestroySession),
            "lsp.applyTextEdits" => Some(Self::LspApplyTextEdits),
            "editor.lineEdit" => Some(Self::EditorLineEdit),
            "editor.lineCommentToken" => Some(Self::EditorLineCommentToken),
            "lsp.plainSnippet" => Some(Self::LspPlainSnippet),
            "lsp.builtinCompletions" => Some(Self::LspBuiltinCompletions),
            "lsp.builtinHover" => Some(Self::LspBuiltinHover),
            "lsp.builtinNavigation" => Some(Self::LspBuiltinNavigation),
            "lsp.startServer" => Some(Self::LspStartServer),
            "lsp.jdtWorkspaceKey" => Some(Self::LspJdtWorkspaceKey),
            "java.workspacePolicy" => Some(Self::JavaWorkspacePolicy),
            "java.runMarkers" => Some(Self::JavaRunMarkers),
            "java.jdtCacheRetention" => Some(Self::JavaJdtCacheRetention),
            "java.jdtWorkspaceFingerprint" => Some(Self::JavaJdtWorkspaceFingerprint),
            "lsp.stopServer" => Some(Self::LspStopServer),
            "lsp.retryMavenProfiles" => Some(Self::LspRetryMavenProfiles),
            "lsp.updateMavenConfiguration" => Some(Self::LspUpdateMavenConfiguration),
            "lsp.syncDocument" => Some(Self::LspSyncDocument),
            "lsp.workspaceFilesChanged" => Some(Self::LspWorkspaceFilesChanged),
            "lsp.closeDocument" => Some(Self::LspCloseDocument),
            "lsp.request" => Some(Self::LspRequest),
            "lsp.buildRequest" => Some(Self::LspBuildRequest),
            "lsp.functionRequest" => Some(Self::LspFunctionRequest),
            "java.resolveNavigation" => Some(Self::JavaResolveNavigation),
            "lsp.cancelOperation" => Some(Self::LspCancelOperation),
            "lsp.pollEvents" => Some(Self::LspPollEvents),
            "lsp.waitEvents" => Some(Self::LspWaitEvents),
            "lsp.destroyServer" => Some(Self::LspDestroyServer),
            "runConfig.inspect" => Some(Self::RunConfigInspect),
            "runConfig.selectJava" => Some(Self::RunConfigSelectJava),
            "runConfig.generate" => Some(Self::RunConfigGenerate),
            "runConfig.resolve" => Some(Self::RunConfigResolve),
            "runConfig.updateOptions" => Some(Self::RunConfigUpdateOptions),
            "runConfig.saveEditorChanges" => Some(Self::RunConfigSaveEditorChanges),
            "runConfig.createUserConfiguration" => Some(Self::RunConfigCreateUserConfiguration),
            "runConfig.createLaunchPlan" => Some(Self::RunConfigCreateLaunchPlan),
            "java.codeVision" => Some(Self::JavaCodeVision),
            "java.className" => Some(Self::JavaClassName),
            "java.sourceDefinition" => Some(Self::JavaSourceDefinition),
            "java.serverPort" => Some(Self::JavaServerPort),
            "java.structure" => Some(Self::JavaStructure),
            "java.navigationMarkers" => Some(Self::JavaNavigationMarkers),
            "spring.index" => Some(Self::SpringIndex),
            "mybatis.index" => Some(Self::MybatisIndex),
            "git.status" => Some(Self::GitStatus),
            "git.commitState" => Some(Self::GitCommitState),
            "git.workspaceCommitPrepare" => Some(Self::GitWorkspaceCommitPrepare),
            "git.workspaceCommitStep" => Some(Self::GitWorkspaceCommitStep),
            "git.watchContext" => Some(Self::GitWatchContext),
            "git.worktrees" => Some(Self::GitWorktrees),
            "git.pullRequestContext" => Some(Self::GitPullRequestContext),
            "git.command" => Some(Self::GitCommand),
            "git.repositoryRoot" => Some(Self::GitRepositoryRoot),
            "git.write" => Some(Self::GitWrite),
            "git.consolePresentation" => Some(Self::GitConsolePresentation),
            "git.remoteUrl" => Some(Self::GitRemoteUrl),
            "git.fetchPlan" => Some(Self::GitFetchPlan),
            "git.executable" => Some(Self::GitExecutable),
            "git.executionInspect" => Some(Self::GitExecutionInspect),
            "git.executionConfigure" => Some(Self::GitExecutionConfigure),
            "git.authRespond" => Some(Self::GitAuthRespond),
            "git.historyRewritePreview" => Some(Self::GitHistoryRewritePreview),
            "git.rebasePreview" => Some(Self::GitRebasePreview),
            "git.repositorySetup" => Some(Self::GitRepositorySetup),
            "git.initialize" => Some(Self::GitInitialize),
            "git.configureIdentity" => Some(Self::GitConfigureIdentity),
            "git.rebaseStart" => Some(Self::GitRebaseStart),
            "git.rebaseSession" => Some(Self::GitRebaseSession),
            "git.rebaseControl" => Some(Self::GitRebaseControl),
            "git.patchExport" => Some(Self::GitPatchExport),
            "git.patchPreview" => Some(Self::GitPatchPreview),
            "git.patchApply" => Some(Self::GitPatchApply),
            "git.diff" => Some(Self::GitDiff),
            "git.apply" => Some(Self::GitApply),
            "git.history" => Some(Self::GitHistory),
            "git.references" => Some(Self::GitReferences),
            "git.historyPage" => Some(Self::GitHistoryPage),
            "git.historyCursorClose" => Some(Self::GitHistoryCursorClose),
            "git.pushPreview" => Some(Self::GitPushPreview),
            "git.commit" => Some(Self::GitCommit),
            "git.commitFiles" => Some(Self::GitCommitFiles),
            "git.comparison" => Some(Self::GitComparison),
            "git.stashes" => Some(Self::GitStashes),
            "git.checkoutPreflight" => Some(Self::GitCheckoutPreflight),
            "git.pullPreflight" => Some(Self::GitPullPreflight),
            "git.integrationPreflight" => Some(Self::GitIntegrationPreflight),
            "git.conflictMarkers" => Some(Self::GitConflictMarkers),
            "git.operationState" => Some(Self::GitOperationState),
            "git.blame" => Some(Self::GitBlame),
            "git.lineHistory" => Some(Self::GitLineHistory),
            "github.parseRemote" => Some(Self::GitHubParseRemote),
            "github.requestPlan" => Some(Self::GitHubRequestPlan),
            "github.normalizeResponse" => Some(Self::GitHubNormalizeResponse),
            "diagnostics.redactText" => Some(Self::DiagnosticsRedactText),
            "diagnostics.prepareLogEvent" => Some(Self::DiagnosticsPrepareLogEvent),
            "diagnostics.queryLogs" => Some(Self::DiagnosticsQueryLogs),
            "diagnostics.buildManifest" => Some(Self::DiagnosticsBuildManifest),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CoreCommand;

    #[test]
    fn parses_semantic_lsp_runtime_commands() {
        for command in [
            "lsp.startServer",
            "lsp.jdtWorkspaceKey",
            "lsp.stopServer",
            "lsp.updateMavenConfiguration",
            "lsp.syncDocument",
            "lsp.closeDocument",
            "lsp.request",
            "lsp.buildRequest",
            "lsp.functionRequest",
            "lsp.cancelOperation",
            "lsp.pollEvents",
            "lsp.waitEvents",
            "lsp.destroyServer",
        ] {
            assert!(CoreCommand::parse(command).is_some(), "missing {command}");
        }
    }

    #[test]
    fn parses_discourse_authorization_commands() {
        for command in [
            "community.discourse.auth.begin",
            "community.discourse.auth.complete",
            "community.discourse.auth.revoke",
            "community.discourse.categories",
            "community.discourse.search",
            "community.discourse.topic",
            "community.discourse.topics",
        ] {
            assert!(CoreCommand::parse(command).is_some(), "missing {command}");
        }
    }

    #[test]
    fn parses_document_lifecycle_command() {
        assert!(CoreCommand::parse("document.lifecycle").is_some());
    }

    #[test]
    fn parses_java_launch_command_planner() {
        assert!(matches!(
            CoreCommand::parse("execution.planLaunchCommand"),
            Some(CoreCommand::ExecutionPlanLaunchCommand)
        ));
    }

    #[test]
    fn parses_process_lifecycle_command() {
        assert!(matches!(
            CoreCommand::parse("processLifecycle.resolve"),
            Some(CoreCommand::ProcessLifecycleResolve)
        ));
        assert!(matches!(
            CoreCommand::parse("processLifecycle.inventory"),
            Some(CoreCommand::ProcessLifecycleInventory)
        ));
        assert!(matches!(
            CoreCommand::parse("processLifecycle.settle"),
            Some(CoreCommand::ProcessLifecycleSettle)
        ));
    }

    #[test]
    fn parses_maven_test_results_command() {
        assert!(matches!(
            CoreCommand::parse("maven.testResults"),
            Some(CoreCommand::MavenTestResults)
        ));
    }

    #[test]
    fn parses_debug_runtime_commands() {
        for command in [
            "debug.createSession",
            "debug.launch",
            "debug.javaTestLaunch",
            "debug.steppingFilters",
            "debug.relocateBreakpoints",
            "debug.setBreakpoints",
            "debug.setExceptionBreakpoints",
            "debug.setFunctionBreakpoints",
            "debug.dataBreakpointInfo",
            "debug.setDataBreakpoints",
            "debug.setVariable",
            "debug.cancelOperation",
            "debug.execute",
            "debug.inspect",
            "debug.receive",
            "debug.runInTerminalResponse",
            "debug.disconnect",
            "debug.destroySession",
        ] {
            assert!(CoreCommand::parse(command).is_some(), "missing {command}");
        }
    }

    #[test]
    fn parses_git_push_preview_command() {
        assert!(matches!(
            CoreCommand::parse("git.pushPreview"),
            Some(CoreCommand::GitPushPreview)
        ));
    }

    #[test]
    fn parses_workspace_repositories_command() {
        assert!(matches!(
            CoreCommand::parse("workspace.repositories"),
            Some(CoreCommand::WorkspaceRepositories)
        ));
    }

    #[test]
    fn parses_git_repository_root_command() {
        assert!(matches!(
            CoreCommand::parse("git.repositoryRoot"),
            Some(CoreCommand::GitRepositoryRoot)
        ));
    }
}
