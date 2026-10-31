//! Publisher signature and content-digest verification for plugin packages.
//!
//! Byte-compatible with the macOS `PluginPackageSignature` (CryptoKit): the
//! canonical payload lines, UTF-8 base64url tokens, file-path sorting, and
//! the content digest follow the same specification, so one signed package
//! verifies identically on both platforms. Package bytes are hashed as UTF-8
//! relative paths with `/` separators; names that are not valid UTF-8 (which
//! Windows can produce) cannot receive a token and are refused.
//!
//! Trust policy lives here, not in the package: the host pins the signature
//! requirement of every official plugin ID, so a package cannot downgrade it
//! by declaring `vendor.signatureRequirement` itself, and `sameTeamAsHost` is
//! only honored for packages that ship inside the host's own installation.

use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

/// Signature document file name inside a package root; excluded from every
/// digest computation, and its presence forces verification.
pub const SIGNATURE_FILE_NAME: &str = "lithe-plugin-signature.json";

/// Signature schema version; must stay equal to the macOS implementation.
pub const SCHEMA_VERSION: u32 = 1;
pub const ALGORITHM: &str = "ed25519";
/// Key ID used for newly signed official packages; same as macOS.
pub const OFFICIAL_KEY_ID: &str = "lithe-official-plugins-v2";
/// Standard-base64 Ed25519 verification key for [`OFFICIAL_KEY_ID`]. This is
/// a public key, not a secret; the private signing key never enters this
/// repository.
pub const OFFICIAL_PUBLIC_KEY_BASE64: &str = "yTjUaLpCNXXEQDuan5Ymw5rCtR0JeTNmh6hyTfOFjTs=";

const STANDARD_BASE64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;
const BASE64URL_NO_PAD: base64::engine::GeneralPurpose =
    base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// The signature document stored in `lithe-plugin-signature.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignatureDocument {
    pub schema_version: u32,
    pub algorithm: String,
    pub key_id: String,
    pub plugin_id: String,
    pub plugin_version: String,
    /// Relative package path (UTF-8, `/` separators) to lowercase hex SHA-256.
    pub files: BTreeMap<String, String>,
    /// Standard-base64 Ed25519 signature over the canonical payload.
    pub signature: String,
}

/// Every rejection this module produces, with the stable code the catalog
/// reports for a quarantined package.
#[derive(Debug, Clone, PartialEq)]
pub enum TrustError {
    /// The package (or its origin) claims no publisher signature, but the
    /// host only trusts unsigned community packages that are not pinned
    /// official plugins.
    UnsignedNotAllowed,
    /// The trust policy requires a publisher signature and none is present.
    SignatureMissing,
    /// A signature document exists but is malformed, does not match the
    /// package, or does not verify.
    SignatureInvalid(String),
    /// The document names a key ID this host does not trust.
    UntrustedKey(String),
    /// The package files differ from the digest recorded when the user
    /// approved it (changed, added, or removed files).
    ContentChanged,
    /// An installed package record carries no content digest, so its bytes
    /// cannot be proven to be what the user approved (schema 1 migration).
    ProvenanceMissing,
    /// A `sameTeamAsHost` package outside the host's own installation.
    HostSealRequired,
    /// The manifest's `vendor.signatureRequirement` is not a known value.
    InvalidPolicy,
}

impl TrustError {
    /// Stable error code for catalog quarantines and diagnostics.
    pub fn code(&self) -> &'static str {
        match self {
            TrustError::UnsignedNotAllowed => "plugin.trust.unsignedNotAllowed",
            TrustError::SignatureMissing => "plugin.trust.signatureMissing",
            TrustError::SignatureInvalid(_) => "plugin.trust.signatureInvalid",
            TrustError::UntrustedKey(_) => "plugin.trust.untrustedKey",
            TrustError::ContentChanged => "plugin.trust.contentChanged",
            TrustError::ProvenanceMissing => "plugin.trust.provenanceMissing",
            TrustError::HostSealRequired => "plugin.trust.hostSealRequired",
            TrustError::InvalidPolicy => "plugin.trust.invalidPolicy",
        }
    }

    pub fn message(&self) -> String {
        match self {
            TrustError::UnsignedNotAllowed => {
                "the package is unsigned and this host only loads unsigned community packages \
                 after user confirmation"
                    .to_string()
            }
            TrustError::SignatureMissing => {
                "the package requires a publisher signature but none is present".to_string()
            }
            TrustError::SignatureInvalid(detail) => {
                format!("the package signature is invalid: {detail}")
            }
            TrustError::UntrustedKey(key_id) => format!(
                "the package is signed by key {key_id}, which this version of Lithe does not trust"
            ),
            TrustError::ContentChanged => {
                "the package differs from the contents the user approved".to_string()
            }
            TrustError::ProvenanceMissing => {
                "the install record has no content digest; reinstall the plugin to approve it \
                 with the current trust rules"
                    .to_string()
            }
            TrustError::HostSealRequired => {
                "the package can only be trusted when it ships inside Lithe".to_string()
            }
            TrustError::InvalidPolicy => {
                "the package declares an unknown signature requirement".to_string()
            }
        }
    }
}

