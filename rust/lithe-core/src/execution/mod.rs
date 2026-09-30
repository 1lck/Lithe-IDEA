//! Run configuration generation, resolution, and project detectors.

mod configuration;
mod detectors;
mod java_selection;
mod launch_command;
pub use java_selection::{
    compare_java_candidates, select_java, select_java_candidates, JavaSelection,
    JavaSelectionCandidate, JavaSelectionRequest,
};
mod types;

pub(crate) use configuration::*;
pub use launch_command::{
    java_feature_version_from_release, plan_launch_command, plan_launch_command_request,
    LaunchCommandPlan, LaunchCommandPlanRequest, LaunchCommandPlanResponse,
    WINDOWS_COMMAND_LINE_LIMIT,
};
