//! Independent static editor resources, without language-server or Run providers.

use crate::plugins::declarative::{decode_grammar_command, validate_command};
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
    assert_eq!(language["grammar"]["source"], HTTP_GRAMMAR);
    assert_eq!(language["configuration"]["lineComment"], "#");
    assert_eq!(
        language["configuration"]["brackets"],
        json!([["{", "}"], ["[", "]"]])
    );
}

#[test]
fn grammar_source_preserves_order_through_sorted_json_roundtrips() {
    let source = r#"{"tokenizer":{"comment":[[".*","comment"]],"root":[["[A-Z]+",{"cases":{"GET":"keyword","[A-Z]+":"string","@default":"identifier"}}]]}}"#;
    let outcome = decode_grammar(source);
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let roundtrip: Value = serde_json::from_str(&outcome.to_string()).unwrap();
    assert_eq!(roundtrip["language"]["grammar"]["source"], source);
    assert!(roundtrip["language"]["grammar"].get("monarch").is_none());
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

#[test]
fn includes_reject_cycles_and_expanded_fan_out() {
    assert_eq!(
        decode_grammar(&json!({"tokenizer":{"root":[{"include":"@root"}]}}).to_string())["error"]
            ["code"],
        "plugin.grammar.invalid"
    );
    let mut states = serde_json::Map::new();
    states.insert("root".into(), json!([{"include":"@s0"}]));
    for index in 0..16 {
        states.insert(
            format!("s{index}"),
            json!([
        {"include":format!("@s{}",index+1)}, {"include":format!("@s{}",index+1)}]),
        );
    }
    states.insert("s16".into(), json!([["a", "keyword"]]));
    assert_eq!(
        decode_grammar(&json!({"tokenizer":states}).to_string())["error"]["code"],
        "plugin.grammar.invalid"
    );
}

#[test]
fn configuration_only_contribution_decodes_without_grammar() {
    let mut plugin = manifest(GRAMMAR_PLUGIN);
    plugin["languages"][0]
        .as_object_mut()
        .unwrap()
        .remove("grammar");
    // A backend is a complete tool plugin, with no language-server ownership.
    let tool = manifest(contract_file!("fixtures/backend-workspace.plugin.json"));
    plugin["backend"] = tool["backend"].clone();
    plugin["requires"]["backend"] = json!(2);
    plugin["requires"]["serverProcess"] = json!(1);
    plugin["permissions"] = json!(["backend.launch"]);
    plugin["activationEvents"] = json!(["onWorkspaceOpen"]);
    let result =
        decode_grammar_command(json!({"manifest":plugin,"languageID":"http","grammar":""}))
            .unwrap();
    assert_eq!(result["status"], "ok", "{result}");
    assert!(result["language"]["grammar"].is_null());
    assert_eq!(result["language"]["configuration"]["lineComment"], "#");
}