/// How a package proves its origin; mirrors the macOS trust model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InstallOrigin {
    /// Ships inside the host installation; sealed by distribution, not by a
    /// package signature.
    Bundled,
    /// Downloaded from a marketplace source as a publisher-signed package.
    Marketplace,
    /// An unsigned package the user installed after confirming its
    /// permissions and programs; integrity comes from the recorded digest.
    Community,
}

/// Signature requirement of a package: the pinned host policy for official
/// plugin IDs, otherwise the manifest's own `vendor.signatureRequirement`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignatureRequirement {
    /// Trusted only inside the host's own installation.
    SameTeamAsHost,
    /// Must carry a valid publisher signature over every file.
    PublisherPackage,
    /// No Lithe signature; community trust only.
    Unsigned,
}

/// Trust policy the host pins per official plugin ID. The pinned policy wins
/// over whatever the package declares, so an official ID cannot downgrade the
/// signature it must carry. This mirrors the macOS `OfficialPluginCatalog`
/// for the IDs that exist on Windows; the bundled PHP contract package ships
/// inside the installer, so it is pinned `sameTeamAsHost`.
pub fn official_signature_requirement(plugin_id: &str) -> Option<SignatureRequirement> {
    match plugin_id {
        "dev.lithe.plugin.php-support" => Some(SignatureRequirement::SameTeamAsHost),
        "dev.lithe.plugin.java-support" => Some(SignatureRequirement::SameTeamAsHost),
        "dev.lithe.plugin.go-support" => Some(SignatureRequirement::PublisherPackage),
        _ => None,
    }
}

/// Parses the manifest's `vendor.signatureRequirement`.
pub fn declared_signature_requirement(
    manifest: &serde_json::Value,
) -> Result<SignatureRequirement, TrustError> {
    match manifest["vendor"]["signatureRequirement"].as_str() {
        Some("sameTeamAsHost") => Ok(SignatureRequirement::SameTeamAsHost),
        Some("publisherPackage") => Ok(SignatureRequirement::PublisherPackage),
        Some("none") => Ok(SignatureRequirement::Unsigned),
        _ => Err(TrustError::InvalidPolicy),
    }
}

/// The host's trust keys, keyed by key ID. A malformed embedded key is a
/// build defect and must never be silently skipped.
pub fn trusted_keys() -> BTreeMap<String, VerifyingKey> {
    #[cfg(test)]
    if let Some(keys) = test_trusted_keys() {
        return keys;
    }
    OFFICIAL_TRUSTED_KEYS
        .get_or_init(|| {
            let bytes = STANDARD_BASE64
                .decode(OFFICIAL_PUBLIC_KEY_BASE64)
                .expect("embedded official plugin signing key must be valid base64");
            let key = VerifyingKey::from_bytes(
                &bytes
                    .try_into()
                    .expect("embedded official plugin signing key must be 32 bytes"),
            )
            .expect("embedded official plugin signing key must be a valid Ed25519 key");
            BTreeMap::from([(OFFICIAL_KEY_ID.to_string(), key)])
        })
        .clone()
}

static OFFICIAL_TRUSTED_KEYS: OnceLock<BTreeMap<String, VerifyingKey>> = OnceLock::new();

#[cfg(test)]
thread_local! {
    static TEST_TRUSTED_KEYS: std::cell::RefCell<Option<BTreeMap<String, VerifyingKey>>> =
        const { std::cell::RefCell::new(None) };
}

