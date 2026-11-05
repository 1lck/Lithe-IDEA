//! Parsing bounded, one-based Go to Line input into portable editor positions.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

const MAX_INPUT_BYTES: usize = 128;
// JavaScript consumers must represent each one-based position exactly.
const MAX_POSITION: u64 = 9_007_199_254_740_991;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    text: String,
}

pub(crate) fn parse_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid navigation input request",
        )
    })?;
    let target = (request.text.len() <= MAX_INPUT_BYTES)
        .then(|| parse(&request.text))
        .flatten();
    Ok(json!({"target": target}))
}

fn parse(text: &str) -> Option<Value> {
    // Match the native dialog's horizontal-whitespace trimming without treating
    // a pasted line terminator as part of a single-line position.
    fn horizontal_space(c: char) -> bool {
        c.is_whitespace()
            && !matches!(
                c,
                '\n' | '\r' | '\u{000b}' | '\u{000c}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
            )
    }
    fn one_based(part: &str) -> Option<u64> {
        let value: u64 = part.trim_matches(horizontal_space).parse().ok()?;
        (1..=MAX_POSITION).contains(&value).then_some(value)
    }
    let mut parts = text.trim_matches(horizontal_space).split(':');
    let line = one_based(parts.next()?)?;
    let column_part = parts.next();
    if parts.next().is_some() {
        return None;
    }
    let column = match column_part {
        Some(part) => one_based(part)?,
        None => 1,
    };
    Some(json!({"line":line - 1, "column":column - 1, "selectsWholeLine":column_part.is_none()}))
}
