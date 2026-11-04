//! Captures bounded commit-message evidence and detects stale Git content.

use super::patch_exchange::{self, PatchExportRequest, PatchFile, PatchSource};
use super::{capture_git_with_options, commit_state, GitStatusRequest};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum Mode {
    Staged,
    Worktree,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Action {
    Capture,
    Check,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SelectedFile {
    path: String,
    original_path: Option<String>,
    change_kind: String,
}
#[derive(Clone, Deserialize, Serialize)]
struct Repository {
    root: String,
    files: Vec<SelectedFile>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    action: Action,
    mode: Mode,
    repositories: Vec<Repository>,
    maximum_diff_characters: Option<usize>,
    token: Option<String>,
}
struct Evidence {
    path: String,
    change_kind: String,
    diff: String,
    is_binary: bool,
}

fn invalid(message: &'static str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}
fn hash_field(hash: &mut Sha256, bytes: &[u8]) {
    hash.update((bytes.len() as u64).to_be_bytes());
    hash.update(bytes);
}
fn selected_repositories(mut repositories: Vec<Repository>) -> Result<Vec<Repository>, CoreError> {
    if repositories.is_empty() {
        return Err(invalid("AI_COMMIT_EMPTY_DIFF"));
    }
    if repositories.len() > 1_000 {
        return Err(invalid("AI_COMMIT_TOO_MANY_FILES"));
    }
    repositories.sort_by(|a, b| a.root.cmp(&b.root));
    let mut roots = BTreeSet::new();
    let mut count = 0usize;
    for repository in &mut repositories {
        if repository.root.is_empty()
            || !roots.insert(repository.root.clone())
            || repository.files.is_empty()
        {
            return Err(invalid("AI_COMMIT_INVALID_OPTIONS"));
        }
        repository.files.sort_by(|a, b| a.path.cmp(&b.path));
        let mut paths = BTreeSet::new();
        for file in &repository.files {
            count += 1;
            if count > 1_000 {
                return Err(invalid("AI_COMMIT_TOO_MANY_FILES"));
            }
            if !super::changelists::safe_path(&file.path)
                || !paths.insert(file.path.clone())
                || file
                    .original_path
                    .as_deref()
                    .is_some_and(|p| !super::changelists::safe_path(p))
                || (file.path.ends_with('/') && file.change_kind != "untracked")
                || !matches!(
                    file.change_kind.as_str(),
                    "added"
                        | "modified"
                        | "deleted"
                        | "renamed"
                        | "copied"
                        | "unmerged"
                        | "untracked"
                )
            {
                return Err(invalid("AI_COMMIT_INVALID_OPTIONS"));
            }
            if crate::ai::is_sensitive_commit_path(&file.path)
                || file
                    .original_path
                    .as_deref()
                    .is_some_and(crate::ai::is_sensitive_commit_path)
            {
                return Err(invalid("AI_COMMIT_SENSITIVE_FILE"));
            }
        }
    }
    Ok(repositories)
}

fn index_state(root: &str) -> Result<[u8; 32], CoreError> {
    let state = commit_state(GitStatusRequest {
        root: root.into(),
        include_index_only_changes: true,
        repository_roots: Vec::new(),
        summarize_untracked_directories: false,
    })?;
    // Hash semantic entries and flags, not raw index stat fields: Git may
    // refresh those fields during a harmless status scan without changing any
    // committed content. Preserve raw bytes so non-UTF-8 unrelated names do
    // not collide through lossy decoding.
    let flags = capture_git_with_options(
        root,
        &[
            "ls-files".into(),
            "-v".into(),
            "--stage".into(),
            "-z".into(),
        ],
        None,
        true,
    )?;
    if flags.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect the Git index",
        ));
    }
    let mut hash = Sha256::new();
    hash_field(
        &mut hash,
        &serde_json::to_vec(&state).map_err(|_| invalid("AI_COMMIT_INVALID_OPTIONS"))?,
    );
    hash_field(&mut hash, &flags.stdout);
    Ok(hash.finalize().into())
}

