//! Read-only VCS snapshots bound to a native window and workspace incarnation.
//! Core owns markers, provider precedence, ambiguity and deepest-root semantics.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

pub(super) const READ_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_WORKSPACES: usize = 128;
const MAX_RETIRED: usize = 4096;
pub(super) const STALE: &str = "requestCancelled";

pub(super) trait VcsCore {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String>;
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Package {
    pub plugin_id: String,
    pub identity: String,
    pub manifest: Value,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Scope {
    pub workspace_id: String,
    pub workspace_root: String,
    pub incarnation: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Root {
    pub id: String,
    pub vcs: String,
    pub path: String,
    pub mapped: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Detection {
    pub providers: Vec<Value>,
    pub roots: Vec<Root>,
    pub ambiguous: Vec<Value>,
    pub unused_mappings: Vec<Value>,
    pub truncated: bool,
    pub rejected: Vec<Value>,
    pub conflicts: Vec<Value>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub generation: u64,
    pub workspace_id: String,
    pub workspace_root: String,
    pub detection: Detection,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mappings: Option<super::mappings::MappingSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub watch_error: Option<String>,
    pub mapping_choices: Vec<Value>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Owner {
    pub path: String,
    pub root: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Ownership {
    pub generation: u64,
    pub owners: Vec<Owner>,
    /// A batch/move can target one owner only when every path resolved to it
    /// and the detector did not report a partial walk. This is no execution grant.
    pub common_root: Option<Root>,
    pub complete: bool,
}

#[derive(Clone)]
pub(super) struct Ticket {
    host: String,
    scope: Scope,
    pub generation: u64,
    pub deadline: Instant,
    pub registration: u64,
    started: Instant,
}
struct Entry {
    ticket: Ticket,
    snapshot: Option<(Snapshot, Vec<Package>)>,
}
#[derive(Default)]
pub(super) struct Registry {
    next: u64,
    entries: HashMap<(String, String), Entry>,
    retired: HashSet<(String, String, String)>,
    exhausted: bool,
}
impl Registry {
    pub fn begin(
        &mut self,
        host: &str,
        scope: Scope,
        registration: u64,
        now: Instant,
    ) -> Result<Ticket, String> {
        let key = (host.into(), scope.workspace_id.clone());
        if self.exhausted
            || self.retired.contains(&(
                host.into(),
                scope.workspace_id.clone(),
                scope.incarnation.clone(),
            ))
        {
            return Err(STALE.into());
        }
        if !self.entries.contains_key(&key) && self.entries.len() >= MAX_WORKSPACES {
            return Err("requestLimitExceeded".into());
        }
        if let Some(previous) = self.entries.get(&key) {
            if previous.ticket.started > now {
                return Err(STALE.into());
            }
            if previous.ticket.scope != scope || previous.ticket.registration != registration {
                if previous.ticket.scope.incarnation == scope.incarnation {
                    return Err(STALE.into());
                }
                let previous = previous.ticket.scope.clone();
                self.retire(host, &previous)?;
            }
        }
        self.next = self.next.checked_add(1).ok_or("requestLimitExceeded")?;
        let ticket = Ticket {
            host: host.into(),
            scope,
            generation: self.next,
            deadline: now + READ_TIMEOUT,
            registration,
            started: now,
        };
        self.entries.insert(
            key,
            Entry {
                ticket: ticket.clone(),
                snapshot: None,
            },
        );
        Ok(ticket)
    }
    fn entry(&self, ticket: &Ticket) -> Result<&Entry, String> {
        self.entries
            .get(&(ticket.host.clone(), ticket.scope.workspace_id.clone()))
            .filter(|entry| {
                entry.ticket.scope == ticket.scope && entry.ticket.generation == ticket.generation
            })
            .ok_or_else(|| STALE.into())
    }
    pub fn publish(
        &mut self,
        ticket: &Ticket,
        detection: Detection,
        packages: Vec<Package>,
        now: Instant,
    ) -> Result<Snapshot, String> {
        self.entry(ticket)?;
        if now >= ticket.deadline {
            return Err("requestTimeout".into());
        }
        let snapshot = Snapshot {
            generation: ticket.generation,
            workspace_id: ticket.scope.workspace_id.clone(),
            workspace_root: ticket.scope.workspace_root.clone(),
            detection,
            mappings: None,
            watch_error: None,
            mapping_choices: Vec::new(),
        };
        self.entries
            .get_mut(&(ticket.host.clone(), ticket.scope.workspace_id.clone()))
            .expect("checked entry")
            .snapshot = Some((snapshot.clone(), packages));
        Ok(snapshot)
    }
    pub fn capture(
        &self,
        host: &str,
        scope: &Scope,
        generation: u64,
    ) -> Result<(Snapshot, Vec<Package>, u64), String> {
        let entry = self
            .entries
            .get(&(host.into(), scope.workspace_id.clone()))
            .filter(|entry| entry.ticket.scope == *scope && entry.ticket.generation == generation)
            .ok_or(STALE)?;
        entry
            .snapshot
            .clone()
            .map(|(snapshot, packages)| (snapshot, packages, entry.ticket.registration))
            .ok_or_else(|| STALE.into())
    }
    pub fn retire(&mut self, host: &str, scope: &Scope) -> Result<(), String> {
        let retired = (
            host.into(),
            scope.workspace_id.clone(),
            scope.incarnation.clone(),
        );
        if !self.retired.contains(&retired) && self.retired.len() >= MAX_RETIRED {
            return Err("requestLimitExceeded".into());
        }
        self.retired.insert(retired);
        let key = (host.into(), scope.workspace_id.clone());
        if self
            .entries
            .get(&key)
            .is_some_and(|entry| entry.ticket.scope == *scope)
        {
            self.entries.remove(&key);
        }
        Ok(())
    }
    pub fn invalidate(&mut self) {
        // Retain incarnation tombstones for a later native window close,
        // while invalidating every captured scan/ownership generation now.
        for entry in self.entries.values_mut() {
            entry.ticket.generation = 0;
            entry.snapshot = None;
        }
    }
    pub fn invalidate_generation(&mut self, host: &str, scope: &Scope, generation: u64) -> bool {
        let Some(entry) = self
            .entries
            .get_mut(&(host.into(), scope.workspace_id.clone()))
            .filter(|entry| entry.ticket.scope == *scope && entry.ticket.generation == generation)
        else {
            return false;
        };
        entry.ticket.generation = 0;
        entry.snapshot = None;
        true
    }
    pub fn annotate(
        &mut self,
        ticket: &Ticket,
        mappings: super::mappings::MappingSnapshot,
        watch_error: Option<String>,
        choices: Vec<Value>,
    ) -> Result<Snapshot, String> {
        self.entry(ticket)?;
        let entry = self
            .entries
            .get_mut(&(ticket.host.clone(), ticket.scope.workspace_id.clone()))
            .ok_or(STALE)?;
        let (snapshot, _) = entry.snapshot.as_mut().ok_or(STALE)?;
        snapshot.mappings = Some(mappings);
        snapshot.watch_error = watch_error;
        snapshot.mapping_choices = choices;
        Ok(snapshot.clone())
    }
    pub fn close_window(&mut self, host: &str) {
        let scopes: Vec<_> = self
            .entries
            .values()
            .filter(|entry| entry.ticket.host == host)
            .map(|entry| entry.ticket.scope.clone())
            .collect();
        for scope in scopes {
            if self.retire(host, &scope).is_err() {
                self.exhausted = true;
            }
        }
        self.entries.retain(|(window, _), _| window != host);
    }
    pub fn discard(&mut self, ticket: &Ticket) {
        if self.entry(ticket).is_ok() {
            let entry = self
                .entries
                .get_mut(&(ticket.host.clone(), ticket.scope.workspace_id.clone()))
                .expect("checked entry");
            entry.ticket.generation = 0;
            entry.snapshot = None;
        }
    }
}

fn ok(response: &Value) -> Result<(), String> {
    if response["status"] == "ok" {
        Ok(())
    } else {
        Err(response
            .get("error")
            .cloned()
            .unwrap_or(json!({"code":"invalidResponse"}))
            .to_string())
    }
}
pub(super) fn same_roots(left: &Detection, right: &Detection) -> bool {
    left.roots == right.roots
        && left.ambiguous == right.ambiguous
        && left.truncated == right.truncated
}
pub(super) fn detect(
    core: &dyn VcsCore,
    scope: &Scope,
    packages: &[Package],
) -> Result<Detection, String> {
    detect_mapped(core, scope, packages, &[])
}
pub(super) fn detect_mapped(
    core: &dyn VcsCore,
    scope: &Scope,
    packages: &[Package],
    mappings: &[super::mappings::Mapping],
) -> Result<Detection, String> {
    let response = core.execute("vcs.detectRoots", json!({"workspaceRoot":scope.workspace_root,
        "plugins":packages.iter().map(|package| json!({"manifest":package.manifest})).collect::<Vec<_>>(), "mappings":mappings}))?;
    ok(&response)?;
    serde_json::from_value(response["detection"].clone()).map_err(|_| "invalidResponse".into())
}
pub(super) fn owners(
    core: &dyn VcsCore,
    snapshot: &Snapshot,
    paths: &[String],
) -> Result<Ownership, String> {
    let response = core.execute("vcs.ownerOf", json!({
        "roots":snapshot.detection.roots.iter().map(|root| &root.id).collect::<Vec<_>>(),
        "ambiguous":snapshot.detection.ambiguous.iter().map(|row| &row["id"]).collect::<Vec<_>>(), "paths":paths}))?;
    ok(&response)?;
    let owners: Vec<Owner> =
        serde_json::from_value(response["owners"].clone()).map_err(|_| "invalidResponse")?;
    if owners.len() != paths.len()
        || owners
            .iter()
            .zip(paths)
            .any(|(owner, path)| owner.path != *path)
    {
        return Err("invalidResponse".into());
    }
    let common = owners
        .first()
        .and_then(|owner| owner.root.as_ref())
        .filter(|root| {
            !snapshot.detection.truncated
                && owners
                    .iter()
                    .all(|owner| owner.root.as_ref() == Some(*root))
        });
    let common_root = common
        .and_then(|id| snapshot.detection.roots.iter().find(|root| root.id == *id))
        .cloned();
    Ok(Ownership {
        generation: snapshot.generation,
        owners,
        common_root,
        complete: !snapshot.detection.truncated,
    })
}
