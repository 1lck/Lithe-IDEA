//! Declarative syntax highlighting of plugin languages, `languages` 2.
//!
//! A language may name a grammar file in its package and a small editing
//! configuration (comments and brackets). The grammar is data the editor's
//! tokenizer engine runs; `kind` names that engine, so a later version can add
//! another engine without changing what an existing grammar means. Version 2
//! accepts only `monarch`, the tokenizer the shared Monaco editor already
//! runs for its built-in languages. Plugin definitions compile and tokenize
//! only in a separate, terminable worker; no extra regex engine is introduced.
//!
//! The host reads the file from the read-only package and passes its text to
//! `plugins.declarative.decodeGrammar`; Core never opens package files. Core
//! checks the Monarch subset below and bounds its size, so a hostile grammar
//! cannot write to the console, jump to a state that does not exist, or grow
//! without limit. Expanded include graphs have their own budget. Regex cost
//! cannot be proven by string length: the host editor terminates a stalled
//! worker and keeps text editable without executing plugin regexes on its UI thread.
//!
//! Note: the decision is recorded in .agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md

use super::declarative::{invalid, is_safe_relative_path, PluginRejection, Validation};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeSet;

/// First `languages` version with `grammar` and `configuration`.
pub(crate) const GRAMMAR_LANGUAGES_VERSION: u32 = 2;

/// Largest grammar file, in UTF-8 bytes.
pub(crate) const MAX_GRAMMAR_BYTES: usize = 256 * 1024;
/// Most tokenizer states in one grammar.
const MAX_STATES: usize = 256;
/// Most rules across every state.
const MAX_RULES: usize = 4096;
/// Longest regular expression source or attribute string.
const MAX_REGEX_BYTES: usize = 2048;
/// Most entries of one attribute list, such as `keywords`.
const MAX_ATTRIBUTE_ENTRIES: usize = 4096;
/// Longest attribute list entry.
const MAX_ATTRIBUTE_ENTRY_BYTES: usize = 256;
/// Most guards of one `cases` object.
const MAX_CASES: usize = 64;
/// Deepest nesting of actions inside groups and `cases`.
const MAX_ACTION_DEPTH: usize = 8;
/// Longest token, state, or embedded language name.
const MAX_NAME_BYTES: usize = 128;
/// Most bracket pairs in a grammar or a language configuration.
const MAX_BRACKETS: usize = 32;
/// Longest comment or bracket delimiter.
const MAX_DELIMITER_BYTES: usize = 16;

/// Keys of an action object. `log` is refused: a grammar never writes to the
/// editor's console.
const ACTION_KEYS: &[&str] = &[
    "token",
    "next",
    "switchTo",
    "goBack",
    "bracket",
    "nextEmbedded",
    "cases",
];

/// Engine that runs a grammar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum GrammarKind {
    /// A Monaco Monarch tokenizer as JSON.
    Monarch,
}

/// `languages[].grammar`: the engine and the package file it reads.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct GrammarDeclaration {
    pub(crate) kind: GrammarKind,
    /// Package-relative grammar file, e.g. `syntax/http.monarch.json`.
    pub(crate) path: String,
}

/// `languages[].configuration`: comment and bracket behavior of the editor.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LanguageConfiguration {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    line_comment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    block_comment: Option<[String; 2]>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    brackets: Vec<[String; 2]>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    auto_closing_pairs: Vec<[String; 2]>,
}

impl GrammarDeclaration {
    pub(crate) fn validate(&self, field: &str) -> Validation<()> {
        if !is_safe_relative_path(&self.path) || self.path.contains(':') {
            return Err(invalid(
                format!("{field}.path"),
                "The grammar must be a file inside the plugin package.",
            ));
        }
        Ok(())
    }
}

