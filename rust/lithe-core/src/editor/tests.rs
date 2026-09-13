//! Tests for the deterministic line-editing transforms and the comment
//! token table. Expected values were pinned against IDEA semantics and the
//! review regressions from PR #642.

use serde_json::{json, Value};

use super::line_edit::{line_comment_token, line_edit, LineCommentTokenRequest, LineEditRequest};

fn edit(
    operation: &str,
    source: &str,
    selection_start: usize,
    selection_length: usize,
    comment_token: Option<&str>,
) -> Value {
    let request = serde_json::from_value::<LineEditRequest>(json!({
        "operation": operation,
        "source": source,
        "selectionStart": selection_start,
        "selectionLength": selection_length,
        "commentToken": comment_token,
    }))
    .expect("request should deserialize");
    serde_json::to_value(line_edit(request).expect("line edit should succeed"))
        .expect("outcome should serialize")
}

fn applied(
    operation: &str,
    source: &str,
    selection_start: usize,
    selection_length: usize,
    comment_token: Option<&str>,
) -> Value {
    let outcome = edit(
        operation,
        source,
        selection_start,
        selection_length,
        comment_token,
    );
    assert_eq!(
        outcome["applied"],
        json!(true),
        "operation should apply: {outcome}"
    );
    outcome
}

fn not_applied(
    operation: &str,
    source: &str,
    selection_start: usize,
    selection_length: usize,
    comment_token: Option<&str>,
) {
    let outcome = edit(
        operation,
        source,
        selection_start,
        selection_length,
        comment_token,
    );
    assert_eq!(outcome["applied"], json!(false), "unexpected: {outcome}");
}

// MARK: Toggle line comment

#[test]
fn toggle_comment_inserts_at_line_start_and_maps_caret() {
    assert_eq!(
        applied("toggleLineComment", "let x = 1", 5, 0, Some("//")),
        json!({
            "applied": true,
            "text": "// let x = 1",
            "replacedStart": 0,
            "replacedLength": 9,
            "selectionStart": 8,
            "selectionLength": 0,
        })
    );
}

#[test]
fn toggle_comment_inserts_after_leading_indentation() {
    assert_eq!(
        applied("toggleLineComment", "  let x = 1", 0, 0, Some("//")),
        json!({
            "applied": true,
            "text": "  // let x = 1",
            "replacedStart": 0,
            "replacedLength": 11,
            "selectionStart": 0,
            "selectionLength": 0,
        })
    );
}

#[test]
fn toggle_comment_removes_token_and_one_trailing_space() {
    assert_eq!(
        applied("toggleLineComment", "// let x = 1", 0, 0, Some("//")),
        json!({
            "applied": true,
            "text": "let x = 1",
            "replacedStart": 0,
            "replacedLength": 12,
            "selectionStart": 0,
            "selectionLength": 0,
        })
    );
}

#[test]
fn toggle_comment_removes_token_without_trailing_space() {
    assert_eq!(
        applied("toggleLineComment", "//let x = 1", 4, 0, Some("//")),
        json!({
            "applied": true,
            "text": "let x = 1",
            "replacedStart": 0,
            "replacedLength": 11,
            "selectionStart": 2,
            "selectionLength": 0,
        })
    );
}

#[test]
fn toggle_comment_uncomments_indented_line() {
    assert_eq!(
        applied("toggleLineComment", "  // let x = 1", 0, 0, Some("//"))["text"],
        json!("  let x = 1")
    );
}

#[test]
fn toggle_comment_comments_mixed_selection() {
    let outcome = applied("toggleLineComment", "a\n// b", 0, 6, Some("//"));
    assert_eq!(outcome["text"], json!("// a\n// // b"));
    assert_eq!(outcome["selectionStart"], json!(0));
    assert_eq!(outcome["selectionLength"], json!(12));
}

#[test]
fn toggle_comment_skips_blank_lines() {
    assert_eq!(
        applied("toggleLineComment", "a\n\nb", 0, 4, Some("//"))["text"],
        json!("// a\n\n// b")
    );
}

