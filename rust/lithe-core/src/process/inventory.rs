//! Classification of a process snapshot into lifecycle items.
//!
//! Hosts read their process table (PIDs, sessions, inherited environment) and
//! signal processes; everything between those two steps is decided here so
//! both products classify the same snapshot the same way:
//!
//! - which processes belong to the instance (its `LITHE_PROCESS_SCOPE` token),
//! - which of an Agent's processes are its own infrastructure and which are
//!   tasks it started, grouped by the task that started them,
//! - which processes detached into background services,
//! - which belong to a terminal session, and what is left.
//!
//! The rules are described in
//! `.agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md`;
//! fixtures live in `shared/fixtures/process-lifecycle/`.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::process::lifecycle::{
    resolve, LifecycleContext, LifecyclePlan, LifecycleRecord, LifecycleRequest, Ownership,
    RecordKind, TerminationSettings,
};

/// Longest display name before it is shortened with an ellipsis.
const DISPLAY_NAME_CHARACTERS: usize = 80;

/// A process as identified across PID reuse.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub struct ProcessIdentity {
    /// Operating-system process ID.
    pub process_id: i64,
    /// Start time in microseconds since 1970.
    pub start_time: u64,
}

/// One row of the host's process snapshot.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessEntry {
    /// Operating-system process ID.
    pub process_id: i64,
    /// Start time in microseconds since 1970.
    pub start_time: u64,
    /// Parent process ID; re-parented orphans report the system's init process.
    pub parent_process_id: i64,
    /// Session ID; on Windows hosts, the ID of the job or console the process belongs to.
    pub session_id: i64,
    /// Whether the process still has a controlling terminal.
    #[serde(default)]
    pub has_controlling_terminal: bool,
    /// Short kernel name, used when the arguments are unreadable.
    #[serde(default)]
    pub name: String,
    /// Executable path.
    #[serde(default)]
    pub executable_path: String,
    /// Arguments including `argv[0]`.
    #[serde(default)]
    pub arguments: Vec<String>,
    /// Value of `LITHE_PROCESS_SCOPE`, if set.
    #[serde(default)]
    pub process_scope: Option<String>,
    /// Value of `LITHE_AGENT_SCOPE`, if set.
    #[serde(default)]
    pub agent_scope: Option<String>,
    /// Working directory, if the host could read it.
    #[serde(default)]
    pub working_directory: Option<String>,
}

impl ProcessEntry {
    fn identity(&self) -> ProcessIdentity {
        ProcessIdentity {
            process_id: self.process_id,
            start_time: self.start_time,
        }
    }

    fn command_line(&self) -> String {
        if !self.arguments.is_empty() {
            self.arguments.join(" ")
        } else if !self.executable_path.is_empty() {
            self.executable_path.clone()
        } else {
            self.name.clone()
        }
    }

    /// Executable name and the start of its arguments, short enough for one row.
    fn display_name(&self) -> String {
        let executable = self
            .executable_path
            .rsplit('/')
            .next()
            .filter(|name| !name.is_empty())
            .unwrap_or(&self.name);
        let arguments = self.arguments.iter().skip(1).cloned().collect::<Vec<_>>();
        let summary = if arguments.is_empty() {
            executable.to_string()
        } else {
            format!("{executable} {}", arguments.join(" "))
        };
        if summary.chars().count() > DISPLAY_NAME_CHARACTERS {
            let shortened: String = summary.chars().take(DISPLAY_NAME_CHARACTERS - 1).collect();
            format!("{shortened}…")
        } else {
            summary
        }
    }
}

/// An open Agent connection of a running instance.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentConnection {
    /// Value of `LITHE_AGENT_SCOPE` given to the Agent's process tree.
    pub scope: String,
    /// Name shown in confirmations.
    pub agent_name: String,
    /// Workspace the Agent works in.
    pub workspace: String,
    /// When the first prompt was sent, in microseconds since 1970. Processes
    /// started earlier are the Agent's own; without a prompt there are no tasks.
    #[serde(default)]
    pub task_baseline: Option<u64>,
}