/// Runs `run` with the given keys trusted by the host. Production builds
/// never see this seam; the signature vectors' RFC 8032 key must never trust
/// a real package.
#[cfg(test)]
pub(crate) fn with_trusted_keys_for_tests<R>(
    keys: BTreeMap<String, VerifyingKey>,
    run: impl FnOnce() -> R,
) -> R {
    TEST_TRUSTED_KEYS.with(|cell| {
        let previous = cell.borrow_mut().replace(keys);
        let result = run();
        *cell.borrow_mut() = previous;
        result
    })
}

#[cfg(test)]
fn test_trusted_keys() -> Option<BTreeMap<String, VerifyingKey>> {
    TEST_TRUSTED_KEYS.with(|cell| cell.borrow().clone())
}

/// The RFC 8032 test signing key shared with `signature-vectors.json`.
#[cfg(test)]
pub(crate) fn rfc8032_signing_key_for_tests() -> ed25519_dalek::SigningKey {
    fn hex_to_bytes(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).expect("hex byte"))
            .collect()
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&hex_to_bytes(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    ));
    ed25519_dalek::SigningKey::from_bytes(&seed)
}

/// True when the package root carries a signature document.
pub fn has_signature_file(package_root: &Path) -> bool {
    package_root.join(SIGNATURE_FILE_NAME).is_file()
}

/// Reads and parses the signature document of a package root.
pub fn read_signature_document(package_root: &Path) -> Result<SignatureDocument, TrustError> {
    let path = package_root.join(SIGNATURE_FILE_NAME);
    let text = std::fs::read_to_string(&path).map_err(|_| TrustError::SignatureMissing)?;
    serde_json::from_str(&text)
        .map_err(|error| TrustError::SignatureInvalid(format!("unreadable document: {error}")))
}

/// UTF-8 base64url token without padding, exactly as the macOS signer emits.
fn token(value: &str) -> String {
    BASE64URL_NO_PAD.encode(value.as_bytes())
}

/// Key IDs are written raw into the signed payload to keep existing
/// signatures byte-compatible, so they are restricted to a safe alphabet.
pub fn is_valid_key_id(key_id: &str) -> bool {
    !key_id.is_empty()
        && key_id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '-' | '_'))
}

/// The exact bytes signed by the publisher, identical to the macOS
/// implementation: header lines, then one line per file in ascending path
/// order (UTF-8 byte order, which matches the macOS scalar order for the NFC
/// names packages must use), every line terminated by `\n`.
pub fn canonical_payload(
    key_id: &str,
    plugin_id: &str,
    plugin_version: &str,
    files: &BTreeMap<String, String>,
) -> Vec<u8> {
    let mut payload = format!(
        "schemaVersion={SCHEMA_VERSION}\nalgorithm={ALGORITHM}\nkeyID={key_id}\npluginID={}\npluginVersion={}\n",
        token(plugin_id),
        token(plugin_version)
    );
    for (path, digest) in files {
        payload.push_str(&format!("file={}={}\n", token(path), digest));
    }
    payload.into_bytes()
}

/// SHA-256 over `token(path)=digest\n` for every file in ascending path
/// order. Recorded when an unsigned package is installed and rechecked on
/// every load, so a changed, added, or removed file is detected.
pub fn content_digest(package_root: &Path) -> Result<String, TrustError> {
    let digests = file_digests(package_root)?;
    let lines: String = digests
        .iter()
        .map(|(path, digest)| format!("{}={digest}\n", token(path)))
        .collect();
    Ok(hex(&Sha256::digest(lines.as_bytes())))
}

/// Verifies the signature document of a package when one is present. A
/// present document is always verified — even for packages trusted through
/// another route — so a forged or damaged document is never ignored.
pub fn verify_signature_if_present(
    package_root: &Path,
    plugin_id: &str,
    plugin_version: &str,
    trusted_keys: &BTreeMap<String, VerifyingKey>,
) -> Result<(), TrustError> {
    if !has_signature_file(package_root) {
        return Ok(());
    }
    let document = read_signature_document(package_root)?;
    verify_document(
        package_root,
        plugin_id,
        plugin_version,
        &document,
        trusted_keys,
    )
}

