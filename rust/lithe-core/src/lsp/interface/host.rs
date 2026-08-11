use super::{
    client_apply_server_message, client_change_document, client_close_document,
    client_feature_request_canonical, client_initialize, client_open_document, client_shutdown,
    ClientApplyServerMessageRequest, ClientChangeDocumentRequest, ClientCloseDocumentRequest,
    ClientFeatureRequest, ClientInitializeRequest, ClientOpenDocumentRequest,
    ClientShutdownRequest, LspClientDiagnostic, LspClientEvent, LspClientState, LspPosition,
    LspRange,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

static HOST: OnceLock<LspHost> = OnceLock::new();

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LspSessionAction {
    Create,
    OpenDocument,
    ChangeDocument,
    CloseDocument,
    Shutdown,
    Request,
    ApplyServerMessage,
    Destroy,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LspSessionCommandRequest {
    pub action: LspSessionAction,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub root_uri: Option<String>,
    #[serde(default)]
    pub process_id: Option<i64>,
    #[serde(default)]
    pub initialization_options: Option<Value>,
    #[serde(default)]
    pub uri: Option<String>,
    #[serde(default)]
    pub language_id: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub position: Option<LspPosition>,
    #[serde(default)]
    pub new_name: Option<String>,
    #[serde(default)]
    pub range: Option<LspRange>,
    #[serde(default)]
    pub diagnostics: Vec<LspClientDiagnostic>,
    #[serde(default)]
    pub completion_item: Option<Value>,
    #[serde(default)]
    pub code_action: Option<Value>,
    #[serde(default)]
    pub command: Option<Value>,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspSessionResponse {
    pub session_id: String,
    pub server_capabilities: Vec<String>,
    pub messages: Vec<String>,
    pub events: Vec<LspClientEvent>,
}

pub fn execute(request: LspSessionCommandRequest) -> Result<LspSessionResponse, CoreError> {
    HOST.get_or_init(LspHost::new).execute(request)
}

struct LspHost {
    next_session_id: AtomicU64,
    sessions: Mutex<BTreeMap<String, Arc<Mutex<LspClientState>>>>,
}

impl LspHost {
    fn new() -> Self {
        Self {
            next_session_id: AtomicU64::new(1),
            sessions: Mutex::new(BTreeMap::new()),
        }
    }

    fn execute(&self, request: LspSessionCommandRequest) -> Result<LspSessionResponse, CoreError> {
        if matches!(request.action, LspSessionAction::Create) {
            return self.create(request);
        }
        let session_id = required(request.session_id.clone(), "sessionId")?;
        if matches!(request.action, LspSessionAction::Destroy) {
            let mut sessions = self.lock_sessions()?;
            if sessions.remove(&session_id).is_none() {
                return Err(missing_session(&session_id));
            }
            return Ok(LspSessionResponse {
                session_id,
                server_capabilities: Vec::new(),
                messages: Vec::new(),
                events: Vec::new(),
            });
        }

        let session = self.session(&session_id)?;
        let mut session_state = Self::lock_session(&session)?;
        let state = session_state.clone();
        let response = match request.action {
            LspSessionAction::OpenDocument => client_open_document(ClientOpenDocumentRequest {
                state,
                uri: required(request.uri, "uri")?,
                language_id: required(request.language_id, "languageId")?,
                text: required(request.text, "text")?,
            }),
            LspSessionAction::ChangeDocument => {
                client_change_document(ClientChangeDocumentRequest {
                    state,
                    uri: required(request.uri, "uri")?,
                    text: required(request.text, "text")?,
                })
            }
            LspSessionAction::CloseDocument => client_close_document(ClientCloseDocumentRequest {
                state,
                uri: required(request.uri, "uri")?,
            }),
            LspSessionAction::Shutdown => client_shutdown(ClientShutdownRequest { state }),
            LspSessionAction::Request => client_feature_request_canonical(ClientFeatureRequest {
                state,
                uri: required(request.uri, "uri")?,
                method: required(request.method, "method")?,
                position: request.position,
                new_name: request.new_name,
                range: request.range,
                diagnostics: request.diagnostics,
                completion_item: request.completion_item,
                code_action: request.code_action,
                command: request.command,
            }),
            LspSessionAction::ApplyServerMessage => {
                client_apply_server_message(ClientApplyServerMessageRequest {
                    state,
                    message: required(request.message, "message")?,
                })
            }
            LspSessionAction::Create | LspSessionAction::Destroy => unreachable!(),
        }?;
        let server_capabilities = response.state.server_capabilities.clone();
        *session_state = response.state;
        Ok(LspSessionResponse {
            session_id,
            server_capabilities,
            messages: response.messages,
            events: response.events,
        })
    }

    fn create(&self, request: LspSessionCommandRequest) -> Result<LspSessionResponse, CoreError> {
        let response = client_initialize(ClientInitializeRequest {
            state: LspClientState::default(),
            root_uri: required(request.root_uri, "rootUri")?,
            process_id: request.process_id,
            initialization_options: request.initialization_options,
        })?;
        let session_id = self
            .next_session_id
            .fetch_add(1, Ordering::Relaxed)
            .to_string();
        let server_capabilities = response.state.server_capabilities.clone();
        self.lock_sessions()?
            .insert(session_id.clone(), Arc::new(Mutex::new(response.state)));
        Ok(LspSessionResponse {
            session_id,
            server_capabilities,
            messages: response.messages,
            events: response.events,
        })
    }

    fn session(&self, session_id: &str) -> Result<Arc<Mutex<LspClientState>>, CoreError> {
        self.lock_sessions()?
            .get(session_id)
            .cloned()
            .ok_or_else(|| missing_session(session_id))
    }

    fn lock_sessions(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, Arc<Mutex<LspClientState>>>>, CoreError> {
        self.sessions.lock().map_err(|_| {
            CoreError::new(ErrorCode::Unknown, "LSP session registry lock is poisoned")
        })
    }

    fn lock_session(
        session: &Mutex<LspClientState>,
    ) -> Result<MutexGuard<'_, LspClientState>, CoreError> {
        session
            .lock()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "LSP session lock is poisoned"))
    }
}

fn required<T>(value: Option<T>, field: &str) -> Result<T, CoreError> {
    value.ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Missing LSP session request field",
        )
        .with_details(field)
    })
}

