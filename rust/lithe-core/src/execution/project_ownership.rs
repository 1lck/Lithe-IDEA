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
    /// Upstream project label; required for a published Maven service.
    #[serde(default)]
    pub name: Option<String>,
    /// Maven backend's effective framework selection, never inferred here.
    #[serde(default)]
    pub maven_run_provider: Option<String>,
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
        if project
            .maven_run_provider
            .as_deref()
            .is_some_and(|provider| {
                !matches!(
                    provider,
                    "spring-boot.maven" | "quarkus.maven" | "micronaut.maven"
                ) || project.maven_reactor_path.is_none()
                    || project.name.as_deref().is_none_or(|name| {
                        name.is_empty() || name.len() > 256 || name.chars().any(char::is_control)
                    })
            })
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

/// Projects Maven's selected services into existing persisted Run identities.
/// Names are disambiguated within each reactor, preserving existing overrides.
pub(super) fn services(
    projects: &[RunProjectOwnership],
) -> Vec<super::configuration::RunConfiguration> {
    use super::configuration::{DebugCapability, RunConfiguration};
    use super::types::{Confidence, Execution, RunCategory};
    use serde_json::json;
    use std::collections::BTreeMap;
    let mut counts = BTreeMap::new();
    for project in projects {
        if let (Some(root), Some(name)) = (&project.maven_reactor_path, &project.name) {
            *counts.entry((root, name)).or_insert(0usize) += 1;
        }
    }
    projects
        .iter()
        .filter_map(|project| {
            let provider = project.maven_run_provider.as_ref()?;
            let root = project.maven_reactor_path.as_ref()?;
            let label = project.name.as_ref()?;
            let module = if root == &project.path {
                "."
            } else if root == "." {
                &project.path
            } else {
                project.path.strip_prefix(&(root.clone() + "/"))?
            };
            let name = if counts.get(&(root, label)) == Some(&1) {
                label.as_str()
            } else {
                module
            };
            let directory = if root == "." {
                String::new()
            } else {
                format!("{root}/")
            };
            let source = if project.path == "." {
                "pom.xml".to_string()
            } else {
                format!("{}/pom.xml", project.path)
            };
            Some(RunConfiguration {
                id: format!("{provider}:{directory}{name}"),
                name: name.to_string(),
                provider: provider.clone(),
                execution: Execution::Service,
                category: RunCategory::Project,
                command: None,
                args: Vec::new(),
                cwd: root.clone(),
                env: BTreeMap::new(),
                confidence: Confidence::Declared,
                toolchains: [
                    ("java".to_string(), "project-jdk".to_string()),
                    ("maven".to_string(), "project-maven".to_string()),
                ]
                .into_iter()
                .collect(),
                debug: Some(DebugCapability {
                    adapter: "jdwp".to_string(),
                }),
                members: Vec::new(),
                extensions: [("maven".to_string(), json!({"module": module}))]
                    .into_iter()
                    .collect(),
                disabled: false,
                source: Some(source),
            })
        })
        .collect()
}
