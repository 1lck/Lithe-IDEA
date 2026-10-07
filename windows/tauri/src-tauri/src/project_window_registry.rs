//! Native directory identities and their owning workspace windows.

use same_file::Handle;
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectWindowOwner {
    pub label: String,
    // None reserves a newly built window until its frontend opens the project.
    pub workspace_id: Option<String>,
}

#[derive(Default)]
pub struct ProjectWindowRegistry {
    owners: HashMap<Handle, ProjectWindowOwner>,
}

impl ProjectWindowRegistry {
    pub fn title_snapshot(&self) -> Vec<RegisteredTitleProject> {
        use std::os::windows::io::AsRawHandle;
        // 只复制登记条目的进程内标识和归属，不查询目录或复制操作系统句柄。
        self.owners
            .iter()
            .map(|(identity, owner)| RegisteredTitleProject {
                identity: RegisteredTitleIdentity {
                    handle: identity.as_raw_handle() as usize,
                    label: owner.label.clone(),
                    workspace_id: owner.workspace_id.clone(),
                },
                owner: owner.clone(),
            })
            .collect()
    }

    pub fn identity(path: &Path) -> Result<Handle, String> {
        if !path.is_dir() {
            return Err("Project directory is unavailable".into());
        }
        // Keep the native handle alive: file IDs may be reused after it closes.
        // This also preserves case-sensitive directories and directory aliases.
        Handle::from_path(path)
            .map_err(|error| format!("Cannot identify project directory: {error}"))
    }

    pub fn claim(
        &mut self,
        identity: Handle,
        label: &str,
        workspace_id: Option<&str>,
    ) -> ProjectWindowOwner {
        let owner = self
            .owners
            .entry(identity)
            .or_insert_with(|| ProjectWindowOwner {
                label: label.to_owned(),
                workspace_id: workspace_id.map(str::to_owned),
            });
        if owner.label == label && owner.workspace_id.is_none() {
            owner.workspace_id = workspace_id.map(str::to_owned);
        }
        owner.clone()
    }

    pub fn release(&mut self, label: &str, workspace_id: Option<&str>) {
        self.owners.retain(|_, owner| {
            owner.label != label
                || workspace_id.is_some_and(|id| owner.workspace_id.as_deref() != Some(id))
        });
    }

    pub fn release_pending(&mut self, label: &str) {
        self.owners
            .retain(|_, owner| owner.label != label || owner.workspace_id.is_some());
    }

