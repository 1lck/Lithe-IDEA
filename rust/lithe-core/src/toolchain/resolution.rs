//! Resolves captured toolchain candidates without native I/O or manager semantics.

use super::{definitions, fixed::FixedToolchainSelection, paths, pins, query};
use crate::plugins::declarative::{PluginRejection, Validation};
use regex::RegexBuilder;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Probe {
    executable: String,
    output: String,
    exit_code: i32,
}

fn fields(input: &Value, allowed: &[&str]) -> Validation<()> {
    if !input
        .as_object()
        .is_some_and(|object| object.keys().all(|key| allowed.contains(&key.as_str())))
    {
        return Err(reject("input"));
    }
    Ok(())
}

/// Numeric releases are tool-neutral; display aliases never enter comparison.
fn components(value: &str) -> Option<Vec<u32>> {
    if value.is_empty() || value.len() > 64 {
        return None;
    }
    let parts: Vec<_> = value.split('.').collect();
    if parts.len() > 8 {
        return None;
    }
    let mut numbers = parts
        .iter()
        .map(|part| {
            (!part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
                .then(|| part.parse().ok())
                .flatten()
        })
        .collect::<Option<Vec<u32>>>()?;
    while numbers.len() > 1 && numbers.last() == Some(&0) {
        numbers.pop();
    }
    Some(numbers)
}

fn reject(field: &str) -> PluginRejection {
    PluginRejection::at(
        "plugin.toolchain.invalidParams",
        field,
        "Invalid toolchain snapshot or native evidence.",
    )
}

fn bounded(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control)
}

fn array<'a>(input: &'a Value, key: &str, max: usize) -> Validation<&'a [Value]> {
    match input.get(key) {
        None => Ok(&[]),
        Some(value) => value
            .as_array()
            .filter(|items| items.len() <= max)
            .map(Vec::as_slice)
            .ok_or_else(|| reject(key)),
    }
}

fn enabled<'a>(registry: &'a Value, tool: &str) -> Option<&'a Value> {
    registry["definitions"]
        .as_array()?
        .iter()
        .find(|entry| entry["definition"]["id"] == tool)
        .map(|entry| &entry["definition"])
}

fn capture(definition: &Value, output: &str, minimum: Option<&str>) -> Validation<Value> {
    if output.len() > 128 * 1024 {
        return Err(reject("output"));
    }
    let minimum = minimum
        .map(|value| components(value).ok_or_else(|| reject("minimumVersion")))
        .transpose()?;
    let expression = RegexBuilder::new(definition["version"]["pattern"].as_str().unwrap_or(""))
        .size_limit(1024 * 1024)
        .build()
        .map_err(|_| reject("version.pattern"))?;
    let captured = expression
        .captures(output)
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str());
    let version = captured.filter(|value| components(value).is_some());
    let satisfied = version.is_some_and(|version| {
        minimum
            .as_ref()
            .is_none_or(|minimum| components(version).as_ref() >= Some(minimum))
    });
    Ok(json!({"satisfied":satisfied,"version":version}))
}

/// Uses only the installed definition's regular expression, never a tool-name branch.
pub(crate) fn check_version(input: &Value) -> Validation<Value> {
    fields(input, &["registry", "tool", "output", "minimumVersion"])?;
    let registry = definitions::registry(&input["registry"])?;
    let tool = input["tool"].as_str().ok_or_else(|| reject("tool"))?;
    let definition = enabled(&registry, tool).ok_or_else(|| reject("tool"))?;
    let output = input["output"].as_str().ok_or_else(|| reject("output"))?;
    let minimum = input
        .get("minimumVersion")
        .map(|value| value.as_str().ok_or_else(|| reject("minimumVersion")))
        .transpose()?;
    capture(definition, output, minimum)
}

/// Exposes both installation routes per tool: definition-owned scans the host expands,
/// and enabled providers the host queries. Native expansion and checks stay in hosts.
pub(crate) fn discovery_plan(input: &Value) -> Validation<Value> {
    fields(input, &["registry", "platform"])?;
    let registry = definitions::registry(&input["registry"])?;
    let platform = input["platform"]
        .as_str()
        .ok_or_else(|| reject("platform"))?;
    if !matches!(platform, "macos" | "windows" | "linux") {
        return Err(reject("platform"));
    }
    let tools = registry["definitions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|entry| {
            let definition = &entry["definition"];
            let scans: Vec<_> = definition["discovery"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|scan| applicable(scan, platform))
                .cloned()
                .collect();
            let providers: Vec<_> = registry["providers"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|provider| {
                    provider["provider"]["tools"]
                        .as_array()
                        .is_some_and(|tools| tools.contains(&definition["id"]))
                })
                .map(|provider| {
                    format!(
                        "{}:{}",
                        provider["pluginID"].as_str().unwrap_or(""),
                        provider["provider"]["id"].as_str().unwrap_or("")
                    )
                })
                .collect();
            // Login-shell home variables the host reads, with the layout each one selects.
            let environment: Vec<_> = definition["executables"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|value| value["kind"] == "environment" && applicable(value, platform))
                .map(|value| json!({"variable":value["variable"],"path":value.get("path")}))
                .collect();
            json!({"tool":definition["id"],"pluginID":entry["pluginID"],"scans":scans,"providers":providers,
            "homeLayouts":definition.get("homeLayouts").cloned().unwrap_or(json!([])),
            "executableLayouts":definition["executableLayouts"],"version":definition["version"],
            "pathPrepend":definition.get("pathPrepend").cloned().unwrap_or(json!([])),
            "environment":environment})
        })
        .collect::<Vec<_>>();
    Ok(json!({"tools":tools,"limits":{"roots":256,"entries":4096,"ancestors":64}}))
}

/// Provenance of homes found by expanding definition-owned `discovery` scans.
const SYSTEM_PROVIDER: &str = "host:system";

