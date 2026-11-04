//! Reviewed GitHub pull-request checkout without resetting existing local refs.
//!
//! Note: .agents/notes/implemented/bug-fix/2026-11-04-github-pull-request-checkout-safety.md

use super::*;
use crate::github::{
    parse_remote, pull_request_checkout_plan, GitHubRepository, ParseRemoteRequest,
    PullRequestCheckoutPlan, PullRequestCheckoutPlanRequest,
};
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

static ORIGIN_FINGERPRINT_SALT: OnceLock<[u8; 32]> = OnceLock::new();

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Pull-request identity for a repository-local checkout preview.
pub struct PullRequestCheckoutPreviewRequest {
    pub root: String,
    pub number: u64,
    pub head_ref: String,
    /// Repository whose pull request was displayed; absent only for generic Core callers.
    pub expected_repository: Option<GitHubRepository>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// The exact checkout identity reviewed by the user.
pub struct PullRequestCheckoutRequest {
    pub root: String,
    pub number: u64,
    pub head_ref: String,
    pub expected_head: String,
    pub expected_branch: Option<String>,
    /// Opaque digest of the effective origin fetch URL, never the URL itself.
    pub expected_origin_fingerprint: String,
    /// Repository whose pull request was displayed, if known by the caller.
    pub expected_repository: Option<GitHubRepository>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// A checkout proposal and the current checkout it was based on.
pub struct PullRequestCheckoutPreview {
    pub plan: PullRequestCheckoutPlan,
    pub head: String,
    pub current_branch: Option<String>,
    /// Opaque digest used to detect a changed origin without disclosing credentials.
    pub origin_fingerprint: String,
}

fn origin_fingerprint(root: &str) -> Result<String, CoreError> {
    // Do not add this output to Git invocation results: URLs can contain credentials.
    let result = capture_git_with_options(
        root,
        &["remote".into(), "get-url".into(), "origin".into()],
        None,
        true,
    )?;
    if result.exit_code != 0 || result.stdout.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The origin remote is unavailable",
        ));
    }
    // A process-local salt keeps a low-entropy credential in a URL from becoming
    // an offline guessing oracle when the opaque fingerprint crosses the bridge.
    let salt = ORIGIN_FINGERPRINT_SALT.get_or_init(rand::random);
    let mut digest = Sha256::new();
    digest.update(salt);
    digest.update(&result.stdout);
    Ok(format!("{:x}", digest.finalize()))
}

fn probe_ref(root: &str, reference: &str) -> Result<bool, CoreError> {
    let result = execute_git_readonly(
        root,
        &[
            "show-ref".into(),
            "--verify".into(),
            "--quiet".into(),
            reference.into(),
        ],
        None,
    )?;
    match result.exit_code {
        0 => Ok(true),
        1 => Ok(false),
        _ => Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect the pull-request branch",
        )),
    }
}

fn inspect(
    root: &str,
    number: u64,
    head_ref: &str,
    expected_repository: Option<&GitHubRepository>,
) -> Result<PullRequestCheckoutPreview, CoreError> {
    if let Some(expected) = expected_repository {
        let matches = match read_git_config_value(root, "remote.origin.url")? {
            Some(remote_url) => {
                // Collapse invalid and different origins into one safe, logged failure.
                parse_remote(ParseRemoteRequest { remote_url })
                    .is_ok_and(|actual| &actual == expected)
            }
            None => false,
        };
        if !matches {
            return Err(CoreError::new(
                ErrorCode::GitCheckoutChanged,
                "The GitHub repository changed",
            ));
        }
    }
    let proposed = pull_request_checkout_plan(PullRequestCheckoutPlanRequest {
        number,
        head_ref: head_ref.to_string(),
        branch_exists: false,
    })?;
    let target_ref = format!("refs/heads/{}", proposed.branch);
    // A ref cannot coexist with a parent or descendant ref, even with another name.
    let descendants = execute_git_readonly(
        root,
        &[
            "for-each-ref".into(),
            "--count=1".into(),
            "--format=%(refname)".into(),
            format!("{target_ref}/"),
        ],
        None,
    )?;
    if descendants.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect pull-request branches",
        ));
    }
    let conflict = probe_ref(root, &target_ref)?
        || probe_ref(root, "refs/heads/pr")?
        || !descendants.stdout.trim().is_empty();
    let plan = pull_request_checkout_plan(PullRequestCheckoutPlanRequest {
        number,
        head_ref: head_ref.to_string(),
        branch_exists: conflict,
    })?;
    let head = execute_git_readonly(
        root,
        &["rev-parse".into(), "--verify".into(), "HEAD".into()],
        None,
    )?;
    if head.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The current checkout has no commit",
        ));
    }
    let branch = execute_git_readonly(
        root,
        &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
        None,
    )?;
    if branch.exit_code != 0 && branch.exit_code != 1 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect the current checkout",
        ));
    }
    Ok(PullRequestCheckoutPreview {
        plan,
        head: head.stdout.trim().to_string(),
        current_branch: (branch.exit_code == 0).then(|| branch.stdout.trim().to_string()),
        origin_fingerprint: origin_fingerprint(root)?,
    })
}

