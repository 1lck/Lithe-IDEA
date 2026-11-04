//! Persists portable user choices separately from opaque provider target identities.
//! Only the selected provider interprets runtime arguments, entrypoints and build options.

use crate::protocol::{CoreError, ErrorCode};
pub use crate::toolchain::fixed::FixedToolchainSelection;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// User-owned Run v2 `extensions.build-run`; never a cached launch plan.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuildProviderRunOptions {
    /// Exact argv elements, including empty arguments and whitespace.
    #[serde(default)]
    pub runtime_arguments: Vec<String>,
    /// Opaque provider entrypoint; empty explicitly clears an inherited choice.
    #[serde(default)]
    pub entrypoint: String,
    /// Declared build-option values; current declaration/model validation occurs at preparation.
    #[serde(default)]
    pub options: BTreeMap<String, Value>,
    /// Explicit tool choices for this Run's build preparation and process only.
    /// They never change another Run or a workspace's directory pins.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tools: BTreeMap<String, Option<FixedToolchainSelection>>,
}

impl BuildProviderRunOptions {
    /// Bound persistence without interpreting a runtime or tool's option syntax.
    pub(super) fn validate(&self) -> Result<(), CoreError> {
        let invalid = || CoreError::new(ErrorCode::InvalidRequest, "Invalid provider run options");
        if self.runtime_arguments.len() > 1024
            || self
                .runtime_arguments
                .iter()
                .any(|arg| arg.len() > 65536 || arg.contains('\0'))
            || self.entrypoint.len() > 4096
            || self.entrypoint.contains('\0')
            || self.options.len() > 64
            || self.options.keys().any(|key| {
                key.is_empty()
                    || key.len() > 200
                    || !key
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
            })
            || serde_json::to_vec(&self.options).map_or(true, |bytes| bytes.len() > 65536)
            || self.tools.len() > 64
            || self.tools.iter().any(|(id, value)| {
                !crate::toolchain::definitions::tool_id(id)
                    || value.as_ref().is_some_and(|value| {
                        serde_json::to_value(value)
                            .ok()
                            .is_none_or(|value| FixedToolchainSelection::parse(&value).is_err())
                    })
            })
            || serde_json::to_vec(&self.tools).map_or(true, |bytes| bytes.len() > 65536)
        {
            return Err(invalid());
        }
        Ok(())
    }

    /// Null clears an inherited per-Run choice, leaving directory policy intact.
    pub(super) fn active_tools(&self) -> BTreeMap<String, FixedToolchainSelection> {
        self.tools
            .iter()
            .filter_map(|(id, value)| value.clone().map(|value| (id.clone(), value)))
            .collect()
    }

    /// Missing options preserve older saved selectors; explicit malformed values fail closed.
    pub(super) fn from_extensions(extensions: &BTreeMap<String, Value>) -> Result<Self, CoreError> {
        let value = match extensions.get("build-run") {
            Some(value) => serde_json::from_value(value.clone()).map_err(|_| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid provider run options")
            })?,
            None => Self::default(),
        };
        value.validate()?;
        Ok(value)
    }
}

/// Omission inherits persisted choices; explicit null is not an instruction to discard them.
pub(super) fn optional_request_options<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<BuildProviderRunOptions>, D::Error> {
    BuildProviderRunOptions::deserialize(deserializer).map(Some)
}
