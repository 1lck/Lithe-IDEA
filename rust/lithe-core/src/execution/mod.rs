//! Run configuration generation, resolution, and project detectors.

mod argument_text;
mod configuration;
mod context_selection;
mod detectors;
pub(crate) mod generated_layer;
mod java_selection;
mod launch_command;
mod project_ownership;
mod provider_run_options;
mod provider_runs;
// Toolchain requirement reading that a host-side Java selector needs without
// owning Core's in-process generated layer.
pub use configuration::{
    java_feature_version_parts, read_requirements, validate_sidecar_version, version_parts,
    version_satisfies, ToolchainRequirementsDocument,
};
pub use java_selection::{
    compare_java_candidates, select_java, select_java_candidates, JavaSelection,
    JavaSelectionCandidate, JavaSelectionRequest,
};
mod types;

pub(crate) use argument_text::{format_argument_text, ArgumentTextRequest};
pub(crate) use configuration::*;
pub(crate) use context_selection::{select_context_configuration, ContextSelectionRequest};
pub(crate) use detectors::{scan, DirectoryContext};
pub use launch_command::{
    java_feature_version_from_release, java_version_from_release, plan_launch_command,
    plan_launch_command_request, LaunchCommandPlan, LaunchCommandPlanRequest,
    LaunchCommandPlanResponse, WINDOWS_COMMAND_LINE_LIMIT,
};

pub(crate) mod workspace_scan;
pub use workspace_scan::is_run_scan_excluded_directory;

mod environment;
pub use environment::{
    resolve_launch_environment, resolve_search_path, LaunchEnvironmentRequest,
    LaunchEnvironmentResponse, SearchPathCandidate, SearchPathRequest,
};
