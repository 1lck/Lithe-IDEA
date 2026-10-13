use crate::plugins::marketplace::{
    install_review_command, resolve_source_command, validate_index_command,
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

const INDEX: &str = contract_file!("fixtures/marketplace/index.json");
const INDEX_CASES: &str = contract_file!("fixtures/marketplace/index-cases.json");
const INVALID_ENTRIES: &str = contract_file!("fixtures/marketplace/invalid-index-entries.json");
const SOURCE_URLS: &str = contract_file!("fixtures/marketplace/source-urls.json");
const INSTALL_REVIEWS: &str = contract_file!("fixtures/marketplace/install-reviews.json");
const PHP_FIXTURE: &str = contract_file!("fixtures/php-support.plugin.json");
const GO_FIXTURE: &str = contract_file!("fixtures/go-support.plugin.json");
const OFFICIAL_INDEX: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/marketplace/index.json"
));

fn json_file(source: &str) -> Value {
    serde_json::from_str(source).expect("fixture is JSON")
}

fn manifest_fixture(name: &str) -> Value {
    match name {
        "php-support.plugin.json" => json_file(PHP_FIXTURE),
        "go-support.plugin.json" => json_file(GO_FIXTURE),
        other => panic!("unknown fixture {other}"),
    }
}

fn validate(index: Value, source_kind: &str, platform: &str) -> Value {
    validate_index_command(json!({
        "index": index,
        "sourceKind": source_kind,
        "platform": platform,
    }))
    .expect("payload is well formed")
}

/// Asserts that every key in `expected` has the same value in `actual`, so a
/// fixture states only the facts it is about.
fn assert_subset(actual: &Value, expected: &Value, context: &str) {
    match expected {
        Value::Object(fields) => {
            for (key, value) in fields {
                assert_subset(&actual[key], value, &format!("{context}.{key}"));
            }
        }
        _ => assert_eq!(actual, expected, "{context}"),
    }
}

fn apply_edit(target: &mut Value, edit: &Value) {
    let path = edit["path"].as_str().unwrap();
    let (parent_path, key) = path.rsplit_once('/').unwrap();
    let parent = target.pointer_mut(parent_path).expect("edit parent exists");
    match edit["op"].as_str().unwrap() {
        "set" => match parent {
            Value::Array(items) => items[key.parse::<usize>().unwrap()] = edit["value"].clone(),
            Value::Object(fields) => {
                fields.insert(key.to_string(), edit["value"].clone());
            }
            _ => panic!("cannot edit {path}"),
        },
        "remove" => {
            parent.as_object_mut().unwrap().remove(key);
        }
        other => panic!("unknown edit {other}"),
    }
}

#[test]
fn index_fixture_cases_match_expected_availability() {
    let cases = json_file(INDEX_CASES);
    for case in cases["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let outcome = validate(
            json_file(INDEX),
            case["sourceKind"].as_str().unwrap(),
            case["platform"].as_str().unwrap(),
        );
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
        let plugins = outcome["index"]["plugins"].as_array().unwrap();
        let expected_plugins = case["expected"]["plugins"].as_array().unwrap();
        assert_eq!(plugins.len(), expected_plugins.len(), "{name}: {outcome}");
        for (actual, expected) in plugins.iter().zip(expected_plugins) {
            assert_subset(actual, expected, name);
        }
        let rejected = outcome["index"]["rejected"].as_array().unwrap();
        let expected_rejected = case["expected"]["rejected"].as_array().unwrap();
        assert_eq!(rejected.len(), expected_rejected.len(), "{name}: {outcome}");
        for (actual, expected) in rejected.iter().zip(expected_rejected) {
            assert_eq!(actual["id"], expected["id"], "{name}");
            assert_eq!(
                actual["error"]["code"], expected["code"],
                "{name}: {actual}"
            );
        }
    }
}

#[test]
fn accepted_entries_are_normalized_newest_first() {
    let outcome = validate(json_file(INDEX), "official", "darwin-arm64");
    let zig = &outcome["index"]["plugins"][2];
    assert_eq!(zig["tags"], json!(["language", "zig"]));
    assert_eq!(
        zig["localizedDescriptions"],
        json!({ "zh-Hans": "Zig 语言服务器与测试运行集成。" })
    );
    // The index lists 1.9.0 before 2.0.0; hosts always see newest first.
    assert_eq!(zig["versions"][0]["version"], "2.0.0");
    assert_eq!(zig["versions"][1]["version"], "1.9.0");
    assert_eq!(zig["latestReleaseDate"], "2026-09-20");
    assert_eq!(zig["repository"], "https://github.com/example/lithe-zig");
}

