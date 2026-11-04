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
    /// Optional Core-owned membership rules also cover paths staged after the UI snapshot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership: Option<MembershipScope>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MembershipScope {
    pub active_id: String,
    pub assignments: BTreeMap<String, BTreeMap<String, String>>,
}

impl PathScope {
    fn permits(&self, repository: &str, path: &str) -> bool {
        if let Some(membership) = &self.membership {
            let member = membership
                .assignments
                .get(repository)
                .and_then(|paths| super::super::changelists::path_member(paths, path))
                .unwrap_or("default");
            return member == membership.active_id;
        }
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
    let repository_ids: BTreeSet<&str> = plan
        .repositories
        .iter()
        .map(|repository| repository.id.as_str())
        .collect();
    for (id, paths) in &scope.paths {
        if !repository_ids.contains(id.as_str()) {
            return Err(invalid("Commit scope references an unknown repository"));
        }
        if !paths.is_empty() {
            super::super::validate_paths(&paths.iter().cloned().collect::<Vec<_>>())?;
        }
    }
    if let Some(membership) = &scope.membership {
        if membership.active_id.is_empty()
            || membership.assignments.len() > 100_000
            || scope.include != (membership.active_id != "default")
        {
            return Err(invalid("Invalid ChangeList membership scope"));
        }
        let mut count = 0usize;
        for (id, paths) in &membership.assignments {
            count = count.saturating_add(paths.len());
            if !repository_ids.contains(id.as_str())
                || count > 100_000
                || paths.values().any(String::is_empty)
                || paths
                    .keys()
                    .any(|path| !super::super::changelists::safe_path(path))
            {
                return Err(invalid("Invalid ChangeList membership scope"));
            }
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
