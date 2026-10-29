//! Real framed-host integration coverage for remote workspace semantic engines.

use super::*;
use serde_json::{json, Value};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;

const STEP: Duration = Duration::from_secs(10);

/// Owns socket deadlines, registered identity, server completion and scratch data.
struct HostFixture {
    id: String,
    root: std::path::PathBuf,
    socket: UnixStream,
    done: mpsc::Receiver<()>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl HostFixture {
    fn new() -> Self {
        let root = crate::tests::support::temporary_root("remote-git-integration");
        std::fs::create_dir_all(root.join("host")).unwrap();
        std::fs::create_dir_all(root.join("placeholder")).unwrap();
        let root = root.canonicalize().unwrap();
        let (client, server) = UnixStream::pair().unwrap();
        server.set_read_timeout(Some(STEP)).unwrap();
        server.set_write_timeout(Some(STEP)).unwrap();
        let socket = client.try_clone().unwrap();
        let (finished, done) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = lithe_remote::server::serve_stdio(server.try_clone().unwrap(), server);
            let _ = finished.send(());
            result.unwrap();
        });
        let (session, events) = RemoteSession::from_streams(
            client.try_clone().unwrap(),
            client,
            &ConnectOptions {
                handshake_timeout: STEP,
                ..ConnectOptions::default()
            },
        )
        .unwrap();
        drop(events);
        let id = nonce();
        registry().lock().unwrap().insert(
            id.clone(),
            Arc::new(Connection {
                session,
                git_tool: Mutex::new(None),
                transport: ConnectionTransport::InProcess,
            }),
        );
        Self {
            id,
            root,
            socket,
            done,
            worker: Some(worker),
        }
    }

    fn call(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.root.join("placeholder"));
        self.request(command, payload)
    }

    fn request(&self, command: &str, payload: Value) -> Value {
        self.request_at(&self.root.join("host"), command, payload)
    }

    fn request_at(&self, remote_root: &std::path::Path, command: &str, payload: Value) -> Value {
        let response: Value = serde_json::from_str(&crate::execute_json(&json!({
            "id": nonce(), "command": command, "timeoutMilliseconds": 30_000,
            "remoteWorkspace": {"sessionId": self.id, "localRoot": self.root.join("placeholder"), "remoteRoot": remote_root},
            "payload": payload,
        }).to_string())).unwrap();
        assert_eq!(response["ok"], true, "{command}: {response}");
        assert!(
            response["data"]["operationError"].is_null(),
            "{command}: {response}"
        );
        response["data"].clone()
    }

    fn git(&self, args: &[&str]) -> Value {
        let data = self.call("git.command", json!({"arguments": args}));
        assert_eq!(data["exitCode"], 0, "{args:?}: {data}");
        data
    }
}

#[test]
fn remote_build_detects_host_models_normalizes_diagnostics_and_invalidates_sync() {
    let host = HostFixture::new();
    let root = host.root.join("host");
    let placeholder = host.root.join("placeholder");
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(
        root.join("Cargo.toml"),
        "[package]\nname = \"host-only\"\nversion = \"1.0.0\"\n[features]\nfast = []\n",
    )
    .unwrap();
    let manifest: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/build-static-file.plugin.json"
    )))
    .unwrap();
    let detection = host.request(
        "build.detect",
        json!({"workspaceRoot": placeholder,
        "plugins": [{"manifest": manifest}], "options": {}}),
    );
    assert_eq!(detection["status"], "ok", "{detection}");
    let instance = &detection["detection"]["instances"][0];
    assert_eq!(instance["id"], "cargo:.", "{detection}");
    assert_eq!(
        instance["model"]["projects"][0]["name"], "host-only",
        "{detection}"
    );
    let call = |command, request| {
        host.request(
            command,
            json!({"manifest": manifest,
        "buildSystemID": "cargo", "workspaceRoot": placeholder, "request": request}),
        )
    };
    let diagnostics = call(
        "build.decodeDiagnostics",
        json!({"workspaceRoot": placeholder, "root": ".",
        "output": format!("{}/src/main.rs:2:3: error: remote diagnostic", root.display())}),
    );
    assert_eq!(
        diagnostics["diagnostics"][0]["path"], "src/main.rs",
        "{diagnostics}"
    );
    let sync = || {
        call(
            "build.syncFingerprint",
            json!({"workspaceRoot": placeholder, "root": ".", "projects": ["."], "options": {}}),
        )
    };
    let before = sync();
    std::fs::write(
        root.join("Cargo.toml"),
        "[package]\nname = \"changed\"\nversion = \"1.0.0\"\n",
    )
    .unwrap();
    let after = sync();
    assert_ne!(before, after, "{before}");
    // Reported symlinks must not expose host paths outside this workspace.
    std::fs::write(host.root.join("outside.rs"), "private").unwrap();
    std::os::unix::fs::symlink(host.root.join("outside.rs"), root.join("src/link.rs")).unwrap();
    let escaped = call(
        "build.decodeDiagnostics",
        json!({"workspaceRoot": placeholder, "root": ".",
        "output": format!("{}/src/link.rs:1:1: error: escaped", root.display())}),
    );
    assert_eq!(escaped["diagnostics"], json!([]), "{escaped}");
    assert_eq!(std::fs::read_dir(placeholder).unwrap().count(), 0);
}

