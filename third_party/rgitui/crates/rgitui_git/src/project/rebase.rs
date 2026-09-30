use anyhow::{Context as _, Result};
use git2::Repository;
use gpui::{AsyncApp, Context, Task, WeakEntity};

use crate::types::*;

use super::argsafe::sh_quote;
use super::ensure_clean_worktree;
use super::refresh::gather_refresh_data;
use super::{GitProject, GitProjectEvent, RefreshData};

impl GitProject {
    /// Perform an interactive rebase using a prepared plan.
    ///
    /// Writes the desired todo list to a temp file and invokes `git rebase -i`
    /// with `GIT_SEQUENCE_EDITOR` set to a command that replaces the editor file
    /// with the prepared plan. For reword actions, the new message is written to
    /// its own file and applied with `exec git commit --amend --file`, keeping
    /// the message off the shell-interpreted `exec` line.
    pub fn rebase_interactive(
        &mut self,
        entries: Vec<RebasePlanEntry>,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let entry_count = entries.len();
        let operation_id = self.begin_operation(
            GitOperationKind::Rebase,
            format!("Rebasing {} commits...", entry_count),
            None,
            branch_name.clone(),
            cx,
        );

        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<(String, RefreshData)> = cx
                .background_executor()
                .spawn(async move {
                    if entries.is_empty() {
                        anyhow::bail!("No entries provided for interactive rebase");
                    }

                    let base_oid = {
                        let repo = Repository::open(&repo_path)?;
                        ensure_clean_worktree(&repo, "Interactive rebase")?;

                        // The plan must cover exactly HEAD's contiguous first-parent
                        // range `base..HEAD`. Derive that range from HEAD itself
                        // (NOT from the date-ordered `--all` commit list the plan was
                        // built from) and verify the plan's commit set matches it, so
                        // a stale or cross-branch plan can't drop, duplicate, or
                        // replay commits from an unrelated branch and corrupt history.
                        // Reordering within the range is allowed (only the set and the
                        // base are validated).
                        let head_commit = repo.head()?.peel_to_commit()?;
                        let mut range: Vec<git2::Oid> = Vec::with_capacity(entries.len());
                        let mut walk = head_commit;
                        for _ in 0..entries.len() {
                            range.push(walk.id());
                            walk = walk
                                .parent(0)
                                .context("rebase range extends past the root commit")?;
                        }
                        // `walk` is now the first parent of the oldest in-range commit.
                        let base = walk.id();

                        let plan_set: std::collections::HashSet<git2::Oid> = entries
                            .iter()
                            .map(|e| git2::Oid::from_str(&e.oid))
                            .collect::<std::result::Result<_, _>>()?;
                        let range_set: std::collections::HashSet<git2::Oid> =
                            range.iter().copied().collect();
                        if plan_set != range_set {
                            anyhow::bail!(
                                "Interactive rebase plan does not match the current branch's \
                                 history (the selected commits are not exactly the last {} \
                                 first-parent commits of HEAD). Refresh and try again.",
                                entries.len()
                            );
                        }

                        base.to_string()
                    };

                    // Holds the todo list and any reword message files. Dropped
                    // once `git rebase` has exited.
                    let scratch = tempfile::Builder::new()
                        .prefix("rgitui-rebase-")
                        .tempdir()
                        .context("Failed to create a temporary directory for the rebase plan")?;

                    let mut todo_lines = Vec::new();
                    for (index, entry) in entries.iter().rev().enumerate() {
                        let short_oid = if entry.oid.len() >= 7 {
                            &entry.oid[..7]
                        } else {
                            &entry.oid
                        };

                        match &entry.action {
                            RebaseEntryAction::Pick => {
                                todo_lines.push(format!("pick {} {}", short_oid, entry.message));
                            }
                            RebaseEntryAction::Reword(new_msg) => {
                                todo_lines.push(format!("pick {} {}", short_oid, entry.message));
                                // Git runs `exec` lines through the shell, so the
                                // message must never appear on the command line.
                                // Write it to a file and let git read it verbatim.
                                let msg_path = scratch.path().join(format!("reword-{index}.msg"));
                                std::fs::write(&msg_path, new_msg.as_bytes()).with_context(
                                    || format!("Failed to write reword message for {short_oid}"),
                                )?;
                                todo_lines.push(format!(
                                    "exec git commit --amend --file {}",
                                    sh_quote(&msg_path.to_string_lossy())
                                ));
                            }
                            RebaseEntryAction::Squash => {
                                todo_lines.push(format!("squash {} {}", short_oid, entry.message));
                            }
                            RebaseEntryAction::Fixup => {
                                todo_lines.push(format!("fixup {} {}", short_oid, entry.message));
                            }
                            RebaseEntryAction::Drop => {
                                todo_lines.push(format!("drop {} {}", short_oid, entry.message));
                            }
                        }
                    }

                    let todo_content = todo_lines.join("\n") + "\n";

                    let todo_file = scratch.path().join("git-rebase-todo");
                    std::fs::write(&todo_file, &todo_content)
                        .context("Failed to write the rebase plan")?;

                    let sequence_editor = if cfg!(windows) {
                        format!(
                            "cmd /c copy /y \"{}\" ",
                            todo_file.to_string_lossy().replace('/', "\\")
                        )
                    } else {
                        format!("cp {} ", sh_quote(&todo_file.to_string_lossy()))
                    };

                    let mut cmd = super::git_command();
                    cmd.current_dir(&repo_path)
                        .env("GIT_SEQUENCE_EDITOR", &sequence_editor)
                        .env("GIT_EDITOR", "true")
                        .args(["rebase", "-i", &base_oid]);
                    let output = cmd
                        .output()
                        .with_context(|| "Failed to execute git rebase -i")?;

                    // A rebase that stopped on a conflict is still in progress,
                    // and its todo list still holds `exec ... --file <path>`
                    // lines pointing into the scratch directory. Deleting it now
                    // would make `git rebase --continue` fail to read the reword
                    // message. Keep the directory in that case and let the OS
                    // temp sweep reclaim it; otherwise git is done with it.
                    let rebase_still_in_progress = !output.status.success()
                        && Repository::open(&repo_path)
                            .map(|repo| {
                                matches!(
                                    repo.state(),
                                    git2::RepositoryState::Rebase
                                        | git2::RepositoryState::RebaseInteractive
                                        | git2::RepositoryState::RebaseMerge
                                )
                            })
                            .unwrap_or(false);
                    if rebase_still_in_progress {
                        let _ = scratch.keep();
                    } else {
                        drop(scratch);
                    }

                    let stdout = String::from_utf8_lossy(&output.stdout);
                    let stderr = String::from_utf8_lossy(&output.stderr);

                    if output.status.success() {
                        let data = gather_refresh_data(&repo_path, commit_limit)?;
                        Ok((
                            format!("Rebased {} commits successfully", entry_count),
                            data,
                        ))
                    } else if stderr.contains("CONFLICT") || stderr.contains("could not apply") {
                        let data = gather_refresh_data(&repo_path, commit_limit)?;
                        let detail: String = stderr.lines().take(3).collect::<Vec<_>>().join(" ");
                        Ok((
                            format!(
                                "CONFLICT:Rebase paused due to conflicts. \
                                 Resolve conflicts and use Continue or Abort. {}",
                                detail
                            ),
                            data,
                        ))
                    } else {
                        anyhow::bail!(
                            "git rebase -i failed:\nstdout: {}\nstderr: {}",
                            stdout.trim(),
                            stderr.trim()
                        );
                    }
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
                                    GitOperationKind::Rebase,
                                    "Rebase paused due to conflicts",
                                    user_msg,
                                    (None, branch_name.clone(), false),
                                    cx,
                                );
                            } else {
                                this.complete_op(
                                    operation_id,
                                    GitOperationKind::Rebase,
                                    msg,
                                    (
                                        Some("Repository state refreshed after rebase.".into()),
                                        None,
                                        branch_name.clone(),
                                    ),
                                    cx,
                                );
                            }
                            cx.emit(GitProjectEvent::RepositoryChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Rebase,
                                "Interactive rebase failed",
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