/// One canonical home reported by several routes stays one installation. A provider
/// answer outranks the host scan, then qualified provider IDs give a stable label;
/// the label never decides between different homes.
fn attribution(selection: &Value) -> (bool, &str) {
    let provider = selection["provider"].as_str().unwrap_or("");
    (provider == SYSTEM_PROVIDER, provider)
}

fn applicable(value: &Value, platform: &str) -> bool {
    value.get("platforms").is_none_or(|values| {
        values
            .as_array()
            .is_some_and(|values| values.iter().any(|value| value == platform))
    })
}

/// A host-side value snapshot is not a provider reply or a persisted launch permit.
struct Snapshot<'a> {
    input: &'a Value,
    definition: &'a Value,
    platform: &'a str,
    case_sensitive: bool,
    roots: Vec<String>,
    facts: &'a [Value],
    /// Resolved targets implied by link facts; canonical selections are looked up here.
    targets: Vec<Value>,
    probes: BTreeMap<String, Probe>,
    minimum: Option<&'a str>,
}

impl Snapshot<'_> {
    /// An explicit consumer choice precedes directory pins, but has exactly the
    /// same native version and project-code boundary as other checked candidates.
    fn fixed_selection(&self, fixed: &FixedToolchainSelection) -> Result<Value, &'static str> {
        match fixed {
            FixedToolchainSelection::Installation { home } => {
                self.selection(home, "host:manual", "pinned")
            }
            FixedToolchainSelection::Executable { executable } => {
                let fact = self.fact(executable, "file").map_err(|_| "notFound")?;
                if fact["executable"] != true {
                    return Err("notExecutable");
                }
                let canonical = fact["canonicalPath"].as_str().ok_or("unsafePath")?;
                let project = self.roots.iter().any(|root| {
                    paths::within(executable, root, self.platform, self.case_sensitive)
                        || paths::within(canonical, root, self.platform, self.case_sensitive)
                });
                if project && self.input["projectCodeAllowed"] != true {
                    return Err("projectCodeRequiresAction");
                }
                if self.definition["launch"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|token| token == "${home}")
                {
                    return Err("homeUnavailable");
                }
                let version = self.version(executable)?;
                self.environment_selection(
                    None,
                    executable,
                    Some(&version),
                    "host:manual",
                    "pinned",
                    project,
                )
            }
        }
    }

    fn key(&self, path: &str) -> Validation<String> {
        paths::normalize(path, self.platform, self.case_sensitive).ok_or_else(|| reject("path"))
    }

    fn fact(&self, path: &str, kind: &str) -> Validation<&Value> {
        let key = self.key(path)?;
        self.facts
            .iter()
            .chain(&self.targets)
            .find(|fact| {
                fact["path"]
                    .as_str()
                    .and_then(|path| self.key(path).ok())
                    .as_ref()
                    == Some(&key)
                    && fact["kind"] == kind
            })
            .ok_or_else(|| reject("filesystem"))
    }

    fn validate_facts(&self) -> Validation<()> {
        let mut identities = BTreeSet::new();
        for fact in self.facts {
            fields(fact, &["path", "canonicalPath", "kind", "executable"])?;
            let path = fact["path"]
                .as_str()
                .ok_or_else(|| reject("filesystem.path"))?;
            let canonical = fact["canonicalPath"]
                .as_str()
                .ok_or_else(|| reject("filesystem.canonicalPath"))?;
            self.key(canonical)?;
            if !identities.insert(self.key(path)?)
                || !matches!(
                    fact["kind"].as_str(),
                    Some("file" | "directory" | "missing")
                )
                || fact
                    .get("executable")
                    .is_some_and(|value| !value.is_boolean())
            {
                return Err(reject("filesystem"));
            }
        }
        for root in &self.roots {
            self.fact(root, "directory")?;
        }
        Ok(())
    }

    fn checked(&self, home: &str, layout: Option<&str>) -> Validation<Value> {
        query::validate_installation(
            home,
            self.definition,
            self.facts,
            &self.roots,
            self.platform,
            self.case_sensitive,
            layout,
        )
    }

    fn version(&self, executable: &str) -> Result<String, &'static str> {
        let key = self.key(executable).map_err(|_| "unsafePath")?;
        let probe = self.probes.get(&key).ok_or("probeFailed")?;
        if probe.exit_code != 0 {
            return Err("probeFailed");
        }
        let checked =
            capture(self.definition, &probe.output, self.minimum).map_err(|_| "probeFailed")?;
        if checked["satisfied"] != true {
            return Err("versionUnsatisfied");
        }
        checked["version"]
            .as_str()
            .map(str::to_owned)
            .ok_or("probeFailed")
    }

    fn selection(&self, home: &str, provider: &str, layer: &str) -> Result<Value, &'static str> {
        self.layout_selection(home, None, provider, layer)
    }

    /// Selects `home` through one declared executable layout, or the first present one.
    fn layout_selection(
        &self,
        home: &str,
        layout: Option<&str>,
        provider: &str,
        layer: &str,
    ) -> Result<Value, &'static str> {
        let checked = self.checked(home, layout).map_err(|_| "unsafePath")?;
        let executable = checked["executable"].as_str().ok_or("unsafePath")?;
        let version = self.version(executable)?;
        self.environment_selection(
            checked["home"].as_str(),
            executable,
            Some(&version),
            provider,
            layer,
            false,
        )
    }

    fn environment_selection(
        &self,
        home: Option<&str>,
        executable: &str,
        version: Option<&str>,
        provider: &str,
        layer: &str,
        project: bool,
    ) -> Result<Value, &'static str> {
        let mut environment = serde_json::Map::new();
        for export in self.definition["exports"].as_array().into_iter().flatten() {
            let value = match export["value"].as_str() {
                Some("${home}") => home,
                Some("${executable}") => Some(executable),
                _ => None,
            };
            if let Some(value) = value {
                environment.insert(
                    export["name"].as_str().ok_or("unsafePath")?.to_owned(),
                    json!(value),
                );
            }
        }
        let mut prepend = Vec::new();
        if let Some(home) = home {
            for template in self.definition["pathPrepend"]
                .as_array()
                .into_iter()
                .flatten()
            {
                let suffix = template
                    .as_str()
                    .and_then(|template| template.strip_prefix("${home}"))
                    .ok_or("unsafePath")?;
                let path = format!("{home}{suffix}");
                let fact = self.fact(&path, "directory").map_err(|_| "unsafePath")?;
                let canonical = fact["canonicalPath"].as_str().ok_or("unsafePath")?;
                if !paths::within(canonical, home, self.platform, self.case_sensitive) {
                    return Err("unsafePath");
                }
                prepend.push(canonical.to_owned());
            }
        }
        Ok(
            json!({"home":home,"executable":executable,"version":version,"provider":provider,
            "layer":layer,"projectCode":project,"environment":environment,"pathPrepend":prepend}),
        )
    }
}

