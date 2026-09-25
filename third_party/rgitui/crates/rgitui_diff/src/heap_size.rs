//! [`HeapSize`] for the rendered rows and the cache that retains them.
//!
//! This is the view where a naive measurement misleads. Every source line is
//! stored twice — once as a unified row, once as a side-by-side row — but the
//! two rows hold clones of one [`gpui::SharedString`], so the text is on the
//! heap once while the highlight spans painted over it are on it twice.
//! Charging text at both sites would report roughly double what the app holds
//! and send someone deduplicating storage that is already deduplicated;
//! charging highlights at one site would hide duplication that is really
//! there. Every row population is therefore split into a `text` node,
//! deduplicated by buffer address, and a `highlights` node that is not.
//!
//! The other half of the story is retention. A [`crate::DisplayCache`] entry
//! keeps the rendered rows *and* the [`FileDiff`] they were rendered from, so
//! the cache's bound of fifty entries is really a bound on two populations
//! that scale differently: the source lines, and the spans syntect produced
//! for them. The walk names them separately for the same reason.

use std::ops::Range;
use std::sync::Arc;

use gpui::HighlightStyle;
use rgitui_git::FileDiff;
use rgitui_perf::{Census, HeapSize};

use crate::{
    CachedDisplayRows, DiffSource, DiffViewer, DisplayCache, DisplayCacheKey, DisplayRow,
    SideBySideRow, StyledLine, ThreeWayRow,
};

/// Bytes a line's highlight spans occupy.
///
/// The vector is priced arithmetically rather than by walking its elements
/// because [`HighlightStyle`] belongs to `gpui`: the orphan rule puts a
/// `HeapSize` impl for it out of reach of this crate, and of the type's own
/// crate too. Arithmetic is exact here rather than a concession — every field
/// of a `HighlightStyle` is an `Option` of `Copy` plain data (colours as four
/// `f32`s, a font weight, a thickness, a flag), so a span owns nothing beyond
/// the inline bytes the vector's buffer already accounts for.
fn highlight_bytes(line: &StyledLine) -> usize {
    line.highlights.capacity() * size_of::<(Range<usize>, HighlightStyle)>()
}

/// A styled line is a shared text handle plus a private span vector, and
/// telling those apart is what this module exists for: the text is charged to
/// the first row that reaches it, the spans to every row holding a copy.
impl HeapSize for StyledLine {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.text.heap_size(census) + highlight_bytes(self)
    }
}

/// A rendered row seen as the parts the census prices separately.
///
/// The three row types differ only in how many styled lines they carry, so
/// this is what lets one measurement serve all of them and keeps the plain
/// [`HeapSize`] impls below from drifting away from the labelled walk.
trait StyledRow {
    /// Bytes owned by fields that are not styled lines: the hunk header and
    /// the enclosing context name, which are `String`s of their own rather
    /// than handles into shared text.
    fn header_bytes(&self, census: &mut Census) -> usize;

    /// The row's styled lines — one for a unified row, two for a side-by-side
    /// pair, three for a three-way triple.
    fn styled_lines(&self) -> [Option<&StyledLine>; 3];
}

impl StyledRow for DisplayRow {
    fn header_bytes(&self, census: &mut Census) -> usize {
        match self {
            DisplayRow::HunkHeader {
                header,
                context_name,
                ..
            } => header.heap_size(census) + context_name.heap_size(census),
            DisplayRow::Line { .. } => 0,
        }
    }

    fn styled_lines(&self) -> [Option<&StyledLine>; 3] {
        match self {
            DisplayRow::HunkHeader { .. } => [None, None, None],
            DisplayRow::Line { styled, .. } => [Some(styled), None, None],
        }
    }
}

impl StyledRow for SideBySideRow {
    fn header_bytes(&self, census: &mut Census) -> usize {
        match self {
            SideBySideRow::HunkHeader {
                header,
                context_name,
                ..
            } => header.heap_size(census) + context_name.heap_size(census),
            SideBySideRow::Pair { .. } => 0,
        }
    }

    fn styled_lines(&self) -> [Option<&StyledLine>; 3] {
        match self {
            SideBySideRow::HunkHeader { .. } => [None, None, None],
            SideBySideRow::Pair {
                left_styled,
                right_styled,
                ..
            } => [Some(left_styled), Some(right_styled), None],
        }
    }
}

