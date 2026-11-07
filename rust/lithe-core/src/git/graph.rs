//! Deterministic, coordinate-free Git graph projection (`git.graphProjection`).
//!
//! This module owns the IntelliJ-compatible commit graph layout that both
//! native products used to implement separately: the permanent layout (head
//! ordering, depth-first layout indices and color IDs), the filtered visible
//! graph (dotted edges, hidden ancestors, missing parents), per-row element
//! ordering, lane positions, print elements, and the recommended graph width.
//!
//! The result contains only integer lane positions, stable signed color IDs,
//! routes, and typed labels. Hosts own pixels, curves, and the mapping from a
//! color ID to a theme color.
//!
//! Incremental loading: the projection is always recomputed for the whole
//! loaded window in one call. Lanes depend on every loaded edge and on the head
//! order, so carrying lane state across pages would make the first rows depend
//! on call history. A head fragment's color ID is a hash of its principal
//! reference name, so a named branch keeps its color across pages and refreshes.
//!
//! Adapted from JetBrains IntelliJ Community (`PermanentLinearGraphBuilder`,
//! `GraphColorManagerImpl`, `DottedFilterEdgesGenerator`,
//! `PrintElementGeneratorImpl`, `GraphElementComparatorByLayoutIndex`,
//! `NaturalComparator`), Apache-2.0, Copyright 2000-2024 JetBrains s.r.o. and
//! contributors. See `macos/Resources/GitGraph/NOTICE.txt`.

use crate::project::file_name_order::compare_reference_names;
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

const GRAPH_PROJECTION_VERSION: u32 = 1;
/// Largest commit list (scoped window or repository context) one request may carry.
const MAX_COMMITS: usize = 20_000;
/// IntelliJ samples at most this many rows when recommending a graph width.
const RECOMMENDED_WIDTH_SAMPLE_SIZE: usize = 20_000;
const RECOMMENDED_WIDTH_WEIGHT_RATIO: f64 = 0.1;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    /// Scoped commits in Git's child-before-parent order.
    commits: Vec<CommitInput>,
    /// Short names of the remotes, so a bare remote-tracking name is typed correctly.
    #[serde(default)]
    remote_names: Vec<String>,
    /// The complete repository history window that fixes the permanent layout.
    #[serde(default)]
    repository_commits: Vec<CommitInput>,
    /// Commits that match the active filter; `None` shows every commit.
    #[serde(default)]
    visible_hashes: Option<Vec<String>>,
    #[serde(default)]
    display_mode: DisplayMode,
    /// When present, the response lists the commits reachable from this local branch.
    #[serde(default)]
    current_branch: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CommitInput {
    hash: String,
    #[serde(default)]
    parent_hashes: Vec<String>,
    #[serde(default)]
    decorations: String,
}

#[derive(Debug, Default, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
enum DisplayMode {
    #[default]
    Compact,
    Expanded,
}

/// Long-edge limits taken from IntelliJ's `PrintElementGeneratorImpl`.
#[derive(Clone, Copy)]
struct DisplayOptions {
    long_edge_size: usize,
    visible_part_size: usize,
    edge_with_arrow_size: usize,
}

