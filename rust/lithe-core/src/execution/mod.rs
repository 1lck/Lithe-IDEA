//! Run configuration generation, resolution, and project detectors.

mod configuration;
mod detectors;
mod launch_command;
mod types;

pub(crate) use configuration::*;
pub use launch_command::{
    java_feature_version_from_release, plan_launch_command, plan_launch_command_request,
    LaunchCommandPlan, LaunchCommandPlanRequest, LaunchCommandPlanResponse,
    WINDOWS_COMMAND_LINE_LIMIT,
};
