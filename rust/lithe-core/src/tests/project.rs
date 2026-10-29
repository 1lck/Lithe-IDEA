use super::support::{fixture, temporary_root};
use crate::execute_json;
use serde_json::Value;
use std::fs;

#[test]
fn search_exclusions_filter_names_content_and_replacement_and_keep_cache_variants_fresh() {
    let root = temporary_root("search-exclusions");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    for path in [
        "Name.log",
        "src/Name.log",
        ".cache/Name.swift",
        "src/.cache/Name.swift",
        "src/Name.swift",
    ] {
        let file = root.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, "Name before").unwrap();
    }
    let query = |command: &str, excluded: bool, text: &str| -> Value {
        let patterns = if excluded {
            vec!["*.log", "**/.*/*", ".*/*"]
        } else {
            vec![]
        };
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "command": command, "payload": {"root": root, "query": text,
                    "replacement": "changed", "maxResults": 100, "maxSymbolResults": 0,
                    "includeGeneratedFileNames": true, "hiddenFilePatterns": patterns}
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    };
    for command in [
        "workspace.search",
        "workspace.searchEverywhere",
        "workspace.replacePreview",
    ] {
        let data = query(command, true, "Name");
        let items = data[if command == "workspace.replacePreview" {
            "files"
        } else {
            "matches"
        }]
        .as_array()
        .unwrap();
        assert!(!items.is_empty(), "{command}");
        assert!(
            items.iter().all(|item| item["path"] == "src/Name.swift"),
            "{data}"
        );
    }
    assert!(!query("workspace.search", false, "before")["matches"]
        .as_array()
        .unwrap()
        .is_empty());
    fs::write(root.join("src/Name.swift"), "Name after").unwrap();
    crate::project::files::update_search_index(
        serde_json::from_value(serde_json::json!({
            "root": root, "paths": ["src/Name.swift"]
        }))
        .unwrap(),
    )
    .unwrap();
    for excluded in [false, true] {
        let data = query("workspace.search", excluded, "after");
        assert_eq!(data["matches"].as_array().unwrap().len(), 1, "{data}");
        assert_eq!(data["matches"][0]["path"], "src/Name.swift");
    }
}

#[test]
fn search_everywhere_uses_git_ignore_rules_for_filename_foreground() {
    let root = temporary_root("everywhere-ignore-status");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::create_dir_all(root.join(".build")).unwrap();
    let git = |arguments: &[&str]| {
        let response = crate::git::execute_git(
            root.to_str().unwrap(),
            &arguments
                .iter()
                .map(|value| value.to_string())
                .collect::<Vec<_>>(),
            None,
        )
        .unwrap();
        assert_eq!(response.exit_code, 0, "{}", response.output);
    };
    git(&["init", "-q"]);
    fs::write(root.join(".gitignore"), ".build/\n*.tmp\n!name-keep.tmp\n").unwrap();
    fs::write(root.join(".git/info/exclude"), "name-local.dat\n").unwrap();
    let paths = [
        ".build/Name.swift",
        "name ignore space.tmp",
        "name-tracked.tmp",
        "name-keep.tmp",
        "name-local.dat",
        "name-normal.swift",
    ];
    #[cfg(unix)]
    let paths = {
        let mut paths = paths.to_vec();
        paths.push("name ignore\nspace.tmp");
        paths
    };
    for path in &paths {
        fs::write(root.join(path), "").unwrap();
    }
    git(&["add", "-f", "name-tracked.tmp"]);
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "command": "workspace.searchEverywhere", "payload": {
                "root": root, "query": "name", "maxResults": 100,
                "maxContentResults": 0, "maxSymbolResults": 0,
                "includeGeneratedFileNames": true
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let matches = response["data"]["matches"].as_array().unwrap();
    for path in paths {
        let item = matches.iter().find(|item| item["path"] == path).unwrap();
        let ignored = path == ".build/Name.swift"
            || path.starts_with("name ignore")
            || path == "name-local.dat";
        assert_eq!(item["isIgnored"], ignored, "{path}");
    }
}

#[test]
fn search_everywhere_preserves_unicode_contiguous_filename_matches() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/unicode-contiguous.json"
    ))
    .unwrap();
    let root = temporary_root("unicode-contiguous-names");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    for case in fixture["cases"].as_array().unwrap() {
        let path = root.join(case["path"].as_str().unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "").unwrap();
    }
    for case in fixture["cases"].as_array().unwrap() {
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "command": "workspace.searchEverywhere", "payload": {
                    "root": root, "query": case["query"],
                    "maxContentResults": 0, "maxSymbolResults": 0
                }
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        let hit = response["data"]["matches"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["path"] == case["path"])
            .unwrap();
        assert_eq!(hit["nameMatchRanges"], case["ranges"], "{case}");
    }
}

#[test]
fn search_everywhere_preserves_directory_fallback_below_basename_matches() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/path-fallback.json"
    ))
    .unwrap();
    let root = temporary_root("search-path-fallback");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    for file in fixture["files"].as_array().unwrap() {
        let path = root.join(file.as_str().unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "").unwrap();
    }
    for case in fixture["cases"].as_array().unwrap() {
        for literal in [false, true] {
            let response: Value = serde_json::from_str(&execute_json(
                &serde_json::json!({
                    "command": "workspace.searchEverywhere", "payload": {
                        "root": root, "query": case["query"], "caseSensitive": literal,
                        "maxResults": 100, "maxContentResults": 0, "maxSymbolResults": 0
                    }
                })
                .to_string(),
            ))
            .unwrap();
            assert_eq!(response["ok"], true, "{response}");
            let matches = response["data"]["matches"].as_array().unwrap();
            assert_eq!(
                matches
                    .iter()
                    .map(|item| item["path"].clone())
                    .collect::<Vec<_>>(),
                case["paths"].as_array().unwrap().clone(),
                "{response}"
            );
            if let Some(basename) = case["basenameFirst"].as_str() {
                assert_eq!(matches[0]["path"], basename);
                assert!(matches[1..]
                    .iter()
                    .all(|item| item["nameMatchRanges"].as_array().is_none_or(Vec::is_empty)));
                assert!(matches[1..]
                    .iter()
                    .all(|item| item["matchingDegree"].as_i64().unwrap()
                        < matches[0]["matchingDegree"].as_i64().unwrap()));
            }
        }
    }
}

