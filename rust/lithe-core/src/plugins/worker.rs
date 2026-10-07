//! Platform-independent validation of imported worker packages and their grants.
//!
//! Workers may request only their declared language and Run services. Platform
//! adapters own storage and execution; unknown input fields never grant services.

use super::{valid_relative_path, PluginVersion};
use crate::protocol::{CoreError, ErrorCode};
use serde_json::{json, Map, Value};

/// Maximum UTF-8 bytes accepted for the version-one worker container.
pub const MAX_WORKER_PACKAGE_BYTES: usize = 256 * 1024;

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, CoreError> {
    value[key]
        .as_str()
        .filter(|text| !text.is_empty() && text.len() <= 4096 && !text.contains('\0'))
        .ok_or_else(|| invalid(&format!("Invalid plugin {key}")))
}

fn name(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

fn strings(value: &Value, maximum: usize) -> Result<Vec<String>, CoreError> {
    let entries = value
        .as_array()
        .filter(|entries| entries.len() <= maximum)
        .ok_or_else(|| invalid("Invalid plugin string list"))?;
    entries
        .iter()
        .map(|entry| {
            entry
                .as_str()
                .filter(|entry| entry.len() <= 4096 && !entry.contains('\0'))
                .map(str::to_owned)
                .ok_or_else(|| invalid("Invalid plugin string"))
        })
        .collect()
}

/// Validates the complete v1 container and returns only supported capabilities.
/// The source is opaque code: Core neither executes it nor infers permissions.
pub fn validate_package(input: &str) -> Result<Value, CoreError> {
    if input.len() > super::bundle::MAX_BUNDLE_BYTES {
        return Err(invalid("Plugin bundle exceeds 128 MB"));
    }
    let package: Value =
        serde_json::from_str(input).map_err(|_| invalid("Invalid worker plugin JSON"))?;
    if package["format"] == "lithe-native-worker-plugin" {
        return super::bundle::verify_bundle(input).map(|bundle| bundle.package);
    }
    if input.len() > MAX_WORKER_PACKAGE_BYTES {
        return Err(invalid("Worker metadata exceeds 256 KB"));
    }
    if !package["nativePackage"].is_null() {
        return super::bundle::validate_receipt(&package);
    }
    validate_value(package, false)
}

pub(crate) fn validate_value(
    package: Value,
    allow_packaged_server: bool,
) -> Result<Value, CoreError> {
    if package["format"] != "lithe-worker-plugin"
        || package["version"] != 1
        || package["source"]
            .as_str()
            .is_none_or(|source| source.trim().is_empty())
    {
        return Err(invalid("Invalid worker plugin package"));
    }
    let source = &package["source"];
    let manifest = &package["manifest"];
    let id = text(manifest, "id")?;
    if id.len() > 128
        || !name(id)
        || id != id.to_ascii_lowercase()
        || !id.contains('.')
        || !id.as_bytes()[0].is_ascii_lowercase()
        || manifest["main"] != "plugin.js"
    {
        return Err(invalid("Invalid plugin identity or entrypoint"));
    }
    if PluginVersion::parse(text(manifest, "version")?).is_none() {
        return Err(invalid("Invalid plugin version"));
    }
    let mut normalized = Map::new();
    for key in [
        "id",
        "name",
        "displayName",
        "description",
        "version",
        "publisher",
    ] {
        normalized.insert(key.into(), json!(text(manifest, key)?));
    }
    normalized.insert("categories".into(), json!(["Language"]));
    normalized.insert("main".into(), json!("plugin.js"));
    normalized.insert("installation".into(), json!({"type":"local"}));
    let languages = manifest["languages"]
        .as_array()
        .filter(|items| !items.is_empty() && items.len() <= 16)
        .ok_or_else(|| invalid("A language plugin must declare its languages"))?;
    let mut language_ids = std::collections::BTreeSet::new();
    let languages: Vec<Value> = languages
        .iter()
        .map(|language| {
            let id = text(language, "id")?;
            if !id.as_bytes()[0].is_ascii_lowercase()
                || !id
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
                || !language_ids.insert(id.to_string())
            {
                return Err(invalid("Invalid or duplicate language identity"));
            }
            let extensions = strings(&language["extensions"], 128)?;
            if extensions.iter().any(|ext| {
                !ext.starts_with('.')
                    || ext.len() < 2
                    || !ext[1..].bytes().all(|c| c.is_ascii_alphanumeric())
            }) {
                return Err(invalid("Invalid language extension"));
            }
            let mut result = json!({"id":id,"extensions":extensions});
            if !language["aliases"].is_null() {
                result["aliases"] = json!(strings(&language["aliases"], 128)?);
            }
            if !language["filenames"].is_null() {
                let filenames = strings(&language["filenames"], 128)?;
                if filenames.iter().any(|file| !name(file)) {
                    return Err(invalid("Invalid language filename"));
                }
                result["filenames"] = json!(filenames);
            }
            Ok(result)
        })
        .collect::<Result<_, CoreError>>()?;
    normalized.insert("languages".into(), json!(languages));
    let run = &manifest["runActions"];
    let mut run_result = Map::new();
    for key in ["manifestFiles", "executables"] {
        let entries = strings(&run[key], 16)?;
        if entries
            .iter()
            .any(|entry| !name(entry) || !valid_relative_path(entry))
        {
            return Err(invalid("Invalid run action declaration"));
        }
        run_result.insert(key.into(), json!(entries));
    }
    normalized.insert("runActions".into(), Value::Object(run_result));
    let lsp = &manifest["lsp"];
    if !lsp.is_null() {
        let tool = text(lsp, "name")?;
        let runtime = text(lsp, "runtime")?;
        if !name(tool)
            || (!(["bun", "system"].contains(&runtime))
                && !(runtime == "package" && allow_packaged_server))
            || (runtime != "package" && lsp["server"]["default"] != tool)
        {
            return Err(invalid("Invalid language server configuration"));
        }
        let mut server = json!({"name":tool,"runtime":runtime,"server":{"default":tool}});
        if runtime == "package" {
            let entrypoint = text(&lsp["server"], "default")?;
            if !super::bundle::safe_resource_path(entrypoint) {
                return Err(invalid("Invalid packaged server entrypoint"));
            }
            server["server"]["default"] = json!(entrypoint);
            if !lsp["runtimeExecutable"].is_null() {
                let executable = text(lsp, "runtimeExecutable")?;
                if executable != "node" {
                    return Err(invalid("Unsupported packaged server runtime"));
                }
                server["runtimeExecutable"] = json!(executable);
            }
        }
        for key in ["args", "fileExtensions", "languageIds"] {
            server[key] = json!(strings(&lsp[key], 128)?);
        }
        if strings(&lsp["languageIds"], 128)?
            .iter()
            .any(|id| !language_ids.contains(id))
        {
            return Err(invalid("Language server references an unowned language"));
        }
        if runtime == "bun" {
            let package = text(lsp, "package")?;
            let parts: Vec<&str> = package.trim_start_matches('@').split('/').collect();
            if parts.is_empty()
                || parts.len() > 2
                || parts.iter().any(|part| !name(part))
                || (parts.len() == 2 && !package.starts_with('@'))
            {
                return Err(invalid("Invalid language server package"));
            }
            server["package"] = json!(package);
        }
        if !lsp["requiredExecutables"].is_null() {
            let executables = strings(&lsp["requiredExecutables"], 16)?;
            if executables.iter().any(|exe| !name(exe)) {
                return Err(invalid("Invalid executable requirement"));
            }
            server["requiredExecutables"] = json!(executables);
        }
        normalized.insert("lsp".into(), server);
    }
    Ok(
        json!({"format":"lithe-worker-plugin","version":1,"source":source,"manifest":normalized,"installed":package["installed"] == true}),
    )
}
