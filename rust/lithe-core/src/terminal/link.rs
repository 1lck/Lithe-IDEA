//! Interprets text that a terminal host recognised as a possible file link.
//!
//! Hosts own hit regions, whether the file exists, and how a target is opened. Core
//! owns what the text means: `path:line:column` suffixes, `file://` decoding, tilde
//! expansion and mapping relative paths onto the working directory. Core never guesses
//! from file extensions; the host's existence check decides whether a link is real.

use serde::{Deserialize, Serialize};

const MAX_TEXTS: usize = 256;
const MAX_TEXT_BYTES: usize = 4096;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Candidate link texts plus the facts needed to resolve them.
pub struct ParseLinkTargetsRequest {
    pub texts: Vec<String>,
    /// Working directory relative paths are resolved against.
    #[serde(default)]
    pub base_directory: Option<String>,
    /// Home directory used for `~` expansion.
    #[serde(default)]
    pub home_directory: Option<String>,
    /// URI schemes that name host-specific file providers; they are opaque paths, not web links.
    #[serde(default)]
    pub provider_schemes: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", tag = "kind")]
/// A resolved link.
pub enum LinkTarget {
    /// A path to check and open. `explicit` is true when the text itself says it is a path
    /// (separator, `~`, `file://`, or a line suffix) rather than a bare word.
    #[serde(rename_all = "camelCase")]
    File {
        path: String,
        line: Option<u32>,
        column: Option<u32>,
        explicit: bool,
    },
    /// A non-file URL for the system to open.
    External { url: String },
}

#[derive(Debug, Serialize)]
/// One entry per requested text; `None` when the text cannot name a link.
pub struct ParseLinkTargetsResponse {
    pub targets: Vec<Option<LinkTarget>>,
}

fn scheme_of(text: &str) -> Option<&str> {
    let (scheme, rest) = text.split_once(':')?;
    let mut chars = scheme.chars();
    let valid = chars.next()?.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    (valid && rest.starts_with("//")).then_some(scheme)
}

fn split_location(text: &str) -> (&str, Option<u32>, Option<u32>) {
    let number = |part: &str| {
        if part.is_empty() || part.len() > 9 || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        part.parse::<u32>().ok().filter(|value| *value > 0)
    };
    if let Some((rest, last)) = text.rsplit_once(':') {
        if let Some(last) = number(last) {
            if let Some((path, line)) = rest.rsplit_once(':') {
                if let Some(line) = number(line) {
                    return (path, Some(line), Some(last));
                }
            }
            return (rest, Some(last), None);
        }
    }
    (text, None, None)
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = text.get(index + 1..index + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn is_drive_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'/' | b'\\')
}

/// Decodes `file://[host]/path`; a non-local host becomes a UNC path.
fn decode_file_uri(text: &str) -> Option<String> {
    let rest = &text[text.find("//")? + 2..];
    let (host, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, ""),
    };
    let path = percent_decode(path)?;
    let path = match path.strip_prefix('/') {
        Some(stripped) if is_drive_path(stripped) => stripped.to_string(),
        _ => path,
    };
    if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
        Some(path)
    } else {
        Some(format!(
            "\\\\{}{}",
            percent_decode(host)?,
            path.replace('/', "\\")
        ))
    }
}

/// Splits a Windows drive or UNC root from the rest; POSIX paths have no root prefix here.
fn split_root(path: &str) -> Option<(String, &str)> {
    if is_drive_path(path) {
        return Some((path[..2].to_string(), &path[2..]));
    }
    let rest = path.strip_prefix("\\\\")?;
    let mut parts = rest.splitn(3, ['\\', '/']);
    let host = parts.next().unwrap_or("");
    let share = parts.next().unwrap_or("");
    let body = parts.next().unwrap_or("");
    Some((format!("\\\\{host}\\{share}"), body))
}

