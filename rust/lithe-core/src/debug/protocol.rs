//! Bounded DAP framing and JSON message helpers independent of native transport.

use crate::protocol::{CoreError, ErrorCode};
use serde_json::Value;

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

pub(crate) fn frame_message(message: &Value) -> Result<Vec<u8>, CoreError> {
    let body = serde_json::to_vec(message).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Could not encode DAP message.")
            .with_details(error.to_string())
    })?;
    let mut frame = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    frame.extend(body);
    Ok(frame)
}

pub(crate) fn parse_messages(buffer: &mut Vec<u8>, chunk: &[u8]) -> Result<Vec<Value>, CoreError> {
    buffer.extend_from_slice(chunk);
    let mut messages = Vec::new();
    loop {
        let Some(header_end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") else {
            if buffer.len() > MAX_HEADER_BYTES {
                return Err(protocol_error("DAP header exceeded the maximum size."));
            }
            break;
        };
        if header_end > MAX_HEADER_BYTES {
            return Err(protocol_error("DAP header exceeded the maximum size."));
        }
        let header = String::from_utf8_lossy(&buffer[..header_end]);
        let content_length = content_length(&header)?;
        if content_length > MAX_MESSAGE_BYTES {
            return Err(protocol_error("DAP message exceeded the maximum size."));
        }
        let body_start = header_end + 4;
        let body_end = body_start
            .checked_add(content_length)
            .ok_or_else(|| protocol_error("DAP Content-Length overflowed."))?;
        if buffer.len() < body_end {
            break;
        }
        let body = &buffer[body_start..body_end];
        let message = serde_json::from_slice(body).map_err(|error| {
            protocol_error("DAP message body was not valid JSON.").with_details(error.to_string())
        })?;
        messages.push(message);
        buffer.drain(..body_end);
    }
    Ok(messages)
}

fn content_length(header: &str) -> Result<usize, CoreError> {
    let value = header.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("content-length")
            .then_some(value.trim())
    });
    value
        .ok_or_else(|| protocol_error("DAP frame did not contain Content-Length."))?
        .parse::<usize>()
        .map_err(|error| {
            protocol_error("DAP Content-Length was not a valid non-negative integer.")
                .with_details(error.to_string())
        })
}

fn protocol_error(message: &str) -> CoreError {
    CoreError::new(ErrorCode::ParseFailed, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn partial_and_consecutive_frames_are_parsed_in_order() {
        let first = frame_message(&json!({"type": "event", "event": "initialized"})).unwrap();
        let second = frame_message(&json!({"type": "event", "event": "terminated"})).unwrap();
        let split = first.len() / 2;
        let mut buffer = Vec::new();
        assert!(parse_messages(&mut buffer, &first[..split])
            .unwrap()
            .is_empty());
        let mut remainder = first[split..].to_vec();
        remainder.extend(second);

        let messages = parse_messages(&mut buffer, &remainder).unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["event"], "initialized");
        assert_eq!(messages[1]["event"], "terminated");
        assert!(buffer.is_empty());
    }

    #[test]
    fn malformed_content_length_is_rejected() {
        let mut buffer = Vec::new();
        let result = parse_messages(&mut buffer, b"Content-Length: nope\r\n\r\n{}");
        assert!(result.is_err());
    }
}
