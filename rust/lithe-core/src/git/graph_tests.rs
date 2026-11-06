//! Regressions for `git.graphProjection`: the shared fixture, pinned IntelliJ oracles,
//! and deterministic scale checks.

use super::*;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

const COMPACT: DisplayOptions = DisplayOptions {
    long_edge_size: 30,
    visible_part_size: 1,
    edge_with_arrow_size: usize::MAX,
};
const EXPANDED: DisplayOptions = DisplayOptions {
    long_edge_size: 1_000,
    visible_part_size: 250,
    edge_with_arrow_size: 30,
};

fn commit(hash: &str, parents: &[&str], decorations: &str) -> CommitInput {
    CommitInput {
        hash: hash.to_string(),
        parent_hashes: parents.iter().map(|parent| (*parent).to_string()).collect(),
        decorations: decorations.to_string(),
    }
}

fn new_request(commits: Vec<CommitInput>) -> Request {
    Request {
        commits,
        remote_names: Vec::new(),
        repository_commits: Vec::new(),
        visible_hashes: None,
        display_mode: DisplayMode::Compact,
        current_branch: None,
    }
}

fn layout(commits: Vec<CommitInput>) -> GraphProjection {
    project(&new_request(commits), COMPACT)
}

fn filtered(commits: Vec<CommitInput>, visible: &[&str]) -> GraphProjection {
    let mut request = new_request(commits);
    request.visible_hashes = Some(visible.iter().map(|hash| (*hash).to_string()).collect());
    project(&request, COMPACT)
}

fn call(payload: Value) -> Value {
    serde_json::from_str(&crate::execute_json(
        &json!({"id":"graph", "command":"git.graphProjection", "payload":payload}).to_string(),
    ))
    .unwrap()
}

fn root_path(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}

fn read_fixture(relative: &str) -> String {
    fs::read_to_string(root_path(relative)).unwrap_or_else(|error| panic!("{relative}: {error}"))
}

fn shared_fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/graph-projection-v1.json"
    ))
    .unwrap()
}

/// Every non-terminal half-edge must meet the matching half in the neighbouring row
/// with its identity, positions, color, and style intact.
fn assert_continuity(projection: &GraphProjection) {
    for (row, value) in projection.rows.iter().enumerate() {
        for element in value.print_elements.iter().filter(|e| !e.is_terminal) {
            let next = if element.direction == PrintDirection::Down {
                row + 1
            } else {
                row.wrapping_sub(1)
            };
            let other = projection
                .rows
                .get(next)
                .unwrap_or_else(|| panic!("row {row}: continuing edge needs row {next}"));
            let edge = element.id.rsplit_once(':').unwrap().0;
            assert!(
                other.print_elements.iter().any(|candidate| {
                    candidate.id.rsplit_once(':').unwrap().0 == edge
                        && candidate.direction != element.direction
                        && !candidate.is_terminal
                        && candidate.position == element.adjacent_position
                        && candidate.adjacent_position == element.position
                        && candidate.color_id == element.color_id
                        && candidate.is_dotted == element.is_dotted
                }),
                "row {row}: {} has no matching half in row {next}",
                element.id
            );
        }
    }
}

fn hashes(projection: &GraphProjection) -> Vec<&str> {
    projection
        .rows
        .iter()
        .map(|row| row.commit_hash.as_str())
        .collect()
}

fn parent_hashes(row: &GraphRow) -> Vec<&str> {
    row.parent_edges
        .iter()
        .map(|edge| edge.parent_hash.as_str())
        .collect()
}

// MARK: - shared fixture

#[test]
fn shared_fixture_projects_the_exact_response() {
    let fixture = shared_fixture();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 20, "the fixture must keep its scenarios");
    for case in cases {
        let response = call(case["request"].clone());
        assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
        assert_eq!(response["data"], case["response"], "{}", case["name"]);
    }
}

