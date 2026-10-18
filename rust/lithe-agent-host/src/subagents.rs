//! Compatibility for the pinned adapters' AIR native child-session extension.
//!
//! Keep standard ACP updates validated by the SDK. The adapters currently emit
//! `subagent_spawned`/`subagent_state_update`; newer SDKs instead implement the
//! incompatible `subagent_update` proposal. Remove this wire shim when the pinned
//! adapters and SDK agree. Transport, child execution and history stay upstream.

use std::collections::{HashMap, HashSet};

use agent_client_protocol::schema::v1::{SessionId, SessionUpdate};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Existing session notification with only the negotiated AIR update variants added.
#[derive(Debug, Clone, Deserialize, Serialize, agent_client_protocol::JsonRpcNotification)]
#[notification(method = "session/update")]
#[serde(rename_all = "camelCase")]
pub(crate) struct Notification {
    pub session_id: SessionId,
    pub update: Update,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn native_and_standard_notifications_round_trip_the_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/agent/acp-events-v1.json"
        ))
        .unwrap();
        for name in [
            "subagentSpawned",
            "nestedSubagentSpawned",
            "subagentStateUpdate",
            "subagentMessageChunk",
            "subagentThoughtChunk",
            "subagentToolCall",
            "toolCall",
        ] {
            let event = &fixture["events"][name];
            let notification = json!({"sessionId":event["sessionId"], "update":event["update"]});
            let parsed: Notification = serde_json::from_value(notification.clone()).unwrap();
            assert_eq!(
                serde_json::to_value(parsed).unwrap(),
                notification,
                "{name}"
            );
        }
    }

    #[test]
    fn child_ownership_rejects_cycles_cross_roots_and_terminal_permissions() {
        let spawn = |id: &str| json!({"sessionUpdate":"subagent_spawned", "subagentSessionId":id});
        let mut sessions = Sessions::default();
        sessions.note_root("one");
        sessions.note_root("two");
        assert!(sessions.observe("one", &spawn("child")));
        assert!(sessions.observe("child", &spawn("nested")));
        assert_eq!(sessions.root("nested").as_deref(), Some("one"));
        assert!(!sessions.observe("two", &spawn("child")));
        assert!(!sessions.observe("nested", &spawn("one")));
        assert!(!sessions.observe("one", &spawn("two")));
        assert!(!sessions.observe("child", &spawn("child")));
        assert!(sessions.observe("one", &json!({"sessionUpdate":"subagent_state_update", "subagentSessionId":"child", "state":"completed"})));
        assert!(!sessions.is_live("child"));
        assert!(!sessions.is_live("nested"));
        assert!(sessions.is_live("one"));
        sessions.clear("one");
        assert_eq!(sessions.root("nested").as_deref(), Some("nested"));
        assert!(
            sessions.observe("one", &spawn("child")),
            "Reload can announce the same child anew"
        );
        assert!(sessions.is_live("child"));
    }
}

/// The SDK owns all ordinary update validation and serialization.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum Update {
    Native(NativeUpdate),
    Standard(SessionUpdate),
}

/// Draft wire forms actually published by claude-agent-acp 0.81.2 and codex-acp 1.13.1.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "sessionUpdate",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub(crate) enum NativeUpdate {
    SubagentSpawned {
        subagent_session_id: String,
        name: String,
        task: String,
        capabilities: Value,
        #[serde(flatten)]
        extra: serde_json::Map<String, Value>,
    },
    SubagentStateUpdate {
        subagent_session_id: String,
        state: String,
        #[serde(flatten)]
        extra: serde_json::Map<String, Value>,
    },
}

/// Connection-local ownership, used to charge child activity and permissions to
/// the existing root turn. It never launches, subscribes to or prompts a child.
#[derive(Default)]
pub(crate) struct Sessions {
    parents: HashMap<String, String>,
    terminal: HashSet<String>,
    roots: HashSet<String>,
}

impl Sessions {
    pub(crate) fn note_root(&mut self, session: &str) {
        self.roots.insert(session.to_owned());
    }

    /// Resolve the root with a bounded walk; unannounced sessions own themselves.
    pub(crate) fn root(&self, session: &str) -> Option<String> {
        let mut current = session;
        for _ in 0..=self.parents.len() {
            match self.parents.get(current) {
                Some(parent) => current = parent,
                None => return Some(current.to_owned()),
            }
        }
        None
    }

    /// Terminal children cannot request new permissions or revive root activity.
    pub(crate) fn is_live(&self, session: &str) -> bool {
        let mut current = session;
        for _ in 0..=self.parents.len() {
            if self.terminal.contains(current) {
                return false;
            }
            match self.parents.get(current) {
                Some(parent) => current = parent,
                None => return true,
            }
        }
        false
    }

    /// Reject cycles and cross-parent reattachment, preserving permission ownership.
    pub(crate) fn observe(&mut self, parent: &str, update: &Value) -> bool {
        match update["sessionUpdate"].as_str() {
            Some("subagent_spawned") => {
                let Some(child) = update["subagentSessionId"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                else {
                    return false;
                };
                if self.roots.contains(child)
                    || child == parent
                    || self.root(parent).as_deref() == Some(child)
                    || self.parents.get(child).is_some_and(|old| old != parent)
                {
                    return false;
                }
                self.parents.insert(child.to_owned(), parent.to_owned());
            }
            Some("subagent_state_update") => {
                let Some(child) = update["subagentSessionId"].as_str() else {
                    return false;
                };
                if self.parents.get(child).map(String::as_str) != Some(parent) {
                    return false;
                }
                if matches!(
                    update["state"].as_str(),
                    Some("completed" | "failed" | "cancelled" | "disconnected")
                ) {
                    self.terminal.insert(child.to_owned());
                }
            }
            _ => {}
        }
        true
    }

    /// A root history reload announces its children again before replaying them.
    pub(crate) fn clear(&mut self, root: &str) {
        let children: Vec<_> = self
            .parents
            .keys()
            .filter(|child| self.root(child).as_deref() == Some(root))
            .cloned()
            .collect();
        for child in children {
            self.parents.remove(&child);
            self.terminal.remove(&child);
        }
    }
}
