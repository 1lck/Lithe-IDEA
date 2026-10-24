//! Evaluating a generator's form: which fields are shown, the value each
//! holds (derived defaults included), and what is wrong with it.
//!
//! Hosts send what the user changed and draw what comes back, so derived
//! defaults ("package = group + artifact") and visibility rules behave the
//! same on every platform without host code per generator.

use super::manifest::{
    Conditions, GeneratorField, ProjectGeneratorDeclaration, FIELD_BOOLEAN, FIELD_ENUM,
    FIELD_MULTI_SELECT, FIELD_RUNTIME, FIELD_TEXT,
};
use super::template::{FieldValue, Values};
use crate::plugins::declarative::version_components;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

/// Longest project name, in characters.
const MAX_PROJECT_NAME: usize = 128;

/// A runtime installation the host discovered and the user selected.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RuntimeSelection {
    pub(crate) home: String,
    pub(crate) version: String,
}

/// What the user has entered so far.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct FormInput {
    pub(crate) project_name: String,
    /// Values by field ID. A text value counts only if its ID is in
    /// `edited`; otherwise the field keeps following its default.
    #[serde(default)]
    pub(crate) values: BTreeMap<String, Value>,
    #[serde(default)]
    pub(crate) edited: BTreeSet<String>,
    /// Selected installations of runtime fields.
    #[serde(default)]
    pub(crate) runtimes: BTreeMap<String, RuntimeSelection>,
}

/// Why a value is not accepted. Hosts localize by code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum FieldProblem {
    Required,
    TooLong,
    InvalidFormat,
    UnsupportedValue,
    RuntimeTooOld,
    /// The value names a newer version than `maximumVersion` allows.
    VersionTooHigh,
}

impl FieldProblem {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::TooLong => "tooLong",
            Self::InvalidFormat => "invalidFormat",
            Self::UnsupportedValue => "unsupportedValue",
            Self::RuntimeTooOld => "runtimeTooOld",
            Self::VersionTooHigh => "versionTooHigh",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FieldState {
    pub(crate) id: String,
    pub(crate) visible: bool,
    pub(crate) value: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) problem: Option<FieldProblem>,
}

/// The evaluated form.
#[derive(Debug, Clone)]
pub(crate) struct FormState {
    pub(crate) project_name_problem: Option<FieldProblem>,
    pub(crate) fields: Vec<FieldState>,
    /// Values of visible fields, as templates read them.
    pub(crate) values: BTreeMap<String, FieldValue>,
    /// Indices of requirements whose conditions hold.
    pub(crate) active_requirements: Vec<usize>,
}

impl FormState {
    pub(crate) fn is_valid(&self) -> bool {
        self.project_name_problem.is_none()
            && self.fields.iter().all(|field| field.problem.is_none())
    }

    pub(crate) fn to_json(&self) -> Value {
        json!({
            "projectName": {"problem": self.project_name_problem},
            "fields": self.fields,
            "activeRequirements": self.active_requirements,
            "valid": self.is_valid(),
        })
    }
}

pub(crate) fn evaluate(generator: &ProjectGeneratorDeclaration, input: &FormInput) -> FormState {
    let mut values: BTreeMap<String, FieldValue> = BTreeMap::new();
    let mut fields = Vec::with_capacity(generator.fields.len());
    for field in &generator.fields {
        let visible = holds(field.visible_when.as_ref(), &values);
        let (value, template_value, problem) = resolve(field, input, &values);
        let problem = problem.or_else(|| version_too_high(field, input, &values, &template_value));
        if visible {
            values.insert(field.id.clone(), template_value);
        }
        fields.push(FieldState {
            id: field.id.clone(),
            visible,
            value,
            problem: problem.filter(|_| visible),
        });
    }
    let active_requirements = generator
        .requirements
        .iter()
        .enumerate()
        .filter(|(_, requirement)| holds(requirement.when.as_ref(), &values))
        .map(|(index, _)| index)
        .collect();
    FormState {
        project_name_problem: project_name_problem(&input.project_name),
        fields,
        values,
        active_requirements,
    }
}

