//! Validates current provider project/source ownership for Run generation.
//! This is a projection of upstream models, never a descriptor scanner.

use crate::protocol::{CoreError, ErrorCode, JavaSourceSetResponse};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// One current build-model project and its own Java content roots.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunProjectOwnership {
    /// Workspace-relative project directory, including `.` for the root.
    pub path: String,
    /// Upstream project label; never interpreted as a framework or selector.
    #[serde(default)]
    pub name: Option<String>,
    /// Compiler language floor published by the upstream execution model.
    #[serde(default)]
    pub minimum_java_version: Option<String>,
    /// Exact current build-model owner; no build-system semantics are interpreted.
    #[serde(default)]
    pub build: Option<RunBuildProjectReference>,
    /// Source roles published for this project by the build model.
    #[serde(default)]
    pub content_roots: Vec<RunSourceRoot>,
}

/// Opaque build-model identity used to route native language preparation.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunBuildProjectReference {
    /// Enabled package contributing this model.
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    /// Declaration within the package.
    #[serde(rename = "buildSystemID")]
    pub build_system_id: String,
    /// Workspace-relative instance directory.
    pub root: String,
    /// Provider-owned project identity, not a filesystem path.
    #[serde(rename = "projectID")]
    pub project_id: String,
}

/// A source directory and upstream-owned role; paths are workspace-relative.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunSourceRoot {
    pub path: String,
    /// `source`, `testSource`, `generatedSource` or `generatedTestSource`.
    pub kind: String,
}

fn contains(root: &str, path: &str) -> bool {
    root == "." || root == path || path.starts_with(&(root.to_string() + "/"))
}

fn portable(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && !path.contains(['\\', '\0', ':'])
        && (path == "."
            || path
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != ".."))
}

/// Rejects incomplete, duplicate or escaping host projections before generation.
pub(super) fn validate(projects: &[RunProjectOwnership]) -> Result<(), CoreError> {
    let invalid = || {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid provider project ownership for Run generation",
        )
    };
    if projects.len() > 2000
        || projects
            .iter()
            .map(|p| p.content_roots.len())
            .sum::<usize>()
            > 10000
    {
        return Err(invalid());
    }
    let mut paths = BTreeSet::new();
    for project in projects {
        if !portable(&project.path)
            || !paths.insert(&project.path)
            || project.build.as_ref().is_some_and(|build| {
                !crate::plugins::declarative::is_plugin_id(&build.plugin_id)
                    || !crate::plugins::declarative::is_identifier(&build.build_system_id)
                    || build.build_system_id.len() > 120
                    || build.project_id.is_empty()
                    || build.project_id.len() > 256
                    || build.project_id.chars().any(char::is_control)
                    || !portable(&build.root)
                    || !contains(&build.root, &project.path)
            })
        {
            return Err(invalid());
        }
        if project
            .minimum_java_version
            .as_deref()
            .is_some_and(|value| {
                value.parse::<u16>().ok().is_none_or(|feature| {
                    feature == 0 || feature > 999 || feature.to_string() != value
                })
            })
        {
            return Err(invalid());
        }
        let mut roots = BTreeSet::new();
        for root in &project.content_roots {
            if !portable(&root.path)
                || project
                    .build
                    .as_ref()
                    .is_some_and(|build| !contains(&build.root, &root.path))
                || !roots.insert((&root.path, &root.kind))
                || !matches!(
                    root.kind.as_str(),
                    "source" | "testSource" | "generatedSource" | "generatedTestSource"
                )
            {
                return Err(invalid());
            }
        }
    }
    Ok(())
}

/// Prefer exact upstream source roots, then the deepest project boundary.
pub(super) fn owner<'a>(
    projects: &'a [RunProjectOwnership],
    source: &str,
) -> Option<&'a RunProjectOwnership> {
    projects
        .iter()
        .filter_map(|project| {
            let source_depth = project
                .content_roots
                .iter()
                .filter(|root| contains(&root.path, source))
                .map(|root| root.path.len())
                .max();
            (source_depth.is_some() || contains(&project.path, source))
                .then_some((source_depth, project))
        })
        .max_by(|(left_depth, left), (right_depth, right)| {
            (left_depth, left.path.len(), &left.path).cmp(&(
                right_depth,
                right.path.len(),
                &right.path,
            ))
        })
        .map(|(_, project)| project)
}

impl RunProjectOwnership {
    /// Source set comes from the selected project's roots, not a directory name.
    pub(super) fn source_set(&self, source: &str) -> JavaSourceSetResponse {
        match self
            .content_roots
            .iter()
            .filter(|root| contains(&root.path, source))
            .max_by(|left, right| {
                (left.path.len(), &left.kind).cmp(&(right.path.len(), &right.kind))
            })
            .map(|root| root.kind.as_str())
        {
            Some("testSource" | "generatedTestSource") => JavaSourceSetResponse::Test,
            Some("source" | "generatedSource") => JavaSourceSetResponse::Main,
            _ => JavaSourceSetResponse::Other,
        }
    }
}

/// Stable identity for all facts consumed by generation, independent of list order.
pub(super) fn fingerprint(projects: &[RunProjectOwnership]) -> String {
    use sha2::{Digest, Sha256};
    let mut projects = projects.iter().collect::<Vec<_>>();
    projects.sort_by(|left, right| left.path.cmp(&right.path));
    let canonical = projects
        .into_iter()
        .map(|project| {
            let roots = project
                .content_roots
                .iter()
                .map(|root| (&root.path, &root.kind))
                .collect::<BTreeSet<_>>();
            serde_json::json!({"path":project.path,"name":project.name,"build":project.build,
            "minimumJavaVersion":project.minimum_java_version,
            "contentRoots":roots})
        })
        .collect::<Vec<_>>();
    let bytes =
        serde_json::to_vec(&canonical).expect("Provider ownership contains only JSON-safe values");
    format!("sha256:{:x}", Sha256::digest(bytes))
}
