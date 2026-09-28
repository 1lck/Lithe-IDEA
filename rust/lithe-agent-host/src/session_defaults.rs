//! Resolve stale new-session model defaults through the adapter's own catalog.
//!
//! Codex ACP retains an unknown configured model as a synthetic selector choice.
//! Its legacy model state excludes that choice, and its versioned AIR extension
//! supplies the actual recommended model. Neither fact is guessed from a name.

use std::path::PathBuf;

use agent_client_protocol::schema::v1::{
    NewSessionRequest, NewSessionResponse, SessionConfigKind, SessionConfigOptionCategory,
    SessionConfigSelectOptions, SetSessionConfigOptionRequest,
};
use agent_client_protocol::{Agent, ConnectionTo, JsonRpcRequest, JsonRpcResponse};
use serde::{Deserialize, Serialize};

/// Preserve the adapter's optional legacy model catalog, which SDK v1 discards.
/// Standard request fields and transport remain owned by the ACP SDK.
#[derive(Debug, Clone, Serialize, Deserialize, JsonRpcRequest)]
#[request(method = "session/new", response = CatalogSessionResponse)]
struct CatalogSessionRequest {
    #[serde(flatten)]
    request: NewSessionRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonRpcResponse)]
struct CatalogSessionResponse {
    #[serde(flatten)]
    session: NewSessionResponse,
    #[serde(default)]
    models: Option<serde_json::Value>,
}

/// Codex legacy ids are `base-model[reasoning-effort]`; selectors use the base.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyModelState {
    current_model_id: String,
    available_models: Vec<LegacyModel>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyModel {
    model_id: String,
}

fn base_model(id: &str) -> &str {
    id.strip_suffix(']')
        .and_then(|id| id.rsplit_once('[').map(|(base, _)| base))
        .unwrap_or(id)
}

/// A recommendation is used only with positive evidence that the current model
/// is absent from the catalog and the replacement exists in both upstream lists.
fn replacement(response: &CatalogSessionResponse) -> Option<(String, String)> {
    // Optional legacy fields must not turn an otherwise valid ACP response into
    // an error when a different adapter uses another model-state shape.
    let models: LegacyModelState =
        serde_json::from_value(response.models.as_ref()?.clone()).ok()?;
    let available = |value: &str| {
        models
            .available_models
            .iter()
            .any(|model| base_model(&model.model_id) == value)
    };
    let options = response.session.config_options.as_ref()?;
    for option in options {
        if option.category != Some(SessionConfigOptionCategory::Model) {
            continue;
        }
        let SessionConfigKind::Select(select) = &option.kind else {
            continue;
        };
        let current = select.current_value.0.as_ref();
        if current != base_model(&models.current_model_id) || available(current) {
            continue;
        }
        let air = option.meta.as_ref()?.get("jetbrains")?.get("air")?;
        if air.get("version")?.as_u64()? < 1 {
            continue;
        }
        let recommended = air.get("recommendedValue")?.as_str()?;
        let selectable = match &select.options {
            SessionConfigSelectOptions::Ungrouped(options) => options
                .iter()
                .any(|choice| choice.value.0.as_ref() == recommended),
            SessionConfigSelectOptions::Grouped(groups) => groups.iter().any(|group| {
                group
                    .options
                    .iter()
                    .any(|choice| choice.value.0.as_ref() == recommended)
            }),
            _ => false,
        };
        if available(recommended) && selectable {
            return Some((option.id.0.to_string(), recommended.to_owned()));
        }
    }
    None
}

/// Create and, when necessary, repair only a new session. The caller's single
/// request deadline covers both requests; history and global CLI files stay intact.
pub(crate) async fn new_session(
    connection: &ConnectionTo<Agent>,
    cwd: PathBuf,
) -> Result<NewSessionResponse, agent_client_protocol::Error> {
    let mut response = connection
        .send_request(CatalogSessionRequest {
            request: NewSessionRequest::new(cwd),
        })
        .block_task()
        .await?;
    if let Some((id, model)) = replacement(&response) {
        let configured = connection
            .send_request(SetSessionConfigOptionRequest::new(
                response.session.session_id.clone(),
                id.clone(),
                model.as_str(),
            ))
            .block_task()
            .await?;
        let confirmed = configured.config_options.iter().any(|option| {
            option.id.0.as_ref() == id
                && matches!(&option.kind, SessionConfigKind::Select(select) if select.current_value.0.as_ref() == model)
        });
        if !confirmed {
            return Err(super::internal(
                "The Agent did not confirm its recommended model. Retry the conversation.",
            ));
        }
        response.session.config_options = Some(configured.config_options);
    }
    Ok(response.session)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repair_requires_catalog_and_a_selectable_upstream_recommendation() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/agent/acp-events-v1.json"
        ))
        .unwrap();
        let initial = fixture["upstream"]["staleModelSession"].clone();
        let parsed = |value| serde_json::from_value::<CatalogSessionResponse>(value).unwrap();
        assert_eq!(
            replacement(&parsed(initial.clone())),
            Some(("model".into(), "model-current".into()))
        );
        for mutation in [
            "validCurrent",
            "noCatalog",
            "malformedCatalog",
            "emptyCatalog",
            "noRecommendation",
            "unavailableRecommendation",
            "wrongVersion",
            "mismatchedCurrent",
        ] {
            let mut value = initial.clone();
            match mutation {
                "validCurrent" => value["models"]["availableModels"]
                    .as_array_mut()
                    .unwrap()
                    .push(serde_json::json!({"modelId": "model-retired[max]"})),
                "noCatalog" => {
                    value.as_object_mut().unwrap().remove("models");
                }
                "malformedCatalog" => {
                    value["models"] = serde_json::json!({"availableModels": "invalid"})
                }
                "emptyCatalog" => value["models"]["availableModels"] = serde_json::json!([]),
                "noRecommendation" => {
                    value["configOptions"][0]
                        .as_object_mut()
                        .unwrap()
                        .remove("_meta");
                }
                "unavailableRecommendation" => {
                    value["configOptions"][0]["_meta"]["jetbrains"]["air"]["recommendedValue"] =
                        serde_json::json!("unknown")
                }
                "wrongVersion" => {
                    value["configOptions"][0]["_meta"]["jetbrains"]["air"]["version"] =
                        serde_json::json!(0)
                }
                "mismatchedCurrent" => {
                    value["models"]["currentModelId"] = serde_json::json!("different[max]")
                }
                _ => unreachable!(),
            }
            assert_eq!(replacement(&parsed(value)), None, "{mutation}");
        }
    }
}