/// Whether every condition holds. A condition on a hidden field is false,
/// so nothing depends on a value the user cannot see.
pub(crate) fn holds(
    conditions: Option<&Conditions>,
    values: &BTreeMap<String, FieldValue>,
) -> bool {
    let Some(conditions) = conditions else {
        return true;
    };
    conditions.as_slice().iter().all(|condition| {
        let Some(value) = values.get(&condition.field) else {
            return false;
        };
        let matches = |expected: &Value| match (value, expected) {
            (FieldValue::Flag(flag), Value::Bool(expected)) => flag == expected,
            (_, Value::String(expected)) => value.text() == *expected,
            _ => false,
        };
        match (&condition.equals, &condition.not_equals, &condition.one_of) {
            (Some(expected), _, _) => matches(expected),
            (_, Some(expected), _) => !matches(expected),
            (_, _, Some(options)) => options.iter().any(matches),
            _ => false,
        }
    })
}

fn resolve(
    field: &GeneratorField,
    input: &FormInput,
    earlier: &BTreeMap<String, FieldValue>,
) -> (Value, FieldValue, Option<FieldProblem>) {
    let given = input.values.get(&field.id);
    match field.kind.as_str() {
        FIELD_TEXT => {
            let text = match given {
                Some(Value::String(text)) if input.edited.contains(&field.id) => text.clone(),
                _ => field
                    .default_template()
                    .map(|parts| {
                        Values {
                            project_name: &input.project_name,
                            fields: earlier,
                        }
                        .expand(&parts)
                    })
                    .unwrap_or_default(),
            };
            let problem = text_problem(field, &text);
            (json!(text), FieldValue::Text(text), problem)
        }
        FIELD_ENUM => {
            let fallback = field
                .default
                .as_ref()
                .and_then(Value::as_str)
                .or_else(|| field.options.first().map(|option| option.value.as_str()))
                .unwrap_or_default()
                .to_string();
            let (choice, problem) = match given {
                None => (fallback, None),
                Some(Value::String(choice)) if field.offers(choice) => (choice.clone(), None),
                Some(_) => (fallback, Some(FieldProblem::UnsupportedValue)),
            };
            (json!(choice), FieldValue::Text(choice), problem)
        }
        FIELD_BOOLEAN => {
            let flag = match given {
                Some(Value::Bool(flag)) => *flag,
                _ => field
                    .default
                    .as_ref()
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            };
            (json!(flag), FieldValue::Flag(flag), None)
        }
        FIELD_MULTI_SELECT => {
            let (items, problem) = match given {
                None => (
                    field
                        .default
                        .as_ref()
                        .and_then(Value::as_array)
                        .map(|items| {
                            items
                                .iter()
                                .filter_map(|item| item.as_str().map(str::to_string))
                                .collect()
                        })
                        .unwrap_or_default(),
                    None,
                ),
                Some(Value::Array(items)) => {
                    let chosen: Vec<String> = items
                        .iter()
                        .filter_map(|item| item.as_str())
                        .filter(|value| field.offers(value))
                        .map(str::to_string)
                        .collect();
                    let problem =
                        (chosen.len() != items.len()).then_some(FieldProblem::UnsupportedValue);
                    // Keep declaration order, so plans do not depend on
                    // the order the user clicked.
                    let ordered = field
                        .options
                        .iter()
                        .filter(|option| chosen.contains(&option.value))
                        .map(|option| option.value.clone())
                        .collect();
                    (ordered, problem)
                }
                Some(_) => (Vec::new(), Some(FieldProblem::UnsupportedValue)),
            };
            (json!(items), FieldValue::List(items), problem)
        }
        FIELD_RUNTIME => match input.runtimes.get(&field.id) {
            Some(selection) if !selection.home.trim().is_empty() => {
                let too_old = field.minimum_version.as_deref().is_some_and(|minimum| {
                    version_components(&selection.version) < version_components(minimum)
                });
                (
                    json!(selection.home),
                    FieldValue::Runtime {
                        home: selection.home.clone(),
                        version: selection.version.clone(),
                    },
                    too_old.then_some(FieldProblem::RuntimeTooOld),
                )
            }
            _ => (
                json!(""),
                FieldValue::Runtime {
                    home: String::new(),
                    version: String::new(),
                },
                (!field.optional).then_some(FieldProblem::Required),
            ),
        },
        _ => (Value::Null, FieldValue::Text(String::new()), None),
    }
}

