//! Passive model bridge to the existing Core backend. Maven's integration
//! already calls `project::maven::scan`, the same owner as the legacy
//! `maven.scan` entry. This host forwards the exact instance root/options;
//! it does not parse POMs, infer modules, start JDT, or execute a wrapper.

use super::super::build_registry::BuildCoreExecutor;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub(crate) fn read_passive_model(
    core: &dyn BuildCoreExecutor,
    manifest: &Value,
    build_system_id: &str,
    workspace_root: &str,
    root: &str,
    options: &BTreeMap<String, Value>,
) -> Result<Value, String> {
    // Core validates the declared source/integration and owns normalization.
    // In particular, modelPlan is intentionally unavailable for a passive
    // source; invoking it would incorrectly require tools/consent to read it.
    core.execute(
        "build.decodeModel",
        json!({
            "manifest": manifest, "buildSystemID": build_system_id,
            "request": { "workspaceRoot": workspace_root, "root": root, "options": options },
        }),
    )
}
