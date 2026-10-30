//! Validates current provider project/source ownership for Run generation.
//! This is a projection of upstream models, never a descriptor scanner.

use crate::protocol::{CoreError, ErrorCode, JavaSourceSetResponse};
use serde::Deserialize;
use std::collections::BTreeSet;

/// One current build-model project and its own Java content roots.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunProjectOwnership {
    /// Workspace-relative project directory, including `.` for the root.
    pub path: String,
    /// Existing Maven import ownership; absent for other project kinds.
    #[serde(default)]
    pub maven_reactor_path: Option<String>,
    /// Source roles published for this project by the build model.
    #[serde(default)]
    pub content_roots: Vec<RunSourceRoot>,
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
            || project
                .maven_reactor_path
                .as_deref()
                .is_some_and(|root| !portable(root) || !contains(root, &project.path))
        {
            return Err(invalid());
        }
        let mut roots = BTreeSet::new();
        for root in &project.content_roots {
            if !portable(&root.path)
                || project
                    .maven_reactor_path
                    .as_deref()
                    .is_some_and(|reactor| !contains(reactor, &root.path))
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
