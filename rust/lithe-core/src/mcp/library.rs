//! MCP server library rules shared by every host: merging discovered sources,
//! validating editor drafts and planning multi-file edits against the ledger.
//!
//! Hosts read configuration files and the ownership ledger, then pass the exact
//! bytes and records here. Core returns the merged rows, field-level draft
//! issues, or the complete next state of every touched file. Hosts write the
//! returned content atomically and persist the returned ledger entries only
//! after the whole batch succeeds. Nothing here touches the filesystem, and
//! secret env/header values are never copied into errors.

use super::parse::{
    find_server, parse_claude_servers, parse_codex_servers, MAX_CONFIGURATION_BYTES,
};
use super::plan::{plan_write_request, OwnedEntry, ToolFilters, WriteRequest};
use super::{McpKeyValue, McpServer, McpTransport};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

/// Maximum configuration files one library request may carry. Hosts manage
/// one global and at most one project file per Agent.
const MAX_LIBRARY_FILES: usize = 16;

/// One Agent configuration file plus its slice of the host ledger.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LibraryFile {
    /// Opaque host identity. Also the ledger key the host stores entries under.
    id: String,
    /// Configuration owner: `codex` or `claude`. Equals the Agent identity used
    /// in drafts' `enabledAgents`.
    source: String,
    /// `global` or `project`.
    scope: String,
    /// Absolute project path for Claude project entries.
    #[serde(default)]
    project_path: Option<String>,
    /// Native path; the key under which retained tool filters are recorded.
    path: String,
    /// Current text; `null` means the file does not exist yet.
    #[serde(default)]
    content: Option<String>,
    /// Ledger entries the host recorded for this file.
    #[serde(default)]
    owned: Vec<LedgerEntry>,
}

impl LibraryFile {
    fn is_global(&self) -> bool {
        self.scope == "global"
    }

    /// Parses the file with the same scope rules as `mcp.parseConfiguration`.
    fn servers(&self, content: &str) -> Result<Vec<McpServer>, CoreError> {
        if content.len() > MAX_CONFIGURATION_BYTES {
            return Err(invalid_request());
        }
        match (self.source.as_str(), self.scope.as_str()) {
            ("codex", "global" | "project") => parse_codex_servers(content),
            ("claude", "global") => parse_claude_servers(content, None),
            ("claude", "project") => parse_claude_servers(
                content,
                Some(self.project_path.as_deref().ok_or_else(invalid_request)?),
            ),
            _ => Err(invalid_request()),
        }
    }

    fn ledger_owns(&self, name: &str, source_hash: &str) -> bool {
        self.owned
            .iter()
            .any(|entry| entry.name == name && entry.source_hash.as_deref() == Some(source_hash))
    }
}

/// Host ledger record: live ownership of one entry, or retained native tool
/// filters without a `sourceHash` after Lithe removed the entry.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LedgerEntry {
    name: String,
    definition_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_hash: Option<String>,
    /// Retained filters keyed by native path, so profile roots stay distinct.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tool_filters: Option<BTreeMap<String, ToolFilters>>,
}

impl LedgerEntry {
    fn owned_entry(&self) -> OwnedEntry {
        OwnedEntry {
            name: self.name.clone(),
            definition_hash: self.definition_hash.clone(),
            source_hash: self.source_hash.clone(),
        }
    }
}

fn invalid_request() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid MCP library request")
}

fn decode<T: for<'de> Deserialize<'de>>(payload: Value) -> Result<T, CoreError> {
    serde_json::from_value(payload).map_err(|_| invalid_request())
}

fn bounded(files: &[LibraryFile]) -> Result<(), CoreError> {
    let mut ids = BTreeSet::new();
    if files.len() > MAX_LIBRARY_FILES || !files.iter().all(|file| ids.insert(file.id.as_str())) {
        return Err(invalid_request());
    }
    Ok(())
}

// MARK: - Snapshot

#[derive(Deserialize)]
struct SnapshotRequest {
    files: Vec<LibraryFile>,
}

/// One discovered definition in one file.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotSource {
    file: String,
    definition_hash: String,
    source_hash: Option<String>,
    /// The ledger records this exact complete entry as written by Lithe.
    owned_by_lithe: bool,
}

/// A definition merged across files by name and definition hash.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotRow {
    id: String,
    /// Definition parsed from the first source in host file order.
    definition: McpServer,
    sources: Vec<SnapshotSource>,
    /// Another global entry with the same name has a different definition.
    has_definition_conflict: bool,
    /// No global source exists; the row is owned by a project grant.
    project_only: bool,
}

