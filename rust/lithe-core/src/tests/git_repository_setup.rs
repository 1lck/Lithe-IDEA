use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::{fs, path::PathBuf};

// Real Git integration fixtures use Core deadlines and own all temporary files.
struct SetupDirectory(PathBuf);
impl SetupDirectory {
    fn new(name: &str) -> Self {
        {
            let root = temporary_root(name);
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
    }
    fn call(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.0);
        serde_json::from_str(&execute_json(
            &json!({
                "id": format!("setup-{command}"), "command": command,
                "timeoutMilliseconds": 5000, "payload": payload
            })
            .to_string(),
        ))
        .unwrap()
    }
    fn data(&self, command: &str, payload: Value) -> Value {
        let response = self.call(command, payload);
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }
    fn git(&self, arguments: &[&str]) -> String {
        let data = self.data("git.command", json!({"arguments": arguments}));
        assert_eq!(data["exitCode"], 0, "{data}");
        assert!(data["operationError"].is_null(), "{data}");
        data["stdout"].as_str().unwrap().to_owned()
    }
}
impl Drop for SetupDirectory {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("Could not remove setup fixture: {error}");
        }
    }
}

#[test]
fn initialization_distinguishes_uninitialized_and_unborn_without_staging_files() {
    let directory = SetupDirectory::new("git-setup-init");
    fs::write(directory.0.join("new.txt"), "uncommitted").unwrap();
    let before = directory.data("git.repositorySetup", json!({}));
    assert_eq!(before["isRepository"], false);
    assert_eq!(before["hasCommits"], false);
    let after = directory.data("git.initialize", json!({}));
    assert_eq!(after["isRepository"], true);
    assert_eq!(after["hasCommits"], false);
    assert!(!after["branch"].as_str().unwrap().is_empty());
    assert!(directory.git(&["ls-files"]).is_empty());
    assert_eq!(
        fs::read_to_string(directory.0.join("new.txt")).unwrap(),
        "uncommitted"
    );
    assert_eq!(directory.call("git.initialize", json!({}))["ok"], false);
    let nested = directory.0.join("nested");
    fs::create_dir(&nested).unwrap();
    let request = json!({"id":"nested-init", "timeoutMilliseconds":5000,
        "command":"git.initialize", "payload":{"root":nested}});
    let response: Value = serde_json::from_str(&execute_json(&request.to_string())).unwrap();
    assert_eq!(response["ok"], false);
    assert!(!nested.join(".git").exists());
}

#[test]
fn identity_saves_one_field_and_clears_only_its_override() {
    let directory = SetupDirectory::new("git-setup-identity");
    directory.data("git.initialize", json!({}));
    directory.git(&["config", "user.email", "fixture@example.invalid"]);
    let saved = directory.data(
        "git.configureIdentity",
        json!({
            "scope":"local", "key":"name", "value":"--测试作者"
        }),
    );
    assert_eq!(saved["configuredName"], "--测试作者");
    assert_eq!(saved["effectiveName"], "--测试作者");
    assert_eq!(saved["configuredEmail"], "fixture@example.invalid");
    let cleared = directory.data(
        "git.configureIdentity",
        json!({
            "scope":"local", "key":"name", "value":null
        }),
    );
    assert!(cleared["configuredName"].is_null());
    assert_eq!(cleared["configuredEmail"], "fixture@example.invalid");
    assert_eq!(cleared["hasCommits"], false);
    // Clearing an already absent override is idempotent.
    directory.data(
        "git.configureIdentity",
        json!({"scope":"local", "key":"name", "value":null}),
    );
}

