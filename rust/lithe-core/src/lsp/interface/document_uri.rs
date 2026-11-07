//! Platform-neutral conversion of absolute filesystem paths to LSP file URIs.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use url::Url;

// A Windows extended-length path can contain 32,767 UTF-16 units; its UTF-8
// representation may use more bytes, so do not reject valid non-ASCII paths.
const MAX_PATH_BYTES: usize = 4 * 32_767;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    path: String,
    platform: Platform,
}

/// Path syntax of a native absolute path; `auto` recognizes drive and UNC paths.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Platform {
    Posix,
    Windows,
    Auto,
}

pub(crate) fn document_uri_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    Ok(json!({"uri": document_uri(&request.path, request.platform)?}))
}

/// Public alias for planners that compare native paths through their URIs.
pub(crate) type DocumentPathPlatform = Platform;

impl Platform {
    /// Canonical file URI of an absolute native path; see `lsp.documentUri`.
    pub(crate) fn document_uri(self, path: &str) -> Result<String, CoreError> {
        document_uri(path, self)
    }

    /// True when `path` uses Windows syntax: drive or UNC, or `windows` explicitly.
    pub(crate) fn is_windows_path(self, path: &str) -> bool {
        match self {
            Platform::Windows => true,
            Platform::Posix => false,
            Platform::Auto => {
                path.starts_with("\\\\")
                    || path.starts_with("//")
                    || path.as_bytes().get(1) == Some(&b':')
            }
        }
    }
}

fn document_uri(path: &str, platform: Platform) -> Result<String, CoreError> {
    if path.len() > MAX_PATH_BYTES || path.contains('\0') {
        return Err(invalid());
    }
    let platform = match platform {
        Platform::Auto
            if path.starts_with("\\\\")
                || path.starts_with("//")
                || (path.as_bytes().get(1) == Some(&b':')) =>
        {
            Platform::Windows
        }
        Platform::Auto => Platform::Posix,
        platform => platform,
    };
    let path = match platform {
        Platform::Posix => {
            if !path.starts_with('/') {
                return Err(invalid());
            }
            path.to_owned()
        }
        Platform::Windows => {
            let path = path.replace('\\', "/");
            if let Some(rest) = path.strip_prefix("//?/UNC/") {
                format!("//{rest}")
            } else if let Some(rest) = path.strip_prefix("//?/") {
                rest.to_owned()
            } else {
                path
            }
        }
        Platform::Auto => unreachable!("auto platform is resolved above"),
    };
    let mut url = Url::parse("file:///").expect("constant file URI must parse");
    let rest = match platform {
        Platform::Posix => &path[1..],
        Platform::Windows if path.starts_with("//") => {
            let (host, rest) = path[2..].split_once('/').ok_or_else(invalid)?;
            if host.is_empty() || rest.is_empty() {
                return Err(invalid());
            }
            url.set_host(Some(host)).map_err(|_| invalid())?;
            rest
        }
        Platform::Windows => {
            let bytes = path.as_bytes();
            if bytes.len() < 3
                || !bytes[0].is_ascii_alphabetic()
                || bytes[1] != b':'
                || bytes[2] != b'/'
            {
                return Err(invalid());
            }
            path.as_str()
        }
        Platform::Auto => unreachable!("auto platform is resolved above"),
    };
    // url::PathSegmentsMut ignores `..` rather than removing the preceding
    // component. Resolve dot segments before inserting and keep drive/share
    // roots intact. Empty trailing components retain a directory separator.
    let root_components = usize::from(matches!(platform, Platform::Windows));
    let mut normalized = Vec::new();
    for segment in rest.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                if normalized.len() > root_components {
                    normalized.pop();
                }
            }
            segment => normalized.push(segment),
        }
    }
    let trailing_slash = rest.ends_with('/') || rest.ends_with("/.") || rest.ends_with("/..");
    {
        let mut segments = url.path_segments_mut().map_err(|_| invalid())?;
        segments.clear();
        for segment in normalized {
            segments.push(segment);
        }
        if trailing_slash || rest.is_empty() {
            segments.push("");
        }
    }
    Ok(url.into())
}

/// Accept a native path alongside existing string URIs without another IPC
/// round trip. Only URI fields of named LSP operations are interpreted; opaque
/// server payloads and virtual URIs remain untouched.
pub(crate) fn resolve_request_paths(command: &str, payload: &mut Value) -> Result<(), CoreError> {
    match command {
        "lsp.startServer" => resolve_field(payload, "rootUri"),
        "lsp.request" => {
            resolve_field(payload, "uri")?;
            if let Some(diagnostics) = payload.get_mut("diagnostics").and_then(Value::as_array_mut)
            {
                for diagnostic in diagnostics {
                    if let Some(related) = diagnostic
                        .get_mut("relatedInformation")
                        .and_then(Value::as_array_mut)
                    {
                        for item in related {
                            if let Some(location) = item.get_mut("location") {
                                resolve_field(location, "uri")?;
                            }
                        }
                    }
                }
            }
            Ok(())
        }
        "lsp.syncDocument" | "lsp.saveDocument" | "lsp.closeDocument" => {
            resolve_field(payload, "uri")
        }
        "lsp.workspaceFilesChanged" => {
            if let Some(changes) = payload.get_mut("changes").and_then(Value::as_array_mut) {
                for change in changes {
                    resolve_field(change, "uri")?;
                }
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Resolve a named URI field at a command-specific boundary.
pub(crate) fn resolve_field(parent: &mut Value, key: &str) -> Result<(), CoreError> {
    let Some(value) = parent.get_mut(key) else {
        return Ok(());
    };
    if value.is_object() {
        let request: Request = serde_json::from_value(value.take()).map_err(|_| invalid())?;
        *value = Value::String(document_uri(&request.path, request.platform)?);
    }
    Ok(())
}

fn invalid() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid absolute document path")
}
