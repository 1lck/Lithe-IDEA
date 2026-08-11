use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameMessageRequest {
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameMessageResponse {
    pub frame: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParseServerMessagesRequest {
    #[serde(default)]
    pub buffer: Vec<u8>,
    #[serde(default)]
    pub chunk: Vec<u8>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParseServerMessagesResponse {
    pub buffer: Vec<u8>,
    pub messages: Vec<String>,
}
pub fn frame_message(request: FrameMessageRequest) -> Result<FrameMessageResponse, CoreError> {
    if request.message.contains('\0') {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "LSP message frame cannot contain NUL bytes.",
        ));
    }
    Ok(FrameMessageResponse {
        frame: format!(
            "Content-Length: {}\r\n\r\n{}",
            request.message.len(),
            request.message
        ),
    })
}

pub fn parse_server_messages(
    request: ParseServerMessagesRequest,
) -> Result<ParseServerMessagesResponse, CoreError> {
    let mut buffer = request.buffer;
    buffer.extend(request.chunk);
    let mut messages = Vec::new();

    loop {
        let Some(header_end) = find_header_end(&buffer) else {
            if buffer.len() > MAX_HEADER_BYTES {
                return Err(transport_error("LSP header exceeded the maximum size."));
            }
            break;
        };
        if header_end > MAX_HEADER_BYTES {
            return Err(transport_error("LSP header exceeded the maximum size."));
        }
        let header = String::from_utf8_lossy(&buffer[..header_end]);
        let content_length = content_length_from_header(&header)?;
        if content_length > MAX_MESSAGE_BYTES {
            return Err(transport_error("LSP message exceeded the maximum size."));
        }
        let body_start = header_end + 4;
        let body_end = body_start
            .checked_add(content_length)
            .ok_or_else(|| transport_error("LSP Content-Length overflowed."))?;
        if buffer.len() < body_end {
            break;
        }
        let body = buffer[body_start..body_end].to_vec();
        buffer.drain(..body_end);
        let message = String::from_utf8(body).map_err(|error| {
            transport_error("LSP message body was not valid UTF-8.").with_details(error.to_string())
        })?;
        messages.push(message);
    }

    Ok(ParseServerMessagesResponse { buffer, messages })
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn content_length_from_header(header: &str) -> Result<usize, CoreError> {
    let value = header.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name.trim().eq_ignore_ascii_case("content-length") {
            Some(value.trim())
        } else {
            None
        }
    });
    let Some(value) = value else {
        return Err(transport_error("LSP frame did not contain Content-Length."));
    };
    value.parse::<usize>().map_err(|error| {
        transport_error("LSP Content-Length was not a valid non-negative integer.")
            .with_details(error.to_string())
    })
}

fn transport_error(message: &str) -> CoreError {
    CoreError::new(ErrorCode::ParseFailed, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_content_length_is_a_transport_error() {
        let missing = parse_server_messages(ParseServerMessagesRequest {
            buffer: Vec::new(),
            chunk: b"Content-Type: application/json\r\n\r\n{}".to_vec(),
        });
        assert!(missing.is_err());

        let invalid = parse_server_messages(ParseServerMessagesRequest {
            buffer: Vec::new(),
            chunk: b"Content-Length: nope\r\n\r\n{}".to_vec(),
        });
        assert!(invalid.is_err());
    }

    #[test]
    fn invalid_utf8_body_is_a_transport_error() {
        let result = parse_server_messages(ParseServerMessagesRequest {
            buffer: Vec::new(),
            chunk: b"Content-Length: 1\r\n\r\n\xff".to_vec(),
        });
        assert!(result.is_err());
    }
}
