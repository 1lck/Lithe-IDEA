//! Pure local ChangeList state transitions and commit-scope projection.

use super::workspace_commit::path_scope::{MembershipScope, PathScope};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const DEFAULT: &str = "default";
const MAX_ITEMS: usize = 100_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct State {
    lists: Vec<List>,
    active_id: String,
    assignments: BTreeMap<String, BTreeMap<String, String>>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct List {
    id: String,
    name: String,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    root: String,
    path: String,
    original_path: Option<String>,
    #[serde(default)]
    is_copy: bool,
}
#[derive(Deserialize)]
struct Repository {
    id: String,
    root: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    state: State,
    #[serde(default)]
    files: Vec<File>,
    #[serde(default)]
    repositories: Vec<Repository>,
    #[serde(default)]
    action: Option<Action>,
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Action {
    Move { id: String, files: Vec<File> },
    RememberRenames,
    Remove { id: String },
    Activate { id: String },
    Create { id: String, name: String },
    Rename { id: String, name: String },
}
fn invalid() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Invalid ChangeList state or action",
    )
}

pub(super) fn safe_path(path: &str) -> bool {
    path.len() <= 32_768
        && !path.is_empty()
        && !path.starts_with(['/', '\\'])
        && !path.contains('\0')
        && !path.split(['/', '\\']).any(|part| part == "..")
}

fn invalid_action() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "INVALID_CHANGELIST_ACTION")
}

/// Resolve a literal path, then its closest assigned directory. Both the
/// projection and commit guard use this rule, including explicit Default overrides.
pub(super) fn path_member<'a>(paths: &'a BTreeMap<String, String>, path: &str) -> Option<&'a str> {
    if let Some(id) = paths.get(path) {
        return Some(id);
    }
    let mut current = path.trim_end_matches('/');
    while let Some(index) = current.rfind('/') {
        if let Some(id) = paths.get(&current[..=index]) {
            return Some(id);
        }
        current = &current[..index];
    }
    None
}

