use anyhow::{Context as _, Result};
use git2::{Repository, SubmoduleUpdateOptions};
use std::path::PathBuf;

/// Information about a submodule in the repository.
#[derive(Debug, Clone)]
pub struct SubmoduleInfo {
    /// Name of the submodule (from .gitmodules)
    pub name: String,
    /// Path relative to repository root
    pub path: PathBuf,
    /// URL of the submodule
    pub url: String,
    /// Branch configured for submodule (if any)
    pub branch: Option<String>,
    /// OID in HEAD tree (what the superproject expects)
    pub head_oid: Option<String>,
    /// OID in index (staged version)
    pub index_oid: Option<String>,
    /// OID in working directory (currently checked out)
    pub workdir_oid: Option<String>,
    /// Whether the submodule is initialized
    pub is_initialized: bool,
}

impl SubmoduleInfo {
    /// Returns a human-readable status string for this submodule.
    pub fn status(&self) -> &'static str {
        if !self.is_initialized {
            return "not initialized";
        }
        match (&self.head_oid, &self.workdir_oid) {
            (Some(head), Some(workdir)) if head == workdir => "up to date",
            (Some(_), Some(_)) => "modified",
            (Some(_), None) => "not checked out",
            (None, _) => "no commit",
        }
    }
}

/// Compute the status of all submodules in the repository.
pub fn compute_submodules(repo: &Repository) -> Result<Vec<SubmoduleInfo>> {
    let submodules = repo
        .submodules()
        .context("Failed to enumerate submodules")?;

    let mut result = Vec::new();
    for submodule in submodules {
        let name = submodule.name().unwrap_or("unknown").to_string();
        let path = submodule.path().to_path_buf();
        let url = submodule.url().unwrap_or("").to_string();
        let branch = submodule.branch().map(str::to_string);

        let head_oid = submodule.head_id().map(|oid| oid.to_string());
        let index_oid = submodule.index_id().map(|oid| oid.to_string());
        let workdir_oid = submodule.workdir_id().map(|oid| oid.to_string());

        // A submodule is initialized if its repository exists
        let is_initialized = submodule.open().is_ok();

        result.push(SubmoduleInfo {
            name,
            path,
            url,
            branch,
            head_oid,
            index_oid,
            workdir_oid,
            is_initialized,
        });
    }

    Ok(result)
}

/// Initialize a submodule by name.
/// This copies submodule info from .gitmodules to .git/config.
pub fn submodule_init(repo: &Repository, name: &str) -> Result<()> {
    let submodules = repo
        .submodules()
        .context("Failed to enumerate submodules")?;

    for mut submodule in submodules {
        if submodule.name() == Some(name) {
            submodule
                .init(false)
                .context("Failed to initialize submodule")?;
            return Ok(());
        }
    }

    anyhow::bail!("Submodule '{}' not found", name)
}

/// Update a submodule by name.
/// This fetches and checks out the submodule to the expected commit.
pub fn submodule_update(repo: &Repository, name: &str, init: bool) -> Result<()> {
    let submodules = repo
        .submodules()
        .context("Failed to enumerate submodules")?;

    for mut submodule in submodules {
        if submodule.name() == Some(name) {
            let mut opts = SubmoduleUpdateOptions::new();
            submodule
                .update(init, Some(&mut opts))
                .context("Failed to update submodule")?;
            return Ok(());
        }
    }

    anyhow::bail!("Submodule '{}' not found", name)
}

/// Initialize all submodules.
pub fn submodule_init_all(repo: &Repository) -> Result<Vec<String>> {
    let submodules = repo
        .submodules()
        .context("Failed to enumerate submodules")?;

    let mut initialized = Vec::new();
    for mut submodule in submodules {
        let name = submodule.name().unwrap_or("unknown").to_string();
        submodule
            .init(false)
            .context(format!("Failed to initialize submodule '{}'", name))?;
        initialized.push(name);
    }

    Ok(initialized)
}

