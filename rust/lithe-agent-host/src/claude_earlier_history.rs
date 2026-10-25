//! Transcript segments that Claude Code compaction hides from `session/load`.
//!
//! The Claude Agent SDK replays only the active parent chain. A compaction
//! boundary has no parent, so everything before the latest boundary is on disk
//! but never reaches the client. This module reads those earlier segments from
//! the account's project transcript, read-only and bounded, and renders them as
//! the same ACP updates a replay would carry. The adapter's own replay then
//! continues from the latest boundary, so nothing is shown twice.
//!
//! Only `<config dir>/projects/*/<session id>.jsonl` is opened. Credentials and
//! the rest of the account directory stay untouched, and nothing is written.

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

/// Larger transcripts are skipped rather than read: the recap alone is shown.
const MAX_TRANSCRIPT_BYTES: u64 = 128 * 1024 * 1024;
/// Upper bound on emitted updates, keeping the replay event queue bounded.
const MAX_UPDATES: usize = 30_000;
/// Per-field text limit, in characters, for tool output and tool input values.
const TEXT_LIMIT: usize = 4_000;
/// Longest base64 image replayed, in bytes: the client's 10 MB decoded limit
/// (`AgentImage.maximumBytes`) inflated by a third. A larger screenshot would only
/// be dropped on arrival, so it is not sent.
const IMAGE_DATA_LIMIT: usize = 10_000_000 / 3 * 4;

/// Projects directory of the account the adapter runs under: the explicit
/// account directory, then `CLAUDE_CONFIG_DIR`, then `~/.claude`.
pub(crate) fn projects_directory(config_dir: Option<&Path>) -> Option<PathBuf> {
    let base = match config_dir {
        Some(directory) => directory.to_path_buf(),
        None => match std::env::var_os("CLAUDE_CONFIG_DIR").filter(|v| !v.is_empty()) {
            Some(directory) => PathBuf::from(directory),
            None => PathBuf::from(std::env::var_os(if cfg!(windows) {
                "USERPROFILE"
            } else {
                "HOME"
            })?)
            .join(".claude"),
        },
    };
    base.is_absolute().then(|| base.join("projects"))
}

/// Updates for every transcript row before the latest compaction boundary, in
/// order. Empty when the session was never compacted or the file is unusable.
pub(crate) fn earlier_updates(projects: &Path, cwd: &Path, session_id: &str) -> Vec<Value> {
    // The id becomes a file name, so anything but a plain identifier is refused.
    if session_id.is_empty()
        || !session_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Vec::new();
    }
    let Some(path) = locate(projects, cwd, session_id) else {
        return Vec::new();
    };
    let Some(boundary) = last_boundary_line(&path) else {
        return Vec::new();
    };
    let Ok(file) = File::open(&path) else {
        return Vec::new();
    };
    let mut converter = Converter::default();
    for line in BufReader::new(file).lines().take(boundary) {
        let Ok(line) = line else { break };
        if let Ok(row) = serde_json::from_str::<Value>(&line) {
            converter.row(&row);
        }
        if converter.updates.len() >= MAX_UPDATES {
            break;
        }
    }
    converter.updates
}

/// Claude names a project directory after its workspace with every character
/// outside `[A-Za-z0-9]` replaced by `-`; other directories are searched when
/// that name does not match, for example after Claude shortens a long path.
fn locate(projects: &Path, cwd: &Path, session_id: &str) -> Option<PathBuf> {
    let name = format!("{session_id}.jsonl");
    let encoded: String = cwd
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let direct = projects.join(encoded).join(&name);
    let found = if direct.is_file() {
        Some(direct)
    } else {
        std::fs::read_dir(projects)
            .ok()?
            .filter_map(Result::ok)
            .map(|entry| entry.path().join(&name))
            .find(|candidate| candidate.is_file())
    }?;
    (found.metadata().ok()?.len() <= MAX_TRANSCRIPT_BYTES).then_some(found)
}

/// Zero-based line of the latest `compact_boundary` record.
fn last_boundary_line(path: &Path) -> Option<usize> {
    let mut latest = None;
    for (index, line) in BufReader::new(File::open(path).ok()?).lines().enumerate() {
        let Ok(line) = line else { break };
        // Cheap substring test first; most rows are never parsed.
        if !line.contains("compact_boundary") {
            continue;
        }
        if let Ok(row) = serde_json::from_str::<Value>(&line) {
            if row["type"] == "system" && row["subtype"] == "compact_boundary" {
                latest = Some(index);
            }
        }
    }
    latest
}

