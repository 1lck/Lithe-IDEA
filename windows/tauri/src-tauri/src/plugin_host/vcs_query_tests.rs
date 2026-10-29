use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let fixture = Self(std::env::temp_dir().join(format!(
            "lithe-vcs-query-{}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        )));
        std::fs::create_dir_all(fixture.0.join(".svn")).unwrap();
        fixture
    }
    fn snapshot(&self, workspace: &Path) -> registry::Snapshot {
        let manifest: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
        ))
        .unwrap();
        let scope = super::super::Scope {
            workspace_id: "fixture".into(),
            workspace_root: workspace.to_string_lossy().into_owned(),
            incarnation: "one".into(),
        };
        let packages = [registry::Package {
            plugin_id: manifest["id"].as_str().unwrap().into(),
            identity: "whole-package-digest".into(),
            manifest,
        }];
        registry::Snapshot {
            generation: 1,
            mappings: None,
            watch_error: None,
            mapping_choices: Vec::new(),
            workspace_id: scope.workspace_id.clone(),
            workspace_root: scope.workspace_root.clone(),
            detection: registry::detect(&super::super::Core, &scope, &packages).unwrap(),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove VCS query fixture");
    }
}

fn decoded(operation: &ReadOperation, reply: Value) -> Value {
    let response = crate::plugin_host::scan::core_execute(
        "vcs.decodeReply",
        json!({"operation":operation.name(),"capabilities":{
            "status":1,"baseContent":1,"checkin":1,"rollback":1,"history":1,"fileHistory":1
        },"request":operation.arguments(),"reply":reply}),
    )
    .unwrap();
    assert_eq!(response["status"], "ok");
    response["result"].clone()
}

#[test]
fn history_query_rejects_unbounded_pages_and_repeated_or_control_cursors() {
    assert!(ReadOperation::History {
        cursor: None,
        limit: 0
    }
    .validate()
    .is_err());
    assert!(ReadOperation::History {
        cursor: None,
        limit: MAX_PAGE + 1
    }
    .validate()
    .is_err());
    assert!(ReadOperation::History {
        cursor: Some(String::new()),
        limit: 1
    }
    .validate()
    .is_err());
    assert!(ReadOperation::History {
        cursor: Some("next\npage".into()),
        limit: 1
    }
    .validate()
    .is_err());
    assert!(ReadOperation::History {
        cursor: Some("opaque-provider-cursor".into()),
        limit: 1
    }
    .validate()
    .is_ok());
}

#[test]
fn file_queries_reject_absolute_parent_and_windows_separator_paths() {
    for path in [
        "C:/outside.txt",
        "/outside.txt",
        "../outside.txt",
        "folder/../file.txt",
        "folder\\file.txt",
        "folder//file.txt",
    ] {
        assert!(
            ReadOperation::FileHistory {
                path: path.into(),
                cursor: None,
                limit: 1
            }
            .validate()
            .is_err(),
            "{path}"
        );
    }
    assert!(ReadOperation::FileHistory {
        path: "src/Main.java".into(),
        cursor: None,
        limit: 50
    }
    .validate()
    .is_ok());
}

#[test]
fn baseline_query_keeps_history_path_and_current_path_distinct() {
    let query = ReadOperation::BaseContent {
        path: "deleted.txt".into(),
        current_path: "renamed.txt".into(),
    };
    assert_eq!(query.name(), "baseContent");
    assert_eq!(query.arguments()["path"], "deleted.txt");
    assert!(query.validate().is_ok());
}

#[test]
fn current_content_is_bounded_and_reports_missing_or_binary_without_exposing_bytes() {
    let fixture = Fixture::new();
    // project() supplies canonical workspace/root paths. On Windows a plain
    // fixture path has a different prefix kind from canonicalize()'s result.
    let root = fixture.0.canonicalize().unwrap();
    let text = root.join("text.txt");
    let binary = root.join("binary.dat");
    std::fs::write(&text, "base\n").unwrap();
    std::fs::write(&binary, [0_u8, 1, 2, 3]).unwrap();
    let text_result = current_content(&root, &text).unwrap();
    assert_eq!(text_result["currentContent"], "base\n");
    assert_eq!(text_result["currentBinary"], false);
    let binary_result = current_content(&root, &binary).unwrap();
    assert_eq!(binary_result["currentContent"], Value::Null);
    assert_eq!(binary_result["currentBinary"], true);
    let missing = current_content(&root, &root.join("deleted.txt")).unwrap();
    assert_eq!(missing["currentContent"], Value::Null);
    assert_eq!(missing["currentBinary"], false);
    let oversized = root.join("oversized.txt");
    std::fs::File::create(&oversized)
        .unwrap()
        .set_len(MAX_CONTENT + 1)
        .unwrap();
    assert_eq!(
        current_content(&root, &oversized).unwrap_err(),
        "vcs.provider.contentUnavailable"
    );
}

#[test]
fn production_projection_accepts_deleted_and_missing_paths_from_an_ordinary_workspace() {
    let fixture = Fixture::new();
    std::fs::write(fixture.0.join("deleted.txt"), "removed\n").unwrap();
    std::fs::remove_file(fixture.0.join("deleted.txt")).unwrap();
    // The real entry point receives the ordinary workspace string, resolves
    // its canonical identity itself, and keeps nonexistent paths lexical.
    let snapshot = fixture.snapshot(&fixture.0);
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id.is_empty())
        .unwrap();
    for path in ["deleted.txt", "missing.txt", "missing-directory/file.txt"] {
        let operation = ReadOperation::BaseContent {
            path: path.into(),
            current_path: path.into(),
        };
        let result = project(
            &super::super::Core,
            &snapshot,
            root,
            &operation,
            decoded(&operation, json!({"content":"base\n","binary":false})),
        )
        .unwrap();
        assert_eq!(result["content"], "base\n");
        assert_eq!(result["currentContent"], Value::Null);
        assert_eq!(result["currentBinary"], false);
    }
}

