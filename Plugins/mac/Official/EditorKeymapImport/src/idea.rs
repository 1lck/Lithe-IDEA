//! JetBrains IDEA keymap selection and bounded parent-scheme resolution.
use crate::shortcut::{idea_keypress, Key};
use quick_xml::{
    events::{BytesStart, Event},
    Reader,
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
struct Scheme {
    name: String,
    parent: Option<String>,
    actions: BTreeMap<String, Vec<Key>>,
    claimed: BTreeSet<Key>,
}
struct Action {
    target: Option<&'static str>,
    keys: Vec<Key>,
    rejected: bool,
}

fn attr(
    event: &BytesStart<'_>,
    key: &[u8],
    reader: &Reader<&[u8]>,
) -> Result<Option<String>, String> {
    for attr in event.attributes() {
        let attr = attr.map_err(|_| "invalid XML attributes")?;
        if attr.key.as_ref() == key {
            return attr
                .decode_and_unescape_value(reader.decoder())
                .map(|s| Some(s.into_owned()))
                .map_err(|_| "invalid XML value".into());
        }
    }
    Ok(None)
}

fn action_id(id: &str) -> Option<&'static str> {
    Some(match id {
        "ShowSettings" => "settings",
        "Back" => "navigate-back",
        "Forward" => "navigate-forward",
        "FindInPath" => "search-in-project",
        "ReplaceInPath" => "replace-in-project",
        "GotoLine" => "go-to-line",
        "Find" => "find-in-file",
        "FindNext" => "find-next",
        "FindPrevious" => "find-previous",
        "Replace" => "replace-in-file",
        "GotoDeclaration" => "go-to-definition",
        "GotoImplementation" => "go-to-implementation",
        "FindUsages" => "find-usages",
        "ToggleLineBreakpoint" => "toggle-breakpoint",
        "ViewBreakpoints" => "view-breakpoints",
        "GotoAction" => "find-action",
        "ActivateTerminalToolWindow" => "toggle-terminal",
        "Run" => "run",
        "Debug" => "debug",
        "Resume" => "debug-resume",
        "StepOver" => "debug-step-over",
        "StepInto" => "debug-step-into",
        "StepOut" => "debug-step-out",
        _ => return None,
    })
}

fn finish(action: Action, scheme: &mut Scheme) -> Result<(), String> {
    if let Some(target) = action.target {
        let keys = if action.rejected {
            Vec::new()
        } else {
            action.keys
        };
        if scheme.actions.insert(target.into(), keys).is_some() {
            return Err("duplicate action".into());
        }
    }
    Ok(())
}

