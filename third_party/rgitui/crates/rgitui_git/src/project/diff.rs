use anyhow::Result;
use git2::{DiffOptions, IndexEntry, MergeFileOptions, Repository};
use std::path::{Path, PathBuf};

use crate::types::*;

use super::refresh::gather_refresh_data_lightweight_cached;
use super::RefreshData;

/// Compute line-level diff stats (additions/deletions) for a single file.
/// For staged files, diffs HEAD vs index. For unstaged files, diffs index vs workdir.
pub(crate) fn batch_diff_stats(
    repo: &Repository,
    staged: bool,
) -> std::collections::HashMap<PathBuf, (usize, usize)> {
    let batch_timer = std::time::Instant::now();
    log::debug!("batch_diff_stats: staged={}", staged);
    let mut opts = DiffOptions::new();
    opts.include_untracked(true);
    opts.show_untracked_content(true);
    opts.recurse_untracked_dirs(true);
    let diff_result = if staged {
        let head_tree = repo.head().ok().and_then(|r| r.peel_to_tree().ok());
        repo.diff_tree_to_index(head_tree.as_ref(), None, Some(&mut opts))
    } else {
        repo.diff_index_to_workdir(None, Some(&mut opts))
    };
    let mut stats_map = std::collections::HashMap::new();
    if let Ok(diff) = diff_result {
        let num_deltas = diff.deltas().len();
        for i in 0..num_deltas {
            if let Ok(Some(patch)) = git2::Patch::from_diff(&diff, i) {
                let (_, adds, dels) = patch.line_stats().unwrap_or((0, 0, 0));
                if let Some(path) = patch.delta().new_file().path() {
                    stats_map.insert(path.to_path_buf(), (adds, dels));
                }
            }
        }
    }
    log::debug!(
        "batch_diff_stats complete in {:?}: {} file stats, staged={}",
        batch_timer.elapsed(),
        stats_map.len(),
        staged
    );
    stats_map
}

pub(crate) fn generate_hunk_patch_for_repo(
    repo: &Repository,
    file_path: &Path,
    hunk_index: usize,
    staged: bool,
) -> Result<String> {
    let mut diff_opts = DiffOptions::new();
    diff_opts.pathspec(file_path);
    // Without this libgit2 fnmatches the pathspec, so a file literally named
    // `data[1].json` would not match itself and could match a different file.
    diff_opts.disable_pathspec_match(true);
    diff_opts.include_untracked(true);
    diff_opts.show_untracked_content(true);
    diff_opts.recurse_untracked_dirs(true);

    let diff = if staged {
        let head_tree = repo.head()?.peel_to_tree().ok();
        repo.diff_tree_to_index(head_tree.as_ref(), None, Some(&mut diff_opts))?
    } else {
        repo.diff_index_to_workdir(None, Some(&mut diff_opts))?
    };

    let mut patch_text = String::new();
    let mut current_hunk_idx: i32 = -1;
    let mut file_header_written = false;

    diff.print(git2::DiffFormat::Patch, |delta, hunk, line| {
        let Some(hunk) = hunk else {
            if !file_header_written {
                let content = String::from_utf8_lossy(line.content());
                match line.origin() {
                    'F' => patch_text.push_str(&content),
                    _ => {
                        let prefix = match line.origin() {
                            '+' | '-' | ' ' | '>' | '<' => String::from(line.origin()),
                            _ => String::new(),
                        };
                        patch_text.push_str(&prefix);
                        patch_text.push_str(&content);
                    }
                }
            }
            return true;
        };

        // Each hunk emits exactly one hunk-header line (origin 'H') before its
        // content lines, so advancing the counter on 'H' tracks hunk boundaries
        // structurally — no substring scan of the accumulating patch text.
        if line.origin() == 'H' {
            current_hunk_idx += 1;
        }

        if current_hunk_idx as usize == hunk_index {
            if !file_header_written {
                let old_path = delta.old_file().path().unwrap_or(Path::new(""));
                let new_path = delta.new_file().path().unwrap_or(Path::new(""));
                patch_text.clear();
                patch_text.push_str(&format!(
                    "diff --git a/{} b/{}\n",
                    old_path.display(),
                    new_path.display()
                ));
                patch_text.push_str(&format!("--- a/{}\n", old_path.display()));
                patch_text.push_str(&format!("+++ b/{}\n", new_path.display()));
                file_header_written = true;
            }

            let content = String::from_utf8_lossy(line.content());
            match line.origin() {
                'H' => {
                    let (old_start, old_lines, new_start, new_lines) = if staged {
                        (
                            hunk.new_start(),
                            hunk.new_lines(),
                            hunk.old_start(),
                            hunk.old_lines(),
                        )
                    } else {
                        (
                            hunk.old_start(),
                            hunk.old_lines(),
                            hunk.new_start(),
                            hunk.new_lines(),
                        )
                    };
                    patch_text.push_str(&format!(
                        "@@ -{},{} +{},{} @@\n",
                        old_start, old_lines, new_start, new_lines
                    ));
                }
                '+' | '-' | ' ' => {
                    if let Some(sign) = emitted_sign(line.origin(), staged) {
                        patch_text.push(sign);
                    }
                    patch_text.push_str(&content);
                }
                // EOFNL markers ('=' context, '>' added, '<' deleted) carry the
                // "\ No newline at end of file" text in their content; emit it
                // verbatim with no sign prefix, matching git's own patch output.
                '=' | '>' | '<' => patch_text.push_str(&content),
                _ => {}
            }
        }

        true
    })?;

    if patch_text.is_empty() {
        anyhow::bail!("Could not generate patch for hunk {}", hunk_index);
    }

    if !patch_text.ends_with('\n') {
        patch_text.push('\n');
    }

    Ok(patch_text)
}

/// Map a diff line's origin to the sign it should carry in the generated patch.
///
/// Staging (`staged == false`, an index→workdir diff applied to the index) preserves
/// signs: a `+` workdir addition must stay `+` to add the line to the index.
/// Unstaging (`staged == true`, a HEAD→index diff applied to the index) negates them:
/// a `+` index addition becomes `-` so applying the patch removes it from the index.
/// Context lines keep their space; non-content origins return `None`.
fn emitted_sign(origin: char, staged: bool) -> Option<char> {
    match origin {
        ' ' => Some(' '),
        '+' => Some(if staged { '-' } else { '+' }),
        '-' => Some(if staged { '+' } else { '-' }),
        _ => None,
    }
}