#[test]
fn shared_fixture_keeps_a_named_branch_color_across_pages() {
    let fixture = shared_fixture();
    let cases = fixture["cases"].as_array().unwrap();
    for sequence in fixture["stability"].as_array().unwrap() {
        let expected = &sequence["expectedColorId"];
        assert!(!expected.is_null());
        for step in sequence["steps"].as_array().unwrap() {
            let case = cases
                .iter()
                .find(|case| case["name"] == step["case"])
                .unwrap();
            let response = call(case["request"].clone());
            let row = response["data"]["rows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["commitHash"] == step["hash"])
                .unwrap();
            assert_eq!(
                &row["colorId"], expected,
                "{} / {}",
                sequence["name"], step["case"]
            );
        }
    }
}

#[test]
fn shared_fixture_rejects_invalid_requests() {
    for case in shared_fixture()["invalid"].as_array().unwrap() {
        let response = call(case["request"].clone());
        assert_eq!(response["ok"], false, "{}", case["name"]);
        assert_eq!(
            response["error"]["code"], "invalid_request",
            "{}",
            case["name"]
        );
    }
    let too_many = (0..=MAX_COMMITS)
        .map(|row| json!({"hash": row.to_string()}))
        .collect::<Vec<_>>();
    assert_eq!(call(json!({"commits": too_many}))["ok"], false);
}

// MARK: - IntelliJ oracles

fn split_graph_line(line: &str) -> (String, Vec<String>) {
    let (hash, parents) = line.split_once("|-").unwrap();
    (
        hash.to_string(),
        parents.split_whitespace().map(str::to_string).collect(),
    )
}

#[test]
fn permanent_layout_matches_pinned_intellij_indices() {
    for name in [
        "manyNodes",
        "oneNode",
        "notFullGraph",
        "oneNodeNotFullGraph",
    ] {
        let read = |suffix: &str| {
            read_fixture(&format!(
                "shared/fixtures/git/graph-idea/layoutBuilder/{name}_{suffix}.txt"
            ))
        };
        let commits = read("in")
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| {
                let (hash, parents) = split_graph_line(line);
                CommitInput {
                    hash,
                    parent_hashes: parents,
                    decorations: String::new(),
                }
            })
            .collect::<Vec<_>>();
        let expected = read("out")
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| line.split("|-").next().unwrap().parse::<i64>().unwrap())
            .collect::<Vec<_>>();
        let actual = layout(commits)
            .rows
            .iter()
            .map(|row| row.layout_index)
            .collect::<Vec<_>>();
        assert_eq!(actual, expected, "{name}");
    }
}

#[test]
fn compact_positions_and_half_edges_match_pinned_intellij_printing() {
    for name in [
        "oneNode",
        "manyNodes",
        "longEdges",
        "oneUpOneDown1",
        "oneUpOneDown2",
    ] {
        let read = |suffix: &str| {
            read_fixture(&format!(
                "shared/fixtures/git/graph-idea/elementGenerator/{name}_{suffix}.txt"
            ))
        };
        let mut commits = Vec::new();
        let mut visible = Vec::new();
        for line in read("in").lines().filter(|line| !line.is_empty()) {
            let (head, rest) = line.split_once("|-").unwrap();
            let id = head.split('_').next().unwrap().to_string();
            visible.push(id.clone());
            let mut hidden = Vec::new();
            let parents = rest
                .split_whitespace()
                .map(|token| {
                    let mut fields = token.split('_');
                    let target = fields.next().unwrap().to_string();
                    // Git commits only carry direct edges. A hidden intermediate
                    // commit recreates the upstream fixture's DOTTED edge naturally.
                    if fields.next() == Some("D") {
                        let hash = format!("hidden-{id}-{target}");
                        hidden.push(commit(&hash, &[target.as_str()], ""));
                        hash
                    } else {
                        target
                    }
                })
                .collect::<Vec<_>>();
            commits.push(CommitInput {
                hash: id,
                parent_hashes: parents,
                decorations: String::new(),
            });
            commits.extend(hidden);
        }
        let options = DisplayOptions {
            long_edge_size: if name == "oneUpOneDown2" { 10 } else { 7 },
            visible_part_size: if name.starts_with("oneUpOneDown") {
                1
            } else {
                2
            },
            edge_with_arrow_size: 10,
        };
        let mut request = new_request(commits);
        request.visible_hashes = Some(visible);
        let projection = project(&request, options);
        // The color callback in JetBrains's fixture uses row numbers. Compare its
        // verbatim geometry, style, and arrow oracle, excluding color.
        let mut expected = read("out")
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let mut parts = line.trim().split("|-");
                format!("{}|{}", parts.next().unwrap(), parts.next().unwrap())
            })
            .collect::<Vec<_>>();
        let mut actual = Vec::new();
        for (row, value) in projection.rows.iter().enumerate() {
            actual.push(format!("Node|{row}:{}", value.lane));
            for element in &value.print_elements {
                let direction = if element.direction == PrintDirection::Down {
                    "DOWN"
                } else {
                    "UP"
                };
                actual.push(format!(
                    "Edge:{direction}{}:{}|{row}:{}:{}",
                    if element.has_arrow { "_ARROW" } else { "" },
                    if element.is_dotted { "DASHED" } else { "SOLID" },
                    element.position,
                    element.adjacent_position
                ));
            }
        }
        expected.sort();
        actual.sort();
        assert_eq!(actual, expected, "{name}");
        assert_continuity(&projection);
    }
}

