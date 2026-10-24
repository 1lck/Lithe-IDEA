//! Session state that outlives individual connections.

use crate::environment::EnvironmentCache;
use crate::link::Link;
use crate::process::ProcessTable;
use crate::resources::{IdWatermark, InFlight};
use crate::spawner::Spawner;
use crate::terminal::TerminalTable;
use crate::tunnel::TunnelTable;
use crate::walk::WalkTable;
use crate::watch::WatchTable;
use lithe_remote_protocol::methods::ServerState;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Default time a persistent session survives without a client.
pub(crate) const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// Upper bound clients may request, so a forgotten session does not keep
/// builds running on a shared host for days.
const MAX_IDLE_TIMEOUT: Duration = Duration::from_secs(24 * 60 * 60);

/// Time process groups get to exit after `SIGTERM` before `SIGKILL`.
pub(crate) const TERMINATION_GRACE: Duration = Duration::from_secs(2);

/// Time requests still running when the session ends get to finish. A write
/// that is cut off leaves its temporary sibling next to the user's file; one
/// request moves at most 8 MiB, so a healthy disk finishes well within this.
const WORKER_DRAIN_GRACE: Duration = Duration::from_secs(5);

pub(crate) struct Session {
    pub(crate) persistent: bool,
    pub(crate) link: Link,
    pub(crate) spawner: Spawner,
    pub(crate) ids: IdWatermark,
    pub(crate) environment: EnvironmentCache,
    pub(crate) processes: ProcessTable,
    pub(crate) terminals: TerminalTable,
    pub(crate) watches: WatchTable,
    pub(crate) tunnels: TunnelTable,
    pub(crate) walks: WalkTable,
    /// Requests running on worker threads, drained before the session ends.
    pub(crate) workers: InFlight,
    /// Whether any client completed a handshake before, which makes the
    /// next one a resumption.
    had_client: AtomicBool,
    next_connection: AtomicU64,
    idle_timeout: Mutex<Duration>,
}

impl Session {
    pub(crate) fn new(persistent: bool) -> std::io::Result<Arc<Self>> {
        Ok(Arc::new(Self {
            persistent,
            link: Link::new(persistent),
            spawner: Spawner::new()?,
            ids: IdWatermark::default(),
            environment: EnvironmentCache::default(),
            processes: ProcessTable::new(),
            terminals: TerminalTable::new(),
            watches: WatchTable::new(),
            tunnels: TunnelTable::new(),
            walks: WalkTable::new(),
            workers: InFlight::default(),
            had_client: AtomicBool::new(false),
            next_connection: AtomicU64::new(0),
            idle_timeout: Mutex::new(DEFAULT_IDLE_TIMEOUT),
        }))
    }

    pub(crate) fn next_connection_id(&self) -> u64 {
        self.next_connection.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// Records a completed handshake; returns whether a client was attached
    /// before.
    pub(crate) fn mark_client(&self) -> bool {
        self.had_client.swap(true, Ordering::AcqRel)
    }

    pub(crate) fn set_idle_timeout(&self, seconds: u64) {
        *crate::lock(&self.idle_timeout) = Duration::from_secs(seconds).min(MAX_IDLE_TIMEOUT);
    }

    pub(crate) fn idle_timeout(&self) -> Duration {
        *crate::lock(&self.idle_timeout)
    }

    pub(crate) fn state(&self) -> ServerState {
        ServerState {
            processes: self.processes.states(),
            terminals: self.terminals.states(),
            watches: self.watches.states(),
        }
    }

    /// Resources bound to a client connection. Tunnels end because their
    /// local sockets are gone; walks end because their results would only
    /// fill the replay buffer.
    pub(crate) fn release_connection_resources(&self, connection: u64) {
        self.tunnels.close_owned_by(connection);
        self.walks.cancel_owned_by(connection);
    }

    /// Ends everything the session started.
    pub(crate) fn terminate_all(&self) {
        self.tunnels.close_all();
        self.walks.cancel_all();
        self.watches.stop_all();
        self.terminals.terminate_all(TERMINATION_GRACE);
        self.processes.terminate_all(TERMINATION_GRACE);
        // Running writes finish, and clean up their temporary files on
        // failure, before the process exits and stops their threads.
        let unfinished = self.workers.drain(WORKER_DRAIN_GRACE);
        if unfinished > 0 {
            eprintln!("lithe-remote-server: {unfinished} requests did not finish");
        }
    }
}
