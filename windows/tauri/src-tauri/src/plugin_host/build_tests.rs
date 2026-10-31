//! Tests for the M4-A build registry: detection, static models, option
//! persistence, and sync fingerprints against the real Core, plus the
//! failure and staleness paths. No test starts a process: this batch is
//! read-only, so every scenario is filesystem- and envelope-level only.

use super::build_registry::{
    BuildCoreExecutor, BuildOptionsPersistence, BuildPackageInput, BuildPackageSource,
    BuildRegistry, StoredBuildOptions,
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};

const FIXTURES_DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../shared/contracts/plugins/v1/fixtures"
);

fn static_fixture() -> Value {
    let text =
        std::fs::read_to_string(Path::new(FIXTURES_DIR).join("build-static-file.plugin.json"))
            .expect("static fixture exists");
    serde_json::from_str(&text).expect("static fixture is JSON")
}

/// Deterministic temp workspace that removes itself on drop; the optional
/// space in the name also exercises paths with spaces through Core.
struct TempWorkspace {
    root: PathBuf,
}

impl TempWorkspace {
    fn new(name: &str, spaced: bool) -> Self {
        let mut root = std::env::temp_dir();
        root.push(format!("lithe-build-test-{}-{}", name, std::process::id()));
        if spaced {
            root.push("dir with spaces");
        }
        std::fs::create_dir_all(&root).expect("temp workspace created");
        TempWorkspace { root }
    }

    fn root(&self) -> String {
        self.root.to_string_lossy().to_string()
    }

    fn write(&self, relative: &str, contents: &str) {
        let path = self.root.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("parent created");
        }
        std::fs::write(path, contents).expect("file written");
    }
}

impl Drop for TempWorkspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Option store rooted in its own temp directory.
struct TempOptions {
    root: PathBuf,
}

impl TempOptions {
    fn new(name: &str) -> Self {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "lithe-build-options-{}-{}",
            name,
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp options dir created");
        TempOptions { root }
    }

    fn stored(&self, workspace_root: &str) -> StoredBuildOptions {
        self.load(workspace_root).expect("options load")
    }
}

impl Drop for TempOptions {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

impl BuildOptionsPersistence for TempOptions {
    fn load(&self, workspace_root: &str) -> Result<StoredBuildOptions, String> {
        let path = self.root.join(format!(
            "{}.json",
            super::store::workspace_state_key(workspace_root)
        ));
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(StoredBuildOptions::default())
            }
            Err(error) => return Err(error.to_string()),
        };
        serde_json::from_str(&text).map_err(|error| error.to_string())
    }

    fn save(&self, workspace_root: &str, options: &StoredBuildOptions) -> Result<(), String> {
        let path = self.root.join(format!(
            "{}.json",
            super::store::workspace_state_key(workspace_root)
        ));
        std::fs::write(
            &path,
            serde_json::to_string_pretty(options).map_err(|e| e.to_string())?,
        )
        .map_err(|error| error.to_string())
    }
}

/// One fixture package whose enabled state and version the test controls,
/// simulating plugin management without touching shared state.
struct FixedPackages {
    plugin_id: String,
    manifest: Mutex<Value>,
    version: Mutex<String>,
    enabled: Mutex<bool>,
}

impl FixedPackages {
    fn one(manifest: Value) -> Self {
        FixedPackages {
            plugin_id: manifest["id"].as_str().expect("fixture id").to_string(),
            manifest: Mutex::new(manifest),
            version: Mutex::new("0.1.0".to_string()),
            enabled: Mutex::new(true),
        }
    }

    fn set_enabled(&self, enabled: bool) {
        *self.enabled.lock().expect("enabled flag") = enabled;
    }

    fn set_version(&self, version: &str) {
        *self.version.lock().expect("version") = version.to_string();
    }

    fn set_manifest(&self, manifest: Value) {
        *self.manifest.lock().expect("manifest") = manifest;
    }

    fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    fn input(&self) -> Option<BuildPackageInput> {
        if !*self.enabled.lock().expect("enabled flag") {
            return None;
        }
        let version = self.version.lock().expect("version").clone();
        Some(BuildPackageInput {
            plugin_id: self.plugin_id.clone(),
            version: version.clone(),
            manifest: self.manifest.lock().expect("manifest").clone(),
            content_identity: version,
        })
    }
}

impl BuildPackageSource for FixedPackages {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        self.input().into_iter().collect()
    }

    fn package(&self, plugin_id: &str) -> Option<BuildPackageInput> {
        if plugin_id == self.plugin_id {
            self.input()
        } else {
            None
        }
    }
}

/// Real Core through the shared host envelope.
struct RealCore;

impl BuildCoreExecutor for RealCore {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::scan::core_execute(command, payload)
    }
}

/// Core double with scripted responses, for envelope failure paths.
struct ScriptedCore {
    responses: Mutex<Vec<Result<Value, String>>>,
}

