use super::build_resolver::{
    BuildResolutionStep, RuntimeExecutableInput, VersionProbeOutcome, VersionProbePlan,
    WindowsBuildToolResolver,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        Self::under(std::env::temp_dir(), label)
    }

    fn in_host_directory(label: &str) -> Self {
        Self::under(
            std::env::current_dir()
                .expect("host directory")
                .join(".artifacts"),
            label,
        )
    }

    fn under(parent: PathBuf, label: &str) -> Self {
        let id = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = parent.join(format!(
            "lithe-build-resolver-{label}-{}-{id}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("fixture root");
        Self { root }
    }

    fn directory(&self, relative: impl AsRef<Path>) -> PathBuf {
        let path = self.root.join(relative);
        std::fs::create_dir_all(&path).expect("fixture directory");
        path
    }

    fn file(&self, relative: impl AsRef<Path>) -> PathBuf {
        let path = self.root.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("fixture file parent");
        }
        std::fs::write(&path, b"placeholder").expect("fixture file");
        path
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn contract_fixture(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/contracts/plugins/v1/fixtures")
        .join(name);
    serde_json::from_str(&std::fs::read_to_string(path).expect("contract fixture"))
        .expect("fixture JSON")
}

fn invocation_plan(manifest: &Value, build_system_id: &str, root: &str, settings: Value) -> Value {
    let result = super::scan::core_execute(
        "build.invocationPlan",
        json!({
            "manifest": manifest,
            "buildSystemID": build_system_id,
            "request": {"root": root, "platform": "windows", "settings": settings},
        }),
    )
    .expect("Core invocation plan");
    assert_eq!(result["status"], "ok", "{result}");
    result["invocation"].clone()
}

fn planned_fixture_case(name: &str) -> (Value, String, Value) {
    let cases = contract_fixture("build-plans.json");
    let case = cases["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .find(|case| case["name"] == name)
        .unwrap_or_else(|| panic!("missing build plan case {name}"));
    let manifest = contract_fixture(case["plugin"].as_str().expect("plugin fixture"));
    let build_system = case["buildSystemID"]
        .as_str()
        .expect("build system")
        .to_string();
    let mut request = case["request"].clone();
    request["platform"] = json!("windows");
    let result = super::scan::core_execute(
        "build.invocationPlan",
        json!({
            "manifest": manifest,
            "buildSystemID": build_system,
            "request": request,
        }),
    )
    .expect("Core fixture plan");
    assert_eq!(result["status"], "ok", "{result}");
    (manifest, build_system, result["invocation"].clone())
}

fn check_version(
    manifest: &Value,
    build_system: &str,
    probe: &VersionProbePlan,
    output: &str,
) -> VersionProbeOutcome {
    let result = super::scan::core_execute(
        "build.checkToolVersion",
        json!({
            "manifest": manifest,
            "buildSystemID": build_system,
            "request": probe.core_request(output),
        }),
    )
    .expect("Core version check");
    assert_eq!(result["status"], "ok", "{result}");
    VersionProbeOutcome::from_core(&result).expect("version outcome")
}

fn path_environment(path: &Path) -> BTreeMap<String, String> {
    BTreeMap::from([(
        "PATH".to_string(),
        std::env::join_paths([path])
            .expect("fixture PATH")
            .to_string_lossy()
            .into_owned(),
    )])
}

fn first_path(environment: &BTreeMap<String, String>) -> PathBuf {
    let value = environment
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("PATH"))
        .expect("PATH")
        .1;
    std::env::split_paths(value)
        .next()
        .expect("first PATH entry")
}

fn expect_resolved(step: BuildResolutionStep) -> super::build_resolver::ResolvedBuildTool {
    match step {
        BuildResolutionStep::Resolved(tool) => tool,
        BuildResolutionStep::Probe(probe) => {
            panic!("unexpected probe for {}", probe.executable.display())
        }
    }
}

fn expect_probe(step: BuildResolutionStep) -> VersionProbePlan {
    match step {
        BuildResolutionStep::Probe(probe) => probe,
        BuildResolutionStep::Resolved(tool) => {
            panic!("unexpected resolved tool {}", tool.executable.display())
        }
    }
}

#[test]
fn configured_tool_with_spaces_wins_and_owns_its_path_environment() {
    let fixture = Fixture::new("configured-spaces");
    let configured = fixture.file("custom tools/fixture-build.exe");
    let fallback = fixture.directory("fallback");
    fixture.file("fallback/fixture-build.cmd");
    let manifest = contract_fixture("build-tool-path.plugin.json");
    let plan = invocation_plan(
        &manifest,
        "fixture",
        ".",
        json!({"toolPath": configured.to_string_lossy()}),
    );
    let resolver =
        WindowsBuildToolResolver::with_environment(path_environment(&fallback), BTreeMap::new());
    let mut session = resolver.start(&plan, &fixture.root).expect("session");
    let resolved = expect_resolved(resolver.advance(&mut session, None).expect("resolved"));

    assert_eq!(resolved.executable, configured);
    assert_eq!(
        first_path(&resolved.environment),
        configured.parent().unwrap()
    );
    assert!(!resolved.executes_project_code);
}

#[test]
fn configured_missing_or_directory_is_terminal_and_never_falls_back() {
    for failure in ["missing", "directory"] {
        let fixture = Fixture::new(failure);
        let configured = fixture.root.join("configured tool.exe");
        if failure == "directory" {
            std::fs::create_dir_all(&configured).expect("configured directory");
        }
        let fallback = fixture.directory("fallback");
        fixture.file("fallback/fixture-build.exe");
        let manifest = contract_fixture("build-tool-path.plugin.json");
        let plan = invocation_plan(
            &manifest,
            "fixture",
            ".",
            json!({"toolPath": configured.to_string_lossy()}),
        );
        let resolver = WindowsBuildToolResolver::with_environment(
            path_environment(&fallback),
            BTreeMap::new(),
        );
        let mut session = resolver.start(&plan, &fixture.root).expect("session");
        let error = resolver
            .advance(&mut session, None)
            .expect_err("configured failure must terminate");
        assert_eq!(error.code(), "plugin.build.configuredToolUnavailable");
        assert!(error.is_terminal());
        assert!(error.to_string().contains("toolPath"));
    }
}

#[test]
fn configured_tool_version_rejection_and_probe_failure_are_terminal() {
    let fixture = Fixture::new("configured-version");
    let configured = fixture.file("configured/build.exe");
    let path = fixture.directory("path");
    fixture.file("path/fixture-build.exe");
    let mut manifest = contract_fixture("build-tool-path.plugin.json");
    manifest["buildSystems"][0]["invocation"]["minimumVersion"] = json!("2");
    manifest["buildSystems"][0]["invocation"]["version"] = json!({
        "arguments":["--version"], "pattern":"build (\\d+(?:\\.\\d+)*)"
    });
    let plan = invocation_plan(
        &manifest,
        "fixture",
        ".",
        json!({"toolPath": configured.to_string_lossy()}),
    );
    let resolver =
        WindowsBuildToolResolver::with_environment(path_environment(&path), BTreeMap::new());

    for failed in [false, true] {
        let mut session = resolver.start(&plan, &fixture.root).expect("session");
        let probe = expect_probe(
            resolver
                .advance(&mut session, None)
                .expect("configured probe"),
        );
        assert_eq!(probe.executable, configured);
        assert!(probe.terminal);
        assert_eq!(first_path(&probe.environment), configured.parent().unwrap());
        let outcome = if failed {
            VersionProbeOutcome::Failed {
                message: "controlled probe failure".into(),
            }
        } else {
            check_version(&manifest, "fixture", &probe, "build 1.0")
        };
        let error = resolver
            .advance(&mut session, Some(outcome))
            .expect_err("configured version failure must not discover another tool");
        assert_eq!(error.code(), "plugin.build.configuredToolUnavailable");
        assert!(error.is_terminal());
    }
}

#[test]
fn unset_empty_and_reset_settings_all_resume_core_ordered_discovery() {
    let fixture = Fixture::new("empty-setting");
    let path = fixture.directory("path");
    let fallback = fixture.file("path/fixture-build.bat");
    let manifest = contract_fixture("build-tool-path.plugin.json");
    let resolver =
        WindowsBuildToolResolver::with_environment(path_environment(&path), BTreeMap::new());

    for settings in [json!({}), json!({"toolPath": ""}), json!({})] {
        let plan = invocation_plan(&manifest, "fixture", ".", settings);
        assert_eq!(plan["executables"][0]["path"], Value::Null);
        let mut session = resolver.start(&plan, &fixture.root).expect("session");
        let resolved = expect_resolved(resolver.advance(&mut session, None).expect("resolved"));
        assert_eq!(resolved.executable, fallback);
    }
}

#[test]
fn published_build_v2_executable_setting_uses_the_same_terminal_candidate_path() {
    let fixture = Fixture::new("legacy-setting");
    let configured = fixture.file("legacy tools/build.exe");
    let fallback = fixture.directory("path");
    fixture.file("path/fixture-build.exe");
    let mut manifest = contract_fixture("build-tool-path.plugin.json");
    manifest["requires"]
        .as_object_mut()
        .expect("requires")
        .remove("executableResolution");
    manifest["requires"]["buildSystems"] = json!(2);
    manifest["buildSystems"][0]["invocation"]["executables"]
        .as_array_mut()
        .expect("executables")
        .remove(0);
    manifest["buildSystems"][0]["invocation"]["executableSetting"] = json!("toolPath");

    let plan = invocation_plan(
        &manifest,
        "fixture",
        ".",
        json!({"toolPath": configured.to_string_lossy()}),
    );
    assert_eq!(plan["executables"][0]["kind"], "setting");
    let resolver =
        WindowsBuildToolResolver::with_environment(path_environment(&fallback), BTreeMap::new());
    let mut session = resolver.start(&plan, &fixture.root).expect("session");
    let resolved = expect_resolved(resolver.advance(&mut session, None).expect("resolved"));
    assert_eq!(resolved.executable, configured);
}

#[test]
fn build_plans_gradle_order_selects_the_project_wrapper_without_probing_it() {
    let fixture = Fixture::new("gradle-wrapper");
    let wrapper = fixture.file("gradlew.bat");
    fixture.file("gradle/wrapper/gradle-wrapper.properties");
    let java = fixture.file("jdk/bin/java.exe");
    let gradle_home = fixture.directory("gradle-home");
    fixture.file("gradle-home/bin/gradle.bat");
    let path = fixture.directory("path");
    fixture.file("path/gradle.exe");
    let (manifest, build_system, plan) =
        planned_fixture_case("gradle prefers the batch wrapper on windows");
    let mut environment = path_environment(&path);
    environment.insert(
        "GRADLE_HOME".into(),
        gradle_home.to_string_lossy().into_owned(),
    );
    let resolver = WindowsBuildToolResolver::with_environment(
        environment,
        BTreeMap::from([(
            "java".into(),
            RuntimeExecutableInput::discovered(java.clone()),
        )]),
    );
    let mut session = resolver.start(&plan, &fixture.root).expect("session");
    let probe = expect_probe(resolver.advance(&mut session, None).expect("runtime probe"));
    assert_eq!(probe.executable, java);
    assert_eq!(probe.arguments, ["-version"]);
    let outcome = check_version(&manifest, &build_system, &probe, "java version \"17.0.9\"");
    let resolved = expect_resolved(
        resolver
            .advance(&mut session, Some(outcome))
            .expect("wrapper resolution"),
    );
    assert_eq!(
        resolved.executable,
        wrapper.canonicalize().expect("wrapper path")
    );
    assert!(resolved.executes_project_code);
    assert_eq!(resolved.runtime_executables["java"], java);
}

#[test]
fn path_lookup_uses_windows_launcher_extensions_and_ignores_extensionless_files() {
    let fixture = Fixture::new("pathext");
    fixture.directory("crates/app");
    let path = fixture.directory("path");
    fixture.file("path/cargo");
    let command = fixture.file("path/cargo.cmd");
    let (manifest, build_system, plan) =
        planned_fixture_case("cargo invocation is the cargo command");
    let resolver =
        WindowsBuildToolResolver::with_environment(path_environment(&path), BTreeMap::new());
    let mut session = resolver.start(&plan, &fixture.root).expect("session");
    let probe = expect_probe(resolver.advance(&mut session, None).expect("probe"));
    assert_eq!(probe.executable, command);
    let outcome = check_version(&manifest, &build_system, &probe, "cargo 1.80.1");
    let resolved = expect_resolved(
        resolver
            .advance(&mut session, Some(outcome))
            .expect("resolved"),
    );
    assert_eq!(resolved.version.as_deref(), Some("1.80.1"));
}

#[test]
fn environment_candidates_read_only_declared_inputs() {
    let fixture = Fixture::new("environment-whitelist");
    let environment_home = fixture.directory("environment-home");
    fixture.file("environment-home/bin/build.exe");
    let fallback_path = fixture.directory("path");
    let fallback = fixture.file("path/fallback.exe");
    let plan = json!({
        "buildSystemID": "fixture",
        "root": ".",
        "executables": [
            {"kind":"environment", "variable":"SECRET_HOME", "path":"bin/build.exe"},
            {"kind":"command", "command":"fallback"}
        ],
        "environmentInputs": [],
        "runtimeDependencies": [],
        "version": null,
        "minimumVersion": null
    });
    let mut environment = path_environment(&fallback_path);
    environment.insert(
        "SECRET_HOME".into(),
        environment_home.to_string_lossy().into_owned(),
    );
    let resolver = WindowsBuildToolResolver::with_environment(environment, BTreeMap::new());
    let mut session = resolver.start(&plan, &fixture.root).expect("session");
    let resolved = expect_resolved(resolver.advance(&mut session, None).expect("resolved"));
    assert_eq!(resolved.executable, fallback);
}

fn assert_relative_discovery_is_frozen(kind: &str) {
    // All paths really exist relative to the host cwd, while execution will
    // use a different workspace cwd. No test mutates the process-wide cwd.
    let host_directory = std::env::current_dir().expect("host directory");
    let fixture = Fixture::in_host_directory(kind);
    let executable = fixture.file("tools/bin/build.exe");
    let relative_home = fixture
        .root
        .join("tools")
        .strip_prefix(&host_directory)
        .expect("fixture belongs to host directory")
        .to_path_buf();
    let relative_executable = relative_home.join("bin/build.exe");
    let mut environment = path_environment(&relative_home.join("bin"));
    environment.insert(
        "CUSTOM_HOME".into(),
        relative_home.to_string_lossy().into_owned(),
    );
    let candidate = match kind {
        "environment" => {
            json!({"kind":"environment", "variable":"CUSTOM_HOME", "path":"bin/build.exe"})
        }
        "path" => json!({"kind":"command", "command":"build"}),
        "host-runtime" => json!({"kind":"runtime", "runtime":"custom"}),
        _ => panic!("unexpected relative discovery kind {kind}"),
    };
    let plan = json!({
        "buildSystemID":"fixture", "root":".", "executables":[candidate],
        "environmentInputs":["CUSTOM_HOME"],
        "runtimeDependencies": if kind == "host-runtime" { json!([{
            "id":"custom", "hostManaged":true, "executables":[]
        }]) } else { json!([]) },
        "version":{"arguments":["--version"]}, "minimumVersion":"1"
    });
    let resolver = WindowsBuildToolResolver::with_environment(
        environment,
        BTreeMap::from([(
            "custom".into(),
            RuntimeExecutableInput::discovered(relative_executable),
        )]),
    );
    let workspace = fixture.directory("workspace");
    let mut session = resolver.start(&plan, &workspace).expect("session");
    let probe = expect_probe(resolver.advance(&mut session, None).expect("probe"));
    assert!(
        probe.executable.is_absolute(),
        "probe must not change identity with cwd"
    );
    assert_eq!(probe.executable, executable);
    let resolved = expect_resolved(
        resolver
            .advance(
                &mut session,
                Some(VersionProbeOutcome::Accepted {
                    version: Some("1".into()),
                }),
            )
            .expect("resolved"),
    );
    assert_eq!(resolved.executable, executable);
    if kind == "host-runtime" {
        assert_eq!(resolved.runtime_executables["custom"], executable);
        assert_eq!(
            first_path(&resolved.environment),
            executable.parent().expect("tool directory")
        );
    }
}

#[test]
fn relative_environment_home_is_frozen_before_the_probe() {
    assert_relative_discovery_is_frozen("environment");
}

#[test]
fn relative_path_entry_is_frozen_before_the_probe() {
    assert_relative_discovery_is_frozen("path");
}

#[test]
fn relative_host_runtime_is_frozen_before_the_probe() {
    assert_relative_discovery_is_frozen("host-runtime");
}

#[test]
fn rejected_runtime_candidate_does_not_leak_its_path_into_the_next_candidate() {
    let fixture = Fixture::new("runtime-isolation");
    let old_home = fixture.directory("old-runtime");
    let old = fixture.file("old-runtime/old.exe");
    let path = fixture.directory("path");
    let fallback = fixture.file("path/custom.exe");
    let mut manifest = contract_fixture("build-tool-path.plugin.json");
    manifest["buildSystems"][0]["invocation"] = json!({
        "executables": [{"kind":"runtime", "runtime":"custom"}],
        "environmentInputs": ["CUSTOM_HOME"],
        "runtimeDependencies": [{
            "id":"custom",
            "minimumVersion":"2",
            "executables":[
                {"kind":"environment", "variable":"CUSTOM_HOME", "path":"old.exe"},
                {"kind":"command", "command":"custom"}
            ],
            "version":{"arguments":["--version"], "pattern":"custom (\\d+(?:\\.\\d+)*)"}
        }]
    });
    manifest["requires"]
        .as_object_mut()
        .expect("requires")
        .remove("executableResolution");
    let plan = invocation_plan(&manifest, "fixture", ".", json!({}));
    let mut environment = path_environment(&path);
    environment.insert(
        "CUSTOM_HOME".into(),
        old_home.to_string_lossy().into_owned(),
    );
    let resolver = WindowsBuildToolResolver::with_environment(environment, BTreeMap::new());
    let mut session = resolver.start(&plan, &fixture.root).expect("session");

    let old_probe = expect_probe(resolver.advance(&mut session, None).expect("old probe"));
    assert_eq!(old_probe.executable, old);
    assert_eq!(first_path(&old_probe.environment), old_home);
    let rejected = check_version(&manifest, "fixture", &old_probe, "custom 1.0");
    let fallback_probe = expect_probe(
        resolver
            .advance(&mut session, Some(rejected))
            .expect("fallback probe"),
    );
    assert_eq!(fallback_probe.executable, fallback);
    assert_eq!(first_path(&fallback_probe.environment), path);
    assert!(
        !std::env::split_paths(fallback_probe.environment.get("PATH").expect("PATH"))
            .any(|entry| entry == old_home)
    );

    let accepted = check_version(&manifest, "fixture", &fallback_probe, "custom 2.3");
    let resolved = expect_resolved(
        resolver
            .advance(&mut session, Some(accepted))
            .expect("resolved runtime tool"),
    );
    assert_eq!(resolved.executable, fallback);
    assert_eq!(resolved.runtime_executables["custom"], fallback);
}

#[test]
fn host_runtime_probe_failure_is_isolated_and_explicit_selection_is_terminal() {
    let fixture = Fixture::new("host-runtime-failure");
    let selected = fixture.file("selected/bin/java.exe");
    let path = fixture.directory("path");
    let fallback = fixture.file("path/java.exe");
    let (_, _, plan) = planned_fixture_case("gradle prefers the batch wrapper on windows");

    for explicit in [false, true] {
        let resolver = WindowsBuildToolResolver::with_environment(
            path_environment(&path),
            BTreeMap::from([(
                "java".into(),
                RuntimeExecutableInput {
                    executable: selected.clone(),
                    environment: BTreeMap::from([("JAVA_HOME".into(), "selected-home".into())]),
                    explicit,
                },
            )]),
        );
        let mut session = resolver.start(&plan, &fixture.root).expect("session");
        let selected_probe = expect_probe(resolver.advance(&mut session, None).expect("probe"));
        assert_eq!(selected_probe.executable, selected);
        assert_eq!(selected_probe.environment["JAVA_HOME"], "selected-home");
        let next = resolver.advance(
            &mut session,
            Some(VersionProbeOutcome::Failed {
                message: "controlled runtime failure".into(),
            }),
        );
        if explicit {
            let error = next.expect_err("explicit runtime must not fall back");
            assert_eq!(error.code(), "plugin.build.configuredToolUnavailable");
            assert!(error.is_terminal());
        } else {
            let probe = expect_probe(next.expect("discovered runtime fallback"));
            assert_eq!(probe.executable, fallback);
            assert_eq!(first_path(&probe.environment), path);
            assert!(!probe.environment.contains_key("JAVA_HOME"));
        }
    }
}

#[test]
fn project_candidates_are_scoped_to_the_selected_instance_root() {
    let fixture = Fixture::new("instance-roots");
    let one = fixture.file("one/wrapper.cmd");
    let two = fixture.file("two/wrapper.cmd");
    let mut manifest = contract_fixture("build-tool-path.plugin.json");
    manifest["buildSystems"][0]["invocation"] = json!({
        "executables": [{"kind":"projectFile", "path":"wrapper.cmd"}]
    });
    manifest["requires"]
        .as_object_mut()
        .expect("requires")
        .remove("executableResolution");
    let resolver = WindowsBuildToolResolver::with_environment(BTreeMap::new(), BTreeMap::new());
    for (root, expected) in [("one", one), ("two", two)] {
        let plan = invocation_plan(&manifest, "fixture", root, json!({}));
        let mut session = resolver.start(&plan, &fixture.root).expect("session");
        let resolved = expect_resolved(resolver.advance(&mut session, None).expect("resolved"));
        assert_eq!(
            resolved.executable,
            expected.canonicalize().expect("project executable")
        );
        assert!(resolved.executes_project_code);
    }

    let mut escaped = invocation_plan(&manifest, "fixture", "one", json!({}));
    escaped["executables"][0]["path"] = json!("two/wrapper.cmd");
    let mut session = resolver.start(&escaped, &fixture.root).expect("session");
    let error = resolver
        .advance(&mut session, None)
        .expect_err("sibling instance path must fail");
    assert_eq!(error.code(), "plugin.build.projectPathEscape");
}

#[test]
fn project_candidate_rejects_a_junction_or_symlink_escape() {
    let fixture = Fixture::new("project link");
    fixture.directory("instance");
    let outside = fixture.directory("outside");
    fixture.file("outside/wrapper.cmd");
    let link = fixture.root.join("instance").join("linked");
    create_directory_link(&outside, &link);
    let mut manifest = contract_fixture("build-tool-path.plugin.json");
    manifest["buildSystems"][0]["invocation"] = json!({
        "executables": [{"kind":"projectFile", "path":"linked/wrapper.cmd"}]
    });
    manifest["requires"]
        .as_object_mut()
        .expect("requires")
        .remove("executableResolution");
    let plan = invocation_plan(&manifest, "fixture", "instance", json!({}));
    let resolver = WindowsBuildToolResolver::with_environment(BTreeMap::new(), BTreeMap::new());
    let mut session = resolver.start(&plan, &fixture.root).expect("session");
    let error = resolver
        .advance(&mut session, None)
        .expect_err("link escape must fail");
    assert_eq!(error.code(), "plugin.build.projectPathEscape");
}

fn create_directory_link(target: &Path, link: &Path) {
    #[cfg(windows)]
    {
        // Junctions exercise the reparse boundary without Developer Mode or
        // admin privilege. Native separators keep mklink from reading a slash
        // in a fixture path as a command option; Command owns argument quoting.
        let target = target.components().collect::<PathBuf>();
        let link = link.components().collect::<PathBuf>();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut command = std::process::Command::new("cmd");
        command
            .args(["/D", "/C", "mklink", "/J"])
            .arg(&link)
            .arg(&target);
        let outcome = lithe_git_host::run(
            &mut command,
            None,
            || std::time::Instant::now() >= deadline,
            || {},
            |_, _| {},
        );
        assert!(
            outcome.failure.is_none() && outcome.status.is_some_and(|status| status.success()),
            "junction creation failed: {}",
            String::from_utf8_lossy(&outcome.stderr)
        );
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, link).expect("directory symlink");
}
