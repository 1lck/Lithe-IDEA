//! Per-test outcomes read from Maven Surefire and Failsafe XML reports.
//!
//! The text reporter parsed by `maven.testResults` names only failing tests,
//! so it cannot tell which of a class's methods passed or were skipped. The
//! XML reports Surefire and Failsafe write for every executed class can: each
//! `<testcase>` records its outcome. Editors use these outcomes for per-method
//! pass/fail markers.
//!
//! Reports outlive the run that wrote them, so a report is read only when it
//! belongs to a requested class and was written at or after the run started.
//! File count, file size, and test-case count are all bounded.
//!
//! Note: the ownership decision is recorded in .agents/notes/implemented/architecture/2026-09-22-editor-run-markers-and-test-outcomes.md

use crate::protocol::{CoreError, ErrorCode, MavenTestCaseResponse};
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Largest single report Core reads; larger files are skipped, not truncated.
const MAX_REPORT_BYTES: u64 = 32 * 1024 * 1024;
/// Most report files read for one run.
const MAX_REPORT_FILES: usize = 512;
/// Most aggregated test cases returned for one run.
const MAX_TEST_CASES: usize = 10_000;
/// Longest failure message kept per test case, in characters.
const MAX_MESSAGE_CHARACTERS: usize = 2_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Which reports belong to the run whose output is being parsed.
pub struct MavenTestReportsRequest {
    /// Workspace-relative directory of the Maven module that ran the tests;
    /// `None` or `.` means the workspace root unless `source_path` is set.
    #[serde(default)]
    pub module: Option<String>,
    /// Workspace-relative test source file, for callers that ran Maven from
    /// the reactor root without selecting a module: the module is then the
    /// nearest directory above the file that contains a `pom.xml`.
    #[serde(default)]
    pub source_path: Option<String>,
    /// Binary names of the test classes the run selected, such as
    /// `demo.OrderServiceTest`. Nested classes (`Outer$Inner`) are included
    /// automatically because Surefire reports them in their own files. When
    /// empty, every report in the module written by the run is read.
    #[serde(default)]
    pub classes: Vec<String>,
    /// Wall-clock start of the run in milliseconds since the Unix epoch.
    /// Reports last modified before this instant belong to an earlier run.
    pub not_before_millis: u64,
}

/// Outcome precedence used when one method has several invocations, such as
/// parameterized or repeated tests: any error or failure marks the method.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Outcome {
    Skipped,
    Passed,
    Failed,
    Error,
}

impl Outcome {
    fn as_str(self) -> &'static str {
        match self {
            Self::Skipped => "skipped",
            Self::Passed => "passed",
            Self::Failed => "failed",
            Self::Error => "error",
        }
    }
}

/// One `<testcase>` as it appears in a report, before aggregation.
struct ReportedCase {
    class_name: String,
    method: String,
    outcome: Outcome,
    message: Option<String>,
}

/// Aggregated outcome for one method across its invocations.
struct AggregatedCase {
    outcome: Outcome,
    message: Option<String>,
    invocations: usize,
}