impl StyledRow for ThreeWayRow {
    fn header_bytes(&self, census: &mut Census) -> usize {
        match self {
            ThreeWayRow::HunkHeader {
                header,
                context_name,
                ..
            } => header.heap_size(census) + context_name.heap_size(census),
            ThreeWayRow::Triple { .. } => 0,
        }
    }

    fn styled_lines(&self) -> [Option<&StyledLine>; 3] {
        match self {
            ThreeWayRow::HunkHeader { .. } => [None, None, None],
            ThreeWayRow::Triple {
                left_styled,
                mid_styled,
                right_styled,
                ..
            } => [Some(left_styled), Some(mid_styled), Some(right_styled)],
        }
    }
}

/// A row's own strings plus everything its styled lines own.
fn row_bytes<R: StyledRow>(row: &R, census: &mut Census) -> usize {
    let mut bytes = row.header_bytes(census);
    for line in row.styled_lines().into_iter().flatten() {
        bytes += line.heap_size(census);
    }
    bytes
}

impl HeapSize for DisplayRow {
    fn heap_size(&self, census: &mut Census) -> usize {
        row_bytes(self, census)
    }
}

/// A side-by-side row is where the duplication shows up: both of its styled
/// lines are clones of unified rows, so its text costs nothing extra and its
/// highlight vectors cost their full size again.
impl HeapSize for SideBySideRow {
    fn heap_size(&self, census: &mut Census) -> usize {
        row_bytes(self, census)
    }
}

impl HeapSize for ThreeWayRow {
    fn heap_size(&self, census: &mut Census) -> usize {
        row_bytes(self, census)
    }
}

/// Which half of a set of [`StyledLine`]s a node is measuring.
#[derive(Clone, Copy)]
enum LinePart {
    /// The text, whose buffer every display mode shares.
    Text,
    /// The highlight spans, which every display mode allocates for itself.
    Highlights,
}

/// One part of the styled lines held by a set of row collections.
struct RowPart<'a, R>(&'a [&'a Arc<Vec<R>>], LinePart);

impl<R: StyledRow> HeapSize for RowPart<'_, R> {
    fn heap_size(&self, census: &mut Census) -> usize {
        let mut bytes = 0;
        for rows in self.0 {
            for row in rows.iter() {
                for line in row.styled_lines().into_iter().flatten() {
                    bytes += match self.1 {
                        LinePart::Text => line.text.heap_size(census),
                        LinePart::Highlights => highlight_bytes(line),
                    };
                }
            }
        }
        bytes
    }
}

/// A set of `Arc`-shared row collections measured as one population, split
/// into the text they share and the highlights they do not.
///
/// The deduplication has to happen before that split rather than inside it.
/// The viewer's live rows are `Arc` clones of a cache entry's, so a collection
/// reached twice would have its text correctly charged once — the
/// `SharedString` impl sees to that — but its highlight vectors charged twice,
/// because those really are separate allocations and the census has no way to
/// tell a genuine second copy from a second visit to the first one. Skipping
/// an already-charged collection whole is what keeps both halves honest.
struct RowPopulation<'a, R>(Vec<&'a Arc<Vec<R>>>);

impl<R: StyledRow> HeapSize for RowPopulation<'_, R> {
    fn heap_size(&self, census: &mut Census) -> usize {
        let fresh: Vec<&Arc<Vec<R>>> = self
            .0
            .iter()
            .copied()
            .filter(|rows| {
                let id = Arc::as_ptr(rows) as *const () as usize;
                census.visit_shared(id, &()).is_some()
            })
            .collect();

        let mut bytes = 0;
        for rows in &fresh {
            // The `Vec` header lives inside the `Arc`'s allocation, so it is
            // this population's cost rather than its holder's.
            bytes += size_of::<Vec<R>>() + rows.capacity() * size_of::<R>();
            for row in rows.iter() {
                bytes += row.header_bytes(census);
            }
        }

        bytes
            + census.enter("text", &RowPart(&fresh, LinePart::Text))
            + census.enter("highlights", &RowPart(&fresh, LinePart::Highlights))
    }

    /// Every row the node names, including collections another path was
    /// charged for. A node reporting zero bytes against a large row count is
    /// the report saying "these rows exist and are counted elsewhere", which
    /// is more useful than a count that silently drops them.
    fn heap_count(&self) -> Option<usize> {
        Some(self.0.iter().map(|rows| rows.len()).sum())
    }
}

