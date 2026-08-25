//! Validation and routing from versioned command names to their owning domains.

use crate::community::{
    self, DiscourseAuthorizationBeginRequest, DiscourseAuthorizationCompleteRequest,
    DiscourseCategoriesRequest, DiscourseRevokeRequest, DiscourseSearchRequest,
    DiscourseTopicRequest, DiscourseTopicsRequest,
};
use crate::git::{
    self, GitApplyRequest, GitBlameRequest, GitCheckoutPreflightRequest, GitCommandRequest,
    GitCommitFilesRequest, GitCommitRequest, GitComparisonRequest, GitConflictMarkerRequest,
    GitDiffRequest, GitHistoryRequest, GitIntegrationPreflightRequest, GitOperationStateRequest,
    GitPullPreflightRequest, GitPullRequestContextRequest, GitStashesRequest, GitStatusRequest,
    GitWatchContextRequest, GitWriteRequest,
};
use crate::github::{NormalizeResponseRequest, ParseRemoteRequest, RequestPlanRequest};
use crate::languages::{
    JavaClassNameRequest, JavaCodeVisionRequest, JavaRunConfigurationsRequest,
    JavaServerPortRequest, JavaSourceDefinitionRequest, JavaStructureRequest, SpringIndexRequest,
};
use crate::project::{
    self, DocumentLifecycleRequest, FileReadRequest, FileWriteRequest, ReplacementPreviewRequest,
    SearchIndexRequest, SearchIndexUpdateRequest, SearchRequest, WorkspaceSnapshotRequest,
};
use crate::project::{
    HistoryContentRequest, HistoryDeleteRequest, HistoryEntriesRequest, HistoryRecordRequest,
    HistoryRelocateRequest, HistoryRenameRequest,
};
use crate::project::{MarkdownRenderRequest, MavenDiagnosticsRequest, MavenScanRequest};
use crate::protocol::CoreResponse;
use crate::protocol::{CoreCommand, CoreRequest};
use crate::protocol::{CoreError, ErrorCode};
use serde_json::json;

pub fn execute_json(request: &str) -> String {
    let response = execute(request);
    serde_json::to_string(&response).unwrap_or_else(|_| {
        serde_json::to_string(&CoreResponse::failure(
            None,
            CoreError::new(ErrorCode::Unknown, "Could not encode core response"),
        ))
        .expect("fallback response should encode")
    })
}

