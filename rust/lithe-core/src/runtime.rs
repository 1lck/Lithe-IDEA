use crate::command::{CoreCommand, CoreRequest};
use crate::error::{CoreError, ErrorCode};
use crate::git::{
    self, GitApplyRequest, GitBlameRequest, GitCheckoutPreflightRequest, GitCommandRequest,
    GitCommitFilesRequest, GitCommitRequest, GitComparisonRequest, GitConflictMarkerRequest,
    GitDiffRequest, GitHistoryRequest, GitIntegrationPreflightRequest, GitOperationStateRequest,
    GitPullPreflightRequest, GitStashesRequest, GitStatusRequest, GitWriteRequest,
};
use crate::history::{
    HistoryContentRequest, HistoryEntriesRequest, HistoryRecordRequest, HistoryRelocateRequest,
};
use crate::java::{
    JavaClassNameRequest, JavaCodeVisionRequest, JavaRunConfigurationsRequest,
    JavaServerPortRequest, JavaSourceDefinitionRequest, JavaStructureRequest,
};
use crate::markdown::MarkdownRenderRequest;
use crate::maven::{MavenDiagnosticsRequest, MavenScanRequest};
use crate::model::CoreResponse;
use crate::workspace::{
    self, FileReadRequest, FileWriteRequest, ReplacementPreviewRequest, SearchRequest,
    WorkspaceSnapshotRequest,
};
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
        crate::cancellation::Scope::begin(operation_id, parsed.timeout_milliseconds);
    if let Err(error) = crate::cancellation::check() {
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
        CoreCommand::WorkspaceSnapshot => {
            match serde_json::from_value::<WorkspaceSnapshotRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid workspace snapshot request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(workspace::snapshot)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("snapshot should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceSearch => {
            match serde_json::from_value::<SearchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid search request")
                        .with_details(error.to_string())
                })
                .and_then(workspace::search)
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
                .and_then(workspace::search_everywhere)
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
                .and_then(workspace::replace_preview)
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
            .and_then(workspace::read_file)
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
            .and_then(workspace::write_file)
        {
            Ok(data) => CoreResponse::success(
                id,
                serde_json::to_value(data).expect("file response should encode"),
            ),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::HistoryRecord => {
            match serde_json::from_value::<HistoryRecordRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history record request")
                        .with_details(error.to_string())
                })
                .and_then(crate::history::record)
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
                .and_then(crate::history::entries)
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
                .and_then(crate::history::content)
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
                .and_then(crate::history::relocate)
            {
                Ok(()) => CoreResponse::success(id, serde_json::json!({"relocated": true})),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::MavenScan => match serde_json::from_value::<MavenScanRequest>(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid Maven scan request")
                    .with_details(error.to_string())
            })
            .and_then(crate::maven::scan)
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
                .and_then(crate::maven::diagnostics)
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
                    serde_json::to_value(crate::markdown::render(request))
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
        CoreCommand::LspClientInitialize => {
            match serde_json::from_value::<crate::lsp::ClientInitializeRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP initialize request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::client_initialize)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspClientOpenDocument => {
            match serde_json::from_value::<crate::lsp::ClientOpenDocumentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP open document request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::client_open_document)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspClientChangeDocument => {
            match serde_json::from_value::<crate::lsp::ClientChangeDocumentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP change document request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::client_change_document)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspClientCloseDocument => {
            match serde_json::from_value::<crate::lsp::ClientCloseDocumentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP close document request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::client_close_document)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspClientShutdown => {
            match serde_json::from_value::<crate::lsp::ClientShutdownRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP shutdown request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::client_shutdown)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspClientRequest => {
            match serde_json::from_value::<crate::lsp::ClientFeatureRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP feature request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::client_feature_request)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspClientApplyServerMessage => {
            match serde_json::from_value::<crate::lsp::ClientApplyServerMessageRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid LSP server message request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::lsp::client_apply_server_message)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP client response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspSessionExecute => {
            match serde_json::from_value::<crate::lsp_host::LspSessionCommandRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP session request")
                    .with_details(error.to_string())
            })
            .and_then(crate::lsp_host::execute)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP session response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspFrameMessage => {
            match serde_json::from_value::<crate::lsp::FrameMessageRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP frame request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::frame_message)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP frame response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspParseServerMessages => {
            match serde_json::from_value::<crate::lsp::ParseServerMessagesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP parser request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::parse_server_messages)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("LSP parser response should encode"),
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
                .and_then(crate::java::run_configurations)
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
            match serde_json::from_value::<crate::run_configuration::InspectRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid run configuration inspect request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::run_configuration::inspect)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigGenerate => {
            match serde_json::from_value::<crate::run_configuration::GenerateRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid run configuration generate request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::run_configuration::generate)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigResolve => {
            match serde_json::from_value::<crate::run_configuration::ResolveRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid run configuration resolve request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::run_configuration::resolve)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigUpdateOptions => {
            match serde_json::from_value::<crate::run_configuration::UpdateOptionsRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid run options request")
                    .with_details(error.to_string())
            })
            .and_then(crate::run_configuration::update_options)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigCreateUserConfiguration => {
            match serde_json::from_value::<
                crate::run_configuration::CreateUserConfigurationRequest,
            >(parsed.payload)
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid user configuration request")
                    .with_details(error.to_string())
            })
            .and_then(crate::run_configuration::create_user_configuration)
            {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RunConfigCreateLaunchPlan => {
            match serde_json::from_value::<crate::run_configuration::LaunchPlanRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid launch plan request")
                    .with_details(error.to_string())
            })
            .and_then(crate::run_configuration::create_launch_plan)
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
                .and_then(crate::java::code_vision)
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
                .and_then(crate::java::class_name)
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
                .and_then(crate::java::source_definition)
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
                .and_then(crate::java::server_port)
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
                .and_then(crate::java::structure)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java structure response should encode"),
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
    };
    if response.is_success() {
        match crate::cancellation::check() {
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
    fn routes_lsp_close_document_and_shutdown_commands() {
        let uri = "file:///tmp/project/main.go";
        let close_response: Value = serde_json::from_str(&execute_json(
            &json!({
                "id": "close-1",
                "command": "lsp.clientCloseDocument",
                "payload": {
                    "state": {
                        "openDocuments": {
                            uri: {
                                "uri": uri,
                                "languageId": "go",
                                "version": 1,
                                "text": "package main\n"
                            }
                        }
                    },
                    "uri": uri
                }
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(close_response["ok"], true);
        assert!(close_response["data"]["state"]["openDocuments"]
            .as_object()
            .unwrap()
            .is_empty());
        let did_close: Value =
            serde_json::from_str(close_response["data"]["messages"][0].as_str().unwrap()).unwrap();
        assert_eq!(did_close["method"], "textDocument/didClose");

        let shutdown_response: Value = serde_json::from_str(&execute_json(
            &json!({
                "id": "shutdown-1",
                "command": "lsp.clientShutdown",
                "payload": {
                    "state": {
                        "initialized": true
                    }
                }
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(shutdown_response["ok"], true);
        assert_eq!(
            shutdown_response["data"]["state"]["shutdownRequested"],
            true
        );
        let shutdown: Value =
            serde_json::from_str(shutdown_response["data"]["messages"][0].as_str().unwrap())
                .unwrap();
        assert_eq!(shutdown["method"], "shutdown");
        assert_eq!(shutdown["id"], "1");
        assert!(shutdown.get("params").is_none());
    }
}
