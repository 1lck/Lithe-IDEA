use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);
const TOOL: &str = "dev.example.tools:compiler";

fn provider_fixture() -> Fixture {
    let mut fixture = Fixture::new();
    let mut provider: Value = serde_json::from_str(include_str!(
        "../../../../../../shared/contracts/plugins/v1/fixtures/toolchain-provider.plugin.json"
    ))
    .unwrap();
    provider["toolchainProviders"][0]["tools"] = json!([TOOL]);
    provider["toolchainProviders"][0]["watchFiles"] =
        json!([{"pattern":".fixture-version","reader":"native"}]);
    fixture.registry["plugins"]
        .as_array_mut()
        .unwrap()
        .push(json!({"manifest":provider,"verifiedOfficial":false}));
    fixture.registry["plugins"][0]["manifest"]["toolDefinitions"][0]["executables"]
        .as_array_mut()
        .unwrap()
        .insert(
            2,
            json!({"id":"project-request","kind":"toolchain","scope":"project"}),
        );
    fs::write(fixture.workspace.join(".fixture-version"), "21").unwrap();
    fixture
}
fn provider_wire(params: &Value, home: &Path, source: &Path) -> Value {
    json!({"id":17,"response":{"jsonrpc":"2.0","id":17,"result":{
        "operationID":params["operationID"],"generation":params["generation"],"providerID":params["providerID"],
        "installations":[{"tool":TOOL,"version":"21","home":native_path(home)}],
        "statements":[{"tool":TOOL,"scope":"project","source":native_path(source),"request":"21",
            "installation":native_path(home),"kind":"declaration","reader":"native"}],"watch":[native_path(source)]}}})
}