#[test]
fn search_everywhere_matches_names_before_limits_and_shares_utf16_fragments() {
    let root = temporary_root("everywhere-name-fragments");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/name-matching.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let path = root.join(case["path"].as_str().unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            path,
            "not a content match\nnot a content match\nnot a content match",
        )
        .unwrap();
    }
    for path in [".git/Name.swift", "excluded/Name.swift", "src/Unrelated.rs"] {
        let path = root.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "not a content match").unwrap();
    }
    // Low-relevance names occur earlier in the index than an exact name.
    for i in 0..60 {
        fs::write(root.join(format!("aName{i}.txt")), "").unwrap();
    }
    let search = |generated: bool, cap: usize| -> Vec<Value> {
        let response: Value = serde_json::from_str(&execute_json(&serde_json::json!({
            "command": "workspace.searchEverywhere", "payload": {
                "root": root, "query": fixture["query"], "maxResults": 1000,
                "maxFileResults": cap, "maxContentResults": 0, "maxSymbolResults": 0,
                "includeGeneratedFileNames": generated, "hiddenDirectoryNames": ["excluded", ".build", "target"]
            }
        }).to_string())).unwrap();
        assert_eq!(response["ok"], true, "{response}");
        response["data"]["matches"].as_array().unwrap().clone()
    };
    let results = search(true, 200);
    for case in fixture["cases"].as_array().unwrap() {
        let result = results
            .iter()
            .find(|m| m["path"] == case["path"])
            .expect("reported IDEA name should be found");
        assert_eq!(
            result["nameMatchRanges"], case["ranges"],
            "{}",
            case["path"]
        );
        assert!(result["matchingDegree"].as_i64().unwrap() > 0);
    }
    assert!(!results
        .iter()
        .any(|m| m["path"].as_str().unwrap().starts_with(".git/")
            || m["path"].as_str().unwrap().starts_with("excluded/")
            || m["path"] == "src/Unrelated.rs"));
    let limited = search(true, 1);
    assert_eq!(limited[0]["path"], ".build/checkouts/Name.swift");
    assert!(!search(false, 200)
        .iter()
        .any(|m| m["path"].as_str().unwrap().contains(".build/")
            || m["path"].as_str().unwrap().contains("target/")));
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "command": "workspace.searchEverywhere", "payload": {
                "root": root, "query": "not", "maxResults": 10,
                "maxFileResults": 0, "maxSymbolResults": 0, "maxContentResults": 2
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["data"]["matches"].as_array().unwrap().len(), 2);
    // A cached names-only index must follow file updates, deletion and directory invalidation.
    let update = |paths: &[&str]| {
        crate::project::files::update_search_index(serde_json::from_value(serde_json::json!({
            "root": root, "paths": paths, "hiddenDirectoryNames": ["excluded", ".build", "target"]
        })).unwrap()).unwrap()
    };
    fs::write(root.join(".build/checkouts/NameGuide.swift"), "").unwrap();
    update(&[".build/checkouts/NameGuide.swift"]);
    assert!(search(true, 200)
        .iter()
        .any(|m| m["path"] == ".build/checkouts/NameGuide.swift"));
    fs::remove_file(root.join(".build/checkouts/NameGuide.swift")).unwrap();
    update(&[".build/checkouts/NameGuide.swift"]);
    assert!(!search(true, 200)
        .iter()
        .any(|m| m["path"] == ".build/checkouts/NameGuide.swift"));
    assert!(update(&[".build/checkouts"]).rebuilt);
    assert!(search(true, 200)
        .iter()
        .any(|m| m["path"] == ".build/checkouts/Name.swift"));
}

#[test]
fn workspace_snapshot_hides_nested_worktree_checkouts() {
    let root = temporary_root("snapshot-worktree");
    fs::create_dir_all(root.join("src")).expect("source directory should be creatable");
    fs::create_dir_all(root.join(".worktree/feature/src"))
        .expect("worktree directory should be creatable");
    fs::create_dir_all(root.join(".worktrees/bugfix/src"))
        .expect("worktrees directory should be creatable");
    fs::write(root.join("src/App.java"), "class App {}").expect("source should be writable");
    fs::write(root.join(".worktree/feature/src/App.java"), "class App {}")
        .expect("worktree source should be writable");
    fs::write(root.join(".worktrees/bugfix/src/App.java"), "class App {}")
        .expect("worktrees source should be writable");

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "snapshot-worktree",
            "command": "workspace.snapshot",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .expect("snapshot response should be JSON");

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["files"],
        serde_json::json!(["src/App.java"])
    );

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

fn core_data(id: &str, command: &str, payload: Value) -> Value {
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({"id": id, "command": command, "payload": payload}).to_string(),
    ))
    .expect("core response should be JSON");
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

fn write_fixture_file(path: &std::path::Path, text: &str) {
    fs::create_dir_all(path.parent().expect("fixture file should have a parent"))
        .expect("fixture directory should be creatable");
    fs::write(path, text).expect("fixture file should be writable");
}

/// Lays out the pointer files Git writes for a linked worktree, a submodule,
/// and a worktree placed beside its main checkout.
fn write_linked_worktree_fixture(root: &std::path::Path) {
    write_fixture_file(&root.join("src/App.java"), "class App {}");
    write_fixture_file(&root.join(".git/HEAD"), "ref: refs/heads/main\n");
    write_fixture_file(
        &root.join(".git/worktrees/agent/HEAD"),
        "ref: refs/heads/agent\n",
    );
    write_fixture_file(
        &root.join(".claude/worktrees/agent/.git"),
        &format!("gitdir: {}\n", root.join(".git/worktrees/agent").display()),
    );
    write_fixture_file(
        &root.join(".claude/worktrees/agent/src/App.java"),
        "class App { int nestedWorktreeToken731; }",
    );
    write_fixture_file(&root.join(".claude/settings.json"), "{}");
    // Submodules point into `.git/modules`, so they remain part of the project.
    write_fixture_file(
        &root.join(".git/modules/lib/HEAD"),
        "ref: refs/heads/main\n",
    );
    write_fixture_file(
        &root.join("vendor/lib/.git"),
        "gitdir: ../../.git/modules/lib\n",
    );
    write_fixture_file(&root.join("vendor/lib/Lib.java"), "class Lib {}");
}

