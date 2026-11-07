//! Plans byte-faithful writable diff blocks, Git-default stageable hunks and
//! editor line-range staging, then performs those writes after re-validating
//! the planned snapshot under the repository write lease.
//!
//! Hosts never build patch text. Core reads complete-file patches, keeps every
//! original byte (CR, missing final newline), and derives the index or worktree
//! patch itself. A write request names a planned block and the snapshot token
//! it was planned from; Core rebuilds the plan under the lease and refuses the
//! write when the repository moved, instead of applying lines that shifted.

use super::{
    command, diff_impl, execute_git_readonly, is_safe_pathspec, rewrite::RewriteLease,
    validate_root, GitCommandRequest, GitDiffRequest, FULL_FILE_CONTEXT_LINES,
};
use crate::protocol::{CoreError, ErrorCode, GitDiffFileResponse, GitDiffHunkResponse};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Context Git uses by default around a change; staged patches carry the same
/// amount so `git apply` still rejects a target that moved since planning.
const PATCH_CONTEXT_LINES: usize = 3;
/// Marker Git prints after a line that has no terminating newline.
const NO_NEWLINE_MARKER: &str = "\\ No newline at end of file";

/// Stable failure: the planned snapshot no longer matches the repository.
pub(crate) const DIFF_BLOCK_STALE: &str = "GIT_DIFF_BLOCK_STALE";
/// Stable failure: the named block exists but cannot perform the action.
pub(crate) const DIFF_BLOCK_UNAVAILABLE: &str = "GIT_DIFF_BLOCK_UNAVAILABLE";
/// Stable failure: attributes may rewrite worktree bytes, so a hunk rollback
/// could not be proven byte-faithful and must fall back to whole-file actions.
pub(crate) const HUNK_ROLLBACK_UNSAFE: &str = "GIT_HUNK_ROLLBACK_UNSAFE";
/// Stable failure: the editor change no longer matches the index or the file on disk.
pub(crate) const GUTTER_CHANGE_STALE: &str = "GIT_GUTTER_CHANGE_STALE";

