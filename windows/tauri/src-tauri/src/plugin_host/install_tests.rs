//! M2 disk-import tests exercise the internal functions directly (the Tauri
//! commands are thin AppHandle wrappers): snapshot isolation, ZIP safety,
//! the staged publish transaction, and rollback verification. The M1
//! trust-chain tests cover the same transaction against the recorded
//! content digest.

mod install_tests {
    use crate::plugin_host::install::{
        copy_directory_snapshot, extract_zip_snapshot, publish_installed_version,
    };
    use crate::plugin_host::signature::{self, InstallOrigin};
    use crate::plugin_host::store::{self, DiskProvenance, InstallationRecord};
    use crate::plugin_host::tests::read_fixture_for_tests;
    use std::path::PathBuf;

    fn unique_temp_root(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-plugin-install-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp root");
        root
    }

    const TEST_PLUGIN_ID: &str = "io.example.acme-php";

    fn package_directory(root: &std::path::Path, version: &str) -> PathBuf {
        let directory = root.join(format!("pkg-{version}"));
        std::fs::create_dir_all(&directory).expect("package dir");
        let mut manifest = read_fixture_for_tests("language-packaged-server.plugin.json");
        // A community install requires a non-official ID and an unsigned
        // trust declaration; the official-namespace fixture is reshaped the
        // way a real disk package looks.
        manifest["id"] = serde_json::json!(TEST_PLUGIN_ID);
        manifest["vendor"]["signatureRequirement"] = serde_json::json!("none");
        manifest["version"] = serde_json::json!(version);
        std::fs::write(
            directory.join("plugin.json"),
            serde_json::to_string_pretty(&manifest).expect("manifest text"),
        )
        .expect("manifest file");
        let server_directory = directory.join("language-server").join("bin");
        std::fs::create_dir_all(&server_directory).expect("server dir");
        std::fs::write(server_directory.join("intelephense.js"), b"entry").expect("entry file");
        directory
    }

    /// A schema 2 community record for `package_directory`, with the content
    /// digest the real install flow records from the approved snapshot.
    fn community_record(
        plugin_id: &str,
        version: &str,
        package_directory: &std::path::Path,
    ) -> InstallationRecord {
        InstallationRecord {
            schema_version: 2,
            plugin_id: plugin_id.to_string(),
            version: version.to_string(),
            previous_version: None,
            enabled: true,
            origin: Some(InstallOrigin::Community),
            previous_origin: None,
            marketplace: None,
            previous_marketplace: None,
            disk: Some(DiskProvenance {
                file_name: "plugin.zip".to_string(),
                archive_sha256: None,
                content_digest: signature::content_digest(package_directory).expect("digest"),
                approved_programs: Vec::new(),
            }),
            previous_disk: None,
        }
    }