#[test]
fn toggle_comment_excludes_line_when_selection_ends_at_line_start() {
    let outcome = applied("toggleLineComment", "a\nb\nc", 0, 2, Some("//"));
    assert_eq!(outcome["text"], json!("// a"));
    assert_eq!(outcome["replacedLength"], json!(1));
}

#[test]
fn toggle_comment_covers_both_lines_when_selection_ends_at_next_line_start() {
    // Regression: {0,4} covers "a\nb\n"; both lines must toggle instead of
    // only the first one.
    let outcome = applied("toggleLineComment", "a\nb\nc", 0, 4, Some("//"));
    assert_eq!(outcome["text"], json!("// a\n// b"));
    assert_eq!(outcome["replacedStart"], json!(0));
    assert_eq!(outcome["replacedLength"], json!(3));
    assert_eq!(outcome["selectionStart"], json!(0));
    assert_eq!(outcome["selectionLength"], json!(10));
}

#[test]
fn toggle_comment_preserves_selection_coverage_across_lines() {
    let outcome = applied("toggleLineComment", "a\nb", 0, 3, Some("//"));
    assert_eq!(outcome["text"], json!("// a\n// b"));
    assert_eq!(outcome["selectionStart"], json!(0));
    assert_eq!(outcome["selectionLength"], json!(9));
}

#[test]
fn toggle_comment_supports_sql_dash_token() {
    assert_eq!(
        applied("toggleLineComment", "SELECT 1", 0, 0, Some("--"))["text"],
        json!("-- SELECT 1")
    );
}

#[test]
fn toggle_comment_on_all_blank_selection_is_no_op() {
    not_applied("toggleLineComment", "  \n\t", 0, 4, Some("//"));
}

#[test]
fn toggle_comment_without_token_is_rejected() {
    let request = serde_json::from_value::<LineEditRequest>(json!({
        "operation": "toggleLineComment",
        "source": "a",
        "selectionStart": 0,
        "selectionLength": 0,
    }))
    .expect("request should deserialize");
    let error = line_edit(request).expect_err("missing token must fail");
    assert_eq!(
        serde_json::to_value(&error).expect("error should serialize")["code"],
        json!("invalid_request")
    );
}

#[test]
fn toggle_twice_restores_original_for_non_first_line() {
    // Regression: the uncomment branch once indexed line content with
    // document offsets and went out of bounds for any line but the first.
    let original = "func f() {\n    let x = 1\n}";
    let caret = original.encode_utf16().count() - 3;
    let first = applied("toggleLineComment", original, caret, 0, Some("//"));
    assert_eq!(
        first["text"],
        json!("    // let x = 1"),
        "region replacement is wrong: {first}"
    );
    let mut document: Vec<u16> = original.encode_utf16().collect();
    let replaced: Vec<u16> = first["text"]
        .as_str()
        .expect("text")
        .encode_utf16()
        .collect();
    let start = first["replacedStart"].as_u64().expect("start") as usize;
    let length = first["replacedLength"].as_u64().expect("length") as usize;
    document.splice(start..start + length, replaced);
    let commented = String::from_utf16(&document).expect("valid");
    assert_eq!(commented, "func f() {\n    // let x = 1\n}");

    let second = line_edit(
        serde_json::from_value::<LineEditRequest>(json!({
            "operation": "toggleLineComment",
            "source": commented,
            "selectionStart": first["selectionStart"],
            "selectionLength": first["selectionLength"],
            "commentToken": "//",
        }))
        .expect("request should deserialize"),
    )
    .expect("line edit should succeed");
    let outcome = serde_json::to_value(&second).expect("serialize");
    document = commented.encode_utf16().collect();
    let replaced: Vec<u16> = outcome["text"]
        .as_str()
        .expect("text")
        .encode_utf16()
        .collect();
    let start = outcome["replacedStart"].as_u64().expect("start") as usize;
    let length = outcome["replacedLength"].as_u64().expect("length") as usize;
    document.splice(start..start + length, replaced);
    assert_eq!(
        String::from_utf16(&document).expect("valid"),
        original,
        "second toggle must restore the original text"
    );
}

