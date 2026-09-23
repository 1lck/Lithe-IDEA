//! Normalizes Java Test extension discovery into Lithe's shared contract.
//!
//! The Java Test extension and JDT decide which declarations are tests. This
//! module deliberately has no annotation or naming rules: it only validates
//! the extension result and exposes stable, typed fields to platform code.
//!
//! Note: semantic ownership is recorded in .agents/notes/implemented/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md

use serde::Serialize;
use serde_json::{json, Value};

/// Java Test extension command that discovers test types and methods in a file.
pub(crate) const JAVA_FIND_TEST_ITEMS_COMMAND: &str = "vscode.java.test.findTestTypesAndMethods";

/// Version of the serialized [`JavaTestItems`] shape.
pub(crate) const JAVA_TEST_ITEMS_SCHEMA_VERSION: u32 = 1;

/// `workspace/executeCommand` params for semantic test discovery in one file.
pub(crate) fn java_test_items_command(uri: &str) -> Value {
    json!({
        "command": JAVA_FIND_TEST_ITEMS_COMMAND,
        "arguments": [uri],
    })
}

/// Java test declarations reported for one source file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaTestItems {
    pub schema_version: u32,
    pub items: Vec<JavaTestItem>,
    /// Invalid extension nodes that were ignored, in traversal order.
    pub diagnostics: Vec<JavaTestItemDiagnostic>,
}

/// One test class or method identified by the Java Test extension.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaTestItem {
    pub id: String,
    pub label: String,
    pub full_name: String,
    pub project_name: String,
    pub test_kind: i64,
    pub test_level: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jdt_handler: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<JavaTestRange>,
    pub children: Vec<JavaTestItem>,
}

/// Zero-based UTF-16 source range from JDT.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaTestRange {
    pub start_line: i64,
    pub start_utf16_column: i64,
    pub end_line: i64,
    pub end_utf16_column: i64,
}

/// One raw extension node Core could not safely expose.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaTestItemDiagnostic {
    pub code: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Converts `findTestTypesAndMethods` output into the shared typed contract.
///
/// An array is a valid answer, including an empty one. `null` is also “no
/// tests”: vscode-java-test returns its root's `children`, which stays `null`
/// until a first test is added. Any other shape is a broken server contract and
/// returns `None` so callers do not mistake it for “no tests”. Malformed child
/// nodes are diagnosed without discarding valid peers.
pub(crate) fn normalize_java_test_items(result: &Value) -> Option<JavaTestItems> {
    let candidates = match result {
        Value::Null => &Vec::new(),
        Value::Array(candidates) => candidates,
        _ => return None,
    };
    let mut diagnostics = Vec::new();
    let items = candidates
        .iter()
        .filter_map(|candidate| normalize_item(candidate, &mut diagnostics))
        .collect();
    Some(JavaTestItems {
        schema_version: JAVA_TEST_ITEMS_SCHEMA_VERSION,
        items,
        diagnostics,
    })
}

