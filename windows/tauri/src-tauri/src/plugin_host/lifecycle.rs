//! Package mutation barrier. Revoke plans before asking each product window
//! to drain its process owners; only acknowledgements from that window count.
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};
use tokio::sync::oneshot;

#[derive(Default)]
pub struct LifecycleState {
    access: Arc<NativeAccess>,
    pending: Mutex<HashMap<String, HashMap<String, oneshot::Sender<Result<(), String>>>>>,
    changing: Mutex<HashSet<String>>,
}

#[derive(Default)]
struct AccessState {
    blocked: HashSet<String>,
    probes: HashMap<String, usize>,
}
#[derive(Default)]
struct NativeAccess {
    state: Mutex<AccessState>,
    changed: tokio::sync::Notify,
}

impl LifecycleState {
    pub fn blocked(&self, plugin_id: &str) -> bool {
        self.access
            .state
            .lock()
            .expect("native plugin access")
            .blocked
            .contains(plugin_id)
    }
    /// Register before any native probe or package read. Revocation and
    /// acquisition share one lock, so a mutation cannot miss a late probe.
    pub fn acquire(&self, plugin_id: &str) -> Result<NativeLease, String> {
        let mut state = self.access.state.lock().expect("native plugin access");
        if state.blocked.contains(plugin_id) {
            return Err("plugin is inactive or changing version".into());
        }
        *state.probes.entry(plugin_id.into()).or_default() += 1;
        Ok(NativeLease {
            access: self.access.clone(),
            plugin_id: plugin_id.into(),
        })
    }
    fn revoke(&self, plugin_id: &str) {
        self.access
            .state
            .lock()
            .expect("native plugin access")
            .blocked
            .insert(plugin_id.into());
    }
    async fn wait_native(&self, plugin_id: &str) -> Result<(), String> {
        tokio::time::timeout(std::time::Duration::from_secs(45), async {
            loop {
                let changed = self.access.changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if self
                    .access
                    .state
                    .lock()
                    .expect("native plugin access")
                    .probes
                    .get(plugin_id)
                    .copied()
                    .unwrap_or(0)
                    == 0
                {
                    return;
                }
                changed.await;
            }
        })
        .await
        .map_err(|_| "native plugin probes did not exit; package files were preserved".into())
    }
}

pub struct NativeLease {
    access: Arc<NativeAccess>,
    plugin_id: String,
}
impl Drop for NativeLease {
    fn drop(&mut self) {
        let mut state = self.access.state.lock().expect("native plugin access");
        if let Some(count) = state.probes.get_mut(&self.plugin_id) {
            *count -= 1;
            if *count == 0 {
                state.probes.remove(&self.plugin_id);
            }
        }
        drop(state);
        self.access.changed.notify_waiters();
    }
}

/// One operation owns the plugin until its catalog and files are consistent.
/// Failure leaves launches revoked; retry/enable can explicitly recover it.
pub struct Mutation {
    app: AppHandle,
    plugin_id: String,
    operation_id: String,
}
impl Drop for Mutation {
    fn drop(&mut self) {
        let state = self.app.state::<LifecycleState>();
        state
            .pending
            .lock()
            .expect("plugin barriers")
            .remove(&self.operation_id);
        state
            .changing
            .lock()
            .expect("plugin mutations")
            .remove(&self.plugin_id);
    }
}
impl Mutation {
    pub(crate) fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    pub fn complete(self, active: bool) {
        self.app
            .state::<LifecycleState>()
            .access
            .state
            .lock()
            .expect("native plugin access")
            .blocked
            .remove(&self.plugin_id);
        let _ = self.app.emit(
            "declarative-plugin-lifecycle",
            serde_json::json!({
                "pluginId": self.plugin_id, "active": active,
            }),
        );
    }
}

pub async fn begin(app: &AppHandle, plugin_id: &str) -> Result<Mutation, String> {
    let state = app.state::<LifecycleState>();
    if !state
        .changing
        .lock()
        .expect("plugin mutations")
        .insert(plugin_id.to_string())
    {
        return Err("another mutation already owns this plugin".into());
    }
    let operation_id = super::store::workspace_state_key(&format!(
        "{}-{:?}",
        plugin_id,
        std::time::SystemTime::now()
    ));
    let mutation = Mutation {
        app: app.clone(),
        plugin_id: plugin_id.into(),
        operation_id: operation_id.clone(),
    };
    state.revoke(plugin_id);
    let mut senders = HashMap::new();
    let mut receivers = Vec::new();
    for label in app
        .webview_windows()
        .keys()
        .filter(|label| label.as_str() == "main" || label.starts_with("workspace-"))
    {
        let (sender, receiver) = oneshot::channel();
        senders.insert(label.clone(), sender);
        receivers.push((label.clone(), receiver));
    }
    let labels: Vec<_> = senders.keys().cloned().collect();
    state
        .pending
        .lock()
        .expect("plugin barriers")
        .insert(operation_id.clone(), senders);
    for label in labels {
        app.emit_to(
            label,
            "declarative-plugin-lifecycle",
            serde_json::json!({
                "pluginId": plugin_id, "active": false, "operationId": operation_id,
            }),
        )
        .map_err(|error| error.to_string())?;
    }
    // Tell UI owners to cancel first: their in-flight native operations also
    // hold leases. Waiting for those leases before dispatching cancellation
    // deadlocks a reload behind work that only the owner can cancel.
    super::project_generators::close_plugin(app, plugin_id)
        .await
        .map_err(|error| error.code)?;
    super::vcs::plugin_changing(app, plugin_id).await?;
    super::functions::close_plugin(app, plugin_id).await?;
    super::provider::close_plugin(app, plugin_id)
        .await
        .map_err(|error| error.detail)?;
    super::web::close_plugin_windows(app, plugin_id)?;
    state.wait_native(plugin_id).await?;
    await_drained(receivers, std::time::Duration::from_secs(45)).await?;
    Ok(mutation)
}

