//! Decoding of build output into the unified shapes: the model, test
//! results, file diagnostics, and dependency trees, plus the fingerprint of
//! the files a model depends on.
//!
//! Each decode point accepts a public format through the plugin's mapping
//! and a canonical `lithe*` format a plugin's own script can print, so a
//! tool whose output fits no mapping still needs no host code.

use super::decode::{self, join_relative, Format, Workspace};
use super::integrations;
use super::manifest::{
    BuildSystemDeclaration, DependenciesSource, DependencyDecoder, DependencyRule,
    DiagnosticsDeclaration, DocumentDecoder, LinePattern, ModelDecoder, ModelSource, OutputChannel,
    Severity, TestResultsSource,
};
use super::model::{self, BuildModel, ModelBuilder};
use super::options;
use super::plans::{self, invalid_selection, unavailable};
use super::select::{self, Node};
use crate::plugins::declarative::Validation;
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const MAX_TEST_CASES: usize = 10_000;
const MAX_DIAGNOSTICS: usize = 10_000;
const MAX_DEPENDENCIES: usize = 10_000;
const MAX_DEPENDENCY_DEPTH: usize = 64;
const MAX_MESSAGE: usize = 2_000;
const MAX_SYNC_FILES: usize = 10_000;
/// Version of the canonical `litheTestResults` and `litheDependencies`
/// documents.
const CANONICAL_VERSION: u32 = 1;

impl From<DocumentDecoder> for Format {
    fn from(decoder: DocumentDecoder) -> Self {
        match decoder {
            DocumentDecoder::Toml => Format::Toml,
        }
    }
}

fn model_format(decoder: ModelDecoder) -> Option<Format> {
    match decoder {
        ModelDecoder::JsonStream => Some(Format::JsonStream),
        ModelDecoder::LitheBuildModel => None,
    }
}

fn dependency_format(decoder: DependencyDecoder) -> Option<Format> {
    match decoder {
        DependencyDecoder::JsonStream => Some(Format::JsonStream),
        DependencyDecoder::LitheDependencies => None,
    }
}

fn message_text(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.chars().take(MAX_MESSAGE).collect())
}

/// The text a finished command left: its stdout, or the file it wrote.
fn command_output(
    channel: OutputChannel,
    output: Option<&str>,
    output_file: Option<&str>,
) -> Validation<String> {
    match channel {
        OutputChannel::Stdout => output
            .map(|text| decode::bounded_text(text).map(str::to_string))
            .unwrap_or_else(|| Err(plans::invalid_selection("Pass the command's output."))),
        OutputChannel::OutputFile => {
            let path = plans::output_file(output_file, channel)?.unwrap_or_default();
            decode::read_bounded(Path::new(&path))
        }
    }
}

/// A provider's JSON-RPC result, held to the bound of command output.
fn provider_result(result: Option<&Value>) -> Validation<&Value> {
    let result = result.ok_or_else(|| plans::invalid_selection("Pass the provider's result."))?;
    let size = serde_json::to_vec(result).map_or(usize::MAX, |bytes| bytes.len());
    if size > decode::MAX_OUTPUT_BYTES {
        return Err(decode::invalid_output(
            "The provider's result is too large.",
        ));
    }
    Ok(result)
}

// MARK: Model

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeModelRequest {
    /// Absolute workspace root.
    pub(crate) workspace_root: String,
    /// Instance root, workspace-relative.
    pub(crate) root: String,
    #[serde(default)]
    pub(crate) output: Option<String>,
    #[serde(default)]
    pub(crate) output_file: Option<String>,
    /// The result of `lithe/build/model`, for a provider model.
    #[serde(default)]
    pub(crate) result: Option<Value>,
    /// Stored option values, for the run entries.
    #[serde(default)]
    pub(crate) options: BTreeMap<String, Value>,
}

