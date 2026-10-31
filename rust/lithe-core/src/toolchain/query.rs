//! Validates provider query replies against host-owned identity and filesystem facts.

use super::paths;
use crate::plugins::declarative::{PluginRejection, Validation};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const INVALID: &str = "plugin.toolchain.invalidParams";
const REPLY: &str = "plugin.toolchain.invalidReply";
const UNSAFE: &str = "plugin.toolchain.unsafePath";
const LIMIT: &str = "plugin.toolchain.limitExceeded";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    jsonrpc: String,
    id: u64,
    method: String,
    params: Params,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Params {
    #[serde(rename = "operationID")]
    operation_id: String,
    generation: u64,
    #[serde(rename = "providerID")]
    provider_id: String,
    authority: Authority,
    context: Option<Context>,
    workspace: Option<Workspace>,
    tools: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Authority {
    kind: String,
    id: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Context {
    #[serde(rename = "contextID")]
    context_id: String,
    generation: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Workspace {
    #[serde(rename = "rootID")]
    root_id: String,
    root: String,
    directory: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reply {
    #[serde(rename = "operationID")]
    operation_id: String,
    generation: u64,
    #[serde(rename = "providerID")]
    provider_id: String,
    installations: Vec<Installation>,
    statements: Vec<Statement>,
    watch: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Installation {
    tool: String,
    version: String,
    home: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Statement {
    tool: String,
    scope: String,
    source: String,
    request: String,
    installation: Option<String>,
    kind: String,
    reader: String,
}

/// Host-observed filesystem state; providers cannot populate this evidence.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FileFact {
    path: String,
    canonical_path: String,
    kind: String,
    #[serde(default)]
    executable: bool,
}

struct Facts {
    // Keys use the target volume's case policy; returned paths retain native spelling.
    values: BTreeMap<String, FileFact>,
    platform: String,
    case_sensitive: bool,
}

impl Facts {
    fn key(&self, path: &str) -> Validation<String> {
        paths::normalize(path, &self.platform, self.case_sensitive).ok_or_else(|| {
            reject(
                UNSAFE,
                "path",
                "An absolute normalized native path is required.",
            )
        })
    }

    fn canonical(&self, path: &str, kind: Option<&str>) -> Validation<String> {
        let key = self.key(path)?;
        let fact = self.values.get(&key).ok_or_else(|| {
            reject(
                UNSAFE,
                "filesystem",
                "Required native filesystem evidence is missing.",
            )
        })?;
        if kind.is_some_and(|expected| fact.kind != expected) {
            return Err(reject(
                UNSAFE,
                "filesystem.kind",
                "The native path has an invalid file type.",
            ));
        }
        paths::normalize(&fact.canonical_path, &self.platform, true).ok_or_else(|| {
            reject(
                UNSAFE,
                "filesystem.canonicalPath",
                "Invalid canonical path evidence.",
            )
        })
    }

    fn executable(&self, path: &str) -> Validation<String> {
        let canonical = self.canonical(path, Some("file"))?;
        if !self.values[&self.key(path)?].executable {
            return Err(reject(
                UNSAFE,
                "filesystem.executable",
                "The selected program is not executable.",
            ));
        }
        Ok(canonical)
    }

    fn within(&self, path: &str, root: &str) -> bool {
        paths::within(path, root, &self.platform, self.case_sensitive)
    }
}

fn reject(code: &'static str, field: &str, message: &str) -> PluginRejection {
    PluginRejection::at(code, field, message)
}

fn bounded(value: &str, maximum: usize) -> bool {
    !value.is_empty() && value.len() <= maximum && !value.chars().any(char::is_control)
}

fn identifier(value: &str) -> bool {
    bounded(value, 128)
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

fn provider_identifier(value: &str) -> bool {
    bounded(value, 64)
        && value.as_bytes()[0].is_ascii_lowercase()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn directory(value: &str) -> bool {
    value == "."
        || (bounded(value, 2048)
            && !value.contains(['\\', ':'])
            && value
                .split('/')
                .all(|part| !part.is_empty() && !matches!(part, "." | "..")))
}

fn object_keys(
    value: &Value,
    allowed: &[&str],
    required: &[&str],
    code: &'static str,
) -> Validation<()> {
    let object = value
        .as_object()
        .ok_or_else(|| reject(code, "response", "An object is required."))?;
    if object.keys().any(|key| !allowed.contains(&key.as_str()))
        || required.iter().any(|key| !object.contains_key(*key))
    {
        return Err(reject(
            code,
            "response",
            "The object contains missing or unsupported fields.",
        ));
    }
    Ok(())
}

/// Maps each query error to one stable JSON-RPC number without transport work.
pub(crate) fn rpc_code(code: &str) -> Option<i64> {
    Some(match code {
        "plugin.toolchain.methodUnavailable" => -32601,
        INVALID => -32602,
        "plugin.toolchain.cancelled" => -32800,
        "plugin.toolchain.permissionDenied" => -32070,
        "plugin.toolchain.authorityUnsupported" => -32071,
        "plugin.toolchain.timeout" => -32072,
        "plugin.toolchain.providerUnavailable" => -32073,
        REPLY => -32074,
        LIMIT => -32075,
        UNSAFE => -32076,
        "plugin.toolchain.operationExpired" => -32077,
        _ => return None,
    })
}

fn error_reply(response: &Value, params: &Params) -> Validation<Value> {
    let error = &response["error"];
    object_keys(
        error,
        &["code", "message", "data"],
        &["code", "message", "data"],
        REPLY,
    )?;
    let data = &error["data"];
    object_keys(
        data,
        &["code", "operationID", "providerID", "details"],
        &["code", "operationID", "providerID"],
        REPLY,
    )?;
    let code = data["code"].as_str().unwrap_or("");
    if rpc_code(code) != error["code"].as_i64()
        || data["operationID"] != params.operation_id
        || data["providerID"] != params.provider_id
        || !error["message"]
            .as_str()
            .is_some_and(|value| bounded(value, 1024))
        || data
            .get("details")
            .is_some_and(|value| !value.is_object() || value.to_string().len() > 4096)
    {
        return Err(reject(
            REPLY,
            "response.error",
            "The provider error mapping or request identity is invalid.",
        ));
    }
    // Borrowed provider strings cannot become stable static error identifiers.
    let stable = match error["code"].as_i64() {
        Some(-32601) => "plugin.toolchain.methodUnavailable",
        Some(-32602) => INVALID,
        Some(-32800) => "plugin.toolchain.cancelled",
        Some(-32070) => "plugin.toolchain.permissionDenied",
        Some(-32071) => "plugin.toolchain.authorityUnsupported",
        Some(-32072) => "plugin.toolchain.timeout",
        Some(-32073) => "plugin.toolchain.providerUnavailable",
        Some(-32074) => REPLY,
        Some(-32075) => LIMIT,
        Some(-32076) => UNSAFE,
        Some(-32077) => "plugin.toolchain.operationExpired",
        _ => {
            return Err(reject(
                REPLY,
                "response.error.code",
                "Unknown provider error code.",
            ))
        }
    };
    Err(PluginRejection::new(
        stable,
        error["message"].as_str().unwrap_or_default(),
    ))
}

fn glob_component(pattern: &str, value: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    let mut remaining = value;
    for (index, part) in parts.iter().enumerate() {
        if index == 0 {
            let Some(rest) = remaining.strip_prefix(part) else {
                return false;
            };
            remaining = rest;
        } else if index == parts.len() - 1 {
            return remaining.ends_with(part);
        } else if let Some(position) = remaining.find(part) {
            remaining = &remaining[position + part.len()..];
        } else {
            return false;
        }
    }
    remaining.is_empty()
}

fn source_anchor(source: &str, pattern: &str, case_sensitive: bool) -> Option<String> {
    let source = if case_sensitive {
        source.to_owned()
    } else {
        source.to_lowercase()
    };
    let pattern = if case_sensitive {
        pattern.to_owned()
    } else {
        pattern.to_lowercase()
    };
    let segments: Vec<&str> = source.split('/').collect();
    let patterns: Vec<&str> = pattern.split('/').collect();
    if segments.len() <= patterns.len()
        || !patterns
            .iter()
            .zip(&segments[segments.len() - patterns.len()..])
            .all(|(pattern, value)| glob_component(pattern, value))
    {
        return None;
    }
    let anchor = segments[..segments.len() - patterns.len()].join("/");
    Some(if anchor.is_empty() {
        "/".to_owned()
    } else {
        anchor
    })
}

fn file_values(input: &Value) -> Validation<&[Value]> {
    input["filesystem"]
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| {
            reject(
                INVALID,
                "filesystem",
                "Native filesystem evidence is required.",
            )
        })
}

fn read_facts(file_values: &[Value], platform: &str, case_sensitive: bool) -> Validation<Facts> {
    let mut facts = Facts {
        values: BTreeMap::new(),
        platform: platform.to_owned(),
        case_sensitive,
    };
    if file_values.len() > 8192 {
        return Err(reject(
            LIMIT,
            "filesystem",
            "Too many native filesystem facts.",
        ));
    }
    for value in file_values {
        let fact: FileFact = serde_json::from_value(value.clone())
            .map_err(|_| reject(INVALID, "filesystem", "Malformed native filesystem fact."))?;
        if !matches!(fact.kind.as_str(), "file" | "directory" | "missing")
            || paths::normalize(&fact.canonical_path, platform, true).is_none()
        {
            return Err(reject(
                UNSAFE,
                "filesystem",
                "Invalid native filesystem evidence.",
            ));
        }
        if facts.values.insert(facts.key(&fact.path)?, fact).is_some() {
            return Err(reject(
                INVALID,
                "filesystem",
                "Duplicate native filesystem path.",
            ));
        }
    }
    Ok(facts)
}

fn checked_installation(
    home: &str,
    definition: &Value,
    facts: &Facts,
    roots: &[String],
) -> Validation<Value> {
    let canonical_home = facts.canonical(home, Some("directory"))?;
    if roots.iter().any(|root| facts.within(&canonical_home, root)) {
        return Err(reject(
            UNSAFE,
            "installation.home",
            "A provider installation cannot be workspace code.",
        ));
    }
    for layout in definition["executableLayouts"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if layout.get("platforms").is_some_and(|platforms| {
            !platforms
                .as_array()
                .is_some_and(|platforms| platforms.iter().any(|value| value == &facts.platform))
        }) {
            continue;
        }
        let path = paths::join(home, layout["path"].as_str().unwrap_or(""), &facts.platform)
            .ok_or_else(|| reject(UNSAFE, "executableLayouts", "Invalid executable layout."))?;
        let Some(fact) = facts.values.get(&facts.key(&path)?) else {
            continue;
        };
        if fact.kind == "missing" {
            continue;
        }
        let executable = facts.executable(&path)?;
        if !facts.within(&executable, &canonical_home)
            || roots.iter().any(|root| facts.within(&executable, root))
        {
            return Err(reject(
                UNSAFE,
                "installation.executable",
                "The executable escapes its installation or enters the workspace.",
            ));
        }
        return Ok(json!({"home":canonical_home,"executable":executable}));
    }
    Err(reject(
        UNSAFE,
        "installation.executable",
        "No validated executable matches the tool definition.",
    ))
}

/// Validates an external installation against trusted, authority-local native facts.
/// Returns canonical home/executable paths without touching the native filesystem.
/// Project-code candidates require their separate consumer trust policy.
pub(crate) fn validate_installation(
    home: &str,
    definition: &Value,
    filesystem: &[Value],
    workspace_roots: &[String],
    platform: &str,
    case_sensitive: bool,
) -> Validation<Value> {
    if !matches!(platform, "macos" | "windows" | "linux") {
        return Err(reject(
            INVALID,
            "platform",
            "A supported target platform is required.",
        ));
    }
    let facts = read_facts(filesystem, platform, case_sensitive)?;
    let roots = workspace_roots
        .iter()
        .map(|root| facts.canonical(root, Some("directory")))
        .collect::<Validation<Vec<_>>>()?;
    checked_installation(home, definition, &facts, &roots)
}

/// Decodes one provider reply using only verified registry and native facts.
/// No filesystem, process, environment or JSON-RPC transport is accessed here.
pub(crate) fn decode(input: &Value) -> Validation<Value> {
    object_keys(
        input,
        &[
            "registry",
            "pluginID",
            "request",
            "response",
            "currentGeneration",
            "filesystem",
            "platform",
            "filesystemCaseSensitive",
            "workspaceRoots",
        ],
        &[
            "registry",
            "pluginID",
            "request",
            "response",
            "currentGeneration",
            "filesystem",
            "platform",
        ],
        INVALID,
    )?;
    let registry = super::definitions::registry(&input["registry"])?;
    let request_value = &input["request"];
    let request: Request = serde_json::from_value(request_value.clone())
        .map_err(|_| reject(INVALID, "request", "Malformed toolchain query request."))?;
    let params = &request.params;
    if request.jsonrpc != "2.0"
        || request.id == 0
        || !identifier(&params.operation_id)
        || params.generation == 0
        || !provider_identifier(&params.provider_id)
        || params.tools.is_empty()
        || params.tools.len() > 64
        || params
            .tools
            .iter()
            .any(|tool| !super::definitions::tool_id(tool))
        || params.tools.iter().collect::<BTreeSet<_>>().len() != params.tools.len()
        || !params.tools.windows(2).all(|pair| pair[0] < pair[1])
        || !request_value["params"].as_object().is_some_and(|object| {
            object.contains_key("workspace") && object.contains_key("context")
        })
    {
        return Err(reject(
            INVALID,
            "request.params",
            "Invalid query identities or tool bounds.",
        ));
    }
    if request.method != "toolchains/query" {
        return Err(reject(
            "plugin.toolchain.methodUnavailable",
            "request.method",
            "Unsupported toolchain method.",
        ));
    }
    if input["currentGeneration"].as_u64() != Some(params.generation) {
        return Err(reject(
            "plugin.toolchain.operationExpired",
            "request.params.generation",
            "The toolchain query generation is no longer current.",
        ));
    }
    if params.authority.kind == "remote" && params.authority.id.as_deref().is_some_and(identifier) {
        return Err(reject(
            "plugin.toolchain.authorityUnsupported",
            "request.params.authority",
            "No remote toolchain adapter is available.",
        ));
    }
    if params.authority.kind != "local"
        || params.authority.id.is_some()
        || params
            .context
            .as_ref()
            .is_some_and(|context| !identifier(&context.context_id) || context.generation == 0)
        || params.workspace.is_some() && params.context.is_none()
    {
        return Err(reject(
            INVALID,
            "request.params.authority",
            "Invalid query authority or workspace context.",
        ));
    }
    object_keys(
        &request_value["params"]["authority"],
        &["kind"],
        &["kind"],
        INVALID,
    )?;
    let platform = input["platform"].as_str().unwrap_or("");
    if !matches!(platform, "macos" | "windows" | "linux") {
        return Err(reject(
            INVALID,
            "platform",
            "A supported target platform is required.",
        ));
    }
    let case_sensitive = match input.get("filesystemCaseSensitive") {
        Some(value) => value.as_bool().ok_or_else(|| {
            reject(
                INVALID,
                "filesystemCaseSensitive",
                "Filesystem case sensitivity must be boolean.",
            )
        })?,
        None => platform != "windows",
    };
    let facts = read_facts(file_values(input)?, platform, case_sensitive)?;
    let mut roots = Vec::new();
    let mut requested_directory = None;
    if let Some(workspace) = &params.workspace {
        if !identifier(&workspace.root_id) || !directory(&workspace.directory) {
            return Err(reject(
                INVALID,
                "request.params.workspace",
                "Invalid workspace identity or directory.",
            ));
        }
        let root = facts.canonical(&workspace.root, Some("directory"))?;
        let native_directory = if workspace.directory == "." {
            root.clone()
        } else {
            let path =
                paths::join(&workspace.root, &workspace.directory, platform).ok_or_else(|| {
                    reject(
                        UNSAFE,
                        "request.params.workspace.directory",
                        "Invalid workspace directory.",
                    )
                })?;
            facts.canonical(&path, Some("directory"))?
        };
        if !facts.within(&native_directory, &root) {
            return Err(reject(
                UNSAFE,
                "request.params.workspace.directory",
                "The queried directory escapes its workspace root.",
            ));
        }
        requested_directory = Some(native_directory);
        roots.push(root);
    }
    if let Some(extra) = input.get("workspaceRoots") {
        let extra = extra
            .as_array()
            .filter(|values| values.len() <= 64)
            .ok_or_else(|| reject(INVALID, "workspaceRoots", "Invalid workspace roots."))?;
        for root in extra {
            roots.push(facts.canonical(
                root.as_str().ok_or_else(|| {
                    reject(INVALID, "workspaceRoots", "Workspace roots must be paths.")
                })?,
                Some("directory"),
            )?);
        }
    }
    let plugin_id = input["pluginID"]
        .as_str()
        .ok_or_else(|| reject(INVALID, "pluginID", "A bound plugin identity is required."))?;
    let provider = registry["providers"]
        .as_array()
        .and_then(|providers| {
            providers.iter().find(|entry| {
                entry["pluginID"] == plugin_id && entry["provider"]["id"] == params.provider_id
            })
        })
        .ok_or_else(|| {
            reject(
                "plugin.toolchain.permissionDenied",
                "pluginID",
                "The enabled provider is not in the verified registry.",
            )
        })?;
    let provider = &provider["provider"];
    let declared: BTreeSet<&str> = provider["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if params
        .tools
        .iter()
        .any(|tool| !declared.contains(tool.as_str()))
    {
        return Err(reject(
            INVALID,
            "request.params.tools",
            "The query names an undeclared provider tool.",
        ));
    }
    let requested: BTreeSet<&str> = params.tools.iter().map(String::as_str).collect();
    let definitions: BTreeMap<&str, &Value> = registry["definitions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|entry| Some((entry["definition"]["id"].as_str()?, &entry["definition"])))
        .collect();
    let response = &input["response"];
    if response.to_string().len() > 1024 * 1024 {
        return Err(reject(
            LIMIT,
            "response",
            "The provider reply exceeds the byte limit.",
        ));
    }
    object_keys(
        response,
        &["jsonrpc", "id", "result", "error"],
        &["jsonrpc", "id"],
        REPLY,
    )?;
    if response["jsonrpc"] != "2.0"
        || response["id"].as_u64() != Some(request.id)
        || response.get("result").is_some() == response.get("error").is_some()
    {
        return Err(reject(
            REPLY,
            "response",
            "The response envelope or JSON-RPC identity is invalid.",
        ));
    }
    if response.get("error").is_some() {
        return error_reply(response, params);
    }
    let reply: Reply = serde_json::from_value(response["result"].clone()).map_err(|_| {
        reject(
            REPLY,
            "response.result",
            "Malformed provider toolchain reply.",
        )
    })?;
    for statement in response["result"]["statements"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if statement.get("installation").is_none() {
            return Err(reject(
                REPLY,
                "response.result.statements.installation",
                "A statement must explicitly identify an installation or null.",
            ));
        }
    }
    if reply.operation_id != params.operation_id
        || reply.provider_id != params.provider_id
        || reply.generation != params.generation
    {
        return Err(reject(
            "plugin.toolchain.operationExpired",
            "response.result",
            "The reply belongs to a different toolchain operation.",
        ));
    }
    if reply.installations.len() > 512 || reply.statements.len() > 256 || reply.watch.len() > 256 {
        return Err(reject(
            LIMIT,
            "response.result",
            "The provider reply exceeds collection limits.",
        ));
    }
    let qualified = format!("{plugin_id}:{}", params.provider_id);
    let mut installations = BTreeMap::new();
    let mut references = BTreeMap::new();
    for installation in &reply.installations {
        if !super::definitions::tool_id(&installation.tool)
            || !bounded(&installation.version, 128)
            || !bounded(&installation.home, 4096)
        {
            return Err(reject(
                REPLY,
                "response.result.installations",
                "Invalid installation string bounds.",
            ));
        }
        let Some(definition) = definitions
            .get(installation.tool.as_str())
            .filter(|_| requested.contains(installation.tool.as_str()))
        else {
            continue;
        };
        let checked = checked_installation(&installation.home, definition, &facts, &roots)?;
        let home = checked["home"]
            .as_str()
            .expect("checked home is a string")
            .to_owned();
        let executable = checked["executable"]
            .as_str()
            .expect("checked executable is a string");
        let home_key = facts.key(&home)?;
        references.insert(
            (installation.tool.clone(), facts.key(&installation.home)?),
            home.clone(),
        );
        let identity = (installation.tool.clone(), home_key);
        if installations
            .get(&identity)
            .is_some_and(|value: &Value| value["version"] != installation.version)
        {
            return Err(reject(
                REPLY,
                "response.result.installations.version",
                "One canonical installation has inconsistent versions.",
            ));
        }
        installations.entry(identity).or_insert_with(|| json!({"tool":installation.tool,"version":installation.version,"home":home,"executable":executable,"provider":qualified}));
    }
    let mut statements = BTreeMap::new();
    let mut statement_facts = BTreeMap::new();
    let mut diagnostics = BTreeMap::new();
    for statement in &reply.statements {
        if !super::definitions::tool_id(&statement.tool)
            || !bounded(&statement.source, 4096)
            || !bounded(&statement.request, 512)
            || statement
                .installation
                .as_ref()
                .is_some_and(|value| !bounded(value, 4096))
            || !matches!(statement.scope.as_str(), "project" | "global")
            || !matches!(statement.kind.as_str(), "environment" | "declaration")
            || !matches!(statement.reader.as_str(), "native" | "compatible")
        {
            return Err(reject(
                REPLY,
                "response.result.statements",
                "Invalid statement shape or string bounds.",
            ));
        }
        if statement.scope == "project" && params.workspace.is_none() {
            return Err(reject(
                REPLY,
                "response.result.statements.scope",
                "A global query cannot contain project statements.",
            ));
        }
        if !requested.contains(statement.tool.as_str()) {
            continue;
        }
        facts.key(&statement.source)?;
        if !definitions.contains_key(statement.tool.as_str()) {
            // Preserve only display facts; even malformed native homes are never inspected.
            let diagnostic = json!({"code":"definitionUnavailable","tool":statement.tool,"scope":statement.scope,"source":statement.source,"request":statement.request,"provider":qualified});
            diagnostics.insert(diagnostic.to_string(), diagnostic);
            continue;
        }
        let source = facts.canonical(&statement.source, Some("file"))?;
        let anchors: Vec<String> = provider["watchFiles"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|watch| watch["reader"] == statement.reader)
            .filter_map(|watch| source_anchor(&source, watch["pattern"].as_str()?, case_sensitive))
            .collect();
        if anchors.is_empty() {
            return Err(reject(
                REPLY,
                "response.result.statements.reader",
                "The source or reader is not declared by the provider.",
            ));
        }
        if statement.scope == "project"
            && !anchors.iter().any(|anchor| {
                requested_directory.as_ref().is_some_and(|directory| {
                    facts.within(directory, anchor)
                        && directory
                            .split('/')
                            .count()
                            .saturating_sub(anchor.split('/').count())
                            < 64
                })
            })
        {
            return Err(reject(
                UNSAFE,
                "response.result.statements.source",
                "The project source is not a bounded ancestor input.",
            ));
        }
        let home = statement
            .installation
            .as_ref()
            .map(|path| {
                references
                    .get(&(statement.tool.clone(), facts.key(path)?))
                    .cloned()
                    .ok_or_else(|| {
                        reject(
                            REPLY,
                            "response.result.statements.installation",
                            "The statement names an unlisted installation.",
                        )
                    })
            })
            .transpose()?;
        let identity = (
            statement.tool.clone(),
            statement.scope.clone(),
            facts.key(&source)?,
            statement.kind.clone(),
            statement.reader.clone(),
        );
        let choice = (
            statement.request.clone(),
            home.as_deref().map(|path| facts.key(path)).transpose()?,
        );
        if let Some(previous) = statement_facts.insert(identity, choice.clone()) {
            if previous != choice {
                return Err(reject(
                    REPLY,
                    "response.result.statements",
                    "One provider source reports inconsistent requirements or installations.",
                ));
            }
            continue;
        }
        let source_directory = anchors
            .iter()
            .filter(|anchor| {
                statement.scope == "global"
                    || requested_directory
                        .as_ref()
                        .is_some_and(|directory| facts.within(directory, anchor))
            })
            .max_by_key(|anchor| anchor.split('/').count())
            .cloned()
            .unwrap_or_default();
        let normalized = json!({"tool":statement.tool,"scope":statement.scope,"source":source,"sourceDirectory":source_directory,"request":statement.request,"installation":home,"kind":statement.kind,"reader":statement.reader,"provider":qualified});
        if home.is_none() {
            let diagnostic = json!({"code":"requestedNotInstalled","tool":statement.tool,"source":source,"request":statement.request,"provider":qualified});
            diagnostics.insert(diagnostic.to_string(), diagnostic);
        }
        statements.insert(normalized.to_string(), normalized);
    }
    let mut watch = BTreeMap::new();
    for path in &reply.watch {
        let key = facts.key(path)?;
        let canonical = if facts.values.contains_key(&key) {
            facts.canonical(path, None)?
        } else {
            paths::normalize(path, platform, true)
                .ok_or_else(|| reject(UNSAFE, "response.result.watch", "Invalid watch path."))?
        };
        watch.insert(facts.key(&canonical)?, canonical);
    }
    Ok(
        json!({"installations":installations.into_values().collect::<Vec<_>>(),"statements":statements.into_values().collect::<Vec<_>>(),"watch":watch.into_values().collect::<Vec<_>>(),"diagnostics":diagnostics.into_values().collect::<Vec<_>>()}),
    )
}
