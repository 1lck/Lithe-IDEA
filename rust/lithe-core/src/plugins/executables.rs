//! Shared executable candidate declarations and deterministic ordering.
//! Native discovery, trust and probing remain injected host responsibilities.

use super::declarative::{invalid, is_identifier, Validation};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// A source plus optional ordering constraints within one plugin-owned set.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExecutableCandidate {
    #[serde(flatten)]
    pub(crate) source: ExecutableSource,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) id: Option<String>,
    /// Higher priorities run first; absent means 0. Ties use array order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) priority: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) insert_before: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) insert_after: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub(crate) platforms: Vec<Platform>,
}

impl<'de> Deserialize<'de> for ExecutableCandidate {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let mut value = Value::deserialize(deserializer)?;
        let map = value
            .as_object_mut()
            .ok_or_else(|| serde::de::Error::custom("An executable is an object."))?;
        // Decode metadata separately so source-specific unknown fields still
        // fail closed instead of disappearing through serde flatten.
        let id = map
            .remove("id")
            .map(serde_json::from_value)
            .transpose()
            .map_err(serde::de::Error::custom)?;
        let priority = map
            .remove("priority")
            .map(serde_json::from_value)
            .transpose()
            .map_err(serde::de::Error::custom)?;
        let insert_before = map
            .remove("insertBefore")
            .map(serde_json::from_value)
            .transpose()
            .map_err(serde::de::Error::custom)?;
        let insert_after = map
            .remove("insertAfter")
            .map(serde_json::from_value)
            .transpose()
            .map_err(serde::de::Error::custom)?;
        let platforms = map
            .remove("platforms")
            .map(serde_json::from_value)
            .transpose()
            .map_err(serde::de::Error::custom)?
            .unwrap_or_default();
        let source = serde_json::from_value(value).map_err(serde::de::Error::custom)?;
        Ok(Self {
            source,
            id,
            priority,
            insert_before,
            insert_after,
            platforms,
        })
    }
}

/// Platform-neutral source. Adapters supply each native discovery capability.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum ExecutableSource {
    ProjectFile {
        path: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        requires: Vec<String>,
    },
    Environment {
        variable: String,
        path: String,
    },
    Command {
        command: String,
    },
    Runtime {
        runtime: String,
    },
    /// Global file preference; empty skips, any invalid nonempty value fails.
    Setting {
        #[serde(rename = "settingID")]
        setting_id: String,
    },
}

/// Operating system filter, applied after validating the complete candidate set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Platform {
    Macos,
    Linux,
    Windows,
}

impl ExecutableCandidate {
    pub(crate) fn uses_resolution(&self) -> bool {
        matches!(self.source, ExecutableSource::Setting { .. })
            || self.id.is_some()
            || self.priority.is_some()
            || self.insert_before.is_some()
            || self.insert_after.is_some()
    }
}

/// Stable topological sort: explicit edges win, otherwise higher priority then
/// original array index wins. No cross-set anchors or arbitrary host code.
pub(crate) fn ordered_indices(
    candidates: &[ExecutableCandidate],
    field: &str,
) -> Validation<Vec<usize>> {
    let mut ids = BTreeMap::new();
    for (index, candidate) in candidates.iter().enumerate() {
        if let Some(id) = &candidate.id {
            if !is_identifier(id) || ids.insert(id.as_str(), index).is_some() {
                return Err(invalid(
                    field,
                    "Candidate IDs must be valid and unique within their set.",
                ));
            }
        }
        if (candidate.priority.is_some()
            && (candidate.insert_before.is_some() || candidate.insert_after.is_some()))
            || (candidate.insert_before.is_some() && candidate.insert_after.is_some())
        {
            return Err(invalid(
                field,
                "Use priority or one relative insertion constraint, not both.",
            ));
        }
    }
    let mut edges = vec![BTreeSet::new(); candidates.len()];
    let mut incoming = vec![0usize; candidates.len()];
    for (index, candidate) in candidates.iter().enumerate() {
        for (anchor, before) in [
            (candidate.insert_before.as_deref(), true),
            (candidate.insert_after.as_deref(), false),
        ] {
            let Some(anchor) = anchor else { continue };
            let other = *ids.get(anchor).ok_or_else(|| {
                invalid(
                    field,
                    "An insertion anchor must name a candidate in this set.",
                )
            })?;
            let (from, to) = if before {
                (index, other)
            } else {
                (other, index)
            };
            if edges[from].insert(to) {
                incoming[to] += 1;
            }
        }
    }
    let mut result = Vec::with_capacity(candidates.len());
    let mut remaining: BTreeSet<_> = (0..candidates.len()).collect();
    while !remaining.is_empty() {
        let next = remaining
            .iter()
            .copied()
            .filter(|&index| incoming[index] == 0)
            .min_by_key(|&index| {
                (
                    std::cmp::Reverse(candidates[index].priority.unwrap_or(0)),
                    index,
                )
            })
            .ok_or_else(|| {
                invalid(
                    field,
                    "Candidate insertion constraints contain a cycle or contradiction.",
                )
            })?;
        remaining.remove(&next);
        result.push(next);
        for &to in &edges[next] {
            incoming[to] -= 1;
        }
    }
    Ok(result)
}
