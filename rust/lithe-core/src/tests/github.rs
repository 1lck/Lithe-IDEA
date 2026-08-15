use crate::execute_json;
use serde_json::{json, Value};

fn execute(command: &str, payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &json!({"id": "github-test", "command": command, "payload": payload}).to_string(),
    ))
    .expect("GitHub Core response should be JSON")
}

#[test]
fn parses_https_and_ssh_github_remotes() {
    for (remote, owner, name) in [
        ("https://github.com/openai/codex.git", "openai", "codex"),
        ("git@github.com:openai/codex.git", "openai", "codex"),
        ("ssh://git@github.com/openai/codex", "openai", "codex"),
    ] {
        let response = execute("github.parseRemote", json!({"remoteUrl": remote}));
        assert_eq!(response["ok"], true, "{response:?}");
        assert_eq!(response["data"]["owner"], owner);
        assert_eq!(response["data"]["name"], name);
    }
}

#[test]
fn rejects_remote_components_that_could_change_a_planned_path() {
    for remote in [
        "https://github.com/../codex",
        "https://github.com/openai/..",
    ] {
        let response = execute("github.parseRemote", json!({"remoteUrl": remote}));
        assert_eq!(response["ok"], false, "{response:?}");
        assert_eq!(response["error"]["code"], "invalid_request");
    }
}

#[test]
fn request_plan_keeps_network_and_credentials_platform_owned() {
    let response = execute(
        "github.requestPlan",
        json!({
            "operation": "createPullRequest",
            "repository": {"owner": "openai", "name": "codex"},
            "title": "Add deterministic GitHub contracts",
            "body": "Ready for review",
            "head": "feature/github",
            "base": "main",
            "draft": true
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["host"], "api");
    assert_eq!(response["data"]["method"], "POST");
    assert_eq!(response["data"]["path"], "/repos/openai/codex/pulls");
    assert_eq!(response["data"]["requiresAuthentication"], true);
    let body: Value = serde_json::from_str(response["data"]["body"].as_str().unwrap()).unwrap();
    assert_eq!(body["head"], "feature/github");
    assert_eq!(body["draft"], true);
}

#[test]
fn request_plan_lists_repository_branches() {
    let response = execute(
        "github.requestPlan",
        json!({
            "operation": "listBranches",
            "repository": {"owner": "openai", "name": "codex"}
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["host"], "api");
    assert_eq!(response["data"]["method"], "GET");
    assert_eq!(response["data"]["path"], "/repos/openai/codex/branches");
    assert_eq!(response["data"]["query"]["per_page"], "100");
    assert_eq!(response["data"]["requiresAuthentication"], true);
}

#[test]
fn request_plan_compares_encoded_branch_names() {
    let response = execute(
        "github.requestPlan",
        json!({
            "operation": "compareBranches",
            "repository": {"owner": "openai", "name": "codex"},
            "base": "release/2026.08",
            "head": "feature/中文"
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["method"], "GET");
    assert_eq!(
        response["data"]["path"],
        "/repos/openai/codex/compare/release%2F2026.08...feature%2F%E4%B8%AD%E6%96%87"
    );
    assert_eq!(response["data"]["requiresAuthentication"], true);
}

#[test]
fn device_flow_requests_the_scope_needed_for_pull_request_mutations() {
    let response = execute(
        "github.requestPlan",
        json!({"operation": "deviceCode", "clientId": "fake-client-id"}),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    let body: Value = serde_json::from_str(response["data"]["body"].as_str().unwrap()).unwrap();
    assert_eq!(body["scope"], "repo read:user");
}

#[test]
fn normalizes_pull_requests_with_deterministic_labels_and_assignees() {
    let raw = json!([{
        "number": 7,
        "title": "GitHub integration",
        "body": null,
        "state": "open",
        "draft": false,
        "html_url": "https://github.com/openai/codex/pull/7",
        "user": {"login": "octocat", "html_url": "https://github.com/octocat", "avatar_url": "https://avatars.example/octocat"},
        "head": {"ref": "feature", "repo": {"full_name": "octocat/codex"}},
        "base": {"ref": "main", "repo": {"full_name": "openai/codex"}},
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-02T00:00:00Z",
        "comments": 2,
        "labels": [{"name": "zeta", "color": "ffffff"}, {"name": "alpha", "color": "000000"}],
        "assignees": [
            {"login": "zoe", "html_url": "https://github.com/zoe", "avatar_url": null},
            {"login": "amy", "html_url": "https://github.com/amy", "avatar_url": null}
        ]
    }]);
    let response = execute(
        "github.normalizeResponse",
        json!({"operation": "listPullRequests", "status": 200, "body": raw.to_string()}),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"][0]["body"], "");
    assert_eq!(response["data"][0]["labels"][0]["name"], "alpha");
    assert_eq!(response["data"][0]["assignees"][0]["login"], "amy");
}

#[test]
fn normalizes_branch_list_deterministically() {
    let raw = json!([
        {"name": "zeta"},
        {"name": "alpha"},
        {"name": "alpha"}
    ]);
    let response = execute(
        "github.normalizeResponse",
        json!({"operation": "listBranches", "status": 200, "body": raw.to_string()}),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(
        response["data"],
        json!([{"name": "alpha"}, {"name": "zeta"}])
    );
}

#[test]
fn normalizes_branch_comparison_for_ai_generation() {
    let raw = json!({
        "commits": [
            {"sha": "abc123", "commit": {"message": "Add PR generation\n\nWith tests"}}
        ],
        "files": [
            {
                "filename": "Sources/Z.swift",
                "status": "modified",
                "additions": 2,
                "deletions": 1,
                "patch": "@@ -1 +1 @@\n-old\n+new"
            },
            {
                "filename": "Sources/A.swift",
                "status": "added",
                "additions": 3,
                "deletions": 0
            }
        ]
    });
    let response = execute(
        "github.normalizeResponse",
        json!({"operation": "compareBranches", "status": 200, "body": raw.to_string()}),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["commits"][0]["sha"], "abc123");
    assert_eq!(response["data"]["files"][0]["path"], "Sources/A.swift");
    assert_eq!(
        response["data"]["files"][1]["patch"],
        "@@ -1 +1 @@\n-old\n+new"
    );
}

#[test]
fn device_flow_pending_and_rate_limit_states_are_explicit() {
    for (error, status) in [
        ("authorization_pending", "pending"),
        ("slow_down", "slowDown"),
    ] {
        let response = execute(
            "github.normalizeResponse",
            json!({
                "operation": "deviceToken",
                "status": 200,
                "body": json!({"error": error, "interval": 10}).to_string()
            }),
        );
        assert_eq!(response["ok"], true, "{response:?}");
        assert_eq!(response["data"]["status"], status);
    }
}

#[test]
fn github_http_failures_use_stable_error_categories_without_response_bodies_in_details() {
    let response = execute(
        "github.normalizeResponse",
        json!({
            "operation": "listPullRequests",
            "status": 403,
            "body": json!({"message": "Resource not accessible by integration"}).to_string()
        }),
    );
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "permission_denied");
    assert_eq!(response["error"]["details"], "httpStatus=403");
}
