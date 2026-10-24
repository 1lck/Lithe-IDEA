//! Turning a filled-in form into the steps a host runs.

use super::form::{self, FormInput, FormState};
use super::manifest::{
    variable_is_known, GeneratorStep, ProjectGeneratorDeclaration, FIELD_RUNTIME,
};
use super::template::{self, FieldValue, Values, Variable};
use crate::plugins::declarative::{is_safe_relative_path, PluginRejection, Validation};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// Limits of one generator's template files, so a damaged package cannot
/// make Core read without bound.
const MAX_TEMPLATE_FILES: usize = 1024;
const MAX_TEMPLATE_FILE_BYTES: u64 = 1024 * 1024;
const MAX_TEMPLATE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_TEMPLATE_DEPTH: usize = 32;
/// Template path segments starting with this become dotfiles
/// (`dot-gitignore` → `.gitignore`). Packages keep no hidden files, because
/// package scans skip them.
const DOTFILE_PREFIX: &str = "dot-";

pub(crate) const INVALID_INPUT: &str = "plugin.project.invalidInput";
const TEMPLATE_INVALID: &str = "plugin.project.templateInvalid";
const INVALID_URL: &str = "plugin.project.invalidURL";

/// Builds the plan for `input`, or reports the first problem.
pub(crate) fn plan(
    generator: &ProjectGeneratorDeclaration,
    package_path: &Path,
    input: &FormInput,
) -> Validation<Value> {
    let state = form::evaluate(generator, input);
    reject_invalid_form(&state)?;
    let values = Values {
        project_name: &input.project_name,
        fields: &state.values,
    };
    let known = |variable: &Variable| {
        variable_is_known(variable, |id| {
            generator.fields.iter().find(|field| field.id == id)
        })
    };

    let mut steps = Vec::new();
    let mut file_budget = FileBudget::default();
    for (index, step) in generator.steps.iter().enumerate() {
        if !form::holds(step.when(), &state.values) {
            continue;
        }
        let field = format!("projectGenerators.{}.steps[{index}]", generator.id);
        steps.push(match step {
            GeneratorStep::Files { source, target, .. } => {
                let target = target
                    .as_deref()
                    .map(|target| expand_path(target, &values, &field))
                    .transpose()?;
                let files = template_files(
                    package_path,
                    source,
                    target.as_deref(),
                    &values,
                    &known,
                    &mut file_budget,
                    &field,
                )?;
                json!({"kind": "writeFiles", "files": files})
            }
            GeneratorStep::Command {
                command,
                arguments,
                environment,
                collect,
                may_use_network,
                timeout_seconds,
                ..
            } => {
                let arguments: Vec<String> = arguments
                    .iter()
                    .filter(|argument| form::holds(argument.when(), &state.values))
                    .map(|argument| expand_value(argument.value(), &values))
                    .filter(|argument| !argument.is_empty())
                    .collect();
                let environment: serde_json::Map<String, Value> = environment
                    .iter()
                    .map(|(name, value)| (name.clone(), json!(expand_value(value, &values))))
                    .collect();
                let collect = collect
                    .as_deref()
                    .map(|collect| expand_path(collect, &values, &field))
                    .transpose()?;
                json!({
                    "kind": "command",
                    "command": command,
                    "arguments": arguments,
                    "environment": environment,
                    "collect": collect,
                    "mayUseNetwork": may_use_network,
                    "timeoutSeconds": timeout_seconds.unwrap_or(600),
                })
            }
            GeneratorStep::Archive { url, query, .. } => {
                let mut address = archive_url(&expand_value(url, &values), &field)?;
                let parameters: Vec<(String, String)> = query
                    .iter()
                    .filter(|parameter| form::holds(parameter.when.as_ref(), &state.values))
                    .map(|parameter| {
                        (
                            parameter.name.clone(),
                            expand_value(&parameter.value, &values),
                            parameter.omit_empty,
                        )
                    })
                    .filter(|(_, value, omit_empty)| !(value.is_empty() && *omit_empty))
                    .map(|(name, value, _)| (name, value))
                    .collect();
                if !parameters.is_empty() {
                    address.query_pairs_mut().extend_pairs(parameters);
                }
                json!({
                    "kind": "archive",
                    "url": address.as_str(),
                    "host": address.host_str().unwrap_or_default(),
                    "format": "zip",
                })
            }
        });
    }

    let mut open_files = Vec::new();
    for (index, path) in generator.open_files.iter().enumerate() {
        if form::holds(path.when(), &state.values) {
            let field = format!("projectGenerators.{}.openFiles[{index}]", generator.id);
            open_files.push(expand_path(path.path(), &values, &field)?);
        }
    }

    let runtimes: Vec<Value> = generator
        .fields
        .iter()
        .filter(|field| field.is(FIELD_RUNTIME))
        .filter_map(|field| match state.values.get(&field.id) {
            Some(FieldValue::Runtime { home, version }) if !home.is_empty() => Some(json!({
                "field": field.id,
                "runtime": field.runtime,
                "home": home,
                "version": version,
            })),
            _ => None,
        })
        .collect();

    let uses_network = generator
        .steps
        .iter()
        .filter(|step| form::holds(step.when(), &state.values))
        .any(GeneratorStep::uses_network);

    Ok(json!({
        "projectName": input.project_name,
        "steps": steps,
        "openFiles": open_files,
        "runtimes": runtimes,
        "usesNetwork": uses_network,
    }))
}

