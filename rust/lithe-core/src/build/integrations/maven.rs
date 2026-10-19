//! The `maven` host integration: reactor models from the POM reader, the
//! dependency-tree goal and its text format, and Surefire/Failsafe results.
//!
//! Everything else about Maven (executables, options, lifecycle tasks,
//! diagnostics) is declared by the official Maven plugin's `plugin.json`.
//! The integration fills the model's `profiles` option values when the
//! plugin declares that option with `choicesFromModel`.

use super::rejected;
use crate::build::decode::{self, join_relative, Workspace};
use crate::build::manifest::ContentRootKind;
use crate::build::model::{
    add_integration_content_root, add_integration_option_value, add_integration_project,
    ModelBuilder,
};
use crate::build::outputs::{
    DecodeTestResultsRequest, DependencyNode, TestCaseResult, TestResults, TestStatus, TestSummary,
};
use crate::build::plans::{invalid_selection, Selection};
use crate::plugins::declarative::Validation;
use crate::project::{
    dependencies as maven_dependencies, dependency_tree_arguments, scan,
    test_results as maven_test_results, validated_output_file, MavenDependenciesRequest,
    MavenScanRequest, MavenTestReportsRequest, MavenTestResultsRequest,
};
use crate::protocol::{
    MavenDependencyResponse, MavenModuleResponse, MavenSourceRootKind, MavenSourceRootResponse,
};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

/// Option whose choices the integration fills from the reactor's profiles.
const PROFILES_OPTION: &str = "profiles";

fn content_root_kind(kind: MavenSourceRootKind) -> ContentRootKind {
    match kind {
        MavenSourceRootKind::MainJava => ContentRootKind::Source,
        MavenSourceRootKind::MainResources => ContentRootKind::Resource,
        MavenSourceRootKind::TestJava => ContentRootKind::TestSource,
        MavenSourceRootKind::TestResources => ContentRootKind::TestResource,
        MavenSourceRootKind::GeneratedMain => ContentRootKind::GeneratedSource,
        MavenSourceRootKind::GeneratedTest => ContentRootKind::GeneratedTestSource,
    }
}

#[allow(clippy::too_many_arguments)]
fn add_project(
    builder: &mut ModelBuilder<'_>,
    path: String,
    artifact_id: &str,
    group_id: Option<&String>,
    version: Option<&String>,
    packaging: &str,
    source_roots: &[MavenSourceRootResponse],
) {
    let mut properties = BTreeMap::from([
        ("artifactId".to_string(), artifact_id.to_string()),
        ("packaging".to_string(), packaging.to_string()),
    ]);
    if let Some(group_id) = group_id {
        properties.insert("groupId".to_string(), group_id.clone());
    }
    if let Some(version) = version {
        properties.insert("version".to_string(), version.clone());
    }
    let Some(index) = add_integration_project(builder, path.clone(), artifact_id, properties)
    else {
        return;
    };
    for source_root in source_roots {
        add_integration_content_root(
            builder,
            index,
            join_relative(&path, &source_root.path),
            content_root_kind(source_root.kind),
        );
    }
}

fn add_modules(builder: &mut ModelBuilder<'_>, root: &str, modules: &[MavenModuleResponse]) {
    for module in modules {
        add_project(
            builder,
            join_relative(root, &module.relative_path),
            &module.artifact_id,
            module.group_id.as_ref(),
            module.version.as_ref(),
            &module.packaging,
            &module.source_roots,
        );
        add_modules(builder, root, &module.modules);
    }
}

/// Reads the reactor at the instance root. The scan is rooted there, so a
/// POM above the instance never takes over its model.
pub(super) fn model(
    workspace: &Workspace,
    root: &str,
    builder: &mut ModelBuilder<'_>,
) -> Validation<()> {
    let reactor = workspace
        .read_path(root)
        .ok_or_else(|| decode::invalid_output("The build-system root is outside the workspace."))?;
    let scanned = scan(MavenScanRequest {
        root: reactor.to_string_lossy().into_owned(),
        paths: vec!["pom.xml".to_string()],
    })
    .map_err(rejected)?
    .ok_or_else(|| decode::invalid_output("The build-system root has no readable pom.xml."))?;
    add_project(
        builder,
        join_relative(root, &scanned.relative_path),
        &scanned.artifact_id,
        scanned.group_id.as_ref(),
        scanned.version.as_ref(),
        &scanned.packaging,
        &scanned.source_roots,
    );
    add_modules(builder, root, &scanned.modules);
    for profile in &scanned.profiles {
        add_integration_option_value(builder, PROFILES_OPTION, &profile.id);
    }
    Ok(())
}

/// Selection flags and the dependency-tree goal: one project per plan,
/// because every project would overwrite the same output file.
pub(super) fn dependency_arguments(
    project: Option<&Selection>,
    output_file: Option<&str>,
) -> Validation<Vec<String>> {
    let output_file = output_file
        .ok_or_else(|| invalid_selection("The Maven dependency tree needs outputFile."))
        .and_then(|path| validated_output_file(path).map_err(rejected))?;
    let mut arguments = Vec::new();
    match project.map(|project| project.relative.as_str()) {
        Some(module) if module != "." => arguments.extend(["-pl".to_string(), module.to_string()]),
        _ => arguments.push("-N".to_string()),
    }
    arguments.extend(dependency_tree_arguments(&output_file));
    Ok(arguments)
}

