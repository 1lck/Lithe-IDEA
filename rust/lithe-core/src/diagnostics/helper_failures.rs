//! One installation boundary for helper facts entering the bounded Core handoff.

use super::core_events;
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::Once;

static INSTALL: Once = Once::new();

/// Every Core command, standalone ACP open and direct IDE/AskPass entry calls
/// this before invoking helpers or starting workers. Subsequent calls are cheap.
pub(crate) fn install() {
    INSTALL.call_once(|| {
        lithe_agent_host::failure_log::install_failure_sink(sink);
        lithe_git_host::failure_log::install_failure_sink(sink);
        lithe_ide_host::failure_log::install_failure_sink(sink);
        lithe_remote::failure_log::install_failure_sink(sink);
    });
}

/// Copy only the scalar fields supplied by adapters; catalog validation owns routing.
fn fields(input: &[(&'static str, Value)]) -> BTreeMap<String, Value> {
    input
        .iter()
        .map(|(key, value)| ((*key).into(), value.clone()))
        .collect()
}

/// The injectable boundary keeps contract failures out of the queue and counts
/// them without recursively logging a logging failure.
fn dispatch(
    event: &str,
    input: &[(&'static str, Value)],
    record: impl FnOnce(&str, BTreeMap<String, Value>) -> Result<(), super::channel::LogError>,
    dropped: impl FnOnce(),
) {
    if record(event, fields(input)).is_err() {
        dropped();
    }
}

fn sink(event: &str, input: &[(&'static str, Value)]) {
    dispatch(
        event,
        input,
        |id, fields| core_events::record(id, fields, None),
        core_events::note_dropped,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::{Cell, RefCell};

    #[test]
    fn helper_events_have_core_ownership_and_expected_channels() {
        install();
        install();
        let input = [
            ("stage", json!("test")),
            ("error", json!("Helper operation failed")),
            ("error_code", json!("PermissionDenied")),
            ("error_domain", json!("io")),
        ];
        for (events, channel) in [
            (lithe_agent_host::failure_log::EVENTS, "agent"),
            (lithe_git_host::failure_log::EVENTS, "vcs/git"),
            (lithe_ide_host::failure_log::EVENTS, "app"),
            (lithe_remote::failure_log::EVENTS, "remote"),
        ] {
            for id in events {
                assert_eq!(
                    super::super::catalog::event_by_id(id).unwrap().owner,
                    "lithe-core"
                );
                // Exercise the exact sink conversion/validation into an owned
                // queue, so parallel host drains cannot steal this assertion.
                let queue = RefCell::new(Vec::new());
                dispatch(
                    id,
                    &input,
                    |event, map| {
                        let prepared = core_events::prepare(event, map, None)?;
                        queue.borrow_mut().push(prepared);
                        Ok(())
                    },
                    || panic!("valid helper event was dropped"),
                );
                let queue = queue.borrow();
                assert_eq!(queue.len(), 1);
                assert_eq!(queue[0].channel, channel);
                assert_eq!(queue[0].event, *id);
            }
        }
    }

    #[test]
    fn invalid_event_only_increments_dropped() {
        let queued = Cell::new(0);
        let dropped = Cell::new(0);
        dispatch(
            "missing.helper.event",
            &[],
            |id, map| {
                core_events::prepare(id, map, None)?;
                queued.set(queued.get() + 1);
                Ok(())
            },
            || dropped.set(dropped.get() + 1),
        );
        assert_eq!(queued.get(), 0);
        assert_eq!(dropped.get(), 1);
    }
}
