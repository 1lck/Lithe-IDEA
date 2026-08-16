//! Events emitted by asynchronous shared-core operations.

use crate::protocol::CoreError;
use crate::protocol::{GitStatusResponse, SearchResponse, WorkspaceSnapshotResponse};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", content = "payload", rename_all = "camelCase")]
/// Tagged asynchronous events delivered to host applications.
pub enum CoreEvent {
    /// A workspace snapshot finished loading.
    WorkspaceLoaded(WorkspaceSnapshotResponse),
    /// An asynchronous search produced its final result set.
    SearchCompleted(SearchResponse),
    /// Observed Git state changed for the active repository.
    GitStatusChanged(GitStatusResponse),
    /// A workspace-relative path changed on disk.
    FileChanged {
        /// Forward-slashed path relative to the workspace root.
        path: String,
    },
    /// An asynchronous Core operation failed before producing data.
    OperationFailed(CoreError),
}
