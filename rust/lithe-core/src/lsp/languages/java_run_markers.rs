//! Projects JDT facts and recorded test outcomes into editor Run markers.
//!
//! Both products show IDEA-style gutter markers: a Run marker beside each
//! launchable `main` method, a Run-all marker beside each test class, and a
//! Run marker beside each test method, the latter two switching to a passed or
//! failed icon once a run recorded an outcome. Which declarations qualify is
//! decided upstream by JDT (`javaMainMethods`) and the Java Test extension
//! (`javaTestItems`); outcomes come from `maven.testResults` reports. This
//! module only combines those answers, so the two platforms cannot drift on
//! placement, labels, or how method outcomes roll up into a class outcome.
//!
//! Note: the design is recorded in .agents/notes/implemented/architecture/2026-09-22-editor-run-markers-and-test-outcomes.md

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Java Test extension level of a test class item.
const TEST_LEVEL_CLASS: i64 = 5;
/// Java Test extension level of a test method item.
const TEST_LEVEL_METHOD: i64 = 6;
/// Upper bound on markers returned for one file.
const MAX_MARKERS: usize = 5_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Upstream answers for one open Java file.
pub struct JavaRunMarkersRequest {
    /// `methods` from the file's `javaMainMethods` answer.
    #[serde(default)]
    pub main_methods: Vec<MainMethodInput>,
    /// `items` from the file's `javaTestItems` answer. Platforms pass an empty
    /// list when they cannot run tests for this file.
    #[serde(default)]
    pub test_items: Vec<TestItemInput>,
    /// Recorded `maven.testResults` `testCases`; entries for other classes
    /// are ignored.
    #[serde(default)]
    pub test_cases: Vec<TestCaseInput>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One `javaMainMethods` entry.
pub struct MainMethodInput {
    pub main_class: String,
    #[serde(default)]
    pub project_name: Option<String>,
    pub range: RangeInput,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One `javaTestItems` node, including its children.
pub struct TestItemInput {
    pub id: String,
    pub label: String,
    pub full_name: String,
    pub test_level: i64,
    #[serde(default)]
    pub range: Option<RangeInput>,
    #[serde(default)]
    pub children: Vec<TestItemInput>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Zero-based UTF-16 range as returned by the upstream operations.
pub struct RangeInput {
    pub start_line: i64,
    /// Java Test ranges run to the end of the declaration body; Java Debug
    /// main-method ranges cover only the method name.
    #[serde(default)]
    pub end_line: Option<i64>,
}

impl RangeInput {
    fn end_line(self) -> i64 {
        self.end_line
            .filter(|end| *end >= self.start_line)
            .unwrap_or(self.start_line)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One `maven.testResults` test case.
pub struct TestCaseInput {
    pub class_name: String,
    pub method: String,
    pub status: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
/// What a marker launches. The declaration order is the order of markers
/// sharing one line.
pub enum JavaRunMarkerKind {
    /// A launchable `main` method.
    Main,
    /// A test class; running it runs every test the class contains.
    TestClass,
    /// One test method.
    TestMethod,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Last recorded outcome shown by a marker.
pub enum JavaRunMarkerStatus {
    /// Not run yet, or no outcome was recorded; shows the plain Run icon.
    None,
    Passed,
    /// A failure or an error.
    Failed,
    /// Every recorded invocation was skipped.
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One gutter marker.
pub struct JavaRunMarker {
    /// Zero-based line of the declaration name.
    pub line: i64,
    /// Last zero-based line of the declaration as JDT reports it: the end of
    /// the body for test classes and methods, the name line for `main`.
    pub end_line: i64,
    pub kind: JavaRunMarkerKind,
    /// Target named in menus, such as `App.main()`, `OrderTest`, or
    /// `OrderTest.creates`; platforms wrap it in their localized verbs.
    pub label: String,
    /// `main` launch target, matching a `javaEntrypoints` entry.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_class: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    /// Fully qualified test class for test markers, as the Java Test
    /// extension names it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_class: Option<String>,
    /// Java method name for test method markers, without parameters.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_method: Option<String>,
    /// Java Test extension item identity, for platforms that launch or debug
    /// through the extension.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_item_id: Option<String>,
    pub status: JavaRunMarkerStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Markers for one file, ordered by line and then [`JavaRunMarkerKind`].
pub struct JavaRunMarkersResponse {
    pub markers: Vec<JavaRunMarker>,
}

/// Builds the markers for one file (`java.runMarkers`).
pub fn java_run_markers(
    request: JavaRunMarkersRequest,
) -> Result<JavaRunMarkersResponse, CoreError> {
    let outcomes = recorded_outcomes(&request.test_cases);
    let mut markers = Vec::new();
    for method in &request.main_methods {
        let main_class = method.main_class.trim();
        if main_class.is_empty() || method.range.start_line < 0 {
            continue;
        }
        markers.push(JavaRunMarker {
            line: method.range.start_line,
            end_line: method.range.end_line(),
            kind: JavaRunMarkerKind::Main,
            label: format!("{}.main()", simple_class_name(main_class)),
            main_class: Some(main_class.to_string()),
            project_name: method
                .project_name
                .as_deref()
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string),
            test_class: None,
            test_method: None,
            test_item_id: None,
            status: JavaRunMarkerStatus::None,
        });
    }
    for item in &request.test_items {
        collect_test_markers(item, None, &outcomes, &mut markers)?;
    }
    if markers.len() > MAX_MARKERS {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many Run markers for one file",
        )
        .with_details(format!("maximumMarkers={MAX_MARKERS}")));
    }
    markers.sort_by(|left, right| {
        (left.line, left.kind, &left.label).cmp(&(right.line, right.kind, &right.label))
    });
    markers.dedup_by(|left, right| {
        left.line == right.line && left.kind == right.kind && left.label == right.label
    });
    Ok(JavaRunMarkersResponse { markers })
}

/// Outcomes keyed by `(class, method)`, with `$` nested-class separators
/// folded to `.` so report binary names match Java Test's source names.
fn recorded_outcomes(cases: &[TestCaseInput]) -> HashMap<(String, String), JavaRunMarkerStatus> {
    let mut outcomes = HashMap::new();
    for case in cases {
        let status = match case.status.as_str() {
            "passed" => JavaRunMarkerStatus::Passed,
            "failed" | "error" => JavaRunMarkerStatus::Failed,
            "skipped" => JavaRunMarkerStatus::Skipped,
            _ => continue,
        };
        outcomes.insert(
            (
                source_class_name(&case.class_name),
                case.method.trim().to_string(),
            ),
            status,
        );
    }
    outcomes
}

fn collect_test_markers(
    item: &TestItemInput,
    owning_class: Option<&str>,
    outcomes: &HashMap<(String, String), JavaRunMarkerStatus>,
    markers: &mut Vec<JavaRunMarker>,
) -> Result<Vec<JavaRunMarkerStatus>, CoreError> {
    crate::protocol::cancellation::check()?;
    match item.test_level {
        TEST_LEVEL_CLASS => {
            let class_name = item.full_name.trim();
            let mut statuses = Vec::new();
            for child in &item.children {
                statuses.extend(collect_test_markers(
                    child,
                    Some(class_name),
                    outcomes,
                    markers,
                )?);
            }
            if let Some(range) = item.range.filter(|range| range.start_line >= 0) {
                markers.push(JavaRunMarker {
                    line: range.start_line,
                    end_line: range.end_line(),
                    kind: JavaRunMarkerKind::TestClass,
                    label: simple_class_name(class_name).to_string(),
                    main_class: None,
                    project_name: None,
                    test_class: Some(class_name.to_string()),
                    test_method: None,
                    test_item_id: Some(item.id.clone()),
                    status: class_status(&statuses),
                });
            }
            Ok(statuses)
        }
        TEST_LEVEL_METHOD => {
            let Some(class_name) = owning_class.or_else(|| declaring_class(&item.full_name)) else {
                return Ok(Vec::new());
            };
            let Some(method) = method_name(item) else {
                return Ok(Vec::new());
            };
            let status = outcomes
                .get(&(source_class_name(class_name), method.clone()))
                .copied()
                .unwrap_or(JavaRunMarkerStatus::None);
            if let Some(range) = item.range.filter(|range| range.start_line >= 0) {
                markers.push(JavaRunMarker {
                    line: range.start_line,
                    end_line: range.end_line(),
                    kind: JavaRunMarkerKind::TestMethod,
                    label: format!("{}.{}", simple_class_name(class_name), method),
                    main_class: None,
                    project_name: None,
                    test_class: Some(class_name.to_string()),
                    test_method: Some(method),
                    test_item_id: Some(item.id.clone()),
                    status,
                });
            }
            Ok(vec![status])
        }
        // Package, project, and workspace levels only group classes.
        _ => {
            let mut statuses = Vec::new();
            for child in &item.children {
                statuses.extend(collect_test_markers(
                    child,
                    owning_class,
                    outcomes,
                    markers,
                )?);
            }
            Ok(statuses)
        }
    }
}

/// A class shows failed when any recorded method failed and passed when at
/// least one passed and none failed; unrun methods do not hide a failure.
fn class_status(statuses: &[JavaRunMarkerStatus]) -> JavaRunMarkerStatus {
    if statuses.contains(&JavaRunMarkerStatus::Failed) {
        JavaRunMarkerStatus::Failed
    } else if statuses.contains(&JavaRunMarkerStatus::Passed) {
        JavaRunMarkerStatus::Passed
    } else if statuses.contains(&JavaRunMarkerStatus::Skipped) {
        JavaRunMarkerStatus::Skipped
    } else {
        JavaRunMarkerStatus::None
    }
}

/// Method name without its parameter list, from `Class#method(Args)` or the label.
fn method_name(item: &TestItemInput) -> Option<String> {
    let semantic = item
        .full_name
        .rsplit_once('#')
        .map(|(_, method)| method)
        .unwrap_or(&item.label);
    let name = semantic.split('(').next().unwrap_or_default().trim();
    (!name.is_empty()).then(|| name.to_string())
}

fn declaring_class(full_name: &str) -> Option<&str> {
    full_name
        .split_once('#')
        .map(|(class_name, _)| class_name.trim())
        .filter(|class_name| !class_name.is_empty())
}

fn source_class_name(class_name: &str) -> String {
    class_name.trim().replace('$', ".")
}

fn simple_class_name(class_name: &str) -> &str {
    let without_module = class_name
        .rsplit_once('/')
        .map_or(class_name, |(_, name)| name);
    without_module
        .rsplit(['.', '$'])
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(without_module)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn markers(request: serde_json::Value) -> Vec<serde_json::Value> {
        let request = serde_json::from_value(request).expect("valid request");
        let response = java_run_markers(request).expect("markers");
        serde_json::to_value(response).expect("encodes")["markers"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    fn range(line: i64) -> serde_json::Value {
        json!({ "startLine": line, "startUtf16Column": 0, "endLine": line, "endUtf16Column": 4 })
    }

    #[test]
    fn main_methods_become_run_markers_named_like_idea() {
        let markers = markers(json!({
            "mainMethods": [
                { "mainClass": "demo.App", "projectName": "app", "range": range(4) },
                { "mainClass": "app/demo.Modular", "range": range(9) }
            ]
        }));
        assert_eq!(
            markers,
            vec![
                json!({ "line": 4, "endLine": 4, "kind": "main", "label": "App.main()", "mainClass": "demo.App", "projectName": "app", "status": "none" }),
                json!({ "line": 9, "endLine": 9, "kind": "main", "label": "Modular.main()", "mainClass": "app/demo.Modular", "status": "none" }),
            ]
        );
    }

    #[test]
    fn test_classes_and_methods_carry_their_recorded_outcomes() {
        let markers = markers(json!({
            "testItems": [{
                "id": "app@demo.OrderTest", "label": "OrderTest", "fullName": "demo.OrderTest",
                "testLevel": 5, "range": range(3),
                "children": [
                    { "id": "m1", "label": "creates()", "fullName": "demo.OrderTest#creates()", "testLevel": 6, "range": range(5), "children": [] },
                    { "id": "m2", "label": "priced(int)", "fullName": "demo.OrderTest#priced(int)", "testLevel": 6, "range": range(8), "children": [] },
                    { "id": "m3", "label": "later()", "fullName": "demo.OrderTest#later()", "testLevel": 6, "range": range(11), "children": [] }
                ]
            }],
            "testCases": [
                { "className": "demo.OrderTest", "method": "creates", "status": "passed" },
                { "className": "demo.OrderTest", "method": "priced", "status": "error" },
                { "className": "demo.OtherTest", "method": "later", "status": "passed" }
            ]
        }));
        let summary = markers
            .iter()
            .map(|marker| {
                (
                    marker["line"].as_i64().unwrap(),
                    marker["kind"].as_str().unwrap().to_string(),
                    marker["label"].as_str().unwrap().to_string(),
                    marker["status"].as_str().unwrap().to_string(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            summary,
            vec![
                (3, "testClass".into(), "OrderTest".into(), "failed".into()),
                (
                    5,
                    "testMethod".into(),
                    "OrderTest.creates".into(),
                    "passed".into()
                ),
                (
                    8,
                    "testMethod".into(),
                    "OrderTest.priced".into(),
                    "failed".into()
                ),
                (
                    11,
                    "testMethod".into(),
                    "OrderTest.later".into(),
                    "none".into()
                ),
            ]
        );
        assert_eq!(markers[2]["testMethod"], json!("priced"));
        assert_eq!(markers[2]["testClass"], json!("demo.OrderTest"));
        assert_eq!(markers[2]["testItemId"], json!("m2"));
    }

    // Java Test nests inner test classes under their outer class and names
    // them by binary name (`Outer$Inner`), as JDT LS 1.61.0 does for
    // `@Nested`; source spelling (`Outer.Inner`) must match reports too.
    #[test]
    fn nested_class_outcomes_match_either_spelling() {
        let markers = markers(json!({
            "testItems": [{
                "id": "outer", "label": "OrderTest", "fullName": "demo.OrderTest", "testLevel": 5, "range": range(2),
                "children": [{
                    "id": "inner", "label": "Refunds", "fullName": "demo.OrderTest$Refunds", "testLevel": 5, "range": range(4),
                    "children": [{ "id": "m", "label": "refunds()", "fullName": "demo.OrderTest$Refunds#refunds()", "testLevel": 6, "range": range(5), "children": [] }]
                }]
            }],
            "testCases": [{ "className": "demo.OrderTest.Refunds", "method": "refunds", "status": "passed" }]
        }));
        assert_eq!(
            markers
                .iter()
                .map(|marker| marker["status"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["passed", "passed", "passed"]
        );
        assert_eq!(markers[1]["label"], json!("Refunds"));
    }

    #[test]
    fn items_without_a_source_range_get_no_marker() {
        let markers = markers(json!({
            "testItems": [{ "id": "c", "label": "InheritedSuite", "fullName": "demo.InheritedSuite", "testLevel": 5, "children": [
                { "id": "m", "label": "inherited()", "fullName": "demo.BaseTests#inherited()", "testLevel": 6, "children": [] }
            ] }]
        }));
        assert!(markers.is_empty());
    }
}