fn read_tsv(name: &str) -> Vec<CommitInput> {
    read_fixture(&format!(
        "macos/Tests/LitheTests/Fixtures/GitGraph/{name}.tsv"
    ))
    .lines()
    .filter(|line| !line.is_empty())
    .map(|line| {
        let columns = line.split('\t').collect::<Vec<_>>();
        assert_eq!(columns.len(), 4, "{line}");
        CommitInput {
            hash: columns[0].to_string(),
            parent_hashes: columns[1].split_whitespace().map(str::to_string).collect(),
            decorations: columns[2]
                .trim_matches(|c| c == ' ' || c == '(' || c == ')')
                .to_string(),
        }
    })
    .collect()
}

#[test]
fn real_history_matches_intellij_for_page_context_and_date_order() {
    for (history, context, oracle) in [
        ("issue410-history", None, "issue410-idea"),
        (
            "issue410-history",
            Some("issue410-context"),
            "issue410-context-idea",
        ),
        (
            "issue410-date-history",
            Some("issue410-date-context"),
            "issue410-date-idea",
        ),
    ] {
        let mut request = new_request(read_tsv(history));
        if let Some(context) = context {
            request.repository_commits = read_tsv(context);
        }
        let projection = project(&request, COMPACT);
        let mut actual = vec![format!("Width|{}", projection.recommended_lane_count)];
        for (row, value) in projection.rows.iter().enumerate() {
            actual.push(format!(
                "Node|{row}:{}:{}:{}",
                value.lane, value.layout_index, value.color_id
            ));
            for element in &value.print_elements {
                actual.push(format!(
                    "Edge|{row}:{}:{}:{}:{}:{}:{}:{}",
                    element.position,
                    element.adjacent_position,
                    if element.direction == PrintDirection::Up {
                        "UP"
                    } else {
                        "DOWN"
                    },
                    element.has_arrow,
                    element.is_terminal,
                    if element.is_dotted { "DASHED" } else { "SOLID" },
                    element.color_id
                ));
            }
        }
        let mut expected = read_fixture(&format!(
            "macos/Tests/LitheTests/Fixtures/GitGraph/{oracle}.txt"
        ))
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
        actual.sort();
        expected.sort();
        let missing = expected
            .iter()
            .filter(|line| !actual.contains(line))
            .take(5)
            .collect::<Vec<_>>();
        assert!(
            actual == expected,
            "{oracle}: {} lines vs {} expected, first missing {missing:?}",
            actual.len(),
            expected.len()
        );
    }
}

// MARK: - topology and routing