fn execute(request: &str) -> CoreResponse {
    let parsed: CoreRequest = match serde_json::from_str(request) {
        Ok(request) => request,
        Err(error) => {
            return CoreResponse::failure(
                None,
                CoreError::new(ErrorCode::InvalidRequest, "Invalid JSON request")
                    .with_details(error.to_string()),
            )
        }
    };
    let id = parsed.id.clone();
    let response_id = id.clone();
    let operation_id = parsed.operation_id.clone().or_else(|| id.clone());
    let _cancellation_scope =
        crate::protocol::cancellation::Scope::begin(operation_id, parsed.timeout_milliseconds);
    if let Err(error) = crate::protocol::cancellation::check() {
        return CoreResponse::failure(id, error);
    }
    let Some(command) = CoreCommand::parse(&parsed.command) else {
        return CoreResponse::failure(
            id,
            CoreError::new(ErrorCode::NotSupported, "Unsupported core command")
                .with_details(parsed.command),
        );
    };

    let response = match command {
        CoreCommand::Ping => CoreResponse::success(
            id,
            json!({
                "protocolVersion": 1,
                "coreVersion": env!("CARGO_PKG_VERSION")
            }),
        ),
        CoreCommand::CommunityDiscourseAuthBegin => {
            match serde_json::from_value::<DiscourseAuthorizationBeginRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Discourse authorization request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(community::begin_authorization)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Discourse authorization response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::CommunityDiscourseAuthComplete => {
            match serde_json::from_value::<DiscourseAuthorizationCompleteRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Discourse authorization callback",
                    )
                    .with_details(error.to_string())
                })
                .and_then(community::complete_authorization)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Discourse authorization credential should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::CommunityDiscourseTopics => {
            match serde_json::from_value::<DiscourseTopicsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Discourse topics request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(community::topics)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Discourse topics should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::CommunityDiscourseTopic => {
            match serde_json::from_value::<DiscourseTopicRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Discourse topic request")
                        .with_details(error.to_string())
                })
                .and_then(community::topic)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Discourse topic should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::CommunityDiscourseCategories => {
            match serde_json::from_value::<DiscourseCategoriesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Discourse categories request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(community::categories)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Discourse categories should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::CommunityDiscourseSearch => {
            match serde_json::from_value::<DiscourseSearchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Discourse search request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(community::search)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Discourse search should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::CommunityDiscourseAuthRevoke => {
            match serde_json::from_value::<DiscourseRevokeRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Discourse revoke request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(community::revoke)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSnapshot => {
            match serde_json::from_value::<WorkspaceSnapshotRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid workspace snapshot request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(project::snapshot)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("snapshot should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSearchIndexWarm => {
            match serde_json::from_value::<SearchIndexRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid search index request")
                        .with_details(error.to_string())
                })
                .and_then(project::warm_search_index)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("search index status should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSearchIndexUpdate => {
            match serde_json::from_value::<SearchIndexUpdateRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid search index update")
                        .with_details(error.to_string())
                })
                .and_then(project::update_search_index)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("search index status should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSearchIndexInvalidate => {
            match serde_json::from_value::<SearchIndexRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid search index request")
                        .with_details(error.to_string())
                })
                .and_then(project::invalidate_search_index)
            {
                Ok(()) => CoreResponse::success(id, json!({})),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSearch => {
            match serde_json::from_value::<SearchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid search request")
                        .with_details(error.to_string())
                })
                .and_then(project::search)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("search should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSearchEverywhere => {
            match serde_json::from_value::<SearchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Search Everywhere request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(project::search_everywhere)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("search everywhere should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceReplacePreview => {
            match serde_json::from_value::<ReplacementPreviewRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid replacement preview request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(project::replace_preview)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("replacement preview should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::FileRead => match serde_json::from_value::<FileReadRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid file read request")
                    .with_details(error.to_string())
            })
            .and_then(project::read_file)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("file response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::FileWrite => match serde_json::from_value::<FileWriteRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid file write request")
                    .with_details(error.to_string())
            })
            .and_then(project::write_file)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("file response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::DocumentLifecycle => {
            match serde_json::from_value::<DocumentLifecycleRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid document lifecycle request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(project::decide_document_lifecycle)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("document lifecycle decision should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryRecord => {
            match serde_json::from_value::<HistoryRecordRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history record request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::record)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("history response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryEntries => {
            match serde_json::from_value::<HistoryEntriesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history entries request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::entries)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("history entries should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryContent => {
            match serde_json::from_value::<HistoryContentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history content request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::content)
            {
                Ok(data) => CoreResponse::success(id, serde_json::json!({"text": data})),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryRelocate => {
            match serde_json::from_value::<HistoryRelocateRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid history relocate request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::relocate)
            {
                Ok(()) => CoreResponse::success(id, serde_json::json!({"relocated": true})),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryRename => {
            match serde_json::from_value::<HistoryRenameRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history rename request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::rename)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("history entry should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryDelete => {
            match serde_json::from_value::<HistoryDeleteRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history delete request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::delete)
            {
                Ok(()) => CoreResponse::success(id, serde_json::json!({"deleted": true})),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::MavenScan => match serde_json::from_value::<MavenScanRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Maven scan request")
                    .with_details(error.to_string())
            })
            .and_then(crate::project::scan)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("Maven scan response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::MavenDiagnostics => {
            match serde_json::from_value::<MavenDiagnosticsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Maven diagnostics request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::diagnostics)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Maven diagnostics should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::MarkdownRender => {
            match serde_json::from_value::<MarkdownRenderRequest>(parsed.payload).map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Markdown render request")
                    .with_details(error.to_string())
            }) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::project::render(request))
                        .expect("Markdown render response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspApplyTextEdits => {
            match serde_json::from_value::<crate::lsp::ApplyTextEditsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP text edit request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::apply_text_edits)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP text edit response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspPlainSnippet => {
            match serde_json::from_value::<crate::lsp::PlainSnippetRequest>(parsed.payload).map_err(
                |error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP snippet request")
                        .with_details(error.to_string())
                },
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::lsp::plain_snippet(request))
                        .expect("LSP snippet response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspBuiltinCompletions => {
            match serde_json::from_value::<crate::lsp::BuiltinRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP completion request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::builtin_completions)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP completion response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspBuiltinHover => {
            match serde_json::from_value::<crate::lsp::BuiltinRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP hover request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::builtin_hover)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP hover response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspBuiltinNavigation => {
            match serde_json::from_value::<crate::lsp::BuiltinNavigationRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP navigation request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::builtin_navigation)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP navigation response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspStartServer => {
            match serde_json::from_value::<crate::lsp::StartServerRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP start-server request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::start_server)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP start-server response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspJdtWorkspaceKey => {
            match serde_json::from_value::<crate::lsp::JdtWorkspaceKeyRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid JDT LS workspace-key request",
                    )
                    .with_details(error.to_string())
                })
                .map(crate::lsp::resolve_workspace_key)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("JDT LS workspace key should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaWorkspacePolicy => {
            match serde_json::from_value::<crate::lsp::JavaWorkspacePolicyRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java workspace-policy request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::java_workspace_policy)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java workspace policy should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaJdtCacheRetention => {
            match serde_json::from_value::<crate::lsp::JdtCacheRetentionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid JDT LS cache-retention request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::jdt_cache_retention)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("JDT LS cache retention should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaJdtWorkspaceFingerprint => {
            match serde_json::from_value::<crate::lsp::JdtWorkspaceFingerprintRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid JDT LS workspace-fingerprint request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::lsp::jdt_workspace_fingerprint)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("JDT LS workspace fingerprint should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspStopServer => {
            match serde_json::from_value::<crate::lsp::SessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP stop-server request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::stop_server)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP stop-server response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspSyncDocument => {
            match serde_json::from_value::<crate::lsp::SyncDocumentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP sync-document request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::sync_document)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP sync-document response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspWorkspaceFilesChanged => {
            match serde_json::from_value::<crate::lsp::WorkspaceFilesChangedRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP workspace-files-changed request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::workspace_files_changed)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("LSP workspace-files-changed response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspCloseDocument => {
            match serde_json::from_value::<crate::lsp::CloseDocumentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP close-document request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::close_document)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP close-document response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspRequest => {
            match serde_json::from_value::<crate::lsp::SemanticRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid semantic LSP request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::semantic_request)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Semantic LSP response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaNavigationMarkers => {
            match serde_json::from_value::<crate::lsp::JavaNavigationMarkersRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java navigation-markers request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::java_navigation_markers)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Java navigation marker operation should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaResolveNavigation => {
            match serde_json::from_value::<crate::lsp::JavaResolveNavigationRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java resolve-navigation request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::java_resolve_navigation)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Java navigation resolution operation should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspCancelOperation => {
            match serde_json::from_value::<crate::lsp::CancelOperationRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP cancellation request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::cancel_operation)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP cancellation response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspPollEvents => {
            match serde_json::from_value::<crate::lsp::SessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP poll-events request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::poll_events)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP poll-events response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspWaitEvents => {
            match serde_json::from_value::<crate::lsp::WaitEventsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP wait-events request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::wait_events)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP wait-events response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspDestroyServer => {
            match serde_json::from_value::<crate::lsp::SessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP destroy-server request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::destroy_server)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP destroy-server response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaRunConfigurations => {
            match serde_json::from_value::<JavaRunConfigurationsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java run configuration request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::languages::run_configurations)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Java run configuration response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigInspect => {
            match serde_json::from_value::<crate::execution::InspectRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid run configuration inspect request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::execution::inspect)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigGenerate => {
            match serde_json::from_value::<crate::execution::GenerateRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid run configuration generate request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::execution::generate)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigResolve => {
            match serde_json::from_value::<crate::execution::ResolveRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid run configuration resolve request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::execution::resolve)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigUpdateOptions => {
            match serde_json::from_value::<crate::execution::UpdateOptionsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid run options request")
                        .with_details(error.to_string())
                })
                .and_then(crate::execution::update_options)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigSaveEditorChanges => {
            match serde_json::from_value::<crate::execution::UpdateOptionsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid run configuration editor request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::execution::save_editor_changes)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigCreateUserConfiguration => {
            match serde_json::from_value::<crate::execution::CreateUserConfigurationRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid user configuration request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::execution::create_user_configuration)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigCreateLaunchPlan => {
            match serde_json::from_value::<crate::execution::LaunchPlanRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid launch plan request")
                        .with_details(error.to_string())
                })
                .and_then(crate::execution::create_launch_plan)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaCodeVision => {
            match serde_json::from_value::<JavaCodeVisionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java code vision request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::languages::code_vision)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java code vision response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaClassName => {
            match serde_json::from_value::<JavaClassNameRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Java class name request")
                        .with_details(error.to_string())
                })
                .and_then(crate::languages::class_name)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java class name response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaSourceDefinition => {
            match serde_json::from_value::<JavaSourceDefinitionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java source definition request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::languages::source_definition)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java source definition should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaServerPort => {
            match serde_json::from_value::<JavaServerPortRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java server port request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::languages::server_port)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java server port should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaStructure => {
            match serde_json::from_value::<JavaStructureRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Java structure request")
                        .with_details(error.to_string())
                })
                .and_then(crate::languages::structure)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java structure response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::SpringIndex => {
            match serde_json::from_value::<SpringIndexRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Spring index request")
                        .with_details(error.to_string())
                })
                .and_then(crate::languages::spring_index)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Spring index response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitStatus => match serde_json::from_value::<GitStatusRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Git status request")
                    .with_details(error.to_string())
            })
            .and_then(git::status)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("Git response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::GitWatchContext => {
            match serde_json::from_value::<GitWatchContextRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git watch context request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::watch_context)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git watch context should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }

        CoreCommand::GitPullRequestContext => {
            match serde_json::from_value::<GitPullRequestContextRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git pull request context request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::pull_request_context)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git pull request context should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }

        CoreCommand::GitCommand => {
            match serde_json::from_value::<GitCommandRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git command request")
                        .with_details(error.to_string())
                })
                .and_then(git::command)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git command response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitWrite => {
            match serde_json::from_value::<GitWriteRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git write request")
                        .with_details(error.to_string())
                })
                .and_then(git::write)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git write response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitDiff => match serde_json::from_value::<GitDiffRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Git diff request")
                    .with_details(error.to_string())
            })
            .and_then(git::diff)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("Git diff response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::GitApply => match serde_json::from_value::<GitApplyRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Git apply request")
                    .with_details(error.to_string())
            })
            .and_then(git::apply)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("Git apply response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::GitHistory => {
            match serde_json::from_value::<GitHistoryRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git history request")
                        .with_details(error.to_string())
                })
                .and_then(git::history)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git history response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitCommit => match serde_json::from_value::<GitCommitRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Git commit request")
                    .with_details(error.to_string())
            })
            .and_then(git::commit)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("Git commit response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::GitCommitFiles => {
            match serde_json::from_value::<GitCommitFilesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git commit files request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::commit_files)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git commit files response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitComparison => {
            match serde_json::from_value::<GitComparisonRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git comparison request")
                        .with_details(error.to_string())
                })
                .and_then(git::comparison)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git comparison response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitStashes => {
            match serde_json::from_value::<GitStashesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git stashes request")
                        .with_details(error.to_string())
                })
                .and_then(git::stashes)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git stashes response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitCheckoutPreflight => {
            match serde_json::from_value::<GitCheckoutPreflightRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git checkout preflight request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::checkout_preflight)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Git checkout preflight response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitPullPreflight => {
            match serde_json::from_value::<GitPullPreflightRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git pull preflight request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::pull_preflight)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git pull preflight response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitConflictMarkers => {
            match serde_json::from_value::<GitConflictMarkerRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git conflict marker request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::conflict_marker_paths)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git conflict marker response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitIntegrationPreflight => {
            match serde_json::from_value::<GitIntegrationPreflightRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git integration preflight request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::integration_preflight)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Git integration preflight response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitOperationState => {
            match serde_json::from_value::<GitOperationStateRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git operation state request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::operation_state)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git operation state response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitBlame => match serde_json::from_value::<GitBlameRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Git blame request")
                    .with_details(error.to_string())
            })
            .and_then(git::blame)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("Git blame response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::GitHubParseRemote => {
            match serde_json::from_value::<ParseRemoteRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid GitHub remote request")
                        .with_details(error.to_string())
                })
                .and_then(crate::github::parse_remote)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("GitHub repository should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitHubRequestPlan => {
            match serde_json::from_value::<RequestPlanRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid GitHub request plan")
                        .with_details(error.to_string())
                })
                .and_then(crate::github::request_plan)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("GitHub request plan should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitHubNormalizeResponse => {
            match serde_json::from_value::<NormalizeResponseRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid GitHub response")
                        .with_details(error.to_string())
                })
                .and_then(crate::github::normalize_response)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
    };
    if response.is_success() {
        match crate::protocol::cancellation::check() {
            Ok(()) => response,
            Err(error) => CoreResponse::failure(response_id, error),
        }
    } else {
        response
    }
}

