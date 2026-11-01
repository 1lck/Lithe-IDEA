//! Native evidence for plugin-defined tools. Core owns ordering, versions and
//! path policy; this adapter reads declarations and never interprets tool names.
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime},
};

const INVALID: &str = "toolchain.native.unavailable";
const CHANGED: &str = "toolchain.native.changed";
const LIMIT: &str = "toolchain.native.limitExceeded";
const MAX_FACTS: usize = 8192;
const MAX_ENTRIES: usize = 4096;

/// Inputs captured by the native host, including independently checked origins.
pub struct Request<'a> {
    pub registry: &'a Value,
    pub workspace: &'a Path,
    pub user_home: &'a Path,
    pub tool: &'a str,
    pub directory: &'a str,
    pub environment: &'a BTreeMap<String, String>,
    pub minimum_version: Option<&'a str>,
    pub project_code_allowed: bool,
}

/// One operation's result, never a persisted or settings-page launch permit.
pub struct Selection {
    pub executable: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub project_code: bool,
    pub version: Option<String>,
}

#[derive(PartialEq)]
struct Observation {
    fact: Value,
    modified: Option<SystemTime>,
    created: Option<SystemTime>,
    length: u64,
    #[cfg(unix)]
    inode: Option<(u64, u64)>,
}

struct Capture {
    facts: BTreeMap<String, Observation>,
    entries: usize,
    deadline: Instant,
}

impl Capture {
    fn check(&self) -> Result<(), String> {
        if Instant::now() >= self.deadline {
            Err(LIMIT.into())
        } else {
            Ok(())
        }
    }
    fn add(&mut self, path: &Path) -> Result<(), String> {
        self.check()?;
        let path = native_path(path);
        let key = identity(&path);
        if !self.facts.contains_key(&key) {
            if self.facts.len() >= MAX_FACTS {
                return Err(LIMIT.into());
            }
            self.facts.insert(key, observe(&path));
        }
        Ok(())
    }
    fn home(&mut self, home: &Path, definition: &Value) -> Result<(), String> {
        self.add(home)?;
        let canonical = home.canonicalize().ok();
        for layout in rows(definition, "executableLayouts").filter(|value| applicable(value)) {
            if let Some(path) = layout["path"].as_str() {
                self.add(&home.join(path))?;
                if let Some(canonical) = &canonical {
                    self.add(&canonical.join(path))?;
                }
            }
        }
        for path in rows(definition, "pathPrepend").filter_map(Value::as_str) {
            if let Some(suffix) = path.strip_prefix("${home}") {
                self.add(
                    &canonical
                        .as_deref()
                        .unwrap_or(home)
                        .join(suffix.trim_start_matches('/')),
                )?;
            }
        }
        Ok(())
    }
    fn expand(&mut self, root: PathBuf, pattern: &str) -> Result<Vec<PathBuf>, String> {
        let mut current = vec![root];
        for component in pattern.split('/') {
            let mut next = Vec::new();
            for directory in current {
                self.check()?;
                if !component.contains('*') {
                    next.push(directory.join(component));
                    continue;
                }
                let entries = match fs::read_dir(directory) {
                    Ok(value) => value,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                    Err(_) => return Err(INVALID.into()),
                };
                let mut paths = Vec::new();
                for entry in entries {
                    self.entries += 1;
                    if self.entries > MAX_ENTRIES {
                        return Err(LIMIT.into());
                    }
                    let entry = entry.map_err(|_| INVALID)?;
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    if (!name.starts_with('.') || component.starts_with('.'))
                        && matches(component, &name)
                    {
                        paths.push(entry.path());
                    }
                }
                paths.sort();
                next.extend(paths);
            }
            if next.len() > MAX_ENTRIES {
                return Err(LIMIT.into());
            }
            current = next;
        }
        Ok(current)
    }
    fn unchanged(&self) -> bool {
        self.facts.values().all(|value| {
            value.fact["path"]
                .as_str()
                .is_some_and(|path| observe(path) == *value)
        })
    }
    fn values(&self) -> Value {
        json!(
            self.facts
                .values()
                .map(|value| &value.fact)
                .collect::<Vec<_>>()
        )
    }
}

