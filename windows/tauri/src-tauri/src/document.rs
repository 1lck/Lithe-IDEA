//! Native document reads, guarded saves, and window-owned watch leases.
use lithe_project::{
    document_file::{self, SaveOutcome},
    document_watcher::{DocumentWatch, DocumentWatcher},
};
use std::{path::PathBuf, sync::Arc};
use tauri::State;

#[derive(serde::Serialize)]
pub struct DocumentError {
    code: &'static str,
    message: &'static str,
    details: String,
}
impl From<std::io::Error> for DocumentError {
    fn from(error: std::io::Error) -> Self {
        let (code, message) = match error.kind() {
            std::io::ErrorKind::PermissionDenied => (
                "DOCUMENT_PERMISSION_DENIED",
                "Check file permissions and retry.",
            ),
            std::io::ErrorKind::Unsupported => (
                "DOCUMENT_UNSUPPORTED",
                "Open a regular local file instead of a link.",
            ),
            std::io::ErrorKind::InvalidData => (
                "DOCUMENT_INVALID_TEXT",
                "Open a UTF-8 text file no larger than 32 MB.",
            ),
            _ => (
                "DOCUMENT_IO_FAILED",
                "The file could not be accessed. Check its location and retry.",
            ),
        };
        Self {
            code,
            message,
            details: error.to_string(),
        }
    }
}
impl DocumentError {
    fn worker(error: impl std::fmt::Display) -> Self {
        Self {
            code: "DOCUMENT_WORKER_FAILED",
            message: "The file operation did not complete. Retry the operation.",
            details: error.to_string(),
        }
    }
}

#[tauri::command]
pub async fn read_document_file(path: PathBuf) -> Result<Option<String>, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::read_document(&path).map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}
#[tauri::command]
pub async fn save_document_file(
    path: PathBuf,
    content: String,
    expected_content: Option<String>,
) -> Result<SaveOutcome, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::save_document(&path, &content, expected_content.as_deref())
            .map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}
#[tauri::command]
pub fn set_document_watches(
    generation: u64,
    documents: Vec<DocumentWatch>,
    window: tauri::WebviewWindow,
    watcher: State<'_, Arc<DocumentWatcher>>,
) -> Result<(), String> {
    watcher.replace(window.label(), generation, documents)
}
