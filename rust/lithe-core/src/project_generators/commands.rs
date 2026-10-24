//! The `project.*` commands: JSON in, outcome envelope out.
//!
//! Commands that take a manifest validate it again, as the `build.*`
//! commands do, so a host never has to trust its own cache of a manifest.
//! Malformed payloads fail the call; rejected declarations and inputs come
//! back as `{status: "rejected", error}`.

use super::archive;
use super::form::{self, FormInput};
use super::manifest::{GeneratorSection, ProjectGeneratorDeclaration};
use super::plan;
use crate::plugins::capabilities::HostCapabilities;
use crate::plugins::declarative::{
    decode_payload, outcome, validate_manifest_value, DeclarativePluginManifest, PluginRejection,
    Validation,
};
use crate::protocol::CoreError;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CatalogPayload {
    plugins: Vec<CatalogPlugin>,
    #[serde(default)]
    host_capabilities: Option<HostCapabilities>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CatalogPlugin {
    manifest: Value,
    /// Whether the user has the plugin turned on. Generators of a disabled
    /// plugin are still listed, so the host can offer to enable it.
    enabled: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FormPayload {
    manifest: Value,
    #[serde(rename = "generatorID")]
    generator_id: String,
    form: FormInput,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PlanPayload {
    manifest: Value,
    #[serde(rename = "generatorID")]
    generator_id: String,
    /// Installed package directory the template files are read from.
    package_path: PathBuf,
    form: FormInput,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CheckNamePayload {
    project_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExtractPayload {
    archive_path: PathBuf,
    /// Existing staging directory the archive is extracted into.
    destination: PathBuf,
}

/// `project.generatorCatalog`: every generator of the given plugins, with
/// the plugins that provide each requirement.
pub(crate) fn project_generator_catalog_command(payload: Value) -> Result<Value, CoreError> {
    let payload: CatalogPayload = decode_payload(payload, "project.generatorCatalog")?;
    let mut manifests = Vec::new();
    let mut issues = Vec::new();
    for plugin in payload.plugins {
        let plugin_id = plugin
            .manifest
            .get("id")
            .and_then(Value::as_str)
            .map(str::to_string);
        let validated = validate_manifest_value(plugin.manifest).and_then(|manifest| {
            if let Some(host) = &payload.host_capabilities {
                crate::plugins::capabilities::check_hosted(manifest.requires(), host)?;
            }
            Ok(manifest)
        });
        match validated {
            Ok(manifest) => manifests.push((manifest, plugin.enabled)),
            Err(error) => issues.push(json!({"pluginID": plugin_id, "error": error})),
        }
    }

    let providers = |matches: &dyn Fn(&DeclarativePluginManifest) -> bool| -> Vec<Value> {
        manifests
            .iter()
            .filter(|(manifest, _)| matches(manifest))
            .map(|(manifest, enabled)| {
                json!({
                    "pluginID": manifest.id(),
                    "pluginName": manifest.display_name(),
                    "enabled": enabled,
                })
            })
            .collect()
    };

    let mut entries: Vec<(GeneratorSection, u32, String, Value)> = Vec::new();
    for (manifest, enabled) in &manifests {
        for generator in manifest.project_generators() {
            let requirements: Vec<Value> = generator
                .requirements
                .iter()
                .map(|requirement| {
                    let (key, id, found) =
                        match (&requirement.language_id, &requirement.build_system_id) {
                            (Some(id), _) => (
                                "languageID",
                                id,
                                providers(&|candidate| {
                                    candidate.language_ids().any(|language| language == id)
                                }),
                            ),
                            (_, Some(id)) => (
                                "buildSystemID",
                                id,
                                providers(&|candidate| {
                                    candidate
                                        .build_systems()
                                        .iter()
                                        .any(|system| &system.id == id)
                                }),
                            ),
                            _ => unreachable!("validated requirement names one ID"),
                        };
                    json!({ key: id, "providers": found })
                })
                .collect();
            entries.push((
                generator.section,
                generator.order,
                generator.display_name.to_lowercase(),
                json!({
                    "pluginID": manifest.id(),
                    "pluginName": manifest.display_name(),
                    "pluginEnabled": enabled,
                    "generator": generator,
                    "requirements": requirements,
                    "usesNetwork": generator.steps.iter().any(|step| step.uses_network()),
                }),
            ));
        }
    }
    entries.sort_by(|left, right| {
        let section = |section: GeneratorSection| section != GeneratorSection::Project;
        (section(left.0), left.1, &left.2).cmp(&(section(right.0), right.1, &right.2))
    });
    let generators: Vec<Value> = entries.into_iter().map(|(_, _, _, entry)| entry).collect();
    Ok(outcome(Ok((
        "catalog",
        json!({"generators": generators, "issues": issues}),
    ))))
}

/// `project.generatorForm`: field values, visibility, and problems.
pub(crate) fn project_generator_form_command(payload: Value) -> Result<Value, CoreError> {
    let payload: FormPayload = decode_payload(payload, "project.generatorForm")?;
    Ok(outcome(with_generator(
        payload.manifest,
        &payload.generator_id,
        |generator| Ok(("form", form::evaluate(generator, &payload.form).to_json())),
    )))
}

/// `project.generationPlan`: the steps that create the project.
pub(crate) fn project_generation_plan_command(payload: Value) -> Result<Value, CoreError> {
    let payload: PlanPayload = decode_payload(payload, "project.generationPlan")?;
    Ok(outcome(with_generator(
        payload.manifest,
        &payload.generator_id,
        |generator| {
            plan::plan(generator, &payload.package_path, &payload.form).map(|plan| ("plan", plan))
        },
    )))
}

/// `project.checkName`: whether a name can be a new project's directory.
pub(crate) fn project_check_name_command(payload: Value) -> Result<Value, CoreError> {
    let payload: CheckNamePayload = decode_payload(payload, "project.checkName")?;
    Ok(outcome(Ok((
        "name",
        json!({"problem": form::project_name_problem(&payload.project_name)}),
    ))))
}

/// `project.extractArchive`: extracts a downloaded archive into staging.
pub(crate) fn project_extract_archive_command(payload: Value) -> Result<Value, CoreError> {
    let payload: ExtractPayload = decode_payload(payload, "project.extractArchive")?;
    Ok(outcome(
        archive::extract(&payload.archive_path, &payload.destination)
            .map(|files| ("extracted", json!({"files": files}))),
    ))
}

fn with_generator(
    manifest: Value,
    generator_id: &str,
    run: impl FnOnce(&ProjectGeneratorDeclaration) -> Validation<(&'static str, Value)>,
) -> Validation<(&'static str, Value)> {
    let manifest = validate_manifest_value(manifest)?;
    let generator = manifest
        .project_generators()
        .iter()
        .find(|generator| generator.id == generator_id)
        .ok_or_else(|| {
            PluginRejection::new(
                "plugin.project.unavailable",
                format!("The plugin declares no project generator {generator_id}."),
            )
        })?;
    run(generator)
}