impl State {
    fn validate(&self) -> Result<(), CoreError> {
        if self.lists.is_empty()
            || self.lists.len() > MAX_ITEMS
            || self.assignments.len() > MAX_ITEMS
        {
            return Err(invalid());
        }
        let mut ids = BTreeSet::new();
        for list in &self.lists {
            if list.id.is_empty()
                || !ids.insert(list.id.as_str())
                || (list.id != DEFAULT && list.name.trim().is_empty())
            {
                return Err(invalid());
            }
        }
        if !ids.contains(DEFAULT) || !ids.contains(self.active_id.as_str()) {
            return Err(invalid());
        }
        let mut count = 0usize;
        for (root, paths) in &self.assignments {
            if root.is_empty() {
                return Err(invalid());
            }
            count = count.saturating_add(paths.len());
            if count > MAX_ITEMS
                || paths
                    .iter()
                    .any(|(path, id)| !safe_path(path) || !ids.contains(id.as_str()))
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
    fn member<'a>(&'a self, file: &File) -> &'a str {
        let Some(paths) = self.assignments.get(&file.root) else {
            return DEFAULT;
        };
        if let Some(original) = file.original() {
            return path_member(paths, original).unwrap_or(DEFAULT);
        }
        path_member(paths, &file.path).unwrap_or(DEFAULT)
    }
    fn assign(&mut self, file: &File, id: &str) {
        let paths = self.assignments.entry(file.root.clone()).or_default();
        paths.insert(file.path.clone(), id.to_string());
        if let Some(original) = file.original() {
            paths.insert(original.to_string(), id.to_string());
        }
    }
    fn remember(&mut self, files: &[File]) -> Result<(), CoreError> {
        let mut updates = BTreeMap::new();
        for file in files.iter().filter(|file| file.original().is_some()) {
            let id = self.member(file).to_string();
            for path in std::iter::once(file.path.as_str()).chain(file.original()) {
                let key = (file.root.clone(), path.to_string());
                if updates.insert(key, id.clone()).is_some_and(|old| old != id) {
                    return Err(invalid());
                }
            }
        }
        for ((root, path), id) in updates {
            self.assignments.entry(root).or_default().insert(path, id);
        }
        Ok(())
    }
    fn name(&self, id: &str, raw: &str) -> Result<String, CoreError> {
        let name = raw.trim();
        if name.is_empty()
            || name.chars().count() > 100
            || self
                .lists
                .iter()
                .any(|list| list.id != id && list.name.to_lowercase() == name.to_lowercase())
        {
            return Err(invalid_action());
        }
        Ok(name.to_string())
    }
    fn apply(&mut self, action: Action, files: &[File]) -> Result<(), CoreError> {
        match action {
            Action::Move { id, files } => {
                if !self.lists.iter().any(|list| list.id == id) || files.len() > MAX_ITEMS {
                    return Err(invalid_action());
                }
                for file in &files {
                    file.validate()?;
                    self.assign(file, &id);
                }
            }
            Action::RememberRenames => self.remember(files)?,
            Action::Remove { id } => {
                if id == DEFAULT || !self.lists.iter().any(|list| list.id == id) {
                    return Err(invalid_action());
                }
                self.lists.retain(|list| list.id != id);
                if self.active_id == id {
                    self.active_id = DEFAULT.into();
                }
                for paths in self.assignments.values_mut() {
                    for list in paths.values_mut() {
                        if *list == id {
                            *list = DEFAULT.into();
                        }
                    }
                }
            }
            Action::Activate { id } => {
                if !self.lists.iter().any(|list| list.id == id) {
                    return Err(invalid_action());
                }
                self.active_id = id;
            }
            Action::Create { id, name } => {
                if id.is_empty() || self.lists.iter().any(|list| list.id == id) {
                    return Err(invalid_action());
                }
                let name = self.name(&id, &name)?;
                self.lists.push(List { id, name });
            }
            Action::Rename { id, name } => {
                if id == DEFAULT {
                    return Err(invalid_action());
                }
                let name = self.name(&id, &name)?;
                let list = self
                    .lists
                    .iter_mut()
                    .find(|list| list.id == id)
                    .ok_or_else(invalid_action)?;
                list.name = name;
            }
        }
        self.validate()
    }
    fn scope(&self, files: &[File], repositories: &[Repository]) -> Result<PathScope, CoreError> {
        let include = self.active_id != DEFAULT;
        let selected = |id: &str| {
            if include {
                id == self.active_id
            } else {
                id != DEFAULT
            }
        };
        let mut ids = BTreeMap::new();
        let mut seen_ids = BTreeSet::new();
        for repo in repositories {
            if repo.id.is_empty()
                || repo.root.is_empty()
                || !seen_ids.insert(&repo.id)
                || ids.insert(&repo.root, &repo.id).is_some()
            {
                return Err(invalid());
            }
        }
        let mut snapshot = self.clone();
        snapshot.remember(files)?;
        let mut paths: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for (root, assignments) in &snapshot.assignments {
            if let Some(id) = ids.get(root) {
                for (path, list) in assignments {
                    if selected(list) {
                        paths.entry((*id).clone()).or_default().insert(path.clone());
                    }
                }
            }
        }
        for file in files {
            let Some(id) = ids.get(&file.root) else {
                continue;
            };
            let Some(assigned) = snapshot.assignments.get(&file.root) else {
                continue;
            };
            if assigned.contains_key(&file.path)
                || file
                    .original()
                    .is_some_and(|path| assigned.contains_key(path))
            {
                continue;
            }
            if path_member(assigned, &file.path).is_some_and(selected) {
                paths
                    .entry((*id).clone())
                    .or_default()
                    .insert(file.path.clone());
            }
        }
        let mut assignments = BTreeMap::new();
        for (root, records) in &snapshot.assignments {
            if let Some(id) = ids.get(root) {
                assignments.insert((*id).clone(), records.clone());
            }
        }
        Ok(PathScope {
            include,
            paths,
            membership: Some(MembershipScope {
                active_id: snapshot.active_id,
                assignments,
            }),
        })
    }
}
impl File {
    fn original(&self) -> Option<&str> {
        if self.is_copy {
            None
        } else {
            self.original_path
                .as_deref()
                .filter(|path| !path.is_empty())
        }
    }
    fn validate(&self) -> Result<(), CoreError> {
        if self.root.is_empty()
            || !safe_path(&self.path)
            || self
                .original_path
                .as_ref()
                .is_some_and(|path| !safe_path(path))
        {
            Err(invalid())
        } else {
            Ok(())
        }
    }
}

