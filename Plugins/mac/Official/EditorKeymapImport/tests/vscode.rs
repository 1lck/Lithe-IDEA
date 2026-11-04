use lithe_editor_keymap_import::vscode::import;
use serde_json::json;

#[test]
fn imports_jsonc_user_actions_and_real_default_breakpoint() {
    let result = import(
        r#"[
      // User override for a common navigation command.
      {"key":"cmd+alt+n","command":"editor.action.nextMatchFindAction"},
      {"key":"cmd+alt+b","command":"editor.debug.action.toggleBreakpoint"},
    ]"#,
    )
    .unwrap();
    assert!(result["bindings"].as_array().unwrap().contains(&json!({"commandID":"find-next", "keys":[{"key":"n","modifiers":["alt","meta"]},{"key":"g","modifiers":["meta"]}]})));
    assert!(result["bindings"].as_array().unwrap().contains(&json!({"commandID":"toggle-breakpoint", "keys":[{"key":"b","modifiers":["alt","meta"]},{"key":"f9","modifiers":[]}]})));
    let defaults = import("[]").unwrap();
    assert!(defaults["bindings"]
        .as_array()
        .unwrap()
        .contains(&json!({"commandID":"toggle-breakpoint", "keys":[{"key":"f9","modifiers":[]}]})));
    assert!(!defaults["bindings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| row["commandID"] == "debug-resume"));
}

#[test]
fn conditional_chords_and_unknown_owners_never_become_global() {
    let result = import(
        r#"[
      {"key":"cmd+f","command":"extension.other","when":"editorFocus"},
      {"key":"ctrl+` ctrl+c","command":"extension.other"},
      {"key":"cmd+alt+x","command":"editor.action.goToImplementation","when":"editorFocus"}
    ]"#,
    )
    .unwrap();
    let entries = result["bindings"].as_array().unwrap();
    assert!(entries
        .iter()
        .any(|row| row["commandID"] == "find-in-file" && row["keys"] == json!([])));
    assert!(entries
        .iter()
        .any(|row| row["commandID"] == "toggle-terminal" && row["keys"] == json!([])));
    assert!(entries.contains(
        &json!({"commandID":"go-to-implementation", "keys":[{"key":"f12", "modifiers":["meta"]}]})
    ));
}

#[test]
fn rejects_json5_extensions_and_malformed_rules() {
    assert!(import("[{key:'cmd+x',command:'actions.find'}]").is_err());
    assert!(import("{} ").is_err());
}

#[test]
fn user_additions_keep_other_effective_keys_and_removals_only_remove_the_named_key() {
    let result = import(
        r#"[
      {"key":"cmd+alt+b","command":"editor.debug.action.toggleBreakpoint"},
      {"key":"ctrl+alt+b","command":"editor.debug.action.toggleBreakpoint"},
      {"key":"f9","command":"-editor.debug.action.toggleBreakpoint"}
    ]"#,
    )
    .unwrap();
    let binding = result["bindings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["commandID"] == "toggle-breakpoint")
        .unwrap();
    assert_eq!(
        binding["keys"],
        json!([
            {"key":"b","modifiers":["control","alt"]},
            {"key":"b","modifiers":["alt","meta"]}
        ])
    );
}

#[test]
fn removal_only_targets_the_named_default_and_never_user_bindings() {
    let result = import(
        r#"[
      {"key":"cmd+s","command":"-workbench.action.debug.start"},
      {"key":"cmd+alt+b","command":"editor.debug.action.toggleBreakpoint"},
      {"key":"cmd+alt+b","command":"-editor.debug.action.toggleBreakpoint"},
      {"key":"f9","command":"-editor.debug.action.toggleBreakpoint"}
    ]"#,
    )
    .unwrap();
    let entries = result["bindings"].as_array().unwrap();
    assert!(
        entries.contains(&json!({"commandID":"save", "keys":[{"key":"s","modifiers":["meta"]}]}))
    );
    assert!(entries.contains(
        &json!({"commandID":"toggle-breakpoint", "keys":[{"key":"b","modifiers":["alt","meta"]}]})
    ));
    let no_key = import(r#"[{"command":"-workbench.action.showCommands"}]"#).unwrap();
    assert!(no_key["bindings"]
        .as_array()
        .unwrap()
        .contains(&json!({"commandID":"find-action", "keys":[]})));
}

#[test]
fn conditional_removal_does_not_remove_an_unconditional_default() {
    let result = import(
        r#"[{"key":"cmd+s","command":"-workbench.action.files.save","when":"editorTextFocus"}]"#,
    )
    .unwrap();
    let bindings = result["bindings"].as_array().unwrap();
    assert!(
        bindings.contains(&json!({"commandID":"save","keys":[{"key":"s","modifiers":["meta"]}]}))
    );
    let unconditional =
        import(r#"[{"key":"cmd+s","command":"-workbench.action.files.save","when":"true"}]"#)
            .unwrap();
    assert!(unconditional["bindings"]
        .as_array()
        .unwrap()
        .contains(&json!({"commandID":"save","keys":[]})));
}

#[test]
fn default_common_commands_match_the_published_macos_reference() {
    let result = import("[]").unwrap();
    let entries = result["bindings"].as_array().unwrap();
    for (id, keys) in [
        ("find-next", json!([{"key":"g","modifiers":["meta"]}])),
        (
            "find-previous",
            json!([{"key":"g","modifiers":["shift","meta"]}]),
        ),
        (
            "go-to-implementation",
            json!([{"key":"f12","modifiers":["meta"]}]),
        ),
        (
            "find-action",
            json!([{"key":"p","modifiers":["shift","meta"]},{"key":"f1","modifiers":[]}]),
        ),
        ("debug-step-over", json!([{"key":"f10","modifiers":[]}])),
        (
            "debug-start-or-continue",
            json!([{"key":"f5","modifiers":[]}]),
        ),
        ("debug-step-into", json!([{"key":"f11","modifiers":[]}])),
        (
            "debug-step-out",
            json!([{"key":"f11","modifiers":["shift"]}]),
        ),
        ("stop-debug", json!([{"key":"f5","modifiers":["shift"]}])),
    ] {
        assert!(
            entries.contains(&json!({"commandID":id,"keys":keys})),
            "missing {id}"
        );
    }
}

#[test]
fn later_rules_shadow_earlier_claims_without_promoting_chords() {
    let result = import(
        r#"[
      {"key":"cmd+alt+b", "command":"workbench.action.navigateBack"},
      {"key":"cmd+alt+b ctrl+c", "command":"extension.other"},
      {"key":"cmd+alt+b", "command":"workbench.action.navigateForward"}
    ]"#,
    )
    .unwrap();
    let entries = result["bindings"].as_array().unwrap();
    let back = entries
        .iter()
        .find(|entry| entry["commandID"] == "navigate-back")
        .unwrap();
    assert!(!back["keys"]
        .as_array()
        .unwrap()
        .iter()
        .any(|key| key["key"] == "b"));
    let forward = entries
        .iter()
        .find(|entry| entry["commandID"] == "navigate-forward")
        .unwrap();
    assert_eq!(
        forward["keys"][0],
        json!({"key":"b", "modifiers":["alt","meta"]})
    );
    assert!(!entries
        .iter()
        .flat_map(|entry| entry["keys"].as_array().unwrap())
        .any(|key| key["key"] == "c"));
}
