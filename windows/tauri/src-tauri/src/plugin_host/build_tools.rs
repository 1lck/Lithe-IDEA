//! Native executable discovery for Core-planned Build invocations.
//! Saved choices and version semantics belong to Core; this adapter reuses the
//! Run toolchain registry, filesystem discovery and bounded native probes.

use super::{build, launch, lifecycle::LifecycleState, scan::core_execute, settings, store};
use crate::run::{self, LaunchExecutable, ResolveLaunchArgs};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager, Window};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildToolContext {
    /// The accepted package used for this resolution; plans must use this exact
    /// declaration rather than a stale frontend catalog copy.
    pub manifest: Value,
    /// Exact stored inputs also revoke a model when a backend setting changes.
    pub identity: Value,
    pub plugin_directory: String,
    pub workspace_state_directory: String,
    /// Only selected runtime and explicitly declared environment inputs cross RPC.
    pub environment: BTreeMap<String, String>,
    pub tool: Value,
    /// Only freshly resolved definition IDs are bound; legacy Run preferences
    /// cannot supply or replace these executable paths at the process handoff.
    pub resolved_executables: BTreeMap<String, String>,
    pub executes_project_code: bool,
}

/// Resolves one instance through current declarations and bounded native probes.
/// Only explicit execution may probe or select a project-owned launcher.
#[tauri::command]
pub async fn declarative_plugins_build_tool(
    app: AppHandle,
    window: Window,
    operation_id: String,
    plugin_id: String,
    build_system_id: String,
    workspace_path: String,
    root: String,
    check_versions: bool,
    configuration_id: Option<String>,
) -> Result<BuildToolContext, String> {
    let operation = super::toolchain_preparation::claim(&app, &window, &operation_id)?;
    crate::blocking::run_blocking(move || {
        let current = || {
            operation.current()?;
            if app.get_webview_window(window.label()).is_none() {
                return Err("toolchain.native.cancelled".into());
            }
            Ok(())
        };
        current()?;
        let _lease = app.state::<LifecycleState>().acquire(&plugin_id)?;
        let package = launch::package_by_id(&app, &plugin_id).ok_or("Build plugin is unavailable")?;
        // Core combines canonical reactor choices and explicit Run overrides.
        // The platform does not maintain another inheritance or path policy.
        let choices = core_execute("runConfig.projectToolchain", json!({"root":workspace_path,"path":root,"configurationId":configuration_id}))?;
        let layers = settings::load_layers(&app, &plugin_id, &workspace_path)?;
        let payload = |request| json!({"manifest":package.manifest,"buildSystemID":build_system_id,"request":request});
        let planned = core_execute("build.invocationPlan", payload(json!({"root":root,"platform":"windows","settings":layers.global})))?;
        if planned["status"] != "ok" { return Err(format!("Build invocation rejected: {}", planned["error"]["message"])); }
        let invocation = &planned["invocation"];
        let (tool_registry, _tool_leases) = installed_tool_registry(&app)?;
        let normalized_tools = core_execute("toolchains.registry", tool_registry.clone())?;
        if normalized_tools["status"] != "ok" { return Err("toolchain.native.unavailable".into()); }
        let workspace = std::fs::canonicalize(&workspace_path).map_err(|error| error.to_string())?;
        let state = build::build_state_directory(&store::plugin_state_directory(&app, &plugin_id)?, &build_system_id)?;
        let workspace_state = state.join(build::build_workspace_key(&workspace_path));
        if check_versions { std::fs::create_dir_all(&workspace_state).map_err(|error| error.to_string())?; }
        let inherited: HashMap<String, String> = std::env::vars().collect();
        let user_home = app.path().home_dir().map_err(|_| "toolchain.native.unavailable")?;
        let defined_context = DefinitionContext { registry:&tool_registry, normalized:&normalized_tools,
            inherited:&inherited, user_home:&user_home, state:&workspace_state, explicit:check_versions,
            selections:&choices["definedTools"], current:&current };
        let referenced: std::collections::HashSet<_> = invocation["executables"].as_array().into_iter().flatten()
            .chain(invocation["runtimeDependencies"].as_array().into_iter().flatten()
                .flat_map(|dependency| dependency["executables"].as_array().into_iter().flatten()))
            .filter_map(|candidate| candidate["toolchainID"].as_str()).collect();
        if choices["definedTools"].as_object().is_some_and(|tools| tools.keys().any(|id| !referenced.contains(id.as_str()))) {
            return Err("toolchain.native.unavailable".into());
        }
        let mut forwarded = BTreeMap::from([("PATH".into(), std::env::var("PATH").unwrap_or_default())]);
        for name in invocation["environmentInputs"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            if let Some((_, value)) = inherited.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)) { forwarded.insert(name.into(),value.clone()); }
        }
        let mut resolver = Resolver { workspace: &workspace, root: &root, choices: &choices["toolchain"], runtimes: serde_json::from_value(choices["toolchain"]["runtimeExecutablePaths"].clone()).map_err(|error| format!("Invalid saved runtime paths: {error}"))?, environment: forwarded, project_code:false, definitions: BTreeMap::new() };
        let mut queries = super::toolchain_queries::Queries::new(&app, &workspace, &current);
        let result = (|| {
        for dependency in invocation["runtimeDependencies"].as_array().into_iter().flatten() {
            current()?;
            let id = dependency["id"].as_str().ok_or("Build runtime has no ID")?;
            let fallback;
            let candidates = if dependency["executables"].as_array().is_none_or(Vec::is_empty) {
                fallback = json!([{"kind":"toolchain","toolchainID":if id == "java" { "project-jdk".to_string() } else { format!("project-{id}") }}]);
                &fallback
            } else { &dependency["executables"] };
            resolver.prepare_definitions(candidates, dependency, &defined_context, &mut queries)?;
            let selected = resolver.select_checked(candidates, |selected| check_version(&package.manifest, &build_system_id, Some(id), dependency, selected, &workspace_state, check_versions))?;
            resolver.add_runtime(id, selected)?;
        }
        resolver.prepare_definitions(&invocation["executables"], invocation, &defined_context, &mut queries)?;
        current()?;
        let selected = resolver.select_checked(&invocation["executables"], |selected| check_version(&package.manifest, &build_system_id, None, invocation, selected, &workspace_state, check_versions))?;
        let environment = selected.environment;
        let native_inputs: BTreeMap<_,_> = resolver.definitions.iter().filter_map(|(id, selected)|
            selected.definition_identity.as_ref().map(|identity| (id,identity))).collect();
        let resolved_executables = resolver.resolved_executables()?;
        Ok(BuildToolContext { manifest:package.manifest, plugin_directory: package.root.to_string_lossy().into_owned(),
            identity: json!({"globalSettings":layers.global,"projectSettings":layers.project,"toolchain":choices["toolchain"],
                "toolDefinitions":tool_registry,"definedToolInputs":native_inputs,"runTools":choices["definedTools"]}),
            workspace_state_directory: workspace_state.to_string_lossy().into_owned(), environment,
            tool: json!({"executable":selected.path}), resolved_executables, executes_project_code:selected.project_code })
        })();
        queries.close()?;
        current()?;
        result
    }).await
}