impl LanguageConfiguration {
    pub(crate) fn validate(&self, field: &str) -> Validation<()> {
        let delimiter = |value: &str| {
            !value.is_empty()
                && value.len() <= MAX_DELIMITER_BYTES
                && !value.chars().any(char::is_control)
        };
        if self
            .line_comment
            .as_deref()
            .is_some_and(|value| !delimiter(value))
        {
            return Err(invalid(
                format!("{field}.lineComment"),
                "A comment delimiter is 1 to 16 bytes without control characters.",
            ));
        }
        if self
            .block_comment
            .as_ref()
            .is_some_and(|[open, close]| !delimiter(open) || !delimiter(close))
        {
            return Err(invalid(
                format!("{field}.blockComment"),
                "A comment delimiter is 1 to 16 bytes without control characters.",
            ));
        }
        for (key, pairs) in [
            ("brackets", &self.brackets),
            ("autoClosingPairs", &self.auto_closing_pairs),
        ] {
            if pairs.len() > MAX_BRACKETS
                || pairs
                    .iter()
                    .any(|[open, close]| !delimiter(open) || !delimiter(close))
            {
                return Err(invalid(
                    format!("{field}.{key}"),
                    "At most 32 pairs, each delimiter 1 to 16 bytes without control characters.",
                ));
            }
        }
        Ok(())
    }
}

fn grammar_error(field: impl Into<String>, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.grammar.invalid", field, message)
}

/// Validates the text of a Monarch grammar file and returns it as a JSON
/// object for validation. Hosts transport the original text, not this map,
/// because Monarch case precedence depends on source key order.
pub(crate) fn decode_monarch(text: &str) -> Validation<Value> {
    if text.len() > MAX_GRAMMAR_BYTES {
        return Err(grammar_error(
            "grammar",
            "The grammar file is larger than 256 KiB.",
        ));
    }
    let value: Value = serde_json::from_str(text)
        .map_err(|error| grammar_error("grammar", format!("The grammar is not JSON: {error}.")))?;
    let Value::Object(grammar) = &value else {
        return Err(grammar_error(
            "grammar",
            "A Monarch grammar is a JSON object.",
        ));
    };
    let Some(Value::Object(tokenizer)) = grammar.get("tokenizer") else {
        return Err(grammar_error(
            "grammar.tokenizer",
            "A Monarch grammar has a tokenizer object.",
        ));
    };
    if tokenizer.is_empty() || tokenizer.len() > MAX_STATES {
        return Err(grammar_error(
            "grammar.tokenizer",
            "A tokenizer has 1 to 256 states.",
        ));
    }
    let states: BTreeSet<&str> = tokenizer.keys().map(String::as_str).collect();
    if let Some(state) = states.iter().find(|state| !is_state_name(state)) {
        return Err(grammar_error(
            format!("grammar.tokenizer.{state}"),
            "A state name is an identifier, optionally with dot-separated parts.",
        ));
    }
    let start = match grammar.get("start") {
        None => "root",
        Some(Value::String(start)) => start.as_str(),
        Some(_) => return Err(grammar_error("grammar.start", "start names a state.")),
    };
    if !states.contains(start) {
        return Err(grammar_error(
            "grammar.start",
            format!("The tokenizer has no {start} state to start in."),
        ));
    }
    let mut attributes = BTreeSet::new();
    for (key, entry) in grammar {
        let field = format!("grammar.{key}");
        match key.as_str() {
            "tokenizer" | "start" => {}
            "ignoreCase" | "unicode" | "includeLF" => {
                if !entry.is_boolean() {
                    return Err(grammar_error(field, format!("{key} is a boolean.")));
                }
            }
            "defaultToken" | "tokenPostfix" => {
                if !entry.as_str().is_some_and(is_token) {
                    return Err(grammar_error(field, format!("{key} is a token name.")));
                }
            }
            "brackets" => check_grammar_brackets(entry, &field)?,
            _ => {
                if !is_identifier(key) {
                    return Err(grammar_error(field, "An attribute name is an identifier."));
                }
                check_attribute(entry, &field)?;
                attributes.insert(key.as_str());
            }
        }
    }
    let context = RuleContext {
        states: &states,
        attributes: &attributes,
    };
    let mut rules = 0;
    for (state, entry) in tokenizer {
        let field = format!("grammar.tokenizer.{state}");
        let Value::Array(entries) = entry else {
            return Err(grammar_error(field, "A state is an array of rules."));
        };
        rules += entries.len();
        if rules > MAX_RULES {
            return Err(grammar_error(
                "grammar.tokenizer",
                "A tokenizer has at most 4096 rules.",
            ));
        }
        for (index, rule) in entries.iter().enumerate() {
            context.check_rule(rule, &format!("{field}[{index}]"))?;
        }
    }
    // Monarch expands includes synchronously. Bound the expanded graph, not
    // merely the input JSON; cycles and repeated fan-out must fail in Core.
    fn expanded(
        state: &str,
        tokenizer: &Map<String, Value>,
        stack: &mut BTreeSet<String>,
        memo: &mut std::collections::BTreeMap<String, usize>,
    ) -> Validation<usize> {
        if let Some(count) = memo.get(state) {
            return Ok(*count);
        }
        if !stack.insert(state.to_string()) {
            return Err(grammar_error(
                "grammar.tokenizer",
                "Tokenizer includes must not form a cycle.",
            ));
        }
        let rules = tokenizer
            .get(state)
            .and_then(Value::as_array)
            .ok_or_else(|| {
                grammar_error("grammar.tokenizer", "An include names an exact state.")
            })?;
        let mut count = 0usize;
        for rule in rules {
            count = count.saturating_add(
                if let Some(target) = rule.get("include").and_then(Value::as_str) {
                    expanded(
                        target.strip_prefix('@').unwrap_or(target),
                        tokenizer,
                        stack,
                        memo,
                    )?
                } else {
                    1
                },
            );
            if count > MAX_RULES {
                return Err(grammar_error(
                    "grammar.tokenizer",
                    "Expanded tokenizer exceeds 4096 rules.",
                ));
            }
        }
        stack.remove(state);
        memo.insert(state.to_string(), count);
        Ok(count)
    }
    let mut memo = std::collections::BTreeMap::new();
    for state in &states {
        expanded(state, tokenizer, &mut BTreeSet::new(), &mut memo)?;
    }
    Ok(value)
}