/// Which kind of text chunk was emitted last, so a new chunk of the same kind
/// starts a new paragraph instead of fusing with the previous message.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Chunk {
    User,
    Agent,
    Thought,
}

#[derive(Default)]
struct Converter {
    updates: Vec<Value>,
    last: Option<Chunk>,
    /// `uuid` of the row being converted; stamps user chunks so the client can
    /// tell consecutive user messages apart, as the adapter's own replay does.
    row_id: Option<String>,
}

impl Converter {
    fn row(&mut self, row: &Value) {
        // Subagent sidechains and meta rows (hooks, reminders) are not conversation.
        if row["isSidechain"] == true || row["isMeta"] == true {
            return;
        }
        self.row_id = row["uuid"].as_str().map(str::to_owned);
        let role = match row["type"].as_str() {
            Some("user") => Chunk::User,
            Some("assistant") => Chunk::Agent,
            // A prompt sent while a turn was running is stored only as this
            // attachment, never as a user row, so it is the message itself.
            Some("attachment") if row["attachment"]["type"] == "queued_command" => {
                return self.content(Chunk::User, &row["attachment"]["prompt"]);
            }
            _ => return,
        };
        // API error stand-ins are synthesized by the CLI, not model output.
        if row["message"]["model"] == "<synthetic>" {
            return;
        }
        self.content(role, &row["message"]["content"]);
    }

    fn content(&mut self, role: Chunk, content: &Value) {
        match content {
            Value::String(text) if role == Chunk::User => self.text(Chunk::User, text),
            Value::Array(blocks) => {
                for block in blocks {
                    self.block(role, block);
                }
            }
            _ => {}
        }
    }

    fn block(&mut self, role: Chunk, block: &Value) {
        match (role, block["type"].as_str()) {
            (Chunk::User, Some("text")) => {
                self.text(Chunk::User, block["text"].as_str().unwrap_or(""))
            }
            (Chunk::Agent, Some("text")) => {
                self.text(Chunk::Agent, block["text"].as_str().unwrap_or(""))
            }
            (Chunk::Agent, Some("thinking")) => {
                self.text(Chunk::Thought, block["thinking"].as_str().unwrap_or(""))
            }
            (Chunk::Agent, Some("tool_use")) => self.tool_call(block),
            (Chunk::User, Some("tool_result")) => self.tool_result(block),
            (Chunk::User, Some("image")) => self.user_image(block),
            _ => {}
        }
    }

    /// A pasted screenshot stays attached to the user message that references
    /// it. Only inline base64 sources are replayed; the client bounds the size.
    fn user_image(&mut self, block: &Value) {
        let source = &block["source"];
        let (Some("base64"), Some(data)) = (source["type"].as_str(), source["data"].as_str())
        else {
            return;
        };
        if data.is_empty() || data.len() > IMAGE_DATA_LIMIT {
            return;
        }
        self.last = Some(Chunk::User);
        let mut update = json!({
            "sessionUpdate": "user_message_chunk",
            "content": {
                "type": "image",
                "data": data,
                "mimeType": source["media_type"].as_str().unwrap_or("image/png"),
            },
        });
        if let Some(id) = &self.row_id {
            update["messageId"] = json!(id);
        }
        self.updates.push(update);
    }

    fn text(&mut self, kind: Chunk, text: &str) {
        if text.trim().is_empty() {
            return;
        }
        let name = match kind {
            Chunk::User => "user_message_chunk",
            Chunk::Agent => "agent_message_chunk",
            Chunk::Thought => "agent_thought_chunk",
        };
        // Same-kind chunks of one reply are fused by the client, so a new
        // reply needs a break; user messages are told apart by message id.
        let text = if kind != Chunk::User && self.last == Some(kind) {
            format!("\n\n{text}")
        } else {
            text.to_owned()
        };
        self.last = Some(kind);
        let mut update = json!({"sessionUpdate": name, "content": {"type": "text", "text": text}});
        if let (Chunk::User, Some(id)) = (kind, &self.row_id) {
            update["messageId"] = json!(id);
        }
        self.updates.push(update);
    }

    fn tool_call(&mut self, block: &Value) {
        let Some(id) = block["id"].as_str() else {
            return;
        };
        let name = block["name"].as_str().unwrap_or("Tool");
        let input = &block["input"];
        self.last = None;
        self.updates.push(json!({
            "sessionUpdate": "tool_call",
            "toolCallId": id,
            "name": name,
            "title": title(name, input),
            "kind": kind(name),
            "status": "completed",
            "rawInput": bounded(input),
        }));
    }

