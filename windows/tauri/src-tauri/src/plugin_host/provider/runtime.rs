//! Bounded native orchestration around Core's existing transport owner.

use super::host::Inner;
use super::session::{Core, ProviderBinding, ProviderError, Reply, Transport};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub(super) struct HostCore;
impl Core for HostCore {
    fn execute(&self, command: &str, payload: Value) -> Reply {
        super::super::scan::core_execute(command, payload)
            .map_err(|detail| ProviderError::new("provider.coreFailed", detail))
    }
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply {
        lithe_core::start_lsp_owned(payload, registered)
            .map_err(|error| ProviderError::new("provider.startFailed", format!("{error:?}")))
    }
}

pub(super) async fn call(
    transport: &Arc<Transport>,
    command: &'static str,
    payload: Value,
) -> Reply {
    let core = transport.core.clone();
    // A wedged write does not strand an async waiter. The native owner and
    // package barrier stay alive while Core's transport maintenance kills it.
    tokio::time::timeout(
        Duration::from_secs(5),
        tauri::async_runtime::spawn_blocking(move || core.execute(command, payload)),
    )
    .await
    .map_err(|_| ProviderError::new("provider.transportTimeout", command))?
    .map_err(|error| ProviderError::new("provider.workerFailed", error.to_string()))?
}