impl DisplayMode {
    fn options(self) -> DisplayOptions {
        match self {
            Self::Compact => DisplayOptions {
                long_edge_size: 30,
                visible_part_size: 1,
                edge_with_arrow_size: usize::MAX,
            },
            Self::Expanded => DisplayOptions {
                long_edge_size: 1_000,
                visible_part_size: 250,
                edge_with_arrow_size: 30,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// The semantic role of one reference label attached to a graph row.
pub enum GraphLabelKind {
    /// The current checked-out commit marker.
    Head,
    /// A local branch reference.
    Branch,
    /// A remote-tracking reference.
    Remote,
    /// An annotated or lightweight tag reference.
    Tag,
}

impl GraphLabelKind {
    fn name(self) -> &'static str {
        match self {
            Self::Head => "head",
            Self::Branch => "branch",
            Self::Remote => "remote",
            Self::Tag => "tag",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One renderer-independent label attached to a projected commit.
pub struct GraphLabel {
    /// Stable label identity, `<kind>:<title>`.
    pub id: String,
    /// Text supplied by Git after removing transport prefixes.
    pub title: String,
    /// Reference category used by hosts for styling.
    pub kind: GraphLabelKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Which half of an edge a print element draws relative to the row center.
pub enum PrintDirection {
    /// The half that reaches toward the previous (newer) row.
    Up,
    /// The half that reaches toward the next (older) row.
    Down,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One route from a commit node to a parent, in the next row's lane coordinates.
pub struct GraphParentEdge {
    /// Edge identity shared with the print elements that draw it.
    pub id: String,
    /// Parent commit hash.
    pub parent_hash: String,
    /// Lane the route occupies in the next row, or `None` at the last row.
    pub target_lane: Option<usize>,
    /// Signed color ID of the route.
    pub color_id: i32,
    /// The parent is outside the loaded history.
    pub is_missing: bool,
    /// The parent is a visible ancestor reached through filtered-out commits.
    pub is_dotted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// A half-edge through a row center; both halves meet at the row boundary midpoint.
pub struct GraphPrintElement {
    /// `<edge id>:<direction>`.
    pub id: String,
    /// Lane of this half in the current row.
    pub position: usize,
    /// Lane of the matching half in the neighbouring row (own lane for a terminal).
    pub adjacent_position: usize,
    /// Direction of the half relative to the row center.
    pub direction: PrintDirection,
    /// Signed color ID of the edge.
    pub color_id: i32,
    /// Filtered topology drawn as a dotted line.
    pub is_dotted: bool,
    /// The edge ends at an unloaded parent.
    pub is_missing: bool,
    /// Long edges and unloaded parents end with a directional marker.
    pub has_arrow: bool,
    /// No matching half exists in the neighbouring row.
    pub is_terminal: bool,
    /// Loaded visible endpoint; missing history never invents a target.
    pub target_hash: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One visible commit with its lane, colors, routes, and labels.
pub struct GraphRow {
    /// Hash of the commit this row draws.
    pub commit_hash: String,
    /// Lane of the commit node.
    pub lane: usize,
    /// Number of lanes occupied in this row.
    pub lane_count: usize,
    /// Signed color ID of the node.
    pub color_id: i32,
    /// Permanent layout index, independent of screen lanes.
    pub layout_index: i64,
    /// Color ID of every row-center element, by lane.
    pub incoming_lane_colors: Vec<i32>,
    /// Routes leaving this commit toward its parents.
    pub parent_edges: Vec<GraphParentEdge>,
    /// Typed decoration labels in source order.
    pub labels: Vec<GraphLabel>,
    /// Explicit half-edges for this row.
    pub print_elements: Vec<GraphPrintElement>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Versioned renderer-neutral graph projection for one loaded history window.
pub struct GraphProjection {
    /// Wire-format version for host migrations.
    pub version: u32,
    /// Visible rows in display order.
    pub rows: Vec<GraphRow>,
    /// Widest row, in lanes.
    pub lane_count: usize,
    /// IntelliJ's weighted visible-edge width; a baseline rather than the widest row.
    pub recommended_lane_count: usize,
    /// One or more routes end at a parent outside the loaded history.
    pub has_missing_parents: bool,
    /// Hashes reachable from `currentBranch`, sorted; empty when none was requested.
    pub current_branch_hashes: Vec<String>,
}

/// Handles `git.graphProjection`.
///
/// Projects one loaded history window in a single call. The request carries the
/// scoped `commits`, optional `repositoryCommits` that fix the permanent layout,
/// optional `visibleHashes` for a filtered graph, `remoteNames`, `displayMode`
/// (`compact` or `expanded`), and an optional `currentBranch`.
pub(crate) fn command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid Git graph request")
            .with_details(error.to_string())
    })?;
    if request.commits.len() > MAX_COMMITS
        || request.repository_commits.len() > MAX_COMMITS
        || request
            .visible_hashes
            .as_ref()
            .is_some_and(|hashes| hashes.len() > MAX_COMMITS)
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many commits to project",
        ));
    }
    serde_json::to_value(project(&request, request.display_mode.options())).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Could not encode the Git graph")
            .with_details(error.to_string())
    })
}

// MARK: - labels and head ordering

fn local_name(name: &str) -> &str {
    name.strip_prefix("refs/heads/").unwrap_or(name)
}

fn label(title: &str, kind: GraphLabelKind) -> GraphLabel {
    GraphLabel {
        id: format!("{}:{title}", kind.name()),
        title: title.to_string(),
        kind,
    }
}

fn parse_labels(decorations: &str, remote_names: &HashSet<&str>) -> Vec<GraphLabel> {
    let mut labels = Vec::new();
    for value in decorations.split(',') {
        let raw = value.trim();
        if raw.is_empty() {
            continue;
        }
        if raw == "HEAD" {
            labels.push(label("HEAD", GraphLabelKind::Head));
        } else if let Some(branch) = raw.strip_prefix("HEAD -> ") {
            labels.push(label("HEAD", GraphLabelKind::Head));
            labels.push(label(local_name(branch), GraphLabelKind::Branch));
        } else if let Some(tag) = raw.strip_prefix("tag: ") {
            labels.push(label(tag, GraphLabelKind::Tag));
        } else if let Some(tag) = raw.strip_prefix("refs/tags/") {
            labels.push(label(tag, GraphLabelKind::Tag));
        } else if remote_names.contains(raw)
            || raw.starts_with("origin/")
            || raw.starts_with("refs/remotes/")
        {
            let title = raw.strip_prefix("refs/remotes/").unwrap_or(raw);
            labels.push(label(title, GraphLabelKind::Remote));
        } else {
            labels.push(label(local_name(raw), GraphLabelKind::Branch));
        }
    }
    labels
}

/// IntelliJ `GitRefManager` priority: main remotes, local main, other remotes and
/// branches, tags, then HEAD.
fn priority(label: &GraphLabel) -> u8 {
    match label.kind {
        GraphLabelKind::Remote => {
            if matches!(label.title.as_str(), "origin/main" | "origin/master") {
                0
            } else {
                1
            }
        }
        GraphLabelKind::Branch => {
            if matches!(label.title.as_str(), "main" | "master") {
                2
            } else {
                3
            }
        }
        GraphLabelKind::Tag => 4,
        GraphLabelKind::Head => 6,
    }
}

fn compare_labels(left: &GraphLabel, right: &GraphLabel) -> Ordering {
    priority(left).cmp(&priority(right)).then_with(|| {
        let a = left.title.encode_utf16().collect::<Vec<_>>();
        let b = right.title.encode_utf16().collect::<Vec<_>>();
        compare_reference_names(&a, &b)
    })
}

/// The principal reference of a head: the first minimal label.
fn best_reference(labels: &[GraphLabel]) -> Option<&GraphLabel> {
    let mut best: Option<&GraphLabel> = None;
    for candidate in labels {
        if best.is_none_or(|current| compare_labels(candidate, current) == Ordering::Less) {
            best = Some(candidate);
        }
    }
    best
}

/// Java `String.hashCode`, used by IDEA's `GraphColorManagerImpl` for the principal
/// fragment of a referenced head. Unreferenced heads use zero.
fn color_id(labels: &[GraphLabel]) -> i32 {
    best_reference(labels).map_or(0, |reference| {
        reference.title.encode_utf16().fold(0i32, |hash, unit| {
            hash.wrapping_mul(31).wrapping_add(i32::from(unit))
        })
    })
}

/// Stable merge sort that tolerates a comparator that is not a strict total
/// order; the standard library sort may panic on one.
fn stable_sort<T: Copy>(items: &mut [T], less: impl Fn(T, T) -> bool) {
    let count = items.len();
    let mut buffer = items.to_vec();
    let mut width = 1;
    while width < count {
        let mut start = 0;
        while start < count {
            let middle = (start + width).min(count);
            let end = (start + 2 * width).min(count);
            let (mut left, mut right, mut out) = (start, middle, start);
            while left < middle && right < end {
                if less(items[right], items[left]) {
                    buffer[out] = items[right];
                    right += 1;
                } else {
                    buffer[out] = items[left];
                    left += 1;
                }
                out += 1;
            }
            while left < middle {
                buffer[out] = items[left];
                left += 1;
                out += 1;
            }
            while right < end {
                buffer[out] = items[right];
                right += 1;
                out += 1;
            }
            start += 2 * width;
        }
        items.copy_from_slice(&buffer);
        width *= 2;
    }
}

fn sorted_heads(labels: &[Vec<GraphLabel>], children: &[Vec<usize>]) -> Vec<usize> {
    let best = labels
        .iter()
        .map(|labels| best_reference(labels))
        .collect::<Vec<_>>();
    // A referenced branch may already have children. It still seeds the DFS
    // before less important graph tips; tags alone do not create a head.
    let mut heads = (0..labels.len())
        .filter(|&row| {
            children[row].is_empty() || labels[row].iter().any(|l| l.kind != GraphLabelKind::Tag)
        })
        .collect::<Vec<_>>();
    stable_sort(&mut heads, |left, right| match (best[left], best[right]) {
        (Some(a), Some(b)) => {
            if a == b {
                left < right
            } else {
                compare_labels(a, b) == Ordering::Less
            }
        }
        (Some(_), None) => true,
        (None, Some(_)) => false,
        (None, None) => left < right,
    });
    heads
}

// MARK: - topology and permanent layout

/// Parent and child rows over the first occurrence of each hash.
struct Topology<'a> {
    by_hash: HashMap<&'a str, usize>,
    parents: Vec<Vec<usize>>,
    children: Vec<Vec<usize>>,
}

impl<'a> Topology<'a> {
    fn new(commits: &'a [CommitInput]) -> Self {
        // History normally has unique IDs. The first occurrence wins so
        // overlapping pages cannot create a second row for one commit.
        let mut by_hash = HashMap::with_capacity(commits.len());
        for (row, commit) in commits.iter().enumerate() {
            by_hash.entry(commit.hash.as_str()).or_insert(row);
        }
        let mut parents = vec![Vec::new(); commits.len()];
        let mut children = vec![Vec::new(); commits.len()];
        for (row, commit) in commits.iter().enumerate() {
            let mut seen = HashSet::new();
            for hash in &commit.parent_hashes {
                if let Some(&parent) = by_hash.get(hash.as_str()) {
                    if parent > row && seen.insert(parent) {
                        parents[row].push(parent);
                        children[parent].push(row);
                    }
                }
            }
        }
        Self {
            by_hash,
            parents,
            children,
        }
    }
}

/// Layout indices and color IDs, independent of compact screen columns.
struct Permanent {
    indices: Vec<i64>,
    colors: Vec<i32>,
}

fn permanent_layout(labels: &[Vec<GraphLabel>], topology: &Topology) -> Permanent {
    let count = topology.parents.len();
    let mut indices = vec![0i64; count];
    let mut colors = vec![0i32; count];
    let mut next_parent = vec![0usize; count];
    let mut layout_index = 1i64;
    for head in sorted_heads(labels, &topology.children) {
        if indices[head] != 0 {
            continue;
        }
        let mut stack = vec![head];
        let head_index = layout_index;
        let head_color = color_id(&labels[head]);
        while let Some(&node) = stack.last() {
            let first_visit = indices[node] == 0;
            if first_visit {
                indices[node] = layout_index;
                // GraphColorGetterByHead + GraphColorManagerImpl: the head
                // fragment uses its reference name; side fragments use their index.
                colors[node] = if layout_index == head_index {
                    head_color
                } else {
                    layout_index as i32
                };
            }
            let parents = &topology.parents[node];
            while next_parent[node] < parents.len() && indices[parents[next_parent[node]]] != 0 {
                next_parent[node] += 1;
            }
            if next_parent[node] < parents.len() {
                stack.push(parents[next_parent[node]]);
            } else {
                if first_visit {
                    layout_index += 1;
                }
                stack.pop();
            }
        }
    }
    Permanent { indices, colors }
}

// MARK: - visible edges

#[derive(Debug)]
struct Edge {
    up: usize,
    down: Option<usize>,
    parent_hash: String,
    dotted: bool,
}

impl Edge {
    fn id(&self) -> String {
        let target = self
            .down
            .map_or_else(|| self.parent_hash.clone(), |down| down.to_string());
        format!("{}:{target}:{}", self.up, self.dotted)
    }
}

/// Collects the visible edges in visible-row coordinates.
struct EdgeBuilder<'a> {
    commits: &'a [CommitInput],
    visible_rows: &'a [Option<usize>],
    edges: Vec<Edge>,
    pairs: HashSet<(usize, usize)>,
}

impl EdgeBuilder<'_> {
    fn add(&mut self, up: usize, down: usize, dotted: bool) {
        let (Some(u), Some(d)) = (self.visible_rows[up], self.visible_rows[down]) else {
            return;
        };
        if u < d && self.pairs.insert((u, d)) {
            self.edges.push(Edge {
                up: u,
                down: Some(d),
                parent_hash: self.commits[down].hash.clone(),
                dotted,
            });
        }
    }
}