    pub fn retain_windows(&mut self, exists: impl Fn(&str) -> bool) {
        self.owners.retain(|_, owner| exists(&owner.label));
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct RegisteredTitleIdentity {
    handle: usize,
    label: String,
    workspace_id: Option<String>,
}

pub struct RegisteredTitleProject {
    pub identity: RegisteredTitleIdentity,
    pub owner: ProjectWindowOwner,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);
    struct TestDirectory(std::path::PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-project-window-{}-{}",
                std::process::id(),
                NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn identity(&self) -> Handle {
            ProjectWindowRegistry::identity(&self.0).unwrap()
        }
    }
    impl Drop for TestDirectory {
        fn drop(&mut self) {
            if let Err(error) = fs::remove_dir_all(&self.0) {
                eprintln!("Could not remove project-window test directory: {error}");
            }
        }
    }

    #[test]
    fn reserves_before_frontend_registration_and_reuses_original_owner() {
        let root = TestDirectory::new();
        let mut registry = ProjectWindowRegistry::default();
        let pending = registry.claim(root.identity(), "workspace-1", None);
        assert_eq!(
            registry.claim(root.identity(), "workspace-2", None),
            pending
        );
        let opened = registry.claim(root.identity(), "workspace-1", Some("project-a"));
        assert_eq!(opened.workspace_id.as_deref(), Some("project-a"));
        assert_eq!(
            registry.claim(root.identity(), "main", Some("alias")),
            opened
        );
    }

    #[test]
    fn release_only_removes_the_matching_window_and_workspace() {
        let a = TestDirectory::new();
        let b = TestDirectory::new();
        let mut registry = ProjectWindowRegistry::default();
        let owner_a = registry.claim(a.identity(), "main", Some("a"));
        let owner_b = registry.claim(b.identity(), "main", Some("b"));
        registry.release("other", Some("a"));
        assert_eq!(registry.claim(a.identity(), "other", Some("a")), owner_a);
        registry.release("main", Some("a"));
        assert_eq!(
            registry.claim(a.identity(), "other", Some("a")).label,
            "other"
        );
        assert_eq!(registry.claim(b.identity(), "other", Some("b")), owner_b);
        registry.release("main", None);
        assert_eq!(
            registry.claim(b.identity(), "other", Some("b")).label,
            "other"
        );
    }

    #[test]
    fn failed_creation_and_stale_windows_do_not_keep_reservations() {
        let root = TestDirectory::new();
        let mut registry = ProjectWindowRegistry::default();
        registry.claim(root.identity(), "failed", None);
        registry.release("failed", None);
        assert_eq!(
            registry.claim(root.identity(), "closed", None).label,
            "closed"
        );
        registry.retain_windows(|label| label != "closed");
        assert_eq!(registry.claim(root.identity(), "new", None).label, "new");
    }

    #[test]
    fn failed_initial_open_releases_only_the_unregistered_reservation() {
        let pending = TestDirectory::new();
        let opened = TestDirectory::new();
        let mut registry = ProjectWindowRegistry::default();
        registry.claim(pending.identity(), "main", None);
        let owner = registry.claim(opened.identity(), "main", Some("opened"));
        registry.release_pending("main");
        assert_eq!(
            registry.claim(pending.identity(), "retry", None).label,
            "retry"
        );
        assert_eq!(registry.claim(opened.identity(), "retry", None), owner);
    }

    #[test]
    fn equivalent_paths_match_but_distinct_directories_do_not() {
        let root = TestDirectory::new();
        let child = root.0.join("Child");
        fs::create_dir(&child).unwrap();
        assert_eq!(
            root.identity(),
            ProjectWindowRegistry::identity(&child.join("..")).unwrap()
        );
        assert_ne!(
            root.identity(),
            ProjectWindowRegistry::identity(&child).unwrap()
        );
        #[cfg(windows)]
        {
            let alternate_case = root.0.join("child");
            // Windows directories can opt into case-sensitive lookup.
            if alternate_case.is_dir() {
                assert_eq!(
                    ProjectWindowRegistry::identity(&child).unwrap(),
                    ProjectWindowRegistry::identity(&alternate_case).unwrap()
                );
            } else {
                assert!(ProjectWindowRegistry::identity(&alternate_case).is_err());
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn follows_directory_links_without_folding_case_sensitive_names() {
        let root = TestDirectory::new();
        let target = root.0.join("Project");
        let other = root.0.join("project");
        let alias = root.0.join("alias");
        fs::create_dir(&target).unwrap();
        fs::create_dir(&other).unwrap();
        std::os::unix::fs::symlink(&target, &alias).unwrap();
        assert_eq!(
            ProjectWindowRegistry::identity(&target).unwrap(),
            ProjectWindowRegistry::identity(&alias).unwrap()
        );
        assert_ne!(
            ProjectWindowRegistry::identity(&target).unwrap(),
            ProjectWindowRegistry::identity(&other).unwrap()
        );
    }

    #[test]
    fn rejects_missing_directories_and_files_without_claiming_them() {
        let root = TestDirectory::new();
        assert!(ProjectWindowRegistry::identity(&root.0.join("missing")).is_err());
        let file = root.0.join("file");
        fs::write(&file, "content").unwrap();
        assert!(ProjectWindowRegistry::identity(&file).is_err());
    }
}