/// Generate a patch containing only the specified line ranges from a file's diff.
///
/// `line_pairs` is `&[(Option<usize>, Option<usize>)]` — `(old_lineno, new_lineno)`
/// from the diff viewer, matching the line numbering of the underlying git2 diff.
/// The viewer emits an addition as `(None, Some(n))` and a deletion as `(Some(n), None)`.
///
/// `staged`:
/// - `false` → diff is index→workdir; the patch stages the selected lines into the
///   index, so signs are preserved (a `+` workdir addition stays `+`).
/// - `true` → diff is HEAD→index; the patch unstages the selected lines from the
///   index, so signs are negated (a `+` index addition becomes `-` to remove it).
///
/// Additions are matched by their `new_lineno` against the new-side targets, and
/// deletions by their `old_lineno` against the old-side targets. The two sides are
/// kept separate so an addition and a deletion that happen to share a line number
/// are not confused for one another.
pub(crate) fn generate_line_patch_for_repo(
    repo: &Repository,
    file_path: &Path,
    line_pairs: &[(Option<usize>, Option<usize>)],
    staged: bool,
) -> Result<String> {
    let mut diff_opts = DiffOptions::new();
    diff_opts.pathspec(file_path);
    // Without this libgit2 fnmatches the pathspec, so a file literally named
    // `data[1].json` would not match itself and could match a different file.
    diff_opts.disable_pathspec_match(true);
    diff_opts.include_untracked(true);
    diff_opts.show_untracked_content(true);
    diff_opts.recurse_untracked_dirs(true);

    let diff = if staged {
        let head_tree = repo.head()?.peel_to_tree().ok();
        repo.diff_tree_to_index(head_tree.as_ref(), None, Some(&mut diff_opts))?
    } else {
        repo.diff_index_to_workdir(None, Some(&mut diff_opts))?
    };

    // Separate target sets per side. Additions carry their position in `new_lineno`,
    // deletions in `old_lineno`, in both the HEAD→index and index→workdir diffs.
    let new_targets: std::collections::HashSet<usize> =
        line_pairs.iter().filter_map(|(_, new)| *new).collect();
    let old_targets: std::collections::HashSet<usize> =
        line_pairs.iter().filter_map(|(old, _)| *old).collect();

    let mut patch_text = String::new();
    let num_deltas = diff.deltas().len();

    for i in 0..num_deltas {
        let patch = match git2::Patch::from_diff(&diff, i) {
            Ok(Some(p)) => p,
            Ok(None) => continue,
            Err(_) => continue,
        };

        let old_path = patch
            .delta()
            .old_file()
            .path()
            .map(PathBuf::from)
            .unwrap_or_default();
        let new_path = patch
            .delta()
            .new_file()
            .path()
            .map(PathBuf::from)
            .unwrap_or_default();

        // Skip patches for other files (pathspec should filter, but be safe).
        if old_path != file_path && new_path != file_path {
            continue;
        }

        let num_hunks = patch.num_hunks();
        for hunk_idx in 0..num_hunks {
            let (hunk, _hunk_start) = patch.hunk(hunk_idx)?;
            let num_lines = patch.num_lines_in_hunk(hunk_idx)?;

            // Collect indices of lines within this hunk that match our targets.
            // Additions match on new_lineno, deletions on old_lineno; context and
            // EOFNL markers are always carried so the partial hunk stays coherent.
            let mut matching_line_indices: Vec<usize> = Vec::new();
            let mut has_change = false;
            for line_idx in 0..num_lines {
                let line = patch.line_in_hunk(hunk_idx, line_idx)?;
                let origin = line.origin();

                let is_target = match origin {
                    '+' => line
                        .new_lineno()
                        .is_some_and(|n| new_targets.contains(&(n as usize))),
                    '-' => line
                        .old_lineno()
                        .is_some_and(|n| old_targets.contains(&(n as usize))),
                    _ => false,
                };

                // Context lines and the "no newline at end of file" markers
                // ('=' context, '>' added, '<' deleted) are carried unconditionally.
                let is_context = matches!(origin, ' ' | '=' | '<' | '>');

                if is_target || is_context {
                    matching_line_indices.push(line_idx);
                    has_change |= matches!(origin, '+' | '-');
                }
            }

            // A hunk made up of only context/marker lines contributes nothing — skip
            // it so we never emit an empty change.
            if !has_change {
                continue;
            }

            // Count emitted pre-/post-image lines and derive the start positions.
            //
            // Counts reflect the *emitted* signs: when unstaging we negate, so an
            // addition becomes a deletion (pre-image side) and vice versa. EOFNL
            // markers annotate the preceding line and do not count toward either side.
            //
            // The output patch is applied to the index in both directions, but the
            // diff's own old/new line numbers describe different sides per direction:
            //   - staging   (index→workdir): pre-image = index   → old_lineno
            //                                 post-image = workdir → new_lineno
            //   - unstaging (HEAD→index):     pre-image = index   → new_lineno
            //                                 post-image = HEAD    → old_lineno
            // so the line number that anchors each side is selected accordingly.
            let mut old_count: u32 = 0;
            let mut new_count: u32 = 0;
            let mut old_start: Option<u32> = None;
            let mut new_start: Option<u32> = None;

            for &line_idx in &matching_line_indices {
                let line = patch.line_in_hunk(hunk_idx, line_idx)?;
                let (preimage, postimage) = if staged {
                    (line.new_lineno(), line.old_lineno())
                } else {
                    (line.old_lineno(), line.new_lineno())
                };
                match emitted_sign(line.origin(), staged) {
                    Some(' ') => {
                        old_count += 1;
                        new_count += 1;
                        old_start = old_start.or(preimage);
                        new_start = new_start.or(postimage);
                    }
                    Some('-') => {
                        old_count += 1;
                        old_start = old_start.or(preimage);
                    }
                    Some('+') => {
                        new_count += 1;
                        new_start = new_start.or(postimage);
                    }
                    _ => {}
                }
            }

            // Fall back to the hunk's own boundaries when one side is empty (e.g. a
            // pure-addition selection has no pre-image line to anchor old_start).
            let (hunk_old_start, hunk_new_start) = if staged {
                (
                    old_start.unwrap_or_else(|| hunk.new_start()),
                    new_start.unwrap_or_else(|| hunk.old_start()),
                )
            } else {
                (
                    old_start.unwrap_or_else(|| hunk.old_start()),
                    new_start.unwrap_or_else(|| hunk.new_start()),
                )
            };

            // Write file header (if first hunk for this file). The `diff --git`
            // line is required for libgit2's `Diff::from_buffer` to recognize the
            // file header; without it the first `@@` is rejected as a hunk header
            // "outside patch".
            if patch_text.is_empty() {
                patch_text.push_str(&format!(
                    "diff --git a/{} b/{}\n",
                    old_path.display(),
                    new_path.display()
                ));
                patch_text.push_str(&format!("--- a/{}\n", old_path.display()));
                patch_text.push_str(&format!("+++ b/{}\n", new_path.display()));
            }

            // Write hunk header with counts derived from the emitted lines.
            patch_text.push_str(&format!(
                "@@ -{},{} +{},{} @@\n",
                hunk_old_start, old_count, hunk_new_start, new_count
            ));

            // Write the matching lines, applying the sign transform per direction.
            for &line_idx in &matching_line_indices {
                let line = patch.line_in_hunk(hunk_idx, line_idx)?;
                let content = String::from_utf8_lossy(line.content());
                match line.origin() {
                    '+' | '-' | ' ' => {
                        if let Some(sign) = emitted_sign(line.origin(), staged) {
                            patch_text.push(sign);
                        }
                        patch_text.push_str(&content);
                    }
                    // EOFNL markers carry the "\ No newline at end of file" text in
                    // their content; emit it verbatim with no sign prefix.
                    '=' | '>' | '<' => patch_text.push_str(&content),
                    _ => {}
                }
            }
        }
    }

    if patch_text.is_empty() {
        anyhow::bail!("Could not generate patch for selected lines");
    }

    if !patch_text.ends_with('\n') {
        patch_text.push('\n');
    }

    Ok(patch_text)
}

/// Parse a git2::Diff into a CommitDiff using structured Patch iteration.
/// Cross-commit parallelism is handled by the caller; this function processes
/// a single diff sequentially to avoid serialize/re-parse overhead.
pub(crate) fn parse_multi_file_diff(diff: &git2::Diff) -> Result<CommitDiff> {
    let num_patches = diff.deltas().len();
    let mut files = Vec::with_capacity(num_patches);
    for i in 0..num_patches {
        if let Some(mut patch) = git2::Patch::from_diff(diff, i)? {
            files.push(parse_single_patch(&mut patch)?);
        }
    }

    let total_additions = files.iter().map(|f| f.additions).sum();
    let total_deletions = files.iter().map(|f| f.deletions).sum();

    Ok(CommitDiff {
        total_additions,
        total_deletions,
        files,
    })
}

/// Parse a single git2::Patch into a FileDiff.
/// Uses the patch's print callback to extract hunk/line content.
fn parse_single_patch(patch: &mut git2::Patch) -> Result<FileDiff> {
    let path = patch
        .delta()
        .new_file()
        .path()
        .unwrap_or(Path::new(""))
        .to_path_buf();
    let kind = delta_to_file_change_kind(patch.delta().status());
    let (_, additions, deletions) = patch.line_stats().unwrap_or((0, 0, 0));

    let mut hunks: Vec<DiffHunk> = Vec::new();
    let mut current_hunk: Option<DiffHunk> = None;

    // Use the patch's embedded print callback to extract hunk/line content.
    // patch.print() processes THIS PATCH ONLY (not the full diff), giving us
    // per-file isolation without needing a separate diff per file.
    patch.print(&mut |_delta, hunk_range, line| {
        if let Some(hunk) = hunk_range {
            let header = String::from_utf8_lossy(hunk.header()).to_string();
            let needs_new = current_hunk
                .as_ref()
                .is_none_or(|h| h.new_start != hunk.new_start() || h.header != header);
            if needs_new {
                if let Some(prev) = current_hunk.take() {
                    hunks.push(prev);
                }
                current_hunk = Some(DiffHunk {
                    old_start: hunk.old_start(),
                    old_lines: hunk.old_lines(),
                    new_start: hunk.new_start(),
                    new_lines: hunk.new_lines(),
                    header,
                    lines: Vec::new(),
                });
            }
        }

        if let Some(ref mut hunk) = current_hunk {
            // delta is the same for all lines in a patch-level print
            let content = String::from_utf8_lossy(line.content()).to_string();
            match line.origin() {
                '+' => hunk.lines.push(DiffLine::Addition(content)),
                '-' => hunk.lines.push(DiffLine::Deletion(content)),
                ' ' => hunk.lines.push(DiffLine::Context(content)),
                _ => {}
            }
        }

        true
    })?;

    if let Some(hunk) = current_hunk {
        hunks.push(hunk);
    }

    Ok(FileDiff {
        path,
        hunks,
        additions,
        deletions,
        kind,
    })
}

pub(crate) fn delta_to_file_change_kind(delta: git2::Delta) -> FileChangeKind {
    match delta {
        git2::Delta::Added | git2::Delta::Untracked => FileChangeKind::Added,
        git2::Delta::Deleted => FileChangeKind::Deleted,
        git2::Delta::Modified | git2::Delta::Typechange => FileChangeKind::Modified,
        git2::Delta::Renamed => FileChangeKind::Renamed,
        git2::Delta::Copied => FileChangeKind::Modified,
        _ => FileChangeKind::Modified,
    }
}

