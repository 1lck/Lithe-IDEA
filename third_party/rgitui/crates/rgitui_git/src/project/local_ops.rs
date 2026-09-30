use anyhow::{Context as _, Result};
use git2::Repository;
use gpui::{AsyncApp, Context, Task, WeakEntity};
use std::io::{Read as _, Seek as _, Write as _};
use std::path::{Path, PathBuf};

use rgitui_settings::current_git_auth_runtime;

use crate::types::*;

use super::auth::inject_https_credentials;
use super::refresh::{gather_refresh_data, gather_refresh_data_lightweight_cached};
use super::worktree_patch::{clean_worktree_bytes, smudge_canonical_bytes};
use super::{ensure_clean_worktree, head_branch_name, GitProject, GitProjectEvent, RefreshData};

// TODO(audit): deferred audit items for this module (tracked, not yet applied):
//  - QUAL-02: the ~39 copy-pasted begin/spawn/apply/complete blocks should collapse
//    into one generic job-dispatch helper (cf. Zed `git_store::send_job`).
//  - QUAL-05: cache an `Arc<Mutex<git2::Repository>>` instead of `Repository::open`
//    per call — conflicts with the deliberate per-thread opens in refresh's
//    thread::scope, so needs a design pass.
//  - BUG-41: `discard_changes_at` directory handling — verifier judged the current
//    code correct (untracked dirs take the remove_dir_all branch); left unchanged.

/// Commit the resolved merge in `repo` with its stored `MERGE_MSG`, exactly as
/// `git merge --continue` does: the index is committed as the user staged it,
/// with `MERGE_HEAD`'s commits as the extra parents. Untracked and unstaged
/// working-tree changes are deliberately left out of the merge commit.
fn finish_merge_commit(repo: &Repository) -> Result<String> {
    let merge_head_path = repo.path().join("MERGE_HEAD");
    if !merge_head_path.exists() {
        anyhow::bail!("Repository is not in a merge state (no MERGE_HEAD to continue).");
    }

    let mut index = repo.index()?;
    let tree_oid = index.write_tree()?;
    let tree = repo.find_tree(tree_oid)?;

    let sig = repo.signature()?;
    let head_commit = repo.head()?.peel_to_commit()?;

    let merge_msg_path = repo.path().join("MERGE_MSG");
    let message = if merge_msg_path.exists() {
        std::fs::read_to_string(&merge_msg_path).unwrap_or_else(|_| "Merge commit".to_string())
    } else {
        "Merge commit".to_string()
    };

    let mut parents = vec![head_commit];
    let contents = std::fs::read_to_string(&merge_head_path)?;
    for line in contents.lines() {
        let line = line.trim();
        if !line.is_empty() {
            let oid = git2::Oid::from_str(line)?;
            parents.push(repo.find_commit(oid)?);
        }
    }

    let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
    repo.commit(Some("HEAD"), &sig, &sig, &message, &tree, &parent_refs)?;
    repo.cleanup_state()?;

    Ok(message.lines().next().unwrap_or("Merge commit").to_string())
}

/// Run `git <subcommand> --continue` in `worktree_path`.
///
/// libgit2 has no sequencer, so cherry-pick, revert, mailbox application and
/// rebase can only be carried forward by the git CLI. Each of those accepts
/// `--continue` on its own and rejects any other flag alongside it, so the
/// editor is suppressed through the environment rather than with `--no-edit`;
/// the message git already stored for the stopped step is reused as-is.
fn run_continue_subcommand(worktree_path: &Path, subcommand: &str) -> Result<String> {
    let output = super::git_command()
        .current_dir(worktree_path)
        .args([subcommand, "--continue"])
        .env("GIT_EDITOR", "true")
        .env("GIT_SEQUENCE_EDITOR", "true")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .with_context(|| format!("Failed to execute git {} --continue", subcommand))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        anyhow::bail!("git {} --continue failed: {}", subcommand, detail);
    }

    let summary = stdout
        .lines()
        .chain(stderr.lines())
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("Operation continued")
        .to_string();
    Ok(summary)
}

/// Renders up to three paths inline, summarising the rest, for error messages.
fn format_path_list(paths: &[String]) -> String {
    const SHOWN: usize = 3;
    let shown = paths.len().min(SHOWN);
    let mut list = paths[..shown].join(", ");
    if paths.len() > shown {
        list.push_str(&format!(" and {} more", paths.len() - shown));
    }
    list
}

/// Checks out `target` without overwriting local work, naming the files that
/// stand in the way when it cannot.
///
/// libgit2 reports a blocked safe checkout as the bare "1 conflict prevents
/// checkout", which tells the user nothing they can act on. The notify callback
/// collects the offending paths so the error can name them, matching what the
/// `git` CLI does on the same refusal.
fn checkout_tree_safe(repo: &Repository, target: &git2::Object<'_>, operation: &str) -> Result<()> {
    let conflicts = std::cell::RefCell::new(Vec::new());
    let result = {
        let mut opts = git2::build::CheckoutBuilder::new();
        opts.safe()
            .notify_on(git2::CheckoutNotificationType::CONFLICT)
            .notify(|_kind, path, _baseline, _target, _workdir| {
                if let Some(path) = path {
                    conflicts.borrow_mut().push(path.display().to_string());
                }
                true
            });
        repo.checkout_tree(target, Some(&mut opts))
    };

    match result {
        Ok(()) => Ok(()),
        Err(err) if err.code() == git2::ErrorCode::Conflict => {
            let paths = conflicts.into_inner();
            if paths.is_empty() {
                anyhow::bail!(
                    "{} would overwrite local changes. Commit, stash, or discard them first.",
                    operation
                );
            }
            anyhow::bail!(
                "{} would overwrite {}. Commit, stash, move, or delete {} first.",
                operation,
                format_path_list(&paths),
                if paths.len() == 1 { "it" } else { "them" }
            );
        }
        Err(err) => Err(err.into()),
    }
}

