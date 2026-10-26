//! Transport ownership and waiter bookkeeping, independent of Tauri and time.

use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::{oneshot, Notify};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProviderContext {
    pub window: String,
    pub workspace_root: String,
    /// Original native workspace path used by existing settings/state adapters.
    /// Canonical identity above must not change their persisted directory key.
    pub launch_workspace_root: String,
    pub generation: u64,
    pub plugin_id: String,
    /// Canonical package directory and the digest of every package file.
    pub package_identity: String,
    pub build_system: String,
    /// Core's normalized workspace-relative root, forwarded byte-for-byte.
    pub instance_root: String,
    pub instance_directory: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProviderError {
    pub code: &'static str,
    pub detail: String,
}

impl ProviderError {
    pub(super) fn new(code: &'static str, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }
}

pub(super) type Reply = Result<Value, ProviderError>;

pub(super) fn same_root(left: &str, right: &str) -> bool {
    #[cfg(windows)]
    {
        let normalize = |value: &str| {
            let value = value
                .replace('\\', "/")
                .trim_end_matches('/')
                .to_lowercase();
            if let Some(unc) = value.strip_prefix("//?/unc/") {
                format!("//{unc}")
            } else {
                value.trim_start_matches("//?/").to_owned()
            }
        };
        normalize(left) == normalize(right)
    }
    #[cfg(not(windows))]
    {
        left == right
    }
}

/// This adapter calls the existing engine; tests script the boundary, never
/// supply a second JSON-RPC parser or build result interpreter.
pub(super) trait Core: Send + Sync {
    fn execute(&self, command: &str, payload: Value) -> Reply;
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply;
}

#[derive(Default)]
pub(super) struct Status {
    pub generation: u64,
    pub open_waiters: usize,
    pub bound: bool,
    pub session_id: Option<String>,
    pub launch_finished: bool,
    pub disposed: bool,
    pub revoked: bool,
    pub ready: bool,
    pub negotiated: bool,
    pub features_received: bool,
    pub failure: Option<ProviderError>,
    pub(super) pending: HashMap<String, oneshot::Sender<Reply>>,
}

pub(super) struct Transport {
    pub id: u64,
    pub context: ProviderContext,
    /// Some only for an existing same-plugin language session. Its sole
    /// event consumer remains the editor; the native Core bridge copies events.
    pub language: Option<String>,
    pub launch_plan: Option<Value>,
    pub status: Mutex<Status>,
    pub changed: Notify,
    pub stopping: tokio::sync::Mutex<()>,
    pub core: Arc<dyn Core>,
    /// Retained across crashes, cancelled starts and failed disposal. Dropping
    /// an arbitrary ProviderBinding never releases package ownership.
    pub lease: Mutex<Option<super::super::lifecycle::NativeLease>>,
}

impl Transport {
    pub fn matches_owner(&self, context: &ProviderContext) -> bool {
        self.context.window == context.window
            && self.context.workspace_root == context.workspace_root
            && self.status.lock().expect("provider session").generation == context.generation
            && self.context.plugin_id == context.plugin_id
            && self.context.package_identity == context.package_identity
    }

    pub fn matches_shared(&self, context: &ProviderContext, language: &str) -> bool {
        self.matches_owner(context)
            && self.language.as_deref() == Some(language)
            && !self.status.lock().expect("provider session").revoked
    }

    pub fn observe(&self, event: &Value) {
        let mut status = self.status.lock().expect("provider session");
        if event["sessionId"].as_str() != status.session_id.as_deref() {
            return;
        }
        if status.revoked {
            return;
        }
        match event["type"].as_str() {
            Some("featuresChanged") => {
                status.features_received = true;
                status.negotiated = event["capabilities"]
                    .as_array()
                    .is_some_and(|items| items.iter().any(|feature| feature == "litheBuild"));
            }
            Some("stateChanged") => match event["state"].as_str() {
                Some("ready") => status.ready = true,
                Some("stopping" | "stopped" | "failed") => {
                    fail(
                        &mut status,
                        ProviderError::new("provider.sessionEnded", event.to_string()),
                    );
                }
                _ => {}
            },
            Some("requestCompleted") => {
                if let Some(operation) = event["operationId"].as_str() {
                    if let Some(waiter) = status.pending.remove(operation) {
                        let reply = if !event["error"].is_null() {
                            Err(ProviderError::new(
                                "provider.requestFailed",
                                event["error"].to_string(),
                            ))
                        } else if let Some(value) = event["result"].get("value") {
                            Ok(value.clone())
                        } else {
                            Err(ProviderError::new(
                                "provider.invalidResult",
                                "Core returned no provider value",
                            ))
                        };
                        let _ = waiter.send(reply);
                    }
                }
            }
            _ => {}
        }
        drop(status);
        self.changed.notify_waiters();
    }

    pub fn revoke(&self, error: ProviderError) {
        fail(&mut self.status.lock().expect("provider session"), error);
        self.changed.notify_waiters();
    }

    pub fn queue(&self, operation: &str) -> Result<oneshot::Receiver<Reply>, ProviderError> {
        let mut status = self.status.lock().expect("provider session");
        if status.revoked || !status.ready || !status.negotiated {
            return Err(status.failure.clone().unwrap_or_else(|| {
                ProviderError::new(
                    "provider.notReady",
                    "Provider has not negotiated litheBuild",
                )
            }));
        }
        if status.pending.contains_key(operation) {
            return Err(ProviderError::new("provider.duplicateOperation", operation));
        }
        if status.pending.len() >= 256 {
            return Err(ProviderError::new(
                "provider.busy",
                "Too many pending native requests",
            ));
        }
        let (sender, receiver) = oneshot::channel();
        status.pending.insert(operation.into(), sender);
        Ok(receiver)
    }

    pub fn finish(&self, operation: &str, result: Reply) {
        if let Some(waiter) = self
            .status
            .lock()
            .expect("provider session")
            .pending
            .remove(operation)
        {
            let _ = waiter.send(result);
        }
    }

    pub fn session_id(&self) -> Result<String, ProviderError> {
        self.status
            .lock()
            .expect("provider session")
            .session_id
            .clone()
            .ok_or_else(|| {
                ProviderError::new("provider.startPending", "Process start has not returned")
            })
    }
}

fn fail(status: &mut Status, error: ProviderError) {
    status.revoked = true;
    status.ready = false;
    status.failure = Some(error.clone());
    for (_, waiter) in status.pending.drain() {
        let _ = waiter.send(Err(error.clone()));
    }
}

/// A native binding cannot be forged from a webview-supplied session ID.
/// Its context keeps each build system and instance separate even when the
/// underlying language process is shared.
#[derive(Clone)]
pub(crate) struct ProviderBinding {
    pub(super) transport: Arc<Transport>,
    pub(super) context: ProviderContext,
    pub(super) approval_plan: Value,
}

impl ProviderBinding {
    pub(crate) fn context(&self) -> &ProviderContext {
        &self.context
    }

    /// Caller supplies only Core's provider plan. This verifies the envelope
    /// identity without interpreting or changing its domain payload.
    pub(super) fn request_payload(&self, operation: &str, plan: &Value, timeout_ms: u64) -> Reply {
        if plan["root"].as_str() != Some(&self.context.instance_root)
            || plan["buildSystemID"].as_str() != Some(&self.context.build_system)
            || plan["provider"]["params"]["root"] != plan["root"]
            || plan["provider"]["params"]["buildSystemID"] != plan["buildSystemID"]
        {
            return Err(ProviderError::new(
                "provider.identityChanged",
                "Core plan does not match its native instance",
            ));
        }
        Ok(json!({
            "sessionId": self.transport.session_id()?, "operationId": operation,
            "method": plan["provider"]["method"], "params": plan["provider"]["params"],
            "timeoutMilliseconds": timeout_ms,
        }))
    }
}
