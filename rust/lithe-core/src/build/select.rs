//! The selector language plugins use to map a decoded document onto the
//! build model.
//!
//! A selector is a JSON Pointer with three additions: `*` fans out over every
//! array element or object value, a leading `$` starts at the document root
//! instead of the current element, and `@key` is the key or index under which
//! the current element was reached. `""` is the current element itself.
//! There are no functions or expressions; filtering is done by `where`
//! predicates, so a mapping stays data a reviewer can read.

use crate::plugins::declarative::{invalid, Validation};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Longest selector accepted in a manifest.
const MAX_SELECTOR: usize = 512;

/// A parsed selector.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Selector {
    /// Relative to the current element.
    Current(Vec<Segment>),
    /// Relative to the document root.
    Root(Vec<Segment>),
    /// The key or index of the current element.
    Key,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Segment {
    Key(String),
    Wildcard,
}

impl Selector {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        if value.len() > MAX_SELECTOR || value.contains('\0') {
            return None;
        }
        if value == "@key" {
            return Some(Self::Key);
        }
        if value.is_empty() {
            return Some(Self::Current(Vec::new()));
        }
        if let Some(rest) = value.strip_prefix('$') {
            return if rest.is_empty() {
                Some(Self::Root(Vec::new()))
            } else {
                rest.starts_with('/')
                    .then(|| segments(&rest[1..]))
                    .flatten()
                    .map(Self::Root)
            };
        }
        value
            .strip_prefix('/')
            .and_then(segments)
            .map(Self::Current)
    }
}

fn segments(value: &str) -> Option<Vec<Segment>> {
    value
        .split('/')
        .map(|segment| {
            if segment == "*" {
                return Some(Segment::Wildcard);
            }
            // JSON Pointer escapes: `~1` is `/`, `~0` is `~`; any other `~`
            // sequence is malformed.
            let mut key = String::new();
            let mut characters = segment.chars();
            while let Some(character) = characters.next() {
                if character == '~' {
                    match characters.next() {
                        Some('0') => key.push('~'),
                        Some('1') => key.push('/'),
                        _ => return None,
                    }
                } else {
                    key.push(character);
                }
            }
            Some(Segment::Key(key))
        })
        .collect()
}

/// Checks a selector field of a manifest. `each` selectors cannot be `@key`,
/// which names a string rather than elements.
pub(crate) fn validate(value: &str, field: &str, allow_key: bool) -> Validation<()> {
    match Selector::parse(value) {
        Some(Selector::Key) if !allow_key => Err(invalid(
            field,
            "@key selects a name, not elements to iterate.",
        )),
        Some(_) => Ok(()),
        None => Err(invalid(
            field,
            "A selector is \"\", @key, or a /-separated path optionally starting with $.",
        )),
    }
}

/// One element reached by a selector, with the key or index it was reached
/// under.
#[derive(Debug, Clone)]
pub(crate) struct Node<'a> {
    pub(crate) value: &'a Value,
    pub(crate) key: Option<String>,
}

impl<'a> Node<'a> {
    pub(crate) fn root(value: &'a Value) -> Self {
        Self { value, key: None }
    }
}

/// Elements the selector reaches from `current`. `@key` reaches nothing.
pub(crate) fn nodes<'a>(selector: &str, document: &'a Value, current: &Node<'a>) -> Vec<Node<'a>> {
    let (start, path) = match Selector::parse(selector) {
        Some(Selector::Current(path)) => (current.clone(), path),
        Some(Selector::Root(path)) => (Node::root(document), path),
        Some(Selector::Key) | None => return Vec::new(),
    };
    let mut reached = vec![start];
    for segment in &path {
        let mut next = Vec::new();
        for node in reached {
            match (segment, node.value) {
                (Segment::Key(key), Value::Object(map)) => {
                    if let Some(value) = map.get(key) {
                        next.push(Node {
                            value,
                            key: Some(key.clone()),
                        });
                    }
                }
                (Segment::Key(key), Value::Array(items)) => {
                    if let Some(value) =
                        key.parse::<usize>().ok().and_then(|index| items.get(index))
                    {
                        next.push(Node {
                            value,
                            key: Some(key.clone()),
                        });
                    }
                }
                (Segment::Wildcard, Value::Object(map)) => {
                    next.extend(map.iter().map(|(key, value)| Node {
                        value,
                        key: Some(key.clone()),
                    }));
                }
                (Segment::Wildcard, Value::Array(items)) => {
                    next.extend(items.iter().enumerate().map(|(index, value)| Node {
                        value,
                        key: Some(index.to_string()),
                    }));
                }
                _ => {}
            }
        }
        reached = next;
    }
    reached
}