/// IntelliJ `DottedFilterEdgesGenerator`'s two directional number walks.
/// Nearest-visible propagation avoids an exponential ancestor path search.
fn dotted_edges(topology: &Topology, visible: &[bool], builder: &mut EdgeBuilder) {
    let count = topology.parents.len();
    let mut numbers = vec![i64::MIN; count];
    for node in 0..count {
        if visible[node] {
            let (mut nearest, mut adjacent) = (i64::MIN, i64::MIN);
            for &child in &topology.children[node] {
                if visible[child] {
                    adjacent = adjacent.max(numbers[child]);
                } else {
                    nearest = nearest.max(numbers[child]);
                }
            }
            if nearest == adjacent || nearest == i64::MIN {
                numbers[node] = adjacent;
            } else {
                builder.add(nearest as usize, node, true);
                numbers[node] = nearest;
            }
        } else {
            numbers[node] = topology.children[node]
                .iter()
                .fold(i64::MIN, |best, &child| {
                    best.max(if visible[child] {
                        child as i64
                    } else {
                        numbers[child]
                    })
                });
        }
    }
    numbers = vec![i64::MAX; count];
    for node in (0..count).rev() {
        if visible[node] {
            let (mut nearest, mut adjacent) = (i64::MAX, i64::MAX);
            for &parent in &topology.parents[node] {
                if visible[parent] {
                    adjacent = adjacent.min(numbers[parent]);
                } else {
                    nearest = nearest.min(numbers[parent]);
                }
            }
            if nearest == adjacent || nearest == i64::MAX {
                numbers[node] = adjacent;
            } else {
                builder.add(node, nearest as usize, true);
                numbers[node] = nearest;
            }
        } else {
            numbers[node] = topology.parents[node]
                .iter()
                .fold(i64::MAX, |best, &parent| {
                    best.min(if visible[parent] {
                        parent as i64
                    } else {
                        numbers[parent]
                    })
                });
        }
    }
}

