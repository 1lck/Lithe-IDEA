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
        if uri.scheme() != "file"
            || uri.query().is_some()
            || uri.fragment().is_some()
            || uri.to_file_path().is_err()
            || file.name.trim().is_empty()
        {
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
