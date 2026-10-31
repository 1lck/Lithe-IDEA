use super::super::super::build_registry::BuildPackageInput;
use super::*;

fn fixtures() -> Vec<Value> {
    [
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../shared/contracts/plugins/v1/fixtures/native-panel.plugin.json"
        )),
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../shared/contracts/plugins/v1/fixtures/native-form.plugin.json"
        )),
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../shared/contracts/plugins/v1/fixtures/native-controls.plugin.json"
        )),
    ]
    .into_iter()
    .map(|text| serde_json::from_str(text).unwrap())
    .collect()
}
fn binding(id: &str, owner: u64, registration: u64) -> Arc<Binding> {
    let manifest = fixtures().remove(0);
    let tool = manifest["ui"]["toolWindows"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    Arc::new(Binding {
        id: id.into(),
        registration,
        window: "main".into(),
        workspace: "/fixture/project".into(),
        plugin_id: manifest["id"].as_str().unwrap().into(),
        tool_window: tool.clone(),
        ui: declaration(&manifest, &tool).unwrap(),
        package_identity: "bytes".into(),
        setting_identity: "settings".into(),
        owner: Arc::new(WindowOwner {
            id: owner,
            alive: AtomicBool::new(true),
        }),
        context: BuildModelContext {
            window_label: "main".into(),
            workspace_root: "/fixture/project".into(),
            generation: 1,
            plugin_id: manifest["id"].as_str().unwrap().into(),
            build_system_id: "sample".into(),
            root: ".".into(),
            package: BuildPackageInput {
                plugin_id: manifest["id"].as_str().unwrap().into(),
                version: "fixture".into(),
                manifest,
                content_identity: "bytes".into(),
            },
            options: Default::default(),
            model: Value::Null,
            model_stale: false,
            revision: 1,
        },
        alive: AtomicBool::new(true),
        busy: AtomicBool::new(false),
    })
}

#[test]
fn three_real_native_fixtures_keep_declarations_and_current_form_values_in_core() {
    for manifest in fixtures() {
        let ui = declaration(
            &manifest,
            manifest["ui"]["toolWindows"][0]["id"].as_str().unwrap(),
        )
        .unwrap();
        let values = (ui["kind"] == "form").then(|| {
            ui["controls"]
                .as_array()
                .unwrap()
                .iter()
                .map(|control| {
                    (
                        control["id"].as_str().unwrap().to_owned(),
                        control["value"].clone(),
                    )
                })
                .collect()
        });
        let (_, params) = parameters(&ui, None, None, values.clone()).unwrap();
        if ui["kind"] == "form" {
            assert_eq!(params, json!({"values":values}));
        } else {
            assert_eq!(params, json!({}));
        }
        for action in ui["actions"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|action| action["kind"] == "invoke")
        {
            let id = action["id"].as_str().unwrap();
            let (selected, build) = selection(&ui, Some(id)).unwrap();
            assert_eq!(selected["function"], action["function"]);
            assert_eq!(build, ui["source"]["buildSystemID"]);
            let (_, params) = parameters(
                &ui,
                Some(id),
                (ui["kind"] != "form").then_some("node"),
                values.clone(),
            )
            .unwrap();
            assert_eq!(
                params["selectedID"],
                if ui["kind"] == "form" {
                    Value::Null
                } else {
                    json!("node")
                }
            );
        }
        assert!(declaration(&manifest, "another.plugin.window").is_err());
        assert!(selection(&ui, Some("frontend.arbitrary.function")).is_err());
    }
}

#[test]
fn full_form_validation_rejects_unknown_missing_wrong_type_and_uncommitted_illegal_values() {
    let manifest = fixtures().remove(2);
    let ui = manifest["ui"]["toolWindows"][0]["native"].clone();
    let values: Map<String, Value> = ui["controls"]
        .as_array()
        .unwrap()
        .iter()
        .map(|control| {
            (
                control["id"].as_str().unwrap().into(),
                control["value"].clone(),
            )
        })
        .collect();
    for value in [
        json!(false),
        json!("x".repeat(1025)),
        json!({"program":"arbitrary"}),
    ] {
        let mut invalid = values.clone();
        invalid.insert("name".into(), value);
        assert!(parameters(&ui, Some("changed"), None, Some(invalid)).is_err());
    }
    let mut missing = values.clone();
    missing.remove("name");
    assert!(parameters(&ui, None, None, Some(missing)).is_err());
    let mut extra = values.clone();
    extra.insert("program".into(), json!("run"));
    assert!(parameters(&ui, None, None, Some(extra)).is_err());
    assert!(parameters(&ui, None, Some("node"), Some(values)).is_err());
    assert!(serde_json::from_value::<Request>(
        json!({"bindingId":"one","operationId":"operation","program":"arbitrary"})
    )
    .is_err());
}

#[test]
fn replacing_a_panel_and_late_close_preserve_the_new_handle_and_other_native_window() {
    let panels = Panels::default();
    let old = binding("old", 1, 1);
    let new = binding("new", 1, 2);
    let other = binding("other", 2, 3);
    panels.insert(old.clone(), |_| Ok(())).unwrap();
    panels.insert(other.clone(), |_| Ok(())).unwrap();
    assert!(panels
        .insert(new.clone(), |_| Err(Error::new(
            "plugin.function.staleContext"
        )))
        .is_err());
    assert!(
        panels.get("old", &old.owner).is_ok(),
        "failed late admission preserves the prior owner"
    );
    panels.insert(new.clone(), |_| Ok(())).unwrap();
    assert!(!old.alive.load(Ordering::Acquire));
    panels.revoke(|binding| binding.id == "old");
    assert!(panels.get("new", &new.owner).is_ok());
    assert!(panels.get("other", &new.owner).is_err());
    panels.revoke(|binding| binding.owner.id == 1);
    assert!(panels.get("new", &new.owner).is_err());
    assert!(panels.get("other", &other.owner).is_ok());
}

#[test]
fn a_late_old_open_cannot_replace_the_newer_registered_panel() {
    let panels = Panels::default();
    let old = binding("old", 1, 1);
    let new = binding("new", 1, 2);
    // The old request starts first, but its async catalog/model lookup
    // completes only after the replacement is registered.
    panels.insert(new.clone(), |_| Ok(())).unwrap();
    assert_eq!(
        panels.insert(old, |_| Ok(())).unwrap_err().code,
        "plugin.function.staleContext"
    );
    panels.revoke(|binding| binding.id == "old");
    assert!(panels.get("new", &new.owner).is_ok());
    assert!(new.alive.load(Ordering::Acquire));
}

#[test]
fn an_old_released_permit_cannot_clear_a_later_approval_or_cleanup_slot() {
    let binding = binding("one", 1, 1);
    binding.busy.store(true, Ordering::Release);
    let old = Permit {
        binding: binding.clone(),
        released: AtomicBool::new(false),
    };
    old.release();
    assert!(!binding.busy.swap(true, Ordering::AcqRel));
    drop(old);
    assert!(binding.busy.load(Ordering::Acquire));
}

#[test]
fn native_source_never_guesses_between_missing_multiple_or_foreign_instances() {
    let instance = json!({"pluginID":"plugin","buildSystemID":"system","root":"nested"});
    assert!(unique_root(&[], "plugin", "system").is_err());
    assert!(unique_root(&[instance.clone(), instance.clone()], "plugin", "system").is_err());
    assert!(unique_root(&[instance.clone()], "foreign", "system").is_err());
    assert!(unique_root(&[instance.clone()], "plugin", "foreign").is_err());
    assert_eq!(
        unique_root(&[instance], "plugin", "system").unwrap(),
        "nested"
    );
}

#[test]
fn source_results_have_the_shared_core_node_rules_and_one_mib_budget() {
    let binding = binding("one", 1, 1);
    let call = Call {
        ui: binding.ui.clone(),
        binding: binding.clone(),
        _permit: Permit {
            binding,
            released: AtomicBool::new(false),
        },
        action: None,
        params: json!({}),
    };
    assert!(validate_result(&call, json!({"nodes":[{"id":"a","label":"Valid"}]})).is_ok());
    assert!(validate_result(
        &call,
        json!({"nodes":[{"id":"a","label":"A"},{"id":"a","label":"Duplicate"}]})
    )
    .is_err());
    assert!(validate_result(&call, json!({"nodes":[],"program":"arbitrary"})).is_err());
    assert_eq!(
        validate_result(&call, json!({"nodes":[],"large":"x".repeat(1024*1024)}))
            .unwrap_err()
            .code,
        "plugin.function.resultTooLarge"
    );
}
