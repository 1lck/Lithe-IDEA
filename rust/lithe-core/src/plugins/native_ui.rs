//! Versioned native plugin presentation: bounded data, stable identities and named actions.
//!
//! Note: ownership is recorded in .agents/notes/implemented/feature/2026-10-21-declarative-native-plugin-ui.md

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// A host-rendered tree, list or form; styling is deliberately absent from the contract.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NativeUI {
    schema_version: u32,
    id: String,
    kind: Kind,
    nodes: Vec<Node>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    controls: Vec<Control>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    buttons: Vec<FormButton>,
    #[serde(skip_serializing_if = "Option::is_none")]
    layout: Option<GridLayout>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) source: Option<Source>,
    actions: Vec<Action>,
    toolbar: Vec<String>,
    context_menu: Vec<String>,
}

/// Tree permits nesting; list requires flat rows; form has controls and no rows.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum Kind {
    Tree,
    List,
    Form,
}

/// Stable row identity, literal label and optional children.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Node {
    id: String,
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    children: Option<Vec<Node>>,
}

/// A bounded scalar owned by the host; no arbitrary JSON or executable content.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum ControlValue {
    Text(String),
    Checked(bool),
    Number(f64),
}

/// The initial form controls reuse native IDE fields, selectors and checkboxes.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum ControlKind {
    Input,
    Search,
    Editor,
    Select,
    Segmented,
    Checkbox,
    Stepper,
}

/// Stable option value and a literal user-visible label.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SelectOption {
    id: String,
    label: String,
}

/// A bounded column grid. The host owns gaps, sizing and the narrow-panel fallback.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct GridLayout {
    columns: u8,
}

/// Form semantics only. onCommit names an existing non-selection invoke action.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Control {
    id: String,
    kind: ControlKind,
    label: String,
    value: ControlValue,
    #[serde(skip_serializing_if = "Option::is_none")]
    placeholder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    options: Option<Vec<SelectOption>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    on_commit: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    span: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    info: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rows: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    minimum: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    maximum: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    step: Option<f64>,
}

/// Button layout policy; all visual metrics stay with the host button owner.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum ButtonWidth {
    Content,
    Fill,
}

/// A form action placement, deliberately separate from value-bearing controls.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct FormButton {
    id: String,
    label: String,
    action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    width: Option<ButtonWidth>,
    #[serde(skip_serializing_if = "Option::is_none")]
    primary: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    span: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    info: Option<String>,
}

/// Existing plugin function that returns `{ nodes }` for a detected build instance.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Source {
    #[serde(rename = "buildSystemID")]
    pub(super) build_system_id: String,
    function: String,
}

/// An independent action referenced by toolbar and context-menu placements.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Action {
    id: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    icon: Option<super::declarative::UIIcon>,
    kind: ActionKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    function: Option<String>,
    requires_selection: bool,
}

/// Refresh reloads the source; invoke calls a declared plugin function.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum ActionKind {
    Refresh,
    Invoke,
}

fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn valid_info(value: Option<&str>) -> bool {
    value.is_none_or(|value| !value.trim().is_empty() && value.len() <= 1024)
}

