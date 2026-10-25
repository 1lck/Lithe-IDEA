//! Convert prompt inputs and completion responses at the upstream ACP boundary.

use agent_client_protocol::schema::v1::{ContentBlock, PromptResponse, ResourceLink, TextContent};
use serde::Deserialize;

/// Bound one message's references without reading or allocating file contents.
const MAXIMUM_FILES: usize = 32;

pub(crate) fn finished(session_id: String, response: PromptResponse) -> crate::AgentEvent {
    crate::AgentEvent::TurnFinished {
        session_id,
        stop_reason: crate::stop_reason_name(&response.stop_reason),
        // Preserve upstream accounting rather than deriving usage from context occupancy.
        usage: response.usage,
    }
}

#[derive(Debug, Deserialize)]
pub struct PromptFile {
    pub uri: String,
    pub name: String,
}

pub(crate) fn content(text: String, files: Vec<PromptFile>) -> Result<Vec<ContentBlock>, String> {
    if files.len() > MAXIMUM_FILES {
        return Err("Attach up to 32 files per message.".into());
    }
    let text_is_command = text.trim_start().starts_with('/');
    let mut content = Vec::with_capacity(files.len() + 1);
    if !text.trim().is_empty() {
        content.push(ContentBlock::Text(TextContent::new(text)));
    }
    // Paths a model cannot read back from the percent-encoded link, one per line.
    let mut decoded_paths = Vec::new();
    for file in files {
        let uri = url::Url::parse(&file.uri)
            .map_err(|_| "Only local files can be attached to an Agent message.".to_string())?;
        let local_file = uri.scheme() == "file"
            && uri
                .host_str()
                .is_none_or(|host| host.eq_ignore_ascii_case("localhost"))
            && !uri.path().is_empty()
            && uri.query().is_none()
            && uri.fragment().is_none();
        if !local_file || file.name.trim().is_empty() {
            return Err("Only local files can be attached to an Agent message.".into());
        }
        // Adapters hand the link to the model verbatim, and a model that reads
        // `Pasted%20image.png` literally fails to open the file. Repeat the real
        // path in the `📎 /path` form the transcript already recognises and hides.
        if uri.path().contains('%') {
            if let Ok(path) = uri.to_file_path() {
                decoded_paths.push(format!("📎 {}", path.display()));
            }
        }
        content.push(ContentBlock::ResourceLink(ResourceLink::new(
            file.name, file.uri,
        )));
    }
    // A native slash command must reach the adapter exactly as typed.
    if !decoded_paths.is_empty() && !text_is_command {
        content.push(ContentBlock::Text(TextContent::new(
            decoded_paths.join("\n"),
        )));
    }
    if content.is_empty() {
        return Err("Write a message or attach a file.".into());
    }
    Ok(content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optional_usage_never_prevents_a_turn_from_finishing() {
        for usage in [
            serde_json::Value::Null,
            serde_json::json!({ "totalTokens": -1, "inputTokens": 1, "outputTokens": 1 }),
            serde_json::json!({ "inputTokens": 1 }),
        ] {
            let response = serde_json::from_value(serde_json::json!({
                "stopReason": "cancelled", "usage": usage
            }))
            .unwrap();
            let event = serde_json::to_value(finished("session-1".into(), response)).unwrap();
            assert_eq!(event["stopReason"], "cancelled");
            assert!(event.get("usage").is_none());
        }
        let response = serde_json::from_value(serde_json::json!({
            "stopReason": "end_turn",
            "usage": { "totalTokens": 0, "inputTokens": 0, "outputTokens": 0 }
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(finished("session-1".into(), response)).unwrap()["usage"],
            serde_json::json!({ "totalTokens": 0, "inputTokens": 0, "outputTokens": 0 })
        );
    }

    #[test]
    fn accepts_local_file_uris_without_host_platform_assumptions() {
        let content = content(
            String::new(),
            vec![PromptFile {
                uri: "file:///example/project/README.md".into(),
                name: "README.md".into(),
            }],
        )
        .expect("local file URI");
        assert!(matches!(
            content.as_slice(),
            [ContentBlock::ResourceLink(_)]
        ));
    }

    #[test]
    fn rejects_remote_or_qualified_file_uris() {
        for uri in [
            "file://server/share/README.md",
            "file:///example/project/README.md?secret",
            "file:///example/project/README.md#section",
        ] {
            assert!(content(
                String::new(),
                vec![PromptFile {
                    uri: uri.into(),
                    name: "README.md".into(),
                }]
            )
            .is_err());
        }
    }

    #[test]
    fn encoded_paths_are_repeated_in_readable_form_for_the_model() {
        let content = content(
            "see this".into(),
            vec![
                PromptFile {
                    uri: "file:///example/Pasted%20image%201.png".into(),
                    name: "Pasted image 1.png".into(),
                },
                PromptFile {
                    uri: "file:///example/plain.png".into(),
                    name: "plain.png".into(),
                },
            ],
        )
        .expect("local file URIs");
        let ContentBlock::Text(text) = content.last().expect("path block") else {
            panic!("the readable paths follow the links as text");
        };
        // Only the encoded path needs repeating; a plain path is already readable.
        assert_eq!(text.text, "📎 /example/Pasted image 1.png");
        assert_eq!(content.len(), 4);
    }

    #[test]
    fn native_slash_commands_are_never_followed_by_extra_text() {
        let content = content(
            "/status".into(),
            vec![PromptFile {
                uri: "file:///example/Pasted%20image.png".into(),
                name: "Pasted image.png".into(),
            }],
        )
        .expect("local file URI");
        assert!(matches!(
            content.as_slice(),
            [ContentBlock::Text(_), ContentBlock::ResourceLink(_)]
        ));
    }
}