#[test]
fn uncomment_maps_endpoint_inside_later_token_to_new_coordinates() {
    // Regression: clamping an endpoint inside a removed span once used the
    // original coordinate and dropped the displacement of earlier lines.
    let outcome = applied("toggleLineComment", "// a\n// b", 0, 6, Some("//"));
    assert_eq!(outcome["text"], json!("a\nb"));
    assert_eq!(outcome["selectionStart"], json!(0));
    assert_eq!(outcome["selectionLength"], json!(2));
}

#[test]
fn toggle_comment_covers_both_crlf_lines_when_selection_ends_at_line_start() {
    let outcome = applied("toggleLineComment", "a\r\nb\r\nc", 0, 6, Some("//"));
    assert_eq!(outcome["text"], json!("// a\r\n// b"));
    assert_eq!(outcome["replacedLength"], json!(4));
}

// MARK: Duplicate line

#[test]
fn duplicate_duplicates_line_with_trailing_newline_and_keeps_column() {
    let outcome = applied("duplicateLine", "abc\ndef", 1, 0, None);
    assert_eq!(outcome["text"], json!("abc\n"));
    assert_eq!(outcome["replacedStart"], json!(4));
    assert_eq!(outcome["replacedLength"], json!(0));
    assert_eq!(outcome["selectionStart"], json!(5));
    assert_eq!(outcome["selectionLength"], json!(0));
}

#[test]
fn duplicate_duplicates_last_line_without_trailing_newline() {
    let outcome = applied("duplicateLine", "abc", 1, 0, None);
    assert_eq!(outcome["text"], json!("\nabc"));
    assert_eq!(outcome["replacedStart"], json!(3));
    assert_eq!(outcome["selectionStart"], json!(5));
}

#[test]
fn duplicate_duplicates_empty_line() {
    let outcome = applied("duplicateLine", "a\n\nb", 2, 0, None);
    assert_eq!(outcome["text"], json!("\n"));
    assert_eq!(outcome["replacedStart"], json!(3));
    assert_eq!(outcome["selectionStart"], json!(3));
}

#[test]
fn duplicate_empty_document_inserts_one_newline() {
    // Regression: an empty document still has one empty line; the shortcut
    // must apply an edit instead of being swallowed.
    let outcome = applied("duplicateLine", "", 0, 0, None);
    assert_eq!(outcome["text"], json!("\n"));
    assert_eq!(outcome["replacedStart"], json!(0));
    assert_eq!(outcome["replacedLength"], json!(0));
    assert_eq!(outcome["selectionStart"], json!(1));
    assert_eq!(outcome["selectionLength"], json!(0));
}

#[test]
fn duplicate_duplicates_selected_text_as_is() {
    let outcome = applied("duplicateLine", "hello world", 0, 5, None);
    assert_eq!(outcome["text"], json!("hello"));
    assert_eq!(outcome["replacedStart"], json!(5));
    assert_eq!(outcome["selectionStart"], json!(5));
    assert_eq!(outcome["selectionLength"], json!(5));
}

#[test]
fn duplicate_duplicates_multi_line_selection() {
    let outcome = applied("duplicateLine", "a\nb", 0, 3, None);
    assert_eq!(outcome["text"], json!("a\nb"));
    assert_eq!(outcome["replacedStart"], json!(3));
    assert_eq!(outcome["selectionStart"], json!(3));
    assert_eq!(outcome["selectionLength"], json!(3));
}

#[test]
fn duplicate_preserves_crlf_separator() {
    let outcome = applied("duplicateLine", "a\r\nb", 1, 0, None);
    assert_eq!(outcome["text"], json!("a\r\n"));
    assert_eq!(outcome["replacedStart"], json!(3));
    assert_eq!(outcome["selectionStart"], json!(4));
}

// MARK: Delete line

