//! Windows-side build session registry for declarative build systems.
//!
//! One registry holds per-window build facts (instances, static models,
//! option descriptions, sync digests) keyed by window label and workspace
//! root. Every semantic interpretation stays in Core: this module only
//! shapes `build.*` requests, applies the host storage rules (values shared
//! per build system plus per-instance explicit-empty markers), and refuses
//! writes whose window has already moved to another workspace. Package
//! identity is re-checked against the injected source before every write,
//! so a disabled, replaced, or quarantined package never keeps answering
//! from a stale session. Detection and option resolution run no processes;
//! the capability declaration stays closed until the full milestone.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One verified package as the build pipeline should see it. The version
/// comes from the same trust check as the manifest, so a session can detect
/// a package replacement between operations.
#[derive(Debug, Clone, PartialEq)]
pub struct BuildPackageInput {
    pub plugin_id: String,
    pub version: String,
    pub manifest: Value,
    /// Canonical installation identity plus live whole-package digest,
    /// including same-version replacements and package relocations.
    pub content_identity: String,
}

/// Executes one Core `build.*` command through the shared envelope.
pub trait BuildCoreExecutor: Send + Sync {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String>;
}

/// The verified build packages. Production re-verifies trust against the
/// live bytes (M1's launch gate) on every call; tests inject fixture
/// manifests, which is the only sanctioned way to exercise build
/// declarations while the capability is closed.
pub trait BuildPackageSource: Send + Sync {
    fn accepted_packages(&self) -> Vec<BuildPackageInput>;

    /// The current verified package for one plugin, or `None` when it is no
    /// longer accepted, enabled, or trusted.
    fn package(&self, plugin_id: &str) -> Option<BuildPackageInput>;
}

/// Persists build option values per workspace. Values are shared per build
/// system; explicit empty multi-select choices are kept as per-instance
/// markers so sibling instances never lose their own selections.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredBuildOptions {
    pub systems: BTreeMap<String, StoredSystemOptions>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredSystemOptions {
    /// Shared stored values by option ID, in the `build.detect` shape.
    pub values: BTreeMap<String, Value>,
    /// Instance roots whose user explicitly cleared a multi-select option;
    /// the marker wins over a non-empty default until reset or re-edit.
    pub empty_markers: BTreeMap<String, BTreeSet<String>>,
}

pub trait BuildOptionsPersistence: Send + Sync {
    fn load(&self, workspace_root: &str) -> Result<StoredBuildOptions, String>;
    fn save(&self, workspace_root: &str, options: &StoredBuildOptions) -> Result<(), String>;
}

/// One detected build-system instance with its host-side session state.
#[derive(Debug, Clone)]
struct BuildSession {
    plugin_id: String,
    build_system_id: String,
    root: String,
    /// Package version the session was built from; a later mismatch means
    /// the package was replaced and the session must not be trusted.
    version: String,
    /// The manifest of the owning package, for plan-shaped Core calls.
    manifest: Value,
    content_identity: String,
    /// Core's detect instance, including the static model when it has one.
    instance: Value,
    /// `build.resolveOptions` description: kinds, choices, effective values.
    options_description: Value,
    /// Effective values (markers applied) as a plain map for sync requests.
    effective_options: BTreeMap<String, Value>,
    /// Model-declared choice values, carried into option resolution.
    model_values: BTreeMap<String, Vec<String>>,
    /// Last `build.syncFingerprint` digest; `None` before the first check.
    sync_digest: Option<String>,
    /// True when a later digest differs from the one the model was built
    /// with; the model stays visible until the user refreshes.
    stale: bool,
}

#[derive(Debug, Default)]
struct WindowState {
    workspace_root: Option<String>,
    generation: u64,
    /// Keyed by (plugin ID, build system ID, instance root).
    sessions: BTreeMap<(String, String, String), BuildSession>,
    issues: Vec<Value>,
}

