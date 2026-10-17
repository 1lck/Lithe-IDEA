//! Offset-based JSON editing that preserves every byte outside the targeted
//! `mcpServers` entry.
//!
//! Configuration files may contain unrelated settings, large state objects and
//! formatting the user maintains by hand. Re-serializing the whole document
//! would reorder keys and drop formatting, so this editor locates the exact
//! value span and splices only that range. Inputs with comments or other
//! non-strict JSON are rejected rather than rewritten.

use crate::protocol::{CoreError, ErrorCode};

type Result<T> = std::result::Result<T, CoreError>;

fn edit_error() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "MCP configuration is not editable JSON",
    )
}

/// JSON parsers keep the last of repeated keys, while an offset editor sees the
/// first. Refusing the edit is safer than guessing which definition the Agent
/// actually uses.
fn duplicate_key_error() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "MCP configuration contains duplicate keys",
    )
}

struct Member {
    key: String,
    key_start: usize,
    value_start: usize,
    value_end: usize,
}

/// A validated JSON object document addressed by byte offsets.
pub(crate) struct JsonDocument {
    text: String,
}

impl JsonDocument {
    /// Parses strict JSON and requires an object at the root.
    pub(crate) fn parse(content: &str) -> Result<Self> {
        serde_json::from_str::<serde_json::Value>(content).map_err(|_| edit_error())?;
        let bytes = content.as_bytes();
        let open = skip_ws(bytes, 0);
        if bytes.get(open) != Some(&b'{') {
            return Err(edit_error());
        }
        let close = value_end(bytes, open)?;
        if skip_ws(bytes, close) != bytes.len() {
            return Err(edit_error());
        }
        Ok(Self {
            text: content.to_string(),
        })
    }

    /// Returns the finished document text after re-validating it.
    ///
    /// Every splice is local, but a wrong comma or offset would still produce
    /// a file Claude Code can no longer parse. Refusing the plan is safer than
    /// writing broken configuration.
    pub(crate) fn into_string(self) -> Result<String> {
        serde_json::from_str::<serde_json::Value>(&self.text).map_err(|_| edit_error())?;
        Ok(self.text)
    }

    /// Ensures every object in `path` exists, creating empty objects as needed,
    /// and returns the byte offset of the deepest object's opening brace.
    pub(crate) fn ensure_object(&mut self, path: &[&str]) -> Result<usize> {
        let mut open = skip_ws(self.text.as_bytes(), 0);
        for key in path {
            let member = match self.find_member(open, key)? {
                Some(member) => member,
                None => {
                    self.insert_member(open, key, "{}")?;
                    self.find_member(open, key)?.ok_or_else(edit_error)?
                }
            };
            if self.text.as_bytes().get(member.value_start) != Some(&b'{') {
                return Err(edit_error());
            }
            open = member.value_start;
        }
        Ok(open)
    }

    /// Returns the deepest existing object in `path` without creating anything.
    pub(crate) fn object_at(&self, path: &[&str]) -> Result<Option<usize>> {
        let mut open = skip_ws(self.text.as_bytes(), 0);
        for key in path {
            let Some(member) = self.find_member(open, key)? else {
                return Ok(None);
            };
            if self.text.as_bytes().get(member.value_start) != Some(&b'{') {
                return Ok(None);
            }
            open = member.value_start;
        }
        Ok(Some(open))
    }

    /// Returns the raw text of `key`'s value in the object at `open`.
    pub(crate) fn member_value(&self, open: usize, key: &str) -> Result<Option<String>> {
        Ok(self
            .find_member(open, key)?
            .map(|member| self.text[member.value_start..member.value_end].to_string()))
    }

    /// Inserts or replaces the member `key` in the object at `open`.
    pub(crate) fn set_member(&mut self, open: usize, key: &str, value_json: &str) -> Result<()> {
        match self.find_member(open, key)? {
            Some(member) => {
                self.text
                    .replace_range(member.value_start..member.value_end, value_json);
                Ok(())
            }
            None => self.insert_member(open, key, value_json),
        }
    }

    /// Removes `key` from the object at `open`, returning whether it existed.
    pub(crate) fn remove_member(&mut self, open: usize, key: &str) -> Result<bool> {
        let members = self.members(open)?;
        let Some(index) = members.iter().position(|member| member.key == key) else {
            return Ok(false);
        };
        let member = &members[index];
        if let Some(next) = members.get(index + 1) {
            // Delete exactly the member and the separator up to the next key.
            // Extending to the line start would remove a neighbouring entry
            // that shares the line, and a previous entry's comma must stay to
            // separate it from the next member.
            self.text
                .replace_range(member.key_start..next.key_start, "");
        } else if let Some(previous) = index.checked_sub(1).map(|index| &members[index]) {
            // Removing the last member must also remove the comma that
            // separates it from the previous member. Deleting only the last
            // member's line would leave `previous,` and therefore invalid JSON.
            self.text
                .replace_range(previous.value_end..member.value_end, "");
        } else {
            self.text
                .replace_range(member.key_start..member.value_end, "");
        }
        Ok(true)
    }

