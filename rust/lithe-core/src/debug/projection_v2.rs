//! Debug session projection version 2: source-optional frames, string references and
//! capability snapshots shared by macOS and Windows.
//!
//! Version 1 stays authoritative until every consumer migrates. The engine emits v2
//! beside it, built here from the raw adapter body so no v1 narrowing leaks into v2.

#[cfg(test)]
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Only wire version this module accepts.
pub(crate) const PROJECTION_VERSION: u32 = 2;
const MAX_ID_BYTES: usize = 256;
const MAX_REFERENCE_BYTES: usize = 128;
const MAX_OPEN_STRING_BYTES: usize = 64;
const MAX_SOURCE_REFERENCE: i64 = i32::MAX as i64;

/// One normalized projection tagged with the stop generation that produced it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SessionProjection {
    pub projection_version: u32,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// Incremented on every stop. References from an older generation are invalid after
    /// continue, step or restart, so late results carrying them must be dropped.
    pub stop_generation: u64,
    pub projection: Projection,
}

/// The payload kinds a v2 projection can carry.
///
/// Each variant wraps a struct so `deny_unknown_fields` applies to the payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub(crate) enum Projection {
    StackTrace(StackTracePayload),
    Scopes(ScopesPayload),
    Capabilities(CapabilitiesPayload),
}

/// Frames of one thread at the current stop.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StackTracePayload {
    #[serde(rename = "threadID")]
    pub thread_id: i64,
    pub frames: Vec<StackFrame>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_frames: Option<u64>,
}

/// Scopes of one frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ScopesPayload {
    #[serde(rename = "frameID")]
    pub frame_id: String,
    pub scopes: Vec<Scope>,
}

/// Capability snapshot for the session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CapabilitiesPayload {
    /// Monotonic snapshot revision; a lower revision never replaces a higher one.
    pub revision: u64,
    pub capabilities: BTreeMap<String, CapabilityState>,
}

/// Exactly one source identity, so a frame can never carry a fake path next to a reference.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub(crate) enum Source {
    /// A file inside the workspace, addressed by a workspace-relative `/` path.
    Workspace(WorkspaceSource),
    /// Adapter-provided content (for example decompiled code) fetched with the DAP
    /// `source` request; invalid once the session ends.
    Session(SessionSource),
    /// A path outside the workspace that the host authorized; the raw path is not exposed.
    External(ExternalSource),
}

/// See [`Source::Workspace`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct WorkspaceSource {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// See [`Source::Session`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SessionSource {
    pub source_reference: i64,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

/// See [`Source::External`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ExternalSource {
    #[serde(rename = "grantID")]
    pub grant_id: String,
    pub name: String,
}

/// A stack frame whose source location is optional (assembly, JIT and stripped frames).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StackFrame {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_column: Option<u64>,
    /// Opaque address string; hosts never do arithmetic on it because 64-bit values
    /// exceed the JavaScript safe integer range.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instruction_pointer_reference: Option<String>,
    #[serde(rename = "moduleID")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module_id: Option<String>,
    /// DAP enumerations are open, so unknown hints are preserved verbatim.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_filtered: Option<bool>,
}

/// A variable scope; `presentation_hint` such as `registers` drives dedicated views.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Scope {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hint: Option<String>,
    pub variables_reference: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub named_variables: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub indexed_variables: Option<u64>,
    pub expensive: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
}

/// Why a capability is or is not usable on this platform right now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CapabilityState {
    /// Reported by the adapter in `initialize` or a `capabilities` event.
    pub adapter: bool,
    /// The host extension that handles it is registered on this platform.
    pub extension: bool,
    pub authorized: bool,
    /// Must equal `adapter && extension && authorized`.
    pub supported: bool,
}

/// Decodes and validates one v2 projection from JSON text.
#[cfg(test)]
pub(crate) fn decode_projection(json: &str) -> Result<SessionProjection, CoreError> {
    let projection: SessionProjection = serde_json::from_str(json).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Invalid debug projection.")
            .with_details(error.to_string())
    })?;
    projection.validate().map_err(|message| {
        CoreError::new(ErrorCode::ParseFailed, "Invalid debug projection.").with_details(message)
    })?;
    Ok(projection)
}

