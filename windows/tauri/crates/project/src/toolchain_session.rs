//! Bounded, operation-owned toolchain transport over Core's existing LSP engine.
//! No framing, child-process manager or provider protocol is reimplemented here.
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    time::{Duration, Instant},
};

const UNAVAILABLE: &str = "toolchain.native.providerUnavailable";

/// Owns one negotiated process until explicit close or unwinding cleanup.
pub struct BackendSession {
    id: Option<String>,
    providers: BTreeSet<String>,
    ready: bool,
}
impl BackendSession {
    /// Launches without waiting, so the caller can register ownership before
    /// initialization. A failed initialization must still be explicitly closed.
    pub fn launch(
        mut launch: Value,
        remaining: Duration,
        mut current: impl FnMut() -> Result<(), String>,
    ) -> Result<Self, String> {
        let deadline = Instant::now() + remaining;
        current()?;
        launch["initializeTimeoutMilliseconds"] = json!(budget(deadline)?.min(5000));
        launch["requestTimeoutMilliseconds"] = json!(budget(deadline)?);
        launch["shutdownTimeoutMilliseconds"] = json!(1000);
        let started = core("lsp.startServer", launch)?;
        Ok(Self {
            id: Some(started["sessionId"].as_str().ok_or(UNAVAILABLE)?.into()),
            providers: BTreeSet::new(),
            ready: false,
        })
    }

    /// Waits for negotiation while the caller already owns this session.
    pub fn initialize(
        &mut self,
        remaining: Duration,
        mut current: impl FnMut() -> Result<(), String>,
    ) -> Result<(), String> {
        let deadline = Instant::now() + remaining;
        let mut seen = 0;
        while !self.ready {
            current()?;
            for event in self.events(deadline)? {
                seen += 1;
                if seen > 4096 {
                    return Err(UNAVAILABLE.into());
                }
                if event["type"] == "toolchainProviders" {
                    self.providers = event["result"]["providers"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|value| value.as_str().map(str::to_owned))
                        .collect();
                }
                if event["type"] == "stateChanged" {
                    if event["state"] == "ready" {
                        self.ready = true;
                    } else if matches!(event["state"].as_str(), Some("failed" | "stopped")) {
                        return Err(UNAVAILABLE.into());
                    }
                }
            }
        }
        current()?;
        Ok(())
    }

    /// Returns the complete JSON-RPC wire envelope, never an implicitly trusted reply.
    pub fn query(
        &self,
        provider: &str,
        params: &Value,
        remaining: Duration,
        mut current: impl FnMut() -> Result<(), String>,
    ) -> Result<Value, String> {
        if !self.ready || !self.providers.contains(provider) || params["providerID"] != provider {
            return Err(UNAVAILABLE.into());
        }
        let deadline = Instant::now() + remaining;
        current()?;
        let operation = core(
            "lsp.toolchainRequest",
            json!({"sessionId":self.id.as_ref().ok_or(UNAVAILABLE)?,
            "params":params,"timeoutMilliseconds":budget(deadline)?}),
        )?;
        let operation = operation["operationId"].as_str().ok_or(UNAVAILABLE)?;
        let mut seen = 0;
        loop {
            current()?;
            for event in self.events(deadline)? {
                seen += 1;
                if seen > 4096 {
                    return Err(UNAVAILABLE.into());
                }
                if event["type"] == "stateChanged"
                    && matches!(event["state"].as_str(), Some("failed" | "stopped"))
                {
                    return Err(UNAVAILABLE.into());
                }
                if event["operationId"] != operation {
                    continue;
                }
                if event["type"] == "requestCompleted" {
                    if event.get("error").is_some() {
                        return Err(UNAVAILABLE.into());
                    }
                    current()?;
                    return Ok(event["result"]["value"].clone());
                }
                if event["type"] == "requestFailed" {
                    return Err(UNAVAILABLE.into());
                }
            }
        }
    }

    /// Core performs bounded shutdown and process-tree cleanup. A failed close
    /// retains ownership so a caller or the unwinding fallback can retry it.
    pub fn close(&mut self) -> Result<(), String> {
        if let Some(id) = &self.id {
            core("lsp.stopServer", json!({"sessionId":id}))?;
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if core("lsp.destroyServer", json!({"sessionId":id})).is_ok() {
                    break;
                }
                self.events(deadline)?;
            }
            self.id = None;
        }
        Ok(())
    }

    fn events(&self, deadline: Instant) -> Result<Vec<Value>, String> {
        let reply = core(
            "lsp.waitEvents",
            json!({"sessionId":self.id.as_ref().ok_or(UNAVAILABLE)?,
            "timeoutMilliseconds":budget(deadline)?.min(50)}),
        )?;
        reply["events"]
            .as_array()
            .cloned()
            .ok_or_else(|| UNAVAILABLE.into())
    }
}
impl Drop for BackendSession {
    fn drop(&mut self) {
        if self.close().is_err() {
            log::warn!("Toolchain backend cleanup failed after its bounded Core shutdown");
        }
    }
}
fn budget(deadline: Instant) -> Result<u64, String> {
    let remaining = deadline
        .saturating_duration_since(Instant::now())
        .as_millis();
    if remaining == 0 {
        return Err(UNAVAILABLE.into());
    }
    Ok(remaining.min(10_000) as u64)
}
fn core(command: &str, payload: Value) -> Result<Value, String> {
    let reply: Value = serde_json::from_str(&lithe_core::execute_json(
        &json!({"command":command,"payload":payload}).to_string(),
    ))
    .map_err(|_| UNAVAILABLE)?;
    if reply["ok"] != true {
        return Err(UNAVAILABLE.into());
    }
    Ok(reply["data"].clone())
}

#[cfg(test)]
mod tests;
