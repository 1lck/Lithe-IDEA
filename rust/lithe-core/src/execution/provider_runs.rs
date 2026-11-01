//! Validates and materializes opaque provider run selectors from current model snapshots.
//! Tool, framework, runtime and configuration semantics remain with the selected provider.

use super::configuration::{BuildProviderRunReference, RunConfiguration};
use super::types::{Confidence, RunCategory};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// One declared provider run applied to an upstream target, independent of language imports.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderRunConfiguration {
    /// Workspace-relative current model project; never inferred from a descriptor.
    pub project_path: String,
    pub name: String,
    pub reference: BuildProviderRunReference,
}

fn contains(root: &str, path: &str) -> bool {
    root == "." || root == path || path.starts_with(&(root.to_string() + "/"))
}

/// Validates a complete run snapshot without reading tool configuration or starting processes.
pub(super) fn validate(runs: &[ProviderRunConfiguration]) -> Result<(), CoreError> {
    let invalid = || CoreError::new(ErrorCode::InvalidRequest, "Invalid provider run snapshot");
    if runs.len() > 10000 {
        return Err(invalid());
    }
    let mut identities = BTreeSet::new();
    for run in runs {
        run.reference.validate()?;
        if run.name.trim().is_empty()
            || run.name.len() > 4096
            || run.name.chars().any(char::is_control)
            || crate::protocol::invalid_relative_path(&run.project_path)
            || run.project_path.is_empty()
            || run.project_path.len() > 4096
            || run.project_path.contains(['\\', '\0'])
            || !contains(&run.reference.root, &run.project_path)
            || !run.reference.user_arguments.is_empty()
            || !identities.insert(run.reference.generated_id())
        {
            return Err(invalid());
        }
    }
    Ok(())
}

/// Materializes selectors without inventing commands, toolchains or adapter identities.
pub(super) fn configurations(runs: &[ProviderRunConfiguration]) -> Vec<RunConfiguration> {
    let mut ordered = runs.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|run| run.reference.generated_id());
    ordered
        .into_iter()
        .map(|run| RunConfiguration {
            id: run.reference.generated_id(),
            name: run.name.clone(),
            provider: "build.provider".to_string(),
            execution: run.reference.execution.unwrap_or_default(),
            category: RunCategory::Project,
            command: None,
            args: Vec::new(),
            cwd: run.reference.root.clone(),
            env: BTreeMap::new(),
            confidence: Confidence::Declared,
            toolchains: BTreeMap::new(),
            debug: None,
            members: Vec::new(),
            extensions: [(
                "build".to_string(),
                serde_json::to_value(&run.reference).expect("validated reference encodes"),
            )]
            .into_iter()
            .collect(),
            disabled: false,
            source: None,
        })
        .collect()
}

/// Identity of the complete declaration/target snapshot, independent of input ordering.
pub(super) fn fingerprint(runs: &[ProviderRunConfiguration]) -> String {
    use sha2::{Digest, Sha256};
    let mut ordered = runs.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|run| run.reference.generated_id());
    let bytes = serde_json::to_vec(&ordered).expect("validated run snapshot encodes");
    format!("sha256:{:x}", Sha256::digest(bytes))
}

/// Complete saved references own their identity; an ID prefix is not an execution capability.
/// Validation still rejects malformed selectors after layer merging.
pub(super) fn is_explicit(item: &Value) -> bool {
    item["provider"] == "build.provider" && item["id"].is_string() && item["name"].is_string()
}

/// Opaque selector identity for deduplication, independent of user choices or display names.
pub(super) fn selector(item: &Value) -> Option<String> {
    (item["provider"] == "build.provider").then_some(())?;
    let reference: BuildProviderRunReference =
        serde_json::from_value(item["extensions"]["build"].clone()).ok()?;
    Some(reference.generated_id())
}