/// Install-time policy check for a package about to be recorded as `origin`.
/// Same rules as [`verify_for_origin`], without the content-digest
/// requirement for community packages: the digest is being created by this
/// install and cannot be checked against a record that does not exist yet.
pub fn verify_for_install(
    package_root: &Path,
    plugin_id: &str,
    plugin_version: &str,
    manifest: &serde_json::Value,
    origin: InstallOrigin,
    bundled_root: Option<&Path>,
    trusted_keys: &BTreeMap<String, VerifyingKey>,
) -> Result<(), TrustError> {
    let declared = declared_signature_requirement(manifest)?;
    let pinned = official_signature_requirement(plugin_id).unwrap_or(declared);
    // The pinned host policy decides which channel the package may use; the
    // package cannot pick a weaker one by declaring it.
    match pinned {
        SignatureRequirement::Unsigned => {
            // Unsigned trust is community-only: the user's explicit review of
            // the exact bytes, never a pinned official ID or another origin.
            if origin != InstallOrigin::Community {
                return Err(TrustError::UnsignedNotAllowed);
            }
            verify_signature_if_present(package_root, plugin_id, plugin_version, trusted_keys)
        }
        SignatureRequirement::PublisherPackage => {
            // A publisher signature is required and verified whatever channel
            // delivered the package: a marketplace download, or a signed disk
            // import recorded as community provenance.
            if !has_signature_file(package_root) {
                return Err(TrustError::SignatureMissing);
            }
            verify_signature_if_present(package_root, plugin_id, plugin_version, trusted_keys)
        }
        SignatureRequirement::SameTeamAsHost => {
            // Trusted only inside the host's own installation, proven by real
            // containment in the trusted bundled root - never by a record's
            // origin claim, and never by a publisher signature alone.
            verify_signature_if_present(package_root, plugin_id, plugin_version, trusted_keys)?;
            verify_bundled_seal(package_root, origin, bundled_root)
        }
    }
}

/// Proves a `sameTeamAsHost` package really lives inside the host's own
/// installation: the origin must be bundled and the package root must sit
/// inside the trusted resource root the discoverer reported.
fn verify_bundled_seal(
    package_root: &Path,
    origin: InstallOrigin,
    bundled_root: Option<&Path>,
) -> Result<(), TrustError> {
    if origin != InstallOrigin::Bundled {
        return Err(TrustError::HostSealRequired);
    }
    let Some(bundled_root) = bundled_root else {
        return Err(TrustError::HostSealRequired);
    };
    let bundled = bundled_root
        .canonicalize()
        .map_err(|_| TrustError::HostSealRequired)?;
    let package = package_root
        .canonicalize()
        .map_err(|_| TrustError::HostSealRequired)?;
    if package.starts_with(&bundled) {
        Ok(())
    } else {
        Err(TrustError::HostSealRequired)
    }
}

/// Full load-time trust check: the host policy decides what the package must
/// prove, the package cannot downgrade it.
///
/// `expected_content_digest` is the digest recorded when the user approved an
/// unsigned community package; load paths must pass it for community origin,
/// install paths use [`verify_for_install`] while they are creating the
/// record.
pub fn verify_for_origin(
    package_root: &Path,
    plugin_id: &str,
    plugin_version: &str,
    manifest: &serde_json::Value,
    origin: InstallOrigin,
    expected_content_digest: Option<&str>,
    bundled_root: Option<&Path>,
    trusted_keys: &BTreeMap<String, VerifyingKey>,
) -> Result<(), TrustError> {
    verify_for_install(
        package_root,
        plugin_id,
        plugin_version,
        manifest,
        origin,
        bundled_root,
        trusted_keys,
    )?;
    // Signed or not, the load path rechecks the package against the digest
    // recorded when its bytes were approved; a publisher signature proves
    // who released the bytes, not that these bytes are what the user saw.
    if matches!(
        origin,
        InstallOrigin::Community | InstallOrigin::Marketplace
    ) {
        let expected = expected_content_digest.ok_or(TrustError::ProvenanceMissing)?;
        let actual = content_digest(package_root)?;
        if actual != expected {
            return Err(TrustError::ContentChanged);
        }
    }
    Ok(())
}