/// Whose snapshot is classified.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum InventoryMode {
    /// The running instance, which knows its Agent connections.
    #[default]
    Live,
    /// An instance that is gone; every Agent process counts as a task.
    Leftover,
}

/// What an item is, for presentation and for the record kind.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ItemCategory {
    /// A command an Agent started, with what it started in turn.
    AgentTask,
    /// The Agent process, its adapter and its MCP servers.
    AgentInfrastructure,
    /// A process that left its terminal or tool to run on its own.
    BackgroundService,
    /// Processes of one terminal session.
    Terminal,
    /// Everything else of the instance, such as language servers.
    Other,
}

/// Request of `processLifecycle.inventory`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InventoryRequest {
    /// Scope token of the instance whose processes are classified.
    pub scope: String,
    /// Whether the instance is still running.
    #[serde(default)]
    pub mode: InventoryMode,
    /// Session of the application process; another session without a terminal
    /// has detached, even if its session leader has already exited.
    pub application_session_id: i64,
    /// Processes never listed, such as the application and its supervisor.
    #[serde(default)]
    pub excluded_process_ids: Vec<i64>,
    /// Processes the user chose to keep; never listed again.
    #[serde(default)]
    pub retained: Vec<ProcessIdentity>,
    /// Restricts an Agent operation to these scopes; omitted means all scopes.
    /// A single connection close must never include another connection's rows.
    #[serde(default)]
    pub agent_scopes: Option<Vec<String>>,
    /// Exact process identities approved for the final unattended sweep.
    #[serde(default)]
    pub approved_termination: Vec<ProcessIdentity>,
    /// Open Agent connections; only used in live mode.
    #[serde(default)]
    pub agent_connections: Vec<AgentConnection>,
    /// The host's snapshot, including processes of other scopes.
    #[serde(default)]
    pub processes: Vec<ProcessEntry>,
    /// When set, the response also carries the plan for these items.
    #[serde(default)]
    pub context: Option<LifecycleContext>,
    /// Settings for that plan.
    #[serde(default)]
    pub settings: TerminationSettings,
}

/// One classified group of processes.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InventoryItem {
    /// Stable while the root process lives; also the lifecycle record ID.
    pub id: String,
    /// What the item is.
    pub category: ItemCategory,
    /// Record kind used for its lifecycle decision.
    pub kind: RecordKind,
    /// It left the session it was started in.
    pub detached: bool,
    /// One-line name for lists.
    pub name: String,
    /// Full command line of the root process.
    pub detail: String,
    /// The process that represents the item.
    pub root_process_id: i64,
    /// Earliest start time of its processes, in microseconds since 1970.
    pub started_at: u64,
    /// Agent that started it, for Agent items.
    pub agent_name: Option<String>,
    /// Workspace of that Agent.
    pub workspace: Option<String>,
    /// Working directory of the root process, if known.
    pub working_directory: Option<String>,
    /// Every process of the item, root first.
    pub processes: Vec<ProcessIdentity>,
}

/// Response of `processLifecycle.inventory`.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Inventory {
    /// Items in presentation order.
    pub items: Vec<InventoryItem>,
    /// Decisions for the items when the request named a context.
    pub plan: Option<LifecyclePlan>,
}