#[test]
fn long_edges_compact_at_thirty_rows_and_keep_both_destinations() {
    let chain = |span: usize| {
        (0..=span)
            .map(|row| {
                let parents = if row == span {
                    Vec::new()
                } else if row == 0 {
                    vec!["1".to_string(), span.to_string()]
                } else {
                    vec![(row + 1).to_string()]
                };
                CommitInput {
                    hash: row.to_string(),
                    parent_hashes: parents,
                    decorations: String::new(),
                }
            })
            .collect::<Vec<_>>()
    };
    for span in [29usize, 30, 31] {
        let projection = layout(chain(span));
        let arrows = projection
            .rows
            .iter()
            .flat_map(|row| &row.print_elements)
            .filter(|element| element.has_arrow)
            .collect::<Vec<_>>();
        assert_eq!(projection.rows.len(), span + 1);
        if span < 30 {
            assert!(arrows.is_empty(), "span {span}");
        } else {
            assert_eq!(arrows.len(), 2, "span {span}");
            let targets = arrows
                .iter()
                .filter_map(|element| element.target_hash.clone())
                .collect::<BTreeSet<_>>();
            assert_eq!(
                targets,
                BTreeSet::from(["0".to_string(), span.to_string()]),
                "span {span}"
            );
            assert_eq!(projection.rows[span / 2].lane_count, 1, "span {span}");
        }
        assert_continuity(&projection);
    }
    for span in [999usize, 1_000] {
        let mut request = new_request(chain(span));
        request.display_mode = DisplayMode::Expanded;
        let projection = project(&request, request.display_mode.options());
        assert_eq!(
            projection.rows[span / 2].lane_count,
            if span < 1_000 { 2 } else { 1 },
            "span {span}"
        );
        let arrows = projection
            .rows
            .iter()
            .flat_map(|row| &row.print_elements)
            .filter(|element| element.has_arrow)
            .count();
        assert_eq!(arrows, if span < 1_000 { 2 } else { 4 }, "span {span}");
        assert_continuity(&projection);
    }
    let compact = layout(chain(100));
    let mut expanded_request = new_request(chain(100));
    expanded_request.display_mode = DisplayMode::Expanded;
    let expanded = project(&expanded_request, EXPANDED);
    assert_eq!(compact.recommended_lane_count, 1);
    assert_eq!(expanded.recommended_lane_count, 2);
}

#[test]
fn filtering_bridges_hidden_ancestors_without_inventing_unloaded_parents() {
    let commits = vec![
        commit("a", &["b"], ""),
        commit("b", &["c"], ""),
        commit("c", &["d"], ""),
        commit("d", &[], ""),
    ];
    let projection = filtered(commits, &["a", "d"]);
    assert_eq!(hashes(&projection), ["a", "d"]);
    assert_eq!(projection.lane_count, 1);
    assert!(!projection.has_missing_parents);
    assert!(projection
        .rows
        .iter()
        .flat_map(|row| &row.print_elements)
        .all(|element| element.is_dotted));
    assert_eq!(parent_hashes(&projection.rows[0]), ["d"]);
    assert_continuity(&projection);
}

#[test]
fn filtered_unloaded_boundary_resolves_after_paging() {
    let page = vec![
        commit("a", &["b"], ""),
        commit("b", &["c"], ""),
        commit("unrelated", &[], ""),
    ];
    let last_row = filtered(page.clone(), &["a"]);
    assert!(last_row.has_missing_parents);
    assert_eq!(parent_hashes(&last_row.rows[0]), ["c"]);
    assert!(last_row.rows[0].parent_edges.iter().all(|e| e.is_missing));
    assert!(last_row.rows[0].print_elements.is_empty());

    let both = filtered(page.clone(), &["a", "unrelated"]);
    assert!(both.has_missing_parents);
    let prints = both
        .rows
        .iter()
        .flat_map(|row| &row.print_elements)
        .collect::<Vec<_>>();
    assert!(!prints.is_empty());
    assert!(prints
        .iter()
        .all(|e| e.is_dotted && e.target_hash.is_none()));
    assert!(prints.iter().any(|e| e.has_arrow && e.is_terminal));
    assert_continuity(&both);

    let mut loaded = page;
    loaded.push(commit("c", &[], ""));
    let hidden_root = filtered(loaded.clone(), &["a", "unrelated"]);
    assert!(!hidden_root.has_missing_parents);
    assert!(hidden_root.rows[0].parent_edges.is_empty());
    let visible_root = filtered(loaded, &["a", "c"]);
    assert!(!visible_root.has_missing_parents);
    assert_eq!(parent_hashes(&visible_root.rows[0]), ["c"]);
    assert!(visible_root
        .rows
        .iter()
        .flat_map(|row| &row.print_elements)
        .all(|element| element.is_dotted));
    assert_continuity(&visible_root);
}

