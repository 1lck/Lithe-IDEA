use serde_json::{json, Map, Value};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[tauri::command]
pub async fn platform_invoke(command: String, args: Value) -> Result<Value, String> {
    let operation_id = args
        .get("operationId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| format!("windows-{}", REQUEST_ID.fetch_add(1, Ordering::Relaxed)));
    let (core_command, payload) = translate(&command, args)?;
    let request = json!({
        "id": operation_id,
        "operationId": operation_id,
        "timeoutMilliseconds": 30_000,
        "command": core_command,
        "payload": payload
    })
    .to_string();

    let response = tauri::async_runtime::spawn_blocking(move || lithe_core::execute_json(&request))
        .await
        .map_err(|error| format!("Shared core task failed: {error}"))?;
    let envelope: Value = serde_json::from_str(&response)
        .map_err(|error| format!("Shared core returned invalid JSON: {error}"))?;

    if envelope.get("ok").and_then(Value::as_bool) == Some(true) {
        let data = envelope.get("data").cloned().unwrap_or(Value::Null);
        if let Some(error) = command_data_error(&data) {
            return Err(error);
        }
        return Ok(data);
    }

    let error = envelope.get("error").unwrap_or(&Value::Null);
    Err(error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Shared core operation failed")
        .to_string())
}

/// Converts logical Git command failures carried in a successful Core envelope
/// into the error shape expected by the existing Windows compatibility API.
fn command_data_error(data: &Value) -> Option<String> {
    if let Some(error) = data.get("operationError") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .filter(|message| !message.trim().is_empty())
            .unwrap_or("Git operation failed")
            .trim();
        let details = error
            .get("details")
            .and_then(Value::as_str)
            .filter(|details| !details.trim().is_empty())
            .map(str::trim);
        return Some(match details {
            Some(details) => format!("{message}: {details}"),
            None => message.to_string(),
        });
    }

    if let Some(stash_restore) = data.get("stashRestore") {
        let paths = stash_restore
            .get("conflictedPaths")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>();
        return Some(if paths.is_empty() {
            "Git stash restore has conflicts".to_string()
        } else {
            format!("Git stash restore has conflicts: {}", paths.join(", "))
        });
    }

    if data.get("exitCode").and_then(Value::as_i64).unwrap_or(0) != 0 {
        return Some(
            data.get("output")
                .and_then(Value::as_str)
                .filter(|output| !output.trim().is_empty())
                .unwrap_or("Git operation failed")
                .trim()
                .to_string(),
        );
    }

    None
}

