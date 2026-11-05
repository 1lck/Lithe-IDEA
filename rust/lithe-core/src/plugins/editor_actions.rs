//! Independent editor actions for tool plugins, not language/build/run providers.
//!
//! Core validates presentation and opaque function bindings. Plugin parsers own
//! their business facts; hosts own document versions, session leases, icon
//! resources and clicks. Version 1 keeps the original two icons and 128 KiB
//! source bound; version 2 takes the icons and bound the host declared in
//! [`EditorHostOptions`](crate::plugins::editor_actions::EditorHostOptions) and adds
//! alternatives and reveal results.

use crate::lsp::interface::plugin_function::is_function_id;
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

const MAX_ACTIONS: usize = 1000;
const MAX_BYTES: usize = 1024 * 1024;
/// Largest document a host may collect actions for, in UTF-8 bytes.
pub const MAX_SOURCE_BYTES: usize = 1024 * 1024;
const LEGACY_SOURCE_BYTES: usize = 128 * 1024;
const LEGACY_ICONS: [&str; 2] = ["run", "run-all"];
const MAX_ICONS: usize = 32;
const MAX_ALTERNATIVES: usize = 4;
const MAX_REVEAL_LOCATIONS: usize = 100;
const MAX_URI_BYTES: usize = 4096;
const REGISTER_ACTIONS: &str = "lithe/host/editor/registerActions";
pub(crate) const REGISTER_PROVIDERS: &str = "lithe/host/editor/registerProviders";

/// Editor presentation a host declares at `lsp.startServer.hostOptions.editor`.
/// Core reports it to sessions granted the matching editor methods through
/// `lithe/host/getCapabilities`, so a plugin learns which icons the host
/// draws and which provider types it routes before registering anything.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditorHostOptions {
    /// Icon names the host has resources for; every action and alternative
    /// uses one of them.
    pub action_icons: Vec<String>,
    /// Largest document, in UTF-8 bytes, the host collects actions for.
    pub action_source_bytes: usize,
    /// Provider types `lithe/host/editor/registerProviders` accepts on this
    /// host; a subset of [`super::editor_providers::PROVIDER_TYPES`].
    #[serde(default)]
    pub provider_types: Vec<String>,
}

impl EditorHostOptions {
    /// Rejects an empty or oversized icon list, an icon name that is not a
    /// lowercase token, a source bound above [`MAX_SOURCE_BYTES`], and
    /// provider types Core cannot validate.
    pub fn validate(&self) -> Result<(), CoreError> {
        let icons: BTreeSet<&String> = self.action_icons.iter().collect();
        if self.action_icons.is_empty()
            || self.action_icons.len() > MAX_ICONS
            || icons.len() != self.action_icons.len()
            || !self.action_icons.iter().all(|icon| icon_name(icon))
            || self.action_source_bytes == 0
            || self.action_source_bytes > MAX_SOURCE_BYTES
        {
            return Err(invalid("Invalid editor host options."));
        }
        let types: BTreeSet<&String> = self.provider_types.iter().collect();
        if types.len() != self.provider_types.len()
            || !self
                .provider_types
                .iter()
                .all(|kind| super::editor_providers::PROVIDER_TYPES.contains(&kind.as_str()))
        {
            return Err(invalid("Unknown editor provider type in host options."));
        }
        Ok(())
    }