/// Parse a git2::Diff into a FileDiff using the print API to avoid borrow issues.
pub(crate) fn parse_file_diff(path: &Path, diff: &git2::Diff) -> Result<FileDiff> {
    let mut file_diff = FileDiff {
        path: path.to_path_buf(),
        hunks: Vec::new(),
        additions: 0,
        deletions: 0,
        kind: FileChangeKind::Modified,
    };

    diff.print(git2::DiffFormat::Patch, |delta, hunk, line| {
        file_diff.kind = delta_to_file_change_kind(delta.status());
        if let Some(hunk) = hunk {
            let header = String::from_utf8_lossy(hunk.header()).to_string();
            let expected_start = hunk.new_start();
            let needs_new = file_diff
                .hunks
                .last()
                .is_none_or(|h| h.new_start != expected_start || h.header != header);
            if needs_new {
                file_diff.hunks.push(DiffHunk {
                    old_start: hunk.old_start(),
                    old_lines: hunk.old_lines(),
                    new_start: hunk.new_start(),
                    new_lines: hunk.new_lines(),
                    header,
                    lines: Vec::new(),
                });
            }
        }

        let content = String::from_utf8_lossy(line.content()).to_string();
        match line.origin() {
            '+' => {
                if let Some(h) = file_diff.hunks.last_mut() {
                    h.lines.push(DiffLine::Addition(content));
                }
                file_diff.additions += 1;
            }
            '-' => {
                if let Some(h) = file_diff.hunks.last_mut() {
                    h.lines.push(DiffLine::Deletion(content));
                }
                file_diff.deletions += 1;
            }
            ' ' => {
                if let Some(h) = file_diff.hunks.last_mut() {
                    h.lines.push(DiffLine::Context(content));
                }
            }
            _ => {}
        }

        true
    })?;

    Ok(file_diff)
}

pub fn compute_file_diff(repo_path: &Path, file_path: &Path, staged: bool) -> Result<FileDiff> {
    let repo = Repository::open(repo_path)?;
    let mut diff_opts = DiffOptions::new();
    diff_opts.pathspec(file_path);
    // Without this libgit2 fnmatches the pathspec, so a file literally named
    // `data[1].json` would not match itself and could match a different file.
    diff_opts.disable_pathspec_match(true);
    diff_opts.include_untracked(true);
    diff_opts.show_untracked_content(true);
    diff_opts.recurse_untracked_dirs(true);
    let diff = if staged {
        let head_tree = repo.head()?.peel_to_tree().ok();
        repo.diff_tree_to_index(head_tree.as_ref(), None, Some(&mut diff_opts))?
    } else {
        repo.diff_index_to_workdir(None, Some(&mut diff_opts))?
    };
    parse_file_diff(file_path, &diff)
}

pub fn compute_commit_diff(repo_path: &Path, oid: git2::Oid) -> Result<CommitDiff> {
    let diff_timer = std::time::Instant::now();
    log::debug!(
        "compute_commit_diff: oid={} repo={}",
        oid,
        repo_path.display()
    );
    let repo = Repository::open(repo_path)?;
    let commit = repo.find_commit(oid)?;
    let tree = commit.tree()?;
    let parent_tree = if commit.parent_count() > 0 {
        Some(commit.parent(0)?.tree()?)
    } else {
        None
    };
    let diff = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), None)?;
    let result = parse_multi_file_diff(&diff);
    if let Ok(ref d) = result {
        log::debug!(
            "compute_commit_diff complete in {:?}: {} files",
            diff_timer.elapsed(),
            d.files.len()
        );
    }
    result
}

pub fn compute_stash_diff(repo_path: &Path, index: usize) -> Result<CommitDiff> {
    let mut repo = Repository::open(repo_path)?;
    let mut stash_oid: Option<git2::Oid> = None;
    repo.stash_foreach(|idx, _msg, oid| {
        if idx == index {
            stash_oid = Some(*oid);
            false // stop early — found the target stash
        } else {
            true
        }
    })?;
    let stash_oid =
        stash_oid.ok_or_else(|| anyhow::anyhow!("Stash index {} out of range", index))?;
    compute_commit_diff(repo_path, stash_oid)
}

pub fn compute_staged_diff_text(repo_path: &Path) -> Result<String> {
    let repo = Repository::open(repo_path)?;
    let head_tree = repo.head()?.peel_to_tree().ok();
    let diff = repo.diff_tree_to_index(head_tree.as_ref(), None, None)?;
    let mut text = String::new();
    diff.print(git2::DiffFormat::Patch, |_delta, _hunk, line| {
        // Lossy rather than skip-on-error: a Latin-1 or Shift-JIS source file
        // used to have its lines vanish from the diff with no marker, leaving
        // the AI to reason about an incomplete change set and write a
        // confidently wrong message. A mangled line is far better than a
        // missing one. (Binary content is unaffected — libgit2 defaults to
        // `show_binary = false` and renders "Binary files ... differ".)
        text.push(line.origin());
        text.push_str(&String::from_utf8_lossy(line.content()));
        true
    })?;
    Ok(text)
}

use gpui::{AsyncApp, Context, Task, WeakEntity};

use super::GitProject;
use super::GitProjectEvent;

impl GitProject {
    /// Get diff for a specific file (staged or unstaged).
    pub fn diff_file(&self, path: &Path, staged: bool) -> Result<FileDiff> {
        let repo = self.open_repo()?;
        let mut diff_opts = DiffOptions::new();
        diff_opts.pathspec(path);
        // Without this libgit2 fnmatches the pathspec, so a file literally named
        // `data[1].json` would not match itself and could match a different file.
        diff_opts.disable_pathspec_match(true);
        diff_opts.include_untracked(true);
        diff_opts.show_untracked_content(true);
        diff_opts.recurse_untracked_dirs(true);

        let diff = if staged {
            let head_tree = repo.head()?.peel_to_tree().ok();
            repo.diff_tree_to_index(head_tree.as_ref(), None, Some(&mut diff_opts))?
        } else {
            repo.diff_index_to_workdir(None, Some(&mut diff_opts))?
        };

        parse_file_diff(path, &diff)
    }