/// Boundary DAG node for unloaded ancestors behind hidden commits: the local
/// unloaded hashes and the links to older groups.
#[derive(Hash, PartialEq, Eq)]
struct MissingGroup {
    hashes: Vec<String>,
    parents: Vec<usize>,
}

/// Projects unloaded ancestors through hidden commits without storing a full
/// reachable-hash set at every hidden node. Returns `(visible row, hash)` pairs.
fn missing_parents(
    commits: &[CommitInput],
    topology: &Topology,
    visible: &[usize],
    visible_flags: &[bool],
) -> Vec<(usize, String)> {
    let mut found = Vec::new();
    if visible.is_empty() {
        return found;
    }
    let mut group_for_row: Vec<Option<usize>> = vec![None; commits.len()];
    let mut groups: Vec<MissingGroup> = Vec::new();
    let mut group_ids: HashMap<(Vec<String>, Vec<usize>), usize> = HashMap::new();
    for row in (0..commits.len()).rev() {
        // A visible ancestor owns its own continuation. Duplicate page entries
        // and unrelated hidden roots cannot introduce fake edges.
        if visible_flags[row] || topology.by_hash.get(commits[row].hash.as_str()) != Some(&row) {
            continue;
        }
        let mut hashes = commits[row]
            .parent_hashes
            .iter()
            .filter(|hash| !topology.by_hash.contains_key(hash.as_str()))
            .cloned()
            .collect::<Vec<_>>();
        hashes.sort();
        hashes.dedup();
        let mut inherited = topology.parents[row]
            .iter()
            .filter_map(|&parent| group_for_row[parent])
            .collect::<Vec<_>>();
        inherited.sort_unstable();
        inherited.dedup();
        if hashes.is_empty() && inherited.len() <= 1 {
            group_for_row[row] = inherited.first().copied();
        } else {
            let key = (hashes, inherited);
            let id = *group_ids.entry(key.clone()).or_insert_with(|| {
                groups.push(MissingGroup {
                    hashes: key.0,
                    parents: key.1,
                });
                groups.len() - 1
            });
            group_for_row[row] = Some(id);
        }
    }
    if groups.is_empty() {
        return found;
    }
    // A traversal stamp avoids clearing a visited array for each visible commit.
    let mut visited = vec![usize::MAX; groups.len()];
    for &row in visible {
        let mut pending = topology.parents[row]
            .iter()
            .filter_map(|&parent| group_for_row[parent])
            .collect::<Vec<_>>();
        let mut missing = HashSet::new();
        while let Some(id) = pending.pop() {
            if visited[id] == row {
                continue;
            }
            visited[id] = row;
            missing.extend(groups[id].hashes.iter().map(String::as_str));
            pending.extend(groups[id].parents.iter().copied());
        }
        let direct = commits[row]
            .parent_hashes
            .iter()
            .map(String::as_str)
            .collect::<HashSet<_>>();
        let mut sorted = missing.into_iter().collect::<Vec<_>>();
        sorted.sort_unstable();
        for hash in sorted {
            if !direct.contains(hash) {
                found.push((row, hash.to_string()));
            }
        }
    }
    found
}

