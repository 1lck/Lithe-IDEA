//! Real Core conversion with deterministic, passive registry fixtures. No
//! executable resolver, wrapper probe, process or network is available here.

use super::super::build_registry::*;
use super::language_import::resolve;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Default)]
struct Core {
    calls: Mutex<Vec<String>>,
}
impl BuildCoreExecutor for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        self.calls.lock().unwrap().push(command.into());
        super::super::scan::core_execute(command, payload)
    }
}
struct Packages(Mutex<Vec<BuildPackageInput>>);
impl BuildPackageSource for Packages {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        self.0.lock().unwrap().clone()
    }
    fn package(&self, id: &str) -> Option<BuildPackageInput> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .find(|package| package.plugin_id == id)
            .cloned()
    }
}
#[derive(Default)]
struct Options(Mutex<StoredBuildOptions>);
impl BuildOptionsPersistence for Options {
    fn load(&self, _: &str) -> Result<StoredBuildOptions, String> {
        Ok(self.0.lock().unwrap().clone())
    }
    fn save(&self, _: &str, value: &StoredBuildOptions) -> Result<(), String> {
        *self.0.lock().unwrap() = value.clone();
        Ok(())
    }
}
struct Workspace(PathBuf);
impl Workspace {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "lithe java import {}",
            super::operation::next_operation_id()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn root(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
    fn write(&self, relative: &str, content: &str) {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }
    fn pom(&self, root: &str) {
        self.write(&format!("{root}/pom.xml"), "<project><modelVersion>4.0.0</modelVersion><groupId>fixture</groupId><artifactId>app</artifactId><version>1</version></project>");
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn package(kind: &str) -> BuildPackageInput {
    let fixture = if kind == "maven" {
        "build-host-integration.plugin.json"
    } else {
        "build-command-output-file.plugin.json"
    };
    let mut manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../shared/contracts/plugins/v1/fixtures")
                .join(fixture),
        )
        .unwrap(),
    )
    .unwrap();
    // The Maven fixture requests a host integration reserved to this namespace.
    manifest["id"] = json!(format!("dev.lithe.fixture.import-{kind}"));
    manifest["buildSystems"][0]["id"] = json!(format!("arbitrary-{kind}"));
    manifest["activationEvents"] = json!([format!("onBuildSystem:arbitrary-{kind}")]);
    manifest["buildSystems"][0]["languageImport"] = if kind == "maven" {
        json!({"kind":"maven","options":{"profiles":"profiles","settingsFile":"settingsFile","localRepository":"localRepository"}})
    } else {
        manifest["buildSystems"][0]["options"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"home","displayName":"Home","kind":"directory", "environment":{"GRADLE_USER_HOME":"${value}"}}));
        json!({"kind":"gradle","options":{"offline":"offline","gradleUserHome":"home"}})
    };
    BuildPackageInput {
        plugin_id: manifest["id"].as_str().unwrap().into(),
        version: "0.1.0".into(),
        content_identity: "accepted-original-bytes".into(),
        manifest,
    }
}
fn refresh(
    registry: &mut BuildRegistry,
    core: &Core,
    packages: &Packages,
    options: &Options,
    workspace: &Workspace,
) {
    let view = registry
        .refresh(core, packages, options, "main", &workspace.root())
        .unwrap();
    assert!(
        view.issues.iter().all(|issue| issue["kind"] != "rejected"),
        "invalid test fixture: {:?}",
        view.issues
    );
}

#[test]
fn exact_nested_instance_uses_core_effective_options_without_executing_the_wrapper() {
    let workspace = Workspace::new();
    workspace.pom("north");
    workspace.pom("south");
    workspace.write(
        "north/mvnw.cmd",
        "@echo off\r\necho should never execute > wrapper-ran\r\n",
    );
    let packages = Packages(Mutex::new(vec![package("maven")]));
    let options = Options::default();
    options.0.lock().unwrap().systems.insert(
        "arbitrary-maven".into(),
        StoredSystemOptions {
            values: BTreeMap::from([
                ("profiles".into(), json!(["dev"])),
                ("settingsFile".into(), json!("C:/fixture/settings.xml")),
            ]),
            empty_markers: BTreeMap::from([(
                "south".into(),
                ["profiles".into()].into_iter().collect(),
            )]),
        },
    );
    let core = Core::default();
    let mut registry = BuildRegistry::new();
    refresh(&mut registry, &core, &packages, &options, &workspace);
    let generation = registry.view("main").generation;
    let north = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        generation,
        Some("north/src/App.java"),
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(
        north.maven_context.as_ref().unwrap()["reactorPath"],
        "north"
    );
    assert_eq!(
        north.maven_context.as_ref().unwrap()["profiles"],
        json!(["dev"])
    );
    assert_eq!(
        north.maven_context.as_ref().unwrap()["settingsPath"],
        "C:/fixture/settings.xml"
    );
    let south = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        generation,
        Some("south/src/App.java"),
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(south.maven_context.as_ref().unwrap()["profiles"], json!([]));
    assert_ne!(north.identity, south.identity);
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        generation,
        None,
        &|| Ok(())
    )
    .is_err());
    assert!(!workspace.0.join("north/wrapper-ran").exists());
    assert!(core.calls.lock().unwrap().iter().all(|command| matches!(
        command.as_str(),
        "build.detect"
            | "build.resolveOptions"
            | "build.decodeModel"
            | "build.syncFingerprint"
            | "build.languageImport"
    )));
}

