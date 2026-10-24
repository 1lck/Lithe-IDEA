//! Client side of Lithe remote workspaces.
//!
//! - [`transport`] turns a chain of hops (SSH, container exec) into the local
//!   command line that runs a program at the end of the chain.
//! - [`bootstrap`] makes sure a matching `lithe-remote-server` is installed at
//!   the end of the chain, uploading it through the same chain if needed.
//! - [`session`] starts the server, exchanges protocol messages with it and
//!   routes each resource's events to its subscriber.
//! - [`api`] offers typed operations and resource handles on a session.
//! - [`forward`] forwards local ports through tunnels.
//!
//! The transport layer deliberately knows nothing about files or processes.
//! Supporting a new kind of remote means adding a hop, not new capabilities.
//!
//! Note: .agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md

pub mod api;
pub mod bootstrap;
pub mod command;
pub mod forward;
pub mod session;
pub mod transport;

pub use api::{SpawnSpec, TerminalSpec, WriteOptions};
pub use bootstrap::{Bootstrapper, InstallLocation, ServerArtifact, ServerTarget};
pub use forward::PortForward;
pub use session::{ClientError, ConnectOptions, Event, RemoteSession};
pub use transport::{ContainerEngine, ContainerHop, Hop, SshHop, TransportChain, TransportError};