#[test]
fn hidden_merge_paths_deduplicate_and_stop_at_visible_ancestors() {
    let projection = filtered(
        vec![
            commit("a", &["left", "right", "missing"], ""),
            commit("peer", &["left"], ""),
            commit("left", &["missing", "missing"], ""),
            commit("right", &["missing", "other"], ""),
            commit("unrelated", &["unrelated-missing"], ""),
        ],
        &["a", "peer"],
    );
    assert!(projection.has_missing_parents);
    assert_eq!(parent_hashes(&projection.rows[0]), ["missing", "other"]);
    assert_eq!(parent_hashes(&projection.rows[1]), ["missing"]);
    let direct = projection.rows[0]
        .parent_edges
        .iter()
        .find(|edge| edge.parent_hash == "missing")
        .unwrap();
    assert!(!direct.is_dotted);
    assert!(projection.rows[0]
        .print_elements
        .iter()
        .filter(|element| element.id.starts_with(&direct.id))
        .all(|element| !element.is_dotted));

    let stopped = filtered(
        vec![
            commit("a", &["b"], ""),
            commit("b", &["c"], ""),
            commit("c", &["missing"], ""),
        ],
        &["a", "b"],
    );
    assert_eq!(parent_hashes(&stopped.rows[0]), ["b"]);
    assert!(stopped.rows[0].parent_edges.iter().all(|e| !e.is_missing));
    assert_eq!(parent_hashes(&stopped.rows[1]), ["missing"]);
    let unrelated = filtered(
        vec![commit("a", &[], ""), commit("hidden", &["missing"], "")],
        &["a"],
    );
    assert!(!unrelated.has_missing_parents);
}

#[test]
fn an_ended_branch_gives_its_column_back() {
    let projection = layout(vec![
        commit("a", &["b", "c"], ""),
        commit("b", &[], ""),
        commit("c", &["d"], ""),
        commit("d", &[], ""),
    ]);
    assert_eq!(projection.rows[1].lane_count, 2);
    assert_eq!(projection.rows[2].lane_count, 1);
    assert_eq!(projection.rows[2].lane, 0);
    assert_continuity(&projection);
}

#[test]
fn pagination_resolves_missing_parents_with_the_same_node_color() {
    let head = commit("a", &["b", "b"], "");
    let page = layout(vec![head.clone()]);
    assert!(page.has_missing_parents);
    assert_eq!(page.rows[0].parent_edges.len(), 1);
    assert!(page.rows[0].print_elements.is_empty());
    let full = layout(vec![head, commit("b", &[], "")]);
    assert!(!full.has_missing_parents);
    assert_eq!(full.rows[0].color_id, page.rows[0].color_id);
    assert_continuity(&full);
}

#[test]
fn empty_inputs_and_filters_produce_no_graph() {
    assert!(layout(Vec::new()).rows.is_empty());
    let projection = filtered(vec![commit("a", &["b"], "")], &[]);
    assert!(projection.rows.is_empty());
    assert_eq!(projection.lane_count, 0);
    assert!(!projection.has_missing_parents);
}

