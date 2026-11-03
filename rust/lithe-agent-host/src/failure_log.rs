//! Injected scalar failure facts; the owning Core supplies the only log writer.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// Complete catalog surface emitted by this adapter.
pub const EVENTS: &[&str] = &[
    "agent.history.prepare_failed",
    "agent.host.operation_failed",
    "agent.observation.start_failed",
    "agent.retry.cleanup_failed",
    "agent.skills.cleanup_failed",
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
/// Observe cleanup without changing the business result; missing artifacts are normal.
pub(crate) fn cleanup(event: &str, stage: &'static str, result: std::io::Result<()>) {
    match result {
        Ok(()) => {}
        // log-exempt: 预期的缺失：清理对象可能尚未创建或已被并发清理。
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => io::<()>(event, stage, Err(error)),
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

/// A bounded asynchronous completion has separate deadline and inner failures.
pub(crate) fn nested<T, D>(
    event: &str,
    stage: &'static str,
    result: Result<Result<T, tokio::task::JoinError>, D>,
    code: &'static str,
    domain: &'static str,
) {
    match result {
        Ok(Ok(_)) => {}
        // log-exempt: 预期的缺失：任务已被关闭流程取消，不存在仍需等待的任务。
        Ok(Err(error)) if error.is_cancelled() => {}
        Ok(Err(_)) => failed(event, stage, code, domain),
        Err(_) => failed(event, stage, "timeout", "deadline"),
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
        #[cfg(unix)]
        // log-exempt: 预期的缺失：ESRCH 表示进程已经退出，没有仍需终止的进程。
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
        Err(error) => io::<()>(event, stage, Err(error)),
    }
}

/// ACP 2.2 maps both a closed outgoing queue and serialization to InternalError.
pub(crate) fn cancel_notification(result: Result<(), agent_client_protocol::Error>) {
    match result {
        Ok(()) => {}
        // log-exempt: 预期的缺失：Agent 已退出时取消目标已不存在；ACP 将断连和序列化共用 InternalError，无法可靠区分正常关闭。
        Err(error) if error.code == agent_client_protocol::ErrorCode::InternalError => {}
        Err(_) => failed(
            "agent.host.operation_failed",
            "cancel_notification",
            "notification_failed",
            "acp",
        ),
    }
}

/// Hyper exposes disconnects through flags or a typed I/O source chain.
pub(crate) fn connection(event: &str, stage: &'static str, result: Result<(), hyper::Error>) {
    let Err(error) = result else { return };
    if error.is_closed()
        || error.is_canceled()
        || error.is_incomplete_message()
        || error.is_body_write_aborted()
    {
        // log-exempt: 预期的缺失：HTTP 客户端已经关闭连接，没有仍需服务的请求。
        return;
    }
    let mut source = std::error::Error::source(&error);
    while let Some(cause) = source {
        if let Some(io) = cause.downcast_ref::<std::io::Error>() {
            // Preserve the category only, never the upstream diagnostic message.
            teardown::<()>(event, stage, Err(std::io::Error::from(io.kind())));
            return;
        }
        source = cause.source();
    }
    if error.is_user() {
        failed(event, stage, "handler_failed", "http");
    }
    // log-exempt: 预期的缺失：其余连接级错误没有可识别的存活请求，Hyper 未提供能区分客户端提前关闭和异常的类别。
}

/// Waiting for a killed process preserves I/O categories and orphan deadlines.
pub(crate) fn process_wait<D>(
    event: &str,
    stage: &'static str,
    result: Result<std::io::Result<std::process::ExitStatus>, D>,
) {
    match result {
        Ok(result) => io(event, stage, result),
        Err(_) => failed(event, stage, "timeout", "deadline"),
    }
}

/// Tree enumeration failures are distinct from an already absent target.
pub(crate) fn kill_tree(result: kill_tree::Result<kill_tree::Outputs>) {
    match result {
        Ok(_) => {}
        Err(kill_tree::Error::Io(error)) => kill(
            "agent.host.operation_failed",
            "process_tree_kill",
            Err(error),
        ),
        #[cfg(unix)]
        // log-exempt: 预期的缺失：ESRCH 表示进程树的目标已经退出。
        Err(kill_tree::Error::Unix(error)) if error as i32 == libc::ESRCH => {}
        Err(_) => failed(
            "agent.host.operation_failed",
            "process_tree_kill",
            "tree_kill_failed",
            "process",
        ),
    }
}

/// A closed completion channel means the worker has already exited.
pub(crate) fn worker_stop(result: Result<(), std::sync::mpsc::RecvTimeoutError>) {
    match result {
        Ok(()) => {}
        // log-exempt: 预期的缺失：完成通道已关闭，worker 已经退出，不存在仍需停止的 worker。
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {}
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => failed(
            "agent.host.operation_failed",
            "worker_stop",
            "timeout",
            "deadline",
        ),
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
