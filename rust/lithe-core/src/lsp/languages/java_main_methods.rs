//! Normalizes JDT's per-file `main` method discovery into Lithe's shared contract.
//!
//! The Java Debug Server's `vscode.java.resolveMainMethod` reports, for one
//! source file, every `main` method the JVM can launch together with the
//! source range of its name. Editors use it to place Run markers beside the
//! declaration. As with workspace entry points, JDT alone decides which
//! methods qualify (Java 25 instance and no-argument `main`, compact source
//! files), so this module never reads Java source; it only validates JDT's
//! answer and orders it deterministically.
//!
//! Note: entry-point ownership is recorded in .agents/notes/implemented/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md

use serde::Serialize;
use serde_json::{json, Value};

/// Java Debug Server command that lists launchable `main` methods in one file.
pub(crate) const JAVA_RESOLVE_MAIN_METHOD_COMMAND: &str = "vscode.java.resolveMainMethod";

/// Version of the serialized [`JavaMainMethods`] shape.
pub(crate) const JAVA_MAIN_METHODS_SCHEMA_VERSION: u32 = 1;

/// `workspace/executeCommand` params that discover `main` methods in one document.
pub(crate) fn java_main_methods_command(uri: &str) -> Value {
    json!({
        "command": JAVA_RESOLVE_MAIN_METHOD_COMMAND,
        "arguments": [uri],
    })
}

/// Launchable `main` methods JDT reported for one source file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaMainMethods {
    pub schema_version: u32,
    /// Methods ordered by source position, then `mainClass`, without duplicates.
    pub methods: Vec<JavaMainMethod>,
    /// JDT results that could not become methods, in JDT's order.
    pub diagnostics: Vec<JavaMainMethodDiagnostic>,
}

/// One `main` method JDT confirmed the JVM can launch.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaMainMethod {
    /// Range of the method name. Field order makes the derived ordering sort
    /// by source position first.
    pub range: JavaMainMethodRange,
    /// Class name as JDT reports it; it matches the `mainClass` of the
    /// workspace entry point generated for the same file.
    pub main_class: String,
    /// JDT project that owns the class; only used to resolve a launch again.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
}

/// Zero-based UTF-16 source range from JDT, matching `javaTestItems` ranges.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaMainMethodRange {
    pub start_line: i64,
    pub start_utf16_column: i64,
    pub end_line: i64,
    pub end_utf16_column: i64,
}

/// A JDT result that was dropped, with the reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaMainMethodDiagnostic {
    /// `invalidMethod`, `missingMainClass`, or `missingRange`.
    pub code: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_class: Option<String>,
}

/// Converts a `resolveMainMethod` result into [`JavaMainMethods`].
///
/// An array is a valid answer, including an empty one. `null` — which the
/// command handler may return for a document outside any Java project — is
/// the same fact as "no launchable method here". Any other shape is a broken server
/// contract and returns `None` so callers keep their previous markers instead
/// of mistaking it for an empty file.
pub(crate) fn normalize_java_main_methods(result: &Value) -> Option<JavaMainMethods> {
    let candidates: &[Value] = match result {
        Value::Array(candidates) => candidates,
        Value::Null => &[],
        _ => return None,
    };
    let mut methods = Vec::new();
    let mut diagnostics = Vec::new();
    for candidate in candidates {
        let Some(object) = candidate.as_object() else {
            diagnostics.push(JavaMainMethodDiagnostic {
                code: "invalidMethod",
                main_class: None,
            });
            continue;
        };
        let main_class = object
            .get("mainClass")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let Some(main_class) = main_class else {
            diagnostics.push(JavaMainMethodDiagnostic {
                code: "missingMainClass",
                main_class: None,
            });
            continue;
        };
        // Without a range the marker has no line to sit on; guessing one from
        // source text would reintroduce Lithe-owned Java rules.
        let Some(range) = object.get("range").and_then(normalize_range) else {
            diagnostics.push(JavaMainMethodDiagnostic {
                code: "missingRange",
                main_class: Some(main_class.to_string()),
            });
            continue;
        };
        let project_name = object
            .get("projectName")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        methods.push(JavaMainMethod {
            range,
            main_class: main_class.to_string(),
            project_name,
        });
    }
    methods.sort();
    methods.dedup();
    Some(JavaMainMethods {
        schema_version: JAVA_MAIN_METHODS_SCHEMA_VERSION,
        methods,
        diagnostics,
    })
}

