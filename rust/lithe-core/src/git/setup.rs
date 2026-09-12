//! Repository initialization and narrowly scoped commit identity configuration.

use super::{capture_git_with_environment, validate_root, CoreError, ErrorCode, GitProcessOutput};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

// Git's config lock protects against external writers; this lock also orders
// initialization and identity writes originating in different Lithe windows.
static SETUP_WRITER: Mutex<()> = Mutex::new(());
const MAX_IDENTITY_BYTES: usize = 1024;

/// Persistent config scope selected explicitly in Settings.
#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum GitIdentityScope {
    #[default]
    Local,
    Global,
}

impl GitIdentityScope {
    fn flag(self) -> &'static str {
        match self {
            Self::Local => "--local",
            Self::Global => "--global",
        }
    }
}

/// Existing workspace directory and the config scope to inspect.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitSetupRequest {
    pub root: String,
    #[serde(default)]
    pub scope: GitIdentityScope,
}

/// Only commit identity keys are editable; arbitrary Git config is not exposed.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GitIdentityKey {
    Name,
    Email,
}

impl GitIdentityKey {
    fn config_key(self) -> &'static str {
        match self {
            Self::Name => "user.name",
            Self::Email => "user.email",
        }
    }
}

/// A single atomic Git config edit. Null removes the selected scope's override.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitConfigureIdentityRequest {
    pub root: String,
    pub scope: GitIdentityScope,
    pub key: GitIdentityKey,
    pub value: Option<String>,
}

/// Repository state is independent of history filters; effective values include
/// Git's normal config inheritance while configured values exclude includes.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitSetupResponse {
    pub is_repository: bool,
    pub has_commits: bool,
    pub branch: Option<String>,
    pub scope: GitIdentityScope,
    pub configured_name: Option<String>,
    pub configured_email: Option<String>,
    pub effective_name: Option<String>,
    pub effective_email: Option<String>,
}

fn git(root: &str, arguments: &[&str]) -> Result<GitProcessOutput, CoreError> {
    if arguments.first() == Some(&"init")
        || arguments
            .iter()
            .any(|arg| matches!(*arg, "--replace-all" | "--unset-all"))
    {
        return super::capture_git_process(
            root,
            &arguments.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            None,
            false,
            &[("LC_ALL".into(), "C".into())],
            true,
        );
    }
    capture_git_with_environment(
        root,
        &arguments.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        None,
        false,
        &[("LC_ALL".into(), "C".into())],
    )
}

fn failed(output: &GitProcessOutput) -> CoreError {
    CoreError::new(ErrorCode::ProcessFailed, "Git setup operation failed")
        .with_details(String::from_utf8_lossy(&output.stderr).into_owned())
}

fn text(bytes: &[u8]) -> Result<String, CoreError> {
    String::from_utf8(bytes.to_vec())
        .map_err(|_| CoreError::new(ErrorCode::ProcessFailed, "Git identity is not valid UTF-8"))
}

fn is_repository(root: &str) -> Result<bool, CoreError> {
    let output = git(root, &["rev-parse", "--is-inside-work-tree"])?;
    if output.exit_code == 0 {
        if output.stdout == b"true\n" {
            return Ok(true);
        }
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git setup requires a working directory, not a bare repository",
        ));
    }
    // Do not treat unsafe ownership, malformed config or unreadable metadata as
    // an invitation to reinitialize an existing repository.
    if String::from_utf8_lossy(&output.stderr).contains("not a git repository") {
        return Ok(false);
    }
    Err(failed(&output))
}

fn config_value(
    root: &str,
    scope: Option<GitIdentityScope>,
    key: &str,
) -> Result<Option<String>, CoreError> {
    let mut arguments = vec!["config"];
    if let Some(scope) = scope {
        arguments.extend([scope.flag(), "--no-includes"]);
    }
    arguments.extend(["--null", "--get", "--", key]);
    let output = git(root, &arguments)?;
    match output.exit_code {
        0 => Ok(Some(
            text(&output.stdout)?.trim_end_matches('\0').to_string(),
        )),
        1 => Ok(None),
        _ => Err(failed(&output)),
    }
}

/// Inspect empty repositories without treating an unborn HEAD as a Git failure.
pub fn inspect(request: GitSetupRequest) -> Result<GitSetupResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let is_repository = is_repository(&root)?;
    let (has_commits, branch) = if is_repository {
        let head = git(&root, &["rev-parse", "--verify", "--quiet", "HEAD"])?;
        if head.exit_code != 0 && head.exit_code != 1 {
            return Err(failed(&head));
        }
        let branch = git(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])?;
        if branch.exit_code != 0 && branch.exit_code != 1 {
            return Err(failed(&branch));
        }
        (
            head.exit_code == 0,
            (branch.exit_code == 0)
                .then(|| text(&branch.stdout))
                .transpose()?
                .map(|s| s.trim_end().to_string()),
        )
    } else {
        (false, None)
    };
    let can_read_scope = is_repository || request.scope == GitIdentityScope::Global;
    Ok(GitSetupResponse {
        is_repository,
        has_commits,
        branch,
        scope: request.scope,
        configured_name: if can_read_scope {
            config_value(&root, Some(request.scope), "user.name")?
        } else {
            None
        },
        configured_email: if can_read_scope {
            config_value(&root, Some(request.scope), "user.email")?
        } else {
            None
        },
        effective_name: config_value(&root, None, "user.name")?,
        effective_email: config_value(&root, None, "user.email")?,
    })
}

/// Initialize only an existing directory outside any repository. Git chooses its
/// initial branch from normal configuration; no files are staged or committed.
pub fn initialize(request: GitSetupRequest) -> Result<GitSetupResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let _writer = SETUP_WRITER
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::ProcessFailed, "Git setup is unavailable"))?;
    if is_repository(&root)? {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "This folder already belongs to a Git repository",
        ));
    }
    let result = git(&root, &["init"])?;
    if result.exit_code != 0 {
        return Err(failed(&result));
    }
    inspect(request)
}

/// Save one identity field through Git's atomic config writer. Each field has a
/// separate UI action, so a second field cannot silently fail after a partial save.
pub fn configure_identity(
    request: GitConfigureIdentityRequest,
) -> Result<GitSetupResponse, CoreError> {
    let root = validate_root(&request.root)?;
    if let Some(value) = &request.value {
        if value.trim().is_empty()
            || value.len() > MAX_IDENTITY_BYTES
            || value
                .chars()
                .any(|c| c.is_control() || c == '<' || c == '>')
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Enter a nonempty Git identity without control characters or angle brackets",
            ));
        }
    }
    let _writer = SETUP_WRITER
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::ProcessFailed, "Git setup is unavailable"))?;
    let repository = is_repository(&root)?;
    if request.scope == GitIdentityScope::Local && !repository {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Initialize a repository before saving repository-specific identity",
        ));
    }
    let _lease = if repository {
        Some(super::rewrite::RewriteLease::acquire(&root)?)
    } else {
        None
    };
    let mut arguments = vec!["config", request.scope.flag()];
    arguments.push(if request.value.is_some() {
        "--replace-all"
    } else {
        "--unset-all"
    });
    arguments.extend(["--", request.key.config_key()]);
    if let Some(value) = &request.value {
        arguments.push(value);
    }
    let output = git(&root, &arguments)?;
    if output.exit_code != 0 && !(request.value.is_none() && output.exit_code == 5) {
        return Err(failed(&output));
    }
    inspect(GitSetupRequest {
        root,
        scope: request.scope,
    })
}