// MARK: - layout

#[derive(Clone, Copy)]
enum Element {
    Node,
    Edge(usize),
}

/// Everything the element comparator and edge colors need.
struct Layout<'a> {
    commits: &'a [CommitInput],
    visible: &'a [usize],
    indices: &'a [i64],
    colors: &'a [i32],
    edges: &'a [Edge],
}

impl Layout<'_> {
    fn layout_index(&self, visible_row: usize) -> i64 {
        self.indices[self.visible[visible_row]]
    }

    fn edge_color(&self, edge: &Edge) -> i32 {
        let up = self.visible[edge.up];
        let Some(down) = edge.down.map(|down| self.visible[down]) else {
            return self.colors[up];
        };
        self.colors[if self.indices[up] > self.indices[down] {
            up
        } else {
            down
        }]
    }

    fn compare_edge_node(&self, edge: &Edge, node: usize) -> i64 {
        let node_index = self.layout_index(node);
        let Some(down) = edge.down else {
            return self.layout_index(edge.up) - node_index;
        };
        let edge_index = self.layout_index(edge.up).max(self.layout_index(down));
        if edge_index != node_index {
            edge_index - node_index
        } else {
            edge.up as i64 - node as i64
        }
    }

    /// Direct translation of `GraphElementComparatorByLayoutIndex`. These rules
    /// also order crossing edges without keeping unrelated empty lane slots.
    fn compare(&self, row: usize, left: Element, right: Element) -> i64 {
        match (left, right) {
            (Element::Node, Element::Node) => 0,
            (Element::Edge(e), Element::Node) => self.compare_edge_node(&self.edges[e], row),
            (Element::Node, Element::Edge(e)) => -self.compare_edge_node(&self.edges[e], row),
            (Element::Edge(a), Element::Edge(b)) => {
                let (first, second) = (&self.edges[a], &self.edges[b]);
                let Some(first_down) = first.down else {
                    return -self.compare_edge_node(second, first.up);
                };
                let Some(second_down) = second.down else {
                    return self.compare_edge_node(first, second.up);
                };
                if first.up == second.up {
                    if first_down < second_down {
                        -self.compare_edge_node(second, first_down)
                    } else {
                        self.compare_edge_node(first, second_down)
                    }
                } else if first.up < second.up {
                    self.compare_edge_node(first, second.up)
                } else {
                    -self.compare_edge_node(second, first.up)
                }
            }
        }
    }
}

