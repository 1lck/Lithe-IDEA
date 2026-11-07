//! Language-agnostic discovery of runnable services.
//!
//! The engine walks a project once, groups the manifest files it finds by
//! directory, and hands each directory to every detector. Detectors never walk
//! the tree themselves: a shared walk is the only way the cost stays bounded as
//! ecosystems are added.
//!
//! Ecosystems whose layout is *declared* by a build model rather than
//! discovered from manifests belong to a build provider plugin, which reports
//! its runs through `build.provider` instead of a detector here.

mod cargo;
mod compose;
mod go;
mod make;
mod npm;
mod procfile;
mod python;
mod scan;
mod shell;

use super::types::{Confidence, Execution, RunCategory};
use crate::protocol::CoreError;
use std::collections::BTreeMap;
use std::path::Path;

pub use scan::{scan, DirectoryContext};

/// One runnable thing a detector found.
///
/// Deliberately not `RunConfiguration`: detectors describe what they saw without
/// deciding ids or serialization shape. The caller owns that translation so
/// every ecosystem gets identical treatment.
#[derive(Debug, Clone)]
pub struct Detected {
    /// Namespaced provider, e.g. `npm.script`. Must pass `valid_provider`.
    pub provider: String,
    /// Human label, unique within its directory for a given provider.
    pub name: String,
    pub execution: Execution,
    /// Whether this runs the project or the infrastructure it depends on.
    pub category: RunCategory,
    pub confidence: Confidence,
    /// The program to spawn. Detectors always name one; `None` is reserved for
    /// launches whose executable comes from a toolchain binding.
    pub command: Option<String>,
    pub args: Vec<String>,
    /// Project-relative directory the command runs in.
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    /// Toolchain bindings by role, e.g. `{runtime: project-node}`. A
    /// process-based detection retains `command` while declaring a runtime it
    /// consumes.
    pub toolchains: BTreeMap<String, String>,
    pub extensions: BTreeMap<String, serde_json::Value>,
    /// Which manifest produced this, for the "why is this here" affordance.
    pub source: String,
}

impl Detected {
    /// Creates a short-lived or interactive application detection.
    pub fn application(
        provider: &str,
        name: &str,
        command: &str,
        args: Vec<&str>,
        ctx: &DirectoryContext,
        source: &str,
    ) -> Self {
        Self::new(
            provider,
            name,
            command,
            args,
            ctx,
            source,
            Execution::Application,
        )
    }

    /// Creates a long-running service detection.
    pub fn service(
        provider: &str,
        name: &str,
        command: &str,
        args: Vec<&str>,
        ctx: &DirectoryContext,
        source: &str,
    ) -> Self {
        Self::new(
            provider,
            name,
            command,
            args,
            ctx,
            source,
            Execution::Service,
        )
    }

    /// Creates a command expected to run to completion.
    pub fn task(
        provider: &str,
        name: &str,
        command: &str,
        args: Vec<&str>,
        ctx: &DirectoryContext,
        source: &str,
    ) -> Self {
        Self::new(provider, name, command, args, ctx, source, Execution::Task)
    }

    fn new(
        provider: &str,
        name: &str,
        command: &str,
        args: Vec<&str>,
        ctx: &DirectoryContext,
        source: &str,
        execution: Execution,
    ) -> Self {
        Self {
            provider: provider.to_string(),
            name: name.to_string(),
            execution,
            category: RunCategory::Project,
            confidence: Confidence::Declared,
            command: Some(command.to_string()),
            args: args.into_iter().map(str::to_string).collect(),
            cwd: ctx.relative.clone(),
            env: BTreeMap::new(),
            toolchains: BTreeMap::new(),
            extensions: BTreeMap::new(),
            source: ctx.join_relative(source),
        }
    }

    /// Marks a detection as external infrastructure rather than project code.
    pub fn as_infrastructure(mut self) -> Self {
        self.category = RunCategory::Infrastructure;
        self
    }

    /// Replaces the default declared confidence with the detector's evidence level.
    pub fn with_confidence(mut self, confidence: Confidence) -> Self {
        self.confidence = confidence;
        self
    }

    /// Declares a runtime requirement while keeping the detector-owned command.
    ///
    /// Process-based detectors still own their command, but Core needs the
    /// binding to scope compatibility diagnostics to the consumers.
    pub fn requiring_toolchain(mut self, role: &str, name: &str) -> Self {
        self.toolchains.insert(role.to_string(), name.to_string());
        self
    }

    /// Attaches provider-specific metadata without expanding the shared schema.
    pub fn with_extension(mut self, namespace: &str, value: serde_json::Value) -> Self {
        self.extensions.insert(namespace.to_string(), value);
        self
    }

    /// Stable across runs and unique per (provider, directory, name). Ids are the
    /// join key for the team and local override layers, so any change to this
    /// format silently detaches every override a user has written.
    pub fn id(&self) -> String {
        let directory = if self.cwd == "." {
            String::new()
        } else {
            format!("{}/", self.cwd)
        };
        format!("{}:{}{}", self.provider, directory, self.name)
    }

    /// Two detections describe the same service when they run in the same place
    /// under the same name. Provider is excluded on purpose: a Procfile `web`
    /// and a compose service `web` in one directory are one service seen twice.
    fn identity(&self) -> (String, String) {
        (self.cwd.clone(), self.name.to_lowercase())
    }
}

type DetectFn = fn(&DirectoryContext) -> Vec<Detected>;

/// Every built-in detector. Adding an ecosystem means one line here and one file
/// next to it -- no changes to the engine, the merge, or the contract.
const DETECTORS: &[DetectFn] = &[
    npm::detect,
    compose::detect,
    procfile::detect,
    python::detect,
    cargo::detect,
    go::detect,
    make::detect,
    shell::detect_just,
];

/// Runs every detector over the project and returns deduplicated results
/// ordered shallowest-directory-first, so the top-level service of a monorepo
/// reads before its packages.
pub fn detect_all(root: &Path) -> Result<Vec<Detected>, CoreError> {
    let directories = scan(root)?;
    let mut found = Vec::new();
    for context in &directories {
        for detector in DETECTORS {
            found.extend(detector(context));
        }
    }
    Ok(dedupe(found))
}

/// Keeps the highest-confidence detection per identity.
///
/// Ties break on provider name rather than scan order: two equally confident
/// detectors must not produce a different winner depending on which ran first,
/// or `generated.json` churns between otherwise identical runs.
fn dedupe(found: Vec<Detected>) -> Vec<Detected> {
    let mut best: BTreeMap<(String, String), Detected> = BTreeMap::new();
    for candidate in found {
        let identity = candidate.identity();
        let replace = match best.get(&identity) {
            Some(existing) => {
                (candidate.confidence, candidate.provider.as_str())
                    > (existing.confidence, existing.provider.as_str())
            }
            None => true,
        };
        if replace {
            best.insert(identity, candidate);
        }
    }
    let mut results = best.into_values().collect::<Vec<_>>();
    results.sort_by_key(|item| {
        (
            item.cwd.matches('/').count(),
            item.cwd.clone(),
            item.name.clone(),
        )
    });
    results
}
