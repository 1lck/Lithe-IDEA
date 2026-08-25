//! Deterministic document persistence states shared by every platform editor.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(
    tag = "status",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
/// Persistence state for one live editor document.
pub enum DocumentLifecycleState {
    /// The editor text and last successfully persisted text are identical.
    Clean {
        /// Monotonically increasing content revision owned by the platform editor.
        revision: u64,
    },
    /// The editor contains changes that have not been persisted.
    Dirty {
        /// Current platform-owned content revision.
        revision: u64,
        /// Last revision known to have been persisted.
        saved_revision: u64,
    },
    /// One save operation owns a snapshot while the editor may continue changing.
    Saving {
        /// Current platform-owned content revision.
        revision: u64,
        /// Last revision persisted before this save started.
        saved_revision: u64,
        /// Revision of the immutable snapshot being written.
        save_revision: u64,
        /// Correlation identifier that rejects stale save completions.
        operation_id: String,
    },
    /// Disk changed while the editor still owns unpublished text.
    Conflict {
        /// Current platform-owned content revision.
        revision: u64,
        /// Last revision known to have been persisted before the conflict.
        saved_revision: u64,
    },
}

impl DocumentLifecycleState {
    fn validate(&self) -> Result<(), CoreError> {
        match self {
            Self::Clean { .. } => Ok(()),
            Self::Dirty {
                revision,
                saved_revision,
            }
            | Self::Conflict {
                revision,
                saved_revision,
            } => validate_revision_order(*saved_revision, *revision),
            Self::Saving {
                revision,
                saved_revision,
                save_revision,
                operation_id,
            } => {
                validate_operation_id(operation_id)?;
                validate_revision_order(*saved_revision, *save_revision)?;
                validate_revision_order(*save_revision, *revision)
            }
        }
    }

