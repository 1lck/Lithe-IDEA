use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreRequest {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub operation_id: Option<String>,
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
    pub command: String,
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub enum CoreCommand {
    Ping,
    WorkspaceSnapshot,
    WorkspaceSearch,
    WorkspaceSearchEverywhere,
    WorkspaceReplacePreview,
    FileRead,
    FileWrite,
    HistoryRecord,
    HistoryEntries,
    HistoryContent,
    HistoryRelocate,
    MavenScan,
    MavenDiagnostics,
    MarkdownRender,
    LspApplyTextEdits,
    LspPlainSnippet,
    LspBuiltinCompletions,
    LspBuiltinHover,
    LspBuiltinNavigation,
    LspClientInitialize,
    LspClientOpenDocument,
    LspClientChangeDocument,
    LspClientCloseDocument,
    LspClientShutdown,
    LspClientRequest,
    LspClientApplyServerMessage,
    LspSessionExecute,
    LspFrameMessage,
    LspParseServerMessages,
    JavaRunConfigurations,
    RunConfigInspect,
    RunConfigGenerate,
    RunConfigResolve,
    RunConfigUpdateOptions,
    RunConfigCreateUserConfiguration,
    RunConfigCreateLaunchPlan,
    JavaCodeVision,
    JavaClassName,
    JavaSourceDefinition,
    JavaServerPort,
    JavaStructure,
    GitStatus,
    GitCommand,
    GitWrite,
    GitDiff,
    GitApply,
    GitHistory,
    GitCommit,
    GitCommitFiles,
    GitComparison,
    GitStashes,
    GitCheckoutPreflight,
    GitPullPreflight,
    GitIntegrationPreflight,
    GitConflictMarkers,
    GitOperationState,
    GitBlame,
}

impl CoreCommand {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "core.ping" => Some(Self::Ping),
            "workspace.snapshot" => Some(Self::WorkspaceSnapshot),
            "workspace.search" => Some(Self::WorkspaceSearch),
            "workspace.searchEverywhere" => Some(Self::WorkspaceSearchEverywhere),
            "workspace.replacePreview" => Some(Self::WorkspaceReplacePreview),
            "file.read" => Some(Self::FileRead),
            "file.write" => Some(Self::FileWrite),
            "history.record" => Some(Self::HistoryRecord),
            "history.entries" => Some(Self::HistoryEntries),
            "history.content" => Some(Self::HistoryContent),
            "history.relocate" => Some(Self::HistoryRelocate),
            "maven.scan" => Some(Self::MavenScan),
            "maven.diagnostics" => Some(Self::MavenDiagnostics),
            "markdown.render" => Some(Self::MarkdownRender),
            "lsp.applyTextEdits" => Some(Self::LspApplyTextEdits),
            "lsp.plainSnippet" => Some(Self::LspPlainSnippet),
            "lsp.builtinCompletions" => Some(Self::LspBuiltinCompletions),
            "lsp.builtinHover" => Some(Self::LspBuiltinHover),
            "lsp.builtinNavigation" => Some(Self::LspBuiltinNavigation),
            "lsp.clientInitialize" => Some(Self::LspClientInitialize),
            "lsp.clientOpenDocument" => Some(Self::LspClientOpenDocument),
            "lsp.clientChangeDocument" => Some(Self::LspClientChangeDocument),
            "lsp.clientCloseDocument" => Some(Self::LspClientCloseDocument),
            "lsp.clientShutdown" => Some(Self::LspClientShutdown),
            "lsp.clientRequest" => Some(Self::LspClientRequest),
            "lsp.clientApplyServerMessage" => Some(Self::LspClientApplyServerMessage),
            "lsp.sessionExecute" => Some(Self::LspSessionExecute),
            "lsp.frameMessage" => Some(Self::LspFrameMessage),
            "lsp.parseServerMessages" => Some(Self::LspParseServerMessages),
            "java.runConfigurations" => Some(Self::JavaRunConfigurations),
            "runConfig.inspect" => Some(Self::RunConfigInspect),
            "runConfig.generate" => Some(Self::RunConfigGenerate),
            "runConfig.resolve" => Some(Self::RunConfigResolve),
            "runConfig.updateOptions" => Some(Self::RunConfigUpdateOptions),
            "runConfig.createUserConfiguration" => Some(Self::RunConfigCreateUserConfiguration),
            "runConfig.createLaunchPlan" => Some(Self::RunConfigCreateLaunchPlan),
            "java.codeVision" => Some(Self::JavaCodeVision),
            "java.className" => Some(Self::JavaClassName),
            "java.sourceDefinition" => Some(Self::JavaSourceDefinition),
            "java.serverPort" => Some(Self::JavaServerPort),
            "java.structure" => Some(Self::JavaStructure),
            "git.status" => Some(Self::GitStatus),
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
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CoreCommand;

    #[test]
    fn parses_lsp_document_and_session_close_commands() {
        assert!(matches!(
            CoreCommand::parse("lsp.clientCloseDocument"),
            Some(CoreCommand::LspClientCloseDocument)
        ));
        assert!(matches!(
            CoreCommand::parse("lsp.clientShutdown"),
            Some(CoreCommand::LspClientShutdown)
        ));
        assert!(matches!(
            CoreCommand::parse("lsp.sessionExecute"),
            Some(CoreCommand::LspSessionExecute)
        ));
    }
}
