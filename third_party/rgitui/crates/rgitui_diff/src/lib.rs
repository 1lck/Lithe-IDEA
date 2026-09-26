#[cfg(feature = "perf")]
mod heap_size;

use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::{Hash, Hasher};
use std::ops::Range;
use std::path::Path;
use std::sync::{Arc, OnceLock};

use similar::{capture_diff_slices, Algorithm};

use gpui::prelude::*;
use gpui::{
    div, list, px, uniform_list, AnyElement, App, ClickEvent, ClipboardItem, Context, CursorStyle,
    ElementId, EventEmitter, FocusHandle, FontStyle, FontWeight, HighlightStyle, ListAlignment,
    ListHorizontalSizingBehavior, ListSizingBehavior, ListState, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, Render, ScrollStrategy, SharedString, StyledText,
    UniformListScrollHandle, WeakEntity, Window,
};
use rgitui_git::{
    ConflictSnapshot, DiffLine, FileDiff, MergeSection, ThreeWayFileDiff, WorktreePatchDirection,
    WorktreePatchScope, WorktreePatchSource,
};
use rgitui_theme::{ActiveTheme, Appearance, Color, StyledExt, ThemeState};
use rgitui_ui::{
    Badge, Button, ButtonSize, ButtonStyle, EstimatedListScroll, Icon, IconName, IconSize, Label,
    LabelSize, Scrollbar, Spinner,
};
use syntect::highlighting::{
    FontStyle as SyntectFontStyle, HighlightIterator, HighlightState, Highlighter, Theme, ThemeSet,
};
use syntect::parsing::{ParseState, ScopeStack, SyntaxReference, SyntaxSet};

/// Line numbers for a single selected line: (old_file_line, new_file_line).
/// old_file_line is None for additions (new lines), new_file_line is None for deletions.
pub type LineSelection = Vec<(Option<usize>, Option<usize>)>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffViewerEvent {
    /// The displayed file changed. Workspace listeners use this to start
    /// blame/history prefetching for every path into the diff viewer.
    DiffChanged {
        path: String,
        commit_id: Option<String>,
        generation: u64,
    },
    HunkStageRequested(usize),
    HunkUnstageRequested(usize),
    /// Request to stage only the given lines within the current file's diff.
    /// Args: (old_file_line_nums, new_file_line_nums) — one entry per selected line.
    LineStageRequested(Vec<(Option<usize>, Option<usize>)>),
    /// Request to unstage only the given lines within the current staged diff.
    LineUnstageRequested(Vec<(Option<usize>, Option<usize>)>),
    /// Request to write the displayed source's content into the working tree
    /// (`Apply`) or take it back out (`Revert`), over `scope`.
    ///
    /// `scope` carries all three granularities — hunk, line selection, whole
    /// file — because the handler treats them alike: resolve the source to a
    /// tree pair and hand the scope to the git layer.
    WorktreePatchRequested {
        /// Always [`DiffOperation::Apply`] or [`DiffOperation::Revert`].
        operation: DiffOperation,
        scope: WorktreePatchScope,
    },
    /// A conflict resolver action. Unlike ordinary staging requests, each
    /// variant carries the exact path and/or repository snapshot it was built
    /// from so the git layer can reject stale work.
    ConflictResolutionRequested(ConflictResolution),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictResolution {
    SaveMerged {
        path: String,
        content: Vec<u8>,
        mode: u32,
        snapshot: ConflictSnapshot,
    },
    UseOurs {
        path: String,
        snapshot: ConflictSnapshot,
    },
    UseTheirs {
        path: String,
        snapshot: ConflictSnapshot,
    },
    StageWorkingTree {
        path: String,
        snapshot: ConflictSnapshot,
    },
    OpenInEditor {
        path: String,
    },
}

impl DiffViewerEvent {
    /// The request `operation` raises against hunk `index`.
    ///
    /// The single mapping from operation to event, so a hunk-header button and a
    /// key binding for the same operation cannot disagree.
    pub fn for_hunk(operation: DiffOperation, index: usize) -> Self {
        match operation {
            DiffOperation::Stage => DiffViewerEvent::HunkStageRequested(index),
            DiffOperation::Unstage => DiffViewerEvent::HunkUnstageRequested(index),
            DiffOperation::Apply | DiffOperation::Revert => {
                DiffViewerEvent::WorktreePatchRequested {
                    operation,
                    scope: WorktreePatchScope::Hunk(index),
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DiffDisplayMode {
    #[default]
    Unified,
    SideBySide,
    ThreeWay,
}

/// An operation the diff viewer can offer over the content it is showing.
///
/// Which of these are available is a property of the content's provenance
/// alone, and [`DiffSource::operations`] is the single place that decides it.
/// A mutable working-tree source can be staged or unstaged; content from
/// anywhere else — a commit, a stash, a comparison of two revisions — cannot,
/// but its changes can be applied to or reverted in the working tree, which are
/// the hunk-level equivalents of a cherry-pick and a revert.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DiffOperation {
    /// Move working-tree content into the index.
    Stage,
    /// Move index content back out to the working tree.
    Unstage,
    /// Write this source's version of the content into the working tree.
    Apply,
    /// Take this source's change back out of the working tree.
    Revert,
}

impl DiffOperation {
    /// Label for the per-hunk button in the diff viewer's hunk headers.
    pub fn hunk_button_label(self) -> &'static str {
        match self {
            DiffOperation::Stage => "Stage Hunk",
            DiffOperation::Unstage => "Unstage Hunk",
            DiffOperation::Apply => "Apply Hunk",
            DiffOperation::Revert => "Revert Hunk",
        }
    }

    /// Short label used inside the already-scoped hunk header.
    pub fn compact_hunk_button_label(self) -> &'static str {
        match self {
            DiffOperation::Stage => "Stage",
            DiffOperation::Unstage => "Unstage",
            DiffOperation::Apply => "Apply",
            DiffOperation::Revert => "Revert",
        }
    }

    /// Label for the whole-file entry in the diff viewer's file menu.
    pub fn file_menu_label(self) -> &'static str {
        match self {
            DiffOperation::Stage => "Stage File",
            DiffOperation::Unstage => "Unstage File",
            DiffOperation::Apply => "Apply File to Working Tree",
            DiffOperation::Revert => "Revert File in Working Tree",
        }
    }

    /// The *default* key that invokes this operation while the diff viewer has
    /// focus, for hints and element ids.
    ///
    /// A hint rather than a lookup: the binding lives in the `commands!` registry
    /// in `rgitui_workspace`, which sits above this crate and so cannot be named
    /// from here, and the user may have rebound it.
    pub fn key(self) -> &'static str {
        match self {
            DiffOperation::Stage => "s",
            DiffOperation::Unstage => "u",
            DiffOperation::Apply => "a",
            DiffOperation::Revert => "r",
        }
    }

    /// True for the two operations that move content between the working tree
    /// and the index without editing any file.
    pub fn is_staging(self) -> bool {
        matches!(self, DiffOperation::Stage | DiffOperation::Unstage)
    }

    /// True for the two operations that rewrite files on disk. Callers must put
    /// these on the undo stack, since nothing else records the previous contents.
    pub fn writes_files(self) -> bool {
        matches!(self, DiffOperation::Apply | DiffOperation::Revert)
    }

    /// The git-layer direction this operation runs in, or `None` for the two
    /// staging operations, which do not go through the patch machinery.
    pub fn patch_direction(self) -> Option<WorktreePatchDirection> {
        match self {
            DiffOperation::Stage | DiffOperation::Unstage => None,
            DiffOperation::Apply => Some(WorktreePatchDirection::Apply),
            DiffOperation::Revert => Some(WorktreePatchDirection::Revert),
        }
    }
}

/// Where the content currently shown in the diff viewer came from.
///
/// Staged versus unstaged is a property of the two mutable sources only. A
/// commit, stash or revision pair has no such distinction — its content is
/// already recorded — so it carries the revision it came from instead, and
/// offers no staging.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum DiffSource {
    /// Unstaged working-tree changes (index → workdir). Can be staged.
    Worktree,
    /// Staged changes (HEAD → index). Can be unstaged.
    Index,
    /// A file inside a commit, identified by its hex OID.
    Commit(String),
    /// A file inside a stash entry, identified by the stash commit's hex OID.
    Stash(String),
    /// The difference between two arbitrary revisions, `from` → `to`, as any
    /// branch-comparison view would produce. Applying brings `to`'s content
    /// into the working tree; reverting restores `from`'s.
    ///
    /// A commit diff carries [`Self::Commit`] rather than this, so that it can be
    /// identified by OID for caching and blame; both resolve to a tree pair in
    /// [`Self::patch_source`], so apply and revert treat them identically.
    Compare { from: String, to: String },
}

impl DiffSource {
    /// Build the matching mutable source from the sidebar's `staged` flag.
    pub fn working_tree(staged: bool) -> Self {
        if staged {
            DiffSource::Index
        } else {
            DiffSource::Worktree
        }
    }

    /// Every operation this content supports, in the order the UI offers them.
    pub fn operations(&self) -> &'static [DiffOperation] {
        match self {
            DiffSource::Worktree => &[DiffOperation::Stage],
            DiffSource::Index => &[DiffOperation::Unstage],
            DiffSource::Commit(_) | DiffSource::Stash(_) | DiffSource::Compare { .. } => {
                &[DiffOperation::Apply, DiffOperation::Revert]
            }
        }
    }

    /// Whether `operation` is available for this content.
    pub fn offers(&self, operation: DiffOperation) -> bool {
        self.operations().contains(&operation)
    }

    /// The staging operation this content supports, or `None` when it is not
    /// mutable working-tree content.
    pub fn staging_action(&self) -> Option<DiffOperation> {
        self.operations()
            .iter()
            .copied()
            .find(|operation| operation.is_staging())
    }

    /// True when the content is a snapshot from outside the working tree, so it
    /// has no staged/unstaged distinction and cannot be staged or unstaged.
    pub fn is_historical(&self) -> bool {
        self.staging_action().is_none()
    }

    /// The commit-like OID backing this content, if any. Used for the display
    /// cache key, the `DiffChanged` payload, and blame/history view caching.
    ///
    /// A comparison has no single commit to attribute lines to — its endpoints
    /// may be branch names rather than OIDs — so it reports `None` and is
    /// treated like working-tree content by the blame/history prefetch.
    pub fn commit_id(&self) -> Option<&str> {
        match self {
            DiffSource::Worktree | DiffSource::Index | DiffSource::Compare { .. } => None,
            DiffSource::Commit(oid) | DiffSource::Stash(oid) => Some(oid),
        }
    }

    /// Short label naming the revision (or pair) this content came from, for
    /// menu entries and tooltips. `None` for working-tree content, which has no
    /// revision to name.
    pub fn revision_label(&self) -> Option<String> {
        match self {
            DiffSource::Worktree | DiffSource::Index => None,
            DiffSource::Commit(oid) | DiffSource::Stash(oid) => {
                Some(oid[..7.min(oid.len())].to_string())
            }
            DiffSource::Compare { from, to } => Some(format!("{from}...{to}")),
        }
    }

    /// The tree pair an apply or revert should be generated from, or `None` for
    /// working-tree content, which supports staging instead.
    pub fn patch_source(&self) -> Option<WorktreePatchSource> {
        match self {
            DiffSource::Worktree | DiffSource::Index => None,
            DiffSource::Commit(oid) | DiffSource::Stash(oid) => git2::Oid::from_str(oid)
                .ok()
                .map(WorktreePatchSource::Commit),
            DiffSource::Compare { from, to } => Some(WorktreePatchSource::Compare {
                from: from.clone(),
                to: to.clone(),
            }),
        }
    }

    /// Why `requested` cannot be performed on this content, as an actionable
    /// sentence, or `None` when the request is valid.
    ///
    /// The viewer already hides the affordances that would produce an invalid
    /// request, so this is a backstop for the case where the displayed content
    /// changes between a click being painted and being delivered.
    pub fn reject_operation(&self, requested: DiffOperation) -> Option<String> {
        if self.offers(requested) {
            return None;
        }
        match (self, requested) {
            (DiffSource::Worktree, DiffOperation::Unstage) => {
                Some("These changes are not staged yet — press s to stage them first.".to_string())
            }
            (DiffSource::Index, DiffOperation::Stage) => {
                Some("These changes are already staged — press u to unstage them.".to_string())
            }
            // A mutable source asked to apply or revert: that content is
            // already in the working tree, so there is nothing to bring in.
            (DiffSource::Worktree | DiffSource::Index, _) => Some(
                "These changes are already in your working tree — use s or u to move them \
                 between the index and the working tree."
                    .to_string(),
            ),
            (DiffSource::Commit(oid), _) => Some(format!(
                "Commit {} is already committed and cannot be staged — press a to apply its \
                 changes to your working tree, or select the file under Staged or Unstaged in \
                 the sidebar.",
                &oid[..7.min(oid.len())]
            )),
            (DiffSource::Stash(_), _) => Some(
                "Stashed changes cannot be staged directly — press a to apply them to your \
                 working tree, or pop the stash and stage it from the sidebar."
                    .to_string(),
            ),
            (DiffSource::Compare { from, to }, _) => Some(format!(
                "{from}...{to} is a comparison of two revisions and cannot be staged — press a \
                 to apply its changes to your working tree instead."
            )),
        }
    }

    /// Badge shown in the diff viewer header. Content from outside the working
    /// tree is labelled by its origin rather than by a staged/unstaged state it
    /// does not have.
    pub fn badge(&self) -> (&'static str, Color) {
        match self {
            DiffSource::Worktree => ("Unstaged", Color::Modified),
            DiffSource::Index => ("Staged", Color::Added),
            DiffSource::Commit(_) => ("Committed", Color::Muted),
            DiffSource::Stash(_) => ("Stashed", Color::Muted),
            DiffSource::Compare { .. } => ("Compared", Color::Muted),
        }
    }
}

#[derive(Clone)]
enum DisplayRow {
    HunkHeader {
        header: String,
        context_name: String,
        hunk_index: usize,
    },
    Line {
        old_num: Option<usize>,
        new_num: Option<usize>,
        styled: StyledLine,
        kind: DisplayLineKind,
    },
}

#[derive(Clone)]
enum SideBySideRow {
    HunkHeader {
        header: String,
        context_name: String,
        hunk_index: usize,
    },
    Pair {
        left_num: Option<usize>,
        left_styled: StyledLine,
        left_kind: SideBySideLineKind,
        right_num: Option<usize>,
        right_styled: StyledLine,
        right_kind: SideBySideLineKind,
    },
}

#[derive(Clone, Copy, PartialEq)]
enum SideBySideLineKind {
    Context,
    Addition,
    Deletion,
    Empty,
}

#[derive(Clone, Copy, PartialEq)]
enum ThreeWayLineKind {
    Unchanged,
    Conflict,
    Resolved,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConflictChoice {
    Ours,
    Theirs,
    BothOursFirst,
    BothTheirsFirst,
}

fn assemble_text_resolution(
    diff: &ThreeWayFileDiff,
    choices: &[Option<ConflictChoice>],
) -> Option<Vec<u8>> {
    if !diff.supports_text_resolution() || choices.len() != diff.conflict_count() {
        return None;
    }

    let mut content = Vec::new();
    let mut conflict_index = 0;
    for section in &diff.sections {
        match section {
            MergeSection::Resolved(bytes) => content.extend_from_slice(bytes),
            MergeSection::Conflict { ours, theirs, .. } => {
                match choices.get(conflict_index).copied().flatten()? {
                    ConflictChoice::Ours => content.extend_from_slice(ours),
                    ConflictChoice::Theirs => content.extend_from_slice(theirs),
                    ConflictChoice::BothOursFirst => {
                        content.extend_from_slice(ours);
                        content.extend_from_slice(theirs);
                    }
                    ConflictChoice::BothTheirsFirst => {
                        content.extend_from_slice(theirs);
                        content.extend_from_slice(ours);
                    }
                }
                conflict_index += 1;
            }
        }
    }
    Some(content)
}

fn conflict_progress_label(unresolved: usize, total: usize) -> String {
    match (unresolved, total) {
        (0, total) => format!("All {total} resolved"),
        (unresolved, total) if unresolved == total => format!("{total} unresolved"),
        (unresolved, total) => {
            format!("{} resolved · {unresolved} remaining", total - unresolved)
        }
    }
}

fn next_line_number(counter: &mut usize, present: bool) -> Option<usize> {
    present.then(|| {
        let number = *counter;
        *counter += 1;
        number
    })
}

#[derive(Clone)]
enum ThreeWayRow {
    HunkHeader {
        header: String,
        context_name: String,
        conflict_index: usize,
        resolved: bool,
        allow_both: bool,
    },
    Triple {
        left_num: Option<usize>,
        left_styled: StyledLine,
        left_kind: ThreeWayLineKind,
        mid_num: Option<usize>,
        mid_styled: StyledLine,
        mid_kind: ThreeWayLineKind,
        right_num: Option<usize>,
        right_styled: StyledLine,
        right_kind: ThreeWayLineKind,
    },
}

#[derive(Clone, Copy)]
enum DisplayLineKind {
    Context,
    Addition,
    Deletion,
}

#[derive(Clone, Default)]
struct StyledLine {
    text: SharedString,
    highlights: Vec<(Range<usize>, HighlightStyle)>,
}

impl StyledLine {
    fn plain(text: impl Into<SharedString>) -> Self {
        Self {
            text: text.into(),
            highlights: Vec::new(),
        }
    }

    /// Merge word-level highlight spans into the existing highlights list.
    /// `deletion_spans` are byte ranges of deleted words (highlighted red).
    /// `addition_spans` are byte ranges of inserted words (highlighted green).
    ///
    /// Spans are clipped to `self.text.len()` and then merged into the
    /// existing (sorted, non-overlapping) syntect highlights.  GPUI's
    /// `compute_runs` requires the final list to be sorted by position and
    /// non-overlapping; simply appending would violate that invariant when
    /// syntect already covers the full text, causing a panic.
    ///
    /// For overlapping regions the syntect foreground colour is preserved
    /// alongside the word-level background colour.
    fn apply_word_highlights(
        &mut self,
        deletion_spans: Vec<Range<usize>>,
        addition_spans: Vec<Range<usize>>,
        deleted_word_bg: HighlightStyle,
        added_word_bg: HighlightStyle,
    ) {
        let text_len = self.text.len();
        if text_len == 0 {
            return;
        }

        // Collect all word spans with their styles, clipped to text bounds.
        let mut word_spans: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
        for span in deletion_spans {
            let start = span.start.min(text_len);
            let end = span.end.min(text_len);
            if start < end {
                word_spans.push((start..end, deleted_word_bg));
            }
        }
        for span in addition_spans {
            let start = span.start.min(text_len);
            let end = span.end.min(text_len);
            if start < end {
                word_spans.push((start..end, added_word_bg));
            }
        }

        if word_spans.is_empty() {
            return;
        }

        word_spans.sort_by_key(|s| s.0.start);

        if self.highlights.is_empty() {
            // No existing syntax highlights — use word spans directly.
            self.highlights = word_spans;
            return;
        }

        // Merge word spans into existing syntect highlights by splitting
        // syntect spans at word-span boundaries and combining styles for
        // overlapping regions.
        let existing = std::mem::take(&mut self.highlights);
        let mut merged: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
        let mut wi = 0;

        for (syn_range, syn_style) in &existing {
            let mut pos = syn_range.start;

            while pos < syn_range.end {
                // Advance past word spans already fully consumed.
                while wi < word_spans.len() && word_spans[wi].0.end <= pos {
                    wi += 1;
                }

                if wi >= word_spans.len() || word_spans[wi].0.start >= syn_range.end {
                    // No more word spans overlap this remainder.
                    merged.push((pos..syn_range.end, *syn_style));
                    break;
                }

                let (ref w_range, w_style) = word_spans[wi];

                if w_range.start > pos {
                    // Syntect-only gap before the word span.
                    let gap_end = w_range.start.min(syn_range.end);
                    merged.push((pos..gap_end, *syn_style));
                    pos = gap_end;
                } else {
                    // Overlap: combine syntect style with word background.
                    let overlap_end = w_range.end.min(syn_range.end);
                    let mut combined = *syn_style;
                    if w_style.background_color.is_some() {
                        combined.background_color = w_style.background_color;
                    }
                    if w_style.color.is_some() {
                        combined.color = w_style.color;
                    }
                    merged.push((pos..overlap_end, combined));
                    pos = overlap_end;
                }
            }
        }

        self.highlights = merged;
    }
}

struct SyntaxAssets {
    syntax_set: SyntaxSet,
    theme_set: ThemeSet,
}

enum SyntaxLineHighlighter {
    Plain,
    Syntect {
        syntax_set: &'static SyntaxSet,
        syntax: &'static SyntaxReference,
        /// Built once per theme rather than per line.
        ///
        /// `HighlightLines::new` looks cheap and is not: it constructs a
        /// `Highlighter`, which walks every scope selector in the theme into two
        /// vectors and sorts one of them. Doing that per diff line put a
        /// 100-200 element sort in front of every line of every diff. The
        /// `Highlighter` is a pure function of the theme, so it is shared; only
        /// the parse and highlight state have to be per line.
        highlighter: &'static Highlighter<'static>,
    },
}

/// Cache key for pre-computed display rows. The `source` distinguishes the two
/// mutable working-tree variants from each other and from any commit or stash;
/// mutable content additionally carries a fingerprint of the full `FileDiff`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct DisplayCacheKey {
    file_path: String,
    is_dark: bool,
    source: DiffSource,
    content_fingerprint: u64,
}

impl DisplayCacheKey {
    fn new(file_path: String, is_dark: bool, source: DiffSource, diff: &FileDiff) -> Self {
        Self {
            file_path,
            is_dark,
            source,
            content_fingerprint: file_diff_fingerprint(diff),
        }
    }
}

/// Hash every field that affects rendered diff rows. The cache also stores and
/// compares the source `FileDiff`, so a theoretical hash collision is a cache
/// miss rather than stale rendered content.
fn file_diff_fingerprint(diff: &FileDiff) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    diff.path.hash(&mut hasher);
    diff.kind.hash(&mut hasher);
    diff.additions.hash(&mut hasher);
    diff.deletions.hash(&mut hasher);
    diff.hunks.len().hash(&mut hasher);
    for hunk in &diff.hunks {
        hunk.old_start.hash(&mut hasher);
        hunk.old_lines.hash(&mut hasher);
        hunk.new_start.hash(&mut hasher);
        hunk.new_lines.hash(&mut hasher);
        hunk.header.hash(&mut hasher);
        hunk.lines.len().hash(&mut hasher);
        for line in &hunk.lines {
            std::mem::discriminant(line).hash(&mut hasher);
            match line {
                DiffLine::Context(text) | DiffLine::Addition(text) | DiffLine::Deletion(text) => {
                    text.hash(&mut hasher);
                }
            }
        }
    }
    hasher.finish()
}

/// Pre-computed display rows cached to avoid redundant syntax highlighting.
struct CachedDisplayRows {
    display_rows: Arc<Vec<DisplayRow>>,
    sbs_rows: Arc<Vec<SideBySideRow>>,
    display_longest_row_ix: usize,
    source_diff: Arc<FileDiff>,
}

struct CachedDisplayRowsHit {
    display_rows: Arc<Vec<DisplayRow>>,
    sbs_rows: Arc<Vec<SideBySideRow>>,
    display_longest_row_ix: usize,
}

struct PreparedDisplayRows {
    display_rows: Arc<Vec<DisplayRow>>,
    sbs_rows: Arc<Vec<SideBySideRow>>,
    display_longest_row_ix: usize,
}

const DISPLAY_CACHE_MAX_ENTRIES: usize = 50;
/// Approximate memory bound expressed in prepared rows. It complements the
/// entry cap so a handful of unusually large diffs cannot dominate the cache.
const DISPLAY_CACHE_MAX_ROWS: usize = 200_000;

#[derive(Default)]
struct DisplayCache {
    entries: HashMap<DisplayCacheKey, CachedDisplayRows>,
    recency: VecDeque<DisplayCacheKey>,
    total_rows: usize,
}

impl DisplayCache {
    fn clear(&mut self) {
        self.entries.clear();
        self.recency.clear();
        self.total_rows = 0;
    }

    fn get(&mut self, key: &DisplayCacheKey, diff: &FileDiff) -> Option<CachedDisplayRowsHit> {
        let matches = self
            .entries
            .get(key)
            .is_some_and(|cached| cached.source_diff.as_ref() == diff);
        if !matches {
            // Remove a theoretical fingerprint collision rather than allowing
            // it to replace or return rows for different source content.
            self.remove(key);
            return None;
        }

        let cached = self.entries.get(key)?;
        let result = CachedDisplayRowsHit {
            display_rows: Arc::clone(&cached.display_rows),
            sbs_rows: Arc::clone(&cached.sbs_rows),
            display_longest_row_ix: cached.display_longest_row_ix,
        };
        self.touch(key);
        Some(result)
    }

    fn insert(&mut self, key: DisplayCacheKey, value: CachedDisplayRows) {
        let row_cost = Self::row_cost(&value);
        self.remove(&key);

        // An entry larger than the entire budget is still displayed by the
        // viewer, but retaining it would immediately evict the useful cache.
        if row_cost > DISPLAY_CACHE_MAX_ROWS {
            return;
        }

        while self.entries.len() >= DISPLAY_CACHE_MAX_ENTRIES
            || self.total_rows.saturating_add(row_cost) > DISPLAY_CACHE_MAX_ROWS
        {
            let Some(oldest) = self.recency.pop_front() else {
                break;
            };
            if let Some(evicted) = self.entries.remove(&oldest) {
                self.total_rows = self.total_rows.saturating_sub(Self::row_cost(&evicted));
            }
        }

        self.total_rows += row_cost;
        self.recency.push_back(key.clone());
        self.entries.insert(key, value);
    }

    fn remove(&mut self, key: &DisplayCacheKey) {
        if let Some(removed) = self.entries.remove(key) {
            self.total_rows = self.total_rows.saturating_sub(Self::row_cost(&removed));
        }
        self.recency.retain(|existing| existing != key);
    }

    fn touch(&mut self, key: &DisplayCacheKey) {
        self.recency.retain(|existing| existing != key);
        self.recency.push_back(key.clone());
    }

    fn row_cost(value: &CachedDisplayRows) -> usize {
        value.display_rows.len() + value.sbs_rows.len()
    }
}

/// A diff viewer panel that displays file diffs with syntax coloring.
pub struct DiffViewer {
    diff: Option<Arc<FileDiff>>,
    display_mode: DiffDisplayMode,
    file_path: Option<String>,
    /// Provenance of the displayed content. Gates every staging affordance.
    source: DiffSource,
    display_rows: Arc<Vec<DisplayRow>>,
    sbs_rows: Arc<Vec<SideBySideRow>>,
    three_way_rows: Arc<Vec<ThreeWayRow>>,
    display_longest_row_ix: usize,
    three_way_diff: Option<Arc<ThreeWayFileDiff>>,
    conflict_choices: Vec<Option<ConflictChoice>>,
    scroll_handle: UniformListScrollHandle,
    /// Variable-height virtualized list state used by wrap-mode rendering.
    /// `gpui::list` caches per-row measurements in a SumTree so only the
    /// visible (plus overdraw) rows render per frame.
    wrap_list_state: ListState,
    focus_handle: FocusHandle,
    highlighted_row: Option<usize>,
    selected_lines: Option<Range<usize>>,
    /// When true, selection tracks individual lines for partial hunk staging.
    partial_mode: bool,
    selection_anchor: Option<usize>,
    mouse_selecting: bool,
    /// Tracks the current theme appearance to drive syntax highlighting.
    current_appearance: Appearance,
    /// Top item index to restore after a display mode switch.
    pending_scroll_top: Option<usize>,
    /// True while a diff is being fetched in the background. Drives the loading
    /// spinner in place of the content/placeholder states.
    loading: bool,
    /// Set when a diff fetch fails so the viewer can surface the error instead of
    /// silently falling back to the empty placeholder.
    error: Option<String>,
    /// Bounded LRU cache for computed display rows.
    display_cache: DisplayCache,
    /// Whether the header's file-level operations menu is open. It is the mouse
    /// route to whole-file apply/revert, the granularity neither the hunk headers
    /// nor a line selection can express.
    file_menu_open: bool,
    /// Bumped when the selected diff content changes. Workspace-level diff
    /// refreshes use this to reject stale repository results.
    generation: u64,
    /// Independently guards background row preparation. Theme changes and
    /// loading/error states invalidate presentation work without pretending the
    /// selected repository diff changed.
    preparation_generation: u64,
}

/// Whether two file diffs would render identically. Used to skip a refresh that
/// would only churn viewer state (cleared selection / reset scroll) with no
/// visible change. Compares the actual hunk content — not just hunk/line counts —
/// so an in-place edit that preserves counts is still detected as a change.
fn file_diffs_render_equal(a: &FileDiff, b: &FileDiff) -> bool {
    a.kind == b.kind
        && a.additions == b.additions
        && a.deletions == b.deletions
        && a.hunks == b.hunks
}

fn should_apply_prepared(current_generation: u64, prepared_generation: u64) -> bool {
    current_generation == prepared_generation
}

impl EventEmitter<DiffViewerEvent> for DiffViewer {}