fn reason(code: &str, tool: &str) -> Value {
    json!({"code":code,"tool":tool})
}

fn trace(trace: &mut Vec<Value>, id: &str, layer: &str, state: &str, reason: Option<Value>) {
    let mut row = json!({"candidateID":id,"layer":layer,"state":state});
    if let Some(reason) = reason {
        row["reason"] = reason;
    }
    trace.push(row);
}

fn output(
    input: &Value,
    outcome: Value,
    trace: Vec<Value>,
    unmet: Vec<Value>,
    conflicts: Vec<Value>,
) -> Value {
    json!({"operationID":input["operationID"],"tool":input["tool"],"directory":input["directory"],
        "outcome":outcome,"trace":trace,"unmet":unmet,"conflicts":conflicts})
}

/// Project sources are merged before attempting a candidate; distance wins over kind.
struct ProjectChoice {
    anchor: String,
    category: u8,
    native: bool,
    value: Value,
    candidate: bool,
}

fn ancestors(directory: &str) -> Vec<&str> {
    let mut result = vec![directory];
    let mut current = directory;
    while current != "." && result.len() < 64 {
        current = current.rsplit_once('/').map_or(".", |(parent, _)| parent);
        result.push(current);
    }
    result
}

fn project_selection(
    snapshot: &Snapshot<'_>,
    choice: &ProjectChoice,
) -> Result<Value, &'static str> {
    if !choice.candidate {
        let home = choice.value["installation"]
            .as_str()
            .ok_or("requestedNotInstalled")?;
        return snapshot.selection(
            home,
            choice.value["provider"].as_str().unwrap_or(""),
            "project",
        );
    }
    if snapshot.input["projectCodeAllowed"] != true {
        return Err("projectCodeRequiresAction");
    }
    let path = choice.value["nativePath"].as_str().ok_or("unsafePath")?;
    let file = snapshot.fact(path, "file").map_err(|_| "notFound")?;
    if file["executable"] != true {
        return Err("notExecutable");
    }
    let canonical = file["canonicalPath"].as_str().ok_or("unsafePath")?;
    if snapshot.key(canonical).map_err(|_| "unsafePath")?
        != snapshot.key(path).map_err(|_| "unsafePath")?
    {
        // Native link-chain identities are not available in this Core-only slice.
        return Err("unsafePath");
    }
    let home = choice.value["nativeHome"].as_str();
    if let Some(home) = home {
        let fact = snapshot.fact(home, "directory").map_err(|_| "unsafePath")?;
        let canonical_home = fact["canonicalPath"].as_str().ok_or("unsafePath")?;
        if snapshot.key(canonical_home).map_err(|_| "unsafePath")?
            != snapshot.key(home).map_err(|_| "unsafePath")?
            || !snapshot.roots.iter().any(|root| {
                paths::within(
                    canonical_home,
                    root,
                    snapshot.platform,
                    snapshot.case_sensitive,
                )
            })
        {
            return Err("unsafePath");
        }
    }
    // A lexical project path must never turn into a provider-owned installation.
    if !snapshot
        .roots
        .iter()
        .any(|root| paths::within(path, root, snapshot.platform, snapshot.case_sensitive))
    {
        return Err("unsafePath");
    }
    if home.is_none()
        && snapshot.definition["launch"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|token| token == "${home}")
    {
        return Err("homeUnavailable");
    }
    // Preserve the lexical interpreter path for project environments (including venv).
    let version = match snapshot.version(path) {
        Ok(version) => Some(version),
        Err(code) if snapshot.minimum.is_some() => return Err(code),
        Err(_) => None,
    };
    snapshot.environment_selection(
        home,
        path,
        version.as_deref(),
        "host:project",
        "project",
        true,
    )
}

/// Validates the native evidence shared by resolution and candidate listing: platform
/// and case policy, workspace roots, filesystem facts and bounded probe outputs.
fn prepare<'a>(input: &'a Value, definition: &'a Value) -> Validation<(Snapshot<'a>, String)> {
    let platform = input["platform"]
        .as_str()
        .filter(|platform| matches!(*platform, "macos" | "windows" | "linux"))
        .ok_or_else(|| reject("platform"))?;
    let case_sensitive = input
        .get("filesystemCaseSensitive")
        .map(|value| {
            value
                .as_bool()
                .ok_or_else(|| reject("filesystemCaseSensitive"))
        })
        .transpose()?
        .unwrap_or(platform != "windows");
    let root = input["workspaceRoot"]
        .as_str()
        .and_then(|root| paths::normalize(root, platform, true))
        .ok_or_else(|| reject("workspaceRoot"))?;
    let mut roots = vec![root.clone()];
    for value in array(input, "workspaceRoots", 64)? {
        roots.push(
            value
                .as_str()
                .ok_or_else(|| reject("workspaceRoots"))?
                .to_owned(),
        );
    }
    let facts = array(input, "filesystem", 16384)?;
    let minimum = input
        .get("minimumVersion")
        .map(|value| {
            value
                .as_str()
                .filter(|value| components(value).is_some())
                .ok_or_else(|| reject("minimumVersion"))
        })
        .transpose()?;
    let mut probes = BTreeMap::new();
    for value in array(input, "probes", 1024)? {
        let probe: Probe = serde_json::from_value(value.clone()).map_err(|_| reject("probes"))?;
        if probe.output.len() > 128 * 1024 {
            return Err(reject("probes.output"));
        }
        let key = paths::normalize(&probe.executable, platform, case_sensitive)
            .ok_or_else(|| reject("probes.executable"))?;
        if probes.insert(key, probe).is_some() {
            return Err(reject("probes"));
        }
    }
    let mut snapshot = Snapshot {
        input,
        definition,
        platform,
        case_sensitive,
        roots,
        facts,
        targets: Vec::new(),
        probes,
        minimum,
    };
    snapshot.validate_facts()?;
    snapshot.targets = query::implied_targets(facts, platform, case_sensitive)
        .map_err(|_| reject("filesystem"))?;
    if snapshot.key(
        snapshot.fact(&root, "directory")?["canonicalPath"]
            .as_str()
            .ok_or_else(|| reject("workspaceRoot"))?,
    )? != snapshot.key(&root)?
    {
        return Err(reject("workspaceRoot"));
    }
    Ok((snapshot, root))
}