impl ScriptedCore {
    fn rejected(code: &str, message: &str) -> Self {
        ScriptedCore {
            responses: Mutex::new(vec![Ok(json!({
                "status": "rejected",
                "error": { "code": code, "message": message },
            }))]),
        }
    }

    fn broken() -> Self {
        ScriptedCore {
            responses: Mutex::new(vec![Ok(json!({ "status": "mysterious" }))]),
        }
    }
}

impl BuildCoreExecutor for ScriptedCore {
    fn execute(&self, _command: &str, _payload: Value) -> Result<Value, String> {
        self.responses
            .lock()
            .expect("scripted responses")
            .pop()
            .expect("scripted response for every call")
    }
}

fn cargo_toml(features: &[(&str, &[&str])]) -> String {
    let mut toml = String::from(
        "[package]\nname = \"fixture-app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[[bin]]\nname = \"fixture-app\"\npath = \"src/main.rs\"\n",
    );
    if !features.is_empty() {
        toml.push_str("\n[features]\n");
        for (name, deps) in features {
            let values = deps
                .iter()
                .map(|dep| format!("\"{dep}\""))
                .collect::<Vec<_>>()
                .join(", ");
            toml.push_str(&format!("{name} = [{values}]\n"));
        }
    }
    toml
}

fn standard_workspace(name: &str) -> TempWorkspace {
    let workspace = TempWorkspace::new(name, true);
    workspace.write("Cargo.toml", &cargo_toml(&[]));
    workspace.write("src/main.rs", "fn main() {}\n");
    workspace
}

fn view_json(view: &super::build_registry::BuildView) -> Value {
    serde_json::to_value(view).expect("view serializes")
}

fn option_value<'a>(view: &'a Value, root: &str, option_id: &str) -> &'a Value {
    view["instances"]
        .as_array()
        .expect("instances")
        .iter()
        .find(|instance| instance["root"].as_str() == Some(root))
        .unwrap_or_else(|| panic!("instance at {root}"))
        .get("options")
        .expect("options list")
        .as_array()
        .expect("options array")
        .iter()
        .find(|option| option["id"].as_str() == Some(option_id))
        .unwrap_or_else(|| panic!("option {option_id}"))
        .get("value")
        .expect("option value")
}

#[test]
fn detect_reads_the_static_model_and_describes_options() {
    let workspace = standard_workspace("detect");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("detect");
    let mut registry = BuildRegistry::new();

    let view = registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect succeeds");
    let view = view_json(&view);

    assert_eq!(view["instances"].as_array().expect("instances").len(), 1);
    let instance = &view["instances"][0];
    assert_eq!(instance["buildSystemID"], json!("cargo"));
    assert_eq!(instance["modelSource"], json!("static"));
    assert_eq!(
        instance["pluginID"],
        json!("dev.lithe.fixture.build-static-file")
    );
    assert_eq!(
        instance["model"]["projects"][0]["name"],
        json!("fixture-app")
    );
    assert_eq!(instance["stale"], json!(false));
    let kinds: Vec<&str> = instance["options"]
        .as_array()
        .expect("options")
        .iter()
        .filter_map(|option| option["kind"].as_str())
        .collect();
    assert!(kinds.contains(&"boolean") && kinds.contains(&"multiSelect"));
    assert!(instance["optionFingerprint"].is_string());
}