struct RuleContext<'a> {
    states: &'a BTreeSet<&'a str>,
    attributes: &'a BTreeSet<&'a str>,
}

impl RuleContext<'_> {
    fn check_rule(&self, rule: &Value, field: &str) -> Validation<()> {
        match rule {
            Value::Array(parts) => {
                let (regex, action, next) = match parts.as_slice() {
                    [regex, action] => (regex, action, None),
                    [regex, action, next] => (regex, action, Some(next)),
                    _ => {
                        return Err(grammar_error(
                            field,
                            "A rule array is [regex, action] or [regex, action, next].",
                        ))
                    }
                };
                self.check_regex(regex, field)?;
                self.check_action(action, &format!("{field}[1]"), 0)?;
                if let Some(next) = next {
                    self.check_next(next, &format!("{field}[2]"))?;
                }
                Ok(())
            }
            Value::Object(object) if object.contains_key("include") => {
                if object.len() != 1 {
                    return Err(grammar_error(field, "An include rule has only include."));
                }
                let target = object.get("include").and_then(Value::as_str).unwrap_or("");
                let state = target.strip_prefix('@').unwrap_or(target);
                if !self.has_state(state) {
                    return Err(grammar_error(
                        format!("{field}.include"),
                        "An include names a state of the tokenizer.",
                    ));
                }
                Ok(())
            }
            Value::Object(object) => {
                if object.keys().any(|key| key != "regex" && key != "action") {
                    return Err(grammar_error(
                        field,
                        "A rule object has regex and action, or include.",
                    ));
                }
                let regex = object
                    .get("regex")
                    .ok_or_else(|| grammar_error(field, "A rule object has a regex."))?;
                self.check_regex(regex, field)?;
                let action = object
                    .get("action")
                    .ok_or_else(|| grammar_error(field, "A rule object has an action."))?;
                self.check_action(action, &format!("{field}.action"), 0)
            }
            _ => Err(grammar_error(field, "A rule is an array or an object.")),
        }
    }

    fn check_regex(&self, regex: &Value, field: &str) -> Validation<()> {
        match regex.as_str() {
            Some(source)
                if !source.is_empty()
                    && source.len() <= MAX_REGEX_BYTES
                    && !source.contains('\0') =>
            {
                Ok(())
            }
            _ => Err(grammar_error(
                field,
                "A rule regex is a string of 1 to 2048 bytes without NUL.",
            )),
        }
    }

    fn check_action(&self, action: &Value, field: &str, depth: usize) -> Validation<()> {
        if depth > MAX_ACTION_DEPTH {
            return Err(grammar_error(field, "Actions nest at most 8 levels deep."));
        }
        match action {
            Value::String(token) if is_token(token) => Ok(()),
            Value::Array(group) if !group.is_empty() && group.len() <= MAX_CASES => {
                for (index, part) in group.iter().enumerate() {
                    self.check_action(part, &format!("{field}[{index}]"), depth + 1)?;
                }
                Ok(())
            }
            Value::Object(object) => self.check_action_object(object, field, depth),
            _ => Err(grammar_error(
                field,
                "An action is a token name, a group of actions, or an action object.",
            )),
        }
    }

    fn check_action_object(
        &self,
        object: &Map<String, Value>,
        field: &str,
        depth: usize,
    ) -> Validation<()> {
        if let Some(key) = object
            .keys()
            .find(|key| !ACTION_KEYS.contains(&key.as_str()))
        {
            return Err(grammar_error(
                format!("{field}.{key}"),
                "Unknown action field; log is not allowed.",
            ));
        }
        if let Some(cases) = object.get("cases") {
            let Value::Object(cases) = cases else {
                return Err(grammar_error(
                    format!("{field}.cases"),
                    "cases is an object.",
                ));
            };
            if cases.is_empty() || cases.len() > MAX_CASES {
                return Err(grammar_error(
                    format!("{field}.cases"),
                    "cases has 1 to 64 guards.",
                ));
            }
            for (guard, case) in cases {
                let case_field = format!("{field}.cases.{guard}");
                if guard.is_empty() || guard.len() > MAX_REGEX_BYTES {
                    return Err(grammar_error(case_field, "A guard is 1 to 2048 bytes."));
                }
                if let Some(attribute) = guard.strip_prefix('@') {
                    if !matches!(attribute, "default" | "eos")
                        && is_identifier(attribute)
                        && !self.attributes.contains(attribute)
                    {
                        return Err(grammar_error(
                            case_field,
                            format!("The guard names an undeclared attribute {attribute}."),
                        ));
                    }
                }
                self.check_action(case, &case_field, depth + 1)?;
            }
        }
        if let Some(token) = object.get("token") {
            if !token.as_str().is_some_and(is_token) {
                return Err(grammar_error(
                    format!("{field}.token"),
                    "token is a token name.",
                ));
            }
        }
        for key in ["next", "switchTo"] {
            if let Some(next) = object.get(key) {
                self.check_next(next, &format!("{field}.{key}"))?;
            }
        }
        if let Some(back) = object.get("goBack") {
            if !back
                .as_u64()
                .is_some_and(|count| count <= MAX_REGEX_BYTES as u64)
            {
                return Err(grammar_error(
                    format!("{field}.goBack"),
                    "goBack is a small non-negative integer.",
                ));
            }
        }
        if let Some(bracket) = object.get("bracket") {
            if !matches!(bracket.as_str(), Some("@open" | "@close")) {
                return Err(grammar_error(
                    format!("{field}.bracket"),
                    "bracket is @open or @close.",
                ));
            }
        }
        if let Some(embedded) = object.get("nextEmbedded") {
            if !embedded
                .as_str()
                .is_some_and(|name| name == "@pop" || is_embedded_language(name))
            {
                return Err(grammar_error(
                    format!("{field}.nextEmbedded"),
                    "nextEmbedded is @pop or a language ID.",
                ));
            }
        }
        if !object.contains_key("token") && !object.contains_key("cases") {
            return Err(grammar_error(field, "An action object has token or cases."));
        }
        Ok(())
    }

    fn check_next(&self, next: &Value, field: &str) -> Validation<()> {
        let Some(next) = next.as_str() else {
            return Err(grammar_error(field, "next names a state."));
        };
        if matches!(next, "@pop" | "@push" | "@popall") {
            return Ok(());
        }
        // `$S2`-style substitutions are resolved by the editor at run time.
        if next.contains('$') && next.starts_with('@') && next.len() <= MAX_NAME_BYTES {
            return Ok(());
        }
        let state = next.strip_prefix('@').unwrap_or(next);
        if self.has_state(state) {
            Ok(())
        } else {
            Err(grammar_error(
                field,
                format!("The tokenizer has no {state} state."),
            ))
        }
    }

    /// Monarch resolves `a.b.c` to the longest declared prefix, so a dotted
    /// state exists when one of its prefixes does.
    fn has_state(&self, state: &str) -> bool {
        let mut candidate = state;
        loop {
            if self.states.contains(candidate) {
                return true;
            }
            match candidate.rfind('.') {
                Some(index) => candidate = &candidate[..index],
                None => return false,
            }
        }
    }
}

