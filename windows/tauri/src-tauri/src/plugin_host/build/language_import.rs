//! Passive Java import from the live build registry. Core owns option and
//! Maven/Gradle semantics; this adapter only selects an exact instance and
//! brackets the conversion with model, window and accepted-package identity.

use super::super::build_registry::{
    BuildCoreExecutor, BuildModelContext, BuildPackageSource, BuildRegistry,
};
use super::*;
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildLanguageImport {
    pub workspace_root: String,
    pub generation: u64,
    pub identity: String,
    pub maven_context: Option<Value>,
    pub java_gradle: Option<Value>,
}

fn relative_path(path: &str) -> Result<(), String> {
    if path == "." {
        return Ok(());
    }
    if path.is_empty()
        || path.contains('\\')
        || path.contains(':')
        || path.starts_with('/')
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err("plugin.build.invalidSelection".into());
    }
    Ok(())
}

fn contains(root: &str, source: &str) -> bool {
    let root = root.to_ascii_lowercase();
    let source = source.to_ascii_lowercase();
    root == "."
        || source == root
        || source
            .strip_prefix(&root)
            .is_some_and(|tail| tail.starts_with('/'))
}

/// No invocation planning, runtime discovery or executable/version probing is
/// performed here. In particular a Wrapper is only a Core-owned input file.
pub(super) fn resolve(
    registry: &BuildRegistry,
    core: &dyn BuildCoreExecutor,
    packages: &dyn BuildPackageSource,
    window: &str,
    workspace: &str,
    generation: u64,
    source_path: Option<&str>,
    checkpoint: &dyn Fn() -> Result<(), String>,
) -> Result<BuildLanguageImport, String> {
    checkpoint()?;
    registry.check_read_snapshot(window, workspace, generation)?;
    if let Some(path) = source_path {
        relative_path(path)?;
    }
    let view = registry.view(window);
    if view.workspace_root != workspace || view.generation != generation {
        return Err("plugin.build.staleContext".into());
    }
    // Rejected declarations must not turn into a successful legacy fallback.
    if view.issues.iter().any(|issue| issue["kind"] == "rejected") {
        return Err("plugin.build.invalidPlan".into());
    }
    let mut candidates: BTreeMap<String, Vec<BuildModelContext>> = BTreeMap::new();
    for instance in &view.instances {
        let context = registry.model_context(
            window,
            workspace,
            instance["pluginID"]
                .as_str()
                .ok_or("plugin.build.invalidSelection")?,
            instance["buildSystemID"]
                .as_str()
                .ok_or("plugin.build.invalidSelection")?,
            instance["root"]
                .as_str()
                .ok_or("plugin.build.invalidSelection")?,
        )?;
        let system = context.package.manifest["buildSystems"]
            .as_array()
            .and_then(|systems| {
                systems
                    .iter()
                    .find(|system| system["id"] == context.build_system_id)
            })
            .ok_or("plugin.build.invalidSelection")?;
        if system["languageImport"].is_null() {
            continue;
        }
        relative_path(&context.root)?;
        if source_path.is_some_and(|path| !contains(&context.root, path)) {
            continue;
        }
        let kind = system["languageImport"]["kind"]
            .as_str()
            .ok_or("plugin.build.invalidPlan")?;
        if !matches!(kind, "maven" | "gradle") {
            return Err("plugin.build.invalidPlan".into());
        }
        candidates.entry(kind.into()).or_default().push(context);
    }
    let mut maven_context = None;
    let mut java_gradle = None;
    let mut snapshots = Vec::new();
    let mut checked_contexts = Vec::new();
    for (kind, mut candidates) in candidates {
        // Ancestor instances cannot displace the most specific containing
        // root. Equal-specificity matches are ambiguous regardless of order.
        let depth = |root: &str| {
            if root == "." {
                0
            } else {
                root.split('/').count()
            }
        };
        candidates.sort_by_key(|context| std::cmp::Reverse(depth(&context.root)));
        if candidates.len() > 1
            && (source_path.is_none() || depth(&candidates[0].root) == depth(&candidates[1].root))
        {
            return Err("plugin.build.invalidSelection".into());
        }
        let context = candidates.remove(0);
        let instance = view
            .instances
            .iter()
            .find(|instance| {
                instance["pluginID"] == context.plugin_id
                    && instance["buildSystemID"] == context.build_system_id
                    && instance["root"] == context.root
            })
            .ok_or("plugin.build.staleContext")?;
        if !instance["modelError"].is_null()
            || context.model_stale
            || (!instance["modelSource"].is_null() && context.model.is_null())
        {
            return Err("plugin.build.modelReloadRequired".into());
        }
        if packages.package(&context.plugin_id).as_ref() != Some(&context.package) {
            return Err("plugin.build.packageChanged".into());
        }
        let before = registry.model_fingerprint(core, &context)?;
        if instance["syncDigest"].as_str() != Some(before.as_str()) {
            return Err("plugin.build.modelReloadRequired".into());
        }
        let response = core.execute("build.languageImport", json!({
            "manifest": context.package.manifest, "buildSystemID": context.build_system_id,
            "request": { "workspaceRoot": workspace, "root": context.root, "options": context.options },
        }))?;
        operation::core_ok(&response)?;
        let import = &response["languageImport"];
        if import["kind"].as_str() != Some(kind.as_str()) {
            return Err("plugin.build.invalidPlan".into());
        }
        match kind.as_str() {
            "maven" if import["mavenContext"].is_object() => {
                maven_context = Some(import["mavenContext"].clone())
            }
            "gradle" if import["javaGradle"].is_object() => {
                java_gradle = Some(import["javaGradle"].clone())
            }
            "maven" | "gradle" => return Err("plugin.build.invalidPlan".into()),
            _ => unreachable!(),
        }
        checkpoint()?;
        if !registry.context_is_current(&context)
            || registry.model_fingerprint(core, &context)? != before
        {
            return Err("plugin.build.staleContext".into());
        }
        if packages.package(&context.plugin_id).as_ref() != Some(&context.package) {
            return Err("plugin.build.packageChanged".into());
        }
        snapshots.push(
            json!({ "plugin": context.plugin_id, "system": context.build_system_id, "revision": context.revision,
            "root": context.root, "package": context.package.content_identity,
            "manifest": context.package.manifest, "options": context.options,
            "model": context.model, "fingerprint": before, "import": import }),
        );
        checked_contexts.push((context, before));
    }
    checkpoint()?;
    registry.check_read_snapshot(window, workspace, generation)?;
    // Both import kinds belong to one result. A later Core call must not
    // leave an earlier instance unchecked at the publication boundary.
    for (context, before) in &checked_contexts {
        if !registry.context_is_current(context)
            || registry.model_fingerprint(core, context)? != *before
        {
            return Err("plugin.build.staleContext".into());
        }
        if packages.package(&context.plugin_id).as_ref() != Some(&context.package) {
            return Err("plugin.build.packageChanged".into());
        }
    }
    let identity = format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&json!({
                "window": window, "workspace": workspace, "generation": generation,
                "sourcePath": source_path, "snapshots": snapshots,
            }))
            .map_err(|error| error.to_string())?
        )
    );
    Ok(BuildLanguageImport {
        workspace_root: workspace.into(),
        generation,
        identity,
        maven_context,
        java_gradle,
    })
}

pub(super) async fn prepare(
    app: AppHandle,
    label: String,
    workspace_root: String,
    generation: u64,
    source_path: Option<String>,
    expected_identity: Option<String>,
) -> Result<BuildLanguageImport, String> {
    // Reject an obsolete queued request before entering the blocking pool.
    live_build_window(&app, &label)?;
    app.state::<BuildHostState>()
        .registry
        .lock()
        .map_err(|_| "build registry mutex poisoned")?
        .check_read_snapshot(&label, &workspace_root, generation)?;
    let checkpoint_app = app.clone();
    run_build_task(app, move |registry, packages, _persistence| {
        let result = resolve(
            registry,
            &HostCoreExecutor,
            packages,
            &label,
            &workspace_root,
            generation,
            source_path.as_deref(),
            &|| live_build_window(&checkpoint_app, &label),
        )?;
        if expected_identity.is_some_and(|expected| expected != result.identity) {
            return Err("plugin.build.staleContext".into());
        }
        Ok(result)
    })
    .await
}