#[test]
fn project_settings_reload_invalidates_only_its_original_window_and_retries_the_same_owner() {
    let workspace = standard_workspace("settings-reload-scope");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("settings-reload-scope");
    let mut registry = BuildRegistry::new();
    let first = registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .unwrap();
    let other = registry
        .refresh(
            &RealCore,
            &packages,
            &options,
            "workspace-other",
            &workspace.root(),
        )
        .unwrap();
    let old = registry
        .model_context(
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .unwrap();
    let untouched = registry
        .model_context(
            "workspace-other",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .unwrap();
    let generation = registry
        .begin_settings_reload("main", &workspace.root(), packages.plugin_id())
        .unwrap();
    assert!(!registry.context_is_current(&old));
    assert!(registry.context_is_current(&untouched));
    assert!(registry
        .model_context(
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            "."
        )
        .is_err());
    // A failed drain performs no publication or release. Retrying does not
    // advance another workspace's generation or borrow its process owner.
    assert_eq!(
        registry
            .begin_settings_reload("main", &workspace.root(), packages.plugin_id())
            .unwrap(),
        generation
    );
    let result = registry
        .reload_settings(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            generation,
            packages.plugin_id(),
            &|| Ok(()),
        )
        .unwrap();
    assert_eq!(result.generation, first.generation);
    assert!(!registry.context_is_current(&old));
    assert_eq!(
        view_json(&registry.view("workspace-other")),
        view_json(&other)
    );
    assert!(registry.context_is_current(&untouched));
    assert!(registry
        .model_context(
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            "."
        )
        .is_ok());
}

#[test]
fn settings_reload_function_revision_survives_completion_and_is_scoped_to_one_plugin_window() {
    let workspace = standard_workspace("settings-reload-function-scope");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("settings-reload-function-scope");
    let mut registry = BuildRegistry::new();
    assert_eq!(
        registry
            .settings_scope_revision("main", &workspace.root(), packages.plugin_id())
            .unwrap(),
        0
    );
    for label in ["main", "workspace-other"] {
        registry
            .refresh(&RealCore, &packages, &options, label, &workspace.root())
            .unwrap();
    }
    let revision = |registry: &BuildRegistry, label, plugin| {
        registry.function_scope_revision(label, &workspace.root(), plugin)
    };
    let old = revision(&registry, "main", packages.plugin_id()).unwrap();
    let other_window = revision(&registry, "workspace-other", packages.plugin_id()).unwrap();
    let other_plugin = revision(&registry, "main", "other.plugin").unwrap();
    let generation = registry
        .begin_settings_reload("main", &workspace.root(), packages.plugin_id())
        .unwrap();
    assert!(revision(&registry, "main", packages.plugin_id()).is_err());
    assert_eq!(
        revision(&registry, "workspace-other", packages.plugin_id()).unwrap(),
        other_window
    );
    assert_eq!(
        revision(&registry, "main", "other.plugin").unwrap(),
        other_plugin
    );
    registry
        .begin_settings_reload("main", &workspace.root(), packages.plugin_id())
        .unwrap();
    registry.finish_settings_reload("main", generation, packages.plugin_id());
    assert_eq!(
        revision(&registry, "main", packages.plugin_id()).unwrap(),
        old + 1
    );
    assert_eq!(
        revision(&registry, "main", "other.plugin").unwrap(),
        other_plugin
    );
}

#[test]
fn project_settings_reload_refuses_late_close_reopen_and_failed_receipt_check() {
    let workspace = standard_workspace("settings-reload-stale");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("settings-reload-stale");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .unwrap();
    let generation = registry
        .begin_settings_reload("main", &workspace.root(), packages.plugin_id())
        .unwrap();
    let before = view_json(&registry.view("main"));
    let failed = registry.reload_settings(
        &RealCore,
        &packages,
        &options,
        "main",
        &workspace.root(),
        generation,
        packages.plugin_id(),
        &|| Err("plugin.settings.conflict".into()),
    );
    assert_eq!(failed.unwrap_err(), "plugin.settings.conflict");
    assert_eq!(view_json(&registry.view("main")), before);
    registry.close_workspace("main", &workspace.root());
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .unwrap();
    let reopened = view_json(&registry.view("main"));
    assert!(registry
        .reload_settings(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            generation,
            packages.plugin_id(),
            &|| Ok(())
        )
        .is_err());
    registry.finish_settings_reload("main", generation, packages.plugin_id());
    assert_eq!(view_json(&registry.view("main")), reopened);
}

#[test]
fn project_settings_reload_preserves_core_ownership_and_unrelated_model_contexts() {
    struct Packages(Vec<BuildPackageInput>);
    impl BuildPackageSource for Packages {
        fn accepted_packages(&self) -> Vec<BuildPackageInput> {
            self.0.clone()
        }
        fn package(&self, id: &str) -> Option<BuildPackageInput> {
            self.0
                .iter()
                .find(|package| package.plugin_id == id)
                .cloned()
        }
    }
    let workspace = standard_workspace("settings-reload-ownership");
    let options = TempOptions::new("settings-reload-ownership");
    let mut winner = FixedPackages::one(static_fixture()).input().unwrap();
    winner.manifest["buildSystems"][0]["detection"]["priority"] = json!(1);
    let mut loser = winner.clone();
    loser.plugin_id = "io.example.shadowed".into();
    loser.manifest["id"] = json!(loser.plugin_id);
    loser.manifest["buildSystems"][0]["detection"]["priority"] = json!(0);
    let packages = Packages(vec![winner.clone(), loser.clone()]);
    let mut registry = BuildRegistry::new();
    let before = registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .unwrap();
    let context = registry
        .model_context("main", &workspace.root(), &winner.plugin_id, "cargo", ".")
        .unwrap();
    let generation = registry
        .begin_settings_reload("main", &workspace.root(), &loser.plugin_id)
        .unwrap();
    let after = registry
        .reload_settings(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            generation,
            &loser.plugin_id,
            &|| Ok(()),
        )
        .unwrap();
    assert!(registry.context_is_current(&context));
    assert_eq!(view_json(&before), view_json(&after));
    assert!(after
        .instances
        .iter()
        .all(|instance| instance["pluginID"] != loser.plugin_id));
}

#[test]
fn rejected_manifest_uses_its_original_request_index_for_the_plugin_id() {
    struct MixedPackages(Vec<BuildPackageInput>);
    impl BuildPackageSource for MixedPackages {
        fn accepted_packages(&self) -> Vec<BuildPackageInput> {
            self.0.clone()
        }

        fn package(&self, plugin_id: &str) -> Option<BuildPackageInput> {
            self.0
                .iter()
                .find(|package| package.plugin_id == plugin_id)
                .cloned()
        }
    }

    let workspace = standard_workspace("rejection-owner");
    let options = TempOptions::new("rejection-owner");
    let valid = FixedPackages::one(static_fixture())
        .input()
        .expect("valid package");
    let mut invalid = valid.clone();
    invalid.plugin_id = "io.example.invalid-build".into();
    invalid.manifest["id"] = json!(invalid.plugin_id);
    invalid.manifest["version"] = json!("not-a-version");
    let packages = MixedPackages(vec![valid.clone(), invalid.clone()]);
    let mut registry = BuildRegistry::new();
    let view = view_json(
        &registry
            .refresh(&RealCore, &packages, &options, "main", &workspace.root())
            .expect("the valid package still detects"),
    );

    assert_eq!(view["instances"][0]["pluginID"], json!(valid.plugin_id));
    assert_eq!(view["issues"].as_array().expect("issues").len(), 1);
    assert_eq!(view["issues"][0]["index"], json!(1));
    assert_eq!(view["issues"][0]["pluginID"], json!(invalid.plugin_id));
    assert_eq!(view["issues"][0]["kind"], json!("rejected"));
}

#[test]
fn malformed_rejection_indices_do_not_blame_an_unrelated_package() {
    let workspace = standard_workspace("rejection-index");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("rejection-index");
    let core = ScriptedCore {
        responses: Mutex::new(vec![Ok(json!({
            "status":"ok",
            "detection": { "instances":[], "shadowed":[], "rejected":[
                {"index":-1,"error":{"code":"invalid"}},
                {"index":99,"error":{"code":"invalid"}},
                {"index":"0","error":{"code":"invalid"}}
            ] }
        }))]),
    };
    let mut registry = BuildRegistry::new();
    let view = view_json(
        &registry
            .refresh(&core, &packages, &options, "main", &workspace.root())
            .expect("invalid rejection indices remain diagnostic data"),
    );

    for issue in view["issues"].as_array().expect("issues") {
        assert!(
            issue.get("pluginID").is_none(),
            "unrelated package must not be blamed: {issue}"
        );
    }
}

#[test]
fn option_edits_persist_and_survive_a_registry_rebuild() {
    let workspace = standard_workspace("persist");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("persist");
    let mut registry = BuildRegistry::new();

    let view = view_json(
        &registry
            .refresh(&RealCore, &packages, &options, "main", &workspace.root())
            .expect("detect"),
    );
    let default_fingerprint = view["instances"][0]["optionFingerprint"]
        .as_str()
        .expect("fingerprint")
        .to_string();

    let view = view_json(
        &registry
            .set_option(
                &RealCore,
                &packages,
                &options,
                "main",
                &workspace.root(),
                packages.plugin_id(),
                "cargo",
                ".",
                "release",
                Some(json!(true)),
            )
            .expect("option edit"),
    );
    assert_eq!(option_value(&view, ".", "release"), &json!(true));
    assert_eq!(
        options.stored(&workspace.root()).systems["cargo"].values["release"],
        json!(true)
    );

    // A rebuilt registry (app restart) detects with the stored values and
    // keeps the changed fingerprint.
    let mut rebuilt = BuildRegistry::new();
    let view = view_json(
        &rebuilt
            .refresh(&RealCore, &packages, &options, "main", &workspace.root())
            .expect("re-detect"),
    );
    assert_eq!(option_value(&view, ".", "release"), &json!(true));
    let fingerprint = view["instances"][0]["optionFingerprint"]
        .as_str()
        .expect("fingerprint");
    assert_ne!(
        fingerprint, default_fingerprint,
        "fingerprint follows the edit"
    );
}

#[test]
fn an_edit_core_rejects_never_reaches_the_storage() {
    let workspace = standard_workspace("dropped");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("dropped");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    // An edit whose value Core drops (no model choice, wrong type) is a
    // rejected write, not a silent rewrite to the effective value.
    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "features",
            Some(json!(["vanished-feature"])),
        )
        .expect_err("edit with invalid feature");
    assert!(error.contains("rejected by Core"), "{error}");
    assert!(options
        .stored(&workspace.root())
        .systems
        .get("cargo")
        .map(|system| system.values.get("features").is_none())
        .unwrap_or(true));

    // Refresh-time staleness still rewrites silently: a value stored by an
    // older declaration that no instance accepts is replaced with the
    // effective value so repeated detections agree.
    let mut stale = StoredBuildOptions::default();
    stale.systems.insert(
        "cargo".to_string(),
        super::build_registry::StoredSystemOptions {
            values: [("features".to_string(), json!(["vanished-feature"]))]
                .into_iter()
                .collect(),
            empty_markers: Default::default(),
        },
    );
    options.save(&workspace.root(), &stale).expect("seed");
    let view = view_json(
        &registry
            .refresh(&RealCore, &packages, &options, "main", &workspace.root())
            .expect("refresh with stale storage"),
    );
    assert_eq!(option_value(&view, ".", "features"), &json!([]));
    assert_eq!(
        options.stored(&workspace.root()).systems["cargo"].values["features"],
        json!([])
    );
}

#[test]
fn explicit_empty_multiselect_uses_a_marker_and_reset_clears_it() {
    let workspace = TempWorkspace::new("marker", false);
    workspace.write("Cargo.toml", &cargo_toml(&[("alpha", &[])]));
    workspace.write("src/main.rs", "fn main() {}\n");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("marker");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    let view = view_json(
        &registry
            .set_option(
                &RealCore,
                &packages,
                &options,
                "main",
                &workspace.root(),
                packages.plugin_id(),
                "cargo",
                ".",
                "features",
                Some(json!([])),
            )
            .expect("clear"),
    );
    assert_eq!(option_value(&view, ".", "features"), &json!([]));
    let stored = options.stored(&workspace.root());
    assert!(
        stored.systems["cargo"]
            .empty_markers
            .get(".")
            .expect("marker")
            .contains("features"),
        "explicit empty stored as a marker"
    );

    let view = view_json(
        &registry
            .set_option(
                &RealCore,
                &packages,
                &options,
                "main",
                &workspace.root(),
                packages.plugin_id(),
                "cargo",
                ".",
                "features",
                None,
            )
            .expect("reset"),
    );
    assert_eq!(option_value(&view, ".", "features"), &json!([]));
    let stored = options.stored(&workspace.root());
    assert!(
        stored.systems["cargo"].values.get("features").is_none(),
        "reset removes the shared override"
    );
    assert!(
        stored.systems["cargo"]
            .empty_markers
            .get(".")
            .map(|markers| markers.is_empty())
            .unwrap_or(true),
        "reset clears the marker"
    );
}

#[test]
fn editing_one_instance_keeps_sibling_only_selections() {
    let workspace = TempWorkspace::new("siblings", false);
    workspace.write("a/Cargo.toml", &cargo_toml(&[("alpha", &[])]));
    workspace.write("a/src/main.rs", "fn main() {}\n");
    workspace.write("b/Cargo.toml", &cargo_toml(&[("beta", &[])]));
    workspace.write("b/src/main.rs", "fn main() {}\n");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("siblings");
    let mut registry = BuildRegistry::new();
    let view = view_json(
        &registry
            .refresh(&RealCore, &packages, &options, "main", &workspace.root())
            .expect("detect"),
    );
    assert_eq!(view["instances"].as_array().expect("instances").len(), 2);

    // Model choices are offers, not selections: a's alpha only reaches the
    // shared store once the user selects it for a.
    registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            "a",
            "features",
            Some(json!(["alpha"])),
        )
        .expect("select alpha for a");

    // Clearing b keeps a's selection in the shared store; b's own explicit
    // empty lives in its marker.
    let view = view_json(
        &registry
            .set_option(
                &RealCore,
                &packages,
                &options,
                "main",
                &workspace.root(),
                packages.plugin_id(),
                "cargo",
                "b",
                "features",
                Some(json!([])),
            )
            .expect("clear b"),
    );
    assert_eq!(option_value(&view, "a", "features"), &json!(["alpha"]));
    assert_eq!(option_value(&view, "b", "features"), &json!([]));
    let stored = options.stored(&workspace.root());
    assert_eq!(
        stored.systems["cargo"].values["features"],
        json!(["alpha"]),
        "sibling selection survives in the shared store"
    );
}

