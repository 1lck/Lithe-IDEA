//! Wire protocol shared by the Lithe client and `lithe-remote-server`.
//!
//! The protocol is transport-agnostic: SSH, `docker exec`, chained hops and a
//! plain local child process all deliver the same byte stream. Every
//! capability lives behind this protocol, so a transport only has to start the
//! server and connect its standard input and output.
//!
//! Note: the design and its trade-offs are recorded in
//! .agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md

pub mod frame;
pub mod message;
pub mod methods;

pub use frame::{FrameError, MAX_FRAME_BYTES, PREAMBLE};
pub use message::{ErrorCode, Message, RemoteError};

/// Protocol revision negotiated by `server.hello`.
///
/// Increment it only for incompatible changes. Additive fields and new methods
/// are advertised through [`methods::Feature`] instead, so an older server
/// keeps working with a newer client that checks the feature list.
pub const PROTOCOL_VERSION: u32 = 1;