    /// Get diff for a specific commit.
    pub fn diff_commit(&self, oid: git2::Oid) -> Result<CommitDiff> {
        let repo = self.open_repo()?;
        let commit = repo.find_commit(oid)?;
        let tree = commit.tree()?;

        let parent_tree = if commit.parent_count() > 0 {
            Some(commit.parent(0)?.tree()?)
        } else {
            None
        };

        let diff = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), None)?;
        parse_multi_file_diff(&diff)
    }

    /// Get the diff for a stash entry at the given index.
    pub fn diff_stash(&self, index: usize) -> Result<CommitDiff> {
        let mut repo = self.open_repo()?;

        let mut stash_oids: Vec<git2::Oid> = Vec::new();
        repo.stash_foreach(|_idx, _msg, oid| {
            stash_oids.push(*oid);
            true
        })?;

        let oid = *stash_oids
            .get(index)
            .ok_or_else(|| anyhow::anyhow!("Stash index {} out of range", index))?;

        let commit = repo.find_commit(oid)?;
        let tree = commit.tree()?;

        let parent_tree = if commit.parent_count() > 0 {
            Some(commit.parent(0)?.tree()?)
        } else {
            None
        };

        let diff = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), None)?;
        parse_multi_file_diff(&diff)
    }

    /// Stage a specific hunk in the given worktree.
    pub fn stage_hunk_at(
        &mut self,
        file_path: &Path,
        hunk_index: usize,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let file_path = file_path.to_path_buf();
        let task_file_path = file_path.clone();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Stage,
            format!(
                "Staging hunk {} in {}...",
                hunk_index + 1,
                file_path.display()
            ),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let patch_text =
                        generate_hunk_patch_for_repo(&repo, &task_file_path, hunk_index, false)?;
                    let diff = git2::Diff::from_buffer(patch_text.as_bytes())?;
                    repo.apply(&diff, git2::ApplyLocation::Index, None)?;
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
                                format!(
                                    "Staged hunk {} in {}",
                                    hunk_index + 1,
                                    file_path.display()
                                ),
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stage,
                                "Stage hunk failed",
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

    /// Unstage a specific hunk from a staged file diff in the given worktree.
    pub fn unstage_hunk_at(
        &mut self,
        file_path: &Path,
        hunk_index: usize,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let file_path = file_path.to_path_buf();
        let task_file_path = file_path.clone();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let operation_id = self.begin_operation(
            GitOperationKind::Unstage,
            format!(
                "Unstaging hunk {} in {}...",
                hunk_index + 1,
                file_path.display()
            ),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let patch_text =
                        generate_hunk_patch_for_repo(&repo, &task_file_path, hunk_index, true)?;
                    let diff = git2::Diff::from_buffer(patch_text.as_bytes())?;
                    let mut opts = git2::ApplyOptions::new();
                    repo.apply(&diff, git2::ApplyLocation::Index, Some(&mut opts))?;
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
                                format!(
                                    "Unstaged hunk {} in {}",
                                    hunk_index + 1,
                                    file_path.display()
                                ),
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Unstage,
                                "Unstage hunk failed",
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

    /// Stage specific lines within a file's diff in the given worktree.
    pub fn stage_lines_at(
        &mut self,
        file_path: &Path,
        line_pairs: &[(Option<usize>, Option<usize>)],
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let file_path = file_path.to_path_buf();
        let task_file_path = file_path.clone();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let line_count = line_pairs.len();
        let line_pairs_owned = line_pairs.to_vec();
        let operation_id = self.begin_operation(
            GitOperationKind::Stage,
            format!(
                "Staging {} line{} in {}...",
                line_count,
                if line_count == 1 { "" } else { "s" },
                file_path.display()
            ),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    let patch_text = generate_line_patch_for_repo(
                        &repo,
                        &task_file_path,
                        &line_pairs_owned,
                        false, // staging from workdir to index
                    )?;
                    let diff = git2::Diff::from_buffer(patch_text.as_bytes())?;
                    repo.apply(&diff, git2::ApplyLocation::Index, None)?;
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
                                format!(
                                    "Staged {} line{} in {}",
                                    line_count,
                                    if line_count == 1 { "" } else { "s" },
                                    file_path.display()
                                ),
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Stage,
                                "Stage lines failed",
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

    /// Unstage specific lines from a staged file diff in the given worktree.
    pub fn unstage_lines_at(
        &mut self,
        file_path: &Path,
        line_pairs: &[(Option<usize>, Option<usize>)],
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let file_path = file_path.to_path_buf();
        let task_file_path = file_path.clone();
        let worktree_path = worktree_path.to_path_buf();
        let refresh_repo_path = self.repo_path.clone();
        let worktree_cache = self.worktree_status_cache.clone();
        let author_filter = self.commit_author_filter.clone();
        let commit_limit = self.commit_limit;
        let branch_name = self.head_branch.clone();
        let line_count = line_pairs.len();
        let line_pairs_owned = line_pairs.to_vec();
        let operation_id = self.begin_operation(
            GitOperationKind::Unstage,
            format!(
                "Unstaging {} line{} in {}...",
                line_count,
                if line_count == 1 { "" } else { "s" },
                file_path.display()
            ),
            None,
            branch_name.clone(),
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: anyhow::Result<RefreshData> = cx
                .background_executor()
                .spawn(async move {
                    let repo = Repository::open(&worktree_path)?;
                    // staged=true: diff is HEAD→index; we negate signs to remove from index.
                    let patch_text = generate_line_patch_for_repo(
                        &repo,
                        &task_file_path,
                        &line_pairs_owned,
                        true, // unstaging from staged (HEAD→index)
                    )?;
                    let diff = git2::Diff::from_buffer(patch_text.as_bytes())?;
                    let mut opts = git2::ApplyOptions::new();
                    repo.apply(&diff, git2::ApplyLocation::Index, Some(&mut opts))?;
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
                                format!(
                                    "Unstaged {} line{} in {}",
                                    line_count,
                                    if line_count == 1 { "" } else { "s" },
                                    file_path.display()
                                ),
                                (None, None, branch_name.clone()),
                                cx,
                            );
                            cx.emit(GitProjectEvent::StatusChanged);
                        }
                        Err(e) => {
                            this.fail_op(
                                operation_id,
                                GitOperationKind::Unstage,
                                "Unstage lines failed",
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

    /// Generate a patch for a single hunk from a file's diff.
    /// Get the staged diff as a string (for AI commit message generation).
    pub fn staged_diff_text(&self) -> Result<String> {
        let repo = self.open_repo()?;
        let head_tree = repo.head()?.peel_to_tree().ok();
        let diff = repo.diff_tree_to_index(head_tree.as_ref(), None, None)?;

        let mut output = String::new();
        diff.print(git2::DiffFormat::Patch, |_delta, _hunk, line| {
            let prefix = match line.origin() {
                '+' => "+",
                '-' => "-",
                _ => " ",
            };
            let content = String::from_utf8_lossy(line.content());
            output.push_str(prefix);
            output.push_str(&content);
            true
        })?;

        Ok(output)
    }

    /// Summary of staged changes for AI context.
    pub fn staged_summary(&self) -> String {
        Self::format_staged_summary(&self.status.staged)
    }

    /// Staged-file summary for a specific worktree, so an AI commit message
    /// describes the changes the commit will actually contain rather than
    /// whatever the main checkout happens to have staged.
    pub fn staged_summary_at(&self, worktree_path: &Path) -> String {
        match self
            .worktree_at(worktree_path)
            .and_then(|worktree| worktree.status.as_ref())
        {
            Some(status) => Self::format_staged_summary(&status.staged),
            None => self.staged_summary(),
        }
    }

    fn format_staged_summary(staged: &[FileStatus]) -> String {
        staged
            .iter()
            .map(|file| format!("{} {}", file.kind.short_code(), file.path.display()))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── delta_to_file_change_kind ──────────────────────────────────

    #[test]
    fn delta_added() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Added),
            FileChangeKind::Added
        ));
    }

    #[test]
    fn delta_untracked_maps_to_added() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Untracked),
            FileChangeKind::Added
        ));
    }

    #[test]
    fn delta_deleted() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Deleted),
            FileChangeKind::Deleted
        ));
    }

    #[test]
    fn delta_modified() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Modified),
            FileChangeKind::Modified
        ));
    }

    #[test]
    fn delta_typechange_maps_to_modified() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Typechange),
            FileChangeKind::Modified
        ));
    }

    #[test]
    fn delta_renamed() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Renamed),
            FileChangeKind::Renamed
        ));
    }

    #[test]
    fn delta_copied_maps_to_modified() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Copied),
            FileChangeKind::Modified
        ));
    }

    #[test]
    fn delta_conflicted_maps_to_modified() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Conflicted),
            FileChangeKind::Modified
        ));
    }

    #[test]
    fn delta_ignored_maps_to_modified() {
        assert!(matches!(
            delta_to_file_change_kind(git2::Delta::Ignored),
            FileChangeKind::Modified
        ));
    }
}

// ── Three-way conflict diff ───────────────────────────────────

/// Compute Git's lossless three-way merge model for a conflicted file.
pub fn compute_three_way_conflict_diff(
    repo_path: &Path,
    file_path: &Path,
) -> Result<ThreeWayFileDiff> {
    let repo = Repository::open(repo_path)?;
    let index = repo.index()?;
    let mut conflicts = index.conflicts()?;

    let path_bytes = file_path.as_os_str().as_encoded_bytes();

    let conflict_entry = loop {
        if let Some(Ok(conflict)) = conflicts.next() {
            let conflict_path_bytes: Option<&[u8]> = conflict
                .our
                .as_ref()
                .map(|e| e.path.as_slice())
                .or_else(|| conflict.their.as_ref().map(|e| e.path.as_slice()))
                .or_else(|| conflict.ancestor.as_ref().map(|e| e.path.as_slice()));

            if conflict_path_bytes.is_some_and(|pb| pb == path_bytes) {
                break conflict;
            }
        } else {
            anyhow::bail!("conflict not found for path '{}'", file_path.display());
        }
    };

    let ancestor_exists = conflict_entry.ancestor.is_some();
    let ours_exists = conflict_entry.our.is_some();
    let theirs_exists = conflict_entry.their.is_some();
    let ancestor_bytes = entry_bytes(&repo, conflict_entry.ancestor.as_ref())?;
    let ours_bytes = entry_bytes(&repo, conflict_entry.our.as_ref())?;
    let theirs_bytes = entry_bytes(&repo, conflict_entry.their.as_ref())?;

    let entries = [
        conflict_entry.ancestor.as_ref(),
        conflict_entry.our.as_ref(),
        conflict_entry.their.as_ref(),
    ];
    let is_special_file = entries
        .iter()
        .flatten()
        .any(|entry| entry.mode & 0o170000 != 0o100000);
    let is_binary = [&ancestor_bytes, &ours_bytes, &theirs_bytes]
        .into_iter()
        .any(|bytes| !is_text(bytes));

    // Delete/modify, binary and special-file conflicts need a whole-side
    // decision. Feeding a synthetic empty blob through the text merger would
    // make deletion indistinguishable from keeping an empty file.
    let (sections, result_mode) = if !is_binary && !is_special_file && ours_exists && theirs_exists
    {
        let empty_blob = (!ancestor_exists).then(|| repo.blob(&[])).transpose()?;
        let synthetic_ancestor = empty_blob.map(|oid| {
            synthetic_empty_entry(
                conflict_entry
                    .our
                    .as_ref()
                    .or(conflict_entry.their.as_ref())
                    .expect("both text sides exist"),
                oid,
            )
        });
        let ancestor_entry = conflict_entry
            .ancestor
            .as_ref()
            .or(synthetic_ancestor.as_ref())
            .expect("a real or synthetic ancestor exists");
        let markers = MergeMarkers::collision_free([
            ancestor_bytes.as_slice(),
            ours_bytes.as_slice(),
            theirs_bytes.as_slice(),
        ])?;
        let mut options = MergeFileOptions::new();
        options
            .ancestor_label(&markers.ancestor_label)
            .our_label(&markers.our_label)
            .their_label(&markers.their_label)
            .style_diff3(true)
            .patience(true)
            .marker_size(markers.size);
        let merged = repo.merge_file_from_index(
            ancestor_entry,
            conflict_entry.our.as_ref().expect("ours exists"),
            conflict_entry.their.as_ref().expect("theirs exists"),
            Some(&mut options),
        )?;
        let mut sections = parse_merge_sections(merged.content(), &markers)?;
        restore_missing_final_newline(&mut sections, &ancestor_bytes, ConflictInputSide::Ancestor);
        restore_missing_final_newline(&mut sections, &ours_bytes, ConflictInputSide::Ours);
        restore_missing_final_newline(&mut sections, &theirs_bytes, ConflictInputSide::Theirs);
        (sections, merged.mode())
    } else {
        let mode = conflict_entry
            .our
            .as_ref()
            .or(conflict_entry.their.as_ref())
            .or(conflict_entry.ancestor.as_ref())
            .map(|entry| entry.mode)
            .unwrap_or(0o100644);
        (
            vec![MergeSection::Conflict {
                ancestor: ancestor_bytes.clone(),
                ours: ours_bytes.clone(),
                theirs: theirs_bytes.clone(),
            }],
            mode,
        )
    };

    let worktree = repo
        .workdir()
        .map(|workdir| workdir.join(file_path))
        .map_or(ConflictWorktreeSnapshot::Missing, |path| {
            read_worktree_snapshot(&path)
        });

    Ok(ThreeWayFileDiff {
        path: file_path.to_path_buf(),
        sections,
        snapshot: ConflictSnapshot {
            ancestor_oid: conflict_entry.ancestor.as_ref().map(|entry| entry.id),
            ancestor_mode: conflict_entry.ancestor.as_ref().map(|entry| entry.mode),
            ours_oid: conflict_entry.our.as_ref().map(|entry| entry.id),
            ours_mode: conflict_entry.our.as_ref().map(|entry| entry.mode),
            theirs_oid: conflict_entry.their.as_ref().map(|entry| entry.id),
            theirs_mode: conflict_entry.their.as_ref().map(|entry| entry.mode),
            worktree,
        },
        ancestor_exists,
        ours_exists,
        theirs_exists,
        is_binary,
        is_special_file,
        result_mode,
    })
}