/// Reads the per-method outcomes of the classes a run selected.
///
/// `module_root` is the canonical module directory and `report_directories`
/// are module-relative directories to search, already resolved from the POM.
/// Missing directories or reports yield no cases for that class, which the
/// platform shows as "no recorded result" rather than as a pass.
pub(crate) fn read_test_cases(
    module_root: &Path,
    report_directories: &[String],
    request: &MavenTestReportsRequest,
) -> Result<Vec<MavenTestCaseResponse>, CoreError> {
    let classes = request
        .classes
        .iter()
        .map(|class_name| class_name.trim())
        .filter(|class_name| !class_name.is_empty())
        .map(|class_name| {
            is_binary_class_name(class_name)
                .then(|| class_name.to_string())
                .ok_or_else(|| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Java test class name")
                        .with_details(class_name.to_string())
                })
        })
        .collect::<Result<Vec<_>, _>>()?;

    let mut report_files = Vec::new();
    for directory in report_directories {
        crate::protocol::cancellation::check()?;
        let directory = module_root.join(directory);
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        let mut names = entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| is_requested_report(name, &classes))
            .collect::<Vec<_>>();
        // Directory order is file-system specific; sorting keeps the bound
        // and the aggregation deterministic.
        names.sort();
        report_files.extend(names.into_iter().map(|name| directory.join(name)));
    }
    report_files.dedup();
    report_files.truncate(MAX_REPORT_FILES);

    let mut aggregated: BTreeMap<(String, String), AggregatedCase> = BTreeMap::new();
    for path in report_files {
        crate::protocol::cancellation::check()?;
        if !is_current_report(&path, request.not_before_millis) {
            continue;
        }
        let Ok(data) = fs::read(&path) else {
            continue;
        };
        // A report Maven is still writing, or one damaged on disk, only loses
        // its own markers; the rest of the run is still reported.
        let Some(cases) = parse_report(&data) else {
            continue;
        };
        for case in cases {
            if !belongs_to_requested_class(&case.class_name, &classes) {
                continue;
            }
            let key = (case.class_name, case.method);
            if !aggregated.contains_key(&key) && aggregated.len() >= MAX_TEST_CASES {
                continue;
            }
            let entry = aggregated.entry(key).or_insert(AggregatedCase {
                outcome: case.outcome,
                message: None,
                invocations: 0,
            });
            entry.invocations += 1;
            if case.outcome >= entry.outcome {
                // The first message of the most severe outcome explains the marker.
                if case.outcome > entry.outcome || entry.message.is_none() {
                    entry.message = case.message.or(entry.message.take());
                }
                entry.outcome = case.outcome;
            }
        }
    }

    Ok(aggregated
        .into_iter()
        .map(|((class_name, method), case)| MavenTestCaseResponse {
            class_name,
            method,
            status: case.outcome.as_str().to_string(),
            message: matches!(case.outcome, Outcome::Failed | Outcome::Error)
                .then_some(case.message)
                .flatten(),
            invocations: case.invocations,
        })
        .collect())
}

/// Accepts only Java binary names, which also keeps them from forming paths.
fn is_binary_class_name(value: &str) -> bool {
    value.split('.').all(|segment| {
        let mut characters = segment.chars();
        characters
            .next()
            .is_some_and(|first| first.is_alphabetic() || first == '_' || first == '$')
            && characters.all(|character| {
                character.is_alphanumeric() || character == '_' || character == '$'
            })
    })
}

fn is_requested_report(file_name: &str, classes: &[String]) -> bool {
    let Some(class_name) = file_name
        .strip_prefix("TEST-")
        .and_then(|rest| rest.strip_suffix(".xml"))
    else {
        return false;
    };
    belongs_to_requested_class(class_name, classes)
}

fn belongs_to_requested_class(class_name: &str, classes: &[String]) -> bool {
    // No class list means the run's own reports are identified by time alone.
    if classes.is_empty() {
        return true;
    }
    classes.iter().any(|requested| {
        class_name == requested
            || class_name
                .strip_prefix(requested.as_str())
                .is_some_and(|rest| rest.starts_with('$'))
    })
}

fn is_current_report(path: &Path, not_before_millis: u64) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() || metadata.len() > MAX_REPORT_BYTES {
        return false;
    }
    metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .is_some_and(|modified| modified.as_millis() >= u128::from(not_before_millis))
}

/// Parses one report, or returns `None` when it is not well-formed XML.
fn parse_report(data: &[u8]) -> Option<Vec<ReportedCase>> {
    let mut reader = Reader::from_reader(data);
    reader.config_mut().trim_text(true);
    let mut buffer = Vec::new();
    let mut cases = Vec::new();
    let mut suite_name: Option<String> = None;
    // Only direct `<testcase>` children decide an outcome; `<system-out>`
    // and similar elements are ignored.
    let mut current: Option<ReportedCase> = None;
    let mut depth_in_case = 0_usize;
    loop {
        let event = reader.read_event_into(&mut buffer).ok()?;
        match event {
            Event::Start(element) => {
                if current.is_some() {
                    depth_in_case += 1;
                    if depth_in_case == 1 {
                        apply_outcome_element(current.as_mut()?, &element);
                    }
                } else if element.local_name().as_ref() == b"testsuite" {
                    suite_name = attribute(&element, b"name");
                } else if element.local_name().as_ref() == b"testcase" {
                    current = reported_case(&element, suite_name.as_deref());
                    depth_in_case = 0;
                    // A malformed testcase is skipped with its children.
                    if current.is_none() {
                        reader
                            .read_to_end_into(element.name(), &mut Vec::new())
                            .ok()?;
                    }
                }
            }
            Event::Empty(element) => {
                if let Some(case) = current.as_mut() {
                    if depth_in_case == 0 {
                        apply_outcome_element(case, &element);
                    }
                } else if element.local_name().as_ref() == b"testcase" {
                    if let Some(case) = reported_case(&element, suite_name.as_deref()) {
                        cases.push(case);
                    }
                }
            }
            Event::End(element) => {
                if current.is_some() {
                    if depth_in_case == 0 && element.local_name().as_ref() == b"testcase" {
                        cases.push(current.take()?);
                    } else {
                        depth_in_case = depth_in_case.saturating_sub(1);
                    }
                }
            }
            Event::Eof => break,
            _ => {}
        }
        buffer.clear();
    }
    current.is_none().then_some(cases)
}

