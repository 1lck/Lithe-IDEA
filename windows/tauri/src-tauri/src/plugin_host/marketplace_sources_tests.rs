//! M2 source-management tests exercise the internal functions directly (the
//! Tauri commands are thin AppHandle wrappers): preset rebuild from host
//! constants, the FNV source ID standard answers shared with macOS,
//! duplicate and official-source refusal, the Lithe Store tombstone, and the
//! corrupted-store handling. Everything runs offline; URL resolution goes
//! through the real Core `plugins.marketplace.resolveSource` command, whose
//! golden answers live in the shared `source-urls.json` fixture.

mod marketplace_sources_tests {
    use crate::plugin_host::marketplace_sources::{
        add_source, load_sources, remove_source, save_sources, set_enabled,
        source_id_for_index_url, source_view, COMMUNITY_INDEX_URL, MAXIMUM_CORRUPTION_BACKUPS,
        OFFICIAL_INDEX_URL, OFFICIAL_SOURCE_ID,
    };
    use serde_json::{json, Value};
    use std::path::{Path, PathBuf};

    /// Fixed standard answers, matching the macOS FNV-1a derivation; the
    /// expectations are literals, never recomputed by the code under test.
    const COMMUNITY_SOURCE_ID: &str = "source-39170ddcae1870bf";
    const EXAMPLE_INDEX_URL: &str =
        "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json";
    const EXAMPLE_SOURCE_ID: &str = "source-94ba41e9fc33730a";

    fn unique_temp_root(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-marketplace-sources-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp root");
        root
    }

    fn sources_path(root: &Path) -> PathBuf {
        root.join("plugin-marketplace").join("sources.json")
    }

    fn cleanup(root: &Path) {
        let _ = std::fs::remove_dir_all(root);
    }

    fn ids(sources: &[Value]) -> Vec<String> {
        sources
            .iter()
            .filter_map(|source| source["id"].as_str().map(str::to_string))
            .collect()
    }

    #[test]
    fn standard_source_ids_match_the_fixed_answers() {
        assert_eq!(
            source_id_for_index_url(COMMUNITY_INDEX_URL),
            COMMUNITY_SOURCE_ID
        );
        assert_eq!(
            source_id_for_index_url(EXAMPLE_INDEX_URL),
            EXAMPLE_SOURCE_ID
        );
        // The official source is a host constant, not a hash.
        assert_eq!(OFFICIAL_SOURCE_ID, "lithe-official");
    }

    #[test]
    fn preset_sources_rebuild_from_host_constants() {
        let root = unique_temp_root("presets");
        let (sources, problem) = load_sources(&sources_path(&root)).expect("defaults load");
        assert_eq!(
            ids(&sources.iter().map(source_view).collect::<Vec<_>>()),
            vec![
                OFFICIAL_SOURCE_ID.to_string(),
                COMMUNITY_SOURCE_ID.to_string(),
            ]
        );
        assert_eq!(sources[0].name, "Lithe");
        assert_eq!(sources[0].index_url, OFFICIAL_INDEX_URL);
        assert_eq!(sources[1].name, "Lithe Store");
        assert_eq!(sources[1].id, COMMUNITY_SOURCE_ID);
        assert!(sources[1]
            .index_url
            .starts_with("https://raw.githubusercontent.com/Lithe-IDEA/Lithe-store/"));
        assert!(problem.is_none());
        let views: Vec<Value> = sources.iter().map(source_view).collect();
        assert_eq!(views[0]["deletable"], json!(false));
        assert_eq!(views[0]["kind"], json!("official"));
        assert_eq!(views[1]["deletable"], json!(true));
        assert_eq!(views[1]["kind"], json!("thirdParty"));
        cleanup(&root);
    }

    #[test]
    fn add_source_resolves_through_core_with_the_standard_answers() {
        let root = unique_temp_root("add");
        let path = sources_path(&root);
        let sources = add_source(&path, "https://github.com/example/lithe-plugins")
            .expect("github repository resolves");
        assert_eq!(sources.len(), 3);
        let added = sources.last().expect("added source");
        assert_eq!(added.id, EXAMPLE_SOURCE_ID);
        assert_eq!(added.index_url, EXAMPLE_INDEX_URL);
        assert_eq!(added.name, "example/lithe-plugins");
        assert_eq!(
            added.repository.as_deref(),
            Some("https://github.com/example/lithe-plugins")
        );
        assert!(added.is_enabled);
        // The added source survives a restart.
        let (reloaded, problem) = load_sources(&path).expect("reload");
        assert!(problem.is_none());
        assert!(reloaded.iter().any(|source| source.id == EXAMPLE_SOURCE_ID));
        cleanup(&root);
    }