/// Host-observed string maps (login-shell variables, command homes, explicit choices).
fn string_maps(input: &Value, keys: &[&str]) -> Validation<()> {
    for key in keys {
        if let Some(value) = input.get(*key) {
            let map = value
                .as_object()
                .filter(|map| map.len() <= 256)
                .ok_or_else(|| reject(key))?;
            if map.values().any(|value| {
                !value
                    .as_str()
                    .is_some_and(|value| value.is_empty() || bounded(value, 4096))
            }) {
                return Err(reject(key));
            }
        }
    }
    Ok(())
}

/// Homes the host found by expanding this tool's `discovery` scans.
fn system_installations(input: &Value, tool: &str) -> Validation<Vec<Value>> {
    let mut installations = Vec::new();
    for value in array(input, "systemInstallations", 512)? {
        fields(value, &["tool", "home"])?;
        if value["tool"] == tool {
            let home = value["home"]
                .as_str()
                .ok_or_else(|| reject("systemInstallations"))?;
            installations.push(json!({"tool":tool,"home":home,"provider":SYSTEM_PROVIDER}));
        }
    }
    Ok(installations)
}

/// Homes `toolchains.decodeReply` accepted from a provider declaring `tool`, kept
/// under that provider's identity; one the registry does not list is refused.
fn provider_installations(input: &Value, tool: &str, registry: &Value) -> Validation<Vec<Value>> {
    let mut installations = Vec::new();
    for value in array(input, "providerInstallations", 512)? {
        fields(value, &["tool", "home", "provider"])?;
        if value["tool"] != tool {
            continue;
        }
        let home = value["home"]
            .as_str()
            .ok_or_else(|| reject("providerInstallations"))?;
        let provider = value["provider"]
            .as_str()
            .and_then(|provider| provider.rsplit_once(':'))
            .filter(|(plugin, provider)| {
                registry["providers"].as_array().is_some_and(|entries| {
                    entries.iter().any(|entry| {
                        entry["pluginID"] == *plugin
                            && entry["provider"]["id"] == *provider
                            && entry["provider"]["tools"]
                                .as_array()
                                .is_some_and(|tools| tools.iter().any(|known| known == tool))
                    })
                })
            })
            .ok_or_else(|| reject("providerInstallations"))?;
        installations.push(
            json!({"tool":tool,"home":home,"provider":format!("{}:{}", provider.0, provider.1)}),
        );
    }
    Ok(installations)
}

/// The automatic layer's candidate set, keyed by canonical home.
struct Automatic {
    eligible: BTreeMap<String, Value>,
    /// Reported installations that failed a check, with the executable to probe when
    /// the layout itself was valid.
    skipped: BTreeMap<String, Value>,
    failure: Option<&'static str>,
}

fn automatic_set(snapshot: &Snapshot<'_>, installations: &[Value]) -> Validation<Automatic> {
    let mut set = Automatic {
        eligible: BTreeMap::new(),
        skipped: BTreeMap::new(),
        failure: None,
    };
    for installation in installations {
        let Some(home) = installation["home"].as_str() else {
            continue;
        };
        let provider = installation["provider"].as_str().unwrap_or("");
        match snapshot.selection(home, provider, "automatic") {
            Ok(value) => {
                let key = snapshot.key(value["home"].as_str().unwrap_or(""))?;
                if set
                    .eligible
                    .get(&key)
                    .is_none_or(|kept: &Value| attribution(&value) < attribution(kept))
                {
                    set.eligible.insert(key, value);
                }
            }
            Err(code) => {
                set.failure = Some(code);
                let checked = snapshot.checked(home, None).ok();
                let canonical = checked
                    .as_ref()
                    .and_then(|value| value["home"].as_str())
                    .unwrap_or(home);
                let mut row = json!({"home":canonical,"provider":provider,"reason":code});
                if let Some(executable) = checked.as_ref().map(|value| &value["executable"]) {
                    row["executable"] = executable.clone();
                }
                let key = snapshot
                    .key(canonical)
                    .unwrap_or_else(|_| canonical.to_owned());
                if set
                    .skipped
                    .get(&key)
                    .is_none_or(|kept: &Value| attribution(&row) < attribution(kept))
                {
                    set.skipped.insert(key, row);
                }
            }
        }
    }
    set.skipped.retain(|key, _| !set.eligible.contains_key(key));
    Ok(set)
}