#[cfg(test)]
mod tests {
    use super::execute_json;
    use serde_json::{json, Value};

    #[test]
    fn routes_semantic_lsp_runtime_commands() {
        let unknown_session = "missing-runtime-session";
        let requests = [
            json!({
                "command": "lsp.stopServer",
                "payload": { "sessionId": unknown_session }
            }),
            json!({
                "command": "lsp.syncDocument",
                "payload": {
                    "sessionId": unknown_session,
                    "uri": "file:///tmp/main.go",
                    "languageId": "go",
                    "text": "package main\n"
                }
            }),
            json!({
                "command": "lsp.closeDocument",
                "payload": {
                    "sessionId": unknown_session,
                    "uri": "file:///tmp/main.go"
                }
            }),
            json!({
                "command": "lsp.request",
                "payload": {
                    "sessionId": unknown_session,
                    "operationId": "completion-1",
                    "operation": "completion",
                    "uri": "file:///tmp/main.go",
                    "position": { "line": 0, "utf16Column": 0 }
                }
            }),
            json!({
                "command": "lsp.cancelOperation",
                "payload": {
                    "sessionId": unknown_session,
                    "operationId": "completion-1"
                }
            }),
            json!({
                "command": "lsp.pollEvents",
                "payload": { "sessionId": unknown_session }
            }),
            json!({
                "command": "lsp.waitEvents",
                "payload": { "sessionId": unknown_session }
            }),
            json!({
                "command": "lsp.destroyServer",
                "payload": { "sessionId": unknown_session }
            }),
        ];

        for request in requests {
            let response: Value =
                serde_json::from_str(&execute_json(&request.to_string())).unwrap();
            assert_eq!(response["ok"], false, "request should reach the runtime");
            assert_eq!(response["error"]["code"], "invalid_request");
            assert_eq!(response["error"]["details"], unknown_session);
        }

        let invalid_start: Value = serde_json::from_str(&execute_json(
            &json!({
                "command": "lsp.startServer",
                "payload": {
                    "providerId": "go",
                    "executablePath": "",
                    "rootUri": "file:///tmp/project",
                    "workingDirectory": "/tmp/project"
                }
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(invalid_start["ok"], false);
        assert_eq!(invalid_start["error"]["code"], "invalid_request");
        assert_eq!(
            invalid_start["error"]["details"],
            "executablePath/workingDirectory"
        );
    }
}
