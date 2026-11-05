//! Typed Git remote, tag and bounded checkout-metadata interpretation.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Deserialize)]
struct RootRequest {
    root: String,
}

#[derive(Deserialize)]
struct TextRequest {
    text: String,
}

/// Returns typed, deterministic metadata without exposing command output parsing to hosts.
pub(crate) fn command(operation: &str, payload: Value) -> Result<Value, CoreError> {
    if matches!(operation, "checkout" | "gitdir") {
        let request: TextRequest = serde_json::from_value(payload).map_err(invalid_request)?;
        if request.text.len() > 4096 {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git metadata exceeds the supported size",
            ));
        }
        let text = request.text.trim();
        return if operation == "checkout" {
            let branch = if let Some(reference) = text.strip_prefix("ref: ") {
                reference.strip_prefix("refs/heads/").map(str::to_owned)
            } else if text.is_empty() {
                None
            } else {
                Some(text.chars().take(8).collect::<String>())
            };
            Ok(json!({"branch": branch}))
        } else {
            let path = text
                .strip_prefix("gitdir:")
                .map(str::trim)
                .filter(|value| !value.is_empty());
            Ok(json!({"path": path}))
        };
    }
    let request: RootRequest = serde_json::from_value(payload).map_err(invalid_request)?;
    let root = super::validate_root(&request.root)?;
    match operation {
        "remotes" => {
            let output = git_output(&root, &["remote", "-v"])?;
            let mut remotes = BTreeMap::new();
            for line in output.lines() {
                if let Some(fetch) = line.strip_suffix(" (fetch)") {
                    let (name, url) = fetch.split_once('\t').ok_or_else(invalid_output)?;
                    remotes.insert(name.to_owned(), url.to_owned());
                }
            }
            Ok(
                json!({"remotes": remotes.into_iter().map(|(name,url)| json!({"name": name,"url": url})).collect::<Vec<_>>()}),
            )
        }
        "tags" => {
            let output = git_output(&root, &[
                "for-each-ref", "--sort=refname", "--sort=-creatordate",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(contents:subject)%00%(creatordate:iso-strict)%00%(objecttype)%00",
                "refs/tags",
            ])?;
            let mut fields = output.split('\0');
            let mut tags = Vec::new();
            while let Some(raw_name) = fields.next() {
                let raw_name = raw_name.trim_start_matches(['\r', '\n']);
                if raw_name.is_empty() {
                    break;
                }
                let name = raw_name
                    .strip_prefix("refs/tags/")
                    .ok_or_else(invalid_output)?;
                let object = fields.next().ok_or_else(invalid_output)?;
                let peeled = fields.next().ok_or_else(invalid_output)?;
                let subject = fields.next().ok_or_else(invalid_output)?;
                let date = fields.next().ok_or_else(invalid_output)?;
                let kind = fields.next().ok_or_else(invalid_output)?;
                tags.push(json!({"name": name, "objectId": object,
                    "targetId": if peeled.is_empty() { object } else { peeled },
                    "message": if subject.is_empty() { None } else { Some(subject) },
                    "date": date, "isAnnotated": kind == "tag"}));
            }
            Ok(json!({"tags": tags}))
        }
        _ => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Unknown Git catalog operation",
        )),
    }
}

fn git_output(root: &str, arguments: &[&str]) -> Result<String, CoreError> {
    let arguments = arguments
        .iter()
        .map(|argument| (*argument).to_owned())
        .collect::<Vec<_>>();
    let output = super::capture_git_with_options(root, &arguments, None, true)?;
    if output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git catalog query failed")
                .with_details(String::from_utf8_lossy(&output.stderr).to_string()),
        );
    }
    String::from_utf8(output.stdout).map_err(|_| invalid_output())
}

fn invalid_request(error: serde_json::Error) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git catalog request")
        .with_details(error.to_string())
}

fn invalid_output() -> CoreError {
    CoreError::new(ErrorCode::ParseFailed, "Invalid Git catalog output")
}