const MIN_MERGE_MARKER_SIZE: u16 = 23;

struct MergeMarkers {
    size: u16,
    ancestor_label: String,
    our_label: String,
    their_label: String,
    open: Vec<u8>,
    bare_base: Vec<u8>,
    base: Vec<u8>,
    separator: Vec<u8>,
    close: Vec<u8>,
}

impl MergeMarkers {
    fn collision_free(inputs: [&[u8]; 3]) -> Result<Self> {
        let size = (MIN_MERGE_MARKER_SIZE..=u16::MAX)
            .find(|size| {
                let bare_base = vec![b'|'; usize::from(*size)];
                let separator = vec![b'='; usize::from(*size)];
                !input_contains_line(&inputs, &bare_base)
                    && !input_contains_line(&inputs, &separator)
            })
            .ok_or_else(|| anyhow::anyhow!("Could not allocate collision-free merge markers"))?;

        for nonce in 0_u64.. {
            let suffix = if nonce == 0 {
                String::new()
            } else {
                format!("-{nonce}")
            };
            let ancestor_label = format!("rgitui-base{suffix}");
            let our_label = format!("rgitui-current{suffix}");
            let their_label = format!("rgitui-incoming{suffix}");
            let bare_base = vec![b'|'; usize::from(size)];
            let separator = vec![b'='; usize::from(size)];
            let open = labeled_merge_marker(b'<', size, &our_label);
            let base = labeled_merge_marker(b'|', size, &ancestor_label);
            let close = labeled_merge_marker(b'>', size, &their_label);
            if [&open, &base, &close]
                .into_iter()
                .all(|marker| !input_contains_line(&inputs, marker))
            {
                return Ok(Self {
                    size,
                    ancestor_label,
                    our_label,
                    their_label,
                    open,
                    bare_base,
                    base,
                    separator,
                    close,
                });
            }
        }
        unreachable!("the merge-marker nonce space is exhaustive")
    }
}

fn labeled_merge_marker(byte: u8, size: u16, label: &str) -> Vec<u8> {
    let mut marker = vec![byte; usize::from(size)];
    marker.push(b' ');
    marker.extend_from_slice(label.as_bytes());
    marker
}

fn input_contains_line(inputs: &[&[u8]], candidate: &[u8]) -> bool {
    inputs.iter().any(|input| {
        input
            .split_inclusive(|byte| *byte == b'\n')
            .any(|line| line_without_eol(line) == candidate)
    })
}

fn entry_bytes(repo: &Repository, entry: Option<&IndexEntry>) -> Result<Vec<u8>> {
    let Some(entry) = entry else {
        return Ok(Vec::new());
    };
    if entry.mode & 0o170000 == 0o160000 {
        // Gitlink OIDs identify commits, so there is no blob to load. Keeping
        // the commit ID as display data lets the whole-side resolver show the
        // exact submodule revision represented by each index stage.
        return Ok(entry.id.to_string().into_bytes());
    }
    Ok(repo.find_blob(entry.id)?.content().to_vec())
}

fn is_text(bytes: &[u8]) -> bool {
    !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok()
}

fn synthetic_empty_entry(template: &IndexEntry, oid: git2::Oid) -> IndexEntry {
    IndexEntry {
        ctime: template.ctime,
        mtime: template.mtime,
        dev: template.dev,
        ino: template.ino,
        mode: template.mode,
        uid: template.uid,
        gid: template.gid,
        file_size: 0,
        id: oid,
        flags: template.flags,
        flags_extended: template.flags_extended,
        path: template.path.clone(),
    }
}

#[derive(Clone, Copy)]
enum ConflictInputSide {
    Ancestor,
    Ours,
    Theirs,
}

#[cfg(test)]
fn side_projection(sections: &[MergeSection], side: ConflictInputSide) -> Vec<u8> {
    let mut bytes = Vec::new();
    for section in sections {
        match section {
            MergeSection::Resolved(resolved) => bytes.extend_from_slice(resolved),
            MergeSection::Conflict {
                ancestor,
                ours,
                theirs,
            } => bytes.extend_from_slice(match side {
                ConflictInputSide::Ancestor => ancestor,
                ConflictInputSide::Ours => ours,
                ConflictInputSide::Theirs => theirs,
            }),
        }
    }
    bytes
}

/// libgit2 has to put marker lines on their own lines. When a conflicting side
/// reaches EOF without a newline it therefore inserts one byte before the next
/// marker. Remove only that provably synthetic byte so choosing a side remains
/// byte-exact.
fn restore_missing_final_newline(
    sections: &mut [MergeSection],
    original: &[u8],
    side: ConflictInputSide,
) {
    if original.ends_with(b"\n") {
        return;
    }

    for section in sections.iter_mut().rev() {
        let MergeSection::Conflict {
            ancestor,
            ours,
            theirs,
        } = section
        else {
            // A non-empty resolved suffix proves this conflict did not reach
            // EOF in the merge output, so its newline is real.
            if matches!(section, MergeSection::Resolved(bytes) if !bytes.is_empty()) {
                return;
            }
            continue;
        };
        let bytes = match side {
            ConflictInputSide::Ancestor => ancestor,
            ConflictInputSide::Ours => ours,
            ConflictInputSide::Theirs => theirs,
        };
        if bytes.is_empty() {
            continue;
        }

        // Depending on the input's line-ending style, libgit2 can add LF or
        // CRLF before its next marker. The conflict must be the final non-empty
        // merge section and the remaining bytes must match the original side's
        // actual EOF before either suffix is considered synthetic.
        let synthetic_len =
            if bytes.ends_with(b"\r\n") && original.ends_with(&bytes[..bytes.len() - 2]) {
                2
            } else if bytes.ends_with(b"\n") && original.ends_with(&bytes[..bytes.len() - 1]) {
                1
            } else {
                return;
            };
        bytes.truncate(bytes.len() - synthetic_len);
        return;
    }
}

fn read_worktree_snapshot(path: &Path) -> ConflictWorktreeSnapshot {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return ConflictWorktreeSnapshot::Missing;
        }
        Err(_) => return ConflictWorktreeSnapshot::Other,
    };
    if metadata.file_type().is_symlink() {
        return std::fs::read_link(path).map_or(ConflictWorktreeSnapshot::Other, |target| {
            ConflictWorktreeSnapshot::Symlink {
                target: target.as_os_str().as_encoded_bytes().to_vec(),
            }
        });
    }
    if metadata.is_file() {
        std::fs::read(path).map_or(ConflictWorktreeSnapshot::Other, |bytes| {
            ConflictWorktreeSnapshot::Regular {
                bytes,
                executable: worktree_executable(&metadata),
                readonly: metadata.permissions().readonly(),
            }
        })
    } else {
        ConflictWorktreeSnapshot::Other
    }
}

