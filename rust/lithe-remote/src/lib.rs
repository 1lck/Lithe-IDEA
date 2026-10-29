//! Remote workspace protocol, client transports and host-side server.
//!
//! The wire types are always available. Desktop consumers enable `client`;
//! remote executable builds use `--no-default-features --features server` to
//! keep client transports out of the uploaded server. Host capabilities remain
//! independent of Core, language engines and the transport used to reach them.
//!
//! Note: .agents/notes/implemented/architecture/2026-10-24-remote-workspace-routing.md

#[cfg(feature = "client")]
pub mod client;
pub mod protocol;
#[cfg(feature = "server")]
pub mod server;
