//! Injected scalar failure facts; the owning Core supplies the only log writer.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// Complete catalog surface emitted by this adapter.
pub const EVENTS: &[&str] = &[
    "remote.client.operation_failed",
    "remote.forward.accept_failed",
    "remote.forward.connection_failed",
];

/// Borrowed scalar fields; callers supply only fixed summaries and stable categories.
pub type Fields<'a> = &'a [(&'static str, Value)];
/// Process-owned callback; no file writer or dependency on Core lives here.
pub type FailureSink = fn(&str, Fields<'_>);

#[derive(Default)]
struct Hook {
    sink: OnceLock<FailureSink>,
    missed: AtomicU64,
}
impl Hook {
    fn install(&self, sink: FailureSink) {
        self.sink.get_or_init(|| sink);
    }
    fn emit(&self, event: &str, fields: Fields<'_>) {
        if let Some(sink) = self.sink.get() {
            sink(event, fields);
        } else {
            self.missed.fetch_add(1, Ordering::Relaxed);
        }
    }
}
static HOOK: Hook = Hook {
    sink: OnceLock::new(),
    missed: AtomicU64::new(0),
};

/// First installation wins; repeated installation never resets the callback.
pub fn install_failure_sink(sink: FailureSink) {
    HOOK.install(sink);
}
/// Failures observed before the owning process installed its sink.
pub fn uninstalled_count() -> u64 {
    HOOK.missed.load(Ordering::Relaxed)
}
/// No error display text is accepted: only caller-controlled categories cross the hook.
pub(crate) fn failed(event: &str, stage: &'static str, code: &str, domain: &'static str) {
    HOOK.failed(event, stage, code, domain);
}
impl Hook {
    fn failed(&self, event: &str, stage: &'static str, code: &str, domain: &'static str) {
        self.emit(
            event,
            &[
                ("stage", json!(stage)),
                ("error", json!("Helper operation failed")),
                ("error_code", json!(code)),
                ("error_domain", json!(domain)),
            ],
        );
    }
    fn teardown<T>(&self, event: &str, stage: &'static str, result: std::io::Result<T>) {
        match result {
            Ok(_) => {}
            // log-exempt: 预期的缺失：对端已经断开，没有仍需关闭或传输的连接。
            Err(error) if disconnected_io(error.kind()) => {}
            Err(error) => self.failed(event, stage, &format!("{:?}", error.kind()), "io"),
        }
    }
}

/// Connection teardown only reports errors that lose a cleanup result.
pub(crate) fn teardown<T>(event: &str, stage: &'static str, result: std::io::Result<T>) {
    HOOK.teardown(event, stage, result);
}

/// Preserve the stable I/O category without copying paths or error messages.
pub(crate) fn io<T>(event: &str, stage: &'static str, result: std::io::Result<T>) {
    if let Err(error) = result {
        failed(event, stage, &format!("{:?}", error.kind()), "io");
    }
}
/// Classifies non-I/O completion failures without accepting diagnostic text.
pub(crate) fn outcome<T, E>(
    event: &str,
    stage: &'static str,
    result: Result<T, E>,
    code: &'static str,
    domain: &'static str,
) {
    if result.is_err() {
        failed(event, stage, code, domain);
    }
}

/// Only enum identity crosses this boundary, never peer diagnostics or addresses.
#[cfg(feature = "client")]
pub(crate) fn client_category(error: &crate::client::session::ClientError) -> String {
    use crate::client::session::ClientError;
    match error {
        ClientError::Timeout => "timeout".into(),
        ClientError::Disconnected { .. } => "closed".into(),
        ClientError::Transport(_) => "transport".into(),
        ClientError::Spawn(error) => format!("{:?}", error.kind()),
        ClientError::Protocol(_) => "protocol".into(),
        ClientError::Remote(error) => format!("remote_{:?}", error.code),
    }
}
#[cfg(feature = "client")]
pub(crate) fn client<T>(
    stage: &'static str,
    result: Result<T, crate::client::session::ClientError>,
) {
    match result {
        Ok(_) => {}
        // log-exempt: 预期的缺失：远程连接已经关闭或关闭请求超时，取消或关闭的目标不再可达。
        Err(
            crate::client::session::ClientError::Disconnected { .. }
            | crate::client::session::ClientError::Timeout,
        ) => {}
        // log-exempt: 预期的缺失：关闭阶段的 Transport 只保留字符串，无法区分已断开的连接与异常，目标可能已不存在。
        Err(crate::client::session::ClientError::Transport(_)) => {}
        Err(error) => failed(
            "remote.client.operation_failed",
            stage,
            &client_category(&error),
            "remote",
        ),
    }
}

fn disconnected_io(kind: std::io::ErrorKind) -> bool {
    use std::io::ErrorKind::*;
    matches!(
        kind,
        NotConnected | BrokenPipe | ConnectionReset | ConnectionAborted | UnexpectedEof
    )
}

/// Killing an already reaped child has achieved the desired terminal state.
pub(crate) fn kill(event: &str, stage: &'static str, result: std::io::Result<()>) {
    match result {
        Ok(()) => {}
        // log-exempt: 预期的缺失：进程已经退出或已被回收，没有仍需终止的进程。
        Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => {}
        // log-exempt: 预期的缺失：系统报告进程不存在，没有仍需终止的进程。
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => io::<()>(event, stage, Err(error)),
    }
}

/// Opening a tunnel can fail because its owning connection already ended.
#[cfg(feature = "client")]
pub(crate) fn bridge_category(error: &crate::client::session::ClientError) -> Option<String> {
    use crate::client::session::ClientError;
    match error {
        // log-exempt: 预期的缺失：远程连接已经关闭，没有仍需建立的转发连接。
        ClientError::Disconnected { .. } => None,
        // log-exempt: 预期的缺失：本地客户端已经断开，没有仍需桥接的连接。
        ClientError::Spawn(error) if disconnected_io(error.kind()) => None,
        _ => Some(client_category(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn teardown_filters_disconnects_but_reports_permission_denied() {
        use std::io::{Error, ErrorKind};
        static EMITTED: AtomicU64 = AtomicU64::new(0);
        let hook = Hook::default();
        hook.install(|event, fields| {
            assert_eq!(event, EVENTS[0]);
            assert!(fields
                .iter()
                .any(|(key, value)| *key == "error_code" && value == "PermissionDenied"));
            EMITTED.fetch_add(1, Ordering::Relaxed);
        });
        for kind in [
            ErrorKind::NotConnected,
            ErrorKind::BrokenPipe,
            ErrorKind::ConnectionReset,
            ErrorKind::ConnectionAborted,
            ErrorKind::UnexpectedEof,
        ] {
            hook.teardown::<()>(EVENTS[0], "test", Err(Error::from(kind)));
        }
        assert_eq!(EMITTED.load(Ordering::Relaxed), 0);
        hook.teardown::<()>(
            EVENTS[0],
            "test",
            Err(Error::from(ErrorKind::PermissionDenied)),
        );
        assert_eq!(EMITTED.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn missing_sink_counts_and_install_is_idempotent() {
        let hook = Hook::default();
        hook.emit(EVENTS[0], &[]);
        assert_eq!(hook.missed.load(Ordering::Relaxed), 1);
        hook.install(|event, fields| {
            assert_eq!(event, EVENTS[0]);
            assert!(fields.is_empty());
        });
        hook.install(|_, _| panic!("installation replaced the original sink"));
        hook.emit(EVENTS[0], &[]);
        assert_eq!(hook.missed.load(Ordering::Relaxed), 1);
    }
}
