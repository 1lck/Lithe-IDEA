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
    use serde_json::json;
    use std::path::PathBuf;

    struct TestRoot(PathBuf);

    impl std::ops::Deref for TestRoot {
        type Target = PathBuf;
        fn deref(&self) -> &PathBuf {
            &self.0
        }
    }

    impl AsRef<std::path::Path> for TestRoot {
        fn as_ref(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn unique_temp_root(label: &str) -> TestRoot {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-plugin-install-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp root");
        TestRoot(root)
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
            None,
            &signature::trusted_keys(),
        )
        .expect_err("tampered previous version must be refused");
        assert_eq!(error.code(), "plugin.trust.contentChanged");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// P1 regression: the installation record is part of the publish
    /// transaction. When the record commit fails after the version bytes
    /// were swapped (the record file is held open, so the rename onto it
    /// fails on Windows), the previous version's bytes and its record must
    /// both be restored, with no staging or temp leftovers.
    /// A package directory with the declared version kept at `version` even
    /// when the source directory name carries a distinguishing suffix, so a
    /// same-version reinstall passes manifest validation.
    fn same_version_package(root: &std::path::Path, version: &str, suffix: &str) -> PathBuf {
        let directory = package_directory(root, &format!("{version}-{suffix}"));
        let manifest_path = directory.join("plugin.json");
        let mut manifest: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(&manifest_path).expect("manifest readable"),
        )
        .expect("manifest is JSON");
        manifest["version"] = serde_json::json!(version);
        std::fs::write(
            &manifest_path,
            serde_json::to_string_pretty(&manifest).expect("manifest text"),
        )
        .expect("manifest rewritten");
        directory
    }

    #[cfg(windows)]
    #[test]
    fn record_commit_failure_restores_the_previous_version() {
        let root = unique_temp_root("staging-record-restore");
        let install_root = root.join("plugins");
        let approved = package_directory(&root, "1.0.0");
        let original_record = community_record(TEST_PLUGIN_ID, "1.0.0", &approved);
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &approved,
            original_record.clone(),
        )
        .expect("first install succeeds");
        let original_digest = original_record
            .disk
            .as_ref()
            .expect("disk provenance")
            .content_digest
            .clone();
        let marker = install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/language-server/bin/intelephense.js");
        assert_eq!(std::fs::read(&marker).expect("marker"), b"entry");

        // A legitimate same-version reinstall: fresh snapshot, fresh review,
        // matching digest binding - only the record commit will fail.
        let replacement = same_version_package(&root, "1.0.0", "replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");
        let replacement_record = community_record(TEST_PLUGIN_ID, "1.0.0", &replacement);
        assert_ne!(
            replacement_record
                .disk
                .as_ref()
                .expect("disk")
                .content_digest,
            original_digest,
            "the replacement must be a different approved byte set"
        );

        // Holding the record file open without FILE_SHARE_DELETE keeps
        // Windows from renaming the new record over it, which fails the
        // commit after the version bytes were already swapped.
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;
        let record_path = install_root.join(TEST_PLUGIN_ID).join("installation.json");
        let record_lock = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(&record_path)
            .expect("record file opened");
        let publish_error = publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            replacement_record,
        )
        .expect_err("the record commit must fail while the record is locked");
        drop(record_lock);
        assert!(
            publish_error.contains("record"),
            "the failure must name the record commit: {publish_error}"
        );

        // The old version bytes and the old record are both restored.
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"entry",
            "the previous version bytes must be restored"
        );
        let stored: InstallationRecord = serde_json::from_str(
            &std::fs::read_to_string(install_root.join(TEST_PLUGIN_ID).join("installation.json"))
                .expect("record"),
        )
        .expect("record parses");
        assert_eq!(
            stored.disk.as_ref().expect("disk").content_digest,
            original_digest,
            "the old record must survive the failed transaction"
        );
        let plugin_directory = install_root.join(TEST_PLUGIN_ID);
        let leftovers: Vec<String> = std::fs::read_dir(&plugin_directory)
            .expect("plugin directory readable")
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        assert!(
            leftovers
                .iter()
                .all(|name| name == "1.0.0" || name == "installation.json"),
            "the failed transaction must leave no staging, backup, or temp entries: {leftovers:?}"
        );

        // Failure retry: with the lock released, the same reinstall commits.
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect("the retry succeeds once the record is writable");
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"replaced",
            "the retry installs the new bytes"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A record that cannot even be staged (a directory blocks the temp
    /// path) fails before any version byte moves.
    #[test]
    fn record_staging_failure_leaves_the_active_version_untouched() {
        let root = unique_temp_root("staging-record-preflight");
        let install_root = root.join("plugins");
        let approved = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &approved,
            community_record(TEST_PLUGIN_ID, "1.0.0", &approved),
        )
        .expect("first install succeeds");
        let marker = install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/language-server/bin/intelephense.js");

        let replacement = same_version_package(&root, "1.0.0", "replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");
        // The temp record path is occupied by a directory.
        std::fs::create_dir_all(
            install_root
                .join(TEST_PLUGIN_ID)
                .join("installation.json.tmp"),
        )
        .expect("blocker planted");
        let publish_error = publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect_err("publish must fail when the record cannot be staged");
        eprintln!("publish error: {publish_error}");
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"entry",
            "the active version must be untouched when the record cannot be staged"
        );
        assert!(
            publish_error.contains("record"),
            "the failure must name the record: {publish_error}"
        );
        let stored: InstallationRecord = serde_json::from_str(
            &std::fs::read_to_string(install_root.join(TEST_PLUGIN_ID).join("installation.json"))
                .expect("record"),
        )
        .expect("record parses");
        assert_eq!(stored.version, "1.0.0");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A first install whose record commit fails publishes no bytes at all:
    /// there is no previous version to fall back to, so the version
    /// directory is removed again.
    #[test]
    fn record_commit_failure_on_first_install_publishes_nothing() {
        let root = unique_temp_root("staging-record-first");
        let install_root = root.join("plugins");
        let package = package_directory(&root, "1.0.0");
        // A directory occupies the record path, so the commit cannot land.
        std::fs::create_dir_all(install_root.join(TEST_PLUGIN_ID).join("installation.json"))
            .expect("record path blocker planted");
        assert!(publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &package,
            community_record(TEST_PLUGIN_ID, "1.0.0", &package),
        )
        .is_err());
        assert!(
            !install_root.join(TEST_PLUGIN_ID).join("1.0.0").exists(),
            "a failed first install must not leave version bytes behind"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    // ---------- signed disk packages (M1: the disk channel must accept
    // publisher-signed packages) and prepare/confirm byte binding ----------

    /// Writes a signature document over the current package bytes with the
    /// shared RFC 8032 test key, exactly like the release signing flow.
    fn write_test_signature(
        package_root: &std::path::Path,
        key_id: &str,
        plugin_id: &str,
        plugin_version: &str,
        signing: &ed25519_dalek::SigningKey,
    ) {
        use base64::Engine;
        use ed25519_dalek::Signer;
        let files = signature::file_digests(package_root).expect("package digests");
        let payload = signature::canonical_payload(key_id, plugin_id, plugin_version, &files);
        let signature_bytes = signing.sign(&payload);
        let document = signature::SignatureDocument {
            schema_version: signature::SCHEMA_VERSION,
            algorithm: signature::ALGORITHM.to_string(),
            key_id: key_id.to_string(),
            plugin_id: plugin_id.to_string(),
            plugin_version: plugin_version.to_string(),
            files,
            signature: base64::engine::general_purpose::STANDARD.encode(signature_bytes.to_bytes()),
        };
        std::fs::write(
            package_root.join(signature::SIGNATURE_FILE_NAME),
            serde_json::to_string_pretty(&document).expect("document text"),
        )
        .expect("signature document written");
    }

    /// A disk-installable package whose manifest declares the given trust
    /// policy; the official-namespace fixture is reshaped the way a signed
    /// community package looks.
    fn declared_package_directory(
        root: &std::path::Path,
        plugin_id: &str,
        declared: &str,
    ) -> PathBuf {
        let directory = root.join(format!("pkg-{plugin_id}"));
        std::fs::create_dir_all(&directory).expect("package dir");
        let mut manifest = read_fixture_for_tests("language-packaged-server.plugin.json");
        manifest["id"] = serde_json::json!(plugin_id);
        manifest["vendor"]["signatureRequirement"] = serde_json::json!(declared);
        manifest["version"] = serde_json::json!("1.0.0");
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

    fn test_trusted_keys(
        signing: &ed25519_dalek::SigningKey,
    ) -> std::collections::BTreeMap<String, ed25519_dalek::VerifyingKey> {
        std::collections::BTreeMap::from([("lithe-test-v1".to_string(), signing.verifying_key())])
    }

    /// P1 regression: a publisher-signed package must be installable from
    /// disk. The disk channel records community provenance and the recorded
    /// digest, and the verified publisher signature satisfies the pinned
    /// policy, so the signed package installs and loads.
    #[test]
    fn signed_disk_package_installs_and_loads() {
        let signing = signature::rfc8032_signing_key_for_tests();
        signature::with_trusted_keys_for_tests(test_trusted_keys(&signing), || {
            let root = unique_temp_root("signed-disk");
            let source =
                declared_package_directory(&root, "io.example.signed-php", "publisherPackage");
            write_test_signature(
                &source,
                "lithe-test-v1",
                "io.example.signed-php",
                "1.0.0",
                &signing,
            );

            let temporary_root = root.join("plugin-temp");
            let install_root = root.join("plugins");
            let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-test-session",
                source.to_str().expect("source path"),
            )
            .expect("prepare accepts the signed package");
            let confirmed = crate::plugin_host::install::confirm_disk_install_snapshot(
                &install_root,
                &temporary_root,
                &prepared.session_id,
                &prepared.manifest_digest,
            )
            .expect("confirm accepts the signed package");
            assert_eq!(
                confirmed.record.origin,
                Some(InstallOrigin::Community),
                "the origin stays the real disk channel"
            );
            crate::plugin_host::install::publish_installed_version(
                &install_root,
                &confirmed.plugin_id,
                &confirmed.version,
                &temporary_root.join(&prepared.session_id),
                confirmed.record,
            )
            .expect("publish succeeds");

            let catalog =
                crate::plugin_host::scan::build_catalog_from(&root.join("none"), &install_root)
                    .expect("catalog builds");
            let entry = &catalog
                .iter()
                .find(|package| package.entry.source == "installed")
                .expect("installed entry")
                .entry;
            assert_eq!(
                entry.status, "accepted",
                "the signed disk package must load: {:?}",
                entry.rejection
            );
            let _ = std::fs::remove_dir_all(&root);
        });
    }

    #[test]
    fn signed_disk_package_with_an_unknown_key_is_refused() {
        let signing = signature::rfc8032_signing_key_for_tests();
        signature::with_trusted_keys_for_tests(test_trusted_keys(&signing), || {
            let root = unique_temp_root("signed-unknown-key");
            let source =
                declared_package_directory(&root, "io.example.signed-php", "publisherPackage");
            // Signed by a key ID the host does not trust at all.
            let stranger = ed25519_dalek::SigningKey::from_bytes(&[9u8; 32]);
            write_test_signature(
                &source,
                "stranger-test-key",
                "io.example.signed-php",
                "1.0.0",
                &stranger,
            );

            let temporary_root = root.join("plugin-temp");
            let error = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-test-session",
                source.to_str().expect("source path"),
            )
            .expect_err("an unknown signing key must be refused");
            assert!(error.contains("trust"), "{error}");
            let _ = std::fs::remove_dir_all(&root);
        });
    }

    #[test]
    fn signed_disk_package_with_a_bad_signature_is_refused() {
        let signing = signature::rfc8032_signing_key_for_tests();
        signature::with_trusted_keys_for_tests(test_trusted_keys(&signing), || {
            let root = unique_temp_root("signed-bad");
            let source =
                declared_package_directory(&root, "io.example.signed-php", "publisherPackage");
            write_test_signature(
                &source,
                "lithe-test-v1",
                "io.example.signed-php",
                "1.0.0",
                &signing,
            );
            // Tamper after signing.
            std::fs::write(source.join("language-server/bin/intelephense.js"), b"evil")
                .expect("tampered entry");

            let temporary_root = root.join("plugin-temp");
            let error = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-test-session",
                source.to_str().expect("source path"),
            )
            .expect_err("a bad signature must be refused");
            assert!(error.contains("signature"), "{error}");
            let _ = std::fs::remove_dir_all(&root);
        });
    }

    #[test]
    fn same_team_disk_package_is_refused_even_when_signed() {
        let signing = signature::rfc8032_signing_key_for_tests();
        signature::with_trusted_keys_for_tests(test_trusted_keys(&signing), || {
            let root = unique_temp_root("signed-same-team");
            let source = declared_package_directory(&root, "io.example.team-php", "sameTeamAsHost");
            write_test_signature(
                &source,
                "lithe-test-v1",
                "io.example.team-php",
                "1.0.0",
                &signing,
            );

            let temporary_root = root.join("plugin-temp");
            let error = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-test-session",
                source.to_str().expect("source path"),
            )
            .expect_err("a sameTeamAsHost disk package must be refused");
            assert!(error.contains("inside Lithe"), "{error}");
            let _ = std::fs::remove_dir_all(&root);
        });
    }

    /// P1 regression: the approval binds to the bytes the user reviewed.
    /// Replacing a package file after prepare (the manifest unchanged) must
    /// not install: the frozen session digest no longer matches.
    #[test]
    fn confirm_rejects_bytes_changed_after_prepare() {
        let signing = signature::rfc8032_signing_key_for_tests();
        signature::with_trusted_keys_for_tests(test_trusted_keys(&signing), || {
            let root = unique_temp_root("confirm-swap");
            let source = declared_package_directory(&root, "io.example.swap-php", "none");
            let temporary_root = root.join("plugin-temp");
            let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-test-session",
                source.to_str().expect("source path"),
            )
            .expect("prepare succeeds");

            // Swap a non-manifest file inside the prepared snapshot.
            let snapshot = temporary_root.join(&prepared.session_id);
            std::fs::write(
                snapshot.join("language-server/bin/intelephense.js"),
                b"replaced after review",
            )
            .expect("snapshot file swapped");

            let install_root = root.join("plugins");
            let error = crate::plugin_host::install::confirm_disk_install_snapshot(
                &install_root,
                &temporary_root,
                &prepared.session_id,
                &prepared.manifest_digest,
            )
            .expect_err("confirm must refuse bytes that changed after prepare");
            assert!(error.contains("changed after review"), "{error}");
            let _ = std::fs::remove_dir_all(&root);
        });
    }

    /// Adding or removing an ordinary file after prepare is the same
    /// rejection: the approved file set is exact.
    #[test]
    fn confirm_rejects_added_and_removed_files_after_prepare() {
        let signing = signature::rfc8032_signing_key_for_tests();
        signature::with_trusted_keys_for_tests(test_trusted_keys(&signing), || {
            let root = unique_temp_root("confirm-files");
            let source = declared_package_directory(&root, "io.example.files-php", "none");
            let temporary_root = root.join("plugin-temp");
            let install_root = root.join("plugins");

            // An added file after prepare.
            let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-added",
                source.to_str().expect("source path"),
            )
            .expect("prepare succeeds");
            std::fs::write(
                temporary_root.join(&prepared.session_id).join("extra.js"),
                b"added after review",
            )
            .expect("file added to the snapshot");
            let error = crate::plugin_host::install::confirm_disk_install_snapshot(
                &install_root,
                &temporary_root,
                &prepared.session_id,
                &prepared.manifest_digest,
            )
            .expect_err("an added file must be refused");
            assert!(error.contains("changed after review"), "{error}");

            // A removed file after prepare.
            let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
                &temporary_root,
                "lithe-plugin-disk-removed",
                source.to_str().expect("source path"),
            )
            .expect("prepare succeeds");
            std::fs::remove_file(
                temporary_root
                    .join(&prepared.session_id)
                    .join("language-server/bin/intelephense.js"),
            )
            .expect("file removed from the snapshot");
            let error = crate::plugin_host::install::confirm_disk_install_snapshot(
                &install_root,
                &temporary_root,
                &prepared.session_id,
                &prepared.manifest_digest,
            )
            .expect_err("a removed file must be refused");
            assert!(error.contains("changed after review"), "{error}");
            let _ = std::fs::remove_dir_all(&root);
        });
    }

    /// P1 regression: a rollback candidate can never be honored with
    /// bundled provenance. The candidate lives in the install root, so the
    /// seal check refuses even a signed, otherwise-valid package.
    #[test]
    fn rollback_cannot_restore_a_bundled_claiming_previous_version() {
        let root = unique_temp_root("rollback-bundled");
        let install_root = root.join("plugins");
        let package = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &package,
            community_record(TEST_PLUGIN_ID, "1.0.0", &package),
        )
        .expect("installs");

        // A sameTeamAsHost candidate claimed as bundled is refused by the
        // seal check: the candidate lives in the install root, never inside
        // the host installation.
        let sealed = declared_package_directory(&root, "io.example.sealed-php", "sameTeamAsHost");
        let error = crate::plugin_host::install::verify_rollback_candidate(
            &sealed,
            "io.example.sealed-php",
            "1.0.0",
            crate::plugin_host::signature::InstallOrigin::Bundled,
            None,
        )
        .expect_err("a bundled claim must not be restorable from the install root");
        assert!(error.contains("inside Lithe"), "{error}");

        // An unsigned candidate claimed as bundled is refused as well: the
        // bundled origin cannot legitimize an unsigned package.
        let unsigned = declared_package_directory(&root, "io.example.unsigned-php", "none");
        let error = crate::plugin_host::install::verify_rollback_candidate(
            &unsigned,
            "io.example.unsigned-php",
            "1.0.0",
            crate::plugin_host::signature::InstallOrigin::Bundled,
            None,
        )
        .expect_err("a bundled claim must not legitimize an unsigned package");
        assert!(error.contains("community"), "{error}");

        // A community candidate without its approved digest is refused too.
        let error = crate::plugin_host::install::verify_rollback_candidate(
            &install_root.join(TEST_PLUGIN_ID).join("1.0.0"),
            TEST_PLUGIN_ID,
            "1.0.0",
            crate::plugin_host::signature::InstallOrigin::Community,
            None,
        )
        .expect_err("a community candidate needs its approved digest");
        assert!(error.contains("digest"), "{error}");

        // The real previous provenance restores cleanly.
        crate::plugin_host::install::verify_rollback_candidate(
            &install_root.join(TEST_PLUGIN_ID).join("1.0.0"),
            TEST_PLUGIN_ID,
            "1.0.0",
            crate::plugin_host::signature::InstallOrigin::Community,
            Some(
                crate::plugin_host::signature::content_digest(&package)
                    .expect("digest")
                    .as_str(),
            ),
        )
        .expect("the recorded provenance restores");
        let _ = std::fs::remove_dir_all(&root);
    }

    // ---------- barrier ordering, cleanup, and recovery-backup handling ----

    /// P1 regression: the install record is read and the rollback chain is
    /// built inside the lifecycle barrier, so a mutation that commits while
    /// another confirm is draining is not overwritten with a stale chain.
    #[test]
    fn record_chain_is_built_inside_the_barrier() {
        let root = unique_temp_root("barrier-chain");
        let install_root = root.join("plugins");
        let temporary_root = root.join("plugin-temp");
        let first = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &first,
            community_record(TEST_PLUGIN_ID, "1.0.0", &first),
        )
        .expect("first install");

        // The session installs version 3.0.0.
        let third = package_directory(&root, "3.0.0");
        let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
            &temporary_root,
            "lithe-plugin-disk-barrier",
            third.to_str().expect("source path"),
        )
        .expect("prepare succeeds");
        let snapshot = temporary_root.join(&prepared.session_id);

        // Another mutation commits version 2.0.0 while the confirm drains:
        // the barrier closure lands that state before the record is built.
        let second_digest = "2".repeat(64);
        let first_digest = crate::plugin_host::signature::content_digest(&first).expect("digest");
        let stale_chain_overwritten = std::sync::Arc::new(std::sync::Mutex::new(false));
        let begin = {
            let install_root = install_root.clone();
            let stale_chain_overwritten = stale_chain_overwritten.clone();
            move || -> Result<(), String> {
                std::fs::write(
                    install_root.join(TEST_PLUGIN_ID).join("installation.json"),
                    json!({
                        "schemaVersion": 2,
                        "pluginId": TEST_PLUGIN_ID,
                        "version": "2.0.0",
                        "enabled": true,
                        "origin": "community",
                        "disk": {
                            "fileName": "second.zip",
                            "archiveSHA256": null,
                            "contentDigest": second_digest,
                            "approvedPrograms": []
                        },
                        "previousVersion": "1.0.0",
                        "previousOrigin": "community",
                        "previousDisk": {
                            "fileName": "plugin.zip",
                            "archiveSHA256": null,
                            "contentDigest": first_digest,
                            "approvedPrograms": []
                        }
                    })
                    .to_string(),
                )
                .expect("concurrent record written");
                *stale_chain_overwritten.lock().expect("flag") = true;
                Ok(())
            }
        };

        let confirmed = crate::plugin_host::install::confirm_and_publish_in_barrier(
            &install_root,
            &temporary_root,
            &prepared.session_id,
            &prepared.manifest_digest,
            &snapshot,
            TEST_PLUGIN_ID,
            &begin,
        )
        .expect("the in-barrier confirm and publish succeed");
        assert!(*stale_chain_overwritten.lock().expect("flag"));
        // The chain is derived from the post-barrier record: the 2.0.0 state
        // that committed during the drain becomes the rollback target.
        assert_eq!(confirmed.record.version, "3.0.0");
        assert_eq!(
            confirmed.record.previous_version.as_deref(),
            Some("2.0.0"),
            "the rollback chain must come from the record as it exists inside the barrier"
        );
        assert_eq!(
            confirmed
                .record
                .previous_disk
                .as_ref()
                .expect("previous disk")
                .content_digest,
            "2".repeat(64)
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Barrier refusals and validation refusals both release the session:
    /// the snapshot directory and the session record are gone afterwards.
    #[test]
    fn failed_confirms_release_the_install_session() {
        let root = unique_temp_root("confirm-cleanup");
        let install_root = root.join("plugins");
        let temporary_root = root.join("plugin-temp");
        let source = package_directory(&root, "1.0.0");

        // A barrier that refuses: the session must be released.
        let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
            &temporary_root,
            "lithe-plugin-disk-drain",
            source.to_str().expect("source path"),
        )
        .expect("prepare succeeds");
        let snapshot = temporary_root.join(&prepared.session_id);
        assert!(snapshot.exists(), "the snapshot exists before the confirm");
        let error = crate::plugin_host::install::confirm_and_publish_in_barrier(
            &install_root,
            &temporary_root,
            &prepared.session_id,
            &prepared.manifest_digest,
            &snapshot,
            TEST_PLUGIN_ID,
            &|| Err("another mutation is still draining".to_string()),
        )
        .expect_err("a refusing barrier must fail the confirm");
        assert!(error.contains("draining"), "{error}");
        assert!(
            !snapshot.exists(),
            "the snapshot must be released after a barrier refusal"
        );
        assert!(
            !temporary_root
                .join(format!("{}.source.json", prepared.session_id))
                .exists(),
            "the session record must be released after a barrier refusal"
        );

        // A validation refusal (corrupted session record) releases too.
        let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
            &temporary_root,
            "lithe-plugin-disk-corrupt",
            source.to_str().expect("source path"),
        )
        .expect("prepare succeeds");
        let snapshot = temporary_root.join(&prepared.session_id);
        std::fs::write(
            temporary_root.join(format!("{}.source.json", prepared.session_id)),
            "{ not json",
        )
        .expect("session record corrupted");
        assert!(crate::plugin_host::install::confirm_and_publish_in_barrier(
            &install_root,
            &temporary_root,
            &prepared.session_id,
            &prepared.manifest_digest,
            &snapshot,
            TEST_PLUGIN_ID,
            &|| Ok(()),
        )
        .is_err());
        assert!(
            !snapshot.exists(),
            "the snapshot must be released after a validation refusal"
        );
        assert!(
            !temporary_root
                .join(format!("{}.source.json", prepared.session_id))
                .exists(),
            "the session record must be released after a validation refusal"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Builds the interrupted mid-commit state: the old bytes sit in the
    /// recovery backup, the interrupted new bytes occupy the version
    /// directory, and the record still names the old version.
    fn plant_interrupted_commit(
        install_root: &std::path::Path,
        replacement: &std::path::Path,
    ) -> PathBuf {
        let plugin_directory = install_root.join(TEST_PLUGIN_ID);
        let version_directory = plugin_directory.join("1.0.0");
        let backup_directory = plugin_directory.join("1.0.0.previous-tmp");
        std::fs::rename(&version_directory, &backup_directory).expect("backup move");
        copy_directory_snapshot(replacement, &version_directory).expect("interrupted bytes");
        backup_directory
    }

    /// A recovery backup left by a crashed transaction is restored before
    /// the next publish replaces anything, and the completed transaction
    /// leaves no backup behind.
    #[test]
    fn stale_recovery_backup_is_restored_before_the_next_publish() {
        let root = unique_temp_root("recovery-restore");
        let install_root = root.join("plugins");
        let original = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &original,
            community_record(TEST_PLUGIN_ID, "1.0.0", &original),
        )
        .expect("first install");
        let marker = install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/language-server/bin/intelephense.js");

        let replacement = same_version_package(&root, "1.0.0", "replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");
        let backup_directory = plant_interrupted_commit(&install_root, &replacement);
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"replaced",
            "the interrupted bytes occupy the version directory"
        );
        assert_eq!(
            std::fs::read(backup_directory.join("language-server/bin/intelephense.js"))
                .expect("backup marker"),
            b"entry",
            "the backup holds the old bytes"
        );

        // The next legitimate publish recovers first, then completes.
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect("publish recovers and completes");
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"replaced",
            "the new transaction installs its own bytes"
        );
        let plugin_directory = install_root.join(TEST_PLUGIN_ID);
        let leftovers: Vec<String> = std::fs::read_dir(&plugin_directory)
            .expect("plugin directory readable")
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        assert!(
            leftovers
                .iter()
                .all(|name| name == "1.0.0" || name == "installation.json"),
            "the recovery backup must not survive a completed transaction: {leftovers:?}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// When the recovery cannot be restored, the backup is kept as the only
    /// recoverable copy and the failure says so; releasing the lock lets the
    /// next publish recover and complete.
    #[cfg(windows)]
    #[test]
    fn recovery_backup_survives_a_failed_restore_until_the_retry() {
        let root = unique_temp_root("recovery-keep");
        let install_root = root.join("plugins");
        let original = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &original,
            community_record(TEST_PLUGIN_ID, "1.0.0", &original),
        )
        .expect("first install");

        let replacement = same_version_package(&root, "1.0.0", "replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");
        let backup_directory = plant_interrupted_commit(&install_root, &replacement);

        // Locking a file inside the backup keeps Windows from renaming the
        // backup directory, so the recovery fails and the backup stays.
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;
        let locked_file = backup_directory.join("language-server/bin/intelephense.js");
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(&locked_file)
            .expect("backup file opened");

        let error = publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect_err("the recovery must fail while the backup is locked");
        drop(lock);
        assert!(error.contains("recovery backup"), "{error}");
        assert!(
            backup_directory.exists(),
            "the recoverable bytes must be kept, never blindly deleted"
        );

        // The retry recovers the backup and completes the transaction.
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect("the retry recovers and completes");
        assert_eq!(
            std::fs::read(
                install_root
                    .join(TEST_PLUGIN_ID)
                    .join("1.0.0/language-server/bin/intelephense.js"),
            )
            .expect("marker"),
            b"replaced"
        );
        // Post-commit backup cleanup is best-effort in production: a leftover
        // backup is the documented self-healing state (the next publish
        // restores it before replacing anything) and must stay removable.
        if backup_directory.exists() {
            std::fs::remove_dir_all(&backup_directory)
                .expect("a leftover backup stays removable once no handle holds it");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    // ---------- final-review regressions: backup recovery direction,
    // backup path collisions, and identity checks before publish ----------

    /// Exercise the backup produced by an actual replacement, rather than
    /// planting one at the path the test assumes. An injected post-commit
    /// cleanup failure retains that real backup; retrying must keep the new record
    /// and new bytes together even when the next record commit fails.
    #[cfg(windows)]
    #[test]
    fn real_replacement_backup_survives_cleanup_and_failed_retry() {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;

        let root = unique_temp_root("real-backup-retry");
        let install_root = root.join("plugins");
        let original = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &original,
            community_record(TEST_PLUGIN_ID, "1.0.0", &original),
        )
        .expect("first install");
        let plugin_directory = install_root.join(TEST_PLUGIN_ID);
        let marker = plugin_directory.join("1.0.0/language-server/bin/intelephense.js");
        let replacement = same_version_package(&root, "1.0.0", "approved-replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"approved-new",
        )
        .expect("replacement bytes");
        let replacement_record = community_record(TEST_PLUGIN_ID, "1.0.0", &replacement);
        crate::plugin_host::install::publish_installed_version_with_backup_cleanup(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            replacement_record.clone(),
            &|_| {
                Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "cleanup blocked",
                ))
            },
        )
        .expect("replacement commits despite cleanup failure");

        let backup = plugin_directory.join("1.0.0.previous-tmp");
        assert_eq!(
            std::fs::read(backup.join("language-server/bin/intelephense.js"))
                .expect("the real transaction uses the complete version in its backup path"),
            b"entry"
        );
        assert!(!plugin_directory.join("1.0.previous-tmp").exists());
        assert_eq!(
            std::fs::read(&marker).expect("active replacement"),
            b"approved-new"
        );

        let record_path = plugin_directory.join("installation.json");
        let _record_lock = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(&record_path)
            .expect("block the next record commit");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &original,
            community_record(TEST_PLUGIN_ID, "1.0.0", &original),
        )
        .expect_err("the next record commit fails");
        assert_eq!(
            std::fs::read(&marker).expect("restored active bytes"),
            b"approved-new"
        );
        let stored: InstallationRecord =
            serde_json::from_slice(&std::fs::read(&record_path).expect("durable record"))
                .expect("record parses");
        assert_eq!(
            stored
                .disk
                .as_ref()
                .expect("stored provenance")
                .content_digest,
            replacement_record
                .disk
                .as_ref()
                .expect("approved provenance")
                .content_digest
        );
        assert!(!backup.exists());
    }

    /// A corrupt record cannot redirect recovery into another directory.
    #[test]
    fn recovery_refuses_record_paths_outside_the_owning_plugin() {
        for forged_id in [true, false] {
            let root = unique_temp_root("recovery-owner");
            let install_root = root.join("plugins");
            let package = package_directory(&root, "1.0.0");
            let mut record = community_record(TEST_PLUGIN_ID, "1.0.0", &package);
            publish_installed_version(
                &install_root,
                TEST_PLUGIN_ID,
                "1.0.0",
                &package,
                record.clone(),
            )
            .expect("initial install");
            let plugin_directory = install_root.join(TEST_PLUGIN_ID);
            let backup = plugin_directory.join("1.0.1.previous-tmp");
            std::fs::rename(plugin_directory.join("1.0.0"), &backup).expect("crash backup");
            if forged_id {
                record.plugin_id = "../outside".to_string();
            } else {
                record.version = "../../outside/1.0.0".to_string();
            }
            let record_path = plugin_directory.join("installation.json");
            let forged_record = serde_json::to_vec(&record).expect("forged record bytes");
            std::fs::write(&record_path, &forged_record).expect("corrupted record");
            let outside = root.join("outside");
            std::fs::create_dir_all(&outside).expect("unrelated directory");
            std::fs::write(outside.join("keep.txt"), b"unrelated user data").expect("sentinel");
            let error = publish_installed_version(
                &install_root,
                TEST_PLUGIN_ID,
                "1.0.0",
                &package,
                community_record(TEST_PLUGIN_ID, "1.0.0", &package),
            )
            .expect_err("a record cannot redirect recovery outside its plugin");
            assert!(error.contains("recovery record"), "{error}");
            assert_eq!(
                std::fs::read(&record_path).expect("unchanged record"),
                forged_record
            );
            assert!(
                backup.join("plugin.json").is_file(),
                "the backup stays in its own plugin"
            );
            assert!(
                !outside.join("1.0.0").exists(),
                "recovery does not write outside the plugin"
            );
            assert_eq!(
                std::fs::read(outside.join("keep.txt")).expect("sentinel"),
                b"unrelated user data"
            );
        }
    }

    /// Adjacent patch versions recover their own complete version names.
    #[test]
    fn adjacent_patch_versions_do_not_collide_on_backup_paths() {
        let root = unique_temp_root("patch-collision");
        let install_root = root.join("plugins");
        let first = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &first,
            community_record(TEST_PLUGIN_ID, "1.0.0", &first),
        )
        .expect("installs 1.0.0");

        // Interrupt the 1.0.0 bytes into their own named backup.
        let plugin_directory = install_root.join(TEST_PLUGIN_ID);
        let backup_100 = plugin_directory.join("1.0.0.previous-tmp");
        std::fs::rename(plugin_directory.join("1.0.0"), &backup_100).expect("backup 1.0.0");

        // Publishing 1.0.1 must restore the approved 1.0.0 bytes from the
        // backup and then install 1.0.1, leaving both versions intact. The
        // record carries the rollback chain confirm builds from the durable
        // record.
        let patch = package_directory(&root, "1.0.1");
        let mut patch_record = community_record(TEST_PLUGIN_ID, "1.0.1", &patch);
        patch_record.previous_version = Some("1.0.0".to_string());
        patch_record.previous_origin = Some(InstallOrigin::Community);
        patch_record.previous_disk = Some(DiskProvenance {
            file_name: "first.zip".to_string(),
            archive_sha256: None,
            content_digest: signature::content_digest(&first).expect("digest"),
            approved_programs: Vec::new(),
        });
        publish_installed_version(&install_root, TEST_PLUGIN_ID, "1.0.1", &patch, patch_record)
            .expect("publishing 1.0.1 recovers 1.0.0 first");
        assert!(
            plugin_directory.join("1.0.0/plugin.json").is_file(),
            "the approved 1.0.0 bytes are restored to their own directory"
        );
        assert!(plugin_directory.join("1.0.1/plugin.json").is_file());
        assert!(
            !backup_100.exists(),
            "no backup survives a completed recovery"
        );
        let stored: InstallationRecord = serde_json::from_str(
            &std::fs::read_to_string(plugin_directory.join("installation.json")).expect("record"),
        )
        .expect("record parses");
        assert_eq!(stored.version, "1.0.1");
        assert_eq!(stored.previous_version.as_deref(), Some("1.0.0"));
        // The legacy with_extension naming would have collapsed both patch
        // versions onto "1.0.previous-tmp"; it must never appear.
        assert!(!plugin_directory.join("1.0.previous-tmp").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A committed transaction that could not delete its backup leaves a
    /// stale copy; the next publish removes it instead of restoring old
    /// bytes over the new record, and a later record-commit failure still
    /// recovers the currently approved bytes.
    #[test]
    fn leftover_backup_after_a_commit_is_cleaned_and_the_retry_recovers() {
        let root = unique_temp_root("stale-backup");
        let install_root = root.join("plugins");
        let original = package_directory(&root, "1.0.0");
        let original_record = community_record(TEST_PLUGIN_ID, "1.0.0", &original);
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &original,
            original_record.clone(),
        )
        .expect("installs");
        let approved_digest = original_record
            .disk
            .as_ref()
            .expect("disk")
            .content_digest
            .clone();
        let marker = install_root
            .join(TEST_PLUGIN_ID)
            .join("1.0.0/language-server/bin/intelephense.js");

        // A stale leftover: bytes that the record does NOT approve.
        let stale_backup = install_root.join(TEST_PLUGIN_ID).join("1.0.0.previous-tmp");
        std::fs::create_dir_all(&stale_backup).expect("stale backup dir");
        std::fs::write(stale_backup.join("stale.txt"), b"stale").expect("stale bytes");

        let replacement = same_version_package(&root, "1.0.0", "replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");

        // Block the record commit of the next transaction.
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;
        let record_path = install_root.join(TEST_PLUGIN_ID).join("installation.json");
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(&record_path)
            .expect("record file opened");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect_err("the record commit must fail while the record is locked");
        drop(lock);

        // The stale backup was removed (the approved bytes were intact), and
        // the failed commit restored the approved bytes - not the stale ones.
        assert_eq!(
            std::fs::read(&marker).expect("marker"),
            b"entry",
            "the approved bytes are restored, never the stale backup"
        );
        let stored: InstallationRecord =
            serde_json::from_str(&std::fs::read_to_string(&record_path).expect("record"))
                .expect("record parses");
        assert_eq!(
            stored.disk.as_ref().expect("disk").content_digest,
            approved_digest,
            "the durable record still approves the restored bytes"
        );
        assert!(
            !stale_backup.exists(),
            "the stale backup was cleaned before the transaction"
        );

        // The retry completes the replacement.
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect("the retry completes");
        assert_eq!(std::fs::read(&marker).expect("marker"), b"replaced");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A missing active directory with a backup present is judged by the
    /// durable record's approved digest: matching bytes are restored,
    /// non-matching bytes are refused with everything kept.
    #[test]
    fn missing_active_with_backup_restores_only_the_approved_bytes() {
        let root = unique_temp_root("missing-active");
        let install_root = root.join("plugins");
        let original = package_directory(&root, "1.0.0");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &original,
            community_record(TEST_PLUGIN_ID, "1.0.0", &original),
        )
        .expect("installs");
        let plugin_directory = install_root.join(TEST_PLUGIN_ID);
        let backup = plugin_directory.join("1.0.0.previous-tmp");
        std::fs::rename(plugin_directory.join("1.0.0"), &backup).expect("crash move");
        assert!(!plugin_directory.join("1.0.0").exists(), "active missing");

        let replacement = same_version_package(&root, "1.0.0", "replacement");
        std::fs::write(
            replacement.join("language-server/bin/intelephense.js"),
            b"replaced",
        )
        .expect("replacement entry");

        // Ambiguous: the backup does not hold the approved bytes. The
        // publish is refused and every byte is kept.
        std::fs::write(
            backup.join("language-server/bin/intelephense.js"),
            b"unprovable",
        )
        .expect("backup bytes changed");
        assert!(publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .is_err());
        assert!(
            backup.join("language-server/bin/intelephense.js").is_file(),
            "the ambiguous backup is kept"
        );
        assert!(
            !plugin_directory.join("1.0.0").exists(),
            "no bytes are invented for the missing active directory"
        );

        // Restore the approved content: the publish recovers and completes.
        std::fs::write(backup.join("language-server/bin/intelephense.js"), b"entry")
            .expect("approved bytes restored into the backup");
        publish_installed_version(
            &install_root,
            TEST_PLUGIN_ID,
            "1.0.0",
            &replacement,
            community_record(TEST_PLUGIN_ID, "1.0.0", &replacement),
        )
        .expect("the recovery completes the publish");
        assert_eq!(
            std::fs::read(plugin_directory.join("1.0.0/language-server/bin/intelephense.js"),)
                .expect("marker"),
            b"replaced"
        );
        assert!(!backup.exists(), "no backup survives the recovery");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A malformed session fails during identity resolution, before the
    /// barrier is ever taken. The command resolves the identity inside its
    /// cleanup-guarded block, so this component regression pins both halves:
    /// the resolution refuses with a diagnosable error, and the shared
    /// release helper clears the snapshot and the session record.
    #[test]
    fn early_identity_failure_releases_the_session() {
        let root = unique_temp_root("identity-early");
        let temporary_root = root.join("plugin-temp");
        let source = package_directory(&root, "1.0.0");
        let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
            &temporary_root,
            "lithe-plugin-disk-badjson",
            source.to_str().expect("source path"),
        )
        .expect("prepare succeeds");
        let snapshot = temporary_root.join(&prepared.session_id);
        std::fs::write(snapshot.join("plugin.json"), "{ not json").expect("manifest corrupted");

        // The command's first in-guard step refuses a malformed session.
        let error = crate::plugin_host::install::session_plugin_id_for_tests(
            &temporary_root,
            &prepared.session_id,
        )
        .expect_err("a malformed session must fail identity resolution");
        assert!(error.contains("plugin.json"), "{error}");

        // Everything the confirm would have published is released.
        crate::plugin_host::install::discard_install_session_for_tests(
            &temporary_root,
            &prepared.session_id,
            &snapshot,
        );
        assert!(
            !snapshot.exists(),
            "the snapshot is released by the early failure"
        );
        assert!(
            !temporary_root
                .join(format!("{}.source.json", prepared.session_id))
                .exists(),
            "the session record is released by the early failure"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// If the session content changes to another plugin while the confirm
    /// waits for the barrier, the identity check refuses before any bytes
    /// are published under the wrong plugin's barrier.
    #[test]
    fn identity_change_is_refused_before_publish() {
        let root = unique_temp_root("identity-swap");
        let install_root = root.join("plugins");
        let temporary_root = root.join("plugin-temp");
        let source = package_directory(&root, "1.0.0");
        let prepared = crate::plugin_host::install::prepare_disk_install_snapshot(
            &temporary_root,
            "lithe-plugin-disk-swap",
            source.to_str().expect("source path"),
        )
        .expect("prepare succeeds");
        let snapshot = temporary_root.join(&prepared.session_id);

        let barrier_taken = std::sync::Arc::new(std::sync::Mutex::new(false));
        let begin = {
            let barrier_taken = barrier_taken.clone();
            move || -> Result<(), String> {
                *barrier_taken.lock().expect("flag") = true;
                Ok(())
            }
        };
        // The expected identity is what the caller's barrier was taken for;
        // the current session is otherwise fully valid and approved for B.
        // Only comparing it to the actual barrier's A identity may reject
        // this, rather than an earlier manifest-digest mismatch masking it.
        let error = crate::plugin_host::install::confirm_and_publish_in_barrier(
            &install_root,
            &temporary_root,
            &prepared.session_id,
            &prepared.manifest_digest,
            &snapshot,
            "io.example.other-barrier-owner",
            &begin,
        )
        .expect_err("an identity change must be refused before publish");
        assert!(error.contains("changed during confirmation"), "{error}");
        assert!(
            *barrier_taken.lock().expect("flag"),
            "the barrier was taken for the prepared identity before the check"
        );
        assert!(
            !install_root.join(TEST_PLUGIN_ID).exists(),
            "nothing is published for the prepared plugin"
        );
        assert!(
            !install_root.join("io.example.other-barrier-owner").exists(),
            "nothing is published for the swapped-in plugin"
        );
        assert!(
            !snapshot.exists(),
            "the failed session releases its snapshot"
        );
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