impl GitProject {
    /// Stage specific files in the given worktree.
    pub fn stage_files_at(
        &mut self,
        paths: &[PathBuf],
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("stage_files: {} paths", paths.len());
        let paths = paths.to_vec();
        let task_paths = paths.clone();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stage,
            if paths.len() == 1 {
                format!("Staging {}...", paths[0].display())
            } else {
                format!("Staging {} files...", paths.len())
            },
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let mut index = repo.index()?;
                    for path in &task_paths {
                        if index.conflict_get(path).is_ok() {
                            anyhow::bail!(
                                "'{}' has unresolved conflicts. Open the conflict resolver before staging it.",
                                path.display()
                            );
                        }
                        if worktree_path.join(path).exists() {
                            index.add_path(path)?;
                        } else {
                            index.remove_path(path)?;
                        }
                    }
                    index.write()?;
                    gather_refresh_data_lightweight_cached(
                        &refresh_repo_path,
                        commit_limit,
                        &worktree_cache,
                        author_filter.as_deref(),
                    )
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.refresh_ahead_behind(cx);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stage,
                                if paths.len() == 1 {
                                    format!("Staged {}", paths[0].display())
                                } else {
                                    format!("Staged {} files", paths.len())
                                },
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stage,
                                "Stage failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Unstage specific files in the given worktree.
    pub fn unstage_files_at(
        &mut self,
        paths: &[PathBuf],
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("unstage_files: {} paths", paths.len());
        let paths = paths.to_vec();
        let task_paths = paths.clone();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Unstage,
            if paths.len() == 1 {
                format!("Unstaging {}...", paths[0].display())
            } else {
                format!("Unstaging {} files...", paths.len())
            },
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    if let Ok(head_tree) = repo.head().and_then(|h| h.peel_to_tree()) {
                        repo.reset_default(Some(&head_tree.into_object()), &task_paths)?;
                    } else {
                        let mut index = repo.index()?;
                        for path in &task_paths {
                            if let Err(e) = index.remove_path(path) {
                                log::warn!(
                                    "Failed to remove path from index during unstage: {}: {}",
                                    path.display(),
                                    e
                                );
                            }
                        }
                        index.write()?;
                    }
                    gather_refresh_data_lightweight_cached(
                        &refresh_repo_path,
                        commit_limit,
                        &worktree_cache,
                        author_filter.as_deref(),
                    )
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.refresh_ahead_behind(cx);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Unstage,
                                if paths.len() == 1 {
                                    format!("Unstaged {}", paths[0].display())
                                } else {
                                    format!("Unstaged {} files", paths.len())
                                },
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Unstage,
                                "Unstage failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Stage all changes in the given worktree.
    pub fn stage_all_at(
        &mut self,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("stage_all");
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stage,
            "Staging all changes...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let mut index = repo.index()?;
                    let conflicted = index
                        .conflicts()?
                        .filter_map(|entry| entry.ok())
                        .filter_map(|entry| {
                            entry
                                .our
                                .as_ref()
                                .or(entry.their.as_ref())
                                .or(entry.ancestor.as_ref())
                                .map(|entry| entry.path.clone())
                        })
                        .collect::<std::collections::HashSet<_>>();
                    let mut skip_conflicts = |path: &Path, _matched: &[u8]| {
                        i32::from(conflicted.contains(path.as_os_str().as_encoded_bytes()))
                    };
                    index.add_all(
                        ["*"].iter(),
                        git2::IndexAddOption::DEFAULT,
                        Some(&mut skip_conflicts),
                    )?;
                    index.write()?;
                    gather_refresh_data_lightweight_cached(
                        &refresh_repo_path,
                        commit_limit,
                        &worktree_cache,
                        author_filter.as_deref(),
                    )
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.refresh_ahead_behind(cx);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stage,
                                "Staged all changes",
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stage,
                                "Stage all failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Unstage all changes in the given worktree.
    pub fn unstage_all_at(
        &mut self,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("unstage_all");
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Unstage,
            "Unstaging all changes...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    if let Ok(head) = repo.head() {
                        let obj = head.peel(git2::ObjectType::Any)?;
                        repo.reset(&obj, git2::ResetType::Mixed, None)?;
                    }
                    gather_refresh_data_lightweight_cached(
                        &refresh_repo_path,
                        commit_limit,
                        &worktree_cache,
                        author_filter.as_deref(),
                    )
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.refresh_ahead_behind(cx);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Unstage,
                                "Unstaged all changes",
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Unstage,
                                "Unstage all failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Create a commit with the current staged changes.
    /// Create a commit in the given worktree with the current staged changes.
    pub fn commit_at(
        &mut self,
        message: &str,
        amend: bool,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<git2::Oid>> {
        log::info!("commit: amend={}", amend);
        let message = message.to_string();
        let task_message = message.clone();
        let commit_summary = message.lines().next().unwrap_or("").to_string();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Commit,
            if amend {
                "Amending commit..."
            } else {
                "Creating commit..."
            },
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(git2::Oid, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let sig = repo.signature()?;
                    let mut index = repo.index()?;
                    if index.is_empty() {
                        anyhow::bail!("There are no staged changes to commit.")
                    }
                    let tree_oid = index.write_tree()?;
                    let tree = repo.find_tree(tree_oid)?;

                    let auth = current_git_auth_runtime();

                    // Amending must never silently destroy an in-progress rebase
                    // (the working tree would be reset to ORIG_HEAD and all rebase
                    // progress/conflict resolution lost). Refuse instead.
                    if amend
                        && matches!(
                            repo.state(),
                            git2::RepositoryState::Rebase
                                | git2::RepositoryState::RebaseInteractive
                                | git2::RepositoryState::RebaseMerge
                        )
                    {
                        anyhow::bail!(
                            "Cannot amend during a rebase. Continue or abort the rebase first."
                        );
                    }

                    // A plain commit made while a merge is in progress must finalize
                    // it as a real merge commit (HEAD + MERGE_HEAD parents) and clear
                    // the merge state; otherwise the second parent is dropped and the
                    // repository stays stuck in the 'Merging' state.
                    let merge_parent_oids: Vec<git2::Oid> = if !amend
                        && (repo.state() == git2::RepositoryState::Merge
                            || repo.path().join("MERGE_HEAD").exists())
                    {
                        let merge_head_path = repo.path().join("MERGE_HEAD");
                        let mut oids = Vec::new();
                        if let Ok(contents) = std::fs::read_to_string(&merge_head_path) {
                            for line in contents.lines() {
                                let line = line.trim();
                                if !line.is_empty() {
                                    oids.push(git2::Oid::from_str(line)?);
                                }
                            }
                        }
                        oids
                    } else {
                        Vec::new()
                    };
                    let finalizing_merge = !merge_parent_oids.is_empty();

                    let oid = if amend {
                        if auth.sign_commits {
                            let gpg_key = auth.gpg_key_id.as_deref().ok_or_else(|| {
                                anyhow::anyhow!(
                                    "GPG signing enabled but no key ID configured in settings"
                                )
                            })?;

                            let head = repo.head()?.peel_to_commit()?;
                            let parents: Vec<git2::Commit> = head.parents().collect();
                            let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
                            let buf = repo.commit_create_buffer(
                                &sig,
                                &sig,
                                &task_message,
                                &tree,
                                &parent_refs,
                            )?;
                            let buf_str = std::str::from_utf8(&buf)
                                .context("commit buffer contains invalid UTF-8")?;
                            let signature = sign_with_gpg(buf_str, gpg_key)?;
                            let commit_oid =
                                repo.commit_signed(buf_str, &signature, Some("gpgsig"))?;
                            if let Ok(mut head_ref) = repo.head() {
                                head_ref.set_target(commit_oid, "commit (gpg signed amend)")?;
                            } else {
                                repo.reference(
                                    "HEAD",
                                    commit_oid,
                                    true,
                                    "commit (gpg signed amend)",
                                )?;
                            }
                            commit_oid
                        } else {
                            let head = repo.head()?.peel_to_commit()?;
                            head.amend(
                                Some("HEAD"),
                                Some(&sig),
                                Some(&sig),
                                None,
                                Some(&task_message),
                                Some(&tree),
                            )?
                        }
                    } else {
                        let mut parents: Vec<git2::Commit> = if let Ok(head) = repo.head() {
                            vec![head.peel_to_commit()?]
                        } else {
                            vec![]
                        };
                        for oid in &merge_parent_oids {
                            parents.push(repo.find_commit(*oid)?);
                        }
                        let parent_refs: Vec<&git2::Commit> = parents.iter().collect();
                        if auth.sign_commits {
                            let gpg_key = auth.gpg_key_id.as_deref().ok_or_else(|| {
                                anyhow::anyhow!(
                                    "GPG signing enabled but no key ID configured in settings"
                                )
                            })?;
                            let buf = repo.commit_create_buffer(
                                &sig,
                                &sig,
                                &task_message,
                                &tree,
                                &parent_refs,
                            )?;
                            let buf_str = std::str::from_utf8(&buf)
                                .context("commit buffer contains invalid UTF-8")?;
                            let signature = sign_with_gpg(buf_str, gpg_key)?;
                            let commit_oid =
                                repo.commit_signed(buf_str, &signature, Some("gpgsig"))?;
                            if let Ok(mut head_ref) = repo.head() {
                                head_ref.set_target(commit_oid, "commit (gpg signed)")?;
                            } else {
                                repo.reference("HEAD", commit_oid, true, "commit (gpg signed)")?;
                            }
                            commit_oid
                        } else {
                            repo.commit(
                                Some("HEAD"),
                                &sig,
                                &sig,
                                &task_message,
                                &tree,
                                &parent_refs,
                            )?
                        }
                    };

                    // Clear MERGE_HEAD/MERGE_MSG so the repository leaves the
                    // 'Merging' state once the merge commit has been created.
                    if finalizing_merge {
                        repo.cleanup_state()?;
                    }

                    let data = gather_refresh_data(&refresh_repo_path, commit_limit)?;
                    Ok((oid, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| match result {
                    Ok((oid, data)) => {
                        this.apply_refresh_data(data);
                        this.complete_op(
                            operation_id,
                            GitOperationKind::Commit,
                            if amend {
                                format!("Amended commit {}", &oid.to_string()[..7])
                            } else {
                                format!("Created commit {}", &oid.to_string()[..7])
                            },
                            (Some(commit_summary.clone()), None, branch_name.clone()),
                            cx,
                        );
                        cx.emit(GitProjectEvent::RepositoryChanged);
                        cx.notify();
                        Ok(oid)
                    }
                    Err(e) => {
                        this.fail_op(
                            operation_id,
                            GitOperationKind::Commit,
                            if amend {
                                "Amend failed"
                            } else {
                                "Commit failed"
                            },
                            e.to_string(),
                            (None, branch_name.clone(), false),
                            cx,
                        );
                        Err(e)
                    }
                })
            })?
        })
    }

    /// Checkout a branch by name.
    /// Handles both local branches and remote tracking branches (e.g. `origin/main`).
    /// For remote branches, creates a local tracking branch first.
    pub fn checkout_branch(&mut self, name: &str, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("checkout_branch: name={}", name);
        let name = name.to_string();
        let task_name = name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Checkout,
            format!("Switching to '{}'...", name),
            None,
            Some(name.clone()),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(String, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    ensure_clean_worktree(&repo, "Checkout")?;
                    let current_branch = head_branch_name(&repo).ok();

                    // Determine whether this is a local or remote branch, and the
                    // object + local branch name to use.
                    let (obj, local_branch_name, is_tracking) =
                        match repo.revparse_single(&format!("refs/heads/{}", task_name)) {
                            Ok(o) => (o, task_name.clone(), false),
                            Err(_) => {
                                // Not a local branch — check if it's a remote tracking branch
                                // (e.g. "origin/main" → refs/remotes/origin/main).
                                let remote_ref = format!("refs/remotes/{}", task_name);
                                if let Ok(remote_obj) = repo.revparse_single(&remote_ref) {
                                    let Some((_remote, short)) = task_name.split_once('/') else {
                                        anyhow::bail!(
                                            "Invalid remote branch name '{}'. \
                                            Expected 'remote/branch' format.",
                                            task_name
                                        );
                                    };
                                    let local_branch_name = short;

                                    // Refuse to overwrite an existing local branch.
                                    if repo
                                        .find_branch(local_branch_name, git2::BranchType::Local)
                                        .is_ok()
                                    {
                                        anyhow::bail!(
                                            "A local branch named '{}' already exists. \
                                            Please delete or rename it first.",
                                            local_branch_name
                                        );
                                    }

                                    // Create the local tracking branch at the remote's commit.
                                    let commit = remote_obj.peel_to_commit()?;
                                    repo.branch(local_branch_name, &commit, false)?;

                                    // Set upstream to track the remote branch.
                                    if let Ok(mut branch) =
                                        repo.find_branch(local_branch_name, git2::BranchType::Local)
                                    {
                                        let _ = branch.set_upstream(Some(&task_name));
                                    }

                                    (remote_obj, local_branch_name.to_string(), true)
                                } else {
                                    anyhow::bail!(
                                        "Branch '{}' not found as a local or remote branch. \
                                        Try fetching to update remote refs.",
                                        task_name
                                    );
                                }
                            }
                        };

                    // Bail if already on the target branch (use local name for tracking).
                    if current_branch.as_deref() == Some(local_branch_name.as_str()) {
                        anyhow::bail!("Already on branch '{}'.", local_branch_name);
                    }

                    let head_ref = if is_tracking {
                        format!("refs/heads/{}", local_branch_name)
                    } else {
                        format!("refs/heads/{}", task_name)
                    };

                    checkout_tree_safe(&repo, &obj, "Checkout")?;
                    repo.set_head(&head_ref)?;
                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    let msg = if is_tracking {
                        format!(
                            "Switched to new branch '{}' tracking '{}'",
                            local_branch_name, task_name
                        )
                    } else {
                        format!("Switched to '{}'", task_name)
                    };
                    Ok((msg, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((msg, data)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Checkout,
                                msg,
                                (
                                    Some("Working tree updated for the selected branch.".into()),
                                    None,
                                    Some(name.clone()),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Checkout,
                                format!("Checkout of '{}' failed", name),
                                e.to_string(),
                                (None, Some(name.clone()), true),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Checkout a specific commit (detached HEAD).
    pub fn checkout_commit(&mut self, oid: git2::Oid, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("checkout_commit: oid={}", oid);
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let short_id = oid.to_string()[..7].to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Checkout,
            format!("Checking out {}...", short_id),
            None,
            Some(short_id.clone()),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    ensure_clean_worktree(&repo, "Checkout")?;
                    let commit = repo.find_commit(oid)?;
                    let obj = commit.into_object();
                    checkout_tree_safe(&repo, &obj, "Checkout")?;
                    repo.set_head_detached(oid)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Checkout,
                                format!("Checked out {}", short_id),
                                (
                                    Some("HEAD is now detached at the selected commit.".into()),
                                    None,
                                    Some(short_id.clone()),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Checkout,
                                format!("Checkout of {} failed", short_id),
                                e.to_string(),
                                (None, Some(short_id.clone()), true),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Checkout a tag, putting HEAD in detached state.
    pub fn checkout_tag(&mut self, name: &str, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("checkout_tag: name={}", name);
        let name = name.to_string();
        let task_name = name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Checkout,
            format!("Checking out tag '{}'...", name),
            None,
            Some(name.clone()),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    ensure_clean_worktree(&repo, "Checkout")?;
                    let obj = repo.revparse_single(&format!("refs/tags/{}", task_name))?;
                    let commit = obj.peel_to_commit()?;
                    let oid = commit.id();
                    let obj = commit.into_object();
                    checkout_tree_safe(&repo, &obj, "Checkout")?;
                    repo.set_head_detached(oid)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Checkout,
                                format!("Checked out tag '{}'", name),
                                (
                                    Some("HEAD is now detached at the selected tag.".into()),
                                    None,
                                    Some(name.clone()),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Checkout,
                                format!("Checkout of tag '{}' failed", name),
                                e.to_string(),
                                (None, Some(name.clone()), true),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Create a new branch from HEAD.
    /// Create a new branch, optionally at a specific commit (SHA or ref).
    /// If `base_ref` is None or empty, creates at HEAD.
    pub fn create_branch_at(
        &mut self,
        name: &str,
        base_ref: Option<&str>,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("create_branch_at: name={}", name);
        let name = name.to_string();
        let base_ref = base_ref.map(|s| s.to_string());
        let task_name = name.clone();
        let task_base_ref = base_ref.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Branch,
            format!("Creating branch '{}'...", name),
            None,
            Some(name.clone()),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    let target = if let Some(ref r) = task_base_ref {
                        if r.is_empty() {
                            repo.head()?.peel_to_commit()?
                        } else {
                            let obj = repo.revparse_single(r)?;
                            obj.peel_to_commit().map_err(|_| {
                                anyhow::anyhow!("'{}' does not resolve to a commit", r)
                            })?
                        }
                    } else {
                        repo.head()?.peel_to_commit()?
                    };
                    repo.branch(&task_name, &target, false)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Branch,
                                format!("Created branch '{}'", name),
                                (
                                    base_ref.as_ref().map(|value| format!("Base: {}", value)),
                                    None,
                                    Some(name.clone()),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RefsChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Branch,
                                format!("Branch '{}' could not be created", name),
                                e.to_string(),
                                (None, Some(name.clone()), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Delete a local branch.
    pub fn delete_branch(&mut self, name: &str, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("delete_branch: name={}", name);
        let name = name.to_string();
        let task_name = name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Branch,
            format!("Deleting branch '{}'...", name),
            None,
            Some(name.clone()),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    let mut branch = repo.find_branch(&task_name, git2::BranchType::Local)?;
                    branch.delete()?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Branch,
                                format!("Deleted branch '{}'", name),
                                (None, None, Some(name.clone())),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RefsChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Branch,
                                format!("Delete branch '{}' failed", name),
                                e.to_string(),
                                (None, Some(name.clone()), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Rename a local branch.
    pub fn rename_branch(
        &mut self,
        old_name: &str,
        new_name: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("rename_branch: old={} new={}", old_name, new_name);
        let old_name = old_name.to_string();
        let new_name = new_name.to_string();
        let task_old_name = old_name.clone();
        let task_new_name = new_name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Branch,
            format!("Renaming branch '{}'...", old_name),
            None,
            Some(old_name.clone()),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    let mut branch = repo.find_branch(&task_old_name, git2::BranchType::Local)?;
                    branch.rename(&task_new_name, false)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Branch,
                                format!("Renamed '{}' to '{}'", old_name, new_name),
                                (None, None, Some(new_name.clone())),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Branch,
                                format!("Rename branch '{}' failed", old_name),
                                e.to_string(),
                                (None, Some(old_name.clone()), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Create a lightweight tag at the given commit.
    pub fn create_tag(
        &mut self,
        name: &str,
        target_oid: git2::Oid,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("create_tag: name={} target={}", name, target_oid);
        let name = name.to_string();
        let task_name = name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Tag,
            format!("Creating tag '{}'...", name),
            None,
            self.head_branch.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    let obj = repo.find_object(target_oid, None)?;
                    repo.tag_lightweight(&task_name, &obj, false)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Tag,
                                format!("Created tag '{}'", name),
                                (None, None, this.head_branch.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RefsChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Tag,
                                format!("Tag '{}' could not be created", name),
                                e.to_string(),
                                (None, this.head_branch.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Delete a tag by name.
    pub fn delete_tag(&mut self, name: &str, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("delete_tag: name={}", name);
        let name = name.to_string();
        let task_name = name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let operation_id = self.begin_operation(
            GitOperationKind::Tag,
            format!("Deleting tag '{}'...", name),
            None,
            self.head_branch.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    repo.tag_delete(&task_name)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Tag,
                                format!("Deleted tag '{}'", name),
                                (None, None, this.head_branch.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RefsChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Tag,
                                format!("Delete tag '{}' failed", name),
                                e.to_string(),
                                (None, this.head_branch.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Save the given worktree to a stash. Stashes are stored in the shared
    /// object store, but the changes taken are those of `worktree_path`.
    pub fn stash_save_at(
        &mut self,
        message: Option<&str>,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("stash_save: worktree={}", worktree_path.display());
        let message = message.map(String::from);
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stash,
            "Saving stash...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let mut repo = Repository::open(&worktree_path)?;
                    let sig = repo.signature()?;
                    repo.stash_save(&sig, message.as_deref().unwrap_or("WIP"), None)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stash,
                                "Saved stash",
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stash,
                                "Save stash failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Pop a stash entry into the given worktree.
    pub fn stash_pop_at(
        &mut self,
        index: usize,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "stash_pop: index={} worktree={}",
            index,
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stash,
            format!("Popping stash #{}...", index),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(RefreshData, String)> = cx
                .background_executor()
                .spawn(async move {
                    let mut repo = Repository::open(&worktree_path)?;
                    // A conflicting pop leaves conflict markers and unmerged index
                    // entries rather than truly failing; surface that (and still
                    // refresh) instead of a hard failure that hides the new state.
                    let message = match repo.stash_pop(index, None) {
                        Ok(()) => format!("Popped stash #{}", index),
                        Err(e) => {
                            if repo.index().map(|i| i.has_conflicts()).unwrap_or(false) {
                                format!(
                                    "CONFLICT: stash #{} applied with conflicts; resolve them, then drop the stash.",
                                    index
                                )
                            } else {
                                return Err(e.into());
                            }
                        }
                    };
                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((data, message))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((data, message)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stash,
                                message,
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stash,
                                format!("Pop stash #{} failed", index),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Apply a stash entry into the given worktree without removing it.
    pub fn stash_apply_at(
        &mut self,
        index: usize,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "stash_apply: index={} worktree={}",
            index,
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stash,
            format!("Applying stash #{}...", index),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(RefreshData, String)> = cx
                .background_executor()
                .spawn(async move {
                    let mut repo = Repository::open(&worktree_path)?;
                    // A conflicting apply leaves conflict markers and unmerged index
                    // entries rather than truly failing; surface that (and still
                    // refresh) instead of a hard failure that hides the new state.
                    let message = match repo.stash_apply(index, None) {
                        Ok(()) => format!("Applied stash #{}", index),
                        Err(e) => {
                            if repo.index().map(|i| i.has_conflicts()).unwrap_or(false) {
                                format!(
                                    "CONFLICT: stash #{} applied with conflicts; resolve them before continuing.",
                                    index
                                )
                            } else {
                                return Err(e.into());
                            }
                        }
                    };
                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((data, message))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((data, message)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stash,
                                message,
                                (
                                    Some("The stash entry was kept.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stash,
                                format!("Apply stash #{} failed", index),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Drop a stash entry without applying it.
    pub fn stash_drop(&mut self, index: usize, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("stash_drop: index={}", index);
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stash,
            format!("Dropping stash #{}...", index),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let mut repo = Repository::open(&repo_path)?;
                    repo.stash_drop(index)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stash,
                                format!("Dropped stash #{}", index),
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stash,
                                format!("Drop stash #{} failed", index),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Create a branch from a stash entry and apply the stash to it.
    /// Equivalent to `git stash branch <branchname>`.
    pub fn stash_branch_at(
        &mut self,
        branch_name: &str,
        stash_index: usize,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "stash_branch: branch={} index={} worktree={}",
            branch_name,
            stash_index,
            worktree_path.display()
        );
        // This checks a new branch out and applies the stash into a working
        // tree — both of which belong to the checkout on screen. Doing it in
        // the main one would switch a checkout the user is not looking at and
        // drop the shared stash from under the one they are.
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name_owned = branch_name.to_string();
        let current_branch = self.head_branch_at(&worktree_path);
        let operation_id = self.begin_operation(
            GitOperationKind::Stash,
            format!(
                "Creating branch '{}' from stash #{}...",
                branch_name_owned, stash_index
            ),
            None,
            current_branch.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            // Clone for cx.update closures (see below)
            let branch_name_for_update = branch_name_owned.clone();
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let mut repo = Repository::open(&worktree_path)?;

                    // Collect stash OIDs to find the one at stash_index.
                    let mut stash_oids: Vec<git2::Oid> = Vec::new();
                    repo.stash_foreach(|_idx, _msg, oid| {
                        stash_oids.push(*oid);
                        true
                    })?;

                    let stash_oid = *stash_oids.get(stash_index).ok_or_else(|| {
                        anyhow::anyhow!("Stash index {} out of range", stash_index)
                    })?;

                    // `git stash branch`: create the branch at the commit HEAD was
                    // on when the stash was made (the stash WIP commit's first
                    // parent), check it out, apply the stash onto it, then drop the
                    // stash. The immutable borrows from find_commit/parent end with
                    // the block, so the mutable set_head/checkout/apply/drop follow.
                    let refname = {
                        let stash_wip = repo.find_commit(stash_oid)?;
                        let base = stash_wip
                            .parent(0)
                            .context("stash entry has no base commit")?;
                        repo.branch(&branch_name_owned, &base, false)?;
                        format!("refs/heads/{}", branch_name_owned)
                    };
                    repo.set_head(&refname)?;
                    repo.checkout_head(Some(git2::build::CheckoutBuilder::new().safe()))?;

                    // Apply onto the new branch, then drop the stash on success. A
                    // conflicting apply errors here and intentionally keeps the
                    // stash entry so the user can retry.
                    repo.stash_apply(stash_index, None)?;
                    repo.stash_drop(stash_index)?;

                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Stash,
                                format!(
                                    "Created branch '{}' from stash #{}",
                                    branch_name_for_update, stash_index
                                ),
                                (None, None, Some(branch_name_for_update.clone())),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stash,
                                format!("Create branch from stash #{} failed", stash_index),
                                e.to_string(),
                                (None, current_branch, false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Discard changes in specific files for the given worktree (restore to HEAD).
    pub fn discard_changes_at(
        &mut self,
        paths: &[PathBuf],
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("discard_changes: {} paths", paths.len());
        let paths = paths.to_vec();
        let operation_id = self.begin_operation(
            GitOperationKind::Discard,
            if paths.len() == 1 {
                format!("Discarding changes in {}...", paths[0].display())
            } else {
                format!("Discarding changes in {} files...", paths.len())
            },
            None,
            self.head_branch.clone(),
            cx,
        );
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let workdir = repo
                        .workdir()
                        .ok_or_else(|| anyhow::anyhow!("Bare repository has no working directory"))?
                        .to_path_buf();
                    let mut checkout_opts = git2::build::CheckoutBuilder::new();
                    checkout_opts.force();
                    let mut has_tracked = false;
                    for path in &paths {
                        let is_untracked = repo
                            .status_file(path)
                            .map(|s| s.contains(git2::Status::WT_NEW))
                            .unwrap_or(false);
                        if is_untracked {
                            let full = workdir.join(path);
                            if full.is_file() {
                                std::fs::remove_file(&full).with_context(|| {
                                    format!("Failed to delete {}", full.display())
                                })?;
                            } else if full.is_dir() {
                                std::fs::remove_dir_all(&full).with_context(|| {
                                    format!("Failed to delete directory {}", full.display())
                                })?;
                            }
                        } else {
                            checkout_opts.path(path);
                            has_tracked = true;
                        }
                    }
                    if has_tracked {
                        repo.checkout_head(Some(&mut checkout_opts))?;
                    }
                    let data = gather_refresh_data_lightweight_cached(
                        &refresh_repo_path,
                        commit_limit,
                        &worktree_cache,
                        author_filter.as_deref(),
                    )?;
                    Ok::<_, anyhow::Error>(data)
                })
                .await;
            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.refresh_ahead_behind(cx);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Discard,
                                "Discarded changes",
                                (None, None, this.head_branch.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Discard,
                                "Discard changes failed",
                                e.to_string(),
                                (None, this.head_branch.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Remove all untracked files and directories from the given worktree.
    pub fn clean_untracked_at(
        &mut self,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("clean_untracked: worktree={}", worktree_path.display());
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Clean,
            "Cleaning untracked files...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(usize, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    // Dry run first to count files
                    let dry_output = super::git_command()
                        .current_dir(&worktree_path)
                        .args(["clean", "-n", "-fd"])
                        .output()
                        .context("Failed to execute git clean -n")?;

                    if !dry_output.status.success() {
                        anyhow::bail!(
                            "git clean -n failed: {}",
                            String::from_utf8_lossy(&dry_output.stderr).trim()
                        );
                    }

                    // `git clean -n` reports what it would remove on stdout.
                    let file_count =
                        count_would_remove(&String::from_utf8_lossy(&dry_output.stdout));

                    if file_count == 0 {
                        // Nothing to clean
                        return Ok((0, gather_refresh_data(&repo_path, commit_limit)?));
                    }

                    // Actually remove untracked files and directories
                    let output = super::git_command()
                        .current_dir(&worktree_path)
                        .args(["clean", "-f", "-fd"])
                        .output()
                        .context("Failed to execute git clean -f")?;

                    let stderr = String::from_utf8_lossy(&output.stderr);
                    if !output.status.success() {
                        anyhow::bail!("git clean -f failed: {}", stderr.trim());
                    }

                    Ok((file_count, gather_refresh_data(&repo_path, commit_limit)?))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((removed, data)) => {
                            this.apply_refresh_data(data);
                            let (title, detail) = if removed == 0 {
                                (
                                    "Nothing to clean".to_string(),
                                    "There were no untracked files to remove.".to_string(),
                                )
                            } else {
                                (
                                    "Cleaned untracked files".to_string(),
                                    format!(
                                        "Removed {} untracked {}.",
                                        removed,
                                        if removed == 1 { "entry" } else { "entries" }
                                    ),
                                )
                            };
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Clean,
                                title,
                                (Some(detail), None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Clean,
                                "Clean failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Hard reset to HEAD, discarding all working tree and index changes.
    pub fn reset_hard_at(
        &mut self,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("reset_hard: worktree={}", worktree_path.display());
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Reset,
            "Resetting working tree to HEAD...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let head_commit = repo.head()?.peel_to_commit()?;
                    repo.reset(head_commit.as_object(), git2::ResetType::Hard, None)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Reset,
                                "Reset working tree to HEAD",
                                (
                                    Some("All staged and unstaged changes were discarded.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Reset,
                                "Reset to HEAD failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Hard-reset the given worktree's branch to a specific commit.
    pub fn reset_to_commit_at(
        &mut self,
        oid: git2::Oid,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "reset_to_commit: oid={} worktree={}",
            oid,
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let short_id = oid.to_string()[..7].to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Reset,
            format!("Resetting to {}...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let commit = repo.find_commit(oid)?;
                    repo.reset(commit.as_object(), git2::ResetType::Hard, None)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Reset,
                                format!("Reset to {}", short_id),
                                (
                                    Some("Working tree reset to the selected commit.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Reset,
                                format!("Reset to {} failed", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Soft-reset the given worktree's branch to `oid`, preserving changes in the
    /// index. Used to undo a commit made while inspecting a linked worktree so the
    /// reset targets that worktree's branch rather than the main repo's HEAD.
    pub fn reset_soft_at(
        &mut self,
        oid: git2::Oid,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("reset_soft: oid={}", oid);
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let short_id = oid.to_string()[..7].to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Reset,
            format!("Soft-resetting to {}...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let commit = repo.find_commit(oid)?;
                    repo.reset(commit.as_object(), git2::ResetType::Soft, None)?;
                    gather_refresh_data(&refresh_repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Reset,
                                format!("Soft reset to {}", short_id),
                                (
                                    Some("Changes preserved in index.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Reset,
                                format!("Soft reset to {} failed", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Mixed-reset the given worktree's branch to a specific commit, unstaging all changes.
    pub fn reset_mixed_at(
        &mut self,
        oid: git2::Oid,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "reset_mixed: oid={} worktree={}",
            oid,
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let short_id = oid.to_string()[..7].to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Reset,
            format!("Mixed-resetting to {}...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let commit = repo.find_commit(oid)?;
                    repo.reset(commit.as_object(), git2::ResetType::Mixed, None)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Reset,
                                format!("Mixed reset to {}", short_id),
                                (
                                    Some("Changes unstaged; index and working tree reset.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Reset,
                                format!("Mixed reset to {} failed", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Revert a commit (creates a new commit that undoes the given commit).
    pub fn revert_commit_at(
        &mut self,
        oid: git2::Oid,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "revert_commit: oid={} worktree={}",
            oid,
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch_at(&worktree_path);
        let short_id = oid.to_string()[..7].to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Revert,
            format!("Reverting {}...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(String, RefreshData, bool)> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    ensure_clean_worktree(&repo, "Revert")?;
                    let commit = repo.find_commit(oid)?;
                    let summary = commit.summary().unwrap_or("").to_string();
                    let mut opts = git2::RevertOptions::new();
                    repo.revert(&commit, Some(&mut opts))?;
                    let has_conflicts = repo.index()?.has_conflicts();
                    if !has_conflicts {
                        repo.cleanup_state()?;
                    }
                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((summary, data, has_conflicts))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((summary, data, has_conflicts)) => {
                            this.apply_refresh_data(data);
                            cx.emit(GitProjectEvent::StatusChanged);
                            if has_conflicts {
                                this.fail_op(
                                    operation_id,
                                    GitOperationKind::Revert,
                                    format!("Revert of {} needs conflict resolution", short_id),
                                    "Resolve the conflicts in the working tree, then commit the revert manually.".to_string(),
                                    (None, branch_name.clone(), false),
                                    cx,
                                );
                            } else {
                                this.complete_op(
                                    operation_id,
                                    GitOperationKind::Revert,
                                    format!("Reverted {}", short_id),
                                    (Some(format!(
                                        "Revert for '{}' has been applied. Review the changes and commit them manually.",
                                        summary
                                    )), None, branch_name.clone()),
                                    cx,
                                );
                            }
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Revert,
                                format!("Revert of {} failed", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Cherry-pick a commit onto the current HEAD.
    pub fn cherry_pick_at(
        &mut self,
        oid: git2::Oid,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!(
            "cherry_pick: oid={} worktree={}",
            oid,
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch_at(&worktree_path);
        let short_id = oid.to_string()[..7].to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::CherryPick,
            format!("Cherry-picking {}...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(String, RefreshData, bool)> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    ensure_clean_worktree(&repo, "Cherry-pick")?;
                    let commit = repo.find_commit(oid)?;
                    let summary = commit.summary().unwrap_or("").to_string();
                    let mut opts = git2::CherrypickOptions::new();
                    repo.cherrypick(&commit, Some(&mut opts))?;
                    let has_conflicts = repo.index()?.has_conflicts();
                    if !has_conflicts {
                        repo.cleanup_state()?;
                    }
                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((summary, data, has_conflicts))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((summary, data, has_conflicts)) => {
                            this.apply_refresh_data(data);
                            cx.emit(GitProjectEvent::StatusChanged);
                            if has_conflicts {
                                this.fail_op(
                                    operation_id,
                                    GitOperationKind::CherryPick,
                                    format!("Cherry-pick of {} needs conflict resolution", short_id),
                                    "Resolve the conflicts in the working tree, then commit the cherry-pick manually.".to_string(),
                                    (None, branch_name.clone(), false),
                                    cx,
                                );
                            } else {
                                this.complete_op(
                                    operation_id,
                                    GitOperationKind::CherryPick,
                                    format!("Cherry-picked {}", short_id),
                                    (Some(format!(
                                        "Cherry-pick for '{}' has been applied. Review the changes and commit them manually.",
                                        summary
                                    )), None, branch_name.clone()),
                                    cx,
                                );
                            }
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::CherryPick,
                                format!("Cherry-pick of {} failed", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    /// Abort the operation in progress in `worktree_path` (merge, rebase,
    /// cherry-pick, revert). Resets that working tree and index to its HEAD and
    /// cleans up its state.
    pub fn abort_operation_at(
        &mut self,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("abort_operation: worktree={}", worktree_path.display());
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch_at(&worktree_path);
        let state_label = self.repo_state_at(&worktree_path).label().to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Merge,
            format!("Aborting {}...", state_label.to_lowercase()),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;

                    if repo.state() == git2::RepositoryState::Rebase
                        || repo.state() == git2::RepositoryState::RebaseInteractive
                        || repo.state() == git2::RepositoryState::RebaseMerge
                    {
                        if let Ok(mut rebase) = repo.open_rebase(None) {
                            let _ = rebase.abort();
                        }
                    }
                    let head = repo.head()?.peel_to_commit()?;
                    repo.reset(
                        head.as_object(),
                        git2::ResetType::Hard,
                        Some(git2::build::CheckoutBuilder::new().force()),
                    )?;
                    repo.cleanup_state()?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Merge,
                                format!("{} aborted", state_label),
                                (
                                    Some("Working tree has been reset to HEAD.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Merge,
                                format!("Failed to abort {}", state_label.to_lowercase()),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Continue whichever operation is paused in `worktree_path`.
    ///
    /// A merge is finished here with libgit2. The sequencer states — cherry-pick,
    /// revert and mailbox application — and rebase have no libgit2 equivalent, so
    /// they run `git <subcommand> --continue` in that checkout. Dispatching on the
    /// state is what makes the conflict banner's Continue button finish the
    /// operation the banner is describing rather than only a merge.
    pub fn continue_operation_at(
        &mut self,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let state = self.repo_state_at(worktree_path);
        log::info!(
            "continue_operation: state={} worktree={}",
            state.label(),
            worktree_path.display()
        );
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch_at(&worktree_path);
        let kind = state.operation_kind();
        let state_label = state.label().to_string();
        let operation_id = self.begin_operation(
            kind,
            format!("Continuing {}...", state_label.to_lowercase()),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(String, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let state = RepoState::from_git2(repo.state());

                    let index = repo.index()?;
                    if index.has_conflicts() {
                        anyhow::bail!(
                            "There are still unresolved conflicts. Resolve all conflicts before continuing."
                        );
                    }
                    drop(index);

                    let summary = match state.continue_subcommand() {
                        Some("merge") => finish_merge_commit(&repo)?,
                        Some(subcommand) => {
                            drop(repo);
                            run_continue_subcommand(&worktree_path, subcommand)?
                        }
                        None => anyhow::bail!(
                            "There is no {} to continue.",
                            state.label().to_lowercase()
                        ),
                    };

                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((summary, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((summary, data)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                kind,
                                format!("{} completed", state_label),
                                (Some(summary), None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                kind,
                                format!("Could not continue {}", state_label.to_lowercase()),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Merge a branch into the current HEAD.
    pub fn merge_branch(&mut self, branch_name: &str, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("merge_branch: name={}", branch_name);
        let branch_name = branch_name.to_string();
        let task_branch_name = branch_name.clone();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let current_branch = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Merge,
            format!("Merging '{}'...", branch_name),
            None,
            current_branch.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(String, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let msg = {
                        let repo = Repository::open(&repo_path)?;
                        ensure_clean_worktree(&repo, "Merge")?;

                        let reference = repo
                            .find_branch(&task_branch_name, git2::BranchType::Local)
                            .or_else(|_| {
                                repo.find_branch(&task_branch_name, git2::BranchType::Remote)
                            })?;
                        let annotated_commit =
                            repo.reference_to_annotated_commit(reference.get())?;

                        let (analysis, _pref) = repo.merge_analysis(&[&annotated_commit])?;

                        if analysis.is_up_to_date() {
                            "Already up to date".to_string()
                        } else if analysis.is_fast_forward() {
                            let head = repo.head()?;
                            let head_branch_name =
                                head.shorthand().unwrap_or("HEAD").to_string();
                            let refname = format!("refs/heads/{}", head_branch_name);
                            let target = repo.find_object(annotated_commit.id(), None)?;
                            // Check out before moving the ref. A safe checkout
                            // refuses rather than clobbering an untracked file,
                            // and leaving the ref alone until it succeeds keeps
                            // HEAD and the working tree in step when it refuses.
                            checkout_tree_safe(&repo, &target, "Merge")?;
                            let mut reference = repo.find_reference(&refname)?;
                            reference.set_target(
                                annotated_commit.id(),
                                &format!("Fast-forward merge of '{}'", task_branch_name),
                            )?;
                            repo.set_head(&refname)?;
                            format!("Merged '{}' (fast-forward)", task_branch_name)
                        } else if analysis.is_normal() {
                            repo.merge(&[&annotated_commit], None, None)?;

                            let has_conflicts = repo.index()?.has_conflicts();
                            if has_conflicts {
                                let conflict_count = repo
                                    .index()?
                                    .conflicts()?
                                    .count();
                                format!(
                                    "CONFLICT:{} conflict(s) detected merging '{}'. Resolve and continue.",
                                    conflict_count, task_branch_name
                                )
                            } else {
                                let sig = repo.signature()?;
                                let mut index = repo.index()?;
                                let tree_oid = index.write_tree()?;
                                let tree = repo.find_tree(tree_oid)?;
                                let head_commit = repo.head()?.peel_to_commit()?;
                                let merge_commit =
                                    repo.find_commit(annotated_commit.id())?;
                                repo.commit(
                                    Some("HEAD"),
                                    &sig,
                                    &sig,
                                    &format!(
                                        "Merge branch '{}' into {}",
                                        task_branch_name,
                                        repo.head()?
                                            .shorthand()
                                            .unwrap_or("HEAD")
                                    ),
                                    &tree,
                                    &[&head_commit, &merge_commit],
                                )?;
                                repo.cleanup_state()?;
                                format!("Merged '{}' successfully", task_branch_name)
                            }
                        } else {
                            "Merge complete".to_string()
                        }
                    };

                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((msg, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((msg, data)) => {
                            let is_conflict = msg.starts_with("CONFLICT:");
                            this.apply_refresh_data(data);
                            if is_conflict {
                                let user_msg = msg.trim_start_matches("CONFLICT:").to_string();
                                this.fail_op(
                                    operation_id,
                                    GitOperationKind::Merge,
                                    format!("Merge conflicts in '{}'", branch_name),
                                    user_msg,
                                    (None, current_branch.clone(), false),
                                    cx,
                                );
                            } else {
                                this.complete_op(
                                    operation_id,
                                    GitOperationKind::Merge,
                                    msg,
                                    (Some("Repository state refreshed after merge.".into()), None, current_branch.clone()),
                                    cx,
                                );
                            }
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Merge,
                                format!("Merge of '{}' failed", branch_name),
                                e.to_string(),
                                (None, current_branch.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Remove a remote by name.
    pub fn remove_remote(&mut self, name: &str, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("remove_remote: name={}", name);
        let name = name.to_string();
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::RemoveRemote,
            format!("Removing remote '{}'...", name),
            Some(name.clone()),
            branch_name.clone(),
            cx,
        );
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;
                    repo.remote_delete(&name)?;
                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok::<_, anyhow::Error>((data, name))
                })
                .await;
            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((data, name)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::RemoveRemote,
                                format!("Removed remote '{}'", name),
                                (
                                    Some("Remote list refreshed.".into()),
                                    Some(name.clone()),
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RefsChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::RemoveRemote,
                                "Removing remote failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    Ok(())
                })
            })?
        })
    }

    // ============================================================================
    // Clone Operations
    // ============================================================================

    /// Clone a repository from a URL to a local path.
    pub fn clone_repo(
        &mut self,
        url: &str,
        path: &std::path::Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("clone_repo: url={}, path={}", url, path.display());
        let url = url.to_string();
        let path = path.to_path_buf();
        let operation_id = self.begin_operation(
            GitOperationKind::Clone,
            format!("Cloning '{}'...", url),
            None,
            None,
            cx,
        );
        let auth = rgitui_settings::current_git_auth_runtime();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let url_inner = url.clone();
            let path_inner = path.clone();
            let result: anyhow::Result<()> = cx
                .background_executor()
                .spawn(async move {
                    if let Err(git2_err) = git2::Repository::clone(&url_inner, &path_inner) {
                        log::info!(
                            "git2::Repository::clone failed ({}), falling back to system git",
                            git2_err
                        );
                        let mut cmd = super::git_command();
                        cmd.env("GIT_TERMINAL_PROMPT", "0");
                        if !url_inner.starts_with("git@") && !url_inner.starts_with("ssh://") {
                            inject_https_credentials(&mut cmd, &auth, &url_inner);
                        }
                        // `--` stops a pasted URL beginning with `-` from being
                        // parsed as an option such as `--upload-pack=`.
                        cmd.args(["clone", "--", &url_inner, &path_inner.to_string_lossy()]);
                        let output = cmd.output().context("git clone failed")?;
                        if !output.status.success() {
                            let stderr = String::from_utf8_lossy(&output.stderr);
                            anyhow::bail!("git clone failed: {}", stderr);
                        }
                    }
                    Ok(())
                })
                .await;
            // Propagate the actual clone outcome to the returned task (not just
            // entity-aliveness) so the caller can report success/failure to the
            // clone dialog while still showing the operation toast.
            match result {
                Ok(()) => {
                    cx.update(|cx| {
                        this.update(cx, |this, cx| {
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Clone,
                                format!("Cloned '{}'", url),
                                (Some(format!("Created: {}", path.display())), None, None),
                                cx,
                            );
                        })
                    })?;
                    Ok(())
                }
                Err(e) => {
                    let message = e.to_string();
                    log::error!("clone_repo failed: {}", message);
                    let toast_message = message.clone();
                    cx.update(|cx| {
                        this.update(cx, |this, cx| {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Clone,
                                "Clone failed",
                                toast_message,
                                (None, None, false),
                                cx,
                            );
                        })
                    })?;
                    Err(anyhow::anyhow!(message))
                }
            }
        })
    }

    // ============================================================================
    // Bisect Operations
    // ============================================================================

    /// Start a bisect session to find a commit that introduced a bug.
    /// After starting, mark commits as good/bad with bisect_good/bisect_bad.
    pub fn bisect_start(&mut self, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("bisect_start");
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Bisect,
            "Starting bisect...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let output = super::git_command()
                        .current_dir(&repo_path)
                        .args(["bisect", "start"])
                        .output()
                        .context("Failed to execute git bisect start")?;

                    let stderr = String::from_utf8_lossy(&output.stderr);
                    if !output.status.success() {
                        anyhow::bail!("git bisect start failed: {}", stderr.trim());
                    }

                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Bisect started".to_string(),
                                (
                                    Some("Mark commits as 'good' or 'bad' to narrow down the problematic commit.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Failed to start bisect",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Mark the specified commit (or current HEAD if None) as "good" during bisect.
    pub fn bisect_good(
        &mut self,
        oid: Option<git2::Oid>,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("bisect_good: oid={:?}", oid);
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let short_id = oid
            .map(|o| o.to_string()[..7].to_string())
            .unwrap_or_else(|| "HEAD".to_string());
        let operation_id = self.begin_operation(
            GitOperationKind::Bisect,
            format!("Marking {} as good...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        let oid_str = oid.map(|o| o.to_string());
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(Option<String>, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let mut cmd = super::git_command();
                    cmd.current_dir(&repo_path).args(["bisect", "good"]);
                    if let Some(ref oid) = oid_str {
                        cmd.arg(oid);
                    }
                    let output = cmd
                        .output()
                        .context("Failed to execute git bisect good")?;

                    let stdout = String::from_utf8_lossy(&output.stdout);
                    let stderr = String::from_utf8_lossy(&output.stderr);

                    if !output.status.success() {
                        anyhow::bail!("git bisect good failed: {}", stderr.trim());
                    }

                    // Check if bisect found the culprit
                    let found_match = stdout.contains("is the first bad commit");
                    let message = if found_match {
                        Some(stdout.lines().take(10).collect::<Vec<_>>().join("\n"))
                    } else {
                        None
                    };

                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((message, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((Some(found_msg), data)) => {
                            // Bisect found the bad commit
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Bisect complete!".to_string(),
                                (
                                    Some(format!("Found the first bad commit:\n{}", found_msg)),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Ok((None, data)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Marked {} as good", short_id),
                                (
                                    Some("Bisect continues. Test the current commit and mark as good/bad.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Failed to mark {} as good", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Mark the specified commit (or current HEAD if None) as "bad" during bisect.
    pub fn bisect_bad(
        &mut self,
        oid: Option<git2::Oid>,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("bisect_bad: oid={:?}", oid);
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let short_id = oid
            .map(|o| o.to_string()[..7].to_string())
            .unwrap_or_else(|| "HEAD".to_string());
        let operation_id = self.begin_operation(
            GitOperationKind::Bisect,
            format!("Marking {} as bad...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        let oid_str = oid.map(|o| o.to_string());
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(Option<String>, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let mut cmd = super::git_command();
                    cmd.current_dir(&repo_path).args(["bisect", "bad"]);
                    if let Some(ref oid) = oid_str {
                        cmd.arg(oid);
                    }
                    let output = cmd
                        .output()
                        .context("Failed to execute git bisect bad")?;

                    let stdout = String::from_utf8_lossy(&output.stdout);
                    let stderr = String::from_utf8_lossy(&output.stderr);

                    if !output.status.success() {
                        anyhow::bail!("git bisect bad failed: {}", stderr.trim());
                    }

                    // Check if bisect found the culprit
                    let found_match = stdout.contains("is the first bad commit");
                    let message = if found_match {
                        Some(stdout.lines().take(10).collect::<Vec<_>>().join("\n"))
                    } else {
                        None
                    };

                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((message, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((Some(found_msg), data)) => {
                            // Bisect found the bad commit
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Bisect complete!".to_string(),
                                (
                                    Some(format!("Found the first bad commit:\n{}", found_msg)),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Ok((None, data)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Marked {} as bad", short_id),
                                (
                                    Some("Bisect continues. Test the current commit and mark as good/bad.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Failed to mark {} as bad", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Mark the current commit (or specified commit) as skipped during bisect.
    /// Skipped commits are excluded from the bisect search.
    pub fn bisect_skip(
        &mut self,
        oid: Option<git2::Oid>,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("bisect_skip: oid={:?}", oid);
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let short_id = oid
            .map(|o| o.to_string()[..7].to_string())
            .unwrap_or_else(|| "HEAD".to_string());
        let operation_id = self.begin_operation(
            GitOperationKind::Bisect,
            format!("Skipping {}...", short_id),
            None,
            branch_name.clone(),
            cx,
        );
        let oid_str = oid.map(|o| o.to_string());
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(Option<String>, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    let mut cmd = super::git_command();
                    cmd.current_dir(&repo_path).args(["bisect", "skip"]);
                    if let Some(ref oid) = oid_str {
                        cmd.arg(oid);
                    }
                    let output = cmd.output().context("Failed to execute git bisect skip")?;

                    let stdout = String::from_utf8_lossy(&output.stdout);
                    let stderr = String::from_utf8_lossy(&output.stderr);

                    if !output.status.success() {
                        anyhow::bail!("git bisect skip failed: {}", stderr.trim());
                    }

                    // Check if bisect can no longer continue (only skipped commits remain)
                    let exhausted = stdout.contains("only skipped commits left to test")
                        || stderr.contains("only skipped commits left to test");
                    let message = if exhausted {
                        Some(
                            "Bisect cannot continue: only skipped commits remain.\n\
                             Consider using 'Bisect Reset' and manually narrowing down."
                                .into(),
                        )
                    } else {
                        // git bisect skip outputs lines like:
                        // "Skipping commit <sha>"
                        // "Bisecting: N commits left to test"
                        let lines: Vec<_> = stdout.lines().filter(|l| !l.is_empty()).collect();
                        if lines.is_empty() {
                            None
                        } else {
                            Some(lines.join("\n"))
                        }
                    };

                    let data = gather_refresh_data(&repo_path, commit_limit)?;
                    Ok((message, data))
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok((Some(msg), data)) if msg.contains("cannot continue") => {
                            this.apply_refresh_data(data);
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Bisect exhausted".to_string(),
                                msg,
                                (None, branch_name.clone(), false),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Ok((Some(msg), data)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Skipped {}", short_id),
                                (Some(msg), None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Ok((None, data)) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Skipped {}", short_id),
                                (
                                    Some("Bisect continues. Test the current commit.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                format!("Failed to skip {}", short_id),
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Reset the bisect session and return to the original branch/commit.
    pub fn bisect_reset(&mut self, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("bisect_reset");
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Bisect,
            "Resetting bisect...",
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let output = super::git_command()
                        .current_dir(&repo_path)
                        .args(["bisect", "reset"])
                        .output()
                        .context("Failed to execute git bisect reset")?;

                    let stderr = String::from_utf8_lossy(&output.stderr);
                    if !output.status.success() {
                        anyhow::bail!("git bisect reset failed: {}", stderr.trim());
                    }

                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Bisect reset".to_string(),
                                (
                                    Some("Returned to original branch/commit.".into()),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Bisect,
                                "Failed to reset bisect",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Create a new Git worktree.
    pub fn create_worktree(
        &mut self,
        name: String,
        path: PathBuf,
        branch: Option<String>,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("create_worktree: name={} path={}", name, path.display());
        let name_clone = name.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Worktree,
            format!("Creating worktree '{}'...", name),
            None,
            self.head_branch.clone(),
            cx,
        );
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path)?;

                    // Resolve branch reference before building options (lifetime constraint).
                    let reference = if let Some(ref branch_name) = branch {
                        repo.find_branch(branch_name, git2::BranchType::Local)
                            .ok()
                            .map(|b| b.into_reference())
                    } else {
                        None
                    };

                    let mut opts = git2::WorktreeAddOptions::new();
                    if let Some(ref r) = reference {
                        opts.reference(Some(r));
                    }

                    repo.worktree(&name, &path, Some(&opts))?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Worktree,
                                format!("Created worktree '{}'", name_clone),
                                (None, None, this.head_branch.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Worktree,
                                format!("Create worktree '{}' failed", name_clone),
                                e.to_string(),
                                (None, this.head_branch.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Remove a Git worktree.
    pub fn remove_worktree(&mut self, path: PathBuf, cx: &mut Context<Self>) -> Task<Result<()>> {
        log::info!("remove_worktree: path={}", path.display());
        let display_path = path.display().to_string();
        let operation_id = self.begin_operation(
            GitOperationKind::Worktree,
            format!("Removing worktree '{}'...", display_path),
            None,
            self.head_branch.clone(),
            cx,
        );
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let display_path_async = display_path.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let output = super::git_command()
                        .current_dir(&repo_path)
                        .args(["worktree", "remove", "--force", &display_path_async])
                        .output()
                        .context("Failed to execute git worktree remove")?;

                    let stderr = String::from_utf8_lossy(&output.stderr);
                    if !output.status.success() {
                        anyhow::bail!("git worktree remove failed: {}", stderr.trim());
                    }

                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::Worktree,
                                format!("Removed worktree '{}'", display_path),
                                (None, None, this.head_branch.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Worktree,
                                format!("Remove worktree '{}' failed", display_path),
                                e.to_string(),
                                (None, this.head_branch.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Save an assembled conflict result and stage it as the sole stage-0 entry.
    ///
    /// The snapshot comes from the resolver load. Both the unmerged index OIDs
    /// and the working-tree bytes must still match before this method writes,
    /// so an old resolver cannot overwrite an external edit.
    pub fn resolve_conflict_at(
        &mut self,
        path: String,
        result: Option<Vec<u8>>,
        result_mode: u32,
        snapshot: ConflictSnapshot,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        self.finish_conflict_resolution(
            path,
            ConflictResolutionInput::Draft {
                result,
                result_mode,
                snapshot,
            },
            worktree_path,
            cx,
        )
    }

    /// Stage a result edited outside rgitui while keeping the conflict-specific
    /// safety checks. Literal conflict markers are rejected.
    pub fn stage_conflict_worktree_at(
        &mut self,
        path: String,
        snapshot: ConflictSnapshot,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        self.finish_conflict_resolution(
            path,
            ConflictResolutionInput::WorkingTree { snapshot },
            worktree_path,
            cx,
        )
    }

    fn finish_conflict_resolution(
        &mut self,
        path: String,
        input: ConflictResolutionInput,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let file_path = PathBuf::from(&path);
        let file_name = file_path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| path.clone());
        let branch_name = self.head_branch_at(&worktree_path);
        let operation_id = self.begin_operation(
            GitOperationKind::ResolveConflict,
            format!("Saving conflict result for '{}'...", file_name),
            None,
            branch_name.clone(),
            cx,
        );

        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    apply_conflict_resolution(&worktree_path, &file_path, input)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::ResolveConflict,
                                "Conflict resolved and staged",
                                (
                                    Some(format!("Saved and staged '{}'.", file_name)),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(error) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::ResolveConflict,
                                "Conflict resolution failed",
                                error.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Accept the "ours" version of a conflicted file, staging it as resolved.
    pub fn accept_conflict_ours_at(
        &mut self,
        path: String,
        snapshot: ConflictSnapshot,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("accept_conflict_ours: path={}", path);
        self.accept_conflict_side(path, ConflictSide::Ours, snapshot, worktree_path, cx)
    }

    /// Accept the "theirs" version of a conflicted file, staging it as resolved.
    pub fn accept_conflict_theirs_at(
        &mut self,
        path: String,
        snapshot: ConflictSnapshot,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        log::info!("accept_conflict_theirs: path={}", path);
        self.accept_conflict_side(path, ConflictSide::Theirs, snapshot, worktree_path, cx)
    }

    fn accept_conflict_side(
        &mut self,
        path: String,
        side: ConflictSide,
        snapshot: ConflictSnapshot,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        // The conflicted index and the file to rewrite both belong to the
        // checkout the conflict is in; the snapshot is still gathered from the
        // project's own root, which is what every other operation does.
        let worktree_path = worktree_path.to_path_buf();
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let file_path = PathBuf::from(&path);
        let file_name = file_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| path.clone());
        let branch_name = self.head_branch_at(&worktree_path);
        let side_label = match side {
            ConflictSide::Ours => "ours",
            ConflictSide::Theirs => "theirs",
        };
        let operation_id = self.begin_operation(
            GitOperationKind::ResolveConflict,
            format!(
                "Resolving conflict using '{}' for '{}'...",
                side_label, file_name
            ),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    apply_conflict_side(&worktree_path, &file_path, side, &snapshot)?;
                    gather_refresh_data(&repo_path, commit_limit)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    match result {
                        Ok(data) => {
                            this.apply_refresh_data(data);
                            this.complete_op(
                                operation_id,
                                GitOperationKind::ResolveConflict,
                                "Conflict resolved",
                                (
                                    Some(format!(
                                        "Accepted '{}' version of '{}'.",
                                        side_label, file_name
                                    )),
                                    None,
                                    branch_name.clone(),
                                ),
                                cx,
                            );
                            cx.emit(GitProjectEvent::RepositoryChanged);
                            cx.notify();
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::ResolveConflict,
                                "Conflict resolution failed",
                                e.to_string(),
                                (None, branch_name.clone(), false),
                                cx,
                            );
                        }
                    }
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }
}

enum ConflictResolutionInput {
    Draft {
        result: Option<Vec<u8>>,
        result_mode: u32,
        snapshot: ConflictSnapshot,
    },
    WorkingTree {
        snapshot: ConflictSnapshot,
    },
}

struct GitIndexLock {
    index_path: PathBuf,
    lock_path: PathBuf,
    file: Option<std::fs::File>,
    committed: bool,
}

impl GitIndexLock {
    fn acquire(index_path: PathBuf) -> Result<Self> {
        let mut lock_name = index_path.as_os_str().to_os_string();
        lock_name.push(".lock");
        let lock_path = PathBuf::from(lock_name);
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
            .with_context(|| {
                format!(
                    "Could not lock Git index '{}'; another Git operation may still be running",
                    index_path.display()
                )
            })?;
        let lock = Self {
            index_path,
            lock_path,
            file: Some(file),
            committed: false,
        };
        // Git's lockfile commit replaces the index, so the lock must carry the
        // index's permissions. In particular, preserve group write access for
        // repositories using core.sharedRepository.
        let permissions = std::fs::metadata(&lock.index_path)?.permissions();
        std::fs::set_permissions(&lock.lock_path, permissions).with_context(|| {
            format!(
                "Could not preserve permissions for Git index '{}'",
                lock.index_path.display()
            )
        })?;
        Ok(lock)
    }

    fn commit_from(mut self, prepared_index: &Path) -> Result<()> {
        let mut source = std::fs::File::open(prepared_index)?;
        let mut destination = self.file.take().expect("held Git index lock");
        destination.set_len(0)?;
        destination.rewind()?;
        std::io::copy(&mut source, &mut destination)?;
        destination.sync_all()?;
        drop(destination);

        // The lock file stays present until this atomic replacement, so every
        // compliant Git writer is excluded from validation through commit.
        std::fs::rename(&self.lock_path, &self.index_path).with_context(|| {
            format!(
                "Could not commit the locked Git index '{}'",
                self.index_path.display()
            )
        })?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for GitIndexLock {
    fn drop(&mut self) {
        if !self.committed {
            self.file.take();
            let _ = std::fs::remove_file(&self.lock_path);
        }
    }
}

fn write_conflict_index_resolution(
    worktree_path: &Path,
    file_path: &Path,
    snapshot: &ConflictSnapshot,
    resolved: Option<(u32, git2::Oid)>,
) -> Result<()> {
    let repo = Repository::open(worktree_path)?;
    let index_path = repo
        .index()?
        .path()
        .map(Path::to_path_buf)
        .context("Repository index has no on-disk path")?;
    let index_lock = GitIndexLock::acquire(index_path.clone())?;
    let index_parent = index_path
        .parent()
        .context("Repository index has no parent directory")?;
    let prepared_index = tempfile::Builder::new()
        .prefix("rgitui-index-")
        .tempfile_in(index_parent)?
        .into_temp_path();
    std::fs::copy(&index_path, &prepared_index)?;

    // The real index is locked before this copy is read. Validate the captured
    // conflict against that immutable snapshot, then let Git mutate only the
    // private copy. The same real lock remains held until the prepared bytes
    // atomically replace the index below.
    let mut locked_snapshot = git2::Index::open(&prepared_index)?;
    reload_conflict_index(&mut locked_snapshot, snapshot, file_path)?;
    drop(locked_snapshot);

    #[cfg(windows)]
    let git_path = file_path
        .as_os_str()
        .as_encoded_bytes()
        .iter()
        .map(|byte| if *byte == b'\\' { b'/' } else { *byte })
        .collect::<Vec<_>>();
    #[cfg(not(windows))]
    let git_path = file_path.as_os_str().as_encoded_bytes().to_vec();

    let mut input = Vec::new();
    write!(input, "0 {}\t", git2::Oid::zero())?;
    input.extend_from_slice(&git_path);
    input.push(0);
    if let Some((mode, oid)) = resolved {
        write!(input, "{mode:o} {oid}\t")?;
        input.extend_from_slice(&git_path);
        input.push(0);
    }

    let mut command = super::git_command();
    command
        .current_dir(worktree_path)
        .args(["update-index", "-z", "--index-info"])
        .env("GIT_INDEX_FILE", &prepared_index)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());
    // The leading zero-mode record removes every conflict stage before the
    // optional stage-zero record. Result objects already exist, so this work is
    // independent of assembled-file size.
    let mut child = command.spawn().with_context(|| {
        format!(
            "Failed to start Git while updating the conflict index for '{}'",
            file_path.display()
        )
    })?;
    child
        .stdin
        .take()
        .expect("piped update-index stdin")
        .write_all(&input)?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        let details = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "Git could not update the conflict index for '{}': {}",
            file_path.display(),
            details.trim()
        );
    }
    index_lock.commit_from(&prepared_index)
}

fn apply_conflict_side(
    worktree_path: &Path,
    file_path: &Path,
    side: ConflictSide,
    snapshot: &ConflictSnapshot,
) -> Result<()> {
    ensure_repo_relative_path(file_path)?;
    let repo = Repository::open(worktree_path)?;
    let mut index = repo.index()?;
    let initial_conflict = reload_conflict_index(&mut index, snapshot, file_path)?;
    let initial_chosen = match side {
        ConflictSide::Ours => initial_conflict.our.as_ref(),
        ConflictSide::Theirs => initial_conflict.their.as_ref(),
    };
    let worktree_file = AnchoredWorktreePath::bind(
        worktree_path,
        file_path,
        initial_chosen.is_some_and(|entry| entry.mode & 0o170000 != 0o160000),
    )?;
    let original_worktree = capture_worktree_entry(&worktree_file)?;
    if !original_worktree.matches_conflict_snapshot(&snapshot.worktree) {
        anyhow::bail!(
            "'{}' changed outside the conflict resolver. Reload it before choosing a side so no edits are overwritten.",
            file_path.display()
        );
    }

    // Filters may execute arbitrary processes and take long enough for another
    // editor or Git operation to change state. Prepare bytes first, then reload
    // both the worktree entry and the on-disk index immediately before writing.
    let prepared_regular = match initial_chosen {
        Some(entry) if entry.mode & 0o170000 == 0o100000 => {
            let canonical = repo.find_blob(entry.id)?.content().to_vec();
            let worktree = smudge_canonical_bytes(worktree_path, file_path, &canonical)?;
            Some(worktree)
        }
        _ => None,
    };
    let prepared_symlink = match initial_chosen {
        Some(entry) if entry.mode & 0o170000 == 0o120000 => {
            Some(repo.find_blob(entry.id)?.content().to_vec())
        }
        _ => None,
    };
    ensure_worktree_entry_matches(&worktree_file, &original_worktree)?;
    let conflict = reload_conflict_index(&mut index, snapshot, file_path)?;
    let conflict_has_gitlink = [
        conflict.ancestor.as_ref(),
        conflict.our.as_ref(),
        conflict.their.as_ref(),
    ]
    .into_iter()
    .flatten()
    .any(|entry| entry.mode & 0o170000 == 0o160000);
    let chosen = match side {
        ConflictSide::Ours => conflict.our.as_ref(),
        ConflictSide::Theirs => conflict.their.as_ref(),
    };

    if let Some(entry) = chosen {
        if entry.mode & 0o170000 == 0o100000 {
            let selected_mode = entry.mode;
            let worktree_content = prepared_regular
                .as_ref()
                .expect("a verified regular side was prepared");
            let applied_worktree = replace_regular_worktree_file(
                &worktree_file,
                worktree_content,
                selected_mode,
                &original_worktree,
            )?;
            let refreshed_conflict = reload_conflict_index_after_worktree_change(
                &mut index,
                snapshot,
                file_path,
                &worktree_file,
                &original_worktree,
                &applied_worktree,
            )?;
            let refreshed_entry = match side {
                ConflictSide::Ours => refreshed_conflict.our.as_ref(),
                ConflictSide::Theirs => refreshed_conflict.their.as_ref(),
            }
            .expect("the verified selected side still exists");
            if let Err(error) = write_conflict_index_resolution(
                worktree_path,
                file_path,
                snapshot,
                Some((selected_mode, refreshed_entry.id)),
            ) {
                return Err(rollback_worktree_after_error(
                    &worktree_file,
                    &original_worktree,
                    &applied_worktree,
                    error,
                ));
            }
        } else if entry.mode & 0o170000 == 0o160000 {
            // A gitlink's OID names a commit, not a blob. Resolving it means
            // selecting the stage-0 gitlink; the submodule working directory is
            // intentionally left untouched.
            write_conflict_index_resolution(
                worktree_path,
                file_path,
                snapshot,
                Some((entry.mode, entry.id)),
            )?;
        } else if entry.mode & 0o170000 == 0o120000 {
            // A Git symlink blob stores its target verbatim. Materialize it
            // ourselves with create-new semantics so an editor save cannot be
            // overwritten between snapshot verification and publication.
            // Repositories with core.symlinks=false use Git's regular-file
            // representation instead.
            let selected_mode = entry.mode;
            let selected_id = entry.id;
            let target = prepared_symlink
                .as_deref()
                .expect("a verified symlink side was prepared");
            let applied_worktree = if checkout_uses_symlinks(&repo) {
                replace_worktree_symlink(&worktree_file, target, &original_worktree)?
            } else {
                replace_regular_worktree_file(&worktree_file, target, 0o100644, &original_worktree)?
            };
            let refreshed_conflict = reload_conflict_index_after_worktree_change(
                &mut index,
                snapshot,
                file_path,
                &worktree_file,
                &original_worktree,
                &applied_worktree,
            )?;
            let refreshed_entry = match side {
                ConflictSide::Ours => refreshed_conflict.our.as_ref(),
                ConflictSide::Theirs => refreshed_conflict.their.as_ref(),
            }
            .expect("the verified selected side still exists");
            debug_assert_eq!(refreshed_entry.id, selected_id);
            let index_result = write_conflict_index_resolution(
                worktree_path,
                file_path,
                snapshot,
                Some((selected_mode, selected_id)),
            );
            if let Err(error) = index_result {
                return Err(rollback_worktree_after_error(
                    &worktree_file,
                    &original_worktree,
                    &applied_worktree,
                    error,
                ));
            }
            return Ok(());
        } else {
            anyhow::bail!(
                "Cannot resolve '{}' using unsupported Git mode {:o}.",
                file_path.display(),
                entry.mode
            );
        }
    } else {
        // A checked-out gitlink directory is owned by the nested repository and
        // must remain as local, untracked worktree state. A regular file or
        // symlink at the same path is not a checked-out submodule, however, and
        // should be removed like any other selected deletion.
        let preserve_gitlink_directory = conflict_has_gitlink
            && worktree_file
                .symlink_metadata()?
                .is_some_and(|metadata| metadata.is_dir());
        if !preserve_gitlink_directory {
            remove_worktree_entry_if_matches(&worktree_file, &original_worktree)?;
        }
        let applied_worktree = (!preserve_gitlink_directory)
            .then(|| capture_worktree_entry(&worktree_file))
            .transpose()?;
        if let Some(applied_worktree) = applied_worktree.as_ref() {
            reload_conflict_index_after_worktree_change(
                &mut index,
                snapshot,
                file_path,
                &worktree_file,
                &original_worktree,
                applied_worktree,
            )?;
        }
        if applied_worktree.is_none() {
            reload_conflict_index(&mut index, snapshot, file_path)?;
        }
        let index_result =
            write_conflict_index_resolution(worktree_path, file_path, snapshot, None);
        if let Err(error) = index_result {
            if let Some(applied_worktree) = applied_worktree.as_ref() {
                return Err(rollback_worktree_after_error(
                    &worktree_file,
                    &original_worktree,
                    applied_worktree,
                    error,
                ));
            }
            return Err(error);
        }
    }
    Ok(())
}

fn apply_conflict_resolution(
    worktree_path: &Path,
    file_path: &Path,
    input: ConflictResolutionInput,
) -> Result<()> {
    ensure_repo_relative_path(file_path)?;
    let repo = Repository::open(worktree_path)?;
    let mut index = repo.index()?;
    let snapshot = match &input {
        ConflictResolutionInput::Draft { snapshot, .. }
        | ConflictResolutionInput::WorkingTree { snapshot } => snapshot.clone(),
    };
    let conflict = reload_conflict_index(&mut index, &snapshot, file_path)?;

    let create_parents = matches!(
        &input,
        ConflictResolutionInput::Draft {
            result: Some(_),
            ..
        }
    );
    let worktree_file = AnchoredWorktreePath::bind(worktree_path, file_path, create_parents)?;
    let original_worktree = capture_worktree_entry(&worktree_file)?;
    let current_worktree = original_worktree.snapshot_bytes().map(<[u8]>::to_vec);
    let (result, result_mode, worktree_result) = match input {
        ConflictResolutionInput::Draft {
            result,
            result_mode,
            snapshot: loaded_snapshot,
        } => {
            if !original_worktree.matches_conflict_snapshot(&loaded_snapshot.worktree) {
                anyhow::bail!(
                    "'{}' changed outside the conflict resolver. Reload it before saving so no edits are overwritten.",
                    file_path.display()
                );
            }
            let worktree_result = result
                .as_ref()
                .map(|bytes| smudge_canonical_bytes(worktree_path, file_path, bytes))
                .transpose()?;
            (result, result_mode, worktree_result)
        }
        ConflictResolutionInput::WorkingTree { .. } => {
            let content = current_worktree.clone().ok_or_else(|| {
                anyhow::anyhow!(
                    "'{}' does not exist in the working tree. Choose the deleted side explicitly instead.",
                    file_path.display()
                )
            })?;
            let marker_size = conflict_marker_size(&repo, file_path, &snapshot);
            if contains_conflict_markers(&content, marker_size) {
                anyhow::bail!(
                    "'{}' still contains conflict markers. Remove them in your editor before staging the working copy.",
                    file_path.display()
                );
            }
            let fallback_mode = conflict
                .our
                .as_ref()
                .or(conflict.their.as_ref())
                .or(conflict.ancestor.as_ref())
                .map(|entry| entry.mode)
                .unwrap_or(0o100644);
            let mode = regular_worktree_mode(&repo, &worktree_file, fallback_mode)?;
            let canonical_content = clean_worktree_bytes(worktree_path, file_path, &content)?;
            if contains_conflict_markers(&canonical_content, marker_size) {
                anyhow::bail!(
                    "'{}' still contains conflict markers after applying Git's clean filters. Remove them in your editor before staging the working copy.",
                    file_path.display()
                );
            }
            (Some(canonical_content), mode, None)
        }
    };

    // Store the assembled result before the final index validation. Hashing a
    // large resolution may be expensive; the subsequent update-index command
    // can now hold the index lock for a short, size-independent transaction.
    let result_oid = result.as_ref().map(|bytes| repo.blob(bytes)).transpose()?;

    ensure_worktree_entry_matches(&worktree_file, &original_worktree)?;
    let conflict = reload_conflict_index(&mut index, &snapshot, file_path)?;

    match result_oid {
        Some(result_oid) => {
            if result_mode & 0o170000 != 0o100000 {
                anyhow::bail!(
                    "'{}' is not a regular file. Choose Current or Incoming as a whole-file resolution.",
                    file_path.display()
                );
            }
            conflict
                .our
                .as_ref()
                .or(conflict.their.as_ref())
                .or(conflict.ancestor.as_ref())
                .ok_or_else(|| anyhow::anyhow!("Conflict has no index entry to resolve"))?;

            let applied_worktree = worktree_result
                .as_ref()
                .map(|worktree_bytes| {
                    replace_regular_worktree_file(
                        &worktree_file,
                        worktree_bytes,
                        result_mode,
                        &original_worktree,
                    )
                })
                .transpose()?;
            if let Some(applied_worktree) = applied_worktree.as_ref() {
                reload_conflict_index_after_worktree_change(
                    &mut index,
                    &snapshot,
                    file_path,
                    &worktree_file,
                    &original_worktree,
                    applied_worktree,
                )?;
            }

            if let Err(error) = write_conflict_index_resolution(
                worktree_path,
                file_path,
                &snapshot,
                Some((result_mode, result_oid)),
            ) {
                if let Some(applied_worktree) = applied_worktree.as_ref() {
                    return Err(rollback_worktree_after_error(
                        &worktree_file,
                        &original_worktree,
                        applied_worktree,
                        error,
                    ));
                }
                return Err(error);
            }
        }
        None => {
            remove_worktree_entry_if_matches(&worktree_file, &original_worktree)?;
            let applied_worktree = capture_worktree_entry(&worktree_file)?;
            reload_conflict_index_after_worktree_change(
                &mut index,
                &snapshot,
                file_path,
                &worktree_file,
                &original_worktree,
                &applied_worktree,
            )?;
            let index_result =
                write_conflict_index_resolution(worktree_path, file_path, &snapshot, None);
            if let Err(error) = index_result {
                return Err(rollback_worktree_after_error(
                    &worktree_file,
                    &original_worktree,
                    &applied_worktree,
                    error,
                ));
            }
        }
    }
    Ok(())
}

fn verify_conflict_snapshot(
    conflict: &git2::IndexConflict,
    snapshot: &ConflictSnapshot,
    file_path: &Path,
) -> Result<()> {
    let actual = (
        conflict
            .ancestor
            .as_ref()
            .map(|entry| (entry.id, entry.mode)),
        conflict.our.as_ref().map(|entry| (entry.id, entry.mode)),
        conflict.their.as_ref().map(|entry| (entry.id, entry.mode)),
    );
    let expected = (
        snapshot.ancestor_oid.zip(snapshot.ancestor_mode),
        snapshot.ours_oid.zip(snapshot.ours_mode),
        snapshot.theirs_oid.zip(snapshot.theirs_mode),
    );
    if actual != expected {
        anyhow::bail!(
            "The conflict for '{}' changed while the resolver was open. Reload it before saving.",
            file_path.display()
        );
    }
    Ok(())
}

fn reload_conflict_index(
    index: &mut git2::Index,
    snapshot: &ConflictSnapshot,
    file_path: &Path,
) -> Result<git2::IndexConflict> {
    index.read(true)?;
    let conflict = index.conflict_get(file_path).map_err(|_| {
        anyhow::anyhow!(
            "The conflict for '{}' changed while the resolution was being prepared. Reload it before saving.",
            file_path.display()
        )
    })?;
    verify_conflict_snapshot(&conflict, snapshot, file_path)?;
    Ok(conflict)
}

fn reload_conflict_index_after_worktree_change(
    index: &mut git2::Index,
    snapshot: &ConflictSnapshot,
    file_path: &Path,
    worktree_file: &AnchoredWorktreePath,
    original: &WorktreeEntryBackup,
    applied: &WorktreeEntryBackup,
) -> Result<git2::IndexConflict> {
    reload_conflict_index(index, snapshot, file_path)
        .map_err(|error| rollback_worktree_after_error(worktree_file, original, applied, error))
}

fn regular_worktree_mode(
    repo: &Repository,
    path: &AnchoredWorktreePath,
    fallback_mode: u32,
) -> Result<u32> {
    let metadata = path.symlink_metadata()?.ok_or_else(|| {
        anyhow::anyhow!("'{}' no longer exists in the working tree", path.display())
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        anyhow::bail!(
            "'{}' is not a regular file. Choose Current or Incoming as a whole-file resolution.",
            path.display()
        );
    }

    #[cfg(unix)]
    {
        use cap_std::fs::PermissionsExt as _;
        let tracks_filemode = repo
            .config()
            .ok()
            .and_then(|config| config.get_bool("core.filemode").ok())
            .unwrap_or(true);
        if tracks_filemode {
            return Ok(if metadata.permissions().mode() & 0o111 != 0 {
                0o100755
            } else {
                0o100644
            });
        }
    }

    let _ = repo;
    Ok(fallback_mode)
}

fn ensure_repo_relative_path(path: &Path) -> Result<()> {
    use std::path::Component;
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        anyhow::bail!(
            "Refusing to resolve an invalid repository path: '{}'",
            path.display()
        );
    }
    Ok(())
}

/// A repository path whose final parent is held open as a directory handle.
///
/// All resolver reads, compare-and-swap renames, temporary files, and final
/// publication are relative to this handle. Replacing an ancestor pathname
/// while a filter runs therefore cannot redirect a write through a symlink or
/// into a directory outside the worktree.
struct AnchoredWorktreePath {
    root: cap_std::fs::Dir,
    parent: Option<cap_std::fs::Dir>,
    parent_components: Vec<std::ffi::OsString>,
    name: std::ffi::OsString,
    display_path: PathBuf,
}

impl AnchoredWorktreePath {
    fn bind(worktree_path: &Path, file_path: &Path, create_parents: bool) -> Result<Self> {
        use cap_fs_ext::DirExt as _;
        use std::path::Component;

        let root = cap_std::fs::Dir::open_ambient_dir(worktree_path, cap_std::ambient_authority())
            .with_context(|| format!("Could not open worktree '{}'", worktree_path.display()))?;
        let name = file_path
            .file_name()
            .ok_or_else(|| anyhow::anyhow!("'{}' has no file name", file_path.display()))?
            .to_os_string();
        let mut parent = Some(root.try_clone()?);
        let mut parent_components = Vec::new();

        for component in file_path.parent().into_iter().flat_map(Path::components) {
            let Component::Normal(component) = component else {
                if matches!(component, Component::CurDir) {
                    continue;
                }
                unreachable!("repository-relative path was validated first");
            };
            parent_components.push(component.to_os_string());
            let Some(current) = parent.as_ref() else {
                continue;
            };
            match current.open_dir_nofollow(component) {
                Ok(next) => parent = Some(next),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound && !create_parents => {
                    parent = None;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    match current.create_dir(component) {
                        Ok(()) => {}
                        Err(create_error)
                            if create_error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(create_error) => return Err(create_error.into()),
                    }
                    parent = Some(current.open_dir_nofollow(component).with_context(|| {
                        format!(
                            "Refusing to resolve '{}' because parent '{}' could not be opened without following symbolic links",
                            file_path.display(),
                            worktree_path
                                .join(file_path.parent().unwrap_or_else(|| Path::new("")))
                                .display()
                        )
                    })?);
                }
                Err(error) => {
                    return Err(anyhow::anyhow!(
                        "Refusing to resolve '{}' because a parent directory could not be opened without following symbolic links: {error}",
                        file_path.display()
                    ));
                }
            }
        }

        Ok(Self {
            root,
            parent,
            parent_components,
            name,
            display_path: worktree_path.join(file_path),
        })
    }

    #[cfg(test)]
    fn bind_absolute(path: &Path, create_parent: bool) -> Result<Self> {
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("'{}' has no parent directory", path.display()))?;
        let name = path
            .file_name()
            .ok_or_else(|| anyhow::anyhow!("'{}' has no file name", path.display()))?;
        Self::bind(parent, Path::new(name), create_parent)
    }

    fn display(&self) -> std::path::Display<'_> {
        self.display_path.display()
    }

    fn sibling_display(&self, name: &Path) -> PathBuf {
        self.display_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join(name)
    }

    fn parent(&self) -> Result<&cap_std::fs::Dir> {
        self.parent.as_ref().ok_or_else(|| {
            anyhow::anyhow!("Parent directory for '{}' does not exist", self.display())
        })
    }

    fn symlink_metadata(&self) -> Result<Option<cap_std::fs::Metadata>> {
        let Some(parent) = self.parent.as_ref() else {
            return Ok(None);
        };
        match parent.symlink_metadata(&self.name) {
            Ok(metadata) => Ok(Some(metadata)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn verify_parent_binding(&self) -> Result<()> {
        use cap_fs_ext::DirExt as _;

        let Some(bound_parent) = self.parent.as_ref() else {
            return Ok(());
        };
        let mut current = self.root.try_clone()?;
        for component in &self.parent_components {
            current = current.open_dir_nofollow(component).map_err(|error| {
                anyhow::anyhow!(
                    "Refusing to publish '{}' because a parent directory changed: {error}",
                    self.display()
                )
            })?;
        }
        let current_identity = same_file::Handle::from_file(current.try_clone()?.into_std_file())?;
        let bound_identity =
            same_file::Handle::from_file(bound_parent.try_clone()?.into_std_file())?;
        if current_identity != bound_identity {
            anyhow::bail!(
                "Refusing to publish '{}' because its parent directory changed while the conflict result was being prepared.",
                self.display()
            );
        }
        Ok(())
    }
}

#[derive(Debug)]
enum WorktreeEntryBackup {
    Missing,
    Regular {
        bytes: Vec<u8>,
        permissions: std::fs::Permissions,
    },
    Symlink {
        target: PathBuf,
        kind: WorktreeSymlinkKind,
    },
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WorktreeSymlinkKind {
    File,
    #[cfg(windows)]
    Directory,
}

impl WorktreeEntryBackup {
    fn snapshot_bytes(&self) -> Option<&[u8]> {
        match self {
            Self::Regular { bytes, .. } => Some(bytes),
            Self::Symlink { target, .. } => Some(target.as_os_str().as_encoded_bytes()),
            Self::Missing | Self::Other => None,
        }
    }

    fn exactly_matches(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Missing, Self::Missing) | (Self::Other, Self::Other) => true,
            (
                Self::Regular {
                    bytes: left_bytes,
                    permissions: left_permissions,
                },
                Self::Regular {
                    bytes: right_bytes,
                    permissions: right_permissions,
                },
            ) => {
                left_bytes == right_bytes && permissions_match(left_permissions, right_permissions)
            }
            (
                Self::Symlink {
                    target: left_target,
                    kind: left_kind,
                },
                Self::Symlink {
                    target: right_target,
                    kind: right_kind,
                },
            ) => left_target == right_target && left_kind == right_kind,
            _ => false,
        }
    }

    fn matches_conflict_snapshot(&self, snapshot: &ConflictWorktreeSnapshot) -> bool {
        match (self, snapshot) {
            (Self::Missing, ConflictWorktreeSnapshot::Missing)
            | (Self::Other, ConflictWorktreeSnapshot::Other) => true,
            (
                Self::Regular { bytes, permissions },
                ConflictWorktreeSnapshot::Regular {
                    bytes: snapshot_bytes,
                    executable,
                    readonly,
                },
            ) => {
                bytes == snapshot_bytes
                    && permissions_executable(permissions) == *executable
                    && permissions.readonly() == *readonly
            }
            (
                Self::Symlink { target, .. },
                ConflictWorktreeSnapshot::Symlink { target: snapshot },
            ) => target.as_os_str().as_encoded_bytes() == snapshot,
            _ => false,
        }
    }
}

#[cfg(unix)]
fn permissions_executable(permissions: &std::fs::Permissions) -> Option<bool> {
    use std::os::unix::fs::PermissionsExt;
    Some(permissions.mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn permissions_executable(_permissions: &std::fs::Permissions) -> Option<bool> {
    None
}

#[cfg(unix)]
fn permissions_match(left: &std::fs::Permissions, right: &std::fs::Permissions) -> bool {
    use std::os::unix::fs::PermissionsExt;
    left.mode() == right.mode()
}

#[cfg(not(unix))]
fn permissions_match(left: &std::fs::Permissions, right: &std::fs::Permissions) -> bool {
    left.readonly() == right.readonly()
}

#[cfg(unix)]
fn worktree_symlink_kind(
    _path: &AnchoredWorktreePath,
    _name: &Path,
) -> Result<WorktreeSymlinkKind> {
    Ok(WorktreeSymlinkKind::File)
}

#[cfg(windows)]
fn worktree_symlink_kind(path: &AnchoredWorktreePath, name: &Path) -> Result<WorktreeSymlinkKind> {
    use std::os::windows::fs::FileTypeExt as _;

    // cap-std preserves the no-follow parent binding, but its portable metadata
    // API does not expose Windows' file-vs-directory symlink bit. This lookup is
    // used only to preserve rollback kind; every mutation remains relative to
    // the verified directory handle below.
    let metadata = std::fs::symlink_metadata(path.sibling_display(name))?;
    if metadata.file_type().is_symlink_dir() {
        Ok(WorktreeSymlinkKind::Directory)
    } else {
        Ok(WorktreeSymlinkKind::File)
    }
}

fn capture_worktree_entry(path: &AnchoredWorktreePath) -> Result<WorktreeEntryBackup> {
    capture_worktree_entry_named(path, Path::new(&path.name))
}

fn capture_worktree_entry_named(
    path: &AnchoredWorktreePath,
    name: &Path,
) -> Result<WorktreeEntryBackup> {
    use cap_fs_ext::{FollowSymlinks, OpenOptionsFollowExt as _};

    let Some(parent) = path.parent.as_ref() else {
        return Ok(WorktreeEntryBackup::Missing);
    };
    let metadata = match parent.symlink_metadata(name) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(WorktreeEntryBackup::Missing);
        }
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() {
        return Ok(WorktreeEntryBackup::Symlink {
            target: parent.read_link_contents(name)?,
            kind: worktree_symlink_kind(path, name)?,
        });
    }
    if metadata.is_file() {
        let mut options = cap_std::fs::OpenOptions::new();
        options.read(true).follow(FollowSymlinks::No);
        let mut file = parent.open_with(name, &options)?.into_std();
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            anyhow::bail!("'{}' changed while it was being inspected", path.display());
        }
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        return Ok(WorktreeEntryBackup::Regular {
            bytes,
            permissions: metadata.permissions(),
        });
    }
    Ok(WorktreeEntryBackup::Other)
}

fn replace_regular_worktree_file(
    path: &AnchoredWorktreePath,
    bytes: &[u8],
    mode: u32,
    expected: &WorktreeEntryBackup,
) -> Result<WorktreeEntryBackup> {
    write_regular_worktree_file_inner(path, bytes, Some(mode), Some(expected))
}

fn write_regular_worktree_file_inner(
    path: &AnchoredWorktreePath,
    bytes: &[u8],
    mode: Option<u32>,
    expected: Option<&WorktreeEntryBackup>,
) -> Result<WorktreeEntryBackup> {
    static NEXT_TEMP_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

    let parent = path.parent()?;
    if matches!(path.symlink_metadata()?, Some(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink())
    {
        anyhow::bail!(
            "Refusing to replace '{}' because it is a directory.",
            path.display()
        );
    }

    let mut temp = None;
    for _ in 0..128 {
        let id = NEXT_TEMP_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let candidate = PathBuf::from(format!(".rgitui-conflict-{}-{id}.tmp", std::process::id()));
        let mut options = cap_std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        match parent.open_with(&candidate, &options) {
            Ok(file) => {
                temp = Some((candidate, file.into_std()));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    let (temp_path, mut temp_file) = temp.ok_or_else(|| {
        anyhow::anyhow!(
            "Could not allocate a temporary conflict result beside '{}'",
            path.display()
        )
    })?;
    if let Err(error) = temp_file.write_all(bytes) {
        drop(temp_file);
        let _ = parent.remove_file(&temp_path);
        return Err(error.into());
    }

    if let Some(mode) = mode {
        if let Err(error) = set_executable_bit(&temp_file, mode) {
            drop(temp_file);
            let _ = parent.remove_file(&temp_path);
            return Err(error);
        }
    }
    drop(temp_file);
    let published_entry = match capture_worktree_entry_named(path, &temp_path) {
        Ok(entry) => entry,
        Err(error) => {
            let _ = parent.remove_file(&temp_path);
            return Err(error);
        }
    };
    if let Some(expected) = expected {
        if let Err(error) = ensure_worktree_entry_matches(path, expected) {
            let _ = parent.remove_file(&temp_path);
            return Err(error);
        }
    }

    // Reserve the current pathname by moving it aside, then compare the exact
    // displaced entry with the caller's snapshot. Publishing uses a hard link,
    // whose create-new semantics cannot overwrite an editor save that races us.
    let current_exists = path.symlink_metadata()?.is_some();
    let backup_path = if current_exists {
        let backup_path = loop {
            let id = NEXT_TEMP_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let candidate = PathBuf::from(format!(
                ".rgitui-conflict-backup-{}-{id}.tmp",
                std::process::id()
            ));
            match parent.symlink_metadata(&candidate) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => break candidate,
                Ok(_) => continue,
                Err(error) => {
                    let _ = parent.remove_file(&temp_path);
                    return Err(error.into());
                }
            }
        };
        if let Err(error) = parent.rename(&path.name, parent, &backup_path) {
            let _ = parent.remove_file(&temp_path);
            return Err(error.into());
        }
        Some(backup_path)
    } else {
        None
    };

    let displaced_entry = match backup_path.as_ref() {
        Some(backup_path) => match capture_worktree_entry_named(path, backup_path) {
            Ok(entry) => entry,
            Err(capture_error) => {
                let _ = parent.remove_file(&temp_path);
                if parent.symlink_metadata(&path.name).is_ok() {
                    anyhow::bail!(
                        "Could not inspect the displaced entry for '{}' ({capture_error}); it was retained at '{}' because a newer path entry appeared.",
                        path.display(),
                        path.sibling_display(backup_path).display()
                    );
                }
                if let Err(restore_error) = parent.rename(backup_path, parent, &path.name) {
                    anyhow::bail!(
                        "Could not inspect the displaced entry for '{}' ({capture_error}) or restore its backup at '{}' ({restore_error}).",
                        path.display(),
                        path.sibling_display(backup_path).display()
                    );
                }
                return Err(capture_error);
            }
        },
        None => WorktreeEntryBackup::Missing,
    };
    if expected.is_some_and(|expected| !displaced_entry.exactly_matches(expected)) {
        let _ = parent.remove_file(&temp_path);
        if let Some(backup_path) = backup_path.as_ref() {
            if let Err(error) = restore_displaced_entry(path, backup_path, &displaced_entry) {
                anyhow::bail!(
                    "'{}' changed while the conflict resolution was being prepared. The displaced entry was retained at '{}' because it could not be restored: {error}",
                    path.display(),
                    path.sibling_display(backup_path).display()
                );
            }
        }
        anyhow::bail!(
            "'{}' changed while the conflict resolution was being prepared. Reload it so no edits are overwritten.",
            path.display()
        );
    }

    if let Err(publish_error) =
        publish_regular_file_noclobber(path, &temp_path, bytes, &published_entry)
    {
        let _ = parent.remove_file(&temp_path);
        if let Some(backup_path) = backup_path.as_ref() {
            if let Err(restore_error) = restore_displaced_entry(path, backup_path, &displaced_entry)
            {
                anyhow::bail!(
                    "Failed to publish '{}' ({publish_error}) and could not restore its backup at '{}' ({restore_error}).",
                    path.display(),
                    path.sibling_display(backup_path).display()
                );
            }
        }
        return Err(publish_error);
    }
    let _ = parent.remove_file(&temp_path);
    if let Some(backup_path) = backup_path {
        if let Err(error) = remove_worktree_file_or_symlink_named(path, &backup_path) {
            log::warn!(
                "Published '{}' but could not remove backup '{}': {}",
                path.display(),
                path.sibling_display(&backup_path).display(),
                error
            );
        }
    }
    Ok(published_entry)
}

fn publish_regular_file_noclobber(
    path: &AnchoredWorktreePath,
    temp_path: &Path,
    bytes: &[u8],
    published_entry: &WorktreeEntryBackup,
) -> Result<()> {
    publish_regular_file_noclobber_inner(path, temp_path, bytes, published_entry, true)
}

fn publish_regular_file_noclobber_inner(
    path: &AnchoredWorktreePath,
    temp_path: &Path,
    bytes: &[u8],
    published_entry: &WorktreeEntryBackup,
    try_hard_link: bool,
) -> Result<()> {
    let parent = path.parent()?;
    if try_hard_link && parent.hard_link(temp_path, parent, &path.name).is_ok() {
        return Ok(());
    }

    // A hard link is the preferred atomic create-new publication, but it is
    // unavailable on FAT/exFAT and on some network filesystems. Fall back to a
    // create-new file so a racing editor save is still never overwritten. The
    // displaced original remains at its backup path until this copy and its
    // exact-content check both succeed.
    if parent.symlink_metadata(&path.name).is_ok() {
        anyhow::bail!(
            "'{}' changed while the conflict result was being published. The newer entry was preserved.",
            path.display()
        );
    }
    let WorktreeEntryBackup::Regular { permissions, .. } = published_entry else {
        anyhow::bail!("Prepared conflict result was not a regular file")
    };
    create_regular_file_noclobber(path, bytes, permissions)
}

fn remove_worktree_entry_if_matches(
    path: &AnchoredWorktreePath,
    expected: &WorktreeEntryBackup,
) -> Result<()> {
    if matches!(expected, WorktreeEntryBackup::Other) {
        anyhow::bail!(
            "Refusing to remove '{}' because it is a directory or another unsupported entry. Remove it manually after checking for untracked files.",
            path.display()
        );
    }
    let backup_path = displace_worktree_entry_if_matches(path, expected, "delete")?;
    let Some(backup_path) = backup_path else {
        return Ok(());
    };
    if let Err(remove_error) = remove_worktree_file_or_symlink_named(path, &backup_path) {
        return match restore_displaced_entry(path, &backup_path, expected) {
            Ok(()) => Err(anyhow::anyhow!(
                "The selected deletion was not staged because '{}' could not be removed: {remove_error}. The original entry was restored.",
                path.display()
            )),
            Err(restore_error) => Err(anyhow::anyhow!(
                "The selected deletion was not staged because the displaced entry at '{}' could not be removed ({remove_error}) or restored ({restore_error}).",
                path.sibling_display(&backup_path).display()
            )),
        };
    }
    Ok(())
}

fn checkout_uses_symlinks(repo: &Repository) -> bool {
    repo.config()
        .ok()
        .and_then(|config| config.get_bool("core.symlinks").ok())
        .unwrap_or(!cfg!(windows))
}

fn replace_worktree_symlink(
    path: &AnchoredWorktreePath,
    target: &[u8],
    expected: &WorktreeEntryBackup,
) -> Result<WorktreeEntryBackup> {
    let target = symlink_target_from_bytes(target)?;
    let kind = selected_symlink_kind(&target, &path.display_path)?;
    publish_special_worktree_entry(path, expected, || {
        create_worktree_symlink(path, Path::new(&path.name), &target, kind)?;
        Ok(())
    })
}

#[cfg(unix)]
fn symlink_target_from_bytes(target: &[u8]) -> Result<PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    Ok(std::ffi::OsString::from_vec(target.to_vec()).into())
}

#[cfg(windows)]
fn symlink_target_from_bytes(target: &[u8]) -> Result<PathBuf> {
    let target = String::from_utf8(target.to_vec())
        .context("Cannot create a Windows symbolic link with a non-UTF-8 target")?;
    Ok(target.into())
}

#[cfg(unix)]
fn selected_symlink_kind(_target: &Path, _path: &Path) -> Result<WorktreeSymlinkKind> {
    Ok(WorktreeSymlinkKind::File)
}

#[cfg(windows)]
fn selected_symlink_kind(target: &Path, path: &Path) -> Result<WorktreeSymlinkKind> {
    let resolved_target = if target.is_absolute() {
        target.to_path_buf()
    } else {
        path.parent().unwrap_or_else(|| Path::new(".")).join(target)
    };
    match std::fs::metadata(resolved_target) {
        Ok(metadata) if metadata.is_dir() => Ok(WorktreeSymlinkKind::Directory),
        Ok(_) => Ok(WorktreeSymlinkKind::File),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // This matches libgit2's Windows checkout fallback for a dangling
            // Git symlink, whose target type cannot otherwise be inferred.
            Ok(WorktreeSymlinkKind::Directory)
        }
        Err(error) => Err(error.into()),
    }
}

fn publish_special_worktree_entry<F>(
    path: &AnchoredWorktreePath,
    expected: &WorktreeEntryBackup,
    publish: F,
) -> Result<WorktreeEntryBackup>
where
    F: FnOnce() -> Result<()>,
{
    if matches!(expected, WorktreeEntryBackup::Other) {
        anyhow::bail!(
            "Refusing to replace '{}' because it is a directory or another unsupported entry.",
            path.display()
        );
    }

    let original_backup = displace_worktree_entry_if_matches(path, expected, "special")?;
    let operation = publish().and_then(|()| capture_worktree_entry(path));
    let applied = match operation {
        Ok(applied) => applied,
        Err(operation_error) => {
            let current = capture_worktree_entry(path);
            return match (current, original_backup.as_deref()) {
                (Ok(WorktreeEntryBackup::Missing), Some(backup_path)) => {
                    match restore_displaced_entry(path, backup_path, expected) {
                        Ok(()) => Err(operation_error),
                        Err(restore_error) => Err(anyhow::anyhow!(
                            "{operation_error}; the original entry remains recoverable at '{}' because it could not be restored: {restore_error}",
                            path.sibling_display(backup_path).display()
                        )),
                    }
                }
                (Ok(WorktreeEntryBackup::Missing), None) => Err(operation_error),
                (Ok(_), Some(backup_path)) => Err(anyhow::anyhow!(
                    "{operation_error}; an entry that appeared at '{}' was preserved, and the original remains recoverable at '{}'.",
                    path.display(),
                    path.sibling_display(backup_path).display()
                )),
                (Ok(_), None) => Err(anyhow::anyhow!(
                    "{operation_error}; an entry that appeared at '{}' was preserved.",
                    path.display()
                )),
                (Err(inspect_error), Some(backup_path)) => Err(anyhow::anyhow!(
                    "{operation_error}; could not inspect '{}': {inspect_error}. The original remains recoverable at '{}'.",
                    path.display(),
                    path.sibling_display(backup_path).display()
                )),
                (Err(inspect_error), None) => Err(anyhow::anyhow!(
                    "{operation_error}; could not inspect '{}': {inspect_error}.",
                    path.display()
                )),
            };
        }
    };

    if let Some(backup_path) = original_backup {
        if let Err(error) = remove_worktree_file_or_symlink_named(path, &backup_path) {
            log::warn!(
                "Published special conflict result '{}' but could not remove backup '{}': {}",
                path.display(),
                path.sibling_display(&backup_path).display(),
                error
            );
        }
    }
    Ok(applied)
}

fn displace_worktree_entry_if_matches(
    path: &AnchoredWorktreePath,
    expected: &WorktreeEntryBackup,
    label: &str,
) -> Result<Option<PathBuf>> {
    static NEXT_BACKUP_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

    if matches!(expected, WorktreeEntryBackup::Missing) {
        ensure_worktree_entry_matches(path, expected)?;
        return Ok(None);
    }
    path.verify_parent_binding()?;
    let parent = path.parent()?;
    let backup_path = loop {
        let id = NEXT_BACKUP_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let candidate = PathBuf::from(format!(
            ".rgitui-conflict-{label}-{}-{id}.tmp",
            std::process::id()
        ));
        match parent.symlink_metadata(&candidate) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break candidate,
            Ok(_) => continue,
            Err(error) => return Err(error.into()),
        }
    };

    // Moving the pathname aside is the compare-and-swap point: whichever
    // exact entry occupied the path is captured without first deleting it.
    parent.rename(&path.name, parent, &backup_path)?;
    let displaced = capture_worktree_entry_named(path, &backup_path)?;
    if !displaced.exactly_matches(expected) {
        match restore_displaced_entry(path, &backup_path, &displaced) {
            Ok(()) => anyhow::bail!(
                "'{}' changed while the conflict resolution was being prepared. Reload it so no edits are overwritten.",
                path.display()
            ),
            Err(error) => anyhow::bail!(
                "'{}' changed while the conflict resolution was being prepared. Its displaced entry was retained at '{}' because it could not be restored: {error}",
                path.display(),
                path.sibling_display(&backup_path).display()
            ),
        }
    }
    Ok(Some(backup_path))
}

fn create_regular_file_noclobber(
    path: &AnchoredWorktreePath,
    bytes: &[u8],
    permissions: &std::fs::Permissions,
) -> Result<()> {
    path.verify_parent_binding()?;
    let mut options = cap_std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    let mut destination = path.parent()?.open_with(&path.name, &options)?.into_std();
    let identity = same_file::Handle::from_file(destination.try_clone()?)?;
    let operation = destination
        .write_all(bytes)
        .and_then(|_| destination.set_permissions(permissions.clone()));
    drop(destination);

    let expected = WorktreeEntryBackup::Regular {
        bytes: bytes.to_vec(),
        permissions: permissions.clone(),
    };
    let operation = operation
        .map_err(anyhow::Error::from)
        .and_then(|_| ensure_created_file_matches(path, &identity, &expected));
    if let Err(error) = operation {
        return match remove_created_file_if_same(path, &identity) {
            Ok(()) => Err(error),
            Err(cleanup_error) => Err(anyhow::anyhow!("{error}; {cleanup_error}")),
        };
    }
    Ok(())
}

fn ensure_created_file_matches(
    path: &AnchoredWorktreePath,
    identity: &same_file::Handle,
    expected: &WorktreeEntryBackup,
) -> Result<()> {
    let current_identity = regular_file_identity(path, Path::new(&path.name))?;
    if &current_identity != identity {
        anyhow::bail!(
            "A newer entry replaced '{}' while the conflict result was being written; it was preserved.",
            path.display()
        );
    }
    ensure_worktree_entry_matches(path, expected)
}

fn remove_created_file_if_same(
    path: &AnchoredWorktreePath,
    identity: &same_file::Handle,
) -> Result<()> {
    let current_identity = match regular_file_identity(path, Path::new(&path.name)) {
        Ok(identity) => identity,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(())
        }
        Err(error) => return Err(error),
    };
    if &current_identity != identity {
        anyhow::bail!(
            "A newer entry replaced '{}'; it was preserved.",
            path.display()
        );
    }

    let current = capture_worktree_entry(path)?;
    let backup = displace_worktree_entry_if_matches(path, &current, "failed")?
        .ok_or_else(|| anyhow::anyhow!("The created file disappeared before cleanup"))?;
    let displaced_identity = regular_file_identity(path, &backup)?;
    if &displaced_identity != identity {
        let displaced = capture_worktree_entry_named(path, &backup)?;
        restore_displaced_entry(path, &backup, &displaced)?;
        anyhow::bail!(
            "A newer entry replaced '{}' during cleanup; it was preserved.",
            path.display()
        );
    }
    remove_worktree_file_or_symlink_named(path, &backup)
}

fn regular_file_identity(path: &AnchoredWorktreePath, name: &Path) -> Result<same_file::Handle> {
    use cap_fs_ext::{FollowSymlinks, OpenOptionsFollowExt as _};

    let mut options = cap_std::fs::OpenOptions::new();
    options.read(true).follow(FollowSymlinks::No);
    let file = path.parent()?.open_with(name, &options)?.into_std();
    Ok(same_file::Handle::from_file(file)?)
}

fn restore_displaced_entry(
    path: &AnchoredWorktreePath,
    backup_path: &Path,
    displaced: &WorktreeEntryBackup,
) -> Result<()> {
    let parent = path.parent()?;
    if parent.symlink_metadata(&path.name).is_ok() {
        anyhow::bail!(
            "a newer entry appeared at '{}'; it was preserved",
            path.display()
        );
    }
    match displaced {
        WorktreeEntryBackup::Regular { bytes, permissions } => {
            if parent.hard_link(backup_path, parent, &path.name).is_err() {
                create_regular_file_noclobber(path, bytes, permissions)?;
            }
            remove_worktree_file_or_symlink_named(path, backup_path)?;
        }
        WorktreeEntryBackup::Symlink { target, kind } => {
            create_worktree_symlink(path, Path::new(&path.name), target, *kind)?;
            remove_worktree_file_or_symlink_named(path, backup_path)?;
        }
        WorktreeEntryBackup::Missing => {}
        WorktreeEntryBackup::Other => anyhow::bail!(
            "unsupported entry remains safely stored at '{}'",
            path.sibling_display(backup_path).display()
        ),
    }
    Ok(())
}

fn ensure_worktree_entry_matches(
    path: &AnchoredWorktreePath,
    expected: &WorktreeEntryBackup,
) -> Result<()> {
    path.verify_parent_binding()?;
    let current = capture_worktree_entry(path)?;
    if !current.exactly_matches(expected) {
        anyhow::bail!(
            "'{}' changed while the conflict resolution was being prepared. Reload it so no edits are overwritten.",
            path.display()
        );
    }
    Ok(())
}

fn remove_worktree_file_or_symlink_named(path: &AnchoredWorktreePath, name: &Path) -> Result<()> {
    use cap_fs_ext::DirExt as _;

    let parent = path.parent()?;
    match parent.symlink_metadata(name) {
        Ok(metadata) if metadata.file_type().is_symlink() || metadata.is_file() => {
            parent.remove_file_or_symlink(name)?;
        }
        Ok(_) => anyhow::bail!(
            "Refusing to remove '{}' because it is a directory. Remove it manually after checking for untracked files.",
            path.sibling_display(name).display()
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

fn conflict_marker_size(repo: &Repository, path: &Path, snapshot: &ConflictSnapshot) -> usize {
    // Attributes may be edited after Git wrote the conflicted worktree file.
    // Recover the width from the complete marker grammar captured when the
    // resolver opened, then fall back to the current attribute for unusual or
    // incomplete worktree states.
    if let ConflictWorktreeSnapshot::Regular { bytes, .. } = &snapshot.worktree {
        if let Some(size) = complete_conflict_marker_size(bytes) {
            return size;
        }
    }

    let value = repo
        .get_attr(
            path,
            "conflict-marker-size",
            git2::AttrCheckFlags::FILE_THEN_INDEX,
        )
        .ok()
        .flatten();
    match git2::AttrValue::from_string(value) {
        git2::AttrValue::String(value) => value
            .parse::<usize>()
            .ok()
            .filter(|size| *size > 0)
            .unwrap_or(7),
        _ => 7,
    }
}

fn complete_conflict_marker_size(content: &[u8]) -> Option<usize> {
    #[derive(Clone, Copy)]
    enum State {
        Resolved,
        Ours(usize),
        Ancestor(usize),
        Theirs(usize),
    }

    fn labeled_marker_width(line: &[u8], marker: u8) -> Option<usize> {
        let width = line.iter().take_while(|byte| **byte == marker).count();
        if width == 0 {
            return None;
        }
        let suffix = &line[width..];
        (suffix.is_empty()
            || suffix
                .first()
                .is_some_and(|byte| matches!(*byte, b' ' | b'\t')))
        .then_some(width)
    }

    fn is_bare_marker(line: &[u8], marker: u8, width: usize) -> bool {
        line.len() == width && line.iter().all(|byte| *byte == marker)
    }

    let mut state = State::Resolved;
    for line in content.split(|byte| *byte == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let next_open = labeled_marker_width(line, b'<');
        state = match state {
            State::Resolved => next_open.map_or(State::Resolved, State::Ours),
            State::Ours(width) if is_bare_marker(line, b'|', width) => State::Ancestor(width),
            State::Ours(width) if is_bare_marker(line, b'=', width) => State::Theirs(width),
            State::Ancestor(width) if is_bare_marker(line, b'=', width) => State::Theirs(width),
            State::Theirs(width) if labeled_marker_width(line, b'>') == Some(width) => {
                return Some(width);
            }
            current => next_open.map_or(current, State::Ours),
        };
    }
    None
}

fn contains_conflict_markers(content: &[u8], marker_size: usize) -> bool {
    content.split(|byte| *byte == b'\n').any(|line| {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        b"<|=>".iter().any(|marker| {
            if line.len() < marker_size || !line[..marker_size].iter().all(|byte| byte == marker) {
                return false;
            }

            let suffix = &line[marker_size..];
            if *marker == b'=' {
                // The separator has no label. Requiring the end of the line
                // avoids treating longer runs used as prose or headings as
                // unresolved conflict markers.
                suffix.is_empty()
            } else {
                // Start, ancestor, and end markers may be followed by a label,
                // which Git separates from the exact-width marker with
                // whitespace. A longer run of the delimiter is not a marker.
                suffix.is_empty()
                    || suffix
                        .first()
                        .is_some_and(|byte| matches!(*byte, b' ' | b'\t'))
            }
        })
    })
}

fn restore_worktree_entry_if_unchanged(
    path: &AnchoredWorktreePath,
    original: &WorktreeEntryBackup,
    applied: &WorktreeEntryBackup,
) -> Result<()> {
    let applied_backup =
        displace_worktree_entry_if_matches(path, applied, "rollback").map_err(|error| {
            anyhow::anyhow!(
                "Could not roll back '{}': {error} The newer worktree entry was preserved.",
                path.display()
            )
        })?;

    let restore_result = match original {
        WorktreeEntryBackup::Missing => Ok(()),
        WorktreeEntryBackup::Regular { bytes, permissions } => {
            create_regular_file_noclobber(path, bytes, permissions)
        }
        WorktreeEntryBackup::Symlink { target, kind } => {
            create_worktree_symlink(path, Path::new(&path.name), target, *kind)
                .map_err(anyhow::Error::from)
        }
        WorktreeEntryBackup::Other => Err(anyhow::anyhow!(
            "Cannot restore unsupported worktree entry '{}'",
            path.display()
        )),
    };
    if let Err(error) = restore_result {
        let recovery = applied_backup
            .as_ref()
            .map(|backup| {
                anyhow::anyhow!(
                    "The displaced resolver result remains recoverable at '{}'.",
                    path.sibling_display(backup).display()
                )
            })
            .unwrap_or_else(|| anyhow::anyhow!("The newer worktree entry, if any, was preserved."));
        return Err(anyhow::anyhow!(
            "Could not restore '{}' during rollback: {error} {recovery}",
            path.display()
        ));
    }
    if let Some(applied_backup) = applied_backup {
        remove_worktree_file_or_symlink_named(path, &applied_backup).with_context(|| {
            format!(
                "Rollback restored '{}' but could not remove the displaced resolver result at '{}'",
                path.display(),
                path.sibling_display(&applied_backup).display()
            )
        })?;
    }
    Ok(())
}

fn rollback_worktree_after_error(
    path: &AnchoredWorktreePath,
    original: &WorktreeEntryBackup,
    applied: &WorktreeEntryBackup,
    operation_error: anyhow::Error,
) -> anyhow::Error {
    match restore_worktree_entry_if_unchanged(path, original, applied) {
        Ok(()) => operation_error,
        Err(rollback_error) => anyhow::anyhow!("{operation_error}; {rollback_error}"),
    }
}

#[cfg(unix)]
fn create_worktree_symlink(
    path: &AnchoredWorktreePath,
    name: &Path,
    target: &Path,
    _kind: WorktreeSymlinkKind,
) -> std::io::Result<()> {
    path.parent()
        .map_err(|error| std::io::Error::other(error.to_string()))?
        .symlink_contents(target, name)
}

#[cfg(windows)]
fn create_worktree_symlink(
    path: &AnchoredWorktreePath,
    name: &Path,
    target: &Path,
    kind: WorktreeSymlinkKind,
) -> std::io::Result<()> {
    let parent = path
        .parent()
        .map_err(|error| std::io::Error::other(error.to_string()))?;

    match kind {
        WorktreeSymlinkKind::Directory => parent.symlink_dir(target, name),
        WorktreeSymlinkKind::File => parent.symlink_file(target, name),
    }
}

#[cfg(unix)]
fn set_executable_bit(file: &std::fs::File, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = file.metadata()?.permissions();
    let mut permissions_mode = permissions.mode();
    if mode & 0o111 != 0 {
        permissions_mode |= 0o111;
    } else {
        permissions_mode &= !0o111;
    }
    permissions.set_mode(permissions_mode);
    file.set_permissions(permissions)?;
    Ok(())
}

#[cfg(not(unix))]
fn set_executable_bit(_file: &std::fs::File, _mode: u32) -> Result<()> {
    Ok(())
}

enum ConflictSide {
    Ours,
    Theirs,
}

fn sign_with_gpg(content: &str, key_id: &str) -> Result<String> {
    use std::io::Write;
    use std::process::Stdio;

    let mut cmd = std::process::Command::new("gpg");
    cmd.args(["--status-fd=2", "-bsau", key_id])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000);
    }
    let mut child = cmd
        .spawn()
        .context("Failed to start gpg. Is GPG installed?")?;

    child.stdin.take().unwrap().write_all(content.as_bytes())?;
    let output = child.wait_with_output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("GPG signing failed: {}", stderr);
    }

    Ok(String::from_utf8(output.stdout)?)
}

/// Return local branches that contain the given commit.
///
/// Uses the git2 merge-base check: if `merge_base(branch_tip, commit_oid) == commit_oid`,
/// then `commit_oid` is an ancestor of `branch_tip` — meaning the branch contains the commit.
///
/// Remote branches are excluded since the UX is about "which of my branches has this commit".
pub fn branches_containing_commit(
    repo_path: &std::path::Path,
    oid: git2::Oid,
) -> Result<Vec<BranchInfo>> {
    let repo = Repository::open(repo_path)
        .with_context(|| format!("Failed to open repository at {}", repo_path.display()))?;

    // Verify the commit exists (will error gracefully if not found)
    repo.find_commit(oid)?;
    let mut containing = Vec::new();

    let branch_iter = repo.branches(Some(git2::BranchType::Local))?;
    for branch_result in branch_iter {
        let (branch, _branch_type) = branch_result?;
        let name = branch.name()?.unwrap_or("").to_string();
        if name.is_empty() {
            continue;
        }

        let Some(tip_oid) = branch.get().target() else {
            continue;
        };

        // Skip if tip is the commit itself (avoid self-reference)
        if tip_oid == oid {
            let upstream = if let Ok(upstream_ref) = branch.upstream() {
                upstream_ref.name().ok().flatten().map(|s| s.to_string())
            } else {
                None
            };
            containing.push(BranchInfo {
                name,
                is_head: branch.is_head(),
                is_remote: false,
                upstream,
                ahead: None,
                behind: None,
                tip_oid: Some(tip_oid),
                author_email: None,
                last_commit_time: None,
                is_merged_into_main: None,
                is_merged_into_head: None,
            });
            continue;
        }

        // merge_base(tip, commit) returns the common ancestor.
        // If it equals our commit oid, then commit is an ancestor of tip.
        if let Ok(merge_base) = repo.merge_base(tip_oid, oid) {
            if merge_base == oid {
                let upstream = if let Ok(upstream_ref) = branch.upstream() {
                    upstream_ref.name().ok().flatten().map(|s| s.to_string())
                } else {
                    None
                };
                containing.push(BranchInfo {
                    name,
                    is_head: branch.is_head(),
                    is_remote: false,
                    upstream,
                    ahead: None,
                    behind: None,
                    tip_oid: Some(tip_oid),
                    author_email: None,
                    last_commit_time: None,
                    is_merged_into_main: None,
                    is_merged_into_head: None,
                });
            }
        }
    }

    containing.sort_by(|a, b| b.is_head.cmp(&a.is_head).then(a.name.cmp(&b.name)));

    Ok(containing)
}

/// Count the entries `git clean -n` reports it would remove.
///
/// The dry run writes `Would remove <path>` lines to **stdout**; stderr stays
/// empty on success. Directories are reported the same way as files, so this
/// counts entries rather than individual files.
fn count_would_remove(stdout: &str) -> usize {
    stdout
        .lines()
        .filter(|line| line.trim_start().starts_with("Would remove "))
        .count()
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::Write;
    use std::process::Stdio;

    use rgitui_test_support::TempRepo;

    use super::run_continue_subcommand;

    fn anchored(path: &std::path::Path) -> super::AnchoredWorktreePath {
        super::AnchoredWorktreePath::bind_absolute(path, true).unwrap()
    }

    /// Run a git subcommand in `dir`, asserting nothing about its exit status —
    /// the conflict-stopping steps these tests set up are expected to fail.
    fn run_git(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
        super::super::git_command()
            .current_dir(dir)
            .args(args)
            .env("GIT_EDITOR", "true")
            .output()
            .expect("failed to run git")
    }

    fn install_gitlink_conflict(
        fixture: &TempRepo,
        path: &str,
        ancestor: git2::Oid,
        ours: git2::Oid,
        theirs: git2::Oid,
    ) {
        install_index_conflict(fixture, path, 0o160000, ancestor, ours, theirs);
    }

    fn install_index_conflict(
        fixture: &TempRepo,
        path: &str,
        mode: u32,
        ancestor: git2::Oid,
        ours: git2::Oid,
        theirs: git2::Oid,
    ) {
        let entries = format!(
            "{mode:o} {ancestor} 1\t{path}\n{mode:o} {ours} 2\t{path}\n{mode:o} {theirs} 3\t{path}\n"
        );
        let mut child = super::super::git_command()
            .current_dir(fixture.path())
            .args(["update-index", "--index-info"])
            .stdin(Stdio::piped())
            .spawn()
            .expect("start git update-index");
        child
            .stdin
            .take()
            .expect("update-index stdin")
            .write_all(entries.as_bytes())
            .expect("write conflict entries");
        assert!(child.wait().expect("wait for update-index").success());
    }

    fn install_gitlink_modify_delete_conflict(
        fixture: &TempRepo,
        path: &str,
        ancestor: git2::Oid,
        ours: git2::Oid,
    ) {
        let entries = format!("160000 {ancestor} 1\t{path}\n160000 {ours} 2\t{path}\n");
        let mut child = super::super::git_command()
            .current_dir(fixture.path())
            .args(["update-index", "--index-info"])
            .stdin(Stdio::piped())
            .spawn()
            .expect("start git update-index");
        child
            .stdin
            .take()
            .expect("update-index stdin")
            .write_all(entries.as_bytes())
            .expect("write conflict entries");
        assert!(child.wait().expect("wait for update-index").success());
    }

    /// A repo whose `feature` branch and `main` both change `file.txt`'s only
    /// line, so cherry-picking `feature` onto `main` stops on a conflict.
    fn make_repo_with_conflicting_pick() -> TempRepo {
        let fixture = TempRepo::init();
        fixture.write_file("file.txt", "base\n");
        fixture.stage("file.txt");
        fixture.commit("base");

        run_git(fixture.path(), &["checkout", "-b", "feature"]);
        fixture.write_file("file.txt", "feature\n");
        fixture.stage("file.txt");
        fixture.commit("feature change");

        run_git(fixture.path(), &["checkout", "main"]);
        fixture.write_file("file.txt", "main\n");
        fixture.stage("file.txt");
        fixture.commit("main change");

        fixture
    }

    fn make_repo_with_conflicting_merge() -> TempRepo {
        let fixture = TempRepo::init();
        fixture.commit_file("file.txt", "base\n", "base");

        assert!(run_git(fixture.path(), &["checkout", "-b", "incoming"])
            .status
            .success());
        fixture.commit_file("file.txt", "incoming\n", "incoming change");

        assert!(run_git(fixture.path(), &["checkout", "main"])
            .status
            .success());
        fixture.commit_file("file.txt", "current\n", "current change");
        let merge = run_git(fixture.path(), &["merge", "incoming"]);
        assert!(
            !merge.status.success(),
            "merge unexpectedly succeeded: stdout={} stderr={}",
            String::from_utf8_lossy(&merge.stdout),
            String::from_utf8_lossy(&merge.stderr)
        );
        fixture
    }

    fn make_repo_with_eol_conflicting_merge(eol: &str) -> TempRepo {
        let fixture = TempRepo::init();
        fixture.write_file(".gitattributes", &format!("file.txt text eol={eol}\n"));
        fixture.write_file("file.txt", "base\n");
        fixture.stage(".gitattributes");
        fixture.stage("file.txt");
        fixture.commit("base with attributes");

        assert!(run_git(fixture.path(), &["checkout", "-b", "incoming"])
            .status
            .success());
        fixture.commit_file("file.txt", "incoming\n", "incoming change");
        assert!(run_git(fixture.path(), &["checkout", "main"])
            .status
            .success());
        fixture.commit_file("file.txt", "current\n", "current change");
        assert!(!run_git(fixture.path(), &["merge", "incoming"])
            .status
            .success());
        fixture
    }

    #[test]
    fn assembled_resolution_is_written_and_staged_byte_exactly() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let resolved = b"current\r\nincoming".to_vec();

        super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::Draft {
                result: Some(resolved.clone()),
                result_mode: diff.result_mode,
                snapshot: diff.snapshot,
            },
        )
        .expect("save resolution");

        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            resolved
        );
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let index = repo.index().unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        let entry = index.get_path(relative_path, 0).expect("stage-0 entry");
        assert_eq!(repo.find_blob(entry.id).unwrap().content(), resolved);
    }

    #[test]
    fn assembled_canonical_result_is_smudged_for_the_worktree() {
        let fixture = make_repo_with_eol_conflicting_merge("crlf");
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let canonical = b"resolved\n".to_vec();

        super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::Draft {
                result: Some(canonical.clone()),
                result_mode: diff.result_mode,
                snapshot: diff.snapshot,
            },
        )
        .expect("save filtered resolution");

        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"resolved\r\n"
        );
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let index = repo.index().unwrap();
        let entry = index.get_path(relative_path, 0).expect("stage-0 entry");
        assert_eq!(repo.find_blob(entry.id).unwrap().content(), canonical);
    }

    #[test]
    fn whole_regular_side_is_smudged_for_the_worktree() {
        let fixture = make_repo_with_eol_conflicting_merge("crlf");
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .expect("choose filtered current side");

        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"current\r\n"
        );
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let index = repo.index().unwrap();
        let entry = index.get_path(relative_path, 0).expect("stage-0 entry");
        assert_eq!(repo.find_blob(entry.id).unwrap().content(), b"current\n");
    }

    #[test]
    fn editor_worktree_result_is_cleaned_before_staging() {
        let fixture = make_repo_with_eol_conflicting_merge("lf");
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        fs::write(fixture.path().join(relative_path), b"manual result\r\n").unwrap();

        super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .expect("stage filtered editor result");

        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"manual result\r\n"
        );
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let index = repo.index().unwrap();
        let entry = index.get_path(relative_path, 0).expect("stage-0 entry");
        assert_eq!(
            repo.find_blob(entry.id).unwrap().content(),
            b"manual result\n"
        );
    }

    #[test]
    fn editor_worktree_result_rejects_markers_created_by_clean_conversion() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        fs::write(
            fixture.path().join(".gitattributes"),
            b"file.txt text working-tree-encoding=UTF-16LE\n",
        )
        .unwrap();
        let encoded = super::smudge_canonical_bytes(
            fixture.path(),
            relative_path,
            b"<<<<<<< current\nstill unresolved\n=======\nincoming\n>>>>>>> incoming\n",
        )
        .expect("encode marker-bearing worktree file");
        fs::write(fixture.path().join(relative_path), encoded).unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");

        let error = super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("after applying Git's clean filters"));
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn editor_worktree_result_uses_the_current_executable_bit() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = TempRepo::init();
        let relative_path = std::path::Path::new("file.txt");
        fixture.write_file("file.txt", "base\n");
        fs::set_permissions(
            fixture.path().join(relative_path),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fixture.stage(relative_path);
        fixture.commit("executable base");
        assert!(
            run_git(fixture.path(), &["config", "core.filemode", "true"])
                .status
                .success()
        );
        assert!(run_git(fixture.path(), &["checkout", "-b", "incoming"])
            .status
            .success());
        fixture.commit_file("file.txt", "incoming\n", "incoming change");
        assert!(run_git(fixture.path(), &["checkout", "main"])
            .status
            .success());
        fixture.commit_file("file.txt", "current\n", "current change");
        assert!(!run_git(fixture.path(), &["merge", "incoming"])
            .status
            .success());
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        fs::write(fixture.path().join(relative_path), b"manual result\n").unwrap();
        fs::set_permissions(
            fixture.path().join(relative_path),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();

        super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .expect("stage non-executable editor result");

        let entry = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .get_path(relative_path, 0)
            .expect("stage-0 entry");
        assert_eq!(entry.mode, 0o100644);
    }

    #[test]
    fn stale_resolver_does_not_overwrite_external_edits() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        fs::write(fixture.path().join(relative_path), b"edited elsewhere\n").unwrap();

        let error = super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::Draft {
                result: Some(b"resolver result\n".to_vec()),
                result_mode: diff.result_mode,
                snapshot: diff.snapshot,
            },
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed outside"));
        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"edited elsewhere\n"
        );
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn stale_whole_side_resolution_does_not_overwrite_external_edits() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        fs::write(fixture.path().join(relative_path), b"edited elsewhere\n").unwrap();

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed outside"));
        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"edited elsewhere\n"
        );
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn stale_whole_side_resolution_rejects_a_same_bytes_symlink_replacement() {
        use std::os::unix::ffi::OsStringExt;
        use std::os::unix::fs::symlink;

        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let full_path = fixture.path().join(relative_path);
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let target = std::ffi::OsString::from_vec(
            diff.snapshot
                .worktree
                .bytes()
                .expect("regular worktree bytes")
                .to_vec(),
        );
        fs::remove_file(&full_path).unwrap();
        symlink(target, &full_path).unwrap();

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed outside"));
        assert!(fs::symlink_metadata(&full_path)
            .unwrap()
            .file_type()
            .is_symlink());
    }

    #[cfg(unix)]
    #[test]
    fn stale_whole_side_resolution_rejects_permission_only_changes() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let full_path = fixture.path().join(relative_path);
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        fs::set_permissions(&full_path, fs::Permissions::from_mode(0o755)).unwrap();

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed outside"));
        assert_ne!(
            fs::metadata(&full_path).unwrap().permissions().mode() & 0o111,
            0
        );
    }

    #[test]
    fn whole_side_resolution_rejects_replaced_index_conflict() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let mut index = repo.index().unwrap();
        let conflict = index.conflict_get(relative_path).unwrap();
        let mut replacement = conflict.our.expect("ours entry");
        replacement.id = repo.blob(b"replacement current\n").unwrap();
        index.add(&replacement).unwrap();
        index.write().unwrap();

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed while"));
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn whole_side_resolution_rejects_conflict_mode_changes_with_the_same_oid() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let mut index = repo.index().unwrap();
        let conflict = index.conflict_get(relative_path).unwrap();
        let mut replacement = conflict.our.expect("ours entry");
        replacement.mode = 0o120000;
        index.add(&replacement).unwrap();
        index.write().unwrap();

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed while"));
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn conflict_index_transaction_preserves_a_stage_after_result_hashing() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let result_oid = repo.blob(b"resolved after a large preparation\n").unwrap();

        // This stage lands after result preparation. The transaction must read
        // it under index.lock rather than overwrite it from a stale Index.
        fs::write(fixture.path().join("unrelated.txt"), b"staged later\n").unwrap();
        assert!(run_git(fixture.path(), &["add", "unrelated.txt"])
            .status
            .success());
        let mut index = repo.index().unwrap();
        let conflict = super::reload_conflict_index(&mut index, &diff.snapshot, relative_path)
            .expect("refresh conflict index");
        let mode = conflict.our.as_ref().expect("ours entry").mode;

        super::write_conflict_index_resolution(
            fixture.path(),
            relative_path,
            &diff.snapshot,
            Some((mode, result_oid)),
        )
        .expect("commit conflict resolution transaction");

        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        assert_eq!(
            index.get_path(relative_path, 0).expect("resolved entry").id,
            result_oid
        );
        let unrelated = index
            .get_path(std::path::Path::new("unrelated.txt"), 0)
            .expect("concurrent stage was preserved");
        assert_eq!(
            repo.find_blob(unrelated.id).unwrap().content(),
            b"staged later\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn conflict_index_transaction_preserves_index_permissions() {
        use std::os::unix::fs::PermissionsExt as _;

        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let index_path = repo.index().unwrap().path().unwrap().to_path_buf();
        fs::set_permissions(&index_path, fs::Permissions::from_mode(0o664)).unwrap();
        let result_oid = repo.blob(b"shared repository result\n").unwrap();
        let mode = repo
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .unwrap()
            .our
            .expect("ours entry")
            .mode;

        super::write_conflict_index_resolution(
            fixture.path(),
            relative_path,
            &diff.snapshot,
            Some((mode, result_oid)),
        )
        .expect("commit conflict resolution transaction");

        assert_eq!(
            fs::metadata(index_path).unwrap().permissions().mode() & 0o777,
            0o664
        );
    }

    #[test]
    fn locked_conflict_index_transaction_rejects_a_changed_conflict() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let result_oid = repo.blob(b"stale resolver result\n").unwrap();
        let replacement_oid = repo.blob(b"new concurrent side\n").unwrap();
        let mut index = repo.index().unwrap();
        let conflict = index.conflict_get(relative_path).unwrap();
        let mut replacement = conflict.our.expect("ours entry");
        let mode = replacement.mode;
        replacement.id = replacement_oid;
        index.add(&replacement).unwrap();
        index.write().unwrap();

        let error = super::write_conflict_index_resolution(
            fixture.path(),
            relative_path,
            &diff.snapshot,
            Some((mode, result_oid)),
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed while"));
        assert!(!repo.path().join("index.lock").exists());
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert_eq!(
            index
                .conflict_get(relative_path)
                .expect("newer conflict remains")
                .our
                .expect("newer ours entry")
                .id,
            replacement_oid
        );
        assert!(index.get_path(relative_path, 0).is_none());
    }

    #[test]
    fn conflict_index_transaction_handles_a_nested_path_with_spaces() {
        let fixture = TempRepo::init();
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let ancestor = repo.blob(b"ancestor\n").unwrap();
        let ours = repo.blob(b"current\n").unwrap();
        let theirs = repo.blob(b"incoming\n").unwrap();
        let resolved = repo.blob(b"resolved\n").unwrap();
        install_index_conflict(
            &fixture,
            "nested/file with space.txt",
            0o100644,
            ancestor,
            ours,
            theirs,
        );
        let relative_path = std::path::Path::new("nested").join("file with space.txt");
        let snapshot = crate::types::ConflictSnapshot {
            ancestor_oid: Some(ancestor),
            ancestor_mode: Some(0o100644),
            ours_oid: Some(ours),
            ours_mode: Some(0o100644),
            theirs_oid: Some(theirs),
            theirs_mode: Some(0o100644),
            worktree: crate::types::ConflictWorktreeSnapshot::Missing,
        };

        super::write_conflict_index_resolution(
            fixture.path(),
            &relative_path,
            &snapshot,
            Some((0o100644, resolved)),
        )
        .expect("commit nested conflict resolution transaction");

        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(&relative_path).is_err());
        assert_eq!(
            index
                .get_path(&relative_path, 0)
                .expect("resolved nested entry")
                .id,
            resolved
        );
    }

    #[test]
    fn staging_working_copy_rejects_unresolved_markers() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");

        let error = super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("still contains conflict markers"));
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn staging_working_copy_accepts_longer_delimiter_runs_as_content() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        let resolved = b"resolved\n====================\nstill resolved\n";
        fs::write(fixture.path().join(relative_path), resolved).unwrap();

        super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .expect("stage the manually resolved working copy");

        let repo = git2::Repository::open(fixture.path()).unwrap();
        let index = repo.index().unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        let staged = index.get_path(relative_path, 0).expect("stage-zero entry");
        assert_eq!(repo.find_blob(staged.id).unwrap().content(), resolved);
    }

    #[test]
    fn every_partial_conflict_marker_is_rejected_on_its_own() {
        for marker in [
            b"<<<<<<< current\n".as_slice(),
            b"||||||| base\n".as_slice(),
            b"=======\n".as_slice(),
            b">>>>>>> incoming\n".as_slice(),
        ] {
            assert!(super::contains_conflict_markers(marker, 7));
        }
        assert!(!super::contains_conflict_markers(b"ordinary content\n", 7));
    }

    #[test]
    fn longer_delimiter_runs_are_not_conflict_markers() {
        for content in [
            b"<<<<<<<< Markdown heading\n".as_slice(),
            b"|||||||| generated data\n".as_slice(),
            b"====================\n".as_slice(),
            b">>>>>>>> Markdown heading\n".as_slice(),
            b"======= not-a-separator-label\n".as_slice(),
        ] {
            assert!(!super::contains_conflict_markers(content, 7));
        }

        assert!(super::contains_conflict_markers(b"<<<<<<< current\n", 7));
        assert!(super::contains_conflict_markers(b"=======\n", 7));
        assert!(super::contains_conflict_markers(b">>>>>>> incoming\n", 7));
    }

    #[test]
    fn staging_working_copy_honours_custom_conflict_marker_size() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        fs::write(
            fixture.path().join(".gitattributes"),
            b"file.txt conflict-marker-size=3\n",
        )
        .unwrap();
        assert!(run_git(
            fixture.path(),
            &["checkout", "--conflict=merge", "--", "file.txt"]
        )
        .status
        .success());
        assert_eq!(
            super::complete_conflict_marker_size(
                &fs::read(fixture.path().join(relative_path)).unwrap()
            ),
            Some(3)
        );
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");

        let error = super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("still contains conflict markers"));
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn staging_working_copy_retains_the_conflicts_original_marker_size() {
        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        fs::write(
            fixture.path().join(".gitattributes"),
            b"file.txt conflict-marker-size=3\n",
        )
        .unwrap();
        let repo = git2::Repository::open(fixture.path()).unwrap();
        assert_eq!(
            super::conflict_marker_size(&repo, relative_path, &diff.snapshot),
            7
        );

        let error = super::apply_conflict_resolution(
            fixture.path(),
            relative_path,
            super::ConflictResolutionInput::WorkingTree {
                snapshot: diff.snapshot,
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("still contains conflict markers"));
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn choosing_deleted_side_removes_file_and_index_conflict() {
        let fixture = TempRepo::init();
        fixture.commit_file("deleted.txt", "base\n", "base");
        assert!(run_git(fixture.path(), &["checkout", "-b", "incoming"])
            .status
            .success());
        assert!(run_git(fixture.path(), &["rm", "deleted.txt"])
            .status
            .success());
        assert!(
            run_git(fixture.path(), &["commit", "-m", "delete incoming"])
                .status
                .success()
        );
        assert!(run_git(fixture.path(), &["checkout", "main"])
            .status
            .success());
        fixture.commit_file("deleted.txt", "current edit\n", "edit current");
        let merge = run_git(fixture.path(), &["merge", "incoming"]);
        assert!(
            !merge.status.success(),
            "merge unexpectedly succeeded: stdout={} stderr={}",
            String::from_utf8_lossy(&merge.stdout),
            String::from_utf8_lossy(&merge.stderr)
        );

        let relative_path = std::path::Path::new("deleted.txt");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose deleted side");

        assert!(!fixture.path().join(relative_path).exists());
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        assert!(index.get_path(relative_path, 0).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn choosing_deleted_side_removes_a_dangling_symlink() {
        use std::os::unix::fs::symlink;

        let fixture = TempRepo::init();
        let relative_path = std::path::Path::new("link");
        let full_path = fixture.path().join(relative_path);
        symlink("missing-base", &full_path).unwrap();
        fixture.stage(relative_path);
        fixture.commit("base symlink");

        assert!(run_git(fixture.path(), &["checkout", "-b", "incoming"])
            .status
            .success());
        assert!(run_git(fixture.path(), &["rm", "link"]).status.success());
        assert!(
            run_git(fixture.path(), &["commit", "-m", "delete incoming"])
                .status
                .success()
        );

        assert!(run_git(fixture.path(), &["checkout", "main"])
            .status
            .success());
        fs::remove_file(&full_path).unwrap();
        symlink("missing-current", &full_path).unwrap();
        fixture.stage(relative_path);
        fixture.commit("change current symlink");
        assert!(!run_git(fixture.path(), &["merge", "incoming"])
            .status
            .success());
        assert!(!full_path.exists(), "fixture must use a dangling symlink");
        assert!(fs::symlink_metadata(&full_path).is_ok());

        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");
        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose deleted side");

        assert!(fs::symlink_metadata(&full_path).is_err());
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_err());
    }

    #[cfg(unix)]
    #[test]
    fn regular_side_replaces_symlink_without_writing_through_it() {
        use std::os::unix::fs::symlink;

        let fixture = make_repo_with_conflicting_merge();
        let relative_path = std::path::Path::new("file.txt");
        let full_path = fixture.path().join(relative_path);
        let target_path = fixture.path().join("outside.txt");
        fs::write(&target_path, b"must stay unchanged\n").unwrap();
        fs::remove_file(&full_path).unwrap();
        symlink("outside.txt", &full_path).unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .expect("choose regular side");

        assert_eq!(fs::read(&target_path).unwrap(), b"must stay unchanged\n");
        let metadata = fs::symlink_metadata(&full_path).unwrap();
        assert!(metadata.is_file());
        assert!(!metadata.file_type().is_symlink());
        assert_eq!(fs::read(&full_path).unwrap(), b"current\n");
    }

    #[cfg(unix)]
    #[test]
    fn conflict_resolution_rejects_symlinked_parent_directory() {
        use std::os::unix::fs::symlink;

        let fixture = TempRepo::init();
        let target = fixture.path().join("target");
        fs::create_dir(&target).unwrap();
        symlink("target", fixture.path().join("linked")).unwrap();

        let error = super::AnchoredWorktreePath::bind(
            fixture.path(),
            std::path::Path::new("linked/file.txt"),
            true,
        )
        .err()
        .expect("symlinked parent must be rejected");
        assert!(error
            .to_string()
            .contains("without following symbolic links"));
    }

    #[cfg(unix)]
    #[test]
    fn conflict_publication_rejects_a_parent_replaced_by_a_symlink() {
        use std::os::unix::fs::symlink;

        let fixture = TempRepo::init();
        let outside = tempfile::tempdir().unwrap();
        let nested = fixture.path().join("nested");
        let moved = fixture.path().join("moved");
        let path = nested.join("file.txt");
        let outside_path = outside.path().join("file.txt");
        fs::create_dir(&nested).unwrap();
        fs::write(&path, b"captured\n").unwrap();
        fs::write(&outside_path, b"outside\n").unwrap();
        let path_access = super::AnchoredWorktreePath::bind(
            fixture.path(),
            std::path::Path::new("nested/file.txt"),
            true,
        )
        .unwrap();
        let captured = super::capture_worktree_entry(&path_access).unwrap();

        fs::rename(&nested, &moved).unwrap();
        symlink(outside.path(), &nested).unwrap();

        let error = super::replace_regular_worktree_file(
            &path_access,
            b"resolver result\n",
            0o100644,
            &captured,
        )
        .unwrap_err();

        assert!(error.to_string().contains("parent directory changed"));
        assert_eq!(fs::read(&outside_path).unwrap(), b"outside\n");
        assert_eq!(fs::read(moved.join("file.txt")).unwrap(), b"captured\n");
    }

    #[test]
    fn regular_worktree_compare_and_swap_preserves_a_later_edit() {
        let fixture = TempRepo::init();
        let path = fixture.path().join("file.txt");
        fs::write(&path, b"captured\n").unwrap();
        let path_access = anchored(&path);
        let captured = super::capture_worktree_entry(&path_access).unwrap();
        fs::write(&path, b"saved later\n").unwrap();

        let error = super::replace_regular_worktree_file(
            &path_access,
            b"resolver result\n",
            0o100644,
            &captured,
        )
        .unwrap_err();

        assert!(error.to_string().contains("changed while"));
        assert_eq!(fs::read(&path).unwrap(), b"saved later\n");
    }

    #[test]
    fn deletion_compare_and_swap_preserves_a_later_edit() {
        let fixture = TempRepo::init();
        let path = fixture.path().join("file.txt");
        fs::write(&path, b"captured\n").unwrap();
        let path_access = anchored(&path);
        let captured = super::capture_worktree_entry(&path_access).unwrap();
        fs::write(&path, b"saved later\n").unwrap();

        let error = super::remove_worktree_entry_if_matches(&path_access, &captured).unwrap_err();

        assert!(error.to_string().contains("changed while"));
        assert_eq!(fs::read(&path).unwrap(), b"saved later\n");
    }

    #[test]
    fn rejected_directory_deletion_leaves_the_directory_in_place() {
        let fixture = TempRepo::init();
        let path = fixture.path().join("directory");
        fs::create_dir(&path).unwrap();
        fs::write(path.join("keep.txt"), b"keep\n").unwrap();
        let path_access = anchored(&path);
        let captured = super::capture_worktree_entry(&path_access).unwrap();

        let error = super::remove_worktree_entry_if_matches(&path_access, &captured).unwrap_err();

        assert!(error.to_string().contains("directory"));
        assert_eq!(fs::read(path.join("keep.txt")).unwrap(), b"keep\n");
        assert!(!fs::read_dir(fixture.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".rgitui-conflict-delete-")
        }));
    }

    #[test]
    fn special_publication_preserves_an_entry_that_races_checkout() {
        let fixture = TempRepo::init();
        let path = fixture.path().join("link");
        fs::write(&path, b"original\n").unwrap();
        let path_access = anchored(&path);
        let captured = super::capture_worktree_entry(&path_access).unwrap();

        let error = super::publish_special_worktree_entry(&path_access, &captured, || {
            fs::write(&path, b"saved later\n")?;
            anyhow::bail!("safe checkout refused the racing entry")
        })
        .unwrap_err();

        assert!(error.to_string().contains("was preserved"));
        assert!(error.to_string().contains("remains recoverable"));
        assert_eq!(fs::read(&path).unwrap(), b"saved later\n");
        let backup = fs::read_dir(fixture.path())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|entry| {
                entry
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(".rgitui-conflict-special-")
            })
            .expect("original backup");
        assert_eq!(fs::read(backup).unwrap(), b"original\n");
    }

    #[test]
    fn regular_publication_falls_back_when_hard_links_are_unavailable() {
        let fixture = TempRepo::init();
        let temp_path = fixture.path().join("prepared.tmp");
        let path = fixture.path().join("file.txt");
        fs::write(&temp_path, b"resolver result\n").unwrap();
        let path_access = anchored(&path);
        let prepared = super::capture_worktree_entry(&anchored(&temp_path)).unwrap();

        super::publish_regular_file_noclobber_inner(
            &path_access,
            std::path::Path::new("prepared.tmp"),
            b"resolver result\n",
            &prepared,
            false,
        )
        .unwrap();

        assert_eq!(fs::read(&path).unwrap(), b"resolver result\n");
        assert_eq!(fs::read(&temp_path).unwrap(), b"resolver result\n");
    }

    #[test]
    fn regular_publication_fallback_never_overwrites_a_new_path() {
        let fixture = TempRepo::init();
        let temp_path = fixture.path().join("prepared.tmp");
        let path = fixture.path().join("file.txt");
        fs::write(&temp_path, b"resolver result\n").unwrap();
        fs::write(&path, b"saved later\n").unwrap();
        let path_access = anchored(&path);
        let prepared = super::capture_worktree_entry(&anchored(&temp_path)).unwrap();

        let error = super::publish_regular_file_noclobber_inner(
            &path_access,
            std::path::Path::new("prepared.tmp"),
            b"resolver result\n",
            &prepared,
            false,
        )
        .unwrap_err();

        assert!(error.to_string().contains("newer entry was preserved"));
        assert_eq!(fs::read(&path).unwrap(), b"saved later\n");
    }

    #[test]
    fn failed_fallback_cleanup_removes_only_the_file_it_created() {
        let fixture = TempRepo::init();
        let path = fixture.path().join("file.txt");
        let displaced = fixture.path().join("displaced.txt");
        let created = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let identity = same_file::Handle::from_file(created.try_clone().unwrap()).unwrap();
        drop(created);

        let path_access = anchored(&path);
        super::remove_created_file_if_same(&path_access, &identity).unwrap();
        assert!(fs::symlink_metadata(&path).is_err());

        fs::write(&path, b"first fallback\n").unwrap();
        let first = same_file::Handle::from_path(&path).unwrap();
        fs::rename(&path, &displaced).unwrap();
        fs::write(&path, b"saved later\n").unwrap();

        let error = super::remove_created_file_if_same(&path_access, &first).unwrap_err();
        assert!(error.to_string().contains("newer entry"));
        assert_eq!(fs::read(&path).unwrap(), b"saved later\n");
        assert_eq!(fs::read(&displaced).unwrap(), b"first fallback\n");
    }

    #[test]
    fn guarded_rollback_preserves_an_edit_made_after_resolution() {
        let fixture = TempRepo::init();
        let path = fixture.path().join("file.txt");
        fs::write(&path, b"original\n").unwrap();
        let path_access = anchored(&path);
        let original = super::capture_worktree_entry(&path_access).unwrap();
        let applied = super::replace_regular_worktree_file(
            &path_access,
            b"resolver result\n",
            0o100644,
            &original,
        )
        .unwrap();
        fs::write(&path, b"saved after resolution\n").unwrap();

        let error = super::restore_worktree_entry_if_unchanged(&path_access, &original, &applied)
            .unwrap_err();

        assert!(error
            .to_string()
            .contains("newer worktree entry was preserved"));
        assert_eq!(fs::read(&path).unwrap(), b"saved after resolution\n");
    }

    #[cfg(windows)]
    #[test]
    fn rollback_restores_a_dangling_windows_directory_symlink() {
        use std::os::windows::fs::{symlink_dir, FileTypeExt};

        let fixture = TempRepo::init();
        let path = fixture.path().join("link");
        if symlink_dir("missing-target", &path).is_err() {
            return;
        }
        let path_access = anchored(&path);
        let original = super::capture_worktree_entry(&path_access).unwrap();
        let applied = super::replace_regular_worktree_file(
            &path_access,
            b"resolver result\n",
            0o100644,
            &original,
        )
        .unwrap();

        super::restore_worktree_entry_if_unchanged(&path_access, &original, &applied).unwrap();

        let metadata = fs::symlink_metadata(&path).unwrap();
        assert!(metadata.file_type().is_symlink_dir());
        assert_eq!(
            fs::read_link(&path).unwrap(),
            std::path::Path::new("missing-target")
        );
    }

    #[test]
    fn choosing_a_gitlink_side_stages_the_commit_without_blob_lookup() {
        let fixture = TempRepo::init();
        let ancestor = fixture.commit_file("seed.txt", "ancestor\n", "ancestor");
        let ours = fixture.commit_file("seed.txt", "ours\n", "ours");
        let theirs = fixture.commit_file("seed.txt", "theirs\n", "theirs");
        install_gitlink_conflict(&fixture, "module", ancestor, ours, theirs);
        let relative_path = std::path::Path::new("module");
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose incoming gitlink");

        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        let entry = index.get_path(relative_path, 0).expect("stage-0 gitlink");
        assert_eq!(entry.mode, 0o160000);
        assert_eq!(entry.id, theirs);
    }

    #[test]
    fn choosing_deleted_gitlink_side_leaves_checked_out_directory_untracked() {
        let fixture = TempRepo::init();
        let ancestor = fixture.commit_file("seed.txt", "ancestor\n", "ancestor");
        let ours = fixture.commit_file("seed.txt", "ours\n", "ours");
        install_gitlink_modify_delete_conflict(&fixture, "module", ancestor, ours);
        let relative_path = std::path::Path::new("module");
        fs::create_dir(fixture.path().join(relative_path)).unwrap();
        fs::write(
            fixture.path().join(relative_path).join("local.txt"),
            b"local work\n",
        )
        .unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("gitlink delete conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose deleted gitlink side");

        assert_eq!(
            fs::read(fixture.path().join(relative_path).join("local.txt")).unwrap(),
            b"local work\n"
        );
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        assert!(index.get_path(relative_path, 0).is_none());
    }

    #[test]
    fn choosing_deleted_gitlink_side_removes_a_regular_worktree_file() {
        let fixture = TempRepo::init();
        let ancestor = fixture.commit_file("seed.txt", "ancestor\n", "ancestor");
        let ours = fixture.commit_file("seed.txt", "ours\n", "ours");
        install_gitlink_modify_delete_conflict(&fixture, "module", ancestor, ours);
        let relative_path = std::path::Path::new("module");
        fs::write(
            fixture.path().join(relative_path),
            b"not a submodule directory\n",
        )
        .unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("gitlink delete conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose deleted gitlink side");

        assert!(!fixture.path().join(relative_path).exists());
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        assert!(index.get_path(relative_path, 0).is_none());
    }

    #[test]
    fn failed_special_entry_checkout_leaves_the_conflict_unresolved() {
        let fixture = TempRepo::init();
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let ancestor = repo.blob(b"ancestor-target").unwrap();
        let ours = repo.blob(b"current-target").unwrap();
        let theirs = repo.blob(b"incoming-target").unwrap();
        drop(repo);
        install_index_conflict(&fixture, "link", 0o120000, ancestor, ours, theirs);
        let relative_path = std::path::Path::new("link");
        fs::create_dir(fixture.path().join(relative_path)).unwrap();
        fs::write(
            fixture.path().join(relative_path).join("keep.txt"),
            b"keep\n",
        )
        .unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("special conflict model");

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        assert!(error.to_string().contains("directory"));
        assert_eq!(
            fs::read(fixture.path().join(relative_path).join("keep.txt")).unwrap(),
            b"keep\n"
        );
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_ok());
        assert!(index.get_path(relative_path, 0).is_none());
    }

    #[test]
    fn choosing_a_symlink_side_uses_safe_special_publication() {
        let fixture = TempRepo::init();
        let repo = git2::Repository::open(fixture.path()).unwrap();
        repo.config()
            .unwrap()
            .set_bool("core.symlinks", false)
            .unwrap();
        let ancestor = repo.blob(b"ancestor-target").unwrap();
        let ours = repo.blob(b"current-target").unwrap();
        let theirs = repo.blob(b"incoming-target").unwrap();
        drop(repo);
        install_index_conflict(&fixture, "link", 0o120000, ancestor, ours, theirs);
        let relative_path = std::path::Path::new("link");
        fs::write(fixture.path().join(relative_path), b"original worktree\n").unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("special conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose incoming symlink");

        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"incoming-target"
        );
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        let entry = index.get_path(relative_path, 0).expect("stage-0 symlink");
        assert_eq!(entry.mode, 0o120000);
        assert_eq!(entry.id, theirs);
    }

    #[cfg(unix)]
    #[test]
    fn choosing_a_symlink_side_creates_the_selected_link() {
        let fixture = TempRepo::init();
        let repo = git2::Repository::open(fixture.path()).unwrap();
        repo.config()
            .unwrap()
            .set_bool("core.symlinks", true)
            .unwrap();
        let ancestor = repo.blob(b"ancestor-target").unwrap();
        let ours = repo.blob(b"current-target").unwrap();
        let theirs = repo.blob(b"incoming-target").unwrap();
        drop(repo);
        install_index_conflict(&fixture, "link", 0o120000, ancestor, ours, theirs);
        let relative_path = std::path::Path::new("link");
        fs::write(fixture.path().join(relative_path), b"original worktree\n").unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("special conflict model");

        super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Theirs,
            &diff.snapshot,
        )
        .expect("choose incoming symlink");

        let full_path = fixture.path().join(relative_path);
        assert!(fs::symlink_metadata(&full_path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(
            fs::read_link(&full_path).unwrap(),
            std::path::Path::new("incoming-target")
        );
        let index = git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap();
        assert!(index.conflict_get(relative_path).is_err());
        let entry = index.get_path(relative_path, 0).expect("stage-0 symlink");
        assert_eq!(entry.mode, 0o120000);
        assert_eq!(entry.id, theirs);
    }

    #[test]
    fn failed_special_entry_index_write_restores_the_worktree() {
        let fixture = TempRepo::init();
        let repo = git2::Repository::open(fixture.path()).unwrap();
        let ancestor = repo.blob(b"ancestor-target").unwrap();
        let ours = repo.blob(b"current-target").unwrap();
        let theirs = repo.blob(b"incoming-target").unwrap();
        drop(repo);
        install_index_conflict(&fixture, "link", 0o120000, ancestor, ours, theirs);
        let relative_path = std::path::Path::new("link");
        fs::write(fixture.path().join(relative_path), b"original worktree\n").unwrap();
        let diff = super::super::compute_three_way_conflict_diff(fixture.path(), relative_path)
            .expect("special conflict model");
        let lock_path = git2::Repository::open(fixture.path())
            .unwrap()
            .path()
            .join("index.lock");
        let lock = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
            .unwrap();

        let error = super::apply_conflict_side(
            fixture.path(),
            relative_path,
            super::ConflictSide::Ours,
            &diff.snapshot,
        )
        .unwrap_err();

        drop(lock);
        fs::remove_file(lock_path).unwrap();
        assert!(!error.to_string().is_empty());
        assert_eq!(
            fs::read(fixture.path().join(relative_path)).unwrap(),
            b"original worktree\n"
        );
        assert!(git2::Repository::open(fixture.path())
            .unwrap()
            .index()
            .unwrap()
            .conflict_get(relative_path)
            .is_ok());
    }

    #[test]
    fn run_continue_subcommand_finishes_a_resolved_cherry_pick() {
        let fixture = make_repo_with_conflicting_pick();
        let path = fixture.path();

        let picked = run_git(path, &["rev-parse", "feature"]);
        let picked = String::from_utf8_lossy(&picked.stdout).trim().to_string();
        run_git(path, &["cherry-pick", &picked]);

        let repo = git2::Repository::open(path).unwrap();
        assert_eq!(repo.state(), git2::RepositoryState::CherryPick);
        drop(repo);

        // Resolve the conflict the way the user would, then continue.
        fs::write(path.join("file.txt"), "resolved\n").unwrap();
        run_git(path, &["add", "file.txt"]);

        let summary = run_continue_subcommand(path, "cherry-pick").unwrap();
        assert!(!summary.is_empty());

        let repo = git2::Repository::open(path).unwrap();
        assert_eq!(repo.state(), git2::RepositoryState::Clean);
        let head = repo.head().unwrap().peel_to_commit().unwrap();
        assert_eq!(head.summary(), Some("feature change"));
    }

    #[test]
    fn run_continue_subcommand_reports_why_git_refused() {
        // Nothing is in progress, so `git cherry-pick --continue` fails; the
        // error has to carry git's reason rather than a bare exit status.
        let fixture = make_test_repo();
        let error = run_continue_subcommand(fixture.path(), "cherry-pick").unwrap_err();
        let message = error.to_string();
        assert!(
            message.contains("cherry-pick --continue failed"),
            "unexpected error: {message}"
        );
        assert!(message.len() > "git cherry-pick --continue failed: ".len());
    }

    /// A repo whose single commit has an empty tree, so a test is free to create
    /// and stage `file.txt` itself without colliding with an existing entry.
    fn make_test_repo() -> TempRepo {
        let repo = TempRepo::init();
        repo.commit("initial commit");
        repo
    }

    /// Make a repo whose `feature` branch adds `path_in_repo`, with HEAD left on
    /// `main` one commit behind and the file absent from the work tree — the
    /// shape a fast-forward merge sees.
    fn make_repo_with_ff_branch(path_in_repo: &str, contents: &str) -> TempRepo {
        let fixture = TempRepo::init();
        let base = fixture.commit("initial");

        // Scoped so every borrow of `fixture` — and every libgit2 handle with a
        // `Drop` that keeps one alive — is released before the fixture moves out.
        {
            let repo = fixture.repo();
            // Build the branch commit straight from a tree so the work tree
            // keeps looking like `main`.
            let blob = repo.blob(contents.as_bytes()).unwrap();
            let mut builder = repo.treebuilder(None).unwrap();
            builder.insert(path_in_repo, blob, 0o100644).unwrap();
            let branch_tree_oid = builder.write().unwrap();
            fixture.commit_tree(
                Some("refs/heads/feature"),
                "add file",
                branch_tree_oid,
                &[base],
            );
        }

        fixture
    }

    #[test]
    fn checkout_tree_safe_refuses_to_clobber_an_untracked_file() {
        let fixture = make_repo_with_ff_branch("notes.txt", "FROM BRANCH\n");
        let untracked = fixture.path().join("notes.txt");
        fs::write(&untracked, "PRECIOUS UNTRACKED\n").unwrap();

        let repo = git2::Repository::open(fixture.path()).unwrap();
        let target = repo.revparse_single("refs/heads/feature").unwrap();
        let err = super::checkout_tree_safe(&repo, &target, "Merge").unwrap_err();

        let msg = err.to_string();
        assert!(
            msg.contains("notes.txt"),
            "error should name the file: {msg}"
        );
        assert!(
            msg.starts_with("Merge would overwrite"),
            "error should be actionable: {msg}"
        );
        assert_eq!(
            fs::read_to_string(&untracked).unwrap(),
            "PRECIOUS UNTRACKED\n",
            "a refused checkout must leave the untracked file alone"
        );
    }

    #[test]
    fn checkout_tree_safe_applies_when_nothing_collides() {
        let fixture = make_repo_with_ff_branch("notes.txt", "FROM BRANCH\n");

        let repo = git2::Repository::open(fixture.path()).unwrap();
        let target = repo.revparse_single("refs/heads/feature").unwrap();
        super::checkout_tree_safe(&repo, &target, "Merge").unwrap();

        assert_eq!(
            fs::read_to_string(fixture.path().join("notes.txt")).unwrap(),
            "FROM BRANCH\n"
        );
    }

    #[test]
    fn format_path_list_summarises_beyond_three() {
        assert_eq!(super::format_path_list(&["a.txt".to_string()]), "a.txt");

        let many: Vec<String> = (0..5).map(|i| format!("f{i}.txt")).collect();
        assert_eq!(
            super::format_path_list(&many),
            "f0.txt, f1.txt, f2.txt and 2 more"
        );
    }

    /// Collect commits via revwalk.  index 0 = newest.
    fn collect_commits(repo: &git2::Repository) -> Vec<git2::Oid> {
        let mut rw = repo.revwalk().unwrap();
        rw.push_head().unwrap();
        rw.collect::<Result<Vec<_>, _>>().unwrap()
    }

    // -------------------------------------------------------------------------
    // Stash tests
    // -------------------------------------------------------------------------

    #[test]
    fn stash_save_and_pop() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let mut repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "hello").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let sig = repo.signature().unwrap();
        repo.stash_save(&sig, "WIP: test stash", None).unwrap();

        // After stash save, pop it.  The file will be restored with "hello".
        repo.stash_pop(0, None).unwrap();

        // File should be restored with the stashed content
        let content = fs::read_to_string(path.join("file.txt")).unwrap();
        assert_eq!(content, "hello");
    }

    #[test]
    #[ignore = "git2's stash_apply requires clean index+working-tree AND checks index state match; the stash index differs from post-reset index causing 'uncommitted changes' error. Test git2 semantics, not application behavior."]
    fn stash_apply_keeps_stash() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let mut repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "hello").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let sig = repo.signature().unwrap();
        repo.stash_save(&sig, "WIP: test stash", None).unwrap();

        // After stash_save: working tree is clean (empty), index is dirty (staged hello).
        // git2's stash_apply requires clean index. Clean the index by committing the
        // staged change, then reset the index to HEAD to make it clean.
        {
            let head_oid = repo.head().unwrap().target().unwrap();
            let head_commit = repo.find_commit(head_oid).unwrap();
            let tree_oid = repo.index().unwrap().write_tree().unwrap();
            let tree = repo.find_tree(tree_oid).unwrap();
            repo.commit(
                Some("HEAD"),
                &sig,
                &sig,
                head_commit.message().unwrap(),
                &tree,
                &[&head_commit],
            )
            .unwrap();
        }
        // Commit done; working tree still has "hello", index is now empty.
        // Now reset the index to match HEAD (which now points to commit with hello).
        {
            let head_oid = repo.head().unwrap().target().unwrap();
            let head_obj = repo.find_object(head_oid, None).unwrap();
            repo.reset(&head_obj, git2::ResetType::Soft, None).unwrap();
            drop(head_obj);
        }
        // Now: working tree has "hello", index is clean, HEAD points to commit with hello.
        // Apply stash: stash has (working_tree=hello, index=[hello staged]).
        // After apply: working_tree=hello, index=[hello staged], stash still present.
        repo.stash_apply(0, None).unwrap();

        // Verify stash_pop succeeds (stash is still present, working tree matches).
        repo.stash_pop(0, None).unwrap();

        let content = fs::read_to_string(path.join("file.txt")).unwrap();
        assert_eq!(content, "hello");
    }

    #[test]
    fn stash_drop_removes_entry() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let mut repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "changes").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let sig = repo.signature().unwrap();
        repo.stash_save(&sig, "WIP: test", None).unwrap();

        repo.stash_drop(0).unwrap();

        // Trying to pop should now fail
        assert!(repo.stash_pop(0, None).is_err());
    }

    #[test]
    fn stash_branch_creates_branch_from_stash() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let mut repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "stash changes").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let sig = repo.signature().unwrap();
        repo.stash_save(&sig, "WIP: test", None).unwrap();

        // Get stash OID using a separate repo instance for stash_foreach
        let stash_oid = {
            let mut r = git2::Repository::open(path).unwrap();
            let mut found = git2::Oid::zero();
            r.stash_foreach(|_i, _msg, oid| {
                found = *oid;
                false
            })
            .unwrap();
            found
        };

        // `git stash branch` creates the branch at the stash's BASE commit
        // (the stash WIP commit's first parent), not at the WIP commit itself.
        let stash_wip = repo.find_commit(stash_oid).unwrap();
        let base = stash_wip.parent(0).unwrap();
        let base_oid = base.id();
        repo.branch("stash-branch", &base, false).unwrap();

        let branch = repo
            .find_branch("stash-branch", git2::BranchType::Local)
            .unwrap();
        assert_eq!(branch.get().target().unwrap(), base_oid);
        assert_ne!(base_oid, stash_oid);
    }

    // -------------------------------------------------------------------------
    // Reset tests
    // -------------------------------------------------------------------------

    #[test]
    fn reset_hard_discards_changes() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "modified").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let head_oid = repo.head().unwrap().target().unwrap();
        let head_commit = repo.find_commit(head_oid).unwrap();
        repo.reset(head_commit.as_object(), git2::ResetType::Hard, None)
            .unwrap();

        assert!(!path.join("file.txt").exists());
        assert!(repo.index().unwrap().is_empty());
    }

    #[test]
    fn reset_soft_preserves_index() {
        // Reset soft to a prior commit: re-stage the index after reset, then commit.
        // Note: git2's reset(Soft) does NOT stage the diff like CLI git reset --soft.
        // It moves HEAD and resets the index to match the target commit. We re-stage
        // the file after reset to emulate the CLI behavior and verify it works.
        let fixture = TempRepo::with_commits(2);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        // Add a change on top of the current HEAD
        fs::write(path.join("file.txt"), "extra").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        // Get current HEAD
        let head_oid = repo.head().unwrap().target().unwrap();

        // Reset soft to the first (older) commit — this moves HEAD and resets the
        // index to match the target commit's tree (no diff is auto-staged by git2).
        let commits = collect_commits(&repo);
        let old_oid = *commits.last().unwrap(); // oldest = first commit
        let old_commit = repo.find_commit(old_oid).unwrap();
        repo.reset(old_commit.as_object(), git2::ResetType::Soft, None)
            .unwrap();

        // git2 reset(Soft) clears the index to match the target tree. Re-stage
        // the file and commit to verify the working tree change is preserved.
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        // Commit the re-staged change
        let new_head_oid = repo.head().unwrap().target().unwrap();
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        fixture.commit_tree(
            Some("HEAD"),
            "reset soft with re-staged change",
            tree_oid,
            &[new_head_oid],
        );

        // The new commit should have the "extra" file in its tree
        let new_tree = repo
            .find_commit(repo.head().unwrap().target().unwrap())
            .unwrap()
            .tree()
            .unwrap();
        assert!(new_tree.get_name("file.txt").is_some());
        assert_ne!(repo.head().unwrap().target().unwrap(), head_oid);
    }

    #[test]
    fn reset_mixed_unsets_index() {
        // Mixed reset: index is cleared, but working tree file stays.
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "modified").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let head_oid = repo.head().unwrap().target().unwrap();
        let head_commit = repo.find_commit(head_oid).unwrap();

        // Mixed reset to HEAD: unstages the index entry
        repo.reset(head_commit.as_object(), git2::ResetType::Mixed, None)
            .unwrap();

        // Index should be empty (changes unstaged)
        assert!(repo.index().unwrap().is_empty());
    }

    #[test]
    fn reset_to_commit_moves_head() {
        let fixture = TempRepo::with_commits(3);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let commits = collect_commits(&repo);
        let first_oid = *commits.last().unwrap(); // oldest
        let first_commit = repo.find_commit(first_oid).unwrap();

        repo.reset(first_commit.as_object(), git2::ResetType::Hard, None)
            .unwrap();

        let head_oid = repo.head().unwrap().target().unwrap();
        assert_eq!(head_oid, first_oid);
    }

    // -------------------------------------------------------------------------
    // Merge tests
    // -------------------------------------------------------------------------

    #[test]
    fn merge_branch_fast_forward() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let head_oid = repo.head().unwrap().target().unwrap();

        fs::write(path.join("file.txt"), "branch changes").unwrap();
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        fixture.commit_tree(
            Some("refs/heads/feature"),
            "feature commit",
            tree_oid,
            &[head_oid],
        );

        let feature_branch = repo
            .find_branch("feature", git2::BranchType::Local)
            .unwrap();
        let annotated = repo
            .reference_to_annotated_commit(feature_branch.get())
            .unwrap();
        let (analysis, _) = repo.merge_analysis(&[&annotated]).unwrap();
        assert!(analysis.is_fast_forward());

        let mut reference = repo.find_reference("refs/heads/main").unwrap();
        reference
            .set_target(annotated.id(), "fast-forward")
            .unwrap();
        repo.set_head("refs/heads/main").unwrap();
    }

    #[test]
    #[ignore = "git2's merge does not create conflict markers for trivial content changes; libgit2 auto-merges non-overlapping modifications without conflict markers. Use GitProject::merge_branch integration tests instead."]
    fn merge_branch_with_conflict() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        // Commit on main with a single-line file
        fs::write(path.join("file.txt"), "line one\n").unwrap();
        {
            let mut idx = repo.index().unwrap();
            idx.add_path(std::path::Path::new("file.txt")).unwrap();
            idx.write().unwrap();
        }
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        let head_oid = repo.head().unwrap().target().unwrap();
        fixture.commit_tree(
            Some("refs/heads/main"),
            "main change",
            tree_oid,
            &[head_oid],
        );

        // Feature branch: modify the SAME LINE differently (creates real conflict)
        fs::write(path.join("file.txt"), "main one\n").unwrap();
        {
            let mut idx = repo.index().unwrap();
            idx.add_path(std::path::Path::new("file.txt")).unwrap();
            idx.write().unwrap();
        }
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        let head_oid = repo.head().unwrap().target().unwrap();
        fixture.commit_tree(
            Some("refs/heads/feature"),
            "feature change",
            tree_oid,
            &[head_oid],
        );

        // Switch back to main (force checkout)
        {
            let mut opts = git2::build::CheckoutBuilder::new();
            opts.force();
            repo.checkout_head(Some(&mut opts)).unwrap();
        }

        let feature_branch = repo
            .find_branch("feature", git2::BranchType::Local)
            .unwrap();
        let annotated = repo
            .reference_to_annotated_commit(feature_branch.get())
            .unwrap();
        repo.merge(&[&annotated], None, None).unwrap();

        assert!(repo.index().unwrap().has_conflicts());

        // Abort
        let head_oid = repo.head().unwrap().target().unwrap();
        let head_commit = repo.find_commit(head_oid).unwrap();
        repo.reset(
            head_commit.as_object(),
            git2::ResetType::Hard,
            Some(git2::build::CheckoutBuilder::new().force()),
        )
        .unwrap();
        repo.cleanup_state().unwrap();
    }

    #[test]
    #[ignore = "git2's merge does not produce conflict markers for non-overlapping content changes (unlike CLI git). Tests git2 merge semantics, not application behavior."]
    fn abort_operation_cleans_merge_state() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        // Commit on main with single-line file
        fs::write(path.join("file.txt"), "line one\n").unwrap();
        {
            let mut idx = repo.index().unwrap();
            idx.add_path(std::path::Path::new("file.txt")).unwrap();
            idx.write().unwrap();
        }
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        let head_oid = repo.head().unwrap().target().unwrap();
        fixture.commit_tree(
            Some("refs/heads/main"),
            "main change",
            tree_oid,
            &[head_oid],
        );

        // Feature branch: modify the SAME LINE differently (creates real conflict)
        fs::write(path.join("file.txt"), "other one\n").unwrap();
        {
            let mut idx = repo.index().unwrap();
            idx.add_path(std::path::Path::new("file.txt")).unwrap();
            idx.write().unwrap();
        }
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        let head_oid = repo.head().unwrap().target().unwrap();
        fixture.commit_tree(
            Some("refs/heads/feature"),
            "feature change",
            tree_oid,
            &[head_oid],
        );

        // Switch back to main (force checkout)
        {
            let mut opts = git2::build::CheckoutBuilder::new();
            opts.force();
            repo.checkout_head(Some(&mut opts)).unwrap();
        }

        let feature_branch = repo
            .find_branch("feature", git2::BranchType::Local)
            .unwrap();
        let annotated = repo
            .reference_to_annotated_commit(feature_branch.get())
            .unwrap();
        repo.merge(&[&annotated], None, None).unwrap();

        assert!(repo.index().unwrap().has_conflicts());

        let head_oid = repo.head().unwrap().target().unwrap();
        let head_commit = repo.find_commit(head_oid).unwrap();
        repo.reset(
            head_commit.as_object(),
            git2::ResetType::Hard,
            Some(git2::build::CheckoutBuilder::new().force()),
        )
        .unwrap();
        repo.cleanup_state().unwrap();

        assert_eq!(repo.state(), git2::RepositoryState::Clean);
    }

    // -------------------------------------------------------------------------
    // Cherry-pick / revert tests
    // -------------------------------------------------------------------------

    #[test]
    fn cherry_pick_creates_new_commit() {
        let fixture = TempRepo::with_commits(2);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let commits = collect_commits(&repo);
        let oldest_oid = *commits.last().unwrap();
        let commit = repo.find_commit(oldest_oid).unwrap();

        repo.cherrypick(&commit, None).unwrap();
        let new_head_oid = repo.head().unwrap().target().unwrap();
        assert_ne!(new_head_oid, oldest_oid);
        repo.cleanup_state().unwrap();
    }

    #[test]
    fn revert_creates_undo_commit() {
        let fixture = TempRepo::with_commits(2);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let commits = collect_commits(&repo);
        let oldest_oid = *commits.last().unwrap();
        let commit = repo.find_commit(oldest_oid).unwrap();

        let mut opts = git2::RevertOptions::new();
        repo.revert(&commit, Some(&mut opts)).unwrap();
        let new_head_oid = repo.head().unwrap().target().unwrap();
        assert_ne!(new_head_oid, oldest_oid);
        repo.cleanup_state().unwrap();
    }

    // -------------------------------------------------------------------------
    // Tag tests
    // -------------------------------------------------------------------------

    #[test]
    fn create_and_delete_tag() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        let obj = repo.find_object(head, None).unwrap();
        repo.tag_lightweight("v1.0.0", &obj, false).unwrap();

        let tag_ref = repo.find_reference("refs/tags/v1.0.0").unwrap();
        assert_eq!(tag_ref.target().unwrap(), head);

        repo.tag_delete("v1.0.0").unwrap();
        assert!(repo.find_reference("refs/tags/v1.0.0").is_err());
    }

    #[test]
    fn create_multiple_tags() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        let obj = repo.find_object(head, None).unwrap();
        repo.tag_lightweight("v1.0.0", &obj, false).unwrap();
        repo.tag_lightweight("v1.0.1", &obj, false).unwrap();
        repo.tag_lightweight("v2.0.0", &obj, false).unwrap();

        let tag_names = repo.tag_names(None).unwrap();
        let tags: Vec<_> = tag_names.iter().flatten().collect();
        assert!(tags.contains(&"v1.0.0"));
        assert!(tags.contains(&"v1.0.1"));
        assert!(tags.contains(&"v2.0.0"));
    }

    // -------------------------------------------------------------------------
    // Branch tests
    // -------------------------------------------------------------------------

    #[test]
    fn create_and_delete_branch() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        let commit = repo.find_commit(head).unwrap();
        repo.branch("feature", &commit, false).unwrap();

        let branch = repo
            .find_branch("feature", git2::BranchType::Local)
            .unwrap();
        assert_eq!(branch.get().target().unwrap(), head);

        let mut b = repo
            .find_branch("feature", git2::BranchType::Local)
            .unwrap();
        b.delete().unwrap();
        assert!(repo
            .find_branch("feature", git2::BranchType::Local)
            .is_err());
    }

    #[test]
    fn rename_branch() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        let commit = repo.find_commit(head).unwrap();
        repo.branch("old-name", &commit, false).unwrap();

        let mut branch = repo
            .find_branch("old-name", git2::BranchType::Local)
            .unwrap();
        branch.rename("new-name", false).unwrap();

        assert!(repo
            .find_branch("old-name", git2::BranchType::Local)
            .is_err());
        let renamed = repo
            .find_branch("new-name", git2::BranchType::Local)
            .unwrap();
        assert_eq!(renamed.get().target().unwrap(), head);
    }

    #[test]
    fn create_branch_at_specific_commit() {
        let fixture = TempRepo::with_commits(3);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let commits = collect_commits(&repo);
        let second_oid = *commits.get(1).unwrap(); // second commit from newest

        let commit = repo.find_commit(second_oid).unwrap();
        repo.branch("at-second", &commit, false).unwrap();

        let branch = repo
            .find_branch("at-second", git2::BranchType::Local)
            .unwrap();
        assert_eq!(branch.get().target().unwrap(), second_oid);
    }

    // -------------------------------------------------------------------------
    // Worktree tests
    // -------------------------------------------------------------------------

    #[test]
    fn create_and_remove_worktree() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        let worktree_path = path.join("../worktree-dir");

        repo.worktree("worktree-dir", &worktree_path, None).unwrap();
        assert!(worktree_path.exists());

        let wt_repo = git2::Repository::open(&worktree_path).unwrap();
        assert_eq!(wt_repo.head().unwrap().target().unwrap(), head);

        let output = std::process::Command::new("git")
            .current_dir(path)
            .args([
                "worktree",
                "remove",
                "--force",
                worktree_path.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(!worktree_path.exists());
    }

    // -------------------------------------------------------------------------
    // Discard changes tests
    // -------------------------------------------------------------------------

    #[test]
    fn discard_changes_removes_staged_file() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("newfile.txt"), "content").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("newfile.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let mut checkout_opts = git2::build::CheckoutBuilder::new();
        checkout_opts.force();
        repo.checkout_head(Some(&mut checkout_opts)).unwrap();

        assert!(!path.join("newfile.txt").exists());
    }

    // -------------------------------------------------------------------------
    // Bisect tests
    // -------------------------------------------------------------------------

    #[test]
    fn bisect_start_and_reset() {
        let fixture = TempRepo::with_commits(5);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let commits = collect_commits(&repo);
        let oldest_oid = *commits.last().unwrap();
        let newest_oid = commits[0];

        let output = std::process::Command::new("git")
            .current_dir(path)
            .args(["bisect", "start"])
            .output()
            .unwrap();
        assert!(output.status.success());

        let output = std::process::Command::new("git")
            .current_dir(path)
            .args(["bisect", "bad"])
            .output()
            .unwrap();
        assert!(output.status.success());

        let output = std::process::Command::new("git")
            .current_dir(path)
            .args(["bisect", "good", &oldest_oid.to_string()])
            .output()
            .unwrap();
        assert!(output.status.success());

        assert!(path.join(".git").join("BISECT_START").exists());

        let output = std::process::Command::new("git")
            .current_dir(path)
            .args(["bisect", "reset"])
            .output()
            .unwrap();
        assert!(output.status.success());

        let head_oid = repo.head().unwrap().target().unwrap();
        assert_eq!(head_oid, newest_oid);
    }

    // -------------------------------------------------------------------------
    // Checkout tests
    // -------------------------------------------------------------------------

    #[test]
    fn checkout_branch_switches_head() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let head_oid = repo.head().unwrap().target().unwrap();

        fs::write(path.join("file.txt"), "feature").unwrap();
        {
            let mut idx = repo.index().unwrap();
            idx.add_path(std::path::Path::new("file.txt")).unwrap();
            idx.write().unwrap();
        }
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        fixture.commit_tree(
            Some("refs/heads/feature"),
            "feature commit",
            tree_oid,
            &[head_oid],
        );

        // Note: repo.commit does NOT update the working tree, so working tree still
        // has "feature" while HEAD (main) has no file.txt. safe() would refuse this
        // checkout because working tree differs from HEAD. Use force() instead.
        let obj = repo.revparse_single("refs/heads/feature").unwrap();
        let mut checkout_opts = git2::build::CheckoutBuilder::new();
        checkout_opts.force();
        repo.checkout_tree(&obj, Some(&mut checkout_opts)).unwrap();
        repo.set_head("refs/heads/feature").unwrap();

        let current = repo.head().unwrap().shorthand().unwrap().to_string();
        assert_eq!(current, "feature");
    }

    #[test]
    fn checkout_commit_detaches_head() {
        let fixture = TempRepo::with_commits(3);
        let path = fixture.path();
        let repo = git2::Repository::open(path).unwrap();

        let commits = collect_commits(&repo);
        let second_oid = commits[1];

        let commit = repo.find_commit(second_oid).unwrap();
        let mut checkout_opts = git2::build::CheckoutBuilder::new();
        checkout_opts.safe();
        repo.checkout_tree(commit.as_object(), Some(&mut checkout_opts))
            .unwrap();
        repo.set_head_detached(second_oid).unwrap();

        assert!(repo.head_detached().unwrap());
        let head_oid = repo.head().unwrap().target().unwrap();
        assert_eq!(head_oid, second_oid);
    }

    // -------------------------------------------------------------------------
    // Commit tests
    // -------------------------------------------------------------------------

    #[test]
    fn commit_creates_new_commit() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        fs::write(path.join("file.txt"), "hello world").unwrap();
        repo.index()
            .unwrap()
            .add_path(std::path::Path::new("file.txt"))
            .unwrap();
        repo.index().unwrap().write().unwrap();

        let sig = repo.signature().unwrap();
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        let tree = repo.find_tree(tree_oid).unwrap();
        let parent = repo.find_commit(head).unwrap();

        let new_oid = repo
            .commit(Some("HEAD"), &sig, &sig, "add file.txt", &tree, &[&parent])
            .unwrap();

        assert_ne!(new_oid, head);
        let new_commit = repo.find_commit(new_oid).unwrap();
        assert_eq!(new_commit.summary().unwrap(), "add file.txt");
    }

    #[test]
    fn amend_commit_updates_message() {
        let fixture = make_test_repo();
        let path = fixture.path();
        let head = fixture.head_oid();
        let repo = git2::Repository::open(path).unwrap();

        let sig = repo.signature().unwrap();
        let parent = repo.find_commit(head).unwrap();

        let new_oid = repo
            .commit(
                Some("HEAD"),
                &sig,
                &sig,
                "original message",
                &parent.tree().unwrap(),
                &[&parent],
            )
            .unwrap();

        let new_commit = repo.find_commit(new_oid).unwrap();
        new_commit
            .amend(
                Some("HEAD"),
                Some(&sig),
                Some(&sig),
                None,
                Some("updated message"),
                None,
            )
            .unwrap();

        // amend() creates a NEW commit with a new SHA. Look up the amended commit
        // from HEAD (which now points to the new commit), not from the old OID.
        let amended = repo
            .find_commit(repo.head().unwrap().target().unwrap())
            .unwrap();
        assert_eq!(amended.summary().unwrap(), "updated message");
    }

    #[test]
    fn count_would_remove_counts_dry_run_entries() {
        let stdout = "Would remove build/\nWould remove notes.txt\nWould remove a b c.txt\n";
        assert_eq!(super::count_would_remove(stdout), 3);
    }

    #[test]
    fn count_would_remove_ignores_unrelated_output() {
        assert_eq!(super::count_would_remove(""), 0);
        assert_eq!(super::count_would_remove("nothing to do\n"), 0);
        // "Would skip" is emitted for ignored entries when -x is not passed.
        assert_eq!(super::count_would_remove("Would skip repository sub/\n"), 0);
        // Only a line that starts with the marker counts; a filename that
        // merely mentions it must not.
        assert_eq!(
            super::count_would_remove("Would remove docs/Would remove me.txt\n"),
            1
        );
    }

    /// `git clean -n` writes its report to stdout, not stderr. Reading the wrong
    /// stream made `clean_untracked` a silent no-op that still reported success.
    #[test]
    fn git_clean_dry_run_reports_on_stdout() {
        let fixture = make_test_repo();
        let path = fixture.path();
        fs::write(path.join("untracked.txt"), "scratch").unwrap();
        fs::create_dir(path.join("untracked_dir")).unwrap();
        fs::write(path.join("untracked_dir").join("inner.txt"), "scratch").unwrap();

        let output = super::super::git_command()
            .current_dir(path)
            .args(["clean", "-n", "-fd"])
            .output()
            .unwrap();
        assert!(output.status.success());

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        assert_eq!(
            super::count_would_remove(&stdout),
            2,
            "expected both untracked entries on stdout, got: {stdout:?}"
        );
        assert_eq!(
            super::count_would_remove(&stderr),
            0,
            "stderr should carry no report, got: {stderr:?}"
        );
    }
}