impl HeapSize for DiffSource {
    fn heap_size(&self, census: &mut Census) -> usize {
        match self {
            DiffSource::Worktree | DiffSource::Index => 0,
            DiffSource::Commit(oid) | DiffSource::Stash(oid) => oid.heap_size(census),
            DiffSource::Compare { from, to } => from.heap_size(census) + to.heap_size(census),
        }
    }
}

impl HeapSize for DisplayCacheKey {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.file_path.heap_size(census) + self.source.heap_size(census)
    }
}

/// A whole cache entry: the rows it rendered and the diff it rendered them
/// from. The census walks the cache by population rather than entry by entry —
/// fifty entries would mean fifty near-identical node paths — so this is the
/// measure for anyone asking what a single entry costs.
impl HeapSize for CachedDisplayRows {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.display_rows.heap_size(census)
            + self.sbs_rows.heap_size(census)
            + self.source_diff.heap_size(census)
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.display_rows.len() + self.sbs_rows.len())
    }
}

/// The cache's keys: the table itself, the key strings, and the recency queue
/// that holds a second full clone of every key.
struct CacheKeys<'a>(&'a DisplayCache);

impl HeapSize for CacheKeys<'_> {
    fn heap_size(&self, census: &mut Census) -> usize {
        // hashbrown keeps `(key, value)` pairs in one bucket array with a
        // control byte per bucket, so the table costs the whole pair even
        // though only the key half is charged here; the value half is charged
        // by the sibling nodes.
        let mut bytes =
            self.0.entries.capacity() * (size_of::<(DisplayCacheKey, CachedDisplayRows)>() + 1);
        for key in self.0.entries.keys() {
            bytes += key.heap_size(census);
        }
        // The recency queue clones its keys, so those strings are a second
        // allocation rather than a shared one.
        bytes + self.0.recency.heap_size(census)
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.0.entries.len())
    }
}

/// The source diffs the cache retains alongside the rows it rendered.
///
/// They are kept so a fingerprint collision is a miss rather than stale
/// content, which means every cached file's lines are held twice: once as
/// `String`s here and again as rendered text. Naming this separately is what
/// lets someone see that trade rather than infer it.
struct CachedSourceDiffs<'a>(&'a DisplayCache);

impl HeapSize for CachedSourceDiffs<'_> {
    fn heap_size(&self, census: &mut Census) -> usize {
        let mut bytes = 0;
        for entry in self.0.entries.values() {
            bytes += entry.source_diff.heap_size(census);
        }
        bytes
    }

    /// Lines rather than files, matching how `FileDiff` counts itself.
    fn heap_count(&self) -> Option<usize> {
        Some(
            self.0
                .entries
                .values()
                .filter_map(|entry| entry.source_diff.heap_count())
                .sum(),
        )
    }
}

/// The cache is walked as four populations rather than entry by entry. The
/// question a report has to answer is not which file is cached but whether the
/// retained weight is the source diffs, the rendered rows, or the spans
/// painted over them — and that answer is the same shape whether the cache
/// holds two entries or fifty.
impl HeapSize for DisplayCache {
    fn heap_size(&self, census: &mut Census) -> usize {
        let unified: Vec<&Arc<Vec<DisplayRow>>> = self
            .entries
            .values()
            .map(|entry| &entry.display_rows)
            .collect();
        let side_by_side: Vec<&Arc<Vec<SideBySideRow>>> =
            self.entries.values().map(|entry| &entry.sbs_rows).collect();

        census.enter("keys", &CacheKeys(self))
            + census.enter("source_diffs", &CachedSourceDiffs(self))
            + census.enter("unified_rows", &RowPopulation(unified))
            + census.enter("side_by_side_rows", &RowPopulation(side_by_side))
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.entries.len())
    }
}

