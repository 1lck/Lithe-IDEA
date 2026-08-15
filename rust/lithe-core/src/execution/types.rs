//! Shared classification types used by configuration generation and detectors.

use serde::{Deserialize, Serialize};

/// How a configuration behaves once started.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Execution {
    /// A user-facing process that may be interactive but is not a background service.
    Application,
    /// A long-running process expected to keep serving until explicitly stopped.
    Service,
    /// A finite command expected to exit after producing its result.
    Task,
    /// A non-process entry that groups other configurations for coordinated launch.
    Group,
}

impl Default for Execution {
    fn default() -> Self {
        Self::Application
    }
}

/// How the configuration was discovered. Higher values win deduplication.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    /// Inferred from naming or source-layout conventions rather than a declaration.
    Heuristic,
    /// Supported by a manifest, build plugin, dependency, or other project declaration.
    Declared,
    /// Authored by Lithe itself and therefore stronger than detector evidence.
    Native,
}

impl Default for Confidence {
    fn default() -> Self {
        Self::Declared
    }
}
