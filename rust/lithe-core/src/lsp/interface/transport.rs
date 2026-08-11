use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

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

    while let Some(header_end) = find_header_end(&buffer) {
        let header = String::from_utf8_lossy(&buffer[..header_end]);
        let Some(content_length) = content_length_from_header(&header) else {
            buffer.drain(..header_end + 4);
            continue;
        };
        let body_start = header_end + 4;
        let body_end = body_start + content_length;
        if buffer.len() < body_end {
            break;
        }
        let body = buffer[body_start..body_end].to_vec();
        buffer.drain(..body_end);
        if let Ok(message) = String::from_utf8(body) {
            messages.push(message);
        }
    }

    Ok(ParseServerMessagesResponse { buffer, messages })
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn content_length_from_header(header: &str) -> Option<usize> {
    header.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name.trim().eq_ignore_ascii_case("content-length") {
            value.trim().parse().ok()
        } else {
            None
        }
    })
}