#[test]
fn workspace_snapshot_omits_linked_worktrees_nested_in_their_own_repository() {
    let root = temporary_root("snapshot-linked-worktree");
    write_linked_worktree_fixture(&root);

    let data = core_data(
        "snapshot-linked-worktree",
        "workspace.snapshot",
        serde_json::json!({"root": root}),
    );

    assert_eq!(
        data["files"],
        serde_json::json!([
            ".claude/settings.json",
            "src/App.java",
            "vendor/lib/Lib.java"
        ])
    );
    assert_eq!(
        data["nestedWorktrees"],
        serde_json::json!([".claude/worktrees/agent"])
    );
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn workspace_snapshot_without_tree_keeps_the_same_file_list() {
    let root = temporary_root("snapshot-files-only");
    write_linked_worktree_fixture(&root);

    let full = core_data(
        "snapshot-full",
        "workspace.snapshot",
        serde_json::json!({"root": root}),
    );
    let files_only = core_data(
        "snapshot-files-only",
        "workspace.snapshot",
        serde_json::json!({"root": root, "includeTree": false}),
    );

    assert_eq!(files_only["files"], full["files"]);
    assert_eq!(files_only["nestedWorktrees"], full["nestedWorktrees"]);
    assert_eq!(files_only["root"]["path"], "");
    assert_eq!(files_only["root"]["isDirectory"], true);
    assert!(files_only["root"].get("children").is_none());
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn list_directories_marks_only_visibly_empty_directories_as_leaves() {
    let root = temporary_root("directory-leaves");
    fs::create_dir_all(root.join("logs")).unwrap();
    fs::create_dir_all(root.join("parent/empty")).unwrap();
    write_fixture_file(&root.join("hidden-only/ignored.tmp"), "");
    let data = core_data(
        "directory-leaves",
        "workspace.listDirectories",
        serde_json::json!({
            "root": root, "paths": [""], "hiddenFilePatterns": ["*.tmp"]
        }),
    );
    let children = data["directories"][0]["children"].as_array().unwrap();
    for name in ["logs", "hidden-only"] {
        let child = children.iter().find(|child| child["name"] == name).unwrap();
        assert_eq!(child["children"], serde_json::json!([]));
    }
    let parent = children
        .iter()
        .find(|child| child["name"] == "parent")
        .unwrap();
    assert!(parent.get("children").is_none());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn list_directories_returns_one_visible_level_per_requested_directory() {
    let root = temporary_root("list-directories");
    write_linked_worktree_fixture(&root);
    write_fixture_file(&root.join("src/main/Util.java"), "class Util {}");
    write_fixture_file(&root.join("build/Output.class"), "");

    let data = core_data(
        "list-directories",
        "workspace.listDirectories",
        serde_json::json!({
            "root": root,
            "paths": ["", "src/", ".claude/worktrees", "missing", "build", "../outside",
                      ".claude/worktrees/agent", ".claude/worktrees/agent/src"]
        }),
    );

    let directories = data["directories"]
        .as_array()
        .expect("directories should be an array");
    let paths = directories
        .iter()
        .map(|directory| directory["path"].as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    assert_eq!(paths, ["", "src", ".claude/worktrees"]);
    let names = |index: usize| {
        directories[index]["children"]
            .as_array()
            .expect("children should be an array")
            .iter()
            .map(|child| {
                assert!(child.get("children").is_none(), "{child}");
                (
                    child["path"].as_str().unwrap_or_default().to_string(),
                    child["isDirectory"].as_bool().unwrap_or_default(),
                )
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(
        names(0),
        [
            (".claude".to_string(), true),
            ("src".to_string(), true),
            ("vendor".to_string(), true)
        ]
    );
    assert_eq!(
        names(1),
        [
            ("src/main".to_string(), true),
            ("src/App.java".to_string(), false)
        ]
    );
    assert!(names(2).is_empty());
    assert_eq!(
        directories[2]["nestedWorktrees"],
        serde_json::json!([".claude/worktrees/agent"])
    );
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn folder_patterns_hide_folders_without_reading_them() {
    // `name/`, `name/*` and `name/**` hide a folder from the project root, and a
    // leading `**/` hides it at any depth, so the tree must not enumerate it. A
    // plain name stays a file pattern.
    let root = temporary_root("folder-patterns");
    write_fixture_file(&root.join("src/App.java"), "class App {}");
    write_fixture_file(&root.join(".lithe/dependencies/index.json"), "{}");
    write_fixture_file(&root.join("generated/Out.java"), "class Out {}");
    write_fixture_file(&root.join("docs/api/index.html"), "<html></html>");
    write_fixture_file(&root.join("modules/.lithe/config.json"), "{}");
    write_fixture_file(&root.join("notes/todo.md"), "kept");
    write_fixture_file(&root.join("tmp/scratch.txt"), "root copy");
    write_fixture_file(&root.join("modules/tmp/scratch.txt"), "nested copy");
    write_fixture_file(&root.join("modules/keep.txt"), "kept");
    let patterns = [".lithe/*", "generated/", "docs/**", "notes", "**/tmp/"];
    let rules = serde_json::json!({"root": root, "hiddenFilePatterns": patterns});

    crate::project::files::DIRECTORY_VISITS.with_borrow_mut(|visits| *visits = Some(Vec::new()));
    let snapshot = core_data(
        "folder-patterns-snapshot",
        "workspace.snapshot",
        rules.clone(),
    );
    let root_listing = core_data(
        "folder-patterns-listing",
        "workspace.listDirectories",
        serde_json::json!({
            "root": root,
            "paths": ["", ".lithe", "generated", "docs", "tmp", "modules", "modules/tmp"],
            "hiddenFilePatterns": patterns
        }),
    );
    let visits = crate::project::files::DIRECTORY_VISITS
        .with_borrow_mut(Option::take)
        .expect("visit trace should be installed");

    let mut snapshot_files = snapshot["files"]
        .as_array()
        .expect("files should be an array")
        .iter()
        .map(|file| file.as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    snapshot_files.sort_unstable();
    assert_eq!(
        snapshot_files,
        [
            "modules/.lithe/config.json",
            "modules/keep.txt",
            "notes/todo.md",
            "src/App.java"
        ]
    );
    let listed = root_listing["directories"]
        .as_array()
        .expect("directories should be an array")
        .iter()
        .map(|directory| directory["path"].as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    assert_eq!(listed, ["", "modules"]);
    let root_children = root_listing["directories"][0]["children"]
        .as_array()
        .expect("children should be an array")
        .iter()
        .map(|child| child["name"].as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    assert_eq!(root_children, ["modules", "notes", "src"]);
    for hidden in [".lithe", "generated", "docs", "tmp", "modules/tmp"] {
        assert!(
            visits
                .iter()
                .all(|path| !path.starts_with(root.join(hidden))),
            "hidden folder {hidden} must not be enumerated: {visits:?}"
        );
    }
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn workspace_snapshot_keeps_worktrees_outside_their_main_checkout() {
    // Opening a folder that holds a main checkout beside one of its linked
    // worktrees shows both: neither duplicates the other's directory.
    let root = temporary_root("snapshot-sibling-worktree");
    write_fixture_file(&root.join("main/.git/HEAD"), "ref: refs/heads/main\n");
    write_fixture_file(
        &root.join("main/.git/worktrees/feature/HEAD"),
        "ref: refs/heads/f\n",
    );
    write_fixture_file(&root.join("main/App.java"), "class App {}");
    write_fixture_file(
        &root.join("feature/.git"),
        &format!(
            "gitdir: {}\n",
            root.join("main/.git/worktrees/feature").display()
        ),
    );
    write_fixture_file(&root.join("feature/App.java"), "class App {}");

    let data = core_data(
        "snapshot-sibling-worktree",
        "workspace.snapshot",
        serde_json::json!({"root": root}),
    );

    assert_eq!(
        data["files"],
        serde_json::json!(["feature/App.java", "main/App.java"])
    );
    assert_eq!(data["nestedWorktrees"], serde_json::json!([]));
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn workspace_snapshot_hides_build_artifact_directory() {
    let root = temporary_root("snapshot-artifacts");
    write_fixture_file(&root.join("src/App.java"), "class App {}");
    write_fixture_file(
        &root.join(".artifacts/test-stability/index.html"),
        "<html></html>",
    );

    let data = core_data(
        "snapshot-artifacts",
        "workspace.snapshot",
        serde_json::json!({"root": root}),
    );

    assert_eq!(data["files"], serde_json::json!(["src/App.java"]));
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn search_everywhere_names_exclude_nested_worktrees_during_incremental_updates() {
    let root = temporary_root("everywhere-linked-worktree");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    write_linked_worktree_fixture(&root);
    let root = fs::canonicalize(&root).unwrap();
    let search = || {
        core_data(
            "everywhere-linked",
            "workspace.searchEverywhere",
            serde_json::json!({
                "root": root, "query": "NestedPreview", "includeGeneratedFileNames": true
            }),
        )
    };
    let path = root.join(".claude/worktrees/agent/src/NestedPreview.java");
    write_fixture_file(&path, "class NestedPreview {}");
    assert_eq!(search()["matches"], serde_json::json!([]));
    fs::write(&path, "class NestedPreview { int updated; }").unwrap();
    let update = core_data(
        "everywhere-linked-update",
        "workspace.searchIndex.update",
        serde_json::json!({"root": root, "paths": [path]}),
    );
    assert_eq!(update["rebuilt"], false, "{update}");
    assert_eq!(search()["matches"], serde_json::json!([]));
}

#[test]
fn search_index_ignores_nested_linked_worktree_content_and_updates() {
    let root = temporary_root("search-linked-worktree");
    write_linked_worktree_fixture(&root);
    // Watcher paths arrive canonical; match them so the update is not dropped
    // merely for lying outside the root.
    let root = fs::canonicalize(&root).expect("fixture root should resolve");
    let search = |id: &str| {
        core_data(
            id,
            "workspace.search",
            serde_json::json!({"root": root, "query": "nestedWorktreeToken731"}),
        )
    };

    assert_eq!(
        search("search-linked-worktree")["matches"],
        serde_json::json!([])
    );
    write_fixture_file(
        &root.join(".claude/worktrees/agent/src/New.java"),
        "class New { int nestedWorktreeToken731; }",
    );
    let update = core_data(
        "search-linked-worktree-update",
        "workspace.searchIndex.update",
        serde_json::json!({
            "root": root,
            "paths": [root.join(".claude/worktrees/agent/src/New.java")]
        }),
    );

    assert_eq!(update["rebuilt"], false, "{update}");
    assert_eq!(
        search("search-linked-worktree-after-update")["matches"],
        serde_json::json!([])
    );
    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn search_can_match_unique_content_inside_jdtls_factorypath_files() {
    // Shared visibility rules must not hide `.factorypath`, otherwise search
    // cannot reach the unique annotation-processor metadata on disk.
    let root = temporary_root("search-factorypath");
    fs::create_dir_all(root.join("services/alpha")).expect("module directory should be creatable");
    fs::write(root.join("README.md"), "visible\n").expect("readme should be writable");
    fs::write(root.join(".factorypath"), "jdtlsFactorypathToken589\n")
        .expect("root factorypath should be writable");
    fs::write(
        root.join("services/alpha/.factorypath"),
        "jdtlsFactorypathToken589\n",
    )
    .expect("module factorypath should be writable");

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "search-factorypath",
            "command": "workspace.search",
            "payload": {
                "root": root,
                "query": "jdtlsFactorypathToken589",
                "caseSensitive": true,
                "maxResults": 20
            }
        })
        .to_string(),
    ))
    .expect("search response should be JSON");

    assert_eq!(response["ok"], true, "{response}");
    let paths = response["data"]["matches"]
        .as_array()
        .expect("matches should be an array")
        .iter()
        .map(|value| value["path"].as_str().expect("path should be text"))
        .collect::<Vec<_>>();
    assert!(
        paths.contains(&".factorypath"),
        "root factorypath should remain searchable: {response}"
    );
    assert!(
        paths.contains(&"services/alpha/.factorypath"),
        "nested factorypath should remain searchable: {response}"
    );
    assert!(root.join(".factorypath").is_file());
    assert!(root.join("services/alpha/.factorypath").is_file());

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn markdown_render_command_returns_sanitized_html() {
    let request = serde_json::json!({
        "id": "markdown-1",
        "command": "markdown.render",
        "payload": {
            "source": "# Preview\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n```plantuml\nAlice -> Bob\n```\n\n<script>alert(1)</script>"
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Markdown request should encode"),
    ))
    .expect("Markdown response should be JSON");

    assert_eq!(response["id"], "markdown-1");
    assert_eq!(response["ok"], true);
    let html = response["data"]["html"]
        .as_str()
        .expect("Markdown response should contain HTML");
    assert!(html.contains("<table"));
    assert!(html.contains("language-plantuml"));
    assert!(html.contains("Alice -&gt; Bob"));
    assert!(!html.contains("<script"));
    assert!(!html.contains("alert(1)"));
}

#[test]
fn search_matches_shared_fixture_semantics() {
    let fixture = fixture();
    let root = temporary_root("search");
    let _ = fs::remove_dir_all(&root);
    for file in fixture["files"]
        .as_array()
        .expect("files should be an array")
    {
        let path = root.join(file["path"].as_str().expect("fixture path should be text"));
        fs::create_dir_all(path.parent().expect("fixture file should have a parent"))
            .expect("fixture parent should be creatable");
        fs::write(
            path,
            file["content"]
                .as_str()
                .expect("fixture content should be text"),
        )
        .expect("fixture file should be writable");
    }

    for case in fixture["cases"]
        .as_array()
        .expect("cases should be an array")
    {
        let request = serde_json::json!({
            "id": "fixture",
            "command": "workspace.search",
            "payload": {
                "root": root.to_string_lossy(),
                "query": case["request"]["query"],
                "caseSensitive": case["request"]["caseSensitive"],
                "wholeWords": case["request"]["wholeWords"],
                "regularExpression": case["request"]["regularExpression"],
                "maxResults": 200
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("request should encode"),
        ))
        .expect("search response should be JSON");
        assert_eq!(response["ok"], true, "case {} should succeed", case["name"]);

        let actual = response["data"]["matches"]
            .as_array()
            .expect("matches should be an array");
        let expected = case["expected"]
            .as_array()
            .expect("expected should be an array");
        assert_eq!(actual, expected, "fixture case {} changed", case["name"]);
    }

    let limited_request = serde_json::json!({
        "id": "limited",
        "command": "workspace.search",
        "payload": {
            "root": root,
            "query": "UserService",
            "maxResults": 100,
            "maxFileResults": 0,
            "maxContentResults": 1
        }
    });
    let limited_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&limited_request).expect("limited request should encode"),
    ))
    .expect("limited response should be JSON");
    assert_eq!(limited_response["ok"], true);
    assert_eq!(
        limited_response["data"]["matches"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(limited_response["data"]["matches"][0]["kind"], "content");

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn search_everywhere_and_replacement_preview_are_shared() {
    let root = temporary_root("advanced-search");
    fs::create_dir_all(root.join("src/main/java/com/example"))
        .expect("fixture directory should be creatable");
    let source = "class UserService {\n    void loadUser() {}\n}\n";
    let relative = "src/main/java/com/example/UserService.java";
    fs::write(root.join(relative), source).expect("fixture source should be writable");

    let request = serde_json::json!({
        "id": "everywhere",
        "command": "workspace.searchEverywhere",
        "payload": {
            "root": root,
            "query": "UserService",
            "caseSensitive": true,
            "wholeWords": true,
            "regularExpression": false,
            "maxResults": 200,
            "maxFileResults": 50,
            "maxContentResults": 50,
            "maxSymbolResults": 50
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("search request should encode"),
    ))
    .expect("search response should be JSON");
    assert_eq!(response["ok"], true);
    let matches = response["data"]["matches"]
        .as_array()
        .expect("search matches should be an array");
    assert!(matches.iter().any(|value| value["kind"] == "file"));
    assert!(matches.iter().any(|value| value["kind"] == "type"));
    assert!(matches.iter().any(|value| value["kind"] == "content"));

    let replacement = serde_json::json!({
        "id": "replacement",
        "command": "workspace.replacePreview",
        "payload": {
            "root": root,
            "query": "load",
            "replacement": "fetch",
            "caseSensitive": false,
            "wholeWords": false,
            "regularExpression": false,
            "paths": [relative]
        }
    });
    let replacement_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&replacement).expect("replacement request should encode"),
    ))
    .expect("replacement response should be JSON");
    assert_eq!(replacement_response["ok"], true);
    assert_eq!(
        replacement_response["data"]["files"][0]["matches"][0]["after"],
        "    void fetchUser() {}"
    );
    assert_eq!(
        replacement_response["data"]["files"][0]["replacementText"],
        "class UserService {\n    void fetchUser() {}\n}\n"
    );

    let mut override_request = serde_json::json!({
        "id": "override",
        "command": "workspace.replacePreview",
        "payload": {
            "root": root,
            "query": "fetch",
            "replacement": "load",
            "paths": [relative],
            "textOverrides": {}
        }
    });
    override_request["payload"]["textOverrides"][relative] =
        serde_json::json!("class UserService {\n    void fetchUser() {}\n}\n");
    let override_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&override_request).expect("override request should encode"),
    ))
    .expect("override response should be JSON");
    assert_eq!(override_response["ok"], true);
    assert_eq!(
        override_response["data"]["files"][0]["matches"][0]["before"],
        "    void fetchUser() {}"
    );

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn file_mask_limits_search_to_matching_extensions() {
    let root = temporary_root("file-mask");
    fs::create_dir_all(root.join("src")).expect("fixture directory should be creatable");
    fs::write(root.join("src/Service.java"), "int total = 1;\n")
        .expect("java fixture should be writable");
    fs::write(root.join("src/notes.txt"), "int total = 2;\n")
        .expect("text fixture should be writable");

    let search = |mask: &str| -> Vec<String> {
        let request = serde_json::json!({
            "id": "mask",
            "command": "workspace.search",
            "payload": {
                "root": root,
                "query": "total",
                "fileMask": mask
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("search request should encode"),
        ))
        .expect("search response should be JSON");
        assert_eq!(response["ok"], true);
        response["data"]["matches"]
            .as_array()
            .expect("matches should be an array")
            .iter()
            .map(|value| value["path"].as_str().unwrap_or_default().to_string())
            .collect()
    };

    let unfiltered = search("");
    assert!(unfiltered.iter().any(|path| path.ends_with("Service.java")));
    assert!(unfiltered.iter().any(|path| path.ends_with("notes.txt")));

    let java_only = search("*.java");
    assert!(java_only.iter().any(|path| path.ends_with("Service.java")));
    assert!(!java_only.iter().any(|path| path.ends_with("notes.txt")));

    // Multiple masks form a union, and whitespace after commas is ignored.
    let both = search("*.java, *.txt");
    assert!(both.iter().any(|path| path.ends_with("Service.java")));
    assert!(both.iter().any(|path| path.ends_with("notes.txt")));

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn preserve_case_matches_original_occurrence_shape() {
    let root = temporary_root("preserve-case");
    fs::create_dir_all(&root).expect("fixture directory should be creatable");
    let relative = "Sample.java";
    fs::write(root.join(relative), "fooBar FooBar FOOBAR fooBar();\n")
        .expect("fixture should be writable");

    let replace = |preserve_case: bool| -> String {
        let request = serde_json::json!({
            "id": "preserve",
            "command": "workspace.replacePreview",
            "payload": {
                "root": root,
                "query": "fooBar",
                "replacement": "bazQux",
                "caseSensitive": false,
                "preserveCase": preserve_case,
                "paths": [relative]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("replace request should encode"),
        ))
        .expect("replace response should be JSON");
        assert_eq!(response["ok"], true);
        response["data"]["files"][0]["matches"][0]["after"]
            .as_str()
            .expect("after text should be a string")
            .to_string()
    };

    assert_eq!(replace(false), "bazQux bazQux bazQux bazQux();");
    assert_eq!(replace(true), "bazQux BazQux BAZQUX bazQux();");

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
}

#[test]
fn local_history_records_deduplicates_lists_and_relocates() {
    let root = temporary_root("history");
    fs::create_dir_all(&root).expect("history workspace should be creatable");
    let storage = root.join("history-storage");

    let request = |command: &str, payload: Value| -> Value {
        let request = serde_json::json!({
            "id": command,
            "command": command,
            "payload": payload
        });
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("history request should encode"),
        ))
        .expect("history response should be JSON")
    };

    let record_payload = |content: &str| {
        serde_json::json!({
            "workspaceRoot": root,
            "storageRoot": storage,
            "path": "src/Main.java",
            "reason": "saved",
            "content": content,
            "hiddenDirectoryNames": [],
            "hiddenFilePatterns": []
        })
    };
    let first = request("history.record", record_payload("one\n"));
    assert_eq!(first["ok"], true);
    assert!(first["data"]["id"].as_str().is_some());
    let duplicate = request("history.record", record_payload("one\n"));
    assert_eq!(duplicate["ok"], true);
    assert!(duplicate["data"].is_null());
    let mut invalid_reason = record_payload("invalid\n");
    invalid_reason["reason"] = serde_json::json!("not-a-history-reason");
    let invalid = request("history.record", invalid_reason);
    assert_eq!(invalid["ok"], false);
    assert_eq!(invalid["error"]["code"], "invalid_request");

    let second = request("history.record", record_payload("two\n"));
    assert_eq!(second["ok"], true);
    let second_id = second["data"]["id"]
        .as_str()
        .expect("recorded history entry should have an ID");
    let renamed = request(
        "history.rename",
        serde_json::json!({
            "storageRoot": storage,
            "path": "src/Main.java",
            "id": second_id,
            "label": "before refactor"
        }),
    );
    assert_eq!(renamed["ok"], true, "{renamed}");
    assert_eq!(renamed["data"]["label"], "before refactor");
    let listed = request(
        "history.entries",
        serde_json::json!({
            "workspaceRoot": root,
            "storageRoot": storage,
            "path": "src/Main.java"
        }),
    );
    assert_eq!(listed["ok"], true);
    assert_eq!(listed["data"]["entries"].as_array().unwrap().len(), 2);
    assert_eq!(listed["data"]["entries"][0]["label"], "before refactor");
    let content_path = listed["data"]["entries"][0]["contentPath"]
        .as_str()
        .unwrap();
    let content = request(
        "history.content",
        serde_json::json!({
            "storageRoot": storage,
            "contentPath": content_path
        }),
    );
    assert_eq!(content["data"]["text"], "two\n");

    let deleted = request(
        "history.delete",
        serde_json::json!({
            "storageRoot": storage,
            "path": "src/Main.java",
            "id": second_id
        }),
    );
    assert_eq!(deleted["ok"], true, "{deleted}");
    let after_delete = request(
        "history.entries",
        serde_json::json!({
            "workspaceRoot": root,
            "storageRoot": storage,
            "path": "src/Main.java"
        }),
    );
    assert_eq!(after_delete["data"]["entries"].as_array().unwrap().len(), 1);

    for invalid_id in ["../outside", "entry.json", ""] {
        let invalid_entry = request(
            "history.delete",
            serde_json::json!({
                "storageRoot": storage,
                "path": "src/Main.java",
                "id": invalid_id
            }),
        );
        assert_eq!(invalid_entry["ok"], false, "ID {invalid_id} should fail");
        assert_eq!(invalid_entry["error"]["code"], "invalid_request");
    }

    let relocated = request(
        "history.relocate",
        serde_json::json!({
            "storageRoot": storage,
            "sourcePath": "src/Main.java",
            "destinationPath": "src/Renamed.java"
        }),
    );
    assert_eq!(relocated["ok"], true);
    let relocated_entries = request(
        "history.entries",
        serde_json::json!({
            "workspaceRoot": root,
            "storageRoot": storage,
            "path": "src/Renamed.java"
        }),
    );
    assert_eq!(
        relocated_entries["data"]["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let traversal = request(
        "history.content",
        serde_json::json!({
            "storageRoot": storage,
            "contentPath": "../outside.snapshot"
        }),
    );
    assert_eq!(traversal["ok"], false);
    assert_eq!(traversal["error"]["code"], "invalid_request");
    fs::remove_dir_all(root).expect("history workspace should be removable");
}

#[test]
fn local_history_honors_the_unified_hidden_path_patterns() {
    let root = temporary_root("history-patterns");
    fs::create_dir_all(&root).expect("history workspace should be creatable");
    let storage = root.join("history-storage");
    let patterns = serde_json::json!(["**/generated/", ".lithe/*", "*.log", "secret.txt"]);

    let record = |path: &str| -> Value {
        let request = serde_json::json!({
            "id": "record",
            "command": "history.record",
            "payload": {
                "workspaceRoot": root,
                "storageRoot": storage,
                "path": path,
                "reason": "saved",
                "content": "text\n",
                "hiddenDirectoryNames": [],
                "hiddenFilePatterns": patterns
            }
        });
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("history request should encode"),
        ))
        .expect("history response should be JSON")
    };

    // Folder rules stop snapshots below the folder at any depth (`**/`) or only
    // at the project root, and file rules match by glob or exact name.
    for hidden in [
        "generated/Out.java",
        "modules/a/generated/Out.java",
        ".lithe/project.json",
        "build.log",
        "src/secret.txt",
    ] {
        let response = record(hidden);
        assert_eq!(response["ok"], true, "{hidden}: {response}");
        assert!(
            response["data"].is_null(),
            "{hidden} should not be recorded"
        );
    }
    for visible in ["src/Main.java", "modules/.lithe/project.json"] {
        let response = record(visible);
        assert_eq!(response["ok"], true, "{visible}: {response}");
        assert!(
            response["data"]["id"].as_str().is_some(),
            "{visible} should be recorded"
        );
    }
    fs::remove_dir_all(root).expect("history workspace should be removable");
}

#[test]
fn file_commands_round_trip_and_reject_traversal() {
    let root = temporary_root("file");
    let outside = temporary_root("outside");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    fs::create_dir_all(&outside).expect("outside directory should be creatable");

    let write = serde_json::json!({
        "id": "write",
        "command": "file.write",
        "payload": {"root": root, "path": "nested/example.txt", "text": "hello"}
    });
    let write_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&write).expect("write request should encode"),
    ))
    .expect("write response should be JSON");
    assert_eq!(write_response["ok"], true);

    let read = serde_json::json!({
        "id": "read",
        "command": "file.read",
        "payload": {"root": root, "path": "nested/example.txt"}
    });
    let read_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&read).expect("read request should encode"),
    ))
    .expect("read response should be JSON");
    assert_eq!(read_response["data"]["text"], "hello");

    let traversal = serde_json::json!({
        "id": "traversal",
        "command": "file.read",
        "payload": {"root": root, "path": "../outside.txt"}
    });
    let traversal_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&traversal).expect("traversal request should encode"),
    ))
    .expect("traversal response should be JSON");
    assert_eq!(traversal_response["ok"], false);
    assert_eq!(traversal_response["error"]["code"], "invalid_request");

    for path in [
        "..\\outside.txt",
        "nested\\..\\outside.txt",
        "C:\\outside.txt",
    ] {
        let request = serde_json::json!({
            "id": "windows-path",
            "command": "file.read",
            "payload": {"root": root, "path": path}
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("Windows path request should encode"),
        ))
        .expect("Windows path response should be JSON");
        assert_eq!(response["ok"], false, "path {path} should be rejected");
        assert_eq!(response["error"]["code"], "invalid_request");
    }

    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&outside, root.join("link"))
            .expect("test symlink should be creatable");
        let symlink_write = serde_json::json!({
            "id": "symlink-write",
            "command": "file.write",
            "payload": {"root": root, "path": "link/escape.txt", "text": "outside"}
        });
        let symlink_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&symlink_write).expect("symlink request should encode"),
        ))
        .expect("symlink response should be JSON");
        assert_eq!(symlink_response["ok"], false);
        assert_eq!(symlink_response["error"]["code"], "permission_denied");
        assert!(!outside.join("escape.txt").exists());
    }

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
    fs::remove_dir_all(outside).expect("outside fixture should be removable");
}

