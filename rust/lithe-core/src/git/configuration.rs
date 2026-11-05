//! Allowlisted Git configuration inspection, provenance, and explicit scoped edits.

use super::{
    capture_git_with_options, execute_git, execution_events, execution_policy, fetch, rewrite,
    validate_root,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

const EDITABLE: &[(&str, &[&str])] = &[
    ("fetch.prune", &["true", "false"]),
    ("fetch.prunetags", &["true", "false"]),
    ("fetch.recursesubmodules", &["false", "true", "on-demand"]),
    ("pull.rebase", &["false", "true", "merges"]),
    ("pull.ff", &["true", "false", "only"]),
    (
        "push.default",
        &["simple", "current", "upstream", "matching", "nothing"],
    ),
    ("credential.usehttppath", &["true", "false"]),
    ("lithe.fetch.prune", &["true", "false"]),
    (
        "lithe.fetch.submodules",
        &["inherit", "no", "onDemand", "yes"],
    ),
    ("lithe.fetch.tags", &["inherit", "all", "none", "prune"]),
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Scope is the destination of an explicit edit, not a change to inspection precedence.
struct Request {
    root: String,
    #[serde(default = "local_scope")]
    scope: String,
    key: Option<String>,
    value: Option<String>,
    /// Values last observed in the selected file. Concurrent edits require reload.
    expected_values: Option<Vec<String>>,
}
fn local_scope() -> String {
    "local".into()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Reads one remote URL for repository discovery, independently of user commands.
struct RemoteUrlRequest {
    root: String,
    remote: String,
}

/// Missing remote configuration is a successful lookup with a null URL.
/// Real inspection failures still propagate through the request's error event.
pub(crate) fn remote_url(payload: Value) -> Result<Value, CoreError> {
    let request: RemoteUrlRequest = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid Git remote URL request")
            .with_details(error.to_string())
    })?;
    if request.remote.is_empty() || request.remote.chars().any(char::is_control) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git remote name",
        ));
    }
    let root = validate_root(&request.root)?;
    let url = super::read_git_config_value(&root, &format!("remote.{}.url", request.remote))?;
    Ok(json!({ "url": url }))
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// A config occurrence in Git's original precedence order. Values are diagnostic-safe.
struct Entry {
    key: String,
    value: String,
    scope: String,
    origin: String,
    effective: bool,
}

fn read(root: &str, args: &[&str]) -> Result<(i32, Vec<u8>), CoreError> {
    let args = args.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let output = capture_git_with_options(root, &args, None, true)?;
    if ![0, 1].contains(&output.exit_code) {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect Git configuration",
        )
        .with_details(execution_events::redact(&String::from_utf8_lossy(
            &output.stderr,
        ))));
    }
    Ok((output.exit_code, output.stdout))
}

fn readable(key: &str) -> bool {
    EDITABLE.iter().any(|(name, _)| key == *name)
        || matches!(
            key,
            "credential.helper" | "core.sshcommand" | "core.askpass"
        )
        || (key.starts_with("remote.")
            && [
                ".url",
                ".prune",
                ".prunetags",
                ".tagopt",
                ".skipfetchall",
                ".fetch",
            ]
            .iter()
            .any(|suffix| key.ends_with(suffix)))
}

fn entries(bytes: &[u8]) -> Result<Vec<Entry>, CoreError> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| CoreError::new(ErrorCode::ParseFailed, "Git configuration is not UTF-8"))?;
    let parts = text.split_terminator('\0').collect::<Vec<_>>();
    if parts.len() % 3 != 0 {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Git configuration provenance is malformed",
        ));
    }
    let mut result: Vec<Entry> = Vec::new();
    for part in parts.chunks_exact(3) {
        let (key, value) = part[2].split_once('\n').unwrap_or((part[2], "true"));
        let key = key.to_string();
        if !readable(&key) {
            continue;
        }
        let additive_remote_fetch = key.starts_with("remote.") && key.ends_with(".fetch");
        if (key != "credential.helper" || value.is_empty())
            && (!additive_remote_fetch || value.is_empty())
        {
            for previous in &mut result {
                if previous.key == key {
                    previous.effective = false;
                }
            }
        }
        result.push(Entry {
            key: key.clone(),
            value: match key.as_str() {
                "core.sshcommand" => "<custom SSH command>".into(),
                "credential.helper"
                    if value.starts_with('!') || value.contains(char::is_whitespace) =>
                {
                    "<custom credential helper>".into()
                }
                _ => execution_events::redact(value),
            },
            scope: part[0].into(),
            origin: execution_events::redact(part[1]),
            effective: true,
        });
    }
    Ok(result)
}