    /// Adds `services.editor.options` and `limits.editorActionSourceBytes`
    /// to a `getCapabilities` answer, each only when the session is granted
    /// the editor method it describes.
    pub(crate) fn report(&self, answer: &mut Value, granted: &BTreeSet<String>) {
        let actions = granted.contains(REGISTER_ACTIONS);
        let providers = granted.contains(REGISTER_PROVIDERS) && !self.provider_types.is_empty();
        if !actions && !providers {
            return;
        }
        let mut options = serde_json::Map::new();
        if actions {
            options.insert("actionIcons".into(), json!(self.action_icons));
            if let Some(limits) = answer.get_mut("limits").and_then(Value::as_object_mut) {
                limits.insert(
                    "editorActionSourceBytes".into(),
                    json!(self.action_source_bytes),
                );
            }
        }
        if providers {
            options.insert("providerTypes".into(), json!(self.provider_types));
        }
        if let Some(editor) = answer
            .get_mut("services")
            .and_then(|services| services.get_mut("editor"))
            .and_then(Value::as_object_mut)
        {
            editor.insert("options".into(), Value::Object(options));
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Registration {
    id: String,
    function: String,
    selector: Selector,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Selector {
    #[serde(default)]
    file_extensions: Vec<String>,
    #[serde(default)]
    file_names: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(deny_unknown_fields)]
struct Position {
    line: usize,
    column: usize,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Range {
    start: Position,
    end: Position,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Invocation {
    #[serde(rename = "functionID")]
    function_id: String,
    /// Plugin-private data: Core never interprets tool names or selectors.
    #[serde(default = "empty_params")]
    params: Value,
}

fn empty_params() -> Value {
    json!({})
}

/// Another invocation offered on the same marker, shown in a menu.
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Alternative {
    id: String,
    title: String,
    icon: String,
    invoke: Invocation,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Action {
    id: String,
    range: Range,
    title: String,
    /// Presentation only; never identifies a Run/Test/Debug domain operation.
    icon: String,
    invoke: Invocation,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    alternatives: Vec<Alternative>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResultList {
    actions: Vec<Action>,
}

/// Zero-based LSP position: `character` counts UTF-16 code units.
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(deny_unknown_fields)]
pub(crate) struct LspPosition {
    pub(crate) line: u32,
    pub(crate) character: u32,
}

/// Zero-based LSP range with `start <= end`.
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct LspRange {
    pub(crate) start: LspPosition,
    pub(crate) end: LspPosition,
}

impl LspRange {
    pub(crate) fn ordered(&self) -> bool {
        self.start <= self.end
    }
}

/// An LSP `Location`.
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Location {
    pub(crate) uri: String,
    pub(crate) range: LspRange,
}

impl Location {
    pub(crate) fn valid(&self) -> bool {
        uri(&self.uri) && self.range.ordered()
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Reveal {
    locations: Vec<Location>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Payload {
    kind: String,
    value: Value,
    #[serde(default)]
    text: String,
    /// 1 when absent: the original icons and source bound.
    #[serde(default = "legacy_version")]
    version: u64,
    /// Version 2: the icons of the host's [`EditorHostOptions`].
    #[serde(default)]
    icons: Vec<String>,
    /// Version 2: the host's `actionSourceBytes`.
    #[serde(default)]
    source_bytes: Option<usize>,
}

fn legacy_version() -> u64 {
    1
}

/// What one decode version admits.
struct Rules {
    icons: Vec<String>,
    source_bytes: usize,
    alternatives: bool,
}

impl Rules {
    fn of(payload: &Payload) -> Result<Self, CoreError> {
        match payload.version {
            1 if payload.icons.is_empty() && payload.source_bytes.is_none() => Ok(Self {
                icons: LEGACY_ICONS.iter().map(ToString::to_string).collect(),
                source_bytes: LEGACY_SOURCE_BYTES,
                alternatives: false,
            }),
            2 => {
                let options = EditorHostOptions {
                    action_icons: payload.icons.clone(),
                    action_source_bytes: payload.source_bytes.unwrap_or(0),
                    provider_types: Vec::new(),
                };
                options.validate()?;
                Ok(Self {
                    icons: options.action_icons,
                    source_bytes: options.action_source_bytes,
                    alternatives: true,
                })
            }
            _ => Err(invalid("Unsupported editor action validation version.")),
        }
    }

    fn icon(&self, icon: &str) -> bool {
        self.icons.iter().any(|known| known == icon)
    }
}

fn invalid(message: impl Into<String>) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
}

fn icon_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn title(value: &str) -> bool {
    !value.trim().is_empty() && value.chars().count() <= 200 && !value.chars().any(char::is_control)
}

/// An absolute URI: a scheme, a colon, and no control characters.
pub(crate) fn uri(value: &str) -> bool {
    let Some((scheme, rest)) = value.split_once(':') else {
        return false;
    };
    value.len() <= MAX_URI_BYTES
        && !rest.is_empty()
        && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        && !value.chars().any(char::is_control)
}

fn invocation(item: &Invocation) -> bool {
    is_function_id(&item.function_id) && item.params.is_object()
}

fn registration(value: Value) -> Result<Value, CoreError> {
    let mut item: Registration = serde_json::from_value(value)
        .map_err(|_| invalid("An editor action registration needs id, function and selector."))?;
    if !identifier(&item.id) || !is_function_id(&item.function) {
        return Err(invalid(
            "Invalid editor action registration or function ID.",
        ));
    }
    if item.selector.file_extensions.len() + item.selector.file_names.len() > 32
        || item.selector.file_extensions.is_empty() && item.selector.file_names.is_empty()
    {
        return Err(invalid(
            "An editor selector has 1 to 32 file names/extensions.",
        ));
    }
    normalize_names(
        &mut item.selector.file_extensions,
        &mut item.selector.file_names,
    )?;
    serde_json::to_value(item).map_err(|_| invalid("Cannot encode editor registration."))
}

/// Lowercases, sorts and deduplicates literal file extensions and names;
/// rejects paths and patterns.
pub(crate) fn normalize_names(
    extensions: &mut Vec<String>,
    names: &mut Vec<String>,
) -> Result<(), CoreError> {
    for extension in extensions.iter_mut() {
        *extension = extension.trim_start_matches('.').to_lowercase();
    }
    for name in names.iter_mut() {
        *name = name.to_lowercase();
    }
    for name in extensions.iter().chain(names.iter()) {
        if !identifier(name) || name.contains(['/', '\\', '*', '?', ':']) {
            return Err(invalid(
                "An editor selector contains literal file names/extensions only.",
            ));
        }
    }
    extensions.sort();
    extensions.dedup();
    names.sort();
    names.dedup();
    Ok(())
}

fn actions(value: Value, text: &str, rules: &Rules) -> Result<Value, CoreError> {
    let mut result: ResultList = serde_json::from_value(value)
        .map_err(|_| invalid("An editor action result is { actions: [...] }."))?;
    if result.actions.len() > MAX_ACTIONS || text.len() > rules.source_bytes {
        return Err(invalid(
            "The editor action result or document exceeds its limit.",
        ));
    }
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    let valid_position = |position: &Position| {
        lines
            .get(position.line.wrapping_sub(1))
            .is_some_and(|line| {
                let line = line.strip_suffix('\r').unwrap_or(line);
                if position.column == 0 {
                    return false;
                }
                let target = position.column - 1;
                let mut offset = 0;
                for character in line.chars() {
                    if offset == target {
                        return true;
                    }
                    offset += character.len_utf16();
                }
                offset == target
            })
    };
    let mut ids = BTreeSet::new();
    for item in &result.actions {
        let mut alternative_ids = BTreeSet::new();
        if !identifier(&item.id)
            || !ids.insert(&item.id)
            || !title(&item.title)
            || !rules.icon(&item.icon)
            || !invocation(&item.invoke)
            || item.range.start > item.range.end
            || !valid_position(&item.range.start)
            || !valid_position(&item.range.end)
            || (!rules.alternatives && !item.alternatives.is_empty())
            || item.alternatives.len() > MAX_ALTERNATIVES
            || !item.alternatives.iter().all(|alternative| {
                identifier(&alternative.id)
                    && alternative_ids.insert(&alternative.id)
                    && title(&alternative.title)
                    && rules.icon(&alternative.icon)
                    && invocation(&alternative.invoke)
            })
        {
            return Err(invalid(
                "Invalid editor action identity, range, presentation or invocation.",
            ));
        }
    }
    result
        .actions
        .sort_by(|a, b| a.range.start.cmp(&b.range.start).then(a.id.cmp(&b.id)));
    serde_json::to_value(result.actions).map_err(|_| invalid("Cannot encode editor actions."))
}

/// Reads the `reveal` member of an action's function result. Other members
/// stay the plugin's own: a version 1 result had no meaning to the host.
fn invoke_result(value: Value) -> Result<Value, CoreError> {
    let Some(reveal) = value.get("reveal").cloned() else {
        return Ok(json!({}));
    };
    let reveal: Reveal = serde_json::from_value(reveal)
        .map_err(|_| invalid("An action reveal is { locations: [{ uri, range }] }."))?;
    if reveal.locations.is_empty()
        || reveal.locations.len() > MAX_REVEAL_LOCATIONS
        || !reveal.locations.iter().all(Location::valid)
    {
        return Err(invalid(
            "An action reveal has 1 to 100 locations with absolute URIs.",
        ));
    }
    Ok(json!({"reveal": {"locations": reveal.locations}}))
}

/// Validates an independent registration (`kind: registration`), a parser
/// result (`kind: actions`, with its exact text) or, from version 2, the
/// result of a clicked action (`kind: invokeResult`). No I/O or tool parsing
/// occurs.
pub fn decode_command(payload: Value) -> Result<Value, CoreError> {
    let payload: Payload = serde_json::from_value(payload)
        .map_err(|_| invalid("Invalid editor action validation payload."))?;
    if payload.value.to_string().len() > MAX_BYTES {
        return Err(invalid("Editor action data exceeds 1 MiB."));
    }
    let rules = Rules::of(&payload)?;
    match payload.kind.as_str() {
        "registration" => Ok(json!({"registration": registration(payload.value)?})),
        "actions" => Ok(json!({"actions": actions(payload.value, &payload.text, &rules)?})),
        "invokeResult" if rules.alternatives => invoke_result(payload.value),
        _ => Err(invalid("Unknown editor action validation kind.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST_ICONS: [&str; 4] = ["run", "debug", "test", "navigate-super"];

    fn v2(kind: &str, text: &str, value: Value) -> Result<Value, CoreError> {
        decode_command(json!({"kind": kind, "version": 2, "icons": HOST_ICONS,
            "sourceBytes": MAX_SOURCE_BYTES, "text": text, "value": value}))
    }

    #[test]
    fn different_tools_share_registration_and_opaque_invocations() {
        for (extension, function) in [("http", "requests.send"), ("sql", "queries.execute")] {
            let registration = decode_command(json!({"kind":"registration", "value":{
                "id":"actions", "function":"actions.collect", "selector":{"fileExtensions":[extension]}
            }})).unwrap();
            assert_eq!(
                registration["registration"]["selector"]["fileExtensions"][0],
                extension
            );
            let result = decode_command(json!({"kind":"actions", "text":"hello\nworld", "value":{"actions":[{
                "id":"a", "range":{"start":{"line":1,"column":1},"end":{"line":2,"column":6}},
                "title":"Execute", "icon":"run", "invoke":{"functionID":function,"params":{"opaque":[1,2]}}
            }]}})).unwrap();
            assert_eq!(
                result["actions"][0]["invoke"]["params"]["opaque"],
                json!([1, 2])
            );
        }
    }

    #[test]
    fn invalid_ranges_and_duplicate_ids_reject_the_whole_result() {
        let item = json!({"id":"a","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":3}},
            "title":"Execute","icon":"run","invoke":{"functionID":"action.execute","params":{}}});
        for (text, items) in [
            ("x", json!([item.clone()])),
            ("abc", json!([item.clone(), item])),
        ] {
            assert!(decode_command(
                json!({"kind":"actions","text":text,"value":{"actions":items}})
            )
            .is_err());
        }
        // Column 2 splits an astral character's UTF-16 surrogate pair.
        assert!(
            decode_command(json!({"kind":"actions","text":"😀","value":{"actions":[{
                "id":"a","range":{"start":{"line":1,"column":2},"end":{"line":1,"column":3}},
                "title":"Execute","icon":"run","invoke":{"functionID":"action.execute"}
            }]}}))
            .is_err()
        );
    }

    #[test]
    fn version_one_keeps_the_original_icons_and_bound() {
        let item = |icon: &str| {
            json!({"actions":[{"id":"a","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":1}},
                "title":"Run","icon":icon,"invoke":{"functionID":"markers.run"}}]})
        };
        assert!(
            decode_command(json!({"kind":"actions","text":"x","value":item("debug")})).is_err()
        );
        let large = "x".repeat(LEGACY_SOURCE_BYTES + 1);
        assert!(
            decode_command(json!({"kind":"actions","text":large,"value":item("run")})).is_err()
        );
        assert!(v2("actions", &large, item("debug")).is_ok());
        assert!(decode_command(json!({"kind":"invokeResult","value":{}})).is_err());
        // A version 1 payload cannot smuggle host icons.
        assert!(decode_command(
            json!({"kind":"actions","icons":["debug"],"text":"x","value":item("debug")})
        )
        .is_err());
    }

    #[test]
    fn host_icons_bound_actions_and_their_alternatives() {
        // A Go source gets a `func main` marker with debug and test
        // alternatives; the plugin owns what each params object means.
        let text = "package main\n\nfunc main() {}\n";
        let marker = |alternatives: Value| {
            json!({"actions":[{"id":"main","range":{"start":{"line":3,"column":1},"end":{"line":3,"column":10}},
                "title":"Run main","icon":"run","invoke":{"functionID":"go.markers.invoke","params":{"entry":"main"}},
                "alternatives":alternatives}]})
        };
        let accepted = v2("actions", text, marker(json!([
            {"id":"debug","title":"Debug main","icon":"debug","invoke":{"functionID":"go.markers.invoke","params":{"debug":true}}},
            {"id":"test","title":"Test package","icon":"test","invoke":{"functionID":"go.markers.invoke"}}
        ]))).unwrap();
        assert_eq!(
            accepted["actions"][0]["alternatives"][1]["invoke"]["params"],
            json!({})
        );
        let alternative = |id: &str, icon: &str| json!({"id":id,"title":"Other","icon":icon,"invoke":{"functionID":"go.markers.invoke"}});
        for alternatives in [
            json!([alternative("a", "test-passed")]),
            json!([alternative("a", "test"), alternative("a", "debug")]),
            json!((0..5)
                .map(|n| alternative(&n.to_string(), "test"))
                .collect::<Vec<_>>()),
        ] {
            assert!(v2("actions", text, marker(alternatives)).is_err());
        }
        assert!(decode_command(
            json!({"kind":"actions","text":text,"value":marker(json!([alternative("a","run")]))})
        )
        .is_err());
        // Icon names are lowercase tokens the host declared.
        assert!(decode_command(
            json!({"kind":"actions","version":2,"icons":["Run"],"sourceBytes":10,"text":"x",
            "value":{"actions":[]}})
        )
        .is_err());
        assert!(decode_command(
            json!({"kind":"actions","version":2,"icons":["run"],"sourceBytes":MAX_SOURCE_BYTES + 1,
            "text":"x","value":{"actions":[]}})
        )
        .is_err());
    }

    #[test]
    fn invoke_results_reveal_bounded_locations_and_keep_other_members_private() {
        let location = json!({"uri":"file:///work/messages.properties",
            "range":{"start":{"line":4,"character":0},"end":{"line":4,"character":12}}});
        let result = v2(
            "invokeResult",
            "",
            json!({"reveal":{"locations":[location.clone()]},"private":1}),
        )
        .unwrap();
        assert_eq!(result, json!({"reveal":{"locations":[location.clone()]}}));
        assert_eq!(
            v2("invokeResult", "", json!({"started":true})).unwrap(),
            json!({})
        );
        assert_eq!(v2("invokeResult", "", Value::Null).unwrap(), json!({}));
        for reveal in [
            json!({"locations":[]}),
            json!({"locations":vec![location; 101]}),
            json!({"locations":[{"uri":"relative/path","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]}),
            json!({"locations":[{"uri":"file:///a","range":{"start":{"line":2,"character":0},"end":{"line":1,"character":0}}}]}),
        ] {
            assert!(v2("invokeResult", "", json!({"reveal":reveal})).is_err());
        }
    }

    #[test]
    fn host_options_report_only_granted_editor_methods() {
        let options = EditorHostOptions {
            action_icons: vec!["run".into(), "debug".into()],
            action_source_bytes: MAX_SOURCE_BYTES,
            provider_types: vec!["hover".into()],
        };
        options.validate().unwrap();
        let answer = || json!({"services":{"editor":{"methods":[]}},"limits":{}});
        let mut granted = BTreeSet::from([REGISTER_ACTIONS.to_string()]);
        let mut reported = answer();
        options.report(&mut reported, &granted);
        assert_eq!(
            reported["services"]["editor"]["options"],
            json!({"actionIcons":["run","debug"]})
        );
        assert_eq!(
            reported["limits"]["editorActionSourceBytes"],
            json!(MAX_SOURCE_BYTES)
        );
        granted = BTreeSet::from([REGISTER_PROVIDERS.to_string()]);
        let mut reported = answer();
        options.report(&mut reported, &granted);
        assert_eq!(
            reported["services"]["editor"]["options"],
            json!({"providerTypes":["hover"]})
        );
        assert!(reported["limits"].get("editorActionSourceBytes").is_none());
        let mut reported = answer();
        options.report(&mut reported, &BTreeSet::new());
        assert_eq!(reported, answer());
        let mut unknown = options.clone();
        unknown.provider_types = vec!["diagnostics".into()];
        assert!(unknown.validate().is_err());
    }

    /// The shared contract fixture: what a host that declared these icons
    /// accepts, normalizes or rejects whole.
    #[test]
    fn contract_fixture_cases() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/editor/editor-actions-v2.json"
        )))
        .unwrap();
        let host: EditorHostOptions = serde_json::from_value(fixture["host"].clone()).unwrap();
        host.validate().unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let kind = case["kind"].as_str().unwrap();
            let decoded = decode_command(json!({"kind": kind, "version": 2,
                "icons": host.action_icons, "sourceBytes": host.action_source_bytes,
                "text": case.get("text").cloned().unwrap_or(json!("")), "value": case["value"]}));
            match case["expected"]["status"].as_str().unwrap() {
                "accepted" => {
                    let decoded = decoded.unwrap_or_else(|error| panic!("{name}: {error:?}"));
                    let value = if kind == "actions" {
                        &decoded["actions"]
                    } else {
                        &decoded
                    };
                    assert_eq!(value, &case["expected"]["value"], "{name}");
                }
                _ => assert!(decoded.is_err(), "{name}"),
            }
        }
    }
}