/// Reads the model of one instance from wherever the declaration says.
pub(crate) fn read_model(
    build_system: &BuildSystemDeclaration,
    workspace: &Workspace,
    root: &str,
    output: Option<&str>,
    output_file: Option<&str>,
    result: Option<&Value>,
) -> Validation<BuildModel> {
    let mut builder = ModelBuilder::new(build_system, workspace, root);
    match &build_system.model {
        None => return Err(unavailable(build_system, "a model")),
        Some(ModelSource::Static { file, decoder, map }) => {
            let unreadable =
                || decode::invalid_output(format!("The model file {file} cannot be read."));
            let path = workspace
                .read_path(&join_relative(root, file))
                .ok_or_else(unreadable)?;
            let text = decode::read_bounded(&path).map_err(|_| unreadable())?;
            let document = decode::document(&text, (*decoder).into())?;
            model::map_document(&mut builder, map, &document);
        }
        Some(ModelSource::Command {
            output: channel,
            decoder,
            map,
            ..
        }) => {
            let text = command_output(*channel, output, output_file)?;
            match (model_format(*decoder), map) {
                (Some(format), Some(map)) => {
                    model::map_document(&mut builder, map, &decode::document(&text, format)?);
                }
                _ => model::map_canonical(&mut builder, decode::document(&text, Format::Json)?)?,
            }
        }
        Some(ModelSource::HostIntegration) => {
            integrations::model(build_system, workspace, root, &mut builder)?;
        }
        Some(ModelSource::Provider) => {
            model::map_canonical(&mut builder, provider_result(result)?.clone())?;
        }
    }
    Ok(builder.finish())
}

/// The first marker present at the instance root, for run entries' source.
pub(crate) fn source_marker(
    build_system: &BuildSystemDeclaration,
    workspace: &Workspace,
    root: &str,
) -> Option<String> {
    build_system
        .detection
        .markers
        .iter()
        .map(|marker| join_relative(root, marker))
        .find(|path| workspace.read_path(path).is_some_and(|path| path.is_file()))
}

/// The model with the run entries derived from it.
pub(crate) fn model_value(
    build_system: &BuildSystemDeclaration,
    model: &BuildModel,
    root: &str,
    options: &BTreeMap<String, Value>,
    source: Option<&str>,
) -> Validation<Value> {
    let run = plans::run_entries(build_system, model, root, options, source)?;
    let mut value =
        serde_json::to_value(model).map_err(|error| decode::invalid_output(error.to_string()))?;
    value["run"] = json!(run);
    Ok(value)
}

/// `build.decodeModel`.
pub(crate) fn decode_model(
    build_system: &BuildSystemDeclaration,
    request: &DecodeModelRequest,
) -> Validation<Value> {
    let workspace = Workspace::new(&request.workspace_root)?;
    let root = decode::request_path(&request.root, "root")?;
    let model = read_model(
        build_system,
        &workspace,
        &root,
        request.output.as_deref(),
        request.output_file.as_deref(),
        request.result.as_ref(),
    )?;
    let source = source_marker(build_system, &workspace, &root);
    model_value(
        build_system,
        &model,
        &root,
        &request.options,
        source.as_deref(),
    )
}

// MARK: Test results

/// Outcome of one test, ordered by severity so the worst invocation wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TestStatus {
    Skipped,
    Passed,
    Failed,
    Error,
}

/// One test case in the canonical shape.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TestCaseResult {
    pub(crate) suite: String,
    pub(crate) case: String,
    pub(crate) status: TestStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) duration_millis: Option<u64>,
    /// Workspace-relative source file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) line: Option<usize>,
    /// Number of invocations aggregated into this case.
    #[serde(default = "one")]
    pub(crate) invocations: usize,
}