/// Update all submodules.
pub fn submodule_update_all(repo: &Repository, init: bool) -> Result<Vec<String>> {
    let submodules = repo
        .submodules()
        .context("Failed to enumerate submodules")?;

    let mut updated = Vec::new();
    for mut submodule in submodules {
        let name = submodule.name().unwrap_or("unknown").to_string();
        let mut opts = SubmoduleUpdateOptions::new();
        submodule
            .update(init, Some(&mut opts))
            .context(format!("Failed to update submodule '{}'", name))?;
        updated.push(name);
    }

    Ok(updated)
}

use gpui::{AsyncApp, Context, Task, WeakEntity};

use super::GitProject;

impl GitProject {
    /// Get submodule status synchronously.
    pub fn submodules(&self) -> Result<Vec<SubmoduleInfo>> {
        let repo = self.open_repo()?;
        compute_submodules(&repo)
    }

    /// Get submodule status asynchronously.
    pub fn submodules_async(&self, cx: &mut Context<Self>) -> Task<Result<Vec<SubmoduleInfo>>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path).context("Failed to open repository")?;
                    compute_submodules(&repo)
                })
                .await
        })
    }

    /// Initialize a submodule by name (async).
    pub fn submodule_init_async(&self, name: String, cx: &mut Context<Self>) -> Task<Result<()>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path).context("Failed to open repository")?;
                    submodule_init(&repo, &name)
                })
                .await
        })
    }

    /// Update a submodule by name (async).
    pub fn submodule_update_async(
        &self,
        name: String,
        init: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path).context("Failed to open repository")?;
                    submodule_update(&repo, &name, init)
                })
                .await
        })
    }

    /// Initialize all submodules (async).
    pub fn submodule_init_all_async(&self, cx: &mut Context<Self>) -> Task<Result<Vec<String>>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path).context("Failed to open repository")?;
                    submodule_init_all(&repo)
                })
                .await
        })
    }

    /// Update all submodules (async).
    pub fn submodule_update_all_async(
        &self,
        init: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<Vec<String>>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move {
                    let repo = Repository::open(&repo_path).context("Failed to open repository")?;
                    submodule_update_all(&repo, init)
                })
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::SubmoduleInfo;

    fn make_submodule(
        is_initialized: bool,
        head_oid: Option<&str>,
        workdir_oid: Option<&str>,
    ) -> SubmoduleInfo {
        SubmoduleInfo {
            name: "test-sub".to_string(),
            path: std::path::PathBuf::from("libs/test-sub"),
            url: "https://example.com/repo".to_string(),
            branch: None,
            head_oid: head_oid.map(String::from),
            index_oid: None,
            workdir_oid: workdir_oid.map(String::from),
            is_initialized,
        }
    }

    #[test]
    fn status_not_initialized() {
        let sub = make_submodule(false, Some("abc123"), Some("abc123"));
        assert_eq!(sub.status(), "not initialized");
    }

    #[test]
    fn status_up_to_date() {
        let sub = make_submodule(true, Some("abc123"), Some("abc123"));
        assert_eq!(sub.status(), "up to date");
    }

    #[test]
    fn status_modified_head_differs_from_workdir() {
        let sub = make_submodule(true, Some("abc123"), Some("def456"));
        assert_eq!(sub.status(), "modified");
    }

    #[test]
    fn status_not_checked_out_has_head_no_workdir() {
        let sub = make_submodule(true, Some("abc123"), None);
        assert_eq!(sub.status(), "not checked out");
    }

    #[test]
    fn status_no_commit() {
        let sub = make_submodule(true, None, None);
        assert_eq!(sub.status(), "no commit");
    }

    #[test]
    fn status_no_commit_with_workdir() {
        // Even with a workdir OID, if there's no head OID, it's "no commit"
        let sub = make_submodule(true, None, Some("def456"));
        assert_eq!(sub.status(), "no commit");
    }
}