#[test]
fn delete_line_removes_covered_line_with_separator() {
    let outcome = applied("deleteLine", "a\nb\nc", 2, 0, None);
    assert_eq!(outcome["text"], json!(""));
    assert_eq!(outcome["replacedStart"], json!(2));
    assert_eq!(outcome["replacedLength"], json!(2));
    assert_eq!(outcome["selectionStart"], json!(2));
}

#[test]
fn delete_line_removes_last_line_without_separator() {
    let outcome = applied("deleteLine", "a\nb", 2, 0, None);
    assert_eq!(outcome["text"], json!(""));
    assert_eq!(outcome["replacedLength"], json!(1));
}

// MARK: Move lines

#[test]
fn move_up_on_first_line_is_no_op() {
    not_applied("moveLineUp", "a\nb", 0, 0, None);
}

#[test]
fn move_down_on_last_line_is_no_op() {
    not_applied("moveLineDown", "a\nb", 2, 0, None);
    not_applied("moveLineDown", "a\nb\n", 2, 0, None);
}

#[test]
fn move_up_swaps_with_line_above_and_shifts_caret() {
    let outcome = applied("moveLineUp", "a\nb\nc", 2, 0, None);
    assert_eq!(outcome["text"], json!("b\na\n"));
    assert_eq!(outcome["replacedStart"], json!(0));
    assert_eq!(outcome["replacedLength"], json!(4));
    assert_eq!(outcome["selectionStart"], json!(0));
}

#[test]
fn move_up_keeps_caret_column() {
    let outcome = applied("moveLineUp", "aaa\nb\nccc", 8, 0, None);
    assert_eq!(outcome["text"], json!("ccc\nb"));
    assert_eq!(outcome["replacedStart"], json!(4));
    assert_eq!(outcome["replacedLength"], json!(5));
    assert_eq!(outcome["selectionStart"], json!(6));
    assert_eq!(outcome["selectionLength"], json!(0));
}

#[test]
fn move_up_moves_multi_line_block_as_whole() {
    let outcome = applied("moveLineUp", "a\nb\nc", 2, 3, None);
    assert_eq!(outcome["text"], json!("b\nc\na"));
    assert_eq!(outcome["selectionStart"], json!(0));
    assert_eq!(outcome["selectionLength"], json!(3));
}

#[test]
fn move_up_handles_last_line_without_newline() {
    let outcome = applied("moveLineUp", "a\nb", 2, 0, None);
    assert_eq!(outcome["text"], json!("b\na"));
    assert_eq!(outcome["selectionStart"], json!(0));
}

#[test]
fn move_down_handles_last_line_without_newline() {
    let outcome = applied("moveLineDown", "a\nb", 0, 0, None);
    assert_eq!(outcome["text"], json!("b\na"));
    assert_eq!(outcome["selectionStart"], json!(2));
}

#[test]
fn move_down_swaps_with_line_below() {
    let outcome = applied("moveLineDown", "a\nb\nc", 0, 0, None);
    assert_eq!(outcome["text"], json!("b\na\n"));
    assert_eq!(outcome["selectionStart"], json!(2));
}

#[test]
fn move_down_excludes_line_when_selection_ends_at_line_start() {
    let outcome = applied("moveLineDown", "a\nb\nc", 0, 2, None);
    assert_eq!(outcome["text"], json!("b\na\n"));
    assert_eq!(outcome["selectionStart"], json!(2));
    assert_eq!(outcome["selectionLength"], json!(2));
}

#[test]
fn move_up_moves_empty_line() {
    let outcome = applied("moveLineUp", "a\n\nb", 2, 0, None);
    assert_eq!(outcome["text"], json!("\na\n"));
    assert_eq!(outcome["selectionStart"], json!(0));
}

#[test]
fn move_preserves_crlf_separator() {
    let outcome = applied("moveLineUp", "a\r\nb", 3, 0, None);
    assert_eq!(outcome["text"], json!("b\r\na"));
    assert_eq!(outcome["selectionStart"], json!(0));
}