#[test]
fn workspace_switch_resets_sessions_and_rejects_stale_writes() {
    let first = standard_workspace("switch-a");
    let second = standard_workspace("switch-b");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("switch");
    let mut registry = BuildRegistry::new();

    let view = registry
        .refresh(&RealCore, &packages, &options, "main", &first.root())
        .expect("detect first");
    assert_eq!(view.generation, 0);

    let view = registry
        .refresh(&RealCore, &packages, &options, "main", &second.root())
        .expect("detect second");
    assert!(view.generation > 0, "workspace switch bumps the generation");

    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &first.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("stale write rejected");
    assert!(error.contains("moved to another workspace"), "{error}");
    let error = registry
        .sync_check(
            &RealCore,
            &packages,
            "main",
            &first.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect_err("stale sync rejected");
    assert!(error.contains("moved to another workspace"), "{error}");

    // Re-entering an already-visited workspace must rebuild the native
    // window session before option editing and watcher checks resume.
    let returned = registry
        .refresh(&RealCore, &packages, &options, "main", &first.root())
        .expect("return to first");
    assert_eq!(returned.workspace_root, first.root());
    let edited = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &first.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect("edit after return");
    assert_eq!(
        option_value(&view_json(&edited), ".", "release"),
        &json!(true)
    );
    assert!(options.stored(&second.root()).systems.is_empty());
    first.write("Cargo.toml", &cargo_toml(&[("after-return", &[])]));
    let synced = registry
        .sync_check(
            &RealCore,
            &packages,
            "main",
            &first.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect("sync after return");
    assert_eq!(view_json(&synced)["instances"][0]["stale"], json!(true));
}

#[test]
fn disabling_the_plugin_clears_sessions_and_blocks_writes() {
    let workspace = standard_workspace("disable");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("disable");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    packages.set_enabled(false);
    let view = registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect after disable");
    assert!(view.instances.is_empty(), "sessions cleared");

    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("write after disable");
    assert!(error.contains("no longer an enabled plugin"), "{error}");
}

#[test]
fn file_changes_mark_the_model_stale_through_the_sync_fingerprint() {
    let workspace = standard_workspace("stale");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("stale");
    let mut registry = BuildRegistry::new();
    let initial = registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");
    assert!(view_json(&initial)["instances"][0]["syncDigest"].is_string());

    // The first watcher event after refresh must compare to the loaded
    // model, not establish a baseline from already-changed files.
    workspace.write("Cargo.toml", &cargo_toml(&[("extra", &[])]));
    let view = view_json(
        &registry
            .sync_check(
                &RealCore,
                &packages,
                "main",
                &workspace.root(),
                packages.plugin_id(),
                "cargo",
                ".",
            )
            .expect("first sync after file change"),
    );
    assert_eq!(view["instances"][0]["stale"], json!(true));
    assert!(view["instances"][0]["syncDigest"].is_string());

    // Refresh rebuilds from disk and clears the stale flag.
    let view = view_json(
        &registry
            .refresh(&RealCore, &packages, &options, "main", &workspace.root())
            .expect("reload"),
    );
    assert_eq!(view["instances"][0]["stale"], json!(false));
    let baseline = view["instances"][0]["syncDigest"].clone();
    let unchanged = registry
        .sync_check(
            &RealCore,
            &packages,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect("unchanged after reload");
    assert_eq!(view_json(&unchanged)["instances"][0]["stale"], json!(false));
    assert_eq!(
        view_json(&unchanged)["instances"][0]["syncDigest"],
        baseline
    );

    workspace.write("Cargo.toml", &cargo_toml(&[("next-change", &[])]));
    let changed_again = registry
        .sync_check(
            &RealCore,
            &packages,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect("first event after the second reload");
    assert_eq!(
        view_json(&changed_again)["instances"][0]["stale"],
        json!(true)
    );
}

/// Changes disk at a deterministic Core return boundary, with no watcher,
/// sleep, thread, or assumption about filesystem timestamp resolution.
struct ChangeAfterCoreCall<'a> {
    workspace: &'a TempWorkspace,
    command: &'static str,
    changed: AtomicBool,
}

impl BuildCoreExecutor for ChangeAfterCoreCall<'_> {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        let response = RealCore.execute(command, payload)?;
        if command == self.command && !self.changed.swap(true, Ordering::SeqCst) {
            self.workspace
                .write("Cargo.toml", &cargo_toml(&[("new-feature", &[])]));
        }
        Ok(response)
    }
}

#[test]
fn a_change_between_detection_and_the_baseline_is_read_into_the_model() {
    let workspace = standard_workspace("baseline-before-model");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("baseline-before-model");
    let core = ChangeAfterCoreCall {
        workspace: &workspace,
        command: "build.detect",
        changed: AtomicBool::new(false),
    };
    let mut registry = BuildRegistry::new();
    let loaded = registry
        .refresh(&core, &packages, &options, "main", &workspace.root())
        .expect("refresh");
    let loaded = view_json(&loaded);
    assert_eq!(loaded["instances"][0]["stale"], json!(false));
    assert!(
        loaded["instances"][0]["options"]
            .as_array()
            .expect("options")
            .iter()
            .any(|option| {
                option["id"] == "features"
                    && option["choices"]
                        .as_array()
                        .expect("choices")
                        .iter()
                        .any(|choice| choice["value"] == "new-feature")
            }),
        "the published model rereads the bytes whose fingerprint is stored"
    );
}

#[test]
fn a_change_while_the_model_loads_is_already_stale_at_refresh_completion() {
    let workspace = standard_workspace("change-during-model");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("change-during-model");
    let core = ChangeAfterCoreCall {
        workspace: &workspace,
        command: "build.decodeModel",
        changed: AtomicBool::new(false),
    };
    let mut registry = BuildRegistry::new();
    let loaded = registry
        .refresh(&core, &packages, &options, "main", &workspace.root())
        .expect("refresh");
    assert_eq!(view_json(&loaded)["instances"][0]["stale"], json!(true));
    let refreshed = registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("reload stable files");
    assert_eq!(view_json(&refreshed)["instances"][0]["stale"], json!(false));
}

#[test]
fn windows_keep_their_own_sessions_for_the_same_workspace() {
    let workspace = standard_workspace("windows");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("windows");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(
            &RealCore,
            &packages,
            &options,
            "window-a",
            &workspace.root(),
        )
        .expect("detect a");
    registry
        .refresh(
            &RealCore,
            &packages,
            &options,
            "window-b",
            &workspace.root(),
        )
        .expect("detect b");

    registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "window-a",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect("edit in a");

    // Window b's stored session still shows the value from its own last
    // refresh until that window refreshes itself.
    let view_b = view_json(&registry.view("window-b"));
    assert_eq!(option_value(&view_b, ".", "release"), &json!(false));
    let view_b = view_json(
        &registry
            .refresh(
                &RealCore,
                &packages,
                &options,
                "window-b",
                &workspace.root(),
            )
            .expect("refresh b"),
    );
    assert_eq!(option_value(&view_b, ".", "release"), &json!(true));
}

#[test]
fn a_non_directory_root_detects_as_empty_without_panicking() {
    // Core tolerates non-directory roots and reports no instances; the
    // registry must surface that as an empty view, not an error.
    let workspace = standard_workspace("invalid");
    let file_root = workspace.root.join("Cargo.toml");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("invalid");
    let mut registry = BuildRegistry::new();

    let view = registry
        .refresh(
            &RealCore,
            &packages,
            &options,
            "main",
            &file_root.to_string_lossy(),
        )
        .expect("core answers for non-directory roots");
    assert!(view.instances.is_empty());
}

#[test]
fn core_rejections_and_broken_envelopes_surface_as_errors() {
    let workspace = standard_workspace("envelope");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("envelope");

    let mut registry = BuildRegistry::new();
    let error = registry
        .refresh(
            &ScriptedCore::rejected("plugin.build.invalidSelection", "bad request"),
            &packages,
            &options,
            "main",
            &workspace.root(),
        )
        .expect_err("rejected detect");
    assert!(error.contains("plugin.build.invalidSelection"), "{error}");

    let mut registry = BuildRegistry::new();
    let error = registry
        .refresh(
            &ScriptedCore::broken(),
            &packages,
            &options,
            "main",
            &workspace.root(),
        )
        .expect_err("unexpected status");
    assert!(error.contains("unexpected status"), "{error}");
}

#[test]
fn an_invalid_option_value_is_rejected_without_touching_storage() {
    let workspace = standard_workspace("invalid-value");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("invalid-value");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!("yes")),
        )
        .expect_err("a string is not a boolean value");
    assert!(error.contains("rejected by Core"), "{error}");

    // The storage and the visible model keep the previous state.
    let stored = options.stored(&workspace.root());
    assert!(stored
        .systems
        .get("cargo")
        .map(|system| system.values.get("release").is_none())
        .unwrap_or(true));
    let view = view_json(&registry.view("main"));
    assert_eq!(option_value(&view, ".", "release"), &json!(false));

    // An unknown multi-select choice is likewise a rejected edit.
    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "features",
            Some(json!(["vanished-feature"])),
        )
        .expect_err("unknown choice");
    assert!(error.contains("rejected by Core"), "{error}");
    assert!(
        options
            .stored(&workspace.root())
            .systems
            .get("cargo")
            .map(|system| system.values.get("features").is_none())
            .unwrap_or(true),
        "storage stayed clean after the rejected edit"
    );
}

