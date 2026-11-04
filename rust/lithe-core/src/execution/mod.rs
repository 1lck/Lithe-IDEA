//! Run configuration generation, resolution, and project detectors.

mod argument_text;
mod classpath_jar;
mod configuration;
mod detectors;
pub(crate) mod generated_layer;
mod java_selection;
mod launch_command;
mod project_ownership;
mod provider_run_options;
mod provider_runs;
pub use java_selection::{
    compare_java_candidates, select_java, select_java_candidates, JavaSelection,
    JavaSelectionCandidate, JavaSelectionRequest,
};
mod types;

pub(crate) use argument_text::{format_argument_text, ArgumentTextRequest};
pub use classpath_jar::{
    plan_classpath_jar_launch, ClasspathJarPlan, ClasspathJarRequest, ClasspathStyle,
};
pub(crate) use configuration::*;
pub(crate) use detectors::{scan, DirectoryContext};
pub use launch_command::{
    java_feature_version_from_release, java_version_from_release, plan_launch_command,
    plan_launch_command_request, LaunchCommandPlan, LaunchCommandPlanRequest,
    LaunchCommandPlanResponse, WINDOWS_COMMAND_LINE_LIMIT,
};

pub(crate) mod workspace_scan;
pub use workspace_scan::{is_run_scan_excluded_directory, list_run_java_sources};

mod environment;
pub use environment::{
    resolve_launch_environment, resolve_search_path, LaunchEnvironmentRequest,
    LaunchEnvironmentResponse, SearchPathCandidate, SearchPathRequest,
};