/// Canonicalizes remote booleans with Git's parser, as Fetch does, for both
/// tag pruning and the `skipFetchAll` remote filter.
/// Raw selected-file values remain separate for optimistic editing.
fn normalize_remote_booleans(root: &str, entries: &mut [Entry]) -> Result<Vec<String>, CoreError> {
    let keys: BTreeSet<String> = entries
        .iter()
        .filter(|entry| {
            matches!(entry.key.as_str(), "fetch.prune" | "fetch.prunetags")
                || (entry.key.starts_with("remote.")
                    && (entry.key.ends_with(".prune")
                        || entry.key.ends_with(".prunetags")
                        || entry.key.ends_with(".skipfetchall")))
        })
        .map(|entry| entry.key.clone())
        .collect();
    let mut invalid = Vec::new();
    for key in keys {
        let output = capture_git_with_options(
            root,
            &[
                "config".into(),
                "--type=bool".into(),
                "--get-all".into(),
                key.clone(),
            ],
            None,
            true,
        )?;
        // Git rejects any malformed occurrence, including one shadowed by a
        // later value. Keep raw values editable and report the unknown effect.
        if output.exit_code != 0 {
            invalid.push(key);
            continue;
        }
        let values = std::str::from_utf8(&output.stdout)
            .map_err(|_| CoreError::new(ErrorCode::ParseFailed, "Git boolean output is not UTF-8"))?
            .lines()
            .collect::<Vec<_>>();
        let matching: Vec<_> = entries
            .iter_mut()
            .filter(|entry| entry.key == key)
            .collect();
        if values.len() != matching.len() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git configuration changed during inspection",
            ));
        }
        for (entry, value) in matching.into_iter().zip(values) {
            if !matches!(value, "true" | "false") {
                return Err(CoreError::new(
                    ErrorCode::ParseFailed,
                    "Git returned an invalid remote boolean",
                ));
            }
            entry.value = value.into();
        }
    }
    Ok(invalid)
}

