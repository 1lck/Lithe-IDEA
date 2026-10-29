//! Native document reads, guarded saves, and window-owned watch leases.
use lithe_project::{
    document_file::{self, DocumentChangeRead, DocumentRead, SaveOutcome},
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
                "Open a supported text encoding and keep the file no larger than 32 MB.",
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
pub async fn resolve_agent_document_path(
    workspace: PathBuf,
    path: PathBuf,
) -> Result<PathBuf, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::agent_document_path(&workspace, &path).map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}

#[tauri::command]
pub async fn trash_agent_document(
    workspace: PathBuf,
    path: PathBuf,
    expected_identity: String,
) -> Result<(), DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::trash_agent_document(&workspace, &path, &expected_identity)
            .map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}

#[tauri::command]
pub async fn save_agent_document(
    workspace: PathBuf,
    path: PathBuf,
    content: String,
    expected_content: Option<String>,
    encoding: Option<String>,
    expected_identity: Option<String>,
) -> Result<SaveOutcome, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        let resolved =
            document_file::agent_document_path(&workspace, &path).map_err(DocumentError::from)?;
        document_file::save_document_with_encoding(
            &resolved,
            &content,
            expected_content.as_deref(),
            encoding.as_deref(),
            encoding.as_deref(),
            expected_identity.as_deref(),
        )
        .map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}

#[tauri::command]
pub async fn read_document_file_details(
    path: PathBuf,
    encoding: Option<String>,
) -> Result<Option<DocumentRead>, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::read_document_with_encoding(&path, encoding.as_deref())
            .map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}
#[tauri::command]
pub async fn read_document_file_change(
    path: PathBuf,
    encoding: Option<String>,
    known_identity: Option<String>,
) -> Result<DocumentChangeRead, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::read_document_change(&path, encoding.as_deref(), known_identity.as_deref())
            .map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}

#[tauri::command]
pub async fn save_document_file(
    path: PathBuf,
    content: String,
    expected_content: Option<String>,
    encoding: Option<String>,
    expected_encoding: Option<String>,
    expected_identity: Option<String>,
) -> Result<SaveOutcome, DocumentError> {
    tauri::async_runtime::spawn_blocking(move || {
        document_file::save_document_with_encoding(
            &path,
            &content,
            expected_content.as_deref(),
            encoding.as_deref(),
            expected_encoding.as_deref(),
            expected_identity.as_deref(),
        )
        .map_err(DocumentError::from)
    })
    .await
    .map_err(DocumentError::worker)?
}
/// Canonicalizes every watched parent and re-registers its native watch, so
/// the work runs off the UI thread. The generation keeps a late, older
/// snapshot from replacing a newer one.
#[tauri::command]
pub async fn set_document_watches(
    generation: u64,
    documents: Vec<DocumentWatch>,
    window: tauri::WebviewWindow,
    watcher: State<'_, Arc<DocumentWatcher>>,
) -> Result<(), String> {
    let watcher = Arc::clone(&watcher);
    let owner = window.label().to_owned();
    crate::blocking::run_blocking(move || watcher.replace(&owner, generation, documents)).await
}