impl DiffViewer {
    pub fn new(cx: &mut Context<Self>) -> Self {
        cx.observe_global::<ThemeState>(|this: &mut Self, cx| {
            this.rehighlight(cx);
        })
        .detach();

        Self {
            diff: None,
            display_mode: DiffDisplayMode::Unified,
            file_path: None,
            source: DiffSource::Worktree,
            display_rows: Arc::new(Vec::new()),
            sbs_rows: Arc::new(Vec::new()),
            three_way_rows: Arc::new(Vec::new()),
            display_longest_row_ix: 0,
            three_way_diff: None,
            conflict_choices: Vec::new(),
            scroll_handle: UniformListScrollHandle::new(),
            wrap_list_state: ListState::new(0, ListAlignment::Top, px(200.)),
            focus_handle: cx.focus_handle(),
            highlighted_row: None,
            selected_lines: None,
            partial_mode: false,
            selection_anchor: None,
            mouse_selecting: false,
            current_appearance: Appearance::Dark,
            pending_scroll_top: None,
            loading: false,
            error: None,
            display_cache: DisplayCache::default(),
            file_menu_open: false,
            generation: 0,
            preparation_generation: 0,
        }
    }

    /// Re-compute syntax-highlighted display rows when the theme appearance changes.
    fn rehighlight(&mut self, cx: &mut Context<Self>) {
        log::debug!("DiffViewer::rehighlight: appearance changed");
        let appearance = cx.theme().appearance;
        if appearance == self.current_appearance {
            return;
        }
        // Clear the display cache since the appearance changed.
        self.display_cache.clear();
        self.current_appearance = appearance;
        // Three-way rows are plain text and theme-independent. In particular,
        // do not invalidate an in-flight three-way preparation, which would
        // otherwise leave its loading state waiting for a discarded result.
        if self.three_way_diff.is_some() {
            cx.notify();
            return;
        }
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        let colors = cx.colors();
        let added_word_bg = HighlightStyle {
            background_color: Some(gpui::Hsla {
                a: 0.25,
                ..colors.vc_added
            }),
            ..Default::default()
        };
        let deleted_word_bg = HighlightStyle {
            background_color: Some(gpui::Hsla {
                a: 0.25,
                ..colors.vc_deleted
            }),
            ..Default::default()
        };
        if let (Some(diff), Some(path)) = (self.diff.clone(), self.file_path.clone()) {
            let cache_key = DisplayCacheKey::new(
                path.clone(),
                appearance == Appearance::Dark,
                self.source.clone(),
                &diff,
            );
            self.spawn_display_preparation(
                diff,
                path,
                cache_key,
                appearance,
                added_word_bg,
                deleted_word_bg,
                cx,
            );
        }
        cx.notify();
    }