fn scoped_values(root: &str, scope: &str, key: &str) -> Result<Vec<String>, CoreError> {
    let flag = if scope == "local" {
        "--local"
    } else {
        "--global"
    };
    let (_, output) = read(
        root,
        &["config", flag, "--no-includes", "--null", "--get-all", key],
    )?;
    let text = String::from_utf8(output)
        .map_err(|_| CoreError::new(ErrorCode::ParseFailed, "Git configuration is not UTF-8"))?;
    Ok(text.split_terminator('\0').map(str::to_string).collect())
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct BehaviorSource {
    scope: String,
    origin: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct TagBehavior {
    /// `reachable`, `all`, `none`, `prune`, `custom`, `remoteDependent`, or `unavailable`.
    value: &'static str,
    source: Option<BehaviorSource>,
    /// `git`, `lithe`, or `multiple`, used when no single source is available.
    basis: &'static str,
    /// Why a concrete behavior cannot be reported.
    reason_code: Option<&'static str>,
}

impl TagBehavior {
    fn new(value: &'static str, source: Option<&Entry>, basis: &'static str) -> Self {
        Self {
            value,
            source: source.map(|entry| BehaviorSource {
                scope: entry.scope.clone(),
                origin: entry.origin.clone(),
            }),
            basis,
            reason_code: None,
        }
    }
    fn unavailable(reason: &'static str) -> Self {
        Self {
            value: "unavailable",
            source: None,
            basis: "git",
            reason_code: Some(reason),
        }
    }
}

fn refspec_may_touch_tags(value: &str) -> bool {
    let value = value.strip_prefix(['+', '^']).unwrap_or(value);
    value.split(':').any(|side| {
        let prefix = side.split('*').next().unwrap_or("");
        !prefix.is_empty() && ("refs/tags/".starts_with(prefix) || prefix.starts_with("refs/tags/"))
    })
}

/// Uses Git-normalized source facts and the exact Fetch options; performs no I/O.
fn resolved_fetch_behavior(
    entries: &[Entry],
    options: &fetch::GitFetchOptions,
    invalid_keys: &[String],
) -> Value {
    let unavailable = |reason| json!({"tags": TagBehavior::unavailable(reason)});
    // Git parses these boolean settings while loading remote configuration,
    // even when another occurrence or another remote would otherwise win.
    if !invalid_keys.is_empty() {
        return unavailable("invalidConfiguration");
    }
    let effective = |key: &str| {
        entries
            .iter()
            .rev()
            .find(|entry| entry.effective && entry.key == key)
    };
    let mut remotes: BTreeSet<String> = entries
        .iter()
        .filter(|entry| {
            entry.effective
                && !entry.value.is_empty()
                && entry.key.starts_with("remote.")
                && entry.key.ends_with(".url")
        })
        .map(|entry| entry.key["remote.".len()..entry.key.len() - ".url".len()].to_string())
        .collect();
    if let Some(remote) = options.remote.as_deref() {
        if !remotes.contains(remote) {
            return unavailable("noRemotes");
        }
        remotes.retain(|candidate| candidate == remote);
    } else {
        remotes.retain(|remote| {
            effective(&format!("remote.{remote}.skipfetchall"))
                .is_none_or(|entry| entry.value != "true")
        });
    }
    if remotes.is_empty() {
        return unavailable("noRemotes");
    }
    let global_prune_tags = effective("fetch.prunetags");
    let lithe_source = effective("lithe.fetch.tags");
    let mut resolved = Vec::new();
    for remote in remotes {
        let fetch_key = format!("remote.{remote}.fetch");
        let tag_refspecs: Vec<&Entry> = entries
            .iter()
            .filter(|entry| {
                entry.effective && entry.key == fetch_key && refspec_may_touch_tags(&entry.value)
            })
            .collect();
        if let Some(custom) = tag_refspecs.iter().find(|entry| {
            entry.value.strip_prefix('+').unwrap_or(&entry.value) != "refs/tags/*:refs/tags/*"
        }) {
            resolved.push(TagBehavior::new("custom", Some(custom), "git"));
            continue;
        }
        if options.tags == fetch::GitFetchTags::Prune {
            resolved.push(TagBehavior::new("prune", lithe_source, "lithe"));
            continue;
        }
        let remote_prune = effective(&format!("remote.{remote}.prunetags"));
        let inherited_prune = remote_prune.or(global_prune_tags);
        let forced = tag_refspecs
            .first()
            .copied()
            .or_else(|| inherited_prune.filter(|entry| entry.value == "true"));
        if let Some(source) = forced {
            resolved.push(TagBehavior::new(
                if options.prune { "prune" } else { "all" },
                Some(source),
                "git",
            ));
            continue;
        }
        let behavior = match options.tags {
            fetch::GitFetchTags::Prune => TagBehavior::new("prune", lithe_source, "lithe"),
            fetch::GitFetchTags::All => TagBehavior::new("all", lithe_source, "lithe"),
            fetch::GitFetchTags::None => TagBehavior::new("none", lithe_source, "lithe"),
            fetch::GitFetchTags::Inherit => {
                let tagopt = effective(&format!("remote.{remote}.tagopt"));
                match tagopt.map(|entry| entry.value.as_str()) {
                    Some("--no-tags") => TagBehavior::new("none", tagopt, "git"),
                    Some("--tags") => TagBehavior::new("all", tagopt, "git"),
                    _ => TagBehavior::new("reachable", None, "git"),
                }
            }
        };
        resolved.push(behavior);
    }
    let first = &resolved[0];
    let tags = if resolved.iter().all(|entry| entry.value == first.value) {
        if resolved.iter().all(|entry| entry == first) {
            first.clone()
        } else {
            TagBehavior::new(first.value, None, "multiple")
        }
    } else {
        TagBehavior::new("remoteDependent", None, "multiple")
    };
    json!({"tags": tags})
}

/// Repository preferences override application defaults; supplied one-time options win.
pub(super) fn fetch_options(
    root: &str,
    one_time: Option<fetch::GitFetchOptions>,
) -> Result<fetch::GitFetchOptions, CoreError> {
    if let Some(options) = one_time {
        fetch::arguments(&options)?;
        return Ok(options);
    }
    let mut options = execution_policy::current().fetch_defaults;
    for (key, _) in EDITABLE
        .iter()
        .filter(|(key, _)| key.starts_with("lithe.fetch."))
    {
        // Runtime preferences follow local includes; editing still targets only
        // the explicitly selected file via scoped_values(--no-includes).
        let (_, bytes) = read(
            root,
            &[
                "config",
                "--local",
                "--includes",
                "--null",
                "--get-all",
                key,
            ],
        )?;
        let text = std::str::from_utf8(&bytes).map_err(|_| {
            CoreError::new(ErrorCode::ParseFailed, "Git configuration is not UTF-8")
        })?;
        if let Some(value) = text.split_terminator('\0').last() {
            match *key {
                "lithe.fetch.prune" => {
                    options.prune = match value {
                        "true" => true,
                        "false" => false,
                        _ => return Err(invalid_value()),
                    }
                }
                "lithe.fetch.tags" => {
                    options.tags =
                        serde_json::from_value(json!(value)).map_err(|_| invalid_value())?
                }
                "lithe.fetch.submodules" => {
                    options.submodules =
                        serde_json::from_value(json!(value)).map_err(|_| invalid_value())?
                }
                _ => (),
            }
        }
    }
    fetch::arguments(&options)?;
    Ok(options)
}
fn invalid_value() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Unsupported Git configuration value; reload or clear the override",
    )
}

