//! Shortcut binding grammar and effective-binding conflict analysis.
//!
//! Hosts keep native key-event conversion and the synchronous key-matching path.
//! Core owns what a binding string means, which bindings are in force after
//! defaults, presets and user overrides are layered, and which of them collide.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_ENTRIES: usize = 20_000;
const MAX_BINDING_BYTES: usize = 256;
const MAX_STEPS: usize = 8;

/// Host operating system whose command key alias (`cmd`/`mod`) is being parsed.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BindingPlatform {
    /// `cmd` is the Command key.
    Macos,
    /// `cmd` is folded into Control, as the Windows host always did.
    Windows,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
enum Modifier {
    Ctrl,
    Alt,
    Shift,
    Meta,
}

/// One keystroke of a binding: a canonical modifier set plus a lower-case key name.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct BindingStep {
    modifiers: Vec<Modifier>,
    key: String,
}

impl BindingStep {
    fn canonical(&self) -> String {
        let mut text = String::new();
        for modifier in &self.modifiers {
            text.push_str(match modifier {
                Modifier::Ctrl => "ctrl+",
                Modifier::Alt => "alt+",
                Modifier::Shift => "shift+",
                Modifier::Meta => "meta+",
            });
        }
        text + &self.key
    }
}

fn modifier_alias(token: &str, platform: BindingPlatform) -> Option<Modifier> {
    match token {
        "ctrl" | "control" => Some(Modifier::Ctrl),
        "alt" | "option" | "opt" => Some(Modifier::Alt),
        "shift" => Some(Modifier::Shift),
        "cmd" | "command" | "mod" => Some(match platform {
            BindingPlatform::Macos => Modifier::Meta,
            BindingPlatform::Windows => Modifier::Ctrl,
        }),
        "meta" | "super" | "win" => Some(Modifier::Meta),
        _ => None,
    }
}

fn key_alias(token: &str) -> String {
    match token {
        "return" => "enter",
        "esc" => "escape",
        "del" => "delete",
        "pgup" => "pageup",
        "pgdn" => "pagedown",
        "spacebar" => "space",
        other => other,
    }
    .to_string()
}

fn parse_step(text: &str, platform: BindingPlatform) -> Result<BindingStep, &'static str> {
    // A trailing plus is the `+` key itself (`ctrl++`), not an empty segment.
    let (head, plus_key) = match text.strip_suffix('+') {
        Some(rest) if rest.is_empty() => ("", true),
        Some(rest) => match rest.strip_suffix('+') {
            Some(head) => (head, true),
            None => return Err("empty_key"),
        },
        None => (text, false),
    };
    let mut modifiers = Vec::new();
    let mut key: Option<String> = plus_key.then(|| "+".to_string());
    for token in head.split('+').filter(|token| !token.is_empty()) {
        let token = token.to_lowercase();
        if let Some(modifier) = modifier_alias(&token, platform) {
            if !modifiers.contains(&modifier) {
                modifiers.push(modifier);
            }
        } else if key.replace(key_alias(&token)).is_some() {
            return Err("multiple_keys");
        }
    }
    modifiers.sort();
    Ok(BindingStep {
        modifiers,
        key: key.ok_or("empty_key")?,
    })
}