#[test]
fn remote_maven_build_reads_reactor_and_current_host_test_reports() {
    let host = HostFixture::new();
    let root = host.root.join("host");
    let placeholder = host.root.join("placeholder");
    std::fs::create_dir_all(root.join("child/target/surefire-reports")).unwrap();
    std::fs::write(root.join("pom.xml"), "<project><modelVersion>4.0.0</modelVersion><groupId>fixture</groupId><artifactId>parent</artifactId><version>1</version><packaging>pom</packaging><modules><module>child</module></modules></project>").unwrap();
    std::fs::write(root.join("child/pom.xml"), "<project><modelVersion>4.0.0</modelVersion><parent><groupId>fixture</groupId><artifactId>parent</artifactId><version>1</version></parent><artifactId>child</artifactId></project>").unwrap();
    std::fs::write(root.join("child/target/surefire-reports/TEST-Fixture.xml"), "<testsuite name=\"Fixture\" tests=\"1\"><testcase classname=\"Fixture\" name=\"hostTest\" time=\"0.25\"/></testsuite>").unwrap();
    let manifest: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/build-host-integration.plugin.json"
    )))
    .unwrap();
    let detected = host.request(
        "build.detect",
        json!({"workspaceRoot": placeholder,
        "plugins": [{"manifest": manifest}], "options": {}}),
    );
    assert_eq!(detected["status"], "ok", "{detected}");
    let projects = detected["detection"]["instances"][0]["model"]["projects"]
        .as_array()
        .unwrap();
    assert!(
        projects.iter().any(|project| project["path"] == "child"),
        "{detected}"
    );
    let call = |not_before| {
        host.request("build.decodeTestResults", json!({"manifest": manifest,
        "buildSystemID": "maven", "workspaceRoot": placeholder, "request": {"workspaceRoot": placeholder,
            "root": ".", "projects": [".", "child"], "output": "", "notBeforeMillis": not_before}}))
    };
    let current = call(0);
    assert_eq!(current["status"], "ok", "{current}");
    assert!(current.to_string().contains("hostTest"), "{current}");
    let stale = call(u64::MAX / 2);
    assert!(!stale.to_string().contains("hostTest"), "{stale}");
}

