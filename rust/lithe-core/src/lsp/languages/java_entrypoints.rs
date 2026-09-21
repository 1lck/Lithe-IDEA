//! Normalizes JDT's Java entry-point discovery into Lithe's shared contract.
//!
//! JDT LS, through the Java Debug Server's `vscode.java.resolveMainClass`,
//! decides which classes the JVM can launch. The rules change with the Java
//! language (instance and no-argument `main` in Java 25, compact source files),
//! so this module never reads Java source to add, drop, or second-guess an
//! entry. It only turns JDT's answer into workspace-relative, deterministic
//! facts and reports what it could not accept.
//!
//! Note: entry-point ownership is recorded in .agents/notes/implemented/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md

use crate::lsp::percent_decode;
use serde::Serialize;
use serde_json::{json, Value};

/// Java Debug Server command that lists launchable classes in a scope.
pub(crate) const JAVA_RESOLVE_MAIN_CLASS_COMMAND: &str = "vscode.java.resolveMainClass";

/// Version of the serialized [`JavaEntrypoints`] shape.
pub(crate) const JAVA_ENTRYPOINTS_SCHEMA_VERSION: u32 = 1;

/// `workspace/executeCommand` params that discover entry points under one workspace.
///
/// Passing the workspace URI scopes the search to projects inside it instead of
/// every project JDT has imported.
pub(crate) fn java_entrypoints_command(root_uri: &str) -> Value {
    json!({
        "command": JAVA_RESOLVE_MAIN_CLASS_COMMAND,
        "arguments": [root_uri],
    })
}

/// Launchable Java classes JDT reported for one workspace.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaEntrypoints {
    pub schema_version: u32,
    /// Entries ordered by `sourcePath`, then `mainClass`, without duplicates.
    pub entries: Vec<JavaEntrypoint>,
    /// JDT results that could not become entries, in JDT's order.
    pub diagnostics: Vec<JavaEntrypointDiagnostic>,
}

/// One class JDT confirmed the JVM can launch.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaEntrypoint {
    /// Workspace-relative path with `/` separators; the stable identity of the
    /// entry, because two modules may declare the same class name.
    pub source_path: String,
    /// Class name as JDT reports it, including a `module/` prefix for modular
    /// projects; it is passed back to JDT and the JVM unchanged.
    pub main_class: String,
    /// JDT project that owns the class. It only helps JDT resolve the launch
    /// again and is not part of any stable identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
}

/// A JDT result that was dropped, with the reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaEntrypointDiagnostic {
    /// `missingMainClass`, `missingSourcePath`, or `outsideWorkspace`.
    pub code: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_class: Option<String>,
    /// Platform-owned detail, such as the absolute path JDT returned.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Converts a `resolveMainClass` result into [`JavaEntrypoints`].
///
/// `canonical_root` is the workspace directory with symbolic links resolved,
/// when the platform could resolve it. JDT may report either spelling — a
/// workspace opened through `/var` on macOS comes back under `/private/var` —
/// so a file inside either one is inside the workspace.
///
/// Returns `None` when the result is not a list, which means the server
/// answered something other than this command's contract.
pub(crate) fn normalize_java_entrypoints(
    root_uri: &str,
    canonical_root: Option<&str>,
    result: &Value,
) -> Option<JavaEntrypoints> {
    let candidates = result.as_array()?;
    let roots = workspace_root_path(root_uri)
        .into_iter()
        .chain(canonical_root.map(|root| root.replace('\\', "/").trim_end_matches('/').to_string()))
        .collect::<Vec<_>>();
    let mut entries = Vec::new();
    let mut diagnostics = Vec::new();
    for candidate in candidates {
        let main_class = candidate
            .get("mainClass")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let Some(main_class) = main_class else {
            diagnostics.push(JavaEntrypointDiagnostic {
                code: "missingMainClass",
                main_class: None,
                detail: None,
            });
            continue;
        };
        // A pathless entry cannot be told apart from a same-named class in
        // another module, so it is reported instead of guessed at.
        let Some(file_path) = candidate
            .get("filePath")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        else {
            diagnostics.push(JavaEntrypointDiagnostic {
                code: "missingSourcePath",
                main_class: Some(main_class.to_string()),
                detail: None,
            });
            continue;
        };
        let Some(source_path) = roots
            .iter()
            .find_map(|root| workspace_relative_path(root, file_path))
        else {
            diagnostics.push(JavaEntrypointDiagnostic {
                code: "outsideWorkspace",
                main_class: Some(main_class.to_string()),
                detail: Some(file_path.to_string()),
            });
            continue;
        };
        let project_name = candidate
            .get("projectName")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        entries.push(JavaEntrypoint {
            source_path,
            main_class: main_class.to_string(),
            project_name,
        });
    }
    entries.sort();
    entries.dedup();
    Some(JavaEntrypoints {
        schema_version: JAVA_ENTRYPOINTS_SCHEMA_VERSION,
        entries,
        diagnostics,
    })
}

