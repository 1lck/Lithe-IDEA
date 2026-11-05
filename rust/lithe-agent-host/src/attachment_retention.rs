//! Retention plan for pasted Agent images.
//!
//! A pasted image is a file the Agent reads later as a resource link, so it must
//! outlive the paste for as long as any conversation still refers to it. Platforms
//! list their pasted-image cache and keep a ledger of the references a conversation
//! accepted; this module decides which files may be deleted. Deleting stays with
//! the platform. Contract: `shared/fixtures/agent/attachment-retention-v1.json`.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

/// Age after which an unreferenced image is no longer needed (seven days).
pub const RETENTION_MILLISECONDS: i64 = 7 * 24 * 3600 * 1000;

/// One file in the platform's pasted-image cache.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Entry {
    pub path: String,
    /// Last modification time in Unix milliseconds; unknown ages are never expired.
    #[serde(default)]
    pub modified_ms: Option<i64>,
    /// True for a paste that was abandoned or failed before any conversation accepted it.
    #[serde(default)]
    pub abandoned: bool,
}

/// Payload of `agent.attachments.retentionPlan`. Pure: no files are read or written.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub now_ms: i64,
    pub entries: Vec<Entry>,
    /// Paths a conversation has accepted, from the platform's ledger.
    #[serde(default)]
    pub accepted_references: Vec<String>,
    /// Compare paths without case (Windows); separators are always normalized.
    #[serde(default)]
    pub case_insensitive: bool,
}

/// Why a file is deleted or kept; stable snake_case codes for logs and tests.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    Referenced,
    Abandoned,
    Expired,
    Recent,
}

/// One decision for one cache entry.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub path: String,
    pub reason: Reason,
}

/// Files the platform should delete and files it must keep.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub delete: Vec<Decision>,
    pub keep: Vec<Decision>,
}

fn key(path: &str, case_insensitive: bool) -> String {
    let normalized = path.replace('\\', "/");
    if case_insensitive {
        normalized.to_lowercase()
    } else {
        normalized
    }
}

/// A referenced image is always kept, even when the paste was marked abandoned.
pub fn plan(request: &Request) -> Plan {
    let referenced: HashSet<String> = request
        .accepted_references
        .iter()
        .map(|path| key(path, request.case_insensitive))
        .collect();
    let cutoff = request.now_ms.saturating_sub(RETENTION_MILLISECONDS);
    let mut result = Plan {
        delete: Vec::new(),
        keep: Vec::new(),
    };
    for entry in &request.entries {
        let reason = if referenced.contains(&key(&entry.path, request.case_insensitive)) {
            Reason::Referenced
        } else if entry.abandoned {
            Reason::Abandoned
        } else if entry.modified_ms.is_some_and(|modified| modified < cutoff) {
            Reason::Expired
        } else {
            Reason::Recent
        };
        let decision = Decision {
            path: entry.path.clone(),
            reason,
        };
        match reason {
            Reason::Referenced | Reason::Recent => result.keep.push(decision),
            Reason::Abandoned | Reason::Expired => result.delete.push(decision),
        }
    }
    result
}