/// Merges the servers of every supplied file into library rows.
///
/// Response: `{ rows, failures: [{ file, code, message }] }`. Rows share an `id`
/// of `name#definitionHash`, so the same server registered with two Agents is
/// one row while a same-name variant stays separate and is flagged as a global
/// definition conflict. Rows are ordered by natural, case-insensitive name,
/// then global before project-only, then definition hash. A file that fails to
/// parse is reported without echoing its content and contributes no rows.
pub fn library_snapshot(payload: Value) -> Result<Value, CoreError> {
    let request: SnapshotRequest = decode(payload)?;
    bounded(&request.files)?;
    let mut rows: Vec<SnapshotRow> = Vec::new();
    let mut global_hashes: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut failures = Vec::new();
    for file in &request.files {
        let servers = match file.servers(file.content.as_deref().unwrap_or("")) {
            Ok(servers) => servers,
            Err(error) => {
                failures.push(json!({
                    "file": file.id, "code": error.code, "message": error.message,
                }));
                continue;
            }
        };
        for server in servers {
            let id = format!("{}#{}", server.name, server.definition_hash);
            let source = SnapshotSource {
                file: file.id.clone(),
                definition_hash: server.definition_hash.clone(),
                source_hash: server.source_hash.clone(),
                owned_by_lithe: server
                    .source_hash
                    .as_deref()
                    .is_some_and(|hash| file.ledger_owns(&server.name, hash)),
            };
            if file.is_global() {
                global_hashes
                    .entry(server.name.clone())
                    .or_default()
                    .insert(server.definition_hash.clone());
            }
            match rows.iter_mut().find(|row| row.id == id) {
                Some(row) => {
                    row.project_only &= !file.is_global();
                    row.sources.push(source);
                }
                None => rows.push(SnapshotRow {
                    id,
                    definition: server,
                    sources: vec![source],
                    has_definition_conflict: false,
                    project_only: !file.is_global(),
                }),
            }
        }
    }
    for row in &mut rows {
        row.has_definition_conflict = global_hashes
            .get(&row.definition.name)
            .is_some_and(|hashes| hashes.len() > 1);
    }
    rows.sort_by(|left, right| {
        natural_compare(&left.definition.name, &right.definition.name)
            .then(left.project_only.cmp(&right.project_only))
            .then_with(|| {
                left.definition
                    .definition_hash
                    .cmp(&right.definition.definition_hash)
            })
    });
    Ok(json!({ "rows": rows, "failures": failures }))
}

/// Finder-like ordering: case-insensitive, digit runs compared numerically,
/// with a byte comparison as the final tie-break so the order is total.
fn natural_compare(left: &str, right: &str) -> Ordering {
    let mut a = left.chars().peekable();
    let mut b = right.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return left.cmp(right),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let take = |chars: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(c);
                        chars.next();
                    }
                    digits
                };
                let (x, y) = (take(&mut a), take(&mut b));
                let (x, y) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
                let order = x.len().cmp(&y.len()).then_with(|| x.cmp(y));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

// MARK: - Draft validation

/// Editor state for one server. Only the active transport's fields are written.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Draft {
    #[serde(default)]
    name: String,
    transport: McpTransport,
    #[serde(default)]
    command: String,
    #[serde(default)]
    url: String,
    /// Exact argv; the host owns the line-editor projection.
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default)]
    env: Vec<McpKeyValue>,
    #[serde(default)]
    headers: Vec<McpKeyValue>,
    /// Agent identities (`codex`, `claude`) the server should be enabled in.
    #[serde(default)]
    enabled_agents: Vec<String>,
    /// Featured template requirement still under review.
    #[serde(default)]
    setup: Option<DraftSetup>,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum DraftSetup {
    BearerToken,
    AllowedDirectories,
}

/// One field-level reason a draft cannot be saved.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct DraftIssue {
    /// Draft field: `name`, `enabledAgents`, `env`, `headers`, `command`,
    /// `url` or `arguments`.
    field: &'static str,
    /// Stable code the host localizes.
    code: &'static str,
}

const fn issue(field: &'static str, code: &'static str) -> DraftIssue {
    DraftIssue { field, code }
}

