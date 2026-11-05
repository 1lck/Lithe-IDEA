//! Content providers of plugin backends (plan API-12).
//!
//! A backend whose server hands out documents that have no file serves them
//! as a URI scheme. The host calls the backend function the scheme is bound
//! to and shows the answer read-only. Core checks that answer, so every host
//! opens the same text under the same limit and refuses the same shapes.

use super::declarative::decode_payload;
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

/// Longest document text a provider may answer, in UTF-8 bytes.
pub(crate) const MAX_CONTENT_BYTES: usize = 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DecodeRequest {
    result: Value,
}

/// `plugins.contentProviders.decode`: returns `{content}` for a provider
/// answer that is a string or `{content: string}` within the byte limit, and
/// refuses anything else so the host opens nothing.
pub fn decode_content_command(payload: Value) -> Result<Value, CoreError> {
    let request: DecodeRequest = decode_payload(payload, "plugins.contentProviders.decode")?;
    let content = answer_text(&request.result).ok_or_else(|| {
        refused("The content provider must answer a string or an object with only `content`.")
    })?;
    if content.len() > MAX_CONTENT_BYTES {
        return Err(refused("The content provider answered more than 1 MiB."));
    }
    Ok(json!({ "content": content }))
}

fn answer_text(result: &Value) -> Option<&str> {
    match result {
        Value::String(text) => Some(text),
        Value::Object(members) if members.len() == 1 => members.get("content")?.as_str(),
        _ => None,
    }
}

fn refused(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_string_and_a_content_object_are_the_same_answer() {
        let plain = decode_content_command(json!({ "result": "class A {}" })).unwrap();
        let wrapped =
            decode_content_command(json!({ "result": { "content": "class A {}" } })).unwrap();
        assert_eq!(plain, json!({ "content": "class A {}" }));
        assert_eq!(wrapped, plain);
    }

    #[test]
    fn other_shapes_are_refused() {
        for result in [
            json!(null),
            json!(7),
            json!(["text"]),
            json!({}),
            json!({ "content": 7 }),
            json!({ "content": "text", "mime": "text/plain" }),
        ] {
            let error = decode_content_command(json!({ "result": result })).unwrap_err();
            assert!(matches!(error.code, ErrorCode::InvalidRequest), "{result}");
        }
    }

    #[test]
    fn the_limit_counts_utf8_bytes() {
        let largest = "a".repeat(MAX_CONTENT_BYTES);
        assert!(decode_content_command(json!({ "result": largest })).is_ok());

        // Two bytes per character: half as many characters already exceed it.
        let too_large = "é".repeat(MAX_CONTENT_BYTES / 2 + 1);
        assert!(decode_content_command(json!({ "result": too_large })).is_err());
    }
}
