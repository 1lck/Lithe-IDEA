//! Convert user-selected native file references to the upstream ACP content types.

use agent_client_protocol::schema::v1::{ContentBlock, ResourceLink, TextContent};
use serde::Deserialize;

/// Bound one message's references without reading or allocating file contents.
const MAXIMUM_FILES: usize = 32;

#[derive(Debug, Deserialize)]
pub struct PromptFile {
    pub uri: String,
    pub name: String,
}

pub(crate) fn content(text: String, files: Vec<PromptFile>) -> Result<Vec<ContentBlock>, String> {
    if files.len() > MAXIMUM_FILES {
        return Err("Attach up to 32 files per message.".into());
    }
    let mut content = Vec::with_capacity(files.len() + 1);
    if !text.trim().is_empty() {
        content.push(ContentBlock::Text(TextContent::new(text)));
    }
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
        content.push(ContentBlock::ResourceLink(ResourceLink::new(
            file.name, file.uri,
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
}