/// Lexically resolves `.` and `..` below `root`, joining with the separator of the style.
fn normalize(root: &str, body: &str, windows_style: bool) -> String {
    let separator = if windows_style { "\\" } else { "/" };
    let mut segments: Vec<&str> = Vec::new();
    for segment in body.split(['/', '\\']) {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop();
            }
            other => segments.push(other),
        }
    }
    format!("{root}{separator}{}", segments.join(separator))
}

fn is_provider(scheme: &str, request: &ParseLinkTargetsRequest) -> bool {
    request
        .provider_schemes
        .iter()
        .any(|known| known.eq_ignore_ascii_case(scheme))
}

fn resolve_path(path: &str, request: &ParseLinkTargetsRequest) -> Option<String> {
    let expanded;
    let mut path = path;
    if path == "~" || path.starts_with("~/") || path.starts_with("~\\") {
        expanded = format!("{}{}", request.home_directory.as_deref()?, &path[1..]);
        path = &expanded;
    }
    if path.is_empty() {
        return None;
    }
    // A provider URI names a root of its own and is returned as written.
    if let Some(scheme) = scheme_of(path) {
        return is_provider(scheme, request).then(|| path.to_string());
    }
    let base = request
        .base_directory
        .as_deref()
        .filter(|base| !base.is_empty());
    // Under a provider workspace, relative and rooted POSIX paths stay inside the provider.
    if let Some(base) = base {
        if let Some(scheme) = scheme_of(base).filter(|scheme| is_provider(scheme, request)) {
            let after = &base[scheme.len() + 3..];
            let authority_end = after.find('/').unwrap_or(after.len());
            let prefix = &base[..scheme.len() + 3 + authority_end];
            let body = if path.starts_with('/') {
                path.to_string()
            } else {
                format!("{}/{path}", &after[authority_end..])
            };
            return Some(format!("{prefix}{}", normalize("", &body, false)));
        }
    }
    if let Some((root, body)) = split_root(path) {
        return Some(normalize(&root, body, true));
    }
    if path.starts_with('/') {
        return Some(normalize("", path, false));
    }
    let base = base?;
    let (root, body, windows_style) = match split_root(base) {
        Some((root, body)) => (root, body, true),
        None => (String::new(), base, base.contains('\\')),
    };
    Some(normalize(&root, &format!("{body}/{path}"), windows_style))
}

fn parse_one(text: &str, request: &ParseLinkTargetsRequest) -> Option<LinkTarget> {
    let text = text.trim();
    if text.is_empty() || text.len() > MAX_TEXT_BYTES {
        return None;
    }
    let scheme = scheme_of(text);
    let is_file_uri = scheme.is_some_and(|scheme| scheme.eq_ignore_ascii_case("file"));
    let provider = scheme.is_some_and(|scheme| is_provider(scheme, request));
    let mailto = text
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("mailto:"));
    if mailto || (scheme.is_some() && !is_file_uri && !provider) {
        return Some(LinkTarget::External {
            url: text.to_string(),
        });
    }
    let (without_location, line, column) = split_location(text);
    let decoded;
    let raw = if is_file_uri {
        decoded = decode_file_uri(without_location)?;
        decoded.as_str()
    } else {
        without_location
    };
    let explicit = is_file_uri
        || provider
        || line.is_some()
        || raw.contains(['/', '\\'])
        || raw.starts_with('~');
    Some(LinkTarget::File {
        path: resolve_path(raw, request)?,
        line,
        column,
        explicit,
    })
}

/// Resolves every candidate text; the response has the same length and order as the request.
pub fn parse_link_targets(
    request: ParseLinkTargetsRequest,
) -> Result<ParseLinkTargetsResponse, crate::CoreError> {
    if request.texts.len() > MAX_TEXTS {
        return Err(crate::CoreError::new(
            crate::ErrorCode::InvalidRequest,
            "Too many terminal link candidates",
        ));
    }
    let targets = request
        .texts
        .iter()
        .map(|text| parse_one(text, &request))
        .collect();
    Ok(ParseLinkTargetsResponse { targets })
}
