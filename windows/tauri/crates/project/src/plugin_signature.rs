//! Read-only verification of the existing publisher package format. Ed25519 is
//! delegated to ring; this adapter supplies bounded native file-tree evidence.
//! A manifest, installation record or directory name never proves publisher origin.

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::{
    Deserialize,
    de::{self, MapAccess, Visitor},
};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    fs::{self, File, Metadata},
    io::Read,
    path::{Component, Path},
    time::{Duration, Instant, SystemTime},
};
use unicode_normalization::UnicodeNormalization;

/// The signature document itself is excluded from the signed file tree.
pub const SIGNATURE_FILE: &str = "lithe-plugin-signature.json";
const KEY_ID: &str = "lithe-official-plugins-v2";
// Same pinned public key as the macOS verifier; the cross-platform tests check
// this rotation boundary. No private signing material belongs in the host.
const PUBLIC_KEY: &str = "yTjUaLpCNXXEQDuan5Ymw5rCtR0JeTNmh6hyTfOFjTs=";
const MAX_ENTRIES: usize = 2_000;
const MAX_FILE: u64 = 16 * 1024 * 1024;
const MAX_TOTAL: u64 = 128 * 1024 * 1024;
const MAX_DOCUMENT: u64 = 2 * 1024 * 1024;

/// Stable refusal categories. Neither file contents nor credentials leave verification.
#[derive(Debug, PartialEq, Eq)]
pub enum SignatureError {
    Missing,
    InvalidDocument,
    UntrustedKey,
    InvalidSignature,
    UnsafeFile,
    Changed,
    Limit,
    Unreadable,
}

/// Independently verified publisher evidence, not a reusable execution grant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedPublisher {
    pub key_id: String,
    pub content_digest: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    schema_version: u64,
    algorithm: String,
    #[serde(rename = "keyID")]
    key_id: String,
    #[serde(rename = "pluginID")]
    plugin_id: String,
    plugin_version: String,
    #[serde(deserialize_with = "unique_files")]
    files: BTreeMap<String, String>,
    signature: String,
}

fn unique_files<'de, D: de::Deserializer<'de>>(
    decoder: D,
) -> Result<BTreeMap<String, String>, D::Error> {
    struct Files;
    impl<'de> Visitor<'de> for Files {
        type Value = BTreeMap<String, String>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a bounded map of unique file paths")
        }
        fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
            let mut files = BTreeMap::new();
            let mut identities = BTreeSet::new();
            while let Some((path, digest)) = map.next_entry::<String, String>()? {
                if files.len() == MAX_ENTRIES
                    || !identities.insert(path.nfc().collect::<String>())
                    || files.insert(path, digest).is_some()
                {
                    return Err(de::Error::custom("duplicate path or file limit"));
                }
            }
            Ok(files)
        }
    }
    decoder.deserialize_map(Files)
}

#[derive(PartialEq, Eq)]
struct Evidence {
    length: u64,
    modified: Option<SystemTime>,
    created: Option<SystemTime>,
    #[cfg(unix)]
    identity: (u64, u64),
}
impl Evidence {
    fn new(meta: &Metadata) -> Self {
        Self {
            length: meta.len(),
            modified: meta.modified().ok(),
            created: meta.created().ok(),
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (meta.dev(), meta.ino())
            },
        }
    }
}

struct Budget {
    deadline: Instant,
    bytes: u64,
}
impl Budget {
    fn check(&self) -> Result<(), SignatureError> {
        if Instant::now() >= self.deadline {
            Err(SignatureError::Limit)
        } else {
            Ok(())
        }
    }
}

fn reparse(meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}

fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && path != SIGNATURE_FILE
        && !path
            .chars()
            .any(|c| c.is_control() || c == '\\' || c == ':')
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn inventory(root: &Path, budget: &Budget) -> Result<BTreeMap<String, Evidence>, SignatureError> {
    let meta = fs::symlink_metadata(root).map_err(|_| SignatureError::Unreadable)?;
    if !meta.is_dir() || reparse(&meta) {
        return Err(SignatureError::UnsafeFile);
    }
    let mut directories = vec![root.to_path_buf()];
    let mut entries = 0;
    let mut files = BTreeMap::new();
    let mut identities = BTreeSet::new();
    while let Some(directory) = directories.pop() {
        budget.check()?;
        for entry in fs::read_dir(directory).map_err(|_| SignatureError::Unreadable)? {
            budget.check()?;
            entries += 1;
            if entries > MAX_ENTRIES {
                return Err(SignatureError::Limit);
            }
            let path = entry.map_err(|_| SignatureError::Unreadable)?.path();
            let relative = path
                .strip_prefix(root)
                .map_err(|_| SignatureError::UnsafeFile)?
                .components()
                .map(|component| match component {
                    Component::Normal(part) => part.to_str().ok_or(SignatureError::UnsafeFile),
                    _ => Err(SignatureError::UnsafeFile),
                })
                .collect::<Result<Vec<_>, _>>()?
                .join("/");
            let meta = fs::symlink_metadata(&path).map_err(|_| SignatureError::Unreadable)?;
            if reparse(&meta) {
                return Err(SignatureError::UnsafeFile);
            }
            if relative == SIGNATURE_FILE {
                if !meta.is_file() {
                    return Err(SignatureError::UnsafeFile);
                }
                continue;
            }
            if !safe_path(&relative) {
                return Err(SignatureError::UnsafeFile);
            }
            if meta.is_dir() {
                directories.push(path);
            } else if meta.is_file() {
                if meta.len() > MAX_FILE {
                    return Err(SignatureError::Limit);
                }
                if !identities.insert(relative.nfc().collect::<String>()) {
                    return Err(SignatureError::UnsafeFile);
                }
                files.insert(relative, Evidence::new(&meta));
            } else {
                return Err(SignatureError::UnsafeFile);
            }
        }
    }
    Ok(files)
}