/// Picks the highest version; equal highest versions in different homes need `chosen`,
/// otherwise they become an `automatic` conflict naming every route.
fn automatic_choice(
    snapshot: &Snapshot<'_>,
    eligible: BTreeMap<String, Value>,
    chosen: Option<&str>,
) -> Validation<(Option<Value>, Option<Value>)> {
    let newest = eligible
        .values()
        .filter_map(|value| components(value["version"].as_str()?))
        .max();
    let mut best: Vec<_> = eligible
        .into_values()
        .filter(|value| value["version"].as_str().and_then(components) == newest)
        .collect();
    if best.len() <= 1 {
        return Ok((best.pop(), None));
    }
    if let Some(chosen) = chosen {
        let identity = snapshot.key(chosen)?;
        let selected = best
            .iter()
            .find(|value| {
                value["home"]
                    .as_str()
                    .and_then(|home| snapshot.key(home).ok())
                    .as_ref()
                    == Some(&identity)
            })
            .cloned();
        if selected.is_some() {
            return Ok((selected, None));
        }
    }
    let providers: BTreeSet<_> = best
        .iter()
        .filter_map(|value| value["provider"].as_str())
        .collect();
    let installations: Vec<_> = best.iter().map(|value| value["home"].clone()).collect();
    Ok((
        None,
        Some(
            json!({"scope":"automatic","providers":providers,"installations":installations,
            "action":"chooseInstallation"}),
        ),
    ))
}

/// Lists what a settings page shows for one tool's global and automatic layers without
/// resolving a directory: login-shell homes and the discovered installations with their
/// checked executables, versions or skip reasons, and Core's automatic choice. Hosts
/// probe only the executables returned here, then call again with `probes`.
pub(crate) fn candidates(input: &Value) -> Validation<Value> {
    fields(
        input,
        &[
            "registry",
            "tool",
            "platform",
            "filesystemCaseSensitive",
            "workspaceRoot",
            "workspaceRoots",
            "filesystem",
            "minimumVersion",
            "probes",
            "systemInstallations",
            "providerInstallations",
            "fixed",
            "projectCodeAllowed",
            "environment",
        ],
    )?;
    let registry = definitions::registry(&input["registry"])?;
    let tool = input["tool"]
        .as_str()
        .filter(|tool| definitions::tool_id(tool))
        .ok_or_else(|| reject("tool"))?;
    let definition = enabled(&registry, tool).ok_or_else(|| reject("tool"))?;
    let (snapshot, _) = prepare(input, definition)?;
    if input
        .get("projectCodeAllowed")
        .is_some_and(|value| !value.is_boolean())
    {
        return Err(reject("projectCodeAllowed"));
    }
    string_maps(input, &["environment"])?;
    let mut shell = Vec::new();
    for candidate in definition["executables"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|value| value["kind"] == "environment" && applicable(value, snapshot.platform))
    {
        let Some(variable) = candidate["variable"].as_str() else {
            continue;
        };
        let Some(home) = input["environment"][variable]
            .as_str()
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let layout = candidate["path"].as_str();
        let mut row = json!({"candidateID":candidate["id"],"variable":variable,"home":home});
        if let Ok(checked) = snapshot.checked(home, layout) {
            row["home"] = checked["home"].clone();
            row["executable"] = checked["executable"].clone();
        }
        match snapshot.layout_selection(home, layout, "host:shell", "global") {
            Ok(value) => row["version"] = value["version"].clone(),
            Err(code) => row["reason"] = json!(code),
        }
        shell.push(row);
    }
    let mut reported = provider_installations(input, tool, &registry)?;
    reported.extend(system_installations(input, tool)?);
    let set = automatic_set(&snapshot, &reported)?;
    let mut installations: Vec<_> = set
        .eligible
        .values()
        .map(|value| {
            json!({"home":value["home"],"executable":value["executable"],
                "version":value["version"],"provider":value["provider"]})
        })
        .collect();
    installations.sort_by(|left, right| {
        let version = |value: &Value| value["version"].as_str().and_then(components);
        version(right)
            .cmp(&version(left))
            .then_with(|| left["home"].as_str().cmp(&right["home"].as_str()))
    });
    let mut skipped: Vec<_> = set.skipped.into_values().collect();
    if let Some(value) = input.get("fixed") {
        let fixed = FixedToolchainSelection::parse(value)?;
        let executable = match &fixed {
            FixedToolchainSelection::Installation { home } => snapshot
                .checked(home, None)
                .ok()
                .and_then(|value| value["executable"].as_str().map(str::to_owned)),
            FixedToolchainSelection::Executable { executable } => snapshot
                .fact(executable, "file")
                .ok()
                .filter(|fact| fact["executable"] == true)
                .map(|_| executable.clone()),
        };
        if let Err(code) = snapshot.fixed_selection(&fixed) {
            let mut row = json!({"reason":code});
            // A project program is not a probe target without the current action.
            if code == "probeFailed" {
                if let Some(executable) = executable {
                    row["executable"] = json!(executable);
                }
            }
            skipped.push(row);
        }
    }
    let (selected, conflict) = automatic_choice(&snapshot, set.eligible, None)?;
    Ok(
        json!({"tool":tool,"shell":shell,"installations":installations,"skipped":skipped,
        "selected":selected.map(|value| value["home"].clone()),
        "conflicts":conflict.into_iter().collect::<Vec<_>>()}),
    )
}

