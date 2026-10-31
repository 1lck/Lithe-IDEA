//! Plugin grammars (`languages` 2) and plugin Run markers (`runMarkers` 1).

use crate::plugins::declarative::{
    decode_grammar_command, decode_run_markers_command, validate_command,
};
use serde_json::{json, Value};

macro_rules! contract_file {
    ($path:literal) => {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/",
            $path
        ))
    };
}

const GRAMMAR_PLUGIN: &str = contract_file!("fixtures/language-grammar.plugin.json");
const RUN_MARKERS_PLUGIN: &str = contract_file!("fixtures/run-markers.plugin.json");
const HTTP_GRAMMAR: &str = contract_file!("fixtures/grammars/http.monarch.json");

fn manifest(source: &str) -> Value {
    serde_json::from_str(source).expect("fixture manifest is JSON")
}

fn decode_grammar(grammar: &str) -> Value {
    decode_grammar_command(json!({
        "manifest": manifest(GRAMMAR_PLUGIN),
        "languageID": "http",
        "grammar": grammar,
    }))
    .expect("payload is well formed")
}

fn grammar_rejection(grammar: Value) -> (String, String) {
    let outcome = decode_grammar(&grammar.to_string());
    assert_eq!(outcome["status"], "rejected", "{grammar}: {outcome}");
    (
        outcome["error"]["code"].as_str().unwrap().to_string(),
        outcome["error"]["field"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
    )
}

fn decode_markers(result: Value, line_count: u64) -> Value {
    decode_run_markers_command(json!({
        "manifest": manifest(RUN_MARKERS_PLUGIN),
        "languageID": "http",
        "lineCount": line_count,
        "result": result,
    }))
    .expect("payload is well formed")
}

fn marker_rejection(result: Value, line_count: u64) -> String {
    let outcome = decode_markers(result.clone(), line_count);
    assert_eq!(outcome["status"], "rejected", "{result}: {outcome}");
    outcome["error"]["code"].as_str().unwrap().to_string()
}

/// The editor gets the grammar file unchanged with what it needs to
/// register the language: file matching, engine kind and configuration.
#[test]
fn a_grammar_file_decodes_to_the_language_the_editor_registers() {
    let outcome = decode_grammar(HTTP_GRAMMAR);
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let language = &outcome["language"];
    assert_eq!(language["id"], "http");
    assert_eq!(language["fileExtensions"], json!(["http", "rest"]));
    assert_eq!(language["grammar"]["kind"], "monarch");
    assert_eq!(
        language["grammar"]["monarch"],
        serde_json::from_str::<Value>(HTTP_GRAMMAR).unwrap()
    );
    assert_eq!(language["configuration"]["lineComment"], "#");
    assert_eq!(
        language["configuration"]["brackets"],
        json!([["{", "}"], ["[", "]"]])
    );
}

#[test]
fn a_language_without_a_grammar_has_nothing_to_decode() {
    let outcome = decode_grammar_command(json!({
        "manifest": manifest(GRAMMAR_PLUGIN),
        "languageID": "rest",
        "grammar": HTTP_GRAMMAR,
    }))
    .unwrap();
    assert_eq!(
        outcome["error"]["code"], "plugin.grammar.unavailable",
        "{outcome}"
    );
}

/// A grammar is data the editor runs on every keystroke, so anything that
/// would make it fail at run time, print, or grow without bound is refused
/// before it reaches the editor.
#[test]
fn grammar_files_are_refused_when_the_editor_could_not_run_them() {
    let rejected = |grammar: Value, field: &str| {
        let (code, actual) = grammar_rejection(grammar.clone());
        assert_eq!(code, "plugin.grammar.invalid", "{grammar}");
        assert_eq!(actual, field, "{grammar}");
    };
    rejected(json!([]), "grammar");
    rejected(json!({ "tokenizer": {} }), "grammar.tokenizer");
    rejected(json!({ "tokenizer": { "main": [] } }), "grammar.start");
    rejected(
        json!({ "tokenizer": { "root": [["a", "keyword", "@missing"]] } }),
        "grammar.tokenizer.root[0][2]",
    );
    rejected(
        json!({ "tokenizer": { "root": [["a", { "token": "keyword", "log": "hit" }]] } }),
        "grammar.tokenizer.root[0][1].log",
    );
    rejected(
        json!({ "tokenizer": { "root": [["\\w+", { "cases": { "@keywords": "keyword" } }]] } }),
        "grammar.tokenizer.root[0][1].cases.@keywords",
    );
    rejected(
        json!({ "tokenizer": { "root": [["", "keyword"]] } }),
        "grammar.tokenizer.root[0]",
    );
    rejected(
        json!({ "tokenizer": { "root": [{ "include": "@other" }] } }),
        "grammar.tokenizer.root[0].include",
    );
    rejected(
        json!({ "ignoreCase": "yes", "tokenizer": { "root": [] } }),
        "grammar.ignoreCase",
    );
    rejected(
        json!({ "tokenizer": { "root": [["a", { "token": "x", "nextEmbedded": "Bad Lang" }]] } }),
        "grammar.tokenizer.root[0][1].nextEmbedded",
    );
    let (code, _) = grammar_rejection(json!({
        "tokenizer": { "root": [["a".repeat(2049), "keyword"]] }
    }));
    assert_eq!(code, "plugin.grammar.invalid");
    let oversized = format!(
        "{{\"padding\":\"{}\",\"tokenizer\":{{\"root\":[]}}}}",
        "x".repeat(256 * 1024)
    );
    assert_eq!(
        decode_grammar(&oversized)["error"]["code"],
        "plugin.grammar.invalid"
    );
}

/// Monarch resolves `@comment.block` to the longest declared prefix, so a
/// dotted next state is accepted when its prefix exists.
#[test]
fn dotted_states_resolve_to_their_declared_prefix() {
    let outcome = decode_grammar(
        &json!({
            "tokenizer": {
                "root": [["/\\*", "comment", "@comment.block"]],
                "comment": [["\\*/", "comment", "@pop"], [".", "comment"]]
            }
        })
        .to_string(),
    );
    assert_eq!(outcome["status"], "ok", "{outcome}");
}

/// A grammar on its own is a complete plugin: it needs no language server,
/// no backend, and no permission.
#[test]
fn a_grammar_only_plugin_validates_without_a_language_server() {
    let outcome = validate_command(json!({ "manifest": manifest(GRAMMAR_PLUGIN) })).unwrap();
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let language = &outcome["plugin"]["languages"][0];
    assert_eq!(language["grammar"]["path"], "grammars/http.monarch.json");
}

/// Markers come back sorted by line with the command that runs them, and
/// `endLine` defaults to the marker line and stops at the document end.
#[test]
fn provider_markers_are_sorted_and_carry_their_command() {
    let outcome = decode_markers(
        json!({
            "markers": [
                { "id": "create", "line": 9, "endLine": 40, "kind": "run", "title": " POST /orders ", "extra": 1 },
                { "id": "list", "line": 1, "kind": "test", "title": "GET /orders" },
                { "id": "suite", "line": 4, "endLine": null, "kind": "testSuite", "title": "Orders" }
            ]
        }),
        20,
    );
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let command = "dev.lithe.fixture.httpclient.send";
    assert_eq!(
        outcome["markers"],
        json!([
            { "id": "list", "line": 1, "endLine": 1, "kind": "test", "title": "GET /orders", "command": command },
            { "id": "suite", "line": 4, "endLine": 4, "kind": "testSuite", "title": "Orders", "command": command },
            { "id": "create", "line": 9, "endLine": 20, "kind": "run", "title": "POST /orders", "command": command }
        ])
    );
}

/// One bad marker rejects the answer, so the gutter never shows part of a
/// list the provider got wrong.
#[test]
fn malformed_provider_answers_are_rejected_whole() {
    let marker = |patch: Value| {
        let mut marker = json!({ "id": "a", "line": 2, "kind": "run", "title": "Send" });
        for (key, value) in patch.as_object().unwrap() {
            marker[key] = value.clone();
        }
        json!({ "markers": [marker] })
    };
    let invalid = "plugin.runMarkers.invalidOutput";
    assert_eq!(marker_rejection(json!([]), 5), invalid);
    assert_eq!(marker_rejection(marker(json!({ "line": 0 })), 5), invalid);
    assert_eq!(marker_rejection(marker(json!({ "line": 6 })), 5), invalid);
    assert_eq!(
        marker_rejection(marker(json!({ "endLine": 1 })), 5),
        invalid
    );
    assert_eq!(
        marker_rejection(marker(json!({ "kind": "debug" })), 5),
        invalid
    );
    assert_eq!(
        marker_rejection(marker(json!({ "title": "  " })), 5),
        invalid
    );
    assert_eq!(
        marker_rejection(marker(json!({ "title": "a\nb" })), 5),
        invalid
    );
    assert_eq!(
        marker_rejection(marker(json!({ "title": "t".repeat(201) })), 5),
        invalid
    );
    assert_eq!(marker_rejection(marker(json!({ "id": "" })), 5), invalid);
    assert_eq!(
        marker_rejection(marker(json!({ "id": "i".repeat(257) })), 5),
        invalid
    );
    assert_eq!(
        marker_rejection(
            json!({ "markers": [
                { "id": "a", "line": 1, "kind": "run", "title": "A" },
                { "id": "a", "line": 2, "kind": "run", "title": "B" }
            ] }),
            5
        ),
        invalid
    );
    assert_eq!(
        marker_rejection(
            json!({ "markers": [
                { "id": "a", "line": 1, "kind": "run", "title": "A" },
                { "id": "b", "line": 1, "kind": "run", "title": "B" }
            ] }),
            5
        ),
        invalid
    );
    let many: Vec<Value> = (1..=1001)
        .map(|line| json!({ "id": format!("m{line}"), "line": line, "kind": "run", "title": "Send" }))
        .collect();
    assert_eq!(marker_rejection(json!({ "markers": many }), 2000), invalid);
}

#[test]
fn a_language_without_a_provider_has_no_markers() {
    let outcome = decode_run_markers_command(json!({
        "manifest": manifest(RUN_MARKERS_PLUGIN),
        "languageID": "rest",
        "lineCount": 3,
        "result": { "markers": [] },
    }))
    .unwrap();
    assert_eq!(
        outcome["error"]["code"], "plugin.runMarkers.unavailable",
        "{outcome}"
    );
}

/// The provider declaration keeps its order-independent normal form.
#[test]
fn run_marker_providers_are_normalized_by_language() {
    let outcome = validate_command(json!({ "manifest": manifest(RUN_MARKERS_PLUGIN) })).unwrap();
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"]["runMarkers"],
        json!([{
            "languageID": "http",
            "function": "requests.markers",
            "command": "dev.lithe.fixture.httpclient.send"
        }])
    );
}

#[test]
fn malformed_decode_payloads_are_core_failures() {
    assert!(decode_grammar_command(json!({ "manifest": {}, "languageID": "http" })).is_err());
    assert!(decode_run_markers_command(json!({ "manifest": {}, "languageID": "http" })).is_err());
}