fn element_key(element: Element) -> i64 {
    match element {
        Element::Node => -1,
        Element::Edge(id) => id as i64,
    }
}

fn recommended_width(visible_count: usize, edges: &[Edge], options: DisplayOptions) -> usize {
    let count = RECOMMENDED_WIDTH_SAMPLE_SIZE.min(visible_count);
    if count <= 1 {
        return count;
    }
    let mut changes = vec![0i64; visible_count + 1];
    let mut missing = vec![0i64; visible_count];
    let mut add = |lower: usize, upper: usize| {
        changes[lower] += 1;
        changes[upper] -= 1;
    };
    for edge in edges {
        let Some(down) = edge.down else {
            missing[edge.up] += 1;
            continue;
        };
        if down - edge.up < options.long_edge_size {
            add(edge.up, down);
        } else {
            add(edge.up, edge.up + options.visible_part_size + 1);
            add(down - options.visible_part_size, down);
        }
    }
    let (mut current, mut previous) = (0i64, 0i64);
    let (mut sum, mut squares) = (0.0f64, 0.0f64);
    for row in 0..count {
        current += changes[row];
        let width = previous.max(current + missing[row]) as f64;
        let weight = 2.0 / (count as f64 * (RECOMMENDED_WIDTH_WEIGHT_RATIO + 1.0))
            * (1.0 + (RECOMMENDED_WIDTH_WEIGHT_RATIO - 1.0) * row as f64 / (count - 1) as f64);
        sum += width * weight;
        squares += width * width * weight;
        previous = current;
    }
    (sum + (squares - sum * sum).max(0.0).sqrt()).round() as usize
}

fn empty_projection() -> GraphProjection {
    GraphProjection {
        version: GRAPH_PROJECTION_VERSION,
        rows: Vec::new(),
        lane_count: 0,
        recommended_lane_count: 0,
        has_missing_parents: false,
        current_branch_hashes: Vec::new(),
    }
}

fn project(request: &Request, options: DisplayOptions) -> GraphProjection {
    let remote_names = request
        .remote_names
        .iter()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    let label_rows = |commits: &[CommitInput]| {
        commits
            .iter()
            .map(|commit| parse_labels(&commit.decorations, &remote_names))
            .collect::<Vec<_>>()
    };

    // IDEA builds the permanent graph before applying the branch scope.
    // Otherwise an older release ref can steal the main branch's layout when
    // main's tip is outside the selected branch's first history page. Use only
    // a complete, unique context; bounded-history misses fall back to the
    // scoped graph instead of dropping commits or mixing indices.
    let context = &request.repository_commits;
    let context_hashes = context
        .iter()
        .map(|commit| commit.hash.as_str())
        .collect::<HashSet<_>>();
    let uses_context = !context.is_empty()
        && context_hashes.len() == context.len()
        && request
            .commits
            .iter()
            .all(|commit| context_hashes.contains(commit.hash.as_str()));
    let ordered_storage;
    let (commits, permanent_context) = if uses_context {
        let scoped = request
            .commits
            .iter()
            .rev()
            .map(|commit| (commit.hash.as_str(), commit))
            .collect::<HashMap<_, _>>();
        ordered_storage = context
            .iter()
            .filter_map(|commit| scoped.get(commit.hash.as_str()).copied())
            .cloned()
            .collect::<Vec<_>>();
        let topology = Topology::new(context);
        let permanent = permanent_layout(&label_rows(context), &topology);
        let rows = context
            .iter()
            .enumerate()
            .map(|(row, commit)| (commit.hash.as_str(), row))
            .collect::<HashMap<_, _>>();
        (&ordered_storage[..], Some((permanent, rows)))
    } else {
        (&request.commits[..], None)
    };

    let mut projection = project_commits(
        request,
        commits,
        &label_rows(commits),
        permanent_context,
        options,
    );
    if let Some(branch) = &request.current_branch {
        projection.current_branch_hashes = current_branch_hashes(request, branch);
    }
    projection
}

