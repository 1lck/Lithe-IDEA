//! Process-local plugin ownership, operation correlation, and resource barriers.
//!
//! Platforms retain native handles and durable installation records. This registry
//! owns whether an operation may start or commit; an old completion cannot replace
//! a newer operation or forget resources whose platform shutdown failed.

use super::{PluginLifecycle, PluginLifecycleAction, PluginLifecycleState};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

/// One platform composition root's request against a plugin session.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PluginSessionRequest {
    /// Opaque host lifetime, never a filesystem path or a persisted identifier.
    pub owner_id: String,
    /// Stable package identity within that host.
    pub plugin_id: String,
    /// Registry operation; distinct from the package lifecycle action.
    pub action: SessionAction,
    /// Lifecycle action for a transition request.
    pub transition: Option<PluginLifecycleAction>,
    /// Correlates a begin/complete pair and invalidates late completions.
    pub operation_id: Option<String>,
    /// Opaque platform resource handle registered before its first async start.
    pub resource_id: Option<String>,
    /// Restore-only installation fact, read from the platform's verified store.
    #[serde(default)]
    pub installed: bool,
    /// Restore-only enablement fact; restoration never creates native resources.
    #[serde(default)]
    pub enabled: bool,
}

/// Commands accepted by the plugin session registry.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionAction {
    /// Initialize once from verified platform state, preserving an existing session.
    Restore,
    /// Apply a package lifecycle transition.
    Transition,
    /// Reserve an owned resource before starting native work.
    BindResource,
    /// Forget a handle only after the native owner confirms termination.
    ReleaseResource,
    /// Read the authoritative state without changing it.
    Snapshot,
    /// Release an idle session; fails while resources or operations remain.
    Close,
}

/// Authoritative state projected to either platform.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginSessionSnapshot {
    /// Current package lifecycle and sorted resource identifiers.
    pub lifecycle: PluginLifecycle,
    /// Current begin/complete correlation, absent outside a pending operation.
    pub operation_id: Option<String>,
    /// Whether a verified package is installed, independently of activation.
    pub installed: bool,
}

/// Registry whose lifetime is one Core host process.
#[derive(Default)]
pub struct PluginSessionRegistry {
    sessions: BTreeMap<(String, String), PluginSessionSnapshot>,
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn opaque_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
}

impl PluginSessionRegistry {
    /// Applies a request atomically. Rejected transitions leave the registry intact.
    pub fn execute(
        &mut self,
        request: PluginSessionRequest,
    ) -> Result<PluginSessionSnapshot, CoreError> {
        if !opaque_id(&request.owner_id) || !opaque_id(&request.plugin_id) {
            return Err(invalid(
                "Plugin session requires valid ownerId and pluginId",
            ));
        }
        let key = (request.owner_id, request.plugin_id.clone());
        if matches!(request.action, SessionAction::Restore) {
            if request.enabled && !request.installed {
                return Err(invalid("An uninstalled plugin cannot be restored enabled"));
            }
            return Ok(self
                .sessions
                .entry(key)
                .or_insert_with(|| {
                    let mut lifecycle = PluginLifecycle::new(request.plugin_id);
                    lifecycle.state = if request.enabled {
                        PluginLifecycleState::Enabled
                    } else if request.installed {
                        PluginLifecycleState::Installed
                    } else {
                        PluginLifecycleState::Discovered
                    };
                    PluginSessionSnapshot {
                        lifecycle,
                        operation_id: None,
                        installed: request.installed,
                    }
                })
                .clone());
        }
        let mut session = self
            .sessions
            .get(&key)
            .cloned()
            .ok_or_else(|| invalid("Plugin session has not been restored"))?;
        match request.action {
            SessionAction::Restore => unreachable!(),
            SessionAction::Snapshot => return Ok(session),
            SessionAction::Close => {
                if !session.lifecycle.resources.is_empty() || session.operation_id.is_some() {
                    return Err(invalid(
                        "Plugin session still owns resources or an operation",
                    ));
                }
                self.sessions.remove(&key);
                return Ok(session);
            }
            SessionAction::BindResource => {
                let resource = request
                    .resource_id
                    .filter(|id| opaque_id(id))
                    .ok_or_else(|| invalid("Plugin resource requires a nonempty resourceId"))?;
                if session.lifecycle.resources.contains(&resource) {
                    return Err(invalid("Plugin resource is already registered"));
                }
                session
                    .lifecycle
                    .bind_resource(resource)
                    .map_err(|error| invalid(&error.to_string()))?;
            }
            SessionAction::ReleaseResource => {
                let resource = request
                    .resource_id
                    .filter(|id| opaque_id(id))
                    .ok_or_else(|| invalid("Plugin resource requires a nonempty resourceId"))?;
                session.lifecycle.unbind_resource(&resource);
            }
            SessionAction::Transition => {
                let action = request
                    .transition
                    .ok_or_else(|| invalid("Missing plugin transition"))?;
                let operation = request
                    .operation_id
                    .filter(|id| opaque_id(id))
                    .ok_or_else(|| invalid("Plugin transition requires operationId"))?;
                use PluginLifecycleAction as Action;
                let begins = matches!(
                    action,
                    Action::BeginInstall | Action::Enable | Action::Disable | Action::Uninstall
                );
                let completes = matches!(
                    action,
                    Action::CompleteInstall
                        | Action::CompleteEnable
                        | Action::CompleteDisable
                        | Action::CompleteUninstall
                );
                if completes && session.operation_id.as_ref() != Some(&operation) {
                    return Err(invalid("Plugin operation completion is stale"));
                }
                if begins && session.operation_id.is_some() && action != Action::Disable {
                    return Err(invalid("Plugin operation is already running"));
                }
                if action == Action::Enable && !session.installed {
                    return Err(invalid("Cannot enable an uninstalled plugin"));
                }
                if action == Action::Fail
                    && session.operation_id.is_some()
                    && session.operation_id.as_ref() != Some(&operation)
                {
                    return Err(invalid("Plugin operation failure is stale"));
                }
                session
                    .lifecycle
                    .apply(action, &operation)
                    .map_err(|error| invalid(&error.to_string()))?;
                if action == Action::CompleteInstall {
                    session.installed = true;
                }
                if action == Action::CompleteUninstall {
                    session.installed = false;
                }
                if begins {
                    session.operation_id = Some(operation);
                } else if completes
                    || matches!(
                        action,
                        Action::Fail | Action::Reset | Action::RequireRestart
                    )
                {
                    session.operation_id = None;
                }
            }
        }
        self.sessions.insert(key, session.clone());
        Ok(session)
    }
}

/// Executes one JSON command against the host-owned registry.
pub fn execute(request: PluginSessionRequest) -> Result<PluginSessionSnapshot, CoreError> {
    static REGISTRY: OnceLock<Mutex<PluginSessionRegistry>> = OnceLock::new();
    REGISTRY
        .get_or_init(Mutex::default)
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Plugin session registry is unavailable"))?
        .execute(request)
}
