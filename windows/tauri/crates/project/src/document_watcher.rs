//! Window-owned document leases share parent-directory watches independently of project indexing.
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentWatch {
    pub id: String,
    pub path: PathBuf,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentChange {
    pub owner: String,
    pub generation: u64,
    pub id: String,
    pub path: PathBuf,
}
pub trait DocumentChangeEmitter: Send + Sync {
    fn emit(&self, event: DocumentChange);
}
#[derive(Default)]
struct Leases {
    owners: BTreeMap<String, (u64, Vec<DocumentWatch>)>,
}
struct Watches {
    watcher: RecommendedWatcher,
    directories: BTreeSet<PathBuf>,
}
pub struct DocumentWatcher {
    leases: Arc<Mutex<Leases>>,
    watches: Mutex<Watches>,
}

impl DocumentWatcher {
    pub fn new(emitter: Arc<dyn DocumentChangeEmitter>) -> notify::Result<Self> {
        let leases = Arc::new(Mutex::new(Leases::default()));
        let callback_leases = Arc::clone(&leases);
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let events = {
                let Ok(leases) = callback_leases.lock() else {
                    return;
                };
                match event {
                    Ok(event) if !matches!(event.kind, notify::EventKind::Access(_)) => {
                        changes_for(&leases, &event.paths)
                    }
                    Ok(_) => Vec::new(),
                    Err(error) => {
                        log::warn!("Document watch needs reconciliation: {error}");
                        changes_for(&leases, &[])
                    }
                }
            };
            for event in events {
                emitter.emit(event);
            }
        })?;
        Ok(Self {
            leases,
            watches: Mutex::new(Watches {
                watcher,
                directories: BTreeSet::new(),
            }),
        })
    }

    /// Full owner snapshots make duplicate disposal and out-of-order requests harmless.
    pub fn replace(
        &self,
        owner: &str,
        generation: u64,
        mut documents: Vec<DocumentWatch>,
    ) -> Result<(), String> {
        if documents
            .iter()
            .any(|document| !document.path.is_absolute())
        {
            return Err("Document watch needs an absolute path".into());
        }
        for document in &mut documents {
            if let (Some(parent), Some(name)) = (document.path.parent(), document.path.file_name())
            {
                if let Ok(parent) = parent.canonicalize() {
                    document.path = parent.join(name);
                }
            }
        }
        let mut watches = self
            .watches
            .lock()
            .map_err(|_| "Document watcher unavailable")?;
        let mut leases = self
            .leases
            .lock()
            .map_err(|_| "Document leases unavailable")?;
        if leases
            .owners
            .get(owner)
            .is_some_and(|(current, _)| generation < *current)
        {
            return Ok(());
        }
        leases
            .owners
            .insert(owner.to_owned(), (generation, documents));
        let desired: BTreeSet<PathBuf> = leases
            .owners
            .values()
            .flat_map(|(_, documents)| {
                documents
                    .iter()
                    .filter_map(|document| document.path.parent().map(Path::to_path_buf))
            })
            .collect();
        drop(leases);
        // Refresh registrations on owner snapshots/focus: deleted and recreated parents
        // may leave a native watch attached to an obsolete directory object.
        let obsolete: Vec<_> = watches.directories.iter().cloned().collect();
        for directory in obsolete {
            if let Err(error) = watches.watcher.unwatch(&directory) {
                log::warn!("Could not remove document watch: {error}");
            }
            watches.directories.remove(&directory);
        }
        let missing: Vec<_> = desired.difference(&watches.directories).cloned().collect();
        let mut errors = Vec::new();
        for directory in missing {
            match watches
                .watcher
                .watch(&directory, RecursiveMode::NonRecursive)
            {
                Ok(()) => {
                    watches.directories.insert(directory);
                }
                Err(error) => errors.push(error.to_string()),
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }

    pub fn remove_owner(&self, owner: &str) -> Result<(), String> {
        self.replace(owner, u64::MAX, Vec::new())
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    #[cfg(windows)]
    {
        left.to_string_lossy()
            .replace('/', "\\")
            .eq_ignore_ascii_case(&right.to_string_lossy().replace('/', "\\"))
    }
    #[cfg(not(windows))]
    {
        left == right
    }
}
fn changes_for(leases: &Leases, paths: &[PathBuf]) -> Vec<DocumentChange> {
    leases
        .owners
        .iter()
        .flat_map(|(owner, (generation, documents))| {
            documents
                .iter()
                .filter(|document| {
                    paths.is_empty()
                        || paths.iter().any(|path| {
                            same_path(path, &document.path)
                                || document
                                    .path
                                    .ancestors()
                                    .skip(1)
                                    .any(|parent| same_path(path, parent))
                        })
                })
                .map(|document| DocumentChange {
                    owner: owner.clone(),
                    generation: *generation,
                    id: document.id.clone(),
                    path: document.path.clone(),
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replacement_and_parent_removal_reach_all_owners_without_active_window_routing() {
        let root = std::env::temp_dir().join("lithe-document-events-fixture");
        let path = root.join("src").join("A.java");
        let documents = vec![DocumentWatch {
            id: "doc-a".into(),
            path: path.clone(),
        }];
        let leases = Leases {
            owners: BTreeMap::from([
                ("window-a".into(), (2, documents.clone())),
                ("window-b".into(), (5, documents)),
            ]),
        };
        let events = changes_for(&leases, &[path.clone()]);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].generation, 2);
        assert_eq!(events[1].generation, 5);
        assert_eq!(
            changes_for(&leases, &[path.parent().unwrap().to_owned()]).len(),
            2
        );
        assert!(changes_for(&leases, &[root.join("unrelated.txt")]).is_empty());
    }
    struct ChannelEmitter(std::sync::mpsc::Sender<DocumentChange>);
    impl DocumentChangeEmitter for ChannelEmitter {
        fn emit(&self, event: DocumentChange) {
            let _ = self.0.send(event);
        }
    }
    #[test]
    fn native_parent_watch_survives_replacement_and_another_window_closing() {
        let directory =
            std::env::temp_dir().join(format!("lithe-native-doc-watch-{}", std::process::id()));
        std::fs::create_dir_all(directory.join("src")).unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                std::fs::remove_dir_all(&self.0).unwrap();
            }
        }
        let _cleanup = Cleanup(directory.clone());
        let path = directory.join("src").join("A.java");
        std::fs::write(&path, "original").unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        let watcher = DocumentWatcher::new(Arc::new(ChannelEmitter(sender))).unwrap();
        let documents = vec![DocumentWatch {
            id: "document".into(),
            path: path.clone(),
        }];
        watcher.replace("window-a", 1, documents.clone()).unwrap();
        watcher.replace("window-b", 1, documents).unwrap();
        assert_eq!(watcher.watches.lock().unwrap().directories.len(), 1);
        watcher.remove_owner("window-a").unwrap();
        let replacement = directory.join("src").join("replacement.tmp");
        std::fs::write(&replacement, "external replacement").unwrap();
        std::fs::remove_file(&path).unwrap();
        std::fs::rename(&replacement, &path).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let event = receiver
                .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
                .expect("replacement notification deadline");
            if event.owner == "window-b" {
                assert_eq!(event.id, "document");
                break;
            }
        }
        watcher.remove_owner("window-b").unwrap();
        assert!(watcher.watches.lock().unwrap().directories.is_empty());
    }
}