/// The parts of a [`DiffViewer`] the census measures.
///
/// Held apart from the view so the node labels can be checked without opening
/// a window: the labels are the report's primary key — a run-to-run comparison
/// matches nodes by path — so one that changes silently turns a comparison
/// into two unrelated reports.
struct DiffViewerCensus<'a> {
    diff: &'a Option<Arc<FileDiff>>,
    display_rows: &'a Arc<Vec<DisplayRow>>,
    sbs_rows: &'a Arc<Vec<SideBySideRow>>,
    three_way_rows: &'a Arc<Vec<ThreeWayRow>>,
    display_cache: &'a DisplayCache,
}

impl<'a> From<&'a DiffViewer> for DiffViewerCensus<'a> {
    fn from(viewer: &'a DiffViewer) -> Self {
        Self {
            diff: &viewer.diff,
            display_rows: &viewer.display_rows,
            sbs_rows: &viewer.sbs_rows,
            three_way_rows: &viewer.three_way_rows,
            display_cache: &viewer.display_cache,
        }
    }
}

impl HeapSize for DiffViewerCensus<'_> {
    fn heap_size(&self, census: &mut Census) -> usize {
        census.enter("display_cache", self.display_cache)
            + census.enter("diff", self.diff)
            + census.enter("unified_rows", &RowPopulation(vec![self.display_rows]))
            + census.enter("side_by_side_rows", &RowPopulation(vec![self.sbs_rows]))
            + census.enter("three_way_rows", &RowPopulation(vec![self.three_way_rows]))
    }
}

impl DiffViewer {
    /// Records this view's retained memory under the current census path,
    /// returning the bytes attributed so an enclosing scope can roll them up.
    ///
    /// The cache is walked before the live fields deliberately. What is on
    /// screen is an `Arc` clone of a cache entry, so exactly one of the two
    /// paths can be charged for it; charging the cache means `display_cache`
    /// reports what the cache is really holding — the figure someone would act
    /// on by lowering its bound — rather than that figure minus whichever file
    /// happens to be open. The live nodes then read zero bytes against a
    /// non-zero row count, which is the report saying "shared, counted above",
    /// and go non-zero exactly when the displayed rows are *not* in the cache:
    /// a three-way conflict view, or a diff too large for the cache to accept.
    ///
    /// Two things the viewer holds stay outside the census. The three-way
    /// source diff's type belongs to `rgitui_git`, which puts a `HeapSize`
    /// impl for it beyond the orphan rule's reach from here, and
    /// `wrap_list_state`'s per-row measurement tree is private to gpui. Both
    /// scale with the file on screen rather than with history, so the gap they
    /// leave is bounded by one file.
    pub fn census(&self, census: &mut Census) -> usize {
        DiffViewerCensus::from(self).heap_size(census)
    }
}

#[cfg(test)]
mod tests {
    /// Comfortably past `SharedString`'s inline threshold, so the text these
    /// fixtures build genuinely lives on the heap and genuinely is shared
    /// between clones. A short literal here silently asserts against a buffer
    /// that was never allocated.
    const LONG_LINE: &str = "let total = values.iter().copied().sum::<usize>();";

    use gpui::SharedString;
    use rgitui_git::{DiffHunk, DiffLine, FileChangeKind};

    use super::*;
    use crate::{DisplayLineKind, SideBySideLineKind};

    /// Bytes one highlight span occupies inside its vector.
    fn span_bytes() -> usize {
        size_of::<(Range<usize>, HighlightStyle)>()
    }

    /// A line with exactly one highlight span, so its vector's capacity is
    /// known rather than left to the allocator.
    fn styled(text: &SharedString) -> StyledLine {
        StyledLine {
            text: text.clone(),
            highlights: vec![(0..2, HighlightStyle::default())],
        }
    }

    fn unified_row(text: &SharedString) -> DisplayRow {
        DisplayRow::Line {
            old_num: Some(1),
            new_num: Some(1),
            styled: styled(text),
            kind: DisplayLineKind::Context,
        }
    }

    /// The side-by-side twin of [`unified_row`]: both halves show the same
    /// context line, exactly as the real renderer builds them.
    fn side_by_side_row(text: &SharedString) -> SideBySideRow {
        SideBySideRow::Pair {
            left_num: Some(1),
            left_styled: styled(text),
            left_kind: SideBySideLineKind::Context,
            right_num: Some(1),
            right_styled: styled(text),
            right_kind: SideBySideLineKind::Context,
        }
    }