fn project_commits(
    request: &Request,
    commits: &[CommitInput],
    labels: &[Vec<GraphLabel>],
    context: Option<(Permanent, HashMap<&str, usize>)>,
    options: DisplayOptions,
) -> GraphProjection {
    let topology = Topology::new(commits);
    let (indices, colors) = match context {
        Some((permanent, rows)) => (
            commits
                .iter()
                .map(|commit| permanent.indices[rows[commit.hash.as_str()]])
                .collect::<Vec<_>>(),
            commits
                .iter()
                .map(|commit| permanent.colors[rows[commit.hash.as_str()]])
                .collect::<Vec<_>>(),
        ),
        None => {
            let permanent = permanent_layout(labels, &topology);
            (permanent.indices, permanent.colors)
        }
    };
    let filter = request
        .visible_hashes
        .as_ref()
        .map(|hashes| hashes.iter().map(String::as_str).collect::<HashSet<_>>());
    let visible = (0..commits.len())
        .filter(|&row| {
            topology.by_hash.get(commits[row].hash.as_str()) == Some(&row)
                && filter
                    .as_ref()
                    .is_none_or(|hashes| hashes.contains(commits[row].hash.as_str()))
        })
        .collect::<Vec<_>>();
    if visible.is_empty() {
        return empty_projection();
    }
    let mut visible_rows = vec![None; commits.len()];
    let mut visible_flags = vec![false; commits.len()];
    for (index, &row) in visible.iter().enumerate() {
        visible_rows[row] = Some(index);
        visible_flags[row] = true;
    }

    let mut builder = EdgeBuilder {
        commits,
        visible_rows: &visible_rows,
        edges: Vec::new(),
        pairs: HashSet::new(),
    };
    for &row in &visible {
        for &parent in &topology.parents[row] {
            if visible_rows[parent].is_some() {
                builder.add(row, parent, false);
            }
        }
        let mut seen = HashSet::new();
        for hash in &commits[row].parent_hashes {
            if !topology.by_hash.contains_key(hash.as_str()) && seen.insert(hash.as_str()) {
                builder.edges.push(Edge {
                    up: visible_rows[row].expect("visible rows are indexed"),
                    down: None,
                    parent_hash: hash.clone(),
                    dotted: false,
                });
            }
        }
    }
    if filter.is_some() {
        dotted_edges(&topology, &visible_flags, &mut builder);
        for (row, hash) in missing_parents(commits, &topology, &visible, &visible_flags) {
            builder.edges.push(Edge {
                up: visible_rows[row].expect("visible rows are indexed"),
                down: None,
                parent_hash: hash,
                dotted: true,
            });
        }
    }
    let mut edges = builder.edges;
    edges.sort_by(|left, right| {
        left.up
            .cmp(&right.up)
            .then_with(|| {
                left.down
                    .unwrap_or(usize::MAX)
                    .cmp(&right.down.unwrap_or(usize::MAX))
            })
            .then_with(|| left.parent_hash.cmp(&right.parent_hash))
    });

    let layout = Layout {
        commits,
        visible: &visible,
        indices: &indices,
        colors: &colors,
        edges: &edges,
    };
    build_rows(&layout, labels, options)
}