fn link_directory(target: &Path, link: &Path) {
    #[cfg(windows)]
    {
        // Reuse the build/web fixture's junction boundary without requiring
        // Developer Mode. The native runner owns the bounded process tree.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut command = std::process::Command::new("cmd");
        command
            .args(["/D", "/C", "mklink", "/J"])
            .arg(link)
            .arg(target);
        let outcome = lithe_git_host::run(
            &mut command,
            None,
            || std::time::Instant::now() >= deadline,
            || {},
            |_, _| {},
        );
        assert!(
            outcome.failure.is_none() && outcome.status.is_some_and(|status| status.success()),
            "junction creation failed: {}",
            String::from_utf8_lossy(&outcome.stderr)
        );
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, link).expect("directory symlink");
}

#[test]
fn current_and_missing_content_below_a_junction_escape_are_both_rejected() {
    let fixture = Fixture::new();
    let outside = Fixture::new();
    std::fs::write(outside.0.join("private.txt"), "outside\n").unwrap();
    link_directory(&outside.0, &fixture.0.join("escape"));
    let workspace = fixture.0.canonicalize().unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id.is_empty())
        .unwrap();
    for path in ["escape/private.txt", "escape/missing.txt"] {
        assert_eq!(
            current_content(&workspace, &workspace.join(path)).unwrap_err(),
            "vcs.provider.pathUnavailable"
        );
        let operation = ReadOperation::BaseContent {
            path: path.into(),
            current_path: path.into(),
        };
        assert_eq!(
            project(
                &super::super::Core,
                &snapshot,
                root,
                &operation,
                decoded(&operation, json!({"content":null,"binary":false})),
            )
            .unwrap_err(),
            "vcs.provider.pathUnavailable"
        );
    }
    drop(fixture);
    assert_eq!(
        std::fs::read(outside.0.join("private.txt")).unwrap(),
        b"outside\n"
    );
}

#[test]
fn real_core_history_projection_keeps_provider_order_cursor_and_workspace_ownership() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("child/nested/.git")).unwrap();
    let snapshot = fixture.snapshot(&fixture.0.join("child"));
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id == "..")
        .unwrap();
    for operation in [
        ReadOperation::History {
            cursor: Some("previous".into()),
            limit: 2,
        },
        ReadOperation::FileHistory {
            path: "child/deleted.txt".into(),
            cursor: None,
            limit: 2,
        },
    ] {
        let result = project(
            &super::super::Core,
            &snapshot,
            root,
            &operation,
            decoded(
                &operation,
                json!({"entries":[
                {"revision":{"id":"9","kind":"number"},"message":"new","changes":[
                    {"path":"child/deleted.txt","status":"deleted"},
                    {"path":"outside.txt","status":"modified"},
                    {"path":"child/nested/git.txt","status":"modified"},
                    {"path":"child/moved.txt","oldPath":"outside.txt","status":"renamed"}
                ]},
                {"revision":{"id":"3","kind":"number"},"message":"old","changes":[]}
            ],"nextCursor":"opaque-next"}),
            ),
        )
        .unwrap();
        assert_eq!(result["entries"][0]["revision"]["id"], "9");
        assert_eq!(result["entries"][1]["revision"]["id"], "3");
        assert_eq!(result["nextCursor"], "opaque-next");
        assert_eq!(result["entries"][0]["changes"].as_array().unwrap().len(), 1);
        assert_eq!(
            result["entries"][0]["changes"][0]["path"],
            "child/deleted.txt"
        );
        assert_eq!(result["entries"][0]["changesTruncated"], true);
    }
}

#[test]
fn real_core_baseline_projection_keeps_deleted_and_renamed_paths_and_denies_other_roots() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("nested/.git")).unwrap();
    std::fs::write(fixture.0.join("renamed.txt"), "current\n").unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id.is_empty())
        .unwrap();
    let renamed = ReadOperation::BaseContent {
        path: "before.txt".into(),
        current_path: "renamed.txt".into(),
    };
    let result = project(
        &super::super::Core,
        &snapshot,
        root,
        &renamed,
        decoded(&renamed, json!({"content":"base\n","binary":false})),
    )
    .unwrap();
    assert_eq!(result["path"], "before.txt");
    assert_eq!(result["currentPath"], "renamed.txt");
    assert_eq!(result["content"], "base\n");
    assert_eq!(result["currentContent"], "current\n");
    let deleted = ReadOperation::BaseContent {
        path: "deleted.txt".into(),
        current_path: "deleted.txt".into(),
    };
    let result = project(
        &super::super::Core,
        &snapshot,
        root,
        &deleted,
        decoded(&deleted, json!({"content":"old\n","binary":false})),
    )
    .unwrap();
    assert_eq!(result["currentContent"], Value::Null);
    assert_eq!(result["currentBinary"], false);
    assert!(paths(
        &super::super::Core,
        &snapshot,
        root,
        &ReadOperation::BaseContent {
            path: "before.txt".into(),
            current_path: "nested/git.txt".into()
        }
    )
    .is_err());
}