fn check_attribute(value: &Value, field: &str) -> Validation<()> {
    match value {
        Value::String(text) if text.len() <= MAX_REGEX_BYTES && !text.contains('\0') => Ok(()),
        Value::Array(entries)
            if entries.len() <= MAX_ATTRIBUTE_ENTRIES
                && entries.iter().all(|entry| {
                    entry.as_str().is_some_and(|text| {
                        text.len() <= MAX_ATTRIBUTE_ENTRY_BYTES && !text.contains('\0')
                    })
                }) =>
        {
            Ok(())
        }
        _ => Err(grammar_error(
            field,
            "An attribute is a regex string or a list of at most 4096 strings.",
        )),
    }
}

fn check_grammar_brackets(value: &Value, field: &str) -> Validation<()> {
    let Value::Array(brackets) = value else {
        return Err(grammar_error(field, "brackets is an array."));
    };
    if brackets.len() > MAX_BRACKETS {
        return Err(grammar_error(field, "A grammar has at most 32 brackets."));
    }
    for (index, bracket) in brackets.iter().enumerate() {
        let well_formed = bracket.as_object().is_some_and(|bracket| {
            bracket.len() == 3
                && ["open", "close"].iter().all(|key| {
                    bracket
                        .get(*key)
                        .and_then(Value::as_str)
                        .is_some_and(|text| !text.is_empty() && text.len() <= MAX_DELIMITER_BYTES)
                })
                && bracket
                    .get("token")
                    .and_then(Value::as_str)
                    .is_some_and(is_token)
        });
        if !well_formed {
            return Err(grammar_error(
                format!("{field}[{index}]"),
                "A bracket is { open, close, token }.",
            ));
        }
    }
    Ok(())
}

fn is_identifier(value: &str) -> bool {
    let mut characters = value.chars();
    value.len() <= MAX_NAME_BYTES
        && characters
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
        && characters.all(|rest| rest.is_ascii_alphanumeric() || rest == '_')
}

fn is_state_name(value: &str) -> bool {
    value.len() <= MAX_NAME_BYTES && value.split('.').all(is_identifier)
}

/// Token names map to theme roles; `$n` and `@` forms are Monarch
/// substitutions (`$S0`, `@rematch`, `@brackets`). The empty token is plain text.
fn is_token(value: &str) -> bool {
    value.len() <= MAX_NAME_BYTES
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-$@#".contains(character))
}

fn is_embedded_language(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_NAME_BYTES
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || "+-_.$".contains(character)
        })
}