fn read_document(root: &Path) -> Result<(Vec<u8>, Document), SignatureError> {
    let path = root.join(SIGNATURE_FILE);
    let meta = fs::symlink_metadata(&path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            SignatureError::Missing
        } else {
            SignatureError::Unreadable
        }
    })?;
    if !meta.is_file() || reparse(&meta) {
        return Err(SignatureError::UnsafeFile);
    }
    if meta.len() > MAX_DOCUMENT {
        return Err(SignatureError::Limit);
    }
    let mut bytes = Vec::new();
    File::open(path)
        .map_err(|_| SignatureError::Unreadable)?
        .take(MAX_DOCUMENT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| SignatureError::Unreadable)?;
    if bytes.len() as u64 > MAX_DOCUMENT {
        return Err(SignatureError::Limit);
    }
    let document = serde_json::from_slice(&bytes).map_err(|_| SignatureError::InvalidDocument)?;
    Ok((bytes, document))
}

fn token(value: &str) -> String {
    URL_SAFE_NO_PAD.encode(value.as_bytes())
}

fn payload(document: &Document) -> String {
    let mut lines = format!(
        "schemaVersion=1\nalgorithm=ed25519\nkeyID={}\npluginID={}\npluginVersion={}\n",
        document.key_id,
        token(&document.plugin_id),
        token(&document.plugin_version)
    );
    // Swift String comparison uses canonical Unicode equivalence. Sort by NFC,
    // but encode each original path's UTF-8 bytes in the established payload.
    let mut files: Vec<_> = document.files.iter().collect();
    files.sort_by_cached_key(|(path, _)| path.nfc().collect::<String>());
    for (path, digest) in files {
        lines += &format!("file={}={digest}\n", token(path));
    }
    lines
}

/// Revalidates the complete tree against the host's pinned publisher key.
/// Call under the installed-package mutation lease and again at launch boundaries.
pub fn verify(
    root: &Path,
    plugin_id: &str,
    version: &str,
) -> Result<VerifiedPublisher, SignatureError> {
    let key = STANDARD
        .decode(PUBLIC_KEY)
        .map_err(|_| SignatureError::InvalidDocument)?;
    verify_with_key(root, plugin_id, version, KEY_ID, &key)
}

fn verify_with_key(
    root: &Path,
    plugin_id: &str,
    version: &str,
    key_id: &str,
    key: &[u8],
) -> Result<VerifiedPublisher, SignatureError> {
    let mut budget = Budget {
        deadline: Instant::now() + Duration::from_secs(10),
        bytes: 0,
    };
    let (original, document) = read_document(root)?;
    if document.schema_version != 1
        || document.algorithm != "ed25519"
        || document.plugin_id != plugin_id
        || document.plugin_version != version
        || document.key_id.is_empty()
        || !document
            .key_id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || b".-_".contains(&c))
        || document.files.keys().any(|path| !safe_path(path))
        || document.files.values().any(|digest| {
            digest.len() != 64
                || !digest
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        })
    {
        return Err(SignatureError::InvalidDocument);
    }
    if document.key_id != key_id {
        return Err(SignatureError::UntrustedKey);
    }
    let signature = STANDARD
        .decode(&document.signature)
        .map_err(|_| SignatureError::InvalidDocument)?;
    if signature.len() != 64 || key.len() != 32 {
        return Err(SignatureError::InvalidDocument);
    }
    UnparsedPublicKey::new(&ED25519, key)
        .verify(payload(&document).as_bytes(), &signature)
        .map_err(|_| SignatureError::InvalidSignature)?;
    let before = inventory(root, &budget)?;
    if !before.keys().eq(document.files.keys()) {
        return Err(SignatureError::Changed);
    }
    let mut content = Sha256::new();
    for (path, evidence) in &before {
        budget.check()?;
        budget.bytes = budget
            .bytes
            .checked_add(evidence.length)
            .ok_or(SignatureError::Limit)?;
        if budget.bytes > MAX_TOTAL {
            return Err(SignatureError::Limit);
        }
        let mut file = File::open(root.join(path)).map_err(|_| SignatureError::Unreadable)?;
        if Evidence::new(&file.metadata().map_err(|_| SignatureError::Unreadable)?) != *evidence {
            return Err(SignatureError::Changed);
        }
        let mut digest = Sha256::new();
        let mut buffer = [0; 65536];
        let mut length = 0u64;
        loop {
            budget.check()?;
            let count = file
                .read(&mut buffer)
                .map_err(|_| SignatureError::Unreadable)?;
            if count == 0 {
                break;
            }
            length += count as u64;
            if length > evidence.length || length > MAX_FILE {
                return Err(SignatureError::Changed);
            }
            digest.update(&buffer[..count]);
        }
        if length != evidence.length || format!("{:x}", digest.finalize()) != document.files[path] {
            return Err(SignatureError::Changed);
        }
    }
    let mut files: Vec<_> = document.files.iter().collect();
    files.sort_by_cached_key(|(path, _)| path.nfc().collect::<String>());
    for (path, digest) in files {
        content.update(format!("{}={digest}\n", token(path)));
    }
    if inventory(root, &budget)? != before || read_document(root)?.0 != original {
        return Err(SignatureError::Changed);
    }
    Ok(VerifiedPublisher {
        key_id: document.key_id,
        content_digest: format!("{:x}", content.finalize()),
    })
}

#[cfg(test)]
mod tests;
