//! End-to-end scenario of the official Subversion plugin
//! (`Plugins/mac/Official/SvnSupport`) against a real `svn` client and a
//! `file://` repository. The package is assembled by its own
//! `assemble-package.sh`, so the test runs exactly what is shipped: root
//! detection from the manifest, the launch plan, the negotiation, and every
//! operation through `lsp.vcsRequest`, including the failures a provider
//! must tell apart (out of date, conflict) and the moves svn must record.
//! A second working copy plays a colleague committing at the same time.

use super::vcs::{change, revision_ids, Provider};
use super::{core, listing, repository_path, Fixture, Session};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const VCS: &str = "svn";

/// svn waits up to a second after changing working files so a later edit
/// gets a newer timestamp. Its own test suite turns that off with this
/// variable; the scenario does too, so its ~40 writes do not take a minute.
/// Every edit here changes the file's size, which svn compares as well.
const NO_TIMESTAMP_SLEEP: (&str, &str) = (
    "SVN_I_LOVE_CORRUPTED_WORKING_COPIES_SO_DISABLE_SLEEP_FOR_TIMESTAMPS",
    "yes",
);

/// Runs the scenario's own `svn` commands with the provider's environment and
/// a private configuration directory.
struct Svn<'a> {
    executable: &'a str,
    config: PathBuf,
}

impl Svn<'_> {
    fn run(&self, directory: &Path, arguments: &[&str]) -> String {
        let output = Command::new(self.executable)
            .args(["--non-interactive", "--config-dir"])
            .arg(&self.config)
            .args(arguments)
            .current_dir(directory)
            .env_remove("LC_ALL")
            .env_remove("LANGUAGE")
            .env(NO_TIMESTAMP_SLEEP.0, NO_TIMESTAMP_SLEEP.1)
            .env("LC_MESSAGES", "C")
            .env(
                "LC_CTYPE",
                if cfg!(target_os = "macos") {
                    "UTF-8"
                } else {
                    "C.UTF-8"
                },
            )
            .output()
            .unwrap_or_else(|error| panic!("run svn {arguments:?}: {error}"));
        assert!(
            output.status.success(),
            "svn {arguments:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).expect("UTF-8 svn output")
    }
}

/// Assembles the plugin package as `build-official-plugins.sh` does.
fn assemble_package(destination: &Path) {
    let source = repository_path("Plugins/mac/Official/SvnSupport");
    fs::create_dir_all(destination).expect("package directory");
    fs::copy(source.join("plugin.json"), destination.join("plugin.json")).expect("manifest");
    let status = Command::new(source.join("assemble-package.sh"))
        .arg("--output")
        .arg(destination)
        .args(["--arch", "universal"])
        .status()
        .expect("run assemble-package.sh");
    assert!(status.success(), "assemble-package.sh failed: {status}");
}

/// The execution report of the first `svn` subcommand named `subcommand`.
fn execution_of(provider: &mut Provider<'_>, subcommand: &str) -> Value {
    let event = provider
        .session
        .await_event(&format!("the {subcommand} report"), |event| {
            event["type"] == "log"
                && event["message"] == "lithe/vcs/execution"
                && serde_json::from_str::<Value>(event["detail"].as_str().unwrap_or("{}"))
                    .is_ok_and(|report| report["command"][2] == subcommand)
        });
    serde_json::from_str(event["detail"].as_str().expect("report detail")).expect("report JSON")
}

fn read(root: &Path, path: &str) -> String {
    fs::read_to_string(root.join(path)).unwrap_or_else(|error| panic!("read {path}: {error}"))
}

fn write(root: &Path, path: &str, contents: &str) {
    let target = root.join(path);
    fs::create_dir_all(target.parent().expect("parent")).expect("parent directory");
    fs::write(target, contents).unwrap_or_else(|error| panic!("write {path}: {error}"));
}