#[test]
fn reference_priority_seeds_main_before_feature_tips_and_inner_heads() {
    let indices = |commits: Vec<CommitInput>| {
        layout(commits)
            .rows
            .iter()
            .map(|row| row.layout_index)
            .collect::<Vec<_>>()
    };
    assert_eq!(
        indices(vec![
            commit("feature", &["main"], "HEAD -> feature"),
            commit("main", &["root"], "refs/heads/main"),
            commit("root", &[], ""),
        ]),
        [2, 1, 1]
    );
    // A tag alone does not make a decorated inner commit a head.
    assert_eq!(
        indices(vec![
            commit("tip", &["tag"], ""),
            commit("tag", &["root"], "tag: v1"),
            commit("root", &[], ""),
        ]),
        [1, 1, 1]
    );
    assert_eq!(
        indices(vec![
            commit("other", &["root"], "refs/remotes/upstream/work"),
            commit("preferred", &["root"], "origin/main"),
            commit("root", &[], ""),
        ]),
        [2, 1, 1]
    );
    let mut with_remote = new_request(vec![
        commit("local", &["root"], "main"),
        commit("remote", &["root"], "upstream/work"),
        commit("root", &[], ""),
    ]);
    with_remote.remote_names = vec!["upstream/work".to_string()];
    let projection = project(&with_remote, COMPACT);
    assert_eq!(
        projection
            .rows
            .iter()
            .map(|row| row.layout_index)
            .collect::<Vec<_>>(),
        [2, 1, 1]
    );
    assert_eq!(projection.rows[1].labels[0].kind, GraphLabelKind::Remote);
}

#[test]
fn natural_reference_names_keep_numeric_zero_and_case_tie_breaks() {
    let mut names = vec![
        "feature10",
        "feature02",
        "feature2",
        "Feature2",
        "feature1",
        "feature002",
        "feature2x",
    ];
    names.sort_by(|a, b| {
        compare_reference_names(
            &a.encode_utf16().collect::<Vec<_>>(),
            &b.encode_utf16().collect::<Vec<_>>(),
        )
    });
    assert_eq!(
        names,
        [
            "feature1",
            "Feature2",
            "feature2",
            "feature2x",
            "feature02",
            "feature002",
            "feature10"
        ]
    );
}

#[test]
fn color_ids_hash_the_principal_reference_name() {
    let id = |decorations: &str| color_id(&parse_labels(decorations, &HashSet::new()));
    assert_eq!(id("main"), 3_343_801);
    assert_eq!(id("master"), -1_081_267_614);
    assert_eq!(id("café"), 3_045_921);
    // A wrapped 32-bit product, non-BMP code units, and a name needing sign wrap.
    assert_eq!(id("feature/very-long-branch-name-for-overflow"), 71_049_904);
    assert_eq!(id("dev/日本語"), 1_583_896_733);
    assert_eq!(id("a😀"), 1_866_116);
    // The most significant reference names the fragment, whatever the source order.
    assert_eq!(id("tag: v1, release, origin/main"), id("origin/main"));
    assert_eq!(id("HEAD -> work, tag: v1"), id("work"));
    // Unreferenced heads share a deterministic zero.
    assert_eq!(id(""), 0);
}

#[test]
fn branch_scope_keeps_repository_priority_and_base_order() {
    let main = commit("main-tip", &["root"], "origin/main");
    let side = commit("side", &["root"], "HEAD -> feature");
    let root = commit("root", &[], "");
    let repository = vec![main.clone(), side.clone(), root.clone()];
    let full = layout(repository.iter().map(CommitInput::clone).collect());
    let mut scoped = new_request(vec![side.clone(), root.clone()]);
    scoped.repository_commits = repository.iter().map(CommitInput::clone).collect();
    let scoped_projection = project(&scoped, COMPACT);
    assert_eq!(
        scoped_projection
            .rows
            .iter()
            .map(|row| row.layout_index)
            .collect::<Vec<_>>(),
        [2, 1]
    );
    assert_eq!(
        scoped_projection
            .rows
            .iter()
            .map(|row| row.color_id)
            .collect::<Vec<_>>(),
        full.rows
            .iter()
            .skip(1)
            .map(|row| row.color_id)
            .collect::<Vec<_>>()
    );
    let mut reordered = new_request(vec![side, main, root]);
    reordered.repository_commits = repository;
    let projection = project(&reordered, COMPACT);
    assert_eq!(hashes(&projection), ["main-tip", "side", "root"]);
    assert_continuity(&projection);
}