fn translate(command: &str, args: Value) -> Result<(String, Value), String> {
    let mut payload = args.as_object().cloned().unwrap_or_default();
    move_field(&mut payload, "repoPath", "root");

    let core_command = match command {
        "git_status" => "git.status",
        "git_blame_file" => {
            move_field(&mut payload, "filePath", "path");
            payload.remove("operationId");
            payload.remove("content");
            "git.blame"
        }
        "git_log" | "git_branches" => "git.history",
        "git_get_stashes" => "git.stashes",
        "git_commit_diff" => {
            move_field(&mut payload, "commitHash", "commit");
            payload.insert("pathspecs".into(), json!(["."]));
            "git.diff"
        }
        "git_add" => {
            paths_from_file(&mut payload);
            payload.insert("operation".into(), json!("stage"));
            "git.write"
        }
        "git_add_all" => {
            payload.insert("operation".into(), json!("stageAll"));
            "git.write"
        }
        "git_reset" => {
            paths_from_file(&mut payload);
            payload.insert("operation".into(), json!("unstage"));
            "git.write"
        }
        "git_discard_file_changes" => {
            paths_from_file(&mut payload);
            payload.insert("operation".into(), json!("discard"));
            "git.write"
        }
        "git_discard_all_changes" => {
            payload.insert("operation".into(), json!("discardAll"));
            "git.write"
        }
        "git_commit" => {
            payload.insert("operation".into(), json!("commit"));
            "git.write"
        }
        "git_diff_file" | "git_status_diff_stats" => {
            if let Some(path) = payload.remove("filePath") {
                payload.insert("pathspecs".into(), Value::Array(vec![path]));
            } else {
                // The shared core rejects empty pathspecs; a request without a
                // file scope means the whole tree, which git spells as `.`.
                payload.insert("pathspecs".into(), json!(["."]));
            }
            "git.diff"
        }
        "git_ref_diff" => {
            if payload.contains_key("gitReference") {
                payload.remove("baseRef");
                payload.remove("targetRef");
                payload.remove("reference");
            } else {
                let base = take_text(&mut payload, "baseRef")?;
                let target = take_text(&mut payload, "targetRef")?;
                payload.insert("reference".into(), json!(format!("{base}..{target}")));
            }
            payload.insert("pathspecs".into(), json!(["."]));
            "git.diff"
        }
        "git_working_tree_ref_diff" => {
            preserve_typed_or_legacy_reference(&mut payload, "reference", false)?;
            payload.insert("pathspecs".into(), json!(["."]));
            "git.diff"
        }
        "git_reference_worktree_diff" => {
            let reference = take_reference(&mut payload)?;
            payload.insert("reference".into(), json!(reference));
            payload.insert("pathspecs".into(), json!(["."]));
            payload.insert("untracked".into(), json!(true));
            "git.diff"
        }
        "git_stash_diff" => {
            let index = payload
                .remove("stashIndex")
                .and_then(|value| value.as_u64())
                .unwrap_or(0);
            payload.insert("reference".into(), json!(format!("stash@{{{index}}}")));
            payload.insert("pathspecs".into(), json!(["."]));
            "git.diff"
        }
        "git_create_branch" => {
            move_field(&mut payload, "branchName", "name");
            if !payload.contains_key("gitReference") && !payload.contains_key("reference") {
                if let Some(from_branch) = payload.remove("fromBranch") {
                    let reference = from_branch
                        .as_str()
                        .filter(|value| !value.trim().is_empty())
                        .map(local_branch_reference)
                        .unwrap_or_else(|| "HEAD".to_string());
                    payload.insert("reference".into(), json!(reference));
                }
            } else {
                payload.remove("fromBranch");
            }
            payload.insert("operation".into(), json!("createBranch"));
            if !payload.contains_key("gitReference") {
                payload.entry("reference").or_insert_with(|| json!("HEAD"));
            }
            "git.write"
        }
        "git_delete_branch" => {
            let branch = take_text(&mut payload, "branchName")?;
            payload.insert("reference".into(), json!(local_branch_reference(&branch)));
            payload.insert("operation".into(), json!("deleteBranch"));
            "git.write"
        }
        "git_checkout" | "git_checkout_and_rebase" => {
            let typed = payload.contains_key("gitReference");
            preserve_typed_or_legacy_reference(&mut payload, "branchName", true)?;
            payload.insert(
                "operation".into(),
                json!(if command == "git_checkout" {
                    "checkout"
                } else {
                    "checkoutAndRebase"
                }),
            );
            if !typed {
                let reference = payload
                    .get("reference")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "Windows platform command requires reference".to_string())?;
                let kind = reference_kind(reference);
                payload
                    .entry("referenceKind")
                    .or_insert_with(|| json!(kind));
            }
            "git.write"
        }
        "git_checkout_preflight" => {
            preserve_typed_or_legacy_reference(&mut payload, "branchName", true)?;
            "git.checkoutPreflight"
        }
        "git_merge" | "git_rebase" => {
            preserve_typed_or_legacy_reference(&mut payload, "branchName", true)?;
            payload.insert(
                "operation".into(),
                json!(if command == "git_merge" {
                    "merge"
                } else {
                    "rebase"
                }),
            );
            "git.write"
        }
        "git_integration_preflight" => {
            preserve_typed_or_legacy_reference(&mut payload, "branchName", true)?;
            "git.integrationPreflight"
        }
        "git_operation_state" => "git.operationState",
        "git_operation_continue" | "git_operation_abort" | "git_operation_skip" => {
            let operation = match command {
                "git_operation_continue" => "operationContinue",
                "git_operation_abort" => "operationAbort",
                _ => "operationSkip",
            };
            payload.insert("operation".into(), json!(operation));
            "git.write"
        }
        "git_conflict_markers" => "git.conflictMarkers",
        "git_create_stash" => {
            payload.insert("operation".into(), json!("stashPush"));
            "git.write"
        }
        "git_apply_stash" | "git_pop_stash" | "git_drop_stash" => {
            let index = payload
                .remove("stashIndex")
                .and_then(|value| value.as_u64())
                .unwrap_or(0);
            payload.insert("reference".into(), json!(format!("stash@{{{index}}}")));
            let operation = match command {
                "git_apply_stash" => "stashApply",
                "git_pop_stash" => "stashPop",
                _ => "stashDrop",
            };
            payload.insert("operation".into(), json!(operation));
            "git.write"
        }
        "git_discover_repo" => {
            move_field(&mut payload, "path", "root");
            payload.insert("arguments".into(), json!(["rev-parse", "--show-toplevel"]));
            "git.command"
        }
        "git_fetch" | "git_pull" | "git_push" => {
            payload.insert(
                "operation".into(),
                json!(command.trim_start_matches("git_")),
            );
            "git.write"
        }
        "git_get_remotes" => {
            payload.insert("arguments".into(), json!(["remote", "-v"]));
            "git.command"
        }
        "git_add_remote" => {
            let name = take_text(&mut payload, "name")?;
            let url = take_text(&mut payload, "url")?;
            payload.insert(
                "arguments".into(),
                json!(["remote", "add", "--", name, url]),
            );
            "git.command"
        }
        "git_remove_remote" => {
            let name = take_text(&mut payload, "name")?;
            payload.insert("arguments".into(), json!(["remote", "remove", "--", name]));
            "git.command"
        }
        "git_get_tags" => {
            payload.insert(
                "arguments".into(),
                json!([
                    "for-each-ref",
                    "--sort=-creatordate",
                    "--format=%(refname:short)%00%(objectname)%00%(contents:subject)%00%(creatordate:iso-strict)%00%(objecttype)",
                    "refs/tags"
                ]),
            );
            "git.command"
        }
        "git_create_tag" => {
            let name = take_text(&mut payload, "name")?;
            let mut arguments = vec!["tag".to_string()];
            if payload.remove("signed").and_then(|value| value.as_bool()) == Some(true) {
                arguments.push("-s".into());
            }
            if let Some(message) = payload
                .remove("message")
                .and_then(|value| value.as_str().map(str::to_string))
                .filter(|value| !value.trim().is_empty())
            {
                arguments.extend(["-a".into(), "-m".into(), message]);
            }
            arguments.extend(["--".into(), name]);
            if let Some(commit) = payload
                .remove("commit")
                .and_then(|value| value.as_str().map(str::to_string))
                .filter(|value| !value.trim().is_empty())
            {
                arguments.push(commit);
            }
            payload.insert("arguments".into(), json!(arguments));
            "git.command"
        }
        "git_delete_tag" => {
            let name = take_text(&mut payload, "name")?;
            payload.insert("arguments".into(), json!(["tag", "-d", "--", name]));
            "git.command"
        }
        "git_push_tag" => {
            let name = take_text(&mut payload, "name")?;
            let remote = take_text(&mut payload, "remote")?;
            payload.insert(
                "arguments".into(),
                json!(["push", "--", remote, format!("refs/tags/{name}")]),
            );
            "git.command"
        }
        "git_delete_remote_tag" => {
            let name = take_text(&mut payload, "name")?;
            let remote = take_text(&mut payload, "remote")?;
            payload.insert(
                "arguments".into(),
                json!([
                    "push",
                    "--delete",
                    "--",
                    remote,
                    format!("refs/tags/{name}")
                ]),
            );
            "git.command"
        }
        "git_checkout_tag" => {
            move_field(&mut payload, "name", "revision");
            payload.insert("operation".into(), json!("checkoutRevision"));
            "git.write"
        }
        "git_get_worktrees" => {
            payload.insert(
                "arguments".into(),
                json!(["worktree", "list", "--porcelain"]),
            );
            "git.command"
        }
        "git_add_worktree" => {
            let path = take_text(&mut payload, "path")?;
            let branch = payload
                .remove("branch")
                .and_then(|value| value.as_str().map(str::to_string))
                .filter(|value| !value.trim().is_empty());
            let create = payload
                .remove("createBranch")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);
            let mut arguments = vec!["worktree".into(), "add".into()];
            if create {
                let branch = branch
                    .as_deref()
                    .ok_or_else(|| "Creating a worktree branch requires branch".to_string())?;
                arguments.extend(["-b".into(), branch.to_string()]);
            }
            arguments.push("--".into());
            arguments.push(path);
            if !create {
                if let Some(branch) = branch {
                    arguments.push(branch);
                }
            }
            payload.insert("arguments".into(), json!(arguments));
            "git.command"
        }
        "git_remove_worktree" => {
            let path = take_text(&mut payload, "path")?;
            let force = payload
                .remove("force")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);
            let mut arguments = vec!["worktree".to_string(), "remove".into()];
            if force {
                arguments.push("--force".into());
            }
            arguments.extend(["--".into(), path]);
            payload.insert("arguments".into(), json!(arguments));
            "git.command"
        }
        "git_init" => {
            payload.insert("arguments".into(), json!(["init"]));
            "git.command"
        }
        "git_clone" => {
            let remote = take_text(&mut payload, "repositoryUrl")?;
            let destination = take_text(&mut payload, "destinationPath")?;
            let destination_path = Path::new(&destination);
            let parent = destination_path
                .parent()
                .ok_or_else(|| "Clone destination requires a parent directory".to_string())?;
            let name = destination_path
                .file_name()
                .and_then(|value| value.to_str())
                .ok_or_else(|| "Clone destination requires a directory name".to_string())?;
            payload.insert("root".into(), json!(parent.to_string_lossy()));
            payload.insert("operation".into(), json!("clone"));
            payload.insert("remote".into(), json!(remote));
            payload.insert("destination".into(), json!(name));
            "git.write"
        }
        "git_reset_all" => {
            payload.insert("arguments".into(), json!(["reset", "HEAD"]));
            "git.command"
        }
        "git_stage_hunk" | "git_unstage_hunk" => {
            let hunk = payload
                .remove("hunk")
                .ok_or_else(|| "Hunk payload is required".to_string())?;
            payload.insert("patch".into(), json!(hunk_patch(&hunk)?));
            payload.insert(
                "mode".into(),
                json!(if command == "git_stage_hunk" {
                    "stage"
                } else {
                    "unstage"
                }),
            );
            "git.apply"
        }
        _ if command.contains('.') => {
            return Ok((command.to_string(), Value::Object(payload)));
        }
        _ => {
            return Err(format!(
                "Windows platform command is not implemented: {command}"
            ))
        }
    };

    Ok((core_command.to_string(), Value::Object(payload)))
}

