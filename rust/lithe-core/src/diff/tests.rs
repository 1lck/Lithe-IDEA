use super::{
    compare_texts, compare_texts_command, line_similarity, pair_lines, CompareTextsRequest,
    MAX_ALIGNMENT_CELLS, MAX_TEXT_BYTES,
};
use crate::protocol::ErrorCode;
use serde_json::{json, Value};

fn fixture() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/diff/compare-texts-v1.json"
    )))
    .expect("compare-texts fixture should parse")
}

#[test]
fn compare_texts_matches_shared_fixture() {
    // Both hosts render these exact rows; any drift changes what Local History
    // and agent diffs show on macOS and Windows at once.
    for case in fixture()["cases"].as_array().expect("cases") {
        let response = compare_texts_command(json!({
            "oldText": case["oldText"],
            "newText": case["newText"],
        }))
        .expect("fixture comparison should succeed");
        assert_eq!(response, case["expected"], "{}", case["name"]);
    }
}

#[test]
fn oversized_text_is_rejected_before_diffing() {
    let error = compare_texts(&CompareTextsRequest {
        old_text: "x".repeat(MAX_TEXT_BYTES + 1),
        new_text: String::new(),
    })
    .expect_err("oversized input should fail");
    assert!(matches!(error.code, ErrorCode::InvalidRequest));
}

#[test]
fn unknown_request_fields_are_rejected() {
    let error = compare_texts_command(json!({"oldText": "", "newText": "", "mode": "words"}))
        .expect_err("unknown fields are a contract violation");
    assert!(matches!(error.code, ErrorCode::InvalidRequest));
}

#[test]
fn similar_lines_pair_even_when_positions_differ() {
    let removed = ["let total = compute(a, b);"];
    let added = ["// recompute the total", "let total = compute(a, b, c);"];

    // Positional pairing would have matched the comment to the statement.
    assert_eq!(
        pair_lines(&removed, &added),
        vec![(None, Some(0)), (Some(0), Some(1))]
    );
}

#[test]
fn unrelated_lines_stay_separate_deletions_and_insertions() {
    let removed = ["import Foundation", "import AppKit"];
    let added = ["let x = 1", "let y = 2", "let z = 3"];

    // Nothing clears the similarity floor, so no row is labelled "changed".
    let pairs = pair_lines(&removed, &added);
    assert!(pairs
        .iter()
        .all(|(left, right)| left.is_none() || right.is_none()));
    assert_eq!(pairs.len(), 5);
}

#[test]
fn pairing_keeps_line_numbers_monotonic() {
    let removed = ["alpha one", "beta two", "gamma three"];
    let added = ["gamma three!", "alpha one!", "beta two!"];

    // A crossing match would scramble line numbers in the rendered list.
    let pairs = pair_lines(&removed, &added);
    let matched: Vec<(usize, usize)> = pairs
        .iter()
        .filter_map(|(left, right)| left.zip(*right))
        .collect();
    assert!(matched
        .windows(2)
        .all(|pair| pair[0].0 < pair[1].0 && pair[0].1 < pair[1].1));
}

#[test]
fn oversized_blocks_fall_back_to_positional_pairing() {
    let text: Vec<String> = (0..(MAX_ALIGNMENT_CELLS + 1))
        .map(|index| format!("line {index}"))
        .collect();
    let removed: Vec<&str> = text.iter().map(String::as_str).collect();
    let added = &removed[..2];

    let pairs = pair_lines(&removed, added);
    assert_eq!(pairs.len(), removed.len());
    assert_eq!(pairs[0], (Some(0), Some(0)));
    assert_eq!(pairs[1], (Some(1), Some(1)));
    assert_eq!(pairs[2], (Some(2), None));
}

#[test]
fn similarity_scores_reindentation_as_a_near_match() {
    assert_eq!(line_similarity("    return value", "\t\treturn value"), 1.0);
    assert_eq!(line_similarity("abc", ""), 0.0);
}
