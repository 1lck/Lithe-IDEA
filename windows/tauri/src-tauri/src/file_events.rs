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
        let _ = self.app_handle.emit("file-changed", event);
    }
}

impl GitMetadataEmitter for TauriFileChangeEmitter {
    fn emit_git_metadata_change(&self, event: &GitMetadataChange) {
        if let Err(error) = self.app_handle.emit("git-metadata-changed", event) {
            eprintln!("Could not publish Git metadata change: {error}");
        }
    }
}