#[cfg(unix)]
fn worktree_executable(metadata: &std::fs::Metadata) -> Option<bool> {
    use std::os::unix::fs::PermissionsExt;
    Some(metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn worktree_executable(_metadata: &std::fs::Metadata) -> Option<bool> {
    None
}

fn parse_merge_sections(content: &[u8], markers: &MergeMarkers) -> Result<Vec<MergeSection>> {
    #[derive(Clone, Copy)]
    enum ParseState {
        Resolved,
        Ours,
        Ancestor,
        Theirs,
    }

    let mut state = ParseState::Resolved;
    let mut resolved = Vec::new();
    let mut ours = Vec::new();
    let mut ancestor = Vec::new();
    let mut theirs = Vec::new();
    let mut sections = Vec::new();

    for line in content.split_inclusive(|byte| *byte == b'\n') {
        let marker_line = line_without_eol(line);
        match state {
            ParseState::Resolved if marker_line == markers.open => {
                if !resolved.is_empty() {
                    sections.push(MergeSection::Resolved(std::mem::take(&mut resolved)));
                }
                state = ParseState::Ours;
            }
            ParseState::Ours if marker_line == markers.base || marker_line == markers.bare_base => {
                state = ParseState::Ancestor
            }
            // libgit2 may omit the ancestor block for add/add conflicts even
            // when diff3 style was requested. The synthetic ancestor is empty,
            // so the ordinary separator still carries the exact information.
            ParseState::Ours if marker_line == markers.separator => state = ParseState::Theirs,
            ParseState::Ancestor if marker_line == markers.separator => state = ParseState::Theirs,
            ParseState::Theirs if marker_line == markers.close => {
                sections.push(MergeSection::Conflict {
                    ancestor: std::mem::take(&mut ancestor),
                    ours: std::mem::take(&mut ours),
                    theirs: std::mem::take(&mut theirs),
                });
                state = ParseState::Resolved;
            }
            ParseState::Resolved => resolved.extend_from_slice(line),
            ParseState::Ours => ours.extend_from_slice(line),
            ParseState::Ancestor => ancestor.extend_from_slice(line),
            ParseState::Theirs => theirs.extend_from_slice(line),
        }
    }

    if !matches!(state, ParseState::Resolved) {
        anyhow::bail!("Git returned an incomplete conflict section for this file");
    }
    if !resolved.is_empty() || sections.is_empty() {
        sections.push(MergeSection::Resolved(resolved));
    }
    Ok(sections)
}

fn line_without_eol(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

#[cfg(test)]
mod conflict_diff_tests {
    use super::*;
    use rgitui_test_support::TempRepo;
    use std::io::Write;
    use std::process::Stdio;

    fn run_git(repo: &TempRepo, args: &[&str]) -> std::process::Output {
        super::super::git_command()
            .current_dir(repo.path())
            .args(args)
            .output()
            .expect("failed to run git")
    }

    fn install_gitlink_conflict(
        repo: &TempRepo,
        path: &str,
        ancestor: git2::Oid,
        ours: git2::Oid,
        theirs: git2::Oid,
    ) {
        let entries = format!(
            "160000 {ancestor} 1\t{path}\n160000 {ours} 2\t{path}\n160000 {theirs} 3\t{path}\n"
        );
        let mut child = super::super::git_command()
            .current_dir(repo.path())
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

    fn make_text_conflict() -> TempRepo {
        let repo = TempRepo::init();
        let base = (0..24)
            .map(|line| format!("base {line}\n"))
            .collect::<String>();
        repo.commit_file("conflict.txt", &base, "base");

        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        let incoming = base
            .replace("base 3\n", "incoming 3\n")
            .replace("base 18\n", "incoming 18\n");
        repo.commit_file("conflict.txt", &incoming, "incoming changes");

        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        let current = base
            .replace("base 3\n", "current 3\n")
            .replace("base 18\n", "current 18\n");
        repo.commit_file("conflict.txt", &current, "current changes");

        let merge = run_git(&repo, &["merge", "incoming"]);
        assert!(!merge.status.success(), "merge should stop on a conflict");
        repo
    }

    #[test]
    fn parse_merge_sections_preserves_crlf_and_missing_final_newline() {
        let markers = MergeMarkers::collision_free([b"", b"", b""]).unwrap();
        let marker = |byte: char| byte.to_string().repeat(usize::from(markers.size));
        let content = format!(
            "prefix\r\n{} rgitui-current\r\nours\r\n{} rgitui-base\r\nbase\r\n{}\r\ntheirs\r\n{} rgitui-incoming\r\nsuffix",
            marker('<'),
            marker('|'),
            marker('='),
            marker('>')
        );

        assert_eq!(
            parse_merge_sections(content.as_bytes(), &markers).unwrap(),
            vec![
                MergeSection::Resolved(b"prefix\r\n".to_vec()),
                MergeSection::Conflict {
                    ancestor: b"base\r\n".to_vec(),
                    ours: b"ours\r\n".to_vec(),
                    theirs: b"theirs\r\n".to_vec(),
                },
                MergeSection::Resolved(b"suffix".to_vec()),
            ]
        );
    }

    #[test]
    fn conflict_side_lines_that_look_like_generated_markers_remain_byte_exact() {
        let repo = TempRepo::init();
        repo.commit_file("conflict.txt", "base\n", "base");
        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        repo.commit_file("conflict.txt", "incoming\n", "incoming changes");
        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        let collision = format!(
            "{} rgitui-base\ncurrent\n",
            "|".repeat(usize::from(MIN_MERGE_MARKER_SIZE))
        );
        repo.commit_file("conflict.txt", &collision, "current changes");
        assert!(!run_git(&repo, &["merge", "incoming"]).status.success());

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("conflict.txt")).unwrap();

        assert_eq!(
            side_projection(&diff.sections, ConflictInputSide::Ours),
            collision.as_bytes()
        );
        assert_eq!(
            side_projection(&diff.sections, ConflictInputSide::Ancestor),
            b"base\n"
        );
        assert_eq!(
            side_projection(&diff.sections, ConflictInputSide::Theirs),
            b"incoming\n"
        );
    }

    #[test]
    fn computes_independent_regions_from_gits_merge_engine() {
        let repo = make_text_conflict();
        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("conflict.txt")).unwrap();

        assert_eq!(diff.conflict_count(), 2);
        assert!(diff.supports_text_resolution());
        assert!(!diff.is_binary);
        assert_eq!(
            diff.snapshot.worktree.bytes(),
            std::fs::read(repo.path().join("conflict.txt"))
                .ok()
                .as_deref()
        );
        assert!(diff.sections.iter().any(|section| matches!(
            section,
            MergeSection::Resolved(bytes) if bytes.windows(b"base 10\n".len()).any(|window| window == b"base 10\n")
        )));
    }

    #[test]
    fn conflict_sides_without_final_newlines_remain_byte_exact() {
        let repo = TempRepo::init();
        repo.commit_file("conflict.txt", "base", "base");
        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        repo.commit_file("conflict.txt", "incoming", "incoming changes");
        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        repo.commit_file("conflict.txt", "current", "current changes");
        assert!(!run_git(&repo, &["merge", "incoming"]).status.success());

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("conflict.txt")).unwrap();
        assert_eq!(
            side_projection(&diff.sections, ConflictInputSide::Ancestor),
            b"base"
        );
        assert_eq!(
            side_projection(&diff.sections, ConflictInputSide::Ours),
            b"current"
        );
        assert_eq!(
            side_projection(&diff.sections, ConflictInputSide::Theirs),
            b"incoming"
        );
    }

    #[test]
    fn eof_conflict_remains_exact_when_resolved_sections_include_other_side_changes() {
        let repo = TempRepo::init();
        let base = (0..20)
            .map(|line| {
                if line == 19 {
                    format!("base {line}")
                } else {
                    format!("base {line}\n")
                }
            })
            .collect::<String>();
        repo.commit_file("conflict.txt", &base, "base");

        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        let incoming = base
            .replace("base 2\n", "incoming 2\n")
            .replace("base 19", "incoming 19");
        repo.commit_file("conflict.txt", &incoming, "incoming changes");

        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        let current = base
            .replace("base 8\n", "current 8\n")
            .replace("base 19", "current 19");
        repo.commit_file("conflict.txt", &current, "current changes");
        assert!(!run_git(&repo, &["merge", "incoming"]).status.success());

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("conflict.txt")).unwrap();
        assert_eq!(diff.conflict_count(), 1);
        assert!(matches!(
            diff.sections
                .iter()
                .find(|section| matches!(section, MergeSection::Conflict { .. })),
            Some(MergeSection::Conflict {
                ancestor,
                ours,
                theirs,
            }) if ancestor == b"base 19"
                && ours == b"current 19"
                && theirs == b"incoming 19"
        ));
    }

    #[test]
    fn non_eof_conflict_keeps_real_newline_when_unterminated_suffix_repeats_its_text() {
        let repo = TempRepo::init();
        let suffix = (1..20)
            .map(|line| {
                if line == 19 {
                    "X".to_string()
                } else {
                    format!("common {line}\n")
                }
            })
            .collect::<String>();
        repo.commit_file("conflict.txt", &format!("base\n{suffix}"), "base");

        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        repo.commit_file(
            "conflict.txt",
            &format!("incoming\n{suffix}"),
            "incoming changes",
        );
        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        repo.commit_file("conflict.txt", &format!("X\n{suffix}"), "current changes");
        assert!(!run_git(&repo, &["merge", "incoming"]).status.success());

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("conflict.txt")).unwrap();
        assert!(matches!(
            diff.sections
                .iter()
                .find(|section| matches!(section, MergeSection::Conflict { .. })),
            Some(MergeSection::Conflict { ours, .. }) if ours == b"X\n"
        ));
        assert!(matches!(
            diff.sections.last(),
            Some(MergeSection::Resolved(bytes)) if bytes.ends_with(b"X")
        ));
    }

    #[test]
    fn add_add_conflict_uses_a_synthetic_empty_ancestor() {
        let repo = TempRepo::init();
        repo.commit("base");
        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        repo.commit_file("added.txt", "incoming\n", "incoming add");
        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        repo.commit_file("added.txt", "current\n", "current add");
        assert!(!run_git(&repo, &["merge", "incoming"]).status.success());

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("added.txt")).unwrap();
        assert!(!diff.ancestor_exists);
        assert!(diff.ours_exists && diff.theirs_exists);
        assert!(diff.supports_text_resolution());
        assert_eq!(diff.conflict_count(), 1);
        assert!(
            matches!(
                &diff.sections[0],
                MergeSection::Conflict { ancestor, ours, theirs }
                    if ancestor.is_empty() && ours == b"current\n" && theirs == b"incoming\n"
            ),
            "unexpected sections: {:?}",
            diff.sections
        );
    }

    #[test]
    fn binary_conflict_is_kept_as_a_whole_side_decision() {
        let repo = TempRepo::init();
        repo.write_file_bytes("image.bin", b"base\0bytes");
        repo.stage("image.bin");
        repo.commit("base");
        assert!(run_git(&repo, &["checkout", "-b", "incoming"])
            .status
            .success());
        repo.write_file_bytes("image.bin", b"incoming\0bytes");
        repo.stage("image.bin");
        repo.commit("incoming binary");
        assert!(run_git(&repo, &["checkout", "main"]).status.success());
        repo.write_file_bytes("image.bin", b"current\0bytes");
        repo.stage("image.bin");
        repo.commit("current binary");
        assert!(!run_git(&repo, &["merge", "incoming"]).status.success());

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("image.bin")).unwrap();
        assert!(diff.is_binary);
        assert!(!diff.supports_text_resolution());
        assert_eq!(diff.conflict_count(), 1);
    }

    #[test]
    fn gitlink_conflict_uses_commit_ids_without_blob_lookup() {
        let repo = TempRepo::init();
        let ancestor = repo.commit_file("seed.txt", "ancestor\n", "ancestor");
        let ours = repo.commit_file("seed.txt", "ours\n", "ours");
        let theirs = repo.commit_file("seed.txt", "theirs\n", "theirs");
        install_gitlink_conflict(&repo, "module", ancestor, ours, theirs);

        let diff = compute_three_way_conflict_diff(repo.path(), Path::new("module")).unwrap();

        assert!(diff.is_special_file);
        assert!(!diff.supports_text_resolution());
        assert_eq!(diff.result_mode, 0o160000);
        assert!(matches!(
            &diff.sections[0],
            MergeSection::Conflict {
                ancestor: actual_ancestor,
                ours: actual_ours,
                theirs: actual_theirs,
            } if actual_ancestor == ancestor.to_string().as_bytes()
                && actual_ours == ours.to_string().as_bytes()
                && actual_theirs == theirs.to_string().as_bytes()
        ));
    }
}