#[derive(Debug, Clone)]
struct Selected {
    path: PathBuf,
    environment: BTreeMap<String, String>,
    project_code: bool,
    definition_identity: Option<String>,
}

struct Resolver<'a> {
    workspace: &'a Path,
    root: &'a str,
    choices: &'a Value,
    runtimes: HashMap<String, String>,
    environment: BTreeMap<String, String>,
    project_code: bool,
    definitions: BTreeMap<String, Selected>,
}

struct DefinitionContext<'a> {
    current: &'a dyn Fn() -> Result<(), String>,
    registry: &'a Value,
    normalized: &'a Value,
    inherited: &'a HashMap<String, String>,
    user_home: &'a Path,
    state: &'a Path,
    explicit: bool,
    selections: &'a Value,
}

impl Resolver<'_> {
    fn resolved_executables(&self) -> Result<BTreeMap<String, String>, String> {
        let mut bindings = BTreeMap::new();
        for (key, selected) in &self.definitions {
            let (id, _) = key.split_once('\n').ok_or("toolchain.native.unavailable")?;
            let path = selected.path.to_string_lossy().into_owned();
            if bindings
                .insert(id.into(), path.clone())
                .is_some_and(|previous| previous != path)
            {
                // A single Run reference cannot choose between two directories
                // of the same tool. Never choose by map or candidate ordering.
                return Err("toolchain.native.unavailable".into());
            }
        }
        Ok(bindings)
    }
    fn prepare_definitions(
        &mut self,
        candidates: &Value,
        declaration: &Value,
        context: &DefinitionContext<'_>,
        queries: &mut super::toolchain_queries::Queries<'_>,
    ) -> Result<(), String> {
        for candidate in candidates
            .as_array()
            .into_iter()
            .flatten()
            .filter(|value| value["kind"] == "toolchain")
        {
            let id = candidate["toolchainID"]
                .as_str()
                .ok_or("toolchain.native.unavailable")?;
            if !context.normalized["registry"]["definitions"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|value| value["definition"]["id"] == id)
            {
                if context.selections.get(id).is_some() { return Err("toolchain.native.unavailable".into()); }
                continue;
            }
            let directory = candidate["root"].as_str().unwrap_or(self.root);
            let mut environment: BTreeMap<String, String> = context
                .inherited
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect();
            for (key, value) in &self.environment {
                environment.retain(|old, _| !old.eq_ignore_ascii_case(key));
                environment.insert(key.clone(), value.clone());
            }
            let selected = lithe_project::defined_toolchain::resolve_current(
                lithe_project::defined_toolchain::Request {
                    registry: context.registry,
                    workspace: self.workspace,
                    user_home: context.user_home,
                    tool: id,
                    directory,
                    environment: &environment,
                    minimum_version: declaration["minimumVersion"].as_str(),
                    project_code_allowed: context.explicit,
                    fixed: context.selections.get(id),
                },
                |path, arguments, environment, deadline| {
                    let mut command =
                        run::command_for_executable(&path.to_string_lossy(), arguments);
                    // Passive checks use the workspace; explicit actions get writable
                    // operation state. Neither directory is an installed package.
                    command.envs(environment).current_dir(if context.explicit {
                        context.state
                    } else {
                        self.workspace
                    });
                    let (stdout, stderr) =
                        launch::run_process_probe_with_timeout(&mut command, id, true, deadline)?;
                    Ok(format!(
                        "{}\n{}",
                        String::from_utf8_lossy(&stdout),
                        String::from_utf8_lossy(&stderr)
                    ))
                },
                |plugin, provider, params, remaining| queries.query(plugin, provider, params, remaining),
                || (context.current)(),
            )?
            .ok_or("toolchain.native.unavailable")?;
            self.definitions.insert(
                format!("{id}\n{directory}"),
                Selected {
                    path: selected.executable,
                    environment: selected.environment,
                    project_code: selected.project_code,
                    definition_identity: Some(selected.identity),
                },
            );
        }
        Ok(())
    }

    fn add_runtime(&mut self, id: &str, selected: Selected) -> Result<(), String> {
        self.project_code |= selected.project_code;
        self.environment.extend(selected.environment);
        let executable = selected.path.to_string_lossy().into_owned();
        self.runtimes.insert(id.into(), executable.clone());
        self.runtimes
            .insert(format!("project-{id}"), executable.clone());
        if selected.definition_identity.is_none() {
            self.environment.insert(
                format!("LITHE_{}_PATH", id.to_uppercase().replace('-', "_")),
                executable,
            );
        }
        if selected.definition_identity.is_none() && id == "java" {
            if let Some(home) = selected.path.parent().and_then(Path::parent) {
                self.environment
                    .insert("JAVA_HOME".into(), home.to_string_lossy().into_owned());
            }
        }
        if let Some(directory) = selected.path.parent() {
            let mut paths = vec![directory.to_path_buf()];
            if let Some(path) = self.environment.get("PATH") {
                paths.extend(std::env::split_paths(path));
            }
            let path = std::env::join_paths(paths).map_err(|error| error.to_string())?;
            self.environment
                .insert("PATH".into(), path.to_string_lossy().into_owned());
        }
        Ok(())
    }
    #[cfg(test)]
    fn select(&self, candidates: &Value) -> Result<Selected, String> {
        self.select_checked(candidates, |_| Ok(()))
    }

    fn select_checked(
        &self,
        candidates: &Value,
        mut accept: impl FnMut(&Selected) -> Result<(), String>,
    ) -> Result<Selected, String> {
        let mut problem = "No declared Build executable is available".to_string();
        for candidate in candidates
            .as_array()
            .ok_or("Build invocation has no candidates")?
        {
            if let Some(selected) = self.resolve_candidate(candidate)? {
                match accept(&selected) {
                    Ok(()) => return Ok(selected),
                    Err(error)
                        if matches!(candidate["kind"].as_str(), Some("setting" | "toolchain")) =>
                    {
                        return Err(error)
                    }
                    Err(error) => problem = error,
                }
            }
        }
        Err(problem)
    }

    fn resolve_candidate(&self, candidate: &Value) -> Result<Option<Selected>, String> {
        let mut environment = self.environment.clone();
        let mut toolchain_project = false;
        let path = match candidate["kind"]
            .as_str()
            .ok_or("Build candidate has no kind")?
        {
            "toolchain" => {
                let id = candidate["toolchainID"]
                    .as_str()
                    .ok_or("Build toolchain has no ID")?;
                let root = candidate["root"].as_str().unwrap_or(self.root);
                if let Some(selected) = self.definitions.get(&format!("{id}\n{root}")) {
                    environment.extend(selected.environment.clone());
                    return Ok(Some(Selected {
                        environment,
                        ..selected.clone()
                    }));
                }
                let maven_java = self.choices["mavenJavaHomePath"].as_str().unwrap_or("");
                let java_home = self.choices["javaHomePath"].as_str().unwrap_or("");
                let (resolved, project_code) = run::resolve_build_launch(ResolveLaunchArgs {
                    root: self.workspace.into(),
                    working_directory: self.root.into(),
                    executable: LaunchExecutable {
                        toolchain: Some(id.into()),
                        command: None,
                        tool: None,
                    },
                    java_home_path: java_home.into(),
                    maven_executable_path: self.choices["mavenExecutablePath"]
                        .as_str()
                        .unwrap_or("")
                        .into(),
                    maven_java_home_path: maven_java.into(),
                    runtime_executable_paths: self.runtimes.clone(),
                    environment: Default::default(),
                })?;
                toolchain_project = project_code;
                environment.extend(runtime_environment(resolved.environment));
                PathBuf::from(resolved.executable)
            }
            "command" => {
                let command = candidate["command"]
                    .as_str()
                    .ok_or("Build command is missing")?;
                let Some(path) = crate::language_tools::find_system_tool(
                    self.environment.get("PATH").map(std::ffi::OsStr::new),
                    command,
                ) else {
                    return Ok(None);
                };
                path
            }
            "runtime" => {
                let id = candidate["runtime"]
                    .as_str()
                    .ok_or("Build runtime is missing")?;
                let Some(path) = self.runtimes.get(id) else {
                    return Ok(None);
                };
                PathBuf::from(path)
            }
            "setting" => {
                let Some(path) = candidate["path"].as_str().filter(|path| !path.is_empty()) else {
                    return Ok(None);
                };
                let path = PathBuf::from(path);
                if !path.is_absolute() || !path.is_file() {
                    return Err("The explicitly selected Build executable is unavailable".into());
                }
                path
            }
            "environment" => {
                let variable = candidate["variable"]
                    .as_str()
                    .ok_or("Build environment candidate has no variable")?;
                let Some(value) = self
                    .environment
                    .get(variable)
                    .filter(|value| !value.is_empty())
                else {
                    return Ok(None);
                };
                let mut path = PathBuf::from(value);
                if let Some(suffix) = candidate["path"].as_str() {
                    path.push(suffix);
                }
                if !path.is_absolute() || !path.is_file() {
                    return Ok(None);
                }
                path
            }
            "projectFile" => {
                let relative = candidate["path"]
                    .as_str()
                    .ok_or("Build project file is missing")?;
                let Ok(path) = self.workspace.join(relative).canonicalize() else {
                    return Ok(None);
                };
                if !path.starts_with(self.workspace) || !path.is_file() {
                    return Err("Build launcher leaves its workspace".into());
                }
                let mut ready = true;
                for required in candidate["requires"].as_array().into_iter().flatten() {
                    let relative = required.as_str().ok_or("Build requirement is not a path")?;
                    match self.workspace.join(relative).canonicalize() {
                        Ok(path) if !path.starts_with(self.workspace) => {
                            return Err("Build requirement leaves its workspace".into())
                        }
                        Ok(path) if path.is_file() => {}
                        _ => {
                            ready = false;
                            break;
                        }
                    }
                }
                if !ready {
                    return Ok(None);
                }
                path
            }
            _ => return Err("Unsupported Build executable candidate".into()),
        };
        let lexical_project = path.starts_with(self.workspace);
        let path = path.canonicalize().map_err(|error| error.to_string())?;
        if !path.is_file() {
            return Err("Build executable is not a regular file".into());
        }
        let project_code = toolchain_project
            || lexical_project
            || path.starts_with(self.workspace)
            || self.project_code;
        Ok(Some(Selected {
            path,
            environment,
            project_code,
            definition_identity: None,
        }))
    }
}