/// Resolves definitions, provider replies, pins and trusted native observations once.
pub(crate) fn resolve(input: &Value) -> Validation<Value> {
    fields(
        input,
        &[
            "registry",
            "tool",
            "directory",
            "operationID",
            "local",
            "platform",
            "filesystemCaseSensitive",
            "workspaceRoot",
            "workspaceRoots",
            "filesystem",
            "minimumVersion",
            "probes",
            "queries",
            "systemInstallations",
            "globalDefault",
            "environment",
            "commandHomes",
            "projectCodeAllowed",
            "providerChoices",
            "generation",
            "context",
            "fixed",
        ],
    )?;
    let registry = definitions::registry(&input["registry"])?;
    let tool = input["tool"]
        .as_str()
        .filter(|tool| definitions::tool_id(tool))
        .ok_or_else(|| reject("tool"))?;
    let directory = input["directory"]
        .as_str()
        .ok_or_else(|| reject("directory"))?;
    input["operationID"]
        .as_str()
        .filter(|value| bounded(value, 128))
        .ok_or_else(|| reject("operationID"))?;
    let document = input
        .get("local")
        .cloned()
        .unwrap_or(json!({"version":1,"toolchains":{}}));
    let pin = pins::resolve(&json!({"document":document,"directory":directory,"tool":tool}))?;
    let fixed = input
        .get("fixed")
        .map(FixedToolchainSelection::parse)
        .transpose()?;
    let Some(definition) = enabled(&registry, tool) else {
        return Ok(output(
            input,
            json!({"kind":"skip","reason":reason("definitionUnavailable",tool)}),
            vec![],
            vec![],
            vec![],
        ));
    };
    let generation = input["generation"]
        .as_u64()
        .filter(|value| *value > 0)
        .ok_or_else(|| reject("generation"))?;
    let (snapshot, root) = prepare(input, definition)?;
    let platform = snapshot.platform;
    let case_sensitive = snapshot.case_sensitive;
    if input
        .get("projectCodeAllowed")
        .is_some_and(|value| !value.is_boolean())
    {
        return Err(reject("projectCodeAllowed"));
    }
    string_maps(input, &["environment", "commandHomes", "providerChoices"])?;
    if let Some(choices) = input.get("providerChoices") {
        fields(choices, &["project", "global", "automatic"])?;
    }
    if let Some(fixed) = fixed {
        return Ok(match snapshot.fixed_selection(&fixed) {
            Ok(selection) => output(
                input,
                json!({"kind":"resolved","selection":selection}),
                vec![json!({"candidateID":"consumerFixed","layer":"pinned","state":"resolved"})],
                vec![],
                vec![],
            ),
            Err(code) => output(
                input,
                json!({"kind":"terminalFailure","reason":reason(code,tool)}),
                vec![
                    json!({"candidateID":"consumerFixed","layer":"pinned","state":"terminalFailure","reason":reason(code,tool)}),
                ],
                vec![],
                vec![],
            ),
        });
    }
    // A failed optional provider must never revoke a usable explicit fixed value.
    if let Some(home) = pin["pin"]["home"].as_str() {
        let result = snapshot.selection(
            home,
            pin["pin"]["provider"].as_str().unwrap_or(""),
            "pinned",
        );
        return Ok(match result {
            Ok(selection) => output(
                input,
                json!({"kind":"resolved","selection":selection}),
                vec![json!({"candidateID":"pinned","layer":"pinned","state":"resolved"})],
                vec![],
                vec![],
            ),
            Err(code) => output(
                input,
                json!({"kind":"terminalFailure","reason":reason(code,tool)}),
                vec![
                    json!({"candidateID":"pinned","layer":"pinned","state":"terminalFailure","reason":reason(code,tool)}),
                ],
                vec![],
                vec![],
            ),
        });
    }
    let mut installations = Vec::new();
    let mut statements = Vec::new();
    let mut unmet = Vec::new();
    let mut query_providers = BTreeSet::new();
    for value in array(input, "queries", 256)? {
        if value["registry"] != input["registry"] {
            return Err(reject("queries.registry"));
        }
        if value["platform"] != platform {
            return Err(reject("queries.platform"));
        }
        if value["request"]["params"]["workspace"]["root"]
            .as_str()
            .and_then(|path| snapshot.key(path).ok())
            != Some(snapshot.key(&root)?)
        {
            return Err(reject("queries.workspace"));
        }
        let requested_directory = value["request"]["params"]["workspace"]["directory"]
            .as_str()
            .unwrap_or("");
        if requested_directory != directory {
            return Err(reject("queries.directory"));
        }
        if value["filesystem"] != input["filesystem"] {
            return Err(reject("queries.filesystem"));
        }
        let query_case = value
            .get("filesystemCaseSensitive")
            .and_then(Value::as_bool)
            .unwrap_or(platform != "windows");
        if query_case != case_sensitive
            || value.get("workspaceRoots") != input.get("workspaceRoots")
        {
            return Err(reject("queries.filesystemPolicy"));
        }
        if value["currentGeneration"].as_u64() != Some(generation) {
            return Err(reject("queries.generation"));
        }
        if value["request"]["params"]["context"] != input["context"] {
            return Err(reject("queries.context"));
        }
        if !query_providers.insert((
            value["pluginID"].to_string(),
            value["request"]["params"]["providerID"].to_string(),
        )) {
            return Err(reject("queries.providerID"));
        }
        let decoded = match query::decode(value) {
            Ok(decoded) => decoded,
            Err(error)
                if matches!(
                    error.code,
                    "plugin.toolchain.timeout" | "plugin.toolchain.providerUnavailable"
                ) =>
            {
                // Only a provider asked about this tool leaves it without an answer; `cause`
                // keeps a missed deadline apart from a backend that could not answer at all.
                if value["request"]["params"]["tools"]
                    .as_array()
                    .is_some_and(|tools| tools.iter().any(|asked| asked == tool))
                {
                    unmet.push(json!({"code":"providerUnavailable","tool":tool,
                        "provider":format!("{}:{}",value["pluginID"].as_str().unwrap_or(""),value["request"]["params"]["providerID"].as_str().unwrap_or("")),
                        "cause":error.code}));
                }
                continue;
            }
            Err(error) => return Err(error),
        };
        installations.extend(
            decoded["installations"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|value| value["tool"] == tool)
                .cloned(),
        );
        statements.extend(
            decoded["statements"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|value| value["tool"] == tool)
                .cloned(),
        );
        unmet.extend(
            decoded["diagnostics"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|value| value["tool"] == tool && value["code"] != "requestedNotInstalled")
                .cloned(),
        );
    }
    installations.extend(system_installations(input, tool)?);
    let candidates: Vec<_> = definition["executables"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|value| applicable(value, platform))
        .collect();
    let mut trace_rows = Vec::new();
    let mut conflicts = Vec::new();
    let mut outcome = None;
    let mut project_done = false;
    if let Some(default) = input.get("globalDefault").filter(|value| !value.is_null()) {
        fields(default, &["home"])?;
        default["home"]
            .as_str()
            .filter(|value| bounded(value, 4096))
            .ok_or_else(|| reject("globalDefault.home"))?;
    }
    // Explicit application defaults obey the same terminal policy without a plugin slot.
    let default_preflight = input
        .get("globalDefault")
        .filter(|value| !value.is_null())
        .is_some()
        && !candidates
            .iter()
            .any(|value| value["kind"] == "setting" && value["layer"] == "global");
    let mut default_checked = !default_preflight;
    for candidate in &candidates {
        let kind = candidate["kind"].as_str().unwrap_or("");
        let id = candidate["id"].as_str().unwrap_or(kind);
        let layer = match kind {
            "setting" if candidate["layer"] == "project" => "pinned",
            "projectFile" => "project",
            "toolchain" if candidate["scope"] == "project" => "project",
            "toolchain" if candidate["scope"] == "installed" => "automatic",
            _ => "global",
        };
        if !default_checked && matches!(layer, "global" | "automatic") && outcome.is_none() {
            default_checked = true;
            let home = input["globalDefault"]["home"]
                .as_str()
                .ok_or_else(|| reject("globalDefault"))?;
            let result = snapshot.selection(home, "host:default", "global");
            outcome = Some(match result {
                Ok(selection) => json!({"kind":"resolved","selection":selection}),
                Err(code) => json!({"kind":"terminalFailure","reason":reason(code,tool)}),
            });
        }
        if outcome.is_some() {
            trace(&mut trace_rows, id, layer, "shadowed", None);
            continue;
        }
        let mut selected = None;
        let mut failure = None;
        let mut terminal = false;
        match (kind, layer) {
            ("setting", "pinned") => {
                if let Some(home) = pin["pin"]["home"].as_str() {
                    match snapshot.selection(
                        home,
                        pin["pin"]["provider"].as_str().unwrap_or(""),
                        layer,
                    ) {
                        Ok(value) => selected = Some(value),
                        Err(code) => {
                            failure = Some(reason(code, tool));
                            terminal = true;
                        }
                    }
                }
            }
            ("setting", _) => {
                if let Some(value) = input.get("globalDefault").filter(|value| !value.is_null()) {
                    let home = value["home"]
                        .as_str()
                        .ok_or_else(|| reject("globalDefault"))?;
                    match snapshot.selection(home, "host:default", layer) {
                        Ok(value) => selected = Some(value),
                        Err(code) => {
                            failure = Some(reason(code, tool));
                            terminal = true;
                        }
                    }
                }
            }
            (_, "project") if !project_done => {
                project_done = true;
                let mut choices = Vec::new();
                for source in &candidates {
                    if source["kind"] != "projectFile" {
                        continue;
                    }
                    for ancestor in ancestors(directory) {
                        let anchor = if ancestor == "." {
                            root.clone()
                        } else {
                            paths::join(&root, ancestor, platform)
                                .ok_or_else(|| reject("directory"))?
                        };
                        let native =
                            paths::join(&anchor, source["path"].as_str().unwrap_or(""), platform)
                                .ok_or_else(|| reject("projectFile"))?;
                        if snapshot.fact(&native, "file").is_err() {
                            continue;
                        }
                        let markers =
                            source["requires"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .all(|marker| {
                                    marker
                                        .as_str()
                                        .and_then(|marker| paths::join(&anchor, marker, platform))
                                        .is_some_and(|path| snapshot.fact(&path, "file").is_ok())
                                });
                        if !markers {
                            continue;
                        }
                        let mut value = (*source).clone();
                        value["nativePath"] = json!(native);
                        if let Some(home) = source["home"].as_str() {
                            value["nativeHome"] = json!(if home == "." {
                                anchor.clone()
                            } else {
                                paths::join(&anchor, home, platform)
                                    .ok_or_else(|| reject("projectFile.home"))?
                            });
                        }
                        choices.push(ProjectChoice {
                            anchor,
                            category: if source["projectKind"] == "environment" {
                                1
                            } else {
                                0
                            },
                            native: true,
                            value,
                            candidate: true,
                        });
                    }
                }
                if candidates
                    .iter()
                    .any(|value| value["kind"] == "toolchain" && value["scope"] == "project")
                {
                    for statement in statements
                        .iter()
                        .filter(|value| value["scope"] == "project")
                    {
                        let anchor = statement["sourceDirectory"]
                            .as_str()
                            .ok_or_else(|| reject("statements.sourceDirectory"))?;
                        choices.push(ProjectChoice {
                            anchor: anchor.to_owned(),
                            category: if statement["kind"] == "environment" {
                                1
                            } else {
                                2
                            },
                            native: statement["reader"] == "native",
                            value: statement.clone(),
                            candidate: false,
                        });
                    }
                }
                choices.sort_by_key(|value| {
                    (
                        std::cmp::Reverse(value.anchor.split('/').count()),
                        value.category,
                    )
                });
                // The nearest declaration masks inherited declarations even when unmet.
                if let Some(nearest) = choices.first().map(|value| value.anchor.split('/').count())
                {
                    choices.retain(|value| value.anchor.split('/').count() == nearest);
                }
                while let Some(first) = choices.first() {
                    let depth = first.anchor.split('/').count();
                    let category = first.category;
                    let count = choices
                        .iter()
                        .take_while(|value| {
                            value.anchor.split('/').count() == depth && value.category == category
                        })
                        .count();
                    let mut group: Vec<_> = choices.drain(..count).collect();
                    let native_sources: BTreeSet<_> = group
                        .iter()
                        .filter(|value| value.native && !value.candidate)
                        .map(|value| value.value["source"].clone().to_string())
                        .collect();
                    group.retain(|value| {
                        value.native || !native_sources.contains(&value.value["source"].to_string())
                    });
                    let homes: BTreeSet<_> = group
                        .iter()
                        .filter_map(|value| value.value["installation"].as_str().map(str::to_owned))
                        .collect();
                    let requests: BTreeSet<_> = group
                        .iter()
                        .filter(|value| !value.candidate)
                        .map(|value| {
                            (
                                value.value["request"].to_string(),
                                value.value["installation"].to_string(),
                            )
                        })
                        .collect();
                    let choice = input["providerChoices"]["project"].as_str();
                    if let Some(chosen) = choice {
                        group.retain(|value| value.candidate || value.value["provider"] == chosen);
                    }
                    let retained: BTreeSet<_> = group
                        .iter()
                        .filter(|value| !value.candidate)
                        .map(|value| {
                            (
                                value.value["request"].to_string(),
                                value.value["installation"].to_string(),
                            )
                        })
                        .collect();
                    if (choice.is_none() && (homes.len() > 1 || requests.len() > 1))
                        || retained.len() > 1
                    {
                        let providers: BTreeSet<_> = group
                            .iter()
                            .filter_map(|value| value.value["provider"].as_str())
                            .collect();
                        conflicts.push(json!({"scope":"project","providers":providers,"action":"chooseProvider"}));
                        failure = Some(reason("providerConflict", tool));
                        break;
                    }
                    for choice in &group {
                        match project_selection(&snapshot, choice) {
                            Ok(value) => {
                                selected = Some(value);
                                break;
                            }
                            Err(code) => {
                                let mut why = reason(code, tool);
                                for key in ["provider", "source", "request"] {
                                    if let Some(value) = choice.value.get(key) {
                                        why[key] = value.clone();
                                    }
                                }
                                if code == "requestedNotInstalled" && !unmet.contains(&why) {
                                    unmet.push(why.clone());
                                }
                                failure = Some(why);
                            }
                        }
                    }
                    if selected.is_some() {
                        break;
                    }
                }
            }
            (_, "project") => continue,
            ("toolchain", "global") => {
                let globals: Vec<_> = statements
                    .iter()
                    .filter(|value| value["scope"] == "global")
                    .collect();
                let chosen = input["providerChoices"]["global"].as_str();
                let globals: Vec<_> = globals
                    .into_iter()
                    .filter(|value| chosen.is_none_or(|chosen| value["provider"] == chosen))
                    .collect();
                let homes: BTreeSet<_> = globals
                    .iter()
                    .filter_map(|value| value["installation"].as_str())
                    .collect();
                let requests: BTreeSet<_> = globals
                    .iter()
                    .map(|value| {
                        (
                            value["request"].to_string(),
                            value["installation"].to_string(),
                        )
                    })
                    .collect();
                if homes.len() > 1 || requests.len() > 1 {
                    let providers: BTreeSet<_> = globals
                        .iter()
                        .filter_map(|value| value["provider"].as_str())
                        .collect();
                    conflicts.push(
                        json!({"scope":"global","providers":providers,"action":"chooseProvider"}),
                    );
                    failure = Some(reason("providerConflict", tool));
                } else if let Some(value) = globals.first() {
                    if let Some(home) = value["installation"].as_str() {
                        match snapshot.selection(
                            home,
                            value["provider"].as_str().unwrap_or(""),
                            layer,
                        ) {
                            Ok(value) => selected = Some(value),
                            Err(code) => failure = Some(reason(code, tool)),
                        }
                    } else {
                        let why = json!({"code":"requestedNotInstalled","tool":tool,"provider":value["provider"],"source":value["source"],"request":value["request"]});
                        unmet.push(why.clone());
                        failure = Some(why);
                    }
                }
            }
            ("toolchain", "automatic") => {
                let set = automatic_set(&snapshot, &installations)?;
                failure = set.failure.map(|code| reason(code, tool));
                let (choice, conflict) = automatic_choice(
                    &snapshot,
                    set.eligible,
                    input["providerChoices"]["automatic"].as_str(),
                )?;
                selected = choice;
                if let Some(conflict) = conflict {
                    conflicts.push(conflict);
                    failure = Some(reason("ambiguousInstallation", tool));
                }
            }
            ("environment", _) => {
                if let Some(home) = candidate["variable"]
                    .as_str()
                    .and_then(|name| input["environment"][name].as_str())
                    .filter(|value| !value.is_empty())
                {
                    match snapshot.layout_selection(
                        home,
                        candidate["path"].as_str(),
                        "host:shell",
                        layer,
                    ) {
                        Ok(value) => selected = Some(value),
                        Err(code) => failure = Some(reason(code, tool)),
                    }
                }
            }
            ("command", _) => {
                if let Some(home) = candidate["command"]
                    .as_str()
                    .and_then(|name| input["commandHomes"][name].as_str())
                {
                    match snapshot.selection(home, "host:shell", layer) {
                        Ok(value) => selected = Some(value),
                        Err(code) => failure = Some(reason(code, tool)),
                    }
                }
            }
            _ => return Err(reject("executables.kind")),
        }
        if let Some(selection) = selected {
            trace(&mut trace_rows, id, layer, "resolved", None);
            outcome = Some(json!({"kind":"resolved","selection":selection}));
        } else if let Some(why) = failure {
            trace(
                &mut trace_rows,
                id,
                layer,
                if terminal { "terminalFailure" } else { "skip" },
                Some(why.clone()),
            );
            if terminal {
                outcome = Some(json!({"kind":"terminalFailure","reason":why}));
            }
        } else {
            trace(&mut trace_rows, id, layer, "empty", None);
        }
    }
    if outcome.is_none() && !default_checked {
        let home = input["globalDefault"]["home"]
            .as_str()
            .ok_or_else(|| reject("globalDefault"))?;
        outcome = Some(match snapshot.selection(home, "host:default", "global") {
            Ok(selection) => json!({"kind":"resolved","selection":selection}),
            Err(code) => json!({"kind":"terminalFailure","reason":reason(code,tool)}),
        });
    }
    Ok(output(
        input,
        outcome.unwrap_or_else(|| json!({"kind":"skip","reason":reason("notFound",tool)})),
        trace_rows,
        unmet,
        conflicts,
    ))
}