/// Resolves the current directory's pin, declared scans and shell candidates.
/// The caller owns bounded process execution and package lifecycle leases. A
/// provider-backed selection fails closed until that host implements queries.
pub fn resolve(
    request: Request<'_>,
    mut probe: impl FnMut(
        &Path,
        &[String],
        &BTreeMap<String, String>,
        Duration,
    ) -> Result<String, String>,
) -> Result<Option<Selection>, String> {
    let mut capture = Capture {
        facts: BTreeMap::new(),
        entries: 0,
        deadline: Instant::now() + Duration::from_secs(20),
    };
    let workspace = request.workspace.canonicalize().map_err(|_| INVALID)?;
    let root = native_path(&workspace);
    let plan = core(
        "toolchains.discoveryPlan",
        json!({"registry":request.registry,"platform":platform()}),
    )?;
    let Some(plan) = rows(&plan["plan"], "tools").find(|value| value["tool"] == request.tool)
    else {
        return Ok(None);
    };
    let registry = core("toolchains.registry", request.registry.clone())?;
    let definition = rows(&registry["registry"], "definitions")
        .find(|entry| entry["definition"]["id"] == request.tool)
        .map(|entry| &entry["definition"])
        .ok_or(INVALID)?;
    let local_path = workspace.join(".lithe/toolchains/local.json");
    let local = read_local(&local_path, &workspace)?;
    let document = local
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .map_err(|_| INVALID)?
        .unwrap_or(json!({"version":1,"toolchains":{}}));
    let pins = core(
        "toolchains.resolvePins",
        json!({"document":document,"directory":request.directory,"tool":request.tool}),
    )?;
    let pinned = pins["resolution"]["pin"]["home"].as_str();
    if pinned.is_none() && !rows(plan, "providers").collect::<Vec<_>>().is_empty() {
        return Err("toolchain.native.providerUnavailable".into());
    }
    capture.add(&workspace)?;
    let mut installations = Vec::new();
    for (index, scan) in rows(plan, "scans").filter(|_| pinned.is_none()).enumerate() {
        if index >= 256 {
            return Err(LIMIT.into());
        }
        let source = &scan["root"];
        let base = match source["kind"].as_str() {
            Some("home") => Some(request.user_home.to_path_buf()),
            Some("environment") => source["variable"]
                .as_str()
                .and_then(|name| environment(request.environment, name))
                .map(PathBuf::from),
            Some("absolute") => source["path"].as_str().map(PathBuf::from),
            _ => None,
        };
        let Some(base) = base.filter(|base| base.is_absolute()) else {
            continue;
        };
        for entry in capture.expand(base, scan["pattern"].as_str().ok_or(INVALID)?)? {
            let layouts: Vec<_> = rows(definition, "homeLayouts")
                .filter(|value| applicable(value))
                .collect();
            let home = if layouts.is_empty() {
                Some(entry)
            } else {
                let name = entry
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("");
                layouts
                    .into_iter()
                    .find(|layout| matches(layout["match"].as_str().unwrap_or(""), name))
                    .and_then(|layout| layout["home"].as_str())
                    .map(|suffix| {
                        if suffix == "." {
                            entry.clone()
                        } else {
                            entry.join(suffix)
                        }
                    })
            };
            let Some(home) = home else {
                continue;
            };
            let Ok(canonical) = home.canonicalize() else {
                continue;
            };
            if within(&canonical, &workspace) || !canonical.is_dir() {
                continue;
            }
            if installations.len() >= 512 {
                return Err(LIMIT.into());
            }
            capture.home(&home, definition)?;
            installations.push(json!({"tool":request.tool,"home":native_path(&home)}));
        }
    }
    let mut variables = BTreeMap::new();
    for candidate in rows(definition, "executables")
        .filter(|value| pinned.is_none() && applicable(value) && value["kind"] == "environment")
    {
        if let Some(name) = candidate["variable"].as_str() {
            if let Some(home) =
                environment(request.environment, name).filter(|home| Path::new(home).is_absolute())
            {
                variables.insert(name.to_owned(), home.to_owned());
                capture.home(Path::new(home), definition)?;
            }
        }
    }
    let mut extra = Vec::new();
    if let Some(home) = pinned {
        capture.home(Path::new(home), definition)?;
        extra.push(home.to_owned());
    }
    let mut commands = BTreeMap::new();
    for command in rows(definition, "commands")
        .filter(|_| pinned.is_none())
        .filter_map(Value::as_str)
    {
        let Some(path) = find_command(request.environment, command) else {
            continue;
        };
        let Ok(canonical) = path.canonicalize() else {
            continue;
        };
        for layout in rows(definition, "executableLayouts").filter(|value| applicable(value)) {
            let suffix = layout["path"].as_str().ok_or(INVALID)?;
            let text = native_path(&canonical);
            if identity(&text).ends_with(&identity(&format!("/{suffix}"))) {
                let home = text[..text.len() - suffix.len() - 1].to_owned();
                capture.home(Path::new(&home), definition)?;
                extra.push(home.clone());
                commands.insert(command.to_owned(), home);
                break;
            }
        }
    }
    let mut ancestor = request.directory;
    for _ in 0..64 {
        let anchor = if ancestor == "." {
            workspace.clone()
        } else {
            workspace.join(ancestor)
        };
        for candidate in rows(definition, "executables")
            .filter(|value| pinned.is_none() && applicable(value) && value["kind"] == "projectFile")
        {
            capture.add(&anchor.join(candidate["path"].as_str().ok_or(INVALID)?))?;
            for marker in rows(candidate, "requires").filter_map(Value::as_str) {
                capture.add(&anchor.join(marker))?;
            }
            if let Some(home) = candidate["home"].as_str() {
                capture.add(&anchor.join(home))?;
            }
        }
        if ancestor == "." {
            break;
        }
        ancestor = ancestor.rsplit_once('/').map_or(".", |(parent, _)| parent);
    }
    let mut all_installations = installations.clone();
    all_installations.extend(
        extra
            .into_iter()
            .map(|home| json!({"tool":request.tool,"home":home})),
    );
    let candidates = core(
        "toolchains.candidates",
        json!({"registry":request.registry,"tool":request.tool,
        "platform":platform(),"filesystemCaseSensitive":cfg!(not(windows)),"workspaceRoot":root,
        "filesystem":capture.values(),"environment":variables,"systemInstallations":all_installations,"probes":[]}),
    )?;
    let mut targets: BTreeSet<String> = ["skipped", "shell"]
        .into_iter()
        .flat_map(|key| rows(&candidates["candidates"], key))
        .filter(|value| value["reason"] == "probeFailed")
        .filter_map(|value| value["executable"].as_str().map(str::to_owned))
        .collect();
    let mut input = json!({"registry":request.registry,"tool":request.tool,"directory":request.directory,
        "operationID":"native-consumer","generation":1,"context":null,"platform":platform(),
        "filesystemCaseSensitive":cfg!(not(windows)),"workspaceRoot":root,"workspaceRoots":[root],
        "filesystem":capture.values(),"local":document,"environment":variables,"commandHomes":commands,
        "systemInstallations":installations,"projectCodeAllowed":request.project_code_allowed,"probes":[]});
    if request.project_code_allowed && request.minimum_version.is_some() {
        let preliminary = core("toolchains.resolve", input.clone())?;
        let selected = &preliminary["resolution"]["outcome"]["selection"];
        if selected["projectCode"] == true {
            if let Some(path) = selected["executable"].as_str() {
                targets.insert(path.into());
            }
        }
    }
    if let Some(version) = request.minimum_version {
        input["minimumVersion"] = json!(version);
    }
    if targets.len() > 64 {
        return Err(LIMIT.into());
    }
    let arguments: Vec<_> = rows(&definition["version"], "arguments")
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let mut probes = Vec::new();
    for target in targets {
        capture.check()?;
        let remaining = capture
            .deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_secs(5));
        if let Ok(output) = probe(
            Path::new(&target),
            &arguments,
            request.environment,
            remaining,
        ) {
            if output.len() > 128 * 1024 {
                return Err(LIMIT.into());
            }
            probes.push(json!({"executable":target,"output":output,"exitCode":0}));
        }
    }
    capture.check()?;
    if !capture.unchanged() || read_local(&local_path, &workspace)? != local {
        return Err(CHANGED.into());
    }
    input["probes"] = json!(probes);
    let resolution = core("toolchains.resolve", input)?;
    let outcome = &resolution["resolution"]["outcome"];
    if outcome["kind"] != "resolved" {
        return Err(INVALID.into());
    }
    let selection = &outcome["selection"];
    // Only declared exports and PATH leave this adapter. The probe's inherited
    // environment may contain credentials that must never enter Provider RPC.
    let mut environment = BTreeMap::new();
    for (key, value) in selection["environment"].as_object().ok_or(INVALID)? {
        if let Some(value) = value.as_str() {
            environment.insert(key.clone(), value.into());
        }
    }
    let mut paths: Vec<PathBuf> = rows(selection, "pathPrepend")
        .filter_map(Value::as_str)
        .map(PathBuf::from)
        .collect();
    if let Some(path) = self::environment(request.environment, "PATH") {
        paths.extend(std::env::split_paths(path).filter(|path| path.is_absolute()));
    }
    if !paths.is_empty() {
        environment.insert(
            "PATH".into(),
            std::env::join_paths(paths)
                .map_err(|_| INVALID)?
                .to_string_lossy()
                .into_owned(),
        );
    }
    Ok(Some(Selection {
        executable: PathBuf::from(selection["executable"].as_str().ok_or(INVALID)?),
        environment,
        project_code: selection["projectCode"] == true,
        version: selection["version"].as_str().map(str::to_owned),
    }))
}

