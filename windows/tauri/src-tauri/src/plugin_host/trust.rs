//! Publisher evidence for signed packages. The legacy unsigned install policy
//! remains separate and never grants official tool-definition ownership.
use lithe_project::plugin_signature::{self, SignatureError, VerifiedPublisher};
use serde_json::Value;
use std::path::Path;

pub(super) const INVALID_SIGNATURE: &str = "plugin.packageSignature.invalid";

/// A present signature must verify, even when a package uses the old unsigned
/// admission route. No origin is inferred from IDs, records or directory names.
pub(super) fn publisher(
    root: &Path,
    manifest: &Value,
) -> Result<Option<VerifiedPublisher>, String> {
    match plugin_signature::verify(
        root,
        manifest["id"].as_str().unwrap_or(""),
        manifest["version"].as_str().unwrap_or(""),
    ) {
        Ok(publisher) => Ok(Some(publisher)),
        Err(SignatureError::Missing) => Ok(None),
        Err(_) => Err(INVALID_SIGNATURE.into()),
    }
}

/// Rechecks the scan's exact signed content, including signature removal or
/// replacement. A cached scan is never a permanent publisher or launch permit.
pub(super) fn current(package: &super::ScannedPackage) -> bool {
    publisher(&package.root, &package.manifest).is_ok_and(|value| value == package.publisher)
}