/// Classifies the processes of `request.scope`.
pub fn classify(request: &InventoryRequest) -> Inventory {
    let excluded: BTreeSet<i64> = request.excluded_process_ids.iter().copied().collect();
    let retained: BTreeSet<ProcessIdentity> = request.retained.iter().copied().collect();
    let mut remaining: Vec<&ProcessEntry> = request
        .processes
        .iter()
        .filter(|process| process.process_scope.as_deref() == Some(request.scope.as_str()))
        .filter(|process| !excluded.contains(&process.process_id))
        .filter(|process| !retained.contains(&process.identity()))
        .filter(|process| {
            request.agent_scopes.as_ref().is_none_or(|scopes| {
                process
                    .agent_scope
                    .as_ref()
                    .is_some_and(|scope| scopes.contains(scope))
            })
        })
        .collect();
    remaining.sort_by_key(|process| process.process_id);

    let mut items = agent_items(request, &mut remaining);
    items.extend(background_items(
        request.application_session_id,
        &mut remaining,
    ));
    items.extend(terminal_items(&mut remaining));
    if let Some(item) = other_item(&remaining) {
        items.push(item);
    }

    let plan = request.context.map(|context| {
        let approved: BTreeSet<ProcessIdentity> =
            request.approved_termination.iter().copied().collect();
        resolve(&LifecycleRequest {
            context,
            settings: request.settings.clone(),
            records: items
                .iter()
                .map(|item| {
                    let mut record = record(item, &approved);
                    if request.application_session_id <= 0 && item.category == ItemCategory::Other {
                        // The scope proves ownership, but the missing original SID
                        // cannot distinguish an ordinary tool from a kept daemon.
                        record.declared_policy =
                            Some(crate::process::lifecycle::ExitPolicy::AskOnExit);
                    }
                    record
                })
                .collect(),
        })
    });
    Inventory { items, plan }
}

/// The lifecycle record of an item.
fn record(item: &InventoryItem, approved: &BTreeSet<ProcessIdentity>) -> LifecycleRecord {
    LifecycleRecord {
        id: item.id.clone(),
        kind: item.kind,
        ownership: Ownership::ScopeToken,
        declared_policy: None,
        recognizer_id: None,
        recognized_policy: None,
        detached: item.detached,
        idle: false,
        retained: false,
        termination_approved: item
            .processes
            .iter()
            .all(|identity| approved.contains(identity)),
    }
}

fn agent_items(
    request: &InventoryRequest,
    remaining: &mut Vec<&ProcessEntry>,
) -> Vec<InventoryItem> {
    let connections: HashMap<&str, &AgentConnection> = match request.mode {
        InventoryMode::Live => request
            .agent_connections
            .iter()
            .map(|connection| (connection.scope.as_str(), connection))
            .collect(),
        InventoryMode::Leftover => HashMap::new(),
    };
    let mut by_scope: BTreeMap<&str, Vec<&ProcessEntry>> = BTreeMap::new();
    remaining.retain(|process| match process.agent_scope.as_deref() {
        Some(scope) => {
            by_scope.entry(scope).or_default().push(process);
            false
        }
        None => true,
    });

    let mut items = Vec::new();
    for (scope, processes) in by_scope {
        let Some(connection) = connections.get(scope) else {
            // A gone instance, or a connection that closed while something it
            // started kept running: nobody can tell infrastructure from tasks.
            // During final sweep, approval belongs to individual identities.
            // At startup, independent orphan trees need independent questions.
            if matches!(
                request.context,
                Some(LifecycleContext::FinalSweep | LifecycleContext::StartupSweep)
            ) {
                let trees = if request.context == Some(LifecycleContext::FinalSweep) {
                    processes.iter().map(|process| vec![*process]).collect()
                } else {
                    task_trees(&processes)
                };
                for tree in trees {
                    let root = tree[0];
                    items.push(group_item(
                        format!("agentTask:{}:{}", root.process_id, root.start_time),
                        ItemCategory::AgentTask,
                        RecordKind::AgentTask,
                        &tree,
                        None,
                    ));
                }
            } else {
                items.push(group_item(
                    format!("agentTask:{scope}"),
                    ItemCategory::AgentTask,
                    RecordKind::AgentTask,
                    &processes,
                    None,
                ));
            }
            continue;
        };
        let (infrastructure, tasks): (Vec<&ProcessEntry>, Vec<&ProcessEntry>) =
            processes.into_iter().partition(|process| {
                connection
                    .task_baseline
                    .is_none_or(|baseline| process.start_time <= baseline)
            });
        for root_tree in task_trees(&tasks) {
            let root = root_tree[0];
            items.push(group_item(
                format!("agentTask:{}:{}", root.process_id, root.start_time),
                ItemCategory::AgentTask,
                RecordKind::AgentTask,
                &root_tree,
                Some(connection),
            ));
        }
        if !infrastructure.is_empty() {
            items.push(group_item(
                format!("agentInfrastructure:{scope}"),
                ItemCategory::AgentInfrastructure,
                RecordKind::Sidecar,
                &infrastructure,
                Some(connection),
            ));
        }
    }
    items
}