/// Reduces one host-owned snapshot and projects list membership and commit scope.
pub(crate) fn changelists_command(payload: Value) -> Result<Value, CoreError> {
    let mut request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    request.state.validate()?;
    if request.files.len() > MAX_ITEMS || request.repositories.len() > MAX_ITEMS {
        return Err(invalid());
    }
    for file in &request.files {
        file.validate()?;
    }
    if let Some(action) = request.action {
        request.state.apply(action, &request.files)?;
    }
    let members: Vec<_> = request
        .files
        .iter()
        .map(|file| request.state.member(file))
        .collect();
    let scope = request.state.scope(&request.files, &request.repositories)?;
    Ok(json!({"state": request.state, "members": members, "scope": scope}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn state() -> Value {
        json!({"lists":[{"id":"default","name":""},{"id":"one","name":"One"},{"id":"two","name":"Two"}],"activeId":"default","assignments":{"/repo":{"dir/":"one","dir/a":"two","source":"one","dest":"default"}}})
    }
    #[test]
    fn shared_fixture_matches_the_reducer() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/changelists-reducer-v1.json"
        ))
        .unwrap();
        assert_eq!(
            changelists_command(fixture["request"].clone()).unwrap(),
            fixture["response"]
        );
    }

    #[test]
    fn removing_a_list_keeps_explicit_default_overrides_beneath_assigned_directories() {
        let result = changelists_command(json!({"state":state(),"action":{"type":"remove","id":"two"},"files":[{"root":"/repo","path":"dir/a"},{"root":"/repo","path":"dir/b"}],"repositories":[{"id":"A","root":"/repo"}]})).unwrap();
        assert_eq!(result["members"], json!(["default", "one"]));
        assert_eq!(result["state"]["assignments"]["/repo"]["dir/a"], "default");
        assert_eq!(
            result["scope"]["paths"],
            json!({"A":["dir/","dir/b","source"]})
        );
    }
    #[test]
    fn renamed_source_wins_but_copy_never_inherits_or_moves_the_source() {
        let files = json!([{"root":"/repo","path":"dest","originalPath":"source"},{"root":"/repo","path":"copy","originalPath":"source","isCopy":true}]);
        let projected = changelists_command(
            json!({"state":state(),"files":files,"repositories":[{"id":"A","root":"/repo"}]}),
        )
        .unwrap();
        assert_eq!(projected["members"], json!(["one", "default"]));
        assert_eq!(
            projected["scope"]["paths"]["A"],
            json!(["dest", "dir/", "dir/a", "source"])
        );
        let remembered = changelists_command(
            json!({"state":state(),"files":files,"action":{"type":"rememberRenames"}}),
        )
        .unwrap();
        assert_eq!(remembered["state"]["assignments"]["/repo"]["dest"], "one");
        assert!(remembered["state"]["assignments"]["/repo"]
            .get("copy")
            .is_none());
    }
    #[test]
    fn an_unassigned_rename_source_overrides_stale_destination_membership() {
        let files = json!([{"root":"/repo","path":"source","originalPath":"not-assigned"}]);
        let projected = changelists_command(
            json!({"state":state(),"files":files,"action":{"type":"rememberRenames"}}),
        )
        .unwrap();
        assert_eq!(projected["members"], json!(["default"]));
        assert_eq!(
            projected["state"]["assignments"]["/repo"]["source"],
            "default"
        );
    }

    #[test]
    fn a_rename_preserves_membership_inherited_from_the_source_directory() {
        let files = json!([{"root":"/repo","path":"dest","originalPath":"dir/b"}]);
        let projected = changelists_command(json!({"state":state(),"files":files,"action":{"type":"rememberRenames"},"repositories":[{"id":"A","root":"/repo"}]})).unwrap();
        assert_eq!(projected["members"], json!(["one"]));
        assert_eq!(projected["state"]["assignments"]["/repo"]["dest"], "one");
        assert_eq!(projected["state"]["assignments"]["/repo"]["dir/b"], "one");
    }

    #[test]
    fn lifecycle_and_repository_isolation_share_the_same_scope_rules() {
        let initial =
            json!({"lists":[{"id":"default","name":""}],"activeId":"default","assignments":{}});
        let create = changelists_command(
            json!({"state":initial,"action":{"type":"create","id":"local","name":"  Local  "}}),
        )
        .unwrap();
        assert_eq!(create["state"]["lists"][1]["name"], "Local");
        let file = json!({"root":"/A","path":"config.yaml"});
        let moved = changelists_command(json!({"state":create["state"],"action":{"type":"move","id":"local","files":[file]},"files":[file,{"root":"/B","path":"config.yaml"}],"repositories":[{"id":"A","root":"/A"},{"id":"B","root":"/B"}]})).unwrap();
        assert_eq!(moved["members"], json!(["local", "default"]));
        assert_eq!(moved["scope"]["paths"], json!({"A":["config.yaml"]}));
        let activated = changelists_command(json!({"state":moved["state"],"action":{"type":"activate","id":"local"},"files":[file],"repositories":[{"id":"A","root":"/A"}]})).unwrap();
        assert_eq!(activated["scope"]["paths"], json!({"A":["config.yaml"]}));
        let removed = changelists_command(json!({"state":activated["state"],"action":{"type":"remove","id":"local"},"files":[file]})).unwrap();
        assert_eq!(removed["state"]["activeId"], "default");
        assert_eq!(removed["members"], json!(["default"]));
        assert_eq!(
            removed["state"]["assignments"]["/A"]["config.yaml"],
            "default"
        );
    }

    #[test]
    fn copy_move_never_changes_source_and_commit_scope_keeps_literal_special_names() {
        let file = json!({"root":"/repo","path":"copy[1]","originalPath":"source","isCopy":true});
        let result = changelists_command(json!({"state":state(),"action":{"type":"move","id":"two","files":[file]},"files":[file],"repositories":[{"id":"__proto__","root":"/repo"}]})).unwrap();
        assert_eq!(result["state"]["assignments"]["/repo"]["source"], "one");
        assert_eq!(result["state"]["assignments"]["/repo"]["copy[1]"], "two");
        assert!(result["scope"]["paths"]["__proto__"]
            .as_array()
            .unwrap()
            .contains(&json!("copy[1]")));
    }

    #[test]
    fn ambiguous_renames_with_conflicting_membership_fail_closed() {
        let files = json!([
            {"root":"/repo","path":"shared","originalPath":"source"},
            {"root":"/repo","path":"shared","originalPath":"dir/a"}
        ]);
        assert!(changelists_command(
            json!({"state":state(),"files":files,"action":{"type":"rememberRenames"}})
        )
        .is_err());
    }

    #[test]
    fn invalid_metadata_and_actions_fail_closed() {
        let mut bad = state();
        bad["assignments"]["/repo"]["dir/a"] = json!("missing");
        assert!(changelists_command(json!({"state":bad})).is_err());
        assert!(changelists_command(
            json!({"state":state(),"action":{"type":"remove","id":"default"}})
        )
        .is_err());
        assert!(changelists_command(
            json!({"state":state(),"action":{"type":"create","id":"three","name":" one "}})
        )
        .is_err());
    }
}
