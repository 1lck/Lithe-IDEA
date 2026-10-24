//! File watching and tree walks.

mod support;

use lithe_remote_client::api::{WatchEvent, WatchHandle};
use lithe_remote_protocol::methods::{ChangeKind, FileKind, WatchErrorCode};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};
use support::{connect, TempDir, STEP_TIMEOUT};

/// Collects changes until every path in `expected` was reported with its
/// kind. Watch batches are delivered asynchronously, so the wait is bounded
/// by events rather than by time.
fn wait_for_changes(
    watch: &WatchHandle<'_>,
    expected: &[(&str, ChangeKind)],
) -> BTreeMap<String, ChangeKind> {
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut seen = BTreeMap::new();
    while !expected
        .iter()
        .all(|(path, kind)| seen.get(*path) == Some(kind))
    {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match watch.next_event(remaining) {
            Ok(Some(WatchEvent::Changed(batch))) => {
                assert!(!batch.overflow, "unexpected overflow");
                for change in batch.changes {
                    seen.insert(change.path, change.kind);
                }
            }
            other => panic!("waiting for {expected:?}: {other:?}; seen {seen:?}"),
        }
    }
    seen
}

/// Asserts that no batch mentioning `path` arrives within `quiet`.
fn assert_not_reported(watch: &WatchHandle<'_>, path: &str, quiet: Duration) {
    let deadline = Instant::now() + quiet;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }
        match watch.next_event(remaining) {
            Ok(Some(WatchEvent::Changed(batch))) => assert!(
                batch
                    .changes
                    .iter()
                    .all(|change| !change.path.starts_with(path)),
                "{path} was reported: {batch:?}"
            ),
            Ok(Some(other)) => panic!("unexpected {other:?}"),
            Ok(None) => panic!("the watch subscription ended"),
            Err(_) => return,
        }
    }
}

#[test]
fn watches_report_creation_modification_and_deletion() {
    let root = TempDir::new("watch");
    let (session, _events) = connect();
    let watch = session.watch(root.str(), &[]).unwrap();

    let file = root.join("a.txt");
    std::fs::write(&file, b"one").unwrap();
    wait_for_changes(&watch, &[(&file, ChangeKind::Created)]);

    std::fs::write(&file, b"two").unwrap();
    wait_for_changes(&watch, &[(&file, ChangeKind::Modified)]);

    std::fs::remove_file(&file).unwrap();
    wait_for_changes(&watch, &[(&file, ChangeKind::Deleted)]);

    watch.stop().unwrap();
    drop(watch);
    session.shutdown(STEP_TIMEOUT);
}

// A directory tree created at once, as `git checkout` or `mkdir -p` do,
// must be fully reported, including files written before a per-directory
// backend could register the new directories.
#[test]
fn new_directory_trees_are_reported_completely() {
    let root = TempDir::new("watch-tree");
    let (session, _events) = connect();
    let watch = session.watch(root.str(), &[]).unwrap();

    std::fs::create_dir_all(root.path().join("src/main/java")).unwrap();
    std::fs::write(root.path().join("src/main/java/App.java"), b"class App {}").unwrap();
    let app = root.join("src/main/java/App.java");
    let seen = wait_for_changes(&watch, &[(&app, ChangeKind::Created)]);
    assert!(seen.contains_key(&root.join("src")), "{seen:?}");

    // The new directories are watched as well, not just reported.
    std::fs::write(&app, b"class App { }").unwrap();
    wait_for_changes(&watch, &[(&app, ChangeKind::Modified)]);
    drop(watch);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn excluded_directories_are_not_reported() {
    let root = TempDir::new("watch-exclude");
    std::fs::create_dir_all(root.path().join("node_modules/pkg")).unwrap();
    let (session, _events) = connect();
    let watch = session.watch(root.str(), &["node_modules"]).unwrap();

    std::fs::write(root.path().join("node_modules/pkg/index.js"), b"x").unwrap();
    std::fs::write(root.path().join("visible.txt"), b"x").unwrap();
    wait_for_changes(&watch, &[(&root.join("visible.txt"), ChangeKind::Created)]);
    assert_not_reported(
        &watch,
        &root.join("node_modules"),
        Duration::from_millis(400),
    );
    drop(watch);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn removing_the_watched_root_ends_the_watch() {
    let parent = TempDir::new("watch-root");
    let root = parent.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (session, _events) = connect();
    let watch = session.watch(root.to_str().unwrap(), &[]).unwrap();
    std::fs::remove_dir(&root).unwrap();

    let deadline = Instant::now() + STEP_TIMEOUT;
    loop {
        match watch.next_event(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(WatchEvent::Error(error))) => {
                assert_eq!(error.code, WatchErrorCode::RootRemoved);
                break;
            }
            Ok(Some(WatchEvent::Changed(_))) => {}
            other => panic!("expected the root removal: {other:?}"),
        }
    }
    assert!(session.state().unwrap().watches.is_empty());
    drop(watch);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn walks_list_trees_in_order_without_following_links() {
    let root = TempDir::new("walk");
    for path in [
        "b/x.txt",
        "a/z.txt",
        "a/y/deep.txt",
        "target/out.class",
        "c.txt",
    ] {
        let path = root.path().join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"").unwrap();
    }
    std::os::unix::fs::symlink("/", root.path().join("link-to-root")).unwrap();
    let (session, _events) = connect();

    let outcome = session
        .walk(root.str(), &["target"], None, STEP_TIMEOUT)
        .unwrap();
    let listed: Vec<(&str, FileKind)> = outcome
        .entries
        .iter()
        .map(|entry| (entry.path.as_str(), entry.kind))
        .collect();
    assert_eq!(
        listed,
        [
            ("a", FileKind::Directory),
            ("a/y", FileKind::Directory),
            ("a/y/deep.txt", FileKind::File),
            ("a/z.txt", FileKind::File),
            ("b", FileKind::Directory),
            ("b/x.txt", FileKind::File),
            ("c.txt", FileKind::File),
            ("link-to-root", FileKind::Symlink),
            // Excluded directories are listed but not descended into.
            ("target", FileKind::Directory),
        ]
    );
    assert!(!outcome.done.truncated);
    assert_eq!(outcome.done.total, 9);

    let limited = session
        .walk(root.str(), &[], Some(3), STEP_TIMEOUT)
        .unwrap();
    assert_eq!(limited.entries.len(), 3);
    assert!(limited.done.truncated);
    session.shutdown(STEP_TIMEOUT);
}