fn reported_case(element: &BytesStart<'_>, suite_name: Option<&str>) -> Option<ReportedCase> {
    let class_name = attribute(element, b"classname")
        .or_else(|| suite_name.map(str::to_string))
        .filter(|name| !name.is_empty())?;
    let method = method_name(&attribute(element, b"name")?)?;
    Some(ReportedCase {
        class_name,
        method,
        outcome: Outcome::Passed,
        message: None,
    })
}

/// Reduces a reported test name to the Java method it ran.
///
/// Surefire reports JUnit 4 and JUnit 5 methods as `name`, and parameterized
/// or repeated invocations as `name(Type)[1]` or `name[1]`. Names that start
/// with a display name instead of a method (`[1] input`) cannot be attributed
/// to a method and are dropped.
fn method_name(reported: &str) -> Option<String> {
    let end = reported.find(['(', '[']).unwrap_or(reported.len());
    let method = reported[..end].trim();
    let mut characters = method.chars();
    let is_identifier = characters
        .next()
        .is_some_and(|first| first.is_alphabetic() || first == '_' || first == '$')
        && characters
            .all(|character| character.is_alphanumeric() || character == '_' || character == '$');
    is_identifier.then(|| method.to_string())
}

fn apply_outcome_element(case: &mut ReportedCase, element: &BytesStart<'_>) {
    let outcome = match element.local_name().as_ref() {
        b"failure" => Outcome::Failed,
        b"error" => Outcome::Error,
        b"skipped" => Outcome::Skipped,
        // `flakyFailure`/`flakyError` record attempts that a later rerun
        // passed; `rerunFailure`/`rerunError` accompany a final failure
        // element. Neither changes the recorded outcome on its own.
        _ => return,
    };
    // A failure outranks a skip marker in the same testcase.
    if case.outcome == Outcome::Passed || outcome > case.outcome {
        case.outcome = outcome;
        case.message = attribute(element, b"message")
            .map(|message| {
                message
                    .trim()
                    .chars()
                    .take(MAX_MESSAGE_CHARACTERS)
                    .collect::<String>()
            })
            .filter(|message| !message.is_empty());
    }
}

fn attribute(element: &BytesStart<'_>, name: &[u8]) -> Option<String> {
    element
        .attributes()
        .flatten()
        .find(|attribute| attribute.key.local_name().as_ref() == name)
        .and_then(|attribute| attribute.unescape_value().ok())
        .map(|value| value.trim().to_string())
}

/// Report directories to search when the POM configures none.
pub(crate) fn default_report_directories(build_directory: &str) -> Vec<String> {
    vec![
        format!("{build_directory}/surefire-reports"),
        format!("{build_directory}/failsafe-reports"),
    ]
}

/// Resolves the module directory named by a request inside the workspace.
pub(crate) fn module_root(
    workspace_root: &Path,
    request: &MavenTestReportsRequest,
) -> Result<PathBuf, CoreError> {
    let module = request
        .module
        .as_deref()
        .map(str::trim)
        .filter(|module| !module.is_empty() && *module != ".");
    let Some(module) = module else {
        return match request.source_path.as_deref().map(str::trim) {
            Some(source_path) if !source_path.is_empty() => {
                nearest_module(workspace_root, source_path)
            }
            _ => Ok(workspace_root.to_path_buf()),
        };
    };
    let candidate = workspace_root
        .join(module.replace('\\', "/"))
        .canonicalize()
        .map_err(|_| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Maven test module does not exist",
            )
            .with_details(module.to_string())
        })?;
    if !candidate.starts_with(workspace_root) || !candidate.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Maven test module must be inside the workspace",
        )
        .with_details(module.to_string()));
    }
    Ok(candidate)
}