pub(super) fn dependency_plan_extra() -> Map<String, Value> {
    let mut extra = Map::new();
    extra.insert("output".to_string(), json!("outputFile"));
    extra.insert("decoder".to_string(), json!("hostIntegration"));
    extra.insert("executesProjectCode".to_string(), json!(true));
    extra.insert("mayUseNetwork".to_string(), json!(true));
    extra
}

fn dependency_node(dependency: MavenDependencyResponse) -> DependencyNode {
    let mut properties = BTreeMap::from([
        ("type".to_string(), dependency.r#type),
        (
            "resolution".to_string(),
            serde_json::to_value(&dependency.resolution)
                .ok()
                .and_then(|value| value.as_str().map(str::to_string))
                .unwrap_or_default(),
        ),
    ]);
    for (key, value) in [
        ("classifier", dependency.classifier),
        ("selectedVersion", dependency.selected_version),
        ("premanagedVersion", dependency.premanaged_version),
        ("premanagedScope", dependency.premanaged_scope),
        ("originalScope", dependency.original_scope),
        ("ignoredScope", dependency.ignored_scope),
    ] {
        if let Some(value) = value {
            properties.insert(key.to_string(), value);
        }
    }
    DependencyNode {
        name: dependency.artifact_id,
        group: Some(dependency.group_id),
        version: Some(dependency.version),
        scope: Some(dependency.scope),
        properties,
        children: dependency
            .children
            .into_iter()
            .map(dependency_node)
            .collect(),
    }
}

pub(super) fn dependencies(
    root: &str,
    project: &str,
    output_file: Option<&str>,
) -> Validation<Vec<DependencyNode>> {
    let module_path = decode::relative_to(root, project)
        .ok_or_else(|| invalid_selection("The project is outside the build-system root."))?;
    let output_file = output_file
        .ok_or_else(|| invalid_selection("Pass the outputFile the dependency plan wrote."))?;
    let response = maven_dependencies(MavenDependenciesRequest {
        module_path,
        output_file: output_file.to_string(),
    })
    .map_err(rejected)?;
    Ok(response
        .dependencies
        .into_iter()
        .map(dependency_node)
        .collect())
}

fn status(value: &str) -> TestStatus {
    match value {
        "failed" => TestStatus::Failed,
        "error" => TestStatus::Error,
        "skipped" => TestStatus::Skipped,
        _ => TestStatus::Passed,
    }
}

/// Splits a Surefire failure name (`method(Class)`, `Class.method`, or
/// `Class#method`) into suite and case.
fn split_failure_name(name: &str) -> (String, String) {
    if let Some((method, rest)) = name.split_once('(') {
        return (rest.trim_end_matches(')').to_string(), method.to_string());
    }
    if let Some((class, method)) = name.rsplit_once('#').or_else(|| name.rsplit_once('.')) {
        return (class.to_string(), method.to_string());
    }
    (String::new(), name.to_string())
}

pub(super) fn test_results(
    workspace: &Workspace,
    _root: &str,
    project: &str,
    request: &DecodeTestResultsRequest,
) -> Validation<TestResults> {
    let reports = request
        .not_before_millis
        .map(|not_before_millis| MavenTestReportsRequest {
            module: Some(project.to_string()),
            source_path: None,
            classes: request.suite.iter().cloned().collect(),
            not_before_millis,
        });
    let response = maven_test_results(MavenTestResultsRequest {
        root: workspace.path.to_string_lossy().into_owned(),
        output: request.output.clone(),
        reports,
    })
    .map_err(rejected)?;
    let mut cases: Vec<TestCaseResult> = response
        .test_cases
        .into_iter()
        .map(|case| TestCaseResult {
            suite: case.class_name,
            case: case.method,
            status: status(&case.status),
            message: case.message,
            duration_millis: case.duration_millis,
            path: None,
            line: None,
            invocations: case.invocations.max(1),
        })
        .collect();
    // Failure details carry the source location the reports lack; a run
    // without reports still lists its failures.
    for detail in response.failure_details {
        let (suite, case) = split_failure_name(&detail.name);
        let status = if detail.kind == "error" {
            TestStatus::Error
        } else {
            TestStatus::Failed
        };
        match cases
            .iter_mut()
            .find(|existing| existing.suite == suite && existing.case == case)
        {
            Some(existing) => {
                existing.path = existing.path.take().or(detail.path);
                existing.line = existing.line.or(detail.line);
            }
            None => cases.push(TestCaseResult {
                suite,
                case,
                status,
                message: detail.message,
                duration_millis: None,
                path: detail.path,
                line: detail.line,
                invocations: 1,
            }),
        }
    }
    Ok(TestResults {
        cases,
        summary: Some(TestSummary {
            total: response.tests_run,
            passed: response.passed,
            failed: response.failures,
            errors: response.errors,
            skipped: response.skipped,
        }),
    })
}