impl Draft {
    /// Issues in display priority; hosts show the first one.
    fn issues(&self) -> Vec<DraftIssue> {
        let mut issues = Vec::new();
        let name = self.name.trim();
        if name.is_empty() {
            issues.push(issue("name", "nameRequired"));
        } else if !valid_name(name) {
            issues.push(issue("name", "nameInvalid"));
        }
        if self.enabled_agents.is_empty() {
            issues.push(issue("enabledAgents", "agentsRequired"));
        }
        // Entries become an object or table, which cannot repeat a key. Only
        // the active transport's entries are written, so only they can collide.
        let (field, entries) = self.active_entries();
        if has_duplicate_keys(entries) {
            issues.push(issue(field, "duplicateKeys"));
        }
        match self.transport {
            McpTransport::Stdio if self.command.trim().is_empty() => {
                issues.push(issue("command", "commandRequired"));
            }
            McpTransport::Http | McpTransport::Sse if !complete_url(self.url.trim()) => {
                issues.push(issue("url", "urlInvalid"));
            }
            _ => {}
        }
        match self.setup {
            Some(DraftSetup::BearerToken) if !self.has_bearer_header() => {
                issues.push(issue("headers", "bearerTokenRequired"));
            }
            Some(DraftSetup::AllowedDirectories) if !self.has_allowed_directories() => {
                issues.push(issue("arguments", "allowedDirectoriesRequired"));
            }
            _ => {}
        }
        issues
    }

    fn active_entries(&self) -> (&'static str, &[McpKeyValue]) {
        match self.transport {
            McpTransport::Stdio => ("env", &self.env),
            McpTransport::Http | McpTransport::Sse => ("headers", &self.headers),
        }
    }

    fn has_bearer_header(&self) -> bool {
        if self.transport == McpTransport::Stdio {
            return false;
        }
        let value = self
            .headers
            .iter()
            .find(|entry| entry.key.eq_ignore_ascii_case("authorization"))
            .map_or("", |entry| entry.value.as_str());
        let parts: Vec<&str> = value.split_whitespace().collect();
        parts.len() == 2 && parts[0].eq_ignore_ascii_case("bearer")
    }

    /// Filesystem's fixed arguments are the runner flag and package; every
    /// later argument must be an absolute folder.
    fn has_allowed_directories(&self) -> bool {
        let folders = self.arguments.get(2..).unwrap_or_default();
        self.transport == McpTransport::Stdio
            && !folders.is_empty()
            && folders.iter().all(|folder| absolute_path(folder))
    }

    /// Normalized definition written to every enabled Agent. Fields unused by
    /// the transport are dropped so the written entry hashes like the draft.
    fn definition(&self) -> McpServer {
        let keep = |entries: &[McpKeyValue]| {
            entries
                .iter()
                .filter(|entry| !entry.key.trim().is_empty())
                .cloned()
                .collect::<Vec<_>>()
        };
        let name = self.name.trim().to_string();
        match self.transport {
            McpTransport::Stdio => McpServer::new(
                name,
                self.transport,
                Some(self.command.trim().to_string()),
                self.arguments.clone(),
                keep(&self.env),
                None,
                Vec::new(),
            ),
            McpTransport::Http | McpTransport::Sse => McpServer::new(
                name,
                self.transport,
                None,
                Vec::new(),
                Vec::new(),
                Some(self.url.trim().to_string()),
                keep(&self.headers),
            ),
        }
    }
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Empty keys are dropped when saving, so only written names can collide.
fn has_duplicate_keys(entries: &[McpKeyValue]) -> bool {
    let mut keys = BTreeSet::new();
    entries
        .iter()
        .filter(|entry| !entry.key.trim().is_empty())
        .any(|entry| !keys.insert(entry.key.as_str()))
}

fn complete_url(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|parsed| parsed.host_str().is_some_and(|host| !host.is_empty()))
}

/// POSIX absolute paths plus Windows drive and UNC paths, independent of the
/// platform Core runs on, so the same draft validates identically everywhere.
fn absolute_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    path.starts_with('/')
        || path.starts_with("\\\\")
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'\\' | b'/'))
}

#[derive(Deserialize)]
struct ValidateRequest {
    draft: Draft,
}

/// Validates one editor draft.
///
/// Response: `{ issues: [{ field, code }], definition }`. `issues` is ordered by
/// display priority; `definition` is the normalized server a save would write,
/// or `null` while issues remain. Values are never echoed in issues.
pub fn validate_draft(payload: Value) -> Result<Value, CoreError> {
    let request: ValidateRequest = decode(payload)?;
    let issues = request.draft.issues();
    let definition = issues.is_empty().then(|| request.draft.definition());
    Ok(json!({ "issues": issues, "definition": definition }))
}