/// Persistence double whose next save can be made to fail.
struct FlakySave {
    inner: TempOptions,
    fail_next: Mutex<bool>,
}

impl FlakySave {
    fn new(name: &str) -> Self {
        FlakySave {
            inner: TempOptions::new(name),
            fail_next: Mutex::new(false),
        }
    }

    fn fail_next_save(&self) {
        *self.fail_next.lock().expect("fail flag") = true;
    }
}

impl BuildOptionsPersistence for FlakySave {
    fn load(&self, workspace_root: &str) -> Result<StoredBuildOptions, String> {
        self.inner.load(workspace_root)
    }

    fn save(&self, workspace_root: &str, options: &StoredBuildOptions) -> Result<(), String> {
        if *self.fail_next.lock().expect("fail flag") {
            *self.fail_next.lock().expect("fail flag") = false;
            return Err("disk full".to_string());
        }
        self.inner.save(workspace_root, options)
    }
}

#[test]
fn a_failed_save_leaves_the_previous_options_untouched() {
    let workspace = standard_workspace("save-fail");
    let packages = FixedPackages::one(static_fixture());
    let options = FlakySave::new("save-fail");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    options.fail_next_save();
    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("save failure surfaces");
    assert!(error.contains("disk full"), "{error}");
    assert!(
        options
            .inner
            .stored(&workspace.root())
            .systems
            .get("cargo")
            .map(|system| system.values.get("release").is_none())
            .unwrap_or(true),
        "storage unchanged after the failed save"
    );
}

