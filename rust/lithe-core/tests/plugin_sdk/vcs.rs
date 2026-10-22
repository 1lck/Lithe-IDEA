//! End-to-end scenario of a VCS provider written with the Node.js SDK
//! (`sdk/node/examples/sample-vcs`), driven through the JSON commands a host
//! sends: root detection from the manifest, the launch plan, the `litheVcs`
//! negotiation, every operation through `lsp.vcsRequest` with its reply
//! decoded by `vcs.decodeReply`, a provider error code, and the execution
//! report a provider's tool run produces.

use super::{core, listing, repository_path, Fixture, Session};
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

const VCS: &str = "sample";

/// Revision 1 of the working copy, as the sample stores it.
fn initial_revision() -> Value {
    json!([{
        "id": "1",
        "author": "sample",
        "date": "2026-01-01T00:00:00.000Z",
        "message": "Initial",
        "files": { "a.txt": "one\ntwo\n", "docs/b.txt": "bee\n" },
        "changes": [
            { "path": "a.txt", "status": "added" },
            { "path": "docs/b.txt", "status": "added" }
        ]
    }])
}

/// One provider session with what it negotiated and the host's resolved tool.
struct Provider<'a> {
    session: Session,
    capabilities: Value,
    root: &'a Path,
    tool: &'a str,
    sequence: usize,
}

impl Provider<'_> {
    /// Sends one operation and returns its `requestCompleted` event.
    fn send(&mut self, operation: &str, arguments: &Value) -> Value {
        self.sequence += 1;
        let operation_id = format!("{operation}-{}", self.sequence);
        core(
            "lsp.vcsRequest",
            json!({
                "sessionId": self.session.id,
                "operationId": operation_id,
                "vcs": VCS,
                "operation": operation,
                "root": self.root,
                "tool": self.tool,
                "arguments": arguments,
            }),
        );
        self.session.completion(&operation_id)
    }

    /// Sends one operation and returns the reply as `vcs.decodeReply` normalizes it.
    fn request(&mut self, operation: &str, arguments: Value) -> Value {
        let completed = self.send(operation, &arguments);
        assert!(
            completed.get("error").is_none(),
            "{operation} failed: {completed}"
        );
        let decoded = core(
            "vcs.decodeReply",
            json!({
                "operation": operation,
                "capabilities": self.capabilities,
                "request": arguments,
                "reply": completed["result"]["value"],
            }),
        );
        assert_eq!(decoded["status"], "ok", "{operation}: {decoded}");
        decoded["result"].clone()
    }

    /// `(path, status, oldPath)` of each change, in Core's order.
    fn changes(&mut self) -> Vec<(String, String, Value)> {
        self.request("status", json!({}))["changes"]
            .as_array()
            .expect("decoded changes")
            .iter()
            .map(|change| {
                (
                    change["path"].as_str().unwrap().to_string(),
                    change["status"].as_str().unwrap().to_string(),
                    change["oldPath"].clone(),
                )
            })
            .collect()
    }
}

fn change(path: &str, status: &str) -> (String, String, Value) {
    (path.to_string(), status.to_string(), Value::Null)
}

fn revision_ids(entries: &Value) -> Vec<String> {
    entries
        .as_array()
        .expect("entries")
        .iter()
        .map(|entry| entry["revision"]["id"].as_str().unwrap().to_string())
        .collect()
}