/// Immutable snapshot for one window: sessions and issues as JSON.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildView {
    pub generation: u64,
    pub workspace_root: String,
    pub instances: Vec<Value>,
    pub issues: Vec<Value>,
}

#[derive(Debug, Default)]
pub struct BuildRegistry {
    windows: HashMap<String, WindowState>,
}

/// Frozen semantic input for an explicit model load. The host operation
/// coordinator owns execution and checks this snapshot again before writes.
#[derive(Debug, Clone)]
pub(crate) struct BuildModelContext {
    pub window_label: String,
    pub workspace_root: String,
    pub generation: u64,
    pub plugin_id: String,
    pub build_system_id: String,
    pub root: String,
    pub package: BuildPackageInput,
    pub options: BTreeMap<String, Value>,
}

impl BuildRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn model_context(
        &self,
        window_label: &str,
        workspace_root: &str,
        plugin_id: &str,
        build_system_id: &str,
        root: &str,
    ) -> Result<BuildModelContext, String> {
        let window = self
            .windows
            .get(window_label)
            .ok_or("plugin.build.staleContext")?;
        if window.workspace_root.as_deref() != Some(workspace_root) {
            return Err("plugin.build.staleContext".into());
        }
        let session = window
            .sessions
            .get(&(plugin_id.into(), build_system_id.into(), root.into()))
            .ok_or("plugin.build.staleContext")?;
        Ok(BuildModelContext {
            window_label: window_label.into(),
            workspace_root: workspace_root.into(),
            generation: window.generation,
            plugin_id: plugin_id.into(),
            build_system_id: build_system_id.into(),
            root: root.into(),
            package: BuildPackageInput {
                plugin_id: plugin_id.into(),
                version: session.version.clone(),
                manifest: session.manifest.clone(),
                content_identity: session.content_identity.clone(),
            },
            options: session.effective_options.clone(),
        })
    }

    pub(crate) fn context_is_current(&self, context: &BuildModelContext) -> bool {
        let Some(window) = self.windows.get(&context.window_label) else {
            return false;
        };
        if window.generation != context.generation
            || window.workspace_root.as_deref() != Some(context.workspace_root.as_str())
        {
            return false;
        }
        window
            .sessions
            .get(&(
                context.plugin_id.clone(),
                context.build_system_id.clone(),
                context.root.clone(),
            ))
            .is_some_and(|session| {
                session.version == context.package.version
                    && session.content_identity == context.package.content_identity
                    && session.manifest == context.package.manifest
                    && session.effective_options == context.options
            })
    }

    /// Apply only the result of the exact operation snapshot. Model choices
    /// and the sync baseline still come from Core, just as on the static path.
    pub(crate) fn apply_command_model(
        &mut self,
        core: &dyn BuildCoreExecutor,
        context: &BuildModelContext,
        model: Value,
        fingerprint_before: &str,
    ) -> Result<BuildView, String> {
        if !self.context_is_current(context) {
            return Err("plugin.build.staleContext".into());
        }
        let window = self
            .windows
            .get_mut(&context.window_label)
            .ok_or("plugin.build.staleContext")?;
        let key = (
            context.plugin_id.clone(),
            context.build_system_id.clone(),
            context.root.clone(),
        );
        let previous = window
            .sessions
            .get(&key)
            .ok_or("plugin.build.staleContext")?;
        let mut instance = previous.instance.clone();
        instance["model"] = model;
        instance
            .as_object_mut()
            .ok_or("invalid build instance")?
            .remove("modelError");
        let mut session = resolve_session(
            core,
            &instance,
            Some(&context.package),
            &context.options,
            BTreeSet::new(),
        )?;
        let after = sync_fingerprint(
            core,
            &context.workspace_root,
            &session,
            &context.package.manifest,
        )?;
        session.stale = fingerprint_before != after;
        session.sync_digest = Some(after);
        window.sessions.insert(key, session);
        Ok(self.view(&context.window_label))
    }

    pub(crate) fn model_fingerprint(
        &self,
        core: &dyn BuildCoreExecutor,
        context: &BuildModelContext,
    ) -> Result<String, String> {
        if !self.context_is_current(context) {
            return Err("plugin.build.staleContext".into());
        }
        let session = &self.windows[&context.window_label].sessions[&(
            context.plugin_id.clone(),
            context.build_system_id.clone(),
            context.root.clone(),
        )];
        sync_fingerprint(
            core,
            &context.workspace_root,
            session,
            &context.package.manifest,
        )
    }

    pub(crate) fn close_window(&mut self, window_label: &str) {
        self.windows.remove(window_label);
    }

    /// Re-detects every instance of the workspace for one window. A changed
    /// workspace root resets the window's sessions and bumps its generation
    /// so responses already in flight are dropped by the frontend.
    pub fn refresh(
        &mut self,
        core: &dyn BuildCoreExecutor,
        packages: &dyn BuildPackageSource,
        persistence: &dyn BuildOptionsPersistence,
        window_label: &str,
        workspace_root: &str,
    ) -> Result<BuildView, String> {
        {
            let window = self.windows.entry(window_label.to_string()).or_default();
            let switched = window.workspace_root.is_some()
                && window.workspace_root.as_deref() != Some(workspace_root);
            if switched {
                window.generation += 1;
                window.sessions.clear();
                window.issues.clear();
            }
            window.workspace_root = Some(workspace_root.to_string());
        }

        let manifests = packages.accepted_packages();
        let mut stored = persistence.load(workspace_root)?;
        let mut changed = false;
        let request_options: BTreeMap<String, BTreeMap<String, Value>> = stored
            .systems
            .iter()
            .map(|(system, options)| (system.clone(), options.values.clone()))
            .collect();
        let response = core.execute(
            "build.detect",
            json!({
                "workspaceRoot": workspace_root,
                "plugins": manifests
                    .iter()
                    .map(|package| json!({ "manifest": package.manifest }))
                    .collect::<Vec<_>>(),
                "options": request_options,
            }),
        )?;
        let detection = outcome_value(&response, "build.detect")?;
        let detection = &detection["detection"];

        let mut issues = Vec::new();
        for rejected in detection["rejected"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
            .iter()
        {
            let mut issue = rejected.clone();
            // Core reports manifest rejections by request index; map back to
            // the plugin ID so the UI can name the package.
            if let Some(package) = rejected["index"]
                .as_u64()
                .and_then(|index| usize::try_from(index).ok())
                .and_then(|index| manifests.get(index))
            {
                issue["pluginID"] = json!(package.plugin_id);
            }
            issue["kind"] = json!("rejected");
            issues.push(issue);
        }
        for shadowed in detection["shadowed"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
        {
            let mut issue = shadowed.clone();
            issue["kind"] = json!("shadowed");
            issues.push(issue);
        }

        let mut sessions = BTreeMap::new();
        for instance in detection["instances"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
        {
            let plugin_id = instance["pluginID"].as_str().unwrap_or_default();
            let build_system_id = instance["buildSystemID"].as_str().unwrap_or_default();
            let root = instance["root"].as_str().unwrap_or_default();
            if plugin_id.is_empty() || build_system_id.is_empty() || root.is_empty() {
                continue;
            }
            let package = manifests
                .iter()
                .find(|package| package.plugin_id == plugin_id);
            let system = stored
                .systems
                .entry(build_system_id.to_string())
                .or_default();
            // Resolve against one snapshot of the shared values so a later
            // instance never sees an earlier instance's dropped adjustment.
            let mut session = resolve_session(
                core,
                instance,
                package,
                &system.values.clone(),
                system.empty_markers.get(root).cloned().unwrap_or_default(),
            )?;
            // Detection discovers roots and model-dependent options. Bracket
            // the authoritative model read with fingerprints: taking only a
            // digest after detection could bless bytes changed after the
            // model was read as its baseline and miss the first watcher event.
            let before = sync_fingerprint(core, workspace_root, &session, &session.manifest)?;
            if matches!(
                instance["modelSource"].as_str(),
                Some("static" | "hostIntegration")
            ) {
                let response = core.execute(
                    "build.decodeModel",
                    json!({
                        "manifest": session.manifest,
                        "buildSystemID": build_system_id,
                        "request": {
                            "workspaceRoot": workspace_root,
                            "root": root,
                            "options": session.effective_options,
                        },
                    }),
                )?;
                let mut loaded = instance.clone();
                loaded
                    .as_object_mut()
                    .expect("detected instance")
                    .remove("model");
                loaded
                    .as_object_mut()
                    .expect("detected instance")
                    .remove("modelError");
                if response["status"] == "ok" {
                    let outcome = outcome_value(&response, "build.decodeModel")?;
                    loaded["model"] = outcome["model"].clone();
                } else {
                    loaded["modelError"] = response["error"].clone();
                }
                session = resolve_session(
                    core,
                    &loaded,
                    package,
                    &system.values,
                    system.empty_markers.get(root).cloned().unwrap_or_default(),
                )?;
            }
            let after = sync_fingerprint(core, workspace_root, &session, &session.manifest)?;
            session.stale = before != after;
            session.sync_digest = Some(after);
            sessions.insert(
                (
                    plugin_id.to_string(),
                    build_system_id.to_string(),
                    root.to_string(),
                ),
                session,
            );
        }

        // A stored value only changes when no instance accepts it anymore;
        // per-instance drops keep sibling-only selections in the shared
        // store, and each instance filters them through its own model.
        for (system_id, instances) in sessions_by_system(&sessions) {
            let Some(system) = stored.systems.get_mut(system_id) else {
                continue;
            };
            let descriptions: Vec<Value> = instances
                .iter()
                .map(|session| session.options_description.clone())
                .collect();
            for (option_id, value) in fully_dropped_adjustments_from(&descriptions) {
                system.values.insert(option_id.to_string(), value);
                changed = true;
            }
        }

        if changed {
            persistence.save(workspace_root, &stored)?;
        }
        let window = self.windows.entry(window_label.to_string()).or_default();
        // Even a same-workspace refresh replaces the model/options snapshot.
        // Preserve the first-generation contract, invalidate subsequent loads.
        if !window.sessions.is_empty() {
            window.generation += 1;
        }
        window.sessions = sessions;
        window.issues = issues;
        Ok(self.view(window_label))
    }

    /// Applies one user option edit. The candidate storage is validated
    /// through Core before anything is persisted; a Core rejection, a save
    /// failure, or a failed re-detection leaves the previous storage and
    /// model untouched. `value: None` resets the option: the stored value
    /// and every instance's empty marker for it are removed so the declared
    /// default applies again.
    #[allow(clippy::too_many_arguments)]
    pub fn set_option(
        &mut self,
        core: &dyn BuildCoreExecutor,
        packages: &dyn BuildPackageSource,
        persistence: &dyn BuildOptionsPersistence,
        window_label: &str,
        workspace_root: &str,
        plugin_id: &str,
        build_system_id: &str,
        root: &str,
        option_id: &str,
        value: Option<Value>,
    ) -> Result<BuildView, String> {
        let fresh = packages
            .package(plugin_id)
            .ok_or_else(|| format!("{plugin_id} is no longer an enabled plugin"))?;
        let kind = {
            let window = self
                .windows
                .get(window_label)
                .ok_or_else(|| format!("window {window_label} has no build state"))?;
            if window.workspace_root.as_deref() != Some(workspace_root) {
                return Err(format!(
                    "build state for window {window_label} moved to another workspace"
                ));
            }
            let session = window
                .sessions
                .get(&(
                    plugin_id.to_string(),
                    build_system_id.to_string(),
                    root.to_string(),
                ))
                .ok_or_else(|| format!("no build instance {build_system_id} at {root}"))?;
            if session.version != fresh.version {
                return Err(format!(
                    "{plugin_id} changed since the build window loaded it; reload"
                ));
            }
            option_kind(&session.options_description, option_id)
                .ok_or_else(|| format!("option {option_id} is not declared"))?
        };

        let previous = persistence.load(workspace_root)?;
        let mut candidate = previous.clone();
        {
            let system = candidate
                .systems
                .entry(build_system_id.to_string())
                .or_default();
            match value {
                None => {
                    // Reset: the shared override and every instance's
                    // explicit empty marker go away, so the declared default
                    // applies again.
                    system.values.remove(option_id);
                    for markers in system.empty_markers.values_mut() {
                        markers.remove(option_id);
                    }
                }
                Some(value) if kind == "multiSelect" => {
                    let selection = value
                        .as_array()
                        .ok_or_else(|| format!("option {option_id} expects an array"))?;
                    let own: BTreeSet<String> = selection.iter().filter_map(as_string).collect();
                    // Sibling selections survive: the shared array is the
                    // union of what every instance still accepts, and this
                    // instance's view is derived from it plus its marker.
                    let siblings: BTreeSet<String> = self
                        .windows
                        .get(window_label)
                        .into_iter()
                        .flat_map(|window| window.sessions.values())
                        .filter(|other| {
                            other.build_system_id == build_system_id && other.root != root
                        })
                        .filter_map(|other| other.effective_options.get(option_id).cloned())
                        .filter_map(|value| string_list(&value))
                        .flatten()
                        .collect();
                    let markers = system.empty_markers.entry(root.to_string()).or_default();
                    if own.is_empty() {
                        markers.insert(option_id.to_string());
                    } else {
                        markers.remove(option_id);
                    }
                    let merged: Vec<String> = siblings.union(&own).cloned().collect();
                    if merged.is_empty() {
                        // Nothing selected anywhere: drop the shared entry so
                        // siblings fall back to defaults while this
                        // instance's marker keeps its explicit empty value.
                        system.values.remove(option_id);
                    } else {
                        system.values.insert(option_id.to_string(), json!(merged));
                    }
                }
                Some(value) => {
                    // Non-array kinds keep the explicit value verbatim; an
                    // empty text value stays an explicit empty choice, not
                    // "unset".
                    system.values.insert(option_id.to_string(), value);
                    system
                        .empty_markers
                        .entry(root.to_string())
                        .or_default()
                        .remove(option_id);
                }
            }
        }

        // Core validation before any disk write: every instance of the
        // system must resolve the candidate, and the edited option must
        // survive for the edited instance. Values Core drops (wrong type,
        // unknown choice) are a rejected edit, not a silent rewrite.
        let mut validated = Vec::new();
        for session in self
            .windows
            .get(window_label)
            .into_iter()
            .flat_map(|window| window.sessions.values())
            .filter(|session| session.build_system_id == build_system_id)
        {
            let marked = marked_values(&candidate, build_system_id, session);
            let description = resolve_options(
                core,
                &fresh.manifest,
                build_system_id,
                &marked,
                &session.model_values,
            )?;
            if session.root == root
                && description["dropped"]
                    .as_array()
                    .map(|dropped| dropped.contains(&json!(option_id)))
                    .unwrap_or(false)
            {
                return Err(format!(
                    "option {option_id} was rejected by Core for instance {root}"
                ));
            }
            validated.push(description);
        }
        let system = candidate
            .systems
            .get_mut(build_system_id)
            .expect("candidate system exists after the edit");
        for (option_id, value) in fully_dropped_adjustments_from(&validated) {
            system.values.insert(option_id, value);
        }

        // First and only disk write, then re-detect; a failed refresh rolls
        // the storage back so the model and the file stay consistent.
        persistence.save(workspace_root, &candidate)?;
        self.refresh(core, packages, persistence, window_label, workspace_root)
            .map_err(|error| {
                if persistence.save(workspace_root, &previous).is_err() {
                    return format!("{error}; the previous build options could not be restored");
                }
                error
            })
    }

    /// Recomputes one instance's sync fingerprint and flags the model stale
    /// when it changed. The package is re-verified first, and a replaced
    /// package version refuses to answer from the old session.
    pub fn sync_check(
        &mut self,
        core: &dyn BuildCoreExecutor,
        packages: &dyn BuildPackageSource,
        window_label: &str,
        workspace_root: &str,
        plugin_id: &str,
        build_system_id: &str,
        root: &str,
    ) -> Result<BuildView, String> {
        let key = (
            plugin_id.to_string(),
            build_system_id.to_string(),
            root.to_string(),
        );
        let session = {
            let window = self
                .windows
                .get(window_label)
                .ok_or_else(|| format!("window {window_label} has no build state"))?;
            if window.workspace_root.as_deref() != Some(workspace_root) {
                return Err(format!(
                    "build state for window {window_label} moved to another workspace"
                ));
            }
            window
                .sessions
                .get(&key)
                .ok_or_else(|| {
                    format!(
                        "no build instance {build_system_id} at {root} in window {window_label}"
                    )
                })?
                .clone()
        };
        let fresh = packages
            .package(plugin_id)
            .ok_or_else(|| format!("{plugin_id} is no longer an enabled plugin"))?;
        if fresh.version != session.version {
            return Err(format!(
                "{plugin_id} changed since the build window loaded it; reload"
            ));
        }

        // Use the current verified manifest, including same-version reinstalls.
        let digest = sync_fingerprint(core, workspace_root, &session, &fresh.manifest)?;

        let window = self
            .windows
            .get_mut(window_label)
            .ok_or_else(|| format!("window {window_label} has no build state"))?;
        let session = window
            .sessions
            .get_mut(&key)
            .ok_or_else(|| format!("no build instance {build_system_id} at {root}"))?;
        match &session.sync_digest {
            Some(previous) if *previous != digest => session.stale = true,
            _ => {}
        }
        session.sync_digest = Some(digest);
        session.manifest = fresh.manifest;
        Ok(self.view(window_label))
    }

    /// Drops every session of one plugin across all windows and bumps the
    /// affected generations: the revocation path for disable, uninstall,
    /// rollback, and same-version replacement. Late responses and stored
    /// sessions of the removed plugin can no longer revive it.
    pub fn drop_plugin(&mut self, plugin_id: &str) {
        for window in self.windows.values_mut() {
            let before = window.sessions.len();
            window
                .sessions
                .retain(|(owner, _, _), _| owner != plugin_id);
            if window.sessions.len() != before {
                window.generation += 1;
            }
            window
                .issues
                .retain(|issue| issue["pluginID"].as_str() != Some(plugin_id));
        }
    }

    /// Clears one window's sessions when its workspace closed, so reopening
    /// the same path cannot silently reuse the pre-close sessions.
    pub fn close_workspace(&mut self, window_label: &str, workspace_root: &str) {
        let Some(window) = self.windows.get_mut(window_label) else {
            return;
        };
        if window.workspace_root.as_deref() == Some(workspace_root) && !window.sessions.is_empty() {
            window.sessions.clear();
            window.issues.clear();
            window.generation += 1;
        }
    }

    /// Snapshot of one window's build state.
    pub fn view(&self, window_label: &str) -> BuildView {
        let empty = WindowState::default();
        let window = self.windows.get(window_label).unwrap_or(&empty);
        let instances = window
            .sessions
            .values()
            .map(|session| {
                let mut value = session.instance.clone();
                value["stale"] = json!(session.stale);
                value["syncDigest"] = session
                    .sync_digest
                    .as_ref()
                    .map(|digest| json!(digest))
                    .unwrap_or(Value::Null);
                value["options"] = session.options_description["options"].clone();
                value["optionFingerprint"] = session.options_description["fingerprint"].clone();
                value
            })
            .collect();
        BuildView {
            generation: window.generation,
            workspace_root: window.workspace_root.clone().unwrap_or_default(),
            instances,
            issues: window.issues.clone(),
        }
    }
}

/// Reads the Core-owned file and option fingerprint for this exact model.
fn sync_fingerprint(
    core: &dyn BuildCoreExecutor,
    workspace_root: &str,
    session: &BuildSession,
    manifest: &Value,
) -> Result<String, String> {
    let projects: Vec<&str> = session.instance["model"]["projects"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|project| project["path"].as_str())
        .collect();
    let response = core.execute(
        "build.syncFingerprint",
        json!({
            "manifest": manifest,
            "buildSystemID": session.build_system_id,
            "request": {
                "workspaceRoot": workspace_root,
                "root": session.root,
                "projects": projects,
                "options": session.effective_options,
            },
        }),
    )?;
    let outcome = outcome_value(&response, "build.syncFingerprint")?;
    outcome["sync"]["fingerprint"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "build.syncFingerprint returned no fingerprint".to_string())
}

/// Builds one session: re-resolves options per instance so per-instance
/// markers, model choices, and dropped values are applied through Core.
fn resolve_session(
    core: &dyn BuildCoreExecutor,
    instance: &Value,
    package: Option<&BuildPackageInput>,
    shared_values: &BTreeMap<String, Value>,
    markers: BTreeSet<String>,
) -> Result<BuildSession, String> {
    let package = package
        .ok_or_else(|| {
            format!(
                "build instance references unknown plugin {}",
                instance["pluginID"].as_str().unwrap_or_default()
            )
        })?
        .clone();
    let build_system_id = instance["buildSystemID"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let root = instance["root"].as_str().unwrap_or_default().to_string();
    let model_values = model_option_values(instance);

    let description = resolve_options(
        core,
        &package.manifest,
        &build_system_id,
        shared_values,
        &model_values,
    )?;
    // Markers may only override options Core still describes as
    // multi-select; a declaration change turns the marker into a no-op.
    let mut marked = shared_values.clone();
    for option in description["options"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let is_multi = option["kind"].as_str() == Some("multiSelect");
        let is_marked = option["id"].as_str().is_some_and(|id| markers.contains(id));
        if is_multi && is_marked {
            if let Some(id) = option["id"].as_str() {
                marked.insert(id.to_string(), json!([]));
            }
        }
    }
    let description = if marked != *shared_values {
        resolve_options(
            core,
            &package.manifest,
            &build_system_id,
            &marked,
            &model_values,
        )?
    } else {
        description
    };

    Ok(BuildSession {
        plugin_id: instance["pluginID"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
        build_system_id: build_system_id.clone(),
        root: root.clone(),
        version: package.version,
        manifest: package.manifest,
        content_identity: package.content_identity,
        instance: instance.clone(),
        effective_options: effective_map(&description),
        options_description: description,
        model_values,
        sync_digest: None,
        stale: false,
    })
}

/// Stored values with one session's explicit-empty markers applied, using
/// the kinds Core described for that session.
fn marked_values(
    stored: &StoredBuildOptions,
    build_system_id: &str,
    session: &BuildSession,
) -> BTreeMap<String, Value> {
    let mut values = stored
        .systems
        .get(build_system_id)
        .map(|system| system.values.clone())
        .unwrap_or_default();
    let markers = stored
        .systems
        .get(build_system_id)
        .and_then(|system| system.empty_markers.get(&session.root))
        .cloned()
        .unwrap_or_default();
    if markers.is_empty() {
        return values;
    }
    for option in session.options_description["options"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let is_multi = option["kind"].as_str() == Some("multiSelect");
        let is_marked = option["id"].as_str().is_some_and(|id| markers.contains(id));
        if is_multi && is_marked {
            if let Some(id) = option["id"].as_str() {
                values.insert(id.to_string(), json!([]));
            }
        }
    }
    values
}

fn resolve_options(
    core: &dyn BuildCoreExecutor,
    manifest: &Value,
    build_system_id: &str,
    values: &BTreeMap<String, Value>,
    model_values: &BTreeMap<String, Vec<String>>,
) -> Result<Value, String> {
    let response = core.execute(
        "build.resolveOptions",
        json!({
            "manifest": manifest,
            "buildSystemID": build_system_id,
            "request": {
                "options": values,
                "modelValues": model_values,
            },
        }),
    )?;
    let outcome = outcome_value(&response, "build.resolveOptions")?;
    Ok(outcome["options"].clone())
}

/// Effective stored values for options that every instance of the system
/// dropped: Core describes what it still accepts (or the default), and the
/// host re-stores that so the next detection sees the same answer. Options
/// at least one instance still accepts stay untouched, so sibling-only
/// selections survive in the shared store.
fn fully_dropped_adjustments_from(descriptions: &[Value]) -> Vec<(String, Value)> {
    let Some(first) = descriptions.first() else {
        return Vec::new();
    };
    let Some(dropped) = first["dropped"].as_array() else {
        return Vec::new();
    };
    dropped
        .iter()
        .filter_map(|id| id.as_str())
        .filter(|id| {
            descriptions.iter().all(|description| {
                description["dropped"]
                    .as_array()
                    .map(|list| list.contains(&json!(id)))
                    .unwrap_or(false)
            })
        })
        .filter_map(|id| {
            descriptions
                .iter()
                .find_map(|description| {
                    description["options"]
                        .as_array()?
                        .iter()
                        .find(|option| option["id"].as_str() == Some(id))
                        .map(|option| option["value"].clone())
                })
                .map(|value| (id.to_string(), value))
        })
        .collect()
}

/// Groups sessions by build-system ID, in deterministic key order.
fn sessions_by_system<'a>(
    sessions: &'a BTreeMap<(String, String, String), BuildSession>,
) -> BTreeMap<&'a str, Vec<&'a BuildSession>> {
    let mut grouped: BTreeMap<&str, Vec<&BuildSession>> = BTreeMap::new();
    for session in sessions.values() {
        grouped
            .entry(session.build_system_id.as_str())
            .or_default()
            .push(session);
    }
    grouped
}

fn effective_map(description: &Value) -> BTreeMap<String, Value> {
    description["options"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|option| {
            option["id"]
                .as_str()
                .map(|id| (id.to_string(), option["value"].clone()))
        })
        .collect()
}

fn option_kind(description: &Value, option_id: &str) -> Option<String> {
    description["options"]
        .as_array()?
        .iter()
        .find(|option| option["id"].as_str() == Some(option_id))?["kind"]
        .as_str()
        .map(str::to_string)
}

/// Model-declared choice values for `choicesFromModel` options.
fn model_option_values(instance: &Value) -> BTreeMap<String, Vec<String>> {
    instance["model"]["optionValues"]
        .as_object()
        .map(|values| {
            values
                .iter()
                .filter_map(|(id, list)| string_list(list).map(|values| (id.clone(), values)))
                .collect()
        })
        .unwrap_or_default()
}

fn string_list(value: &Value) -> Option<Vec<String>> {
    value
        .as_array()
        .map(|values| values.iter().filter_map(as_string).collect())
}

fn as_string(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

/// Unwraps the shared `{status, <key>}` envelope; rejected declarations and
/// requests surface as errors with their stable code.
fn outcome_value(response: &Value, command: &str) -> Result<Value, String> {
    match response["status"].as_str() {
        Some("ok") => Ok(response.clone()),
        Some("rejected") => {
            let code = response["error"]["code"].as_str().unwrap_or("unknown");
            let message = response["error"]["message"].as_str().unwrap_or("rejected");
            Err(format!("{command} rejected: {code}: {message}"))
        }
        _ => Err(format!("{command} returned an unexpected status")),
    }
}
