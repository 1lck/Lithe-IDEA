//! Packaged Java resources use Core's existing JDT plan, without executing a JVM.

use super::*;
use crate::plugin_host::{CatalogEntry, ScannedPackage};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    package: ScannedPackage,
    plan: Value,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-java-plugin-plan-{}-{}",
            std::process::id(),
            NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&root).expect("fixture root");
        let manifest: Value = serde_json::from_str(include_str!(
            "../../../../Plugins/win/Official/JavaSupport/plugin.json"
        ))
        .expect("Windows Java manifest");
        let outcome = crate::plugin_host::scan::core_execute("plugins.declarative.languageServerLaunchPlan", json!({
            "manifest": manifest, "languageID": "java", "request": {
                "pluginDirectory": root.to_string_lossy(), "stateDirectory": root.join("state").to_string_lossy(),
                "workspaceStateDirectory": root.join("state/workspace").to_string_lossy(),
                "architecture": crate::plugin_host::host_architecture(),
            },
        })).expect("Core plan");
        assert_eq!(outcome["status"], "ok", "{outcome}");
        let plan = outcome["plan"].clone();
        for relative in plan["requiredPackagePaths"]
            .as_array()
            .expect("required paths")
        {
            let relative = relative.as_str().expect("path");
            let path = root.join(relative);
            if relative.contains("configuration/")
                || relative.ends_with("java-debug")
                || relative.ends_with("java-test/extensions")
            {
                std::fs::create_dir_all(&path).expect("resource directory");
            } else {
                std::fs::create_dir_all(path.parent().expect("parent")).expect("resource parent");
                std::fs::write(path, b"fixture data; never executed").expect("resource file");
            }
        }
        let configuration = plan["hostIntegration"]["resources"]["configuration"]
            .as_str()
            .expect("configuration");
        std::fs::write(
            root.join(configuration).join("config.ini"),
            b"fixture configuration",
        )
        .expect("config.ini");
        std::fs::write(
            root.join("language-server/java-debug/com.microsoft.java.debug.plugin-fixture.jar"),
            b"fixture debug",
        )
        .expect("debug bundle");
        std::fs::write(
            root.join("language-server/java-test/extensions/test.jar"),
            b"fixture test",
        )
        .expect("test bundle");
        std::fs::write(
            root.join("language-server/manifest.json"),
            r#"{"version":"1.61.0"}"#,
        )
        .expect("upstream identity");
        let package = ScannedPackage {
            entry: CatalogEntry {
                plugin_id: "dev.lithe.plugin.java-support".into(),
                display_name: "Java Support".into(),
                version: "1.1.0".into(),
                api_version: 3,
                source: "installed",
                enabled: true,
                status: "accepted",
                languages: Vec::new(),
                declared_settings: Vec::new(),
                declares_tests: false,
                primary_language_id: Some("java".into()),
                rejection: None,
            },
            root: root.clone(),
            manifest,
            trust: None,
        };
        Self {
            root,
            package,
            plan,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn windows_java_package_keeps_complete_requires_and_existing_jdt_launch_layout() {
    let fixture = Fixture::new();
    let rejection = crate::plugin_host::scan::validate_manifest_with(
        &fixture.package.manifest,
        Some(crate::plugin_host::host_capabilities()),
    )
    .expect_err("production admission remains closed");
    assert_eq!(rejection.code, "plugin.api.unsupported");
    assert_eq!(rejection.path.as_deref(), Some("requires.packageTrust"));
    crate::plugin_host::with_package_trust_for_tests(|| {
        crate::plugin_host::scan::validate_manifest(&fixture.package.manifest)
            .expect("complete Windows candidate is valid");
    });
    let resolution = resolve_packaged_jdt_resolution(
        &fixture.package,
        &fixture.plan,
        &fixture.root.join("state"),
    )
    .expect("existing Core JDT resource layout");
    assert_eq!(
        resolution.plugin_id.as_deref(),
        Some("dev.lithe.plugin.java-support")
    );
    assert_eq!(resolution.version.as_deref(), Some("1.61.0"));
    assert_eq!(
        resolution.cache_directory,
        Some(fixture.root.join("state/jdtls"))
    );
    assert!(resolution.executable.ends_with("bin/java.exe"));
    assert!(resolution.arguments.contains(&"-Xmx2048m".to_string()));
    let resources = resolution
        .jdtls_launch_resources
        .expect("direct JDT resources");
    assert!(resolution
        .arguments
        .windows(2)
        .any(|pair| pair[0] == "-jar" && pair[1] == normalize_path(&resources.launcher_jar_path)));
    assert_eq!(resources.java_extension_bundle_paths.len(), 2);
    assert!(
        !fixture.root.join("state").exists(),
        "resolution does not write Equinox state into the package"
    );
}

#[test]
fn windows_java_package_cache_remains_bound_to_the_resolved_owner() {
    let fixture = Fixture::new();
    let state = fixture.root.join("selected-owner-state");
    let resolution = resolve_packaged_jdt_resolution(&fixture.package, &fixture.plan, &state)
        .expect("selected owner resolution");
    let mut later_owner = fixture.package.clone();
    later_owner.entry.plugin_id = "io.example.later-jdt".into();
    let current = unique_jdt_package(vec![later_owner]).expect("catalog changed after selection");
    assert_ne!(
        Some(&current.entry.plugin_id),
        resolution.plugin_id.as_ref()
    );
    assert_eq!(resolution.cache_directory, Some(state.join("jdtls")));
    assert!(
        !state.exists(),
        "resolution keeps package and state read-only"
    );
}

#[test]
fn windows_java_package_rejects_missing_and_escaping_jdt_resources() {
    let mut fixture = Fixture::new();
    let state = fixture.root.join("state");
    let configuration = fixture.plan["hostIntegration"]["resources"]["configuration"]
        .as_str()
        .expect("configuration");
    std::fs::remove_file(fixture.root.join(configuration).join("config.ini"))
        .expect("remove config");
    assert!(resolve_packaged_jdt_resolution(&fixture.package, &fixture.plan, &state).is_err());
    fixture.plan["hostIntegration"]["resources"]["configuration"] = json!("../outside");
    assert!(
        resolve_packaged_jdt_resolution(&fixture.package, &fixture.plan, &state)
            .expect_err("escape")
            .contains("inside the package")
    );
}

#[test]
fn windows_java_package_has_one_enabled_jdt_owner_and_no_disabled_fallback() {
    let fixture = Fixture::new();
    assert!(unique_jdt_package(vec![]).is_err());
    let mut disabled = fixture.package.clone();
    disabled.entry.enabled = false;
    assert!(unique_jdt_package(vec![disabled]).is_err());
    let mut quarantined = fixture.package.clone();
    quarantined.entry.status = "rejected";
    assert!(unique_jdt_package(vec![quarantined]).is_err());
    let mut conflict = fixture.package.clone();
    conflict.entry.plugin_id = "io.example.other-jdt".into();
    assert!(unique_jdt_package(vec![fixture.package.clone(), conflict])
        .expect_err("ambiguous owner")
        .contains("Multiple"));
    assert_eq!(
        unique_jdt_package(vec![fixture.package.clone()])
            .expect("unique owner")
            .entry
            .plugin_id,
        fixture.package.entry.plugin_id
    );
}
