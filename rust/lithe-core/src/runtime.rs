use crate::command::{CoreCommand, CoreRequest};
use crate::error::{CoreError, ErrorCode};
use crate::git::{
    self, GitApplyRequest, GitBlameRequest, GitCommandRequest, GitCommitFilesRequest,
    GitCommitRequest, GitComparisonRequest, GitDiffRequest, GitHistoryRequest, GitStashesRequest,
    GitStatusRequest, GitWriteRequest,
};
use crate::history::{
    HistoryContentRequest, HistoryEntriesRequest, HistoryRecordRequest, HistoryRelocateRequest,
};
use crate::java::{
    JavaClassNameRequest, JavaCodeVisionRequest, JavaRunConfigurationsRequest,
    JavaServerPortRequest, JavaSourceDefinitionRequest, JavaStructureRequest,
};
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