    fn revision(&self) -> u64 {
        match self {
            Self::Clean { revision }
            | Self::Dirty { revision, .. }
            | Self::Saving { revision, .. }
            | Self::Conflict { revision, .. } => *revision,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
/// Persistence event reduced by [`decide_document_lifecycle`].
pub enum DocumentLifecycleEvent {
    /// The platform editor applied local text and advanced its revision.
    Edited {
        revision: u64,
        /// Whether the new editor text equals the last persisted snapshot.
        matches_saved_content: bool,
    },
    /// A caller is ready to persist the current immutable snapshot.
    SaveStarted { operation_id: String },
    /// The write owned by the matching operation completed successfully.
    SaveSucceeded { operation_id: String },
    /// The write owned by the matching operation failed.
    SaveFailed { operation_id: String },
    /// A watcher observed a disk change not attributed to the current save.
    ExternalChanged,
    /// A requested disk reload completed and installed this revision.
    ReloadSucceeded { revision: u64 },
    /// The user chose the live editor text after a conflict.
    KeepEditor,
    /// The user requested that disk replace the live editor text.
    LoadDisk,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Platform effect required after a lifecycle transition.
pub enum DocumentLifecycleAction {
    /// No platform persistence work is required.
    None,
    /// Persist the current immutable editor snapshot.
    WriteToDisk,
    /// Read disk and replace the live document only if that read succeeds.
    ReloadFromDisk,
    /// Keep the live text and ask the user to resolve the conflict.
    ShowConflict,
    /// Surface the matching save failure while retaining dirty text.
    ReportSaveFailure,
    /// Ignore a completion from an operation that no longer owns the save.
    IgnoreStaleResult,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for one deterministic document lifecycle transition.
pub struct DocumentLifecycleRequest {
    pub state: DocumentLifecycleState,
    pub event: DocumentLifecycleEvent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Next state and platform effect for one lifecycle event.
pub struct DocumentLifecycleDecision {
    pub state: DocumentLifecycleState,
    pub action: DocumentLifecycleAction,
}

/// Reduces one document lifecycle event without reading text or touching disk.
pub fn decide_document_lifecycle(
    request: DocumentLifecycleRequest,
) -> Result<DocumentLifecycleDecision, CoreError> {
    request.state.validate()?;
    let current_revision = request.state.revision();

    let decision = match (request.state, request.event) {
        (
            state,
            DocumentLifecycleEvent::Edited {
                revision,
                matches_saved_content,
            },
        ) => {
            if revision <= current_revision {
                return Err(invalid_request(
                    "Edited document revision must advance monotonically",
                ));
            }
            let state = match state {
                DocumentLifecycleState::Clean {
                    revision: saved_revision,
                } => DocumentLifecycleState::Dirty {
                    revision,
                    saved_revision,
                },
                DocumentLifecycleState::Dirty { .. } if matches_saved_content => {
                    DocumentLifecycleState::Clean { revision }
                }
                DocumentLifecycleState::Dirty { saved_revision, .. } => {
                    DocumentLifecycleState::Dirty {
                        revision,
                        saved_revision,
                    }
                }
                DocumentLifecycleState::Saving {
                    saved_revision,
                    save_revision,
                    operation_id,
                    ..
                } => DocumentLifecycleState::Saving {
                    revision,
                    saved_revision,
                    save_revision,
                    operation_id,
                },
                DocumentLifecycleState::Conflict { saved_revision, .. } => {
                    DocumentLifecycleState::Conflict {
                        revision,
                        saved_revision,
                    }
                }
            };
            decision(state, DocumentLifecycleAction::None)
        }
        (
            DocumentLifecycleState::Dirty {
                revision,
                saved_revision,
            },
            DocumentLifecycleEvent::SaveStarted { operation_id },
        ) => {
            validate_operation_id(&operation_id)?;
            decision(
                DocumentLifecycleState::Saving {
                    revision,
                    saved_revision,
                    save_revision: revision,
                    operation_id,
                },
                DocumentLifecycleAction::WriteToDisk,
            )
        }
        (state, DocumentLifecycleEvent::SaveStarted { operation_id }) => {
            validate_operation_id(&operation_id)?;
            let action = if matches!(state, DocumentLifecycleState::Conflict { .. }) {
                DocumentLifecycleAction::ShowConflict
            } else {
                DocumentLifecycleAction::None
            };
            decision(state, action)
        }
        (
            DocumentLifecycleState::Saving {
                revision,
                saved_revision: _,
                save_revision,
                operation_id: owner,
            },
            DocumentLifecycleEvent::SaveSucceeded { operation_id },
        ) if owner == operation_id => {
            let state = if revision == save_revision {
                DocumentLifecycleState::Clean { revision }
            } else {
                DocumentLifecycleState::Dirty {
                    revision,
                    saved_revision: save_revision,
                }
            };
            decision(state, DocumentLifecycleAction::None)
        }
        (
            DocumentLifecycleState::Saving {
                revision,
                saved_revision,
                operation_id: owner,
                ..
            },
            DocumentLifecycleEvent::SaveFailed { operation_id },
        ) if owner == operation_id => decision(
            DocumentLifecycleState::Dirty {
                revision,
                saved_revision,
            },
            DocumentLifecycleAction::ReportSaveFailure,
        ),
        (state, DocumentLifecycleEvent::SaveSucceeded { operation_id })
        | (state, DocumentLifecycleEvent::SaveFailed { operation_id }) => {
            validate_operation_id(&operation_id)?;
            decision(state, DocumentLifecycleAction::IgnoreStaleResult)
        }
        (DocumentLifecycleState::Clean { revision }, DocumentLifecycleEvent::ExternalChanged) => {
            decision(
                DocumentLifecycleState::Clean { revision },
                DocumentLifecycleAction::ReloadFromDisk,
            )
        }
        (
            DocumentLifecycleState::Dirty {
                revision,
                saved_revision,
            }
            | DocumentLifecycleState::Conflict {
                revision,
                saved_revision,
            },
            DocumentLifecycleEvent::ExternalChanged,
        ) => decision(
            DocumentLifecycleState::Conflict {
                revision,
                saved_revision,
            },
            DocumentLifecycleAction::ShowConflict,
        ),
        (
            DocumentLifecycleState::Saving {
                revision,
                saved_revision,
                ..
            },
            DocumentLifecycleEvent::ExternalChanged,
        ) => decision(
            DocumentLifecycleState::Conflict {
                revision,
                saved_revision,
            },
            DocumentLifecycleAction::ShowConflict,
        ),
        (_, DocumentLifecycleEvent::ReloadSucceeded { revision }) => decision(
            DocumentLifecycleState::Clean { revision },
            DocumentLifecycleAction::None,
        ),
        (
            DocumentLifecycleState::Conflict {
                revision,
                saved_revision,
            },
            DocumentLifecycleEvent::KeepEditor,
        ) => decision(
            DocumentLifecycleState::Dirty {
                revision,
                saved_revision,
            },
            DocumentLifecycleAction::None,
        ),
        (state @ DocumentLifecycleState::Conflict { .. }, DocumentLifecycleEvent::LoadDisk) => {
            decision(state, DocumentLifecycleAction::ReloadFromDisk)
        }
        (state, DocumentLifecycleEvent::KeepEditor | DocumentLifecycleEvent::LoadDisk) => {
            decision(state, DocumentLifecycleAction::None)
        }
    };

    Ok(decision)
}

fn decision(
    state: DocumentLifecycleState,
    action: DocumentLifecycleAction,
) -> DocumentLifecycleDecision {
    DocumentLifecycleDecision { state, action }
}

fn validate_revision_order(earlier: u64, later: u64) -> Result<(), CoreError> {
    if earlier <= later {
        Ok(())
    } else {
        Err(invalid_request(
            "Document lifecycle revisions must be monotonically ordered",
        ))
    }
}

fn validate_operation_id(operation_id: &str) -> Result<(), CoreError> {
    if operation_id.trim().is_empty() {
        Err(invalid_request("Save operationID must not be empty"))
    } else {
        Ok(())
    }
}

fn invalid_request(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edit_during_save_keeps_the_newer_revision_dirty_after_success() {
        let saving = decide_document_lifecycle(DocumentLifecycleRequest {
            state: DocumentLifecycleState::Dirty {
                revision: 4,
                saved_revision: 1,
            },
            event: DocumentLifecycleEvent::SaveStarted {
                operation_id: "save-1".into(),
            },
        })
        .unwrap()
        .state;
        let edited = decide_document_lifecycle(DocumentLifecycleRequest {
            state: saving,
            event: DocumentLifecycleEvent::Edited {
                revision: 5,
                matches_saved_content: false,
            },
        })
        .unwrap()
        .state;
        let completed = decide_document_lifecycle(DocumentLifecycleRequest {
            state: edited,
            event: DocumentLifecycleEvent::SaveSucceeded {
                operation_id: "save-1".into(),
            },
        })
        .unwrap();

        assert_eq!(
            completed.state,
            DocumentLifecycleState::Dirty {
                revision: 5,
                saved_revision: 4,
            }
        );
    }

    #[test]
    fn dirty_external_change_requires_an_explicit_user_choice() {
        let result = decide_document_lifecycle(DocumentLifecycleRequest {
            state: DocumentLifecycleState::Dirty {
                revision: 3,
                saved_revision: 1,
            },
            event: DocumentLifecycleEvent::ExternalChanged,
        })
        .unwrap();

        assert_eq!(result.action, DocumentLifecycleAction::ShowConflict);
        assert!(matches!(
            result.state,
            DocumentLifecycleState::Conflict { .. }
        ));
    }

    #[test]
    fn stale_save_completion_cannot_clear_newer_document_state() {
        let state = DocumentLifecycleState::Saving {
            revision: 2,
            saved_revision: 1,
            save_revision: 2,
            operation_id: "save-new".into(),
        };
        let result = decide_document_lifecycle(DocumentLifecycleRequest {
            state: state.clone(),
            event: DocumentLifecycleEvent::SaveSucceeded {
                operation_id: "save-old".into(),
            },
        })
        .unwrap();

        assert_eq!(result.state, state);
        assert_eq!(result.action, DocumentLifecycleAction::IgnoreStaleResult);
    }
}