fn parse_scheme(text: &str) -> Result<Scheme, String> {
    if text.len() > 1_048_576 {
        return Err("source too large".into());
    }
    let mut reader = Reader::from_str(text);
    reader.config_mut().trim_text(true);
    reader.config_mut().expand_empty_elements = true;
    let mut depth = 0usize;
    let mut root_seen = false;
    let mut scheme = Scheme::default();
    let mut current: Option<Action> = None;
    let mut action_count = 0usize;
    loop {
        match reader.read_event().map_err(|_| "invalid XML")? {
            Event::DocType(_) => return Err("DOCTYPE is not allowed".into()),
            Event::Start(event) => {
                depth += 1;
                if depth > 64 {
                    return Err("XML nesting limit".into());
                }
                let name = event.name();
                let tag = name.as_ref();
                if depth == 1 {
                    if root_seen || tag != b"keymap" {
                        return Err("invalid keymap root".into());
                    }
                    root_seen = true;
                    scheme.name = attr(&event, b"name", &reader)?
                        .filter(|name| !name.is_empty() && name.len() <= 1024)
                        .ok_or("missing scheme name")?;
                    scheme.parent = attr(&event, b"parent", &reader)?;
                } else if depth == 2 && tag == b"action" {
                    action_count += 1;
                    if action_count > 4096 || current.is_some() {
                        return Err("too many actions".into());
                    }
                    let id = attr(&event, b"id", &reader)?.unwrap_or_default();
                    current = Some(Action {
                        target: action_id(&id),
                        keys: Vec::new(),
                        rejected: false,
                    });
                } else if depth == 3 && tag == b"keyboard-shortcut" {
                    if let Some(action) = current.as_mut() {
                        let first = attr(&event, b"first-keystroke", &reader)?
                            .and_then(|key| idea_keypress(&key));
                        if let Some(key) = first.clone() {
                            scheme.claimed.insert(key);
                        }
                        if attr(&event, b"second-keystroke", &reader)?.is_some() || first.is_none()
                        {
                            action.rejected = true;
                        } else if let Some(key) = first {
                            if !action.keys.contains(&key) {
                                action.keys.push(key);
                            }
                            if action.keys.len() > 8 {
                                return Err("too many shortcuts".into());
                            }
                        }
                    }
                }
            }
            Event::End(event) => {
                if depth == 2 && event.name().as_ref() == b"action" {
                    if let Some(action) = current.take() {
                        finish(action, &mut scheme)?;
                    }
                }
                depth = depth.checked_sub(1).ok_or("invalid XML nesting")?;
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !root_seen || depth != 0 {
        return Err("incomplete keymap".into());
    }
    Ok(scheme)
}

fn active_scheme(text: &str) -> Result<Option<String>, String> {
    if text.len() > 1_048_576 {
        return Err("source too large".into());
    }
    let mut reader = Reader::from_str(text);
    reader.config_mut().expand_empty_elements = true;
    let mut stack: Vec<Vec<u8>> = Vec::new();
    let mut component = false;
    let mut active = None;
    let mut root_seen = false;
    loop {
        match reader.read_event().map_err(|_| "invalid XML")? {
            Event::DocType(_) => return Err("DOCTYPE is not allowed".into()),
            Event::Start(event) => {
                let name = event.name().as_ref().to_vec();
                if stack.len() >= 64 {
                    return Err("XML nesting limit".into());
                }
                if stack.is_empty() {
                    if root_seen || name != b"application" {
                        return Err("invalid options root".into());
                    }
                    root_seen = true;
                }
                if name == b"component" && stack.len() == 1 {
                    component = attr(&event, b"name", &reader)?.as_deref() == Some("KeymapManager");
                }
                if name == b"active_keymap" && stack.len() == 2 && component {
                    if active.is_some() {
                        return Err("duplicate active scheme".into());
                    }
                    active = Some(
                        attr(&event, b"name", &reader)?
                            .filter(|name| !name.is_empty() && name.len() <= 1024)
                            .ok_or("missing active scheme")?,
                    );
                }
                stack.push(name);
            }
            Event::End(event) => {
                if event.name().as_ref() == b"component" {
                    component = false;
                }
                stack.pop().ok_or("invalid XML nesting")?;
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !root_seen || !stack.is_empty() {
        return Err("incomplete options".into());
    }
    Ok(active)
}

fn defaults(name: &str) -> BTreeMap<String, Vec<Key>> {
    let pairs: &[(&str, &[&str])] = match name {
        "$default" => &[
            ("debug", &["shift F9"]),
            ("debug-resume", &["F9"]),
            ("debug-step-into", &["F7"]),
            ("debug-step-out", &["shift F8"]),
            ("debug-step-over", &["F8"]),
            ("find-next", &["F3", "control L"]),
            ("find-previous", &["shift F3", "control shift L"]),
            ("find-in-file", &["control F", "alt F3"]),
            ("replace-in-file", &["control R"]),
            ("go-to-definition", &["control B"]),
            ("go-to-implementation", &["control alt B"]),
            ("find-usages", &["alt F7"]),
            ("find-action", &["control shift A"]),
            ("toggle-breakpoint", &["control F8"]),
            ("view-breakpoints", &["control shift F8"]),
            ("go-to-line", &["control G"]),
            ("navigate-back", &["control alt LEFT"]),
            ("navigate-forward", &["control alt RIGHT"]),
            ("replace-in-project", &["control shift R"]),
            ("run", &["shift F10"]),
            ("search-in-project", &["control shift F"]),
            ("settings", &["control alt S"]),
            ("toggle-terminal", &["alt F12"]),
        ],
        "Mac OS X" => &[
            ("debug", &["shift F9"]),
            ("debug-resume", &["F9"]),
            ("debug-step-into", &["F7"]),
            ("debug-step-out", &["shift F8"]),
            ("debug-step-over", &["F8"]),
            ("find-next", &["F3", "control L"]),
            ("find-previous", &["shift F3", "control shift L"]),
            // The classic Mac scheme inherits these actions from $default,
            // except for its own declaration shortcut.
            ("find-in-file", &["control F", "alt F3"]),
            ("replace-in-file", &["control R"]),
            ("go-to-definition", &["meta B"]),
            ("go-to-implementation", &["control alt B"]),
            ("find-usages", &["alt F7"]),
            ("find-action", &["control shift A"]),
            ("toggle-breakpoint", &["control F8"]),
            ("view-breakpoints", &["control shift F8"]),
            ("go-to-line", &["meta G"]),
            ("navigate-back", &["meta alt LEFT"]),
            ("navigate-forward", &["meta alt RIGHT"]),
            ("replace-in-project", &["control shift R"]),
            ("run", &["shift F10"]),
            ("search-in-project", &["control shift F"]),
            ("settings", &["meta COMMA"]),
            ("toggle-terminal", &["alt F12"]),
        ],
        "Mac OS X 10.5+" => &[
            ("debug", &["control D"]),
            ("debug-resume", &["meta alt R", "F9"]),
            ("debug-step-into", &["F7"]),
            ("debug-step-out", &["shift F8"]),
            ("debug-step-over", &["F8"]),
            ("find-next", &["meta G"]),
            ("find-previous", &["meta shift G"]),
            ("go-to-line", &["meta L"]),
            ("navigate-back", &["meta OPEN_BRACKET", "meta alt LEFT"]),
            (
                "navigate-forward",
                &["meta CLOSE_BRACKET", "meta alt RIGHT"],
            ),
            ("replace-in-project", &["meta shift R"]),
            ("run", &["control R"]),
            ("search-in-project", &["meta shift F"]),
            ("settings", &["meta COMMA"]),
            ("toggle-terminal", &["alt F12"]),
            // JetBrains' published macOS keymap for the existing Lithe actions.
            ("find-in-file", &["meta F"]),
            ("replace-in-file", &["meta R"]),
            ("go-to-definition", &["meta B"]),
            ("go-to-implementation", &["meta alt B"]),
            ("find-usages", &["alt F7"]),
            ("find-action", &["meta shift A"]),
            ("toggle-breakpoint", &["meta F8"]),
            ("view-breakpoints", &["meta shift F8"]),
        ],
        _ => &[],
    };
    pairs
        .iter()
        .map(|(id, keys)| {
            (
                (*id).to_string(),
                keys.iter().filter_map(|key| idea_keypress(key)).collect(),
            )
        })
        .collect()
}

fn resolve(
    name: &str,
    schemes: &BTreeMap<String, Scheme>,
    visited: &mut BTreeSet<String>,
) -> Result<BTreeMap<String, Vec<Key>>, String> {
    if !visited.insert(name.to_string()) || visited.len() > 64 {
        return Err("keymap parent cycle".into());
    }
    let Some(scheme) = schemes.get(name) else {
        return Ok(defaults(name));
    };
    let mut result = match &scheme.parent {
        Some(parent) => resolve(parent, schemes, visited)?,
        None => BTreeMap::new(),
    };
    for bindings in result.values_mut() {
        bindings.retain(|key| !scheme.claimed.contains(key));
    }
    for (id, keys) in &scheme.actions {
        result.insert(id.clone(), keys.clone());
    }
    Ok(result)
}

/// Resolves a selected scheme without following undeclared paths or XML entities.
pub fn import(files: &BTreeMap<String, String>) -> Result<Value, String> {
    if files.len() > 128 {
        return Err("too many sources".into());
    }
    let active = files
        .get("options/keymap.xml")
        .map(|text| active_scheme(text))
        .transpose()?
        .flatten()
        .unwrap_or_else(|| "Mac OS X 10.5+".into());
    let mut schemes = BTreeMap::new();
    for (path, text) in files
        .iter()
        .filter(|(path, _)| path.starts_with("keymaps/") && path.ends_with(".xml"))
    {
        let scheme = parse_scheme(text).map_err(|_| format!("invalid keymap source: {path}"))?;
        if schemes.insert(scheme.name.clone(), scheme).is_some() {
            return Err("duplicate keymap name".into());
        }
    }
    let entries = resolve(&active, &schemes, &mut BTreeSet::new())?;
    let bindings: Vec<_> = entries.into_iter().map(|(id, keys)| json!({"commandID":id,"keys":
        keys.into_iter().map(|key| json!({"key":key.key,"modifiers":key.modifiers})).collect::<Vec<_>>()
    })).collect();
    Ok(json!({"bindings":bindings}))
}