fn hunk_patch(hunk: &Value) -> Result<String, String> {
    let path = hunk
        .get("file_path")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Hunk requires file_path".to_string())?;
    let lines = hunk
        .get("lines")
        .and_then(Value::as_array)
        .ok_or_else(|| "Hunk requires lines".to_string())?;
    let mut patch = format!("diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n");
    for line in lines {
        let kind = line
            .get("line_type")
            .and_then(Value::as_str)
            .unwrap_or("context");
        let content = line
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let prefix = match kind {
            "added" => "+",
            "removed" => "-",
            "header" => "",
            _ => " ",
        };
        patch.push_str(prefix);
        patch.push_str(content);
        patch.push('\n');
    }
    Ok(patch)
}

fn move_field(payload: &mut Map<String, Value>, from: &str, to: &str) {
    if let Some(value) = payload.remove(from) {
        payload.insert(to.to_string(), value);
    }
}

fn preserve_typed_or_legacy_reference(
    payload: &mut Map<String, Value>,
    legacy_field: &str,
    qualify_local: bool,
) -> Result<(), String> {
    if payload.contains_key("gitReference") {
        payload.remove(legacy_field);
        payload.remove("reference");
        return Ok(());
    }
    if let Some(reference) = payload.remove("reference") {
        let reference = reference
            .as_str()
            .map(str::to_string)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| "Windows platform command requires reference".to_string())?;
        payload.insert("reference".into(), json!(reference));
        if legacy_field != "reference" {
            payload.remove(legacy_field);
        }
        return Ok(());
    }
    let reference = take_text(payload, legacy_field)?;
    payload.insert(
        "reference".into(),
        json!(if qualify_local {
            local_branch_reference(&reference)
        } else {
            reference
        }),
    );
    Ok(())
}