// MARK: - Batch planning

/// Source captured when the editor opened; never refreshed afterwards.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OriginalSource {
    file: String,
    #[serde(default)]
    source_hash: Option<String>,
    #[serde(default)]
    owned_by_lithe: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Original {
    name: String,
    /// Global sources of the edited row.
    #[serde(default)]
    sources: Vec<OriginalSource>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum Intent {
    /// Create or update a server in every enabled Agent's global file.
    Save {
        draft: Draft,
        #[serde(default)]
        original: Option<Original>,
    },
    /// Add or remove one definition in one Agent's global file.
    #[serde(rename_all = "camelCase")]
    SetAgent {
        definition: McpServer,
        agent: String,
        enabled: bool,
    },
    /// Remove a server from the listed global files.
    Delete { name: String, files: Vec<String> },
}

#[derive(Deserialize)]
struct BatchRequest {
    files: Vec<LibraryFile>,
    intent: Intent,
}

enum Operation {
    /// `expected` is the complete source version shown when editing.
    Set {
        server: McpServer,
        expected: Option<String>,
        previous: Option<String>,
    },
    /// `expected` authorizes removing the displayed original during a rename.
    Remove {
        name: String,
        expected: Option<String>,
    },
}

/// Why the batch was refused before any file was touched.
struct Rejection {
    /// `notOwned`, `externallyModified` or `agentHasNoGlobalConfiguration`.
    code: &'static str,
    name: String,
    /// File whose plan conflicted; absent for draft-level ownership checks.
    file: Option<String>,
}

impl Rejection {
    fn new(code: &'static str, name: &str, file: Option<&str>) -> Self {
        Self {
            code,
            name: name.to_string(),
            file: file.map(str::to_string),
        }
    }

    fn into_value(self) -> Value {
        json!({ "status": "rejected", "rejection": {
            "code": self.code, "name": self.name, "file": self.file,
        }})
    }
}

/// Plans a library edit across files as one all-or-nothing batch.
///
/// Response is one of:
/// - `{ status: "invalid", issues }` when a save draft fails validation;
/// - `{ status: "rejected", rejection: { code, name, file } }` when ownership or
///   a captured source version forbids the edit. Conflicts from `mcp.planWrite`
///   use its codes (`ownedByUser` is reported as `notOwned`);
/// - `{ status: "ready", changes: [{ file, changed, content?, owned, renames }] }`
///   listing every file with operations in host order. `content` is present
///   only when `changed`; `owned` is the file's complete next ledger (the input
///   ledger when unchanged), to be stored only after every changed file was
///   written; `renames` lists
///   `{ from, to }` moves the host forwards to per-name state.
pub fn batch_plan(payload: Value) -> Result<Value, CoreError> {
    let request: BatchRequest = decode(payload)?;
    bounded(&request.files)?;
    let operations = match operations(&request.files, &request.intent) {
        Ok(operations) => operations,
        Err(Ok(issues)) => return Ok(json!({ "status": "invalid", "issues": issues })),
        Err(Err(rejection)) => return Ok(rejection.into_value()),
    };
    let mut changes = Vec::new();
    for file in &request.files {
        let file_operations: Vec<&Operation> = operations
            .iter()
            .filter(|(id, _)| *id == file.id)
            .map(|(_, operation)| operation)
            .collect();
        if file_operations.is_empty() {
            continue;
        }
        match plan_file(file, &file_operations)? {
            Ok(change) => changes.push(change),
            Err(rejection) => return Ok(rejection.into_value()),
        }
    }
    Ok(json!({ "status": "ready", "changes": changes }))
}

type Planned = Result<Vec<(String, Operation)>, Result<Vec<DraftIssue>, Rejection>>;

/// Expands an intent into ordered per-file operations.
fn operations(files: &[LibraryFile], intent: &Intent) -> Planned {
    let global = |agent: &str| {
        files
            .iter()
            .find(|file| file.is_global() && file.source == agent)
    };
    match intent {
        Intent::Save { draft, original } => {
            let issues = draft.issues();
            if !issues.is_empty() {
                return Err(Ok(issues));
            }
            save_operations(files, draft, original.as_ref()).map_err(Err)
        }
        Intent::SetAgent {
            definition,
            agent,
            enabled,
        } => {
            let Some(file) = global(agent) else {
                return Err(Err(Rejection::new(
                    "agentHasNoGlobalConfiguration",
                    &definition.name,
                    None,
                )));
            };
            let operation = if *enabled {
                Operation::Set {
                    server: definition.clone(),
                    expected: None,
                    previous: None,
                }
            } else {
                Operation::Remove {
                    name: definition.name.clone(),
                    expected: None,
                }
            };
            Ok(vec![(file.id.clone(), operation)])
        }
        Intent::Delete { name, files: ids } => {
            if ids.is_empty() {
                return Err(Err(Rejection::new("notOwned", name, None)));
            }
            Ok(ids
                .iter()
                .map(|id| {
                    (
                        id.clone(),
                        Operation::Remove {
                            name: name.clone(),
                            expected: None,
                        },
                    )
                })
                .collect())
        }
    }
}

fn save_operations(
    files: &[LibraryFile],
    draft: &Draft,
    original: Option<&Original>,
) -> Result<Vec<(String, Operation)>, Rejection> {
    let definition = draft.definition();
    let enabled = |agent: &str| draft.enabled_agents.iter().any(|value| value == agent);
    let file = |id: &str| files.iter().find(|file| file.id == id);
    let mut operations = Vec::new();
    let original_name = original.map(|original| original.name.as_str());
    let renaming = original_name.is_some_and(|name| name != definition.name);
    if let Some(original) = original {
        // Disabling an Agent still requires explicit ownership. The captured
        // version stays mandatory: a newer ledger entry alone must not
        // authorize removing an entry this draft never saw.
        for source in &original.sources {
            let Some(source_file) = file(&source.file) else {
                return Err(Rejection::new("externallyModified", &original.name, None));
            };
            if enabled(&source_file.source) {
                continue;
            }
            let Some(expected) = source.source_hash.as_deref() else {
                return Err(Rejection::new("notOwned", &original.name, None));
            };
            if !source_file.ledger_owns(&original.name, expected) {
                // A newer complete version, or a record this draft saw as owned
                // that is now gone, means the entry changed after capture. A
                // legacy record without a hash cannot be refreshed into
                // ownership, so it keeps the take-ownership reason.
                let changed = source.owned_by_lithe
                    || source_file
                        .owned
                        .iter()
                        .any(|entry| entry.name == original.name && entry.source_hash.is_some());
                let code = if changed {
                    "externallyModified"
                } else {
                    "notOwned"
                };
                return Err(Rejection::new(code, &original.name, None));
            }
            operations.push((
                source.file.clone(),
                Operation::Remove {
                    name: original.name.clone(),
                    expected: Some(expected.to_string()),
                },
            ));
        }
    }
    for target in files
        .iter()
        .filter(|file| file.is_global() && enabled(&file.source))
    {
        let source = original.and_then(|original| {
            original
                .sources
                .iter()
                .find(|source| source.file == target.id)
        });
        // A source version must remain the one captured when the editor opened.
        if source.is_some_and(|source| source.source_hash.is_none()) {
            return Err(Rejection::new(
                "externallyModified",
                original_name.unwrap_or(&definition.name),
                None,
            ));
        }
        let expected = source.and_then(|source| source.source_hash.clone());
        let previous = (renaming && source.is_some())
            .then(|| original_name.map(str::to_string))
            .flatten();
        operations.push((
            target.id.clone(),
            Operation::Set {
                server: definition.clone(),
                expected: expected.clone(),
                previous: previous.clone(),
            },
        ));
        // Removing the old name after the set lets Core copy the old entry,
        // including unmodeled fields, before it disappears. The displayed hash
        // authorizes removing an original Lithe did not create.
        if let Some(previous) = previous {
            operations.push((
                target.id.clone(),
                Operation::Remove {
                    name: previous,
                    expected,
                },
            ));
        }
    }
    Ok(operations)
}

/// Applies a file's operations in order, each planned against the previous
/// output, and derives the file's next ledger.
fn plan_file(
    file: &LibraryFile,
    operations: &[&Operation],
) -> Result<Result<Value, Rejection>, CoreError> {
    let source = file.content.as_deref();
    let mut content = source.unwrap_or("").to_string();
    let mut entries = file.owned.clone();
    let mut completed_renames: BTreeMap<String, String> = BTreeMap::new();
    let mut renames = Vec::new();
    let mut changed = false;
    for operation in operations {
        let request = |operation: &str,
                       server: Option<McpServer>,
                       name: Option<String>,
                       previous: Option<String>,
                       expected: Option<String>,
                       content: &str,
                       entries: &[LedgerEntry]| {
            let tool_filters = server.as_ref().and_then(|server| {
                entries
                    .iter()
                    .find(|entry| entry.name == server.name)
                    .and_then(|entry| entry.tool_filters.as_ref())
                    .and_then(|filters| filters.get(&file.path))
                    .cloned()
            });
            WriteRequest {
                source: file.source.clone(),
                scope: file.scope.clone(),
                project_path: file.project_path.clone(),
                content: Some(content.to_string()),
                operation: operation.to_string(),
                server,
                name,
                previous_name: previous,
                expected_hash: expected,
                owned: entries.iter().map(LedgerEntry::owned_entry).collect(),
                tool_filters,
            }
        };
        match operation {
            Operation::Set {
                server,
                expected,
                previous,
            } => {
                let plan = plan_write_request(&request(
                    "set",
                    Some(server.clone()),
                    None,
                    previous.clone(),
                    expected.clone(),
                    &content,
                    &entries,
                ))?;
                if let Some(conflict) = plan["conflict"].as_str() {
                    return Ok(Err(conflict_rejection(conflict, &server.name, file)));
                }
                content = plan["content"].as_str().unwrap_or_default().to_string();
                changed |= plan["changed"].as_bool().unwrap_or(false);
                if let (Some(previous), Some(expected)) = (previous, expected) {
                    // Codex moves the original while planning the set; the
                    // later removal of the old name is then already satisfied.
                    if find_server(&file.servers(&content)?, previous).is_none() {
                        completed_renames.insert(previous.clone(), expected.clone());
                    }
                }
                if let Some(hash) = plan["definitionHash"].as_str() {
                    let filters =
                        take_entry(&mut entries, &server.name).and_then(|entry| entry.tool_filters);
                    entries.push(LedgerEntry {
                        name: server.name.clone(),
                        definition_hash: hash.to_string(),
                        source_hash: plan["sourceHash"].as_str().map(str::to_string),
                        tool_filters: filters,
                    });
                }
                if let Some(previous) = previous {
                    renames.push(json!({ "from": previous, "to": server.name }));
                }
            }
            Operation::Remove { name, expected } => {
                if expected.is_some() && completed_renames.get(name) == expected.as_ref() {
                    take_entry(&mut entries, name);
                    continue;
                }
                let plan = plan_write_request(&request(
                    "remove",
                    None,
                    Some(name.clone()),
                    None,
                    expected.clone(),
                    &content,
                    &entries,
                ))?;
                if let Some(conflict) = plan["conflict"].as_str() {
                    return Ok(Err(conflict_rejection(conflict, name, file)));
                }
                content = plan["content"].as_str().unwrap_or_default().to_string();
                changed |= plan["changed"].as_bool().unwrap_or(false);
                // Ordinary removal keeps only non-secret restrictions, without a
                // source hash that could authorize a future edit.
                if plan["action"] == "removed" {
                    let mut filters = take_entry(&mut entries, name)
                        .and_then(|entry| entry.tool_filters)
                        .unwrap_or_default();
                    match serde_json::from_value::<Option<ToolFilters>>(plan["toolFilters"].clone())
                        .map_err(|_| invalid_request())?
                    {
                        Some(retained) => {
                            filters.insert(file.path.clone(), retained);
                        }
                        None => {
                            filters.remove(&file.path);
                        }
                    }
                    if let (false, Some(hash)) =
                        (filters.is_empty(), plan["definitionHash"].as_str())
                    {
                        entries.push(LedgerEntry {
                            name: name.clone(),
                            definition_hash: hash.to_string(),
                            source_hash: None,
                            tool_filters: Some(filters),
                        });
                    }
                }
            }
        }
    }
    // An unchanged file publishes nothing: an explicit no-op save of an entry
    // Lithe did not write must not adopt it into the ledger.
    if !changed {
        entries = file.owned.clone();
    }
    Ok(Ok(json!({
        "file": file.id,
        "changed": changed,
        "content": changed.then_some(content),
        "owned": entries,
        "renames": renames,
    })))
}

fn take_entry(entries: &mut Vec<LedgerEntry>, name: &str) -> Option<LedgerEntry> {
    let index = entries.iter().position(|entry| entry.name == name)?;
    let entry = entries.remove(index);
    // Any duplicate records for the name are stale and dropped as well.
    entries.retain(|entry| entry.name != name);
    Some(entry)
}

fn conflict_rejection(conflict: &str, name: &str, file: &LibraryFile) -> Rejection {
    let code = if conflict == "externallyModified" {
        "externallyModified"
    } else {
        "notOwned"
    };
    Rejection::new(code, name, Some(&file.id))
}
