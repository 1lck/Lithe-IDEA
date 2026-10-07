//! Signed worker packages containing immutable native language-server resources.
//!
//! Core authenticates bytes and safe portable paths. The platform alone creates
//! staging/version directories, resolves external runtimes and removes resources.

use super::worker;
use crate::protocol::{CoreError, ErrorCode};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

fn publisher_key() -> Vec<u8> {
    let identity: Value = serde_json::from_str(include_str!(
        "../../../../shared/contracts/plugin-publisher.json"
    ))
    .expect("compiled publisher identity");
    STANDARD
        .decode(
            identity["publicKeyBase64"]
                .as_str()
                .expect("compiled publisher key field"),
        )
        .expect("compiled publisher key")
}

/// Bound before decoding the JSON container or allocating resource bytes.
pub const MAX_BUNDLE_BYTES: usize = 128 * 1024 * 1024;
const MAX_FILES: usize = 4096;

/// Detached signature of a package's complete file inventory.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PackageSignature {
    /// Signature document schema, independent of the worker container version.
    pub schema_version: u32,
    /// Signature algorithm; currently `ed25519`.
    pub algorithm: String,
    /// Trusted publisher key selector, never a key supplied by the package.
    #[serde(rename = "keyID")]
    pub key_id: String,
    /// Package identity authenticated by this document.
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    /// Exact plugin version authenticated by this document.
    pub plugin_version: String,
    /// Sorted portable paths mapped to lowercase SHA-256 hashes.
    pub files: BTreeMap<String, String>,
    /// Base64-encoded Ed25519 signature over the canonical inventory.
    pub signature: String,
}

/// Verified bytes ready for an isolated platform staging directory.
pub struct VerifiedWorkerBundle {
    /// Normalized worker metadata, including a signed receipt for later reads.
    pub package: Value,
    /// Full authenticated inventory; no symlinks or archive extraction is involved.
    pub files: BTreeMap<String, Vec<u8>>,
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

/// Portable file path accepted on both macOS and Windows, with no alternate streams.
pub fn safe_resource_path(path: &str) -> bool {
    if path.len() > 512 || !super::valid_relative_path(path) {
        return false;
    }
    path.split('/').all(|part| {
        let stem = part
            .split('.')
            .next()
            .unwrap_or_default()
            .to_ascii_uppercase();
        !part.ends_with(['.', ' '])
            && !part
                .chars()
                .any(|c| c.is_control() || "<>\"|?*:".contains(c))
            && ![
                "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
                "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",
                "LPT9",
            ]
            .contains(&stem.as_str())
    })
}

/// Canonical byte format is compatible with macOS PluginPackageSignature.
pub fn canonical_signature_payload(document: &PackageSignature) -> Vec<u8> {
    let token = |text: &str| URL_SAFE_NO_PAD.encode(text.as_bytes());
    let mut lines = vec![
        "schemaVersion=1".to_owned(),
        "algorithm=ed25519".to_owned(),
        "keyID=lithe-official-plugins-v1".to_owned(),
        format!("pluginID={}", token(&document.plugin_id)),
        format!("pluginVersion={}", token(&document.plugin_version)),
    ];
    lines.extend(
        document
            .files
            .iter()
            .map(|(path, hash)| format!("file={}={hash}", token(path))),
    );
    (lines.join("\n") + "\n").into_bytes()
}

fn verify_signature(document: &PackageSignature, public_key: &[u8]) -> Result<(), CoreError> {
    if document.schema_version != 1
        || document.algorithm != "ed25519"
        || document.key_id != "lithe-official-plugins-v1"
        || document.files.is_empty()
        || document.files.len() > MAX_FILES
    {
        return Err(invalid("Invalid plugin signature document"));
    }
    let mut folded = std::collections::BTreeSet::new();
    for (path, digest) in &document.files {
        if !safe_resource_path(path)
            || !folded.insert(path.to_lowercase())
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err(invalid(
                "Invalid or colliding plugin resource path or checksum",
            ));
        }
    }
    let signature = STANDARD
        .decode(&document.signature)
        .map_err(|_| invalid("Invalid plugin signature"))?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, public_key)
        .verify(&canonical_signature_payload(document), &signature)
        .map_err(|_| invalid("Plugin publisher signature could not be verified"))
}

fn verify_file(document: &PackageSignature, path: &str, bytes: &[u8]) -> Result<(), CoreError> {
    let digest = format!("{:x}", Sha256::digest(bytes));
    if document.files.get(path) != Some(&digest) {
        return Err(invalid("Plugin resource checksum mismatch"));
    }
    Ok(())
}