async fn await_drained(
    receivers: Vec<(String, oneshot::Receiver<Result<(), String>>)>,
    timeout: std::time::Duration,
) -> Result<(), String> {
    tokio::time::timeout(timeout, async {
        for (label, receiver) in receivers {
            receiver
                .await
                .map_err(|_| format!("process owner {label} disconnected"))??;
        }
        Ok::<_, String>(())
    })
    .await
    .map_err(|_| "plugin process stop timed out; package files were preserved".to_string())?
}

#[tauri::command]
pub fn declarative_plugins_lifecycle_ack(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
    error: Option<String>,
) -> Result<(), String> {
    let state = app.state::<LifecycleState>();
    let sender = state
        .pending
        .lock()
        .expect("plugin barriers")
        .get_mut(&operation_id)
        .and_then(|pending| pending.remove(window.label()))
        .ok_or("unknown plugin mutation acknowledgement")?;
    let _ = sender.send(error.map_or(Ok(()), Err));
    Ok(())
}

pub fn window_destroyed<R: tauri::Runtime>(app: &AppHandle<R>, label: &str) {
    // A closed UI window can still own Core processes. Do not count destruction
    // as a successful drain: fail the mutation and preserve the package.
    for pending in app
        .state::<LifecycleState>()
        .pending
        .lock()
        .expect("plugin barriers")
        .values_mut()
    {
        if let Some(sender) = pending.remove(label) {
            let _ = sender.send(Err(
                "process owner window closed before acknowledgement".into()
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn mutation_drains_native_probes_and_rejects_late_acquisition() {
        let state = LifecycleState::default();
        let probe = state.acquire("test.plugin").unwrap();
        state.revoke("test.plugin");
        assert!(state.acquire("test.plugin").is_err());
        let waiting = state.wait_native("test.plugin");
        tokio::pin!(waiting);
        tokio::select! { biased;
            result = &mut waiting => panic!("mutation advanced while native probe owns package: {result:?}"),
            _ = std::future::ready(()) => {},
        }
        drop(probe);
        waiting.await.unwrap();
    }

    #[tokio::test]
    async fn failed_global_stop_retains_the_old_lease_and_retry_does_not_revoke_other_plugins() {
        let state = LifecycleState::default();
        let old_owner = state.acquire("target.plugin").unwrap();
        let other_owner = state.acquire("other.plugin").unwrap();
        state.revoke("target.plugin");
        let (failed, failed_result) = oneshot::channel();
        failed.send(Err("process still running".into())).unwrap();
        assert!(await_drained(
            vec![("first".into(), failed_result)],
            std::time::Duration::from_secs(1)
        )
        .await
        .is_err());
        assert!(state.blocked("target.plugin"));
        assert!(state.acquire("target.plugin").is_err());
        assert!(state.acquire("other.plugin").is_ok());
        let retry = state.wait_native("target.plugin");
        tokio::pin!(retry);
        tokio::select! { biased;
            result = &mut retry => panic!("failed stop discarded its old lease: {result:?}"),
            _ = std::future::ready(()) => {},
        }
        drop(old_owner);
        // The unrelated owner's lease cannot hold up the target retry.
        retry.await.unwrap();
        assert!(state.blocked("target.plugin"));
        drop(other_owner);
    }

    #[tokio::test]
    async fn mutation_waits_for_every_window_and_propagates_stop_failure() {
        let (first, first_result) = oneshot::channel();
        let (second, second_result) = oneshot::channel();
        let drain = await_drained(
            vec![
                ("first".into(), first_result),
                ("second".into(), second_result),
            ],
            std::time::Duration::from_secs(1),
        );
        tokio::pin!(drain);
        second.send(Ok(())).unwrap();
        // Poll once with only the second window released: the mutation cannot advance.
        tokio::select! { biased;
            result = &mut drain => panic!("mutation advanced without its first owner: {result:?}"),
            _ = std::future::ready(()) => {},
        }
        first.send(Err("executable still in use".into())).unwrap();
        assert_eq!(drain.await.unwrap_err(), "executable still in use");
    }

    #[tokio::test]
    async fn mutation_refuses_disconnected_or_unresponsive_owners() {
        let (sender, receiver) = oneshot::channel();
        drop(sender);
        assert!(await_drained(
            vec![("closed".into(), receiver)],
            std::time::Duration::from_secs(1)
        )
        .await
        .unwrap_err()
        .contains("disconnected"));
        let (_sender, receiver) = oneshot::channel();
        assert!(
            await_drained(vec![("busy".into(), receiver)], std::time::Duration::ZERO)
                .await
                .unwrap_err()
                .contains("files were preserved")
        );
    }
}