/// Reads provenance or edits one allowlisted field after an explicit user Save action.
pub(crate) fn dispatch(payload: Value, save: bool) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git configuration request",
        )
    })?;
    let root = validate_root(&request.root)?;
    if !matches!(request.scope.as_str(), "local" | "global") {
        return Err(invalid_value());
    }
    if save {
        let key = request
            .key
            .as_deref()
            .ok_or_else(invalid_value)?
            .to_ascii_lowercase();
        let (_, choices) = EDITABLE
            .iter()
            .find(|(name, _)| *name == key)
            .ok_or_else(invalid_value)?;
        if key.starts_with("lithe.") && request.scope != "local" {
            return Err(invalid_value());
        }
        if request
            .value
            .as_ref()
            .is_some_and(|value| !choices.contains(&value.as_str()))
        {
            return Err(invalid_value());
        }
        let _lease = rewrite::RewriteLease::acquire(&root)?;
        if request.expected_values.as_ref() != Some(&scoped_values(&root, &request.scope, &key)?) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git configuration changed; reload before saving",
            ));
        }
        // Each save is a single Git config transaction; no multi-file partial commit.
        let mut args = vec![
            "config".into(),
            format!("--{}", request.scope),
            if request.value.is_some() {
                "--replace-all"
            } else {
                "--unset-all"
            }
            .into(),
            "--".into(),
            key,
        ];
        if let Some(value) = request.value {
            args.push(value);
        }
        let output = execute_git(&root, &args, None)?;
        if output.exit_code != 0 && !(args[2] == "--unset-all" && output.exit_code == 5) {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not save Git configuration",
            )
            .with_details(execution_events::redact(&output.stderr)));
        }
    }
    inspect(&root, &request.scope)
}