/// Runs the scenario with `node` as both the provider's runtime and the
/// sample VCS's "client".
pub fn run_vcs_scenario(node: &str) {
    let package = repository_path("sdk/node/examples/sample-vcs");
    let manifest: Value =
        serde_json::from_slice(&fs::read(package.join("plugin.json")).expect("sample manifest"))
            .expect("sample manifest JSON");
    let plugin_id = manifest["id"].as_str().expect("plugin ID").to_string();
    let package_before = listing(&package);
    let validated = core(
        "plugins.declarative.validate",
        json!({ "manifest": manifest }),
    );
    assert_eq!(validated["status"], "ok", "{validated}");

    let fixture = Fixture::new("vcs");
    let workspace = fixture.workspace();
    fs::create_dir_all(workspace.join(".samplevcs")).expect("metadata directory");
    fs::create_dir_all(workspace.join("docs")).expect("docs directory");
    fs::write(
        workspace.join(".samplevcs/revisions.json"),
        initial_revision().to_string(),
    )
    .expect("revisions");
    fs::write(workspace.join("a.txt"), "one\ntwo\n").expect("a.txt");
    fs::write(workspace.join("docs/b.txt"), "bee\n").expect("b.txt");

    // Core finds the working copy from the manifest's marker alone.
    let detection = core(
        "vcs.detectRoots",
        json!({ "workspaceRoot": workspace, "plugins": [{ "manifest": manifest }] }),
    );
    assert_eq!(detection["status"], "ok", "{detection}");
    let root = detection["detection"]["roots"]
        .as_array()
        .expect("roots")
        .iter()
        .find(|root| root["vcs"] == VCS)
        .unwrap_or_else(|| panic!("no sample root: {detection}"))
        .clone();
    assert_eq!(root["id"], "");
    assert_eq!(root["path"], json!(workspace));

    // The host starts the provider from the plan Core expands.
    let plan = core(
        "plugins.declarative.languageServerLaunchPlan",
        json!({
            "manifest": manifest,
            "vcsProviderID": VCS,
            "request": {
                "pluginDirectory": package,
                "stateDirectory": fixture.root.join("state"),
                "workspaceStateDirectory": fixture.root.join("workspace-state"),
                "architecture": if cfg!(target_arch = "aarch64") { "arm64" } else { "x86_64" },
            }
        }),
    );
    assert_eq!(plan["status"], "ok", "{plan}");
    let plan = &plan["plan"];
    assert_eq!(plan["vcsProvider"]["vcs"], VCS, "{plan}");
    assert_eq!(plan["launch"]["tool"], "node");
    let arguments = plan["arguments"].as_array().expect("arguments").clone();
    let mut session = Session::start_provider(
        &format!("vcsProvider:{plugin_id}:{VCS}"),
        &plugin_id,
        node,
        &arguments,
        &workspace,
    );

    // The provider negotiated one capability per handler it declared.
    let negotiated = session.await_event("the VCS negotiation", |event| {
        event["type"] == "vcsProvider"
    });
    assert_eq!(negotiated["result"]["vcs"], VCS, "{negotiated}");
    let capabilities = negotiated["result"]["capabilities"].clone();
    assert_eq!(
        capabilities,
        json!({
            "annotate": 1, "baseContent": 1, "checkin": 1, "cleanup": 1, "conflicts": 1,
            "fileHistory": 1, "fileOperations": 1, "history": 1, "rollback": 1, "status": 1,
            "update": 1
        })
    );
    let mut provider = Provider {
        session,
        capabilities,
        root: &workspace,
        tool: node,
        sequence: 0,
    };

    // Local edits come back as one sorted status snapshot.
    fs::write(workspace.join("a.txt"), "one\nTWO\nthree\n").expect("edit a.txt");
    fs::remove_file(workspace.join("docs/b.txt")).expect("remove b.txt");
    fs::write(workspace.join("c.txt"), "sea\n").expect("c.txt");
    assert_eq!(
        provider.changes(),
        [
            change("a.txt", "modified"),
            change("c.txt", "unversioned"),
            change("docs/b.txt", "missing"),
        ]
    );
    provider.request(
        "fileOperation",
        json!({ "kind": "add", "paths": ["c.txt"] }),
    );
    assert_eq!(provider.changes()[1], change("c.txt", "added"));
    assert_eq!(
        provider.request("baseContent", json!({ "path": "a.txt" })),
        json!({ "content": "one\ntwo\n", "binary": false })
    );

    // A provider's contract code reaches the host; anything else would not.
    fs::write(workspace.join(".samplevcs/lock"), "").expect("lock");
    let locked = provider.send(
        "checkin",
        &json!({ "paths": ["a.txt", "c.txt"], "message": "Second" }),
    );
    assert_eq!(
        locked["error"]["code"], "vcs.workingCopy.locked",
        "{locked}"
    );
    // Cleanup runs the tool, which the session reports for the console.
    provider.request("cleanup", json!({}));
    let execution = provider
        .session
        .await_event("the execution report", |event| {
            event["type"] == "log" && event["message"] == "lithe/vcs/execution"
        });
    let report: Value = serde_json::from_str(execution["detail"].as_str().expect("report detail"))
        .expect("report JSON");
    assert_eq!(report["command"], json!([node, "--version"]), "{report}");
    assert_eq!(report["exitCode"], 0, "{report}");

    let checked_in = provider.request(
        "checkin",
        json!({ "paths": ["c.txt", "a.txt"], "message": "Second" }),
    );
    assert_eq!(
        checked_in["revision"],
        json!({ "id": "2", "display": "r2", "kind": "number" })
    );
    assert_eq!(provider.changes(), [change("docs/b.txt", "missing")]);
    provider.request("rollback", json!({ "paths": ["docs/b.txt"] }));
    assert_eq!(
        fs::read_to_string(workspace.join("docs/b.txt")).expect("restored b.txt"),
        "bee\n"
    );
    assert!(provider.changes().is_empty());

    // History pages keep the provider's order and resume from its cursor.
    let first = provider.request("history", json!({ "limit": 1 }));
    assert_eq!(revision_ids(&first["entries"]), ["2"]);
    assert_eq!(first["nextCursor"], "1");
    let second = provider.request("history", json!({ "limit": 1, "cursor": "1" }));
    assert_eq!(revision_ids(&second["entries"]), ["1"]);
    assert_eq!(second["nextCursor"], Value::Null);
    let file_history = provider.request("fileHistory", json!({ "path": "c.txt" }));
    assert_eq!(revision_ids(&file_history["entries"]), ["2"]);
    let annotation = provider.request("annotate", json!({ "path": "a.txt" }));
    assert_eq!(annotation["lines"], json!(["1", "2", "2"]));
    assert_eq!(revision_ids(&annotation["revisions"]), ["1", "2"]);
    assert_eq!(
        provider.request("update", json!({})),
        json!({ "revision": { "id": "2", "display": "r2", "kind": "number" }, "conflicts": [] })
    );

    // A tracked move is reported as a rename from its source.
    provider.request(
        "fileOperation",
        json!({ "kind": "move", "from": "c.txt", "to": "docs/c.txt" }),
    );
    assert_eq!(
        provider.changes(),
        [(
            "docs/c.txt".to_string(),
            "renamed".to_string(),
            json!("c.txt")
        )]
    );
    provider.request("resolve", json!({ "paths": ["docs/c.txt"] }));
    // Rolling the move back restores the source and clears the rename.
    provider.request("rollback", json!({ "paths": ["docs/c.txt"] }));
    assert!(!workspace.join("docs/c.txt").exists());
    assert_eq!(
        fs::read_to_string(workspace.join("c.txt")).expect("restored c.txt"),
        "sea\n"
    );
    assert!(provider.changes().is_empty());

    provider.session.stop();
    drop(provider);
    assert!(
        listing(&package) == package_before,
        "the plugin package changed at runtime"
    );
}