    #[test]
    fn directory_snapshot_copies_contents() {
        let root = unique_temp_root("snapshot");
        let package = package_directory(&root, "1.0.0");
        let snapshot = root.join("snapshot");
        copy_directory_snapshot(&package, &snapshot).expect("snapshot copies");
        assert!(snapshot.join("plugin.json").is_file());
        assert!(snapshot
            .join("language-server/bin/intelephense.js")
            .is_file());

        // A symlink inside the source must abort the copy when the platform
        // lets the test create one.
        #[cfg(unix)]
        {
            let link = package.join("linked.js");
            if std::os::unix::fs::symlink(package.join("plugin.json"), &link).is_ok() {
                let hostile = root.join("snapshot-hostile");
                assert!(copy_directory_snapshot(&package, &hostile).is_err());
            }
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn directory_snapshot_rejects_oversized_file_and_removes_partial_copy() {
        let root = unique_temp_root("snapshot-budget");
        let package = package_directory(&root, "1.0.0");
        let oversized = std::fs::File::create(package.join("oversized.bin")).expect("file");
        oversized.set_len(16 * 1024 * 1024 + 1).expect("size");
        let snapshot = root.join("snapshot");
        assert!(copy_directory_snapshot(&package, &snapshot).is_err());
        assert!(!snapshot.exists(), "failed copy must release its snapshot");
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn zip_snapshot_extracts_and_rejects_unsafe_paths() {
        let root = unique_temp_root("zip");
        let package = package_directory(&root, "1.0.0");
        let zip_path = root.join("pkg.zip");
        let zip_file = std::fs::File::create(&zip_path).expect("zip file");
        let mut writer = zip::ZipWriter::new(zip_file);
        let options: zip::write::SimpleFileOptions = Default::default();
        writer
            .add_directory("wrapper/", options)
            .expect("wrapper dir");
        for relative in ["plugin.json", "language-server/bin/intelephense.js"] {
            let source = package.join(relative);
            let text = std::fs::read(&source).expect("entry bytes");
            writer
                .start_file(format!("wrapper/{relative}"), options)
                .expect("entry");
            std::io::Write::write_all(&mut writer, &text).expect("entry bytes");
        }
        writer.finish().expect("zip finish");
        let snapshot = root.join("snapshot");
        extract_zip_snapshot(&zip_path, &snapshot).expect("extracts");
        assert!(snapshot.join("plugin.json").is_file());

        // A traversal entry name is refused before anything is written.
        let hostile_zip = root.join("hostile.zip");
        let hostile_file = std::fs::File::create(&hostile_zip).expect("hostile zip");
        let mut hostile_writer = zip::ZipWriter::new(hostile_file);
        hostile_writer
            .start_file("../escape.txt", options)
            .expect("hostile entry");
        std::io::Write::write_all(&mut hostile_writer, b"nope").expect("hostile bytes");
        hostile_writer.finish().expect("zip finish");
        let hostile_snapshot = root.join("snapshot-hostile");
        assert!(extract_zip_snapshot(&hostile_zip, &hostile_snapshot).is_err());
        assert!(!root.join("escape.txt").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Two entries that only differ in case (or a duplicated name) would
    /// silently overwrite each other on Windows and break the approved file
    /// set, so the second one is a rejection.
    #[test]
    fn zip_case_conflicting_entries_are_rejected() {
        let root = unique_temp_root("zip-conflict");
        let zip_path = root.join("conflict.zip");
        let zip_file = std::fs::File::create(&zip_path).expect("zip file");
        let mut writer = zip::ZipWriter::new(zip_file);
        let options: zip::write::SimpleFileOptions = Default::default();
        let mut manifest = read_fixture_for_tests("language-packaged-server.plugin.json");
        manifest["version"] = serde_json::json!("1.0.0");
        let manifest_text = serde_json::to_string_pretty(&manifest).expect("manifest text");
        for name in ["plugin.json", "Plugin.json"] {
            writer.start_file(name, options).expect("entry");
            std::io::Write::write_all(&mut writer, manifest_text.as_bytes()).expect("entry bytes");
        }
        writer.finish().expect("zip finish");
        let snapshot = root.join("snapshot");
        assert!(extract_zip_snapshot(&zip_path, &snapshot).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn publish_rejects_broken_manifests_and_keeps_the_active_version() {
        let root = unique_temp_root("staging");
        let install_root = root.join("plugins");
        let good = package_directory(&root, "1.0.0");
        let record = community_record(TEST_PLUGIN_ID, "1.0.0", &good);
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &good,
            record.clone(),
        )
        .expect("installs");
        assert!(install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/plugin.json")
            .is_file());

        // A broken package fails validation and leaves the active version.
        let broken = root.join("pkg-broken");
        std::fs::create_dir_all(&broken).expect("broken dir");
        std::fs::write(broken.join("plugin.json"), "{ not json").expect("broken manifest");
        let broken_record = community_record(TEST_PLUGIN_ID, "2.0.0", &broken);
        assert!(publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "2.0.0",
            &broken,
            broken_record,
        )
        .is_err());
        assert!(!install_root.join(TEST_PLUGIN_ID).join("2.0.0").exists());
        assert!(install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/plugin.json")
            .is_file());
        // The staging directory is cleaned up on failure.
        assert!(!install_root
            .join(TEST_PLUGIN_ID)
            .join(".staging-2.0.0")
            .exists());

        // A successful upgrade keeps both versions for rollback.
        let upgrade = package_directory(&root, "2.0.0");
        let upgrade_record = community_record(TEST_PLUGIN_ID, "2.0.0", &upgrade);
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "2.0.0",
            &upgrade,
            upgrade_record,
        )
        .expect("upgrade");
        assert!(install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/plugin.json")
            .is_file());
        assert!(install_root
            .join(TEST_PLUGIN_ID)
            .join("2.0.0/plugin.json")
            .is_file());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The staged copy must match the digest recorded for the approved
    /// snapshot: a snapshot swapped between review and publish never becomes
    /// the active version, and the old version stays intact.
    #[test]
    fn publish_binds_the_staged_bytes_to_the_approved_digest() {
        let root = unique_temp_root("staging-digest");
        let install_root = root.join("plugins");
        let approved = package_directory(&root, "1.0.0");
        let record = community_record(TEST_PLUGIN_ID, "2.0.0", &approved);

        let tampered = package_directory(&root, "2.0.0");
        std::fs::write(
            tampered.join("language-server/bin/intelephense.js"),
            b"evil",
        )
        .expect("tampered entry");
        assert!(publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "2.0.0",
            &tampered,
            record.clone(),
        )
        .is_err());
        assert!(!install_root.join(TEST_PLUGIN_ID).join("2.0.0").exists());

        // Publishing the approved bytes succeeds and the record carries the
        // same digest the installed files recompute to.
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "2.0.0",
            &approved,
            record.clone(),
        )
        .expect("installs");
        let stored: InstallationRecord = serde_json::from_str(
            &std::fs::read_to_string(install_root.join(TEST_PLUGIN_ID).join("installation.json"))
                .expect("record"),
        )
        .expect("record parses");
        let installed_directory = install_root.join(TEST_PLUGIN_ID).join("2.0.0");
        assert_eq!(
            stored
                .disk
                .as_ref()
                .expect("disk provenance")
                .content_digest,
            signature::content_digest(&installed_directory).expect("digest")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A same-version reinstall of changed bytes is rejected: the record and
    /// the version directory keep the originally approved state.
    #[test]
    fn same_version_reinstall_of_changed_bytes_is_rejected() {
        let root = unique_temp_root("staging-same-version");
        let install_root = root.join("plugins");
        let approved = package_directory(&root, "1.0.0");
        let record = community_record(TEST_PLUGIN_ID, "1.0.0", &approved);
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &approved,
            record.clone(),
        )
        .expect("installs");
        let marker = install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/language-server/bin/intelephense.js");
        assert_eq!(std::fs::read(&marker).expect("marker"), b"entry");

        let replacement = package_directory(&root, "1.0.0-replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");
        assert!(publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            record,
        )
        .is_err());
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"entry",
            "the active version keeps its approved bytes"
        );
        assert!(!install_root
            .join(TEST_PLUGIN_ID)
            .join(".staging-1.0.0")
            .exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Rollback verification: the restored version is checked against its
    /// own recorded digest before the record may swap. The production
    /// command performs exactly this check on the previous version
    /// directory before writing the swapped record.
    #[test]
    fn rollback_rejects_a_tampered_previous_version() {
        let root = unique_temp_root("rollback");
        let install_root = root.join("plugins");
        let first = package_directory(&root, "1.0.0");
        let first_digest = signature::content_digest(&first).expect("digest");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &first,
            community_record(TEST_PLUGIN_ID, "1.0.0", &first),
        )
        .expect("installs");

        // Tampering with the previous version makes the rollback candidate
        // unverifiable against its recorded digest.
        let previous_directory = install_root.join(TEST_PLUGIN_ID).join("1.0.0");
        std::fs::write(
            previous_directory.join("language-server/bin/intelephense.js"),
            b"evil",
        )
        .expect("tamper");
        let manifest_text =
            std::fs::read_to_string(previous_directory.join("plugin.json")).expect("manifest");
        let manifest: serde_json::Value = serde_json::from_str(&manifest_text).expect("manifest");
        let error = signature::verify_for_origin(
            &previous_directory,
            TEST_PLUGIN_ID,
            "1.0.0",
            &manifest,
            InstallOrigin::Community,
            Some(first_digest.as_str()),
            signature::trusted_keys(),
        )
        .expect_err("tampered previous version must be refused");
        assert_eq!(error.code(), "plugin.trust.contentChanged");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The record shape survives serde round-trips with all provenance
    /// fields intact; the scan and launch paths rely on this.
    #[test]
    fn installation_record_round_trips_provenance() {
        let root = unique_temp_root("record-shape");
        let package = package_directory(&root, "1.0.0");
        let record = community_record(TEST_PLUGIN_ID, "1.0.0", &package);
        let text = serde_json::to_string_pretty(&record).expect("record text");
        let parsed: InstallationRecord = serde_json::from_str(&text).expect("record parses");
        assert_eq!(parsed.schema_version, 2);
        assert_eq!(parsed.origin, Some(InstallOrigin::Community));
        assert_eq!(
            parsed.active_content_digest(),
            record.active_content_digest()
        );
        // A schema 1 record decodes without provenance; discovery quarantines
        // it instead of trusting the enabled flag.
        let legacy: InstallationRecord = serde_json::from_str(&format!(
            r#"{{"schemaVersion": 1, "pluginId": "{TEST_PLUGIN_ID}", "version": "1.0.0"}}"#
        ))
        .expect("legacy record parses");
        assert_eq!(legacy.origin, None);
        assert_eq!(legacy.active_content_digest(), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The write helper produces an atomic record the discovery path reads
    /// back with its provenance.
    #[test]
    fn record_write_is_readable_by_discovery() {
        let root = unique_temp_root("record-write");
        let install_root = root.join("plugins");
        let package = package_directory(&root, "1.0.0");
        let record = community_record(TEST_PLUGIN_ID, "1.0.0", &package);
        publish_installed_version(&install_root, TEST_PLUGIN_ID, "1.0.0", &package, record)
            .expect("published");
        let discovered = store::discover_installed_in(&install_root).expect("discovery works");
        assert_eq!(discovered.len(), 1);
        assert!(discovered[0].record_problem.is_none());
        assert_eq!(discovered[0].origin, Some(InstallOrigin::Community));
        assert!(discovered[0].content_digest.is_some());
        let _ = std::fs::remove_dir_all(&root);
    }
}