/// Compares a value with the field's `maximumVersion`, expanded over the
/// earlier fields. An empty value or bound (no JDK chosen yet) is left to the
/// fields' own checks.
fn version_too_high(
    field: &GeneratorField,
    input: &FormInput,
    earlier: &BTreeMap<String, FieldValue>,
    value: &FieldValue,
) -> Option<FieldProblem> {
    let parts = field.maximum_version_template()?;
    let bound = Values {
        project_name: &input.project_name,
        fields: earlier,
    }
    .expand(&parts);
    let value = value.text();
    if bound.is_empty() || value.is_empty() {
        return None;
    }
    (version_components(&value) > version_components(&bound))
        .then_some(FieldProblem::VersionTooHigh)
}

fn text_problem(field: &GeneratorField, text: &str) -> Option<FieldProblem> {
    if text.is_empty() {
        return (!field.optional).then_some(FieldProblem::Required);
    }
    if text.chars().count() > field.max_text_length() as usize {
        return Some(FieldProblem::TooLong);
    }
    // Free text never starts like an option and never carries control
    // characters, so it cannot become a flag or split a line in argv.
    let safe = !text.starts_with('-') && !text.chars().any(char::is_control);
    let matches = field
        .text_pattern()
        .is_none_or(|pattern| pattern.is_match(text));
    (!safe || !matches).then_some(FieldProblem::InvalidFormat)
}

