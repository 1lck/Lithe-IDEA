//! Validates plugin-owned tool policies and constructs an origin-checked registry.
//! Filesystem evidence and native execution remain host-owned responsibilities.

use crate::plugins::declarative::{invalid, validate_manifest_value, UIIcon, Validation};
use crate::plugins::executables::{ordered_indices, ExecutableCandidate};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

/// Validates a short tool ID or a plugin-qualified tool ID, without granting ownership.
pub(crate) fn tool_id(value: &str) -> bool {
    let local = |s: &str| {
        s.len() <= 64
            && s.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
            && s.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    };
    value.len() <= 192
        && match value.split_once(':') {
            Some((plugin, id)) => {
                !id.contains(':')
                    && !plugin.is_empty()
                    && plugin.split(['.', '-']).all(|part| {
                        !part.is_empty()
                            && part
                                .bytes()
                                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
                    })
                    && local(id)
            }
            None => local(value),
        }
}

/// Checks declared export names; native process-environment filtering still applies.
pub(crate) fn safe_environment_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value != "PATH"
        && !value.starts_with("DYLD_")
        && !value.starts_with("LD_")
        && (value.as_bytes()[0].is_ascii_uppercase() || value.as_bytes()[0] == b'_')
        && value
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
}

fn object<'a>(
    value: &'a Value,
    fields: &[&str],
    required: &[&str],
    field: &str,
) -> Validation<&'a Map<String, Value>> {
    let map = value
        .as_object()
        .ok_or_else(|| invalid(field, "An object is required."))?;
    if map.keys().any(|key| !fields.contains(&key.as_str()))
        || required.iter().any(|key| !map.contains_key(*key))
    {
        return Err(invalid(
            field,
            "The object contains unknown fields or omits required fields.",
        ));
    }
    Ok(map)
}

fn text<'a>(value: &'a Value, max: usize, field: &str) -> Validation<&'a str> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control))
        .ok_or_else(|| {
            invalid(
                field,
                "A bounded nonempty string without controls is required.",
            )
        })
}

fn list<'a>(value: &'a Value, min: usize, max: usize, field: &str) -> Validation<&'a [Value]> {
    value
        .as_array()
        .filter(|v| (min..=max).contains(&v.len()))
        .map(Vec::as_slice)
        .ok_or_else(|| invalid(field, "The array exceeds its declared bounds."))
}

fn optional_list<'a>(value: &'a Value, key: &str, max: usize) -> Validation<&'a [Value]> {
    match value.get(key) {
        Some(value) => list(value, 0, max, key),
        None => Ok(&[]),
    }
}

fn relative(value: &str, glob: bool) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && !value.chars().any(char::is_control)
        && !value.contains(['\\', ':', '?', '[', ']', '{', '}'])
        && (glob || !value.contains('*'))
        && !value.contains("**")
        && value
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
        && (!glob || value.split('/').count() <= 8)
}

fn path(value: &Value, glob: bool, field: &str) -> Validation<()> {
    if !relative(text(value, 256, field)?, glob) {
        return Err(invalid(
            field,
            "A bounded relative path without traversal is required.",
        ));
    }
    Ok(())
}

fn platforms(value: &Value) -> Validation<BTreeSet<String>> {
    let Some(items) = value.get("platforms") else {
        return Ok(["macos", "linux", "windows"].map(str::to_owned).into());
    };
    let mut result = BTreeSet::new();
    for item in list(items, 1, 3, "platforms")? {
        let name = text(item, 16, "platforms")?;
        if !["macos", "windows", "linux"].contains(&name) || !result.insert(name.to_owned()) {
            return Err(invalid(
                "platforms",
                "Platforms must be unique supported operating systems.",
            ));
        }
    }
    Ok(result)
}

fn strings(
    value: &Value,
    min: usize,
    max: usize,
    field: &str,
    check: impl Fn(&str) -> bool,
) -> Validation<()> {
    let mut seen = BTreeSet::new();
    for item in list(value, min, max, field)? {
        let item = text(item, 256, field)?;
        if !check(item) || !seen.insert(item) {
            return Err(invalid(field, "Values must be valid and unique."));
        }
    }
    Ok(())
}