    fn spawn_display_preparation(
        &mut self,
        diff: Arc<FileDiff>,
        path: String,
        cache_key: DisplayCacheKey,
        appearance: Appearance,
        added_word_bg: HighlightStyle,
        deleted_word_bg: HighlightStyle,
        cx: &mut Context<Self>,
    ) {
        let generation = self.preparation_generation;
        cx.spawn(async move |this, cx: &mut gpui::AsyncApp| {
            let diff_for_prepare = Arc::clone(&diff);
            let path_for_prepare = path.clone();
            let prepared = cx
                .background_executor()
                .spawn(async move {
                    Self::prepare_display_rows(
                        &diff_for_prepare,
                        &path_for_prepare,
                        appearance,
                        added_word_bg,
                        deleted_word_bg,
                    )
                })
                .await;

            this.update(cx, |this, cx| {
                if !should_apply_prepared(this.preparation_generation, generation) {
                    return;
                }

                this.display_cache.insert(
                    cache_key,
                    CachedDisplayRows {
                        display_rows: Arc::clone(&prepared.display_rows),
                        sbs_rows: Arc::clone(&prepared.sbs_rows),
                        display_longest_row_ix: prepared.display_longest_row_ix,
                        source_diff: Arc::clone(&diff),
                    },
                );
                this.display_rows = prepared.display_rows;
                this.sbs_rows = prepared.sbs_rows;
                this.display_longest_row_ix = prepared.display_longest_row_ix;
                this.loading = false;
                this.sync_wrap_list_state();
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    pub fn focus(&self, window: &mut Window, cx: &mut Context<Self>) {
        self.focus_handle.focus(window, cx);
        cx.notify();
    }

    pub fn is_focused(&self, window: &Window) -> bool {
        self.focus_handle.is_focused(window)
    }

    pub fn set_diff(
        &mut self,
        diff: FileDiff,
        path: String,
        source: DiffSource,
        cx: &mut Context<Self>,
    ) {
        log::debug!("DiffViewer::set_diff: path={} source={:?}", path, source);
        self.generation = self.generation.wrapping_add(1);
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.error = None;
        // Showing a standard diff supersedes any active conflict view. Clearing
        // the three-way state here (before the cache-hit early-return) prevents the
        // render match from routing to the stale ThreeWay arm after switching from a
        // conflict file to a normal one.
        if self.three_way_diff.is_some() {
            self.three_way_diff = None;
            self.three_way_rows = Arc::new(Vec::new());
            self.conflict_choices.clear();
        }
        if self.display_mode == DiffDisplayMode::ThreeWay {
            self.display_mode = DiffDisplayMode::Unified;
        }
        let appearance = cx.theme().appearance;
        let is_dark = appearance == Appearance::Dark;
        let diff = Arc::new(diff);
        let cache_key = DisplayCacheKey::new(path.clone(), is_dark, source.clone(), &diff);

        self.current_appearance = appearance;
        self.diff = Some(Arc::clone(&diff));
        self.file_path = Some(path.clone());
        self.source = source;
        self.highlighted_row = None;
        self.selected_lines = None;
        self.partial_mode = false;
        self.selection_anchor = None;
        self.mouse_selecting = false;
        self.file_menu_open = false;

        cx.emit(DiffViewerEvent::DiffChanged {
            path: path.clone(),
            commit_id: self.source.commit_id().map(str::to_string),
            generation: self.generation,
        });

        // Check display rows cache
        if let Some(cached) = self.display_cache.get(&cache_key, &diff) {
            log::debug!("DiffViewer: display_cache hit for path={}", path);
            self.display_rows = cached.display_rows;
            self.sbs_rows = cached.sbs_rows;
            self.display_longest_row_ix = cached.display_longest_row_ix;
            self.loading = false;
            self.sync_wrap_list_state();
            cx.notify();
            return;
        }

        log::debug!("DiffViewer: display_cache miss for path={}", path);
        let colors = cx.colors();
        let added_word_bg = HighlightStyle {
            background_color: Some(gpui::Hsla {
                a: 0.25,
                ..colors.vc_added
            }),
            ..Default::default()
        };
        let deleted_word_bg = HighlightStyle {
            background_color: Some(gpui::Hsla {
                a: 0.25,
                ..colors.vc_deleted
            }),
            ..Default::default()
        };
        self.loading = true;
        self.display_rows = Arc::new(Vec::new());
        self.sbs_rows = Arc::new(Vec::new());
        self.display_longest_row_ix = 0;
        self.sync_wrap_list_state();
        cx.notify();
        self.spawn_display_preparation(
            diff,
            path,
            cache_key,
            appearance,
            added_word_bg,
            deleted_word_bg,
            cx,
        );
    }

    pub fn clear(&mut self, cx: &mut Context<Self>) {
        log::debug!("DiffViewer::clear");
        self.generation = self.generation.wrapping_add(1);
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.loading = false;
        self.error = None;
        self.diff = None;
        self.file_path = None;
        self.source = DiffSource::Worktree;
        self.display_mode = DiffDisplayMode::Unified;
        self.display_rows = Arc::new(Vec::new());
        self.sbs_rows = Arc::new(Vec::new());
        self.three_way_rows = Arc::new(Vec::new());
        self.display_longest_row_ix = 0;
        self.three_way_diff = None;
        self.conflict_choices.clear();
        self.highlighted_row = None;
        self.selected_lines = None;
        self.partial_mode = false;
        self.selection_anchor = None;
        self.mouse_selecting = false;
        self.file_menu_open = false;
        self.sync_wrap_list_state();
        cx.notify();
    }

    /// Set a 3-way conflict diff to display.
    pub fn set_three_way_diff(&mut self, diff: ThreeWayFileDiff, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        self.loading = true;
        self.error = None;
        let appearance = cx.theme().appearance;
        self.current_appearance = appearance;
        self.diff = None; // No standard FileDiff when showing 3-way
        self.file_path = Some(diff.path.display().to_string());
        // A conflicted file lives in the working tree; the three-way renderer
        // has no per-hunk staging of its own, but the source must not claim
        // the content is historical.
        self.source = DiffSource::Worktree;
        let diff = Arc::new(diff);
        self.conflict_choices = vec![None; diff.conflict_count()];
        self.three_way_diff = Some(Arc::clone(&diff));
        self.three_way_rows = Arc::new(Vec::new());
        // Switch to the three-way renderer. This must precede `sync_wrap_list_state`,
        // which sizes the wrap list off `row_count()` for the active `display_mode`.
        self.display_mode = DiffDisplayMode::ThreeWay;
        self.highlighted_row = None;
        self.selected_lines = None;
        self.partial_mode = false;
        self.selection_anchor = None;
        self.mouse_selecting = false;
        self.file_menu_open = false;
        cx.emit(DiffViewerEvent::DiffChanged {
            path: self.file_path.clone().unwrap_or_default(),
            commit_id: None,
            generation: self.generation,
        });
        self.sync_wrap_list_state();
        cx.notify();

        let choices = self.conflict_choices.clone();
        self.prepare_three_way_rows(diff, choices, cx);
    }

    fn prepare_three_way_rows(
        &mut self,
        diff: Arc<ThreeWayFileDiff>,
        choices: Vec<Option<ConflictChoice>>,
        cx: &mut Context<Self>,
    ) {
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        let generation = self.preparation_generation;
        cx.spawn(async move |this, cx: &mut gpui::AsyncApp| {
            let rows = cx
                .background_executor()
                .spawn(async move { Self::compute_three_way_rows(&diff, &choices) })
                .await;
            this.update(cx, |this, cx| {
                if !should_apply_prepared(this.preparation_generation, generation) {
                    return;
                }
                this.three_way_rows = Arc::new(rows);
                this.loading = false;
                this.sync_wrap_list_state();
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Begin loading a conflict and return the generation that owns the request.
    /// Callers compare it again before applying the background result.
    pub fn set_conflict_loading(&mut self, path: String, cx: &mut Context<Self>) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.loading = true;
        self.error = None;
        self.diff = None;
        self.file_path = Some(path.clone());
        self.source = DiffSource::Worktree;
        self.display_mode = DiffDisplayMode::ThreeWay;
        self.three_way_diff = None;
        self.three_way_rows = Arc::new(Vec::new());
        self.conflict_choices.clear();
        self.highlighted_row = None;
        self.selected_lines = None;
        self.partial_mode = false;
        self.selection_anchor = None;
        self.mouse_selecting = false;
        self.file_menu_open = false;
        self.sync_wrap_list_state();
        cx.emit(DiffViewerEvent::DiffChanged {
            path,
            commit_id: None,
            generation: self.generation,
        });
        cx.notify();
        self.generation
    }

    /// Begin loading an ordinary file diff and return the generation that owns
    /// the request. A later file or conflict selection invalidates this token,
    /// preventing an older background result from replacing the newer view.
    pub fn set_diff_loading(
        &mut self,
        path: String,
        source: DiffSource,
        cx: &mut Context<Self>,
    ) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.loading = true;
        self.error = None;
        self.diff = None;
        self.file_path = Some(path.clone());
        self.source = source;
        self.display_mode = DiffDisplayMode::Unified;
        self.three_way_diff = None;
        self.three_way_rows = Arc::new(Vec::new());
        self.conflict_choices.clear();
        self.display_rows = Arc::new(Vec::new());
        self.sbs_rows = Arc::new(Vec::new());
        self.highlighted_row = None;
        self.selected_lines = None;
        self.partial_mode = false;
        self.selection_anchor = None;
        self.mouse_selecting = false;
        self.file_menu_open = false;
        self.sync_wrap_list_state();
        cx.emit(DiffViewerEvent::DiffChanged {
            path,
            commit_id: self.source.commit_id().map(str::to_string),
            generation: self.generation,
        });
        cx.notify();
        self.generation
    }

    /// Claim ownership of a diff request whose file path is not known until
    /// its repository query completes (for example a commit or stash diff).
    /// Every later selection invalidates the returned generation.
    pub fn begin_diff_request(&mut self, cx: &mut Context<Self>) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.loading = true;
        self.error = None;
        self.diff = None;
        self.file_path = None;
        self.source = DiffSource::Worktree;
        self.display_mode = DiffDisplayMode::Unified;
        self.display_rows = Arc::new(Vec::new());
        self.sbs_rows = Arc::new(Vec::new());
        self.three_way_diff = None;
        self.three_way_rows = Arc::new(Vec::new());
        self.conflict_choices.clear();
        self.highlighted_row = None;
        self.selected_lines = None;
        self.partial_mode = false;
        self.selection_anchor = None;
        self.mouse_selecting = false;
        self.file_menu_open = false;
        self.sync_wrap_list_state();
        cx.notify();
        self.generation
    }

    /// Mark that a diff fetch is in progress so the viewer shows a loading
    /// spinner instead of stale content or the empty placeholder.
    pub fn set_loading(&mut self, cx: &mut Context<Self>) {
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.loading = true;
        self.error = None;
        cx.notify();
    }

    /// Surface a diff-fetch failure in the viewer instead of silently leaving
    /// the previous file's content (or the generic placeholder) on screen.
    pub fn set_error(&mut self, message: impl Into<String>, cx: &mut Context<Self>) {
        self.preparation_generation = self.preparation_generation.wrapping_add(1);
        self.loading = false;
        self.error = Some(message.into());
        cx.notify();
    }

    fn range_from_anchor(anchor: usize, row_ix: usize) -> Range<usize> {
        anchor.min(row_ix)..anchor.max(row_ix) + 1
    }

    fn handle_line_click(&mut self, row_ix: usize, shift: bool, cx: &mut Context<Self>) {
        if shift {
            if let Some(anchor) = self.selection_anchor {
                self.selected_lines = Some(Self::range_from_anchor(anchor, row_ix));
            } else {
                self.selection_anchor = Some(row_ix);
                self.selected_lines = Some(row_ix..row_ix + 1);
            }
        } else {
            self.selection_anchor = Some(row_ix);
            self.selected_lines = Some(row_ix..row_ix + 1);
        }
        cx.notify();
    }

    fn begin_mouse_selection(&mut self, row_ix: usize, shift: bool, cx: &mut Context<Self>) {
        self.mouse_selecting = true;
        self.handle_line_click(row_ix, shift, cx);
    }

    fn extend_mouse_selection(&mut self, row_ix: usize, cx: &mut Context<Self>) {
        if !self.mouse_selecting {
            return;
        }
        let anchor = self.selection_anchor.unwrap_or(row_ix);
        self.selection_anchor = Some(anchor);
        let range = Self::range_from_anchor(anchor, row_ix);
        if self.selected_lines.as_ref() != Some(&range) {
            self.selected_lines = Some(range);
            cx.notify();
        }
    }

    fn end_mouse_selection(
        &mut self,
        _event: &MouseUpEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.mouse_selecting {
            self.mouse_selecting = false;
            cx.notify();
        }
    }

    fn copy_selected_lines(&self, cx: &mut Context<Self>) {
        let range = match &self.selected_lines {
            Some(r) => r.clone(),
            None => return,
        };

        let mut text = String::new();
        match self.display_mode {
            DiffDisplayMode::Unified => {
                for i in range {
                    if i < self.display_rows.len() {
                        match &self.display_rows[i] {
                            DisplayRow::HunkHeader { header, .. } => {
                                text.push_str(header);
                                text.push('\n');
                            }
                            DisplayRow::Line { styled, .. } => {
                                text.push_str(styled.text.as_ref());
                                text.push('\n');
                            }
                        }
                    }
                }
            }
            DiffDisplayMode::SideBySide => {
                for i in range {
                    if i < self.sbs_rows.len() {
                        match &self.sbs_rows[i] {
                            SideBySideRow::HunkHeader { header, .. } => {
                                text.push_str(header);
                                text.push('\n');
                            }
                            SideBySideRow::Pair {
                                left_styled,
                                left_kind,
                                right_styled,
                                right_kind,
                                ..
                            } => {
                                if *left_kind != SideBySideLineKind::Empty {
                                    text.push_str(left_styled.text.as_ref());
                                }
                                if *left_kind != SideBySideLineKind::Empty
                                    && *right_kind != SideBySideLineKind::Empty
                                    && *left_kind != SideBySideLineKind::Context
                                {
                                    text.push('\t');
                                }
                                if *right_kind != SideBySideLineKind::Empty
                                    && *right_kind != SideBySideLineKind::Context
                                {
                                    text.push_str(right_styled.text.as_ref());
                                }
                                text.push('\n');
                            }
                        }
                    }
                }
            }
            DiffDisplayMode::ThreeWay => {
                for i in range {
                    if i < self.three_way_rows.len() {
                        match &self.three_way_rows[i] {
                            ThreeWayRow::HunkHeader { header, .. } => {
                                text.push_str(header);
                                text.push('\n');
                            }
                            ThreeWayRow::Triple {
                                left_styled,
                                mid_styled,
                                right_styled,
                                ..
                            } => {
                                text.push_str(left_styled.text.as_ref());
                                text.push('\n');
                                text.push_str(mid_styled.text.as_ref());
                                text.push('\n');
                                text.push_str(right_styled.text.as_ref());
                                text.push('\n');
                            }
                        }
                    }
                }
            }
        }

        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn row_count(&self) -> usize {
        match self.display_mode {
            DiffDisplayMode::Unified => self.display_rows.len(),
            DiffDisplayMode::SideBySide => self.sbs_rows.len(),
            DiffDisplayMode::ThreeWay => self.three_way_rows.len(),
        }
    }

    /// Resize the virtualized wrap-mode list so its SumTree matches the current
    /// row set. Call this after any mutation that changes the number or
    /// identity of rows for the active `display_mode`.
    ///
    /// `ListState::reset` discards `logical_scroll_top`, which would snap the wrap
    /// view back to the top on every refresh (e.g. after staging a hunk or a theme
    /// re-highlight). The no-wrap path keeps its position because its
    /// `UniformListScrollHandle` is untouched here; to stay consistent we capture
    /// the logical scroll offset and restore it (clamped to the new row count) so a
    /// content refresh preserves the user's place. Callers that want a specific
    /// position (`toggle_display_mode`, `scroll_to_line`) set it afterward.
    fn sync_wrap_list_state(&self) {
        let row_count = self.row_count();
        let prev = self.wrap_list_state.logical_scroll_top();
        self.wrap_list_state.reset(row_count);
        if row_count == 0 {
            return;
        }
        let mut restored = prev;
        if restored.item_ix >= row_count {
            restored.item_ix = row_count - 1;
            restored.offset_in_item = px(0.);
        }
        self.wrap_list_state.scroll_to(restored);
    }

    /// Whether the active layout renders through the wrap-mode `gpui::list`
    /// (backed by `wrap_list_state`) rather than the uniform list. Side-by-side and
    /// three-way always wrap so their columns stay aligned, regardless of the
    /// `diff_wrap_lines` setting; unified follows the setting.
    fn wrap_active(&self, cx: &App) -> bool {
        cx.global::<rgitui_settings::SettingsState>()
            .settings()
            .diff_wrap_lines
            || matches!(
                self.display_mode,
                DiffDisplayMode::SideBySide | DiffDisplayMode::ThreeWay
            )
    }

    /// Reveal row `ix` in whichever scrollable container is currently active.
    /// The uniform list scroll handle is used for no-wrap rendering, while
    /// wrap mode lives inside a `gpui::list` backed by `wrap_list_state`.
    fn scroll_row_into_view(&self, ix: usize, cx: &App) {
        if self.wrap_active(cx) {
            self.wrap_list_state.scroll_to_reveal_item(ix);
        } else {
            self.scroll_handle.scroll_to_item(ix, ScrollStrategy::Top);
        }
    }

    /// Moves the diff cursor down one row, scrolling it into view.
    ///
    /// The workspace drives this and the methods below from the `diff::*`
    /// actions: this crate sits below `rgitui_workspace` in the dependency graph
    /// and so cannot name them.
    pub fn select_next_row(&mut self, cx: &mut Context<Self>) {
        let row_count = self.row_count();
        if row_count == 0 {
            return;
        }
        let next = match self.highlighted_row {
            Some(i) if i + 1 < row_count => i + 1,
            None => 0,
            Some(i) => i,
        };
        self.highlight_row(next, cx);
    }

    /// Moves the diff cursor up one row, scrolling it into view.
    pub fn select_prev_row(&mut self, cx: &mut Context<Self>) {
        if self.row_count() == 0 {
            return;
        }
        let next = match self.highlighted_row {
            Some(i) if i > 0 => i - 1,
            Some(i) => i,
            None => 0,
        };
        self.highlight_row(next, cx);
    }

    /// Moves the diff cursor to the first row.
    pub fn select_first_row(&mut self, cx: &mut Context<Self>) {
        if self.row_count() > 0 {
            self.highlight_row(0, cx);
        }
    }

    /// Moves the diff cursor to the last row.
    pub fn select_last_row(&mut self, cx: &mut Context<Self>) {
        let row_count = self.row_count();
        if row_count > 0 {
            self.highlight_row(row_count - 1, cx);
        }
    }

    fn highlight_row(&mut self, row: usize, cx: &mut Context<Self>) {
        self.highlighted_row = Some(row);
        self.scroll_row_into_view(row, cx);
        cx.notify();
    }

    /// Whether the row at `index` in the current display mode is a hunk header.
    fn is_hunk_header(&self, index: usize) -> bool {
        match self.display_mode {
            DiffDisplayMode::Unified => {
                matches!(self.display_rows[index], DisplayRow::HunkHeader { .. })
            }
            DiffDisplayMode::SideBySide => {
                matches!(self.sbs_rows[index], SideBySideRow::HunkHeader { .. })
            }
            DiffDisplayMode::ThreeWay => {
                matches!(self.three_way_rows[index], ThreeWayRow::HunkHeader { .. })
            }
        }
    }

    /// Moves the cursor to the next hunk header, wrapping at the end.
    pub fn select_next_hunk(&mut self, cx: &mut Context<Self>) {
        let row_count = self.row_count();
        if row_count == 0 {
            return;
        }
        let start = self.highlighted_row.map(|r| r + 1).unwrap_or(0);
        let next = (start..row_count)
            .find(|&i| self.is_hunk_header(i))
            .or_else(|| (0..start).find(|&i| self.is_hunk_header(i)));
        if let Some(pos) = next {
            self.highlight_row(pos, cx);
        }
    }

    /// Moves the cursor to the previous hunk header, wrapping at the start.
    pub fn select_prev_hunk(&mut self, cx: &mut Context<Self>) {
        let row_count = self.row_count();
        if row_count == 0 {
            return;
        }
        let end = self.highlighted_row.unwrap_or(row_count);
        let prev = (0..end)
            .rev()
            .find(|&i| self.is_hunk_header(i))
            .or_else(|| (end..row_count).rev().find(|&i| self.is_hunk_header(i)));
        if let Some(pos) = prev {
            self.highlight_row(pos, cx);
        }
    }

    /// Toggles line-level selection, clearing any selection when leaving it.
    pub fn toggle_partial_mode(&mut self, cx: &mut Context<Self>) {
        // Partial mode exists to scope the source's line-level operation —
        // staging for the working tree, apply/revert for anything else. The
        // three-way conflict view has no line-level operation, so there is
        // nothing for a line selection to act on.
        if self.display_mode == DiffDisplayMode::ThreeWay {
            return;
        }
        self.partial_mode = !self.partial_mode;
        if !self.partial_mode {
            self.selected_lines = None;
            self.selection_anchor = None;
        }
        cx.notify();
    }

    /// Selects every row in the diff.
    pub fn select_all_lines(&mut self, cx: &mut Context<Self>) {
        let row_count = self.row_count();
        if row_count == 0 {
            return;
        }
        self.selection_anchor = Some(0);
        self.selected_lines = Some(0..row_count);
        cx.notify();
    }

    /// Copies the selected diff lines to the clipboard.
    pub fn copy_selection(&self, cx: &mut Context<Self>) {
        self.copy_selected_lines(cx);
    }

    /// Requests staging of the hunks — or, in partial mode, the individual
    /// lines — under the current selection, falling back to the cursor's hunk.
    pub fn stage_selection(&mut self, cx: &mut Context<Self>) {
        // Only the working tree can be staged; committed and stashed content is
        // historical and has nothing to stage.
        if !self.source.offers(DiffOperation::Stage) {
            return;
        }
        if self.partial_mode {
            // Line-level staging: emit the selected change lines (additions and
            // deletions). Each pair carries its old/new line number; the git
            // layer matches additions on the new side and deletions on the old
            // side, so deletions must flow through unfiltered.
            let line_pairs = self.change_lines_under_selection();
            if !line_pairs.is_empty() {
                cx.emit(DiffViewerEvent::LineStageRequested(line_pairs));
            }
            // TODO(audit): BUG-15 surface a "no stageable lines" toast when a
            // partial selection yields nothing — needs a new DiffViewerEvent
            // variant + a handler arm in rgitui_workspace events.rs (the toast
            // system lives there), which can't be added from this crate alone.
            return;
        }
        for idx in self.hunks_to_act_on() {
            cx.emit(DiffViewerEvent::HunkStageRequested(idx));
        }
    }

    /// Requests unstaging of the hunks — or lines — under the current selection.
    pub fn unstage_selection(&mut self, cx: &mut Context<Self>) {
        // Only the index can be unstaged.
        if !self.source.offers(DiffOperation::Unstage) {
            return;
        }
        if self.partial_mode {
            // Deletions must flow through so the git layer can match them on the
            // old side; filtering to additions would make unstaging a pure
            // deletion a silent no-op.
            let line_pairs = self.change_lines_under_selection();
            if !line_pairs.is_empty() {
                cx.emit(DiffViewerEvent::LineUnstageRequested(line_pairs));
            }
            return;
        }
        for idx in self.hunks_to_act_on() {
            cx.emit(DiffViewerEvent::HunkUnstageRequested(idx));
        }
    }

    /// Requests staging of just the hunk under the cursor.
    pub fn stage_current_hunk(&mut self, cx: &mut Context<Self>) {
        if !self.source.offers(DiffOperation::Stage) {
            return;
        }
        if let Some(idx) = self.current_hunk_index() {
            cx.emit(DiffViewerEvent::HunkStageRequested(idx));
        }
    }

    /// Requests unstaging of just the hunk under the cursor.
    pub fn unstage_current_hunk(&mut self, cx: &mut Context<Self>) {
        if !self.source.offers(DiffOperation::Unstage) {
            return;
        }
        if let Some(idx) = self.current_hunk_index() {
            cx.emit(DiffViewerEvent::HunkUnstageRequested(idx));
        }
    }

    /// Requests that the displayed source's version of the hunks — or, in partial
    /// mode, the lines — under the current selection be written into the working
    /// tree.
    ///
    /// The counterpart of [`Self::stage_selection`] for content that has no
    /// staging route: a commit, a stash entry, or a comparison of two revisions.
    pub fn apply_selection(&mut self, cx: &mut Context<Self>) {
        self.request_worktree_patch(DiffOperation::Apply, cx);
    }

    /// Requests that the displayed source's change be taken back out of the
    /// working tree, over the same granularity [`Self::apply_selection`] uses.
    pub fn revert_selection(&mut self, cx: &mut Context<Self>) {
        self.request_worktree_patch(DiffOperation::Revert, cx);
    }

    /// Requests that the whole file be brought to the displayed source's version,
    /// ignoring the current selection.
    pub fn apply_file(&mut self, cx: &mut Context<Self>) {
        self.request_whole_file_patch(DiffOperation::Apply, cx);
    }

    /// Requests that the displayed source's change be taken out of the whole
    /// file, ignoring the current selection.
    pub fn revert_file(&mut self, cx: &mut Context<Self>) {
        self.request_whole_file_patch(DiffOperation::Revert, cx);
    }

    /// The change lines under the selection, or the cursor hunk's if there is none.
    fn change_lines_under_selection(&self) -> Vec<(Option<usize>, Option<usize>)> {
        match &self.selected_lines {
            Some(selection) => self
                .lines_under_selection(selection.clone())
                .into_iter()
                .filter(Self::is_change_line)
                .collect(),
            None => self.current_hunk_changes(),
        }
    }

    /// The hunks under the selection, or the cursor's hunk if there is none.
    fn hunks_to_act_on(&self) -> Vec<usize> {
        match &self.selected_lines {
            Some(selection) => self.hunks_under_selection(selection.clone()),
            None => self
                .current_hunk_index()
                .map(|i| vec![i])
                .unwrap_or_default(),
        }
    }

    /// The operations the file-level menu offers: the ones that act on the whole
    /// file rather than on a hunk or a line selection.
    ///
    /// Whole-file staging is reached from the sidebar's Staged/Unstaged lists, so
    /// the menu carries apply/revert only.
    fn file_menu_operations(&self) -> Vec<DiffOperation> {
        if self.display_mode == DiffDisplayMode::ThreeWay {
            return Vec::new();
        }
        self.source
            .operations()
            .iter()
            .copied()
            .filter(|operation| operation.writes_files())
            .collect()
    }

    /// Ask the workspace to apply or revert `operation` over the whole file.
    fn request_whole_file_patch(&mut self, operation: DiffOperation, cx: &mut Context<Self>) {
        self.file_menu_open = false;
        if !self.source.offers(operation) {
            cx.notify();
            return;
        }
        cx.emit(DiffViewerEvent::WorktreePatchRequested {
            operation,
            scope: WorktreePatchScope::File,
        });
        cx.notify();
    }

    /// Ask the workspace to apply or revert `operation` over the granularity the
    /// current selection implies. Silently does nothing when the displayed
    /// content does not support the operation, so the key is inert rather than
    /// wrong on a working-tree diff.
    fn request_worktree_patch(&mut self, operation: DiffOperation, cx: &mut Context<Self>) {
        if !self.source.offers(operation) {
            return;
        }
        if let Some(scope) = self.selected_patch_scope() {
            cx.emit(DiffViewerEvent::WorktreePatchRequested { operation, scope });
        }
    }

    /// The scope an apply/revert should cover: line-level when the user has turned
    /// on partial mode, otherwise the hunk under the cursor, or the hunks the row
    /// selection spans.
    ///
    /// Several selected hunks collapse into one `Lines` scope. These operations
    /// read the file off disk and write it back, so two requests in flight over
    /// the same file would race; one request covering every selected line cannot.
    fn selected_patch_scope(&self) -> Option<WorktreePatchScope> {
        if self.partial_mode {
            let lines = match &self.selected_lines {
                Some(selection) => self
                    .lines_under_selection(selection.clone())
                    .into_iter()
                    .filter(Self::is_change_line)
                    .collect(),
                None => self.current_hunk_changes(),
            };
            if lines.is_empty() {
                return None;
            }
            return Some(WorktreePatchScope::Lines(lines));
        }

        let hunks = match &self.selected_lines {
            Some(selection) => self.hunks_under_selection(selection.clone()),
            None => self
                .current_hunk_index()
                .map(|i| vec![i])
                .unwrap_or_default(),
        };
        match hunks.as_slice() {
            [] => None,
            [only] => Some(WorktreePatchScope::Hunk(*only)),
            several => {
                let lines = self.changes_in_hunks(several);
                if lines.is_empty() {
                    None
                } else {
                    Some(WorktreePatchScope::Lines(lines))
                }
            }
        }
    }

    /// Returns the hunk index at or before the currently highlighted row.
    /// If the highlighted row itself is a hunk header, returns its index.
    /// Otherwise searches backwards to find the nearest preceding hunk.
    fn current_hunk_index(&self) -> Option<usize> {
        let pos = self.highlighted_row?;
        match self.display_mode {
            DiffDisplayMode::Unified => {
                // Check current position first. `.get` guards against a stale
                // `highlighted_row` left over from a different mode's longer row set.
                if let Some(DisplayRow::HunkHeader { hunk_index, .. }) = self.display_rows.get(pos)
                {
                    return Some(*hunk_index);
                }
                // Search backwards for nearest hunk header
                (0..pos.min(self.display_rows.len())).rev().find_map(|i| {
                    if let DisplayRow::HunkHeader { hunk_index, .. } = &self.display_rows[i] {
                        Some(*hunk_index)
                    } else {
                        None
                    }
                })
            }
            DiffDisplayMode::SideBySide => {
                if let Some(SideBySideRow::HunkHeader { hunk_index, .. }) = self.sbs_rows.get(pos) {
                    return Some(*hunk_index);
                }
                (0..pos.min(self.sbs_rows.len())).rev().find_map(|i| {
                    if let SideBySideRow::HunkHeader { hunk_index, .. } = &self.sbs_rows[i] {
                        Some(*hunk_index)
                    } else {
                        None
                    }
                })
            }
            DiffDisplayMode::ThreeWay => {
                // Check current position first
                if let Some(ThreeWayRow::HunkHeader { .. }) = self.three_way_rows.get(pos) {
                    return Some(pos); // In 3-way mode, row index = hunk index
                }
                (0..pos.min(self.three_way_rows.len()))
                    .rev()
                    .find(|&i| matches!(self.three_way_rows[i], ThreeWayRow::HunkHeader { .. }))
            }
        }
    }

    /// Returns all unique hunk indices that have at least one row within `range`.
    /// Works by tracking the current hunk as we iterate through display rows,
    /// emitting the hunk index each time we encounter a hunk header within the range.
    fn hunks_under_selection(&self, range: Range<usize>) -> Vec<usize> {
        let mut hunks = Vec::new();
        let mut seen = HashSet::new();
        let start = range.start;
        let end = range.end.min(self.row_count());

        match &self.display_mode {
            DiffDisplayMode::Unified => {
                let rows = &self.display_rows;
                let mut current_hunk: Option<usize> = None;
                for i in start..end {
                    if let DisplayRow::HunkHeader { hunk_index, .. } = &rows[i] {
                        current_hunk = Some(*hunk_index);
                    } else if let Some(h) = current_hunk {
                        if seen.insert(h) {
                            hunks.push(h);
                        }
                    }
                }
            }
            DiffDisplayMode::SideBySide => {
                let rows = &self.sbs_rows;
                let mut current_hunk: Option<usize> = None;
                for i in start..end {
                    if let SideBySideRow::HunkHeader { hunk_index, .. } = &rows[i] {
                        current_hunk = Some(*hunk_index);
                    } else if let Some(h) = current_hunk {
                        if seen.insert(h) {
                            hunks.push(h);
                        }
                    }
                }
            }
            DiffDisplayMode::ThreeWay => {
                let rows = &self.three_way_rows;
                let mut current_hunk: Option<usize> = None;
                for i in start..end {
                    if let ThreeWayRow::HunkHeader { .. } = &rows[i] {
                        current_hunk = Some(i);
                    } else if let Some(h) = current_hunk {
                        if seen.insert(h) {
                            hunks.push(h);
                        }
                    }
                }
            }
        }
        hunks
    }

    /// Returns the (old_file_line, new_file_line) pairs for all rows in the given range.
    /// Used for line-level partial staging.
    fn lines_under_selection(&self, range: Range<usize>) -> Vec<(Option<usize>, Option<usize>)> {
        let start = range.start;
        let end = range.end.min(self.row_count());
        let mut lines = Vec::new();

        match &self.display_mode {
            DiffDisplayMode::Unified => {
                let rows = &self.display_rows;
                for i in start..end {
                    if let DisplayRow::Line {
                        old_num, new_num, ..
                    } = &rows[i]
                    {
                        lines.push((*old_num, *new_num));
                    }
                }
            }
            DiffDisplayMode::SideBySide => {
                let rows = &self.sbs_rows;
                for i in start..end {
                    if let SideBySideRow::Pair {
                        left_num,
                        left_kind,
                        right_num,
                        right_kind,
                        ..
                    } = &rows[i]
                    {
                        // A pair can carry a deletion on the left and an addition on
                        // the right (a modification row). Split it into its constituent
                        // change lines — keyed on the side's kind — so each side is
                        // staged against the correct (old / new) target set. Context
                        // pairs contribute nothing.
                        if *left_kind == SideBySideLineKind::Deletion {
                            lines.push((*left_num, None));
                        }
                        if *right_kind == SideBySideLineKind::Addition {
                            lines.push((None, *right_num));
                        }
                    }
                }
            }
            DiffDisplayMode::ThreeWay => {
                // ThreeWay doesn't support partial line staging yet
            }
        }
        lines
    }

    /// True for an addition `(None, Some)` or deletion `(Some, None)` line; false
    /// for context `(Some, Some)` and empty `(None, None)` rows. Used to keep
    /// non-change rows out of a partial-staging selection.
    fn is_change_line(pair: &(Option<usize>, Option<usize>)) -> bool {
        pair.0.is_some() ^ pair.1.is_some()
    }

    /// Returns the change lines (additions and deletions) in the current hunk as
    /// (old_num, new_num) pairs. Deletions are emitted as (Some, None) and
    /// additions as (None, Some) so the git layer can stage either side.
    fn current_hunk_changes(&self) -> Vec<(Option<usize>, Option<usize>)> {
        match self.current_hunk_index() {
            Some(index) => self.changes_in_hunks(&[index]),
            None => Vec::new(),
        }
    }

    /// The change lines of every hunk in `hunks`, as (old_num, new_num) pairs in
    /// file order. Used to express a multi-hunk selection as a single line-scoped
    /// request.
    fn changes_in_hunks(&self, hunks: &[usize]) -> Vec<(Option<usize>, Option<usize>)> {
        // Line numbers only come off the unified rows; the side-by-side rows
        // split a modification across two columns.
        if self.display_mode == DiffDisplayMode::ThreeWay {
            return Vec::new();
        }
        let wanted: HashSet<usize> = hunks.iter().copied().collect();
        let mut lines = Vec::new();
        let mut current_hunk: Option<usize> = None;
        for row in self.display_rows.iter() {
            match row {
                DisplayRow::HunkHeader { hunk_index, .. } => current_hunk = Some(*hunk_index),
                DisplayRow::Line {
                    old_num,
                    new_num,
                    kind,
                    ..
                } => {
                    let in_wanted_hunk = current_hunk.is_some_and(|hunk| wanted.contains(&hunk));
                    if in_wanted_hunk
                        && matches!(kind, DisplayLineKind::Addition | DisplayLineKind::Deletion)
                    {
                        lines.push((*old_num, *new_num));
                    }
                }
            }
        }
        lines
    }

    pub fn toggle_display_mode(&mut self, cx: &mut Context<Self>) {
        // A three-way conflict has no unified/side-by-side representation, so the
        // toggle is inert while one is shown — flipping to Unified would render an
        // empty diff.
        if self.three_way_diff.is_some() {
            return;
        }

        // Capture the current top item so we can restore scroll position after the
        // switch. No-wrap reads the uniform list's base handle; wrap mode lives in a
        // `gpui::list` whose `logical_scroll_top` is the authoritative position (the
        // uniform handle is never rendered in wrap mode and stays at 0).
        let top_item = if self.wrap_active(cx) {
            self.wrap_list_state.logical_scroll_top().item_ix
        } else {
            self.scroll_handle.0.borrow().base_handle.top_item()
        };
        self.pending_scroll_top = Some(top_item);

        self.display_mode = match self.display_mode {
            DiffDisplayMode::Unified => DiffDisplayMode::SideBySide,
            DiffDisplayMode::SideBySide => DiffDisplayMode::Unified,
            DiffDisplayMode::ThreeWay => DiffDisplayMode::Unified,
        };
        self.sync_wrap_list_state();

        // The new mode's row set differs in length (a unified modification pair maps
        // to one side-by-side row), so clamp any highlighted row back into bounds to
        // keep later index lookups from panicking.
        let row_count = self.row_count();
        self.highlighted_row = match self.highlighted_row {
            Some(_) if row_count == 0 => None,
            Some(r) => Some(r.min(row_count - 1)),
            None => None,
        };

        cx.notify();
    }

    pub fn diff(&self) -> Option<&FileDiff> {
        self.diff.as_deref()
    }

    pub fn file_path(&self) -> Option<&str> {
        self.file_path.as_deref()
    }

    /// Provenance of the displayed content. Callers use this to decide whether
    /// staging is meaningful and to recover the backing commit/stash OID.
    pub fn source(&self) -> &DiffSource {
        &self.source
    }

    /// `None` for working-tree and index diffs; the hex OID for commit and
    /// stash diffs.
    pub fn commit_id(&self) -> Option<&str> {
        self.source.commit_id()
    }

    /// Monotonic counter bumped whenever the displayed content changes
    /// A workspace diff refresh captures this before computing and re-checks it
    /// before applying, so stale repository results cannot clobber a newer diff.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn has_three_way_diff(&self) -> bool {
        self.three_way_diff.is_some()
    }

    /// True from the moment a conflict is selected until its three-way view is
    /// explicitly replaced or cleared. Unlike `has_three_way_diff`, this also
    /// covers the background-load window before the conflict model arrives.
    pub fn is_conflict_view_active(&self) -> bool {
        self.display_mode == DiffDisplayMode::ThreeWay
    }

    pub fn unresolved_conflict_count(&self) -> usize {
        self.conflict_choices
            .iter()
            .filter(|choice| choice.is_none())
            .count()
    }

    fn selected_conflict_index(&self) -> Option<usize> {
        let row_index = self.highlighted_row?;
        match self.three_way_rows.get(row_index) {
            Some(ThreeWayRow::HunkHeader { conflict_index, .. }) => Some(*conflict_index),
            Some(ThreeWayRow::Triple { .. }) => self.three_way_rows[..row_index]
                .iter()
                .rev()
                .find_map(|row| match row {
                    ThreeWayRow::HunkHeader { conflict_index, .. } => Some(*conflict_index),
                    ThreeWayRow::Triple { .. } => None,
                }),
            None => None,
        }
    }

    fn target_conflict_index(&self) -> Option<usize> {
        self.selected_conflict_index()
            .or_else(|| self.conflict_choices.iter().position(Option::is_none))
            .or_else(|| (!self.conflict_choices.is_empty()).then_some(0))
    }

    fn set_conflict_choice(
        &mut self,
        conflict_index: usize,
        choice: Option<ConflictChoice>,
        cx: &mut Context<Self>,
    ) {
        let Some(slot) = self.conflict_choices.get_mut(conflict_index) else {
            return;
        };
        *slot = choice;
        self.rebuild_three_way_rows(cx);
    }

    fn rebuild_three_way_rows(&mut self, cx: &mut Context<Self>) {
        let Some(diff) = self.three_way_diff.as_ref().map(Arc::clone) else {
            return;
        };
        // Styling and laying out a large conflict is expensive. Keep the last
        // complete rows visible while this choice is prepared off the UI
        // thread; the generation guard coalesces rapid choices and prevents an
        // older preparation from replacing the newest state.
        let choices = self.conflict_choices.clone();
        self.prepare_three_way_rows(diff, choices, cx);
        cx.notify();
    }

    pub fn use_current_for_conflict(&mut self, cx: &mut Context<Self>) {
        if let Some(index) = self.target_conflict_index() {
            self.set_conflict_choice(index, Some(ConflictChoice::Ours), cx);
        }
    }

    pub fn use_incoming_for_conflict(&mut self, cx: &mut Context<Self>) {
        if let Some(index) = self.target_conflict_index() {
            self.set_conflict_choice(index, Some(ConflictChoice::Theirs), cx);
        }
    }

    pub fn use_both_for_conflict(&mut self, incoming_first: bool, cx: &mut Context<Self>) {
        let Some(diff) = self.three_way_diff.as_ref() else {
            return;
        };
        if !diff.supports_text_resolution() {
            return;
        }
        if let Some(index) = self.target_conflict_index() {
            let choice = if incoming_first {
                ConflictChoice::BothTheirsFirst
            } else {
                ConflictChoice::BothOursFirst
            };
            self.set_conflict_choice(index, Some(choice), cx);
        }
    }

    pub fn reset_conflict_choice(&mut self, cx: &mut Context<Self>) {
        if let Some(index) = self.target_conflict_index() {
            self.set_conflict_choice(index, None, cx);
        }
    }

    pub fn use_current_for_all_conflicts(&mut self, cx: &mut Context<Self>) {
        for choice in &mut self.conflict_choices {
            choice.get_or_insert(ConflictChoice::Ours);
        }
        self.rebuild_three_way_rows(cx);
    }

    pub fn use_incoming_for_all_conflicts(&mut self, cx: &mut Context<Self>) {
        for choice in &mut self.conflict_choices {
            choice.get_or_insert(ConflictChoice::Theirs);
        }
        self.rebuild_three_way_rows(cx);
    }

    pub fn save_conflict_result(&mut self, cx: &mut Context<Self>) {
        let Some(diff) = self.three_way_diff.as_ref() else {
            return;
        };
        if self.unresolved_conflict_count() > 0 {
            return;
        }
        let path = diff.path.display().to_string();
        if !diff.supports_text_resolution() {
            match self.conflict_choices.first().copied().flatten() {
                Some(ConflictChoice::Ours) => cx.emit(
                    DiffViewerEvent::ConflictResolutionRequested(ConflictResolution::UseOurs {
                        path,
                        snapshot: diff.snapshot.clone(),
                    }),
                ),
                Some(ConflictChoice::Theirs) => cx.emit(
                    DiffViewerEvent::ConflictResolutionRequested(ConflictResolution::UseTheirs {
                        path,
                        snapshot: diff.snapshot.clone(),
                    }),
                ),
                _ => {}
            }
            return;
        }

        let Some(content) = assemble_text_resolution(diff, &self.conflict_choices) else {
            return;
        };
        cx.emit(DiffViewerEvent::ConflictResolutionRequested(
            ConflictResolution::SaveMerged {
                path,
                content,
                mode: diff.result_mode,
                snapshot: diff.snapshot.clone(),
            },
        ));
    }

    pub fn stage_conflict_working_copy(&mut self, cx: &mut Context<Self>) {
        if let Some(diff) = self.three_way_diff.as_ref() {
            cx.emit(DiffViewerEvent::ConflictResolutionRequested(
                ConflictResolution::StageWorkingTree {
                    path: diff.path.display().to_string(),
                    snapshot: diff.snapshot.clone(),
                },
            ));
        }
    }

    pub fn open_conflict_in_editor(&mut self, cx: &mut Context<Self>) {
        if let Some(path) = self
            .three_way_diff
            .as_ref()
            .map(|diff| diff.path.display().to_string())
            .or_else(|| self.file_path.clone())
        {
            cx.emit(DiffViewerEvent::ConflictResolutionRequested(
                ConflictResolution::OpenInEditor { path },
            ));
        }
    }

    /// True iff `set_diff` with these inputs would produce identical content to
    /// what's already shown. Lets callers skip a refresh that would only churn
    /// state (cleared selection / scroll reset) without visible benefit.
    pub fn matches_current_diff(&self, path: &str, source: &DiffSource, diff: &FileDiff) -> bool {
        if self.has_three_way_diff() {
            return false;
        }
        let Some(existing_path) = self.file_path.as_deref() else {
            return false;
        };
        if existing_path != path || &self.source != source {
            return false;
        }
        let Some(existing) = self.diff.as_deref() else {
            return false;
        };
        file_diffs_render_equal(existing, diff)
    }

    /// Scroll to and highlight the given line number (1-indexed) in the new/right side
    /// of the diff. Used by global search to navigate from grep results to the
    /// corresponding location in the diff viewer. Returns true if the line was found.
    pub fn scroll_to_line(&mut self, line_number: usize, cx: &Context<Self>) -> bool {
        // A three-way conflict has no `display_rows` to navigate; bail before the
        // mode-switch logic below acts on a stale unified row set.
        if self.three_way_diff.is_some() || self.display_rows.is_empty() {
            return false;
        }
        let target = self.display_rows.iter().position(|row| {
            matches!(
                row,
                DisplayRow::Line {
                    new_num: Some(n),
                    ..
                } if *n == line_number
            )
        });
        if let Some(idx) = target {
            // The target index addresses `display_rows`, so `highlighted_row` is only
            // valid against the unified row set. Switch to unified first (search
            // navigation is a unified-view concept) so the highlight and scroll land
            // on the right row regardless of the prior mode.
            if self.display_mode != DiffDisplayMode::Unified {
                self.display_mode = DiffDisplayMode::Unified;
                self.sync_wrap_list_state();
            }
            self.highlighted_row = Some(idx);
            self.scroll_row_into_view(idx, cx);
            return true;
        }
        false
    }

    fn count_changes(rows: &[DisplayRow]) -> (usize, usize) {
        let mut additions = 0usize;
        let mut deletions = 0usize;
        for row in rows {
            if let DisplayRow::Line { kind, .. } = row {
                match kind {
                    DisplayLineKind::Addition => additions += 1,
                    DisplayLineKind::Deletion => deletions += 1,
                    DisplayLineKind::Context => {}
                }
            }
        }
        (additions, deletions)
    }

    fn icon_for_path(path: &str) -> IconName {
        if let Some(ext) = path.rsplit('.').next() {
            match ext {
                "rs" | "py" | "js" | "ts" | "tsx" | "jsx" | "mjs" | "cjs" | "mts" | "cts" | "c"
                | "cpp" | "h" | "hpp" | "go" | "java" | "rb" | "sh" | "lua" | "zig" | "swift"
                | "kt" | "kts" | "cs" | "fs" | "ex" | "exs" | "hs" | "ml" | "elm" | "dart"
                | "r" | "scala" | "clj" | "erl" | "v" | "odin" | "proto" | "sql" | "vue"
                | "svelte" | "astro" | "php" | "pl" | "d" => IconName::File,
                "toml" | "yaml" | "yml" | "json" | "jsonc" | "json5" | "xml" | "ini" | "conf"
                | "cfg" | "env" | "hcl" | "tf" | "graphql" | "gql" | "prisma" => IconName::Settings,
                "css" | "scss" | "sass" | "less" | "styl" | "pcss" => IconName::File,
                "html" | "htm" | "hbs" | "ejs" | "njk" => IconName::File,
                "md" | "txt" | "rst" | "org" => IconName::File,
                "lock" => IconName::Pin,
                _ => IconName::File,
            }
        } else {
            IconName::File
        }
    }

    /// Extract the function/context name from a hunk header.
    /// Hunk headers look like `@@ -10,5 +10,7 @@ fn some_function(...)`
    /// This returns the part after the closing `@@`.
    fn extract_context_name(header: &str) -> String {
        if let Some(pos) = header.find("@@") {
            let after_first = &header[pos + 2..];
            if let Some(pos2) = after_first.find("@@") {
                let context = after_first[pos2 + 2..].trim();
                if !context.is_empty() {
                    return context.to_string();
                }
            }
        }
        String::new()
    }

    /// Extract the line range portion from a hunk header (the `@@ -x,y +x,y @@` part).
    fn extract_line_range(header: &str) -> String {
        if let Some(start) = header.find("@@") {
            let after_first = &header[start..];
            if let Some(end) = after_first[2..].find("@@") {
                return after_first[..end + 4].to_string();
            }
        }
        header.to_string()
    }

    fn syntax_assets() -> &'static SyntaxAssets {
        static ASSETS: OnceLock<SyntaxAssets> = OnceLock::new();
        ASSETS.get_or_init(|| {
            log::info!("DiffViewer: initializing SyntaxAssets (one-time cost)");
            SyntaxAssets {
                syntax_set: SyntaxSet::load_defaults_newlines(),
                theme_set: ThemeSet::load_defaults(),
            }
        })
    }

    fn syntax_theme(appearance: Appearance) -> &'static Theme {
        let assets = Self::syntax_assets();
        let preferred_name = match appearance {
            Appearance::Dark => "base16-ocean.dark",
            Appearance::Light => "base16-ocean.light",
        };
        assets
            .theme_set
            .themes
            .get(preferred_name)
            .or_else(|| {
                // Graceful fallback: for light pick any non-dark theme, else any
                if appearance == Appearance::Light {
                    assets
                        .theme_set
                        .themes
                        .iter()
                        .find(|(k, _)| k.contains("light") || k.contains("Light"))
                        .map(|(_, v)| v)
                } else {
                    None
                }
            })
            .or_else(|| assets.theme_set.themes.values().next())
            .expect("syntect theme set should contain at least one theme")
    }

    fn syntax_for_path(path: &str) -> Option<&'static SyntaxReference> {
        let assets = Self::syntax_assets();
        assets
            .syntax_set
            .find_syntax_for_file(Path::new(path))
            .ok()
            .flatten()
            .or_else(|| {
                Path::new(path)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .and_then(|name| assets.syntax_set.find_syntax_by_token(name))
            })
            .or_else(|| {
                // Fallback: map common extensions that syntect's defaults don't cover
                // to the closest available syntax grammar.
                let ext = Path::new(path).extension()?.to_str()?;
                let fallback_name = match ext {
                    // TypeScript / JSX / TSX → JavaScript
                    "ts" | "tsx" | "jsx" | "mjs" | "cjs" | "mts" | "cts" => "JavaScript",
                    // Markup variants → HTML
                    "vue" | "svelte" | "astro" | "hbs" | "ejs" | "njk" | "liquid" => "HTML",
                    // Style variants → CSS
                    "scss" | "sass" | "less" | "styl" | "pcss" | "postcss" => "CSS",
                    // Config / data → JSON or YAML
                    "jsonc" | "json5" | "geojson" | "webmanifest" | "eslintrc" | "prettierrc"
                    | "babelrc" => "JSON",
                    "toml" | "ini" | "cfg" | "conf" | "env" | "properties" | "editorconfig" => {
                        // TOML/INI are closest to YAML in structure for basic highlighting
                        "YAML"
                    }
                    // Shell variants → Bash
                    "ps1" | "psm1" | "psd1" | "nu" => "Bourne Again Shell (bash)",
                    // Docker / container
                    "dockerfile" => "Makefile",
                    // Systems languages → C/C++
                    "zig" | "odin" | "v" => "C",
                    "kt" | "kts" => "Java",
                    "swift" => "Objective-C",
                    "dart" => "Java",
                    // Functional languages
                    "ex" | "exs" | "eex" | "heex" | "leex" => "Ruby",
                    "elm" | "hs" | "purs" => "Haskell",
                    "fs" | "fsx" | "fsi" => "C#",
                    "ml" | "mli" | "re" | "rei" => "OCaml",
                    // Other
                    "proto" | "protobuf" => "C",
                    "graphql" | "gql" => "JavaScript",
                    "tf" | "hcl" => "JSON",
                    "cmake" => "Makefile",
                    "r" | "rmd" => "R",
                    "sql" | "pgsql" | "mysql" | "tsql" => "SQL",
                    _ => return None,
                };
                assets.syntax_set.find_syntax_by_name(fallback_name)
            })
            .or_else(|| {
                // Final fallback: match known filenames without extensions
                let filename = Path::new(path).file_name()?.to_str()?;
                let fallback_name = match filename {
                    "Dockerfile" | "Containerfile" | "Justfile" | "Brewfile" => "Makefile",
                    ".bashrc" | ".zshrc" | ".profile" | ".bash_profile" | ".zprofile" | ".env"
                    | ".envrc" => "Bourne Again Shell (bash)",
                    ".gitignore" | ".dockerignore" | ".prettierignore" | ".eslintignore" => {
                        "Bourne Again Shell (bash)"
                    }
                    "tsconfig.json" | "package.json" | "composer.json" | ".swcrc" => "JSON",
                    "CMakeLists.txt" => "Makefile",
                    _ => return None,
                };
                assets.syntax_set.find_syntax_by_name(fallback_name)
            })
    }

    fn syntax_line_highlighter(path: &str, appearance: Appearance) -> SyntaxLineHighlighter {
        let assets = Self::syntax_assets();
        let Some(syntax) = Self::syntax_for_path(path) else {
            return SyntaxLineHighlighter::Plain;
        };

        SyntaxLineHighlighter::Syntect {
            syntax_set: &assets.syntax_set,
            syntax,
            highlighter: Self::syntax_highlighter(appearance),
        }
    }

    /// The shared [`Highlighter`] for an appearance.
    ///
    /// There are only ever two, and each is derived entirely from a `'static`
    /// theme, so they are built once and handed out by reference.
    fn syntax_highlighter(appearance: Appearance) -> &'static Highlighter<'static> {
        static DARK: OnceLock<Highlighter<'static>> = OnceLock::new();
        static LIGHT: OnceLock<Highlighter<'static>> = OnceLock::new();

        let cell = match appearance {
            Appearance::Dark => &DARK,
            Appearance::Light => &LIGHT,
        };
        cell.get_or_init(|| Highlighter::new(Self::syntax_theme(appearance)))
    }

    fn syntect_style_to_highlight(style: syntect::highlighting::Style) -> HighlightStyle {
        let foreground = style.foreground;
        let mut highlight = HighlightStyle {
            color: Some(rgitui_theme::rgba_u8_to_hsla(
                foreground.r,
                foreground.g,
                foreground.b,
                foreground.a,
            )),
            ..Default::default()
        };

        if style.font_style.contains(SyntectFontStyle::BOLD) {
            highlight.font_weight = Some(FontWeight::BOLD);
        }
        if style.font_style.contains(SyntectFontStyle::ITALIC) {
            highlight.font_style = Some(FontStyle::Italic);
        }

        highlight
    }

    fn highlight_text(text: &str, highlighter: &mut SyntaxLineHighlighter) -> StyledLine {
        let trimmed = text.trim_end();
        if trimmed.is_empty() {
            return StyledLine::plain(trimmed.to_string());
        }

        match highlighter {
            SyntaxLineHighlighter::Plain => StyledLine::plain(trimmed.to_string()),
            SyntaxLineHighlighter::Syntect {
                syntax_set,
                syntax,
                highlighter,
            } => {
                // Highlight each line with a fresh parse state to prevent
                // block-comment / multi-line string state from bleeding across
                // diff lines (additions, deletions, context are interleaved
                // from different file versions so stateful highlighting
                // produces incorrect results -- e.g. a `/*` in a deleted line
                // would color all subsequent additions as comments).
                //
                // The state is what has to be fresh; the highlighter behind it
                // does not, so it is shared rather than rebuilt here.
                let mut parse_state = ParseState::new(syntax);
                let mut highlight_state = HighlightState::new(highlighter, ScopeStack::new());
                let Ok(operations) = parse_state.parse_line(trimmed, syntax_set) else {
                    return StyledLine::plain(trimmed.to_string());
                };
                let ranges: Vec<(syntect::highlighting::Style, &str)> =
                    HighlightIterator::new(&mut highlight_state, &operations, trimmed, highlighter)
                        .collect();

                let text_len = trimmed.len();
                let mut highlights = Vec::new();
                let mut cursor = 0usize;
                for (style, segment) in ranges.into_iter() {
                    let segment: &str = segment;
                    let len = segment.len();
                    if len == 0 {
                        continue;
                    }
                    // Clip to text bounds. GPUI panics if StyledText runs exceed
                    // text length — syntect can return spans extending into
                    // trailing whitespace that trim_end() removed.
                    let start = cursor.min(text_len);
                    let end = (cursor + len).min(text_len);
                    if start < end {
                        highlights.push((start..end, Self::syntect_style_to_highlight(style)));
                    }
                    cursor += len;
                }

                StyledLine {
                    text: trimmed.to_string().into(),
                    highlights,
                }
            }
        }
    }

    /// Returns the row index of the longest line for the given mode, used to
    /// seed `UniformList::with_width_from_item` so horizontal scroll range
    /// covers the widest line in the diff. Byte length is a good-enough proxy
    /// for code diffs, which are overwhelmingly ASCII.
    fn longest_row_ix(
        mode: DiffDisplayMode,
        display_rows: &[DisplayRow],
        sbs_rows: &[SideBySideRow],
        three_way_rows: &[ThreeWayRow],
    ) -> usize {
        match mode {
            DiffDisplayMode::Unified => display_rows
                .iter()
                .enumerate()
                .map(|(i, row)| {
                    let len = match row {
                        DisplayRow::Line { styled, .. } => styled.text.len(),
                        DisplayRow::HunkHeader { header, .. } => header.len(),
                    };
                    (i, len)
                })
                .max_by_key(|(_, len)| *len)
                .map(|(i, _)| i)
                .unwrap_or(0),
            DiffDisplayMode::SideBySide => sbs_rows
                .iter()
                .enumerate()
                .map(|(i, row)| {
                    let len = match row {
                        SideBySideRow::Pair {
                            left_styled,
                            right_styled,
                            ..
                        } => left_styled.text.len().max(right_styled.text.len()),
                        SideBySideRow::HunkHeader { header, .. } => header.len(),
                    };
                    (i, len)
                })
                .max_by_key(|(_, len)| *len)
                .map(|(i, _)| i)
                .unwrap_or(0),
            DiffDisplayMode::ThreeWay => three_way_rows
                .iter()
                .enumerate()
                .map(|(i, row)| {
                    let len = match row {
                        ThreeWayRow::Triple {
                            left_styled,
                            mid_styled,
                            right_styled,
                            ..
                        } => left_styled
                            .text
                            .len()
                            .max(mid_styled.text.len())
                            .max(right_styled.text.len()),
                        ThreeWayRow::HunkHeader { header, .. } => header.len(),
                    };
                    (i, len)
                })
                .max_by_key(|(_, len)| *len)
                .map(|(i, _)| i)
                .unwrap_or(0),
        }
    }

    fn render_styled_text(
        window: &Window,
        text: &StyledLine,
        default_color: gpui::Hsla,
        row_height: f32,
        wrap: bool,
    ) -> gpui::AnyElement {
        // Runs (colors / font) are built from this style. StyledText's layout
        // reads `window.text_style()` — NOT this local — for white_space,
        // line_height, etc., so we also push those onto the ancestor div below.
        let mut run_style = window.text_style();
        run_style.color = default_color;
        run_style.line_height = px(row_height).into();

        let styled_text = StyledText::new(text.text.clone());
        // Guard: if text is empty but highlights exist, GPUI panics on
        // StyledText::with_default_highlights (Text: '', run: len: N).
        // This can happen with word-level diff on whitespace-only lines.
        // Pass highlights as a borrowed-iter (cloned per-element) to skip the
        // Vec allocation per row per frame.
        let styled = if text.text.is_empty() {
            styled_text
                .with_default_highlights(&run_style, std::iter::empty())
                .into_any_element()
        } else {
            styled_text
                .with_default_highlights(&run_style, text.highlights.iter().cloned())
                .into_any_element()
        };

        // The text layouter reads `window.text_style()` at its request_layout
        // time, so white_space and line_height must be on an ancestor div via
        // `with_text_style` — setting them on a local TextStyle that is only
        // handed to `with_default_highlights` does nothing for layout.
        if wrap {
            // `overflow_hidden` is also required so Taffy passes a definite
            // width down to the text layouter inside a flex container (per
            // zed's text.rs storybook example).
            div()
                .overflow_hidden()
                .line_height(px(row_height))
                .whitespace_normal()
                .child(styled)
                .into_any_element()
        } else {
            // No-wrap: ancestor `overflow_x_scroll` scroll area handles
            // horizontal scrolling; the StyledText extends to its natural
            // width inside it.
            div()
                .line_height(px(row_height))
                .whitespace_nowrap()
                .child(styled)
                .into_any_element()
        }
    }

    fn prepare_display_rows(
        diff: &FileDiff,
        path: &str,
        appearance: Appearance,
        added_word_bg: HighlightStyle,
        deleted_word_bg: HighlightStyle,
    ) -> PreparedDisplayRows {
        // Syntax highlighting and word-level LCS are computed once for the
        // unified representation. Side-by-side rows reuse those StyledLines
        // instead of running a second syntect/LCS pass over the same diff.
        let display_rows = Arc::new(Self::compute_display_rows(
            diff,
            path,
            appearance,
            added_word_bg,
            deleted_word_bg,
        ));
        let sbs_rows = Arc::new(Self::compute_sbs_rows(&display_rows));
        let display_longest_row_ix =
            Self::longest_row_ix(DiffDisplayMode::Unified, &display_rows, &[], &[]);

        PreparedDisplayRows {
            display_rows,
            sbs_rows,
            display_longest_row_ix,
        }
    }

    fn compute_sbs_rows(display_rows: &[DisplayRow]) -> Vec<SideBySideRow> {
        let mut rows = Vec::new();
        let mut pending_dels: Vec<(usize, StyledLine)> = Vec::new();
        let mut pending_adds: Vec<(usize, StyledLine)> = Vec::new();

        let flush = |rows: &mut Vec<SideBySideRow>,
                     dels: &mut Vec<(usize, StyledLine)>,
                     adds: &mut Vec<(usize, StyledLine)>| {
            let max_len = dels.len().max(adds.len());
            for i in 0..max_len {
                let (left_num, left_styled, left_kind) = dels.get(i).map_or_else(
                    || (None, StyledLine::plain(""), SideBySideLineKind::Empty),
                    |(num, styled)| (Some(*num), styled.clone(), SideBySideLineKind::Deletion),
                );
                let (right_num, right_styled, right_kind) = adds.get(i).map_or_else(
                    || (None, StyledLine::plain(""), SideBySideLineKind::Empty),
                    |(num, styled)| (Some(*num), styled.clone(), SideBySideLineKind::Addition),
                );
                rows.push(SideBySideRow::Pair {
                    left_num,
                    left_styled,
                    left_kind,
                    right_num,
                    right_styled,
                    right_kind,
                });
            }
            dels.clear();
            adds.clear();
        };

        for row in display_rows {
            match row {
                DisplayRow::HunkHeader {
                    header,
                    context_name,
                    hunk_index,
                } => {
                    flush(&mut rows, &mut pending_dels, &mut pending_adds);
                    rows.push(SideBySideRow::HunkHeader {
                        header: header.clone(),
                        context_name: context_name.clone(),
                        hunk_index: *hunk_index,
                    });
                }
                DisplayRow::Line {
                    old_num,
                    new_num,
                    styled,
                    kind: DisplayLineKind::Context,
                } => {
                    flush(&mut rows, &mut pending_dels, &mut pending_adds);
                    rows.push(SideBySideRow::Pair {
                        left_num: *old_num,
                        left_styled: styled.clone(),
                        left_kind: SideBySideLineKind::Context,
                        right_num: *new_num,
                        right_styled: styled.clone(),
                        right_kind: SideBySideLineKind::Context,
                    });
                }
                DisplayRow::Line {
                    old_num: Some(old_num),
                    styled,
                    kind: DisplayLineKind::Deletion,
                    ..
                } => pending_dels.push((*old_num, styled.clone())),
                DisplayRow::Line {
                    new_num: Some(new_num),
                    styled,
                    kind: DisplayLineKind::Addition,
                    ..
                } => pending_adds.push((*new_num, styled.clone())),
                DisplayRow::Line { .. } => {}
            }
        }
        flush(&mut rows, &mut pending_dels, &mut pending_adds);
        rows
    }

    fn compute_three_way_rows(
        diff: &ThreeWayFileDiff,
        choices: &[Option<ConflictChoice>],
    ) -> Vec<ThreeWayRow> {
        let mut rows = Vec::new();
        let mut conflict_index = 0;
        let mut left_line = 1;
        let mut mid_line = 1;
        let mut right_line = 1;
        let conflict_count = diff.conflict_count();
        let context_name = diff
            .path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default();

        for section in &diff.sections {
            match section {
                MergeSection::Resolved(content) => {
                    for line in Self::display_lines(content, false) {
                        let styled = Self::plain_styled(&line);
                        rows.push(ThreeWayRow::Triple {
                            left_num: next_line_number(&mut left_line, true),
                            left_styled: styled.clone(),
                            left_kind: ThreeWayLineKind::Unchanged,
                            mid_num: next_line_number(&mut mid_line, true),
                            mid_styled: styled.clone(),
                            mid_kind: ThreeWayLineKind::Unchanged,
                            right_num: next_line_number(&mut right_line, true),
                            right_styled: styled,
                            right_kind: ThreeWayLineKind::Unchanged,
                        });
                    }
                }
                MergeSection::Conflict {
                    ancestor: _,
                    ours,
                    theirs,
                } => {
                    let choice = choices.get(conflict_index).copied().flatten();
                    let allow_both = diff.supports_text_resolution();
                    let left_has_real_lines =
                        diff.ours_exists && !diff.is_binary && !diff.is_special_file;
                    let right_has_real_lines =
                        diff.theirs_exists && !diff.is_binary && !diff.is_special_file;
                    let result_has_real_lines = match choice {
                        Some(ConflictChoice::Ours) => left_has_real_lines,
                        Some(ConflictChoice::Theirs) => right_has_real_lines,
                        Some(ConflictChoice::BothOursFirst | ConflictChoice::BothTheirsFirst) => {
                            allow_both
                        }
                        None => false,
                    };
                    let detail = if diff.is_binary {
                        "Binary file"
                    } else if diff.is_special_file {
                        "Special file"
                    } else if !diff.ours_exists || !diff.theirs_exists {
                        "Modify/delete conflict"
                    } else if choice.is_some() {
                        "Resolved in draft"
                    } else {
                        "Choose a result"
                    };
                    rows.push(ThreeWayRow::HunkHeader {
                        header: format!(
                            "Conflict {} of {}: {}",
                            conflict_index + 1,
                            conflict_count,
                            detail
                        ),
                        context_name: context_name.clone(),
                        conflict_index,
                        resolved: choice.is_some(),
                        allow_both,
                    });

                    let mut ours_lines = Self::display_lines(ours, diff.is_binary);
                    let mut theirs_lines = Self::display_lines(theirs, diff.is_binary);
                    if !diff.ours_exists {
                        ours_lines = vec!["<deleted>".to_string()];
                    }
                    if !diff.theirs_exists {
                        theirs_lines = vec!["<deleted>".to_string()];
                    }
                    let mut result_lines = match choice {
                        Some(ConflictChoice::Ours) => ours_lines.clone(),
                        Some(ConflictChoice::Theirs) => theirs_lines.clone(),
                        Some(ConflictChoice::BothOursFirst) => ours_lines
                            .iter()
                            .chain(theirs_lines.iter())
                            .cloned()
                            .collect(),
                        Some(ConflictChoice::BothTheirsFirst) => theirs_lines
                            .iter()
                            .chain(ours_lines.iter())
                            .cloned()
                            .collect(),
                        None => vec!["<unresolved>".to_string()],
                    };
                    if ours_lines.is_empty() {
                        ours_lines.push(String::new());
                    }
                    if theirs_lines.is_empty() {
                        theirs_lines.push(String::new());
                    }
                    if result_lines.is_empty() {
                        result_lines.push(String::new());
                    }
                    let line_count = ours_lines
                        .len()
                        .max(result_lines.len())
                        .max(theirs_lines.len());
                    for line_index in 0..line_count {
                        rows.push(ThreeWayRow::Triple {
                            left_num: next_line_number(
                                &mut left_line,
                                left_has_real_lines && line_index < ours_lines.len(),
                            ),
                            left_styled: Self::plain_styled(
                                ours_lines.get(line_index).map(String::as_str).unwrap_or(""),
                            ),
                            left_kind: ThreeWayLineKind::Conflict,
                            mid_num: next_line_number(
                                &mut mid_line,
                                result_has_real_lines && line_index < result_lines.len(),
                            ),
                            mid_styled: Self::plain_styled(
                                result_lines
                                    .get(line_index)
                                    .map(String::as_str)
                                    .unwrap_or(""),
                            ),
                            mid_kind: if choice.is_some() {
                                ThreeWayLineKind::Resolved
                            } else {
                                ThreeWayLineKind::Conflict
                            },
                            right_num: next_line_number(
                                &mut right_line,
                                right_has_real_lines && line_index < theirs_lines.len(),
                            ),
                            right_styled: Self::plain_styled(
                                theirs_lines
                                    .get(line_index)
                                    .map(String::as_str)
                                    .unwrap_or(""),
                            ),
                            right_kind: ThreeWayLineKind::Conflict,
                        });
                    }
                    conflict_index += 1;
                }
            }
        }
        rows
    }

    fn display_lines(content: &[u8], binary: bool) -> Vec<String> {
        if binary {
            return vec![format!("<binary content: {} bytes>", content.len())];
        }
        if content.is_empty() {
            return Vec::new();
        }
        String::from_utf8_lossy(content)
            .split_inclusive('\n')
            .map(|line| line.strip_suffix('\n').unwrap_or(line))
            .map(|line| line.strip_suffix('\r').unwrap_or(line).to_string())
            .collect()
    }

    /// Build a plain (no syntax highlighting) StyledLine from a string.
    fn plain_styled(text: &str) -> StyledLine {
        StyledLine {
            text: text.to_string().into(),
            highlights: Vec::new(),
        }
    }

    fn compute_display_rows(
        diff: &FileDiff,
        path: &str,
        appearance: Appearance,
        added_word_bg: HighlightStyle,
        deleted_word_bg: HighlightStyle,
    ) -> Vec<DisplayRow> {
        let mut rows = Vec::new();
        for (i, hunk) in diff.hunks.iter().enumerate() {
            let header_str = hunk.header.trim().to_string();
            rows.push(DisplayRow::HunkHeader {
                context_name: Self::extract_context_name(&header_str),
                header: header_str,
                hunk_index: i,
            });
            let mut old_line = hunk.old_start as usize;
            let mut new_line = hunk.new_start as usize;
            let mut highlighter = Self::syntax_line_highlighter(path, appearance);

            let mut pending_dels: Vec<(usize, String, StyledLine)> = Vec::new();
            let mut pending_adds: Vec<(usize, String, StyledLine)> = Vec::new();

            let flush = |rows: &mut Vec<DisplayRow>,
                         dels: &mut Vec<(usize, String, StyledLine)>,
                         adds: &mut Vec<(usize, String, StyledLine)>,
                         deleted_word_bg: HighlightStyle,
                         added_word_bg: HighlightStyle| {
                let max_len = dels.len().max(adds.len());
                // Word-diff pairs rows by index, so applying it when the
                // deletion and addition counts disagree (reformats, insertions
                // that split a line, etc.) produces dense token-coincidence
                // noise instead of useful change markers. The row-level red/
                // green coloring alone is clearer in that case.
                let pair_word_diff = dels.len() == adds.len();
                for j in 0..max_len {
                    match (dels.get_mut(j), adds.get_mut(j)) {
                        (
                            Some((del_line, del_text, del_styled)),
                            Some((_add_line, add_text, add_styled)),
                        ) => {
                            if pair_word_diff {
                                let (del_spans, add_spans) = Self::compute_word_diff(
                                    del_text.trim_end(),
                                    add_text.trim_end(),
                                );
                                del_styled.apply_word_highlights(
                                    del_spans,
                                    Vec::new(),
                                    deleted_word_bg,
                                    added_word_bg,
                                );
                                add_styled.apply_word_highlights(
                                    Vec::new(),
                                    add_spans,
                                    deleted_word_bg,
                                    added_word_bg,
                                );
                            }
                            rows.push(DisplayRow::Line {
                                old_num: Some(*del_line),
                                new_num: None,
                                styled: del_styled.clone(),
                                kind: DisplayLineKind::Deletion,
                            });
                            rows.push(DisplayRow::Line {
                                old_num: None,
                                new_num: Some(*_add_line),
                                styled: add_styled.clone(),
                                kind: DisplayLineKind::Addition,
                            });
                        }
                        (Some((del_line, _, del_styled)), None) => {
                            rows.push(DisplayRow::Line {
                                old_num: Some(*del_line),
                                new_num: None,
                                styled: del_styled.clone(),
                                kind: DisplayLineKind::Deletion,
                            });
                        }
                        (None, Some((add_line, _, add_styled))) => {
                            rows.push(DisplayRow::Line {
                                old_num: None,
                                new_num: Some(*add_line),
                                styled: add_styled.clone(),
                                kind: DisplayLineKind::Addition,
                            });
                        }
                        (None, None) => {}
                    }
                }
                dels.clear();
                adds.clear();
            };

            for line in &hunk.lines {
                match line {
                    DiffLine::Context(text) => {
                        flush(
                            &mut rows,
                            &mut pending_dels,
                            &mut pending_adds,
                            deleted_word_bg,
                            added_word_bg,
                        );
                        rows.push(DisplayRow::Line {
                            old_num: Some(old_line),
                            new_num: Some(new_line),
                            styled: Self::highlight_text(text, &mut highlighter),
                            kind: DisplayLineKind::Context,
                        });
                        old_line += 1;
                        new_line += 1;
                    }
                    DiffLine::Deletion(text) => {
                        pending_dels.push((
                            old_line,
                            text.clone(),
                            Self::highlight_text(text, &mut highlighter),
                        ));
                        old_line += 1;
                    }
                    DiffLine::Addition(text) => {
                        pending_adds.push((
                            new_line,
                            text.clone(),
                            Self::highlight_text(text, &mut highlighter),
                        ));
                        new_line += 1;
                    }
                }
            }
            flush(
                &mut rows,
                &mut pending_dels,
                &mut pending_adds,
                deleted_word_bg,
                added_word_bg,
            );
        }
        rows
    }

    /// Compute word-level diff highlights between `old_text` and `new_text`.
    /// Returns `(deletion_spans, addition_spans)` as byte-index ranges into
    /// each respective string.
    ///
    /// Uses `Algorithm::Lcs` (Longest Common Subsequence) — the only `similar`
    /// algorithm that is fully iterative with no recursive `DiffHook` callbacks.
    ///
    /// **Why trim before diff?** `highlight_text` stores text with `trim_end()`
    /// (trailing whitespace removed). Computing diff on raw text produces spans
    /// into trailing whitespace that exceed `StyledLine` bounds → GPUI panic.
    /// Trimming both strings first ensures spans always land within the
    /// `StyledLine` content.
    ///
    /// LCS is O(NM) time/space and entirely iterative. Word-level highlighting
    /// is skipped when either text exceeds 100 words (10,000 entries ≈ 80 KB).
    pub(crate) fn compute_word_diff(
        old_text: &str,
        new_text: &str,
    ) -> (Vec<Range<usize>>, Vec<Range<usize>>) {
        let old_trimmed = old_text.trim_end();
        let new_trimmed = new_text.trim_end();

        let old_word_ranges = Self::split_word_ranges(old_trimmed);
        let new_word_ranges = Self::split_word_ranges(new_trimmed);

        if old_word_ranges.is_empty() && new_word_ranges.is_empty() {
            return (Vec::new(), Vec::new());
        }

        // Cap at 100 words per line: LCS is O(NM) in space.
        if old_word_ranges.len() > 100 || new_word_ranges.len() > 100 {
            return (Vec::new(), Vec::new());
        }

        let old_wv: Vec<&str> = old_word_ranges
            .iter()
            .map(|r| &old_trimmed[r.clone()])
            .collect();
        let new_wv: Vec<&str> = new_word_ranges
            .iter()
            .map(|r| &new_trimmed[r.clone()])
            .collect();

        let ops = capture_diff_slices(Algorithm::Lcs, &old_wv, &new_wv);

        let mut del_spans: Vec<Range<usize>> = Vec::new();
        let mut add_spans: Vec<Range<usize>> = Vec::new();

        for op in ops {
            for change in op.iter_changes(&old_wv, &new_wv) {
                match change.tag() {
                    similar::ChangeTag::Delete => {
                        if let Some(idx) = change.old_index() {
                            if idx < old_word_ranges.len() {
                                del_spans.push(old_word_ranges[idx].clone());
                            }
                        }
                    }
                    similar::ChangeTag::Insert => {
                        if let Some(idx) = change.new_index() {
                            if idx < new_word_ranges.len() {
                                add_spans.push(new_word_ranges[idx].clone());
                            }
                        }
                    }
                    similar::ChangeTag::Equal => {}
                }
            }
        }

        let del_spans = Self::merge_nearby_spans(del_spans, 1);
        let add_spans = Self::merge_nearby_spans(add_spans, 1);

        // Extend each span to include immediately adjacent punctuation
        // (e.g. trailing parens/brackets) so `overflow_y_hidden()` highlights
        // as one block instead of stopping before the `()`.
        let del_spans = Self::extend_spans_to_punctuation(del_spans, old_trimmed);
        let add_spans = Self::extend_spans_to_punctuation(add_spans, new_trimmed);

        (del_spans, add_spans)
    }

    /// Split `text` into tokens for word-level diffing.
    ///
    /// Tokens are runs of alphanumeric/underscore characters OR individual
    /// punctuation characters. Whitespace is a separator and not emitted.
    /// This gives much finer granularity than splitting on whitespace alone:
    /// `foo.bar(x)` → `["foo", ".", "bar", "(", "x", ")"]` instead of one
    /// big token.
    pub(crate) fn split_word_ranges(text: &str) -> Vec<Range<usize>> {
        let mut result = Vec::new();
        let mut word_start: Option<usize> = None;

        for (i, ch) in text.char_indices() {
            if ch.is_whitespace() {
                if let Some(start) = word_start.take() {
                    result.push(start..i);
                }
            } else if ch.is_alphanumeric() || ch == '_' {
                if word_start.is_none() {
                    word_start = Some(i);
                }
            } else {
                // Punctuation: flush current word, emit punct as own token.
                if let Some(start) = word_start.take() {
                    result.push(start..i);
                }
                result.push(i..i + ch.len_utf8());
            }
        }
        if let Some(start) = word_start {
            result.push(start..text.len());
        }
        result
    }

    /// Merge spans that are close together into contiguous blocks.
    ///
    /// Without this, fine-grained tokenisation produces many small separate
    /// highlights (e.g. `compute`, `x`, `y` each individually highlighted).
    /// Merging with a small gap tolerance produces cleaner visual blocks
    /// (e.g. one highlight covering `compute(x, y)`).
    fn merge_nearby_spans(spans: Vec<Range<usize>>, max_gap: usize) -> Vec<Range<usize>> {
        if spans.is_empty() {
            return spans;
        }
        let mut merged = vec![spans[0].clone()];
        for span in &spans[1..] {
            let last = merged.last_mut().unwrap();
            if span.start <= last.end + max_gap {
                last.end = span.end;
            } else {
                merged.push(span.clone());
            }
        }
        merged
    }

    /// Extend each span to absorb immediately adjacent punctuation so
    /// highlights cover complete expressions like `func()` or `arr[i]`.
    fn extend_spans_to_punctuation(spans: Vec<Range<usize>>, text: &str) -> Vec<Range<usize>> {
        spans
            .into_iter()
            .map(|span| {
                let mut end = span.end;
                let bytes = text.as_bytes();
                while end < bytes.len() {
                    let ch = bytes[end];
                    if ch == b'('
                        || ch == b')'
                        || ch == b'['
                        || ch == b']'
                        || ch == b'{'
                        || ch == b'}'
                        || ch == b'.'
                        || ch == b','
                        || ch == b';'
                        || ch == b':'
                        || ch == b'<'
                        || ch == b'>'
                    {
                        end += 1;
                    } else {
                        break;
                    }
                }
                span.start..end
            })
            .collect()
    }
}

/// Height of one row in the diff viewer's file-operations menu, in pixels.
const FILE_MENU_ITEM_HEIGHT: f32 = 28.0;
/// Minimum width of the file-operations menu, in pixels.
const FILE_MENU_WIDTH: f32 = 220.0;
/// Where the menu's dismiss backdrop starts, in pixels from the top of the
/// viewer. Must clear the header so the toggle button stays clickable.
const FILE_MENU_BACKDROP_TOP: f32 = 26.0;

impl DiffViewer {
    /// The header's file-operations toggle. Renders nothing when the displayed
    /// content has no whole-file operation.
    fn render_file_menu_button(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.file_menu_operations().is_empty() {
            return div().into_any_element();
        }
        let tooltip: SharedString = match self.source.revision_label() {
            Some(revision) => format!("Apply or revert this whole file from {revision}").into(),
            None => "Whole-file operations".into(),
        };
        Button::new("diff-file-menu", "File")
            .size(ButtonSize::Compact)
            .style(ButtonStyle::Subtle)
            .tooltip(tooltip)
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.file_menu_open = !this.file_menu_open;
                cx.notify();
            }))
            .into_any_element()
    }

    /// True when the file-operations menu is open and has something to show.
    ///
    /// Both the menu and its dismiss backdrop are gated on this, so the backdrop
    /// can never outlive the menu and swallow clicks over the diff body.
    fn file_menu_visible(&self) -> bool {
        self.file_menu_open && !self.file_menu_operations().is_empty()
    }

    /// A backdrop over the diff body that dismisses the open file menu.
    ///
    /// Starts below the header so the toggle button stays uncovered: a backdrop
    /// over the button would eat its mouse-down, and the button would reopen the
    /// menu it had just closed.
    fn render_file_menu_backdrop(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.file_menu_visible() {
            return None;
        }
        Some(
            div()
                .id("diff-file-menu-backdrop")
                .absolute()
                .top(px(FILE_MENU_BACKDROP_TOP))
                .left_0()
                .right_0()
                .bottom_0()
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _: &MouseDownEvent, _, cx| {
                        this.file_menu_open = false;
                        cx.notify();
                        cx.stop_propagation();
                    }),
                )
                .into_any_element(),
        )
    }

    /// The open file-operations menu, positioned under the header's toggle.
    fn render_file_menu(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.file_menu_visible() {
            return None;
        }
        let operations = self.file_menu_operations();
        let colors = cx.colors();
        let revision = self.source.revision_label();

        let mut menu = div()
            .id("diff-file-menu-popover")
            .absolute()
            .top(px(28.))
            .right(px(8.))
            .v_flex()
            .min_w(px(FILE_MENU_WIDTH))
            .py(px(4.))
            .bg(colors.elevated_surface_background)
            .border_1()
            .border_color(colors.border)
            .rounded(px(6.))
            .elevation_3(cx)
            // Clicking inside the menu must not reach the viewer's own click
            // handler, which would steal focus and re-render underneath.
            .on_mouse_down(
                MouseButton::Left,
                |_: &MouseDownEvent, _: &mut Window, cx: &mut App| {
                    cx.stop_propagation();
                },
            );

        if let Some(revision) = &revision {
            menu = menu.child(
                div().px(px(10.)).pb(px(2.)).child(
                    Label::new(SharedString::from(revision.clone()))
                        .size(LabelSize::XSmall)
                        .color(Color::Muted),
                ),
            );
        }

        for operation in operations {
            let hover_bg = colors.ghost_element_hover;
            let active_bg = colors.ghost_element_active;
            let accent = colors.text_accent;
            menu = menu.child(
                div()
                    .id(SharedString::from(format!(
                        "diff-file-menu-{}",
                        operation.key()
                    )))
                    .h_flex()
                    .w_full()
                    .h(px(FILE_MENU_ITEM_HEIGHT))
                    .px(px(10.))
                    .gap(px(6.))
                    .items_center()
                    .rounded(px(4.))
                    .cursor_pointer()
                    .hover(move |s| s.bg(hover_bg).border_l_2().border_color(accent))
                    .active(move |s| s.bg(active_bg))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.request_whole_file_patch(operation, cx);
                    }))
                    .child(
                        Label::new(operation.file_menu_label())
                            .size(LabelSize::Small)
                            .color(Color::Default),
                    ),
            );
        }

        Some(menu.into_any_element())
    }
}