/// Scalar texts the selector reaches. Arrays reached are flattened one level,
/// so `/kind` yields each entry of `"kind": ["bin", "test"]`. Objects and
/// `null` yield nothing.
pub(crate) fn scalars(selector: &str, document: &Value, current: &Node<'_>) -> Vec<String> {
    if Selector::parse(selector) == Some(Selector::Key) {
        return current.key.clone().into_iter().collect();
    }
    let mut texts = Vec::new();
    for node in nodes(selector, document, current) {
        match node.value {
            Value::Array(items) => texts.extend(items.iter().filter_map(scalar_text)),
            value => texts.extend(scalar_text(value)),
        }
    }
    texts
}

fn scalar_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

/// A mapped field: a selector, a selector plus a transform of its text, or
/// fixed text for values the document does not hold (a tool's conventional
/// source directories, for example).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum FieldSpec {
    Selector(String),
    Transformed { from: String, transform: Transform },
    Literal { value: String },
}

/// Text transforms for values that carry more than the model needs, such as
/// Go import paths whose last segment is the binary name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Transform {
    LastSegment,
}

impl FieldSpec {
    pub(crate) fn validate(&self, field: &str) -> Validation<()> {
        match self {
            Self::Selector(selector) | Self::Transformed { from: selector, .. } => {
                validate(selector, field, true)
            }
            Self::Literal { value } => {
                if value.trim().is_empty()
                    || value.len() > MAX_SELECTOR
                    || value.chars().any(char::is_control)
                {
                    return Err(invalid(
                        format!("{field}.value"),
                        "A literal value is 1-512 printable characters.",
                    ));
                }
                Ok(())
            }
        }
    }

    /// First non-empty scalar text the field reaches, transformed.
    pub(crate) fn text(&self, document: &Value, current: &Node<'_>) -> Option<String> {
        let (selector, transform) = match self {
            Self::Selector(selector) => (selector, None),
            Self::Transformed { from, transform } => (from, Some(*transform)),
            Self::Literal { value } => return Some(value.clone()),
        };
        let text = scalars(selector, document, current)
            .into_iter()
            .find(|text| !text.trim().is_empty())?;
        let text = match transform {
            None => text,
            Some(Transform::LastSegment) => text
                .trim_end_matches(['/', '\\'])
                .rsplit(['/', '\\'])
                .next()
                .unwrap_or_default()
                .to_string(),
        };
        (!text.is_empty()).then_some(text)
    }
}

/// A filter on the current element: the selector reaches a value equal to
/// `equals` (any of them, for an array), or reaches something at all
/// (`exists`).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Predicate {
    pub(crate) pointer: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) equals: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) exists: Option<bool>,
}

impl Predicate {
    pub(crate) fn validate(&self, field: &str) -> Validation<()> {
        validate(&self.pointer, &format!("{field}.pointer"), true)?;
        let scalar =
            |value: &Value| matches!(value, Value::String(_) | Value::Number(_) | Value::Bool(_));
        let equals_valid = match &self.equals {
            None => true,
            Some(Value::Array(items)) => !items.is_empty() && items.iter().all(scalar),
            Some(value) => scalar(value),
        };
        if !equals_valid || self.equals.is_some() == self.exists.is_some() {
            return Err(invalid(
                field,
                "A predicate needs exactly one of equals (a scalar or array of scalars) and exists.",
            ));
        }
        Ok(())
    }

    pub(crate) fn holds(&self, document: &Value, current: &Node<'_>) -> bool {
        let found = scalars(&self.pointer, document, current);
        if let Some(exists) = self.exists {
            let reached = Selector::parse(&self.pointer) == Some(Selector::Key)
                && current.key.is_some()
                || !nodes(&self.pointer, document, current).is_empty();
            return reached == exists;
        }
        let expected: Vec<String> = match &self.equals {
            Some(Value::Array(items)) => items.iter().filter_map(scalar_text).collect(),
            Some(value) => scalar_text(value).into_iter().collect(),
            None => Vec::new(),
        };
        found.iter().any(|text| expected.contains(text))
    }
}

/// True when every predicate holds.
pub(crate) fn all_hold(predicates: &[Predicate], document: &Value, current: &Node<'_>) -> bool {
    predicates
        .iter()
        .all(|predicate| predicate.holds(document, current))
}