/// The closest directory at or above `source_path`'s parent that holds a
/// `pom.xml`, never leaving the workspace; the workspace root otherwise.
fn nearest_module(workspace_root: &Path, source_path: &str) -> Result<PathBuf, CoreError> {
    let source = workspace_root
        .join(source_path.replace('\\', "/"))
        .canonicalize()
        .map_err(|_| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Maven test source does not exist",
            )
            .with_details(source_path.to_string())
        })?;
    if !source.starts_with(workspace_root) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Maven test source must be inside the workspace",
        )
        .with_details(source_path.to_string()));
    }
    let mut directory = source.parent();
    while let Some(candidate) = directory.filter(|candidate| candidate.starts_with(workspace_root))
    {
        if candidate.join("pom.xml").is_file() {
            return Ok(candidate.to_path_buf());
        }
        directory = candidate.parent();
    }
    Ok(workspace_root.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cases(xml: &str) -> Vec<(String, String, Outcome, Option<String>)> {
        parse_report(xml.as_bytes())
            .expect("well-formed report")
            .into_iter()
            .map(|case| (case.class_name, case.method, case.outcome, case.message))
            .collect()
    }

    #[test]
    fn reads_every_outcome_surefire_records() {
        let parsed = cases(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="demo.OrderTest" tests="4" failures="1" errors="1" skipped="1">
  <properties><property name="java.version" value="25"/></properties>
  <testcase name="creates" classname="demo.OrderTest" time="0.01"/>
  <testcase name="refunds" classname="demo.OrderTest" time="0.02">
    <failure message="expected: &lt;4&gt; but was: &lt;5&gt;" type="org.opentest4j.AssertionFailedError">stack</failure>
    <system-out>log</system-out>
  </testcase>
  <testcase name="cancels" classname="demo.OrderTest" time="0">
    <error message="boom" type="java.lang.IllegalStateException"/>
  </testcase>
  <testcase name="later" classname="demo.OrderTest" time="0"><skipped/></testcase>
</testsuite>"#,
        );
        assert_eq!(
            parsed,
            vec![
                (
                    "demo.OrderTest".into(),
                    "creates".into(),
                    Outcome::Passed,
                    None
                ),
                (
                    "demo.OrderTest".into(),
                    "refunds".into(),
                    Outcome::Failed,
                    Some("expected: <4> but was: <5>".into())
                ),
                (
                    "demo.OrderTest".into(),
                    "cancels".into(),
                    Outcome::Error,
                    Some("boom".into())
                ),
                (
                    "demo.OrderTest".into(),
                    "later".into(),
                    Outcome::Skipped,
                    None
                ),
            ]
        );
    }

    // Surefire's rerun feature keeps earlier attempts as child elements; a
    // test that eventually passed must not be marked as failed.
    #[test]
    fn flaky_attempts_that_later_passed_stay_passed() {
        let parsed = cases(
            r#"<testsuite name="demo.RetryTest">
  <testcase name="eventually" classname="demo.RetryTest">
    <flakyFailure message="first try" type="AssertionError"><stackTrace>x</stackTrace></flakyFailure>
  </testcase>
</testsuite>"#,
        );
        assert_eq!(parsed[0].2, Outcome::Passed);
    }

    #[test]
    fn invocation_names_reduce_to_their_method() {
        assert_eq!(
            method_name("parameterized(String)[2]").as_deref(),
            Some("parameterized")
        );
        assert_eq!(method_name("repeated[3]").as_deref(), Some("repeated"));
        assert_eq!(method_name("plain").as_deref(), Some("plain"));
        assert_eq!(method_name("[1] display name"), None);
        assert_eq!(method_name(""), None);
    }

    #[test]
    fn class_names_that_could_form_paths_are_rejected() {
        assert!(is_binary_class_name("demo.Outer$Inner"));
        assert!(!is_binary_class_name("../demo.OrderTest"));
        assert!(!is_binary_class_name("demo/OrderTest"));
        assert!(!is_binary_class_name("demo..OrderTest"));
    }

    #[test]
    fn nested_class_reports_belong_to_their_outer_class_only() {
        let classes = vec!["demo.OrderTest".to_string()];
        assert!(is_requested_report("TEST-demo.OrderTest.xml", &classes));
        assert!(is_requested_report(
            "TEST-demo.OrderTest$Refunds.xml",
            &classes
        ));
        assert!(!is_requested_report(
            "TEST-demo.OrderTestHelper.xml",
            &classes
        ));
        assert!(!is_requested_report("demo.OrderTest.txt", &classes));
    }

    #[test]
    fn truncated_report_is_not_trusted() {
        assert!(parse_report(
            br#"<testsuite name="demo.A"><testcase name="a" classname="demo.A">"#
        )
        .is_none());
    }
}
