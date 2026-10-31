//! Validation and routing from versioned command names to their owning domains.

use crate::community::{
    self, DiscourseAuthorizationBeginRequest, DiscourseAuthorizationCompleteRequest,
    DiscourseCategoriesRequest, DiscourseRevokeRequest, DiscourseSearchRequest,
    DiscourseTopicRequest, DiscourseTopicsRequest,
};
use crate::diagnostics::{BuildManifestRequest, RedactTextRequest};
use crate::git::{
    self, GitApplyRequest, GitBlameRequest, GitCheckoutPreflightRequest, GitCommandRequest,
    GitCommitFilesRequest, GitCommitRequest, GitComparisonRequest, GitConflictMarkerRequest,
    GitDiffRequest, GitHistoryCursorCloseRequest, GitHistoryPageRequest, GitHistoryRequest,
    GitHistoryRewritePreviewRequest, GitIntegrationPreflightRequest, GitLineHistoryRequest,
    GitOperationStateRequest, GitPullPreflightRequest, GitPullRequestContextRequest,
    GitPushPreviewRequest, GitRebaseControlRequest, GitRebasePreviewRequest,
    GitRebaseSessionRequest, GitRebaseStartRequest, GitReferencesRequest, GitRepositoryRootRequest,
    GitStashesRequest, GitStatusRequest, GitUntrackedDirectoryRequest, GitWatchContextRequest,
    GitWorktreesRequest, GitWriteRequest, PatchApplyRequest, PatchExportRequest,
    PatchPreviewRequest, WorkspaceRepositoriesRequest,
};
use crate::github::{NormalizeResponseRequest, ParseRemoteRequest, RequestPlanRequest};
use crate::languages::{
    JavaClassNameRequest, JavaCodeVisionRequest, JavaServerPortRequest,
    JavaSourceDefinitionRequest, JavaStructureRequest, MybatisIndexRequest, SpringIndexRequest,
};
use crate::project::{
    self, DirectoryListingRequest, DocumentLifecycleRequest, FileReadRequest, FileWriteRequest,
    ReplacementPreviewRequest, SearchIndexRequest, SearchIndexUpdateRequest, SearchRequest,
    WorkspaceSnapshotRequest,
};
use crate::project::{
    HistoryContentRequest, HistoryDeleteRequest, HistoryEntriesRequest,
    HistoryIgnorePreviewRequest, HistoryRecordRequest, HistoryRelocateRequest,
    HistoryRenameRequest, HistoryStorageRequest,
};
use crate::project::{
    MarkdownRenderRequest, MavenDependenciesRequest, MavenDependencyPlanRequest,
    MavenDiagnosticsRequest, MavenScanRequest,
};
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

/// Decode an agent management payload and run `operation` on it.
/// Declarative plugin commands decode their own payloads so manifest content
/// problems surface as `rejected` outcomes rather than Core failures.
fn plugin_response(
    id: Option<String>,
    payload: serde_json::Value,
    operation: fn(serde_json::Value) -> Result<serde_json::Value, CoreError>,
) -> CoreResponse {
    match operation(payload) {
        Ok(data) => CoreResponse::success(id, data),
        Err(error) => CoreResponse::failure(id, error),
    }
}

