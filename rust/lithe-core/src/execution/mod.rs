//! Run configuration generation, resolution, and project detectors.

mod argument_text;
mod configuration;
mod context_selection;
mod detectors;
pub(crate) mod generated_layer;
mod provider_run_options;
mod provider_runs;
// Toolchain requirement reading for hosts that select a toolchain candidate
// without owning Core's in-process generated layer.
pub use configuration::{
    read_requirements, validate_sidecar_version, version_parts, version_satisfies,
    ToolchainRequirementsDocument,
};
mod types;

pub(crate) use argument_text::{format_argument_text, ArgumentTextRequest};
pub(crate) use configuration::*;
pub(crate) use context_selection::{select_context_configuration, ContextSelectionRequest};
pub(crate) use detectors::{scan, DirectoryContext};

pub(crate) mod workspace_scan;
pub use workspace_scan::is_run_scan_excluded_directory;

mod environment;
pub use environment::{
    resolve_launch_environment, resolve_search_path, LaunchEnvironmentRequest,
    LaunchEnvironmentResponse, SearchPathCandidate, SearchPathRequest,
};
