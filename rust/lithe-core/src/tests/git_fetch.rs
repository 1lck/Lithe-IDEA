//! Real Git integration verifies Fetch selection using Git's own config parser.
use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

struct Repository(PathBuf);

impl Repository {
    fn new() -> Self {
        let repo = Self(temporary_root("fetch-booleans"));
        fs::create_dir_all(&repo.0).unwrap();
        repo.git(&["init", "--template=", "-q", "-b", "main"]);
        repo
    }

    fn request(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.0);
        // Every native subprocess stays inside a bounded Core request. The
        // timing harness additionally owns the whole integration test process.
        serde_json::from_str(&execute_json(
            &json!({
                "timeoutMilliseconds": 5000,
                "gitExecution": { "detailedFetch": true },
                "command": command,
                "payload": payload,
            })
            .to_string(),
        ))
        .unwrap()
    }

    fn git(&self, arguments: &[&str]) -> String {
        let response = self.request("git.command", json!({ "arguments": arguments }));
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["data"]["exitCode"], 0, "{response}");
        response["data"]["stdout"].as_str().unwrap().trim().into()
    }

    fn add_remotes(&self, remotes: &[(&str, &str)]) {
        let path = self.0.join(".git/config");
        let mut config = fs::read_to_string(&path).unwrap();
        for (remote, boolean) in remotes {
            // Fetch from this fixture's own branch into remote-tracking refs;
            // no external service, credentials or second repository is needed.
            config.push_str(&format!(
                "\n[remote \"{remote}\"]\nurl = .\nfetch = +refs/heads/main:refs/remotes/{remote}/main\n{boolean}\n"
            ));
        }
        fs::write(path, config).unwrap();
    }
}

impl Drop for Repository {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("Could not clean Fetch integration repository: {error}");
        }
    }
}

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/fetch-skip-boolean-v1.json"
    ))
    .unwrap()
}

#[test]
fn fetch_plan_preserves_git_boolean_config_semantics() {
    let repo = Repository::new();
    let fixture = fixture();
    let cases = fixture["cases"].as_array().unwrap();
    let remotes = cases
        .iter()
        .map(|case| {
            (
                case["name"].as_str().unwrap(),
                case["configuration"].as_str().unwrap(),
            )
        })
        .collect::<Vec<_>>();
    repo.add_remotes(&remotes);
    let result = repo.request("git.fetchPlan", json!({ "options": {} }));
    assert_eq!(result["ok"], true, "{result}");
    let actual = result["data"]["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|args| args.as_array().unwrap().last().unwrap().as_str().unwrap())
        .collect::<Vec<_>>();
    let mut expected = cases
        .iter()
        .filter(|case| case["skipped"] == false)
        .map(|case| case["name"].as_str().unwrap())
        .collect::<Vec<_>>();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}

#[test]
fn fetch_skips_valueless_true_unless_the_remote_is_explicitly_selected() {
    let repo = Repository::new();
    repo.add_remotes(&[("active", ""), ("skip", "skipFetchAll")]);
    repo.git(&[
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "core.hooksPath=disabled-fixture-hooks",
        "commit",
        "--allow-empty",
        "-qm",
        "fixture",
    ]);
    let response = repo.request("git.write", json!({ "operation": "fetch" }));
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["exitCode"], 0, "{response}");
    assert!(response["data"]["operationError"].is_null(), "{response}");
    assert_eq!(
        repo.git(&[
            "for-each-ref",
            "--format=%(refname)",
            "refs/remotes/active/main",
            "refs/remotes/skip/main"
        ]),
        "refs/remotes/active/main"
    );

    let options = json!({ "remote": "skip" });
    let plan = repo.request("git.fetchPlan", json!({ "options": options }));
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["commands"].as_array().unwrap().len(), 1);
    assert_eq!(
        plan["data"]["commands"][0].as_array().unwrap().last(),
        Some(&json!("skip"))
    );
    let response = repo.request(
        "git.write",
        json!({ "operation": "fetch", "fetchOptions": options }),
    );
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["exitCode"], 0, "{response}");
    assert_eq!(
        repo.git(&[
            "for-each-ref",
            "--format=%(refname)",
            "refs/remotes/active/main",
            "refs/remotes/skip/main"
        ]),
        "refs/remotes/active/main\nrefs/remotes/skip/main"
    );
}

#[test]
fn invalid_fetch_boolean_rejects_preview_and_execution_before_transfers() {
    let repo = Repository::new();
    let fixture = fixture();
    repo.add_remotes(&[
        ("active", ""),
        ("invalid", fixture["invalid"].as_str().unwrap()),
    ]);
    for (command, payload) in [
        ("git.fetchPlan", json!({ "options": {} })),
        ("git.write", json!({ "operation": "fetch" })),
    ] {
        let result = repo.request(command, payload);
        assert_eq!(result["ok"], false, "{result}");
        assert_eq!(result["error"]["code"], "process_failed", "{result}");
        assert!(
            !result["error"]["details"].as_str().unwrap().is_empty(),
            "{result}"
        );
        assert!(
            result["data"].is_null(),
            "Preflight must fail before any transfer: {result}"
        );
    }
    assert!(repo
        .git(&["for-each-ref", "--format=%(refname)", "refs/remotes"])
        .is_empty());
}
