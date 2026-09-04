//! Deterministic, coordinate-free Git graph projection and routing.
//!
//! This module owns the shared intermediate representation used before either
//! native product turns graph lanes into pixels. It deliberately emits integer
//! lane coordinates and typed routes rather than renderer-specific paths.

use crate::protocol::GitCommitResponse;
use serde::Serialize;
use std::collections::{BTreeSet, HashMap, HashSet};

const GRAPH_PROJECTION_VERSION: u32 = 1;

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

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One renderer-independent label attached to a projected commit.
pub struct GraphLabel {
    /// Stable label identity within the projection.
    pub id: String,
    /// Text supplied by Git after removing transport prefixes.
    pub title: String,
    /// Reference category used by hosts for styling.
    pub kind: GraphLabelKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// A live vertical lane segment crossing one graph-row boundary.
pub struct GraphLaneSegment {
    /// Stable horizontal grid column.
    pub lane: usize,
    /// Palette slot assigned when the lane first became live.
    pub color_index: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// The topological meaning of a route leaving a commit node.
pub enum GraphRouteKind {
    /// The first parent continues the mainline from this node.
    FirstParent,
    /// A later parent opens or converges a side lane.
    MergeParent,
    /// The parent lies outside the projected history window.
    MissingParent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// An integer-grid route from one commit node to one parent target.
pub struct GraphRoute {
    /// Deterministic identity derived from child hash, parent order, and parent hash.
    pub id: String,
    /// Parent commit hash supplied by Git.
    pub parent_id: String,
    /// Lane containing the source commit node.
    pub source_lane: usize,
    /// Parent lane, or `None` when history was truncated before the parent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_lane: Option<usize>,
    /// Palette slot shared by all connected parts of this route.
    pub color_index: usize,
    /// Topological route meaning; hosts must not infer it from geometry.
    pub kind: GraphRouteKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One projected commit and only the routes crossing its lower boundary.
pub struct GraphProjectionRow {
    /// Zero-based position in the supplied newest-first history order.
    pub row_index: usize,
    /// Full commit hash used as a stable row identity.
    pub commit_id: String,
    /// Lane containing the commit node.
    pub node_lane: usize,
    /// Sparse live lanes entering this row, ordered by lane index.
    pub incoming_segments: Vec<GraphLaneSegment>,
    /// Parent routes leaving this row in Git parent order.
    pub routes: Vec<GraphRoute>,
    /// Typed decoration labels in deterministic source order.
    pub labels: Vec<GraphLabel>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Versioned renderer-neutral graph projection for one bounded history window.
pub struct GraphProjection {
    /// Wire-format version for future host migrations.
    pub version: u32,
    /// Rows in the exact order of the supplied Git history page.
    pub rows: Vec<GraphProjectionRow>,
    /// Largest live lane width observed by any row.
    pub lane_count: usize,
    /// Number of palette slots allocated while routing this page.
    pub color_count: usize,
    /// Whether one or more parent routes terminate outside the history page.
    pub has_missing_parents: bool,
}

#[derive(Debug, Clone)]
struct Lane {
    hash: String,
    color_index: usize,
}

/// Projects a newest-first, topologically ordered Git history into stable lanes.
///
/// The result has no view, pixel, curve, or platform dependency. Live lanes use
/// fixed slots until they end, which preserves continuity across incremental UI
/// rendering and prevents a merge from renumbering unrelated branches.
pub fn project_graph(commits: &[GitCommitResponse]) -> GraphProjection {
    let known_hashes = commits
        .iter()
        .map(|commit| commit.hash.as_str())
        .collect::<HashSet<_>>();
    let mut slots: Vec<Option<Lane>> = Vec::new();
    let mut lanes_by_hash: HashMap<&str, usize> = HashMap::new();
    let mut free_slots = BTreeSet::new();
    let mut next_color_index = 0;
    let mut lane_count = 0;
    let mut has_missing_parents = false;
    let mut rows = Vec::with_capacity(commits.len());

    for (row_index, commit) in commits.iter().enumerate() {
        let node_lane = if let Some(&lane) = lanes_by_hash.get(commit.hash.as_str()) {
            lane
        } else {
            let lane = claim_slot(&mut slots, &mut free_slots);
            slots[lane] = Some(Lane {
                hash: commit.hash.clone(),
                color_index: next_color_index,
            });
            lanes_by_hash.insert(commit.hash.as_str(), lane);
            next_color_index += 1;
            lane
        };

        let incoming_segments = slots
            .iter()
            .enumerate()
            .filter_map(|(lane, entry)| {
                entry.as_ref().map(|entry| GraphLaneSegment {
                    lane,
                    color_index: entry.color_index,
                })
            })
            .collect::<Vec<_>>();
        let current_color_index = slots[node_lane]
            .as_ref()
            .map(|lane| lane.color_index)
            .expect("the current commit always owns its lane");

        release_slot(node_lane, &mut slots, &mut lanes_by_hash, &mut free_slots);

        let mut routes = Vec::with_capacity(commit.parent_hashes.len());
        for (parent_index, parent_hash) in commit.parent_hashes.iter().enumerate() {
            let kind = if parent_index == 0 {
                GraphRouteKind::FirstParent
            } else {
                GraphRouteKind::MergeParent
            };

            if !known_hashes.contains(parent_hash.as_str()) {
                has_missing_parents = true;
                let color_index = if parent_index == 0 {
                    current_color_index
                } else {
                    let color = next_color_index;
                    next_color_index += 1;
                    color
                };
                routes.push(GraphRoute {
                    id: route_id(&commit.hash, parent_index, parent_hash),
                    parent_id: parent_hash.clone(),
                    source_lane: node_lane,
                    target_lane: None,
                    color_index,
                    kind: GraphRouteKind::MissingParent,
                });
                continue;
            }

            let (target_lane, color_index) =
                if let Some(&lane) = lanes_by_hash.get(parent_hash.as_str()) {
                    let color = slots[lane]
                        .as_ref()
                        .map(|entry| entry.color_index)
                        .expect("a tracked lane must remain allocated");
                    (lane, color)
                } else if parent_index == 0 {
                    occupy_slot(
                        node_lane,
                        parent_hash,
                        current_color_index,
                        &mut slots,
                        &mut lanes_by_hash,
                        &mut free_slots,
                    );
                    (node_lane, current_color_index)
                } else {
                    let lane = claim_slot(&mut slots, &mut free_slots);
                    let color = next_color_index;
                    next_color_index += 1;
                    occupy_slot(
                        lane,
                        parent_hash,
                        color,
                        &mut slots,
                        &mut lanes_by_hash,
                        &mut free_slots,
                    );
                    (lane, color)
                };

            routes.push(GraphRoute {
                id: route_id(&commit.hash, parent_index, parent_hash),
                parent_id: parent_hash.clone(),
                source_lane: node_lane,
                target_lane: Some(target_lane),
                color_index,
                kind,
            });
        }

        trim_empty_tail(&mut slots, &mut free_slots);
        lane_count = lane_count.max(
            slots.len().max(
                incoming_segments
                    .last()
                    .map(|segment| segment.lane + 1)
                    .unwrap_or(0),
            ),
        );
        rows.push(GraphProjectionRow {
            row_index,
            commit_id: commit.hash.clone(),
            node_lane,
            incoming_segments,
            routes,
            labels: labels(&commit.decorations),
        });
    }

    GraphProjection {
        version: GRAPH_PROJECTION_VERSION,
        rows,
        lane_count,
        color_count: next_color_index,
        has_missing_parents,
    }
}

fn claim_slot(slots: &mut Vec<Option<Lane>>, free_slots: &mut BTreeSet<usize>) -> usize {
    if let Some(&lane) = free_slots.first() {
        free_slots.remove(&lane);
        lane
    } else {
        slots.push(None);
        slots.len() - 1
    }
}

fn occupy_slot<'a>(
    lane: usize,
    hash: &'a str,
    color_index: usize,
    slots: &mut [Option<Lane>],
    lanes_by_hash: &mut HashMap<&'a str, usize>,
    free_slots: &mut BTreeSet<usize>,
) {
    free_slots.remove(&lane);
    slots[lane] = Some(Lane {
        hash: hash.to_string(),
        color_index,
    });
    lanes_by_hash.insert(hash, lane);
}

fn release_slot<'a>(
    lane: usize,
    slots: &mut [Option<Lane>],
    lanes_by_hash: &mut HashMap<&'a str, usize>,
    free_slots: &mut BTreeSet<usize>,
) {
    let previous = slots[lane]
        .take()
        .expect("only occupied lanes can be released");
    lanes_by_hash.remove(previous.hash.as_str());
    free_slots.insert(lane);
}

fn trim_empty_tail(slots: &mut Vec<Option<Lane>>, free_slots: &mut BTreeSet<usize>) {
    while slots.last().is_some_and(Option::is_none) {
        let lane = slots.len() - 1;
        slots.pop();
        free_slots.remove(&lane);
    }
}

fn route_id(commit_hash: &str, parent_index: usize, parent_hash: &str) -> String {
    format!("{commit_hash}:{parent_index}:{parent_hash}")
}

fn labels(decorations: &str) -> Vec<GraphLabel> {
    decorations
        .split(',')
        .filter_map(|value| {
            let value = value.trim();
            (!value.is_empty()).then_some(value)
        })
        .flat_map(|value| {
            if value == "HEAD" {
                return vec![label("HEAD", GraphLabelKind::Head)];
            }
            if let Some(branch) = value.strip_prefix("HEAD -> ") {
                return vec![
                    label("HEAD", GraphLabelKind::Head),
                    label(branch, GraphLabelKind::Branch),
                ];
            }
            if let Some(tag) = value.strip_prefix("tag: ") {
                return vec![label(tag, GraphLabelKind::Tag)];
            }
            if let Some(tag) = value.strip_prefix("refs/tags/") {
                return vec![label(tag, GraphLabelKind::Tag)];
            }
            if let Some(remote) = value.strip_prefix("refs/remotes/") {
                return vec![label(remote, GraphLabelKind::Remote)];
            }
            if value.starts_with("origin/") {
                return vec![label(value, GraphLabelKind::Remote)];
            }
            vec![label(value, GraphLabelKind::Branch)]
        })
        .collect()
}

fn label(title: &str, kind: GraphLabelKind) -> GraphLabel {
    GraphLabel {
        id: format!("{:?}:{title}", kind).to_lowercase(),
        title: title.to_string(),
        kind,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commit(hash: &str, parents: &[&str], decorations: &str) -> GitCommitResponse {
        GitCommitResponse {
            hash: hash.to_string(),
            short_hash: hash.to_string(),
            parent_hashes: parents.iter().map(|parent| (*parent).to_string()).collect(),
            author_name: "Lithe Test".to_string(),
            author_email: "test@example.com".to_string(),
            date: "2026-09-04".to_string(),
            subject: hash.to_string(),
            decorations: decorations.to_string(),
        }
    }

    #[test]
    fn projects_a_linear_history_in_one_continuous_lane() {
        let projection = project_graph(&[
            commit("C", &["B"], "HEAD -> main"),
            commit("B", &["A"], ""),
            commit("A", &[], ""),
        ]);

        assert_eq!(projection.version, 1);
        assert_eq!(projection.lane_count, 1);
        assert_eq!(
            projection
                .rows
                .iter()
                .map(|row| row.node_lane)
                .collect::<Vec<_>>(),
            [0, 0, 0]
        );
        assert_eq!(projection.rows[0].routes[0].target_lane, Some(0));
        assert_eq!(projection.rows[0].labels[1].kind, GraphLabelKind::Branch);
    }

    #[test]
    fn routes_merge_parents_without_renumbering_live_lanes() {
        let projection = project_graph(&[
            commit("M", &["D", "C"], ""),
            commit("D", &["B"], ""),
            commit("C", &["B"], ""),
            commit("B", &[], ""),
        ]);

        assert_eq!(projection.lane_count, 2);
        assert_eq!(
            projection.rows[0]
                .routes
                .iter()
                .map(|route| route.target_lane)
                .collect::<Vec<_>>(),
            [Some(0), Some(1)]
        );
        assert_eq!(projection.rows[1].node_lane, 0);
        assert_eq!(projection.rows[2].node_lane, 1);
        assert_eq!(projection.rows[2].routes[0].target_lane, Some(0));
        assert_eq!(
            projection.rows[2].routes[0].kind,
            GraphRouteKind::FirstParent
        );
    }

    #[test]
    fn marks_truncated_parents_as_terminal_routes() {
        let projection = project_graph(&[commit("HEAD", &["OLDER"], "")]);

        assert!(projection.has_missing_parents);
        assert_eq!(projection.rows[0].routes[0].target_lane, None);
        assert_eq!(
            projection.rows[0].routes[0].kind,
            GraphRouteKind::MissingParent
        );
    }

    #[test]
    fn projection_is_deterministic_for_identical_input() {
        let commits = vec![
            commit("M", &["D", "C"], "HEAD -> main, origin/main, tag: v1"),
            commit("D", &["B"], ""),
            commit("C", &["B"], ""),
            commit("B", &[], ""),
        ];

        assert_eq!(project_graph(&commits), project_graph(&commits));
    }

    #[test]
    fn serializes_the_versioned_renderer_neutral_contract() {
        let projection = project_graph(&[commit("C", &["P"], "HEAD -> main")]);
        let value = serde_json::to_value(projection).expect("projection should serialize");

        assert_eq!(value["version"], 1);
        assert_eq!(value["rows"][0]["nodeLane"], 0);
        assert_eq!(value["rows"][0]["routes"][0]["sourceLane"], 0);
        assert!(value["rows"][0]["routes"][0].get("targetLane").is_none());
        assert_eq!(value["rows"][0]["routes"][0]["kind"], "missingParent");
    }
}