fn reject_invalid_form(state: &FormState) -> Validation<()> {
    if let Some(problem) = state.project_name_problem {
        return Err(PluginRejection::at(
            INVALID_INPUT,
            "projectName",
            format!("The project name is not accepted ({}).", problem.code()),
        ));
    }
    if let Some(field) = state.fields.iter().find(|field| field.problem.is_some()) {
        return Err(PluginRejection::at(
            INVALID_INPUT,
            format!("values.{}", field.id),
            format!(
                "The value of {} is not accepted ({}).",
                field.id,
                field.problem.expect("found by problem").code()
            ),
        ));
    }
    Ok(())
}

fn expand_value(value: &str, values: &Values<'_>) -> String {
    // Declarations are validated, so every template parses.
    template::parse(value)
        .map(|parts| values.expand(&parts))
        .unwrap_or_default()
}

/// Expands a project-relative path and checks the result still stays
/// inside the project: a field value may contain `/`, never `..`.
fn expand_path(value: &str, values: &Values<'_>, field: &str) -> Validation<String> {
    let expanded = expand_value(value, values);
    if !is_safe_relative_path(&expanded)
        || expanded
            .split('/')
            .any(|part| part.is_empty() || part == ".")
    {
        return Err(PluginRejection::at(
            INVALID_INPUT,
            field,
            format!("{expanded} is not a path inside the project."),
        ));
    }
    Ok(expanded)
}

fn archive_url(text: &str, field: &str) -> Validation<url::Url> {
    let rejected = || {
        PluginRejection::at(
            INVALID_URL,
            field,
            format!("{text} is not an HTTPS address of a project archive."),
        )
    };
    let address = url::Url::parse(text).map_err(|_| rejected())?;
    let loopback = matches!(
        address.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]")
    );
    let scheme_ok = address.scheme() == "https" || (address.scheme() == "http" && loopback);
    if !scheme_ok
        || address.host_str().is_none_or(str::is_empty)
        || !address.username().is_empty()
        || address.password().is_some()
        || address.query().is_some()
        || address.fragment().is_some()
    {
        return Err(rejected());
    }
    Ok(address)
}

#[derive(Default)]
struct FileBudget {
    files: usize,
    bytes: u64,
}