#[test]
fn document_lifecycle_matches_the_cross_platform_fixture() {
    let fixture_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../shared/fixtures/documents/lifecycle-v1.json");
    let fixture: Value = serde_json::from_str(
        &fs::read_to_string(fixture_path).expect("document lifecycle fixture should be readable"),
    )
    .expect("document lifecycle fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("document lifecycle cases should be an array")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "document.lifecycle",
            "payload": {
                "state": case["state"],
                "event": case["event"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("document lifecycle response should be valid JSON");
        assert_eq!(
            response["data"], case["expected"],
            "fixture case {}",
            case["name"]
        );
    }
}

#[test]
fn search_everywhere_streams_names_before_content_index_and_preserves_the_final_response() {
    use std::sync::{Arc, Mutex};
    let root = temporary_root("search-stream-names-first");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::create_dir_all(&root).unwrap();
    let file = root.join("Name.java");
    fs::write(&file, "class Before {}").unwrap();
    let events = Arc::new(Mutex::new(Vec::<Value>::new()));
    let received = events.clone();
    let request = serde_json::json!({ "command": "workspace.searchEverywhere", "operationId": "stream-search",
        "timeoutMilliseconds": 5000, "payload": { "root": root, "query": "Name", "maxResults": 20,
            "maxFileResults": 2, "maxSymbolResults": 2, "maxContentResults": 0 } }).to_string();
    let response: Value = serde_json::from_str(&crate::execute_json_with_events(
        &request,
        Arc::new(move |raw| {
            let event: Value = serde_json::from_str(raw).unwrap();
            if event["type"] != "searchResults" {
                return;
            }
            let mut events = received.lock().unwrap();
            if events.is_empty() {
                assert_eq!(event["results"]["matches"][0]["kind"], "file");
                // If content was indexed first, this new class would be absent from the final response.
                fs::write(&file, "class Name { void NameMethod() {} }").unwrap();
            }
            assert_eq!(event["operationId"], "stream-search");
            events.push(event);
        }),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    assert!(events.lock().unwrap().len() >= 2);
    assert!(response["data"]["matches"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| item["kind"] == "type"));
    let synchronous: Value = serde_json::from_str(&execute_json(&request)).unwrap();
    assert_eq!(response["data"], synchronous["data"]);

    // A query replaced while the first batch is being delivered stops before later providers.
    let cancelled: Value = serde_json::from_str(&crate::execute_json_with_events(
        &request,
        Arc::new(|raw| {
            let event: Value = serde_json::from_str(raw).unwrap();
            if event["type"] == "searchResults" {
                assert!(crate::cancel_operation("stream-search"));
            }
        }),
    ))
    .unwrap();
    assert_eq!(cancelled["error"]["code"], "cancelled", "{cancelled}");
}

#[test]
fn search_everywhere_pages_all_sources_past_200_without_duplicates_or_missing_matches() {
    let root = temporary_root("search-keyset-pages");
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::create_dir_all(&root).unwrap();
    for index in 0..257 {
        fs::write(
            root.join(format!("Name{index:03}.java")),
            format!("class Name{index:03} {{\n    void NameMethod{index:03}() {{}}\n}}\n"),
        )
        .unwrap();
    }
    fs::write(root.join("NameHidden.java"), "class NameHidden {}\n").unwrap();
    let call = |payload: Value| -> Value {
        serde_json::from_str(&execute_json(&serde_json::json!({
            "command": "workspace.searchEverywhere", "timeoutMilliseconds": 5000, "payload": payload
        }).to_string())).unwrap()
    };
    let base = serde_json::json!({ "root": root, "query": "Name", "pageSize": 50,
        "hiddenFilePatterns": ["NameHidden.java"] });
    for kinds in [
        vec!["file"],
        vec!["type"],
        vec!["symbol"],
        vec!["content"],
        vec!["file", "type", "symbol", "content"],
    ] {
        let mut payload = base.clone();
        payload["resultKinds"] = serde_json::json!(kinds);
        let mut seen = std::collections::HashSet::new();
        let mut sizes = Vec::new();
        for _ in 0..16 {
            let response = call(payload.clone());
            assert_eq!(response["ok"], true, "{response}");
            let matches = response["data"]["matches"].as_array().unwrap();
            sizes.push(matches.len());
            assert!(matches.len() <= 50 * kinds.len());
            for item in matches {
                assert!(kinds.contains(&item["kind"].as_str().unwrap()));
                assert_ne!(item["path"], "NameHidden.java");
                assert!(
                    seen.insert((
                        item["kind"].clone().to_string(),
                        item["path"].clone().to_string(),
                        item["line"].clone().to_string(),
                        item["symbolName"].clone().to_string()
                    )),
                    "duplicate {item}"
                );
            }
            let cursor = &response["data"]["nextCursor"];
            if cursor.is_null() {
                break;
            }
            assert_ne!(cursor, &payload["cursor"]);
            payload["cursor"] = cursor.clone();
        }
        let counts: Vec<usize> = kinds
            .iter()
            .map(|kind| if *kind == "content" { 514 } else { 257 })
            .collect();
        let expected: Vec<usize> = (0..counts.iter().max().unwrap().div_ceil(50))
            .map(|page| {
                counts
                    .iter()
                    .map(|count| count.saturating_sub(page * 50).min(50))
                    .sum()
            })
            .collect();
        assert_eq!(sizes, expected, "{kinds:?}");
        assert_eq!(seen.len(), counts.iter().sum::<usize>());
    }
    let mut payload = base.clone();
    payload["resultKinds"] = serde_json::json!(["file"]);
    let first = call(payload.clone());
    payload["cursor"] = first["data"]["nextCursor"].clone();
    for (key, value) in [
        ("query", serde_json::json!("Other")),
        ("pageSize", serde_json::json!(49)),
        ("resultKinds", serde_json::json!(["type"])),
        ("root", serde_json::json!(root.join("other"))),
        ("hiddenFilePatterns", serde_json::json!([])),
        ("cursor", serde_json::json!("malformed")),
    ] {
        let mut changed = payload.clone();
        changed[key] = value;
        assert_eq!(
            call(changed)["ok"],
            false,
            "cursor must reject a different {key}"
        );
    }
    for (query, expected) in [("^Name0[0-4][0-9]\\.java$", 50), ("^missing$", 0), ("", 0)] {
        let mut exact = base.clone();
        exact["query"] = serde_json::json!(query);
        exact["regularExpression"] = serde_json::json!(true);
        exact["resultKinds"] = serde_json::json!(["file"]);
        let response = call(exact);
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(
            response["data"]["matches"].as_array().unwrap().len(),
            expected
        );
        assert!(response["data"]["nextCursor"].is_null());
    }
    let ranked = root.join("ranked");
    for path in [
        "Name.java",
        "NameExtra.java",
        "OtherName.java",
        "NameLongSuffix.java",
        "nested/Name.java",
    ] {
        let file = ranked.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, "").unwrap();
    }
    let mut ranking = serde_json::json!({"root": ranked, "query": "Name", "maxFileResults": 50,
        "maxSymbolResults": 0, "maxContentResults": 0});
    let legacy = call(ranking.clone());
    assert_eq!(legacy["ok"], true);
    ranking["pageSize"] = serde_json::json!(2);
    let mut matches = Vec::new();
    for _ in 0..3 {
        let response = call(ranking.clone());
        assert_eq!(response["ok"], true);
        matches.extend(
            response["data"]["matches"]
                .as_array()
                .unwrap()
                .iter()
                .cloned(),
        );
        ranking["cursor"] = response["data"]["nextCursor"].clone();
    }
    assert!(ranking["cursor"].is_null());
    assert_eq!(serde_json::json!(matches), legacy["data"]["matches"]);
    let large = root.join("large");
    fs::create_dir_all(&large).unwrap();
    fs::write(
        large.join("minified.json"),
        format!("Name{}\nName second\n", "x".repeat(70_000)),
    )
    .unwrap();
    let mut long_line = serde_json::json!({"root": large, "query": "Name", "pageSize": 1, "resultKinds": ["content"]});
    let first = call(long_line.clone());
    assert_eq!(first["ok"], true);
    assert!(first["data"]["nextCursor"].as_str().unwrap().len() < 1024);
    long_line["cursor"] = first["data"]["nextCursor"].clone();
    let second = call(long_line);
    assert_eq!(second["ok"], true);
    assert_eq!(second["data"]["matches"][0]["line"], 2);
    assert!(second["data"]["nextCursor"].is_null());
    for size in [0, 201] {
        let mut invalid = base.clone();
        invalid["pageSize"] = serde_json::json!(size);
        assert_eq!(call(invalid)["ok"], false);
    }
}
