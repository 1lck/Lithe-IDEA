//! Real Core/legacy Maven backend regressions for passive model admission,
//! exact reactor roots, options, package identity and publication. All races
//! are controlled at a Core return boundary; no tools, JDT or timers run.

use super::super::build_registry::*;
use super::operation::next_operation_id;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};

const SYSTEM: &str = "fixture-reactor";

struct Workspace(PathBuf);
impl Workspace {
    fn new() -> Self {
        let workspace =
            Self(std::env::temp_dir().join(format!("lithe maven model {}", next_operation_id())));
        workspace.write("north/pom.xml", &pom("north", "<packaging>pom</packaging><modules><module>lib</module></modules><profiles><profile><id>alpha</id></profile></profiles>"));
        workspace.write("north/lib/pom.xml", &pom("library", "<modules><module>deep</module></modules><build><sourceDirectory>sources/main</sourceDirectory><testSourceDirectory>sources/test</testSourceDirectory><resources><resource><directory>assets/main</directory></resource></resources></build>"));
        workspace.write("north/lib/deep/pom.xml", &pom("deep", ""));
        workspace.write(
            "south/pom.xml",
            &pom(
                "south",
                "<profiles><profile><id>beta</id></profile></profiles>",
            ),
        );
        for root in ["north", "south"] {
            workspace.write(&format!("{root}/mvnw.cmd"), "@echo off\r\nexit /b 99\r\n");
            workspace.write(
                &format!("{root}/.mvn/wrapper/maven-wrapper.properties"),
                "distributionUrl=https://example.invalid/maven.zip\n",
            );
        }
        workspace
    }
    fn path(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
    fn write(&self, relative: &str, text: &str) {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("directory");
        std::fs::write(path, text).expect("fixture file");
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn pom(artifact: &str, body: &str) -> String {
    format!("<project><modelVersion>4.0.0</modelVersion><groupId>fixture.test</groupId><artifactId>{artifact}</artifactId><version>1</version>{body}</project>")
}
fn declaration() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/contracts/plugins/v1/fixtures/build-host-integration.plugin.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("fixture"))
            .expect("manifest JSON");
    // Integration dispatch belongs to Core's declaration, never a host test
    // for one plugin ID or the literal build-system ID `maven`.
    manifest["id"] = json!("dev.lithe.fixture.alternate-reactor");
    manifest["buildSystems"][0]["id"] = json!(SYSTEM);
    manifest["activationEvents"] = json!([format!("onBuildSystem:{SYSTEM}")]);
    manifest
}
struct Packages(Mutex<Option<BuildPackageInput>>);
impl Packages {
    fn new() -> Self {
        let manifest = declaration();
        Self(Mutex::new(Some(BuildPackageInput {
            plugin_id: manifest["id"].as_str().expect("ID").into(),
            version: "0.1.0".into(),
            manifest,
            content_identity: "verified-installation:first".into(),
        })))
    }
    fn input(&self) -> BuildPackageInput {
        self.0.lock().expect("package").clone().expect("enabled")
    }
}
impl BuildPackageSource for Packages {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        self.0
            .lock()
            .expect("package")
            .clone()
            .into_iter()
            .collect()
    }
    fn package(&self, id: &str) -> Option<BuildPackageInput> {
        self.0
            .lock()
            .expect("package")
            .as_ref()
            .filter(|package| package.plugin_id == id)
            .cloned()
    }
}
#[derive(Default)]
struct Options {
    values: Mutex<StoredBuildOptions>,
    saves: AtomicUsize,
}
impl BuildOptionsPersistence for Options {
    fn load(&self, _: &str) -> Result<StoredBuildOptions, String> {
        Ok(self.values.lock().expect("options").clone())
    }
    fn save(&self, _: &str, options: &StoredBuildOptions) -> Result<(), String> {
        *self.values.lock().expect("options") = options.clone();
        self.saves.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}
type CoreBoundary = Arc<dyn Fn(&str, &Value) + Send + Sync>;
#[derive(Default)]
struct Core {
    seen: Mutex<Vec<(String, Value)>>,
    after: Option<CoreBoundary>,
}
impl BuildCoreExecutor for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        self.seen
            .lock()
            .expect("calls")
            .push((command.into(), payload.clone()));
        let result = super::super::scan::core_execute(command, payload.clone());
        if let Some(after) = &self.after {
            after(command, &payload);
        }
        result
    }
}
fn instance(view: &BuildView, root: &str) -> Value {
    view.instances
        .iter()
        .find(|instance| instance["root"] == root)
        .expect("instance")
        .clone()
}
fn context(
    registry: &BuildRegistry,
    workspace: &Workspace,
    packages: &Packages,
) -> BuildModelContext {
    registry
        .model_context(
            "main",
            &workspace.path(),
            &packages.input().plugin_id,
            SYSTEM,
            "north",
        )
        .expect("context")
}
fn assert_legacy_projects(model: &Value, root: &str, project: &Value) {
    let relative = project["relativePath"].as_str().expect("backend path");
    let path = if relative == "." {
        root.into()
    } else {
        format!("{root}/{relative}")
    };
    let normalized = model["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .find(|candidate| candidate["path"] == path)
        .expect("backend project in build model");
    assert_eq!(normalized["name"], project["artifactId"]);
    for property in ["artifactId", "packaging", "groupId", "version"] {
        if !project[property].is_null() {
            assert_eq!(normalized["properties"][property], project[property]);
        }
    }
    for source in project["sourceRoots"].as_array().expect("source roots") {
        let kind = match source["kind"].as_str().expect("kind") {
            "mainJava" => "source",
            "mainResources" => "resource",
            "testJava" => "testSource",
            "testResources" => "testResource",
            "generatedMain" => "generatedSource",
            "generatedTest" => "generatedTestSource",
            other => panic!("new backend source kind needs an adapter assertion: {other}"),
        };
        let source_path = format!("{path}/{}", source["path"].as_str().expect("source path"));
        assert!(
            model["contentRoots"]
                .as_array()
                .expect("content roots")
                .iter()
                .any(|item| item["projectID"] == normalized["id"]
                    && item["path"] == source_path
                    && item["kind"] == kind),
            "{source_path}"
        );
    }
    for child in project["modules"].as_array().expect("modules") {
        assert_legacy_projects(model, root, child);
    }
}

#[test]
fn passive_models_reuse_legacy_maven_facts_with_exact_instance_roots() {
    let workspace = Workspace::new();
    // Include an ancestor POM, while the declaration explicitly keeps each
    // root separate. Each child still must read its own reactor, not this POM.
    workspace.write("pom.xml", &pom("ancestor", "<packaging>pom</packaging>"));
    let packages = Packages::new();
    packages
        .0
        .lock()
        .expect("package")
        .as_mut()
        .expect("enabled")
        .manifest["buildSystems"][0]["detection"]["nesting"] = json!("separate");
    let core = Core::default();
    let mut registry = BuildRegistry::new();
    let view = registry
        .refresh(
            &core,
            &packages,
            &Options::default(),
            "main",
            &workspace.path(),
        )
        .expect("passive refresh");
    for root in ["north", "south"] {
        let backend = super::super::scan::core_execute(
            "maven.scan",
            json!({"root":workspace.0.join(root), "paths":["pom.xml"]}),
        )
        .expect("legacy Maven backend");
        let instance = instance(&view, root);
        assert_eq!(instance["modelSource"], "hostIntegration");
        assert!(!instance["model"]["projects"]
            .as_array()
            .expect("projects")
            .is_empty());
        assert_legacy_projects(&instance["model"], root, &backend);
        let profiles: Vec<_> = backend["profiles"]
            .as_array()
            .expect("profiles")
            .iter()
            .map(|profile| profile["id"].clone())
            .collect();
        assert_eq!(
            instance["model"]["optionValues"]["profiles"],
            json!(profiles)
        );
        assert_eq!(instance["stale"], false);
    }
    let calls = core.seen.lock().expect("calls");
    assert!(
        calls.iter().all(|(command, _)| matches!(
            command.as_str(),
            "build.detect" | "build.decodeModel" | "build.resolveOptions" | "build.syncFingerprint"
        )),
        "passive discovery never plans a process or probes a wrapper"
    );
    assert!(calls
        .iter()
        .any(|(command, payload)| command == "build.decodeModel"
            && payload["request"]["root"] == "north"));
}

#[test]
fn effective_options_fingerprints_and_model_revisions_stay_together() {
    let workspace = Workspace::new();
    let packages = Packages::new();
    let options = Options::default();
    options
        .values
        .lock()
        .expect("options")
        .systems
        .entry(SYSTEM.into())
        .or_default()
        .values = BTreeMap::from([
        ("profiles".into(), json!(["alpha"])),
        ("offline".into(), json!(true)),
    ]);
    let core = Core::default();
    let mut registry = BuildRegistry::new();
    let view = registry
        .refresh(&core, &packages, &options, "main", &workspace.path())
        .expect("refresh");
    let old = context(&registry, &workspace, &packages);
    assert_eq!(old.options["profiles"], json!(["alpha"]));
    let sync = core.execute("build.syncFingerprint", json!({"manifest":old.package.manifest,"buildSystemID":SYSTEM,"request":{"workspaceRoot":workspace.path(),"root":"north","projects":old.model["projects"].as_array().expect("projects").iter().map(|project| project["path"].clone()).collect::<Vec<_>>(),"options":old.options}})).expect("Core fingerprint");
    assert_eq!(
        instance(&view, "north")["syncDigest"],
        sync["sync"]["fingerprint"]
    );
    let updated = registry
        .set_option(
            &core,
            &packages,
            &options,
            "main",
            &workspace.path(),
            &packages.input().plugin_id,
            SYSTEM,
            "north",
            "profiles",
            Some(json!([])),
        )
        .expect("explicit empty profile selection");
    let new = context(&registry, &workspace, &packages);
    assert!(!registry.context_is_current(&old));
    assert_eq!(new.options["profiles"], json!([]));
    assert_ne!(
        instance(&view, "north")["optionFingerprint"],
        instance(&updated, "north")["optionFingerprint"]
    );
    assert_eq!(new.model, instance(&updated, "north")["model"]);
    assert!(core
        .seen
        .lock()
        .expect("calls")
        .iter()
        .any(|(command, payload)| command == "build.decodeModel"
            && payload["request"]["root"] == "north"
            && payload["request"]["options"]["profiles"] == json!([])));
    registry
        .refresh(&core, &packages, &options, "main", &workspace.path())
        .expect("reload");
    assert!(
        !registry.context_is_current(&new),
        "same-content reload also invalidates approvals"
    );
}

#[test]
fn changing_a_module_during_passive_decode_marks_its_model_stale() {
    let workspace = Arc::new(Workspace::new());
    let changed = Arc::new(AtomicBool::new(false));
    let core = Core {
        seen: Mutex::new(vec![]),
        after: Some(Arc::new({
            let workspace = workspace.clone();
            let changed = changed.clone();
            move |command, payload| {
                if command == "build.decodeModel"
                    && payload["request"]["root"] == "north"
                    && !changed.swap(true, Ordering::SeqCst)
                {
                    workspace.write("north/lib/pom.xml", &pom("new-library", ""));
                }
            }
        })),
    };
    let packages = Packages::new();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    let view = registry
        .refresh(&core, &packages, &options, "main", &workspace.path())
        .expect("refresh");
    assert_eq!(instance(&view, "north")["stale"], true);
    assert_eq!(instance(&view, "south")["stale"], false);
    let old = context(&registry, &workspace, &packages);
    let view = registry
        .refresh(
            &Core::default(),
            &packages,
            &options,
            "main",
            &workspace.path(),
        )
        .expect("stable reload");
    assert_eq!(instance(&view, "north")["stale"], false);
    assert!(instance(&view, "north")["model"]["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .any(|project| project["name"] == "new-library"));
    assert!(!registry.context_is_current(&old));
}

#[test]
fn revocation_and_same_version_replacements_during_decode_cannot_publish() {
    for replacement in ["disabled", "relocated", "manifest"] {
        let workspace = Workspace::new();
        let packages = Arc::new(Packages::new());
        let options = Options::default();
        let mut registry = BuildRegistry::new();
        registry
            .refresh(
                &Core::default(),
                &*packages,
                &options,
                "main",
                &workspace.path(),
            )
            .expect("initial");
        let old = context(&registry, &workspace, &packages);
        let ticket = registry.reserve_refresh("main", &workspace.path());
        let core = Core {
            seen: Mutex::new(vec![]),
            after: Some(Arc::new({
                let packages = packages.clone();
                move |command, _| {
                    if command == "build.decodeModel" {
                        let mut package = packages.0.lock().expect("package");
                        match replacement {
                            "disabled" => *package = None,
                            "relocated" => {
                                package.as_mut().expect("enabled").content_identity =
                                    "verified-installation:second".into()
                            }
                            "manifest" => {
                                package.as_mut().expect("enabled").manifest["displayName"] =
                                    json!("Replaced fixture")
                            }
                            _ => unreachable!(),
                        }
                    }
                }
            })),
        };
        let result = registry.refresh_reserved(&core, &*packages, &options, &ticket, &|| Ok(()));
        assert_eq!(result.err().as_deref(), Some("plugin.build.packageChanged"));
        assert!(!registry.context_is_current(&old));
        assert_eq!(options.saves.load(Ordering::SeqCst), 0);
        registry.drop_plugin(&old.plugin_id);
        assert!(registry.view("main").instances.is_empty());
        assert!(registry
            .refresh_reserved(&Core::default(), &*packages, &options, &ticket, &|| Ok(()))
            .is_err());
    }
}

#[test]
fn same_version_sync_invalidates_model_identity_without_adopting_new_package() {
    let workspace = Workspace::new();
    let packages = Packages::new();
    let options = Options::default();
    let mut registry = BuildRegistry::new();
    registry
        .refresh(
            &Core::default(),
            &packages,
            &options,
            "main",
            &workspace.path(),
        )
        .expect("initial");
    let old = context(&registry, &workspace, &packages);
    packages
        .0
        .lock()
        .expect("package")
        .as_mut()
        .expect("enabled")
        .content_identity = "same-version:new-bytes".into();
    let view = registry
        .sync_check(
            &Core::default(),
            &packages,
            "main",
            &workspace.path(),
            &old.plugin_id,
            SYSTEM,
            "north",
        )
        .expect("sync reports stale using current verified package");
    assert_eq!(instance(&view, "north")["stale"], true);
    assert!(!registry.context_is_current(&old));
    assert_eq!(
        context(&registry, &workspace, &packages).package,
        old.package,
        "old model retains its original decoding identity"
    );
    assert!(registry
        .set_option(
            &Core::default(),
            &packages,
            &options,
            "main",
            &workspace.path(),
            &old.plugin_id,
            SYSTEM,
            "north",
            "offline",
            Some(json!(true))
        )
        .is_err());
    assert_eq!(options.saves.load(Ordering::SeqCst), 0);
    registry
        .refresh(
            &Core::default(),
            &packages,
            &options,
            "main",
            &workspace.path(),
        )
        .expect("explicit reload");
    let new = context(&registry, &workspace, &packages);
    assert_eq!(new.package, packages.input());
    assert!(!new.model_stale);
}

#[test]
fn option_storage_changed_during_model_read_cannot_publish_or_be_overwritten() {
    let workspace = Workspace::new();
    let packages = Packages::new();
    let options = Arc::new(Options::default());
    let core = Core {
        seen: Mutex::new(vec![]),
        after: Some(Arc::new({
            let options = options.clone();
            move |command, _| {
                if command == "build.decodeModel" {
                    options
                        .values
                        .lock()
                        .expect("options")
                        .systems
                        .entry(SYSTEM.into())
                        .or_default()
                        .values
                        .insert("offline".into(), json!(true));
                }
            }
        })),
    };
    let mut registry = BuildRegistry::new();
    let ticket = registry.reserve_refresh("main", &workspace.path());
    assert_eq!(
        registry
            .refresh_reserved(&core, &packages, &*options, &ticket, &|| Ok(()))
            .err()
            .as_deref(),
        Some("plugin.build.staleContext")
    );
    assert!(registry.view("main").instances.is_empty());
    assert_eq!(options.saves.load(Ordering::SeqCst), 0);
    assert_eq!(
        options.values.lock().expect("options").systems[SYSTEM].values["offline"],
        true
    );
    // The consumed request cannot be replayed against the changed options.
    assert!(registry
        .refresh_reserved(&Core::default(), &packages, &*options, &ticket, &|| Ok(()))
        .is_err());
}

#[test]
fn queued_initial_refresh_cannot_revive_a_closed_or_replaced_workspace() {
    for action in [
        "workspace-close",
        "window-close",
        "new-request",
        "option-change",
        "plugin-change",
    ] {
        let workspace = Workspace::new();
        let packages = Packages::new();
        let options = Options::default();
        let mut registry = BuildRegistry::new();
        let ticket = registry.reserve_refresh("main", &workspace.path());
        match action {
            "workspace-close" => registry.close_workspace("main", &workspace.path()),
            "window-close" => registry.close_window("main"),
            "new-request" => {
                registry.reserve_refresh("main", "different-workspace");
            }
            "option-change" => {
                registry.suspend_execution("main");
                registry.resume_execution("main");
            }
            "plugin-change" => registry.drop_plugin(&packages.input().plugin_id),
            _ => unreachable!(),
        }
        let core = Core::default();
        assert_eq!(
            registry
                .refresh_reserved(&core, &packages, &options, &ticket, &|| Ok(()))
                .err()
                .as_deref(),
            Some("plugin.build.staleContext")
        );
        assert!(
            core.seen.lock().expect("calls").is_empty(),
            "refuse before rereading a closed workspace"
        );
        assert!(registry.view("main").instances.is_empty());
        let second = registry.reserve_refresh("workspace-second", &workspace.path());
        assert!(!registry
            .refresh_reserved(&core, &packages, &options, &second, &|| Ok(()))
            .expect("other window remains independent")
            .instances
            .is_empty());
    }
}

#[test]
fn window_checkpoint_and_failed_passive_decode_do_not_publish_a_ready_model() {
    let workspace = Arc::new(Workspace::new());
    let packages = Packages::new();
    let options = Options::default();
    let live = Arc::new(AtomicBool::new(true));
    let core = Core {
        seen: Mutex::new(vec![]),
        after: Some(Arc::new({
            let live = live.clone();
            move |command, _| {
                if command == "build.decodeModel" {
                    live.store(false, Ordering::SeqCst);
                }
            }
        })),
    };
    let mut registry = BuildRegistry::new();
    let ticket = registry.reserve_refresh("main", &workspace.path());
    assert!(registry
        .refresh_reserved(
            &core,
            &packages,
            &options,
            &ticket,
            &|| if live.load(Ordering::SeqCst) {
                Ok(())
            } else {
                Err("plugin.build.staleContext".into())
            }
        )
        .is_err());
    assert!(registry.view("main").instances.is_empty());
    let core = Core {
        seen: Mutex::new(vec![]),
        after: Some(Arc::new({
            let workspace = workspace.clone();
            move |command, _| {
                if command == "build.detect" {
                    workspace.write("north/pom.xml", "<project>");
                }
            }
        })),
    };
    let view = registry
        .refresh(&core, &packages, &options, "main", &workspace.path())
        .expect("a failed reactor does not hide its sibling");
    assert!(instance(&view, "north")["model"].is_null());
    assert_eq!(
        instance(&view, "north")["modelError"]["code"],
        "plugin.build.invalidOutput"
    );
    assert!(!instance(&view, "south")["model"].is_null());
}