/// Groups task processes under the task that started them; a process whose
/// parent is not a task (the Agent itself, or the system after re-parenting)
/// is a task root. Each tree is returned root first.
fn task_trees<'a>(tasks: &[&'a ProcessEntry]) -> Vec<Vec<&'a ProcessEntry>> {
    let by_id: HashMap<i64, &ProcessEntry> =
        tasks.iter().map(|task| (task.process_id, *task)).collect();
    let root_of = |process: &ProcessEntry| -> i64 {
        let mut current = process;
        let mut steps = 0;
        while let Some(parent) = by_id.get(&current.parent_process_id) {
            // A parent cycle cannot happen in a consistent snapshot; bound the
            // walk anyway because snapshots are read without a lock.
            if parent.process_id == current.process_id || steps > by_id.len() {
                break;
            }
            current = parent;
            steps += 1;
        }
        current.process_id
    };
    let mut trees: BTreeMap<i64, Vec<&ProcessEntry>> = BTreeMap::new();
    for task in tasks {
        trees.entry(root_of(task)).or_default().push(task);
    }
    trees
        .into_iter()
        .map(|(root_id, mut members)| {
            members.sort_by_key(|member| (member.process_id != root_id, member.process_id));
            members
        })
        .collect()
}

fn background_items(
    application_session_id: i64,
    remaining: &mut Vec<&ProcessEntry>,
) -> Vec<InventoryItem> {
    // A double-fork daemon keeps the detached session's ID after its leader
    // exits. Classify the surviving session, not just a live session leader.
    // Missing session IDs and application-session orphans do not prove detachment.
    // An old record may not have persisted its original application session.
    // The recovery executor's SID is not a substitute for that missing fact.
    if application_session_id <= 0 {
        return Vec::new();
    }
    let mut sessions: BTreeMap<i64, Vec<&ProcessEntry>> = BTreeMap::new();
    for process in remaining.iter().copied() {
        if process.session_id > 0 && process.session_id != application_session_id {
            sessions
                .entry(process.session_id)
                .or_default()
                .push(process);
        }
    }
    let mut items = Vec::new();
    for (session_id, mut members) in sessions {
        // A surviving terminal session must not become a daemon merely because
        // one member has no controlling terminal in the snapshot.
        if members.iter().any(|member| member.has_controlling_terminal) {
            continue;
        }
        remaining.retain(|process| process.session_id != session_id);
        let process_ids: BTreeSet<i64> = members.iter().map(|member| member.process_id).collect();
        members.sort_by_key(|member| {
            (
                member.process_id != session_id,
                process_ids.contains(&member.parent_process_id),
                member.process_id,
            )
        });
        let root = members[0];
        items.push(group_item(
            format!("service:{}:{}", root.process_id, root.start_time),
            ItemCategory::BackgroundService,
            RecordKind::Daemon,
            &members,
            None,
        ));
    }
    items
}