    fn insert_member(&mut self, open: usize, key: &str, value_json: &str) -> Result<()> {
        let key_json = serde_json::to_string(key).map_err(|_| edit_error())?;
        let members = self.members(open)?;
        if let Some(last) = members.last() {
            let indent = self.member_indent(open, &members);
            let block = format!(",\n{indent}{key_json}: {value_json}");
            self.text.insert_str(last.value_end, &block);
        } else {
            let close = object_close(self.text.as_bytes(), open)?;
            let parent_indent = line_indent(&self.text, open).unwrap_or("");
            let indent = format!("{parent_indent}  ");
            let block = format!("\n{indent}{key_json}: {value_json}\n{parent_indent}");
            self.text.insert_str(close, &block);
        }
        Ok(())
    }

    fn member_indent(&self, open: usize, members: &[Member]) -> String {
        let first = &members[0];
        if let Some(indent) = line_indent(&self.text, first.key_start) {
            return indent.to_string();
        }
        let parent = line_indent(&self.text, open).unwrap_or("");
        format!("{parent}  ")
    }

    fn find_member(&self, open: usize, key: &str) -> Result<Option<Member>> {
        Ok(self
            .members(open)?
            .into_iter()
            .find(|member| member.key == key))
    }

    fn members(&self, open: usize) -> Result<Vec<Member>> {
        let bytes = self.text.as_bytes();
        if bytes.get(open) != Some(&b'{') {
            return Err(edit_error());
        }
        let mut members = Vec::new();
        let mut index = skip_ws(bytes, open + 1);
        loop {
            match bytes.get(index) {
                Some(b'}') => return Ok(members),
                Some(b'"') => {
                    let key_start = index;
                    let key_end = string_end(bytes, index)?;
                    let key: String = serde_json::from_str(&self.text[key_start..key_end])
                        .map_err(|_| edit_error())?;
                    if members.iter().any(|member| member.key == key) {
                        return Err(duplicate_key_error());
                    }
                    index = skip_ws(bytes, key_end);
                    if bytes.get(index) != Some(&b':') {
                        return Err(edit_error());
                    }
                    let value_start = skip_ws(bytes, index + 1);
                    let value_end = value_end(bytes, value_start)?;
                    members.push(Member {
                        key,
                        key_start,
                        value_start,
                        value_end,
                    });
                    index = skip_ws(bytes, value_end);
                    match bytes.get(index) {
                        Some(b',') => index = skip_ws(bytes, index + 1),
                        Some(b'}') => return Ok(members),
                        _ => return Err(edit_error()),
                    }
                }
                _ => return Err(edit_error()),
            }
        }
    }
}

fn skip_ws(bytes: &[u8], mut index: usize) -> usize {
    while matches!(bytes.get(index), Some(b' ' | b'\t' | b'\n' | b'\r')) {
        index += 1;
    }
    index
}

fn string_end(bytes: &[u8], start: usize) -> Result<usize> {
    if bytes.get(start) != Some(&b'"') {
        return Err(edit_error());
    }
    let mut index = start + 1;
    while let Some(byte) = bytes.get(index) {
        match byte {
            b'\\' => index += 2,
            b'"' => return Ok(index + 1),
            _ => index += 1,
        }
    }
    Err(edit_error())
}

fn value_end(bytes: &[u8], start: usize) -> Result<usize> {
    match bytes.get(start) {
        Some(b'"') => string_end(bytes, start),
        Some(b'{') => object_close(bytes, start).map(|close| close + 1),
        Some(b'[') => array_close(bytes, start).map(|close| close + 1),
        Some(b't') if bytes[start..].starts_with(b"true") => Ok(start + 4),
        Some(b'f') if bytes[start..].starts_with(b"false") => Ok(start + 5),
        Some(b'n') if bytes[start..].starts_with(b"null") => Ok(start + 4),
        Some(b'-' | b'0'..=b'9') => {
            let mut index = start + 1;
            while matches!(
                bytes.get(index),
                Some(b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-')
            ) {
                index += 1;
            }
            Ok(index)
        }
        _ => Err(edit_error()),
    }
}

fn object_close(bytes: &[u8], open: usize) -> Result<usize> {
    let mut index = skip_ws(bytes, open + 1);
    loop {
        match bytes.get(index) {
            Some(b'}') => return Ok(index),
            Some(b'"') => {
                index = skip_ws(bytes, string_end(bytes, index)?);
                if bytes.get(index) != Some(&b':') {
                    return Err(edit_error());
                }
                index = skip_ws(bytes, index + 1);
                index = skip_ws(bytes, value_end(bytes, index)?);
                match bytes.get(index) {
                    Some(b',') => index = skip_ws(bytes, index + 1),
                    Some(b'}') => return Ok(index),
                    _ => return Err(edit_error()),
                }
            }
            _ => return Err(edit_error()),
        }
    }
}

fn array_close(bytes: &[u8], open: usize) -> Result<usize> {
    let mut index = skip_ws(bytes, open + 1);
    loop {
        match bytes.get(index) {
            Some(b']') => return Ok(index),
            Some(_) => {
                index = skip_ws(bytes, value_end(bytes, index)?);
                match bytes.get(index) {
                    Some(b',') => index = skip_ws(bytes, index + 1),
                    Some(b']') => return Ok(index),
                    _ => return Err(edit_error()),
                }
            }
            None => return Err(edit_error()),
        }
    }
}

fn line_start(text: &str, offset: usize) -> usize {
    text[..offset].rfind('\n').map_or(0, |index| index + 1)
}

fn line_indent(text: &str, offset: usize) -> Option<&str> {
    let start = line_start(text, offset);
    let indent = &text[start..offset];
    indent
        .chars()
        .all(|character| character == ' ' || character == '\t')
        .then_some(indent)
}