fn missing_session(session_id: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Unknown LSP session handle").with_details(session_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn request(action: LspSessionAction) -> LspSessionCommandRequest {
        serde_json::from_value(json!({ "action": action_name(action) })).unwrap()
    }

    fn action_name(action: LspSessionAction) -> &'static str {
        match action {
            LspSessionAction::Create => "create",
            LspSessionAction::OpenDocument => "openDocument",
            LspSessionAction::ChangeDocument => "changeDocument",
            LspSessionAction::CloseDocument => "closeDocument",
            LspSessionAction::Shutdown => "shutdown",
            LspSessionAction::Request => "request",
            LspSessionAction::ApplyServerMessage => "applyServerMessage",
            LspSessionAction::Destroy => "destroy",
        }
    }

    #[test]
    fn host_owns_state_across_document_changes() {
        let host = LspHost::new();
        let mut create = request(LspSessionAction::Create);
        create.root_uri = Some("file:///tmp/project".to_string());
        let created = host.execute(create).unwrap();

        let mut initialized = request(LspSessionAction::ApplyServerMessage);
        initialized.session_id = Some(created.session_id.clone());
        initialized.message = Some(
            json!({
                "jsonrpc": "2.0",
                "id": "1",
                "result": { "capabilities": { "completionProvider": {} } }
            })
            .to_string(),
        );
        let initialized = host.execute(initialized).unwrap();
        assert_eq!(initialized.server_capabilities, vec!["completion"]);

        let mut open = request(LspSessionAction::OpenDocument);
        open.session_id = Some(created.session_id.clone());
        open.uri = Some("file:///tmp/project/main.go".to_string());
        open.language_id = Some("go".to_string());
        open.text = Some("package main".to_string());
        assert_eq!(host.execute(open).unwrap().messages.len(), 1);

        let mut change = request(LspSessionAction::ChangeDocument);
        change.session_id = Some(created.session_id.clone());
        change.uri = Some("file:///tmp/project/main.go".to_string());
        change.text = Some("package main\nfunc main() {}".to_string());
        assert_eq!(host.execute(change).unwrap().messages.len(), 1);

        let mut destroy = request(LspSessionAction::Destroy);
        destroy.session_id = Some(created.session_id.clone());
        host.execute(destroy).unwrap();

        let mut stale = request(LspSessionAction::Shutdown);
        stale.session_id = Some(created.session_id);
        assert!(host.execute(stale).is_err());
    }

    #[test]
    fn host_isolates_open_documents_between_sessions() {
        let host = LspHost::new();
        let mut first_create = request(LspSessionAction::Create);
        first_create.root_uri = Some("file:///tmp/first".to_string());
        let first = host.execute(first_create).unwrap();
        let mut second_create = request(LspSessionAction::Create);
        second_create.root_uri = Some("file:///tmp/second".to_string());
        let second = host.execute(second_create).unwrap();

        let mut open = request(LspSessionAction::OpenDocument);
        open.session_id = Some(first.session_id);
        open.uri = Some("file:///tmp/first/main.go".to_string());
        open.language_id = Some("go".to_string());
        open.text = Some("package main".to_string());
        host.execute(open).unwrap();

        let mut change = request(LspSessionAction::ChangeDocument);
        change.session_id = Some(second.session_id);
        change.uri = Some("file:///tmp/first/main.go".to_string());
        change.text = Some("package changed".to_string());
        assert!(host.execute(change).is_err());
    }

    #[test]
    fn session_requests_reject_unknown_fields() {
        let error = serde_json::from_value::<LspSessionCommandRequest>(json!({
            "action": "create",
            "rootUri": "file:///tmp/project",
            "unexpected": true
        }))
        .unwrap_err();

        assert!(error.to_string().contains("unknown field `unexpected`"));
    }
}