fn one() -> usize {
    1
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalTestResults {
    format: String,
    version: u32,
    #[serde(default)]
    tests: Vec<TestCaseResult>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeTestResultsRequest {
    pub(crate) workspace_root: String,
    pub(crate) root: String,
    /// Workspace-relative directory of the project that ran; the whole
    /// instance when absent.
    #[serde(default)]
    pub(crate) project: Option<String>,
    /// Workspace-relative project directories from the current model. A run
    /// without `project` covers the root and every one of them, because
    /// report globs are relative to the project that wrote them.
    #[serde(default)]
    pub(crate) projects: Vec<String>,
    /// The run's combined output.
    #[serde(default)]
    pub(crate) output: String,
    /// The run's start; earlier report files are ignored.
    #[serde(default)]
    pub(crate) not_before_millis: Option<u64>,
    /// The suite the run selected, if any.
    #[serde(default)]
    pub(crate) suite: Option<String>,
}

/// Aggregated results and their summary.
pub(crate) struct TestResults {
    pub(crate) cases: Vec<TestCaseResult>,
    /// Counts reported by the tool when it prints its own summary.
    pub(crate) summary: Option<TestSummary>,
}

#[derive(Debug, Clone, Copy, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TestSummary {
    pub(crate) total: usize,
    pub(crate) passed: usize,
    pub(crate) failed: usize,
    pub(crate) errors: usize,
    pub(crate) skipped: usize,
}

/// Merges invocations of the same case, keeping the most severe outcome and
/// its first message.
pub(crate) fn aggregate(cases: Vec<TestCaseResult>) -> Vec<TestCaseResult> {
    let mut merged: BTreeMap<(String, String), TestCaseResult> = BTreeMap::new();
    for case in cases {
        let key = (case.suite.clone(), case.case.clone());
        if !merged.contains_key(&key) && merged.len() >= MAX_TEST_CASES {
            continue;
        }
        match merged.get_mut(&key) {
            None => {
                merged.insert(key, case);
            }
            Some(existing) => {
                existing.invocations += case.invocations.max(1);
                if case.status > existing.status {
                    existing.status = case.status;
                    existing.message = case.message.or(existing.message.take());
                } else if case.status == existing.status && existing.message.is_none() {
                    existing.message = case.message;
                }
                existing.path = existing.path.take().or(case.path);
                existing.line = existing.line.or(case.line);
            }
        }
    }
    merged.into_values().collect()
}

fn summary(cases: &[TestCaseResult]) -> TestSummary {
    let mut summary = TestSummary {
        total: cases.len(),
        ..TestSummary::default()
    };
    for case in cases {
        match case.status {
            TestStatus::Passed => summary.passed += 1,
            TestStatus::Failed => summary.failed += 1,
            TestStatus::Error => summary.errors += 1,
            TestStatus::Skipped => summary.skipped += 1,
        }
    }
    summary
}

/// `build.decodeTestResults`.
pub(crate) fn decode_test_results(
    build_system: &BuildSystemDeclaration,
    request: &DecodeTestResultsRequest,
) -> Validation<Value> {
    let source = build_system
        .test
        .as_ref()
        .and_then(|test| test.results.as_ref())
        .ok_or_else(|| unavailable(build_system, "test results"))?;
    let workspace = Workspace::new(&request.workspace_root)?;
    let root = decode::request_path(&request.root, "root")?;
    let directory = match &request.project {
        Some(project) => decode::request_path(project, "project")?,
        None => root.clone(),
    };
    decode::bounded_text(&request.output)?;
    let results = match source {
        TestResultsSource::JunitXml { reports } => TestResults {
            cases: report_cases(
                &workspace,
                &report_directories(&root, &directory, request)?,
                reports,
                request.not_before_millis,
                |text, base| junit_cases(text, &workspace, base),
            ),
            summary: None,
        },
        TestResultsSource::LitheTestResults { reports } => TestResults {
            cases: report_cases(
                &workspace,
                &report_directories(&root, &directory, request)?,
                reports,
                request.not_before_millis,
                |text, base| canonical_cases(text, &workspace, base),
            ),
            summary: None,
        },
        TestResultsSource::HostIntegration => {
            integrations::test_results(build_system, &workspace, &root, &directory, request)?
        }
    };
    let cases = aggregate(results.cases);
    let summary = results.summary.unwrap_or_else(|| summary(&cases));
    Ok(json!({
        "tests": cases,
        "summary": summary,
        "success": summary.failed == 0 && summary.errors == 0,
    }))
}

/// Directories whose reports belong to the run: the selected project, or the
/// root and every model project inside it, deepest first so a file two globs
/// reach is read relative to its own project.
fn report_directories(
    root: &str,
    directory: &str,
    request: &DecodeTestResultsRequest,
) -> Validation<Vec<String>> {
    let mut directories = BTreeSet::from([directory.to_string()]);
    if request.project.is_none() {
        for project in request.projects.iter().take(model::MAX_PROJECTS) {
            let project = decode::request_path(project, "project")?;
            if decode::contains(root, &project) {
                directories.insert(project);
            }
        }
    }
    let mut directories: Vec<String> = directories.into_iter().collect();
    directories.sort_by_key(|directory| std::cmp::Reverse(model::depth(directory)));
    Ok(directories)
}

fn report_cases(
    workspace: &Workspace,
    directories: &[String],
    reports: &[String],
    not_before_millis: Option<u64>,
    parse: impl Fn(&str, &str) -> Option<Vec<TestCaseResult>>,
) -> Vec<TestCaseResult> {
    let mut seen = BTreeSet::new();
    let mut files = Vec::new();
    for directory in directories {
        let Some(base) = workspace.read_path(directory) else {
            continue;
        };
        for pattern in reports {
            for file in decode::glob(&base, pattern, not_before_millis) {
                if seen.insert(file.clone()) {
                    files.push((file, directory.as_str()));
                }
            }
        }
    }
    // Deterministic regardless of which directory found a file first.
    files.sort();
    let mut cases = Vec::new();
    for (file, directory) in files {
        // A report still being written or damaged loses only its own cases.
        let Ok(text) = decode::read_bounded(&file) else {
            continue;
        };
        if let Some(parsed) = parse(&text, directory) {
            cases.extend(parsed);
        }
        if cases.len() >= MAX_TEST_CASES * 4 {
            break;
        }
    }
    cases
}

fn canonical_cases(text: &str, workspace: &Workspace, base: &str) -> Option<Vec<TestCaseResult>> {
    let document: CanonicalTestResults = serde_json::from_str(text).ok()?;
    if document.format != "litheTestResults" || document.version != CANONICAL_VERSION {
        return None;
    }
    Some(
        document
            .tests
            .into_iter()
            .filter(|case| !case.suite.trim().is_empty() || !case.case.trim().is_empty())
            .map(|mut case| {
                case.message = case.message.as_deref().and_then(message_text);
                case.path = case
                    .path
                    .as_deref()
                    .and_then(|path| workspace.relativize_reported(path, base));
                case.invocations = case.invocations.max(1);
                case
            })
            .collect(),
    )
}

fn attribute(element: &BytesStart<'_>, name: &[u8]) -> Option<String> {
    element
        .attributes()
        .flatten()
        .find(|attribute| attribute.key.local_name().as_ref() == name)
        .and_then(|attribute| attribute.unescape_value().ok())
        .map(|value| value.into_owned())
}

/// Parses one JUnit XML report: `<testsuite>`/`<testcase>` with
/// `<failure>`, `<error>`, and `<skipped>` children, as written by Surefire,
/// Gradle, pytest, Jest, Go, and most other runners.
fn junit_cases(text: &str, workspace: &Workspace, base: &str) -> Option<Vec<TestCaseResult>> {
    let mut reader = Reader::from_str(text);
    reader.config_mut().trim_text(true);
    let mut suites: Vec<String> = Vec::new();
    let mut cases = Vec::new();
    let mut current: Option<TestCaseResult> = None;
    let mut depth_in_case = 0usize;
    let mut capture_message = false;
    loop {
        let event = reader.read_event().ok()?;
        match event {
            Event::Start(element) => {
                let name = element.local_name();
                if current.is_some() {
                    depth_in_case += 1;
                    if depth_in_case == 1 {
                        capture_message = apply_outcome(current.as_mut()?, &element);
                    }
                } else if name.as_ref() == b"testsuite" {
                    suites.push(attribute(&element, b"name").unwrap_or_default());
                } else if name.as_ref() == b"testcase" {
                    current = Some(junit_case(&element, &suites, workspace, base));
                    depth_in_case = 0;
                }
            }
            Event::Empty(element) => {
                let name = element.local_name();
                if let Some(case) = current.as_mut() {
                    if depth_in_case == 0 {
                        apply_outcome(case, &element);
                    }
                } else if name.as_ref() == b"testcase" {
                    cases.push(junit_case(&element, &suites, workspace, base));
                }
            }
            Event::Text(text) => {
                if capture_message {
                    if let Some(case) = current.as_mut().filter(|case| case.message.is_none()) {
                        case.message = text.unescape().ok().as_deref().and_then(message_text);
                    }
                }
            }
            Event::CData(text) => {
                if capture_message {
                    if let Some(case) = current.as_mut().filter(|case| case.message.is_none()) {
                        case.message = message_text(&String::from_utf8_lossy(&text));
                    }
                }
            }
            Event::End(element) => {
                let name = element.local_name();
                if current.is_some() {
                    if depth_in_case == 0 && name.as_ref() == b"testcase" {
                        cases.push(current.take()?);
                    } else {
                        depth_in_case = depth_in_case.saturating_sub(1);
                        capture_message = false;
                    }
                } else if name.as_ref() == b"testsuite" {
                    suites.pop();
                }
            }
            Event::Eof => break,
            _ => {}
        }
        if cases.len() >= MAX_TEST_CASES {
            break;
        }
    }
    Some(cases)
}

fn junit_case(
    element: &BytesStart<'_>,
    suites: &[String],
    workspace: &Workspace,
    base: &str,
) -> TestCaseResult {
    let suite = attribute(element, b"classname")
        .filter(|name| !name.is_empty())
        .or_else(|| suites.iter().rev().find(|name| !name.is_empty()).cloned())
        .unwrap_or_default();
    let duration_millis = attribute(element, b"time")
        .and_then(|time| time.trim().replace(',', "").parse::<f64>().ok())
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .map(|seconds| (seconds * 1000.0).round() as u64);
    TestCaseResult {
        suite,
        case: attribute(element, b"name").unwrap_or_default(),
        status: TestStatus::Passed,
        message: None,
        duration_millis,
        path: attribute(element, b"file")
            .and_then(|file| workspace.relativize_reported(&file, base)),
        line: attribute(element, b"line").and_then(|line| line.parse().ok()),
        invocations: 1,
    }
}

/// Applies a `<failure>`, `<error>`, or `<skipped>` child. Returns whether
/// its text may carry the message.
fn apply_outcome(case: &mut TestCaseResult, element: &BytesStart<'_>) -> bool {
    let status = match element.local_name().as_ref() {
        b"failure" => TestStatus::Failed,
        b"error" => TestStatus::Error,
        b"skipped" => TestStatus::Skipped,
        _ => return false,
    };
    // A skipped marker never hides a failure in the same case.
    if case.status == TestStatus::Passed || status > case.status {
        case.status = status;
        case.message = attribute(element, b"message")
            .as_deref()
            .and_then(message_text);
    }
    status != TestStatus::Skipped
}

// MARK: Diagnostics

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeDiagnosticsRequest {
    pub(crate) workspace_root: String,
    pub(crate) root: String,
    pub(crate) output: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Diagnostic {
    pub(crate) path: String,
    pub(crate) line: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) column: Option<usize>,
    pub(crate) severity: &'static str,
    pub(crate) message: String,
}

/// A canonical diagnostic line: `{"lithe":"diagnostic", ...}`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalDiagnostic {
    lithe: String,
    path: String,
    line: usize,
    #[serde(default)]
    column: Option<usize>,
    #[serde(default)]
    severity: Option<Severity>,
    message: String,
}