// ── Integration-level diff tests ────────────────────────────────

#[cfg(test)]
mod diff_integration_tests {
    use super::*;
    use rgitui_test_support::TempRepo;
    use std::path::Path;

    /// A repo with two commits touching `hello.txt`; `HEAD` is the second.
    /// File content:
    ///   initial  → "line1\nline2\nline3\n"
    ///   amended  → "line1\nLINE2_CHANGED\nline3\n"
    fn make_two_commit_repo() -> TempRepo {
        let fixture = TempRepo::init();
        fixture.commit_file("hello.txt", "line1\nline2\nline3\n", "initial");
        fixture.commit_file("hello.txt", "line1\nLINE2_CHANGED\nline3\n", "change line2");
        fixture
    }

    /// Build a repo where one file is staged (index differs from HEAD).
    fn make_staged_change_repo() -> TempRepo {
        let fixture = TempRepo::init();
        fixture.commit_file("data.txt", "alpha\nbeta\ngamma\n", "initial");

        // Modify the file and stage it — don't commit.
        fixture.write_file("data.txt", "alpha\nbeta_modified\ngamma\n");
        fixture.stage("data.txt");
        fixture
    }

    // ── compute_commit_diff ───────────────────────────────────────

    #[test]
    fn commit_diff_returns_changed_file() {
        let fixture = make_two_commit_repo();
        let diff = compute_commit_diff(fixture.path(), fixture.head_oid()).unwrap();
        assert_eq!(diff.files.len(), 1, "should have exactly one changed file");
        assert_eq!(diff.files[0].path, Path::new("hello.txt"));
    }

    #[test]
    fn commit_diff_counts_additions_and_deletions() {
        let fixture = make_two_commit_repo();
        let diff = compute_commit_diff(fixture.path(), fixture.head_oid()).unwrap();
        // "line2" → "LINE2_CHANGED": one deletion + one addition
        assert_eq!(diff.total_additions, 1);
        assert_eq!(diff.total_deletions, 1);
    }

    #[test]
    fn commit_diff_hunk_has_lines() {
        let fixture = make_two_commit_repo();
        let diff = compute_commit_diff(fixture.path(), fixture.head_oid()).unwrap();
        let file = &diff.files[0];
        assert!(!file.hunks.is_empty(), "should have at least one hunk");
        let hunk = &file.hunks[0];
        // Should contain an addition and a deletion
        let has_addition = hunk
            .lines
            .iter()
            .any(|l| matches!(l, DiffLine::Addition(_)));
        let has_deletion = hunk
            .lines
            .iter()
            .any(|l| matches!(l, DiffLine::Deletion(_)));
        assert!(has_addition, "hunk should have an addition line");
        assert!(has_deletion, "hunk should have a deletion line");
    }

    #[test]
    fn commit_diff_invalid_oid_returns_err() {
        let fixture = make_two_commit_repo();
        let fake_oid = git2::Oid::from_str("0000000000000000000000000000000000000000").unwrap();
        assert!(compute_commit_diff(fixture.path(), fake_oid).is_err());
    }

    #[test]
    fn commit_diff_first_commit_no_parent() {
        // The first commit has no parent; compute_commit_diff should handle it
        let fixture = TempRepo::init();
        let oid = fixture.commit_file("f.txt", "hello\n", "root");
        let diff = compute_commit_diff(fixture.path(), oid).unwrap();
        // Root commit: diff against empty tree → f.txt is added
        assert_eq!(diff.files.len(), 1);
        assert!(matches!(diff.files[0].kind, FileChangeKind::Added));
    }

    // ── compute_file_diff (unstaged) ─────────────────────────────

    #[test]
    fn file_diff_unstaged_no_changes() {
        let fixture = TempRepo::init();
        fixture.commit_file("clean.txt", "no changes\n", "init");
        // No modifications — should return empty hunk list
        let diff = compute_file_diff(fixture.path(), Path::new("clean.txt"), false).unwrap();
        assert!(diff.hunks.is_empty(), "no unstaged changes expected");
    }

    // ── compute_staged_diff_text ──────────────────────────────────

    #[test]
    fn staged_diff_text_contains_change() {
        let fixture = make_staged_change_repo();
        let text = compute_staged_diff_text(fixture.path()).unwrap();
        assert!(
            text.contains("beta_modified") || text.contains("+beta_modified"),
            "staged diff should include modified content"
        );
        assert!(
            text.contains("-beta") || text.contains("beta"),
            "staged diff should include original content"
        );
    }

    #[test]
    fn staged_diff_text_has_diff_markers() {
        let fixture = make_staged_change_repo();
        let text = compute_staged_diff_text(fixture.path()).unwrap();
        // compute_staged_diff_text prefixes each line with origin char
        assert!(
            text.contains('+') || text.contains('-'),
            "should have diff markers"
        );
    }

    // ── batch_diff_stats ─────────────────────────────────────────