#[test]
fn setup_rejects_invalid_identity_and_malformed_repository_configuration() {
    let directory = SetupDirectory::new("git-setup-invalid");
    assert_eq!(
        directory.call(
            "git.configureIdentity",
            json!({
                "scope":"local", "key":"name", "value":"Fixture"
            })
        )["ok"],
        false
    );
    directory.data("git.initialize", json!({}));
    for value in ["", "   ", "bad\nname", "bad<name>"] {
        assert_eq!(
            directory.call(
                "git.configureIdentity",
                json!({
                    "scope":"local", "key":"name", "value":value
                })
            )["ok"],
            false
        );
    }
    assert_eq!(
        directory.call(
            "git.configureIdentity",
            json!({
                "scope":"local", "key":"credential.helper", "value":"other"
            })
        )["ok"],
        false
    );
    fs::write(directory.0.join(".git/config"), "[invalid").unwrap();
    assert_eq!(
        directory.call("git.repositorySetup", json!({}))["ok"],
        false
    );
    assert_eq!(directory.call("git.initialize", json!({}))["ok"], false);
}

#[test]
fn pull_expected_branch_rejects_a_changed_or_detached_checkout_before_execution() {
    let directory = SetupDirectory::new("pull-expected-branch");
    directory.data("git.initialize", json!({}));
    directory.git(&[
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "--allow-empty",
        "--no-gpg-sign",
        "-m",
        "initial",
    ]);
    directory.git(&["branch", "-M", "topic"]);
    directory.git(&["switch", "-c", "other"]);
    let before = directory.git(&["rev-parse", "HEAD"]);
    for detached in [false, true] {
        if detached {
            directory.git(&["switch", "--detach"]);
        }
        let result = directory.data(
            "git.write",
            json!({
                "operation": "pull", "mode": "ffOnly", "expectedBranch": "refs/heads/topic"
            }),
        );
        assert!(
            result["operationError"]["message"]
                .as_str()
                .unwrap()
                .contains("selected branch changed"),
            "{result}"
        );
        assert!(result["invocations"]
            .as_array()
            .unwrap()
            .iter()
            .all(|invocation| invocation["arguments"][0] != "pull"));
        assert_eq!(directory.git(&["rev-parse", "HEAD"]), before);
        assert_eq!(directory.git(&["rev-parse", "refs/heads/other"]), before);
    }
}

#[test]
fn pull_expected_branch_accepts_a_matching_full_ref_and_rejects_other_operations() {
    let directory = SetupDirectory::new("pull-matching-branch");
    directory.data("git.initialize", json!({}));
    directory.git(&[
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "--allow-empty",
        "--no-gpg-sign",
        "-m",
        "initial",
    ]);
    directory.git(&["branch", "-M", "topic"]);
    directory.git(&["clone", "--bare", ".", "origin.git"]);
    directory.git(&[
        "remote",
        "add",
        "origin",
        directory.0.join("origin.git").to_str().unwrap(),
    ]);
    directory.git(&["fetch", "origin"]);
    directory.git(&["branch", "--set-upstream-to=origin/topic", "topic"]);
    let fetched_head = directory.git(&["rev-parse", "refs/remotes/origin/topic"]);
    for mode in ["ffOnly", "merge", "rebase"] {
        let result = directory.data(
            "git.write",
            json!({
                "operation": "pull", "mode": mode, "expectedBranch": "refs/heads/topic"
            }),
        );
        assert_eq!(result["exitCode"], 0, "{result}");
        assert_eq!(
            result["arguments"][0],
            if mode == "rebase" { "rebase" } else { "merge" }
        );
        assert_eq!(
            result["arguments"].as_array().unwrap().last().unwrap(),
            &json!(fetched_head.trim())
        );
        assert!(result["invocations"]
            .as_array()
            .unwrap()
            .iter()
            .all(|invocation| invocation["arguments"][0] != "pull"
                && invocation["arguments"][0] != "fetch"));
    }
    let invalid = directory.call(
        "git.write",
        json!({
            "operation": "fetch", "expectedBranch": "refs/heads/topic"
        }),
    );
    assert_eq!(invalid["ok"], false, "{invalid}");
    let short_ref = directory.call(
        "git.write",
        json!({
            "operation": "pull", "expectedBranch": "topic"
        }),
    );
    assert_eq!(short_ref["ok"], false, "{short_ref}");
}