/// Runs the scenario with `node` as the provider's runtime and `svn` as the
/// client the host resolved.
pub fn run_svn_scenario(node: &str, svn_executable: &str) {
    let fixture = Fixture::new("svn");
    let package = fixture.root.join("package");
    assemble_package(&package);
    let package_before = listing(&package);
    let manifest: Value =
        serde_json::from_slice(&fs::read(package.join("plugin.json")).expect("manifest"))
            .expect("manifest JSON");
    let plugin_id = manifest["id"].as_str().expect("plugin ID").to_string();
    let validated = core(
        "plugins.declarative.validate",
        json!({ "manifest": manifest }),
    );
    assert_eq!(validated["status"], "ok", "{validated}");

    // Revision 1 creates trunk, revision 2 the files the scenario changes.
    let svn = Svn {
        executable: svn_executable,
        config: fixture.root.join("svn-config"),
    };
    let repository = fixture.root.join("repository");
    let status = Command::new(Path::new(svn_executable).with_file_name("svnadmin"))
        .arg("create")
        .arg(&repository)
        .status()
        .expect("run svnadmin");
    assert!(status.success(), "svnadmin create failed");
    let trunk = format!("file://{}/trunk", repository.display());
    svn.run(
        &fixture.root,
        &["mkdir", "-m", "Create trunk", "--username", "alice", &trunk],
    );
    let workspace = fixture.workspace();
    let other = fixture.root.join("other");
    svn.run(&fixture.root, &["checkout", &trunk, "workspace"]);
    write(&workspace, "a.txt", "one\ntwo\n");
    write(&workspace, "docs/b.txt", "bee\n");
    write(&workspace, "keep.txt", "keep\n");
    svn.run(&workspace, &["add", "a.txt", "docs", "keep.txt"]);
    svn.run(
        &workspace,
        &["commit", "-m", "Initial", "--username", "alice"],
    );
    // A commit leaves the root directory at its old revision; a fresh
    // checkout, as users start from, has the whole tree at one revision.
    svn.run(&workspace, &["update"]);
    svn.run(&fixture.root, &["checkout", &trunk, "other"]);

    // Core finds the working copy root from the manifest's `.svn` marker.
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
        .unwrap_or_else(|| panic!("no Subversion root: {detection}"))
        .clone();
    assert_eq!(root["path"], json!(workspace));

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
    assert_eq!(
        plan["vcsProvider"]["tool"]["commands"],
        json!(["svn"]),
        "{plan}"
    );
    let arguments = plan["arguments"].as_array().expect("arguments").clone();
    let mut session = Session::start_provider_with_environment(
        &format!("vcsProvider:{plugin_id}:{VCS}"),
        &plugin_id,
        node,
        &arguments,
        &workspace,
        json!({ NO_TIMESTAMP_SLEEP.0: NO_TIMESTAMP_SLEEP.1 }),
    );
    let negotiated = session.await_event("the VCS negotiation", |event| {
        event["type"] == "vcsProvider"
    });
    assert_eq!(negotiated["result"]["vcs"], VCS, "{negotiated}");
    let capabilities = negotiated["result"]["capabilities"].clone();
    // Subversion commits straight to the server and has no staging area.
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
        vcs: VCS,
        capabilities,
        root: &workspace,
        tool: svn_executable,
        sequence: 0,
    };

    // A client the host resolved but that cannot run is its own error.
    let missing_tool = fixture.root.join("missing/svn");
    provider.tool = missing_tool.to_str().expect("UTF-8 path");
    let unavailable = provider.send("status", &json!({}));
    assert_eq!(
        unavailable["error"]["code"], "vcs.tool.unavailable",
        "{unavailable}"
    );
    provider.tool = svn_executable;

    // Local edits, a file removed without svn, and a new file.
    write(&workspace, "a.txt", "one\nTWO\nthree\n");
    fs::remove_file(workspace.join("docs/b.txt")).expect("remove b.txt");
    write(&workspace, "c.txt", "sea\n");
    assert_eq!(
        provider.changes(),
        [
            change("a.txt", "modified"),
            change("c.txt", "unversioned"),
            change("docs/b.txt", "missing"),
        ]
    );
    let head = provider.request("status", json!({}))["head"].clone();
    assert_eq!(
        head,
        json!({ "revision": { "id": "2", "display": "r2", "kind": "number" }, "branch": null, "location": trunk })
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
    assert_eq!(
        provider.request("baseContent", json!({ "path": "c.txt" })),
        json!({ "content": null, "binary": false })
    );

    // A colleague commits keep.txt first; committing ours is out of date,
    // which the host shows as its own error.
    write(&other, "keep.txt", "theirs\n");
    svn.run(&other, &["commit", "-m", "Theirs", "--username", "bob"]);
    write(&workspace, "keep.txt", "mine, edited\n");
    let rejected = provider.send(
        "checkin",
        &json!({ "paths": ["keep.txt"], "message": "Mine" }),
    );
    assert_eq!(rejected["error"]["code"], "vcs.outOfDate", "{rejected}");
    provider.request("rollback", json!({ "paths": ["keep.txt"] }));
    assert_eq!(read(&workspace, "keep.txt"), "keep\n");

    // Mutating commands are reported for the console; reads are not.
    provider.request("cleanup", json!({}));
    let report = execution_of(&mut provider, "cleanup");
    assert_eq!(
        report["command"],
        json!([svn_executable, "--non-interactive", "cleanup"])
    );
    assert_eq!(report["exitCode"], 0, "{report}");

    // The missing file is deleted through svn as part of the check-in.
    let checked_in = provider.request(
        "checkin",
        json!({ "paths": ["a.txt", "c.txt", "docs/b.txt"], "message": "Second\n\nWith a body." }),
    );
    assert_eq!(
        checked_in["revision"],
        json!({ "id": "4", "display": "r4", "kind": "number" })
    );
    assert!(provider.changes().is_empty());
    assert_eq!(
        provider.request("update", json!({})),
        json!({ "revision": { "id": "4", "display": "r4", "kind": "number" }, "conflicts": [] })
    );
    assert_eq!(read(&workspace, "keep.txt"), "theirs\n");

    // History pages run newest first and resume from the cursor.
    let first = provider.request("history", json!({ "limit": 1 }));
    assert_eq!(revision_ids(&first["entries"]), ["4"]);
    assert_eq!(first["nextCursor"], "3");
    let latest = &first["entries"][0];
    assert_eq!(latest["message"], "Second\n\nWith a body.");
    assert_eq!(
        latest["changes"],
        json!([
            { "path": "a.txt", "oldPath": null, "status": "modified", "flags": [] },
            { "path": "c.txt", "oldPath": null, "status": "added", "flags": [] },
            { "path": "docs/b.txt", "oldPath": null, "status": "deleted", "flags": [] }
        ])
    );
    let rest = provider.request("history", json!({ "limit": 2, "cursor": "3" }));
    assert_eq!(revision_ids(&rest["entries"]), ["3", "2"]);
    assert_eq!(rest["entries"][1]["author"], "alice");
    assert_eq!(rest["nextCursor"], "1");
    let file_history = provider.request("fileHistory", json!({ "path": "a.txt" }));
    assert_eq!(revision_ids(&file_history["entries"]), ["4", "2"]);
    assert_eq!(file_history["nextCursor"], Value::Null);

    // Annotation follows the working file: a local line has no revision.
    write(&workspace, "a.txt", "one\nTWO\nthree\nfour\n");
    let annotation = provider.request("annotate", json!({ "path": "a.txt" }));
    assert_eq!(annotation["lines"], json!(["2", "4", "4", null]));
    assert_eq!(revision_ids(&annotation["revisions"]), ["2", "4"]);
    assert_eq!(annotation["revisions"][0]["message"], "Initial");
    provider.request("rollback", json!({ "paths": ["a.txt"] }));

    // A move is a rename from its source; rolling it back restores the source.
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
    provider.request("rollback", json!({ "paths": ["docs/c.txt"] }));
    assert!(!workspace.join("docs/c.txt").exists());
    assert_eq!(read(&workspace, "c.txt"), "sea\n");
    assert!(provider.changes().is_empty());

    // Checking in the destination alone commits both halves of the move.
    provider.request(
        "fileOperation",
        json!({ "kind": "move", "from": "c.txt", "to": "docs/c.txt" }),
    );
    let moved = provider.request(
        "checkin",
        json!({ "paths": ["docs/c.txt"], "message": "Move c" }),
    );
    assert_eq!(moved["revision"]["id"], "5");
    assert!(provider.changes().is_empty());
    let move_entry = provider.request("history", json!({ "limit": 1 }));
    assert_eq!(
        move_entry["entries"][0]["changes"],
        json!([{ "path": "docs/c.txt", "oldPath": "c.txt", "status": "renamed", "flags": [] }])
    );

    // An update that conflicts leaves the file conflicted until resolved.
    svn.run(&other, &["update"]);
    write(&other, "docs/c.txt", "sea from bob\n");
    svn.run(&other, &["commit", "-m", "Bob's c", "--username", "bob"]);
    write(&workspace, "docs/c.txt", "sea from us\n");
    let updated = provider.request("update", json!({}));
    assert_eq!(updated["revision"]["id"], "6");
    assert_eq!(updated["conflicts"], json!(["docs/c.txt"]));
    let conflicted = provider.send(
        "checkin",
        &json!({ "paths": ["docs/c.txt"], "message": "Too early" }),
    );
    assert_eq!(conflicted["error"]["code"], "vcs.conflict", "{conflicted}");
    fs::write(workspace.join("docs/c.txt"), "sea from both\n").expect("merge by hand");
    provider.request("resolve", json!({ "paths": ["docs/c.txt"] }));
    assert_eq!(provider.changes(), [change("docs/c.txt", "modified")]);
    assert_eq!(read(&workspace, "docs/c.txt"), "sea from both\n");
    provider.request("rollback", json!({ "paths": ["docs/c.txt"] }));
    assert_eq!(read(&workspace, "docs/c.txt"), "sea from bob\n");

    // A tracked delete removes the file; rollback brings it back.
    provider.request(
        "fileOperation",
        json!({ "kind": "delete", "paths": ["keep.txt"] }),
    );
    assert!(!workspace.join("keep.txt").exists());
    assert_eq!(provider.changes(), [change("keep.txt", "deleted")]);
    provider.request("rollback", json!({ "paths": ["keep.txt"] }));
    assert_eq!(read(&workspace, "keep.txt"), "theirs\n");

    // New paths are added on check-in: a whole directory, a name svn would
    // read as a peg revision, and a binary file whose base is not sent.
    write(&workspace, "new/x.txt", "x\n");
    write(&workspace, "new/sub/y.txt", "y\n");
    write(&workspace, "a@b.txt", "at\n");
    fs::write(workspace.join("image.bin"), b"bin\0ary").expect("binary file");
    assert_eq!(
        provider.changes(),
        [
            change("a@b.txt", "unversioned"),
            change("image.bin", "unversioned"),
            change("new", "unversioned"),
        ]
    );
    let added = provider.request(
        "checkin",
        json!({ "paths": ["new", "a@b.txt", "image.bin"], "message": "Add new files" }),
    );
    assert_eq!(added["revision"]["id"], "7");
    assert!(provider.changes().is_empty());
    assert_eq!(
        revision_ids(
            &provider.request("fileHistory", json!({ "path": "new/sub/y.txt" }))["entries"]
        ),
        ["7"]
    );
    assert_eq!(
        provider.request("baseContent", json!({ "path": "a@b.txt" })),
        json!({ "content": "at\n", "binary": false })
    );
    assert_eq!(
        provider.request("baseContent", json!({ "path": "image.bin" })),
        json!({ "content": null, "binary": true })
    );

    provider.session.stop();
    drop(provider);
    assert!(
        listing(&package) == package_before,
        "the plugin package changed at runtime"
    );
}