impl NativeUI {
    pub(super) fn validate(&self) -> Result<(), &'static str> {
        if self.schema_version != 1 || !identifier(&self.id) || self.actions.len() > 64 {
            return Err("Native UI requires schemaVersion 1, a stable ID and at most 64 actions.");
        }
        if self
            .source
            .as_ref()
            .is_some_and(|source| !identifier(&source.function))
        {
            return Err("Invalid native UI source function.");
        }
        if self.controls.len() > 32
            || self.buttons.len() > 16
            || (self.kind == Kind::Form
                && ((self.controls.is_empty() && self.buttons.is_empty())
                    || !self.nodes.is_empty()
                    || !self.context_menu.is_empty()))
            || (self.kind != Kind::Form && (!self.controls.is_empty() || !self.buttons.is_empty()))
        {
            return Err(
                "A native form needs controls or buttons, at most 32 controls and 16 buttons, and no rows.",
            );
        }
        if self
            .layout
            .as_ref()
            .is_some_and(|layout| self.kind != Kind::Form || !(1..=12).contains(&layout.columns))
            || self
                .controls
                .iter()
                .map(|control| control.span)
                .chain(self.buttons.iter().map(|button| button.span))
                .any(|span| {
                    span.is_some_and(|span| {
                        self.layout
                            .as_ref()
                            .is_none_or(|layout| span == 0 || span > layout.columns)
                    })
                })
        {
            return Err("Native form grids need 1–12 columns; each span needs a grid and must fit its columns.");
        }
        let mut ids = BTreeSet::from([self.id.as_str()]);
        let mut pending: Vec<_> = self.nodes.iter().map(|node| (node, 0)).collect();
        let mut count = 0;
        while let Some((node, depth)) = pending.pop() {
            count += 1;
            if count > 2000
                || depth > 16
                || !identifier(&node.id)
                || !ids.insert(&node.id)
                || node.label.trim().is_empty()
                || node.label.len() > 1024
            {
                return Err(
                    "Native rows need unique IDs and labels; limit 2000 nodes and depth 16.",
                );
            }
            if let Some(children) = &node.children {
                if self.kind == Kind::List && !children.is_empty() {
                    return Err("A native list cannot contain nested rows.");
                }
                pending.extend(children.iter().map(|child| (child, depth + 1)));
            }
        }
        let mut actions = BTreeSet::new();
        for action in &self.actions {
            if !identifier(&action.id)
                || !ids.insert(&action.id)
                || !actions.insert(&action.id)
                || action.title.trim().is_empty()
                || action.title.len() > 256
                || action
                    .icon
                    .as_ref()
                    .is_some_and(|icon| !icon.is_valid_host_icon())
                || self.source.is_none()
                || match action.kind {
                    ActionKind::Refresh => action.function.is_some() || action.requires_selection,
                    ActionKind::Invoke => !action.function.as_deref().is_some_and(identifier),
                }
            {
                return Err(
                    "Native actions need unique IDs, a source and a valid refresh/invoke handler.",
                );
            }
        }
        for control in &self.controls {
            if !identifier(&control.id)
                || !ids.insert(&control.id)
                || control.label.trim().is_empty()
                || control.label.len() > 256
                || control
                    .placeholder
                    .as_ref()
                    .is_some_and(|value| value.len() > 256)
                || !valid_info(control.info.as_deref())
                || (control.kind != ControlKind::Editor && control.rows.is_some())
                || (control.kind == ControlKind::Editor && control.on_commit.is_some())
                || (control.kind != ControlKind::Stepper
                    && (control.minimum.is_some()
                        || control.maximum.is_some()
                        || control.step.is_some()))
                || control.on_commit.as_ref().is_some_and(|id| {
                    !self.actions.iter().any(|action| {
                        &action.id == id
                            && action.kind == ActionKind::Invoke
                            && !action.requires_selection
                    })
                })
            {
                return Err("Native controls need unique IDs, bounded labels and a declared non-selection invoke action.");
            }
            match (&control.kind, &control.value) {
                (ControlKind::Input | ControlKind::Search, ControlValue::Text(value))
                    if value.len() <= 1024 && control.options.is_none() => {}
                (ControlKind::Editor, ControlValue::Text(value))
                    if value.len() <= 8192
                        && control.options.is_none()
                        && control.placeholder.is_none()
                        && control.rows.is_none_or(|rows| (2..=12).contains(&rows)) => {}
                (ControlKind::Stepper, ControlValue::Number(value))
                    if control.options.is_none() && control.placeholder.is_none() =>
                {
                    let (Some(minimum), Some(maximum), Some(step)) =
                        (control.minimum, control.maximum, control.step)
                    else {
                        return Err("A native stepper requires minimum, maximum and step.");
                    };
                    if !minimum.is_finite()
                        || !maximum.is_finite()
                        || !step.is_finite()
                        || minimum.abs() > 1e9
                        || maximum.abs() > 1e9
                        || minimum > maximum
                        || step <= 0.0
                        || step > 1e9
                        || !value.is_finite()
                        || *value < minimum
                        || *value > maximum
                    {
                        return Err("Native stepper values must fit a finite bounded range and positive step.");
                    }
                }
                (ControlKind::Checkbox, ControlValue::Checked(_))
                    if control.options.is_none() && control.placeholder.is_none() => {}
                (ControlKind::Select | ControlKind::Segmented, ControlValue::Text(value))
                    if control.placeholder.is_none() =>
                {
                    let Some(options) = &control.options else {
                        return Err("A native selector needs options.");
                    };
                    let mut option_ids = BTreeSet::new();
                    if options.is_empty()
                        || options.len()
                            > if control.kind == ControlKind::Segmented {
                                8
                            } else {
                                128
                            }
                        || options.iter().any(|option| {
                            !identifier(&option.id)
                                || !option_ids.insert(&option.id)
                                || option.label.trim().is_empty()
                                || option.label.len() > 256
                        })
                        || !options.iter().any(|option| &option.id == value)
                    {
                        return Err("Native selectors need 1–128 unique options and an existing selected value.");
                    }
                }
                _ => return Err("Native control values and properties must match their kind."),
            }
        }
        for button in &self.buttons {
            if !identifier(&button.id)
                || !ids.insert(&button.id)
                || button.label.trim().is_empty()
                || button.label.len() > 256
                || !actions.contains(&button.action)
                || !valid_info(button.info.as_deref())
                || self
                    .actions
                    .iter()
                    .any(|action| action.id == button.action && action.requires_selection)
            {
                return Err("Native form buttons need unique IDs, bounded labels and a non-selection action.");
            }
        }
        for placement in [&self.toolbar, &self.context_menu] {
            let mut seen = BTreeSet::new();
            if placement.len() > 64
                || placement
                    .iter()
                    .any(|id| !actions.contains(id) || !seen.insert(id))
            {
                return Err("Native action placements must reference distinct declared actions.");
            }
        }
        Ok(())
    }
}

/// Validates a refreshed node set with the same identity and budget rules as
/// the initial declaration. Platform renderers never maintain a second validator.
pub(crate) fn validate_data_command(
    payload: serde_json::Value,
) -> Result<serde_json::Value, crate::protocol::CoreError> {
    use serde_json::{json, Value};
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Payload {
        ui: NativeUI,
        data: Value,
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Data {
        nodes: Vec<Node>,
    }
    let mut payload: Payload = serde_json::from_value(payload).map_err(|error| {
        crate::protocol::CoreError::new(
            crate::protocol::ErrorCode::InvalidRequest,
            error.to_string(),
        )
    })?;
    let validate = || -> Result<Value, String> {
        if serde_json::to_vec(&payload.data)
            .map_err(|error| error.to_string())?
            .len()
            > 1024 * 1024
        {
            return Err("Native data exceeds 1 MiB.".into());
        }
        let data: Data = serde_json::from_value(payload.data).map_err(|error| error.to_string())?;
        payload.ui.nodes = data.nodes;
        payload.ui.validate().map_err(String::from)?;
        Ok(json!({"status":"ok", "nodes": payload.ui.nodes}))
    };
    Ok(match validate() {
        Ok(nodes) => nodes,
        Err(message) => {
            json!({"status":"rejected", "error":{"code":"plugin.ui.invalidData", "message":message}})
        }
    })
}