impl SessionProjection {
    /// Checks the rules JSON typing cannot express: identity bounds, workspace path
    /// containment, location dependencies and the capability conjunction.
    pub(crate) fn validate(&self) -> Result<(), String> {
        if self.projection_version != PROJECTION_VERSION {
            return Err(format!(
                "unsupported projection version {}",
                self.projection_version
            ));
        }
        check_bounded("sessionID", &self.session_id, MAX_ID_BYTES)?;
        match &self.projection {
            Projection::StackTrace(payload) => {
                payload.frames.iter().try_for_each(StackFrame::validate)
            }
            Projection::Scopes(payload) => {
                check_bounded("frameID", &payload.frame_id, MAX_ID_BYTES)?;
                payload.scopes.iter().try_for_each(Scope::validate)
            }
            Projection::Capabilities(payload) => {
                for (name, state) in &payload.capabilities {
                    if !is_capability_name(name) {
                        return Err(format!("capability name {name} must match supports[A-Z]*"));
                    }
                    // The snapshot is only trustworthy if it cannot overstate support.
                    if state.supported != (state.adapter && state.extension && state.authorized) {
                        return Err(format!(
                            "capability {name} supported must equal adapter && extension && authorized"
                        ));
                    }
                }
                Ok(())
            }
        }
    }
}

impl StackFrame {
    fn validate(&self) -> Result<(), String> {
        check_bounded("frame id", &self.id, MAX_ID_BYTES)?;
        if let Some(source) = &self.source {
            source.validate()?;
        }
        // A location without a source would send the editor to a made-up file.
        if self.line.is_some() && self.source.is_none() {
            return Err("frame line requires a source".into());
        }
        if self.column.is_some() && self.line.is_none() {
            return Err("frame column requires a line".into());
        }
        if self.end_line.is_some() && self.line.is_none() {
            return Err("frame endLine requires a line".into());
        }
        if self.end_column.is_some() && self.end_line.is_none() {
            return Err("frame endColumn requires an endLine".into());
        }
        let coordinates = [self.line, self.column, self.end_line, self.end_column];
        if coordinates.iter().flatten().any(|value| *value == 0) {
            return Err("frame coordinates are one-based".into());
        }
        if let Some(reference) = &self.instruction_pointer_reference {
            check_bounded(
                "instructionPointerReference",
                reference,
                MAX_REFERENCE_BYTES,
            )?;
        }
        if let Some(hint) = &self.presentation_hint {
            check_bounded("presentationHint", hint, MAX_OPEN_STRING_BYTES)?;
        }
        Ok(())
    }
}

impl Scope {
    fn validate(&self) -> Result<(), String> {
        if let Some(hint) = &self.presentation_hint {
            check_bounded("presentationHint", hint, MAX_OPEN_STRING_BYTES)?;
        }
        self.source.as_ref().map_or(Ok(()), Source::validate)
    }
}

impl Source {
    fn validate(&self) -> Result<(), String> {
        match self {
            Source::Workspace(source) => validate_workspace_path(&source.path),
            Source::Session(source) => {
                if !(1..=MAX_SOURCE_REFERENCE).contains(&source.source_reference) {
                    return Err("sourceReference must be between 1 and 2147483647".into());
                }
                check_bounded("source name", &source.name, usize::MAX)
            }
            Source::External(source) => {
                check_bounded("grantID", &source.grant_id, MAX_ID_BYTES)?;
                check_bounded("source name", &source.name, usize::MAX)
            }
        }
    }
}

fn check_bounded(field: &str, value: &str, max_bytes: usize) -> Result<(), String> {
    if value.is_empty() || value.len() > max_bytes {
        return Err(format!("{field} must be 1 to {max_bytes} bytes"));
    }
    Ok(())
}

/// Rejects absolute paths, drive letters and `..` segments so a projection can never
/// name a file outside the workspace.
fn validate_workspace_path(path: &str) -> Result<(), String> {
    let drive_letter = path.as_bytes().get(1) == Some(&b':')
        && path.as_bytes().first().is_some_and(u8::is_ascii_alphabetic);
    if path.is_empty() || path.starts_with('/') || drive_letter {
        return Err(format!("workspace path {path} must be relative"));
    }
    if path.split('/').any(|segment| segment == "..") {
        return Err(format!("workspace path {path} escapes the workspace"));
    }
    Ok(())
}

pub(crate) fn is_capability_name(name: &str) -> bool {
    name.strip_prefix("supports")
        .and_then(|rest| rest.chars().next().map(|first| (first, rest)))
        .is_some_and(|(first, rest)| {
            first.is_ascii_uppercase() && rest.chars().all(|c| c.is_ascii_alphanumeric())
        })
}

