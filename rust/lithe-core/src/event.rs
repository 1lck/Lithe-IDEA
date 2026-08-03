use crate::error::CoreError;
use crate::model::{GitStatusResponse, SearchResponse, WorkspaceSnapshotResponse};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", content = "payload", rename_all = "camelCase")]
pub enum CoreEvent {
    WorkspaceLoaded(WorkspaceSnapshotResponse),
    SearchCompleted(SearchResponse),
    GitStatusChanged(GitStatusResponse),
    FileChanged { path: String },
    OperationFailed(CoreError),
}
