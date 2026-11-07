//! Lexical workspace containment for native paths named by language servers.
//!
//! Hosts pass absolute paths (and, where they can resolve symlinks, the real
//! paths); Core compares them through their canonical file URIs so dot
//! segments, separators, percent-encoding and Windows drive/UNC syntax follow
//! the `lsp.documentUri` rules. Windows comparisons ignore ASCII case, as the
//! Windows filesystem does. No filesystem access happens here.

use crate::lsp::DocumentPathPlatform;
use crate::protocol::CoreError;

/// One workspace root in canonical URI form.
pub(crate) struct WorkspaceScope {
    /// Root URI with a trailing `/`, case-folded for Windows paths.
    prefix: String,
    platform: DocumentPathPlatform,
}

impl WorkspaceScope {
    pub(crate) fn new(root: &str, platform: DocumentPathPlatform) -> Result<Self, CoreError> {
        let mut prefix = comparable(root, platform)?;
        if !prefix.ends_with('/') {
            prefix.push('/');
        }
        Ok(Self { prefix, platform })
    }

    /// True when `path` lies strictly below the root; the root itself is not a
    /// file inside it.
    pub(crate) fn contains(&self, path: &str) -> Result<bool, CoreError> {
        let target = comparable(path, self.platform)?;
        Ok(target.len() > self.prefix.len() && target.starts_with(&self.prefix))
    }

    /// `/`-separated path of `path` relative to the root, when inside it.
    pub(crate) fn relative_path(&self, path: &str) -> Result<Option<String>, CoreError> {
        if !self.contains(path)? {
            return Ok(None);
        }
        let uri = self.platform.document_uri(path)?;
        // The case-folded prefix has the same byte length as the original URI
        // prefix because only ASCII letters are folded.
        let relative = &uri[self.prefix.len()..];
        Ok(Some(crate::lsp::percent_decode(relative)))
    }
}

/// Canonical URI used for comparison. Distinct spellings of one Windows path
/// (drive letter case, separators, `\\?\` prefixes) compare equal.
pub(crate) fn comparable(path: &str, platform: DocumentPathPlatform) -> Result<String, CoreError> {
    let uri = platform.document_uri(path)?;
    Ok(if platform.is_windows_path(path) {
        uri.to_ascii_lowercase()
    } else {
        uri
    })
}