/// Verifies one signature document against the live package bytes.
pub fn verify_document(
    package_root: &Path,
    plugin_id: &str,
    plugin_version: &str,
    document: &SignatureDocument,
    trusted_keys: &BTreeMap<String, VerifyingKey>,
) -> Result<(), TrustError> {
    let Some(public_key) = trusted_keys.get(&document.key_id) else {
        return Err(TrustError::UntrustedKey(document.key_id.clone()));
    };
    let signature_bytes = STANDARD_BASE64
        .decode(document.signature.as_bytes())
        .map_err(|_| TrustError::SignatureInvalid("signature is not base64".to_string()))?;
    if document.schema_version != SCHEMA_VERSION
        || document.algorithm != ALGORITHM
        || !is_valid_key_id(&document.key_id)
        || document.plugin_id != plugin_id
        || document.plugin_version != plugin_version
        || signature_bytes.len() != 64
    {
        return Err(TrustError::SignatureInvalid(
            "document fields do not match the package".to_string(),
        ));
    }
    let actual = file_digests(package_root)?;
    if actual.keys().len() != document.files.len()
        || actual
            .keys()
            .zip(document.files.keys())
            .any(|(left, right)| left != right)
    {
        return Err(TrustError::SignatureInvalid(
            "the package file list does not match its signature".to_string(),
        ));
    }
    for (path, digest) in &actual {
        if document.files.get(path).map(String::as_str) != Some(digest.as_str()) {
            return Err(TrustError::SignatureInvalid(format!(
                "the package file was changed after signing: {path}"
            )));
        }
    }
    let payload = canonical_payload(
        &document.key_id,
        &document.plugin_id,
        &document.plugin_version,
        &document.files,
    );
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| TrustError::SignatureInvalid("signature is not 64 bytes".to_string()))?;
    public_key
        .verify(&payload, &signature)
        .map_err(|_| TrustError::SignatureInvalid("signature does not verify".to_string()))
}

/// SHA-256 digest of every package file, keyed by relative path with `/`
/// separators in ascending order. Refuses reparse points, symlinks, unsafe
/// names, and non-UTF-8 names; the signature document itself is skipped.
pub fn file_digests(package_root: &Path) -> Result<BTreeMap<String, String>, TrustError> {
    if !package_root.is_dir() {
        return Err(TrustError::SignatureInvalid(
            "the package root is not a directory".to_string(),
        ));
    }
    let mut digests = BTreeMap::new();
    walk_files(package_root, "", &mut digests)?;
    Ok(digests)
}

