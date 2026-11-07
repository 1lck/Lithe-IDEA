//! Applying the session settings a user chose while a turn was running.
//!
//! Choices made during a turn stay local to the product until the turn ends.
//! The product then hands every remaining choice to the Host in one
//! `applyNextTurnConfiguration` command. The Host applies them one ACP
//! request at a time: model choices first, because a model change can replace
//! the other options, then the rest in catalog order. Each remaining choice is
//! revalidated against the latest catalog the Agent returned, and each request
//! must be confirmed by the Agent's reported value. The first problem stops the
//! sequence with one stable failure code.
//! Contract: `shared/fixtures/agent/next-turn-configuration-v1.json`.

use agent_client_protocol::schema::v1::{
    SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory, SessionConfigSelectOptions,
};
use serde::{Deserialize, Serialize};

/// One selectable session setting as both products parse it from ACP.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogOption {
    pub id: String,
    /// ACP category, e.g. `model`; absent for uncategorized options.
    #[serde(default)]
    pub category: Option<String>,
    pub current_value: String,
    /// Selectable value identifiers, flattened across groups.
    pub choices: Vec<String>,
}

/// A value the user chose for the next turn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigChoice {
    pub config_id: String,
    pub value: String,
}

/// Why the remaining choices were abandoned. Products localize the code; a
/// request failure additionally carries the Agent's own message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConfigFailure {
    /// The latest catalog no longer offers the option or the chosen value.
    Unsupported,
    /// The Agent answered but reported a different current value.
    NotConfirmed,
    /// The ACP request failed; the event's `message` is upstream diagnostics.
    RequestFailed,
}

/// Next action of the sequence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// Send one `session/set_config_option` request.
    Send(ConfigChoice),
    /// Every choice is applied or already current.
    Done,
    /// Stop without sending the remaining choices.
    Failed(ConfigFailure),
}

/// Deterministic state of one next-turn application.
#[derive(Debug, Clone)]
pub struct NextTurnPlan {
    catalog: Vec<CatalogOption>,
    remaining: Vec<ConfigChoice>,
    awaiting: Option<ConfigChoice>,
}

impl NextTurnPlan {
    /// `catalog` is the product's latest confirmed catalog. A later choice for
    /// the same option replaces an earlier one.
    pub fn new(catalog: Vec<CatalogOption>, choices: Vec<ConfigChoice>) -> Self {
        let mut remaining: Vec<ConfigChoice> = Vec::new();
        for choice in choices {
            remaining.retain(|existing| existing.config_id != choice.config_id);
            remaining.push(choice);
        }
        Self {
            catalog,
            remaining,
            awaiting: None,
        }
    }

    /// Chooses the next request against the latest catalog.
    pub fn next(&mut self) -> Step {
        debug_assert!(self.awaiting.is_none(), "confirm the sent choice first");
        let is_model = |option: &CatalogOption| option.category.as_deref() == Some("model");
        let ordered = self
            .catalog
            .iter()
            .filter(|option| is_model(option))
            .chain(self.catalog.iter().filter(|option| !is_model(option)));
        for option in ordered {
            let Some(index) = self
                .remaining
                .iter()
                .position(|choice| choice.config_id == option.id)
            else {
                continue;
            };
            if option.current_value == self.remaining[index].value {
                // A model change may already have produced the chosen value.
                self.remaining.remove(index);
                continue;
            }
            if !option.choices.contains(&self.remaining[index].value) {
                return Step::Failed(ConfigFailure::Unsupported);
            }
            let choice = self.remaining.remove(index);
            self.awaiting = Some(choice.clone());
            return Step::Send(choice);
        }
        if self.remaining.is_empty() {
            Step::Done
        } else {
            // The catalog no longer contains a chosen option at all.
            Step::Failed(ConfigFailure::Unsupported)
        }
    }

    /// Records the Agent's answer to the sent choice.
    pub fn confirm(&mut self, catalog: Vec<CatalogOption>) -> Result<(), ConfigFailure> {
        let sent = self.awaiting.take();
        self.catalog = catalog;
        let confirmed = sent.is_some_and(|sent| {
            self.catalog
                .iter()
                .any(|option| option.id == sent.config_id && option.current_value == sent.value)
        });
        if confirmed {
            Ok(())
        } else {
            Err(ConfigFailure::NotConfirmed)
        }
    }
}

/// Parses an Agent catalog the way both products do: select options only,
/// with grouped values flattened.
pub fn catalog(options: &[SessionConfigOption]) -> Vec<CatalogOption> {
    options
        .iter()
        .filter_map(|option| {
            let SessionConfigKind::Select(select) = &option.kind else {
                return None;
            };
            let choices = match &select.options {
                SessionConfigSelectOptions::Ungrouped(values) => {
                    values.iter().map(|value| value.value.0.to_string()).collect()
                }
                SessionConfigSelectOptions::Grouped(groups) => groups
                    .iter()
                    .flat_map(|group| group.options.iter())
                    .map(|value| value.value.0.to_string())
                    .collect(),
                _ => Vec::new(),
            };
            Some(CatalogOption {
                id: option.id.0.to_string(),
                category: option.category.as_ref().map(category_name),
                current_value: select.current_value.0.to_string(),
                choices,
            })
        })
        .collect()
}

fn category_name(category: &SessionConfigOptionCategory) -> String {
    serde_json::to_value(category)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Drives every fixture case against scripted Agent answers and checks
    /// the requests, their order, and the final outcome.
    #[test]
    fn fixture_cases_apply_in_the_shared_order() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/agent/next-turn-configuration-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let options: Vec<SessionConfigOption> =
                serde_json::from_value(case["catalog"].clone()).unwrap();
            let choices: Vec<ConfigChoice> =
                serde_json::from_value(case["choices"].clone()).unwrap();
            let mut answers = case["answers"].as_array().unwrap().iter();
            let mut plan = NextTurnPlan::new(catalog(&options), choices);
            let mut sent = Vec::new();
            let failure = loop {
                match plan.next() {
                    Step::Done => break None,
                    Step::Failed(failure) => break Some(failure),
                    Step::Send(choice) => {
                        sent.push(serde_json::to_value(&choice).unwrap());
                        let answer = answers.next().expect("scripted answer");
                        if answer.get("error").is_some() {
                            break Some(ConfigFailure::RequestFailed);
                        }
                        let options: Vec<SessionConfigOption> =
                            serde_json::from_value(answer["configOptions"].clone()).unwrap();
                        if let Err(failure) = plan.confirm(catalog(&options)) {
                            break Some(failure);
                        }
                    }
                }
            };
            assert_eq!(Value::Array(sent), case["expected"]["requests"], "{name} requests");
            assert_eq!(
                failure.map(|failure| serde_json::to_value(failure).unwrap()),
                case["expected"]["failure"].as_str().map(Value::from),
                "{name} failure"
            );
            assert!(answers.next().is_none(), "{name} left answers unused");
        }
    }
}