/// Windows callers name local branches by their short form, while the shared
/// core requires fully qualified references so branch and tag names cannot
/// collide. Only `refs/heads/` counts as already qualified; any other ref
/// namespace is treated as a branch name instead of silently targeting a
/// different namespace.
fn local_branch_reference(branch: &str) -> String {
    if branch.starts_with("refs/heads/") {
        branch.to_string()
    } else {
        format!("refs/heads/{branch}")
    }
}

fn take_reference(payload: &mut Map<String, Value>) -> Result<String, String> {
    if let Some(reference) = payload.remove("reference") {
        return reference
            .as_str()
            .map(str::to_string)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| "Windows platform command requires reference".to_string());
    }
    take_text(payload, "branchName").map(|branch| local_branch_reference(&branch))
}

fn reference_kind(reference: &str) -> &'static str {
    if reference.starts_with("refs/remotes/") {
        "remote"
    } else if reference.starts_with("refs/tags/") {
        "tag"
    } else {
        "local"
    }
}

fn paths_from_file(payload: &mut Map<String, Value>) {
    if let Some(path) = payload.remove("filePath") {
        payload.insert("paths".into(), Value::Array(vec![path]));
    }
}

fn take_text(payload: &mut Map<String, Value>, field: &str) -> Result<String, String> {
    payload
        .remove(field)
        .and_then(|value| value.as_str().map(str::to_string))
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("Windows platform command requires {field}"))
}

