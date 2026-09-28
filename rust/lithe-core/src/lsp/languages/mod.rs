//! Dynamic provider metadata and host-model adapters for individual languages.

mod catalog;
pub(crate) mod java_entrypoints;
pub(crate) mod java_main_methods;
pub(crate) mod java_navigation_syntax;
mod java_run_markers;
pub(crate) mod java_tests;
mod java_workspace;
pub(crate) mod jdt;
pub(crate) mod jdt_build;
mod jdt_configuration;
pub(crate) mod jdt_navigation;
pub(crate) mod jdt_progress;
mod jdt_project_metadata;
pub(crate) mod project_preparation;
#[cfg(test)]
pub(crate) mod swift;

pub(crate) use catalog::*;
pub(crate) use java_run_markers::{java_run_markers, JavaRunMarkersRequest};
pub(crate) use java_workspace::{
    java_workspace_policy, jdt_cache_retention, jdt_workspace_fingerprint,
    JavaWorkspacePolicyRequest, JdtCacheRetentionRequest, JdtWorkspaceFingerprintRequest,
};
pub(crate) use jdt::{resolve_workspace_key, workspace_key, JdtWorkspaceKeyRequest};
pub(crate) use jdt_configuration::prepare_configuration_area as prepare_jdt_configuration_area;
pub(crate) use jdt_project_metadata::prepare_workspace as prepare_jdt_workspace;