/// Core double with an ordered response script and a record of payloads.
struct ScriptedSequence {
    responses: Mutex<Vec<Result<Value, String>>>,
    seen: Mutex<Vec<(String, Value)>>,
}

impl ScriptedSequence {
    fn ok_then_detect_error() -> Self {
        ScriptedSequence {
            responses: Mutex::new(vec![
                // set_option validation: resolveOptions ok.
                Ok(json!({
                    "status": "ok",
                    "options": { "options": [
                        { "id": "release", "kind": "boolean", "value": true, "choices": [] },
                        { "id": "features", "kind": "multiSelect", "value": [], "choices": [] },
                        { "id": "offline", "kind": "boolean", "value": false, "choices": [] }
                    ], "dropped": [], "fingerprint": "validated" }
                })),
                // The re-detection after the save fails.
                Ok(json!({
                    "status": "rejected",
                    "error": { "code": "plugin.build.invalidSelection", "message": "boom" }
                })),
            ]),
            seen: Mutex::new(Vec::new()),
        }
    }

    fn sync_response() -> Self {
        ScriptedSequence {
            responses: Mutex::new(vec![Ok(json!({
                "status": "ok",
                "sync": { "fingerprint": "synced", "watch": [] }
            }))]),
            seen: Mutex::new(Vec::new()),
        }
    }
}

