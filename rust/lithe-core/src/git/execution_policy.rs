//! Request-scoped execution choices and deterministic temporary configuration.

use super::fetch::GitFetchOptions;
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;

/// Native execution preferences supplied by the host, never copied into a project file.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct GitExecutionOptions {
    /// Null uses Git from the host PATH. A selected executable is an absolute native path.
    pub executable: Option<String>,
    /// Host can answer AskPass challenges for this user-initiated operation.
    pub interactive: bool,
    /// Explicit helper preference; noninteractive callers fail if credentials are unavailable.
    pub use_credential_helper: bool,
    /// Application defaults; explicit invocation choices and repository overrides take priority.
    pub fetch_defaults: GitFetchOptions,
    /// Request per-remote Fetch execution and structured outcomes.
    pub detailed_fetch: bool,
}
impl Default for GitExecutionOptions {
    fn default() -> Self {
        Self {
            executable: None,
            interactive: false,
            use_credential_helper: true,
            fetch_defaults: GitFetchOptions::default(),
            detailed_fetch: false,
        }
    }
}

thread_local! { static OPTIONS: RefCell<GitExecutionOptions> = RefCell::new(GitExecutionOptions::default()); }

/// Restores the previous policy even if a nested request fails.
pub(crate) struct Scope(GitExecutionOptions);
impl Scope {
    pub(crate) fn begin(options: Option<GitExecutionOptions>) -> Result<Self, CoreError> {
        let options = options.unwrap_or_default();
        if options.executable.as_ref().is_some_and(|path| {
            !std::path::Path::new(path).is_absolute() || path.contains(['\0', '\r', '\n'])
        }) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git executable must be an absolute path",
            ));
        }
        super::fetch::arguments(&options.fetch_defaults)?;
        Ok(Self(OPTIONS.with(|current| current.replace(options))))
    }
}
impl Drop for Scope {
    fn drop(&mut self) {
        OPTIONS.with(|current| {
            current.replace(self.0.clone());
        });
    }
}

pub(super) fn current() -> GitExecutionOptions {
    OPTIONS.with(|current| current.borrow().clone())
}

/// Environment configuration and scope provenance require Git 2.31 or newer.
pub(super) fn validate_version(version: &str) -> Result<(), CoreError> {
    let supported = version
        .strip_prefix("git version ")
        .and_then(|number| {
            let mut parts = number.split('.');
            Some((
                parts.next()?.parse::<u32>().ok()?,
                parts.next()?.parse::<u32>().ok()?,
            ))
        })
        .is_some_and(|number| number >= (2, 31));
    if supported {
        Ok(())
    } else {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git 2.31 or newer is required; select a newer executable in Git settings",
        ))
    }
}

/// Temporary values are scoped to a subprocess and visible in execution diagnostics.
pub(super) fn temporary_config() -> Vec<(String, String)> {
    let mut values = vec![
        ("color.ui".into(), "false".into()),
        ("core.quotepath".into(), "false".into()),
        ("log.showSignature".into(), "false".into()),
    ];
    if !current().use_credential_helper {
        values.push(("credential.helper".into(), String::new()));
    }
    values
}

/// Transfer commands emit progress even when their stderr is a pipe.
pub(super) fn arguments(arguments: &[String]) -> Vec<String> {
    let mut result = arguments.to_vec();
    if let Some(index) = command_index(arguments) {
        if matches!(
            arguments[index].as_str(),
            "fetch" | "pull" | "push" | "clone"
        ) && !arguments
            .iter()
            .any(|value| value == "--progress" || value == "--no-progress")
        {
            result.insert(index + 1, "--progress".into());
        }
    }
    result
}

pub(super) fn command_index(arguments: &[String]) -> Option<usize> {
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if matches!(
            argument.as_str(),
            "-c" | "-C" | "--git-dir" | "--work-tree" | "--config-env"
        ) {
            index += 2;
        } else if argument.starts_with('-') {
            index += 1;
        } else {
            return Some(index);
        }
    }
    None
}

/// Separates the readable subcommand from the global options folded by native consoles.
/// Raw process arguments remain unchanged in the event and command response.
pub(super) fn console_arguments(
    arguments: &[String],
    temporary_config: &[(String, String)],
) -> (Vec<String>, Vec<String>) {
    let command = command_index(arguments).unwrap_or(0);
    let mut global = temporary_config
        .iter()
        .flat_map(|(key, value)| ["-c".into(), format!("{key}={value}")])
        .collect::<Vec<String>>();
    // Include every original global argument in the disclosure. In particular,
    // do not mistake a commit message containing "-c" for a configuration flag.
    global.extend_from_slice(&arguments[..command]);
    (arguments[command..].to_vec(), global)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn console_projection_preserves_raw_arguments_and_folds_only_global_options() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/console-command-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let arguments: Vec<String> = serde_json::from_value(case["arguments"].clone()).unwrap();
            let configuration: Vec<(String, String)> =
                serde_json::from_value(case["temporaryConfig"].clone()).unwrap();
            let (display, global) = console_arguments(&arguments, &configuration);
            assert_eq!(
                serde_json::json!(display),
                case["displayArguments"],
                "{}",
                case["name"]
            );
            assert_eq!(
                serde_json::json!(global),
                case["globalArguments"],
                "{}",
                case["name"]
            );
            assert_eq!(serde_json::json!(arguments), case["arguments"]);
        }
    }

    #[test]
    fn version_capabilities_reject_old_or_unknown_executables() {
        for version in [
            "git version 2.31.0",
            "git version 2.50.1.windows.1",
            "git version 2.39.5 (Apple Git-154)",
        ] {
            assert!(validate_version(version).is_ok());
        }
        for version in ["git version 2.30.9", "unknown", "git version 2.bad"] {
            assert!(validate_version(version).is_err());
        }
    }

    #[test]
    fn named_defaults_are_scoped_and_do_not_duplicate_transfer_progress() {
        let before = current();
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/execution-policy-v1.json"
        ))
        .unwrap();
        assert_eq!(
            serde_json::to_value(temporary_config()).unwrap(),
            fixture["temporaryConfig"]
        );
        {
            let _scope = Scope::begin(Some(GitExecutionOptions {
                interactive: true,
                use_credential_helper: false,
                ..Default::default()
            }))
            .unwrap();
            assert_eq!(temporary_config().last().unwrap().0, "credential.helper");
            let args =
                ["-c", "core.editor=true", "push", "--progress", "origin"].map(str::to_string);
            assert_eq!(arguments(&args), args);
            assert_eq!(
                arguments(&["clone".into(), "--".into(), "remote".into()])[1],
                "--progress"
            );
        }
        assert_eq!(
            current().use_credential_helper,
            before.use_credential_helper
        );
        assert!(Scope::begin(Some(GitExecutionOptions {
            executable: Some("relative/git".into()),
            ..Default::default()
        }))
        .is_err());
    }
}
