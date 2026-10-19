//! The `build.*` commands: JSON in, outcome envelope out.
//!
//! Every command except `build.detect` takes `{manifest, buildSystemID,
//! request}` and validates the manifest again, as the `plugins.declarative.*`
//! commands do, so a host never has to trust its own cache of a manifest.
//! Malformed payloads fail the call; rejected declarations and requests come
//! back as `{status: "rejected", error}`.

use super::detect::{self, DetectRequest};
use super::invocation::{self, InvocationRequest, VersionCheckRequest};
use super::language_import::{self, LanguageImportRequest};
use super::manifest::BuildSystemDeclaration;
use super::options;
use super::outputs::{
    self, DecodeDependenciesRequest, DecodeDiagnosticsRequest, DecodeModelRequest,
    DecodeTestResultsRequest, SyncFingerprintRequest,
};
use super::plans::{self, OutputPlanRequest, TaskPlanRequest, TestPlanRequest};
use crate::plugins::declarative::{
    decode_payload, outcome, validate_manifest_value, PluginRejection, Validation,
};
use crate::protocol::CoreError;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BuildPayload<T> {
    manifest: Value,
    #[serde(rename = "buildSystemID")]
    build_system_id: String,
    request: T,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ResolveOptionsRequest {
    /// Stored option values by option ID.
    #[serde(default)]
    options: BTreeMap<String, Value>,
    /// The loaded model's `optionValues`; absent before a model exists, so
    /// values only the model can confirm are kept rather than dropped.
    #[serde(default)]
    model_values: Option<BTreeMap<String, Vec<String>>>,
}

fn with_build_system<T: DeserializeOwned>(
    payload: Value,
    command: &str,
    key: &'static str,
    run: impl FnOnce(&BuildSystemDeclaration, &T) -> Validation<Value>,
) -> Result<Value, CoreError> {
    let payload: BuildPayload<T> = decode_payload(payload, command)?;
    Ok(outcome(validate_manifest_value(payload.manifest).and_then(
        |manifest| {
            let build_system = manifest
                .build_systems()
                .iter()
                .find(|build_system| build_system.id == payload.build_system_id)
                .ok_or_else(|| {
                    PluginRejection::new(
                        "plugin.build.unavailable",
                        format!(
                            "The plugin declares no build system {}.",
                            payload.build_system_id
                        ),
                    )
                })?;
            run(build_system, &payload.request).map(|value| (key, value))
        },
    )))
}

/// `build.detect`: build-system instances of a workspace, with the models
/// that need no process.
pub(crate) fn build_detect_command(payload: Value) -> Result<Value, CoreError> {
    let request: DetectRequest = decode_payload(payload, "build.detect")?;
    Ok(outcome(
        detect::detect(request).map(|detection| ("detection", detection)),
    ))
}

/// `build.invocationPlan`: executable candidates and version probes.
pub(crate) fn build_invocation_plan_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.invocationPlan",
        "invocation",
        |build_system, request: &InvocationRequest| {
            invocation::invocation_plan(build_system, request)
        },
    )
}

/// `build.checkToolVersion`: compares probe output with a declared minimum.
pub(crate) fn build_check_tool_version_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.checkToolVersion",
        "version",
        |build_system, request: &VersionCheckRequest| {
            invocation::check_version(build_system, request)
        },
    )
}

/// `build.resolveOptions`: effective option values, choices, and the
/// fingerprint of the configuration.
pub(crate) fn build_resolve_options_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.resolveOptions",
        "options",
        |build_system, request: &ResolveOptionsRequest| {
            let resolved = options::resolve(
                build_system,
                &request.options,
                request.model_values.as_ref(),
            );
            Ok(options::describe(
                build_system,
                &resolved,
                request.model_values.as_ref(),
            ))
        },
    )
}

/// `build.modelPlan`: the command that prints a command-sourced model.
pub(crate) fn build_model_plan_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.modelPlan",
        "plan",
        |build_system, request: &OutputPlanRequest| plans::model_plan(build_system, request),
    )
}

/// `build.taskPlan`: one declared or model task as an argv plan.
pub(crate) fn build_task_plan_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.taskPlan",
        "plan",
        |build_system, request: &TaskPlanRequest| plans::task_plan(build_system, request),
    )
}

/// `build.testPlan`: a test run and where its results will be.
pub(crate) fn build_test_plan_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.testPlan",
        "plan",
        |build_system, request: &TestPlanRequest| plans::test_plan(build_system, request),
    )
}

/// `build.dependencyPlan`: the command that prints a project's dependencies.
pub(crate) fn build_dependency_plan_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.dependencyPlan",
        "plan",
        |build_system, request: &OutputPlanRequest| plans::dependency_plan(build_system, request),
    )
}

/// `build.decodeModel`: the normalized model and its run entries.
pub(crate) fn build_decode_model_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.decodeModel",
        "model",
        |build_system, request: &DecodeModelRequest| outputs::decode_model(build_system, request),
    )
}

/// `build.decodeTestResults`: per-case outcomes and a summary.
pub(crate) fn build_decode_test_results_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.decodeTestResults",
        "results",
        |build_system, request: &DecodeTestResultsRequest| {
            outputs::decode_test_results(build_system, request)
        },
    )
}

/// `build.decodeDiagnostics`: file diagnostics from process output.
pub(crate) fn build_decode_diagnostics_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.decodeDiagnostics",
        "diagnostics",
        |build_system, request: &DecodeDiagnosticsRequest| {
            outputs::decode_diagnostics(build_system, request)
        },
    )
}

/// `build.decodeDependencies`: one project's dependency tree.
pub(crate) fn build_decode_dependencies_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.decodeDependencies",
        "dependencies",
        |build_system, request: &DecodeDependenciesRequest| {
            outputs::decode_dependencies(build_system, request)
        },
    )
}

/// `build.syncFingerprint`: a digest of the files the model depends on.
pub(crate) fn build_sync_fingerprint_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.syncFingerprint",
        "sync",
        |build_system, request: &SyncFingerprintRequest| {
            outputs::sync_fingerprint(build_system, request)
        },
    )
}

/// `build.languageImport`: the Java language server's import settings for
/// an instance, from the user's options; `null` without a declaration.
pub(crate) fn build_language_import_command(payload: Value) -> Result<Value, CoreError> {
    with_build_system(
        payload,
        "build.languageImport",
        "languageImport",
        |build_system, request: &LanguageImportRequest| {
            language_import::language_import(build_system, request)
        },
    )
}