/// Failure leaves the transport in the registry, with its NativeLease. Retry
/// is allowed; package replacement cannot pass wait_native until this succeeds.
pub(super) async fn stop(
    inner: Arc<Inner>,
    transport: Arc<Transport>,
) -> Result<(), ProviderError> {
    transport.revoke(ProviderError::new(
        "provider.cancelled",
        "Native owner closed",
    ));
    let _stopping = tokio::time::timeout(Duration::from_secs(12), transport.stopping.lock())
        .await
        .map_err(|_| {
            ProviderError::new(
                "provider.stopFailed",
                "Another cleanup attempt is still pending",
            )
        })?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        if dispose_once(&inner, &transport).await {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(ProviderError::new(
                "provider.stopFailed",
                "Package retained because process cleanup was not confirmed",
            ));
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

pub(super) async fn dispose_once(inner: &Inner, transport: &Arc<Transport>) -> bool {
    let (finished, disposed, session) = {
        let status = transport.status.lock().expect("provider session");
        (
            status.launch_finished,
            status.disposed,
            status.session_id.clone(),
        )
    };
    if !disposed {
        if let Some(session) = session {
            // A registered session can be stopped while its first write is
            // still returning. Never defer cancellation behind that write.
            let _ = call(transport, "lsp.stopServer", json!({"sessionId":session})).await;
            if call(transport, "lsp.destroyServer", json!({"sessionId":session}))
                .await
                .is_err()
            {
                return false;
            }
            transport.status.lock().expect("provider session").disposed = true;
        } else if !finished {
            return false;
        }
    }
    // A late native launch worker still owns its frozen launch/probe inputs.
    // Keep the package barrier until it has also reached its terminal path.
    if !finished {
        return false;
    }
    inner.release(transport);
    true
}

pub(super) fn pump(inner: Arc<Inner>, transport: Arc<Transport>) {
    tauri::async_runtime::spawn(async move {
        loop {
            if transport.status.lock().expect("provider session").revoked {
                break;
            }
            let Ok(session) = transport.session_id() else {
                break;
            };
            match call(
                &transport,
                "lsp.waitEvents",
                json!({"sessionId":session,"timeoutMilliseconds":250}),
            )
            .await
            {
                Ok(value) => {
                    for event in value["events"].as_array().into_iter().flatten() {
                        transport.observe(event);
                    }
                }
                Err(error) => {
                    transport.revoke(error);
                    break;
                }
            }
        }
        if let Err(error) = stop(inner, transport).await {
            eprintln!(
                "Provider cleanup retained its package barrier: {}",
                error.detail
            );
        }
    });
}

pub(super) async fn ready(transport: &Arc<Transport>) -> Result<(), ProviderError> {
    tokio::time::timeout(Duration::from_secs(12), async {
        loop {
            let changed = transport.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            {
                let status = transport.status.lock().expect("provider session");
                if status.revoked {
                    return Err(status.failure.clone().unwrap_or_else(|| {
                        ProviderError::new("provider.cancelled", "Owner closed")
                    }));
                }
                if status.ready && status.features_received {
                    return if status.negotiated {
                        Ok(())
                    } else {
                        Err(ProviderError::new(
                            "provider.notNegotiated",
                            "Server did not negotiate litheBuild",
                        ))
                    };
                }
            }
            changed.await;
        }
    })
    .await
    .map_err(|_| {
        ProviderError::new(
            "provider.initializeTimeout",
            "Provider initialization timed out",
        )
    })?
}

pub(super) struct OpenGuard(pub Arc<Inner>, pub Option<Arc<Transport>>);
impl OpenGuard {
    pub fn new(inner: Arc<Inner>, transport: Arc<Transport>) -> Self {
        transport
            .status
            .lock()
            .expect("provider session")
            .open_waiters += 1;
        Self(inner, Some(transport))
    }
    pub fn commit(&mut self) {
        if let Some(transport) = self.1.take() {
            let mut status = transport.status.lock().expect("provider session");
            status.open_waiters -= 1;
            status.bound = true;
        }
    }
}
impl Drop for OpenGuard {
    fn drop(&mut self) {
        if let Some(transport) = self.1.take() {
            {
                let mut status = transport.status.lock().expect("provider session");
                status.open_waiters -= 1;
                if status.open_waiters > 0 || status.bound {
                    return;
                }
            }
            let inner = self.0.clone();
            transport.revoke(ProviderError::new(
                "provider.cancelled",
                "Initialization cancelled",
            ));
            cleanup_later(inner, transport);
        }
    }
}

pub(super) fn cleanup_later(inner: Arc<Inner>, transport: Arc<Transport>) {
    tauri::async_runtime::spawn(async move {
        if let Err(error) = stop(inner, transport).await {
            eprintln!(
                "Provider owner retained after failed cleanup: {}",
                error.detail
            );
        }
    });
}

#[derive(Default)]
struct Dispatch {
    cancelled: AtomicBool,
    order: std::sync::Mutex<()>,
}

struct RequestGuard(Arc<Transport>, String, Arc<Dispatch>);
impl Drop for RequestGuard {
    fn drop(&mut self) {
        let transport = self.0.clone();
        let operation = self.1.clone();
        let dispatch = self.2.clone();
        dispatch.cancelled.store(true, Ordering::Release);
        transport.finish(
            &operation,
            Err(ProviderError::new(
                "provider.cancelled",
                "Request cancelled",
            )),
        );
        tauri::async_runtime::spawn(async move {
            if let Ok(session) = transport.session_id() {
                // Serialize cancellation after an already-started Core call.
                // If the pool has not dispatched it, the atomic flag prevents
                // a late buildRequest from starting after its waiter closed.
                let cancelled = tauri::async_runtime::spawn_blocking(move || {
                    let _order = dispatch.order.lock().expect("provider dispatch");
                    transport.core.execute(
                        "lsp.cancelOperation",
                        json!({"sessionId":session,"operationId":operation}),
                    )
                });
                if let Ok(Err(error)) = cancelled.await {
                    eprintln!("Could not cancel Provider request: {}", error.detail);
                }
            }
        });
    }
}

impl ProviderBinding {
    /// `plan` comes unchanged from build.modelPlan/dependencyPlan. No domain
    /// result parsing happens here. The async caller's cancellation drops a
    /// guard that resolves the waiter and cancels Core's operation.
    pub(crate) async fn request(
        &self,
        app: &tauri::AppHandle,
        window: &tauri::WebviewWindow,
        plan: Value,
        timeout_ms: u64,
    ) -> Reply {
        super::host::validate_binding_async(app, window.label(), self).await?;
        let timeout_ms = timeout_ms.clamp(1, 60 * 60 * 1000);
        let operation = format!("native-provider-{}", super::host::next_id());
        let payload = self.request_payload(&operation, &plan, timeout_ms)?;
        let reply = dispatch_request(&self.transport, operation, payload, timeout_ms).await?;
        super::host::validate_binding_async(app, window.label(), self).await?;
        Ok(reply)
    }
}

/// One request waiter owns its dispatch/cancellation ordering, independent of
/// other bindings sharing this transport.
pub(super) async fn dispatch_request(
    transport: &Arc<Transport>,
    operation: String,
    payload: Value,
    timeout_ms: u64,
) -> Reply {
    let receiver = transport.queue(&operation)?;
    let dispatch = Arc::new(Dispatch::default());
    let guard = RequestGuard(transport.clone(), operation.clone(), dispatch.clone());
    let worker = transport.clone();
    let sent = tauri::async_runtime::spawn_blocking(move || {
        let _order = dispatch.order.lock().expect("provider dispatch");
        if dispatch.cancelled.load(Ordering::Acquire)
            || worker.status.lock().expect("provider session").revoked
        {
            return Err(ProviderError::new(
                "provider.cancelled",
                "Request closed before dispatch",
            ));
        }
        worker.core.execute("lsp.buildRequest", payload)
    });
    tokio::time::timeout(Duration::from_secs(5), sent)
        .await
        .map_err(|_| {
            ProviderError::new("provider.transportTimeout", "Provider dispatch timed out")
        })?
        .map_err(|error| ProviderError::new("provider.workerFailed", error.to_string()))??;
    let reply = tokio::time::timeout(Duration::from_millis(timeout_ms), receiver)
        .await
        .map_err(|_| ProviderError::new("provider.requestTimeout", "Provider request timed out"))?
        .map_err(|_| ProviderError::new("provider.sessionEnded", "Provider waiter disconnected"))?;
    drop(guard);
    reply
}
