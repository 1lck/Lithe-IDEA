//! VS Code's JSONC user keybindings and its documented macOS defaults.
use serde_json::{json, Value};
use std::collections::BTreeMap;

use crate::shortcut::{keypress, Key};

fn command(id: &str) -> Option<&'static str> {
    Some(match id {
        "workbench.action.files.save" => "save",
        "workbench.action.openSettings" => "settings",
        "workbench.action.navigateBack" => "navigate-back",
        "workbench.action.navigateForward" => "navigate-forward",
        "workbench.action.findInFiles" => "search-in-project",
        "workbench.action.replaceInFiles" => "replace-in-project",
        "actions.find" => "find-in-file",
        "editor.action.startFindReplaceAction" => "replace-in-file",
        "editor.action.nextMatchFindAction" => "find-next",
        "editor.action.previousMatchFindAction" => "find-previous",
        "editor.action.revealDefinition" => "go-to-definition",
        "editor.action.goToReferences" => "find-usages",
        "editor.action.goToImplementation" => "go-to-implementation",
        "editor.debug.action.toggleBreakpoint" => "toggle-breakpoint",
        "workbench.action.showCommands" => "find-action",
        "workbench.action.gotoLine" => "go-to-line",
        "workbench.action.terminal.toggleTerminal" => "toggle-terminal",
        "workbench.action.debug.start" => "debug",
        "workbench.action.debug.run" => "run",
        "workbench.action.debug.continue" => "debug-resume",
        "workbench.action.debug.stop" => "stop-debug",
        "workbench.action.debug.stepOver" => "debug-step-over",
        "workbench.action.debug.stepInto" => "debug-step-into",
        "workbench.action.debug.stepOut" => "debug-step-out",
        _ => return None,
    })
}

/// Returns supported, globally applicable rules; conditional and chord rules mask claimed keys.
pub fn import(source: &str) -> Result<Value, String> {
    if source.len() > 1_048_576 {
        return Err("source too large".into());
    }
    let options = jsonc_parser::ParseOptions {
        allow_comments: true,
        allow_trailing_commas: true,
        allow_loose_object_property_names: false,
        allow_missing_commas: false,
        allow_single_quoted_strings: false,
        allow_hexadecimal_numbers: false,
        allow_unary_plus_numbers: false,
        allow_bare_decimal_point_numbers: false,
        allow_non_finite_numbers: false,
        allow_extended_string_escapes: false,
    };
    let value: Value =
        jsonc_parser::parse_to_serde_value(source, &options).map_err(|_| "invalid JSONC")?;
    let rows = value
        .as_array()
        .filter(|items| items.len() <= 4096)
        .ok_or("invalid keybinding list")?;
    let defaults = [
        ("save", "cmd+s"),
        ("settings", "cmd+,"),
        ("navigate-back", "ctrl+-"),
        ("navigate-forward", "ctrl+shift+-"),
        ("search-in-project", "cmd+shift+f"),
        ("replace-in-project", "cmd+shift+h"),
        ("go-to-line", "ctrl+g"),
        ("toggle-terminal", "ctrl+`"),
        ("find-in-file", "cmd+f"),
        ("replace-in-file", "cmd+alt+f"),
        ("go-to-definition", "f12"),
        ("find-usages", "shift+f12"),
        ("toggle-breakpoint", "f9"),
        ("find-next", "cmd+g"),
        ("find-previous", "cmd+shift+g"),
        ("go-to-implementation", "cmd+f12"),
        ("find-action", "cmd+shift+p"),
        ("find-action", "f1"),
        ("debug-start-or-continue", "f5"),
        ("debug-step-over", "f10"),
        ("debug-step-into", "f11"),
        ("debug-step-out", "shift+f11"),
        ("stop-debug", "shift+f5"),
    ];
    let mut result: BTreeMap<&str, Vec<Key>> = BTreeMap::new();
    for (id, key) in defaults {
        result
            .entry(id)
            .or_default()
            .push(keypress(key).expect("valid reference key"));
    }
    // VS Code applies removal rules to matching defaults by command before
    // considering user overrides; a removal never claims an unrelated key.
    for row in rows {
        let object = row.as_object().ok_or("invalid keybinding row")?;
        let Some(raw_command) = object
            .get("command")
            .and_then(Value::as_str)
            .and_then(|name| name.strip_prefix('-'))
        else {
            continue;
        };
        // Conditional removals only target matching upstream context rules.
        // Without their when-clause semantics we cannot treat them as global.
        if object.get("when").is_some_and(|when| {
            !when
                .as_str()
                .is_some_and(|expression| expression.trim() == "true")
        }) {
            continue;
        }
        let key = match object.get("key") {
            None => None,
            Some(Value::String(value)) => match keypress(value) {
                Some(key) => Some(key),
                None => continue,
            },
            Some(_) => continue,
        };
        if let Some(bindings) = command(raw_command).and_then(|id| result.get_mut(id)) {
            if let Some(key) = &key {
                bindings.retain(|existing| existing != key);
            } else {
                bindings.clear();
            }
        }
        // F5 represents the combined start/continue behavior, so removing
        // either source command removes that reference binding as well.
        if matches!(
            raw_command,
            "workbench.action.debug.start" | "workbench.action.debug.continue"
        ) {
            if let Some(bindings) = result.get_mut("debug-start-or-continue") {
                if let Some(key) = &key {
                    bindings.retain(|existing| existing != key);
                } else {
                    bindings.clear();
                }
            }
        }
    }
    for row in rows {
        let object = row.as_object().ok_or("invalid keybinding row")?;
        let name = object.get("command").and_then(Value::as_str);
        if name.is_some_and(|value| value.starts_with('-')) {
            continue;
        }
        let raw_key = object.get("key").and_then(Value::as_str);
        if let Some(first) = raw_key
            .and_then(|value| value.split_whitespace().next())
            .and_then(keypress)
        {
            for bindings in result.values_mut() {
                bindings.retain(|key| *key != first);
            }
        }
        let Some(id) = name.and_then(command) else {
            continue;
        };
        let binding = raw_key.and_then(keypress);
        if object.contains_key("when") || object.contains_key("args") || binding.is_none() {
            continue;
        }
        let bindings = result.entry(id).or_default();
        if bindings.len() >= 8 {
            return Err("too many keys for action".into());
        }
        bindings.insert(0, binding.unwrap());
    }
    let bindings: Vec<_> = result.into_iter().map(|(id, keys)| json!({"commandID":id, "keys":
        keys.into_iter().map(|key| json!({"key":key.key, "modifiers":key.modifiers})).collect::<Vec<_>>()
    })).collect();
    Ok(json!({"bindings":bindings}))
}