fn template_files(
    package_path: &Path,
    source: &str,
    target: Option<&str>,
    values: &Values<'_>,
    known: &dyn Fn(&Variable) -> bool,
    budget: &mut FileBudget,
    field: &str,
) -> Validation<Vec<Value>> {
    let template_error = |message: String| PluginRejection::at(TEMPLATE_INVALID, field, message);
    let root = package_path.join(source);
    let metadata = fs::symlink_metadata(&root)
        .map_err(|_| template_error(format!("The package has no template directory {source}.")))?;
    if !metadata.is_dir() {
        return Err(template_error(format!("{source} is not a directory.")));
    }
    let mut relative_files = Vec::new();
    collect_files(&root, PathBuf::new(), 0, &mut relative_files)
        .map_err(|message| template_error(format!("{source}: {message}")))?;
    relative_files.sort();

    let mut files = Vec::with_capacity(relative_files.len());
    for relative in relative_files {
        let relative_text = relative
            .to_str()
            .ok_or_else(|| template_error("A template path is not UTF-8.".into()))?
            .replace('\\', "/");
        let full = root.join(&relative);
        let metadata = fs::symlink_metadata(&full)
            .map_err(|error| template_error(format!("{relative_text}: {error}")))?;
        budget.files += 1;
        budget.bytes += metadata.len();
        if budget.files > MAX_TEMPLATE_FILES
            || metadata.len() > MAX_TEMPLATE_FILE_BYTES
            || budget.bytes > MAX_TEMPLATE_BYTES
        {
            return Err(template_error("The templates are too large.".into()));
        }

        let parts = template::parse(&relative_text)
            .filter(|parts| {
                parts.iter().all(|part| match part {
                    crate::plugins::declarative::TemplatePart::Variable(variable) => {
                        known(variable)
                    }
                    crate::plugins::declarative::TemplatePart::Text(_) => true,
                })
            })
            .ok_or_else(|| template_error(format!("{relative_text} names an unknown variable.")))?;
        let expanded = values
            .expand(&parts)
            .split('/')
            .map(|segment| match segment.strip_prefix(DOTFILE_PREFIX) {
                Some(rest) if !rest.is_empty() => format!(".{rest}"),
                _ => segment.to_string(),
            })
            .collect::<Vec<_>>()
            .join("/");
        let path = match target {
            Some(target) => format!("{target}/{expanded}"),
            None => expanded,
        };
        if !is_safe_relative_path(&path)
            || path.split('/').any(|part| part.is_empty() || part == ".")
        {
            return Err(PluginRejection::at(
                INVALID_INPUT,
                field,
                format!("{path} is not a path inside the project."),
            ));
        }

        let bytes =
            fs::read(&full).map_err(|error| template_error(format!("{relative_text}: {error}")))?;
        let text = String::from_utf8(bytes)
            .map_err(|_| template_error(format!("{relative_text} is not UTF-8 text.")))?;
        let contents = values.expand_file(&text, known).map_err(|variable| {
            template_error(format!(
                "{relative_text} uses an unknown variable {variable}."
            ))
        })?;
        files.push(json!({
            "path": path,
            "contents": contents,
            "executable": is_executable(&metadata),
        }));
    }
    Ok(files)
}

/// Lists regular files below `directory`, refusing symbolic links and
/// skipping hidden entries such as `.DS_Store`.
fn collect_files(
    directory: &Path,
    relative: PathBuf,
    depth: usize,
    files: &mut Vec<PathBuf>,
) -> Result<(), String> {
    if depth > MAX_TEMPLATE_DEPTH {
        return Err("templates are nested too deeply".into());
    }
    let entries = fs::read_dir(directory).map_err(|error| error.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name();
        let Some(name_text) = name.to_str() else {
            return Err("a template name is not UTF-8".into());
        };
        if name_text.starts_with('.') {
            continue;
        }
        let file_type = entry.file_type().map_err(|error| error.to_string())?;
        let child = relative.join(&name);
        if file_type.is_symlink() {
            return Err(format!("{} is a symbolic link", child.display()));
        } else if file_type.is_dir() {
            collect_files(&entry.path(), child, depth + 1, files)?;
        } else if file_type.is_file() {
            files.push(child);
        }
        if files.len() > MAX_TEMPLATE_FILES {
            return Err("too many template files".into());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn is_executable(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_: &fs::Metadata) -> bool {
    false
}
