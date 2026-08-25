//! Dynamic provider metadata and host-model adapters for individual languages.

mod catalog;
pub(crate) mod java_navigation_syntax;
mod java_workspace;
pub(crate) mod jdt;
pub(crate) mod jdt_navigation;
#[cfg(test)]
pub(crate) mod swift;

pub(crate) use catalog::*;
pub(crate) use java_workspace::{
    java_workspace_policy, jdt_cache_retention, jdt_workspace_fingerprint,
    JavaWorkspacePolicyRequest, JdtCacheRetentionRequest, JdtWorkspaceFingerprintRequest,
};
pub(crate) use jdt::{resolve_workspace_key, workspace_key, JdtWorkspaceKeyRequest};