    #[test]
    fn batch_diff_stats_staged_detects_changed_file() {
        let fixture = make_staged_change_repo();
        let stats = batch_diff_stats(fixture.repo(), true);
        assert!(
            stats.contains_key(Path::new("data.txt")),
            "staged stats should include data.txt"
        );
        let (adds, dels) = stats[Path::new("data.txt")];
        assert_eq!(adds, 1, "one line added");
        assert_eq!(dels, 1, "one line deleted");
    }

    #[test]
    fn batch_diff_stats_unstaged_empty_when_clean() {
        let fixture = TempRepo::init();
        fixture.commit_file("x.txt", "clean\n", "init");
        let stats = batch_diff_stats(fixture.repo(), false);
        // Working tree matches index → no unstaged changes
        assert!(stats.is_empty(), "no unstaged changes on clean repo");
    }
    // ── parse_multi_file_diff ─────────────────────────────────────

    #[test]
    fn parse_multi_file_diff_aggregates_files() {
        let fixture = make_two_commit_repo();
        let repo = fixture.repo();
        let commit = repo.find_commit(fixture.head_oid()).unwrap();
        let tree = commit.tree().unwrap();
        let parent = commit.parent(0).unwrap();
        let parent_tree = parent.tree().unwrap();
        let diff = repo
            .diff_tree_to_tree(Some(&parent_tree), Some(&tree), None)
            .unwrap();
        let result = parse_multi_file_diff(&diff).unwrap();
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.total_additions, 1);
        assert_eq!(result.total_deletions, 1);
    }

    // ── emitted_sign ──────────────────────────────────────────────

    #[test]
    fn emitted_sign_staging_preserves_signs() {
        // Staging (staged=false) applies an index→workdir patch to the index, so
        // signs are preserved: a workdir addition stays '+', a deletion stays '-'.
        assert_eq!(emitted_sign('+', false), Some('+'));
        assert_eq!(emitted_sign('-', false), Some('-'));
        assert_eq!(emitted_sign(' ', false), Some(' '));
        assert_eq!(emitted_sign('=', false), None);
    }

    #[test]
    fn emitted_sign_unstaging_negates_signs() {
        // Unstaging (staged=true) applies a HEAD→index patch to the index, so signs
        // are negated: an index addition becomes '-' (removed), a deletion '+'.
        assert_eq!(emitted_sign('+', true), Some('-'));
        assert_eq!(emitted_sign('-', true), Some('+'));
        assert_eq!(emitted_sign(' ', true), Some(' '));
        assert_eq!(emitted_sign('>', true), None);
    }

    // ── generate_line_patch_for_repo tests ───────────────────────────────────

    /// End-to-end check of the viewer→git contract for unstaging.
    ///
    /// The diff viewer emits an addition as `(None, Some(new_lineno))`. For the
    /// staged diff that turns "beta" into "beta_modified", the addition
    /// "+beta_modified" has new_lineno=2, so the viewer sends `(None, Some(2))`.
    /// Unstaging must negate that addition into a "-beta_modified" deletion so the
    /// applied patch removes the line from the index.
    ///
    /// This is the contract BUG-14 corrected: the previous code matched additions
    /// against the `old` slot, which is always `None` for viewer-emitted additions,
    /// silently producing a context-only no-op patch.
    #[test]
    fn hunk_patch_stages_and_parses_as_a_complete_patch() {
        let fixture = make_staged_change_repo();
        let repo = fixture.repo();

        let head_tree = repo.head().unwrap().peel_to_tree().unwrap();
        let mut index = repo.index().unwrap();
        index.read_tree(&head_tree).unwrap();
        index.write().unwrap();

        let patch_text =
            generate_hunk_patch_for_repo(repo, Path::new("data.txt"), 0, false).unwrap();
        assert!(patch_text.starts_with("diff --git "));
        let diff = git2::Diff::from_buffer(patch_text.as_bytes()).unwrap();
        repo.apply(&diff, git2::ApplyLocation::Index, None).unwrap();
    }

    #[test]
    fn hunk_patch_unstaging_reverses_the_change() {
        let fixture = make_staged_change_repo();
        let repo = fixture.repo();

        let patch_text =
            generate_hunk_patch_for_repo(repo, Path::new("data.txt"), 0, true).unwrap();
        assert!(patch_text.contains("-beta_modified\n"));
        assert!(patch_text.contains("+beta\n"));
        let diff = git2::Diff::from_buffer(patch_text.as_bytes()).unwrap();
        repo.apply(&diff, git2::ApplyLocation::Index, None).unwrap();

        let head_tree = repo.head().unwrap().peel_to_tree().unwrap();
        let staged = repo
            .diff_tree_to_index(Some(&head_tree), None, None)
            .unwrap();
        assert_eq!(staged.deltas().len(), 0);
    }

    #[test]
    fn line_patch_unstage_addition_negates_to_deletion() {
        let fixture = make_staged_change_repo();
        let repo = fixture.repo();

        // Viewer-produced pair for the "+beta_modified" addition (new_lineno=2).
        let line_pairs = vec![(None, Some(2usize))];
        let patch_text =
            generate_line_patch_for_repo(repo, Path::new("data.txt"), &line_pairs, true).unwrap();

        assert!(
            patch_text.contains("-beta_modified\n"),
            "unstaging should negate the addition into '-beta_modified', got:\n{patch_text}"
        );
        assert!(
            !patch_text.contains("+beta_modified\n"),
            "the addition must not be emitted with its original '+' sign, got:\n{patch_text}"
        );

        // The patch is applied to the index, whose content is the pre-image. Only a
        // correct old_start/new_start swap (BUG-13) yields a patch git will accept;
        // a text-only check cannot catch an off-by-one in those positions.
        let diff = git2::Diff::from_buffer(patch_text.as_bytes()).unwrap();
        repo.apply(&diff, git2::ApplyLocation::Index, None).unwrap();
    }

    /// A deletion selected for unstaging (viewer pair `(Some(old_lineno), None)`)
    /// must be negated into a restoring "+" line.
    #[test]
    fn line_patch_unstage_deletion_negates_to_addition() {
        let fixture = make_staged_change_repo();
        let repo = fixture.repo();

        // "-beta" deletion in the staged diff has old_lineno=2.
        let line_pairs = vec![(Some(2usize), None)];
        let patch_text =
            generate_line_patch_for_repo(repo, Path::new("data.txt"), &line_pairs, true).unwrap();

        assert!(
            patch_text.contains("+beta\n"),
            "unstaging should negate the deletion into '+beta', got:\n{patch_text}"
        );
    }

    /// Staging a workdir addition preserves its '+' sign so applying the patch adds
    /// the line to the index. Build an unstaged-only addition and stage it.
    #[test]
    fn line_patch_stage_addition_preserves_sign() {
        let fixture = TempRepo::init();
        fixture.commit_file("data.txt", "alpha\ngamma\n", "init");

        // Insert "beta" in the working tree only (index→workdir addition at new line 2).
        fixture.write_file("data.txt", "alpha\nbeta\ngamma\n");

        let repo = fixture.repo();
        let line_pairs = vec![(None, Some(2usize))];
        let patch_text =
            generate_line_patch_for_repo(repo, Path::new("data.txt"), &line_pairs, false).unwrap();

        assert!(
            patch_text.contains("+beta\n"),
            "staging should preserve the '+beta' addition, got:\n{patch_text}"
        );

        // The generated patch must apply cleanly to the index.
        let diff = git2::Diff::from_buffer(patch_text.as_bytes()).unwrap();
        repo.apply(&diff, git2::ApplyLocation::Index, None).unwrap();
    }

    /// Appending a line at the end of a long file makes the last matched line an
    /// addition (old_lineno = None) inside a hunk that starts well past line 1.
    /// The old `last_lineno + 1 - hunk_old_start` math underflowed u32 here
    /// (BUG-13); counting emitted lines instead must produce an applicable patch.
    #[test]
    fn line_patch_stage_trailing_addition_no_underflow() {
        let fixture = TempRepo::init();
        let base: String = (1..=20).map(|i| format!("line{i}\n")).collect();
        fixture.commit_file("data.txt", &base, "init");

        // Append a line at the end; its hunk starts past line 1 and ends on the
        // addition itself (old_lineno = None for that line).
        fixture.write_file("data.txt", &format!("{base}appended\n"));

        // The appended line sits at new line 21.
        let repo = fixture.repo();
        let line_pairs = vec![(None, Some(21usize))];
        let patch_text =
            generate_line_patch_for_repo(repo, Path::new("data.txt"), &line_pairs, false).unwrap();

        assert!(
            patch_text.contains("+appended\n"),
            "patch should contain the appended line, got:\n{patch_text}"
        );
        // Underflow would yield "@@ -N,4294967292 ... @@"; assert no such count.
        assert!(
            !patch_text.contains("4294967292"),
            "hunk header must not carry an underflowed count, got:\n{patch_text}"
        );
        let diff = git2::Diff::from_buffer(patch_text.as_bytes()).unwrap();
        repo.apply(&diff, git2::ApplyLocation::Index, None).unwrap();
    }
}
