//! Per-remote Fetch results preserve partial successes and exact changed references.
use super::{
    capture_git_with_options, configuration, execute_git, execution_events, fetch,
    read_git_config_value, GitCommandResponse,
};
use crate::protocol::{CoreError, ErrorCode};
use serde_json::json;
use std::collections::BTreeMap;

fn capture(root: &str, arguments: &[&str]) -> Result<String, CoreError> {
    let output = capture_git_with_options(
        root,
        &arguments
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>(),
        None,
        true,
    )?;
    if output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect Fetch scope").with_details(
                execution_events::redact(&String::from_utf8_lossy(&output.stderr)),
            ),
        );
    }
    String::from_utf8(output.stdout)
        .map_err(|_| CoreError::new(ErrorCode::ParseFailed, "Fetch scope is not UTF-8"))
}
fn references(root: &str) -> Result<BTreeMap<String, String>, CoreError> {
    Ok(capture(
        root,
        &[
            "for-each-ref",
            "--format=%(refname)%00%(objectname)",
            "refs/remotes",
            "refs/tags",
        ],
    )?
    .lines()
    .filter_map(|line| line.split_once('\0'))
    .map(|(name, oid)| (name.to_string(), oid.to_string()))
    .collect())
}

pub(super) fn remote_names(
    root: &str,
    options: &fetch::GitFetchOptions,
) -> Result<Vec<String>, CoreError> {
    let all_remotes = options.remote.is_none();
    let mut remotes = if let Some(remote) = &options.remote {
        if read_git_config_value(root, &format!("remote.{remote}.url"))?.is_none() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Fetch remote is not configured",
            ));
        }
        vec![remote.clone()]
    } else {
        capture(root, &["remote"])?
            .lines()
            .map(str::to_string)
            .collect()
    };
    remotes.sort();
    let mut enabled = Vec::new();
    for remote in remotes {
        let skip = all_remotes
            && read_git_config_value(root, &format!("remote.{remote}.skipFetchAll"))?.is_some_and(
                |value| {
                    matches!(
                        value.to_ascii_lowercase().as_str(),
                        "true" | "yes" | "on" | "1"
                    )
                },
            );
        if !skip {
            enabled.push(remote);
        }
    }
    if enabled.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "No configured remote is enabled for Fetch",
        ));
    }
    Ok(enabled)
}

pub(super) fn execute(
    root: &str,
    options: Option<fetch::GitFetchOptions>,
) -> Result<GitCommandResponse, CoreError> {
    let mut options = configuration::fetch_options(root, options)?;
    let remotes = remote_names(root, &options)?;
    let mut last = None;
    let mut failures = Vec::new();
    for remote in remotes {
        crate::protocol::cancellation::check()?;
        options.remote = Some(remote.clone());
        let before = references(root)?;
        let result = execute_git(root, &fetch::arguments(&options)?, None);
        let after = references(root);
        let mut reference_error = None;
        let (updated, deleted) = match after {
            Ok(after) => (
                after
                    .iter()
                    .filter(|(name, oid)| before.get(*name) != Some(*oid))
                    .map(|(name, _)| name.clone())
                    .collect::<Vec<_>>(),
                before
                    .keys()
                    .filter(|name| !after.contains_key(*name))
                    .cloned()
                    .collect::<Vec<_>>(),
            ),
            Err(error) => {
                reference_error = Some(error.message.clone());
                (Vec::new(), Vec::new())
            }
        };
        let error = match &result {
            Ok(result) if result.exit_code == 0 => reference_error.clone(),
            Ok(result) => Some(
                execution_events::redact(&result.stderr)
                    .chars()
                    .take(8192)
                    .collect::<String>(),
            ),
            Err(error) => Some(error.message.clone()),
        };
        execution_events::emit(json!({ "type": "remoteResult", "remote": remote,
            "updatedReferenceCount": updated.len(), "deletedReferenceCount": deleted.len(),
            "referencesAvailable": reference_error.is_none(),
            "referencesTruncated": updated.len() > 50 || deleted.len() > 50,
            "updatedReferences": updated.iter().take(50).collect::<Vec<_>>(), "deletedReferences": deleted.iter().take(50).collect::<Vec<_>>(), "error": error.as_ref().map(|message| json!({"code": "process_failed", "message": message})),
            "succeeded": error.is_none() }));
        if let Some(error) = error {
            failures.push(format!("{remote}: {error}"));
        }
        match result {
            Ok(result) => last = Some(result),
            Err(error) if matches!(error.code, ErrorCode::Cancelled | ErrorCode::TimedOut) => {
                return Err(error)
            }
            Err(_) => (),
        }
    }
    let mut result = last.ok_or_else(|| {
        CoreError::new(
            ErrorCode::ProcessFailed,
            if failures.is_empty() {
                "No configured remote is enabled for Fetch".into()
            } else {
                failures.join("\n")
            },
        )
    })?;
    if !failures.is_empty() {
        result.operation_error = Some(
            CoreError::new(ErrorCode::ProcessFailed, "Some Fetch operations failed")
                .with_details(failures.join("\n")),
        );
    }
    Ok(result)
}