/// Decodes a `file:` workspace URI into a `/`-separated absolute path.
///
/// This is done textually rather than through the host OS so that a Windows
/// URI such as `file:///c%3A/work` normalizes identically on every platform.
fn workspace_root_path(root_uri: &str) -> Option<String> {
    let url = url::Url::parse(root_uri).ok()?;
    if url.scheme() != "file" {
        return None;
    }
    let decoded = percent_decode(url.path());
    let path = match decoded.as_bytes() {
        // `/C:/work` is how a URI carries a Windows drive path.
        [b'/', drive, b':', ..] if drive.is_ascii_alphabetic() => decoded[1..].to_string(),
        _ => decoded,
    };
    let path = match url.host_str().filter(|host| !host.is_empty()) {
        Some(host) => format!("//{host}{path}"),
        None => path,
    };
    Some(path.trim_end_matches('/').to_string())
}

/// Returns `file_path` relative to `root` with `/` separators, or `None` when
/// it is not strictly inside the workspace.
///
/// Windows drive and UNC paths compare case-insensitively, matching the file
/// system; the returned relative path keeps JDT's casing.
fn workspace_relative_path(root: &str, file_path: &str) -> Option<String> {
    let file_path = file_path.replace('\\', "/");
    let case_insensitive = is_windows_path(root) || is_windows_path(&file_path);
    let prefix_matches = file_path.len() > root.len()
        && file_path.is_char_boundary(root.len())
        && if case_insensitive {
            file_path[..root.len()].eq_ignore_ascii_case(root)
        } else {
            file_path[..root.len()] == *root
        };
    if !prefix_matches {
        return None;
    }
    let relative = file_path[root.len()..].strip_prefix('/')?;
    let is_contained = !relative.is_empty()
        && relative
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..");
    is_contained.then(|| relative.to_string())
}

