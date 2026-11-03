//! Injected scalar failure facts; the owning Core supplies the only log writer.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// Complete catalog surface emitted by this adapter.
pub const EVENTS: &[&str] = &["app.ide.broker_failed", "app.ide.connection_cleanup_failed"];

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
pub(crate) fn emit(event: &str, fields: Fields<'_>) {
    HOOK.emit(event, fields);
}
/// No error display text is accepted: only caller-controlled categories cross the hook.
pub(crate) fn failed(event: &str, stage: &'static str, code: &str, domain: &'static str) {
    emit(
        event,
        &[
            ("stage", json!(stage)),
            ("error", json!("Helper operation failed")),
            ("error_code", json!(code)),
            ("error_domain", json!(domain)),
        ],
    );
}
#[cfg(test)]
mod tests {
    use super::*;
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