#[test]
fn incomplete_or_duplicate_repository_context_falls_back_without_dropping_commits() {
    let values = || vec![commit("tip", &["root"], ""), commit("root", &[], "")];
    let expected = layout(values());
    for context in [
        vec![commit("root", &[], "")],
        vec![
            commit("tip", &["root"], ""),
            commit("tip", &["root"], ""),
            commit("root", &[], ""),
        ],
    ] {
        let mut request = new_request(values());
        request.repository_commits = context;
        assert_eq!(project(&request, COMPACT), expected);
    }
}

#[test]
fn recommended_width_follows_weighted_edge_counts() {
    let projection = layout(vec![
        commit("a", &["c"], ""),
        commit("b", &["c"], ""),
        commit("c", &[], ""),
    ]);
    assert_eq!(projection.recommended_lane_count, 2);
    assert_eq!(
        layout(vec![commit("only", &[], "")]).recommended_lane_count,
        1
    );
}

#[test]
fn current_branch_ancestry_follows_every_merge_parent_and_never_guesses() {
    let commits = || {
        vec![
            commit("head", &["left", "merged"], "HEAD -> main"),
            commit("other", &["base"], "other"),
            commit("left", &["base"], ""),
        ]
    };
    let context = || {
        vec![
            commit("merged", &["base"], ""),
            commit("base", &["missing"], ""),
        ]
    };
    let mut request = new_request(commits());
    request.repository_commits = context();
    request.current_branch = Some("main".to_string());
    assert_eq!(
        project(&request, COMPACT).current_branch_hashes,
        ["base", "head", "left", "merged", "missing"]
    );
    request.current_branch = Some("absent".to_string());
    assert!(project(&request, COMPACT).current_branch_hashes.is_empty());
    request.current_branch = None;
    assert!(project(&request, COMPACT).current_branch_hashes.is_empty());
    let mut detached = new_request(vec![commit("detached", &[], "HEAD")]);
    detached.current_branch = Some("main".to_string());
    assert!(project(&detached, COMPACT).current_branch_hashes.is_empty());
}

#[test]
fn current_branch_ancestry_is_bounded_and_prefers_the_scoped_commit() {
    // A cycle in malformed input is walked once.
    let mut cyclic = new_request(vec![commit("a", &["b"], "main"), commit("b", &["a"], "")]);
    cyclic.current_branch = Some("main".to_string());
    assert_eq!(project(&cyclic, COMPACT).current_branch_hashes, ["a", "b"]);
    // The scoped commit wins over a stale duplicate in the repository context, and
    // ancestry extends through context-only commits.
    let mut scoped = new_request(vec![commit("main", &["new"], "main")]);
    scoped.repository_commits = vec![
        commit("main", &["stale"], "main"),
        commit("new", &["root"], ""),
        commit("root", &[], ""),
    ];
    scoped.current_branch = Some("main".to_string());
    assert_eq!(
        project(&scoped, COMPACT).current_branch_hashes,
        ["main", "new", "root"]
    );
}

// MARK: - scale

#[test]
fn hidden_merge_boundaries_keep_only_the_visible_result() {
    // Each merge adds a distinct unloaded parent. Copying every suffix's full
    // set once retained ~12.5 million members for a one-row result.
    let count = 5_000;
    let history = (0..count)
        .map(|row| {
            let mut parents = vec![format!("missing-{row}")];
            if row + 1 < count {
                parents.insert(0, (row + 1).to_string());
            }
            CommitInput {
                hash: row.to_string(),
                parent_hashes: parents,
                decorations: String::new(),
            }
        })
        .collect::<Vec<_>>();
    let mut request = new_request(history);
    request.visible_hashes = Some(vec![]);
    let empty = project(&request, COMPACT);
    assert!(empty.rows.is_empty() && !empty.has_missing_parents);
    request.visible_hashes = Some(vec!["0".to_string()]);
    let projection = project(&request, COMPACT);
    assert_eq!(projection.rows.len(), 1);
    let found = parent_hashes(&projection.rows[0])
        .into_iter()
        .map(str::to_string)
        .collect::<BTreeSet<_>>();
    assert_eq!(
        found,
        (0..count).map(|row| format!("missing-{row}")).collect()
    );
    assert!(projection.rows[0].parent_edges.iter().all(|e| e.is_missing));
    assert!(projection.has_missing_parents);
}