#[test]
fn option_edit_same_version_replacement_close_and_switch_never_borrow_an_old_snapshot() {
    let workspace = Workspace::new();
    workspace.pom(".");
    let packages = Packages(Mutex::new(vec![package("maven")]));
    let core = Core::default();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    refresh(&mut registry, &core, &packages, &options, &workspace);
    let generation = registry.view("main").generation;
    let first = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        generation,
        Some("App.java"),
        &|| Ok(()),
    )
    .unwrap();
    registry
        .set_option(
            &core,
            &packages,
            &options,
            "main",
            &workspace.root(),
            "dev.lithe.fixture.import-maven",
            "arbitrary-maven",
            ".",
            "profiles",
            Some(json!(["changed"])),
        )
        .unwrap();
    let changed = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("App.java"),
        &|| Ok(()),
    )
    .unwrap();
    assert_ne!(first.identity, changed.identity);
    packages.0.lock().unwrap()[0].content_identity = "accepted-same-version-replacement".into();
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("App.java"),
        &|| Ok(())
    )
    .unwrap_err()
    .contains("packageChanged"));
    registry.close_workspace("main", &workspace.root());
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        generation,
        Some("App.java"),
        &|| Ok(())
    )
    .is_err());
    refresh(&mut registry, &core, &packages, &options, &workspace);
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        "C:/other",
        registry.view("main").generation,
        Some("App.java"),
        &|| Ok(())
    )
    .is_err());
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "another-window",
        &workspace.root(),
        generation,
        Some("App.java"),
        &|| Ok(())
    )
    .is_err());
}

#[test]
fn missing_command_model_is_an_error_until_the_approved_model_is_loaded() {
    let workspace = Workspace::new();
    workspace.write("build.gradle", "plugins {}\n");
    workspace.write(
        "gradle/wrapper/gradle-wrapper.properties",
        "distributionUrl=https://example.invalid/gradle.zip\n",
    );
    let packages = Packages(Mutex::new(vec![package("gradle")]));
    let core = Core::default();
    let options = Options::default();
    options.0.lock().unwrap().systems.insert(
        "arbitrary-gradle".into(),
        StoredSystemOptions {
            values: BTreeMap::from([("home".into(), json!("C:/fixture/gradle-cache"))]),
            empty_markers: BTreeMap::new(),
        },
    );
    let mut registry = BuildRegistry::new();
    refresh(&mut registry, &core, &packages, &options, &workspace);
    let generation = registry.view("main").generation;
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        generation,
        Some("src/App.java"),
        &|| Ok(())
    )
    .unwrap_err()
    .contains("modelReloadRequired"));
    let context = registry
        .model_context(
            "main",
            &workspace.root(),
            "dev.lithe.fixture.import-gradle",
            "arbitrary-gradle",
            ".",
        )
        .unwrap();
    let fingerprint = registry.model_fingerprint(&core, &context).unwrap();
    registry
        .apply_command_model(
            &core,
            &context,
            json!({"projects":[],"targets":[],"tasks":[]}),
            &fingerprint,
        )
        .unwrap();
    registry
        .set_option(
            &core,
            &packages,
            &options,
            "main",
            &workspace.root(),
            "dev.lithe.fixture.import-gradle",
            "arbitrary-gradle",
            ".",
            "offline",
            Some(json!(true)),
        )
        .unwrap();
    // Option edits stale the command model. A controlled approved reload is
    // necessary; the import path itself never tries to run the model command.
    let context = registry
        .model_context(
            "main",
            &workspace.root(),
            "dev.lithe.fixture.import-gradle",
            "arbitrary-gradle",
            ".",
        )
        .unwrap();
    let fingerprint = registry.model_fingerprint(&core, &context).unwrap();
    registry
        .apply_command_model(
            &core,
            &context,
            json!({"projects":[],"targets":[],"tasks":[]}),
            &fingerprint,
        )
        .unwrap();
    let result = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("src/App.java"),
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(
        result.java_gradle.unwrap(),
        json!({"wrapperPresent":true,"offline":true,"userHome":"C:/fixture/gradle-cache"})
    );
    assert!(result.maven_context.is_none());
    // Even identical model data is a new native snapshot after a reload.
    // Revision identity must not depend on whether the visible JSON changed.
    let context = registry
        .model_context(
            "main",
            &workspace.root(),
            "dev.lithe.fixture.import-gradle",
            "arbitrary-gradle",
            ".",
        )
        .unwrap();
    let fingerprint = registry.model_fingerprint(&core, &context).unwrap();
    registry
        .apply_command_model(&core, &context, context.model.clone(), &fingerprint)
        .unwrap();
    let reloaded = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("src/App.java"),
        &|| Ok(()),
    )
    .unwrap();
    assert_ne!(result.identity, reloaded.identity);
}