fn normalize_item(
    candidate: &Value,
    diagnostics: &mut Vec<JavaTestItemDiagnostic>,
) -> Option<JavaTestItem> {
    let Some(object) = candidate.as_object() else {
        diagnostics.push(JavaTestItemDiagnostic {
            code: "invalidItem",
            detail: Some("item is not an object".to_string()),
        });
        return None;
    };
    let required_string = |name: &str| {
        object
            .get(name)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    };
    let id = required_string("id");
    let label = required_string("label");
    let full_name = required_string("fullName");
    let project_name = required_string("projectName");
    let test_kind = integer_value(object.get("testKind"));
    let test_level = integer_value(object.get("testLevel"));
    let (
        Some(id),
        Some(label),
        Some(full_name),
        Some(project_name),
        Some(test_kind),
        Some(test_level),
    ) = (id, label, full_name, project_name, test_kind, test_level)
    else {
        diagnostics.push(JavaTestItemDiagnostic {
            code: "missingRequiredField",
            detail: object
                .get("label")
                .and_then(Value::as_str)
                .map(str::to_string),
        });
        return None;
    };
    let children = object
        .get("children")
        .and_then(Value::as_array)
        .map(|children| {
            children
                .iter()
                .filter_map(|child| normalize_item(child, diagnostics))
                .collect()
        })
        .unwrap_or_default();
    Some(JavaTestItem {
        id,
        label,
        full_name,
        project_name,
        test_kind,
        test_level,
        jdt_handler: optional_string(object.get("jdtHandler")),
        sort_text: optional_string(object.get("sortText")),
        range: object.get("range").and_then(normalize_range),
        children,
    })
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn integer_value(value: Option<&Value>) -> Option<i64> {
    value.and_then(|value| {
        value
            .as_i64()
            .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
    })
}

fn normalize_range(value: &Value) -> Option<JavaTestRange> {
    let start = value.get("start")?;
    let end = value.get("end")?;
    Some(JavaTestRange {
        start_line: integer_value(start.get("line"))?,
        start_utf16_column: integer_value(start.get("character"))?,
        end_line: integer_value(end.get("line"))?,
        end_utf16_column: integer_value(end.get("character"))?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_passes_the_document_uri_to_java_test() {
        assert_eq!(
            java_test_items_command("file:///work/src/Composed.java"),
            json!({
                "command": "vscode.java.test.findTestTypesAndMethods",
                "arguments": ["file:///work/src/Composed.java"]
            })
        );
    }

    #[test]
    fn normalizes_classes_methods_and_utf16_ranges_without_semantic_guessing() {
        let result = json!([{
            "id": "class-id",
            "label": "OddlyNamedSpec",
            "fullName": "demo.OddlyNamedSpec",
            "projectName": "app",
            "testKind": 0,
            "testLevel": "5",
            "jdtHandler": "=app/src<demo{OddlyNamedSpec.java[OddlyNamedSpec",
            "sortText": "001",
            "range": {
                "start": { "line": 3, "character": 4 },
                "end": { "line": 12, "character": 1 }
            },
            "children": [{
                "id": "method-id",
                "label": "customAnnotation()",
                "fullName": "demo.OddlyNamedSpec#customAnnotation()",
                "projectName": "app",
                "testKind": 0,
                "testLevel": 6,
                "range": {
                    "start": { "line": 7, "character": 2 },
                    "end": { "line": 9, "character": 3 }
                }
            }]
        }]);
        let normalized = normalize_java_test_items(&result).expect("array result");
        assert!(normalized.diagnostics.is_empty());
        assert_eq!(normalized.schema_version, 1);
        assert_eq!(normalized.items[0].label, "OddlyNamedSpec");
        assert_eq!(normalized.items[0].test_level, 5);
        assert_eq!(
            normalized.items[0].children[0].full_name,
            "demo.OddlyNamedSpec#customAnnotation()"
        );
        assert_eq!(
            normalized.items[0].children[0].range,
            Some(JavaTestRange {
                start_line: 7,
                start_utf16_column: 2,
                end_line: 9,
                end_utf16_column: 3,
            })
        );
    }

    #[test]
    fn malformed_nodes_are_diagnosed_without_hiding_valid_peers() {
        let result = json!([
            "not-an-item",
            { "id": "missing-fields", "label": "Broken" },
            {
                "id": "valid", "label": "InheritedTests", "fullName": "demo.InheritedTests",
                "projectName": "app", "testKind": 0, "testLevel": 5
            }
        ]);
        let normalized = normalize_java_test_items(&result).expect("array result");
        assert_eq!(normalized.items.len(), 1);
        assert_eq!(normalized.items[0].label, "InheritedTests");
        assert_eq!(normalized.diagnostics.len(), 2);
        assert_eq!(normalized.diagnostics[0].code, "invalidItem");
        assert_eq!(normalized.diagnostics[1].code, "missingRequiredField");
    }

    #[test]
    fn non_array_is_not_misreported_as_an_empty_test_list() {
        assert_eq!(normalize_java_test_items(&json!({ "items": [] })), None);
        assert_eq!(normalize_java_test_items(&json!("items")), None);
    }

    #[test]
    fn null_from_a_file_without_tests_is_an_empty_test_list() {
        // vscode-java-test 0.46.0 returns `fakeRoot.getChildren()`, which is
        // `null` for a file such as `src/main/java/App.java` with no tests.
        assert_eq!(
            normalize_java_test_items(&Value::Null),
            Some(JavaTestItems {
                schema_version: JAVA_TEST_ITEMS_SCHEMA_VERSION,
                items: Vec::new(),
                diagnostics: Vec::new(),
            })
        );
    }
}