    #[test]
    fn add_source_keeps_core_rejection_codes() {
        let root = unique_temp_root("invalid");
        let path = sources_path(&root);
        let plain_http = add_source(&path, "http://plugins.example.com/index.json")
            .expect_err("plain http is refused");
        assert!(plain_http.contains("plugin.source.invalid"), "{plain_http}");
        let empty = add_source(&path, "   ").expect_err("empty input is refused");
        assert!(
            empty.contains("plugin.marketplace.sources.emptyInput"),
            "{empty}"
        );
        let (sources, _) = load_sources(&path).expect("nothing was added");
        assert_eq!(sources.len(), 2);
        cleanup(&root);
    }

    #[test]
    fn duplicate_add_is_refused_and_state_is_kept() {
        let root = unique_temp_root("duplicate");
        let path = sources_path(&root);
        add_source(&path, "https://github.com/example/lithe-plugins").expect("first add");
        set_enabled(&path, EXAMPLE_SOURCE_ID, false).expect("disable");
        // Same index under a different host case, `.git` suffix, surrounding
        // whitespace, and a trailing slash: Core normalizes all of it to the
        // same index URL, so the host must refuse the duplicate.
        let duplicate = add_source(&path, " https://GitHub.com/EXAMPLE/lithe-plugins.git/ ")
            .expect_err("duplicate source is refused");
        assert!(
            duplicate.contains("plugin.marketplace.sourceAlreadyAdded"),
            "{duplicate}"
        );
        let (sources, _) = load_sources(&path).expect("reload");
        assert_eq!(
            sources.len(),
            3,
            "only official, community, and the original entry"
        );
        let example = sources
            .iter()
            .find(|s| s.id == EXAMPLE_SOURCE_ID)
            .expect("kept");
        assert!(!example.is_enabled, "the stored enabled state survives");
        cleanup(&root);
    }

    #[test]
    fn official_source_cannot_be_removed() {
        let root = unique_temp_root("official");
        let path = sources_path(&root);
        let refused =
            remove_source(&path, OFFICIAL_SOURCE_ID).expect_err("official is undeletable");
        assert!(
            refused.contains("plugin.marketplace.officialSourceCannotBeRemoved"),
            "{refused}"
        );
        let (sources, _) = load_sources(&path).expect("reload");
        assert!(sources.iter().any(|source| source.id == OFFICIAL_SOURCE_ID));
        cleanup(&root);
    }

    #[test]
    fn community_removal_tombstones_across_restarts() {
        let root = unique_temp_root("tombstone");
        let path = sources_path(&root);
        let remaining = remove_source(&path, COMMUNITY_SOURCE_ID).expect("community is removable");
        assert!(!remaining
            .iter()
            .any(|source| source.id == COMMUNITY_SOURCE_ID));
        let persisted = std::fs::read_to_string(&path).expect("store file");
        assert!(
            persisted.contains(COMMUNITY_SOURCE_ID) && persisted.contains("removedPresetSourceIDs"),
            "the removal tombstone is persisted: {persisted}"
        );
        // A restart rebuilds from constants: Lithe Store stays removed.
        let (sources, _) = load_sources(&path).expect("reload");
        assert!(!sources
            .iter()
            .any(|source| source.id == COMMUNITY_SOURCE_ID));
        assert!(sources.iter().any(|source| source.id == OFFICIAL_SOURCE_ID));
        cleanup(&root);
    }