#[test]
fn invalid_index_entries_report_their_stable_codes() {
    let cases = json_file(INVALID_ENTRIES);
    for case in cases["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let mut entry = json_file(INDEX)["plugins"][0].clone();
        for edit in case["edits"].as_array().unwrap() {
            apply_edit(&mut entry, edit);
        }
        let outcome = validate(
            json!({ "schemaVersion": 1, "plugins": [entry] }),
            "thirdParty",
            "darwin-arm64",
        );
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
        assert!(
            outcome["index"]["plugins"].as_array().unwrap().is_empty(),
            "{name}: {outcome}"
        );
        assert_eq!(
            outcome["index"]["rejected"][0]["error"]["code"], case["expectedCode"],
            "{name}: {outcome}"
        );
    }
}

#[test]
fn whole_index_problems_reject_the_index() {
    for (index, code) in [
        (
            json!({ "schemaVersion": 2, "plugins": [] }),
            "plugin.index.schemaUnsupported",
        ),
        (json!({ "plugins": [] }), "plugin.index.invalid"),
        (json!({ "schemaVersion": 1 }), "plugin.index.invalid"),
        (
            json!({ "schemaVersion": 1, "plugins": [], "mirror": "x" }),
            "plugin.index.invalid",
        ),
        (json!([]), "plugin.index.invalid"),
    ] {
        let outcome = validate(index.clone(), "thirdParty", "darwin-arm64");
        assert_eq!(outcome["status"], "rejected", "{index}: {outcome}");
        assert_eq!(outcome["error"]["code"], code, "{index}: {outcome}");
    }
}

#[test]
fn official_marketplace_index_validates_without_rejections() {
    for platform in ["darwin-arm64", "darwin-x64"] {
        let outcome = validate(json_file(OFFICIAL_INDEX), "official", platform);
        assert_eq!(outcome["status"], "ok", "{outcome}");
        assert_eq!(outcome["index"]["rejected"], json!([]), "{outcome}");
    }
}

#[test]
fn source_url_fixtures_resolve_to_expected_index_urls() {
    let cases = json_file(SOURCE_URLS);
    for case in cases["cases"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        let outcome = resolve_source_command(json!({ "url": input })).unwrap();
        if let Some(code) = case.get("expectedCode") {
            assert_eq!(outcome["status"], "rejected", "{input}: {outcome}");
            assert_eq!(&outcome["error"]["code"], code, "{input}: {outcome}");
        } else {
            assert_eq!(outcome["status"], "ok", "{input}: {outcome}");
            assert_eq!(outcome["source"], case["expected"], "{input}");
        }
    }
}

#[test]
fn install_review_fixtures_match_golden_outcomes() {
    let cases = json_file(INSTALL_REVIEWS);
    for case in cases["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let mut manifest = manifest_fixture(case["base"].as_str().unwrap());
        for edit in case["edits"].as_array().into_iter().flatten() {
            apply_edit(&mut manifest, edit);
        }
        let mut payload = json!({ "manifest": manifest });
        if let Some(id) = case.get("expectedID") {
            payload["expectedID"] = id.clone();
        }
        if let Some(version) = case.get("expectedVersion") {
            payload["expectedVersion"] = version.clone();
        }
        if let Some(approved_from) = case.get("approvedFrom") {
            // The approval recorded for the installed version is exactly the
            // program list its own review produced.
            let approved = install_review_command(json!({
                "manifest": manifest_fixture(approved_from.as_str().unwrap())
            }))
            .unwrap();
            payload["approvedPrograms"] = approved["review"]["programs"].clone();
        }
        let outcome = install_review_command(payload).unwrap();
        if let Some(code) = case.get("expectedCode") {
            assert_eq!(outcome["status"], "rejected", "{name}: {outcome}");
            assert_eq!(&outcome["error"]["code"], code, "{name}: {outcome}");
            continue;
        }
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
        let review = &outcome["review"];
        let mut expected = case["expected"].clone();
        if let Some(count) = expected.as_object_mut().unwrap().remove("newProgramCount") {
            assert_eq!(
                review["newPrograms"].as_array().unwrap().len() as u64,
                count.as_u64().unwrap(),
                "{name}: {review}"
            );
        }
        assert_subset(review, &expected, name);
    }
}