fn command(value: &str) -> bool {
    value.len() <= 64
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn same_platforms(left: &Value, right: &Value) -> Validation<bool> {
    Ok(platforms(left)?.is_subset(&platforms(right)?))
}

fn matching_wrapper(candidate: &Value, wrapper: &Value) -> Validation<bool> {
    Ok(candidate["path"] == wrapper["path"]
        && candidate.get("requires").unwrap_or(&json!([]))
            == wrapper.get("requires").unwrap_or(&json!([]))
        && same_platforms(candidate, wrapper)?)
}

fn rank(candidate: &Value) -> Validation<u8> {
    match candidate["kind"].as_str() {
        Some("setting") => match candidate["layer"].as_str() {
            Some("project") => Ok(0),
            Some("global") => Ok(2),
            _ => Err(invalid(
                "executables.layer",
                "A setting layer is project or global.",
            )),
        },
        Some("projectFile") => Ok(1),
        Some("toolchain") => match candidate["scope"].as_str() {
            Some("project") => Ok(1),
            Some("global") => Ok(3),
            Some("installed") => Ok(5),
            _ => Err(invalid(
                "executables.scope",
                "A toolchain scope is project, global or installed.",
            )),
        },
        Some("environment" | "command") => Ok(4),
        _ => Err(invalid(
            "executables.kind",
            "This tool source is not supported.",
        )),
    }
}

fn candidates(definition: &Value) -> Validation<Vec<usize>> {
    let values = list(&definition["executables"], 1, 32, "executables")?;
    let mut metadata = Vec::new();
    for value in values {
        let kind = text(&value["kind"], 32, "executables.kind")?;
        let mut allowed = vec![
            "kind",
            "id",
            "priority",
            "insertBefore",
            "insertAfter",
            "platforms",
        ];
        let required: &[&str] = match kind {
            "setting" => &["kind", "settingID", "layer"],
            "toolchain" => &["kind", "scope"],
            "projectFile" => &["kind", "path"],
            "environment" => &["kind", "variable", "path"],
            "command" => &["kind", "command"],
            // Dependent tool source graphs require the consumer adapter, not this Core slice.
            _ => {
                return Err(invalid(
                    "executables.kind",
                    "This candidate source is not implemented for tool definitions.",
                ))
            }
        };
        allowed.extend_from_slice(required);
        if kind == "projectFile" {
            allowed.extend(["requires", "projectKind", "home"]);
        }
        object(value, &allowed, required, "executables")?;
        for key in ["id", "insertBefore", "insertAfter"] {
            if let Some(id) = value.get(key) {
                if !text(id, 64, key).is_ok_and(|id| tool_id(id) && !id.contains(':')) {
                    return Err(invalid(
                        "executables",
                        "Candidate IDs and anchors must be bounded local identifiers.",
                    ));
                }
            }
        }
        platforms(value)?;
        match kind {
            "setting" if value["settingID"] != "executable" => {
                return Err(invalid(
                    "executables.settingID",
                    "Tool settings use the framework executable slot.",
                ))
            }
            "projectFile" => {
                path(&value["path"], false, "executables.path")?;
                if value
                    .get("projectKind")
                    .is_some_and(|kind| !kind.is_string())
                {
                    return Err(invalid(
                        "executables.projectKind",
                        "The project source category must be a string.",
                    ));
                }
                if let Some(markers) = value.get("requires") {
                    strings(markers, 0, 8, "executables.requires", |s| {
                        relative(s, false)
                    })?;
                }
                match value
                    .get("projectKind")
                    .and_then(Value::as_str)
                    .unwrap_or("wrapper")
                {
                    "wrapper" => {
                        if value.get("home").is_some() {
                            return Err(invalid(
                                "executables.home",
                                "An executable-only wrapper cannot claim a home.",
                            ));
                        }
                        let wrappers = optional_list(definition, "wrappers", 8)?;
                        if !wrappers
                            .iter()
                            .any(|wrapper| matching_wrapper(value, wrapper).unwrap_or(false))
                        {
                            return Err(invalid(
                                "executables",
                                "A wrapper candidate must match its declared wrapper metadata.",
                            ));
                        }
                    }
                    "environment" => {
                        let home = text(&value["home"], 256, "executables.home")?;
                        if home != "." && !relative(home, false) {
                            return Err(invalid(
                                "executables.home",
                                "A project environment home must be relative.",
                            ));
                        }
                        let layouts =
                            list(&definition["executableLayouts"], 1, 8, "executableLayouts")?;
                        if !layouts.iter().any(|layout| {
                            let expected = if home == "." {
                                layout["path"].as_str().unwrap_or("").to_owned()
                            } else {
                                format!("{home}/{}", layout["path"].as_str().unwrap_or(""))
                            };
                            value["path"].as_str() == Some(expected.as_str())
                                && same_platforms(value, layout).unwrap_or(false)
                        }) {
                            return Err(invalid("executables.home", "A project environment executable must match its declared home layout."));
                        }
                    }
                    _ => {
                        return Err(invalid(
                            "executables.projectKind",
                            "Project sources are wrappers or environments.",
                        ))
                    }
                }
            }
            "environment" => {
                path(&value["path"], false, "executables.path")?;
                if value["variable"] != definition["homeVariable"]
                    || !value["variable"]
                        .as_str()
                        .is_some_and(safe_environment_name)
                    || !definition["executableLayouts"]
                        .as_array()
                        .is_some_and(|layouts| {
                            layouts.iter().any(|layout| {
                                layout["path"] == value["path"]
                                    && same_platforms(value, layout).unwrap_or(false)
                            })
                        })
                {
                    return Err(invalid("executables", "A shell environment candidate must match the home variable and executable layout."));
                }
            }
            "command" => {
                if !definition["commands"]
                    .as_array()
                    .is_some_and(|commands| commands.contains(&value["command"]))
                {
                    return Err(invalid(
                        "executables.command",
                        "A command must belong to its tool definition.",
                    ));
                }
            }
            _ => (),
        }
        // Reuse the shared graph validator without admitting new source fields to legacy sets.
        let mut projected = value.as_object().expect("validated object").clone();
        projected.retain(|key, _| {
            ["id", "priority", "insertBefore", "insertAfter", "platforms"].contains(&key.as_str())
        });
        projected.insert("kind".into(), json!("command"));
        projected.insert("command".into(), json!("toolchain-metadata"));
        metadata.push(
            serde_json::from_value::<ExecutableCandidate>(Value::Object(projected))
                .map_err(|_| invalid("executables", "Candidate ordering metadata is invalid."))?,
        );
        rank(value)?;
    }
    let indices = ordered_indices(&metadata, "executables")?;
    if indices
        .windows(2)
        .any(|pair| rank(&values[pair[0]]).unwrap_or(255) > rank(&values[pair[1]]).unwrap_or(0))
    {
        return Err(invalid(
            "executables",
            "Candidate ordering cannot cross the fixed four-layer boundaries.",
        ));
    }
    for wrapper in optional_list(definition, "wrappers", 8)? {
        let mut covered = BTreeSet::new();
        for candidate in values {
            if candidate["kind"] == "projectFile"
                && candidate
                    .get("projectKind")
                    .and_then(Value::as_str)
                    .unwrap_or("wrapper")
                    == "wrapper"
                && matching_wrapper(candidate, wrapper)?
            {
                covered.extend(platforms(candidate)?);
            }
        }
        if !platforms(wrapper)?.is_subset(&covered) {
            return Err(invalid(
                "wrappers",
                "Every wrapper needs a matching resolver candidate.",
            ));
        }
    }
    for cmd in list(&definition["commands"], 1, 8, "commands")? {
        if !values
            .iter()
            .any(|candidate| candidate["kind"] == "command" && candidate["command"] == *cmd)
        {
            return Err(invalid(
                "commands",
                "Every shell command needs a resolver candidate.",
            ));
        }
    }
    if definition.get("homeVariable").is_some()
        && !values
            .iter()
            .any(|candidate| candidate["kind"] == "environment")
    {
        return Err(invalid(
            "homeVariable",
            "The home variable needs a resolver candidate.",
        ));
    }
    Ok(indices)
}

fn definition(plugin_id: &str, value: &Value) -> Validation<()> {
    object(
        value,
        &[
            "id",
            "displayName",
            "icon",
            "executableLayouts",
            "executables",
            "version",
            "homeLayouts",
            "discovery",
            "homeVariable",
            "commands",
            "wrappers",
            "exports",
            "pathPrepend",
            "launch",
        ],
        &[
            "id",
            "displayName",
            "executableLayouts",
            "executables",
            "version",
            "commands",
            "launch",
        ],
        "toolDefinitions",
    )?;
    let id = text(&value["id"], 192, "toolDefinitions.id")?;
    if !tool_id(id)
        || id
            .split_once(':')
            .is_some_and(|(owner, _)| owner != plugin_id)
    {
        return Err(invalid(
            "toolDefinitions.id",
            "A tool ID must be short or owned by this plugin's namespace.",
        ));
    }
    text(&value["displayName"], 64, "toolDefinitions.displayName")?;
    if let Some(icon) = value.get("icon") {
        let icon: UIIcon = serde_json::from_value(icon.clone())
            .map_err(|_| invalid("toolDefinitions.icon", "The icon shape is invalid."))?;
        icon.validate_at("toolDefinitions.icon")?;
    }
    for layout in list(&value["executableLayouts"], 1, 8, "executableLayouts")? {
        object(
            layout,
            &["path", "platforms"],
            &["path"],
            "executableLayouts",
        )?;
        path(&layout["path"], false, "executableLayouts.path")?;
        platforms(layout)?;
    }
    for layout in optional_list(value, "homeLayouts", 8)? {
        object(
            layout,
            &["match", "home", "platforms"],
            &["match", "home"],
            "homeLayouts",
        )?;
        path(&layout["match"], true, "homeLayouts.match")?;
        if layout["match"].as_str().is_some_and(|s| s.contains('/')) {
            return Err(invalid(
                "homeLayouts.match",
                "A home layout matches one directory name.",
            ));
        }
        if layout["home"] != "." {
            path(&layout["home"], false, "homeLayouts.home")?;
        }
        platforms(layout)?;
    }
    for scan in optional_list(value, "discovery", 16)? {
        object(
            scan,
            &["root", "pattern", "platforms"],
            &["root", "pattern"],
            "discovery",
        )?;
        path(&scan["pattern"], true, "discovery.pattern")?;
        platforms(scan)?;
        let root = &scan["root"];
        match root["kind"].as_str() {
            Some("home") => {
                object(root, &["kind"], &["kind"], "discovery.root")?;
            }
            Some("environment") => {
                object(
                    root,
                    &["kind", "variable"],
                    &["kind", "variable"],
                    "discovery.root",
                )?;
                if !text(&root["variable"], 64, "discovery.root.variable")
                    .is_ok_and(safe_environment_name)
                {
                    return Err(invalid(
                        "discovery.root.variable",
                        "The environment variable is unsafe.",
                    ));
                }
            }
            Some("absolute") => {
                object(root, &["kind", "path"], &["kind", "path"], "discovery.root")?;
                let root = text(&root["path"], 256, "discovery.root.path")?;
                if !(root.starts_with('/')
                    || (root.len() >= 3
                        && root.as_bytes()[0].is_ascii_alphabetic()
                        && root.as_bytes()[1] == b':'
                        && matches!(root.as_bytes()[2], b'/' | b'\\')))
                    || root
                        .split(['/', '\\'])
                        .any(|part| part == "." || part == "..")
                {
                    return Err(invalid(
                        "discovery.root.path",
                        "Discovery roots must be normalized absolute paths.",
                    ));
                }
            }
            _ => return Err(invalid("discovery.root", "Unknown discovery root kind.")),
        }
    }
    strings(&value["commands"], 1, 8, "commands", command)?;
    if let Some(variable) = value.get("homeVariable") {
        if !text(variable, 64, "homeVariable").is_ok_and(safe_environment_name) {
            return Err(invalid("homeVariable", "The home variable is unsafe."));
        }
    }
    for wrapper in optional_list(value, "wrappers", 8)? {
        object(
            wrapper,
            &["path", "requires", "platforms"],
            &["path"],
            "wrappers",
        )?;
        path(&wrapper["path"], false, "wrappers.path")?;
        platforms(wrapper)?;
        if let Some(markers) = wrapper.get("requires") {
            strings(markers, 0, 8, "wrappers.requires", |s| relative(s, false))?;
        }
    }
    let version = &value["version"];
    object(
        version,
        &["arguments", "pattern"],
        &["arguments", "pattern"],
        "version",
    )?;
    strings(&version["arguments"], 1, 8, "version.arguments", |arg| {
        let flag = arg
            .strip_prefix("--")
            .or_else(|| arg.strip_prefix('-'))
            .unwrap_or("");
        arg.len() <= 64
            && flag.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
            && flag.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    })?;
    let pattern = text(&version["pattern"], 512, "version.pattern")?;
    if Regex::new(pattern).map_or(true, |regex| regex.captures_len() < 2) {
        return Err(invalid(
            "version.pattern",
            "A valid bounded version expression needs a first capture.",
        ));
    }
    let mut export_names = BTreeSet::new();
    for export in optional_list(value, "exports", 16)? {
        object(export, &["name", "value"], &["name", "value"], "exports")?;
        let name = text(&export["name"], 64, "exports.name")?;
        if !safe_environment_name(name)
            || !export_names.insert(name)
            || ![json!("${home}"), json!("${executable}")].contains(&export["value"])
        {
            return Err(invalid(
                "exports",
                "Export names and templates must be safe and unique.",
            ));
        }
    }
    if let Some(prepend) = value.get("pathPrepend") {
        strings(prepend, 0, 8, "pathPrepend", |s| {
            s == "${home}"
                || s.strip_prefix("${home}/")
                    .is_some_and(|suffix| relative(suffix, false) && !suffix.contains('$'))
        })?;
    }
    let launch = list(&value["launch"], 1, 32, "launch")?;
    if launch.first() != Some(&json!("${executable}")) {
        return Err(invalid(
            "launch",
            "The first argv token must be the selected executable.",
        ));
    }
    let mut lists = BTreeSet::new();
    for token in launch {
        let token = text(token, 256, "launch")?;
        if token.contains('$')
            && ![
                "${home}",
                "${executable}",
                "${entry}",
                "${runtimeArguments}",
                "${arguments}",
            ]
            .contains(&token)
        {
            return Err(invalid(
                "launch",
                "Only whole-token launch variables are permitted.",
            ));
        }
        if ["${runtimeArguments}", "${arguments}"].contains(&token) && !lists.insert(token) {
            return Err(invalid(
                "launch",
                "An argument list may be expanded only once.",
            ));
        }
    }
    candidates(value)?;
    Ok(())
}

fn provider(value: &Value) -> Validation<()> {
    object(
        value,
        &["id", "displayName", "tools", "watchFiles"],
        &["id", "displayName", "tools", "watchFiles"],
        "toolchainProviders",
    )?;
    let id = text(&value["id"], 64, "toolchainProviders.id")?;
    if !tool_id(id) || id.contains(':') {
        return Err(invalid(
            "toolchainProviders.id",
            "A provider ID is local to its plugin.",
        ));
    }
    text(&value["displayName"], 64, "toolchainProviders.displayName")?;
    strings(&value["tools"], 1, 32, "toolchainProviders.tools", tool_id)?;
    let mut patterns = BTreeSet::new();
    for watch in list(&value["watchFiles"], 1, 32, "watchFiles")? {
        object(
            watch,
            &["pattern", "reader"],
            &["pattern", "reader"],
            "watchFiles",
        )?;
        path(&watch["pattern"], true, "watchFiles.pattern")?;
        let pattern = text(&watch["pattern"], 256, "watchFiles.pattern")?;
        if !patterns.insert(pattern)
            || ![json!("native"), json!("compatible")].contains(&watch["reader"])
        {
            return Err(invalid(
                "watchFiles",
                "Watch patterns must be unique and declare native or compatible ownership.",
            ));
        }
    }
    Ok(())
}

/// Checks declaration shape and deterministic policy without asserting native trust.
pub(crate) fn validate_declarations(
    plugin_id: &str,
    definitions: &[Value],
    providers: &[Value],
) -> Validation<()> {
    if definitions.len() > 32 || providers.len() > 8 {
        return Err(invalid(
            "toolDefinitions",
            "The plugin exceeds toolchain contribution limits.",
        ));
    }
    let mut ids = BTreeSet::new();
    for value in definitions {
        definition(plugin_id, value)?;
        if !ids.insert(value["id"].as_str()) {
            return Err(invalid(
                "toolDefinitions.id",
                "Tool definition IDs must be unique.",
            ));
        }
    }
    ids.clear();
    for value in providers {
        provider(value)?;
        if !ids.insert(value["id"].as_str()) {
            return Err(invalid(
                "toolchainProviders.id",
                "Provider IDs must be unique.",
            ));
        }
    }
    Ok(())
}

/// Revalidates complete enabled manifests and host-attested origin before registration.
/// A conflicting batch is rejected atomically; an existing definition is never replaced.
pub(crate) fn registry(input: &Value) -> Validation<Value> {
    object(input, &["plugins"], &["plugins"], "registry")?;
    let plugins = list(&input["plugins"], 0, 128, "plugins")?;
    let mut definitions = Vec::new();
    let mut providers = Vec::new();
    let mut tool_ids = BTreeSet::new();
    let mut plugin_ids = BTreeSet::new();
    for entry in plugins {
        object(
            entry,
            &["manifest", "verifiedOfficial"],
            &["manifest", "verifiedOfficial"],
            "plugins",
        )?;
        let official = entry["verifiedOfficial"].as_bool().ok_or_else(|| {
            invalid(
                "verifiedOfficial",
                "Verified origin is host-supplied boolean evidence.",
            )
        })?;
        let manifest = validate_manifest_value(entry["manifest"].clone())?;
        let manifest = serde_json::to_value(manifest)
            .map_err(|_| invalid("manifest", "The validated manifest cannot be encoded."))?;
        let plugin_id = text(&manifest["id"], 128, "id")?;
        if !plugin_ids.insert(plugin_id.to_owned()) {
            return Err(invalid(
                "plugins",
                "Plugin IDs must be unique in the enabled registry.",
            ));
        }
        for definition in optional_list(&manifest, "toolDefinitions", 32)? {
            let id = text(&definition["id"], 192, "toolDefinitions.id")?;
            if (!id.contains(':') && !official) || !tool_ids.insert(id.to_owned()) {
                return Err(invalid("toolDefinitions.id", "A short ID needs verified official provenance and no ID may replace an existing owner."));
            }
            let mut normalized = definition.clone();
            let indices = candidates(definition)?;
            normalized["executables"] = json!(indices
                .iter()
                .map(|index| definition["executables"][*index].clone())
                .collect::<Vec<_>>());
            definitions.push(json!({"pluginID":plugin_id,"definition":normalized}));
        }
        for provider in optional_list(&manifest, "toolchainProviders", 8)? {
            providers.push(json!({"pluginID":plugin_id,"provider":provider}));
        }
        if definitions.len() > 512 || providers.len() > 256 {
            return Err(invalid(
                "plugins",
                "The registry exceeds aggregate contribution limits.",
            ));
        }
    }
    definitions.sort_by_key(|entry| {
        (
            entry["definition"]["id"].as_str().unwrap_or("").to_owned(),
            entry["pluginID"].as_str().unwrap_or("").to_owned(),
        )
    });
    providers.sort_by_key(|entry| {
        (
            entry["pluginID"].as_str().unwrap_or("").to_owned(),
            entry["provider"]["id"].as_str().unwrap_or("").to_owned(),
        )
    });
    Ok(json!({"definitions":definitions,"providers":providers}))
}
