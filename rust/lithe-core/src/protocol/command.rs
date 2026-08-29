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
    /// Reports the Core and protocol versions (`core.ping`).
    Ping,
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
    /// Normalizes diagnostics from Maven output (`maven.diagnostics`).
    MavenDiagnostics,
    /// Renders and sanitizes shared Markdown (`markdown.render`).
    MarkdownRender,
    /// Applies validated UTF-16 LSP text edits (`lsp.applyTextEdits`).
    LspApplyTextEdits,
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
    /// Selects expired inactive JDT LS workspace caches (`java.jdtCacheRetention`).
    JavaJdtCacheRetention,
    /// Derives a JDT LS workspace fingerprint from platform observations (`java.jdtWorkspaceFingerprint`).
    JavaJdtWorkspaceFingerprint,
    /// Gracefully shuts down a managed server (`lsp.stopServer`).
    LspStopServer,
    /// Opens or updates a synchronized document (`lsp.syncDocument`).
    LspSyncDocument,
    /// Publishes external workspace file changes (`lsp.workspaceFilesChanged`).
    LspWorkspaceFilesChanged,
    /// Closes a synchronized document (`lsp.closeDocument`).
    LspCloseDocument,
    /// Queues one semantic server request (`lsp.request`).
    LspRequest,
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
    /// Discovers Java main classes and run entries (`java.runConfigurations`).
    JavaRunConfigurations,
    /// Validates layered run-configuration documents (`runConfig.inspect`).
    RunConfigInspect,
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
    /// Reads normalized repository and working-tree state (`git.status`).
    GitStatus,
    /// Resolves paths a Git-aware watcher must observe (`git.watchContext`).
    GitWatchContext,
    /// Describes the checked-out branch or detached worktree for PR creation (`git.pullRequestContext`).
    GitPullRequestContext,
    /// Executes a caller-supplied argument vector without a shell (`git.command`).
    GitCommand,
    /// Performs one supported Git mutation (`git.write`).
    GitWrite,
    /// Builds a structured Git diff (`git.diff`).
    GitDiff,
    /// Applies a patch to the index or working tree (`git.apply`).
    GitApply,
    /// Lists references and bounded commit history (`git.history`).
    GitHistory,
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
    /// Parses a GitHub repository identity from a Git remote URL (`github.parseRemote`).
    GitHubParseRemote,
    /// Builds a platform-executable GitHub HTTP request (`github.requestPlan`).
    GitHubRequestPlan,
    /// Normalizes a GitHub HTTP response into the shared contract (`github.normalizeResponse`).
    GitHubNormalizeResponse,
}

impl CoreCommand {
    /// Resolves a compatibility command name without accepting aliases or
    /// case variations that could behave differently across hosts.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "core.ping" => Some(Self::Ping),
            "community.discourse.auth.begin" => Some(Self::CommunityDiscourseAuthBegin),
            "community.discourse.auth.complete" => Some(Self::CommunityDiscourseAuthComplete),
            "community.discourse.topics" => Some(Self::CommunityDiscourseTopics),
            "community.discourse.topic" => Some(Self::CommunityDiscourseTopic),
            "community.discourse.categories" => Some(Self::CommunityDiscourseCategories),
            "community.discourse.search" => Some(Self::CommunityDiscourseSearch),
            "community.discourse.auth.revoke" => Some(Self::CommunityDiscourseAuthRevoke),
            "workspace.snapshot" => Some(Self::WorkspaceSnapshot),
            "workspace.searchIndex.warm" => Some(Self::WorkspaceSearchIndexWarm),
            "workspace.searchIndex.update" => Some(Self::WorkspaceSearchIndexUpdate),
            "workspace.searchIndex.invalidate" => Some(Self::WorkspaceSearchIndexInvalidate),
            "workspace.search" => Some(Self::WorkspaceSearch),
            "workspace.searchEverywhere" => Some(Self::WorkspaceSearchEverywhere),
            "workspace.replacePreview" => Some(Self::WorkspaceReplacePreview),
            "file.read" => Some(Self::FileRead),
            "file.write" => Some(Self::FileWrite),
            "document.lifecycle" => Some(Self::DocumentLifecycle),
            "history.record" => Some(Self::HistoryRecord),
            "history.entries" => Some(Self::HistoryEntries),
            "history.content" => Some(Self::HistoryContent),
            "history.relocate" => Some(Self::HistoryRelocate),
            "history.rename" => Some(Self::HistoryRename),
            "history.delete" => Some(Self::HistoryDelete),
            "maven.scan" => Some(Self::MavenScan),
            "maven.launchPlan" => Some(Self::MavenLaunchPlan),
            "maven.diagnostics" => Some(Self::MavenDiagnostics),
            "markdown.render" => Some(Self::MarkdownRender),
            "lsp.applyTextEdits" => Some(Self::LspApplyTextEdits),
            "lsp.plainSnippet" => Some(Self::LspPlainSnippet),
            "lsp.builtinCompletions" => Some(Self::LspBuiltinCompletions),
            "lsp.builtinHover" => Some(Self::LspBuiltinHover),
            "lsp.builtinNavigation" => Some(Self::LspBuiltinNavigation),
            "lsp.startServer" => Some(Self::LspStartServer),
            "lsp.jdtWorkspaceKey" => Some(Self::LspJdtWorkspaceKey),
            "java.workspacePolicy" => Some(Self::JavaWorkspacePolicy),
            "java.jdtCacheRetention" => Some(Self::JavaJdtCacheRetention),
            "java.jdtWorkspaceFingerprint" => Some(Self::JavaJdtWorkspaceFingerprint),
            "lsp.stopServer" => Some(Self::LspStopServer),
            "lsp.syncDocument" => Some(Self::LspSyncDocument),
            "lsp.workspaceFilesChanged" => Some(Self::LspWorkspaceFilesChanged),
            "lsp.closeDocument" => Some(Self::LspCloseDocument),
            "lsp.request" => Some(Self::LspRequest),
            "java.resolveNavigation" => Some(Self::JavaResolveNavigation),
            "lsp.cancelOperation" => Some(Self::LspCancelOperation),
            "lsp.pollEvents" => Some(Self::LspPollEvents),
            "lsp.waitEvents" => Some(Self::LspWaitEvents),
            "lsp.destroyServer" => Some(Self::LspDestroyServer),
            "java.runConfigurations" => Some(Self::JavaRunConfigurations),
            "runConfig.inspect" => Some(Self::RunConfigInspect),
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
            "git.status" => Some(Self::GitStatus),
            "git.watchContext" => Some(Self::GitWatchContext),
            "git.pullRequestContext" => Some(Self::GitPullRequestContext),
            "git.command" => Some(Self::GitCommand),
            "git.write" => Some(Self::GitWrite),
            "git.diff" => Some(Self::GitDiff),
            "git.apply" => Some(Self::GitApply),
            "git.history" => Some(Self::GitHistory),
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
            "github.parseRemote" => Some(Self::GitHubParseRemote),
            "github.requestPlan" => Some(Self::GitHubRequestPlan),
            "github.normalizeResponse" => Some(Self::GitHubNormalizeResponse),
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
            "lsp.syncDocument",
            "lsp.closeDocument",
            "lsp.request",
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
}
