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

/// Open and recently visited paths that break ties between equally good name matches.
///
/// `workspace.rankNames` compares them with the candidate's `path`; `workspace.searchEverywhere`
/// compares them with the workspace-relative, `/`-separated path of each file under its root.
#[derive(Deserialize, Serialize, Default, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RankContext {
    /// Paths of open editors, including the active one.
    #[serde(default)]
    pub(crate) open_paths: Vec<String>,
    /// Recently visited paths, most recent first.
    #[serde(default)]
    pub(crate) recent_paths: Vec<String>,
}

/// A degree scaled by this factor leaves room for the context bonus without reordering degrees.
const CONTEXT_SCALE: i32 = 1024;

/// Lookup tables built once per request from a [`RankContext`].
pub(crate) struct ContextIndex<'a> {
    open: std::collections::HashSet<&'a str>,
    recent: HashMap<&'a str, usize>,
}

impl<'a> ContextIndex<'a> {
    pub(crate) fn new(context: &'a RankContext) -> Self {
        let mut recent = HashMap::new();
        for (rank, path) in context.recent_paths.iter().enumerate() {
            recent.entry(path.as_str()).or_insert(rank);
        }
        Self {
            open: context.open_paths.iter().map(String::as_str).collect(),
            recent,
        }
    }

    fn classify(&self, identity: &str) -> (Tier, usize) {
        if self.open.contains(identity) {
            (Tier::Open, usize::MAX)
        } else if let Some(rank) = self.recent.get(identity) {
            (Tier::Recent, *rank)
        } else {
            (Tier::Other, usize::MAX)
        }
    }

    /// Folds the context into a degree so one integer order also serves paged search cursors:
    /// among equal degrees open files come first, then recent files by recency.
    pub(crate) fn contextual_degree(&self, degree: i32, identity: &str) -> i32 {
        let bonus = match self.classify(identity) {
            (Tier::Open, _) => CONTEXT_SCALE - 1,
            (Tier::Recent, rank) => CONTEXT_SCALE - 2 - rank.min(CONTEXT_SCALE as usize - 3) as i32,
            (Tier::Other, _) => 0,
        };
        degree * CONTEXT_SCALE + bonus
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Tier {
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
    let context = ContextIndex::new(&request.context);

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
        let (tier, recent_rank) = context.classify(identity);
        hits.push(Hit {
            ranked: RankedName {
                index,
                degree,
                tier,
                name_match_ranges: ranges,
            },
            recent_rank,
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