    #[test]
    fn readding_community_restores_the_preset_identity() {
        let root = unique_temp_root("readd");
        let path = sources_path(&root);
        remove_source(&path, COMMUNITY_SOURCE_ID).expect("remove first");
        let sources = add_source(&path, "https://github.com/Lithe-IDEA/Lithe-store")
            .expect("the store URL resolves back to the preset");
        assert_eq!(
            sources
                .iter()
                .filter(|s| s.id == COMMUNITY_SOURCE_ID)
                .count(),
            1,
            "Lithe Store takes its preset ID back"
        );
        let persisted = std::fs::read_to_string(&path).expect("store file");
        let file: Value = serde_json::from_str(&persisted).expect("valid JSON");
        assert!(
            file.get("removedPresetSourceIDs").is_none(),
            "the tombstone is cleared: {persisted}"
        );
        let (reloaded, _) = load_sources(&path).expect("reload");
        assert_eq!(
            reloaded
                .iter()
                .filter(|source| source.id == COMMUNITY_SOURCE_ID)
                .count(),
            1,
            "no duplicate stand-in after a restart"
        );
        cleanup(&root);
    }

    #[test]
    fn hand_added_store_url_under_different_case_stands_in_for_the_preset() {
        let root = unique_temp_root("standin");
        let path = sources_path(&root);
        // Lithe Store added by hand before it became a preset, typed with a
        // differently cased host: that entry keeps the ID its plugins
        // recorded and stands in for the preset.
        std::fs::create_dir_all(path.parent().expect("parent")).expect("store dir");
        std::fs::write(
            &path,
            json!({
                "schemaVersion": 1,
                "sources": [{
                    "id": "source-legacy1",
                    "name": "Lithe Store",
                    "input": "https://RAW.GitHubUserContent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json",
                    "indexURL": "https://RAW.GitHubUserContent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json",
                    "repository": "https://github.com/Lithe-IDEA/Lithe-store",
                    "isEnabled": true,
                }],
            })
            .to_string(),
        )
        .expect("store file");
        let (sources, _) = load_sources(&path).expect("reload");
        assert_eq!(sources.len(), 2, "official plus the standing-in entry");
        assert!(sources.iter().any(|source| source.id == "source-legacy1"));
        assert!(
            !sources
                .iter()
                .any(|source| source.id == COMMUNITY_SOURCE_ID),
            "the preset must not be appended next to its stand-in"
        );
        cleanup(&root);
    }

    #[test]
    fn corrupted_store_is_preserved_and_reported() {
        let root = unique_temp_root("corrupt");
        let path = sources_path(&root);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("store dir");
        std::fs::write(&path, "{ not json").expect("corrupt store");
        let (sources, problem) = load_sources(&path).expect("rebuild from presets");
        assert!(sources.len() == 2, "presets only");
        let diagnosis = problem.expect("the corruption is diagnosable");
        assert!(
            diagnosis.contains("plugin.marketplace.sources.corrupt"),
            "{diagnosis}"
        );
        let corrupt_copy = path.with_extension("json.corrupt-1");
        assert_eq!(
            std::fs::read_to_string(&corrupt_copy).expect("preserved bytes"),
            "{ not json",
            "the user's data is kept for diagnosis"
        );
        assert!(!path.exists(), "the unreadable file moved aside");
        cleanup(&root);
    }

    #[test]
    fn exhausted_backup_slots_preserve_the_store_and_every_backup() {
        let root = unique_temp_root("corrupt-full");
        let path = sources_path(&root);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("store dir");
        // Every backup slot holds distinct user data from earlier corruptions.
        for attempt in 1..=MAXIMUM_CORRUPTION_BACKUPS {
            std::fs::write(
                path.with_extension(format!("json.corrupt-{attempt}")),
                format!("BACKUP-{attempt}"),
            )
            .expect("seed backup");
        }
        std::fs::write(&path, "{ current corruption").expect("corrupt store");
        // No free slot remains: the load must fail with a diagnosable error
        // instead of deleting any user data.
        let failure = load_sources(&path).expect_err("no free backup slot");
        assert!(
            failure.contains("plugin.marketplace.sources.corrupt"),
            "{failure}"
        );
        assert!(failure.contains("backup slots"), "{failure}");
        assert_eq!(
            std::fs::read_to_string(&path).expect("original untouched"),
            "{ current corruption",
            "the unreadable store is never reset or overwritten"
        );
        for attempt in 1..=MAXIMUM_CORRUPTION_BACKUPS {
            assert_eq!(
                std::fs::read_to_string(path.with_extension(format!("json.corrupt-{attempt}")))
                    .expect("backup intact"),
                format!("BACKUP-{attempt}"),
                "backup {attempt} must be byte-identical"
            );
        }
        cleanup(&root);
    }