    fn tool_result(&mut self, block: &Value) {
        let Some(id) = block["tool_use_id"].as_str() else {
            return;
        };
        let text = match &block["content"] {
            Value::String(text) => text.clone(),
            Value::Array(parts) => parts
                .iter()
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n"),
            _ => String::new(),
        };
        self.last = None;
        let mut update = json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": id,
            "status": if block["is_error"] == true { "failed" } else { "completed" },
        });
        if !text.trim().is_empty() {
            update["content"] =
                json!([{"type": "content", "content": {"type": "text", "text": truncate(&text)}}]);
        }
        self.updates.push(update);
    }
}

/// ACP tool kind of a Claude Code tool, as the adapter classifies them.
fn kind(name: &str) -> &'static str {
    match name {
        "Bash" | "BashOutput" | "KillShell" => "execute",
        "Read" | "NotebookRead" => "read",
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "edit",
        "Grep" | "Glob" => "search",
        "WebFetch" | "WebSearch" => "fetch",
        "Task" | "Agent" | "TodoWrite" => "think",
        _ => "other",
    }
}

/// Row title in the adapter's style: the command or target, not the tool name alone.
fn title(name: &str, input: &Value) -> String {
    let field = |key: &str| input[key].as_str().filter(|v| !v.is_empty());
    let detail = match name {
        "Bash" => field("description").or_else(|| field("command")),
        "Read" | "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => {
            field("file_path").or_else(|| field("notebook_path"))
        }
        "Grep" | "Glob" => field("pattern"),
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        "Task" | "Agent" => field("description"),
        _ => None,
    };
    match detail {
        Some(detail) => {
            let first = detail.lines().next().unwrap_or(detail);
            truncate_to(&format!("{name} {first}"), 200)
        }
        None => name.to_owned(),
    }
}

/// Copy of `value` whose strings are cut to [`TEXT_LIMIT`], so a whole-file
/// `Write` input does not travel through the replay queue.
fn bounded(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(truncate(text)),
        Value::Array(items) => Value::Array(items.iter().map(bounded).collect()),
        Value::Object(map) => {
            Value::Object(map.iter().map(|(k, v)| (k.clone(), bounded(v))).collect())
        }
        other => other.clone(),
    }
}

fn truncate(text: &str) -> String {
    truncate_to(text, TEXT_LIMIT)
}

