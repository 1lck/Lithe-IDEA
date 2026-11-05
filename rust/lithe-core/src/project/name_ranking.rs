//! Pure name ranking for hosts that enumerate candidates themselves (`workspace.rankNames`).
//!
//! Quick Open on Windows lists remote and WSL workspaces through platform I/O, so Core cannot
//! walk those roots. The host still sends only candidate names, the query and explicit context
//! (open and recently visited files); the score, the UTF-16 highlight ranges and the tie-break
//! order all come from the same matcher that backs `workspace.searchEverywhere`.

use super::file_name_order::FileNameKey;
use super::name_matching::match_name;
use crate::protocol::{CoreError, ErrorCode, SearchNameRange};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Upper bound for one request; matches the entry-order budget for natively listed names.
const MAX_CANDIDATES: usize = 500_000;
/// Longest accepted candidate name or path, in UTF-8 bytes; longer values are rejected.
const MAX_TEXT_BYTES: usize = 4_096;
const DEFAULT_LIMIT_PER_TIER: usize = 200;
/// A path-only hit is weaker than a name hit of the same form.
const PATH_DEGREE_DIVISOR: i32 = 4;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RankNamesRequest {
    query: String,
    candidates: Vec<RankCandidate>,
    #[serde(default)]
    context: RankContext,
    /// Keeps the best N hits of each tier; the host shows tiers as separate sections.
    #[serde(default)]
    limit_per_tier: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RankCandidate {
    name: String,
    /// Full path; identifies the candidate in the context lists and is a weaker match target.
    #[serde(default)]
    path: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RankContext {
    /// Paths of open editors, including the active one.
    #[serde(default)]
    open_paths: Vec<String>,
    /// Recently visited paths, most recent first.
    #[serde(default)]
    recent_paths: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
enum Tier {
    Open,
    Recent,
    Other,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RankedName {
    /// Index into the request's `candidates`.
    index: usize,
    degree: i32,
    tier: Tier,
    /// UTF-16 ranges in the candidate name; empty when only the path matched.
    name_match_ranges: Vec<SearchNameRange>,
}

/// Scores and orders candidates for `workspace.rankNames`.
///
/// Returns `{ matches }` sorted by degree, then open before recent before other, then the
/// recency of recent files, then IDEA's file-name order, then request order. A candidate
/// matches through its name, or through its path at a reduced degree. Oversized requests fail
/// with `invalid_request` instead of being truncated.
pub(crate) fn rank_names_command(payload: Value) -> Result<Value, CoreError> {
    let request: RankNamesRequest = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid name ranking request")
            .with_details(error.to_string())
    })?;
    if request.candidates.len() > MAX_CANDIDATES {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many names to rank",
        ));
    }
    if request.candidates.iter().any(|candidate| {
        candidate.name.len() > MAX_TEXT_BYTES
            || candidate
                .path
                .as_ref()
                .is_some_and(|path| path.len() > MAX_TEXT_BYTES)
    }) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Name is too long to rank",
        ));
    }
    let query = request.query.trim();
    if query.is_empty() {
        return Ok(serde_json::json!({ "matches": [] }));
    }
    let open: std::collections::HashSet<&str> = request
        .context
        .open_paths
        .iter()
        .map(String::as_str)
        .collect();
    let mut recent: HashMap<&str, usize> = HashMap::new();
    for (rank, path) in request.context.recent_paths.iter().enumerate() {
        recent.entry(path.as_str()).or_insert(rank);
    }

    struct Hit {
        ranked: RankedName,
        recent_rank: usize,
        key: FileNameKey,
    }
    let mut hits = Vec::new();
    for (index, candidate) in request.candidates.iter().enumerate() {
        let (degree, ranges) = if let Some(hit) = match_name(query, &candidate.name) {
            (hit.degree, hit.ranges)
        } else if let Some(hit) = candidate
            .path
            .as_deref()
            .and_then(|path| match_name(query, path))
        {
            ((hit.degree / PATH_DEGREE_DIVISOR).max(1), Vec::new())
        } else {
            continue;
        };
        let identity = candidate.path.as_deref().unwrap_or(&candidate.name);
        let recent_rank = recent.get(identity).copied();
        let tier = if open.contains(identity) {
            Tier::Open
        } else if recent_rank.is_some() {
            Tier::Recent
        } else {
            Tier::Other
        };
        hits.push(Hit {
            ranked: RankedName {
                index,
                degree,
                tier,
                name_match_ranges: ranges,
            },
            recent_rank: recent_rank.unwrap_or(usize::MAX),
            key: FileNameKey::new(&candidate.name),
        });
    }
    hits.sort_by(|a, b| {
        b.ranked
            .degree
            .cmp(&a.ranked.degree)
            .then(a.ranked.tier.cmp(&b.ranked.tier))
            .then(a.recent_rank.cmp(&b.recent_rank))
            .then_with(|| a.key.cmp(&b.key))
            .then(a.ranked.index.cmp(&b.ranked.index))
    });
    let limit = request.limit_per_tier.unwrap_or(DEFAULT_LIMIT_PER_TIER);
    let mut taken = [0usize; 3];
    let matches: Vec<RankedName> = hits
        .into_iter()
        .filter_map(|hit| {
            let slot = &mut taken[hit.ranked.tier as usize];
            (*slot < limit).then(|| {
                *slot += 1;
                hit.ranked
            })
        })
        .collect();
    Ok(serde_json::json!({ "matches": matches }))
}