#[test]
fn move_down_moves_whole_block_when_selection_ends_at_next_line_start() {
    // Regression: {0,4} covers "a\nb\n"; the block must move as a whole and
    // the selection must tighten to the moved block content because the
    // block separator moves in front of it.
    let outcome = applied("moveLineDown", "a\nb\nc", 0, 4, None);
    assert_eq!(outcome["text"], json!("c\na\nb"));
    assert_eq!(outcome["replacedStart"], json!(0));
    assert_eq!(outcome["replacedLength"], json!(5));
    assert_eq!(outcome["selectionStart"], json!(2));
    assert_eq!(outcome["selectionLength"], json!(3));
}

#[test]
fn move_down_moves_whole_crlf_block_when_selection_ends_at_next_line_start() {
    let outcome = applied("moveLineDown", "a\r\nb\r\nc", 0, 6, None);
    assert_eq!(outcome["text"], json!("c\r\na\r\nb"));
    assert_eq!(outcome["selectionStart"], json!(3));
    assert_eq!(outcome["selectionLength"], json!(4));
}

#[test]
fn move_down_to_last_line_without_newline_clamps_selection_end() {
    // Regression: keeping the selection length once produced an endpoint
    // beyond the new document length.
    let outcome = applied("moveLineDown", "a\nb", 0, 2, None);
    assert_eq!(outcome["text"], json!("b\na"));
    assert_eq!(outcome["selectionStart"], json!(2));
    assert_eq!(outcome["selectionLength"], json!(1));
}

// MARK: Copy lines

#[test]
fn copy_line_up_inserts_copy_above_and_keeps_selection() {
    let outcome = applied("copyLineUp", "a\nb\nc", 2, 0, None);
    assert_eq!(outcome["text"], json!("b\n"));
    assert_eq!(outcome["replacedStart"], json!(2));
    assert_eq!(outcome["replacedLength"], json!(0));
    assert_eq!(outcome["selectionStart"], json!(2));
    assert_eq!(outcome["selectionLength"], json!(0));
}

#[test]
fn copy_line_up_handles_last_line_without_newline() {
    let outcome = applied("copyLineUp", "a\nb", 2, 0, None);
    assert_eq!(outcome["text"], json!("b\n"));
    assert_eq!(outcome["replacedStart"], json!(2));
    assert_eq!(outcome["selectionStart"], json!(2));
}

#[test]
fn copy_line_down_behaves_like_duplicate() {
    let outcome = applied("copyLineDown", "abc\ndef", 1, 0, None);
    assert_eq!(outcome["text"], json!("abc\n"));
    assert_eq!(outcome["selectionStart"], json!(5));
}

// MARK: Comment token table

#[test]
fn line_comment_token_maps_common_extensions_and_language_ids() {
    for (extension, expected) in [
        ("swift", "//"),
        ("Swift", "//"),
        ("java", "//"),
        ("ts", "//"),
        ("csharp", "//"),
        ("zig", "//"),
        ("javascript", "//"),
        ("javascriptreact", "//"),
        ("typescript", "//"),
        ("typescriptreact", "//"),
        ("kotlin", "//"),
        ("py", "#"),
        ("python", "#"),
        ("ruby", "#"),
        ("yaml", "#"),
        ("properties", "#"),
        ("shell", "#"),
        ("dotenv", "#"),
        ("sql", "--"),
        ("lua", "--"),
    ] {
        let token = line_comment_token(LineCommentTokenRequest {
            identifier: extension.to_string(),
        });
        assert_eq!(
            token.token.as_deref(),
            Some(expected),
            "extension {extension}"
        );
    }
}

#[test]
fn line_comment_token_returns_none_for_unknown_extension() {
    for extension in ["json", ""] {
        let token = line_comment_token(LineCommentTokenRequest {
            identifier: extension.to_string(),
        });
        assert_eq!(token.token, None, "extension {extension}");
    }
}