fn integer_value(value: Option<&Value>) -> Option<i64> {
    value.and_then(Value::as_i64).filter(|value| *value >= 0)
}

fn normalize_range(value: &Value) -> Option<JavaMainMethodRange> {
    let start = value.get("start")?;
    let end = value.get("end")?;
    Some(JavaMainMethodRange {
        start_line: integer_value(start.get("line"))?,
        start_utf16_column: integer_value(start.get("character"))?,
        end_line: integer_value(end.get("line"))?,
        end_utf16_column: integer_value(end.get("character"))?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn range(line: i64, start: i64, end: i64) -> Value {
        json!({
            "start": { "line": line, "character": start },
            "end": { "line": line, "character": end }
        })
    }

    #[test]
    fn command_passes_the_document_uri_to_java_debug() {
        assert_eq!(
            java_main_methods_command("file:///work/src/App.java"),
            json!({
                "command": "vscode.java.resolveMainMethod",
                "arguments": ["file:///work/src/App.java"]
            })
        );
    }

    // Shape captured from JDT LS 1.61.0 with Java Debug 0.53.2 on a Java 25
    // project; the instance `main` must survive because JDT accepted it.
    #[test]
    fn keeps_every_method_jdt_accepted_in_source_order() {
        let result = json!([
            { "range": range(9, 16, 20), "mainClass": "demo.Outer$Inner", "projectName": "app" },
            { "range": range(1, 33, 37), "mainClass": "demo.InstanceArgs", "projectName": "app" }
        ]);
        let normalized = normalize_java_main_methods(&result).expect("array result");
        assert!(normalized.diagnostics.is_empty());
        assert_eq!(normalized.schema_version, 1);
        assert_eq!(
            normalized
                .methods
                .iter()
                .map(|method| (method.range.start_line, method.main_class.as_str()))
                .collect::<Vec<_>>(),
            vec![(1, "demo.InstanceArgs"), (9, "demo.Outer$Inner")]
        );
        assert_eq!(normalized.methods[0].project_name.as_deref(), Some("app"));
        assert_eq!(normalized.methods[0].range.start_utf16_column, 33);
    }

    #[test]
    fn null_result_means_no_methods() {
        let normalized = normalize_java_main_methods(&Value::Null).expect("null result");
        assert!(normalized.methods.is_empty());
        assert!(normalized.diagnostics.is_empty());
    }

    #[test]
    fn malformed_entries_are_diagnosed_without_hiding_valid_peers() {
        let result = json!([
            "not-a-method",
            { "range": range(0, 0, 4) },
            { "mainClass": "demo.NoRange" },
            { "range": range(2, 4, 8), "mainClass": "demo.App", "projectName": "  " },
            { "range": range(2, 4, 8), "mainClass": "demo.App" }
        ]);
        let normalized = normalize_java_main_methods(&result).expect("array result");
        assert_eq!(normalized.methods.len(), 1);
        assert_eq!(normalized.methods[0].main_class, "demo.App");
        assert_eq!(normalized.methods[0].project_name, None);
        assert_eq!(
            normalized
                .diagnostics
                .iter()
                .map(|diagnostic| diagnostic.code)
                .collect::<Vec<_>>(),
            vec!["invalidMethod", "missingMainClass", "missingRange"]
        );
    }

    #[test]
    fn other_shapes_are_not_misreported_as_an_empty_file() {
        assert_eq!(normalize_java_main_methods(&json!({ "methods": [] })), None);
    }
}
