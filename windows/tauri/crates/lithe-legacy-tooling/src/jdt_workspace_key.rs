//! Directory key for one JDT language-server workspace state.
//!
//! Copied from lithe-core's `lsp/languages/jdt.rs`. The Windows host clears
//! this directory outside the language-server runtime, so the key must match
//! the one Core derives when it starts JDT LS. Both sides are held to the shared
//! `jdt-workspace-key-v1.json` fixture, which the test below replays.

use sha2::{Digest, Sha256};
use std::path::Path;

/// Derives the shared directory key for one JDT LS workspace state.
///
/// Hashes the normalized workspace identity and optional structural fingerprint.
pub fn jdt_workspace_key(workspace_root: &Path, fingerprint: Option<&str>) -> String {
    let mut identity = normalized_workspace_identity(workspace_root);
    // Mix the structural fingerprint in as a null-delimited suffix so changes
    // to build files or the module set produce a fresh state directory without
    // touching the previous one.  Absent fingerprint keeps the legacy key.
    if let Some(fp) = fingerprint {
        identity.push('\x00');
        identity.push_str(fp);
    }
    let digest = Sha256::digest(identity.as_bytes());
    let mut key = String::with_capacity(digest.len() * 2);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in digest {
        key.push(HEX[(byte >> 4) as usize] as char);
        key.push(HEX[(byte & 0x0f) as usize] as char);
    }
    key
}

fn normalized_workspace_identity(workspace_root: &Path) -> String {
    let raw = workspace_root.to_string_lossy().replace('\\', "/");
    let bytes = raw.as_bytes();
    let has_drive = bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':';
    let is_unc = raw.starts_with("//");
    let (prefix, remainder, is_absolute, protected_components, fold_case) = if has_drive {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        let remainder = &raw[2..];
        (
            format!("{drive}:"),
            remainder,
            remainder.starts_with('/'),
            0,
            true,
        )
    } else if is_unc {
        ("//".to_string(), raw.trim_start_matches('/'), true, 2, true)
    } else if raw.starts_with('/') {
        ("/".to_string(), raw.trim_start_matches('/'), true, 0, false)
    } else {
        (String::new(), raw.as_str(), false, 0, false)
    };

    let mut components: Vec<String> = Vec::new();
    for component in remainder.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if components.len() > protected_components
                    && components.last().is_some_and(|value| value != "..")
                {
                    components.pop();
                } else if !is_absolute {
                    components.push("..".to_string());
                }
            }
            value => components.push(if fold_case {
                value.to_lowercase()
            } else {
                value.to_string()
            }),
        }
    }

    let joined = components.join("/");
    match (prefix.as_str(), joined.is_empty(), is_absolute) {
        ("", true, _) => ".".to_string(),
        ("/", true, _) => "/".to_string(),
        ("//", true, _) => "//".to_string(),
        (prefix, true, _) => prefix.to_string(),
        ("", false, _) => joined,
        ("/", false, _) => format!("/{joined}"),
        ("//", false, _) => format!("//{joined}"),
        (prefix, false, true) => format!("{prefix}/{joined}"),
        (prefix, false, false) => format!("{prefix}{joined}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn fixture_cases() -> Vec<Value> {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/lsp/jdt-workspace-key-v1.json"
        ))
        .expect("JDT workspace-key fixture should be valid JSON");
        fixture["cases"]
            .as_array()
            .expect("JDT workspace-key fixture should contain cases")
            .clone()
    }

    #[test]
    fn key_matches_the_shared_compatibility_fixture() {
        for case in fixture_cases() {
            let root = case["workspaceRoot"].as_str().expect("workspaceRoot");
            let fingerprint = case["workspaceFingerprint"].as_str();

            assert_eq!(
                jdt_workspace_key(Path::new(root), fingerprint),
                case["workspaceKey"].as_str().expect("workspaceKey"),
                "case {}",
                case["name"]
            );
        }
    }

    /// Core derives the same key when it starts JDT LS. The Windows host clears
    /// the directory by this crate's key, so the two must never drift apart.
    #[test]
    fn key_matches_the_key_core_returns() {
        for case in fixture_cases() {
            let request = json!({
                "id": case["name"],
                "command": "lsp.jdtWorkspaceKey",
                "payload": {
                    "workspaceRoot": case["workspaceRoot"],
                    "workspaceFingerprint": case["workspaceFingerprint"],
                },
            });
            let response: Value =
                serde_json::from_str(&lithe_core::execute_json(&request.to_string()))
                    .expect("Core response should be JSON");
            let root = case["workspaceRoot"].as_str().expect("workspaceRoot");

            assert_eq!(
                response["data"]["workspaceKey"],
                jdt_workspace_key(Path::new(root), case["workspaceFingerprint"].as_str()),
                "case {}",
                case["name"]
            );
        }
    }

    #[test]
    fn identity_is_lexical_cross_platform_and_unique() {
        assert_eq!(
            jdt_workspace_key(Path::new(r"C:\Users\Ada\Project\.\src\.."), None),
            jdt_workspace_key(Path::new("c:/users/ada/project"), None)
        );
        assert_eq!(
            jdt_workspace_key(Path::new("/workspace/project/./src/.."), None),
            jdt_workspace_key(Path::new("/workspace/project"), None)
        );
        assert_ne!(
            jdt_workspace_key(Path::new("/workspace/project"), None),
            jdt_workspace_key(Path::new("/workspace/other"), None)
        );
    }
}