    fn file_diff() -> FileDiff {
        FileDiff {
            path: std::path::PathBuf::from("src/main.rs"),
            hunks: vec![DiffHunk {
                old_start: 1,
                old_lines: 1,
                new_start: 1,
                new_lines: 1,
                header: "@@ -1 +1 @@".to_string(),
                lines: vec![DiffLine::Context("fn main() {".to_string())],
            }],
            additions: 0,
            deletions: 0,
            kind: FileChangeKind::Modified,
        }
    }

    fn cache_key(diff: &FileDiff) -> DisplayCacheKey {
        DisplayCacheKey::new(
            diff.path.display().to_string(),
            true,
            DiffSource::Worktree,
            diff,
        )
    }

    /// A cache holding one entry whose rows are the same allocations the
    /// viewer would be displaying.
    fn populated_cache(
        diff: &Arc<FileDiff>,
        display_rows: &Arc<Vec<DisplayRow>>,
        sbs_rows: &Arc<Vec<SideBySideRow>>,
    ) -> DisplayCache {
        let mut cache = DisplayCache::default();
        cache.insert(
            cache_key(diff),
            CachedDisplayRows {
                display_rows: Arc::clone(display_rows),
                sbs_rows: Arc::clone(sbs_rows),
                display_longest_row_ix: 0,
                source_diff: Arc::clone(diff),
            },
        );
        cache
    }