#[test]
fn line_comment_token_resolves_dotfile_basenames() {
    // Regression: macOS pathExtension is empty for dotfiles such as .env,
    // so callers pass the basename and Core resolves the last dot segment.
    for (name, expected) in [(".env", Some("#")), ("Foo.py", Some("#")), ("README", None)] {
        let token = line_comment_token(LineCommentTokenRequest {
            identifier: name.to_string(),
        });
        assert_eq!(token.token.as_deref(), expected, "file name {name}");
    }
}

#[test]
fn move_down_maps_crlf_separator_caret_to_valid_selection() {
    // Regression: a caret between \r and \n once mapped to an offset
    // beyond the edited document.
    let outcome = applied("moveLineDown", "a\r\nb", 2, 0, None);
    assert_eq!(outcome["text"], json!("b\r\na"));
    assert_eq!(outcome["selectionStart"], json!(4));
    assert_eq!(outcome["selectionLength"], json!(0));
}

/// Regression helper for the exhaustive sweep: computes the edited UTF-16
/// length (sourceLength - replacedLength + textLength) plus the mapped
/// selection.
fn edited_length_and_selection(source_length: usize, outcome: &Value) -> (usize, usize, usize) {
    let replaced_length = outcome["replacedLength"].as_u64().expect("replaced length") as usize;
    let text_length = outcome["text"]
        .as_str()
        .expect("text")
        .encode_utf16()
        .count();
    (
        source_length - replaced_length + text_length,
        outcome["selectionStart"].as_u64().expect("selection start") as usize,
        outcome["selectionLength"]
            .as_u64()
            .expect("selection length") as usize,
    )
}

#[test]
fn every_operation_maps_selections_inside_the_edited_document() {
    // Exhaustive sweep over the reviewer's reproduction corpus: every start
    // and length against LF and CRLF documents, all operations. The edited
    // document length is sourceLength - replacedLength + textLength.
    let sources = ["a\r\nb", "a\r\nb\r\nc", "a\nb\nc", "x", ""];
    let operations = [
        "toggleLineComment",
        "duplicateLine",
        "deleteLine",
        "moveLineUp",
        "moveLineDown",
        "copyLineUp",
        "copyLineDown",
    ];
    for source in sources {
        let length = source.encode_utf16().count();
        for start in 0..=length {
            for selection_length in 0..=(length - start) {
                for operation in operations {
                    let token = if operation == "toggleLineComment" {
                        Some("//")
                    } else {
                        None
                    };
                    let outcome = edit(operation, source, start, selection_length, token);
                    if outcome["applied"] != json!(true) {
                        continue;
                    }
                    let (edited_length, mapped_start, mapped_length) =
                        edited_length_and_selection(length, &outcome);
                    assert!(
                        mapped_start + mapped_length <= edited_length,
                        "{operation} on {source:?} selection ({start}, {selection_length}) \
                         produced selection ({mapped_start}, {mapped_length}) \
                         outside the edited document length {edited_length}: {outcome}"
                    );
                }
            }
        }
    }
}

// MARK: Shared fixture contract

#[test]
fn shared_fixture_cases_match_core_outcomes() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/editor/line-edit-v1.json"
    )))
    .expect("line edit fixture should be valid JSON");
    for case_value in fixture["cases"].as_array().expect("cases") {
        let name = case_value["name"].as_str().expect("case name");
        // The fixture covers both editor commands; dispatch on the request
        // shape so one file pins the whole editor contract.
        let outcome = if case_value["request"].get("operation").is_some() {
            let request: LineEditRequest = serde_json::from_value(case_value["request"].clone())
                .unwrap_or_else(|error| panic!("{name}: {error:?}"));
            serde_json::to_value(
                line_edit(request).unwrap_or_else(|error| panic!("{name}: {error:?}")),
            )
            .expect("outcome should serialize")
        } else {
            let request: LineCommentTokenRequest =
                serde_json::from_value(case_value["request"].clone())
                    .unwrap_or_else(|error| panic!("{name}: {error:?}"));
            serde_json::to_value(line_comment_token(request)).expect("token should serialize")
        };
        assert_eq!(outcome, case_value["expected"], "case {name}");
    }
}
