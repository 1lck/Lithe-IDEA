//! Cross-platform presentation fixtures protect semantics, lossless ranges and grouping.
use super::*;
use serde_json::{json, Value};

#[test]
fn presentation_matches_shared_console_cases_without_rewriting_retained_output() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../shared/fixtures/git/console-presentation-v1.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let request: Request = serde_json::from_value(case["input"].clone()).unwrap();
        let result = present(request).unwrap();
        assert_eq!(
            serde_json::to_value(&result).unwrap(),
            case["presentation"],
            "{}",
            case["name"]
        );
        let expected = &case["expected"];
        let entry = &result.entries[0];
        if let Some(folds) = expected.get("folds") {
            let actual = entry
                .output
                .iter()
                .filter(|f| f.kind != "text")
                .map(|f| json!([f.start, f.end, f.kind]))
                .collect::<Vec<_>>();
            assert_eq!(json!(actual), *folds, "{}", case["name"]);
        }
        if let Some(contains) = expected["visibleCommandContains"].as_array() {
            let text = entry
                .command
                .iter()
                .filter(|f| f.kind == "text")
                .map(|f| f.text.clone())
                .collect::<Vec<_>>()
                .join(" ");
            for value in contains {
                assert!(
                    text.contains(value.as_str().unwrap()),
                    "{text}: {}",
                    case["name"]
                );
            }
        }
        if let Some(kinds) = expected.get("commandFoldKinds") {
            assert_eq!(
                json!(entry
                    .command
                    .iter()
                    .filter(|f| f.kind != "text")
                    .map(|f| &f.kind)
                    .collect::<Vec<_>>()),
                *kinds
            );
        }
        if let Some(count) = expected["commandFoldCount"].as_u64() {
            assert_eq!(entry.command.last().unwrap().count, count as usize);
        }
        if let Some(groups) = expected.get("groups") {
            assert_eq!(
                json!(result
                    .groups
                    .iter()
                    .map(|g| &g.record_ids)
                    .collect::<Vec<_>>()),
                *groups
            );
        }
        if let Some(labels) = expected.get("labels") {
            assert_eq!(
                json!(result
                    .entries
                    .iter()
                    .map(|e| &e.repository_label)
                    .collect::<Vec<_>>()),
                *labels
            );
        }
        if let Some(failed) = expected["failed"].as_bool() {
            assert_eq!(entry.failed, failed);
        }
        if let Some(matches) = expected["matches"].as_u64() {
            assert_eq!(result.total_matches, matches as usize);
        }
        for (entry, raw) in result
            .entries
            .iter()
            .zip(case["input"]["records"].as_array().unwrap())
        {
            let indices = entry
                .output
                .iter()
                .flat_map(|f| f.start..f.end)
                .collect::<Vec<_>>();
            assert_eq!(
                indices,
                (0..raw["lines"].as_array().unwrap().len()).collect::<Vec<_>>(),
                "{}",
                case["name"]
            );
        }
    }
}

#[test]
fn configuration_folds_in_place_while_force_options_and_targets_stay_visible() {
    let request = serde_json::from_value(json!({"records":[{
        "id":"force", "root":"/repo", "arguments":["-c","core.hooksPath=/hooks","push","--force-with-lease","origin","main"],
        "temporaryConfig":[["credential.helper",""]],"lines":[],"state":"completed","exitCode":0
    }]})).unwrap();
    let result = present(request).unwrap();
    assert_eq!(result.entries[0].command[0].kind, "configuration");
    assert!(result.entries[0].command[0]
        .text
        .contains("credential.helper="));
    assert!(result.entries[0].command[0]
        .text
        .contains("core.hooksPath=/hooks"));
    let text = result.entries[0]
        .command
        .iter()
        .map(|f| f.text.clone())
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        text.contains("core.hooksPath=/hooks") && text.contains("--force-with-lease origin main")
    );
}

#[test]
fn search_limits_locations_without_discarding_output_or_counts() {
    let request = serde_json::from_value(json!({"search":"match", "records":[{
        "id":"large", "root":"/repo", "arguments":["log"], "state":"completed","exitCode":0,
        "lines":[{"stream":"stderr","text":"match ".repeat(1500)}]
    }]}))
    .unwrap();
    let result = present(request).unwrap();
    assert_eq!(result.total_matches, 1500);
    assert_eq!(result.matches.len(), 1000);
    assert_eq!(result.entries[0].output[0].end, 1);
    assert!(!result.entries[0].failed);
}

#[test]
fn ordinary_output_stays_visible_during_growth_and_failure() {
    let make = |count: usize, state: &str| -> Request {
        serde_json::from_value(json!({"search":"fatal", "records":[{
            "id":"stream", "root":"/repo", "arguments":["fetch","origin"], "state":state,
            "exitCode": if state == "completed" { Some(1) } else { None },
            "lines":(0..count).map(|i| json!({"stream":"stderr","text":if i == 10 { "fatal: denied".to_string() } else { format!("line {i}") }})).collect::<Vec<_>>()
        }]})).unwrap()
    };
    for count in [12, 20, 40] {
        let running = present(make(count, "running")).unwrap();
        assert_eq!(running.entries[0].output[3].id, "output-3");
        assert!(running.entries[0]
            .output
            .iter()
            .all(|fragment| fragment.kind == "text"));
        assert_eq!(running.entries[0].output.len(), count);
    }
    let failed = present(make(40, "completed")).unwrap();
    assert!(failed.entries[0].failed);
    assert!(failed.entries[0]
        .output
        .iter()
        .any(|f| f.kind == "text" && f.start == 10));
    assert_eq!(failed.matches[0].line_index, Some(10));
}

#[test]
fn expected_nonzero_queries_are_distinct_from_real_failures_and_limits_are_explicit() {
    let record = json!({"id":"optional", "root":"/repo", "arguments":["config","--get","remote.origin.skipFetchAll"],
        "state":"completed","exitCode":1,"expectedExit":true,"lines":[]});
    let output =
        present(serde_json::from_value(json!({"records":[record.clone()]})).unwrap()).unwrap();
    assert!(!output.entries[0].failed);
    assert!(output.entries[0].output.is_empty());
    let mut failure = record.clone();
    failure["error"] = json!("Could not inspect configuration");
    assert!(
        present(serde_json::from_value(json!({"records":[failure]})).unwrap())
            .unwrap()
            .entries[0]
            .failed
    );
    assert!(present(serde_json::from_value(json!({"records":vec![record;201]})).unwrap()).is_err());
    assert!(present(
        serde_json::from_value(json!({"records":[],"search":"x".repeat(1025)})).unwrap()
    )
    .is_err());
}
