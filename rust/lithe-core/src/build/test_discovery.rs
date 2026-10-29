//! Normalizes provider-owned test selectors without inferring test semantics.
//! Every item must round-trip through the ordinary typed test plan, so discovery
//! cannot expose an item the declaration is unable to run exactly.

use super::decode::{invalid_output, MAX_OUTPUT_BYTES};
use super::manifest::BuildSystemDeclaration;
use super::plans::{self, PlanBase, SelectedEntity, TestPlanRequest};
use crate::plugins::declarative::Validation;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const MAX_TESTS: usize = 10_000;

/// The plan's configuration and a provider's canonical discovery result.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeTestDiscoveryRequest {
    #[serde(flatten)]
    pub(crate) base: PlanBase,
    pub(crate) result: Value,
}

/// Selectors have no host-generated command or cached upstream project model.
#[derive(Deserialize)]
struct Selector {
    suite: String,
    case: String,
    project: Option<SelectedEntity>,
    target: Option<SelectedEntity>,
}

/// Rejects the entire malformed result rather than publishing a partial list
/// whose apparent completeness could hide tests or widen a selected run.
pub(crate) fn decode(
    build_system: &BuildSystemDeclaration,
    request: &DecodeTestDiscoveryRequest,
) -> Validation<Value> {
    if !build_system
        .test
        .as_ref()
        .is_some_and(|test| test.discovery)
    {
        return Err(plans::unavailable(build_system, "test discovery"));
    }
    // Validate host context even for a valid empty discovery result.
    plans::PlanContext::new(build_system, &request.base)?;
    let result = &request.result;
    if serde_json::to_vec(result).map_or(usize::MAX, |bytes| bytes.len()) > MAX_OUTPUT_BYTES
        || result["format"] != "litheTestDiscovery"
        || result["version"] != 1
    {
        return Err(invalid_output("Invalid test discovery document."));
    }
    let tests = result["tests"]
        .as_array()
        .filter(|tests| tests.len() <= MAX_TESTS)
        .ok_or_else(|| invalid_output("Test discovery requires at most 10000 selectors."))?;
    let mut normalized = BTreeMap::new();
    for test in tests {
        let selector: Selector = serde_json::from_value(test.clone())
            .map_err(|_| invalid_output("Invalid test selector."))?;
        let plan = plans::test_plan(
            build_system,
            &TestPlanRequest {
                base: request.base.clone(),
                project: selector.project,
                target: selector.target,
                suite: Some(selector.suite),
                case: Some(selector.case),
                user_arguments: vec![],
                projects: vec![],
            },
        )
        .map_err(|_| invalid_output("A discovered selector cannot be run by this declaration."))?;
        let params = &plan["provider"]["params"];
        let mut selected = json!({"suite":params["suite"],"case":params["case"]});
        for field in ["project", "target"] {
            if let Some(value) = params.get(field) {
                selected[field] = value.clone();
            }
        }
        let key = serde_json::to_string(&selected).expect("selector is JSON");
        // Identity includes project and target, so equal suite/case names in
        // sibling modules remain independently runnable. Order is deterministic.
        selected["id"] = json!(format!("test:{:x}", Sha256::digest(key.as_bytes())));
        normalized.insert(key, selected);
    }
    Ok(json!({"tests":normalized.into_values().collect::<Vec<_>>()}))
}