fn severity_named(name: &str) -> Option<Severity> {
    match name.trim().to_ascii_lowercase().as_str() {
        "error" | "fatal" | "err" | "e" => Some(Severity::Error),
        "warning" | "warn" | "w" => Some(Severity::Warning),
        "information" | "info" | "note" | "i" => Some(Severity::Information),
        "hint" | "help" => Some(Severity::Hint),
        _ => None,
    }
}

fn strip_ansi(line: &str, ansi: &Regex) -> String {
    ansi.replace_all(line, "").into_owned()
}

fn line_diagnostic(
    pattern: &LinePattern,
    regex: &Regex,
    line: &str,
    workspace: &Workspace,
    root: &str,
) -> Option<Diagnostic> {
    let captures = regex.captures(line)?;
    let group = |index: usize| captures.get(index).map(|value| value.as_str());
    let path = workspace.relativize_reported(group(pattern.file)?, root)?;
    let line_number = group(pattern.line)?
        .trim()
        .parse()
        .ok()
        .filter(|line| *line > 0)?;
    let column = pattern
        .column
        .and_then(group)
        .and_then(|column| column.trim().parse().ok())
        .filter(|column| *column > 0);
    let message = message_text(group(pattern.message)?)?;
    let severity = pattern
        .severity
        .and_then(group)
        .and_then(|raw| {
            pattern
                .severities
                .get(raw)
                .copied()
                .or_else(|| severity_named(raw))
        })
        .or(pattern.default_severity)
        .unwrap_or(Severity::Error);
    Some(Diagnostic {
        path,
        line: line_number,
        column,
        severity: severity.as_str(),
        message,
    })
}

