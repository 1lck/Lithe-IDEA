//! The `vcs.*` commands: JSON in, outcome envelope out.
//!
//! Like `build.detect`, `vcs.detectRoots` takes the manifests of the enabled
//! plugins and validates each again, so a host never trusts its own cache of
//! a manifest. Malformed payloads fail the call; rejected manifests and
//! replies come back as `{status: "rejected", error}`.

use super::manifest::{built_in_git_markers, VcsProviderDeclaration, BUILT_IN_GIT};
use super::model::{is_root_relative, Capabilities};
use super::requests::{self, Operation};
use super::roots::{self, Mapping, MarkerSet};
use crate::plugins::declarative::{
    decode_payload, is_official_namespace, outcome, validate_manifest_value,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DetectRootsRequest {
    /// Absolute workspace root.
    workspace_root: String,
    /// Manifests of the enabled plugins, in any order.
    #[serde(default)]
    plugins: Vec<DetectPlugin>,
    /// The user's choices for ambiguous directories.
    #[serde(default)]
    mappings: Vec<MappingInput>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DetectPlugin {
    manifest: Value,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct MappingInput {
    id: String,
    vcs: String,
}

/// The declaration that answers for one VCS ID.
struct Owner<'a> {
    plugin_id: &'a str,
    declaration: &'a VcsProviderDeclaration,
}

/// Official plugins win a VCS ID, then the lower plugin ID, so the result
/// does not depend on the order a host lists plugins in.
fn precedes(candidate: &Owner<'_>, current: &Owner<'_>) -> bool {
    (
        !is_official_namespace(candidate.plugin_id),
        candidate.plugin_id,
    ) < (!is_official_namespace(current.plugin_id), current.plugin_id)
}

/// `vcs.detectRoots`: registered providers, the roots of every VCS with a
/// provider (and of the built-in Git), ambiguous directories, and which
/// mappings applied.
pub(crate) fn vcs_detect_roots_command(payload: Value) -> Result<Value, CoreError> {
    let request: DetectRootsRequest = decode_payload(payload, "vcs.detectRoots")?;
    let workspace = PathBuf::from(&request.workspace_root);
    if !workspace.is_absolute() || request.workspace_root.contains('\0') {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The workspace root must be an absolute path.",
        ));
    }
    // Ancestors are read from the resolved location: a workspace opened
    // through a link sits in the link target's working copy.
    let workspace = workspace.canonicalize().unwrap_or(workspace);

    let mut rejected = Vec::new();
    let mut manifests = Vec::new();
    for (index, plugin) in request.plugins.into_iter().enumerate() {
        match validate_manifest_value(plugin.manifest) {
            Ok(manifest) => manifests.push(manifest),
            Err(error) => rejected.push(json!({ "index": index, "error": error })),
        }
    }
    let mut owners: BTreeMap<&str, Owner<'_>> = BTreeMap::new();
    let mut conflicts = Vec::new();
    for manifest in &manifests {
        for declaration in manifest.vcs_providers() {
            let candidate = Owner {
                plugin_id: manifest.id(),
                declaration,
            };
            let (winner, loser) = match owners.remove(declaration.id.as_str()) {
                None => {
                    owners.insert(&declaration.id, candidate);
                    continue;
                }
                Some(current) if precedes(&candidate, &current) => (candidate, current),
                Some(current) => (current, candidate),
            };
            conflicts.push(json!({
                "pluginID": loser.plugin_id,
                "vcs": declaration.id,
                "by": winner.plugin_id,
            }));
            owners.insert(&declaration.id, winner);
        }
    }
    conflicts.sort_by_key(Value::to_string);

    let git_markers = built_in_git_markers();
    let mut providers = vec![json!({
        "vcs": BUILT_IN_GIT,
        "displayName": "Git",
        "origin": { "kind": "builtIn" },
        "markers": git_markers,
    })];
    let mut sets = vec![MarkerSet {
        vcs: BUILT_IN_GIT,
        markers: &git_markers,
    }];
    for owner in owners.values() {
        providers.push(owner.declaration.descriptor(owner.plugin_id));
        sets.push(MarkerSet {
            vcs: &owner.declaration.id,
            markers: &owner.declaration.detection.markers,
        });
    }
    let mappings: Vec<Mapping> = request
        .mappings
        .into_iter()
        .map(|mapping| Mapping {
            id: mapping.id,
            vcs: mapping.vcs,
        })
        .collect();
    let detection = roots::detect(&workspace, &sets, &mappings);
    let roots: Vec<Value> = detection
        .roots
        .iter()
        .map(|root| {
            json!({
                "id": root.id,
                "vcs": root.vcs,
                "path": root.path.to_string_lossy(),
                "mapped": root.mapped,
            })
        })
        .collect();
    let ambiguous: Vec<Value> = detection
        .ambiguous
        .iter()
        .map(|directory| json!({ "id": directory.id, "vcs": directory.vcs }))
        .collect();
    let unused: Vec<Value> = detection
        .unused_mappings
        .iter()
        .map(|mapping| json!({ "id": mapping.id, "vcs": mapping.vcs }))
        .collect();
    Ok(outcome(Ok((
        "detection",
        json!({
            "providers": providers,
            "roots": roots,
            "ambiguous": ambiguous,
            "unusedMappings": unused,
            "truncated": detection.truncated,
            "rejected": rejected,
            "conflicts": conflicts,
        }),
    ))))
}

