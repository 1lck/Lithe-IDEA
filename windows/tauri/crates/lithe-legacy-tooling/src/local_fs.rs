//! Local filesystem calls with the shape the copied Maven code expects.
//!
//! Core reaches these through `remote::workspace_io`, which also serves remote
//! workspaces. Windows has no remote workspaces, so every call here goes
//! straight to `std::fs`. The std functions already match Core's local
//! behavior; only the two existence probes differ, and they are kept here so
//! callers can tell a missing path from an unreadable one.

use std::io;
use std::path::Path;

pub use std::fs::{canonicalize, metadata, read, read_dir, File};

/// Tests whether a path is a directory, treating only a missing path as `false`.
pub fn is_dir(path: impl AsRef<Path>) -> io::Result<bool> {
    match metadata(path) {
        Ok(value) => Ok(value.is_dir()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Tests whether a path is a regular file, treating only a missing path as `false`.
pub fn is_file(path: impl AsRef<Path>) -> io::Result<bool> {
    match metadata(path) {
        Ok(value) => Ok(value.is_file()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}