/// `build.decodeDiagnostics`: file diagnostics in output order, without
/// duplicates.
pub(crate) fn decode_diagnostics(
    build_system: &BuildSystemDeclaration,
    request: &DecodeDiagnosticsRequest,
) -> Validation<Value> {
    let declaration = build_system
        .diagnostics
        .as_ref()
        .ok_or_else(|| unavailable(build_system, "diagnostics"))?;
    let workspace = Workspace::new(&request.workspace_root)?;
    let root = decode::request_path(&request.root, "root")?;
    let output = decode::bounded_text(&request.output)?;
    let ansi =
        Regex::new(r"\x1b\[[0-?]*[ -/]*[@-~]").expect("static ANSI escape expression is valid");
    let patterns: Vec<(&LinePattern, Regex)> = match declaration {
        DiagnosticsDeclaration::LineMatcher { patterns } => patterns
            .iter()
            .filter_map(|pattern| Some((pattern, Regex::new(&pattern.regex).ok()?)))
            .collect(),
        DiagnosticsDeclaration::LitheDiagnostics => Vec::new(),
    };
    let canonical = matches!(declaration, DiagnosticsDeclaration::LitheDiagnostics);
    let mut seen = BTreeSet::new();
    let mut diagnostics = Vec::new();
    for raw in output.lines() {
        let line = strip_ansi(raw, &ansi);
        let diagnostic = if canonical {
            canonical_diagnostic(&line, &workspace, &root)
        } else {
            patterns.iter().find_map(|(pattern, regex)| {
                line_diagnostic(pattern, regex, &line, &workspace, &root)
            })
        };
        if let Some(diagnostic) = diagnostic {
            if seen.insert(diagnostic.clone()) {
                diagnostics.push(diagnostic);
            }
            if diagnostics.len() >= MAX_DIAGNOSTICS {
                break;
            }
        }
    }
    Ok(json!(diagnostics))
}