fn invalid(message: &'static str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

/// One file line exactly as Git printed it inside a patch.
#[derive(Clone, Debug, PartialEq, Eq)]
struct RawLine {
    /// Line text without the patch prefix and terminating LF; a CR is kept.
    text: String,
    /// False only for a final line Git marked with `\ No newline at end of file`.
    newline: bool,
}

impl RawLine {
    /// Text as an editor shows it: one trailing CR belongs to the line break.
    fn display(&self) -> &str {
        self.text.strip_suffix('\r').unwrap_or(&self.text)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Operation {
    Context,
    Removed,
    Added,
}

/// One body line of a single-hunk patch with its original marker, if any.
struct PatchEntry {
    operation: Operation,
    line: RawLine,
    /// The exact `\` marker line Git printed after this entry.
    marker: Option<String>,
}

/// A patch section with exactly one hunk, parsed without losing bytes.
struct SingleHunkDocument {
    /// File header lines before the hunk (`diff --git`, `index`, `---`, `+++`).
    header: Vec<String>,
    entries: Vec<PatchEntry>,
    old_start: usize,
    new_start: usize,
}

impl SingleHunkDocument {
    /// Parses one file section. `None` means the section has no hunk, more
    /// than one hunk, or a body Git would not produce; callers fail closed.
    fn parse(section: &str) -> Option<Self> {
        let body = section.strip_suffix('\n').unwrap_or(section);
        let mut lines = body.split('\n');
        let mut header = Vec::new();
        let hunk_header = loop {
            let line = lines.next()?;
            if line.starts_with("@@") {
                break line;
            }
            header.push(line.to_string());
        };
        let (old_start, old_count, new_start, new_count) = parse_range_header(hunk_header)?;
        let mut entries: Vec<PatchEntry> = Vec::new();
        for line in lines {
            let operation = match line.as_bytes().first() {
                Some(b' ') => Operation::Context,
                Some(b'-') => Operation::Removed,
                Some(b'+') => Operation::Added,
                Some(b'\\') => {
                    let entry = entries.last_mut()?;
                    if entry.marker.is_some() {
                        return None;
                    }
                    entry.marker = Some(line.to_string());
                    entry.line.newline = false;
                    continue;
                }
                // `diff.suppressBlankEmpty` prints an empty context line bare.
                None => Operation::Context,
                Some(_) => return None,
            };
            if entries.last().is_some_and(|entry| entry.marker.is_some()) {
                // Only the final line of a side can lack its newline.
                let previous = entries.last().expect("checked above");
                if previous.operation == Operation::Context || previous.operation == operation {
                    return None;
                }
            }
            entries.push(PatchEntry {
                operation,
                line: RawLine {
                    text: line.get(1..).unwrap_or_default().to_string(),
                    newline: true,
                },
                marker: None,
            });
        }
        let document = Self {
            header,
            entries,
            old_start,
            new_start,
        };
        (document.old().len() == old_count && document.new().len() == new_count).then_some(document)
    }

    /// Parses a section whose hunk spans both complete files.
    fn parse_complete(section: &str) -> Option<Self> {
        let document = Self::parse(section)?;
        let expected = |count: usize| usize::from(count > 0);
        (document.old_start == expected(document.old().len())
            && document.new_start == expected(document.new().len()))
        .then_some(document)
    }

    fn old(&self) -> Vec<RawLine> {
        self.side(Operation::Removed)
    }

    fn new(&self) -> Vec<RawLine> {
        self.side(Operation::Added)
    }

    fn side(&self, changed: Operation) -> Vec<RawLine> {
        self.entries
            .iter()
            .filter(|entry| entry.operation == Operation::Context || entry.operation == changed)
            .map(|entry| entry.line.clone())
            .collect()
    }

    /// Minimal header that applies content only. Mode, rename and index lines
    /// are dropped so a block write never stages a mode change or a rename.
    fn content_header(&self) -> Option<[String; 3]> {
        let diff = self
            .header
            .iter()
            .find(|line| line.starts_with("diff --git "))?;
        let old = self.header.iter().find(|line| line.starts_with("--- "))?;
        let new = self.header.iter().find(|line| line.starts_with("+++ "))?;
        if old == "--- /dev/null" || new == "+++ /dev/null" {
            return None;
        }
        Some([diff.clone(), old.clone(), new.clone()])
    }

    /// Contiguous change runs in patch order, with zero-based side positions.
    fn runs(&self) -> Vec<ChangeRun> {
        let mut runs: Vec<ChangeRun> = Vec::new();
        let mut open = false;
        let (mut old, mut new) = (0, 0);
        for (index, entry) in self.entries.iter().enumerate() {
            // Unified line 0 is the hunk header, so body entries start at 1.
            let unified = index + 1;
            if entry.operation == Operation::Context {
                open = false;
                old += 1;
                new += 1;
                continue;
            }
            if !open {
                runs.push(ChangeRun {
                    old_start: old,
                    old_end: old,
                    new_start: new,
                    new_end: new,
                    first_removed: None,
                    first_added: None,
                });
                open = true;
            }
            let run = runs.last_mut().expect("run was opened");
            if entry.operation == Operation::Removed {
                old += 1;
                run.old_end = old;
                run.first_removed.get_or_insert(unified);
            } else {
                new += 1;
                run.new_end = new;
                run.first_added.get_or_insert(unified);
            }
        }
        runs
    }
}

fn parse_range_header(header: &str) -> Option<(usize, usize, usize, usize)> {
    let mut columns = header.split(' ');
    if columns.next()? != "@@" {
        return None;
    }
    let range = |value: &str| -> Option<(usize, usize)> {
        let mut parts = value.splitn(2, ',');
        let start = parts.next()?.parse().ok()?;
        let count = parts.next().map_or(Some(1), |count| count.parse().ok())?;
        Some((start, count))
    };
    let (old_start, old_count) = range(columns.next()?.strip_prefix('-')?)?;
    let (new_start, new_count) = range(columns.next()?.strip_prefix('+')?)?;
    (columns.next()? == "@@").then_some((old_start, old_count, new_start, new_count))
}

/// One contiguous run of removed and added lines.
#[derive(Clone, Copy, Debug)]
struct ChangeRun {
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
    /// Unified line index of the first removed line in the run.
    first_removed: Option<usize>,
    /// Unified line index of the first added line in the run.
    first_added: Option<usize>,
}

impl ChangeRun {
    /// Identity shared with the per-file unified `lines`: hosts address rows
    /// by `line-<index>`, the first old-side row of the run, else its first
    /// new-side row.
    fn id(&self) -> String {
        format!(
            "line-{}",
            self.first_removed.or(self.first_added).unwrap_or_default()
        )
    }
}

fn emit(patch: &mut String, prefix: char, line: &RawLine) {
    patch.push(prefix);
    patch.push_str(&line.text);
    patch.push('\n');
    if !line.newline {
        patch.push_str(NO_NEWLINE_MARKER);
        patch.push('\n');
    }
}

/// Builds a patch that replaces `base[start..end]` with `replacement`, with
/// Git's default context from `base`. Returns `None` for a no-op, or when the
/// result would leave a line without its newline in the middle of the file.
fn replacement_patch(
    header: &[String; 3],
    base: &[RawLine],
    start: usize,
    end: usize,
    replacement: &[RawLine],
) -> Option<String> {
    if start > end || end > base.len() || base[start..end] == *replacement {
        return None;
    }
    let result = base[..start]
        .iter()
        .chain(replacement)
        .chain(&base[end..])
        .collect::<Vec<_>>();
    if result
        .iter()
        .take(result.len().saturating_sub(1))
        .any(|line| !line.newline)
    {
        return None;
    }
    let context_start = start.saturating_sub(PATCH_CONTEXT_LINES);
    let context_end = (end + PATCH_CONTEXT_LINES).min(base.len());
    let old_count = context_end - context_start;
    let new_count = (start - context_start) + replacement.len() + (context_end - end);
    // Git names the line before an empty range, or 0 at the start of the file.
    let first = |count: usize| {
        if count == 0 {
            context_start
        } else {
            context_start + 1
        }
    };
    let mut patch = header.join("\n");
    patch.push('\n');
    patch.push_str(&format!(
        "@@ -{},{old_count} +{},{new_count} @@\n",
        first(old_count),
        first(new_count)
    ));
    for line in &base[context_start..start] {
        emit(&mut patch, ' ', line);
    }
    for line in &base[start..end] {
        emit(&mut patch, '-', line);
    }
    for line in replacement {
        emit(&mut patch, '+', line);
    }
    for line in &base[end..context_end] {
        emit(&mut patch, ' ', line);
    }
    Some(patch)
}

// ---------------------------------------------------------------------------
// Git-default stageable hunks for complete-file diffs
// ---------------------------------------------------------------------------

/// Splits a complete-file section into the hunks Git would print with its
/// default three context lines. Each hunk keeps the original bytes and the
/// section's file header so `git apply` reproduces Git's own `-U3` patch.
/// `None` means the section cannot be split safely; callers then expose no
/// writable hunk rather than one that would stage the whole file.
pub(super) fn stageable_hunks(section: &str) -> Option<Vec<GitDiffHunkResponse>> {
    let document = SingleHunkDocument::parse(section)?;
    let changed = |index: usize| document.entries[index].operation != Operation::Context;
    let mut hunks = Vec::new();
    let mut index = 0;
    while index < document.entries.len() {
        if !changed(index) {
            index += 1;
            continue;
        }
        let mut last = index;
        // Like Git, changes whose surrounding context would touch share one hunk.
        let mut next = index + 1;
        while next < document.entries.len() && next - last - 1 <= 2 * PATCH_CONTEXT_LINES {
            if changed(next) {
                last = next;
            }
            next += 1;
        }
        let start = index.saturating_sub(PATCH_CONTEXT_LINES);
        let end = (last + PATCH_CONTEXT_LINES + 1).min(document.entries.len());
        hunks.push(split_hunk(&document, hunks.len(), start, end));
        index = last + 1;
    }
    Some(hunks)
}

fn split_hunk(
    document: &SingleHunkDocument,
    ordinal: usize,
    start: usize,
    end: usize,
) -> GitDiffHunkResponse {
    let side_before = |changed: Operation| {
        document.entries[..start]
            .iter()
            .filter(|entry| entry.operation == Operation::Context || entry.operation == changed)
            .count()
    };
    let side_count = |changed: Operation| {
        document.entries[start..end]
            .iter()
            .filter(|entry| entry.operation == Operation::Context || entry.operation == changed)
            .count()
    };
    let range = |first: usize, before: usize, count: usize| {
        // Git names the line before an empty range, or 0 at the start of the file.
        let line = first.max(1) + before;
        format!("{},{count}", if count == 0 { line - 1 } else { line })
    };
    let old_count = side_count(Operation::Removed);
    let new_count = side_count(Operation::Added);
    let header = format!(
        "@@ -{} +{} @@",
        range(
            document.old_start,
            side_before(Operation::Removed),
            old_count
        ),
        range(document.new_start, side_before(Operation::Added), new_count)
    );
    let mut patch = document.header.join("\n");
    if !patch.is_empty() {
        patch.push('\n');
    }
    patch.push_str(&header);
    patch.push('\n');
    for entry in &document.entries[start..end] {
        patch.push(match entry.operation {
            Operation::Context => ' ',
            Operation::Removed => '-',
            Operation::Added => '+',
        });
        patch.push_str(&entry.line.text);
        patch.push('\n');
        if let Some(marker) = &entry.marker {
            patch.push_str(marker);
            patch.push('\n');
        }
    }
    GitDiffHunkResponse {
        id: format!("hunk-{ordinal}"),
        header,
        patch,
        content_patch: None,
        // Unified line 0 is the section's single hunk header.
        line_start: Some(start + 1),
        line_end: Some(end + 1),
    }
}

// ---------------------------------------------------------------------------
// Commit review blocks: HEAD -> worktree display, HEAD -> index inclusion
// ---------------------------------------------------------------------------

/// One side of a complete-file comparison as Git reported it.
#[derive(Clone, Copy)]
pub(super) struct PlanSide<'a> {
    pub patch: &'a str,
    /// Git status letter of the section: `A`, `D`, `R` or `M`.
    pub status: &'a str,
    pub is_binary: bool,
}

/// One planned block and the Core-owned patches its actions apply.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DiffBlock {
    /// `line-<index>` into the HEAD -> worktree section's unified lines.
    id: String,
    /// The index already holds exactly this block's worktree content.
    checked: bool,
    /// The index holds content that is neither HEAD's nor the worktree's.
    indeterminate: bool,
    can_toggle: bool,
    can_rollback: bool,
    /// New and deleted files toggle as a whole through ordinary staging.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    whole_file: bool,
    /// Forward index patch that makes the index hold this block's worktree text.
    #[serde(skip)]
    include: Option<String>,
    /// Forward index patch that restores HEAD's text for this block in the index.
    #[serde(skip)]
    exclude: Option<String>,
    /// Forward worktree patch that restores the index text for this block.
    #[serde(skip)]
    rollback: Option<String>,
    /// Rollback is otherwise possible; only attribute safety may still block it.
    #[serde(skip)]
    rollback_candidate: bool,
}

fn whole_file_block(run: &ChangeRun, checked: bool, indeterminate: bool) -> DiffBlock {
    DiffBlock {
        id: run.id(),
        checked,
        indeterminate,
        can_toggle: true,
        can_rollback: false,
        whole_file: true,
        include: None,
        exclude: None,
        rollback: None,
        rollback_candidate: false,
    }
}

/// Plans commit-review blocks. The HEAD -> worktree comparison owns the
/// visible blocks and the HEAD -> index comparison owns inclusion. A block can
/// hold only some staged lines, and earlier staged edits shift index
/// coordinates, so each block's index span is mapped explicitly. `None` means
/// the file only supports whole-file inclusion. `writable` is false when Git
/// output lost bytes; `rollback_safe` reports the worktree attribute check.
pub(super) fn plan_blocks(
    worktree: PlanSide,
    index: Option<PlanSide>,
    writable: bool,
    rollback_safe: bool,
) -> Option<Vec<DiffBlock>> {
    if worktree.is_binary || worktree.status == "R" {
        return None;
    }
    let visible = SingleHunkDocument::parse_complete(worktree.patch)?;
    let index = index.filter(|side| !side.patch.is_empty());
    let indexed = match index {
        Some(side) if side.is_binary => return None,
        Some(side) => Some(SingleHunkDocument::parse_complete(side.patch)?),
        None => None,
    };
    let runs = visible.runs();
    let (head_lines, worktree_lines) = (visible.old(), visible.new());
    if matches!(worktree.status, "A" | "D") {
        let [run] = runs.as_slice() else {
            return None;
        };
        let checked = indexed
            .as_ref()
            .is_some_and(|indexed| indexed.new() == worktree_lines);
        // Whole-file inclusion stages the file through `git add`, which keeps
        // its bytes even when the patch text could not be decoded faithfully.
        return Some(vec![whole_file_block(
            run,
            checked,
            !checked && indexed.is_some(),
        )]);
    }
    let (index_head, index_lines, index_runs) = match &indexed {
        Some(indexed) => (indexed.old(), indexed.new(), indexed.runs()),
        None => (head_lines.clone(), head_lines.clone(), Vec::new()),
    };
    if index_head != head_lines {
        return None;
    }
    let header = visible.content_header()?;
    let mut prior_cursor = 0;
    let mut shift_before: isize = 0;
    let blocks = runs
        .iter()
        .map(|run| {
            // Index changes are disjoint and sorted; those wholly before this
            // block form a prefix whose size changes shift its index span.
            while let Some(prior) = index_runs.get(prior_cursor) {
                if prior.old_end <= run.old_start && prior.old_start < run.old_start {
                    shift_before += size_delta(prior);
                    prior_cursor += 1;
                } else {
                    break;
                }
            }
            let start = offset(run.old_start, shift_before);
            let mut end = offset(run.old_end, shift_before);
            let mut overlaps_boundary = false;
            for prior in index_runs[prior_cursor..]
                .iter()
                .take_while(|prior| prior.old_start <= run.old_end)
            {
                // A staged insertion at a replacement's outer boundary can be an
                // index-only edit absent from this worktree block. Do not erase it.
                if prior.old_start == prior.old_end
                    && prior.old_start == run.old_start
                    && run.old_start != run.old_end
                {
                    overlaps_boundary = true;
                }
                if prior.old_start >= run.old_start
                    && prior.old_end <= run.old_end
                    && (prior.old_start < run.old_end || run.old_start == run.old_end)
                {
                    end = offset(end, size_delta(prior));
                } else if prior.old_start < run.old_end && prior.old_end > run.old_start {
                    overlaps_boundary = true;
                }
            }
            let before = &head_lines[run.old_start..run.old_end];
            let after = &worktree_lines[run.new_start..run.new_end];
            let span = index_lines.get(start..end).unwrap_or_default();
            let checked = span == after;
            let indeterminate = !checked && span != before;
            let include = replacement_patch(&header, &index_lines, start, end, after);
            let exclude = replacement_patch(&header, &index_lines, start, end, before);
            let rollback =
                replacement_patch(&header, &worktree_lines, run.new_start, run.new_end, span);
            // The checkbox includes an unchecked or partial block and excludes a checked one.
            let toggle_patch = if checked {
                exclude.is_some()
            } else {
                include.is_some()
            };
            let consistent = end <= index_lines.len();
            let rollback_candidate =
                writable && consistent && !overlaps_boundary && !checked && rollback.is_some();
            DiffBlock {
                id: run.id(),
                checked,
                indeterminate,
                can_toggle: writable && consistent && !overlaps_boundary && toggle_patch,
                can_rollback: rollback_candidate && rollback_safe,
                whole_file: false,
                include,
                exclude,
                rollback,
                rollback_candidate,
            }
        })
        .collect();
    Some(blocks)
}

fn size_delta(run: &ChangeRun) -> isize {
    (run.new_end - run.new_start) as isize - (run.old_end - run.old_start) as isize
}

fn offset(position: usize, delta: isize) -> usize {
    position.saturating_add_signed(delta)
}

// ---------------------------------------------------------------------------
// Repository reads and commands
// ---------------------------------------------------------------------------

fn complete_file_request(root: &str, pathspecs: Vec<String>) -> GitDiffRequest {
    GitDiffRequest {
        root: root.to_string(),
        stash_reference: None,
        include_file_sections: true,
        omit_file_patch: false,
        pathspecs,
        reference: None,
        empty_tree_base: false,
        git_reference: None,
        target_git_reference: None,
        commit: None,
        staged: false,
        untracked: false,
        worktree_snapshot: false,
        context_lines: FULL_FILE_CONTEXT_LINES,
        ignore_all_whitespace: false,
    }
}

/// Reads one complete-file section; prefers the section named `path`.
fn read_section(
    request: GitDiffRequest,
    path: &str,
) -> Result<(Option<GitDiffFileResponse>, bool), CoreError> {
    let response = diff_impl(request)?;
    let mut files = response.files.unwrap_or_default();
    let position = files.iter().position(|file| file.path == path).unwrap_or(0);
    let file = (!files.is_empty()).then(|| files.swap_remove(position));
    Ok((file, response.has_decoding_loss))
}

fn safe_path(path: &str) -> bool {
    is_safe_pathspec(path) && !path.contains('\0')
}

/// Returns whether Git's effective attributes let a worktree patch round-trip:
/// a clean/smudge `filter` or a `working-tree-encoding` may rewrite bytes the
/// patch was computed from, so either one fails closed. `text` and `eol` are
/// conversions `git apply` performs itself and stay allowed.
pub(super) fn worktree_attributes_safe(root: &str, paths: &[String]) -> Result<bool, CoreError> {
    if paths.is_empty() || !paths.iter().all(|path| safe_path(path)) {
        return Ok(false);
    }
    let mut arguments = vec![
        "check-attr".to_string(),
        "-z".to_string(),
        "filter".to_string(),
        "working-tree-encoding".to_string(),
        "--".to_string(),
    ];
    arguments.extend(paths.iter().cloned());
    let output = execute_git_readonly(root, &arguments, None)?;
    if output.exit_code != 0 {
        return Ok(false);
    }
    let fields = output.stdout.split('\0').collect::<Vec<_>>();
    let mut reported = 0;
    for record in fields.chunks_exact(3) {
        if record[1] == "filter" || record[1] == "working-tree-encoding" {
            reported += 1;
            if record[2] != "unspecified" && record[2] != "unset" {
                return Ok(false);
            }
        }
    }
    // A missing record means the check itself is unreliable.
    Ok(reported == paths.len() * 2)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BlockTarget {
    root: String,
    path: String,
    #[serde(default)]
    original_path: Option<String>,
    /// Review the index (HEAD -> index) instead of the worktree.
    #[serde(default)]
    staged: bool,
}

/// One complete read of the files a commit review compares.
struct BlockSnapshot {
    worktree: Option<GitDiffFileResponse>,
    index: Option<GitDiffFileResponse>,
    decoding_loss: bool,
    rollback_safe: bool,
    token: String,
}

impl BlockSnapshot {
    fn read(target: &BlockTarget, root: &str) -> Result<Self, CoreError> {
        let mut pathspecs = Vec::new();
        for path in target.original_path.iter().chain([&target.path]) {
            if !safe_path(path) {
                return Err(invalid("Git diff contains an invalid path"));
            }
            if !pathspecs.contains(path) {
                pathspecs.push(path.clone());
            }
        }
        let mut staged = complete_file_request(root, vec![target.path.clone()]);
        staged.staged = true;
        let (index, index_loss) = read_section(staged, &target.path)?;
        let (worktree, worktree_loss) = if target.staged {
            (index.clone(), index_loss)
        } else {
            let mut request = complete_file_request(root, pathspecs.clone());
            request.worktree_snapshot = true;
            read_section(request, &target.path)?
        };
        let rollback_safe = !target.staged && worktree_attributes_safe(root, &pathspecs)?;
        let mut digest = Sha256::new();
        for file in [&worktree, &index] {
            match file {
                Some(file) => {
                    digest.update(file.status.as_bytes());
                    digest.update([0]);
                    digest.update(file.patch.as_bytes());
                }
                None => digest.update(b"-"),
            }
            digest.update([0]);
        }
        let token = digest
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        Ok(Self {
            worktree,
            index,
            decoding_loss: worktree_loss || index_loss,
            rollback_safe,
            token,
        })
    }

    fn blocks(&self) -> Vec<DiffBlock> {
        let Some(worktree) = &self.worktree else {
            return Vec::new();
        };
        fn side(file: &GitDiffFileResponse) -> PlanSide<'_> {
            PlanSide {
                patch: &file.patch,
                status: &file.status,
                is_binary: file.is_binary,
            }
        }
        plan_blocks(
            side(worktree),
            self.index.as_ref().map(side),
            !self.decoding_loss,
            self.rollback_safe,
        )
        .unwrap_or_default()
    }
}

/// Response section for one side: the display document without patch text.
fn section_value(file: Option<GitDiffFileResponse>, decoding_loss: bool) -> Value {
    let files = file
        .map(|mut file| {
            file.patch = String::new();
            file.hunks = Vec::new();
            vec![file]
        })
        .unwrap_or_default();
    json!({ "hasDecodingLoss": decoding_loss, "files": files })
}

/// Plans commit-review blocks for one file (`git.planDiffBlocks`).
pub(crate) fn plan_diff_blocks_command(payload: Value) -> Result<Value, CoreError> {
    let target: BlockTarget =
        serde_json::from_value(payload).map_err(|_| invalid("Invalid Git diff block request"))?;
    let root = validate_root(&target.root)?;
    let snapshot = BlockSnapshot::read(&target, &root)?;
    let blocks = snapshot.blocks();
    let decoding_loss = snapshot.decoding_loss;
    Ok(json!({
        "token": snapshot.token,
        "blocks": blocks,
        "worktree": section_value(snapshot.worktree, decoding_loss),
        "index": section_value(snapshot.index, decoding_loss),
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApplyBlockRequest {
    #[serde(flatten)]
    target: BlockTarget,
    #[serde(default)]
    block_id: String,
    /// `include`, `exclude`, `rollback`, or the whole-file `includeFile` / `excludeFile`.
    action: String,
    /// Token returned by the `git.planDiffBlocks` result the user acted on.
    token: String,
}

/// Applies one planned block action (`git.applyDiffBlock`). The plan is rebuilt
/// under the write lease; a different token means the file, the index or the
/// attributes changed after the user saw the block, so nothing is written.
pub(crate) fn apply_diff_block_command(payload: Value) -> Result<Value, CoreError> {
    let request: ApplyBlockRequest =
        serde_json::from_value(payload).map_err(|_| invalid("Invalid Git diff block request"))?;
    let root = validate_root(&request.target.root)?;
    let _lease = RewriteLease::acquire(&root)?;
    let snapshot = BlockSnapshot::read(&request.target, &root)?;
    if snapshot.token != request.token {
        return Err(invalid(DIFF_BLOCK_STALE));
    }
    // Whole-file inclusion needs no block, but it is still bound to the token:
    // a file that changed since the user saw it is never staged or unstaged.
    if matches!(request.action.as_str(), "includeFile" | "excludeFile") {
        let paths = request
            .target
            .original_path
            .iter()
            .chain([&request.target.path])
            .cloned()
            .collect::<Vec<_>>();
        let response = if request.action == "includeFile" {
            super::stage_paths(&root, &paths)?
        } else {
            super::unstage_paths(&root, &paths)?
        };
        return serde_json::to_value(response)
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "Could not encode Git response"));
    }
    let block = snapshot
        .blocks()
        .into_iter()
        .find(|block| block.id == request.block_id)
        .ok_or_else(|| invalid(DIFF_BLOCK_STALE))?;
    if block.whole_file {
        return Err(invalid(DIFF_BLOCK_UNAVAILABLE));
    }
    let (patch, arguments) = match request.action.as_str() {
        "include" | "exclude" if !block.can_toggle => return Err(invalid(DIFF_BLOCK_UNAVAILABLE)),
        "include" => (block.include, vec!["apply", "--cached"]),
        "exclude" => (block.exclude, vec!["apply", "--cached"]),
        "rollback" if block.rollback_candidate && !snapshot.rollback_safe => {
            return Err(invalid(HUNK_ROLLBACK_UNSAFE))
        }
        "rollback" if !block.can_rollback => return Err(invalid(DIFF_BLOCK_UNAVAILABLE)),
        "rollback" => (block.rollback, vec!["apply"]),
        _ => return Err(invalid("Unsupported Git diff block action")),
    };
    let patch = patch.ok_or_else(|| invalid(DIFF_BLOCK_UNAVAILABLE))?;
    run_apply(&root, arguments, patch)
}

fn run_apply(root: &str, arguments: Vec<&str>, patch: String) -> Result<Value, CoreError> {
    let mut arguments = arguments
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>();
    arguments.push("--whitespace=nowarn".to_string());
    let response = command(GitCommandRequest {
        root: root.to_string(),
        arguments,
        input: Some(patch),
    })?;
    serde_json::to_value(response)
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Could not encode Git apply response"))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GutterChangeRequest {
    root: String,
    path: String,
    /// One-based, end-exclusive index line range the editor compared.
    original_start: usize,
    original_end: usize,
    /// One-based, end-exclusive editor line range of the same change.
    modified_start: usize,
    modified_end: usize,
    /// Index lines the editor showed for the change, without line breaks.
    original_lines: Vec<String>,
    /// Editor lines of the change, without line breaks.
    modified_lines: Vec<String>,
}

fn displayed(lines: &[RawLine], start: usize, end: usize, expected: &[String]) -> bool {
    start >= 1
        && start <= end
        && end - 1 <= lines.len()
        && lines[start - 1..end - 1]
            .iter()
            .map(RawLine::display)
            .eq(expected.iter().map(String::as_str))
}

/// Stages one editor gutter change (`git.stageGutterChange`). The editor sends
/// what it compared; Core re-reads the index -> worktree patch under the lease,
/// confirms both sides still show those lines and stages them with the
/// original bytes, so a moved index or an unsaved edit is never staged.
pub(crate) fn stage_gutter_change_command(payload: Value) -> Result<Value, CoreError> {
    let request: GutterChangeRequest = serde_json::from_value(payload)
        .map_err(|_| invalid("Invalid Git gutter change request"))?;
    if !safe_path(&request.path) {
        return Err(invalid("Git diff contains an invalid path"));
    }
    let root = validate_root(&request.root)?;
    let _lease = RewriteLease::acquire(&root)?;
    let (file, decoding_loss) = read_section(
        complete_file_request(&root, vec![request.path.clone()]),
        &request.path,
    )?;
    let file = file
        .filter(|file| file.path == request.path && file.status == "M" && !file.is_binary)
        .ok_or_else(|| invalid(GUTTER_CHANGE_STALE))?;
    if decoding_loss {
        return Err(invalid(DIFF_BLOCK_UNAVAILABLE));
    }
    let document = SingleHunkDocument::parse_complete(&file.patch)
        .ok_or_else(|| invalid(GUTTER_CHANGE_STALE))?;
    let (index_lines, worktree_lines) = (document.old(), document.new());
    if !displayed(
        &index_lines,
        request.original_start,
        request.original_end,
        &request.original_lines,
    ) || !displayed(
        &worktree_lines,
        request.modified_start,
        request.modified_end,
        &request.modified_lines,
    ) {
        return Err(invalid(GUTTER_CHANGE_STALE));
    }
    let header = document
        .content_header()
        .ok_or_else(|| invalid(DIFF_BLOCK_UNAVAILABLE))?;
    let patch = replacement_patch(
        &header,
        &index_lines,
        request.original_start - 1,
        request.original_end - 1,
        &worktree_lines[request.modified_start - 1..request.modified_end - 1],
    )
    .ok_or_else(|| invalid(DIFF_BLOCK_UNAVAILABLE))?;
    run_apply(&root, vec!["apply", "--cached"], patch)
}

#[cfg(test)]
pub(crate) mod fixture_support {
    //! Pure entry points the shared fixture tests exercise without a repository.

    use super::*;

    /// Plans fixture blocks and exposes the Core-owned patches for assertions.
    pub(crate) fn plan(
        worktree: (&str, &str),
        index: Option<(&str, &str)>,
        writable: bool,
        rollback_safe: bool,
    ) -> Option<Vec<Value>> {
        let worktree = PlanSide {
            patch: worktree.1,
            status: worktree.0,
            is_binary: false,
        };
        let index = index.map(|(status, patch)| PlanSide {
            patch,
            status,
            is_binary: false,
        });
        plan_blocks(worktree, index, writable, rollback_safe).map(|blocks| {
            blocks
                .into_iter()
                .map(|block| {
                    let mut value = serde_json::to_value(&block).expect("block should encode");
                    value["include"] = json!(block.include);
                    value["exclude"] = json!(block.exclude);
                    value["rollback"] = json!(block.rollback);
                    value
                })
                .collect()
        })
    }

    /// Splits a complete-file section into Git-default hunks.
    pub(crate) fn hunks(section: &str) -> Option<Vec<GitDiffHunkResponse>> {
        stageable_hunks(section)
    }
}