fn truncate_to(text: &str, limit: usize) -> String {
    match text.char_indices().nth(limit) {
        Some((index, _)) => format!("{}…", &text[..index]),
        None => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Writes `rows` as a transcript under a fresh projects directory and
    /// returns that directory together with the workspace it belongs to.
    fn transcript(rows: &[Value]) -> (tempdir::Dir, PathBuf) {
        let dir = tempdir::Dir::new();
        let cwd = PathBuf::from("/work/my.app");
        let project = dir.path().join("-work-my-app");
        std::fs::create_dir_all(&project).unwrap();
        let mut file = File::create(project.join("abc-1.jsonl")).unwrap();
        for row in rows {
            writeln!(file, "{row}").unwrap();
        }
        (dir, cwd)
    }

    fn user(text: &str) -> Value {
        json!({"type": "user", "uuid": text, "message": {"role": "user", "content": text}})
    }

    fn boundary() -> Value {
        json!({"type": "system", "subtype": "compact_boundary", "parentUuid": null})
    }

    #[test]
    fn replays_only_what_precedes_the_latest_boundary() {
        let (dir, cwd) = transcript(&[
            user("first question"),
            json!({"type": "assistant", "message": {"content": [
                {"type": "thinking", "thinking": "hmm"},
                {"type": "text", "text": "first answer"},
                {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls", "description": "List files"}},
            ]}}),
            json!({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "t1", "content": "a\nb"},
            ]}}),
            boundary(),
            user("This session is being continued from a previous conversation"),
            user("second question"),
            boundary(),
            user("after the last boundary"),
        ]);
        let updates = earlier_updates(dir.path(), &cwd, "abc-1");
        let kinds: Vec<_> = updates
            .iter()
            .map(|u| u["sessionUpdate"].as_str().unwrap())
            .collect();
        assert_eq!(
            kinds,
            [
                "user_message_chunk",
                "agent_thought_chunk",
                "agent_message_chunk",
                "tool_call",
                "tool_call_update",
                "user_message_chunk",
                "user_message_chunk",
            ]
        );
        assert_eq!(updates[3]["title"], "Bash List files");
        assert_eq!(updates[3]["kind"], "execute");
        assert_eq!(updates[4]["content"][0]["content"]["text"], "a\nb");
        // Two user rows in a row must not fuse into one bubble.
        assert_ne!(updates[5]["messageId"], updates[6]["messageId"]);
        assert!(updates[5]["messageId"].is_string());
    }

    #[test]
    fn an_uncompacted_or_unsafe_session_yields_nothing() {
        let (dir, cwd) = transcript(&[user("hi")]);
        assert!(earlier_updates(dir.path(), &cwd, "abc-1").is_empty());
        assert!(earlier_updates(dir.path(), &cwd, "../abc-1").is_empty());
        assert!(earlier_updates(dir.path(), &cwd, "missing").is_empty());
    }

    #[test]
    fn sidechains_meta_rows_and_failed_results_are_classified() {
        let (dir, cwd) = transcript(&[
            json!({"type": "user", "isMeta": true, "message": {"content": "reminder"}}),
            json!({"type": "assistant", "isSidechain": true, "message": {"content": [{"type": "text", "text": "child"}]}}),
            json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t", "name": "Read", "input": {"file_path": "/a/b.rs"}}]}}),
            json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t", "is_error": true, "content": [{"type": "text", "text": "denied"}]}]}}),
            boundary(),
        ]);
        let updates = earlier_updates(dir.path(), &cwd, "abc-1");
        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0]["title"], "Read /a/b.rs");
        assert_eq!(updates[1]["status"], "failed");
    }

    #[test]
    fn prompts_queued_during_a_turn_and_tool_names_are_kept() {
        let (dir, cwd) = transcript(&[
            json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "w", "name": "mcp__ccd_turn__wrap_up", "input": {"recap": "done"}}]}}),
            json!({"type": "attachment", "uuid": "q1", "attachment": {"type": "queued_command", "prompt": "go faster"}}),
            json!({"type": "attachment", "uuid": "r1", "attachment": {"type": "total_tokens_reminder"}}),
            boundary(),
        ]);
        let updates = earlier_updates(dir.path(), &cwd, "abc-1");
        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0]["name"], "mcp__ccd_turn__wrap_up");
        assert_eq!(updates[1]["sessionUpdate"], "user_message_chunk");
        assert_eq!(updates[1]["content"]["text"], "go faster");
        assert_eq!(updates[1]["messageId"], "q1");
    }

    #[test]
    fn pasted_screenshots_stay_on_the_user_message_that_references_them() {
        let (dir, cwd) = transcript(&[
            json!({"type": "user", "uuid": "u1", "message": {"content": [
                {"type": "text", "text": "[Image #1] look"},
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "/9j/4A=="}},
                {"type": "image", "source": {"type": "url", "url": "https://example.test/a.png"}},
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": ""}},
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "A".repeat(IMAGE_DATA_LIMIT + 4)}},
            ]}}),
            boundary(),
        ]);
        let updates = earlier_updates(dir.path(), &cwd, "abc-1");
        assert_eq!(updates.len(), 2, "only the inline base64 image within the limit is replayed");
        assert_eq!(updates[1]["sessionUpdate"], "user_message_chunk");
        assert_eq!(updates[1]["content"]["type"], "image");
        assert_eq!(updates[1]["content"]["data"], "/9j/4A==");
        assert_eq!(updates[1]["content"]["mimeType"], "image/jpeg");
        assert_eq!(updates[1]["messageId"], updates[0]["messageId"]);
    }

    #[test]
    fn long_text_is_cut_on_a_character_boundary() {
        let long = "é".repeat(TEXT_LIMIT + 10);
        let cut = truncate(&long);
        assert_eq!(cut.chars().count(), TEXT_LIMIT + 1);
        assert!(cut.ends_with('…'));
    }

    /// Minimal self-cleaning temporary directory; the crate has no tempfile dependency.
    mod tempdir {
        use std::path::{Path, PathBuf};

        pub struct Dir(PathBuf);

        impl Dir {
            pub fn new() -> Self {
                use std::sync::atomic::{AtomicU32, Ordering};
                static NEXT: AtomicU32 = AtomicU32::new(0);
                let path = std::env::temp_dir().join(format!(
                    "lithe-earlier-history-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ));
                std::fs::create_dir_all(&path).unwrap();
                Self(path)
            }

            pub fn path(&self) -> &Path {
                &self.0
            }
        }

        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }
}