fn terminal_items(remaining: &mut Vec<&ProcessEntry>) -> Vec<InventoryItem> {
    let mut sessions: BTreeMap<i64, Vec<&ProcessEntry>> = BTreeMap::new();
    remaining.retain(|process| {
        if process.has_controlling_terminal {
            sessions
                .entry(process.session_id)
                .or_default()
                .push(process);
            false
        } else {
            true
        }
    });
    sessions
        .into_iter()
        .map(|(session_id, mut members)| {
            members.sort_by_key(|member| (member.process_id != session_id, member.process_id));
            group_item(
                format!("terminal:{session_id}"),
                ItemCategory::Terminal,
                RecordKind::Terminal,
                &members,
                None,
            )
        })
        .collect()
}

fn other_item(remaining: &[&ProcessEntry]) -> Option<InventoryItem> {
    (!remaining.is_empty()).then(|| {
        group_item(
            "run:other".to_string(),
            ItemCategory::Other,
            RecordKind::Run,
            remaining,
            None,
        )
    })
}

/// Builds an item from processes whose first entry represents it.
fn group_item(
    id: String,
    category: ItemCategory,
    kind: RecordKind,
    processes: &[&ProcessEntry],
    connection: Option<&AgentConnection>,
) -> InventoryItem {
    let process_ids: BTreeSet<i64> = processes.iter().map(|process| process.process_id).collect();
    // Without a better root, the first process whose parent is outside the
    // group stands for it.
    let root = processes
        .iter()
        .find(|process| !process_ids.contains(&process.parent_process_id))
        .unwrap_or(&processes[0]);
    let mut identities: Vec<ProcessIdentity> = vec![root.identity()];
    identities.extend(
        processes
            .iter()
            .filter(|process| process.process_id != root.process_id)
            .map(|process| process.identity()),
    );
    InventoryItem {
        id,
        category,
        kind,
        detached: category == ItemCategory::BackgroundService,
        name: root.display_name(),
        detail: root.command_line(),
        root_process_id: root.process_id,
        started_at: processes
            .iter()
            .map(|process| process.start_time)
            .min()
            .unwrap_or(0),
        agent_name: connection.map(|connection| connection.agent_name.clone()),
        workspace: connection.map(|connection| connection.workspace.clone()),
        working_directory: root.working_directory.clone(),
        processes: identities,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        schema_version: u32,
        cases: Vec<FixtureCase>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct FixtureCase {
        name: String,
        request: serde_json::Value,
        expected: serde_json::Value,
    }

    // Both hosts replay this file, so a rule change must update it.
    #[test]
    fn shared_fixture_inventories_match() {
        let fixture: Fixture = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/process-lifecycle/inventory-v1.json"
        ))
        .expect("fixture should parse");
        assert_eq!(fixture.schema_version, 1);
        for case in fixture.cases {
            let mut request: InventoryRequest =
                serde_json::from_value(case.request).expect("fixture request should decode");
            for ordering in ["original", "reversed", "rotated"] {
                match ordering {
                    "reversed" => request.processes.reverse(),
                    "rotated" if !request.processes.is_empty() => request.processes.rotate_left(1),
                    _ => {}
                }
                let inventory =
                    serde_json::to_value(classify(&request)).expect("inventory should encode");
                assert_eq!(
                    inventory, case.expected,
                    "fixture case {} ({ordering} snapshot)",
                    case.name
                );
            }
        }
    }

    #[test]
    fn long_display_names_are_shortened() {
        let process = ProcessEntry {
            process_id: 10,
            start_time: 1,
            parent_process_id: 1,
            session_id: 10,
            has_controlling_terminal: false,
            name: "java".into(),
            executable_path: "/usr/bin/java".into(),
            arguments: vec!["java".into(), "x".repeat(200)],
            process_scope: None,
            agent_scope: None,
            working_directory: None,
        };
        let name = process.display_name();
        assert_eq!(name.chars().count(), DISPLAY_NAME_CHARACTERS);
        assert!(name.starts_with("java x"));
        assert!(name.ends_with('…'));
    }
}