impl Render for DiffViewer {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        log::trace!(
            "DiffViewer::render: path={:?} display_rows={} sbs_rows={}",
            self.file_path,
            self.display_rows.len(),
            self.sbs_rows.len()
        );
        let colors = cx.colors();

        let has_content = self.diff.is_some() || self.three_way_diff.is_some();
        if self.error.is_some() || self.loading || !has_content {
            let is_conflict = self.display_mode == DiffDisplayMode::ThreeWay;
            let header = div()
                .h_flex()
                .w_full()
                .h(px(26.))
                .px(px(10.))
                .gap(px(4.))
                .items_center()
                .bg(colors.toolbar_background)
                .border_b_1()
                .border_color(colors.border_variant)
                .child(
                    Icon::new(IconName::File)
                        .size(IconSize::XSmall)
                        .color(Color::Muted),
                )
                .child(
                    Label::new(if is_conflict {
                        "Conflict Resolver"
                    } else {
                        "Diff"
                    })
                    .size(LabelSize::XSmall)
                    .weight(FontWeight::SEMIBOLD)
                    .color(Color::Muted),
                );

            let card = div()
                .v_flex()
                .gap(px(12.))
                .items_center()
                .px(px(32.))
                .py(px(24.))
                .rounded(px(8.))
                .bg(colors.element_background);

            let card = if let Some(message) = &self.error {
                card.child(
                    Icon::new(IconName::AlertTriangle)
                        .size(IconSize::Large)
                        .color(Color::Error),
                )
                .child(
                    Label::new(if is_conflict {
                        "Couldn't load this conflict"
                    } else {
                        "Failed to load diff"
                    })
                    .size(LabelSize::Small)
                    .color(Color::Error),
                )
                .child(
                    Label::new(message.clone())
                        .size(LabelSize::XSmall)
                        .color(Color::Muted),
                )
                .when(is_conflict, |element| {
                    element.child(
                        Button::new("conflict-error-open", "Open File")
                            .size(ButtonSize::Compact)
                            .style(ButtonStyle::Outlined)
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.open_conflict_in_editor(cx);
                            })),
                    )
                })
            } else if self.loading {
                card.child(Spinner::new().label(if is_conflict {
                    "Loading conflict comparison..."
                } else {
                    "Loading diff..."
                }))
            } else {
                card.child(
                    Icon::new(IconName::File)
                        .size(IconSize::Large)
                        .color(Color::Placeholder),
                )
                .child(
                    Label::new("Select a file to view changes")
                        .size(LabelSize::Small)
                        .color(Color::Muted),
                )
                .child(
                    Label::new("Click a file in the sidebar or detail panel")
                        .size(LabelSize::XSmall)
                        .color(Color::Placeholder),
                )
            };

            return div()
                .id("diff-viewer")
                .v_flex()
                .size_full()
                .bg(colors.editor_background)
                .child(header)
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(card),
                )
                .into_any_element();
        }

        let display_rows = self.display_rows.clone();
        let sbs_rows = self.sbs_rows.clone();
        let three_way_rows = self.three_way_rows.clone();
        // Stage/unstage for working-tree content, apply/revert for everything
        // else; the hunk headers below render one button per entry.
        let hunk_operations = self.source.operations();
        let display_mode = self.display_mode;
        let view: WeakEntity<DiffViewer> = cx.weak_entity();

        let editor_bg = colors.editor_background;
        let text_color = colors.text;
        let text_muted = colors.text_muted;
        let text_placeholder_color = colors.text_placeholder;
        let border_variant = colors.border_variant;
        let vc_added = colors.vc_added;
        let vc_deleted = colors.vc_deleted;
        let conflict_color = Color::Conflict.color(cx);
        let element_bg = colors.element_background;
        let toolbar_bg = colors.toolbar_background;
        let border_focused = colors.border_focused;

        let added_line_bg = gpui::Hsla {
            a: 0.12,
            ..vc_added
        };
        let deleted_line_bg = gpui::Hsla {
            a: 0.12,
            ..vc_deleted
        };

        let added_gutter_bg = gpui::Hsla {
            a: 0.20,
            ..vc_added
        };
        let deleted_gutter_bg = gpui::Hsla {
            a: 0.20,
            ..vc_deleted
        };

        let empty_fill_bg = gpui::Hsla {
            a: 0.04,
            ..text_color
        };

        let gutter_bg = gpui::Hsla {
            a: 0.04,
            ..text_color
        };

        let settings_state = cx.global::<rgitui_settings::SettingsState>();
        let compactness = settings_state.settings().compactness;
        // Side-by-side and three-way columns scroll horizontally per row with no
        // scrollbar, so a line wider than its column is silently clipped and adjacent
        // rows fall out of alignment. Force wrap for those layouts so overflow is
        // always visible and the columns stay aligned; the unified layout keeps the
        // user's wrap preference (it has a global horizontal scrollbar).
        let wrap_enabled = settings_state.settings().diff_wrap_lines
            || matches!(
                self.display_mode,
                DiffDisplayMode::SideBySide | DiffDisplayMode::ThreeWay
            );
        let row_height = compactness.spacing(20.0);
        let hunk_header_height = row_height;

        let highlighted_row = self.highlighted_row;
        let highlight_bg = gpui::Hsla {
            a: 0.10,
            ..colors.text_accent
        };
        let row_hover_bg = gpui::Hsla {
            a: 0.04,
            ..text_color
        };
        let selection_bg = gpui::Hsla {
            a: 0.15,
            ..colors.text_accent
        };
        let selected_lines = self.selected_lines.clone();
        let display_longest_row_ix = self.display_longest_row_ix;

        // Restore scroll position after a display mode switch. The deferred scroll is
        // applied by GPUI's layout pass before the list content is painted, so the
        // user sees the correct scroll position immediately.
        if let Some(top_ix) = self.pending_scroll_top.take() {
            let target_ix = top_ix.min(self.row_count().saturating_sub(1));
            self.scroll_row_into_view(target_ix, cx);
        }

        log::debug!(
            target: "rgitui::diff",
            "render mode={:?} wrap={} row_height={} rows={}",
            display_mode,
            wrap_enabled,
            row_height,
            self.row_count(),
        );

        let list = match display_mode {
            DiffDisplayMode::Unified => {
                let view = view.clone();
                let row_count = display_rows.len();
                let build_unified = move |range: Range<usize>,
                                          window: &mut Window,
                                          _cx: &mut App|
                      -> Vec<gpui::AnyElement> {
                    range
                        .map(|i| {
                            let row = &display_rows[i];
                            match row {
                                DisplayRow::HunkHeader {
                                    header,
                                    context_name,
                                    hunk_index,
                                } => {
                                    let line_range: SharedString =
                                        Self::extract_line_range(header).into();
                                    let ctx_name: SharedString = context_name.clone().into();
                                    let has_context = !context_name.is_empty();
                                    let idx = *hunk_index;
                                    let view_hunk = view.clone();
                                    let view_hunk_drag = view.clone();
                                    let is_hunk_selected =
                                        selected_lines.as_ref().is_some_and(|r| r.contains(&i));
                                    let hunk_bg = if is_hunk_selected {
                                        selection_bg
                                    } else {
                                        element_bg
                                    };

                                    let mut hunk_row = div()
                                        .id(ElementId::NamedInteger(
                                            "hunk-header".into(),
                                            i as u64,
                                        ))
                                        .h_flex()
                                        .h(px(hunk_header_height))
                                        .w_full()
                                        .min_w_0()
                                        .overflow_hidden()
                                        .px(px(8.))
                                        .py(px(4.))
                                        .items_center()
                                        .gap(px(6.))
                                        .bg(hunk_bg)
                                        .border_t_1()
                                        .border_b_1()
                                        .border_color(border_variant)
                                        .cursor(CursorStyle::IBeam)
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |event: &MouseDownEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                let shift = event.modifiers.shift;
                                                view_hunk
                                                    .update(cx, |this, cx| {
                                                        this.begin_mouse_selection(i, shift, cx);
                                                    })
                                                    .ok();
                                            },
                                        )
                                        .on_mouse_move(
                                            move |event: &MouseMoveEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                if event.dragging() {
                                                    view_hunk_drag
                                                        .update(cx, |this, cx| {
                                                            this.extend_mouse_selection(i, cx);
                                                        })
                                                        .ok();
                                                }
                                            },
                                        )
                                        .child(
                                            div()
                                                .flex_shrink_0()
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_muted)
                                                .child(line_range),
                                        );

                                    if has_context {
                                        hunk_row = hunk_row.child(
                                            div()
                                                .flex_1()
                                                .min_w_0()
                                                .overflow_hidden()
                                                .text_xs()
                                                .text_color(text_placeholder_color)
                                                .italic()
                                                .child(
                                                    Label::new(ctx_name)
                                                        .size(LabelSize::XSmall)
                                                        .color(Color::Placeholder)
                                                        .italic()
                                                        .truncate(),
                                                ),
                                        );
                                    } else {
                                        hunk_row = hunk_row.child(div().flex_1().min_w_0());
                                    }

                                    // One button per operation the source
                                    // supports: Stage/Unstage for working-tree
                                    // content, Apply/Revert for a commit, a
                                    // stash, or a comparison.
                                    let mut hunk_actions =
                                        div().h_flex().gap_1().flex_shrink_0().items_center();
                                    for operation in hunk_operations {
                                        let operation = *operation;
                                        let button_view = view.clone();
                                        hunk_actions = hunk_actions.child(
                                            Button::new(
                                                SharedString::from(format!(
                                                    "hunk-{}-{}",
                                                    operation.key(),
                                                    idx
                                                )),
                                                operation.compact_hunk_button_label(),
                                            )
                                            .size(ButtonSize::Compact)
                                            .style(ButtonStyle::Subtle)
                                            .tooltip(operation.hunk_button_label())
                                            .on_click(
                                                move |_: &ClickEvent,
                                                      _: &mut Window,
                                                      cx: &mut App| {
                                                    button_view
                                                        .update(cx, |_this, cx| {
                                                            cx.emit(DiffViewerEvent::for_hunk(
                                                                operation, idx,
                                                            ));
                                                        })
                                                        .ok();
                                                },
                                            ),
                                        );
                                    }
                                    hunk_row = hunk_row.child(hunk_actions);

                                    hunk_row.into_any_element()
                                }
                                DisplayRow::Line {
                                    old_num,
                                    new_num,
                                    styled,
                                    kind,
                                } => {
                                    let (prefix, text_col, line_bg, gutter_accent) = match kind {
                                        DisplayLineKind::Context => {
                                            (" ", text_color, editor_bg, gutter_bg)
                                        }
                                        DisplayLineKind::Addition => {
                                            ("+", vc_added, added_line_bg, added_gutter_bg)
                                        }
                                        DisplayLineKind::Deletion => {
                                            ("-", vc_deleted, deleted_line_bg, deleted_gutter_bg)
                                        }
                                    };

                                    let old_str: SharedString = old_num
                                        .map(|n| format!("{:>4}", n))
                                        .unwrap_or_else(|| "    ".to_string())
                                        .into();
                                    let new_str: SharedString = new_num
                                        .map(|n| format!("{:>4}", n))
                                        .unwrap_or_else(|| "    ".to_string())
                                        .into();
                                    let prefix_str: SharedString = prefix.into();
                                    let is_highlighted = highlighted_row == Some(i);
                                    let is_selected =
                                        selected_lines.as_ref().is_some_and(|r| r.contains(&i));
                                    let effective_bg = if is_selected {
                                        selection_bg
                                    } else if is_highlighted {
                                        highlight_bg
                                    } else {
                                        line_bg
                                    };

                                    let view_line = view.clone();
                                    let view_line_drag = view.clone();
                                    let mut row_div = div()
                                        .id(ElementId::NamedInteger(
                                            "diff-line".into(),
                                            i as u64,
                                        ))
                                        .bg(effective_bg)
                                        .hover(move |s| s.bg(row_hover_bg))
                                        .cursor(CursorStyle::IBeam)
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |event: &MouseDownEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                let shift = event.modifiers.shift;
                                                view_line
                                                    .update(cx, |this, cx| {
                                                        this.begin_mouse_selection(i, shift, cx);
                                                    })
                                                    .ok();
                                            },
                                        )
                                        .on_mouse_move(
                                            move |event: &MouseMoveEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                if event.dragging() {
                                                    view_line_drag
                                                        .update(cx, |this, cx| {
                                                            this.extend_mouse_selection(i, cx);
                                                        })
                                                        .ok();
                                                }
                                            },
                                        );
                                    if wrap_enabled {
                                        // Wrap mode: w_full makes the row span the list width so
                                        // bg is consistent; flex_shrink_0 keeps the row from being
                                        // squeezed vertically when content totals exceed viewport,
                                        // which would make wrapped lines overlap the row below.
                                        row_div = row_div
                                            .w_full()
                                            .flex_shrink_0()
                                            .h_flex()
                                            .items_start()
                                            .min_h(px(row_height));
                                    } else {
                                        // No-wrap: w_full spans available width so bg is
                                        // consistent across the scrolled area; the row's min-
                                        // content width (sum of children's min-content widths)
                                        // is what the list uses to determine horizontal scroll
                                        // range.
                                        row_div = row_div.w_full().h_flex().h(px(row_height));
                                    }

                                    let make_gutter_cell = |val: SharedString, width: f32| {
                                        div()
                                            .w(px(width))
                                            .flex_shrink_0()
                                            .min_h(px(row_height))
                                            .flex()
                                            .items_center()
                                            .justify_end()
                                            .bg(gutter_accent)
                                            .border_r_1()
                                            .border_color(border_variant)
                                            .text_xs()
                                            .font_family("Lilex")
                                            .text_color(text_muted)
                                            .pr(px(4.))
                                            .child(val)
                                    };
                                    let prefix_cell = div()
                                        .w(px(18.))
                                        .flex_shrink_0()
                                        .min_h(px(row_height))
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .text_xs()
                                        .font_family("Lilex")
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(text_col)
                                        .child(prefix_str);

                                    // Text content. Wrap mode uses a flex child with min_w_0 so
                                    // the text layouter receives a bounded width and can word-
                                    // wrap. No-wrap mode lets the text set its natural width so
                                    // the enclosing list can scroll horizontally.
                                    let content_area: gpui::AnyElement = if wrap_enabled {
                                        // No vertical padding in wrap mode — it adds ~4px
                                        // between logical lines because the row grows with
                                        // the padded content height, not the text box.
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .pl(px(6.))
                                            .text_xs()
                                            .font_family("Lilex")
                                            .text_color(text_col)
                                            .child(Self::render_styled_text(
                                                window, styled, text_col, row_height, true,
                                            ))
                                            .into_any_element()
                                    } else {
                                        div()
                                            .h_flex()
                                            .h_full()
                                            .pl(px(6.))
                                            .pr(px(12.))
                                            .text_xs()
                                            .font_family("Lilex")
                                            .text_color(text_col)
                                            .child(Self::render_styled_text(
                                                window, styled, text_col, row_height, false,
                                            ))
                                            .into_any_element()
                                    };

                                    row_div
                                        .child(make_gutter_cell(old_str, 44.))
                                        .child(make_gutter_cell(new_str, 44.))
                                        .child(prefix_cell)
                                        .child(content_area)
                                        .into_any_element()
                                }
                            }
                        })
                        .collect()
                };

                if wrap_enabled {
                    // Virtualized wrap mode: `gpui::list` caches per-row heights in a
                    // SumTree so only the visible window (plus overdraw) renders each
                    // frame. `overflow_x_hidden` on the wrapper prevents any
                    // non-wrapping long line from bleeding into neighboring panels.
                    let list_body = list(self.wrap_list_state.clone(), move |ix, window, cx| {
                        build_unified(ix..ix + 1, window, cx)
                            .into_iter()
                            .next()
                            .expect("build_unified returns exactly one row")
                    })
                    .with_sizing_behavior(gpui::ListSizingBehavior::Auto)
                    .flex_grow(1.0);
                    // v_flex parent so `list_body`'s `flex_grow` actually
                    // gives it a definite height — without it the List is
                    // 0px tall and renders nothing in wrap mode.
                    div()
                        .id("diff-lines-wrap")
                        .v_flex()
                        .flex_grow(1.0)
                        .min_h(px(0.))
                        .min_w_0()
                        .overflow_x_hidden()
                        .child(list_body)
                        .into_any_element()
                } else {
                    uniform_list("diff-lines", row_count, build_unified)
                        .with_sizing_behavior(ListSizingBehavior::Auto)
                        .with_horizontal_sizing_behavior(
                            ListHorizontalSizingBehavior::Unconstrained,
                        )
                        .with_width_from_item(Some(display_longest_row_ix))
                        .flex_grow(1.0)
                        .track_scroll(&self.scroll_handle)
                        .into_any_element()
                }
            }
            DiffDisplayMode::SideBySide => {
                let view = view.clone();
                let row_count = sbs_rows.len();
                let build_sbs = move |range: Range<usize>,
                                      window: &mut Window,
                                      _cx: &mut App|
                      -> Vec<gpui::AnyElement> {
                    range
                        .map(|i| {
                            let row = &sbs_rows[i];
                            match row {
                                SideBySideRow::HunkHeader {
                                    header,
                                    context_name,
                                    hunk_index,
                                } => {
                                    let line_range: SharedString =
                                        Self::extract_line_range(header).into();
                                    let ctx_name: SharedString = context_name.clone().into();
                                    let has_context = !context_name.is_empty();
                                    let idx = *hunk_index;
                                    let view_sbs_hunk = view.clone();
                                    let view_sbs_hunk_drag = view.clone();
                                    let is_sbs_hunk_selected =
                                        selected_lines.as_ref().is_some_and(|r| r.contains(&i));
                                    let sbs_hunk_bg = if is_sbs_hunk_selected {
                                        selection_bg
                                    } else {
                                        element_bg
                                    };

                                    let mut hunk_row = div()
                                        .id(ElementId::NamedInteger(
                                            "sbs-hunk-header".into(),
                                            i as u64,
                                        ))
                                        .h_flex()
                                        .h(px(hunk_header_height))
                                        .w_full()
                                        .min_w_0()
                                        .overflow_hidden()
                                        .px(px(8.))
                                        .py(px(4.))
                                        .items_center()
                                        .gap(px(6.))
                                        .bg(sbs_hunk_bg)
                                        .border_t_1()
                                        .border_b_1()
                                        .border_color(border_variant)
                                        .cursor(CursorStyle::IBeam)
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |event: &MouseDownEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                let shift = event.modifiers.shift;
                                                view_sbs_hunk
                                                    .update(cx, |this, cx| {
                                                        this.begin_mouse_selection(i, shift, cx);
                                                    })
                                                    .ok();
                                            },
                                        )
                                        .on_mouse_move(
                                            move |event: &MouseMoveEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                if event.dragging() {
                                                    view_sbs_hunk_drag
                                                        .update(cx, |this, cx| {
                                                            this.extend_mouse_selection(i, cx);
                                                        })
                                                        .ok();
                                                }
                                            },
                                        )
                                        .child(
                                            div()
                                                .flex_shrink_0()
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_muted)
                                                .child(line_range),
                                        );

                                    if has_context {
                                        hunk_row = hunk_row.child(
                                            div()
                                                .flex_1()
                                                .min_w_0()
                                                .overflow_hidden()
                                                .text_xs()
                                                .text_color(text_placeholder_color)
                                                .italic()
                                                .child(
                                                    Label::new(ctx_name)
                                                        .size(LabelSize::XSmall)
                                                        .color(Color::Placeholder)
                                                        .italic()
                                                        .truncate(),
                                                ),
                                        );
                                    } else {
                                        hunk_row = hunk_row.child(div().flex_1().min_w_0());
                                    }

                                    // Same operations as the unified header, from
                                    // the same source decision.
                                    let mut hunk_actions =
                                        div().h_flex().gap_1().flex_shrink_0().items_center();
                                    for operation in hunk_operations {
                                        let operation = *operation;
                                        let button_view = view.clone();
                                        hunk_actions = hunk_actions.child(
                                            Button::new(
                                                SharedString::from(format!(
                                                    "sbs-hunk-{}-{}",
                                                    operation.key(),
                                                    idx
                                                )),
                                                operation.compact_hunk_button_label(),
                                            )
                                            .size(ButtonSize::Compact)
                                            .style(ButtonStyle::Subtle)
                                            .tooltip(operation.hunk_button_label())
                                            .on_click(
                                                move |_: &ClickEvent,
                                                      _: &mut Window,
                                                      cx: &mut App| {
                                                    button_view
                                                        .update(cx, |_this, cx| {
                                                            cx.emit(DiffViewerEvent::for_hunk(
                                                                operation, idx,
                                                            ));
                                                        })
                                                        .ok();
                                                },
                                            ),
                                        );
                                    }
                                    hunk_row = hunk_row.child(hunk_actions);

                                    hunk_row.into_any_element()
                                }
                                SideBySideRow::Pair {
                                    left_num,
                                    left_styled,
                                    left_kind,
                                    right_num,
                                    right_styled,
                                    right_kind,
                                } => {
                                    let (left_bg, left_gutter_bg, left_text_col) = match left_kind {
                                        SideBySideLineKind::Context => {
                                            (editor_bg, gutter_bg, text_color)
                                        }
                                        SideBySideLineKind::Deletion => {
                                            (deleted_line_bg, deleted_gutter_bg, vc_deleted)
                                        }
                                        SideBySideLineKind::Addition => {
                                            (added_line_bg, added_gutter_bg, vc_added)
                                        }
                                        SideBySideLineKind::Empty => {
                                            (empty_fill_bg, gutter_bg, text_placeholder_color)
                                        }
                                    };
                                    let (right_bg, right_gutter_bg, right_text_col) =
                                        match right_kind {
                                            SideBySideLineKind::Context => {
                                                (editor_bg, gutter_bg, text_color)
                                            }
                                            SideBySideLineKind::Addition => {
                                                (added_line_bg, added_gutter_bg, vc_added)
                                            }
                                            SideBySideLineKind::Deletion => {
                                                (deleted_line_bg, deleted_gutter_bg, vc_deleted)
                                            }
                                            SideBySideLineKind::Empty => {
                                                (empty_fill_bg, gutter_bg, text_placeholder_color)
                                            }
                                        };

                                    let left_num_str: SharedString = left_num
                                        .map(|n| format!("{:>4}", n))
                                        .unwrap_or_else(|| "    ".to_string())
                                        .into();
                                    let right_num_str: SharedString = right_num
                                        .map(|n| format!("{:>4}", n))
                                        .unwrap_or_else(|| "    ".to_string())
                                        .into();
                                    let is_highlighted = highlighted_row == Some(i);
                                    let is_sbs_selected =
                                        selected_lines.as_ref().is_some_and(|r| r.contains(&i));
                                    let effective_left_bg = if is_sbs_selected {
                                        selection_bg
                                    } else if is_highlighted {
                                        highlight_bg
                                    } else {
                                        left_bg
                                    };
                                    let effective_right_bg = if is_sbs_selected {
                                        selection_bg
                                    } else if is_highlighted {
                                        highlight_bg
                                    } else {
                                        right_bg
                                    };

                                    let view_sbs_line = view.clone();
                                    let view_sbs_line_drag = view.clone();
                                    let mut row_div = div()
                                        .id(ElementId::NamedInteger(
                                            "sbs-line".into(),
                                            i as u64,
                                        ))
                                        .w_full()
                                        .hover(move |s| s.bg(row_hover_bg))
                                        .cursor(CursorStyle::IBeam)
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |event: &MouseDownEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                let shift = event.modifiers.shift;
                                                view_sbs_line
                                                    .update(cx, |this, cx| {
                                                        this.begin_mouse_selection(i, shift, cx);
                                                    })
                                                    .ok();
                                            },
                                        )
                                        .on_mouse_move(
                                            move |event: &MouseMoveEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                if event.dragging() {
                                                    view_sbs_line_drag
                                                        .update(cx, |this, cx| {
                                                            this.extend_mouse_selection(i, cx);
                                                        })
                                                        .ok();
                                                }
                                            },
                                        );
                                    if wrap_enabled {
                                        row_div = row_div
                                            .flex_shrink_0()
                                            .h_flex()
                                            .items_start()
                                            .min_h(px(row_height));
                                    } else {
                                        row_div = row_div.h_flex().h(px(row_height));
                                    }

                                    // Build gutter (fixed 44px wide, column-height).
                                    let make_gutter = |num_str: SharedString,
                                                       gutter_bg_val: gpui::Hsla|
                                     -> gpui::AnyElement {
                                        let mut g = div()
                                            .w(px(44.))
                                            .flex_shrink_0()
                                            .flex()
                                            .items_center()
                                            .justify_end()
                                            .bg(gutter_bg_val)
                                            .border_r_1()
                                            .border_color(border_variant)
                                            .text_xs()
                                            .font_family("Lilex")
                                            .text_color(text_muted)
                                            .pr(px(4.))
                                            .child(num_str);
                                        g = if wrap_enabled {
                                            g.min_h(px(row_height))
                                        } else {
                                            g.h_full()
                                        };
                                        g.into_any_element()
                                    };

                                    // Build a column: gutter (outside scroll) + text.
                                    // - wrap mode: text_div is a plain block with flex_1 +
                                    //   min_w_0 so it inherits column's flex share as its
                                    //   max width; render_styled_text returns StyledText
                                    //   directly so the text layouter word-wraps.
                                    // - no-wrap mode: an inner scroll area (with id) holds
                                    //   the text. The gutter stays OUTSIDE that scroll area
                                    //   so it remains visible when the text scrolls right.
                                    let build_column = |side: &'static str,
                                                        bg_val: gpui::Hsla,
                                                        gutter_bg_val: gpui::Hsla,
                                                        num_str: SharedString,
                                                        text_col_val: gpui::Hsla,
                                                        styled: &StyledLine,
                                                        window: &mut Window|
                                     -> gpui::AnyElement {
                                        if wrap_enabled {
                                            let text_div = div()
                                                .flex_1()
                                                .min_w_0()
                                                .pl(px(6.))
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_col_val)
                                                .child(Self::render_styled_text(
                                                    window,
                                                    styled,
                                                    text_col_val,
                                                    row_height,
                                                    true,
                                                ));
                                            div()
                                                .h_flex()
                                                .flex_1()
                                                .min_w_0()
                                                .items_start()
                                                .min_h(px(row_height))
                                                .bg(bg_val)
                                                .child(make_gutter(num_str, gutter_bg_val))
                                                .child(text_div)
                                                .into_any_element()
                                        } else {
                                            // Split view: each column has a fixed flex share
                                            // of row width. Use per-row overflow_x_scroll so
                                            // long lines scroll inside the column instead of
                                            // bleeding into the adjacent column.
                                            let scroll_area = div()
                                                .id(ElementId::NamedInteger(
                                                    side.into(),
                                                    i as u64,
                                                ))
                                                .h_flex()
                                                .flex_1()
                                                .min_w_0()
                                                .h_full()
                                                .pl(px(6.))
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_col_val)
                                                .overflow_x_scroll()
                                                .child(Self::render_styled_text(
                                                    window,
                                                    styled,
                                                    text_col_val,
                                                    row_height,
                                                    false,
                                                ));
                                            div()
                                                .h_flex()
                                                .flex_1()
                                                .min_w_0()
                                                .h_full()
                                                .bg(bg_val)
                                                .child(make_gutter(num_str, gutter_bg_val))
                                                .child(scroll_area)
                                                .into_any_element()
                                        }
                                    };

                                    let mut divider =
                                        div().w(px(2.)).flex_shrink_0().bg(border_variant);
                                    divider = if wrap_enabled {
                                        divider.min_h(px(row_height))
                                    } else {
                                        divider.h_full()
                                    };

                                    row_div
                                        .child(build_column(
                                            "sbs-left",
                                            effective_left_bg,
                                            left_gutter_bg,
                                            left_num_str,
                                            left_text_col,
                                            left_styled,
                                            window,
                                        ))
                                        .child(divider)
                                        .child(build_column(
                                            "sbs-right",
                                            effective_right_bg,
                                            right_gutter_bg,
                                            right_num_str,
                                            right_text_col,
                                            right_styled,
                                            window,
                                        ))
                                        .into_any_element()
                                }
                            }
                        })
                        .collect()
                };

                if wrap_enabled {
                    let list_body = list(self.wrap_list_state.clone(), move |ix, window, cx| {
                        build_sbs(ix..ix + 1, window, cx)
                            .into_iter()
                            .next()
                            .expect("build_sbs returns exactly one row")
                    })
                    .with_sizing_behavior(gpui::ListSizingBehavior::Auto)
                    .flex_grow(1.0);
                    div()
                        .id("diff-lines-sbs-wrap")
                        .v_flex()
                        .flex_grow(1.0)
                        .min_h(px(0.))
                        .min_w_0()
                        .overflow_x_hidden()
                        .child(list_body)
                        .into_any_element()
                } else {
                    // Split view: each column has an independent per-row horizontal
                    // scroll area, so the list itself should be viewport-width
                    // (no Unconstrained sizing, no global horizontal scrollbar).
                    uniform_list("diff-lines-sbs", row_count, build_sbs)
                        .with_sizing_behavior(ListSizingBehavior::Auto)
                        .flex_grow(1.0)
                        .track_scroll(&self.scroll_handle)
                        .into_any_element()
                }
            }
            DiffDisplayMode::ThreeWay => {
                let view = view.clone();
                let tw_rows = three_way_rows.clone();
                let row_count = tw_rows.len();
                let build_tw = move |range: Range<usize>,
                                     window: &mut Window,
                                     _cx: &mut App|
                      -> Vec<gpui::AnyElement> {
                    range
                        .map(|i| {
                            let row = &tw_rows[i];
                            match row {
                                ThreeWayRow::HunkHeader {
                                    header,
                                    context_name,
                                    conflict_index,
                                    resolved,
                                    allow_both,
                                } => {
                                    let is_selected = selected_lines
                                        .as_ref()
                                        .is_some_and(|range| range.contains(&i));
                                    let header_bg = if is_selected {
                                        selection_bg
                                    } else {
                                        element_bg
                                    };
                                    let view_hunk = view.clone();
                                    let view_hunk_drag = view.clone();
                                    let current_view = view.clone();
                                    let incoming_view = view.clone();
                                    let both_current_view = view.clone();
                                    let both_incoming_view = view.clone();
                                    let reset_view = view.clone();
                                    let conflict_index = *conflict_index;
                                    div()
                                        .id(ElementId::NamedInteger(
                                            "tw-hunk-header".into(),
                                            i as u64,
                                        ))
                                        .h_flex()
                                        .h(px(hunk_header_height))
                                        .w_full()
                                        .px(px(8.))
                                        .py(px(4.))
                                        .items_center()
                                        .gap(px(6.))
                                        .bg(header_bg)
                                        .border_t_1()
                                        .border_b_1()
                                        .border_color(border_variant)
                                        .cursor(CursorStyle::IBeam)
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |event: &MouseDownEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                let shift = event.modifiers.shift;
                                                view_hunk
                                                    .update(cx, |this, cx| {
                                                        this.begin_mouse_selection(i, shift, cx);
                                                    })
                                                    .ok();
                                            },
                                        )
                                        .on_mouse_move(
                                            move |event: &MouseMoveEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                if event.dragging() {
                                                    view_hunk_drag
                                                        .update(cx, |this, cx| {
                                                            this.extend_mouse_selection(i, cx);
                                                        })
                                                        .ok();
                                                }
                                            },
                                        )
                                        .child(
                                            div()
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(if *resolved {
                                                    vc_added
                                                } else {
                                                    conflict_color
                                                })
                                                .font_weight(FontWeight::SEMIBOLD)
                                                .child(header.clone()),
                                        )
                                        .child(
                                            div()
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_muted)
                                                .ml(px(8.))
                                                .child(format!("[{}]", context_name)),
                                        )
                                        .child(div().flex_1())
                                        .child(
                                            Button::new(
                                                ElementId::NamedInteger(
                                                    "tw-use-current".into(),
                                                    conflict_index as u64,
                                                ),
                                                "Use Current",
                                            )
                                            .size(ButtonSize::Compact)
                                            .style(ButtonStyle::Subtle)
                                            .tooltip("Put Current into Result")
                                            .on_click(move |_: &ClickEvent, _, cx| {
                                                current_view
                                                    .update(cx, |this, cx| {
                                                        this.set_conflict_choice(
                                                            conflict_index,
                                                            Some(ConflictChoice::Ours),
                                                            cx,
                                                        );
                                                    })
                                                    .ok();
                                            }),
                                        )
                                        .when(*allow_both, |element| {
                                            element
                                                .child(
                                                    Button::new(
                                                        ElementId::NamedInteger(
                                                            "tw-use-both-current".into(),
                                                            conflict_index as u64,
                                                        ),
                                                        "Both C→I",
                                                    )
                                                    .size(ButtonSize::Compact)
                                                    .style(ButtonStyle::Subtle)
                                                    .tooltip("Current, then Incoming")
                                                    .on_click(move |_: &ClickEvent, _, cx| {
                                                        both_current_view
                                                            .update(cx, |this, cx| {
                                                                this.set_conflict_choice(
                                                                    conflict_index,
                                                                    Some(
                                                                        ConflictChoice::BothOursFirst,
                                                                    ),
                                                                    cx,
                                                                );
                                                            })
                                                            .ok();
                                                    }),
                                                )
                                                .child(
                                                    Button::new(
                                                        ElementId::NamedInteger(
                                                            "tw-use-both-incoming".into(),
                                                            conflict_index as u64,
                                                        ),
                                                        "Both I→C",
                                                    )
                                                    .size(ButtonSize::Compact)
                                                    .style(ButtonStyle::Subtle)
                                                    .tooltip("Incoming, then Current")
                                                    .on_click(move |_: &ClickEvent, _, cx| {
                                                        both_incoming_view
                                                            .update(cx, |this, cx| {
                                                                this.set_conflict_choice(
                                                                    conflict_index,
                                                                    Some(
                                                                        ConflictChoice::BothTheirsFirst,
                                                                    ),
                                                                    cx,
                                                                );
                                                            })
                                                            .ok();
                                                    }),
                                                )
                                        })
                                        .child(
                                            Button::new(
                                                ElementId::NamedInteger(
                                                    "tw-use-incoming".into(),
                                                    conflict_index as u64,
                                                ),
                                                "Use Incoming",
                                            )
                                            .size(ButtonSize::Compact)
                                            .style(ButtonStyle::Subtle)
                                            .tooltip("Put Incoming into Result")
                                            .on_click(move |_: &ClickEvent, _, cx| {
                                                incoming_view
                                                    .update(cx, |this, cx| {
                                                        this.set_conflict_choice(
                                                            conflict_index,
                                                            Some(ConflictChoice::Theirs),
                                                            cx,
                                                        );
                                                    })
                                                    .ok();
                                            }),
                                        )
                                        .when(*resolved, |element| {
                                            element.child(
                                                Button::new(
                                                    ElementId::NamedInteger(
                                                        "tw-reset".into(),
                                                        conflict_index as u64,
                                                    ),
                                                    "Reset",
                                                )
                                                .size(ButtonSize::Compact)
                                                .style(ButtonStyle::Subtle)
                                                .tooltip("Make this conflict unresolved again")
                                                .on_click(move |_: &ClickEvent, _, cx| {
                                                    reset_view
                                                        .update(cx, |this, cx| {
                                                            this.set_conflict_choice(
                                                                conflict_index,
                                                                None,
                                                                cx,
                                                            );
                                                        })
                                                        .ok();
                                                }),
                                            )
                                        })
                                        .into_any_element()
                                }
                                ThreeWayRow::Triple {
                                    left_num,
                                    left_styled,
                                    left_kind,
                                    mid_num,
                                    mid_styled,
                                    mid_kind,
                                    right_num,
                                    right_styled,
                                    right_kind,
                                } => {
                                    let conflict_bg =
                                        |kind: ThreeWayLineKind, base: gpui::Hsla| -> gpui::Hsla {
                                            match kind {
                                                ThreeWayLineKind::Conflict => {
                                                    gpui::Hsla { a: 0.2, ..base }
                                                }
                                                ThreeWayLineKind::Resolved => gpui::Hsla {
                                                    a: 0.12,
                                                    ..vc_added
                                                },
                                                _ => base,
                                            }
                                        };
                                    let is_highlighted = highlighted_row == Some(i);
                                    let is_selected = selected_lines
                                        .as_ref()
                                        .is_some_and(|range| range.contains(&i));
                                    let row_bg = |base: gpui::Hsla| {
                                        if is_selected {
                                            selection_bg
                                        } else if is_highlighted {
                                            highlight_bg
                                        } else {
                                            base
                                        }
                                    };
                                    let left_bg = row_bg(conflict_bg(*left_kind, editor_bg));
                                    let mid_bg = row_bg(conflict_bg(*mid_kind, editor_bg));
                                    let right_bg = row_bg(conflict_bg(*right_kind, editor_bg));
                                    let left_text_col = match left_kind {
                                        ThreeWayLineKind::Conflict => conflict_color,
                                        _ => text_color,
                                    };
                                    let right_text_col = match right_kind {
                                        ThreeWayLineKind::Conflict => conflict_color,
                                        _ => text_color,
                                    };
                                    let left_num_str: SharedString =
                                        left_num.map(|n| n.to_string()).unwrap_or_default().into();
                                    let mid_num_str: SharedString =
                                        mid_num.map(|n| n.to_string()).unwrap_or_default().into();
                                    let right_num_str: SharedString =
                                        right_num.map(|n| n.to_string()).unwrap_or_default().into();

                                    let view_row = view.clone();
                                    let view_row_drag = view.clone();
                                    let mut row_div = div()
                                        .id(ElementId::NamedInteger("tw-row".into(), i as u64))
                                        .w_full()
                                        .flex()
                                        .cursor(CursorStyle::IBeam)
                                        .border_b_1()
                                        .border_color(gpui::Hsla {
                                            a: 0.5,
                                            ..border_variant
                                        })
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |event: &MouseDownEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                let shift = event.modifiers.shift;
                                                view_row
                                                    .update(cx, |this, cx| {
                                                        this.begin_mouse_selection(i, shift, cx);
                                                    })
                                                    .ok();
                                            },
                                        )
                                        .on_mouse_move(
                                            move |event: &MouseMoveEvent,
                                                  _window: &mut Window,
                                                  cx: &mut App| {
                                                if event.dragging() {
                                                    view_row_drag
                                                        .update(cx, |this, cx| {
                                                            this.extend_mouse_selection(i, cx);
                                                        })
                                                        .ok();
                                                }
                                            },
                                        );
                                    row_div = if wrap_enabled {
                                        row_div.flex_shrink_0().items_start().min_h(px(row_height))
                                    } else {
                                        row_div.h(px(row_height))
                                    };

                                    // Same pattern as split view: gutter is OUTSIDE the
                                    // scroll area so the line number stays visible while
                                    // the text scrolls horizontally.
                                    let make_col = |side: &'static str,
                                                    bg: gpui::Hsla,
                                                    num_str: SharedString,
                                                    text_col_val: gpui::Hsla,
                                                    styled: &StyledLine,
                                                    border_right: bool,
                                                    window: &mut Window|
                                     -> gpui::AnyElement {
                                        let mut num_div = div()
                                            .w(px(32.))
                                            .flex_shrink_0()
                                            .text_xs()
                                            .font_family("Lilex")
                                            .text_color(text_muted)
                                            .justify_end();
                                        if wrap_enabled {
                                            num_div = num_div.min_h(px(row_height));
                                        }
                                        if wrap_enabled {
                                            let text_div = div()
                                                .flex_1()
                                                .min_w_0()
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_col_val)
                                                .child(Self::render_styled_text(
                                                    window,
                                                    styled,
                                                    text_col_val,
                                                    row_height,
                                                    true,
                                                ));
                                            let mut col = div()
                                                .flex_1()
                                                .min_w_0()
                                                .flex()
                                                .items_start()
                                                .min_h(px(row_height))
                                                .px(px(4.))
                                                .bg(bg)
                                                .gap(px(2.));
                                            if border_right {
                                                col = col
                                                    .border_r_1()
                                                    .border_color(border_variant);
                                            }
                                            col.child(num_div.child(num_str))
                                                .child(text_div)
                                                .into_any_element()
                                        } else {
                                            // Three-way split: each column is 1/3 of row width.
                                            // Per-row overflow_x_scroll clips long lines inside
                                            // their column rather than bleeding across the
                                            // dividers into adjacent versions.
                                            let scroll_area = div()
                                                .id(ElementId::NamedInteger(
                                                    side.into(),
                                                    i as u64,
                                                ))
                                                .h_flex()
                                                .flex_1()
                                                .min_w_0()
                                                .h_full()
                                                .text_xs()
                                                .font_family("Lilex")
                                                .text_color(text_col_val)
                                                .overflow_x_scroll()
                                                .child(Self::render_styled_text(
                                                    window,
                                                    styled,
                                                    text_col_val,
                                                    row_height,
                                                    false,
                                                ));
                                            let mut col = div()
                                                .flex_1()
                                                .min_w_0()
                                                .h_flex()
                                                .h_full()
                                                .px(px(4.))
                                                .bg(bg)
                                                .gap(px(2.));
                                            if border_right {
                                                col = col
                                                    .border_r_1()
                                                    .border_color(border_variant);
                                            }
                                            col.child(num_div.child(num_str))
                                                .child(scroll_area)
                                                .into_any_element()
                                        }
                                    };

                                    row_div
                                        .child(make_col(
                                            "tw-left",
                                            left_bg,
                                            left_num_str.clone(),
                                            left_text_col,
                                            left_styled,
                                            true,
                                            window,
                                        ))
                                        .child(make_col(
                                            "tw-mid",
                                            mid_bg,
                                            mid_num_str.clone(),
                                            text_color,
                                            mid_styled,
                                            true,
                                            window,
                                        ))
                                        .child(make_col(
                                            "tw-right",
                                            right_bg,
                                            right_num_str.clone(),
                                            right_text_col,
                                            right_styled,
                                            false,
                                            window,
                                        ))
                                        .into_any_element()
                                }
                            }
                        })
                        .collect()
                };

                if wrap_enabled {
                    let list_body = list(self.wrap_list_state.clone(), move |ix, window, cx| {
                        build_tw(ix..ix + 1, window, cx)
                            .into_iter()
                            .next()
                            .expect("build_tw returns exactly one row")
                    })
                    .with_sizing_behavior(gpui::ListSizingBehavior::Auto)
                    .flex_grow(1.0);
                    div()
                        .id("diff-lines-tw-wrap")
                        .v_flex()
                        .flex_grow(1.0)
                        .min_h(px(0.))
                        .min_w_0()
                        .overflow_x_hidden()
                        .child(list_body)
                        .into_any_element()
                } else {
                    uniform_list("diff-lines-tw", row_count, build_tw)
                        .with_sizing_behavior(ListSizingBehavior::Auto)
                        .flex_grow(1.0)
                        .track_scroll(&self.scroll_handle)
                        .into_any_element()
                }
            }
        };

        let is_focused = self.focus_handle.is_focused(window);
        let focus_ring_color = if is_focused {
            border_focused
        } else {
            gpui::transparent_black()
        };
        let mut container = div()
            .id("diff-viewer")
            .track_focus(&self.focus_handle)
            // Bindings scoped to `DiffViewer` resolve to `diff::*` actions the
            // workspace root handles; this crate cannot name them itself.
            .key_context(if self.display_mode == DiffDisplayMode::ThreeWay {
                "DiffViewer ConflictResolver"
            } else {
                "DiffViewer"
            })
            .on_mouse_up(MouseButton::Left, cx.listener(Self::end_mouse_selection))
            .on_mouse_up_out(MouseButton::Left, cx.listener(Self::end_mouse_selection))
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                this.focus_handle.focus(window, cx);
                cx.notify();
            }))
            .v_flex()
            .size_full()
            .overflow_hidden()
            // `relative` so the file-operations menu can be positioned against
            // this container rather than the window.
            .relative()
            // Focus ring so j/k navigation is discoverable: an accent border when the
            // pane holds keyboard focus, a transparent border of the same width
            // otherwise so toggling focus never shifts layout or adds chrome.
            .border_1()
            .border_color(focus_ring_color)
            .bg(editor_bg);

        if let Some(path) = &self.file_path {
            let (additions, deletions) = Self::count_changes(&self.display_rows);
            let unresolved = self.unresolved_conflict_count();
            let total_conflicts = self
                .three_way_diff
                .as_ref()
                .map(|diff| diff.conflict_count())
                .unwrap_or(0);
            let file_icon = Self::icon_for_path(path);
            let path_str: SharedString = path.clone().into();
            let mode_label = match self.display_mode {
                DiffDisplayMode::Unified => "Split",
                DiffDisplayMode::SideBySide => "Unified",
                DiffDisplayMode::ThreeWay => "3-Way",
            };

            container = container.child(
                div()
                    .h_flex()
                    .w_full()
                    .h(px(26.))
                    .px(px(10.))
                    .gap(px(6.))
                    .items_center()
                    .bg(toolbar_bg)
                    .border_b_1()
                    .border_color(border_variant)
                    .child(
                        Icon::new(file_icon)
                            .size(IconSize::Small)
                            .color(Color::Muted),
                    )
                    .child(
                        Label::new(path_str)
                            .size(LabelSize::Small)
                            .weight(FontWeight::MEDIUM)
                            .truncate(),
                    )
                    .child({
                        // A commit or stash diff has no staged/unstaged state —
                        // label it by where it came from instead.
                        let (badge_label, badge_color) =
                            if self.display_mode == DiffDisplayMode::ThreeWay {
                                ("Conflict", Color::Conflict)
                            } else {
                                self.source.badge()
                            };
                        Badge::new(badge_label).color(badge_color)
                    })
                    .child(div().flex_1())
                    .child(if self.display_mode == DiffDisplayMode::ThreeWay {
                        Label::new(SharedString::from(conflict_progress_label(
                            unresolved,
                            total_conflicts,
                        )))
                        .size(LabelSize::XSmall)
                        .weight(FontWeight::SEMIBOLD)
                        .color(if unresolved == 0 {
                            Color::Added
                        } else {
                            Color::Conflict
                        })
                        .into_any_element()
                    } else {
                        div()
                            .h_flex()
                            .gap(px(4.))
                            .child(
                                div()
                                    .text_xs()
                                    .font_family("Lilex")
                                    .text_color(vc_added)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(SharedString::from(format!("+{}", additions))),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .font_family("Lilex")
                                    .text_color(vc_deleted)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(SharedString::from(format!("-{}", deletions))),
                            )
                            .into_any_element()
                    })
                    .child(
                        div()
                            .text_xs()
                            .text_color(text_placeholder_color)
                            .child("\u{00B7}"),
                    )
                    .child({
                        // Always-present partial-mode affordance so the line-level
                        // entry point is discoverable: emphasized while active, a
                        // muted "Partial (p)" hint otherwise. The keys it points at
                        // depend on the source — s/u for working-tree content, a/r
                        // for anything else. Hidden only for the three-way conflict
                        // view, which has no line-level operation at all.
                        let keys = self
                            .source
                            .operations()
                            .iter()
                            .map(|operation| operation.key())
                            .collect::<Vec<_>>()
                            .join(" / ");
                        let partial_tooltip: SharedString = if self.partial_mode {
                            format!(
                                "Line-level changes: select lines, then {keys}. Press p to exit."
                            )
                        } else {
                            format!("Partial line-level changes ({keys}) — press p to toggle.")
                        }
                        .into();
                        let (partial_label, partial_color) = if self.partial_mode {
                            ("Partial", Color::Warning.color(cx))
                        } else {
                            ("Partial (p)", text_placeholder_color)
                        };
                        if self.display_mode == DiffDisplayMode::ThreeWay {
                            div().into_any_element()
                        } else {
                            div()
                                .id("diff-partial-indicator")
                                .text_xs()
                                .text_color(partial_color)
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(partial_label)
                                .tooltip(rgitui_ui::Tooltip::text(partial_tooltip))
                                .into_any_element()
                        }
                    })
                    .when(self.display_mode == DiffDisplayMode::ThreeWay, |element| {
                        element
                            .child(
                                Button::new("conflict-all-current", "All Current")
                                    .size(ButtonSize::Compact)
                                    .style(ButtonStyle::Subtle)
                                    .tooltip("Use Current for every unresolved section")
                                    .on_click(cx.listener(
                                        |this, _: &ClickEvent, _, cx| {
                                            this.use_current_for_all_conflicts(cx);
                                        },
                                    )),
                            )
                            .child(
                                Button::new("conflict-all-incoming", "All Incoming")
                                    .size(ButtonSize::Compact)
                                    .style(ButtonStyle::Subtle)
                                    .tooltip("Use Incoming for every unresolved section")
                                    .on_click(cx.listener(
                                        |this, _: &ClickEvent, _, cx| {
                                            this.use_incoming_for_all_conflicts(cx);
                                        },
                                    )),
                            )
                            .child(
                                Button::new("conflict-open-editor", "Open File")
                                    .size(ButtonSize::Compact)
                                    .style(ButtonStyle::Subtle)
                                    .tooltip("Open the working file in your configured editor")
                                    .on_click(cx.listener(
                                        |this, _: &ClickEvent, _, cx| {
                                            this.open_conflict_in_editor(cx);
                                        },
                                    )),
                            )
                            .child(
                                Button::new("conflict-stage-working", "Stage Working Copy")
                                    .size(ButtonSize::Compact)
                                    .style(ButtonStyle::Outlined)
                                    .tooltip(
                                        "Stage a manually edited working copy after checking for conflict markers",
                                    )
                                    .on_click(cx.listener(
                                        |this, _: &ClickEvent, _, cx| {
                                            this.stage_conflict_working_copy(cx);
                                        },
                                    )),
                            )
                            .child(
                                Button::new("conflict-save", "Save & Stage")
                                    .size(ButtonSize::Compact)
                                    .style(ButtonStyle::Filled)
                                    .disabled(unresolved > 0)
                                    .tooltip(if unresolved > 0 {
                                        "Choose a result for every conflict first"
                                    } else {
                                        "Write the Result and stage this file"
                                    })
                                    .on_click(cx.listener(
                                        |this, _: &ClickEvent, _, cx| {
                                            this.save_conflict_result(cx);
                                        },
                                    )),
                            )
                    })
                    .child(self.render_file_menu_button(cx))
                    .child({
                        let toggle_tooltip = match self.display_mode {
                            DiffDisplayMode::Unified => "Switch to side-by-side view (d)",
                            DiffDisplayMode::SideBySide => "Switch to unified view (d)",
                            DiffDisplayMode::ThreeWay => "Three-way conflict view",
                        };
                        Button::new("toggle-diff-mode", mode_label)
                            .size(ButtonSize::Compact)
                            .style(ButtonStyle::Subtle)
                            .disabled(self.display_mode == DiffDisplayMode::ThreeWay)
                            .tooltip(toggle_tooltip)
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.toggle_display_mode(cx);
                            }))
                    }),
            );
        }

        if self.display_mode == DiffDisplayMode::ThreeWay {
            let column = |label: &'static str, detail: &'static str, border: bool| {
                div()
                    .flex_1()
                    .min_w_0()
                    .h_flex()
                    .h(px(24.))
                    .px(px(8.))
                    .gap(px(5.))
                    .items_center()
                    .when(border, |element| {
                        element.border_r_1().border_color(border_variant)
                    })
                    .child(
                        Label::new(label)
                            .size(LabelSize::XSmall)
                            .weight(FontWeight::SEMIBOLD),
                    )
                    .child(
                        Label::new(detail)
                            .size(LabelSize::XSmall)
                            .color(Color::Muted),
                    )
            };
            container = container.child(
                div()
                    .w_full()
                    .h_flex()
                    .bg(toolbar_bg)
                    .border_b_1()
                    .border_color(border_variant)
                    .child(column("Current", "Git ours", true))
                    .child(column("Result", "staged on save", true))
                    .child(column("Incoming", "Git theirs", false)),
            );
        }

        // Wrap the list in a row container that holds a vertical scrollbar on
        // the right, then append a horizontal scrollbar below only for the one
        // mode that scrolls the whole list horizontally: no-wrap unified. Split
        // and three-way always wrap (their columns never scroll horizontally), so
        // they need no horizontal scrollbar. Wrap mode is backed by `gpui::list`,
        // so the vertical scrollbar drives `ListState`; no-wrap unified stays on
        // the uniform list's base `ScrollHandle`.
        let vscroll: AnyElement = if wrap_enabled {
            // Wrap mode is backed by `gpui::list`, whose measured content height
            // grows as rows scroll into view. Drive the scrollbar from a fixed
            // per-row estimate instead so the thumb keeps a constant size.
            Scrollbar::vertical(
                "diff-vscroll",
                EstimatedListScroll::new(
                    self.wrap_list_state.clone(),
                    self.row_count(),
                    px(row_height),
                ),
            )
            .into_any_element()
        } else {
            Scrollbar::vertical(
                "diff-vscroll",
                self.scroll_handle.0.borrow().base_handle.clone(),
            )
            .into_any_element()
        };

        let list_row = div()
            .flex_grow(1.0)
            .h_flex()
            .items_stretch()
            .min_h(px(0.))
            .child(list)
            .child(vscroll);

        let mut body = div().v_flex().flex_grow(1.0).min_h(px(0.)).child(list_row);
        let show_hscroll = !wrap_enabled && display_mode == DiffDisplayMode::Unified;
        if show_hscroll {
            let h_handle = self.scroll_handle.0.borrow().base_handle.clone();
            body = body.child(Scrollbar::horizontal("diff-hscroll", h_handle));
        }
        container = container.child(body);
        // Backdrop first so the menu paints on top of it.
        if let Some(backdrop) = self.render_file_menu_backdrop(cx) {
            container = container.child(backdrop);
        }
        if let Some(menu) = self.render_file_menu(cx) {
            container = container.child(menu);
        }

        container.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_conflict_diff(sections: Vec<MergeSection>) -> ThreeWayFileDiff {
        ThreeWayFileDiff {
            path: std::path::PathBuf::from("conflict.txt"),
            sections,
            snapshot: ConflictSnapshot {
                ancestor_oid: None,
                ancestor_mode: None,
                ours_oid: None,
                ours_mode: None,
                theirs_oid: None,
                theirs_mode: None,
                worktree: rgitui_git::ConflictWorktreeSnapshot::Missing,
            },
            ancestor_exists: true,
            ours_exists: true,
            theirs_exists: true,
            is_binary: false,
            is_special_file: false,
            result_mode: 0o100644,
        }
    }

    #[test]
    fn assembles_independent_conflict_choices_without_normalizing_bytes() {
        let diff = text_conflict_diff(vec![
            MergeSection::Resolved(b"prefix\r\n".to_vec()),
            MergeSection::Conflict {
                ancestor: b"base-a\r\n".to_vec(),
                ours: b"current-a\r\n".to_vec(),
                theirs: b"incoming-a\r\n".to_vec(),
            },
            MergeSection::Resolved(b"middle\r\n".to_vec()),
            MergeSection::Conflict {
                ancestor: b"base-b".to_vec(),
                ours: b"current-b".to_vec(),
                theirs: b"incoming-b".to_vec(),
            },
        ]);

        let content = assemble_text_resolution(
            &diff,
            &[
                Some(ConflictChoice::Theirs),
                Some(ConflictChoice::BothOursFirst),
            ],
        )
        .unwrap();

        assert_eq!(
            content,
            b"prefix\r\nincoming-a\r\nmiddle\r\ncurrent-bincoming-b"
        );
    }

    #[test]
    fn unresolved_choice_cannot_be_assembled() {
        let diff = text_conflict_diff(vec![MergeSection::Conflict {
            ancestor: b"base\n".to_vec(),
            ours: b"current\n".to_vec(),
            theirs: b"incoming\n".to_vec(),
        }]);
        assert_eq!(assemble_text_resolution(&diff, &[None]), None);
    }

    #[test]
    fn conflict_progress_copy_reports_state_directly() {
        assert_eq!(conflict_progress_label(2, 2), "2 unresolved");
        assert_eq!(conflict_progress_label(1, 2), "1 resolved · 1 remaining");
        assert_eq!(conflict_progress_label(0, 2), "All 2 resolved");
    }

    #[test]
    fn three_way_line_numbers_continue_across_merge_sections() {
        let diff = text_conflict_diff(vec![
            MergeSection::Resolved(b"header\n".to_vec()),
            MergeSection::Conflict {
                ancestor: b"base\n".to_vec(),
                ours: b"current one\ncurrent two\n".to_vec(),
                theirs: b"incoming\n".to_vec(),
            },
            MergeSection::Resolved(b"footer\n".to_vec()),
        ]);
        let rows = DiffViewer::compute_three_way_rows(&diff, &[Some(ConflictChoice::Ours)]);
        let numbers = rows
            .iter()
            .filter_map(|row| match row {
                ThreeWayRow::Triple {
                    left_num,
                    mid_num,
                    right_num,
                    ..
                } => Some((*left_num, *mid_num, *right_num)),
                ThreeWayRow::HunkHeader { .. } => None,
            })
            .collect::<Vec<_>>();

        assert_eq!(
            numbers,
            vec![
                (Some(1), Some(1), Some(1)),
                (Some(2), Some(2), Some(2)),
                (Some(3), Some(3), None),
                (Some(4), Some(4), Some(3)),
            ]
        );
    }

    #[test]
    fn mouse_selection_range_extends_forward_inclusively() {
        assert_eq!(DiffViewer::range_from_anchor(2, 6), 2..7);
    }

    #[test]
    fn mouse_selection_range_extends_backward_inclusively() {
        assert_eq!(DiffViewer::range_from_anchor(6, 2), 2..7);
    }
    use rgitui_git::{DiffHunk, FileChangeKind};

    fn test_hunk(line: DiffLine) -> DiffHunk {
        DiffHunk {
            old_start: 1,
            old_lines: 1,
            new_start: 1,
            new_lines: 1,
            header: "@@ -1 +1 @@".to_string(),
            lines: vec![line],
        }
    }

    fn test_file_diff(hunks: Vec<DiffHunk>, additions: usize, deletions: usize) -> FileDiff {
        FileDiff {
            path: std::path::PathBuf::from("foo.txt"),
            hunks,
            additions,
            deletions,
            kind: FileChangeKind::Modified,
        }
    }

    fn test_cache_key(diff: &FileDiff, staged: bool) -> DisplayCacheKey {
        DisplayCacheKey::new(
            diff.path.display().to_string(),
            true,
            DiffSource::working_tree(staged),
            diff,
        )
    }

    fn test_cached_rows(diff: &FileDiff) -> CachedDisplayRows {
        CachedDisplayRows {
            display_rows: Arc::new(Vec::new()),
            sbs_rows: Arc::new(Vec::new()),
            display_longest_row_ix: 0,
            source_diff: Arc::new(diff.clone()),
        }
    }

    #[test]
    fn file_diffs_render_equal_treats_identical_diffs_as_equal() {
        let a = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let b = a.clone();
        assert!(file_diffs_render_equal(&a, &b));
    }

    #[test]
    fn file_diffs_render_equal_detects_in_place_content_change() {
        // Same hunk count and same +/- totals, but different line text. The old
        // count-only heuristic wrongly treated these as equal and skipped the
        // refresh, leaving stale text on screen — this is the regression guard.
        let a = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let b = test_file_diff(vec![test_hunk(DiffLine::Addition("world".into()))], 1, 0);
        assert_eq!(a.additions, b.additions);
        assert_eq!(a.deletions, b.deletions);
        assert_eq!(a.hunks.len(), b.hunks.len());
        assert!(!file_diffs_render_equal(&a, &b));
    }

    #[test]
    fn prepared_generation_guard_rejects_stale_results() {
        assert!(should_apply_prepared(7, 7));
        assert!(!should_apply_prepared(8, 7));
        assert!(!should_apply_prepared(7, 8));
    }

    // ── DiffSource provenance ─────────────────────────────────────
    //
    // Regression guards for the bug where selecting a past commit showed the
    // diff as unstaged working-tree content. The viewer used a `staged: bool`
    // that every commit call site set to `false`, so a commit diff rendered an
    // "Unstaged" badge, a live "Stage Hunk" button on every hunk, and the
    // "Partial (p)" staging hint — and `s` really did emit a stage request,
    // which the workspace resolved against the *working tree*.

    const OID: &str = "9f2c1ab4d5e6f708192a3b4c5d6e7f8091a2b3c4";

    #[test]
    fn commit_diff_is_never_labelled_staged_or_unstaged() {
        let (label, _) = DiffSource::Commit(OID.to_string()).badge();
        assert_ne!(
            label, "Unstaged",
            "a commit diff must not claim to be unstaged"
        );
        assert_ne!(label, "Staged");
        assert_eq!(label, "Committed");
    }

    #[test]
    fn stash_diff_is_never_labelled_staged_or_unstaged() {
        let (label, _) = DiffSource::Stash(OID.to_string()).badge();
        assert_ne!(label, "Unstaged");
        assert_ne!(label, "Staged");
        assert_eq!(label, "Stashed");
    }

    #[test]
    fn working_tree_badges_keep_their_staged_unstaged_labels() {
        assert_eq!(DiffSource::Worktree.badge().0, "Unstaged");
        assert_eq!(DiffSource::Index.badge().0, "Staged");
    }

    #[test]
    fn historical_sources_offer_no_staging_affordance() {
        for source in [
            DiffSource::Commit(OID.to_string()),
            DiffSource::Stash(OID.to_string()),
            DiffSource::Compare {
                from: "main".to_string(),
                to: "feature".to_string(),
            },
        ] {
            assert!(source.is_historical(), "{source:?} should be historical");
            assert_eq!(
                source.staging_action(),
                None,
                "{source:?} must offer no stage/unstage button or key binding"
            );
            assert!(
                !source.offers(DiffOperation::Stage) && !source.offers(DiffOperation::Unstage),
                "{source:?} must offer neither staging operation"
            );
        }
    }

    #[test]
    fn historical_sources_offer_apply_and_revert_instead() {
        for source in [
            DiffSource::Commit(OID.to_string()),
            DiffSource::Stash(OID.to_string()),
            DiffSource::Compare {
                from: "main".to_string(),
                to: "feature".to_string(),
            },
        ] {
            assert_eq!(
                source.operations(),
                &[DiffOperation::Apply, DiffOperation::Revert],
                "{source:?} must offer both working-tree operations"
            );
            assert!(
                source.patch_source().is_some(),
                "{source:?} must resolve to a tree pair to generate the patch from"
            );
        }
    }

    #[test]
    fn mutable_sources_offer_exactly_one_staging_action() {
        assert!(!DiffSource::Worktree.is_historical());
        assert!(!DiffSource::Index.is_historical());
        assert_eq!(
            DiffSource::Worktree.staging_action(),
            Some(DiffOperation::Stage)
        );
        assert_eq!(
            DiffSource::Index.staging_action(),
            Some(DiffOperation::Unstage)
        );
    }

    #[test]
    fn working_tree_constructor_maps_the_staged_flag() {
        assert_eq!(DiffSource::working_tree(false), DiffSource::Worktree);
        assert_eq!(DiffSource::working_tree(true), DiffSource::Index);
    }

    #[test]
    fn commit_id_is_carried_only_by_historical_sources() {
        assert_eq!(DiffSource::Commit(OID.to_string()).commit_id(), Some(OID));
        assert_eq!(DiffSource::Stash(OID.to_string()).commit_id(), Some(OID));
        assert_eq!(DiffSource::Worktree.commit_id(), None);
        assert_eq!(DiffSource::Index.commit_id(), None);
    }

    #[test]
    fn hunk_button_labels_match_the_action() {
        assert_eq!(DiffOperation::Stage.hunk_button_label(), "Stage Hunk");
        assert_eq!(DiffOperation::Unstage.hunk_button_label(), "Unstage Hunk");
        assert_eq!(DiffOperation::Apply.hunk_button_label(), "Apply Hunk");
        assert_eq!(DiffOperation::Revert.hunk_button_label(), "Revert Hunk");
        assert_eq!(DiffOperation::Stage.compact_hunk_button_label(), "Stage");
        assert_eq!(
            DiffOperation::Unstage.compact_hunk_button_label(),
            "Unstage"
        );
        assert_eq!(DiffOperation::Apply.compact_hunk_button_label(), "Apply");
        assert_eq!(DiffOperation::Revert.compact_hunk_button_label(), "Revert");
    }

    #[test]
    fn staging_a_commit_diff_is_rejected_with_an_actionable_message() {
        // A staging request from a commit diff would reach
        // `GitProject::stage_hunk_at`, which resolves the hunk index against the
        // working tree — staging unrelated uncommitted edits.
        for action in [DiffOperation::Stage, DiffOperation::Unstage] {
            let message = DiffSource::Commit(OID.to_string())
                .reject_operation(action)
                .expect("staging a commit diff must be rejected");
            assert!(
                message.contains("9f2c1ab"),
                "message names the commit: {message}"
            );
            assert!(
                message.contains("sidebar"),
                "message tells the user where to go instead: {message}"
            );
            assert!(message.ends_with('.'), "message is a sentence: {message}");
        }
    }

    #[test]
    fn staging_a_stash_diff_is_rejected_with_an_actionable_message() {
        for action in [DiffOperation::Stage, DiffOperation::Unstage] {
            let message = DiffSource::Stash(OID.to_string())
                .reject_operation(action)
                .expect("staging a stash diff must be rejected");
            assert!(
                message.contains("pop the stash"),
                "message names the way forward: {message}"
            );
            assert!(message.ends_with('.'));
        }
    }

    #[test]
    fn a_comparison_cannot_be_staged_but_says_what_to_do_instead() {
        let source = DiffSource::Compare {
            from: "main".to_string(),
            to: "feature".to_string(),
        };
        for action in [DiffOperation::Stage, DiffOperation::Unstage] {
            let message = source
                .reject_operation(action)
                .expect("a comparison must not be staged");
            assert!(
                message.contains("main...feature"),
                "message names the comparison: {message}"
            );
            assert!(
                message.contains("press a to apply"),
                "message points at the operation that does work: {message}"
            );
            assert!(message.ends_with('.'));
        }
    }

    #[test]
    fn mutable_sources_cannot_apply_or_revert() {
        // Working-tree content is already in the working tree, so there is
        // nothing to bring in — and `patch_source` has no tree pair for it.
        for source in [DiffSource::Worktree, DiffSource::Index] {
            for action in [DiffOperation::Apply, DiffOperation::Revert] {
                assert!(
                    !source.offers(action),
                    "{source:?} must not offer {action:?}"
                );
                let message = source
                    .reject_operation(action)
                    .expect("the request must be rejected");
                assert!(
                    message.contains("already in your working tree"),
                    "got: {message}"
                );
            }
            assert!(source.patch_source().is_none());
        }
    }

    #[test]
    fn every_source_offers_at_least_one_operation() {
        // No displayable source may be inert: each one has an affordance to render.
        for source in [
            DiffSource::Worktree,
            DiffSource::Index,
            DiffSource::Commit(OID.to_string()),
            DiffSource::Stash(OID.to_string()),
            DiffSource::Compare {
                from: "main".to_string(),
                to: "feature".to_string(),
            },
        ] {
            assert!(
                !source.operations().is_empty(),
                "{source:?} offers nothing at all"
            );
            for operation in source.operations() {
                assert_eq!(
                    source.reject_operation(*operation),
                    None,
                    "{source:?} offers {operation:?} but rejects it"
                );
            }
        }
    }

    #[test]
    fn a_commit_source_resolves_to_its_own_change() {
        let source = DiffSource::Commit(OID.to_string());
        assert_eq!(
            source.patch_source(),
            Some(WorktreePatchSource::Commit(
                git2::Oid::from_str(OID).unwrap()
            ))
        );
    }

    #[test]
    fn a_comparison_resolves_to_both_of_its_endpoints() {
        let source = DiffSource::Compare {
            from: "main".to_string(),
            to: "origin/feature".to_string(),
        };
        assert_eq!(
            source.patch_source(),
            Some(WorktreePatchSource::Compare {
                from: "main".to_string(),
                to: "origin/feature".to_string(),
            }),
            "the endpoints must survive verbatim: their order decides which \
             side an apply pulls in"
        );
    }

    #[test]
    fn revision_labels_name_the_source() {
        assert_eq!(DiffSource::Worktree.revision_label(), None);
        assert_eq!(DiffSource::Index.revision_label(), None);
        assert_eq!(
            DiffSource::Commit(OID.to_string())
                .revision_label()
                .unwrap(),
            "9f2c1ab"
        );
        assert_eq!(
            DiffSource::Compare {
                from: "main".to_string(),
                to: "feature".to_string(),
            }
            .revision_label()
            .unwrap(),
            "main...feature"
        );
    }

    #[test]
    fn operation_labels_and_keys_are_distinct_per_operation() {
        let operations = [
            DiffOperation::Stage,
            DiffOperation::Unstage,
            DiffOperation::Apply,
            DiffOperation::Revert,
        ];
        let keys: Vec<&str> = operations.iter().map(|o| o.key()).collect();
        let unique: HashSet<&&str> = keys.iter().collect();
        assert_eq!(unique.len(), keys.len(), "keys collide: {keys:?}");
        for operation in operations {
            assert!(!operation.hunk_button_label().is_empty());
            assert!(!operation.file_menu_label().is_empty());
        }
        assert!(DiffOperation::Stage.is_staging());
        assert!(DiffOperation::Unstage.is_staging());
        assert!(!DiffOperation::Apply.is_staging());
        assert!(!DiffOperation::Revert.is_staging());
        assert!(DiffOperation::Apply.writes_files());
        assert!(DiffOperation::Revert.writes_files());
        assert!(!DiffOperation::Stage.writes_files());
        assert!(!DiffOperation::Unstage.writes_files());
    }

    #[test]
    fn valid_staging_requests_are_not_rejected() {
        assert_eq!(
            DiffSource::Worktree.reject_operation(DiffOperation::Stage),
            None
        );
        assert_eq!(
            DiffSource::Index.reject_operation(DiffOperation::Unstage),
            None
        );
    }

    #[test]
    fn mismatched_working_tree_requests_are_rejected() {
        assert!(DiffSource::Worktree
            .reject_operation(DiffOperation::Unstage)
            .is_some());
        assert!(DiffSource::Index
            .reject_operation(DiffOperation::Stage)
            .is_some());
    }

    #[test]
    fn display_cache_distinguishes_a_commit_from_identical_worktree_content() {
        // The same path with byte-identical hunks can legitimately be shown as
        // both a commit diff and a working-tree diff. Provenance is part of the
        // cache key so the two never share prepared rows (and therefore never
        // share a stale badge or button set).
        let diff = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let commit_key = DisplayCacheKey::new(
            "foo.txt".to_string(),
            true,
            DiffSource::Commit(OID.to_string()),
            &diff,
        );
        let worktree_key =
            DisplayCacheKey::new("foo.txt".to_string(), true, DiffSource::Worktree, &diff);
        let index_key = DisplayCacheKey::new("foo.txt".to_string(), true, DiffSource::Index, &diff);
        assert_ne!(commit_key, worktree_key);
        assert_ne!(commit_key, index_key);
        assert_ne!(worktree_key, index_key);
    }

    #[test]
    fn side_by_side_rows_reuse_prepared_unified_text() {
        let display_rows = vec![
            DisplayRow::HunkHeader {
                header: "@@ -1 +1 @@".into(),
                context_name: "example".into(),
                hunk_index: 0,
            },
            DisplayRow::Line {
                old_num: Some(1),
                new_num: None,
                styled: StyledLine::plain("old value"),
                kind: DisplayLineKind::Deletion,
            },
            DisplayRow::Line {
                old_num: None,
                new_num: Some(1),
                styled: StyledLine::plain("new value"),
                kind: DisplayLineKind::Addition,
            },
            DisplayRow::Line {
                old_num: Some(2),
                new_num: Some(2),
                styled: StyledLine::plain("context"),
                kind: DisplayLineKind::Context,
            },
        ];

        let rows = DiffViewer::compute_sbs_rows(&display_rows);
        assert_eq!(rows.len(), 3);
        match &rows[1] {
            SideBySideRow::Pair {
                left_num,
                left_styled,
                right_num,
                right_styled,
                ..
            } => {
                assert_eq!(*left_num, Some(1));
                assert_eq!(left_styled.text.as_ref(), "old value");
                assert_eq!(*right_num, Some(1));
                assert_eq!(right_styled.text.as_ref(), "new value");
            }
            SideBySideRow::HunkHeader { .. } => panic!("expected paired change row"),
        }
    }

    #[test]
    fn display_cache_distinguishes_staged_and_unstaged_diffs() {
        let diff = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let unstaged_key = test_cache_key(&diff, false);
        let staged_key = test_cache_key(&diff, true);
        assert_ne!(unstaged_key, staged_key);

        let mut cache = DisplayCache::default();
        cache.insert(unstaged_key, test_cached_rows(&diff));
        assert!(cache.get(&staged_key, &diff).is_none());
    }

    #[test]
    fn display_cache_distinguishes_same_count_changed_content() {
        let before = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let after = test_file_diff(vec![test_hunk(DiffLine::Addition("world".into()))], 1, 0);
        assert_eq!(before.hunks.len(), after.hunks.len());
        assert_eq!(before.additions, after.additions);
        assert_eq!(before.deletions, after.deletions);

        let before_key = test_cache_key(&before, false);
        let after_key = test_cache_key(&after, false);
        assert_ne!(before_key, after_key);

        let mut cache = DisplayCache::default();
        cache.insert(before_key, test_cached_rows(&before));
        assert!(cache.get(&after_key, &after).is_none());
    }

    #[test]
    fn display_cache_rejects_fingerprint_collision_with_different_source() {
        let before = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let after = test_file_diff(vec![test_hunk(DiffLine::Addition("world".into()))], 1, 0);
        let key = test_cache_key(&before, false);
        let mut cache = DisplayCache::default();
        cache.insert(key.clone(), test_cached_rows(&before));

        assert!(cache.get(&key, &after).is_none());
        assert!(!cache.entries.contains_key(&key));
    }

    #[test]
    fn display_cache_evicts_least_recently_used_entry() {
        let diff = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let mut cache = DisplayCache::default();
        let mut keys = Vec::new();

        for i in 0..DISPLAY_CACHE_MAX_ENTRIES {
            let mut key = test_cache_key(&diff, false);
            key.file_path = format!("file-{i}.txt");
            cache.insert(key.clone(), test_cached_rows(&diff));
            keys.push(key);
        }

        // Refresh the oldest entry, making the second entry the LRU victim.
        assert!(cache.get(&keys[0], &diff).is_some());
        let mut newest = test_cache_key(&diff, false);
        newest.file_path = "newest.txt".into();
        cache.insert(newest.clone(), test_cached_rows(&diff));

        assert!(cache.entries.contains_key(&keys[0]));
        assert!(!cache.entries.contains_key(&keys[1]));
        assert!(cache.entries.contains_key(&newest));
        assert_eq!(cache.entries.len(), DISPLAY_CACHE_MAX_ENTRIES);
    }

    #[test]
    fn is_change_line_accepts_additions_and_deletions_only() {
        // Addition: (None, Some) — staged on the new side.
        assert!(DiffViewer::is_change_line(&(None, Some(3))));
        // Deletion: (Some, None) — staged on the old side. Filtering on
        // `new_num.is_some()` would drop these.
        assert!(DiffViewer::is_change_line(&(Some(7), None)));
        // Context: (Some, Some) — carried by the git layer, never a change target.
        assert!(!DiffViewer::is_change_line(&(Some(7), Some(7))));
        // Empty / non-line row.
        assert!(!DiffViewer::is_change_line(&(None, None)));
    }

    #[test]
    fn file_diffs_render_equal_detects_count_and_kind_changes() {
        let a = test_file_diff(vec![test_hunk(DiffLine::Addition("hello".into()))], 1, 0);
        let emptied = test_file_diff(vec![], 0, 0);
        assert!(!file_diffs_render_equal(&a, &emptied));

        let mut renamed = a.clone();
        renamed.kind = FileChangeKind::Added;
        assert!(!file_diffs_render_equal(&a, &renamed));
    }

    #[test]
    fn icon_for_path_uses_expected_fallback_icons() {
        assert_eq!(DiffViewer::icon_for_path("src/main.rs"), IconName::File);
        assert_eq!(
            DiffViewer::icon_for_path("config/settings.jsonc"),
            IconName::Settings
        );
        assert_eq!(DiffViewer::icon_for_path("Cargo.lock"), IconName::Pin);
    }

    #[test]
    fn syntax_for_path_maps_common_extension_fallbacks() {
        let tsx = DiffViewer::syntax_for_path("src/app.tsx")
            .expect("tsx fallback should resolve")
            .name
            .as_str();
        let jsonc = DiffViewer::syntax_for_path("config/biome.jsonc")
            .expect("jsonc fallback should resolve")
            .name
            .as_str();
        let env = DiffViewer::syntax_for_path(".env")
            .expect("dot env fallback should resolve")
            .name
            .as_str();
        let sql = DiffViewer::syntax_for_path("queries/migrate.sql")
            .expect("sql fallback should resolve")
            .name
            .as_str();

        assert_eq!(tsx, "JavaScript");
        assert_eq!(jsonc, "JSON");
        assert_eq!(env, "Bourne Again Shell (bash)");
        assert_eq!(sql, "SQL");
    }

    #[test]
    fn icon_for_path_covers_common_extensions() {
        // Code files
        assert_eq!(DiffViewer::icon_for_path("main.rs"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path("server.go"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path("script.py"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path("app.js"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path("types.ts"), IconName::File);
        // Config files
        assert_eq!(DiffViewer::icon_for_path("Cargo.toml"), IconName::Settings);
        assert_eq!(DiffViewer::icon_for_path("config.yaml"), IconName::Settings);
        assert_eq!(DiffViewer::icon_for_path("deploy.yml"), IconName::Settings);
        assert_eq!(
            DiffViewer::icon_for_path("settings.json"),
            IconName::Settings
        );
        // Lock files
        assert_eq!(DiffViewer::icon_for_path("yarn.lock"), IconName::Pin);
        // package-lock.json has extension .json → Settings, not Pin
        assert_eq!(
            DiffViewer::icon_for_path("package-lock.json"),
            IconName::Settings
        );
        // Other
        assert_eq!(DiffViewer::icon_for_path("styles.css"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path("index.html"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path("README.md"), IconName::File);
        // No extension → File
        assert_eq!(DiffViewer::icon_for_path("Makefile"), IconName::File);
        assert_eq!(DiffViewer::icon_for_path(".gitignore"), IconName::File);
    }

    #[test]
    fn extract_context_name_parses_hunk_header() {
        // Normal hunk with function name
        let header = "@@ -1,5 +1,7 @@ fn main()";
        assert_eq!(DiffViewer::extract_context_name(header), "fn main()");

        // Multi-line Rust function signature
        let header = "@@ -10,5 +10,7 @@ pub fn process_items<T>(items: Vec<T>) where T: Clone";
        assert_eq!(
            DiffViewer::extract_context_name(header),
            "pub fn process_items<T>(items: Vec<T>) where T: Clone"
        );

        // Empty context after @@ (no function name)
        let header = "@@ -0,0 +1,4 @@";
        assert_eq!(DiffViewer::extract_context_name(header), "");

        // No second @@
        let header = "@@ -1,3 +1,4";
        assert_eq!(DiffViewer::extract_context_name(header), "");

        // Not a hunk header at all
        let header = "just some text";
        assert_eq!(DiffViewer::extract_context_name(header), "");

        // Class method
        let header = "@@ -5,10 +5,12 @@ impl<T> MyStruct<T> {";
        assert_eq!(
            DiffViewer::extract_context_name(header),
            "impl<T> MyStruct<T> {"
        );
    }

    #[test]
    fn extract_line_range_parses_hunk_header() {
        // Normal multi-line hunk
        let header = "@@ -1,5 +1,7 @@ fn main()";
        assert_eq!(DiffViewer::extract_line_range(header), "@@ -1,5 +1,7 @@");

        // Single-line hunk (deletion only)
        let header = "@@ -3,1 +3,0 @@";
        assert_eq!(DiffViewer::extract_line_range(header), "@@ -3,1 +3,0 @@");

        // Single-line hunk (addition only)
        let header = "@@ -0,0 +1,1 @@";
        assert_eq!(DiffViewer::extract_line_range(header), "@@ -0,0 +1,1 @@");

        // Non-hunk string returns as-is
        let header = "no markers here";
        assert_eq!(DiffViewer::extract_line_range(header), "no markers here");
    }

    #[test]
    fn syntax_for_path_covers_rust_and_config_extensions() {
        let rs = DiffViewer::syntax_for_path("src/lib.rs")
            .expect("rust file should resolve")
            .name
            .as_str();
        assert_eq!(rs, "Rust");

        let toml = DiffViewer::syntax_for_path("workspace.toml")
            .expect("toml file should resolve")
            .name
            .as_str();
        // Fallback maps .toml → YAML (closest in structure for basic highlighting)
        assert_eq!(toml, "YAML");

        let yaml = DiffViewer::syntax_for_path("ci.yml")
            .expect("yaml file should resolve")
            .name
            .as_str();
        assert_eq!(yaml, "YAML");

        let css = DiffViewer::syntax_for_path("style.css")
            .expect("css file should resolve")
            .name
            .as_str();
        assert_eq!(css, "CSS");
    }

    // --- Word-level diff tests ---

    #[test]
    fn split_word_ranges_simple() {
        let words = DiffViewer::split_word_ranges("hello world");
        assert_eq!(words.len(), 2);
        assert_eq!(words[0], 0..5); // "hello"
        assert_eq!(words[1], 6..11); // "world"
    }

    #[test]
    fn split_word_ranges_single_word() {
        let words = DiffViewer::split_word_ranges("hello");
        assert_eq!(words.len(), 1);
        assert_eq!(words[0], 0..5);
    }

    #[test]
    fn split_word_ranges_empty() {
        assert!(DiffViewer::split_word_ranges("").is_empty());
    }

    #[test]
    fn split_word_ranges_only_spaces() {
        // All-whitespace input yields no word ranges
        assert!(DiffViewer::split_word_ranges("   ").is_empty());
    }

    #[test]
    fn split_word_ranges_leading_trailing_spaces() {
        // Leading/trailing spaces are trimmed; only "foo" is a word
        let words = DiffViewer::split_word_ranges("  foo  ");
        assert_eq!(words.len(), 1);
        assert_eq!(words[0], 2..5);
    }

    #[test]
    fn split_word_ranges_multiple_spaces_between_words() {
        // Multiple spaces between words: each gap is a separator
        let words = DiffViewer::split_word_ranges("foo  bar");
        assert_eq!(words.len(), 2);
        assert_eq!(words[0], 0..3); // "foo"
        assert_eq!(words[1], 5..8); // "bar" (indices skip the two spaces)
    }

    #[test]
    fn split_word_ranges_mixed_whitespace() {
        let words = DiffViewer::split_word_ranges("foo\tbar\nbaz");
        assert_eq!(words.len(), 3);
        assert_eq!(words[0], 0..3); // "foo"
        assert_eq!(words[1], 4..7); // "bar" (\t at index 3)
        assert_eq!(words[2], 8..11); // "baz" (\n at index 7)
    }

    #[test]
    fn split_word_ranges_with_unicode() {
        // Non-ASCII chars treated as word characters
        let words = DiffViewer::split_word_ranges("日本語 English");
        assert_eq!(words.len(), 2);
        assert_eq!(words[0], 0..9); // "日本語" = 3 chars × 3 bytes = 9 bytes
        assert_eq!(words[1], 10..17); // " English" — space at 9, then 7 chars
    }

    #[test]
    fn split_word_ranges_punctuation_splits_tokens() {
        // Punctuation should produce separate tokens, not stick to adjacent words.
        let words = DiffViewer::split_word_ranges("foo.bar(x, y)");
        // "foo" "." "bar" "(" "x" "," "y" ")"
        assert_eq!(words.len(), 8);
        assert_eq!(words[0], 0..3); // "foo"
        assert_eq!(words[1], 3..4); // "."
        assert_eq!(words[2], 4..7); // "bar"
        assert_eq!(words[3], 7..8); // "("
        assert_eq!(words[4], 8..9); // "x"
        assert_eq!(words[5], 9..10); // ","
        assert_eq!(words[6], 11..12); // "y"
        assert_eq!(words[7], 12..13); // ")"
    }

    #[test]
    fn split_word_ranges_rust_code() {
        let words = DiffViewer::split_word_ranges("let x = foo::bar();");
        // "let" "x" "=" "foo" ":" ":" "bar" "(" ")" ";"
        assert_eq!(words.len(), 10);
        assert_eq!(words[0], 0..3); // "let"
        assert_eq!(words[3], 8..11); // "foo"
        assert_eq!(words[6], 13..16); // "bar"
    }

    #[test]
    fn compute_word_diff_function_arg_change() {
        let (del_spans, add_spans) =
            DiffViewer::compute_word_diff("compute(x, y)", "compute(a, b)");
        // Changed tokens: "x" → "a" and "y" → "b" reported as separate spans.
        // Spans are extended to absorb adjacent punctuation for visual grouping.
        assert_eq!(del_spans.len(), 2);
        assert_eq!(del_spans[0], 8..10); // "x" extended with trailing comma
        assert_eq!(del_spans[1], 11..13); // "y" extended with trailing )
        assert_eq!(add_spans.len(), 2);
        assert_eq!(add_spans[0], 8..10); // "a" extended with trailing comma
        assert_eq!(add_spans[1], 11..13); // "b" extended with trailing )
    }

    #[test]
    fn compute_word_diff_method_name_change() {
        // Changing just the method name in a chain.
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("foo.bar()", "foo.baz()");
        assert_eq!(del_spans.len(), 1);
        assert_eq!(del_spans[0], 4..9); // "bar" extended with trailing ()
        assert_eq!(add_spans.len(), 1);
        assert_eq!(add_spans[0], 4..9); // "baz" extended with trailing ()
    }

    #[test]
    fn compute_word_diff_unchanged() {
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("hello world", "hello world");
        assert!(del_spans.is_empty());
        assert!(add_spans.is_empty());
    }

    #[test]
    fn compute_word_diff_simple_word_change() {
        // "foo" → "bar": both single words, should produce one del + one add
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("foo", "bar");
        assert_eq!(del_spans.len(), 1);
        assert_eq!(del_spans[0].clone(), 0..3); // "foo"
        assert_eq!(add_spans.len(), 1);
        assert_eq!(add_spans[0].clone(), 0..3); // "bar"
    }

    #[test]
    fn compute_word_diff_addition_only() {
        // New text has "bar" added
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("foo", "foo bar");
        assert!(del_spans.is_empty());
        assert_eq!(add_spans.len(), 1);
        assert_eq!(add_spans[0].clone(), 4..7); // "bar"
    }

    #[test]
    fn compute_word_diff_deletion_only() {
        // "bar" deleted from old text
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("foo bar", "foo");
        assert_eq!(del_spans.len(), 1);
        assert_eq!(del_spans[0].clone(), 4..7); // "bar"
        assert!(add_spans.is_empty());
    }

    #[test]
    fn compute_word_diff_both_empty() {
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("", "");
        assert!(del_spans.is_empty());
        assert!(add_spans.is_empty());
    }

    #[test]
    fn compute_word_diff_word_replaced_in_sentence() {
        // "The quick brown fox" → "The slow brown fox"
        let (del_spans, add_spans) =
            DiffViewer::compute_word_diff("The quick brown fox", "The slow brown fox");
        assert_eq!(del_spans.len(), 1);
        assert_eq!(del_spans[0].clone(), 4..9); // "quick"
        assert_eq!(add_spans.len(), 1);
        assert_eq!(add_spans[0].clone(), 4..8); // "slow"
    }

    #[test]
    fn compute_word_diff_empty_old_new_has_content() {
        // Pure addition — all tokens differ, nearby spans merge into one block.
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("", "hello world");
        assert!(del_spans.is_empty());
        assert_eq!(add_spans.len(), 1); // merged into single block
        assert_eq!(add_spans[0], 0..11);
    }

    #[test]
    fn compute_word_diff_old_has_content_new_empty() {
        // Pure deletion — all tokens differ, nearby spans merge into one block.
        let (del_spans, add_spans) = DiffViewer::compute_word_diff("hello world", "");
        assert_eq!(del_spans.len(), 1); // merged into single block
        assert_eq!(del_spans[0], 0..11);
        assert!(add_spans.is_empty());
    }

    // --- apply_word_highlights tests ---

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_skips_when_text_empty() {
        let mut line = StyledLine::plain("");
        let bg = HighlightStyle::default();
        line.apply_word_highlights([0..5].to_vec(), vec![], bg, bg);
        assert!(line.highlights.is_empty());
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_clips_deletion_spans_to_text_length() {
        let mut line = StyledLine::plain("hi"); // len = 2
        let bg = HighlightStyle::default();
        line.apply_word_highlights(vec![0..10], vec![], bg, bg);
        assert_eq!(line.highlights.len(), 1);
        assert_eq!(line.highlights[0].0.start, 0);
        assert_eq!(line.highlights[0].0.end, 2);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_clips_addition_spans_to_text_length() {
        let mut line = StyledLine::plain("hi"); // len = 2
        let bg = HighlightStyle::default();
        line.apply_word_highlights(vec![], vec![0..100], bg, bg);
        assert_eq!(line.highlights.len(), 1);
        assert_eq!(line.highlights[0].0.end, 2);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_drops_spans_clipped_to_empty() {
        let mut line = StyledLine::plain("hi"); // len = 2
        let bg = HighlightStyle::default();
        line.apply_word_highlights(vec![5..6], vec![], bg, bg);
        assert!(line.highlights.is_empty());
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_preserves_valid_spans() {
        let mut line = StyledLine::plain("hello");
        let bg = HighlightStyle::default();
        line.apply_word_highlights(vec![0..2, 3..5], vec![], bg, bg);
        assert_eq!(line.highlights.len(), 2);
        assert_eq!(line.highlights[0].0, 0..2);
        assert_eq!(line.highlights[1].0, 3..5);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_both_deletion_and_addition_spans() {
        let mut line = StyledLine::plain("hello");
        let bg = HighlightStyle::default();
        line.apply_word_highlights(vec![0..1], vec![0..1], bg, bg);
        // Both del and add produce word spans at 0..1 (sorted stably).
        assert_eq!(line.highlights.len(), 2);
        assert_eq!(line.highlights[0].0, 0..1);
        assert_eq!(line.highlights[1].0, 0..1);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_merges_with_syntect_spans() {
        // Simulate syntect covering the full text with two spans.
        let syn_style_a = HighlightStyle {
            color: Some(gpui::hsla(0.0, 1.0, 0.5, 1.0)),
            ..Default::default()
        };
        let syn_style_b = HighlightStyle {
            color: Some(gpui::hsla(0.5, 1.0, 0.5, 1.0)),
            ..Default::default()
        };
        let word_bg = HighlightStyle {
            background_color: Some(gpui::hsla(0.0, 0.5, 0.5, 0.25)),
            ..Default::default()
        };

        // Text: "hello world" (11 bytes)
        // Syntect: [0..5, syn_a], [5..11, syn_b]
        // Word del: [0..5] ("hello" changed)
        let mut line = StyledLine {
            text: "hello world".into(),
            highlights: vec![(0..5, syn_style_a), (5..11, syn_style_b)],
        };
        line.apply_word_highlights(Vec::from([0..5]), vec![], word_bg, word_bg);

        // Should produce 3 spans: [0..5 combined], [5..11 syntect-only]
        // The combined span has syntect colour + word background.
        assert_eq!(line.highlights.len(), 2);
        assert_eq!(line.highlights[0].0, 0..5);
        assert_eq!(line.highlights[0].1.color, syn_style_a.color);
        assert_eq!(
            line.highlights[0].1.background_color,
            word_bg.background_color
        );
        assert_eq!(line.highlights[1].0, 5..11);
        assert_eq!(line.highlights[1].1.color, syn_style_b.color);
        assert_eq!(line.highlights[1].1.background_color, None);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_splits_syntect_span_at_word_boundaries() {
        let syn = HighlightStyle {
            color: Some(gpui::hsla(0.0, 1.0, 0.5, 1.0)),
            ..Default::default()
        };
        let word_bg = HighlightStyle {
            background_color: Some(gpui::hsla(0.0, 0.5, 0.5, 0.25)),
            ..Default::default()
        };

        // Text: "hello world!" (12 bytes)
        // Syntect: single span covering everything [0..12]
        // Word highlight: [6..11] ("world")
        let mut line = StyledLine {
            text: "hello world!".into(),
            highlights: vec![(0..12, syn)],
        };
        line.apply_word_highlights(Vec::from([6..11]), vec![], word_bg, word_bg);

        // Should split into: [0..6 syn], [6..11 syn+word], [11..12 syn]
        assert_eq!(line.highlights.len(), 3);
        assert_eq!(line.highlights[0].0, 0..6);
        assert_eq!(line.highlights[0].1.background_color, None);
        assert_eq!(line.highlights[1].0, 6..11);
        assert_eq!(
            line.highlights[1].1.background_color,
            word_bg.background_color
        );
        assert_eq!(line.highlights[1].1.color, syn.color);
        assert_eq!(line.highlights[2].0, 11..12);
        assert_eq!(line.highlights[2].1.background_color, None);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn apply_word_highlights_word_span_crosses_syntect_boundary() {
        let syn_a = HighlightStyle {
            color: Some(gpui::hsla(0.0, 1.0, 0.5, 1.0)),
            ..Default::default()
        };
        let syn_b = HighlightStyle {
            color: Some(gpui::hsla(0.5, 1.0, 0.5, 1.0)),
            ..Default::default()
        };
        let word_bg = HighlightStyle {
            background_color: Some(gpui::hsla(0.0, 0.5, 0.5, 0.25)),
            ..Default::default()
        };

        // Text: "hello world!" (12 bytes)
        // Syntect: [0..5, syn_a], [5..12, syn_b]
        // Word: [3..7] — crosses the syn_a/syn_b boundary
        let mut line = StyledLine {
            text: "hello world!".into(),
            highlights: vec![(0..5, syn_a), (5..12, syn_b)],
        };
        line.apply_word_highlights(Vec::from([3..7]), vec![], word_bg, word_bg);

        // Expected: [0..3 syn_a], [3..5 syn_a+word], [5..7 syn_b+word], [7..12 syn_b]
        assert_eq!(line.highlights.len(), 4);
        assert_eq!(line.highlights[0].0, 0..3);
        assert_eq!(line.highlights[0].1.background_color, None);
        assert_eq!(line.highlights[1].0, 3..5);
        assert_eq!(line.highlights[1].1.color, syn_a.color);
        assert_eq!(
            line.highlights[1].1.background_color,
            word_bg.background_color
        );
        assert_eq!(line.highlights[2].0, 5..7);
        assert_eq!(line.highlights[2].1.color, syn_b.color);
        assert_eq!(
            line.highlights[2].1.background_color,
            word_bg.background_color
        );
        assert_eq!(line.highlights[3].0, 7..12);
        assert_eq!(line.highlights[3].1.background_color, None);
    }
}

/// View-level regression tests for diff provenance.
///
/// The pure tests above prove `DiffSource` classifies content correctly. These
/// drive a real `DiffViewer` in a headless GPUI window and press the actual
/// staging keys, which is the only way to show that no staging request escapes
/// a source that cannot be staged. A request that did would reach
/// `GitProject::stage_hunk_at`, which resolves the hunk index against the
/// working tree — staging unrelated uncommitted edits.
#[cfg(test)]
mod view_tests {
    use gpui::prelude::*;
    use gpui::{div, Context, Entity, Render, Window};
    use rgitui_git::{
        ConflictSnapshot, DiffHunk, DiffLine, FileChangeKind, FileDiff, MergeSection,
        ThreeWayFileDiff,
    };
    use rgitui_test_support::ViewTest;

    use super::{
        ConflictChoice, ConflictResolution, DiffOperation, DiffSource, DiffViewer, DiffViewerEvent,
        WorktreePatchScope,
    };

    const OID: &str = "9f2c1ab4d5e6f708192a3b4c5d6e7f8091a2b3c4";
    const PATH: &str = "src/main.rs";

    /// Hosts a real `DiffViewer` and records everything it emits, so a test can
    /// assert that a keystroke produced no staging request at all.
    struct StagingProbe {
        viewer: Entity<DiffViewer>,
        events: Vec<DiffViewerEvent>,
    }

    impl StagingProbe {
        fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
            // The viewer reads settings while rendering; install defaults
            // without touching the user's config file or the OS keychain.
            rgitui_settings::init_test(cx);
            let viewer = cx.new(DiffViewer::new);
            cx.subscribe(
                &viewer,
                |probe: &mut Self, _viewer, event: &DiffViewerEvent, _cx| {
                    probe.events.push(event.clone());
                },
            )
            .detach();
            viewer.update(cx, |viewer, cx| viewer.focus(window, cx));
            Self {
                viewer,
                events: Vec::new(),
            }
        }

        /// Emitted requests, ignoring the `DiffChanged` notification that every
        /// `set_diff` produces.
        fn request_events(&self) -> Vec<DiffViewerEvent> {
            self.events
                .iter()
                .filter(|event| !matches!(event, DiffViewerEvent::DiffChanged { .. }))
                .cloned()
                .collect()
        }

        /// [`Self::request_events`] as debug strings, for assertions that only
        /// care that nothing (or one named thing) came out.
        fn requests(&self) -> Vec<String> {
            self.request_events()
                .iter()
                .map(|event| format!("{event:?}"))
                .collect()
        }
    }

    /// Shows `diff` from `source` in the probe's viewer and focuses it.
    fn show(probe: &mut ViewTest<StagingProbe>, diff: FileDiff, source: DiffSource) {
        probe.update(|probe, window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_diff(diff, PATH.to_string(), source, cx);
                viewer.focus(window, cx);
            });
        });
    }

    impl Render for StagingProbe {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(self.viewer.clone())
        }
    }

    fn one_hunk_diff() -> FileDiff {
        FileDiff {
            path: std::path::PathBuf::from(PATH),
            hunks: vec![DiffHunk {
                old_start: 1,
                old_lines: 2,
                new_start: 1,
                new_lines: 3,
                header: "@@ -1,2 +1,3 @@ fn main()".to_string(),
                lines: vec![
                    DiffLine::Context("fn main() {".to_string()),
                    DiffLine::Addition("    println!(\"hello\");".to_string()),
                    DiffLine::Context("}".to_string()),
                ],
            }],
            additions: 1,
            deletions: 0,
            kind: FileChangeKind::Modified,
        }
    }

    /// Shows `source` in a focused viewer, selects every row so a staging
    /// request would have a target, invokes stage-then-unstage, and returns
    /// whatever staging requests came back.
    ///
    /// These go through the methods rather than simulated keystrokes because the
    /// `s`/`u` bindings are gpui actions declared in `rgitui_workspace`, which
    /// sits above this crate and so cannot be reached from here. The keystrokes
    /// are covered by the keymap registry's own tests; what matters here is that
    /// the entry points the actions call refuse on historical content.
    fn staging_requests_after_stage_then_unstage(source: DiffSource) -> Vec<String> {
        let mut probe = ViewTest::open(StagingProbe::new);
        show(&mut probe, one_hunk_diff(), source);

        // Guard against a vacuous test: the rows must actually exist, or the
        // selection would find no hunk regardless of provenance.
        probe.read(|probe, cx| {
            let viewer = probe.viewer.read(cx);
            assert!(
                viewer.row_count() > 0,
                "display rows should be prepared before staging is attempted"
            );
        });

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                // Select every row, so the request resolves to the whole hunk.
                viewer.select_all_lines(cx);
                viewer.stage_selection(cx);
                viewer.unstage_selection(cx);
            });
        });

        probe.read(|probe, _| probe.requests())
    }

    #[test]
    fn pressing_s_or_u_on_a_commit_diff_requests_no_staging() {
        let requests =
            staging_requests_after_stage_then_unstage(DiffSource::Commit(OID.to_string()));
        assert!(
            requests.is_empty(),
            "a committed diff must not be stageable, but the viewer emitted {requests:?}"
        );
    }

    #[test]
    fn pressing_s_or_u_on_a_stash_diff_requests_no_staging() {
        let requests =
            staging_requests_after_stage_then_unstage(DiffSource::Stash(OID.to_string()));
        assert!(
            requests.is_empty(),
            "a stashed diff must not be stageable, but the viewer emitted {requests:?}"
        );
    }

    /// The control case. Without it the two tests above would still pass if the
    /// keys had simply stopped working everywhere.
    #[test]
    fn pressing_s_on_a_worktree_diff_still_requests_staging() {
        let requests = staging_requests_after_stage_then_unstage(DiffSource::Worktree);
        assert_eq!(
            requests,
            vec!["HunkStageRequested(0)".to_string()],
            "an unstaged working-tree diff must still stage on `s` (and ignore `u`)"
        );
    }

    /// The mirror control case: the index unstages on `u` and ignores `s`.
    #[test]
    fn pressing_u_on_an_index_diff_still_requests_unstaging() {
        let requests = staging_requests_after_stage_then_unstage(DiffSource::Index);
        assert_eq!(
            requests,
            vec!["HunkUnstageRequested(0)".to_string()],
            "a staged diff must still unstage on `u` (and ignore `s`)"
        );
    }

    /// Partial mode is available on committed content, whose line-level operation
    /// is applying or reverting those lines in the working tree. Staging is not,
    /// in partial mode either.
    #[test]
    fn partial_mode_on_a_commit_diff_still_refuses_to_stage() {
        let mut probe = ViewTest::open(StagingProbe::new);
        show(
            &mut probe,
            one_hunk_diff(),
            DiffSource::Commit(OID.to_string()),
        );

        probe.update(|probe, _window, cx| {
            probe
                .viewer
                .update(cx, |viewer, cx| viewer.toggle_partial_mode(cx));
        });
        probe.read(|probe, cx| {
            assert!(
                probe.viewer.read(cx).partial_mode,
                "line-level apply/revert needs partial mode, so `p` must work here"
            );
        });

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.select_all_lines(cx);
                viewer.stage_selection(cx);
                viewer.unstage_selection(cx);
            });
        });
        probe.read(|probe, _| {
            assert!(
                probe.requests().is_empty(),
                "partial mode must not open a staging route for committed content: {:?}",
                probe.requests()
            );
        });
    }

    #[test]
    fn partial_staging_mode_still_toggles_on_a_worktree_diff() {
        let mut probe = ViewTest::open(StagingProbe::new);
        show(&mut probe, one_hunk_diff(), DiffSource::Worktree);

        probe.update(|probe, _window, cx| {
            probe
                .viewer
                .update(cx, |viewer, cx| viewer.toggle_partial_mode(cx));
        });
        probe.read(|probe, cx| assert!(probe.viewer.read(cx).partial_mode));
        probe.update(|probe, _window, cx| {
            probe
                .viewer
                .update(cx, |viewer, cx| viewer.toggle_partial_mode(cx));
        });
        probe.read(|probe, cx| assert!(!probe.viewer.read(cx).partial_mode));
    }

    // ── apply / revert affordances ────────────────────────────────

    /// Shows `source` in a focused viewer, selects every row, then runs `act`
    /// against the viewer and returns the requests that came back.
    ///
    /// `act` calls the same public methods the `diff::*` actions dispatch to
    /// rather than simulating keystrokes: those bindings are gpui actions declared
    /// in `rgitui_workspace`, which sits above this crate, so a keystroke pressed
    /// here reaches no handler. The keystrokes are pinned by the keymap registry's
    /// own tests.
    fn requests_after(
        source: DiffSource,
        act: impl FnOnce(&mut DiffViewer, &mut Context<DiffViewer>),
    ) -> Vec<DiffViewerEvent> {
        let mut probe = ViewTest::open(StagingProbe::new);
        show(&mut probe, one_hunk_diff(), source);
        probe.read(|probe, cx| {
            assert!(
                probe.viewer.read(cx).row_count() > 0,
                "display rows should be prepared before the command is invoked"
            );
        });
        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.select_all_lines(cx);
                act(viewer, cx);
            });
        });
        probe.read(|probe, _| probe.request_events())
    }

    fn historical_sources() -> Vec<DiffSource> {
        vec![
            DiffSource::Commit(OID.to_string()),
            DiffSource::Stash(OID.to_string()),
            DiffSource::Compare {
                from: "main".to_string(),
                to: "feature".to_string(),
            },
        ]
    }

    #[test]
    fn applying_content_from_outside_the_working_tree_requests_an_apply() {
        for source in historical_sources() {
            let requests = requests_after(source.clone(), |viewer, cx| viewer.apply_selection(cx));
            assert_eq!(
                requests,
                vec![DiffViewerEvent::WorktreePatchRequested {
                    operation: DiffOperation::Apply,
                    scope: WorktreePatchScope::Hunk(0),
                }],
                "{source:?} should offer to apply its hunk"
            );
        }
    }

    #[test]
    fn reverting_content_from_outside_the_working_tree_requests_a_revert() {
        for source in historical_sources() {
            let requests = requests_after(source.clone(), |viewer, cx| viewer.revert_selection(cx));
            assert_eq!(
                requests,
                vec![DiffViewerEvent::WorktreePatchRequested {
                    operation: DiffOperation::Revert,
                    scope: WorktreePatchScope::Hunk(0),
                }],
                "{source:?} should offer to revert its hunk"
            );
        }
    }

    /// Working-tree content must not offer to apply or revert itself: it is
    /// already in the working tree, and the git layer has no tree pair to
    /// generate a patch from.
    #[test]
    fn applying_or_reverting_a_working_tree_diff_requests_nothing() {
        for source in [DiffSource::Worktree, DiffSource::Index] {
            let requests = requests_after(source.clone(), |viewer, cx| {
                viewer.apply_selection(cx);
                viewer.revert_selection(cx);
                viewer.apply_file(cx);
                viewer.revert_file(cx);
            });
            assert!(
                requests.is_empty(),
                "{source:?} must not emit a working-tree patch request, got {requests:?}"
            );
        }
    }

    #[test]
    fn a_line_selection_scopes_the_apply_to_those_lines() {
        // Partial mode plus a whole-diff row selection; the one change line in
        // the fixture is the addition at new line 2.
        let requests = requests_after(DiffSource::Commit(OID.to_string()), |viewer, cx| {
            viewer.toggle_partial_mode(cx);
            viewer.select_all_lines(cx);
            viewer.apply_selection(cx);
        });
        assert_eq!(
            requests,
            vec![DiffViewerEvent::WorktreePatchRequested {
                operation: DiffOperation::Apply,
                scope: WorktreePatchScope::Lines(vec![(None, Some(2))]),
            }],
            "a manual line selection must narrow the scope to those lines"
        );
    }

    #[test]
    fn the_file_menu_carries_apply_and_revert_only_for_content_from_elsewhere() {
        for source in historical_sources() {
            let mut probe = ViewTest::open(StagingProbe::new);
            show(&mut probe, one_hunk_diff(), source.clone());
            probe.read(|probe, cx| {
                assert_eq!(
                    probe.viewer.read(cx).file_menu_operations(),
                    vec![DiffOperation::Apply, DiffOperation::Revert],
                    "{source:?} needs a whole-file route; the hunk headers cannot express one"
                );
            });
        }

        for source in [DiffSource::Worktree, DiffSource::Index] {
            let mut probe = ViewTest::open(StagingProbe::new);
            show(&mut probe, one_hunk_diff(), source.clone());
            probe.read(|probe, cx| {
                assert!(
                    probe.viewer.read(cx).file_menu_operations().is_empty(),
                    "{source:?} stages whole files from the sidebar, so it gets no menu"
                );
            });
        }
    }

    #[test]
    fn the_dismiss_backdrop_only_exists_while_the_menu_does() {
        // The backdrop covers the diff body to catch outside clicks, so it must
        // never outlive the menu — otherwise it silently swallows clicks on the
        // diff itself. `file_menu_open` alone is not enough: a source with no
        // whole-file operations renders no menu even when the flag is set.
        let mut probe = ViewTest::open(StagingProbe::new);
        show(&mut probe, one_hunk_diff(), DiffSource::Worktree);
        probe.update(|probe, _, cx| {
            probe
                .viewer
                .update(cx, |viewer, _| viewer.file_menu_open = true);
        });
        probe.read(|probe, cx| {
            assert!(
                !probe.viewer.read(cx).file_menu_visible(),
                "the worktree has no menu to dismiss, so it must have no backdrop"
            );
        });

        let mut probe = ViewTest::open(StagingProbe::new);
        show(
            &mut probe,
            one_hunk_diff(),
            DiffSource::Commit(OID.to_string()),
        );
        probe.read(|probe, cx| {
            assert!(
                !probe.viewer.read(cx).file_menu_visible(),
                "the menu starts closed"
            );
        });
        probe.update(|probe, _, cx| {
            probe
                .viewer
                .update(cx, |viewer, _| viewer.file_menu_open = true);
        });
        probe.read(|probe, cx| {
            assert!(probe.viewer.read(cx).file_menu_visible());
        });
    }

    #[test]
    fn choosing_apply_from_the_file_menu_requests_the_whole_file() {
        let mut probe = ViewTest::open(StagingProbe::new);
        show(
            &mut probe,
            one_hunk_diff(),
            DiffSource::Commit(OID.to_string()),
        );

        probe.update(|probe, _, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.file_menu_open = true;
                viewer.request_whole_file_patch(DiffOperation::Apply, cx);
            });
        });

        probe.read(|probe, cx| {
            assert_eq!(
                probe.request_events(),
                vec![DiffViewerEvent::WorktreePatchRequested {
                    operation: DiffOperation::Apply,
                    scope: WorktreePatchScope::File,
                }]
            );
            assert!(
                !probe.viewer.read(cx).file_menu_open,
                "choosing an entry should dismiss the menu"
            );
        });
    }

    /// The whole-file commands ignore the row selection entirely, so the menu and
    /// the keystroke reach the same scope from opposite starting states.
    #[test]
    fn the_whole_file_commands_request_file_scope_whatever_is_selected() {
        for (operation, act) in [
            (
                DiffOperation::Apply,
                &DiffViewer::apply_file as &dyn Fn(&mut DiffViewer, &mut Context<DiffViewer>),
            ),
            (DiffOperation::Revert, &DiffViewer::revert_file),
        ] {
            let requests = requests_after(DiffSource::Commit(OID.to_string()), |viewer, cx| {
                act(viewer, cx)
            });
            assert_eq!(
                requests,
                vec![DiffViewerEvent::WorktreePatchRequested {
                    operation,
                    scope: WorktreePatchScope::File,
                }],
                "{operation:?} over the whole file must not be narrowed by the selection"
            );
        }
    }

    #[test]
    fn a_hunk_header_button_and_the_key_raise_the_same_request() {
        // Both routes go through `for_hunk`, so neither can drift from the other.
        for operation in [DiffOperation::Apply, DiffOperation::Revert] {
            assert_eq!(
                DiffViewerEvent::for_hunk(operation, 3),
                DiffViewerEvent::WorktreePatchRequested {
                    operation,
                    scope: WorktreePatchScope::Hunk(3),
                }
            );
        }
        assert_eq!(
            DiffViewerEvent::for_hunk(DiffOperation::Stage, 3),
            DiffViewerEvent::HunkStageRequested(3)
        );
        assert_eq!(
            DiffViewerEvent::for_hunk(DiffOperation::Unstage, 3),
            DiffViewerEvent::HunkUnstageRequested(3)
        );
    }

    #[test]
    fn independent_conflict_choices_emit_one_complete_staged_result() {
        let mut probe = ViewTest::open(StagingProbe::new);
        let snapshot = ConflictSnapshot {
            ancestor_oid: None,
            ancestor_mode: None,
            ours_oid: None,
            ours_mode: None,
            theirs_oid: None,
            theirs_mode: None,
            worktree: rgitui_git::ConflictWorktreeSnapshot::Regular {
                bytes: b"markers\n".to_vec(),
                executable: None,
                readonly: false,
            },
        };
        let diff = ThreeWayFileDiff {
            path: PATH.into(),
            sections: vec![
                MergeSection::Conflict {
                    ancestor: b"base-a\n".to_vec(),
                    ours: b"current-a\n".to_vec(),
                    theirs: b"incoming-a\n".to_vec(),
                },
                MergeSection::Resolved(b"middle\n".to_vec()),
                MergeSection::Conflict {
                    ancestor: b"base-b\n".to_vec(),
                    ours: b"current-b\n".to_vec(),
                    theirs: b"incoming-b\n".to_vec(),
                },
            ],
            snapshot: snapshot.clone(),
            ancestor_exists: true,
            ours_exists: true,
            theirs_exists: true,
            is_binary: false,
            is_special_file: false,
            result_mode: 0o100644,
        };

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_three_way_diff(diff, cx);
            });
        });
        probe.read(|probe, cx| {
            assert_eq!(probe.viewer.read(cx).unresolved_conflict_count(), 2);
        });
        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.use_current_for_conflict(cx);
                viewer.use_incoming_for_conflict(cx);
                viewer.save_conflict_result(cx);
            });
        });

        probe.read(|probe, _| {
            assert_eq!(
                probe.request_events(),
                vec![DiffViewerEvent::ConflictResolutionRequested(
                    ConflictResolution::SaveMerged {
                        path: PATH.to_string(),
                        content: b"current-a\nmiddle\nincoming-b\n".to_vec(),
                        mode: 0o100644,
                        snapshot,
                    }
                )]
            );
        });
    }

    #[test]
    fn conflict_view_is_active_while_its_model_is_loading() {
        let mut probe = ViewTest::open(StagingProbe::new);

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_conflict_loading(PATH.to_string(), cx);
            });
        });
        probe.read(|probe, cx| {
            let viewer = probe.viewer.read(cx);
            assert!(viewer.is_conflict_view_active());
            assert!(!viewer.has_three_way_diff());
            assert_eq!(viewer.file_path(), Some(PATH));
        });

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| viewer.clear(cx));
        });
        probe.read(|probe, cx| {
            assert!(!probe.viewer.read(cx).is_conflict_view_active());
        });
    }

    #[test]
    fn conflict_selection_invalidates_an_older_ordinary_diff_load() {
        let mut probe = ViewTest::open(StagingProbe::new);
        let ordinary_generation = probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_diff_loading("ordinary.txt".to_string(), DiffSource::Worktree, cx)
            })
        });

        let conflict_generation = probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_conflict_loading(PATH.to_string(), cx)
            })
        });

        probe.read(|probe, cx| {
            let viewer = probe.viewer.read(cx);
            assert_ne!(ordinary_generation, conflict_generation);
            assert_ne!(viewer.generation(), ordinary_generation);
            assert_eq!(viewer.file_path(), Some(PATH));
            assert!(viewer.is_conflict_view_active());
        });
    }

    #[test]
    fn conflict_selection_invalidates_an_older_pathless_diff_request() {
        let mut probe = ViewTest::open(StagingProbe::new);
        let historical_generation = probe.update(|probe, _window, cx| {
            probe
                .viewer
                .update(cx, |viewer, cx| viewer.begin_diff_request(cx))
        });

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_conflict_loading(PATH.to_string(), cx);
            });
        });

        probe.read(|probe, cx| {
            let viewer = probe.viewer.read(cx);
            assert_ne!(viewer.generation(), historical_generation);
            assert_eq!(viewer.file_path(), Some(PATH));
            assert!(viewer.is_conflict_view_active());
        });
    }

    #[test]
    fn choosing_a_conflict_side_invalidates_initial_row_preparation() {
        let mut probe = ViewTest::open(StagingProbe::new);
        let diff = ThreeWayFileDiff {
            path: PATH.into(),
            sections: vec![MergeSection::Conflict {
                ancestor: b"base\n".to_vec(),
                ours: b"current\n".to_vec(),
                theirs: b"incoming\n".to_vec(),
            }],
            snapshot: ConflictSnapshot {
                ancestor_oid: None,
                ancestor_mode: None,
                ours_oid: None,
                ours_mode: None,
                theirs_oid: None,
                theirs_mode: None,
                worktree: rgitui_git::ConflictWorktreeSnapshot::Missing,
            },
            ancestor_exists: true,
            ours_exists: true,
            theirs_exists: true,
            is_binary: false,
            is_special_file: false,
            result_mode: 0o100644,
        };

        let (initial_generation, chosen_generation, rebuilt_inline) =
            probe.update(|probe, _window, cx| {
                probe.viewer.update(cx, |viewer, cx| {
                    viewer.set_three_way_diff(diff, cx);
                    let initial_generation = viewer.preparation_generation;
                    let rows_before = std::sync::Arc::clone(&viewer.three_way_rows);
                    viewer.use_current_for_conflict(cx);
                    (
                        initial_generation,
                        viewer.preparation_generation,
                        !std::sync::Arc::ptr_eq(&rows_before, &viewer.three_way_rows),
                    )
                })
            });

        assert_ne!(initial_generation, chosen_generation);
        assert!(
            !rebuilt_inline,
            "row preparation must not run on the UI thread"
        );
        assert!(!super::should_apply_prepared(
            chosen_generation,
            initial_generation
        ));
        probe.read(|probe, cx| {
            assert_eq!(probe.viewer.read(cx).unresolved_conflict_count(), 0);
        });
    }

    #[test]
    fn filling_remaining_conflicts_preserves_existing_choices() {
        let mut probe = ViewTest::open(StagingProbe::new);
        let diff = ThreeWayFileDiff {
            path: PATH.into(),
            sections: vec![
                MergeSection::Conflict {
                    ancestor: b"base-a\n".to_vec(),
                    ours: b"current-a\n".to_vec(),
                    theirs: b"incoming-a\n".to_vec(),
                },
                MergeSection::Conflict {
                    ancestor: b"base-b\n".to_vec(),
                    ours: b"current-b\n".to_vec(),
                    theirs: b"incoming-b\n".to_vec(),
                },
            ],
            snapshot: ConflictSnapshot {
                ancestor_oid: None,
                ancestor_mode: None,
                ours_oid: None,
                ours_mode: None,
                theirs_oid: None,
                theirs_mode: None,
                worktree: rgitui_git::ConflictWorktreeSnapshot::Missing,
            },
            ancestor_exists: true,
            ours_exists: true,
            theirs_exists: true,
            is_binary: false,
            is_special_file: false,
            result_mode: 0o100644,
        };

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_three_way_diff(diff, cx);
                viewer.use_current_for_conflict(cx);
                viewer.use_incoming_for_all_conflicts(cx);
            });
        });

        probe.read(|probe, cx| {
            let viewer = probe.viewer.read(cx);
            assert_eq!(
                viewer.conflict_choices,
                vec![Some(ConflictChoice::Ours), Some(ConflictChoice::Theirs)]
            );
            assert_eq!(viewer.unresolved_conflict_count(), 0);
        });
    }

    #[test]
    fn whole_side_resolution_event_carries_the_loaded_snapshot() {
        let mut probe = ViewTest::open(StagingProbe::new);
        let snapshot = ConflictSnapshot {
            ancestor_oid: None,
            ancestor_mode: None,
            ours_oid: None,
            ours_mode: None,
            theirs_oid: None,
            theirs_mode: None,
            worktree: rgitui_git::ConflictWorktreeSnapshot::Regular {
                bytes: b"binary markers\0".to_vec(),
                executable: None,
                readonly: false,
            },
        };
        let diff = ThreeWayFileDiff {
            path: PATH.into(),
            sections: vec![MergeSection::Conflict {
                ancestor: b"base\0".to_vec(),
                ours: b"current\0".to_vec(),
                theirs: b"incoming\0".to_vec(),
            }],
            snapshot: snapshot.clone(),
            ancestor_exists: true,
            ours_exists: true,
            theirs_exists: true,
            is_binary: true,
            is_special_file: false,
            result_mode: 0o100644,
        };

        probe.update(|probe, _window, cx| {
            probe.viewer.update(cx, |viewer, cx| {
                viewer.set_three_way_diff(diff, cx);
                viewer.use_current_for_conflict(cx);
                viewer.save_conflict_result(cx);
            });
        });

        probe.read(|probe, _| {
            assert_eq!(
                probe.request_events(),
                vec![DiffViewerEvent::ConflictResolutionRequested(
                    ConflictResolution::UseOurs {
                        path: PATH.to_string(),
                        snapshot,
                    }
                )]
            );
        });
    }
}