/// Builds the v2 stack trace of one thread from a raw DAP `stackTrace` body.
///
/// Returns `None` when the adapter body is malformed; v1 remains the source of errors.
pub(crate) fn stack_trace_projection(
    session_id: &str,
    stop_generation: u64,
    thread_id: i64,
    body: &Value,
    root_path: &str,
    is_filtered: impl Fn(&str, Option<&str>, Option<&str>) -> bool,
) -> Option<SessionProjection> {
    // A malformed frame withholds the whole projection: dropping it would leave
    // `frames` shorter than the adapter's list and shift host paging offsets.
    let frames = body
        .get("stackFrames")?
        .as_array()?
        .iter()
        .map(|value| {
            let name = value.get("name")?.as_str()?.to_string();
            let source = value.get("source").and_then(|s| map_source(s, root_path));
            let hint = value.get("presentationHint").and_then(Value::as_str);
            let raw_path = value
                .get("source")
                .and_then(|s| s.get("path"))
                .and_then(Value::as_str);
            // Coordinates are meaningless without a source, so they are dropped with it.
            let has_source = source.is_some();
            let coordinate = |key: &str| {
                value
                    .get(key)
                    .and_then(Value::as_u64)
                    .filter(|number| *number > 0 && has_source)
            };
            let line = coordinate("line");
            let column = line.and(coordinate("column"));
            let end_line = line.and(coordinate("endLine"));
            let end_column = end_line.and(coordinate("endColumn"));
            Some(StackFrame {
                id: value.get("id")?.as_i64()?.to_string(),
                is_filtered: Some(is_filtered(&name, raw_path, hint)),
                name,
                source,
                line,
                column,
                end_line,
                end_column,
                instruction_pointer_reference: value
                    .get("instructionPointerReference")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                module_id: match value.get("moduleId") {
                    Some(Value::String(text)) => Some(text.clone()),
                    Some(Value::Number(number)) => Some(number.to_string()),
                    _ => None,
                },
                presentation_hint: hint.map(str::to_string),
            })
        })
        .collect::<Option<Vec<_>>>()?;
    finish(SessionProjection {
        projection_version: PROJECTION_VERSION,
        session_id: session_id.to_string(),
        stop_generation,
        projection: Projection::StackTrace(StackTracePayload {
            thread_id,
            frames,
            total_frames: body.get("totalFrames").and_then(Value::as_u64),
        }),
    })
}

/// Builds the v2 scopes of one frame from a raw DAP `scopes` body.
pub(crate) fn scopes_projection(
    session_id: &str,
    stop_generation: u64,
    frame_id: i64,
    body: &Value,
    root_path: &str,
) -> Option<SessionProjection> {
    let scopes = body
        .get("scopes")?
        .as_array()?
        .iter()
        .filter_map(|value| {
            Some(Scope {
                name: value.get("name")?.as_str()?.to_string(),
                presentation_hint: value
                    .get("presentationHint")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                variables_reference: value.get("variablesReference")?.as_u64()?,
                named_variables: value.get("namedVariables").and_then(Value::as_u64),
                indexed_variables: value.get("indexedVariables").and_then(Value::as_u64),
                expensive: value
                    .get("expensive")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                source: value.get("source").and_then(|s| map_source(s, root_path)),
            })
        })
        .collect();
    finish(SessionProjection {
        projection_version: PROJECTION_VERSION,
        session_id: session_id.to_string(),
        stop_generation,
        projection: Projection::Scopes(ScopesPayload {
            frame_id: frame_id.to_string(),
            scopes,
        }),
    })
}

/// Builds the v2 capability snapshot.
pub(crate) fn capabilities_projection(
    session_id: &str,
    stop_generation: u64,
    revision: u64,
    capabilities: BTreeMap<String, CapabilityState>,
) -> Option<SessionProjection> {
    finish(SessionProjection {
        projection_version: PROJECTION_VERSION,
        session_id: session_id.to_string(),
        stop_generation,
        projection: Projection::Capabilities(CapabilitiesPayload {
            revision,
            capabilities,
        }),
    })
}

/// A projection that fails its own validation is withheld rather than sent to hosts.
fn finish(projection: SessionProjection) -> Option<SessionProjection> {
    projection.validate().ok().map(|_| projection)
}

/// Returns `path` relative to `root`, accepting `/` and Windows backslash separators.
///
/// A drive-letter root (`C:\proj`) compares its letter case-insensitively, as the file
/// system does; POSIX roots stay case-sensitive.
fn workspace_relative(path: &str, root: &str) -> Option<String> {
    let is_windows =
        root.as_bytes().get(1) == Some(&b':') && root.as_bytes()[0].is_ascii_alphabetic();
    let normalize = |text: &str| {
        if is_windows {
            text.replace('\\', "/")
        } else {
            text.to_string()
        }
    };
    let (path, root) = (normalize(path), normalize(root));
    let root = root.trim_end_matches('/');
    let rest = if is_windows && path.len() >= root.len() && path.is_char_boundary(root.len()) {
        let (head, tail) = path.split_at(root.len());
        head.eq_ignore_ascii_case(root).then_some(tail)?
    } else {
        path.strip_prefix(root)?
    };
    rest.strip_prefix('/').map(str::to_string)
}