/// Checks a name that becomes a directory name and appears in argv.
pub(crate) fn project_name_problem(name: &str) -> Option<FieldProblem> {
    if name.is_empty() {
        return Some(FieldProblem::Required);
    }
    if name.chars().count() > MAX_PROJECT_NAME {
        return Some(FieldProblem::TooLong);
    }
    let invalid = name == "."
        || name == ".."
        || name.starts_with('-')
        || name.trim() != name
        || name
            .chars()
            .any(|character| character.is_control() || matches!(character, '/' | '\\' | ':'));
    invalid.then_some(FieldProblem::InvalidFormat)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn generator(fields: Value) -> ProjectGeneratorDeclaration {
        serde_json::from_value(json!({
            "id": "demo",
            "displayName": "Demo",
            "section": "generator",
            "fields": fields,
            "steps": [{"kind": "files", "source": "templates"}],
        }))
        .unwrap()
    }

    fn input(project_name: &str, values: Value, edited: &[&str]) -> FormInput {
        FormInput {
            project_name: project_name.into(),
            values: serde_json::from_value(values).unwrap(),
            edited: edited.iter().map(|id| id.to_string()).collect(),
            runtimes: BTreeMap::new(),
        }
    }

    fn field<'a>(state: &'a FormState, id: &str) -> &'a FieldState {
        state.fields.iter().find(|field| field.id == id).unwrap()
    }

    #[test]
    fn derived_defaults_follow_until_edited() {
        let generator = generator(json!([
            {"id": "groupId", "type": "text", "title": "Group", "default": "com.example"},
            {"id": "artifactId", "type": "text", "title": "Artifact", "default": "${project.name}"},
            {"id": "packageName", "type": "text", "title": "Package",
             "default": "${field.groupId}.${field.artifactId|package}"}
        ]));
        let state = evaluate(&generator, &input("My-App", json!({}), &[]));
        assert_eq!(field(&state, "artifactId").value, json!("My-App"));
        assert_eq!(
            field(&state, "packageName").value,
            json!("com.example.myapp")
        );

        let state = evaluate(
            &generator,
            &input(
                "My-App",
                json!({"packageName": "org.custom", "artifactId": "ignored"}),
                &["packageName"],
            ),
        );
        assert_eq!(field(&state, "artifactId").value, json!("My-App"));
        assert_eq!(field(&state, "packageName").value, json!("org.custom"));
    }

    #[test]
    fn hidden_fields_are_not_validated_or_read() {
        let generator = generator(json!([
            {"id": "buildSystem", "type": "enum", "title": "Build", "options": [
                {"value": "none", "title": "None"}, {"value": "maven", "title": "Maven"}]},
            {"id": "groupId", "type": "text", "title": "Group",
             "visibleWhen": {"field": "buildSystem", "equals": "maven"}}
        ]));
        let state = evaluate(&generator, &input("demo", json!({}), &[]));
        assert!(!field(&state, "groupId").visible);
        assert!(state.is_valid());
        assert!(!state.values.contains_key("groupId"));

        let state = evaluate(
            &generator,
            &input("demo", json!({"buildSystem": "maven"}), &[]),
        );
        assert_eq!(
            field(&state, "groupId").problem,
            Some(FieldProblem::Required)
        );
    }

    #[test]
    fn rejects_unsafe_text_and_old_runtimes() {
        let generator = generator(json!([
            {"id": "groupId", "type": "text", "title": "Group", "pattern": "[a-z.]+"},
            {"id": "jdk", "type": "runtime", "title": "JDK", "runtime": "java", "minimumVersion": "17"}
        ]));
        let mut form = input("demo", json!({"groupId": "-Dx=y"}), &["groupId"]);
        form.runtimes.insert(
            "jdk".into(),
            RuntimeSelection {
                home: "/jdk".into(),
                version: "11.0.2".into(),
            },
        );
        let state = evaluate(&generator, &form);
        assert_eq!(
            field(&state, "groupId").problem,
            Some(FieldProblem::InvalidFormat)
        );
        assert_eq!(
            field(&state, "jdk").problem,
            Some(FieldProblem::RuntimeTooOld)
        );
    }

    /// A target release newer than the selected JDK cannot compile, so the
    /// bound follows the JDK; before a JDK is chosen nothing is compared.
    #[test]
    fn maximum_version_follows_an_earlier_runtime() {
        let generator = generator(json!([
            {"id": "jdk", "type": "runtime", "title": "JDK", "runtime": "java", "minimumVersion": "17"},
            {"id": "javaVersion", "type": "enum", "title": "Java", "maximumVersion": "${field.jdk.major}",
             "options": [{"value": "17", "title": "17"}, {"value": "21", "title": "21"}]}
        ]));
        let mut form = input("demo", json!({"javaVersion": "21"}), &[]);
        assert_eq!(
            field(&evaluate(&generator, &form), "javaVersion").problem,
            None
        );
        for (version, problem) in [
            ("17.0.12", Some(FieldProblem::VersionTooHigh)),
            ("21.0.4", None),
            ("25", None),
        ] {
            form.runtimes.insert(
                "jdk".into(),
                RuntimeSelection {
                    home: "/jdk".into(),
                    version: version.into(),
                },
            );
            assert_eq!(
                field(&evaluate(&generator, &form), "javaVersion").problem,
                problem,
                "{version}"
            );
        }
    }

    #[test]
    fn project_names_are_single_directory_names() {
        assert_eq!(project_name_problem("demo"), None);
        assert_eq!(project_name_problem(""), Some(FieldProblem::Required));
        for name in ["a/b", "..", "-x", " demo", "a:b"] {
            assert_eq!(
                project_name_problem(name),
                Some(FieldProblem::InvalidFormat),
                "{name}"
            );
        }
    }
}
