//! The thread that starts every child process.
//!
//! On Linux, `PR_SET_PDEATHSIG` fires when the *thread* that forked a child
//! exits, not the process. Connections and worker threads come and go, so
//! spawning from them would kill children early. All spawns are therefore
//! executed on one thread that lives as long as the session.

use std::sync::mpsc::{self, Sender};
use std::sync::Mutex;
use std::thread;

type Job = Box<dyn FnOnce() + Send>;

pub(crate) struct Spawner {
    jobs: Mutex<Sender<Job>>,
}

impl Spawner {
    pub(crate) fn new() -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel::<Job>();
        // The thread ends when the session drops the sender. Children it
        // started then receive their parent-death signal, which is exactly
        // the end of the session.
        thread::Builder::new()
            .name("remote-spawner".into())
            .spawn(move || {
                while let Ok(job) = receiver.recv() {
                    job();
                }
            })?;
        Ok(Self {
            jobs: Mutex::new(sender),
        })
    }

    /// Runs `job` on the spawner thread and returns its result. Jobs must be
    /// short: they only fork and exec, never wait for a child.
    pub(crate) fn run<R: Send + 'static>(&self, job: impl FnOnce() -> R + Send + 'static) -> R {
        let (reply, result) = mpsc::channel();
        let job: Job = Box::new(move || {
            let _ = reply.send(job());
        });
        crate::server::lock(&self.jobs)
            .send(job)
            .expect("the spawner thread lives as long as the session");
        result
            .recv()
            .expect("the spawner thread completes every job it receives")
    }
}