#[cfg(test)]
mod tests {
    use super::{command_data_error, local_branch_reference, translate};
    use serde_json::json;

    #[test]
    fn rejects_logical_git_failures_after_successful_subprocesses() {
        let operation_error = json!({
            "exitCode": 0,
            "operationError": {
                "code": "invalid_request",
                "message": "Invalid Git reference",
                "details": "branch names cannot contain spaces"
            }
        });
        assert_eq!(
            command_data_error(&operation_error).as_deref(),
            Some("Invalid Git reference: branch names cannot contain spaces")
        );

        let stash_conflict = json!({
            "exitCode": 0,
            "stashRestore": {
                "stashReference": "stash@{0}",
                "conflictedPaths": ["README.md", "src/main.rs"]
            }
        });
        assert_eq!(
            command_data_error(&stash_conflict).as_deref(),
            Some("Git stash restore has conflicts: README.md, src/main.rs")
        );
    }

    #[test]
    fn translates_git_status_root() {
        let (command, payload) = translate("git_status", json!({ "repoPath": "C:/work" })).unwrap();

        assert_eq!(command, "git.status");
        assert_eq!(payload, json!({ "root": "C:/work" }));
    }

    #[test]
    fn translates_stage_file_to_git_write() {
        let (command, payload) = translate(
            "git_add",
            json!({ "repoPath": "C:/work", "filePath": "src/main.rs" }),
        )
        .unwrap();

        assert_eq!(command, "git.write");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "operation": "stage",
                "paths": ["src/main.rs"]
            })
        );
    }

    #[test]
    fn translates_checkout_branch_with_reference_kind() {
        let (command, payload) = translate(
            "git_checkout",
            json!({ "repoPath": "C:/work", "branchName": "feature/checkout" }),
        )
        .unwrap();

        assert_eq!(command, "git.write");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "operation": "checkout",
                "reference": "refs/heads/feature/checkout",
                "referenceKind": "local"
            })
        );
    }

    #[test]
    fn preserves_complete_references_for_git_log_actions() {
        let (checkout_command, checkout_payload) = translate(
            "git_checkout",
            json!({
                "repoPath": "C:/work",
                "reference": "refs/remotes/origin/feature/demo",
                "referenceKind": "remote"
            }),
        )
        .unwrap();
        assert_eq!(checkout_command, "git.write");
        assert_eq!(
            checkout_payload,
            json!({
                "root": "C:/work",
                "operation": "checkout",
                "reference": "refs/remotes/origin/feature/demo",
                "referenceKind": "remote"
            })
        );

        let (rebase_command, rebase_payload) = translate(
            "git_checkout_and_rebase",
            json!({
                "repoPath": "C:/work",
                "reference": "refs/remotes/origin/feature/demo",
                "referenceKind": "remote"
            }),
        )
        .unwrap();
        assert_eq!(rebase_command, "git.write");
        assert_eq!(
            rebase_payload,
            json!({
                "root": "C:/work",
                "operation": "checkoutAndRebase",
                "reference": "refs/remotes/origin/feature/demo",
                "referenceKind": "remote"
            })
        );

        let (diff_command, diff_payload) = translate(
            "git_reference_worktree_diff",
            json!({
                "repoPath": "C:/work",
                "reference": "refs/remotes/origin/feature/demo"
            }),
        )
        .unwrap();
        assert_eq!(diff_command, "git.diff");
        assert_eq!(
            diff_payload,
            json!({
                "root": "C:/work",
                "reference": "refs/remotes/origin/feature/demo",
                "pathspecs": ["."],
                "untracked": true
            })
        );
    }

    #[test]
    fn translates_checkout_preflight_reference() {
        let (command, payload) = translate(
            "git_checkout_preflight",
            json!({ "repoPath": "C:/work", "branchName": "main" }),
        )
        .unwrap();

        assert_eq!(command, "git.checkoutPreflight");
        assert_eq!(
            payload,
            json!({ "root": "C:/work", "reference": "refs/heads/main" })
        );
    }

    #[test]
    fn translates_merge_and_rebase_to_qualified_references() {
        let (merge_command, merge_payload) = translate(
            "git_merge",
            json!({ "repoPath": "C:/work", "branchName": "feature/demo" }),
        )
        .unwrap();
        assert_eq!(merge_command, "git.write");
        assert_eq!(
            merge_payload,
            json!({
                "root": "C:/work",
                "operation": "merge",
                "reference": "refs/heads/feature/demo"
            })
        );

        let (rebase_command, rebase_payload) = translate(
            "git_rebase",
            json!({ "repoPath": "C:/work", "branchName": "main" }),
        )
        .unwrap();
        assert_eq!(rebase_command, "git.write");
        assert_eq!(
            rebase_payload,
            json!({
                "root": "C:/work",
                "operation": "rebase",
                "reference": "refs/heads/main"
            })
        );

        let (_, remote_merge_payload) = translate(
            "git_merge",
            json!({
                "repoPath": "C:/work",
                "reference": "refs/remotes/origin/feature/demo",
                "referenceKind": "remote"
            }),
        )
        .unwrap();
        assert_eq!(
            remote_merge_payload["reference"],
            "refs/remotes/origin/feature/demo"
        );
    }

    #[test]
    fn translates_integration_preflight_operation() {
        let (command, payload) = translate(
            "git_integration_preflight",
            json!({ "repoPath": "C:/work", "branchName": "main", "operation": "rebase" }),
        )
        .unwrap();

        assert_eq!(command, "git.integrationPreflight");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "reference": "refs/heads/main",
                "operation": "rebase"
            })
        );
    }

    #[test]
    fn translates_operation_state_and_resolution_commands() {
        let (state_command, state_payload) =
            translate("git_operation_state", json!({ "repoPath": "C:/work" })).unwrap();
        assert_eq!(state_command, "git.operationState");
        assert_eq!(state_payload, json!({ "root": "C:/work" }));

        for (compat, operation) in [
            ("git_operation_continue", "operationContinue"),
            ("git_operation_abort", "operationAbort"),
            ("git_operation_skip", "operationSkip"),
        ] {
            let (command, payload) = translate(compat, json!({ "repoPath": "C:/work" })).unwrap();
            assert_eq!(command, "git.write");
            assert_eq!(
                payload,
                json!({ "root": "C:/work", "operation": operation })
            );
        }
    }

    #[test]
    fn translates_conflict_markers_request() {
        let (command, payload) =
            translate("git_conflict_markers", json!({ "repoPath": "C:/work" })).unwrap();

        assert_eq!(command, "git.conflictMarkers");
        assert_eq!(payload, json!({ "root": "C:/work" }));
    }

    #[test]
    fn translates_delete_branch_to_qualified_reference() {
        let (command, payload) = translate(
            "git_delete_branch",
            json!({ "repoPath": "C:/work", "branchName": "feature/old" }),
        )
        .unwrap();

        assert_eq!(command, "git.write");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "operation": "deleteBranch",
                "reference": "refs/heads/feature/old"
            })
        );
    }

    #[test]
    fn qualifies_short_branch_names_only() {
        assert_eq!(local_branch_reference("main"), "refs/heads/main");
        assert_eq!(
            local_branch_reference("feature/old"),
            "refs/heads/feature/old"
        );
        assert_eq!(local_branch_reference("refs/heads/main"), "refs/heads/main");
        assert_eq!(local_branch_reference("refs/foo"), "refs/heads/refs/foo");
    }

    #[test]
    fn translates_diff_defaults() {
        let (command, payload) =
            translate("git_diff_file", json!({ "repoPath": "C:/work" })).unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(payload, json!({ "root": "C:/work", "pathspecs": ["."] }));
    }

    #[test]
    fn translates_diff_file_pathspec() {
        let (command, payload) = translate(
            "git_diff_file",
            json!({ "repoPath": "C:/work", "filePath": "src/main.rs", "staged": true }),
        )
        .unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "pathspecs": ["src/main.rs"],
                "staged": true
            })
        );
    }

    #[test]
    fn translates_untracked_diff_file_pathspec() {
        let (command, payload) = translate(
            "git_diff_file",
            json!({
                "repoPath": "C:/work",
                "filePath": "new.txt",
                "untracked": true
            }),
        )
        .unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "pathspecs": ["new.txt"],
                "untracked": true
            })
        );
    }

    #[test]
    fn translates_status_diff_stats_whole_tree() {
        let (command, payload) = translate(
            "git_status_diff_stats",
            json!({ "repoPath": "C:/work", "staged": true }),
        )
        .unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(
            payload,
            json!({ "root": "C:/work", "pathspecs": ["."], "staged": true })
        );
    }

    #[test]
    fn preserves_typed_remote_references_for_compatibility_commands() {
        let reference = json!({
            "fullName": "refs/remotes/origin/feature/checkout",
            "shortName": "origin/feature/checkout",
            "kind": "remote"
        });
        for (compatibility_command, core_command, operation) in [
            ("git_checkout", "git.write", Some("checkout")),
            ("git_checkout_preflight", "git.checkoutPreflight", None),
            ("git_merge", "git.write", Some("merge")),
            ("git_rebase", "git.write", Some("rebase")),
        ] {
            let (command, payload) = translate(
                compatibility_command,
                json!({ "repoPath": "C:/work", "gitReference": reference }),
            )
            .unwrap();
            assert_eq!(command, core_command);
            assert_eq!(payload.get("gitReference"), Some(&reference));
            assert_eq!(payload.get("reference"), None);
            assert_eq!(payload.get("referenceKind"), None);
            assert_eq!(
                payload.get("operation").and_then(|value| value.as_str()),
                operation
            );
        }

        let (command, payload) = translate(
            "git_integration_preflight",
            json!({
                "repoPath": "C:/work",
                "gitReference": reference,
                "operation": "merge"
            }),
        )
        .unwrap();
        assert_eq!(command, "git.integrationPreflight");
        assert_eq!(payload.get("gitReference"), Some(&reference));
    }

    #[test]
    fn translates_working_tree_reference_diff() {
        let (command, payload) = translate(
            "git_working_tree_ref_diff",
            json!({
                "repoPath": "C:/work",
                "reference": "refs/remotes/origin/main"
            }),
        )
        .unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "reference": "refs/remotes/origin/main",
                "pathspecs": ["."]
            })
        );
    }

    #[test]
    fn translates_typed_working_tree_reference_diff_without_rewriting_it() {
        let reference = json!({
            "fullName": "refs/tags/v1.0.0",
            "shortName": "v1.0.0",
            "kind": "tag"
        });
        let (command, payload) = translate(
            "git_working_tree_ref_diff",
            json!({ "repoPath": "C:/work", "gitReference": reference }),
        )
        .unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "gitReference": reference,
                "pathspecs": ["."]
            })
        );
    }

    #[test]
    fn translates_typed_two_reference_diff_without_constructing_a_range() {
        let base = json!({
            "fullName": "refs/remotes/origin/main",
            "shortName": "origin/main",
            "kind": "remote"
        });
        let target = json!({
            "fullName": "refs/heads/main",
            "shortName": "main",
            "kind": "local"
        });
        let (command, payload) = translate(
            "git_ref_diff",
            json!({
                "repoPath": "C:/work",
                "gitReference": base,
                "targetGitReference": target
            }),
        )
        .unwrap();

        assert_eq!(command, "git.diff");
        assert_eq!(
            payload,
            json!({
                "root": "C:/work",
                "gitReference": base,
                "targetGitReference": target,
                "pathspecs": ["."]
            })
        );
    }

    #[test]
    fn rejects_unknown_platform_command() {
        let error = translate("missing_command", json!({})).unwrap_err();
        assert!(error.contains("not implemented"));
    }

    #[test]
    fn translates_remote_listing_to_argument_based_git_command() {
        let (command, payload) =
            translate("git_get_remotes", json!({ "repoPath": "C:/work" })).unwrap();

        assert_eq!(command, "git.command");
        assert_eq!(
            payload,
            json!({ "root": "C:/work", "arguments": ["remote", "-v"] })
        );
    }

    #[test]
    fn translates_clone_to_parent_root_and_destination_name() {
        let (command, payload) = translate(
            "git_clone",
            json!({
                "repositoryUrl": "https://example.invalid/team/repo.git",
                "destinationPath": "C:/projects/repo"
            }),
        )
        .unwrap();

        assert_eq!(command, "git.write");
        assert_eq!(payload["root"], "C:/projects");
        assert_eq!(payload["operation"], "clone");
        assert_eq!(payload["destination"], "repo");
    }

    #[test]
    fn translates_hunk_lines_to_apply_patch() {
        let (command, payload) = translate(
            "git_stage_hunk",
            json!({
                "repoPath": "C:/work",
                "hunk": {
                    "file_path": "src/main.rs",
                    "lines": [
                        { "line_type": "header", "content": "@@ -1 +1 @@" },
                        { "line_type": "removed", "content": "old" },
                        { "line_type": "added", "content": "new" }
                    ]
                }
            }),
        )
        .unwrap();

        assert_eq!(command, "git.apply");
        assert_eq!(payload["mode"], "stage");
        assert_eq!(
            payload["patch"],
            "diff --git a/src/main.rs b/src/main.rs\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1 +1 @@\n-old\n+new\n"
        );
    }
}
