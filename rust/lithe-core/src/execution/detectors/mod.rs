//! Language-agnostic discovery of runnable services.
//!
//! The engine walks a project once, groups the manifest files it finds by
//! directory, and hands each directory to every detector. Detectors never walk
//! the tree themselves: a shared walk is the only way the cost stays bounded as
//! ecosystems are added.
//!
//! An ecosystem whose layout is *declared* rather than discovered reads its own
//! manifest graph instead, from the root directory only -- see `maven`. That is
//! not a shortcut around the shared walk: a declared graph names directories the
//! walk prunes, and omits ones it would visit.

mod cargo;
mod compose;
mod go;
mod gradle;
mod make;
mod maven;
mod npm;
mod procfile;
mod python;
mod scan;
mod shell;

use super::types::{Confidence, Execution};
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
    pub confidence: Confidence,
    /// The program to spawn, or `None` when `toolchains` names the executable.
    pub command: Option<String>,
    pub args: Vec<String>,
    /// Project-relative directory the command runs in.
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    /// Toolchain bindings by role, e.g. `{java: project-jdk}`. Empty for a
    /// detection that spawns `command` directly.
    pub toolchains: BTreeMap<String, String>,
    /// The debug adapter this service supports, when launching it under a
    /// debugger is something the launch layer already knows how to assemble.
    pub debug: Option<String>,
    pub extensions: BTreeMap<String, serde_json::Value>,
    /// Which manifest produced this, for the "why is this here" affordance.
    pub source: String,
}

impl Detected {
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
            confidence: Confidence::Declared,
            command: Some(command.to_string()),
            args: args.into_iter().map(str::to_string).collect(),
            cwd: ctx.relative.clone(),
            env: BTreeMap::new(),
            toolchains: BTreeMap::new(),
            debug: None,
            extensions: BTreeMap::new(),
            source: ctx.join_relative(source),
        }
    }

    pub fn with_confidence(mut self, confidence: Confidence) -> Self {
        self.confidence = confidence;
        self
    }

    /// Hands the executable to a toolchain instead of spawning `command`.
    ///
    /// Most detections name a program that is on `PATH`, which is what keeps a
    /// new ecosystem from needing changes in the launch layer. An ecosystem
    /// whose launch is assembled from a toolchain rather than a command line --
    /// Maven's `spring-boot:run`, addressed through the project JDK and Maven
    /// binding -- takes this instead, and the launch layer must already know
    /// that provider.
    pub fn with_toolchains(mut self, toolchains: &[(&str, &str)]) -> Self {
        self.command = None;
        self.toolchains = toolchains
            .iter()
            .map(|(role, name)| (role.to_string(), name.to_string()))
            .collect();
        self
    }

    pub fn with_debug(mut self, adapter: &str) -> Self {
        self.debug = Some(adapter.to_string());
        self
    }

    /// Overrides the directory the command runs in. Defaults to the directory
    /// the detection was made in, which is wrong when a build must be invoked
    /// from its root -- a Gradle subproject, or a Maven module addressed by
    /// `-pl` from the reactor root.
    pub fn with_cwd(mut self, cwd: &str) -> Self {
        self.cwd = cwd.to_string();
        self
    }

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
    gradle::detect,
    maven::detect,
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
