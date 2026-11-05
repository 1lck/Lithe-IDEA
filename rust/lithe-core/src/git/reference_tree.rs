//! Groups one kind of loaded Git references into the ordered tree both Git Log
//! reference panes show.
//!
//! The tree is a pure projection of short names split at `/`. Expansion,
//! indentation, row identities, and virtualization stay in the views; Core only
//! decides the grouping and the sibling order.

use crate::project::file_name_order::FileNameKey;
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Upper bound for one projection; a repository with more refs is paged by the host.
const MAX_REFERENCES: usize = 100_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reference {
    /// Short name such as `feature/login` or `origin/main`.
    name: String,
    /// A reference the user pinned (for example a marked branch); it and the
    /// groups that contain it sort before their siblings.
    #[serde(default)]
    prioritized: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    /// References of one kind (local, remote, or tag) in host order.
    references: Vec<Reference>,
}

/// One path segment. A node can both name a reference and group longer names,
/// as `feature` does next to `feature/x`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Node {
    /// Last path segment, which the row displays.
    name: String,
    /// Segments from the root joined with `/`; unique within one tree.
    path: String,
    /// Index into the request's `references`; `null` for a pure group.
    reference: Option<usize>,
    children: Vec<Node>,
    #[serde(skip)]
    prioritized: bool,
    #[serde(skip)]
    contains_prioritized: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    nodes: Vec<Node>,
}

/// Handles `git.referenceTree`.
///
/// Siblings sort by: a prioritized reference, then a group containing one,
/// then references before pure groups, then IDEA's natural name order
/// (`v2` before `v10`, case ignored until it is the only difference). Empty
/// segments are ignored; a repeated short name keeps the last reference.
pub(crate) fn command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git reference tree request",
        )
        .with_details(error.to_string())
    })?;
    if request.references.len() > MAX_REFERENCES {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many Git references for one tree",
        ));
    }
    let mut root = Builder::default();
    for (index, reference) in request.references.iter().enumerate() {
        let mut node = &mut root;
        let mut attached = false;
        for segment in reference
            .name
            .split('/')
            .filter(|segment| !segment.is_empty())
        {
            node = node.children.entry(segment.to_string()).or_default();
            attached = true;
        }
        // A name made only of separators has no segment to attach to.
        if attached {
            node.reference = Some(index);
            node.prioritized = reference.prioritized;
        }
    }
    let nodes = root.into_nodes("");
    Ok(serde_json::to_value(Response { nodes }).expect("reference tree encodes"))
}

/// Mutable trie; children are keyed by segment so building stays linear in
/// the number of segments even for thousands of top-level tags.
#[derive(Default)]
struct Builder {
    reference: Option<usize>,
    prioritized: bool,
    children: HashMap<String, Builder>,
}

impl Builder {
    fn into_nodes(self, parent: &str) -> Vec<Node> {
        let mut nodes = self
            .children
            .into_iter()
            .map(|(name, child)| {
                let path = if parent.is_empty() {
                    name.clone()
                } else {
                    format!("{parent}/{name}")
                };
                let reference = child.reference;
                let prioritized = child.prioritized;
                let children = child.into_nodes(&path);
                let contains_prioritized =
                    prioritized || children.iter().any(|node| node.contains_prioritized);
                (
                    FileNameKey::new(&name),
                    Node {
                        name,
                        path,
                        reference,
                        children,
                        prioritized,
                        contains_prioritized,
                    },
                )
            })
            .collect::<Vec<_>>();
        nodes.sort_by(|(left_key, left), (right_key, right)| {
            right
                .prioritized
                .cmp(&left.prioritized)
                .then(right.contains_prioritized.cmp(&left.contains_prioritized))
                .then(right.reference.is_some().cmp(&left.reference.is_some()))
                .then_with(|| left_key.cmp(right_key))
                // Natural order ties for names differing only in case; the raw
                // name keeps the projection deterministic.
                .then_with(|| left.name.cmp(&right.name))
        });
        nodes.into_iter().map(|(_, node)| node).collect()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    fn call(payload: Value) -> Value {
        serde_json::from_str(&crate::execute_json(
            &json!({"id":"tree", "command":"git.referenceTree", "payload":payload}).to_string(),
        ))
        .unwrap()
    }

    #[test]
    fn shared_fixture_trees_have_one_grouping_and_order() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/reference-tree-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let response = call(case["request"].clone());
            assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
            assert_eq!(response["data"]["nodes"], case["nodes"], "{}", case["name"]);
        }
    }

    #[test]
    fn rejects_unknown_fields() {
        let response = call(json!({"references":[{"name":"main","kind":"local"}]}));
        assert_eq!(response["ok"], false);
    }
}