/// Most paths one `vcs.ownerOf` call may ask about.
const MAX_OWNER_PATHS: usize = 100_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OwnerOfRequest {
    /// Root IDs of one `vcs.detectRoots` result.
    roots: Vec<String>,
    /// Its unmapped ambiguous directories.
    #[serde(default)]
    ambiguous: Vec<String>,
    /// Workspace-relative paths with `/` separators; `""` is the workspace.
    paths: Vec<String>,
}

/// `vcs.ownerOf`: the root that owns each path under the rule of
/// `vcs.detectRoots`, so every host assigns files the same way.
pub(crate) fn vcs_owner_of_command(payload: Value) -> Result<Value, CoreError> {
    let request: OwnerOfRequest = decode_payload(payload, "vcs.ownerOf")?;
    if request.paths.len() > MAX_OWNER_PATHS {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("One call asks about at most {MAX_OWNER_PATHS} paths."),
        ));
    }
    if let Some(id) = request
        .roots
        .iter()
        .chain(&request.ambiguous)
        .find(|id| !roots::is_directory_id(id))
    {
        return Err(
            CoreError::new(ErrorCode::InvalidRequest, "Malformed root ID").with_details(id.clone()),
        );
    }
    if let Some(path) = request
        .paths
        .iter()
        .find(|path| !path.is_empty() && !is_root_relative(path))
    {
        return Err(
            CoreError::new(ErrorCode::InvalidRequest, "Malformed workspace path")
                .with_details(path.clone()),
        );
    }
    let owners: Vec<Value> = request
        .paths
        .iter()
        .map(|path| {
            json!({
                "path": path,
                "root": roots::owner(&request.roots, &request.ambiguous, path),
            })
        })
        .collect();
    Ok(outcome(Ok(("owners", json!(owners)))))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecodeReplyRequest {
    operation: String,
    /// Capabilities the session negotiated, as Core reported them.
    capabilities: Capabilities,
    /// The arguments the host sent with the request.
    #[serde(default)]
    request: Value,
    /// The provider's result, unwrapped from the session's `value`.
    reply: Value,
}

/// `vcs.decodeReply`: a provider's reply as the normalized result, or
/// `plugin.vcs.invalidOutput`.
pub(crate) fn vcs_decode_reply_command(payload: Value) -> Result<Value, CoreError> {
    let request: DecodeReplyRequest = decode_payload(payload, "vcs.decodeReply")?;
    let operation = Operation::parse(&request.operation).ok_or_else(|| {
        CoreError::new(ErrorCode::InvalidRequest, "Unknown VCS operation")
            .with_details(request.operation.clone())
    })?;
    Ok(outcome(
        requests::decode(
            operation,
            &request.request,
            &request.reply,
            &request.capabilities,
        )
        .map(|result| ("result", result)),
    ))
}