fn export(root: &str, mode: Mode, files: &[SelectedFile]) -> Result<String, CoreError> {
    let mut paths = BTreeSet::new();
    for file in files {
        paths.insert(file.path.clone());
        if let Some(original) = &file.original_path {
            paths.insert(original.clone());
        }
    }
    Ok(patch_exchange::export(PatchExportRequest {
        root: root.into(),
        source: match mode {
            Mode::Staged => PatchSource::Staged,
            Mode::Worktree => PatchSource::WorkingTree,
        },
        paths: paths.into_iter().collect(),
        base_revision: None,
        target_revision: None,
        metadata_only: false,
        include_untracked: false,
    })?
    .patch)
}

fn sections(root: &str, patch: &str) -> Result<Vec<(PatchFile, String)>, CoreError> {
    if patch.is_empty() {
        return Err(invalid("AI_COMMIT_DIFF_FAILED"));
    }
    let identities = patch_exchange::ordered_patch_files(root, patch)?;
    let mut starts = Vec::new();
    let mut offset = 0;
    for line in patch.split_inclusive('\n') {
        if line.starts_with("diff --git ") {
            starts.push(offset);
        }
        offset += line.len();
    }
    if starts.first() != Some(&0) || starts.len() != identities.len() {
        return Err(invalid("AI_COMMIT_DIFF_FAILED"));
    }
    starts.push(patch.len());
    Ok(identities
        .into_iter()
        .zip(starts.windows(2))
        .map(|(file, span)| (file, patch[span[0]..span[1]].to_string()))
        .collect())
}

fn destination_matches(selected: &SelectedFile, file: &PatchFile) -> bool {
    if selected.path.ends_with('/') {
        file.path.starts_with(&selected.path)
    } else {
        selected.path == file.path
            && (selected.original_path == file.original_path || selected.original_path.is_none())
    }
}

fn selection_matches(selected: &SelectedFile, file: &PatchFile) -> bool {
    destination_matches(selected, file)
        || (selected.change_kind == "deleted"
            && selected.original_path.is_none()
            && file.original_path.as_deref() == Some(selected.path.as_str()))
}