/// Resolves the host-selected or PATH Git and probes its version.
///
/// Executable resolution is independent of a repository, so the settings page
/// can echo the effective Git before a project is open. The version probe is
/// best effort: a binary that starts but cannot report a version still stays
/// selected.
pub(crate) fn locate_executable() -> Result<Value, CoreError> {
    if let Some(host) = crate::remote::workspace::current() {
        let params =
            super::remote_process::parameters(&host, "/", &["--version".into()], false, true, &[])?;
        return Ok(json!({"executable": params.argv.first(),
            "version": host.connection.git_tool.lock().unwrap_or_else(|error| error.into_inner()).as_ref().map(|(_, version)| version.clone())}));
    }
    let selected = execution_policy::current().executable;
    let resolved = lithe_git_host::configuration::executable(selected.as_deref());
    let version = resolved.as_ref().and_then(|path| {
        lithe_git_host::configuration::version(path.as_os_str(), || false)
            .ok()
            .map(|version| version.trim().to_owned())
    });
    Ok(json!({
        "executable": resolved.map(|path| path.to_string_lossy().into_owned()),
        "version": version,
    }))
}

fn inspect(root: &str, scope: &str) -> Result<Value, CoreError> {
    let (_, version) = read(root, &["--version"])?;
    let (_, output) = read(
        root,
        &[
            "config",
            "--null",
            "--show-origin",
            "--show-scope",
            "--list",
        ],
    )?;
    let mut entries = entries(&output)?;
    let invalid_booleans = normalize_remote_booleans(root, &mut entries)?;
    let mut fields = Vec::new();
    for (key, choices) in EDITABLE {
        if scope == "global" && key.starts_with("lithe.") {
            continue;
        }
        fields.push(json!({ "key": key, "choices": choices, "configuredValues": scoped_values(root, scope, key)? }));
    }
    let options = execution_policy::current();
    let effective_fetch = fetch_options(root, None);
    let resolved_fetch = effective_fetch
        .as_ref()
        .ok()
        .map(|options| resolved_fetch_behavior(&entries, options, &invalid_booleans));
    let mut fetch_sources = serde_json::Map::new();
    for field in ["prune", "submodules", "tags"] {
        let key = format!("lithe.fetch.{field}");
        let source = entries
            .iter()
            .rev()
            .find(|entry| entry.key == key && entry.scope == "local")
            .map(|entry| json!({"scope": entry.scope, "origin": entry.origin}))
            .unwrap_or_else(|| json!({"scope": "application", "origin": null}));
        fetch_sources.insert(field.into(), source);
    }
    let executable = locate_executable()?["executable"].clone();
    Ok(json!({ "executable": executable,
        "version": String::from_utf8_lossy(&version).trim(), "scope": scope, "entries": entries, "fields": fields,
        "temporaryConfig": execution_policy::temporary_config(),
        "fetchSources": fetch_sources, "fetchOptions": effective_fetch.as_ref().ok(), "fetchError": effective_fetch.as_ref().err(),
        "resolvedFetchBehavior": resolved_fetch,
        "credentialHelperEnabled": options.use_credential_helper,
        "interactiveAuthentication": options.interactive }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resolved_fetch_behavior_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/fetch-behavior-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let entries: Vec<Entry> =
                serde_json::from_value(case["request"]["entries"].clone()).unwrap();
            let options: fetch::GitFetchOptions =
                serde_json::from_value(case["request"]["options"].clone()).unwrap();
            let invalid: Vec<String> =
                serde_json::from_value(case["request"]["invalidKeys"].clone()).unwrap();
            assert_eq!(
                resolved_fetch_behavior(&entries, &options, &invalid),
                case["expected"],
                "{}",
                case["name"]
            );
        }
    }
    #[test]
    fn locating_git_rejects_a_missing_selected_executable_without_a_repository() {
        // The settings page must distinguish "no runnable Git" from a blank
        // field; a bogus override is the same deterministic failure everywhere.
        let missing =
            std::env::temp_dir().join(format!("lithe-missing-git-{}", std::process::id()));
        let options = execution_policy::GitExecutionOptions {
            executable: Some(missing.to_string_lossy().into_owned()),
            ..Default::default()
        };
        let _scope = execution_policy::Scope::begin(Some(options)).expect("valid policy");
        let result = locate_executable().unwrap();
        assert!(result["executable"].is_null());
        assert!(result["version"].is_null());
    }

    #[test]
    fn remote_url_rejects_invalid_requests_before_accessing_a_repository() {
        for remote in ["", "origin\nother", "origin\0"] {
            let error = remote_url(json!({ "root": "/fixture", "remote": remote })).unwrap_err();
            assert!(matches!(error.code, ErrorCode::InvalidRequest));
        }
        assert!(remote_url(json!({ "root": "/fixture" })).is_err());
        assert!(remote_url(
            json!({ "root": "/fixture", "remote": "origin", "arguments": ["push"] })
        )
        .is_err());
    }

    #[test]
    fn provenance_retains_precedence_and_redacts_credentials_without_exposing_unrelated_config() {
        let records = entries(b"global\0file:global.conf\0fetch.prune\nfalse\0local\0file:.git/config\0fetch.prune\ntrue\0local\0file:.git/config\0remote.origin.url\nhttps://user:fake@example.invalid/repo?token=private\0local\0file:.git/config\0unrelated.secret\nhidden\0").unwrap();
        assert_eq!(records.len(), 3);
        assert!(!records[0].effective);
        assert!(records[1].effective);
        assert_eq!(records[1].scope, "local");
        let json = serde_json::to_string(&records).unwrap();
        for secret in ["fake", "private", "hidden"] {
            assert!(!json.contains(secret));
        }
        assert!(entries(b"incomplete\0").is_err());
        assert!(!EDITABLE.iter().any(|(key, _)| *key == "credential.helper"));
        let helpers = entries(b"global\0file:global.conf\0credential.helper\nosxkeychain\0local\0file:.git/config\0credential.helper\n\0local\0file:.git/config\0credential.helper\n!echo unlabelled-fixture-secret\0local\0file:.git/config\0core.sshcommand\nsshpass -p unlabelled-fixture-secret ssh\0").unwrap();
        assert!(!helpers[0].effective);
        assert!(helpers[1].effective && helpers[2].effective);
        assert!(!serde_json::to_string(&helpers)
            .unwrap()
            .contains("unlabelled-fixture-secret"));
    }
}