fn runtime_environment(environment: HashMap<String, String>) -> BTreeMap<String, String> {
    environment
        .into_iter()
        .filter(|(key, _)| {
            key.eq_ignore_ascii_case("PATH") || key.eq_ignore_ascii_case("JAVA_HOME")
        })
        .map(|(key, value)| (key.to_ascii_uppercase(), value))
        .collect()
}

/// Only a freshly verified publisher signature proves official origin.
/// Legacy unsigned installation records and directory names confer no ownership.
fn installed_tool_registry(
    app: &AppHandle,
) -> Result<(Value, Vec<super::lifecycle::NativeLease>), String> {
    let lifecycle = app.state::<LifecycleState>();
    let mut plugins = Vec::new();
    let mut leases = Vec::new();
    for package in app
        .state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .filter(|package| {
            package.entry.enabled
                && package.entry.status == "accepted"
                && (package.manifest["toolDefinitions"].is_array()
                    || package.manifest["toolchainProviders"].is_array())
        })
    {
        leases.push(lifecycle.acquire(&package.entry.plugin_id)?);
        if !super::trust::current(&package) { return Err("toolchain.native.unavailable".into()); }
        plugins.push(json!({"manifest":package.manifest,"verifiedOfficial":package.publisher.is_some()}));
    }
    Ok((json!({"plugins":plugins}), leases))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn native_tool_context_serializes_the_shared_frontend_wire_shape() {
        let expected: Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/build/native-tool-context.json"
        ))
        .unwrap();
        let context = BuildToolContext {
            manifest: expected["manifest"].clone(),
            identity: expected["identity"].clone(),
            plugin_directory: expected["pluginDirectory"].as_str().unwrap().into(),
            workspace_state_directory: expected["workspaceStateDirectory"].as_str().unwrap().into(),
            environment: serde_json::from_value(expected["environment"].clone()).unwrap(),
            tool: expected["tool"].clone(),
            resolved_executables: serde_json::from_value(expected["resolvedExecutables"].clone())
                .unwrap(),
            executes_project_code: false,
        };
        assert_eq!(serde_json::to_value(context).unwrap(), expected);
    }

    #[test]
    fn definition_bindings_exclude_saved_paths_and_refuse_conflicting_roots() {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        let choices = json!({});
        let selected = fixture.file("kit/build.cmd");
        let other = fixture.file("other/build.cmd");
        let mut resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            runtimes: HashMap::from([("dev.example.tools:builder".into(), "stale-input".into())]),
            environment: BTreeMap::new(),
            project_code: false,
            definitions: BTreeMap::new(),
        };
        let selection = |path| Selected {
            path,
            environment: BTreeMap::new(),
            project_code: false,
            definition_identity: Some("operation-evidence".into()),
        };
        resolver.definitions.insert(
            "dev.example.tools:builder\n.".into(),
            selection(selected.clone()),
        );
        assert_eq!(
            resolver.resolved_executables().unwrap(),
            BTreeMap::from([(
                "dev.example.tools:builder".into(),
                selected.to_string_lossy().into_owned()
            )])
        );
        resolver
            .definitions
            .insert("dev.example.tools:builder\nother".into(), selection(other));
        assert!(resolver.resolved_executables().is_err());
    }
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-build-tools-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(path.join("workspace")).unwrap();
            Self(path.canonicalize().unwrap())
        }
        fn workspace(&self) -> PathBuf {
            self.0.join("workspace")
        }
        fn file(&self, path: &str) -> PathBuf {
            let path = self.0.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"fixture").unwrap();
            path
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_saved_runtime_directory_is_not_an_executable() {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        let choices = json!({});
        let resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            runtimes: HashMap::from([("java".into(), fixture.0.to_string_lossy().into_owned())]),
            environment: BTreeMap::new(),
            project_code: false,
            definitions: BTreeMap::new(),
        };
        assert!(resolver
            .select(&json!([{"kind":"runtime","runtime":"java"}]))
            .unwrap_err()
            .contains("regular file"));
    }

    #[test]
    fn runtime_rpc_environment_excludes_unrelated_inherited_and_lithe_prefixed_secrets() {
        let safe = runtime_environment(HashMap::from([
            ("Path".into(), "selected-path".into()),
            ("JAVA_HOME".into(), "selected-home".into()),
            ("TOKEN".into(), "private".into()),
            ("LITHE_TEST_CREDENTIAL_PATH".into(), "private-file".into()),
        ]));
        assert_eq!(
            safe,
            BTreeMap::from([
                ("PATH".into(), "selected-path".into()),
                ("JAVA_HOME".into(), "selected-home".into())
            ])
        );
    }

    #[test]
    fn definition_runtime_exports_do_not_infer_a_legacy_home_or_private_variable() {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        let choices = json!({});
        let executable = fixture.file("kit/custom/compiler.exe");
        let mut resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            runtimes: HashMap::new(),
            environment: BTreeMap::new(),
            project_code: false,
            definitions: BTreeMap::new(),
        };
        let selected = Selected {
            path: executable.clone(),
            project_code: false,
            definition_identity: Some("fixture-evidence".into()),
            environment: BTreeMap::from([(
                "DECLARED_HOME".into(),
                fixture.0.join("kit").to_string_lossy().into_owned(),
            )]),
        };
        resolver
            .definitions
            .insert("dev.example.tools:compiler\napp".into(), selected.clone());
        let selected = resolver.select(&json!([{"kind":"toolchain","toolchainID":"dev.example.tools:compiler","root":"app"}])).unwrap();
        assert_eq!(selected.path, executable);
        resolver.add_runtime("java", selected).unwrap();
        assert!(resolver.environment.contains_key("DECLARED_HOME"));
        assert!(!resolver.environment.contains_key("JAVA_HOME"));
        assert!(!resolver.environment.contains_key("LITHE_JAVA_PATH"));
    }

    #[test]
    fn an_automatic_candidate_can_fail_version_acceptance_but_an_explicit_setting_cannot_fall_back()
    {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        let choices = json!({});
        let old = fixture.file("old/runtime.exe");
        let compatible = fixture.file("compatible/runtime.exe");
        let resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            project_code: false,
            definitions: BTreeMap::new(),
            runtimes: HashMap::from([
                ("old".into(), old.to_string_lossy().into_owned()),
                (
                    "compatible".into(),
                    compatible.to_string_lossy().into_owned(),
                ),
            ]),
            environment: BTreeMap::new(),
        };
        let selected = resolver.select_checked(&json!([{"kind":"runtime","runtime":"old"},{"kind":"runtime","runtime":"compatible"}]),
            |selected| if selected.path == old { Err("old runtime".into()) } else { Ok(()) }).unwrap();
        assert_eq!(selected.path, compatible);
        let mut attempts = 0;
        let result = resolver.select_checked(
            &json!([{"kind":"setting","path":old},{"kind":"runtime","runtime":"compatible"}]),
            |_| {
                attempts += 1;
                Err("explicit runtime is too old".into())
            },
        );
        assert!(result.is_err());
        assert_eq!(attempts, 1);
    }

    #[test]
    fn project_launchers_are_not_probed_and_requirements_cannot_escape_the_workspace() {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        fixture.file("workspace/mvnw.cmd");
        let choices = json!({});
        let resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            runtimes: HashMap::new(),
            environment: BTreeMap::new(),
            project_code: false,
            definitions: BTreeMap::new(),
        };
        let candidates = json!([{"kind":"projectFile","path":"mvnw.cmd","requires":[".mvn/wrapper.properties"]}]);
        assert!(resolver.select(&candidates).is_err());
        fixture.file("workspace/.mvn/wrapper.properties");
        let selected = resolver.select(&candidates).unwrap();
        assert!(selected.project_code);
        // This would fail before a probe if the project-code guard were removed.
        check_version(
            &json!({}),
            "example",
            None,
            &json!({"version":{"arguments":["--version"]}}),
            &selected,
            &workspace,
            true,
        )
        .unwrap();
        fixture.file("outside.properties");
        assert!(resolver.select(&json!([{"kind":"projectFile","path":"mvnw.cmd","requires":["../outside.properties"]}])).unwrap_err().contains("leaves its workspace"));
    }

    #[test]
    fn an_explicit_missing_setting_is_terminal_and_cannot_choose_another_executable() {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        let choices = json!({});
        let fallback = fixture.file("fallback.exe");
        let resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            runtimes: HashMap::new(),
            environment: BTreeMap::new(),
            project_code: false,
            definitions: BTreeMap::new(),
        };
        assert!(resolver.select(&json!([{"kind":"setting","path":fixture.0.join("missing.exe")},{"kind":"setting","path":fallback}])).is_err());
    }

    #[test]
    fn selected_runtime_paths_and_environment_follow_the_current_dependency() {
        let fixture = Fixture::new();
        let workspace = fixture.workspace();
        let choices = json!({});
        let executable = fixture.file("jdk/bin/java.exe");
        let mut resolver = Resolver {
            workspace: &workspace,
            root: ".",
            choices: &choices,
            runtimes: HashMap::new(),
            environment: BTreeMap::new(),
            project_code: false,
            definitions: BTreeMap::new(),
        };
        resolver
            .add_runtime(
                "java",
                Selected {
                    path: executable.clone(),
                    environment: BTreeMap::new(),
                    project_code: false,
                    definition_identity: None,
                },
            )
            .unwrap();
        let selected = resolver
            .select(&json!([{"kind":"runtime","runtime":"java"}]))
            .unwrap();
        assert_eq!(selected.path, executable);
        assert_eq!(
            selected.environment["JAVA_HOME"],
            fixture.0.join("jdk").to_string_lossy()
        );
        assert_eq!(
            selected.environment["LITHE_JAVA_PATH"],
            executable.to_string_lossy()
        );
        assert_eq!(
            std::env::split_paths(&selected.environment["PATH"])
                .next()
                .unwrap(),
            fixture.0.join("jdk/bin")
        );
        assert!(!selected.project_code);
    }
}

fn check_version(
    manifest: &Value,
    system: &str,
    runtime: Option<&str>,
    declaration: &Value,
    selected: &Selected,
    state: &Path,
    enabled: bool,
) -> Result<(), String> {
    if !enabled || selected.project_code || declaration["version"].is_null() {
        return Ok(());
    }
    let arguments: Vec<_> = declaration["version"]["arguments"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let mut command = run::command_for_executable(&selected.path.to_string_lossy(), &arguments);
    command.envs(&selected.environment).current_dir(state);
    let (stdout, stderr) = launch::run_process_probe(&mut command, "Build tool version", false)?;
    let output = format!(
        "{}\n{}",
        String::from_utf8_lossy(&stdout),
        String::from_utf8_lossy(&stderr)
    );
    let result = core_execute(
        "build.checkToolVersion",
        json!({"manifest":manifest,"buildSystemID":system,"request":{"runtime":runtime,"output":output}}),
    )?;
    if result["status"] != "ok" || result["version"]["satisfied"] != true {
        return Err("Build tool does not satisfy the plugin's version requirements".into());
    }
    Ok(())
}
