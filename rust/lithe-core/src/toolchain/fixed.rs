//! Inert consumer-owned choices; native hosts must attest paths and version probes.

use super::pins;
use crate::plugins::declarative::{PluginRejection, Validation};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One explicit installation or executable for a single consumer operation.
/// It never supplies a version, publisher identity, environment or launch permit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum FixedToolchainSelection {
    /// An installation whose executable and exports follow the active definition.
    Installation {
        /// Absolute native installation directory, checked by the host at use time.
        home: String,
    },
    /// A user-selected launcher that need not follow an installation layout.
    Executable {
        /// Absolute native program path; home-based exports are unavailable.
        executable: String,
    },
}

impl FixedToolchainSelection {
    /// Validates a saved path lexically, without looking up its definition or files.
    pub(crate) fn parse(value: &Value) -> Validation<Self> {
        let invalid = || {
            PluginRejection::at(
                "plugin.toolchain.invalidParams",
                "fixed",
                "Invalid explicit tool selection.",
            )
        };
        let choice: Self = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
        let path = match &choice {
            Self::Installation { home } => home,
            Self::Executable { executable } => executable,
        };
        if path.len() > 4096 || !pins::valid_native_path(path) {
            return Err(invalid());
        }
        Ok(choice)
    }
}