fn canonical_diagnostic(line: &str, workspace: &Workspace, root: &str) -> Option<Diagnostic> {
    let line = line.trim();
    if !line.starts_with('{') {
        return None;
    }
    let diagnostic: CanonicalDiagnostic = serde_json::from_str(line).ok()?;
    if diagnostic.lithe != "diagnostic" || diagnostic.line == 0 {
        return None;
    }
    Some(Diagnostic {
        path: workspace.relativize_reported(&diagnostic.path, root)?,
        line: diagnostic.line,
        column: diagnostic.column.filter(|column| *column > 0),
        severity: diagnostic.severity.unwrap_or(Severity::Error).as_str(),
        message: message_text(&diagnostic.message)?,
    })
}

// MARK: Dependencies

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DecodeDependenciesRequest {
    pub(crate) workspace_root: String,
    pub(crate) root: String,
    /// Workspace-relative directory of the project the plan selected.
    #[serde(default)]
    pub(crate) project: Option<String>,
    #[serde(default)]
    pub(crate) output: Option<String>,
    #[serde(default)]
    pub(crate) output_file: Option<String>,
    /// The result of `lithe/build/dependencies`, for provider dependencies.
    #[serde(default)]
    pub(crate) result: Option<Value>,
}

/// One dependency node in the canonical shape.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DependencyNode {
    pub(crate) name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) group: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) scope: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) properties: BTreeMap<String, String>,
    #[serde(default)]
    pub(crate) children: Vec<DependencyNode>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalDependencies {
    format: String,
    version: u32,
    #[serde(default)]
    dependencies: Vec<DependencyNode>,
}