fn is_windows_path(path: &str) -> bool {
    path.starts_with("//")
        || matches!(path.as_bytes(), [drive, b':', ..] if drive.is_ascii_alphabetic())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(source_path: &str, main_class: &str, project_name: Option<&str>) -> JavaEntrypoint {
        JavaEntrypoint {
            source_path: source_path.to_string(),
            main_class: main_class.to_string(),
            project_name: project_name.map(str::to_string),
        }
    }

    #[test]
    fn the_command_is_scoped_to_the_workspace() {
        assert_eq!(
            java_entrypoints_command("file:///work/app/"),
            json!({ "command": "vscode.java.resolveMainClass", "arguments": ["file:///work/app/"] })
        );
    }

    #[test]
    fn same_class_names_in_two_modules_stay_separate_entries() {
        // Maven reactors often repeat `demo.App` per module; the source path,
        // not the class name, keeps them apart.
        let result = json!([
            { "mainClass": "demo.App", "projectName": "app-b", "filePath": "/work/app-b/src/main/java/demo/App.java" },
            { "mainClass": "demo.App", "projectName": "app-a", "filePath": "/work/app-a/src/main/java/demo/App.java" }
        ]);
        let normalized =
            normalize_java_entrypoints("file:///work/", None, &result).expect("list result");
        assert_eq!(
            normalized.entries,
            vec![
                entry(
                    "app-a/src/main/java/demo/App.java",
                    "demo.App",
                    Some("app-a")
                ),
                entry(
                    "app-b/src/main/java/demo/App.java",
                    "demo.App",
                    Some("app-b")
                ),
            ]
        );
        assert!(normalized.diagnostics.is_empty());
    }

    #[test]
    fn windows_paths_match_the_workspace_uri_without_regard_to_case() {
        let result = json!([
            { "mainClass": "demo.StaticNoArgs", "projectName": "app", "filePath": "c:\\Work\\App\\src\\main\\java\\demo\\StaticNoArgs.java" }
        ]);
        let normalized = normalize_java_entrypoints("file:///C%3A/work/app", None, &result)
            .expect("list result");
        assert_eq!(
            normalized.entries,
            vec![entry(
                "src/main/java/demo/StaticNoArgs.java",
                "demo.StaticNoArgs",
                Some("app")
            )]
        );
    }

    #[test]
    fn unc_workspaces_keep_their_server_name() {
        let result = json!([
            { "mainClass": "App", "filePath": "\\\\server\\share\\app\\App.java" }
        ]);
        let normalized = normalize_java_entrypoints("file://server/share/app/", None, &result)
            .expect("list result");
        assert_eq!(normalized.entries, vec![entry("App.java", "App", None)]);
    }

    #[test]
    fn percent_encoded_workspace_uris_decode_before_matching() {
        let result = json!([
            { "mainClass": "App", "filePath": "/home/dev/my project/App.java" }
        ]);
        let normalized =
            normalize_java_entrypoints("file:///home/dev/my%20project/", None, &result)
                .expect("list result");
        assert_eq!(normalized.entries, vec![entry("App.java", "App", None)]);
    }

    #[test]
    fn unusable_results_become_diagnostics_instead_of_guesses() {
        let result = json!([
            { "projectName": "app", "filePath": "/work/app/A.java" },
            { "mainClass": "  ", "filePath": "/work/app/B.java" },
            { "mainClass": "demo.Pathless", "projectName": "app" },
            { "mainClass": "demo.Elsewhere", "filePath": "/other/Elsewhere.java" },
            { "mainClass": "demo.Sibling", "filePath": "/work/app-sibling/Sibling.java" },
            { "mainClass": "demo.Escapes", "filePath": "/work/app/../secret/Escapes.java" },
            { "mainClass": "demo.Root", "filePath": "/work/app" }
        ]);
        let normalized =
            normalize_java_entrypoints("file:///work/app/", None, &result).expect("list result");
        assert!(normalized.entries.is_empty(), "{normalized:?}");
        let codes = normalized
            .diagnostics
            .iter()
            .map(|diagnostic| (diagnostic.code, diagnostic.main_class.as_deref()))
            .collect::<Vec<_>>();
        assert_eq!(
            codes,
            vec![
                ("missingMainClass", None),
                ("missingMainClass", None),
                ("missingSourcePath", Some("demo.Pathless")),
                ("outsideWorkspace", Some("demo.Elsewhere")),
                ("outsideWorkspace", Some("demo.Sibling")),
                ("outsideWorkspace", Some("demo.Escapes")),
                ("outsideWorkspace", Some("demo.Root")),
            ]
        );
        assert_eq!(
            normalized.diagnostics[3].detail.as_deref(),
            Some("/other/Elsewhere.java")
        );
    }

    #[test]
    fn repeated_results_collapse_and_blank_project_names_are_dropped() {
        let result = json!([
            { "mainClass": "B", "projectName": " ", "filePath": "/work/B.java" },
            { "mainClass": "A", "projectName": "p", "filePath": "/work/A.java" },
            { "mainClass": "A", "projectName": "p", "filePath": "/work/A.java" }
        ]);
        let normalized =
            normalize_java_entrypoints("file:///work", None, &result).expect("list result");
        assert_eq!(
            normalized.entries,
            vec![entry("A.java", "A", Some("p")), entry("B.java", "B", None)]
        );
    }

    #[test]
    fn files_under_the_resolved_workspace_path_are_inside_the_workspace() {
        // macOS: a workspace opened as `/var/...` is reported by JDT under
        // `/private/var/...`; both spellings name the same directory.
        let result = json!([
            { "mainClass": "demo.App", "filePath": "/private/var/work/app/src/demo/App.java" }
        ]);
        let normalized = normalize_java_entrypoints(
            "file:///var/work/app/",
            Some("/private/var/work/app"),
            &result,
        )
        .expect("list result");
        assert_eq!(
            normalized.entries,
            vec![entry("src/demo/App.java", "demo.App", None)]
        );
        assert!(normalized.diagnostics.is_empty());
    }

    #[test]
    fn a_non_list_result_is_not_an_entry_list() {
        assert!(
            normalize_java_entrypoints("file:///work", None, &json!({ "mainClass": "A" }))
                .is_none()
        );
        assert!(normalize_java_entrypoints("file:///work", None, &Value::Null).is_none());
    }

    #[test]
    fn an_empty_list_is_a_valid_answer() {
        let normalized =
            normalize_java_entrypoints("file:///work", None, &json!([])).expect("list result");
        assert_eq!(
            serde_json::to_value(normalized).expect("serializes"),
            json!({ "schemaVersion": 1, "entries": [], "diagnostics": [] })
        );
    }
}