fn walk_files(
    directory: &Path,
    prefix: &str,
    digests: &mut BTreeMap<String, String>,
) -> Result<(), TrustError> {
    let entries = std::fs::read_dir(directory).map_err(|error| {
        TrustError::SignatureInvalid(format!("unreadable package entry: {error}"))
    })?;
    for entry in entries {
        let entry = entry
            .map_err(|error| TrustError::SignatureInvalid(format!("unreadable entry: {error}")))?;
        let path = entry.path();
        let name = entry.file_name();
        // Windows package names are compared as UTF-8 text; names with
        // invalid UTF-16 surrogates cannot receive a signature token.
        let name = name.to_str().ok_or_else(|| {
            TrustError::SignatureInvalid("a package entry name is not UTF-8".to_string())
        })?;
        let metadata = std::fs::symlink_metadata(&path).map_err(|error| {
            TrustError::SignatureInvalid(format!("{} is unreadable: {error}", path.display()))
        })?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            // Reparse-point attribute: covers symbolic links and junctions.
            if metadata.file_attributes() & 0x0400 != 0 {
                return Err(TrustError::SignatureInvalid(format!(
                    "{} is a reparse point; package entries must be regular files",
                    path.display()
                )));
            }
        }
        #[cfg(not(windows))]
        if metadata.file_type().is_symlink() {
            return Err(TrustError::SignatureInvalid(format!(
                "{} is a symbolic link; package entries must be regular files",
                path.display()
            )));
        }
        if metadata.is_dir() {
            let prefix = if prefix.is_empty() {
                name.to_string()
            } else {
                format!("{prefix}/{name}")
            };
            walk_files(&path, &prefix, digests)?;
            continue;
        }
        if !metadata.is_file() {
            return Err(TrustError::SignatureInvalid(format!(
                "{} is not a regular file",
                path.display()
            )));
        }
        let relative = if prefix.is_empty() {
            name.to_string()
        } else {
            format!("{prefix}/{name}")
        };
        if relative.contains('\0') || relative.contains('\n') || relative.contains('\r') {
            return Err(TrustError::SignatureInvalid(format!(
                "the package contains an unsupported file: {relative}"
            )));
        }
        if relative.split('/').any(|part| part == "..") {
            return Err(TrustError::SignatureInvalid(format!(
                "the package contains an unsupported file: {relative}"
            )));
        }
        // Only the root-level signature document is excluded; a nested file
        // with the same name is an ordinary package file.
        if relative == SIGNATURE_FILE_NAME {
            continue;
        }
        let bytes = std::fs::read(&path).map_err(|error| {
            TrustError::SignatureInvalid(format!("{} is unreadable: {error}", path.display()))
        })?;
        digests.insert(relative, hex(&Sha256::digest(&bytes)));
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use ed25519_dalek::{Signer, SigningKey};

    /// The RFC 8032 Ed25519 test key, used as the shared public test seed in
    /// `signature-vectors.json`; it must never sign real packages.
    const RFC8032_SEED_HEX: &str =
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
    const RFC8032_PUBLIC_HEX: &str =
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    /// RFC 8032 TEST 1: signature over the empty message.
    const RFC8032_EMPTY_SIGNATURE_HEX: &str = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

    fn test_signing_key() -> SigningKey {
        rfc8032_signing_key_for_tests()
    }

    fn hex_to_bytes(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).expect("hex byte"))
            .collect()
    }

    /// The primitive is anchored to the public RFC 8032 vector, not to this
    /// crate's own round-trip, so both platforms verify the same known answer.
    #[test]
    fn ed25519_matches_the_rfc_8032_test_vector() {
        let key = test_signing_key();
        assert_eq!(hex(&key.verifying_key().to_bytes()), RFC8032_PUBLIC_HEX);
        let signature = key.sign(b"");
        assert_eq!(hex(&signature.to_bytes()), RFC8032_EMPTY_SIGNATURE_HEX);
        assert!(key.verifying_key().verify(b"", &signature).is_ok());
    }

    /// Prints the shared fixture values; run with `--ignored --nocapture`
    /// when the fixture must be regenerated, then paste into
    /// shared/contracts/plugins/v1/fixtures/signature-vectors.json. The
    /// committed fixture was produced from the same construction (see the
    /// fixture's description); the end-to-end test below re-derives it.
    #[test]
    #[ignore = "fixture generator; output is committed as signature-vectors.json"]
    fn generate_signature_vectors_fixture() {
        let key = test_signing_key();
        let files_content = [
            ("plugin.json", "plugin manifest bytes"),
            ("language-server/bin/server.js", "console.log('server');\n"),
            ("插件/服务器.js", "console.log('非 ASCII 路径');\n"),
            ("日本語/README.md", "# サンプル\n"),
            ("assets/заметки.txt", "заметки\n"),
        ];
        let files: BTreeMap<String, String> = files_content
            .iter()
            .map(|(path, content)| (path.to_string(), hex(&Sha256::digest(content.as_bytes()))))
            .collect();
        let payload = canonical_payload("lithe-test-v1", "dev.example.plugin", "0.3.0", &files);
        let signature = key.sign(&payload);
        let digest = {
            let lines: String = files
                .iter()
                .map(|(path, digest)| format!("{}={digest}\n", token(path)))
                .collect();
            hex(&Sha256::digest(lines.as_bytes()))
        };
        println!(
            "{}",
            serde_json::json!({
                "ed25519": {
                    "seedHex": RFC8032_SEED_HEX,
                    "publicKeyHex": RFC8032_PUBLIC_HEX,
                    "messageEmptySignatureHex": RFC8032_EMPTY_SIGNATURE_HEX,
                },
                "packageFiles": files_content
                    .iter()
                    .map(|(path, content)| (path.to_string(), content.to_string()))
                    .collect::<BTreeMap<String, String>>(),
                "canonicalPayload": {
                    "keyID": "lithe-test-v1",
                    "pluginID": "dev.example.plugin",
                    "pluginVersion": "0.3.0",
                    "files": files,
                    "payloadBase64": STANDARD.encode(&payload),
                    "signatureBase64": STANDARD.encode(signature.to_bytes()),
                },
                "contentDigest": {
                    "files": files,
                    "digest": digest,
                },
            })
        );
    }

    #[test]
    fn token_encoding_matches_the_macos_base64url_rules() {
        assert_eq!(token("plugin.json"), "cGx1Z2luLmpzb24");
        // `+` and `/` map to `-` and `_`; padding is omitted.
        assert_eq!(token("~?"), "fj8");
        // Non-ASCII paths are base64url of their UTF-8 bytes: the round trip
        // reproduces the input and the output uses the URL-safe alphabet.
        let path = "插件/服务器.js";
        let token = token(path);
        assert!(!token.contains('+') && !token.contains('/') && !token.contains('='));
        let decoded = BASE64URL_NO_PAD
            .decode(token.as_bytes())
            .expect("token decodes");
        assert_eq!(String::from_utf8(decoded).expect("UTF-8"), path);
    }

    /// A `sameTeamAsHost` package is only honored for a bundled origin whose
    /// root is provably inside the trusted resource root; a record's claim
    /// alone, or a root outside the installation, is a refused seal.
    #[test]
    fn bundled_origin_requires_a_verified_bundled_root() {
        let manifest = serde_json::json!({
            "vendor": { "signatureRequirement": "sameTeamAsHost" }
        });
        let root = std::env::temp_dir().join(format!(
            "lithe-sig-seal-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        let package_root = root.join("OfficialPlugins").join("pkg");
        std::fs::create_dir_all(&package_root).expect("package dir");
        let outside_root =
            std::env::temp_dir().join(format!("lithe-sig-seal-outside-{}", std::process::id()));
        let keys = trusted_keys();

        // No trusted root at all: a launch path that cannot prove the seal
        // refuses instead of guessing.
        assert_eq!(
            verify_for_install(
                &package_root,
                "dev.lithe.plugin.php-support",
                "1.0.0",
                &manifest,
                InstallOrigin::Bundled,
                None,
                &keys
            ),
            Err(TrustError::HostSealRequired)
        );
        // A trusted root that does not contain the package.
        assert_eq!(
            verify_for_install(
                &package_root,
                "dev.lithe.plugin.php-support",
                "1.0.0",
                &manifest,
                InstallOrigin::Bundled,
                Some(&outside_root),
                &keys
            ),
            Err(TrustError::HostSealRequired)
        );
        // The real containment proof.
        assert_eq!(
            verify_for_install(
                &package_root,
                "dev.lithe.plugin.php-support",
                "1.0.0",
                &manifest,
                InstallOrigin::Bundled,
                Some(&root.join("OfficialPlugins")),
                &keys
            ),
            Ok(())
        );
        // The same package on disk can never claim the seal, even though the
        // root would contain it, because the origin is not bundled.
        assert_eq!(
            verify_for_install(
                &package_root,
                "dev.lithe.plugin.php-support",
                "1.0.0",
                &manifest,
                InstallOrigin::Community,
                Some(&root.join("OfficialPlugins")),
                &keys
            ),
            Err(TrustError::HostSealRequired)
        );
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside_root);
    }

    #[test]
    fn unsafe_package_entries_are_refused() {
        let root = std::env::temp_dir().join(format!("lithe-sig-unsafe-{}", std::process::id()));
        let nested = root.join("sub");
        std::fs::create_dir_all(&nested).expect("dir");
        std::fs::write(nested.join("server.js"), b"ok").expect("file");
        let digests = file_digests(&root).expect("digests");
        assert!(digests.contains_key("sub/server.js"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn official_ids_keep_their_pinned_signature_requirement() {
        assert_eq!(
            official_signature_requirement("dev.lithe.plugin.php-support"),
            Some(SignatureRequirement::SameTeamAsHost)
        );
        assert_eq!(
            official_signature_requirement("dev.lithe.plugin.go-support"),
            Some(SignatureRequirement::PublisherPackage)
        );
        assert_eq!(official_signature_requirement("io.example.plugin"), None);
        let manifest = serde_json::json!({
            "vendor": { "signatureRequirement": "none" }
        });
        assert_eq!(
            declared_signature_requirement(&manifest),
            Ok(SignatureRequirement::Unsigned)
        );
        assert_eq!(
            declared_signature_requirement(&serde_json::json!({ "vendor": {} })),
            Err(TrustError::InvalidPolicy)
        );
    }

    /// Regenerating the fixture changes the expected digest; the test then
    /// forces a deliberate look at the fixture instead of drifting silently.
    #[test]
    fn shared_fixture_verifies_end_to_end() {
        let fixture_path = std::path::PathBuf::from(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../shared/contracts/plugins/v1/fixtures/signature-vectors.json"
        ));
        let fixture: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(&fixture_path).expect("signature-vectors.json is readable"),
        )
        .expect("signature-vectors.json is JSON");

        // The primitive anchor in the fixture matches the RFC vector above.
        assert_eq!(fixture["ed25519"]["seedHex"], RFC8032_SEED_HEX);
        assert_eq!(fixture["ed25519"]["publicKeyHex"], RFC8032_PUBLIC_HEX);
        assert_eq!(
            fixture["ed25519"]["messageEmptySignatureHex"],
            RFC8032_EMPTY_SIGNATURE_HEX
        );

        // The recorded package signature verifies with the shared public key
        // and the recorded canonical payload reproduces byte for byte.
        let payload_case = &fixture["canonicalPayload"];
        let mut files = BTreeMap::new();
        for (path, digest) in payload_case["files"].as_object().expect("files object") {
            files.insert(
                path.clone(),
                digest.as_str().expect("digest string").to_string(),
            );
        }
        let payload = canonical_payload(
            payload_case["keyID"].as_str().expect("keyID"),
            payload_case["pluginID"].as_str().expect("pluginID"),
            payload_case["pluginVersion"]
                .as_str()
                .expect("pluginVersion"),
            &files,
        );
        assert_eq!(
            STANDARD.encode(&payload),
            payload_case["payloadBase64"]
                .as_str()
                .expect("payloadBase64"),
            "canonical payload bytes diverged from the shared fixture"
        );
        let key = test_signing_key();
        let signature = key.sign(&payload);
        assert_eq!(
            STANDARD.encode(signature.to_bytes()),
            payload_case["signatureBase64"]
                .as_str()
                .expect("signatureBase64"),
            "deterministic Ed25519 must reproduce the shared signature"
        );

        // The materialized package tree verifies through the real verify path.
        let root = std::env::temp_dir().join(format!(
            "lithe-sig-vector-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        for (path, content) in fixture["packageFiles"].as_object().expect("packageFiles") {
            let target = root.join(path);
            std::fs::create_dir_all(target.parent().expect("parent")).expect("package dir");
            std::fs::write(&target, content.as_str().expect("content")).expect("package file");
        }
        let document = SignatureDocument {
            schema_version: SCHEMA_VERSION,
            algorithm: ALGORITHM.to_string(),
            key_id: payload_case["keyID"].as_str().expect("keyID").to_string(),
            plugin_id: payload_case["pluginID"]
                .as_str()
                .expect("pluginID")
                .to_string(),
            plugin_version: payload_case["pluginVersion"]
                .as_str()
                .expect("pluginVersion")
                .to_string(),
            files,
            signature: payload_case["signatureBase64"]
                .as_str()
                .expect("signatureBase64")
                .to_string(),
        };
        verify_document(
            &root,
            &document.plugin_id,
            &document.plugin_version,
            &document,
            &{
                let mut keys = BTreeMap::new();
                keys.insert("lithe-test-v1".to_string(), key.verifying_key());
                keys
            },
        )
        .expect("fixture package verifies");

        // Tampering with any file is rejected.
        std::fs::write(root.join("plugin.json"), b"changed bytes").expect("tamper");
        assert!(matches!(
            verify_document(
                &root,
                &document.plugin_id,
                &document.plugin_version,
                &document,
                &{
                    let mut keys = BTreeMap::new();
                    keys.insert("lithe-test-v1".to_string(), key.verifying_key());
                    keys
                }
            ),
            Err(TrustError::SignatureInvalid(_))
        ));
        let _ = std::fs::remove_dir_all(&root);

        // The recorded content digest matches the un-tampered tree.
        let digest_case = &fixture["contentDigest"];
        let mut digest_files = BTreeMap::new();
        for (path, digest) in digest_case["files"].as_object().expect("digest files") {
            digest_files.insert(
                path.clone(),
                digest.as_str().expect("digest string").to_string(),
            );
        }
        let expected_lines: String = digest_files
            .iter()
            .map(|(path, digest)| format!("{}={digest}\n", token(path)))
            .collect();
        assert_eq!(
            hex(&Sha256::digest(expected_lines.as_bytes())),
            digest_case["digest"].as_str().expect("digest"),
            "content digest diverged from the shared fixture"
        );
    }
}