    fn node<'a>(nodes: &'a [rgitui_perf::CensusNode], path: &str) -> &'a rgitui_perf::CensusNode {
        nodes
            .iter()
            .find(|node| node.path == path)
            .unwrap_or_else(|| panic!("{path} is missing from the census"))
    }

    #[test]
    fn a_styled_lines_highlights_are_charged_their_capacity() {
        let mut census = Census::new();
        let text = LONG_LINE;
        let mut highlights = Vec::with_capacity(8);
        highlights.push((0..3, HighlightStyle::default()));

        let line = StyledLine {
            text: SharedString::from(text.to_string()),
            highlights,
        };

        assert_eq!(
            line.heap_size(&mut census),
            text.len() + 8 * span_bytes(),
            "a vector that grew and was not filled is still holding its buffer"
        );
    }

    #[test]
    fn shared_text_is_charged_once_while_duplicated_highlights_are_charged_twice() {
        let text = SharedString::from(LONG_LINE.to_string());
        let unified = unified_row(&text);
        let side_by_side = side_by_side_row(&text);

        let mut census = Census::new();
        let unified_bytes = unified.heap_size(&mut census);
        let side_by_side_bytes = side_by_side.heap_size(&mut census);

        assert_eq!(
            unified_bytes,
            text.len() + span_bytes(),
            "the first row to reach the text is charged for it"
        );
        assert_eq!(
            side_by_side_bytes,
            2 * span_bytes(),
            "the twin shares the text buffer but owns both of its own span vectors"
        );
        assert_eq!(
            unified_bytes + side_by_side_bytes,
            text.len() + 3 * span_bytes(),
            "three span vectors exist and one text buffer does"
        );
    }

    #[test]
    fn a_populated_cache_reports_its_entries_and_a_non_zero_size() {
        let diff = Arc::new(file_diff());
        let text = SharedString::from(LONG_LINE.to_string());
        let display_rows = Arc::new(vec![unified_row(&text)]);
        let sbs_rows = Arc::new(vec![side_by_side_row(&text)]);
        let cache = populated_cache(&diff, &display_rows, &sbs_rows);

        let mut census = Census::new();
        let bytes = census.enter("display_cache", &cache);
        let nodes = census.into_nodes();

        assert_eq!(node(&nodes, "display_cache").count, Some(1));
        assert!(bytes > 0, "a cache holding an entry cannot cost nothing");
        assert!(node(&nodes, "display_cache/source_diffs").bytes > 0);
        assert!(node(&nodes, "display_cache/unified_rows/text").bytes > 0);
        assert_eq!(
            node(&nodes, "display_cache/side_by_side_rows/text").bytes,
            0,
            "the side-by-side rows clone the unified rows' text"
        );
        assert_eq!(
            node(&nodes, "display_cache/side_by_side_rows/highlights").bytes,
            2 * span_bytes(),
            "they do not clone its highlights"
        );
    }

    #[test]
    fn rows_shared_with_the_cache_are_charged_to_the_cache_alone() {
        let diff = Arc::new(file_diff());
        let text = SharedString::from(LONG_LINE.to_string());
        let display_rows = Arc::new(vec![unified_row(&text)]);
        let sbs_rows = Arc::new(vec![side_by_side_row(&text)]);
        let cache = populated_cache(&diff, &display_rows, &sbs_rows);

        let viewer = DiffViewerCensus {
            diff: &Some(Arc::clone(&diff)),
            display_rows: &display_rows,
            sbs_rows: &sbs_rows,
            three_way_rows: &Arc::new(Vec::new()),
            display_cache: &cache,
        };

        let mut census = Census::new();
        census.enter("diff_viewer", &viewer);
        let nodes = census.into_nodes();

        assert!(node(&nodes, "diff_viewer/display_cache").bytes > 0);
        assert_eq!(
            node(&nodes, "diff_viewer/diff").bytes,
            0,
            "the displayed diff is the entry's own source diff"
        );
        assert_eq!(node(&nodes, "diff_viewer/unified_rows").bytes, 0);
        assert_eq!(
            node(&nodes, "diff_viewer/unified_rows").count,
            Some(1),
            "the rows are still named, so the report can say where they went"
        );
    }

    #[test]
    fn rows_the_cache_refused_are_charged_to_the_viewer() {
        let text = SharedString::from(LONG_LINE.to_string());
        let three_way_rows = Arc::new(vec![ThreeWayRow::Triple {
            left_num: Some(1),
            left_styled: styled(&text),
            left_kind: crate::ThreeWayLineKind::Unchanged,
            mid_num: Some(1),
            mid_styled: styled(&text),
            mid_kind: crate::ThreeWayLineKind::Unchanged,
            right_num: Some(1),
            right_styled: styled(&text),
            right_kind: crate::ThreeWayLineKind::Unchanged,
        }]);

        let viewer = DiffViewerCensus {
            diff: &None,
            display_rows: &Arc::new(Vec::new()),
            sbs_rows: &Arc::new(Vec::new()),
            three_way_rows: &three_way_rows,
            display_cache: &DisplayCache::default(),
        };

        let mut census = Census::new();
        census.enter("diff_viewer", &viewer);
        let nodes = census.into_nodes();

        assert_eq!(
            node(&nodes, "diff_viewer/three_way_rows/text").bytes,
            text.len()
        );
        assert_eq!(
            node(&nodes, "diff_viewer/three_way_rows/highlights").bytes,
            3 * span_bytes()
        );
    }

    #[test]
    fn the_viewer_census_emits_one_node_per_measured_population() {
        let viewer = DiffViewerCensus {
            diff: &None,
            display_rows: &Arc::new(Vec::new()),
            sbs_rows: &Arc::new(Vec::new()),
            three_way_rows: &Arc::new(Vec::new()),
            display_cache: &DisplayCache::default(),
        };

        let mut census = Census::new();
        census.enter("diff_viewer", &viewer);

        let mut paths: Vec<String> = census
            .into_nodes()
            .into_iter()
            .map(|node| node.path)
            .collect();
        paths.sort();

        assert_eq!(
            paths,
            [
                "diff_viewer",
                "diff_viewer/diff",
                "diff_viewer/display_cache",
                "diff_viewer/display_cache/keys",
                "diff_viewer/display_cache/side_by_side_rows",
                "diff_viewer/display_cache/side_by_side_rows/highlights",
                "diff_viewer/display_cache/side_by_side_rows/text",
                "diff_viewer/display_cache/source_diffs",
                "diff_viewer/display_cache/unified_rows",
                "diff_viewer/display_cache/unified_rows/highlights",
                "diff_viewer/display_cache/unified_rows/text",
                "diff_viewer/side_by_side_rows",
                "diff_viewer/side_by_side_rows/highlights",
                "diff_viewer/side_by_side_rows/text",
                "diff_viewer/three_way_rows",
                "diff_viewer/three_way_rows/highlights",
                "diff_viewer/three_way_rows/text",
                "diff_viewer/unified_rows",
                "diff_viewer/unified_rows/highlights",
                "diff_viewer/unified_rows/text",
            ]
        );
    }
}