#[test]
fn many_visible_children_share_one_hidden_chain_boundary() {
    let count = 2_500;
    let mut commits = (0..count)
        .map(|row| commit(&format!("head-{row}"), &["hidden-0"], ""))
        .collect::<Vec<_>>();
    for row in 0..count {
        let parent = if row + 1 < count {
            format!("hidden-{}", row + 1)
        } else {
            "missing".to_string()
        };
        commits.push(commit(&format!("hidden-{row}"), &[parent.as_str()], ""));
    }
    let visible = (0..count)
        .map(|row| format!("head-{row}"))
        .collect::<Vec<_>>();
    let mut request = new_request(commits);
    request.visible_hashes = Some(visible);
    let projection = project(&request, COMPACT);
    assert_eq!(projection.rows.len(), count);
    assert!(projection.has_missing_parents);
    assert!(projection
        .rows
        .iter()
        .all(|row| parent_hashes(row) == ["missing"]));
    assert_continuity(&projection);
}

/// A deterministic 5,000-commit history with merges, side branches, and named heads.
fn generated_history(count: usize) -> Vec<CommitInput> {
    let mut state = 0x2545_f491_4f6c_dd1du64;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    (0..count)
        .map(|row| {
            let mut parents = Vec::new();
            if row + 1 < count {
                parents.push((row + 1).to_string());
            }
            if row % 7 == 3 && row + 2 < count {
                let second = row + 2 + (next() % 40) as usize;
                if second < count {
                    parents.push(second.to_string());
                }
            }
            let decorations = match row {
                0 => "HEAD -> main, origin/main".to_string(),
                _ if row % 97 == 0 => format!("feature/branch-{row}"),
                _ if row % 389 == 0 => format!("tag: v{row}"),
                _ => String::new(),
            };
            CommitInput {
                hash: row.to_string(),
                parent_hashes: parents,
                decorations,
            }
        })
        .collect()
}

#[test]
fn projects_five_thousand_commits_deterministically() {
    let count = 5_000;
    let history = generated_history(count);
    let projection = layout(history.iter().map(CommitInput::clone).collect());
    assert_eq!(projection.rows.len(), count);
    assert!(!projection.has_missing_parents);
    assert!(projection.lane_count >= 2);
    assert_eq!(projection.rows[0].layout_index, 1);
    assert_eq!(
        projection.rows[0].color_id,
        color_id(&parse_labels("origin/main", &HashSet::new()))
    );
    for (row, value) in projection.rows.iter().enumerate() {
        assert_eq!(value.commit_hash, row.to_string());
        assert!(value.lane < value.lane_count && value.lane_count <= projection.lane_count);
        let distinct = history[row]
            .parent_hashes
            .iter()
            .collect::<BTreeSet<_>>()
            .len();
        assert_eq!(value.parent_edges.len(), distinct, "row {row}");
        assert!(value
            .parent_edges
            .iter()
            .all(|e| e.target_lane.is_some() == (row + 1 < count)));
    }
    assert_continuity(&projection);
    // The same window always projects to the same lanes and colors.
    let again = layout(history);
    assert_eq!(projection, again);
    // The filtered projection over the same window stays internally consistent.
    let mut filtered_request = new_request(generated_history(count));
    filtered_request.visible_hashes = Some(
        (0..count)
            .filter(|row| row % 5 == 0)
            .map(|row| row.to_string())
            .collect(),
    );
    let sparse = project(&filtered_request, COMPACT);
    assert_eq!(sparse.rows.len(), count / 5);
    assert_continuity(&sparse);
}