#[test]
fn unowned_workspace_returns_no_import_but_invalid_declarations_do_not_fall_back() {
    let workspace = Workspace::new();
    workspace.pom(".");
    let core = Core::default();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    let empty = Packages(Mutex::new(vec![]));
    refresh(&mut registry, &core, &empty, &options, &workspace);
    let result = resolve(
        &registry,
        &core,
        &empty,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        None,
        &|| Ok(()),
    )
    .unwrap();
    assert!(result.maven_context.is_none() && result.java_gradle.is_none());
    let mut invalid = package("maven");
    invalid.manifest["buildSystems"][0]["languageImport"]["options"]["profiles"] =
        json!("missing-option");
    let packages = Packages(Mutex::new(vec![invalid]));
    registry
        .refresh(&core, &packages, &options, "main", &workspace.root())
        .unwrap();
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        None,
        &|| Ok(())
    )
    .is_err());
}

#[test]
fn workspace_file_changes_and_window_disposal_during_core_conversion_are_rejected() {
    let workspace = Workspace::new();
    workspace.pom(".");
    let core = Core::default();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    let packages = Packages(Mutex::new(vec![package("maven")]));
    refresh(&mut registry, &core, &packages, &options, &workspace);
    workspace.write("pom.xml", "<project>changed after model</project>");
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("App.java"),
        &|| Ok(())
    )
    .is_err());
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("../outside.java"),
        &|| Ok(())
    )
    .is_err());
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        None,
        &|| Err("plugin.build.staleContext".into())
    )
    .is_err());
}

#[test]
fn nested_roots_are_exact_and_equal_depth_import_owners_are_ambiguous() {
    let workspace = Workspace::new();
    workspace.pom(".");
    // A one-character directory must still be deeper than the "." sentinel.
    workspace.pom("a");
    let mut first = package("maven");
    first.manifest["buildSystems"][0]["detection"]["nesting"] = json!("separate");
    let packages = Packages(Mutex::new(vec![first.clone()]));
    let core = Core::default();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    refresh(&mut registry, &core, &packages, &options, &workspace);
    let value = resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("a/src/App.java"),
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(value.maven_context.unwrap()["reactorPath"], "a");
    let mut second = first.clone();
    second.plugin_id = "dev.lithe.fixture.second-import".into();
    second.manifest["id"] = json!(second.plugin_id);
    second.manifest["buildSystems"][0]["id"] = json!("second-system");
    second.manifest["activationEvents"] = json!(["onBuildSystem:second-system"]);
    packages.0.lock().unwrap().push(second);
    refresh(&mut registry, &core, &packages, &options, &workspace);
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("a/src/App.java"),
        &|| Ok(())
    )
    .is_err());
}

#[test]
fn a_reserved_refresh_cannot_claim_that_no_declarative_owner_exists() {
    let workspace = Workspace::new();
    let packages = Packages(Mutex::new(vec![]));
    let core = Core::default();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    refresh(&mut registry, &core, &packages, &options, &workspace);
    let _ticket = registry.reserve_refresh("main", &workspace.root());
    assert!(resolve(
        &registry,
        &core,
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        None,
        &|| Ok(())
    )
    .unwrap_err()
    .contains("staleContext"));
}

#[test]
fn trust_is_rechecked_after_core_even_when_the_package_version_did_not_change() {
    let workspace = Workspace::new();
    workspace.pom(".");
    let packages = Packages(Mutex::new(vec![package("maven")]));
    let core = Core::default();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    refresh(&mut registry, &core, &packages, &options, &workspace);
    struct ChangedCore<'a>(&'a Packages);
    impl BuildCoreExecutor for ChangedCore<'_> {
        fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
            let result = super::super::scan::core_execute(command, payload);
            if command == "build.languageImport" {
                self.0 .0.lock().unwrap()[0].content_identity = "same-version-replaced".into();
            }
            result
        }
    }
    assert!(resolve(
        &registry,
        &ChangedCore(&packages),
        &packages,
        "main",
        &workspace.root(),
        registry.view("main").generation,
        Some("App.java"),
        &|| Ok(())
    )
    .unwrap_err()
    .contains("packageChanged"));
}