fn collect(mode: Mode, repositories: &[Repository]) -> Result<(Vec<Evidence>, String), CoreError> {
    let mut hash = Sha256::new();
    hash_field(&mut hash, b"lithe.commit-message-context.v1");
    hash_field(
        &mut hash,
        &serde_json::to_vec(&mode).map_err(|_| invalid("AI_COMMIT_INVALID_OPTIONS"))?,
    );
    let mut all = Vec::new();
    let mut total_patch_bytes = 0usize;
    for (index, repository) in repositories.iter().enumerate() {
        let before = index_state(&repository.root)?;
        let patch = export(&repository.root, mode, &repository.files)?;
        total_patch_bytes = total_patch_bytes.saturating_add(patch.len());
        if total_patch_bytes > patch_exchange::MAX_PATCH_BYTES {
            return Err(invalid("AI_COMMIT_DIFF_FAILED"));
        }
        let after = index_state(&repository.root)?;
        if before != after {
            return Err(invalid("AI_COMMIT_STALE"));
        }
        // The worktree is mutable independently of the index; compare a second
        // uncached export before accepting the captured evidence.
        if matches!(mode, Mode::Worktree) {
            let again = export(&repository.root, mode, &repository.files)?;
            if patch != again || after != index_state(&repository.root)? {
                return Err(invalid("AI_COMMIT_STALE"));
            }
        }
        hash_field(
            &mut hash,
            &serde_json::to_vec(repository).map_err(|_| invalid("AI_COMMIT_INVALID_OPTIONS"))?,
        );
        hash_field(&mut hash, &after);
        hash_field(&mut hash, patch.as_bytes());
        let sections = sections(&repository.root, &patch)?;
        if all.len().saturating_add(sections.len()) > 1_000 {
            return Err(invalid("AI_COMMIT_TOO_MANY_FILES"));
        }
        // A summarized untracked directory can cover many files. Check every
        // selected identity and every exported section before accepting any of them.
        for selected in &repository.files {
            if !sections
                .iter()
                .any(|(file, _)| selection_matches(selected, file))
            {
                return Err(invalid("AI_COMMIT_DIFF_FAILED"));
            }
        }
        for (file, patch) in sections {
            if crate::ai::is_sensitive_commit_path(&file.path)
                || file
                    .original_path
                    .as_deref()
                    .is_some_and(crate::ai::is_sensitive_commit_path)
            {
                return Err(invalid("AI_COMMIT_SENSITIVE_FILE"));
            }
            let selected = repository
                .files
                .iter()
                .filter(|selected| destination_matches(selected, &file))
                .max_by_key(|selected| selected.path.len())
                .ok_or_else(|| invalid("AI_COMMIT_DIFF_FAILED"))?;
            if let Some(original) = &file.original_path {
                let explicit_rename = selected.original_path.as_ref() == Some(original);
                let selected_deletion = repository.files.iter().any(|candidate| {
                    candidate.path == *original && candidate.change_kind == "deleted"
                });
                if !explicit_rename && !selected_deletion {
                    return Err(invalid("AI_COMMIT_DIFF_FAILED"));
                }
            }
            // The UI status may describe a different layer (for example an
            // unstaged deletion over a staged modification). Use the captured
            // patch's own headers for the evidence presented to the model.
            let change_kind = if file.original_path.is_some() {
                if patch.lines().any(|line| line.starts_with("copy from ")) {
                    "copied"
                } else {
                    "renamed"
                }
            } else if patch.lines().any(|line| line.starts_with("new file mode ")) {
                if matches!(mode, Mode::Worktree) && selected.change_kind == "untracked" {
                    "untracked"
                } else {
                    "added"
                }
            } else if patch
                .lines()
                .any(|line| line.starts_with("deleted file mode "))
            {
                "deleted"
            } else {
                "modified"
            };
            // Binary data is not evidence for the language model. Keep a
            // nonempty marker so the file remains present in the complete set.
            let is_binary = file.additions.is_none() && file.deletions.is_none();
            let diff = if is_binary {
                "[Binary file; content omitted.]".into()
            } else {
                patch
            };
            let path = if repositories.len() == 1 {
                file.path
            } else {
                format!("repository-{}/{}", index + 1, file.path)
            };
            all.push(Evidence {
                path,
                change_kind: change_kind.into(),
                diff,
                is_binary,
            });
        }
    }
    all.sort_by(|a, b| a.path.cmp(&b.path));
    if all.iter().all(|file| file.is_binary) {
        return Err(invalid("AI_COMMIT_EMPTY_DIFF"));
    }
    Ok((all, format!("{:x}", hash.finalize())))
}

/// Captures bounded evidence or checks whether its complete Git state is current.
pub(crate) fn commit_message_context_command(value: Value) -> Result<Value, CoreError> {
    let request: Request =
        serde_json::from_value(value).map_err(|_| invalid("AI_COMMIT_INVALID_OPTIONS"))?;
    let repositories = selected_repositories(request.repositories)?;
    if matches!(request.action, Action::Check) {
        let token = request
            .token
            .ok_or_else(|| invalid("AI_COMMIT_INVALID_OPTIONS"))?;
        if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(invalid("AI_COMMIT_INVALID_OPTIONS"));
        }
        let current = collect(request.mode, &repositories)
            .map(|(_, current)| current == token)
            .unwrap_or(false);
        return Ok(json!({"isCurrent": current}));
    }
    let (files, token) = collect(request.mode, &repositories)?;
    let lengths = files
        .iter()
        .map(|file| file.diff.chars().count())
        .collect::<Vec<_>>();
    let budgets = crate::ai::commit_input_budget(
        request
            .maximum_diff_characters
            .ok_or_else(|| invalid("AI_COMMIT_INVALID_OPTIONS"))?,
        &lengths,
    )
    .map_err(invalid)?;
    let files: Vec<_> = files
        .into_iter()
        .zip(lengths)
        .zip(budgets)
        .map(|((file, original), budget)| {
            json!({
                "path":file.path, "changeKind":file.change_kind,
                "diff":file.diff.chars().take(budget.characters).collect::<String>(),
                "originalCharacters":original, "truncated":budget.truncated
            })
        })
        .collect();
    Ok(json!({"files": files, "token": token}))
}