impl BuildCoreExecutor for ScriptedSequence {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        self.seen
            .lock()
            .expect("seen")
            .push((command.to_string(), payload.clone()));
        self.responses
            .lock()
            .expect("scripted responses")
            .pop()
            .expect("scripted response for every call")
    }
}

#[test]
fn a_failed_redetection_rolls_back_the_saved_options() {
    let workspace = standard_workspace("rollback");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("rollback");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");
    let generation_before = registry.view("main").generation;

    let core = ScriptedSequence::ok_then_detect_error();
    let error = registry
        .set_option(
            &core,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("re-detection failure surfaces");
    assert!(error.contains("plugin.build.invalidSelection"), "{error}");

    // The saved candidate was rolled back and the sessions are untouched.
    let stored = options.stored(&workspace.root());
    assert!(
        stored
            .systems
            .get("cargo")
            .map(|system| system.values.get("release").is_none())
            .unwrap_or(true),
        "storage rolled back to the pre-edit values"
    );
    let view = view_json(&registry.view("main"));
    assert_eq!(option_value(&view, ".", "release"), &json!(false));
    assert_eq!(registry.view("main").generation, generation_before);
}

#[test]
fn a_replaced_package_refuses_sync_and_option_writes() {
    let workspace = standard_workspace("replaced");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("replaced");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    packages.set_version("0.2.0");
    let error = registry
        .sync_check(
            &RealCore,
            &packages,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect_err("version change refuses sync");
    assert!(error.contains("changed since"), "{error}");
    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("version change refuses writes");
    assert!(error.contains("changed since"), "{error}");

    // A disabled package refuses the same queries.
    packages.set_version("0.1.0");
    packages.set_enabled(false);
    let error = registry
        .sync_check(
            &RealCore,
            &packages,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect_err("disabled package refuses sync");
    assert!(error.contains("no longer an enabled plugin"), "{error}");
}

#[test]
fn drop_plugin_revokes_sessions_and_blocks_writes() {
    let workspace = standard_workspace("revoke");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("revoke");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    registry.drop_plugin(packages.plugin_id());
    let view = view_json(&registry.view("main"));
    assert!(view["instances"].as_array().expect("instances").is_empty());

    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("revoked session refuses writes");
    assert!(error.contains("no build instance"), "{error}");
}

#[test]
fn closing_the_workspace_clears_sessions_before_a_reopen() {
    let workspace = standard_workspace("close");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("close");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    registry.close_workspace("main", &workspace.root());
    let view = view_json(&registry.view("main"));
    assert!(view["instances"].as_array().expect("instances").is_empty());
    assert_eq!(
        view["workspaceRoot"], "",
        "a closed root is no longer readable"
    );
    let generation = view["generation"].as_u64().expect("generation");
    assert!(generation > 0, "close bumps the generation");

    let error = registry
        .set_option(
            &RealCore,
            &packages,
            &options,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
            "release",
            Some(json!(true)),
        )
        .expect_err("closed workspace refuses writes");
    assert!(error.contains("moved to another workspace"), "{error}");
    assert!(registry
        .check_read_snapshot("main", &workspace.root(), generation)
        .is_err());
}

#[test]
fn sync_sends_the_current_verified_manifest_not_the_session_snapshot() {
    let workspace = standard_workspace("fresh-manifest");
    let packages = FixedPackages::one(static_fixture());
    let options = TempOptions::new("fresh-manifest");
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&RealCore, &packages, &options, "main", &workspace.root())
        .expect("detect");

    // Same-version reinstall: the bytes and therefore the manifest change
    // under the same plugin ID and version.
    let mut replaced = static_fixture();
    replaced["displayName"] = json!("Reinstalled Fixture");
    packages.set_manifest(replaced.clone());

    let core = ScriptedSequence::sync_response();
    registry
        .sync_check(
            &core,
            &packages,
            "main",
            &workspace.root(),
            packages.plugin_id(),
            "cargo",
            ".",
        )
        .expect("sync succeeds with the fresh package");

    let seen = core.seen.lock().expect("seen");
    let (_, payload) = seen
        .iter()
        .find(|(command, _)| command == "build.syncFingerprint")
        .expect("sync request recorded");
    assert_eq!(
        payload["manifest"]["displayName"],
        json!("Reinstalled Fixture")
    );
}