#[test]
fn provider_replies_share_native_facts_and_leave_a_stable_identity_across_operations() {
    let fixture = provider_fixture();
    let home = fixture.install("provider-selected");
    let source = fixture.workspace.join(".fixture-version");
    let mut generations = Vec::new();
    let mut identities = Vec::new();
    for _ in 0..2 {
        let mut queries = 0;
        let selected = resolve_with_queries(
            fixture.request(),
            |path, _, _, _| {
                assert_eq!(path, home.join(launcher()));
                Ok("compiler 21".into())
            },
            |plugin, provider, params, remaining| {
                queries += 1;
                assert_eq!(plugin, "dev.lithe.fixture.mise");
                assert_eq!(provider, "mise");
                assert_eq!(params["tools"], json!([TOOL]));
                assert_eq!(params["workspace"]["root"], native_path(&fixture.workspace));
                assert!(remaining <= Duration::from_secs(10) && !remaining.is_zero());
                generations.push(params["generation"].as_u64().unwrap());
                let mut wire = provider_wire(params, &home, &source);
                if generations.len() == 2 {
                    wire["id"] = json!("rpc:雪-2");
                    wire["response"]["id"] = wire["id"].clone();
                }
                Ok(wire)
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(selected.executable, home.join(launcher()));
        identities.push(selected.identity);
        assert_eq!(queries, 1);
    }
    assert_ne!(generations[0], generations[1]);
    assert_eq!(
        identities[0], identities[1],
        "Operation IDs must not invalidate an unchanged model"
    );
}

#[test]
fn checked_unavailable_provider_may_use_lower_layers_but_unsafe_replies_never_do() {
    let fixture = provider_fixture();
    let home = fixture.install("Kits/automatic");
    let selected = resolve_with_queries(
        fixture.request(),
        |_, _, _, _| Ok("compiler 21".into()),
        |_, _, params, _| {
            Ok(
                json!({"id":17,"response":{"jsonrpc":"2.0","id":17,"error":{"code":-32073,
            "message":"fixture unavailable","data":{"code":"plugin.toolchain.providerUnavailable",
                "operationID":params["operationID"],"providerID":params["providerID"]}}}}),
            )
        },
    )
    .unwrap()
    .unwrap();
    assert_eq!(selected.executable, home.join(launcher()));
    for change in ["id", "generation", "workspace"] {
        let invalid_home = fixture.install("workspace/untrusted");
        assert!(
            resolve_with_queries(
                fixture.request(),
                |_, _, _, _| panic!("Unsafe answers cannot reach a lower probe"),
                |_, _, params, _| {
                    let mut wire =
                        provider_wire(params, &home, &fixture.workspace.join(".fixture-version"));
                    match change {
                        "id" => wire["response"]["id"] = json!(18),
                        "generation" => wire["response"]["result"]["generation"] = json!(0),
                        _ => {
                            wire = provider_wire(
                                params,
                                &invalid_home,
                                &fixture.workspace.join(".fixture-version"),
                            )
                        }
                    }
                    Ok(wire)
                }
            )
            .is_err(),
            "{change}"
        );
    }
}

#[test]
fn provider_source_changes_during_a_probe_revoke_the_resolution() {
    let fixture = provider_fixture();
    let home = fixture.install("provided");
    let source = fixture.workspace.join(".fixture-version");
    assert_eq!(
        resolve_with_queries(
            fixture.request(),
            |_, _, _, _| {
                fs::write(&source, "changed native input").unwrap();
                Ok("compiler 21".into())
            },
            |_, _, params, _| Ok(provider_wire(params, &home, &source))
        )
        .err()
        .as_deref(),
        Some(CHANGED)
    );
}

#[test]
fn unsupported_launch_templates_are_refused_without_probing_or_dropping_arguments() {
    let mut fixture = Fixture::new();
    for launch in [
        json!(["${executable}", "--fixture", "${arguments}"]),
        json!(["${executable}", "${home}", "${arguments}"]),
    ] {
        fixture.registry["plugins"][0]["manifest"]["toolDefinitions"][0]["launch"] = launch;
        assert_eq!(
            resolve(fixture.request(), |_, _, _, _| panic!(
                "Unsupported templates cannot start a probe"
            ))
            .err()
            .as_deref(),
            Some("toolchain.native.unsupportedLaunch")
        );
    }
}

struct Fixture {
    root: PathBuf,
    workspace: PathBuf,
    registry: Value,
    environment: BTreeMap<String, String>,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-defined-tools-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(root.join("workspace")).unwrap();
        let root = PathBuf::from(native_path(&root.canonicalize().unwrap()));
        let mut manifest: Value = serde_json::from_str(include_str!(
            "../../../../../../shared/contracts/plugins/v1/fixtures/tool-definition.plugin.json"
        ))
        .unwrap();
        manifest["id"] = json!("dev.example.tools");
        manifest["toolDefinitions"] = json!([{
            "id":TOOL,"displayName":"Fixture compiler","icon":{"host":"plugin"},
            "executableLayouts":[{"path":launcher()}],
            "executables":[
                {"id":"pin","kind":"setting","settingID":"executable","layer":"project"},
                {"id":"wrapper","kind":"projectFile","path":wrapper(),"requires":[".fixture-marker"]},
                {"id":"home","kind":"environment","variable":"FIXTURE_HOME","path":launcher()},
                {"id":"command","kind":"command","command":"compiler"},
                {"id":"scan","kind":"toolchain","scope":"installed"}
            ],
            "version":{"arguments":["--version"],"pattern":"compiler ([0-9]+(?:\\.[0-9]+)*)"},
            "discovery":[{"root":{"kind":"home"},"pattern":"Kits/*"}],
            "wrappers":[{"path":wrapper(),"requires":[".fixture-marker"]}],"commands":["compiler"],"homeVariable":"FIXTURE_HOME",
            "exports":[{"name":"FIXTURE_HOME","value":"${home}"}],
            "pathPrepend":["${home}/bin","${home}/helpers"],"launch":["${executable}","${arguments}"]
        }]);
        let admission: Value = serde_json::from_str(&lithe_core::execute_json(&json!({
            "command":"toolchains.registry","payload":{"plugins":[{"manifest":manifest,"verifiedOfficial":false}]}
        }).to_string())).unwrap();
        assert_eq!(admission["data"]["status"], "ok", "{admission}");
        Self {
            workspace: root.join("workspace"),
            root,
            registry: json!({"plugins":[{"manifest":manifest,"verifiedOfficial":false}]}),
            environment: BTreeMap::new(),
        }
    }
    fn install(&self, name: &str) -> PathBuf {
        let home = self.root.join(name);
        fs::create_dir_all(home.join("bin")).unwrap();
        fs::create_dir_all(home.join("helpers")).unwrap();
        self.executable(&home.join(launcher()));
        home
    }
    fn executable(&self, path: &Path) {
        fs::write(path, b"fixture").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }
    fn pin(&self, directory: &str, home: &Path) {
        fs::create_dir_all(self.workspace.join(".lithe/toolchains")).unwrap();
        fs::write(self.workspace.join(".lithe/toolchains/local.json"), json!({"version":1,"toolchains":{},"pins":{
            directory:{TOOL:{"home":native_path(home),"version":"selected","provider":"host:manual"}}
        }}).to_string()).unwrap();
    }
    fn request(&self) -> Request<'_> {
        Request {
            registry: &self.registry,
            workspace: &self.workspace,
            user_home: &self.root,
            tool: TOOL,
            directory: ".",
            environment: &self.environment,
            minimum_version: Some("17"),
            project_code_allowed: false,
            fixed: None,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn launcher() -> &'static str {
    if cfg!(windows) {
        "bin/compiler.cmd"
    } else {
        "bin/compiler"
    }
}
fn wrapper() -> &'static str {
    if cfg!(windows) {
        "compilerw.cmd"
    } else {
        "compilerw"
    }
}

#[test]
fn fixed_home_is_operation_owned_and_preserves_all_declared_exports() {
    let fixture = Fixture::new();
    let home = fixture.install("selected kit");
    fixture.pin(".", &home);
    let mut probes = Vec::new();
    let selected = resolve(
        fixture.request(),
        |path, arguments, environment, deadline| {
            assert_eq!(arguments, ["--version"]);
            assert!(environment.is_empty());
            assert!(deadline <= Duration::from_secs(5) && !deadline.is_zero());
            probes.push(path.to_path_buf());
            Ok("compiler 21.0.1".into())
        },
    )
    .unwrap()
    .unwrap();
    assert_eq!(selected.executable, home.join(launcher()));
    assert_eq!(selected.version.as_deref(), Some("21.0.1"));
    assert_eq!(selected.environment["FIXTURE_HOME"], native_path(&home));
    assert_eq!(
        std::env::split_paths(&selected.environment["PATH"]).collect::<Vec<_>>(),
        vec![home.join("bin"), home.join("helpers")]
    );
    assert_eq!(probes, vec![home.join(launcher())]);
    assert!(!selected.project_code);
}

#[test]
fn invalid_fixed_home_never_falls_back_to_the_available_scanned_tool() {
    let fixture = Fixture::new();
    fixture.install("Kits/available");
    fixture.pin(".", &fixture.root.join("missing"));
    assert!(resolve(fixture.request(), |_, _, _, _| Ok("compiler 23".into())).is_err());
    assert!(resolve(fixture.request(), |_, _, _, _| Ok("compiler 1".into())).is_err());
}

#[test]
fn declaration_scans_choose_the_highest_version_and_keep_equal_versions_ambiguous() {
    let fixture = Fixture::new();
    let older = fixture.install("Kits/old");
    let newer = fixture.install("Kits/new");
    fixture.install("Kits/.hidden");
    let mut probed = BTreeSet::new();
    let selected = resolve(fixture.request(), |path, _, _, _| {
        probed.insert(path.to_path_buf());
        Ok(if path.starts_with(&older) {
            "compiler 17"
        } else {
            "compiler 23"
        }
        .into())
    })
    .unwrap()
    .unwrap();
    assert_eq!(selected.executable, newer.join(launcher()));
    assert_eq!(
        probed,
        BTreeSet::from([older.join(launcher()), newer.join(launcher())])
    );
    assert!(resolve(fixture.request(), |_, _, _, _| Ok("compiler 21".into())).is_err());
}

#[test]
fn wrapper_is_probed_only_for_an_explicit_action_and_still_requires_the_floor() {
    let fixture = Fixture::new();
    let executable = fixture.workspace.join(wrapper());
    fixture.executable(&executable);
    fs::write(fixture.workspace.join(".fixture-marker"), "fixture").unwrap();
    let mut calls = 0;
    assert!(
        resolve(fixture.request(), |_, _, _, _| {
            calls += 1;
            Ok("compiler 21".into())
        })
        .is_err()
    );
    assert_eq!(calls, 0);
    let mut request = fixture.request();
    request.project_code_allowed = true;
    let selected = resolve(request, |path, _, _, _| {
        assert_eq!(path, executable);
        calls += 1;
        Ok("compiler 21".into())
    })
    .unwrap()
    .unwrap();
    assert_eq!(calls, 1);
    assert!(selected.project_code);
    assert_eq!(selected.executable, executable);
    let mut request = fixture.request();
    request.project_code_allowed = true;
    assert!(resolve(request, |_, _, _, _| Ok("compiler 11".into())).is_err());
}

#[test]
fn changes_during_a_probe_revoke_files_and_saved_pin_bytes() {
    for change_pin in [false, true] {
        let fixture = Fixture::new();
        let home = fixture.install("selected");
        fixture.pin(".", &home);
        let error = resolve(fixture.request(), |path, _, _, _| {
            if change_pin {
                fs::write(fixture.workspace.join(".lithe/toolchains/local.json"), "{}").unwrap();
            } else {
                fs::remove_file(path).unwrap();
            }
            Ok("compiler 21".into())
        })
        .err();
        assert_eq!(error.as_deref(), Some(CHANGED));
    }
}

#[test]
fn directory_pins_and_a_second_tool_use_the_same_definition_adapter() {
    let fixture = Fixture::new();
    let home = fixture.install("selected");
    fixture.pin("app", &home);
    let mut request = fixture.request();
    request.directory = "app/nested";
    assert_eq!(
        resolve(request, |_, _, _, _| Ok("compiler 21".into()))
            .unwrap()
            .unwrap()
            .executable,
        home.join(launcher())
    );
    let mut other = Fixture::new();
    other.registry["plugins"][0]["manifest"]["id"] = json!("dev.example.other");
    other.registry["plugins"][0]["manifest"]["toolDefinitions"][0]["id"] =
        json!("dev.example.other:runner");
    let home = other.install("different");
    other
        .environment
        .insert("FIXTURE_HOME".into(), native_path(&home));
    let mut request = other.request();
    request.tool = "dev.example.other:runner";
    assert_eq!(
        resolve(request, |_, _, _, _| Ok("compiler 23".into()))
            .unwrap()
            .unwrap()
            .executable,
        home.join(launcher())
    );
}

#[test]
fn inherited_secrets_never_become_provider_environment_and_untrusted_short_ids_are_refused() {
    let mut fixture = Fixture::new();
    let home = fixture.install("selected");
    fixture.pin(".", &home);
    fixture
        .environment
        .insert("HOST_SECRET".into(), "private-fixture-value".into());
    let selected = resolve(fixture.request(), |_, _, environment, _| {
        assert!(environment.contains_key("HOST_SECRET"));
        Ok("compiler 21".into())
    })
    .unwrap()
    .unwrap();
    assert!(!selected.environment.contains_key("HOST_SECRET"));
    fixture.registry["plugins"][0]["manifest"]["toolDefinitions"][0]["id"] = json!("compiler");
    let mut request = fixture.request();
    request.tool = "compiler";
    let mut probes = 0;
    assert!(
        resolve(request, |_, _, _, _| {
            probes += 1;
            Ok("compiler 21".into())
        })
        .is_err()
    );
    assert_eq!(probes, 0);
}

#[test]
fn a_provider_cannot_be_silently_skipped_without_native_query_support() {
    let mut fixture = Fixture::new();
    let mut provider: Value = serde_json::from_str(include_str!(
        "../../../../../../shared/contracts/plugins/v1/fixtures/toolchain-provider.plugin.json"
    ))
    .unwrap();
    provider["toolchainProviders"][0]["tools"] = json!([TOOL]);
    fixture.registry["plugins"]
        .as_array_mut()
        .unwrap()
        .push(json!({"manifest":provider,"verifiedOfficial":false}));
    let mut probes = 0;
    assert_eq!(
        resolve(fixture.request(), |_, _, _, _| {
            probes += 1;
            Ok("compiler 21".into())
        })
        .err()
        .as_deref(),
        Some("toolchain.native.providerUnavailable")
    );
    assert_eq!(probes, 0);
    let home = fixture.install("selected");
    fixture.pin(".", &home);
    assert!(
        resolve(fixture.request(), |_, _, _, _| Ok("compiler 21".into()))
            .unwrap()
            .is_some()
    );
}

#[cfg(unix)]
#[test]
fn links_into_the_workspace_are_never_probed_as_installations() {
    let fixture = Fixture::new();
    let home = fixture.install("workspace/local");
    fs::create_dir_all(fixture.root.join("Kits")).unwrap();
    std::os::unix::fs::symlink(&home, fixture.root.join("Kits/alias")).unwrap();
    let mut calls = 0;
    assert!(
        resolve(fixture.request(), |_, _, _, _| {
            calls += 1;
            Ok("compiler 21".into())
        })
        .is_err()
    );
    assert_eq!(calls, 0);
}

#[test]
fn per_run_choices_override_pins_independently_and_do_not_write_them() {
    let fixture = Fixture::new();
    let inherited = fixture.install("inherited");
    let first = fixture.install("first run");
    let second = fixture.install("second run");
    fixture.pin(".", &inherited);
    let pin_path = fixture.workspace.join(".lithe/toolchains/local.json");
    let original = fs::read(&pin_path).unwrap();
    let mut identities = Vec::new();
    for home in [&first, &second, &first] {
        let fixed = json!({"home":native_path(home)});
        let mut request = fixture.request();
        request.fixed = Some(&fixed);
        let mut probes = Vec::new();
        let selected = resolve(request, |path, _, _, _| {
            probes.push(path.to_path_buf());
            Ok("compiler 21".into())
        })
        .unwrap()
        .unwrap();
        assert_eq!(selected.executable, home.join(launcher()));
        assert_eq!(probes, [home.join(launcher())]);
        identities.push(selected.identity);
        assert_eq!(fs::read(&pin_path).unwrap(), original);
    }
    assert_eq!(identities[0], identities[2]);
    assert_ne!(identities[0], identities[1]);
    let fixed = json!({"home":native_path(&first)});
    let mut request = fixture.request();
    request.fixed = Some(&fixed);
    let changed_version = resolve(request, |_, _, _, _| Ok("compiler 23".into()))
        .unwrap()
        .unwrap();
    assert_ne!(identities[0], changed_version.identity);
    let fixed = json!({"home":native_path(&fixture.root.join("missing"))});
    let mut request = fixture.request();
    request.fixed = Some(&fixed);
    assert!(
        resolve(request, |_, _, _, _| panic!(
            "Invalid fixed choice cannot probe a fallback"
        ))
        .is_err()
    );
}

#[test]
fn per_run_launcher_requires_an_action_inside_the_workspace_and_never_invents_a_home() {
    let mut fixture = Fixture::new();
    fixture
        .environment
        .insert("FIXTURE_SECRET".into(), "private".into());
    let launcher = fixture.workspace.join(if cfg!(windows) {
        "custom runner.cmd"
    } else {
        "custom runner"
    });
    fs::write(&launcher, "fixture").unwrap();
    fixture.executable(&launcher);
    let fixed = json!({"executable":native_path(&launcher)});
    let mut request = fixture.request();
    request.fixed = Some(&fixed);
    assert!(
        resolve(request, |_, _, _, _| panic!(
            "Passive selection must not run workspace code"
        ))
        .is_err()
    );
    let mut request = fixture.request();
    request.fixed = Some(&fixed);
    request.project_code_allowed = true;
    let selected = resolve(request, |path, _, environment, _| {
        assert_eq!(path, launcher);
        assert_eq!(environment["FIXTURE_SECRET"], "private");
        Ok("compiler 21".into())
    })
    .unwrap()
    .unwrap();
    assert_eq!(selected.executable, launcher);
    assert!(selected.project_code);
    assert!(
        selected.environment.is_empty(),
        "No home or unrelated process environment may be invented"
    );
}
