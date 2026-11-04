use lithe_project::git_watcher::{GitMetadataChange, GitMetadataEmitter};
use lithe_project::{FileChangeEmitter, FileChangeEvent};
use tauri::{AppHandle, Emitter};

pub struct TauriFileChangeEmitter {
    app_handle: AppHandle,
}

impl TauriFileChangeEmitter {
    pub fn new(app_handle: AppHandle) -> Self {
        Self { app_handle }
    }
}

impl FileChangeEmitter for TauriFileChangeEmitter {
    fn emit_file_change(&self, event: &FileChangeEvent) {
        self.emit_file_changes(std::slice::from_ref(event));
    }

    fn emit_file_changes(&self, events: &[FileChangeEvent]) {
        let paths = events
            .iter()
            .filter(|event| {
                matches!(
                    event.event_type,
                    lithe_project::FileChangeType::Rescan | lithe_project::FileChangeType::Deleted
                ) || std::path::Path::new(&event.path)
                    .file_name()
                    .is_some_and(|name| name == ".gitignore" || name == ".git")
            })
            .map(|event| std::path::PathBuf::from(&event.path))
            .collect::<Vec<_>>();
        // Retire once for the entire native batch, before any WebView observes it.
        crate::core::invalidate_indexing_paths(&self.app_handle, &paths, true);
        for event in events {
            let _ = self.app_handle.emit("file-changed", event);
        }
    }
}

impl GitMetadataEmitter for TauriFileChangeEmitter {
    fn emit_git_metadata_change(&self, event: &GitMetadataChange) {
        crate::core::invalidate_indexing_paths(&self.app_handle, &event.repository_roots, true);
        if let Err(error) = self.app_handle.emit("git-metadata-changed", event) {
            eprintln!("Could not publish Git metadata change: {error}");
        }
    }
}

impl lithe_project::document_watcher::DocumentChangeEmitter for TauriFileChangeEmitter {
    fn emit(&self, event: lithe_project::document_watcher::DocumentChange) {
        if let Err(error) =
            self.app_handle
                .emit_to(event.owner.clone(), "document-file-changed", event)
        {
            eprintln!("Could not publish document change: {error}");
        }
    }
}