/// Parses one binding string such as `cmd+shift+p` or `ctrl+k ctrl+t` into canonical steps.
///
/// Modifier order, case and aliases (`cmd`, `command`, `mod`, `option`, `esc`, ...) do not
/// affect the result, so equivalent spellings compare equal. Errors are stable codes.
pub fn parse_binding(
    binding: &str,
    platform: BindingPlatform,
) -> Result<Vec<BindingStep>, &'static str> {
    if binding.len() > MAX_BINDING_BYTES {
        return Err("too_long");
    }
    let steps = binding
        .split_whitespace()
        .map(|step| parse_step(step, platform))
        .collect::<Result<Vec<_>, _>>()?;
    match steps.len() {
        0 => Err("empty"),
        count if count > MAX_STEPS => Err("too_many_steps"),
        _ => Ok(steps),
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One binding contributed by a layer. `enabled: false` removes the command's bindings.
pub struct BindingEntry {
    pub command: String,
    pub key: String,
    #[serde(default)]
    pub when: Option<String>,
    #[serde(default)]
    pub enabled: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// A source of bindings. Within a layer, a command's entries replace everything below it.
pub struct BindingLayer {
    #[serde(default)]
    pub entries: Vec<BindingEntry>,
    /// Commands this layer unbinds entirely.
    #[serde(default)]
    pub disabled_commands: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Layers ordered from lowest priority (defaults) to highest (user overrides).
pub struct AnalyzeConflictsRequest {
    pub platform: BindingPlatform,
    pub layers: Vec<BindingLayer>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Several commands that are active on the same canonical key sequence and `when` clause.
pub struct BindingConflict {
    pub key: String,
    pub when: Option<String>,
    pub commands: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// A binding that is in force but cannot be parsed; it takes no part in conflicts.
pub struct InvalidBinding {
    pub command: String,
    pub key: String,
    pub code: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Conflicts among the final effective bindings, in a deterministic order.
pub struct AnalyzeConflictsResponse {
    pub conflicts: Vec<BindingConflict>,
    pub invalid: Vec<InvalidBinding>,
}

fn normalize_when(when: &Option<String>) -> Option<String> {
    let joined = when
        .as_deref()?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!joined.is_empty()).then_some(joined)
}

/// Layers bindings per command and reports every collision among the result.
pub fn analyze_conflicts(
    request: AnalyzeConflictsRequest,
) -> Result<AnalyzeConflictsResponse, crate::CoreError> {
    let total: usize = request
        .layers
        .iter()
        .map(|layer| layer.entries.len() + layer.disabled_commands.len())
        .sum();
    if total > MAX_ENTRIES {
        return Err(crate::CoreError::new(
            crate::ErrorCode::InvalidRequest,
            "Too many keymap bindings",
        ));
    }
    // BTreeMap keeps the output independent of the order commands were registered in.
    let mut effective: BTreeMap<&str, Vec<&BindingEntry>> = BTreeMap::new();
    for layer in &request.layers {
        for command in &layer.disabled_commands {
            effective.remove(command.as_str());
        }
        let mut replaced: BTreeMap<&str, Vec<&BindingEntry>> = BTreeMap::new();
        for entry in &layer.entries {
            replaced
                .entry(entry.command.as_str())
                .or_default()
                .push(entry);
        }
        effective.extend(replaced);
    }
    let mut groups: BTreeMap<(String, Option<String>), Vec<String>> = BTreeMap::new();
    let mut invalid = Vec::new();
    for (command, entries) in effective {
        for entry in entries
            .into_iter()
            .filter(|entry| entry.enabled != Some(false))
        {
            match parse_binding(&entry.key, request.platform) {
                Ok(steps) => {
                    let key = steps
                        .iter()
                        .map(BindingStep::canonical)
                        .collect::<Vec<_>>()
                        .join(" ");
                    let commands = groups
                        .entry((key, normalize_when(&entry.when)))
                        .or_default();
                    if !commands.iter().any(|existing| existing == command) {
                        commands.push(command.to_string());
                    }
                }
                Err(code) => invalid.push(InvalidBinding {
                    command: command.to_string(),
                    key: entry.key.clone(),
                    code,
                }),
            }
        }
    }
    let conflicts = groups
        .into_iter()
        .filter(|(_, commands)| commands.len() > 1)
        .map(|((key, when), commands)| BindingConflict {
            key,
            when,
            commands,
        })
        .collect();
    Ok(AnalyzeConflictsResponse { conflicts, invalid })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equivalent_spellings_share_one_canonical_form() {
        let canonical = |text: &str, platform| {
            parse_binding(text, platform)
                .unwrap()
                .iter()
                .map(BindingStep::canonical)
                .collect::<Vec<_>>()
                .join(" ")
        };
        let windows = BindingPlatform::Windows;
        assert_eq!(canonical("Shift+CTRL+P", windows), "ctrl+shift+p");
        assert_eq!(canonical("cmd+shift+p", windows), "ctrl+shift+p");
        assert_eq!(canonical("ctrl++", windows), "ctrl++");
        assert_eq!(canonical("cmd+esc", BindingPlatform::Macos), "meta+escape");
        assert_eq!(parse_binding("ctrl+a+b", windows), Err("multiple_keys"));
        assert_eq!(parse_binding("ctrl+", windows), Err("empty_key"));
        assert_eq!(parse_binding("   ", windows), Err("empty"));
    }
}
