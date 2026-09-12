//! Allowlisted Git configuration inspection, provenance, and explicit scoped edits.

use super::{
    capture_git_with_options, execute_git, execution_events, execution_policy, fetch, rewrite,
    validate_root,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

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

#[derive(Clone, Debug, Serialize)]
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
            && [".url", ".prune", ".prunetags", ".tagopt", ".skipfetchall"]
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
        if key != "credential.helper" || value.is_empty() {
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
    let entries = entries(&output)?;
    let mut fields = Vec::new();
    for (key, choices) in EDITABLE {
        if scope == "global" && key.starts_with("lithe.") {
            continue;
        }
        fields.push(json!({ "key": key, "choices": choices, "configuredValues": scoped_values(root, scope, key)? }));
    }
    let options = execution_policy::current();
    let effective_fetch = fetch_options(root, None);
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
    Ok(
        json!({ "executable": lithe_git_host::configuration::executable(options.executable.as_deref()).map(|path| path.to_string_lossy().into_owned()),
        "version": String::from_utf8_lossy(&version).trim(), "scope": scope, "entries": entries, "fields": fields,
        "temporaryConfig": execution_policy::temporary_config(),
        "fetchSources": fetch_sources, "fetchOptions": effective_fetch.as_ref().ok(), "fetchError": effective_fetch.as_ref().err(),
        "credentialHelperEnabled": options.use_credential_helper,
        "interactiveAuthentication": options.interactive }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
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