fn build_rows(
    layout: &Layout,
    labels: &[Vec<GraphLabel>],
    options: DisplayOptions,
) -> GraphProjection {
    let edges = layout.edges;
    let row_count = layout.visible.len();
    let edge_ids = edges.iter().map(Edge::id).collect::<Vec<_>>();
    let mut elements = vec![vec![Element::Node]; row_count];
    let mut adjacent = vec![Vec::<usize>::new(); row_count];
    for (id, edge) in edges.iter().enumerate() {
        adjacent[edge.up].push(id);
        if let Some(down) = edge.down {
            adjacent[down].push(id);
            if down <= edge.up + 1 {
                continue;
            }
            let crossed = if down - edge.up < options.long_edge_size {
                [(edge.up + 1)..down, 0..0]
            } else {
                [
                    (edge.up + 1)..(edge.up + options.visible_part_size + 1),
                    (down - options.visible_part_size)..down,
                ]
            };
            for range in crossed {
                for crossing in &mut elements[range] {
                    crossing.push(Element::Edge(id));
                }
            }
        } else if edge.up + 1 < row_count {
            elements[edge.up + 1].push(Element::Edge(id));
        }
    }

    let mut positions = vec![HashMap::<usize, usize>::new(); row_count];
    let mut node_positions = vec![0usize; row_count];
    for row in 0..row_count {
        stable_sort(&mut elements[row], |left, right| {
            let order = layout.compare(row, left, right);
            if order == 0 {
                element_key(left) < element_key(right)
            } else {
                order < 0
            }
        });
        for (position, element) in elements[row].iter().enumerate() {
            match element {
                Element::Node => {
                    node_positions[row] = position;
                    for &edge in &adjacent[row] {
                        positions[row].insert(edge, position);
                    }
                }
                Element::Edge(edge) => {
                    positions[row].insert(*edge, position);
                }
            }
        }
    }

    let mut rows = Vec::with_capacity(row_count);
    for row in 0..row_count {
        let mut prints = Vec::new();
        for (position, element) in elements[row].iter().enumerate() {
            let own = [match element {
                Element::Edge(id) => *id,
                Element::Node => usize::MAX,
            }];
            let ids: &[usize] = match element {
                Element::Edge(_) => &own,
                Element::Node => &adjacent[row],
            };
            for &id in ids {
                let edge = &edges[id];
                for direction in [PrintDirection::Up, PrintDirection::Down] {
                    let next = match direction {
                        PrintDirection::Up => row.checked_sub(1),
                        PrintDirection::Down => Some(row + 1),
                    };
                    let next_position = next
                        .and_then(|next| positions.get(next))
                        .and_then(|map| map.get(&id).copied());
                    let has_arrow = match edge.down {
                        Some(down) => {
                            let span = down - edge.up;
                            let offset = if direction == PrintDirection::Down {
                                row.wrapping_sub(edge.up)
                            } else {
                                down.wrapping_sub(row)
                            };
                            (span >= options.long_edge_size && offset == options.visible_part_size)
                                || (span >= options.edge_with_arrow_size && offset == 1)
                        }
                        // IDEA places unloaded-parent arrows on the next row,
                        // never stacked on the last visible node.
                        None => direction == PrintDirection::Down && row == edge.up + 1,
                    };
                    if next_position.is_none() && !has_arrow {
                        continue;
                    }
                    prints.push(GraphPrintElement {
                        id: format!(
                            "{}:{}",
                            edge_ids[id],
                            if direction == PrintDirection::Down {
                                "down"
                            } else {
                                "up"
                            }
                        ),
                        position,
                        adjacent_position: next_position.unwrap_or(position),
                        direction,
                        color_id: layout.edge_color(edge),
                        is_dotted: edge.dotted,
                        is_missing: edge.down.is_none(),
                        has_arrow,
                        is_terminal: next_position.is_none(),
                        target_hash: edge.down.map(|down| {
                            let target = if direction == PrintDirection::Down {
                                down
                            } else {
                                edge.up
                            };
                            layout.commits[layout.visible[target]].hash.clone()
                        }),
                    });
                }
            }
        }
        let node = layout.visible[row];
        rows.push(GraphRow {
            commit_hash: layout.commits[node].hash.clone(),
            lane: node_positions[row],
            lane_count: elements[row].len(),
            color_id: layout.colors[node],
            layout_index: layout.indices[node],
            incoming_lane_colors: elements[row]
                .iter()
                .map(|element| match element {
                    Element::Edge(id) => layout.edge_color(&edges[*id]),
                    Element::Node => layout.colors[node],
                })
                .collect(),
            parent_edges: adjacent[row]
                .iter()
                .filter(|&&id| edges[id].up == row)
                .map(|&id| {
                    let edge = &edges[id];
                    GraphParentEdge {
                        id: edge_ids[id].clone(),
                        parent_hash: edge.parent_hash.clone(),
                        target_lane: positions.get(row + 1).and_then(|map| map.get(&id).copied()),
                        color_id: layout.edge_color(edge),
                        is_missing: edge.down.is_none(),
                        is_dotted: edge.dotted,
                    }
                })
                .collect(),
            labels: labels[node].clone(),
            print_elements: prints,
        });
    }
    GraphProjection {
        version: GRAPH_PROJECTION_VERSION,
        lane_count: elements.iter().map(Vec::len).max().unwrap_or(0),
        recommended_lane_count: recommended_width(row_count, edges, options),
        has_missing_parents: edges.iter().any(|edge| edge.down.is_none()),
        rows,
        current_branch_hashes: Vec::new(),
    }
}

// MARK: - current branch

/// IntelliJ's `CurrentBranchHighlighter` colors ancestry, including every merge
/// parent. Only the loaded graph can prove membership; a missing parent ends the walk.
fn current_branch_hashes(request: &Request, branch: &str) -> Vec<String> {
    let all = request
        .commits
        .iter()
        .chain(request.repository_commits.iter())
        .collect::<Vec<_>>();
    let no_remotes = HashSet::new();
    let Some(head) = all.iter().find(|commit| {
        parse_labels(&commit.decorations, &no_remotes)
            .iter()
            .any(|l| l.kind == GraphLabelKind::Branch && l.title == branch)
    }) else {
        return Vec::new();
    };
    let mut by_hash: HashMap<&str, &CommitInput> = HashMap::with_capacity(all.len());
    for commit in &all {
        by_hash.entry(commit.hash.as_str()).or_insert(commit);
    }
    let mut pending = vec![head.hash.as_str()];
    let mut reached = HashSet::new();
    while let Some(hash) = pending.pop() {
        if !reached.insert(hash) {
            continue;
        }
        if let Some(commit) = by_hash.get(hash) {
            pending.extend(commit.parent_hashes.iter().map(String::as_str));
        }
    }
    let mut hashes = reached.into_iter().map(str::to_string).collect::<Vec<_>>();
    hashes.sort();
    hashes
}

#[cfg(test)]
#[path = "graph_tests.rs"]
mod tests;