#[cfg(test)]
mod inherited_tag_tests {
    use serde_json::{json, Value};
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct Repository(PathBuf);

    impl Repository {
        fn request(&self, command: &str, mut payload: Value) -> Value {
            payload["root"] = json!(self.0);
            // Core owns subprocess deadlines; the fixture never waits on an
            // unbounded native child, including repository initialization.
            serde_json::from_str(&crate::execute_json(
                &json!({
                    "timeoutMilliseconds": 5000,
                    "command": command,
                    "payload": payload,
                })
                .to_string(),
            ))
            .unwrap()
        }
    }

    impl Drop for Repository {
        fn drop(&mut self) {
            if let Err(error) = fs::remove_dir_all(&self.0) {
                eprintln!("Could not clean tag boolean repository: {error}");
            }
        }
    }

    // Real Git integration protects the inspection-to-presentation contract.
    #[test]
    fn inspection_normalizes_inherited_tag_booleans_without_changing_edit_values() {
        let repo = Repository(std::env::temp_dir().join(format!(
            "lithe-tag-booleans-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        )));
        fs::create_dir_all(&repo.0).unwrap();
        let initialized = repo.request(
            "git.command",
            json!({ "arguments": ["init", "--template=", "-q", "-b", "main"] }),
        );
        assert_eq!(initialized["ok"], true, "{initialized}");
        assert_eq!(initialized["data"]["exitCode"], 0, "{initialized}");

        // Exercise Git's parser rather than duplicating its accepted spellings.
        // Valueless and empty assignments are deliberately distinct booleans.
        let cases = [
            ("yes", "pruneTags = yes", "true"),
            ("on", "pruneTags = on", "true"),
            ("one", "pruneTags = 1", "true"),
            ("mixed", "pruneTags = TrUe", "true"),
            ("valueless", "pruneTags", "true"),
            ("no", "pruneTags = no", "false"),
            ("off", "pruneTags = off", "false"),
            ("zero", "pruneTags = 0", "false"),
            ("false", "pruneTags = FaLsE", "false"),
            ("empty", "pruneTags =", "false"),
            ("invalid", "pruneTags = invalid", "invalid"),
        ];
        let path = repo.0.join(".git/config");
        let mut config = fs::read_to_string(&path).unwrap();
        config.push_str("\n[fetch]\npruneTags = yes\n");
        for (name, configuration, _) in cases {
            config.push_str(&format!("\n[remote \"{name}\"]\n{configuration}\n"));
        }
        fs::write(path, config).unwrap();

        let response = repo.request("git.executionInspect", json!({}));
        assert_eq!(response["ok"], true, "{response}");
        let entries = response["data"]["entries"].as_array().unwrap();
        for (name, _, expected) in cases {
            let key = format!("remote.{name}.prunetags");
            let entry = entries
                .iter()
                .find(|entry| entry["key"] == key && entry["effective"] == true)
                .unwrap();
            assert_eq!(entry["value"], expected, "{key}");
            assert_eq!(entry["scope"], "local", "{key}");
            assert!(entry["origin"].as_str().unwrap().ends_with(".git/config"));
        }
        let fetch = entries
            .iter()
            .find(|entry| entry["key"] == "fetch.prunetags" && entry["effective"] == true)
            .unwrap();
        assert_eq!(fetch["value"], "true");
        let field = response["data"]["fields"]
            .as_array()
            .unwrap()
            .iter()
            .find(|field| field["key"] == "fetch.prunetags")
            .unwrap();
        assert_eq!(field["configuredValues"], json!(["yes"]));
    }

    #[test]
    fn inspection_normalizes_skip_fetch_all_booleans() {
        let repo = Repository(std::env::temp_dir().join(format!(
            "lithe-skip-fetch-booleans-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        )));
        fs::create_dir_all(&repo.0).unwrap();
        let initialized = repo.request(
            "git.command",
            json!({ "arguments": ["init", "--template=", "-q", "-b", "main"] }),
        );
        assert_eq!(initialized["ok"], true, "{initialized}");
        assert_eq!(initialized["data"]["exitCode"], 0, "{initialized}");

        let path = repo.0.join(".git/config");
        let mut config = fs::read_to_string(&path).unwrap();
        config.push_str("\n[remote \"yes\"]\nurl = /tmp/yes\nskipFetchAll = yes\n");
        config.push_str("\n[remote \"valueless\"]\nurl = /tmp/valueless\nskipFetchAll\n");
        config.push_str("\n[remote \"empty\"]\nurl = /tmp/empty\nskipFetchAll =\n");
        config.push_str("\n[remote \"no\"]\nurl = /tmp/no\nskipFetchAll = no\n");
        fs::write(path, config).unwrap();

        let response = repo.request("git.executionInspect", json!({}));
        assert_eq!(response["ok"], true, "{response}");
        let entries = response["data"]["entries"].as_array().unwrap();
        for (name, expected) in [
            ("yes", "true"),
            ("valueless", "true"),
            ("empty", "false"),
            ("no", "false"),
        ] {
            let key = format!("remote.{name}.skipfetchall");
            let entry = entries
                .iter()
                .find(|entry| entry["key"] == key && entry["effective"] == true)
                .unwrap();
            assert_eq!(entry["value"], expected, "{key}");
        }
    }

    #[test]
    fn inspection_matches_git_when_tags_are_forced_or_configuration_is_invalid() {
        let repo = Repository(std::env::temp_dir().join(format!(
            "lithe-fetch-effective-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        )));
        fs::create_dir_all(&repo.0).unwrap();
        let git = |arguments: &[&str]| {
            let response = repo.request("git.command", json!({"arguments": arguments}));
            assert_eq!(response["ok"], true, "{response}");
            response["data"].clone()
        };
        let ok = |arguments: &[&str]| {
            let response = git(arguments);
            assert_eq!(response["exitCode"], 0, "{arguments:?}: {response}");
        };
        ok(&["init", "--template=", "-q", "-b", "main"]);
        ok(&[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "--allow-empty",
            "--no-gpg-sign",
            "-qm",
            "base",
        ]);
        ok(&["-c", "tag.gpgSign=false", "tag", "reachable"]);
        ok(&[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "--allow-empty",
            "--no-gpg-sign",
            "-qm",
            "other",
        ]);
        ok(&["-c", "tag.gpgSign=false", "tag", "extra"]);
        ok(&["reset", "--hard", "HEAD~1"]);
        let remote = repo.0.join("remote.git");
        ok(&[
            "init",
            "--bare",
            "--template=",
            "-q",
            remote.to_str().unwrap(),
        ]);
        ok(&[
            "--git-dir",
            remote.to_str().unwrap(),
            "symbolic-ref",
            "HEAD",
            "refs/heads/main",
        ]);
        ok(&["remote", "add", "origin", remote.to_str().unwrap()]);
        ok(&[
            "push",
            "-q",
            "origin",
            "HEAD:refs/heads/main",
            "refs/tags/*:refs/tags/*",
        ]);
        ok(&["tag", "-d", "reachable", "extra"]);
        ok(&["config", "lithe.fetch.tags", "none"]);
        ok(&["config", "lithe.fetch.prune", "false"]);
        ok(&["config", "fetch.pruneTags", "true"]);
        let inspect = || {
            let result = repo.request("git.executionInspect", json!({}));
            assert_eq!(result["ok"], true, "{result}");
            result["data"]["resolvedFetchBehavior"]["tags"].clone()
        };
        let fetch = || git(&["fetch", "--dry-run", "--no-tags", "--no-prune", "origin"]);
        assert_eq!(inspect()["value"], "all");
        let actual = fetch();
        assert_eq!(actual["exitCode"], 0, "{actual}");
        assert!(
            actual["stderr"].as_str().unwrap().contains("extra"),
            "{actual}"
        );

        ok(&["config", "--unset", "fetch.pruneTags"]);
        ok(&[
            "config",
            "--add",
            "remote.origin.fetch",
            "+refs/tags/*:refs/tags/*",
        ]);
        assert_eq!(inspect()["value"], "all");
        assert!(fetch()["stderr"].as_str().unwrap().contains("extra"));
        ok(&["config", "--add", "remote.origin.fetch", "^refs/tags/extra"]);
        assert_eq!(inspect()["value"], "custom");
        assert!(!fetch()["stderr"].as_str().unwrap().contains("extra"));

        ok(&["config", "--add", "remote.origin.fetch", ""]);
        assert_eq!(inspect()["value"], "none");
        assert!(!fetch()["stderr"].as_str().unwrap().contains("extra"));

        ok(&["config", "remote.origin.pruneTags", "invalid"]);
        let unknown = inspect();
        assert_eq!(unknown["value"], "unavailable");
        assert_eq!(unknown["reasonCode"], "invalidConfiguration");
        assert_ne!(fetch()["exitCode"], 0);
        ok(&["config", "--unset", "remote.origin.pruneTags"]);
        for key in ["fetch.prune", "remote.origin.prune", "remote.other.prune"] {
            ok(&["config", key, "invalid"]);
            assert_eq!(inspect()["reasonCode"], "invalidConfiguration", "{key}");
            assert_ne!(fetch()["exitCode"], 0, "{key}");
            ok(&["config", "--unset", key]);
        }
    }
}