fn agent_response<T: serde::de::DeserializeOwned>(
    id: Option<String>,
    payload: serde_json::Value,
    operation: fn(T) -> Result<serde_json::Value, CoreError>,
) -> CoreResponse {
    match serde_json::from_value::<T>(payload)
        .map_err(|error| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid agent management request",
            )
            .with_details(error.to_string())
        })
        .and_then(operation)
    {
        Ok(data) => CoreResponse::success(id, data),
        Err(error) => CoreResponse::failure(id, error),
    }
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
    let _cancellation_scope = crate::protocol::cancellation::Scope::begin(
        operation_id.clone(),
        parsed.timeout_milliseconds,
    );
    crate::git::execution_events::request_started(operation_id.as_deref());
    if let Err(error) = crate::protocol::cancellation::check() {
        return CoreResponse::failure(id, error);
    }
    let _workspace =
        match crate::remote::workspace::Scope::begin(parsed.remote_workspace, &parsed.command) {
            Ok(scope) => scope,
            Err(error) => return CoreResponse::failure(id, error),
        };
    let _git_policy = match crate::git::execution_policy::Scope::begin(parsed.git_execution) {
        Ok(scope) => scope,
        Err(error) => return CoreResponse::failure(id, error),
    };
    let Some(command) = CoreCommand::parse(&parsed.command) else {
        return CoreResponse::failure(
            id,
            CoreError::new(ErrorCode::NotSupported, "Unsupported core command")
                .with_details(parsed.command),
        );
    };

    let preserve_workspace_outcome = matches!(command, CoreCommand::GitWorkspaceCommitStep);
    let response = match command {
        CoreCommand::IdeHostControl => {
            let action = parsed.payload["action"].as_str().unwrap_or("");
            match lithe_ide_host::execute(action, parsed.payload["arguments"].clone()) {
                Ok(data) => CoreResponse::success(id, data),
                Err(message) => {
                    CoreResponse::failure(id, CoreError::new(ErrorCode::InvalidRequest, message))
                }
            }
        }
        CoreCommand::Ping => CoreResponse::success(
            id,
            json!({
                "protocolVersion": 1,
                "coreVersion": env!("CARGO_PKG_VERSION")
            }),
        ),
        CoreCommand::AgentStatus => agent_response(id, parsed.payload, crate::agent::status),
        CoreCommand::AgentInstructionsRead => {
            agent_response(id, parsed.payload, crate::agent::instructions::read)
        }
        CoreCommand::AgentInstructionsSave => {
            agent_response(id, parsed.payload, crate::agent::instructions::save)
        }
        CoreCommand::AgentInstructionsShared => {
            agent_response(id, parsed.payload, crate::agent::instructions::shared)
        }
        CoreCommand::AgentSkills => agent_response(id, parsed.payload, crate::agent::skills),
        CoreCommand::AgentHooks => agent_response(id, parsed.payload, crate::agent::hooks::execute),
        CoreCommand::AgentParseProviderConfiguration => {
            match crate::ai::parse_provider_configuration(parsed.payload) {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::McpParseConfiguration => {
            match crate::mcp::parse_configuration(parsed.payload) {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::McpParseRegistry => match crate::mcp::parse_registry(parsed.payload) {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::McpFeaturedRegistry => match crate::mcp::featured_registry() {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::McpProbe => agent_response(id, parsed.payload, crate::mcp::probe),
        CoreCommand::McpToolPolicy => match crate::mcp::tool_policy(parsed.payload) {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::McpCommandLine => match crate::mcp::command_line(parsed.payload) {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::McpPlanWrite => match crate::mcp::plan_write(parsed.payload) {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::PluginsNativeUIValidateData => plugin_response(
            id,
            parsed.payload,
            crate::plugins::native_ui::validate_data_command,
        ),
        CoreCommand::PluginsDeclarativeValidate => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::validate_command,
        ),
        CoreCommand::PluginsDeclarativeRunPlan => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::run_plan_command,
        ),
        CoreCommand::PluginsDeclarativeDiscoverTests => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::discover_tests_command,
        ),
        CoreCommand::PluginsDeclarativeTestPlan => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::test_plan_command,
        ),
        CoreCommand::PluginsDeclarativeLanguageServerLaunchPlan => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::language_server_launch_plan_command,
        ),
        CoreCommand::DebugValidateAdapterEndpoint => {
            match crate::debug::validate_adapter_endpoint(parsed.payload) {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugTransportPolicy => match crate::debug::transport_policy(parsed.payload) {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::DebugTransportHandle => {
            match crate::debug::handle_transport_event(parsed.payload) {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugTransportRelease => {
            match crate::debug::release_transport(parsed.payload) {
                Ok(data) => CoreResponse::success(id, data),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugAdaptersStartArguments => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::debug_start_arguments_command,
        ),
        CoreCommand::DebugAdaptersExecutablePlan => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::debug_executable_plan_command,
        ),
        CoreCommand::PluginsDeclarativeCheckRuntimeVersion => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::check_runtime_version_command,
        ),
        CoreCommand::PluginsDeclarativeResolveSettings => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::resolve_settings_command,
        ),
        CoreCommand::PluginsDeclarativeWorkspaceConfiguration => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::workspace_configuration_command,
        ),
        CoreCommand::PluginsDeclarativeDecodeGrammar => plugin_response(
            id,
            parsed.payload,
            crate::plugins::declarative::decode_grammar_command,
        ),
        CoreCommand::PluginsEditorActionsDecode => plugin_response(
            id,
            parsed.payload,
            crate::plugins::editor_actions::decode_command,
        ),
        CoreCommand::BuildDetect => {
            plugin_response(id, parsed.payload, crate::build::build_detect_command)
        }
        CoreCommand::BuildInvocationPlan => plugin_response(
            id,
            parsed.payload,
            crate::build::build_invocation_plan_command,
        ),
        CoreCommand::BuildCheckToolVersion => plugin_response(
            id,
            parsed.payload,
            crate::build::build_check_tool_version_command,
        ),
        CoreCommand::BuildResolveOptions => plugin_response(
            id,
            parsed.payload,
            crate::build::build_resolve_options_command,
        ),
        CoreCommand::BuildModelPlan => {
            plugin_response(id, parsed.payload, crate::build::build_model_plan_command)
        }
        CoreCommand::BuildTaskPlan => {
            plugin_response(id, parsed.payload, crate::build::build_task_plan_command)
        }
        CoreCommand::BuildPrepareDebugPlan => plugin_response(
            id,
            parsed.payload,
            crate::build::build_prepare_debug_plan_command,
        ),
        CoreCommand::BuildDecodeDebugPreparation => plugin_response(
            id,
            parsed.payload,
            crate::build::build_decode_debug_preparation_command,
        ),
        CoreCommand::BuildResolveModelInputs => plugin_response(
            id,
            parsed.payload,
            crate::build::build_resolve_model_inputs_command,
        ),
        CoreCommand::BuildPrepareRunPlan => plugin_response(
            id,
            parsed.payload,
            crate::build::build_prepare_run_plan_command,
        ),
        CoreCommand::BuildDecodeRunPreparation => plugin_response(
            id,
            parsed.payload,
            crate::build::build_decode_run_preparation_command,
        ),
        CoreCommand::BuildTestPlan => {
            plugin_response(id, parsed.payload, crate::build::build_test_plan_command)
        }
        CoreCommand::BuildTestDiscoveryPlan => plugin_response(
            id,
            parsed.payload,
            crate::build::build_test_discovery_plan_command,
        ),
        CoreCommand::BuildDecodeTestDiscovery => plugin_response(
            id,
            parsed.payload,
            crate::build::build_decode_test_discovery_command,
        ),
        CoreCommand::BuildDependencyPlan => plugin_response(
            id,
            parsed.payload,
            crate::build::build_dependency_plan_command,
        ),
        CoreCommand::BuildDecodeModel => {
            plugin_response(id, parsed.payload, crate::build::build_decode_model_command)
        }
        CoreCommand::BuildDecodeTestResults => plugin_response(
            id,
            parsed.payload,
            crate::build::build_decode_test_results_command,
        ),
        CoreCommand::BuildDecodeDiagnostics => plugin_response(
            id,
            parsed.payload,
            crate::build::build_decode_diagnostics_command,
        ),
        CoreCommand::BuildDecodeDependencies => plugin_response(
            id,
            parsed.payload,
            crate::build::build_decode_dependencies_command,
        ),
        CoreCommand::BuildSyncFingerprint => plugin_response(
            id,
            parsed.payload,
            crate::build::build_sync_fingerprint_command,
        ),
        CoreCommand::BuildLanguageImport => plugin_response(
            id,
            parsed.payload,
            crate::build::build_language_import_command,
        ),
        CoreCommand::VcsDetectRoots => {
            plugin_response(id, parsed.payload, crate::vcs::vcs_detect_roots_command)
        }
        CoreCommand::VcsOwnerOf => {
            plugin_response(id, parsed.payload, crate::vcs::vcs_owner_of_command)
        }
        CoreCommand::VcsDecodeReply => {
            plugin_response(id, parsed.payload, crate::vcs::vcs_decode_reply_command)
        }
        CoreCommand::ProjectGeneratorCatalog => plugin_response(
            id,
            parsed.payload,
            crate::project_generators::project_generator_catalog_command,
        ),
        CoreCommand::ProjectGeneratorForm => plugin_response(
            id,
            parsed.payload,
            crate::project_generators::project_generator_form_command,
        ),
        CoreCommand::ProjectGenerationPlan => plugin_response(
            id,
            parsed.payload,
            crate::project_generators::project_generation_plan_command,
        ),
        CoreCommand::ProjectCheckName => plugin_response(
            id,
            parsed.payload,
            crate::project_generators::project_check_name_command,
        ),
        CoreCommand::ProjectExtractArchive => plugin_response(
            id,
            parsed.payload,
            crate::project_generators::project_extract_archive_command,
        ),
        CoreCommand::PluginsMarketplaceValidateIndex => plugin_response(
            id,
            parsed.payload,
            crate::plugins::marketplace::validate_index_command,
        ),
        CoreCommand::PluginsMarketplaceResolveSource => plugin_response(
            id,
            parsed.payload,
            crate::plugins::marketplace::resolve_source_command,
        ),
        CoreCommand::PluginsMarketplaceInstallReview => plugin_response(
            id,
            parsed.payload,
            crate::plugins::marketplace::install_review_command,
        ),
        CoreCommand::AgentInstall => agent_response(id, parsed.payload, crate::agent::install),
        CoreCommand::AgentUninstall => agent_response(id, parsed.payload, crate::agent::uninstall),
        CoreCommand::AgentInstallCli => {
            agent_response(id, parsed.payload, crate::agent::install_cli)
        }
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
        CoreCommand::WorkspaceFilterChanges => {
            match serde_json::from_value::<crate::project::WorkspaceChangeFilterRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::json!(crate::project::filter_workspace_changes(request)),
                ),
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid workspace event paths")
                        .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::WorkspaceListDirectories => {
            match serde_json::from_value::<DirectoryListingRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid directory listing request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(project::list_directories)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("directory listing should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::WorkspaceRepositories => {
            match serde_json::from_value::<WorkspaceRepositoriesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid workspace repositories request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::workspace_repositories)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("workspace repositories should encode"),
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
            match serde_json::from_value::<project::SearchPageRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Search Everywhere request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(project::search_page)
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
        CoreCommand::DocumentClassifyText => {
            match parsed
                .payload
                .get("text")
                .and_then(serde_json::Value::as_str)
            {
                Some(text) => CoreResponse::success(
                    id,
                    serde_json::json!({
                        "isPlainText": project::is_plain_text(text)
                    }),
                ),
                None => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Decoded document text is required",
                    ),
                ),
            }
        }
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
        CoreCommand::HistoryIgnorePreview => {
            match serde_json::from_value::<HistoryIgnorePreviewRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid history ignore preview request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::ignore_preview)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("history ignore preview should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryUsage => {
            match serde_json::from_value::<HistoryStorageRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history usage request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::usage)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("history usage should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::HistoryClear => {
            match serde_json::from_value::<HistoryStorageRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid history clear request")
                        .with_details(error.to_string())
                })
                .and_then(crate::project::clear)
            {
                Ok(()) => CoreResponse::success(id, serde_json::json!({"cleared": true})),
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
        CoreCommand::MavenLaunchPlan => {
            match serde_json::from_value::<crate::project::MavenLaunchPlanRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Maven launch-plan request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::launch_plan)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Maven launch plan should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::ExecutionResolveEnvironment => {
            match serde_json::from_value::<crate::execution::LaunchEnvironmentRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::execution::resolve_launch_environment(request))
                        .expect("environment encodes"),
                ),
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid launch environment request",
                    )
                    .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::ExecutionPlanLaunchCommand => {
            match serde_json::from_value::<crate::execution::LaunchCommandPlanRequest>(
                parsed.payload,
            )
            .map(crate::execution::plan_launch_command_request)
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid Java launch-command request",
                )
                .with_details(error.to_string())
            }) {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java launch-command plan should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::ProcessLifecycleResolve => {
            match serde_json::from_value::<crate::process::lifecycle::LifecycleRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::process::lifecycle::resolve(&request))
                        .expect("process lifecycle plan should encode"),
                ),
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid process lifecycle request",
                    )
                    .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::ProcessLifecycleInventory => {
            match serde_json::from_value::<crate::process::inventory::InventoryRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::process::inventory::classify(&request))
                        .expect("process inventory should encode"),
                ),
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid process inventory request",
                    )
                    .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::ProcessLifecycleSettle => {
            match serde_json::from_value::<crate::process::lifecycle::SettleRequest>(parsed.payload)
            {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::process::lifecycle::settle(&request))
                        .expect("process lifecycle settlement should encode"),
                ),
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid process lifecycle settlement request",
                    )
                    .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::MavenDependencyPlan => {
            match serde_json::from_value::<MavenDependencyPlanRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Maven dependency-plan request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::dependency_plan)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Maven dependency plan should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::MavenDependencies => {
            match serde_json::from_value::<MavenDependenciesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Maven dependencies request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::dependencies)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Maven dependencies should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
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
        CoreCommand::MavenTestResults => {
            match serde_json::from_value::<crate::project::MavenTestResultsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Maven test-results request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::project::test_results)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Maven test results should encode"),
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
        CoreCommand::DebugCreateSession => {
            match serde_json::from_value::<crate::debug::CreateSessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug create-session request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::create_session)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug session update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugLaunch => {
            match serde_json::from_value::<crate::debug::LaunchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid debug launch request")
                        .with_details(error.to_string())
                })
                .and_then(crate::debug::launch)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug launch update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugJavaTestLaunch => {
            match serde_json::from_value::<crate::debug::JavaTestLaunchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java test debug launch request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::java_test_launch)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Java test debug launch configuration should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSteppingFilters => {
            match serde_json::from_value::<crate::debug::DebugSteppingFiltersRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid debug stepping-filters request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::debug::stepping_filters)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug stepping filters should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugRelocateBreakpoints => {
            match serde_json::from_value::<crate::debug::RelocateBreakpointsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug relocate-breakpoints request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::relocate_breakpoints)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug breakpoint relocation should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSetBreakpoints => {
            match serde_json::from_value::<crate::debug::SetBreakpointsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug set-breakpoints request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::set_breakpoints)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug breakpoint update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSetExceptionBreakpoints => {
            match serde_json::from_value::<crate::debug::SetExceptionBreakpointsRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid debug set-exception-breakpoints request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::debug::set_exception_breakpoints)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Debug exception breakpoint update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSetFunctionBreakpoints => {
            match serde_json::from_value::<crate::debug::SetFunctionBreakpointsRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid debug set-function-breakpoints request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::debug::set_function_breakpoints)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Debug function breakpoint update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSetInstructionBreakpoints => {
            match serde_json::from_value::<crate::debug::SetInstructionBreakpointsRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid debug set-instruction-breakpoints request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::debug::set_instruction_breakpoints)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Debug instruction breakpoint update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugDataBreakpointInfo => {
            match serde_json::from_value::<crate::debug::DataBreakpointInfoRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug data-breakpoint-info request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::data_breakpoint_info)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Debug data breakpoint info update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSetDataBreakpoints => {
            match serde_json::from_value::<crate::debug::SetDataBreakpointsRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug set-data-breakpoints request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::set_data_breakpoints)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug data breakpoint update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugSetVariable => {
            match serde_json::from_value::<crate::debug::SetVariableRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug set-variable request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::set_variable)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug variable update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugCancelOperation => {
            match serde_json::from_value::<crate::debug::CancelOperationRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug cancel-operation request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::cancel_operation)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug cancellation update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugExecute => {
            match serde_json::from_value::<crate::debug::ExecuteRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid debug execute request")
                        .with_details(error.to_string())
                })
                .and_then(crate::debug::execute)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug execution update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugInspect => {
            match serde_json::from_value::<crate::debug::InspectRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid debug inspect request")
                        .with_details(error.to_string())
                })
                .and_then(crate::debug::inspect)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug inspection update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugReceive => {
            match serde_json::from_value::<crate::debug::ReceiveRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid debug receive request")
                        .with_details(error.to_string())
                })
                .and_then(crate::debug::receive)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug receive update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugRunInTerminalResponse => {
            match serde_json::from_value::<crate::debug::DebugRunInTerminalResponseRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid debug run-in-terminal response",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::debug::run_in_terminal_response)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Debug run-in-terminal response update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugStartDebuggingResponse => {
            match serde_json::from_value::<crate::debug::DebugStartDebuggingResponseRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid debug start-debugging response",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::debug::start_debugging_response)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Debug start-debugging response update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugDisconnect => {
            match serde_json::from_value::<crate::debug::SessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug disconnect request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::disconnect)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Debug disconnect update should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DebugDestroySession => {
            match serde_json::from_value::<crate::debug::SessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid debug destroy-session request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::debug::destroy_session)
            {
                Ok(destroyed_children) => CoreResponse::success(
                    id,
                    json!({"destroyed": true, "destroyedChildSessionIds": destroyed_children}),
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
        CoreCommand::EditorLineEdit => {
            match serde_json::from_value::<crate::editor::LineEditRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid editor line edit request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::editor::line_edit)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Editor line edit response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::EditorLineCommentToken => {
            match serde_json::from_value::<crate::editor::LineCommentTokenRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid editor line comment token request",
                    )
                    .with_details(error.to_string())
                })
                .map(crate::editor::line_comment_token)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Comment token response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::NetworkProxyPolicy => {
            match serde_json::from_value::<crate::network::NetworkProxyPolicyRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid network proxy policy request",
                )
                .with_details(error.to_string())
            })
            .map(crate::network::proxy_policy)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Proxy policy response should encode"),
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
        CoreCommand::JavaRunMarkers => {
            match serde_json::from_value::<crate::lsp::JavaRunMarkersRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Java Run-marker request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::java_run_markers)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java Run markers should encode"),
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
        CoreCommand::LspRetryMavenProfiles => {
            match serde_json::from_value::<crate::lsp::SessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Maven profile retry request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::retry_maven_profiles)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).unwrap_or(serde_json::Value::Null),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspUpdateMavenConfiguration => {
            match serde_json::from_value::<crate::lsp::UpdateMavenConfigurationRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid Maven configuration update request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::lsp::update_maven_configuration)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Maven configuration update response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspUpdateWorkspaceConfiguration => {
            match serde_json::from_value::<crate::lsp::UpdateWorkspaceConfigurationRequest>(
                parsed.payload,
            )
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid workspace configuration update request",
                )
                .with_details(error.to_string())
            })
            .and_then(crate::lsp::update_workspace_configuration)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("workspace configuration update response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspSaveDocument => {
            match serde_json::from_value::<crate::lsp::SaveDocumentRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid LSP save-document request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::save_document)
            {
                Ok(sent) => CoreResponse::success(id, json!({"sent": sent})),
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
        CoreCommand::LspBuildRequest => {
            match serde_json::from_value::<crate::lsp::BuildProviderRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid build-provider request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::build_provider_request)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Build-provider response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspVcsRequest => {
            match serde_json::from_value::<crate::lsp::VcsProviderRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid VCS-provider request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::vcs_provider_request)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("VCS-provider response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspFunctionRequest => {
            match serde_json::from_value::<crate::lsp::PluginFunctionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid plugin-function request")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::plugin_function_request)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Plugin-function response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::JavaPrepareLaunch => {
            match serde_json::from_value::<crate::lsp::JavaPrepareLaunchRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Java launch preparation request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(crate::lsp::java_prepare_launch)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java launch operation should encode"),
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
        CoreCommand::LspHostResponse => {
            match serde_json::from_value::<crate::lsp::PluginHostResponse>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid host-service response")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::plugin_host_response)
            {
                Ok(()) => CoreResponse::success(id, json!({})),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::LspHostNotify => {
            match serde_json::from_value::<crate::lsp::PluginHostNotification>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid host notification")
                        .with_details(error.to_string())
                })
                .and_then(crate::lsp::plugin_host_notify)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Host notification response should encode"),
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
        CoreCommand::RunConfigSelectJava => {
            match serde_json::from_value::<crate::execution::JavaSelectionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Java selection request")
                        .with_details(error.to_string())
                })
                .and_then(crate::execution::select_java)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Java selection encodes"),
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
        CoreCommand::MybatisIndex => {
            match serde_json::from_value::<MybatisIndexRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid MyBatis index request")
                        .with_details(error.to_string())
                })
                .and_then(crate::languages::mybatis_index)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("MyBatis index response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitWorkspaceCommitPrepare => {
            let result =
                serde_json::from_value::<git::workspace_commit::PrepareRequest>(parsed.payload)
                    .map_err(|error| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "Invalid workspace commit request",
                        )
                        .with_details(error.to_string())
                    })
                    .and_then(git::workspace_commit::prepare);
            match result {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Workspace commit response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitWorkspaceCommitStep => {
            let result =
                serde_json::from_value::<git::workspace_commit::StepRequest>(parsed.payload)
                    .map_err(|error| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "Invalid workspace commit request",
                        )
                        .with_details(error.to_string())
                    })
                    .and_then(git::workspace_commit::step);
            match result {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Workspace commit response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitCommitState => {
            match serde_json::from_value::<GitStatusRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid commit state request")
                        .with_details(error.to_string())
                })
                .and_then(git::commit_state)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Commit state should encode"),
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
        CoreCommand::GitUntrackedDirectory => {
            match serde_json::from_value::<GitUntrackedDirectoryRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git untracked directory request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::untracked_directory)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git untracked directory should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
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

        CoreCommand::GitWorktrees => {
            match serde_json::from_value::<GitWorktreesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git worktrees request")
                        .with_details(error.to_string())
                })
                .and_then(git::worktrees)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git worktrees should encode"),
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
        CoreCommand::GitRepositoryRoot => {
            match serde_json::from_value::<GitRepositoryRootRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git repository root request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::discover_repository_root)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git repository root response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitRebasePreview => {
            match serde_json::from_value::<GitRebasePreviewRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid rebase preview request")
                        .with_details(error.to_string())
                })
                .and_then(git::rebase_preview)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Rebase preview should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitRebaseStart => {
            match serde_json::from_value::<GitRebaseStartRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid rebase start request")
                        .with_details(error.to_string())
                })
                .and_then(git::rebase_start)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Rebase start should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitRebaseSession => {
            match serde_json::from_value::<GitRebaseSessionRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid rebase session request")
                        .with_details(error.to_string())
                })
                .and_then(git::rebase_session)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Rebase session should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitRebaseControl => {
            match serde_json::from_value::<GitRebaseControlRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid rebase control request")
                        .with_details(error.to_string())
                })
                .and_then(git::rebase_control)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Rebase control should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitRepositorySetup => {
            match serde_json::from_value::<git::GitSetupRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git setup request")
                        .with_details(error.to_string())
                })
                .and_then(git::repository_setup)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git setup should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitInitialize => {
            match serde_json::from_value::<git::GitSetupRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git setup request")
                        .with_details(error.to_string())
                })
                .and_then(git::initialize_repository)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git setup should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitConfigureIdentity => {
            match serde_json::from_value::<git::GitConfigureIdentityRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git setup request")
                        .with_details(error.to_string())
                })
                .and_then(git::configure_identity)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git setup should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitPatchExport => {
            match serde_json::from_value::<PatchExportRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid patch export request")
                        .with_details(error.to_string())
                })
                .and_then(git::export_patch)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Patch export should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitPatchPreview => {
            match serde_json::from_value::<PatchPreviewRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid patch preview request")
                        .with_details(error.to_string())
                })
                .and_then(git::preview_patch)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Patch preview should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitPatchApply => {
            match serde_json::from_value::<PatchApplyRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid patch apply request")
                        .with_details(error.to_string())
                })
                .and_then(git::apply_patch_reviewed)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Patch apply should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitHistoryRewritePreview => {
            match serde_json::from_value::<GitHistoryRewritePreviewRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid history rewrite preview request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::history_rewrite_preview)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("History rewrite preview should encode"),
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
        CoreCommand::GitAuthRespond => {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Reply {
                request_id: String,
                answer: Option<String>,
            }
            match serde_json::from_value::<Reply>(parsed.payload) {
                Ok(reply) => CoreResponse::success(
                    id,
                    json!({ "accepted": lithe_git_host::authentication::respond(&reply.request_id, reply.answer) }),
                ),
                Err(_) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git authentication response",
                    ),
                ),
            }
        }
        CoreCommand::GitExecutable => match git::configuration::locate_executable() {
            Ok(data) => CoreResponse::success(id, data),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::RemoteProbe => {
            match serde_json::from_value::<crate::remote::ProbeRequest>(parsed.payload) {
                Ok(request) => match crate::remote::probe(request) {
                    Ok(result) => CoreResponse::success(
                        id,
                        serde_json::to_value(result).expect("remote probe result should encode"),
                    ),
                    Err(error) => CoreResponse::failure(id, error),
                },
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid remote probe request")
                        .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::RemoteConnect => {
            match serde_json::from_value::<crate::remote::sessions::ConnectRequest>(parsed.payload)
            {
                Ok(request) => match crate::remote::sessions::connect(request) {
                    Ok(result) => CoreResponse::success(
                        id,
                        serde_json::to_value(result).expect("remote connect result should encode"),
                    ),
                    Err(error) => CoreResponse::failure(id, error),
                },
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid remote connect request")
                        .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::RemoteReadDir => {
            match serde_json::from_value::<crate::remote::sessions::ReadDirRequest>(parsed.payload)
            {
                Ok(request) => match crate::remote::sessions::read_dir(request) {
                    Ok(result) => CoreResponse::success(id, result),
                    Err(error) => CoreResponse::failure(id, error),
                },
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid remote directory request",
                    )
                    .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::RemoteReadFile => {
            match serde_json::from_value::<crate::remote::sessions::ReadFileRequest>(parsed.payload)
            {
                Ok(request) => match crate::remote::sessions::read_file(request) {
                    Ok(result) => CoreResponse::success(id, result),
                    Err(error) => CoreResponse::failure(id, error),
                },
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid remote file request")
                        .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::RemoteWriteFile => {
            match serde_json::from_value::<crate::remote::sessions::WriteFileRequest>(
                parsed.payload,
            ) {
                Ok(request) => match crate::remote::sessions::write_file(request) {
                    Ok(result) => CoreResponse::success(id, result),
                    Err(error) => CoreResponse::failure(id, error),
                },
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid remote file request")
                        .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::RemoteCaptureProcess => {
            match serde_json::from_value(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid host capture request")
                        .with_details(error.to_string())
                })
                .and_then(crate::remote::workspace_host::capture_process)
            {
                Ok(value) => CoreResponse::success(id, value),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RemoteHostRequest
        | CoreCommand::RemoteRunProcess
        | CoreCommand::RemoteRunWatch
        | CoreCommand::RemoteRunTerminal => {
            let operation = match command {
                CoreCommand::RemoteHostRequest => crate::remote::workspace_host::request,
                CoreCommand::RemoteRunProcess => crate::remote::workspace_host::run_process,
                CoreCommand::RemoteRunWatch => crate::remote::workspace_host::run_watch,
                _ => crate::remote::workspace_host::run_terminal,
            };
            match serde_json::from_value(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid workspace host request")
                        .with_details(error.to_string())
                })
                .and_then(operation)
            {
                Ok(value) => CoreResponse::success(id, value),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RemoteUploadFile => {
            match serde_json::from_value(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid upload request")
                        .with_details(error.to_string())
                })
                .and_then(crate::remote::upload::upload)
            {
                Ok(value) => CoreResponse::success(id, value),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RemoteHostInfo => {
            match parsed
                .payload
                .get("sessionId")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Missing host session"))
                .and_then(crate::remote::upload::host_info)
            {
                Ok(value) => CoreResponse::success(id, value),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::RemoteDisconnect => {
            match serde_json::from_value::<crate::remote::sessions::DisconnectRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    json!({ "closed": crate::remote::sessions::disconnect(request) }),
                ),
                Err(error) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid remote disconnect request",
                    )
                    .with_details(error.to_string()),
                ),
            }
        }
        CoreCommand::RemoteCloseAll => CoreResponse::success(
            id,
            json!({ "closed": crate::remote::sessions::close_all() }),
        ),
        CoreCommand::RemoteAuthRespond => {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Reply {
                request_id: String,
                answer: Option<String>,
            }
            match serde_json::from_value::<Reply>(parsed.payload) {
                Ok(reply) => CoreResponse::success(
                    id,
                    json!({ "accepted": crate::remote::respond(&reply.request_id, reply.answer) }),
                ),
                Err(_) => CoreResponse::failure(
                    id,
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid remote authentication response",
                    ),
                ),
            }
        }
        CoreCommand::GitExecutionInspect | CoreCommand::GitExecutionConfigure => {
            match git::configuration::dispatch(
                parsed.payload,
                matches!(command, CoreCommand::GitExecutionConfigure),
            ) {
                Ok(value) => CoreResponse::success(id, value),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitRemoteUrl => match git::configuration::remote_url(parsed.payload) {
            Ok(value) => CoreResponse::success(id, value),
            Err(error) => CoreResponse::failure(id, error),
        },
        CoreCommand::GitConsolePresentation => {
            match serde_json::from_value::<git::console::Request>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git console snapshot")
                        .with_details(error.to_string())
                })
                .and_then(git::console::present)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Console presentation should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitFetchPlan => {
            match serde_json::from_value::<git::GitFetchPlanRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Fetch plan request")
                        .with_details(error.to_string())
                })
                .and_then(git::fetch_plan)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Fetch plan should encode"),
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
        CoreCommand::GitReferences => {
            match serde_json::from_value::<GitReferencesRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git references request")
                        .with_details(error.to_string())
                })
                .and_then(git::references)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git references response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitHistoryPage => {
            match serde_json::from_value::<GitHistoryPageRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git history page request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::history_page)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git history page response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitHistoryCursorClose => {
            match serde_json::from_value::<GitHistoryCursorCloseRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git history cursor close request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::close_history_cursor)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data)
                        .expect("Git history cursor close response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::GitPushPreview => {
            match serde_json::from_value::<GitPushPreviewRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git push preview request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::push_preview)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git push preview response should encode"),
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
        CoreCommand::GitLineHistory => {
            match serde_json::from_value::<GitLineHistoryRequest>(parsed.payload)
                .map_err(|error| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid Git line history request",
                    )
                    .with_details(error.to_string())
                })
                .and_then(git::line_history)
            {
                Ok(data) => CoreResponse::success(
                    id,
                    serde_json::to_value(data).expect("Git line history response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
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
        CoreCommand::DiagnosticsPrepareLogEvent => {
            match serde_json::from_value::<crate::diagnostics::logging::LogEventRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::diagnostics::logging::prepare_log_event(request))
                        .expect("Log event should encode"),
                ),
                Err(_) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid log event request"),
                ),
            }
        }
        CoreCommand::DiagnosticsQueryLogs => {
            match serde_json::from_value::<crate::diagnostics::logging::LogQueryRequest>(
                parsed.payload,
            ) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::diagnostics::logging::query_logs(request))
                        .expect("Log query should encode"),
                ),
                Err(_) => CoreResponse::failure(
                    id,
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid log query request"),
                ),
            }
        }
        CoreCommand::DiagnosticsRedactText => {
            match serde_json::from_value::<RedactTextRequest>(parsed.payload).map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid diagnostics redact request",
                )
                .with_details(error.to_string())
            }) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::diagnostics::redact_text(request))
                        .expect("Diagnostics redact response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
        CoreCommand::DiagnosticsBuildManifest => {
            match serde_json::from_value::<BuildManifestRequest>(parsed.payload).map_err(|error| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid diagnostics manifest request",
                )
                .with_details(error.to_string())
            }) {
                Ok(request) => CoreResponse::success(
                    id,
                    serde_json::to_value(crate::diagnostics::build_manifest(request))
                        .expect("Diagnostics manifest response should encode"),
                ),
                Err(error) => CoreResponse::failure(id, error),
            }
        }
    };
    // Workspace steps already reconcile cancelled writes under a bounded cleanup
    // deadline. Preserve that continuation so a retry cannot duplicate a commit.
    if response.is_success() && !preserve_workspace_outcome {
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
                "command": "lsp.buildRequest",
                "payload": {
                    "sessionId": unknown_session,
                    "operationId": "build-1",
                    "method": "lithe/build/model",
                    "params": {}
                }
            }),
            json!({
                "command": "lsp.functionRequest",
                "payload": {
                    "sessionId": unknown_session,
                    "operationId": "function-1",
                    "function": { "pluginID": "dev.lithe.fixture.maven", "functionID": "snapshot.refresh" },
                    "params": {}
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
