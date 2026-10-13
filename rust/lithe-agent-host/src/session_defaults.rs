//! Resolve stale new-session model defaults through the adapter's own catalog.
//!
//! Codex ACP retains an unknown configured model as a synthetic selector choice.
//! Its legacy model state excludes that choice, and its versioned AIR extension
//! may supply a recommended model. Without one, select from the catalog itself;
//! neither availability nor preference is guessed from a model name.

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

/// Find a valid replacement from the Agent-owned catalog without guessing a
/// model name. The AIR recommendation wins; older adapters fall back to the
/// first catalog choice that the Agent exposed in its selector.
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
        let recommended = option
            .meta
            .as_ref()
            .and_then(|meta| meta.get("jetbrains"))
            .and_then(|jetbrains| jetbrains.get("air"))
            .filter(|air| {
                air.get("version")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(0)
                    >= 1
            })
            .and_then(|air| air.get("recommendedValue"))
            .and_then(serde_json::Value::as_str)
            .filter(|value| available(value));
        let selectable = |value: &str| match &select.options {
            SessionConfigSelectOptions::Ungrouped(options) => options
                .iter()
                .any(|choice| choice.value.0.as_ref() == value),
            SessionConfigSelectOptions::Grouped(groups) => groups.iter().any(|group| {
                group
                    .options
                    .iter()
                    .any(|choice| choice.value.0.as_ref() == value)
            }),
            _ => false,
        };
        if let Some(recommended) = recommended.filter(|value| selectable(value)) {
            return Some((option.id.0.to_string(), recommended.to_owned()));
        }
        let fallback = models
            .available_models
            .iter()
            .map(|model| base_model(&model.model_id))
            .find(|value| selectable(value));
        if let Some(fallback) = fallback {
            return Some((option.id.0.to_string(), fallback.to_owned()));
        }
    }
    None
}

/// Create and, when necessary, repair only a new session. The caller's single
/// request deadline covers both requests; history and global CLI files stay intact.
pub(crate) async fn new_session(
    connection: &ConnectionTo<Agent>,
    request: NewSessionRequest,
) -> Result<NewSessionResponse, agent_client_protocol::Error> {
    let mut response = connection
        .send_request(CatalogSessionRequest { request })
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
                "The Agent did not confirm the selected model. Retry the conversation.",
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
    fn repair_uses_recommendation_or_a_selectable_catalog_model() {
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
        for (mutation, expected) in [
            ("validCurrent", None),
            ("noCatalog", None),
            ("malformedCatalog", None),
            ("emptyCatalog", None),
            ("noRecommendation", Some(("model", "model-current"))),
            (
                "unavailableRecommendation",
                Some(("model", "model-current")),
            ),
            ("wrongVersion", Some(("model", "model-current"))),
            ("preferRecommendation", Some(("model", "model-other"))),
            ("unselectableRecommendation", Some(("model", "model-other"))),
            (
                "groupedWithoutRecommendation",
                Some(("model", "model-current")),
            ),
            ("noSelectableCatalogModel", None),
            ("mismatchedCurrent", None),
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
                "preferRecommendation" => {
                    value["configOptions"][0]["_meta"]["jetbrains"]["air"]["recommendedValue"] =
                        serde_json::json!("model-other")
                }
                "unselectableRecommendation" => {
                    value["configOptions"][0]["options"]
                        .as_array_mut()
                        .unwrap()
                        .remove(1);
                }
                "groupedWithoutRecommendation" => {
                    let option = &mut value["configOptions"][0];
                    option.as_object_mut().unwrap().remove("_meta");
                    option["options"] = serde_json::json!([{
                        "group": "official", "name": "Official", "options": option["options"]
                    }]);
                }
                "noSelectableCatalogModel" => {
                    value["configOptions"][0]["options"]
                        .as_array_mut()
                        .unwrap()
                        .truncate(1);
                }
                "mismatchedCurrent" => {
                    value["models"]["currentModelId"] = serde_json::json!("different[max]")
                }
                _ => unreachable!(),
            }
            assert_eq!(
                replacement(&parsed(value)),
                expected.map(|(id, model)| (id.into(), model.into())),
                "{mutation}"
            );
        }
    }
}