impl Drop for HostFixture {
    fn drop(&mut self) {
        let _ = crate::execute_json(&json!({
            "id": nonce(), "command": "workspace.searchIndex.invalidate", "timeoutMilliseconds": 1_000,
            "remoteWorkspace": {"sessionId": self.id, "localRoot": self.root.join("placeholder"), "remoteRoot": self.root.join("host")},
            "payload": {"root": self.root.join("placeholder")}
        }).to_string());
        if let Some(connection) = registry().lock().unwrap().remove(&self.id) {
            connection.close();
        }
        let _ = self.socket.shutdown(Shutdown::Both);
        if self.done.recv_timeout(STEP + STEP).is_ok() {
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
        } else {
            if !std::thread::panicking() {
                panic!("remote test host did not finish within its cleanup deadline");
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn remote_search_reads_host_content_and_applies_incremental_updates_without_local_cache_leaks() {
    let host = HostFixture::new();
    std::fs::create_dir(host.root.join("host/src")).unwrap();
    std::fs::write(
        host.root.join("host/src/RemoteName.java"),
        "class RemoteName { void remoteMethod() {} }\n",
    )
    .unwrap();
    // Warm the same URL locally first: host identity must separate its empty index.
    let local: Value = serde_json::from_str(&crate::execute_json(
        &json!({
            "id": nonce(), "command": "workspace.searchEverywhere",
            "payload": {"root": host.root.join("placeholder"), "query": "RemoteName"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(local["ok"], true, "{local}");
    assert_eq!(local["data"]["matches"], json!([]));
    let found = host.call("workspace.searchEverywhere", json!({"query": "RemoteName"}));
    for kind in ["file", "type", "content"] {
        assert!(
            found["matches"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["kind"] == kind && item["path"] == "src/RemoteName.java"),
            "{kind}: {found}"
        );
    }
    std::fs::write(
        host.root.join("host/src/RemoteName.java"),
        "class ChangedName {}\n",
    )
    .unwrap();
    host.call(
        "workspace.searchIndex.update",
        json!({"paths": ["src/RemoteName.java"]}),
    );
    let changed = host.call("workspace.search", json!({"query": "ChangedName"}));
    assert!(
        changed["matches"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["path"] == "src/RemoteName.java"),
        "{changed}"
    );
    let missing = host.call("workspace.search", json!({"query": "remoteMethod"}));
    assert_eq!(missing["matches"], json!([]));
    let read = host.call("file.read", json!({"path": "src/RemoteName.java"}));
    assert_eq!(read["text"], "class ChangedName {}\n");
    host.call(
        "file.write",
        json!({"path": "written.txt", "text": "remote write\n"}),
    );
    assert_eq!(
        std::fs::read(host.root.join("host/written.txt")).unwrap(),
        b"remote write\n"
    );
    assert_eq!(
        std::fs::read_dir(host.root.join("placeholder"))
            .unwrap()
            .count(),
        0
    );
    let local: Value = serde_json::from_str(&crate::execute_json(
        &json!({
            "id": nonce(), "command": "workspace.searchIndex.invalidate",
            "payload": {"root": host.root.join("placeholder")}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(local["ok"], true, "{local}");
}

#[test]
fn real_remote_git_status_stage_commit_and_history_never_touch_the_placeholder() {
    let host = HostFixture::new();
    host.git(&["init", "-q", "-b", "main"]);
    host.git(&["config", "user.name", "Lithe Remote Test"]);
    host.git(&["config", "user.email", "remote@example.invalid"]);
    std::fs::write(host.root.join("host/remote.txt"), b"host-only\n").unwrap();
    let status = host.call("git.status", json!({}));
    assert_eq!(status["repositoryRoot"], ".");
    assert_eq!(status["changes"][0]["path"], "remote.txt");
    let staged = host.call(
        "git.write",
        json!({"operation": "stage", "paths": ["remote.txt"]}),
    );
    assert_eq!(staged["exitCode"], 0, "{staged}");
    host.git(&["commit", "-qm", "first remote commit"]);
    std::fs::write(host.root.join("host/remote.txt"), b"changed remotely\n").unwrap();
    host.git(&["add", "remote.txt"]);
    host.git(&["commit", "-qm", "second remote commit"]);
    let first = host.call("git.historyPage", json!({"limit": 1}));
    assert_eq!(first["commits"][0]["subject"], "second remote commit");
    let cursor = first["nextCursor"].as_str().expect("a second page");
    let second = host.call("git.historyPage", json!({"limit": 1, "cursor": cursor}));
    assert_eq!(second["commits"][0]["subject"], "first remote commit");
    if let Some(cursor) = second["nextCursor"].as_str() {
        host.call("git.historyCursorClose", json!({"cursor": cursor}));
    }
    assert_eq!(
        std::fs::read_dir(host.root.join("placeholder"))
            .unwrap()
            .count(),
        0
    );
    assert!(host.root.join("host/.git/index").is_file());
}

#[test]
fn remote_parent_repository_discovery_keeps_identity_for_status_and_stage() {
    discovered_repository_keeps_host_identity(false);
}

#[test]
fn remote_symlink_repository_discovery_keeps_identity_for_status_and_stage() {
    discovered_repository_keeps_host_identity(true);
}

fn discovered_repository_keeps_host_identity(symlink: bool) {
    let host = HostFixture::new();
    host.git(&["init", "-q", "-b", "main"]);
    let repository = host.root.join("host");
    std::fs::write(repository.join("remote.txt"), "remote only\n").unwrap();
    let remote_root = if symlink {
        let link = host.root.join("opened-link");
        std::os::unix::fs::symlink(&repository, &link).unwrap();
        link
    } else {
        let child = repository.join("src");
        std::fs::create_dir(&child).unwrap();
        child
    };
    let placeholder = host.root.join("placeholder");
    let host_paths = host.root.join("placeholder.lithe-remote-host");
    let expected = host_paths.join(repository.strip_prefix("/").unwrap());
    let discovered = host.request_at(
        &remote_root,
        "workspace.repositories",
        json!({"root": placeholder}),
    );
    assert_eq!(discovered["repositories"], json!([{"path": expected}]));
    let root = discovered["repositories"][0]["path"].as_str().unwrap();

    // Simulate the bridge's next request using only the returned repository URL.
    // A real local repository at that URL catches any placeholder fallback.
    std::fs::create_dir_all(&expected).unwrap();
    let local_git = |arguments: &[&str]| {
        let response: Value = serde_json::from_str(&crate::execute_json(
            &json!({
                "id": nonce(), "command": "git.command", "timeoutMilliseconds": 10_000,
                "payload": {"root": expected, "arguments": arguments}
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["data"]["exitCode"], 0, "{response}");
    };
    local_git(&["init", "-q", "-b", "main"]);
    std::fs::write(expected.join("local.txt"), "local sentinel\n").unwrap();
    local_git(&["add", "local.txt"]);
    let index = std::fs::read(expected.join(".git/index")).unwrap();
    let routed = |command, payload| {
        assert!(std::path::Path::new(root).starts_with(&host_paths));
        host.request_at(&remote_root, command, payload)
    };
    let status = routed(
        "git.status",
        json!({"root": root, "repositoryRoots": [root]}),
    );
    assert_eq!(status["changes"][0]["path"], "remote.txt", "{status}");
    let context = routed("git.watchContext", json!({"root": root}));
    assert_eq!(context["repositoryRoot"], json!(expected));
    assert_eq!(context["gitCommonDirectory"], json!(expected.join(".git")));
    let staged = routed(
        "git.write",
        json!({"root": root, "operation": "stage", "paths": ["remote.txt"]}),
    );
    assert_eq!(staged["exitCode"], 0, "{staged}");
    assert_eq!(
        host.git(&["diff", "--cached", "--name-only"])["stdout"],
        "remote.txt\n"
    );
    assert_eq!(std::fs::read(expected.join(".git/index")).unwrap(), index);
    assert_eq!(
        std::fs::read_to_string(expected.join("local.txt")).unwrap(),
        "local sentinel\n"
    );
    assert_eq!(std::fs::read_dir(placeholder).unwrap().count(), 0);
}

#[test]
fn remote_git_snapshot_selected_commit_and_unsaved_line_history_preserve_the_real_index() {
    let host = HostFixture::new();
    host.git(&["init", "-q", "-b", "main"]);
    host.git(&["config", "user.name", "Lithe Remote Test"]);
    host.git(&["config", "user.email", "remote@example.invalid"]);
    std::fs::write(host.root.join("host/selected.txt"), b"one\nbase\n").unwrap();
    std::fs::write(host.root.join("host/unrelated.txt"), b"base\n").unwrap();
    host.git(&["add", "--all"]);
    host.git(&["commit", "-qm", "initial remote content"]);
    std::fs::write(host.root.join("host/selected.txt"), b"staged\nbase\n").unwrap();
    std::fs::write(host.root.join("host/unrelated.txt"), b"keep staged\n").unwrap();
    host.git(&["add", "--all"]);
    std::fs::write(host.root.join("host/selected.txt"), b"staged\nworktree\n").unwrap();
    let index = std::fs::read(host.root.join("host/.git/index")).unwrap();

    let snapshot = host.call(
        "git.diff",
        json!({"pathspecs": ["selected.txt"], "worktreeSnapshot": true}),
    );
    let patch = snapshot["patch"].as_str().unwrap();
    assert!(
        patch.contains("+staged") && patch.contains("+worktree"),
        "{snapshot}"
    );
    assert_eq!(
        std::fs::read(host.root.join("host/.git/index")).unwrap(),
        index
    );
    let committed = host.call(
        "git.write",
        json!({"operation": "commit", "paths": ["selected.txt"], "message": "selected remote content"}),
    );
    assert_eq!(committed["exitCode"], 0, "{committed}");
    assert_eq!(
        host.git(&["show", "HEAD:selected.txt"])["stdout"],
        "staged\nworktree\n"
    );
    assert_eq!(
        host.git(&["show", "HEAD:unrelated.txt"])["stdout"],
        "base\n"
    );
    assert_eq!(
        host.git(&["diff", "--cached", "--name-only"])["stdout"],
        "unrelated.txt\n"
    );

    let history = host.call(
        "git.lineHistory",
        json!({"path": "selected.txt", "content": "unsaved\nstaged\nworktree\n", "startLine": 3, "endLine": 3}),
    );
    assert_eq!(history["commits"][0]["subject"], "selected remote content");
    assert_eq!(history["unmappedLines"], json!([]));
    assert_eq!(
        std::fs::read(host.root.join("host/selected.txt")).unwrap(),
        b"staged\nworktree\n"
    );
    assert_eq!(
        std::fs::read_dir(host.root.join("placeholder"))
            .unwrap()
            .count(),
        0,
        "index and source snapshots must stay on the workspace host"
    );
    assert!(std::fs::read_dir(host.root.join("host/.git"))
        .unwrap()
        .all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("lithe-commit-")));
}

#[test]
fn remote_git_worktree_and_clone_destinations_use_the_host_filesystem() {
    let host = HostFixture::new();
    host.git(&["init", "-q", "-b", "main"]);
    host.git(&["config", "user.name", "Lithe Remote Test"]);
    host.git(&["config", "user.email", "remote@example.invalid"]);
    std::fs::write(host.root.join("host/tracked.txt"), b"host-only\n").unwrap();
    host.git(&["add", "tracked.txt"]);
    host.git(&["commit", "-qm", "remote worktree source"]);

    let destination = host.root.join("placeholder/.worktrees/topic with spaces");
    let created = host.call(
        "git.write",
        json!({"operation": "createWorktree", "destination": destination,
        "worktreeMode": "detached", "gitReference": {
            "kind": "local", "fullName": "refs/heads/main", "shortName": "main"
        }}),
    );
    assert_eq!(created["exitCode"], 0, "{created}");
    assert!(host
        .root
        .join("host/.worktrees/topic with spaces/.git")
        .is_file());
    let entries = host.call("git.worktrees", json!({}));
    let entry = entries["worktrees"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["path"] == json!(destination))
        .expect("worktree paths must retain the client's workspace identity");
    assert_eq!(entry["isCurrent"], false);
    assert_eq!(entry["isPrimary"], false);
    for operation in ["lockWorktree", "unlockWorktree", "removeWorktree"] {
        let result = host.call(
            "git.write",
            json!({"operation": operation, "destination": entry["path"]}),
        );
        assert_eq!(result["exitCode"], 0, "{operation}: {result}");
    }
    assert!(!host.root.join("host/.worktrees/topic with spaces").exists());

    let cloned = host.call(
        "git.write",
        json!({"operation": "clone", "remote": host.root.join("host"),
            "destination": host.root.join("placeholder/cloned project")}),
    );
    assert_eq!(cloned["exitCode"], 0, "{cloned}");
    assert_eq!(
        std::fs::read(host.root.join("host/cloned project/tracked.txt")).unwrap(),
        b"host-only\n"
    );
    assert_eq!(
        std::fs::read_dir(host.root.join("placeholder"))
            .unwrap()
            .count(),
        0,
        "remote Git must never create worktrees or clones in the placeholder"
    );
}

#[test]
fn remote_git_configuration_reports_the_host_executable_and_sources() {
    let host = HostFixture::new();
    host.git(&["init", "-q", "-b", "main"]);
    host.git(&["config", "fetch.prune", "true"]);
    let request = |command| -> Value {
        serde_json::from_str(&crate::execute_json(&json!({
            "id": nonce(), "command": command, "timeoutMilliseconds": 10_000,
            "remoteWorkspace": {"sessionId": host.id, "localRoot": host.root.join("placeholder"), "remoteRoot": host.root.join("host")},
            // This client override must not be used on the workspace host.
            "gitExecution": {"executable": "/fixture/client-only/git"},
            "payload": {"root": host.root.join("placeholder")}
        }).to_string())).unwrap()
    };
    let located = request("git.executable");
    assert_eq!(located["ok"], true, "{located}");
    let executable = located["data"]["executable"].as_str().unwrap();
    assert!(executable.starts_with('/'), "{located}");
    assert_ne!(executable, "/fixture/client-only/git");
    let inspected = request("git.executionInspect");
    assert_eq!(inspected["ok"], true, "{inspected}");
    assert_eq!(inspected["data"]["executable"], executable);
    assert_eq!(inspected["data"]["version"], located["data"]["version"]);
    let entry = inspected["data"]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["key"] == "fetch.prune" && entry["scope"] == "local")
        .unwrap();
    assert_eq!(entry["value"], "true");
    assert!(entry["origin"].as_str().unwrap().contains(".git/config"));
    // Disconnect after a cached resolution: errors must still propagate instead
    // of showing an empty setting or probing the client's selected executable.
    lookup(&host.id).unwrap().close();
    let closed = request("git.executable");
    assert_eq!(closed["ok"], false, "{closed}");
}

#[test]
fn remote_workspace_file_limits_preserve_host_content_and_report_disconnects() {
    use crate::remote::{workspace, workspace_io as fs};
    use std::io::Read;

    let host = HostFixture::new();
    let _deadline = crate::protocol::cancellation::Scope::begin(None, Some(10_000));
    let workspace = serde_json::from_value(json!({"sessionId": host.id,
        "localRoot": host.root.join("placeholder"), "remoteRoot": host.root.join("host")}))
    .unwrap();
    let _workspace = workspace::Scope::begin(Some(workspace), "git.status").unwrap();
    let local = host.root.join("placeholder");
    let remote = host.root.join("host");
    let content = vec![b'x'; 2 * 1024 * 1024 + 7];
    fs::write(local.join("file"), &content).unwrap();
    assert_eq!(fs::read(local.join("file")).unwrap(), content);

    let oversized = vec![b'y'; methods::MAX_TRANSFER_BYTES as usize + 1];
    assert_eq!(
        fs::write(local.join("file"), &oversized)
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::InvalidInput
    );
    assert_eq!(std::fs::read(remote.join("file")).unwrap(), content);

    // A sparse file checks the total materialization budget without a large
    // allocation, while streaming consumers can still inspect its contents.
    let sparse = std::fs::File::create(remote.join("large")).unwrap();
    sparse.set_len(32 * 1024 * 1024 + 1).unwrap();
    assert_eq!(
        fs::read(local.join("large")).unwrap_err().kind(),
        std::io::ErrorKind::InvalidData
    );
    let mut prefix = [1; 32];
    fs::File::open(local.join("large"))
        .unwrap()
        .read_exact(&mut prefix)
        .unwrap();
    assert_eq!(prefix, [0; 32]);

    assert!(!fs::try_exists(local.join("absent")).unwrap());
    assert!(fs::is_dir(&local).unwrap());
    lookup(&host.id).unwrap().close();
    assert!(fs::try_exists(local.join("file")).is_err());
    assert!(fs::is_dir(&local).is_err());
    assert_eq!(std::fs::read_dir(local).unwrap().count(), 0);
}

// `runConfig.inspect` has no remote adapter yet; this pins the shared traversal's
// remote contract so enabling it cannot read the placeholder or accept a dead link.
#[test]
fn shared_run_scan_reads_the_host_tree_and_stops_when_the_link_drops() {
    use crate::execution::workspace_scan::{scan_run_workspace, scan_with_reader};
    use crate::remote::{workspace, workspace_io as fs};

    let host = HostFixture::new();
    let _deadline = crate::protocol::cancellation::Scope::begin(None, Some(10_000));
    let local = host.root.join("placeholder");
    let remote = host.root.join("host");
    std::fs::create_dir_all(remote.join("service/api")).unwrap();
    std::fs::write(remote.join("package.json"), "{}").unwrap();
    std::fs::write(remote.join("service/pom.xml"), "<project/>").unwrap();
    let workspace = serde_json::from_value(
        json!({"sessionId": host.id, "localRoot": local, "remoteRoot": remote}),
    )
    .unwrap();
    let _workspace = workspace::Scope::begin(Some(workspace), "build.detect").unwrap();

    let scan = scan_run_workspace(&local, Some(3)).unwrap();
    let files: Vec<_> = scan
        .directories
        .iter()
        .map(|directory| {
            let relative = directory.path.strip_prefix(&local).unwrap();
            (
                relative.to_owned(),
                directory.files.iter().cloned().collect::<Vec<_>>(),
            )
        })
        .collect();
    assert_eq!(
        files,
        [
            (std::path::PathBuf::new(), vec!["package.json".to_owned()]),
            ("service".into(), vec!["pom.xml".to_owned()]),
            ("service/api".into(), Vec::new()),
        ]
    );
    assert!(scan.unreadable_paths.is_empty());
    assert_eq!(std::fs::read_dir(&local).unwrap().count(), 0);

    // A directory the host reports as unreadable is incomplete-scan evidence,
    // while the same session keeps serving its siblings.
    let unreadable = scan_with_reader(&local, Some(3), &|path| {
        if path.ends_with("service") {
            return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        }
        fs::read_dir(path)?
            .map(|entry| {
                let entry = entry?;
                let kind = entry.file_type()?;
                Ok((entry.path(), kind.is_dir(), kind.is_symlink()))
            })
            .collect()
    })
    .unwrap();
    assert_eq!(
        unreadable.unreadable_paths,
        std::collections::BTreeSet::from(["service".to_owned()])
    );

    // The link dropping after the root was listed must fail the whole scan,
    // not publish the root alone as if the project had no modules.
    let dropped = scan_with_reader(&local, Some(3), &|path| {
        let entries = fs::read_dir(path)?
            .map(|entry| {
                let entry = entry?;
                let kind = entry.file_type()?;
                Ok((entry.path(), kind.is_dir(), kind.is_symlink()))
            })
            .collect::<std::io::Result<Vec<_>>>();
        lookup(&host.id).unwrap().close();
        entries
    });
    assert!(
        dropped.is_err(),
        "a dropped link must not look like a smaller project"
    );
    assert!(scan_run_workspace(&local, Some(3)).is_err());
    assert_eq!(std::fs::read_dir(local).unwrap().count(), 0);
}

#[test]
fn captured_host_process_preserves_binary_streams_and_cleans_up_limit_failures() {
    let host = HostFixture::new();
    let capture = |argv: &[&str], timeout: u64, limit: usize| {
        let _scope = crate::protocol::cancellation::Scope::begin(None, Some(5_000));
        crate::remote::workspace_host::capture_process(
            serde_json::from_value(json!({
                "sessionId": host.id, "params": {"processId": 0, "argv": argv},
                "timeoutMilliseconds": timeout, "maxOutputBytes": limit
            }))
            .unwrap(),
        )
    };
    let output = capture(
        &[
            "/bin/sh",
            "-c",
            r"printf 'a\000b'; printf 'err' >&2; exit 7",
        ],
        2_000,
        6,
    )
    .unwrap();
    assert_eq!(
        lithe_remote::protocol::methods::decode_bytes(output["stdout"].as_str().unwrap()).unwrap(),
        b"a\0b"
    );
    assert_eq!(
        lithe_remote::protocol::methods::decode_bytes(output["stderr"].as_str().unwrap()).unwrap(),
        b"err"
    );
    assert_eq!(output["exitCode"], 7);
    assert!(matches!(
        capture(&["/bin/sh", "-c", "printf abcd; printf efgh >&2"], 2_000, 7)
            .unwrap_err()
            .code,
        ErrorCode::ProcessFailed
    ));
    // The long-lived child has no natural completion within the test deadline;
    // only the capture owner can terminate it when its budget expires.
    assert!(matches!(
        capture(&["/bin/sleep", "60"], 50, 128).unwrap_err().code,
        ErrorCode::TimedOut
    ));
    let connection = lookup(&host.id).unwrap();
    let deadline = Instant::now() + STEP;
    loop {
        let state = connection
            .session
            .request_value(methods::SERVER_STATE, json!({}), STEP)
            .unwrap();
        if state["processes"].as_array().unwrap().is_empty() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "capture leaked a host process: {state}"
        );
        std::thread::yield_now();
    }
}

#[test]
fn native_plugin_upload_streams_beyond_one_frame_and_rejects_mismatch_without_publication() {
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::PermissionsExt;
    let host = HostFixture::new();
    let source = host.root.join("native-package");
    let target = host.root.join("host/package");
    let content = vec![b'p'; methods::MAX_TRANSFER_BYTES as usize + 7];
    std::fs::write(&source, &content).unwrap();
    let digest = format!("{:x}", Sha256::digest(&content));
    let upload = |path: &std::path::Path, expected: &str| {
        let request = serde_json::from_value(json!({"sessionId": host.id,
            "sourcePath": source, "path": path, "sha256": expected, "mode": 0o500}))
        .unwrap();
        super::super::upload::upload(request)
    };
    let receipt = upload(&target, &digest).unwrap();
    assert_eq!(receipt["sha256"], digest);
    assert_eq!(receipt["size"], content.len());
    assert_eq!(std::fs::read(&target).unwrap(), content);
    assert_eq!(
        std::fs::metadata(&target).unwrap().permissions().mode() & 0o777,
        0o500
    );
    assert!(
        upload(&target, &digest).is_err(),
        "upload must not replace installed bytes"
    );
    let bad = host.root.join("host/bad");
    assert!(upload(&bad, &"0".repeat(64)).is_err());
    assert!(!bad.exists());
    assert_eq!(
        std::fs::read_dir(host.root.join("host")).unwrap().count(),
        1
    );
    assert_eq!(
        std::fs::read_dir(host.root.join("placeholder"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn plugin_stdio_uses_its_owned_host_and_reclaims_the_remote_process() {
    use crate::lsp::interface::process::{
        LspProcessLauncher, LspProcessSpec, SystemProcessLauncher,
    };
    use std::io::Read;
    let host = HostFixture::new();
    let workspace = serde_json::from_value(json!({"sessionId": host.id,
        "localRoot": host.root.join("placeholder"), "remoteRoot": host.root.join("host")}))
    .unwrap();
    let scope = super::super::workspace::Scope::begin(Some(workspace), "lsp.startServer").unwrap();
    let streams = SystemProcessLauncher
        .launch(LspProcessSpec {
            executable: "/bin/sh".into(),
            arguments: vec!["-c".into(), "pwd >&2; cat".into()],
            working_directory: host.root.join("placeholder"),
            environment: Default::default(),
        })
        .unwrap();
    // Later calls execute without a current workspace. The handle must retain
    // its original connection instead of choosing a local or newly selected host.
    drop(scope);
    let input = b"Content-Length: 2\r\n\r\n{}";
    streams.handle.write_input(input).unwrap();
    streams.handle.close_input();
    let (done, completed) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut output = streams.output;
        let mut errors = streams.errors;
        let result = output
            .read_to_end(&mut stdout)
            .and_then(|_| errors.read_to_end(&mut stderr));
        let _ = done.send((result, stdout, stderr));
    });
    let result = completed.recv_timeout(STEP);
    // Termination wakes readers on assertion failures and has its own deadline.
    streams.handle.terminate();
    let outcome = match result {
        Ok(result) => result,
        Err(error) => {
            if completed.recv_timeout(STEP).is_ok() {
                reader.join().unwrap();
            }
            panic!("remote stdio did not complete: {error}")
        }
    };
    reader.join().unwrap();
    let (io_result, stdout, stderr) = outcome;
    io_result.expect("remote stdio must reach EOF without a transport error");
    assert_eq!(stdout, input);
    assert_eq!(
        String::from_utf8(stderr).unwrap().trim(),
        host.root.join("host").to_str().unwrap()
    );
    assert_eq!(
        streams.handle.process_id(),
        None,
        "remote PIDs must not enter local process registries"
    );
    assert_eq!(streams.handle.exit_status(), Some(Some(0)));
}

#[test]
fn plugin_protocol_maps_owned_uris_without_rewriting_source_text() {
    let host = HostFixture::new();
    let workspace = serde_json::from_value(json!({"sessionId": host.id,
        "localRoot": host.root.join("placeholder"), "remoteRoot": host.root.join("host")}))
    .unwrap();
    let _scope = super::super::workspace::Scope::begin(Some(workspace), "lsp.startServer").unwrap();
    let owner = super::super::workspace::current().unwrap();
    let local = url::Url::from_file_path(host.root.join("placeholder/a space.java"))
        .unwrap()
        .to_string();
    let remote = url::Url::from_file_path(host.root.join("host/a space.java"))
        .unwrap()
        .to_string();
    let external_path = host.root.join("outside/a space.java");
    let external_uri = url::Url::from_file_path(&external_path)
        .unwrap()
        .to_string();
    let external_local = owner.map_uri(&external_uri, false).unwrap();
    assert_eq!(
        url::Url::parse(&external_local)
            .unwrap()
            .to_file_path()
            .unwrap(),
        host.root
            .join("placeholder.lithe-remote-host")
            .join(external_path.strip_prefix("/").unwrap())
    );
    assert_eq!(owner.map_uri(&external_local, true), Some(external_uri));
    let value = json!({"method": "textDocument/didOpen", "params": {"textDocument": {"uri": local,
        "text": format!("// {local}"), "languageId": "java", "version": 1}}});
    let mapped: Value = serde_json::from_str(
        &crate::lsp::interface::remote_process::map_message(&owner, &value.to_string(), true, None)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(mapped["params"]["textDocument"]["uri"], remote);
    assert_eq!(
        mapped["params"]["textDocument"]["text"],
        value["params"]["textDocument"]["text"]
    );
    let edit = json!({"method": "workspace/applyEdit", "params": {"edit": {"changes": {remote.clone(): [{"newText": local}]}}}});
    let mapped: Value = serde_json::from_str(
        &crate::lsp::interface::remote_process::map_message(&owner, &edit.to_string(), false, None)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        mapped["params"]["edit"]["changes"][&local][0]["newText"],
        local
    );
    let map = |value: &Value, outbound, method| -> Value {
        serde_json::from_str(
            &crate::lsp::interface::remote_process::map_message(
                &owner,
                &value.to_string(),
                outbound,
                method,
            )
            .unwrap(),
        )
        .unwrap()
    };
    // JSON-RPC replies have no method. The originating request keeps plugin
    // values opaque while standard LSP location results still get mapped.
    let reply = json!({"id": 17, "result": {"uri": remote, "data": {"uri": remote}}});
    assert_eq!(map(&reply, false, Some("lithe/function/invoke")), reply);
    let mapped = map(&reply, false, Some("textDocument/definition"));
    assert_eq!(mapped["result"]["uri"], local);
    assert_eq!(mapped["result"]["data"], reply["result"]["data"]);
    for method in [
        "lithe/function/invoke",
        "lithe/host/credentials/get",
        "custom/lookup",
    ] {
        let request = json!({"method": method, "params": {"uri": local, "data": {"uri": local}}});
        assert_eq!(map(&request, true, None), request);
    }
    let request = json!({"method": "initialize", "params": {"rootUri": local,
        "initializationOptions": {"uri": local}, "capabilities": {"experimental": {"uri": local}}}});
    let mapped = map(&request, true, None);
    assert_eq!(mapped["params"]["rootUri"], remote);
    assert_eq!(
        mapped["params"]["initializationOptions"],
        request["params"]["initializationOptions"]
    );
    assert_eq!(
        mapped["params"]["capabilities"],
        request["params"]["capabilities"]
    );
    let request = json!({"method": "lithe/vcs/status", "params": {
        "root": {"path": host.root.join("placeholder")},
        "tool": {"executable": host.root.join("placeholder/tools/svn")},
        "paths": ["dir/file"], "uri": local}});
    let mapped = map(&request, true, None);
    assert_eq!(
        mapped["params"]["root"]["path"],
        json!(host.root.join("host"))
    );
    assert_eq!(
        mapped["params"]["tool"]["executable"],
        json!(host.root.join("host/tools/svn"))
    );
    assert_eq!(mapped["params"]["paths"], request["params"]["paths"]);
    assert_eq!(mapped["params"]["uri"], local);
}
