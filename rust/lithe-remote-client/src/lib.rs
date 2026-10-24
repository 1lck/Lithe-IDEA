//! Client side of Lithe remote workspaces.
//!
//! - [`transport`] turns a chain of hops (SSH, container exec) into the local
//!   command line that runs a program at the end of the chain.
//! - [`bootstrap`] makes sure a matching `lithe-remote-server` is installed at
//!   the end of the chain, uploading it through the same chain if needed.
//! - [`session`] starts the server and exchanges protocol messages with it.
//!
//! The transport layer deliberately knows nothing about files or processes.
//! Supporting a new kind of remote means adding a hop, not new capabilities.
//!
//! Note: .agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md

pub mod bootstrap;
pub mod command;
pub mod session;
pub mod transport;

pub use bootstrap::{Bootstrapper, InstallLocation, ServerArtifact, ServerTarget};
pub use session::{ClientError, RemoteSession};
pub use transport::{ContainerEngine, ContainerHop, Hop, SshHop, TransportChain, TransportError};
