//! Read-only path guards for local changelists; Git remains the index authority.
use super::{invalid, Plan};
use crate::git::GitCommitState;
use crate::protocol::CoreError;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Membership snapshot captured when the user starts a workspace commit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PathScope {
    /// True permits only listed paths; false permits every path except those listed.
    pub include: bool,
    /// Repository identities map to literal repository-relative paths, never pathspecs.
    pub paths: BTreeMap<String, BTreeSet<String>>,
}

impl PathScope {
    fn permits(&self, repository: &str, path: &str) -> bool {
        self.paths
            .get(repository)
            .is_some_and(|paths| paths.contains(path))
            == self.include
    }
}

pub(super) fn validate(
    plan: &Plan,
    states: &BTreeMap<String, GitCommitState>,
    committed: &BTreeSet<String>,
) -> Result<(), CoreError> {
    let Some(scope) = &plan.path_scope else {
        return Ok(());
    };
    for (id, paths) in &scope.paths {
        if !plan
            .repositories
            .iter()
            .any(|repository| &repository.id == id)
        {
            return Err(invalid("Commit scope references an unknown repository"));
        }
        if !paths.is_empty() {
            super::super::validate_paths(&paths.iter().cloned().collect::<Vec<_>>())?;
        }
    }
    // Parent references are writes too, even when the parent index was clean.
    let outside = plan
        .ordered_ids
        .iter()
        .filter(|id| !committed.contains(*id))
        .any(|id| {
            states.get(id).is_some_and(|state| {
                state
                    .staged_paths
                    .iter()
                    .any(|path| !scope.permits(id, path))
            })
        })
        || plan.propagated_relations.iter().any(|relation| {
            !committed.contains(&relation.parent)
                && !scope.permits(&relation.parent, &relation.path)
        });
    if outside {
        return Err(invalid("Changes outside the active changelist are staged or require a parent reference update. Unstage those changes or disable parent reference updates before committing."));
    }
    Ok(())
}