/// Inspects the current checkout and branch conflict without changing the repository.
pub fn preview(
    request: PullRequestCheckoutPreviewRequest,
) -> Result<PullRequestCheckoutPreview, CoreError> {
    let root = validate_root(&request.root)?;
    let preview = inspect(
        &root,
        request.number,
        &request.head_ref,
        request.expected_repository.as_ref(),
    )?;
    if !preview.plan.allowed {
        return Err(CoreError::new(
            ErrorCode::GitBranchExists,
            "The pull-request branch already exists",
        ));
    }
    Ok(preview)
}

fn verify_reviewed(
    preview: &PullRequestCheckoutPreview,
    request: &PullRequestCheckoutRequest,
) -> Result<(), CoreError> {
    if !preview.plan.allowed {
        return Err(CoreError::new(
            ErrorCode::GitBranchExists,
            "The pull-request branch already exists",
        ));
    }
    if preview.head != request.expected_head
        || preview.current_branch != request.expected_branch
        || preview.origin_fingerprint != request.expected_origin_fingerprint
    {
        return Err(CoreError::new(
            ErrorCode::GitCheckoutChanged,
            "The checkout changed after review",
        ));
    }
    Ok(())
}

/// Rechecks the reviewed checkout under the Git write lease, then fetches and creates a branch.
pub fn checkout(request: PullRequestCheckoutRequest) -> Result<GitCommandResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let _lease = rewrite::RewriteLease::acquire(&root)?;
    let reviewed = inspect(
        &root,
        request.number,
        &request.head_ref,
        request.expected_repository.as_ref(),
    )?;
    verify_reviewed(&reviewed, &request)?;
    with_git_invocation_trace(|| {
        let remote = format!("refs/remotes/origin/pr/{}", request.number);
        let fetch = match execute_git(
            &root,
            &[
                "fetch".into(),
                "origin".into(),
                format!("pull/{}/head:{remote}", request.number),
            ],
            None,
        ) {
            Ok(result) => result,
            Err(error) => return Ok(authoritative_failure(error)),
        };
        if fetch.exit_code != 0 {
            return Ok(fetch);
        }
        // External Git can change the checkout during network I/O; recheck before mutation.
        let current = match inspect(
            &root,
            request.number,
            &request.head_ref,
            request.expected_repository.as_ref(),
        ) {
            Ok(result) => result,
            Err(error) => return Ok(authoritative_failure(error)),
        };
        if let Err(error) = verify_reviewed(&current, &request) {
            // A successful fetch must not turn a later rejected checkout into success.
            return Ok(authoritative_failure(error));
        }
        match execute_git(
            &root,
            &["checkout".into(), "-b".into(), current.plan.branch, remote],
            None,
        ) {
            Ok(result) => Ok(result),
            Err(error) => Ok(authoritative_failure(error)),
        }
    })
}

fn authoritative_failure(error: CoreError) -> GitCommandResponse {
    let mut failed = failed_git_result(error);
    failed.outcome_authoritative = true;
    failed
}