    #[test]
    fn failed_save_cleans_up_its_unique_temp_file() {
        let root = unique_temp_root("save-failure");
        let path = sources_path(&root);
        std::fs::create_dir_all(&path).expect("the store path is a directory, so rename fails");
        let (sources, _) =
            load_sources(&path.parent().unwrap().join("elsewhere.json")).expect("presets");
        let failure = save_sources(&path, &sources).expect_err("renaming onto a directory fails");
        assert!(!failure.is_empty());
        let store_dir = path.parent().expect("parent");
        let leftovers: Vec<_> = std::fs::read_dir(store_dir)
            .expect("store dir")
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("sources.json.tmp")
            })
            .collect();
        assert!(
            leftovers.is_empty(),
            "a failed save cleans up its own temp file: {leftovers:?}"
        );
        assert!(path.is_dir(), "the failing destination is left as it was");
        cleanup(&root);
    }

    #[test]
    fn consecutive_corruptions_keep_every_original() {
        let root = unique_temp_root("corrupt-chain");
        let path = sources_path(&root);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("store dir");
        // Two corruptions in a row must leave both originals on disk.
        std::fs::write(&path, "{ first corruption").expect("first store");
        load_sources(&path).expect("first rebuild");
        std::fs::write(&path, "{ second corruption").expect("second store");
        load_sources(&path).expect("second rebuild");
        assert_eq!(
            std::fs::read_to_string(path.with_extension("json.corrupt-1")).expect("first backup"),
            "{ first corruption",
            "the first user data survives the second corruption"
        );
        assert_eq!(
            std::fs::read_to_string(path.with_extension("json.corrupt-2")).expect("second backup"),
            "{ second corruption",
        );
        // A pre-existing backup file is never overwritten: the chain moves on.
        std::fs::write(path.with_extension("json.corrupt-2"), "USER-DATA-KEPT")
            .expect("seed backup");
        std::fs::write(&path, "{ third corruption").expect("third store");
        load_sources(&path).expect("third rebuild");
        assert_eq!(
            std::fs::read_to_string(path.with_extension("json.corrupt-2")).expect("seeded backup"),
            "USER-DATA-KEPT",
            "an existing backup must never be overwritten"
        );
        assert_eq!(
            std::fs::read_to_string(path.with_extension("json.corrupt-3")).expect("third backup"),
            "{ third corruption",
        );
        cleanup(&root);
    }

    /// Removes the temp root on success AND on failure paths, so a panicking
    /// test never leaves a directory behind for a still-running worker.
    struct TempRoot(PathBuf);

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn concurrent_transactions_do_not_lose_updates() {
        let root = TempRoot(unique_temp_root("concurrent"));
        let path = sources_path(&root.0);
        add_source(&path, "https://github.com/example/lithe-plugins").expect("seed one source");
        // Hold the host lock, then start another window's transaction on a
        // separate thread. The worker signals when it is about to enter the
        // transaction and again when it has finished; every wait is bounded.
        let guard = crate::plugin_host::marketplace_sources::sources_lock()
            .lock()
            .expect("test holds the lock");
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let spawned_path = path.clone();
        let worker = std::thread::spawn(move || {
            started_tx.send(()).expect("receiver alive");
            let result = add_source(&spawned_path, "https://github.com/other/lithe-plugins");
            // The completion signal is the worker's last action, so receiving
            // it bounds the whole wait.
            done_tx.send(()).expect("receiver alive");
            result
        });
        started_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("the worker reached the transaction entry");
        // While the guard is held the transaction cannot complete: the bounded
        // receive must time out instead of returning. A broken lock would make
        // this return Ok and fail the test.
        assert!(
            done_rx
                .recv_timeout(std::time::Duration::from_millis(1500))
                .is_err(),
            "the transaction must wait for the host lock, not run concurrently"
        );
        drop(guard);
        done_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("the transaction finishes once the lock is released");
        worker
            .join()
            .expect("worker thread terminates after signaling done");
        let (sources, _) = load_sources(&path).expect("reload");
        assert_eq!(
            sources.len(),
            4,
            "the seeded source and the concurrent addition both survive"
        );
        assert!(sources
            .iter()
            .any(|source| source.index_url == EXAMPLE_INDEX_URL));
        assert!(sources.iter().any(|source| {
            source.index_url
                == "https://raw.githubusercontent.com/other/lithe-plugins/HEAD/lithe-plugin-index.json"
        }));
    }

    #[test]
    fn enabled_state_survives_preset_rebuild() {
        let root = unique_temp_root("enabled");
        let path = sources_path(&root);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("store dir");
        std::fs::write(
            &path,
            json!({
                "schemaVersion": 1,
                "sources": [
                    {
                        "id": OFFICIAL_SOURCE_ID,
                        "name": "stale-name",
                        "input": "stale-input",
                        "indexURL": "stale-url",
                        "isEnabled": false,
                    },
                    {
                        "id": COMMUNITY_SOURCE_ID,
                        "name": "stale-store",
                        "input": "stale-input",
                        "indexURL": "stale-url",
                        "isEnabled": false,
                    },
                    {
                        "id": EXAMPLE_SOURCE_ID,
                        "name": "example/lithe-plugins",
                        "input": "https://github.com/example/lithe-plugins",
                        "indexURL": EXAMPLE_INDEX_URL,
                        "repository": "https://github.com/example/lithe-plugins",
                        "isEnabled": true,
                    },
                ],
            })
            .to_string(),
        )
        .expect("store file");
        let (sources, _) = load_sources(&path).expect("reload");
        let official = sources
            .iter()
            .find(|s| s.id == OFFICIAL_SOURCE_ID)
            .expect("official");
        assert_eq!(
            official.index_url, OFFICIAL_INDEX_URL,
            "preset constants are rebuilt"
        );
        assert_eq!(
            official.name, "Lithe",
            "the stored name never replaces the preset identity"
        );
        assert!(!official.is_enabled, "only the enable state is the user's");
        let community = sources
            .iter()
            .find(|source| source.id == COMMUNITY_SOURCE_ID)
            .expect("community");
        assert_eq!(community.index_url, COMMUNITY_INDEX_URL);
        assert!(!community.is_enabled);
        let example = sources
            .iter()
            .find(|s| s.id == EXAMPLE_SOURCE_ID)
            .expect("kept");
        assert_eq!(
            example.name, "example/lithe-plugins",
            "user sources are kept verbatim"
        );
        assert!(example.is_enabled);
        cleanup(&root);
    }

    #[test]
    fn toggles_persist_atomically_without_temp_files() {
        let root = unique_temp_root("toggle");
        let path = sources_path(&root);
        set_enabled(&path, OFFICIAL_SOURCE_ID, false).expect("disable official");
        let persisted = std::fs::read_to_string(&path).expect("store file");
        assert!(
            persisted.contains("\"isEnabled\": false"),
            "the toggle is persisted: {persisted}"
        );
        let store_dir = path.parent().expect("parent");
        let leftovers: Vec<_> = std::fs::read_dir(store_dir)
            .expect("store dir")
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("sources.json.tmp")
            })
            .collect();
        assert!(leftovers.is_empty(), "no temp files remain: {leftovers:?}");
        let (reloaded, _) = load_sources(&path).expect("reload");
        let official = reloaded
            .iter()
            .find(|s| s.id == OFFICIAL_SOURCE_ID)
            .expect("official");
        assert!(!official.is_enabled, "the disable survives a restart");
        assert!(
            reloaded
                .iter()
                .any(|source| source.id == COMMUNITY_SOURCE_ID),
            "official removal is impossible, so no tombstone exists"
        );
        cleanup(&root);
    }

    #[test]
    fn save_sources_round_trips_through_the_persisted_shape() {
        let root = unique_temp_root("roundtrip");
        let path = sources_path(&root);
        let (sources, _) = load_sources(&path).expect("defaults");
        save_sources(&path, &sources).expect("save");
        let persisted = std::fs::read_to_string(&path).expect("store file");
        let file: Value = serde_json::from_str(&persisted).expect("valid JSON");
        assert_eq!(file["schemaVersion"], json!(1));
        let saved = file["sources"].as_array().expect("sources array");
        assert_eq!(saved.len(), 2);
        assert_eq!(saved[0]["indexURL"], json!(OFFICIAL_INDEX_URL));
        assert_eq!(saved[1]["isEnabled"], json!(true));
        assert!(
            file.get("removedPresetSourceIDs").is_none(),
            "nothing removed yet, so the key is omitted like macOS"
        );
        cleanup(&root);
    }
}