/// Bounds a tree in node count and depth, dropping what lies beyond.
fn bound_tree(nodes: Vec<DependencyNode>, depth: usize, budget: &mut usize) -> Vec<DependencyNode> {
    let mut kept = Vec::new();
    for mut node in nodes {
        if *budget == 0 || node.name.trim().is_empty() {
            continue;
        }
        *budget -= 1;
        node.children = if depth + 1 >= MAX_DEPENDENCY_DEPTH {
            Vec::new()
        } else {
            bound_tree(std::mem::take(&mut node.children), depth + 1, budget)
        };
        kept.push(node);
    }
    kept
}

fn map_dependency(
    rule: &DependencyRule,
    document: &Value,
    node: &Node<'_>,
    budget: &mut usize,
) -> Option<DependencyNode> {
    if *budget == 0 {
        return None;
    }
    let name = rule.name.text(document, node)?;
    *budget -= 1;
    let text =
        |spec: &Option<select::FieldSpec>| spec.as_ref().and_then(|spec| spec.text(document, node));
    let properties = rule
        .properties
        .iter()
        .filter_map(|(key, spec)| Some((key.clone(), spec.text(document, node)?)))
        .collect();
    Some(DependencyNode {
        name,
        group: text(&rule.group),
        version: text(&rule.version),
        scope: text(&rule.scope),
        properties,
        children: Vec::new(),
    })
}

/// The nodes of a `litheDependencies` document, bounded.
fn canonical_dependencies(
    document: Result<CanonicalDependencies, serde_json::Error>,
    budget: &mut usize,
) -> Validation<Vec<DependencyNode>> {
    let document = document.map_err(|error| {
        decode::invalid_output(format!(
            "The output is not a litheDependencies document: {error}"
        ))
    })?;
    if document.format != "litheDependencies" || document.version != CANONICAL_VERSION {
        return Err(decode::invalid_output(format!(
            "Expected litheDependencies version {CANONICAL_VERSION}."
        )));
    }
    Ok(bound_tree(document.dependencies, 0, budget))
}