fn receipt_package(
    manifest_json: &str,
    source: &str,
    document: &PackageSignature,
    installed: bool,
) -> Result<Value, CoreError> {
    verify_file(document, "plugin.json", manifest_json.as_bytes())?;
    verify_file(document, "plugin.js", source.as_bytes())?;
    let manifest: Value = serde_json::from_str(manifest_json)
        .map_err(|_| invalid("Invalid signed plugin manifest"))?;
    if manifest["id"] != document.plugin_id
        || manifest["version"] != document.plugin_version
        || !["windows-x86_64", "windows-aarch64"]
            .contains(&manifest["nativeTarget"].as_str().unwrap_or_default())
    {
        return Err(invalid(
            "Signed plugin identity, version or target is invalid",
        ));
    }
    if manifest["lsp"]["runtime"] != "package" {
        return Err(invalid("Signed native resources require the package runtime"));
    }
    let entrypoint = manifest["lsp"]["server"]["default"]
        .as_str()
        .ok_or_else(|| invalid("Missing packaged server entrypoint"))?;
    if !entrypoint.starts_with("resources/") || !document.files.contains_key(entrypoint) {
        return Err(invalid(
            "Packaged language server is missing from the signed inventory",
        ));
    }
    let mut package = worker::validate_value(
        json!({"format":"lithe-worker-plugin", "version":1,
        "manifest":manifest, "source":source, "installed":installed}),
        true,
    )?;
    package["nativePackage"] = json!({"manifestJSON":manifest_json,"signature":document});
    Ok(package)
}

/// Checks the receipt kept beside worker source after the large assets are installed.
pub fn validate_receipt(package: &Value) -> Result<Value, CoreError> {
    let receipt = &package["nativePackage"];
    let document: PackageSignature = serde_json::from_value(receipt["signature"].clone())
        .map_err(|_| invalid("Invalid plugin receipt"))?;
    verify_signature(&document, &publisher_key())?;
    let manifest = receipt["manifestJSON"]
        .as_str()
        .ok_or_else(|| invalid("Missing signed manifest"))?;
    let source = package["source"]
        .as_str()
        .ok_or_else(|| invalid("Missing worker source"))?;
    let mut result = receipt_package(manifest, source, &document, package["installed"] == true)?;
    if let Some(staging_id) = receipt["stagingId"].as_str() {
        if staging_id.len() != 36
            || !staging_id
                .bytes()
                .all(|c| c.is_ascii_hexdigit() || c == b'-')
        {
            return Err(invalid("Invalid plugin staging identity"));
        }
        result["nativePackage"]["stagingId"] = json!(staging_id);
    }
    Ok(result)
}

/// Authenticates a distributable package before the platform writes any resources.
pub fn verify_bundle(input: &str) -> Result<VerifiedWorkerBundle, CoreError> {
    verify_bundle_with_key(input, &publisher_key())
}

pub(crate) fn verify_bundle_with_key(
    input: &str,
    public_key: &[u8],
) -> Result<VerifiedWorkerBundle, CoreError> {
    if input.len() > MAX_BUNDLE_BYTES {
        return Err(invalid("Plugin bundle exceeds 128 MB"));
    }
    let value: Value =
        serde_json::from_str(input).map_err(|_| invalid("Invalid plugin bundle JSON"))?;
    if value["format"] != "lithe-native-worker-plugin" || value["version"] != 1 {
        return Err(invalid("Unsupported plugin bundle"));
    }
    let document: PackageSignature = serde_json::from_value(value["signature"].clone())
        .map_err(|_| invalid("Invalid plugin signature document"))?;
    verify_signature(&document, public_key)?;
    let encoded = value["files"]
        .as_object()
        .ok_or_else(|| invalid("Missing plugin resources"))?;
    if encoded.len() != document.files.len() {
        return Err(invalid("Plugin resource inventory mismatch"));
    }
    let mut files = BTreeMap::new();
    for (path, encoded) in encoded {
        let bytes = STANDARD
            .decode(
                encoded
                    .as_str()
                    .ok_or_else(|| invalid("Invalid plugin resource bytes"))?,
            )
            .map_err(|_| invalid("Invalid plugin resource encoding"))?;
        verify_file(&document, path, &bytes)?;
        files.insert(path.clone(), bytes);
    }
    let read = |path: &str| {
        files
            .get(path)
            .and_then(|bytes| std::str::from_utf8(bytes).ok())
            .ok_or_else(|| invalid("Missing UTF-8 plugin metadata"))
    };
    let package = receipt_package(read("plugin.json")?, read("plugin.js")?, &document, false)?;
    Ok(VerifiedWorkerBundle { package, files })
}