/// Maps a DAP source to exactly one identity.
///
/// Paths outside the workspace have no host grant yet, so they stay sourceless instead
/// of leaking a raw path; adapter-served content uses its `sourceReference`.
fn map_source(source: &Value, root_path: &str) -> Option<Source> {
    let name = source.get("name").and_then(Value::as_str);
    if let Some(path) = source.get("path").and_then(Value::as_str) {
        if let Some(relative) = workspace_relative(path, root_path) {
            if !relative.is_empty() && validate_workspace_path(&relative).is_ok() {
                return Some(Source::Workspace(WorkspaceSource {
                    path: relative,
                    name: name.map(str::to_string),
                }));
            }
        }
    }
    let reference = source.get("sourceReference").and_then(Value::as_i64)?;
    if !(1..=MAX_SOURCE_REFERENCE).contains(&reference) {
        return None;
    }
    let name = name.or_else(|| source.get("path").and_then(Value::as_str))?;
    Some(Source::Session(SessionSource {
        source_reference: reference,
        name: name.to_string(),
        origin: source
            .get("origin")
            .and_then(Value::as_str)
            .map(str::to_string),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn examples() -> Value {
        serde_json::from_str(include_str!(
            "../../../../shared/fixtures/debug/projection-v2-examples.json"
        ))
        .unwrap()
    }

    // The same inputs the draft JSON Schema accepts must decode, and round-trip
    // unchanged so no field is silently dropped between Core and the platforms.
    #[test]
    fn every_accepted_example_decodes_and_round_trips() {
        let examples = examples();
        let accepted = examples["accept"].as_array().unwrap();
        assert!(!accepted.is_empty());
        for example in accepted {
            let name = example["name"].as_str().unwrap();
            let text = example["value"].to_string();
            let decoded = decode_projection(&text).unwrap_or_else(|e| panic!("{name}: {e:?}"));
            assert_eq!(
                serde_json::to_value(&decoded).unwrap(),
                example["value"],
                "{name}"
            );
        }
    }

    // Each rejection protects one invariant: lossless addresses, no fake locations,
    // one source identity, workspace containment and stale-result protection.
    #[test]
    fn every_rejected_example_fails_to_decode() {
        let examples = examples();
        let rejected = examples["reject"].as_array().unwrap();
        assert!(!rejected.is_empty());
        for example in rejected {
            let name = example["name"].as_str().unwrap();
            assert!(
                decode_projection(&example["value"].to_string()).is_err(),
                "{name}"
            );
        }
    }

    #[test]
    fn capability_snapshot_cannot_overstate_support() {
        let text = r#"{"projectionVersion":2,"sessionID":"s","stopGeneration":0,"projection":{"kind":"capabilities","revision":1,"capabilities":{"supportsReadMemoryRequest":{"adapter":true,"extension":false,"authorized":true,"supported":true}}}}"#;
        assert!(decode_projection(text).is_err());
    }

    #[test]
    fn addresses_above_the_javascript_safe_range_survive_as_strings() {
        let text = r#"{"projectionVersion":2,"sessionID":"s","stopGeneration":1,"projection":{"kind":"stackTrace","threadID":1,"frames":[{"id":"f","name":"x","instructionPointerReference":"0xffffffffffffffff"}]}}"#;
        let decoded = decode_projection(text).unwrap();
        let Projection::StackTrace(StackTracePayload { frames, .. }) = decoded.projection else {
            panic!("expected a stack trace");
        };
        assert_eq!(
            frames[0].instruction_pointer_reference.as_deref(),
            Some("0xffffffffffffffff")
        );
    }

    #[test]
    fn unknown_presentation_hints_are_preserved() {
        let text = r#"{"projectionVersion":2,"sessionID":"s","stopGeneration":1,"projection":{"kind":"scopes","frameID":"f","scopes":[{"name":"V","presentationHint":"x-vendor-simd","variablesReference":3,"expensive":true}]}}"#;
        let decoded = decode_projection(text).unwrap();
        let Projection::Scopes(ScopesPayload { scopes, .. }) = decoded.projection else {
            panic!("expected scopes");
        };
        assert_eq!(
            scopes[0].presentation_hint.as_deref(),
            Some("x-vendor-simd")
        );
    }

    #[test]
    fn workspace_paths_accept_windows_separators_and_drive_case() {
        assert_eq!(
            workspace_relative("c:\\proj\\src\\Main.java", "C:\\proj\\").as_deref(),
            Some("src/Main.java")
        );
        assert_eq!(workspace_relative("/other/a.rs", "/proj"), None);
        assert_eq!(
            workspace_relative("/proj/a.rs", "/proj").as_deref(),
            Some("a.rs")
        );
    }

    #[test]
    fn a_malformed_frame_withholds_the_stack_trace_projection() {
        let body = serde_json::json!({"stackFrames": [
            {"id": 1, "name": "ok"}, {"name": "no id"}]});
        assert!(stack_trace_projection("s", 1, 1, &body, "/w", |_, _, _| false).is_none());
    }
}