/// `build.decodeDependencies`.
pub(crate) fn decode_dependencies(
    build_system: &BuildSystemDeclaration,
    request: &DecodeDependenciesRequest,
) -> Validation<Value> {
    let source = build_system
        .dependencies
        .as_ref()
        .ok_or_else(|| unavailable(build_system, "dependencies"))?;
    // Validated for parity with the other decoders; dependency output names
    // coordinates, not workspace files.
    Workspace::new(&request.workspace_root)?;
    let root = decode::request_path(&request.root, "root")?;
    let project = match &request.project {
        Some(project) => decode::request_path(project, "project")?,
        None => root.clone(),
    };
    if !decode::contains(&root, &project) {
        return Err(invalid_selection(
            "The project is outside the build-system root.",
        ));
    }
    let mut budget = MAX_DEPENDENCIES;
    let nodes = match source {
        DependenciesSource::Command {
            output,
            decoder,
            map,
            ..
        } => {
            let text = command_output(
                *output,
                request.output.as_deref(),
                request.output_file.as_deref(),
            )?;
            match (dependency_format(*decoder), map) {
                (Some(format), Some(rule)) => {
                    let document = decode::document(&text, format)?;
                    let root_node = Node::root(&document);
                    select::nodes(&rule.each, &document, &root_node)
                        .iter()
                        .filter(|node| select::all_hold(&rule.filter, &document, node))
                        .filter_map(|node| map_dependency(rule, &document, node, &mut budget))
                        .collect()
                }
                _ => canonical_dependencies(serde_json::from_str(&text), &mut budget)?,
            }
        }
        DependenciesSource::Provider { .. } => canonical_dependencies(
            CanonicalDependencies::deserialize(provider_result(request.result.as_ref())?),
            &mut budget,
        )?,
        DependenciesSource::HostIntegration => {
            let nodes = integrations::dependencies(
                build_system,
                &root,
                &project,
                request.output_file.as_deref(),
            )?;
            bound_tree(nodes, 0, &mut budget)
        }
    };
    Ok(json!({
        "project": project,
        "dependencies": nodes,
        "truncated": budget == 0,
    }))
}

// MARK: Sync fingerprint

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SyncFingerprintRequest {
    pub(crate) workspace_root: String,
    pub(crate) root: String,
    /// Workspace-relative project directories from the current model.
    #[serde(default)]
    pub(crate) projects: Vec<String>,
    #[serde(default)]
    pub(crate) options: BTreeMap<String, Value>,
}

/// `build.syncFingerprint`: a digest of the markers, the static model file,
/// the declared watch files of the root and every project, and the options.
/// A changed digest means the model is stale. `watch` lists every path,
/// present or not, so the host also notices a file being created.
pub(crate) fn sync_fingerprint(
    build_system: &BuildSystemDeclaration,
    request: &SyncFingerprintRequest,
) -> Validation<Value> {
    let workspace = Workspace::new(&request.workspace_root)?;
    let root = decode::request_path(&request.root, "root")?;
    let mut directories = BTreeSet::from([root.clone()]);
    for project in request.projects.iter().take(MAX_SYNC_FILES) {
        let project = decode::request_path(project, "project")?;
        if decode::contains(&root, &project) {
            directories.insert(project);
        }
    }
    let mut files = BTreeSet::new();
    for marker in &build_system.detection.markers {
        files.insert(join_relative(&root, marker));
    }
    if let Some(ModelSource::Static { file, .. }) = &build_system.model {
        files.insert(join_relative(&root, file));
    }
    if let Some(sync) = &build_system.sync {
        for directory in &directories {
            for file in &sync.watch {
                files.insert(join_relative(directory, file));
            }
        }
    }
    let files: Vec<String> = files.into_iter().take(MAX_SYNC_FILES).collect();
    let resolved = options::resolve(build_system, &request.options, None);
    let mut hasher = Sha256::new();
    hasher.update(b"lithe.build.sync/1\0");
    hasher.update(options::fingerprint(build_system, &resolved).as_bytes());
    for file in &files {
        hasher.update([0]);
        hasher.update(file.as_bytes());
        hasher.update([0]);
        match workspace
            .read_path(file)
            .and_then(|path| decode::read_bytes_bounded(&path))
        {
            Some(bytes) => hasher.update(Sha256::digest(&bytes)),
            None => hasher.update(b"absent"),
        }
    }
    Ok(json!({
        "fingerprint": format!("{:x}", hasher.finalize()),
        "watch": files,
    }))
}