fn core(command: &str, payload: Value) -> Result<Value, String> {
    let value: Value = serde_json::from_str(&lithe_core::execute_json(
        &json!({"command":command,"payload":payload}).to_string(),
    ))
    .map_err(|_| INVALID)?;
    if value["ok"] != true || value["data"]["status"] != "ok" {
        return Err(INVALID.into());
    }
    Ok(value["data"].clone())
}
fn rows<'a>(value: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}
fn platform() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}
fn applicable(value: &Value) -> bool {
    value.get("platforms").is_none_or(|values| {
        values
            .as_array()
            .is_some_and(|values| values.iter().any(|value| value == platform()))
    })
}
fn environment<'a>(values: &'a BTreeMap<String, String>, name: &str) -> Option<&'a str> {
    values
        .iter()
        .find(|(key, _)| {
            if cfg!(windows) {
                key.eq_ignore_ascii_case(name)
            } else {
                *key == name
            }
        })
        .map(|(_, value)| value.as_str())
}
fn native_path(path: &Path) -> String {
    let path = path.components().collect::<PathBuf>();
    let text = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        text.strip_prefix("//?/UNC/")
            .map(|rest| format!("//{rest}"))
            .unwrap_or_else(|| text.strip_prefix("//?/").unwrap_or(&text).into())
    } else {
        text
    }
}
fn identity(path: &str) -> String {
    if cfg!(windows) {
        path.to_lowercase()
    } else {
        path.into()
    }
}
fn within(path: &Path, root: &Path) -> bool {
    let (path, root) = (identity(&native_path(path)), identity(&native_path(root)));
    path == root || path.starts_with(&(root.trim_end_matches('/').to_owned() + "/"))
}
fn observe(path: &str) -> Observation {
    let metadata = fs::metadata(path).ok();
    let canonical = fs::canonicalize(path).ok().map(|path| native_path(&path));
    let kind = match metadata.as_ref() {
        Some(value) if value.is_dir() => "directory",
        Some(value) if value.is_file() => "file",
        _ => "missing",
    };
    let mut fact =
        json!({"path":path,"canonicalPath":canonical.unwrap_or_else(||path.into()),"kind":kind});
    if kind == "file" {
        fact["executable"] = json!(is_executable(Path::new(path)));
    }
    Observation {
        fact,
        modified: metadata.as_ref().and_then(|value| value.modified().ok()),
        created: metadata.as_ref().and_then(|value| value.created().ok()),
        length: metadata.as_ref().map_or(0, fs::Metadata::len),
        #[cfg(unix)]
        inode: {
            use std::os::unix::fs::MetadataExt;
            metadata.map(|value| (value.dev(), value.ino()))
        },
    }
}
fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        path.extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| {
                ["exe", "cmd", "bat", "com"]
                    .iter()
                    .any(|extension| value.eq_ignore_ascii_case(extension))
            })
    }
}
fn find_command(environment_values: &BTreeMap<String, String>, command: &str) -> Option<PathBuf> {
    for directory in std::env::split_paths(environment(environment_values, "PATH")?) {
        if !directory.is_absolute() {
            continue;
        }
        let names = if cfg!(windows) {
            vec![
                format!("{command}.exe"),
                format!("{command}.cmd"),
                format!("{command}.bat"),
            ]
        } else {
            vec![command.into()]
        };
        if let Some(path) = names
            .into_iter()
            .map(|name| directory.join(name))
            .find(|path| is_executable(path))
        {
            return Some(path);
        }
    }
    None
}
fn matches(pattern: &str, name: &str) -> bool {
    let parts: Vec<_> = pattern.split('*').collect();
    let mut remaining = name;
    for (index, part) in parts.iter().enumerate() {
        if index == 0 {
            let Some(rest) = remaining.strip_prefix(part) else {
                return false;
            };
            remaining = rest;
        } else if index + 1 == parts.len() {
            return remaining.ends_with(part);
        } else if let Some(offset) = remaining.find(part) {
            remaining = &remaining[offset + part.len()..];
        } else {
            return false;
        }
    }
    remaining.is_empty()
}
fn read_local(path: &Path, workspace: &Path) -> Result<Option<String>, String> {
    let resolved = crate::native_configuration::validated_target(path, &[]).map_err(|_| INVALID)?;
    if !within(&resolved, workspace) {
        return Err(INVALID.into());
    }
    if fs::metadata(&resolved).is_ok_and(|value| !value.is_file() || value.len() > 2 * 1024 * 1024)
    {
        return Err(INVALID.into());
    }
    let value = crate::document_file::read_document(&resolved).map_err(|_| INVALID)?;
    if value
        .as_ref()
        .is_some_and(|value| value.len() > 2 * 1024 * 1024)
    {
        return Err(INVALID.into());
    }
    Ok(value)
}

#[cfg(test)]
mod tests;
