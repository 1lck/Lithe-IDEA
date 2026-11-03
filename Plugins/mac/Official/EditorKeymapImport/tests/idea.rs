use lithe_editor_keymap_import::idea::import;
use serde_json::json;
use std::collections::BTreeMap;

fn files(items: &[(&str, &str)]) -> BTreeMap<String, String> {
    items
        .iter()
        .map(|(path, content)| (path.to_string(), content.to_string()))
        .collect()
}
#[test]
fn inherits_default_scheme_and_imports_custom_actions() {
    let source = files(&[
        ("options/keymap.xml", "<application><component name='KeymapManager'><active_keymap name='Mine'/></component></application>"),
        ("keymaps/mine.xml", "<keymap name='Mine' parent='Mac OS X 10.5+'><action id='ToggleLineBreakpoint'><keyboard-shortcut first-keystroke='meta alt B'/></action><action id='GotoAction'><keyboard-shortcut first-keystroke='meta shift A'/></action></keymap>"),
    ]);
    let result = import(&source).unwrap();
    let bindings = result["bindings"].as_array().unwrap();
    assert!(bindings.contains(
        &json!({"commandID":"toggle-breakpoint", "keys":[{"key":"b", "modifiers":["alt","meta"]}]})
    ));
    assert!(bindings.contains(
        &json!({"commandID":"find-action", "keys":[{"key":"a", "modifiers":["shift","meta"]}]})
    ));
    assert!(bindings
        .contains(&json!({"commandID":"go-to-line", "keys":[{"key":"l", "modifiers":["meta"]}]})));
}
#[test]
fn rejects_external_entities_duplicate_names_and_cycles() {
    assert!(import(&files(&[(
        "options/keymap.xml",
        "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///private'>]><application/>"
    )]))
    .is_err());
    let active = ("options/keymap.xml", "<application><component name='KeymapManager'><active_keymap name='A'/></component></application>");
    assert!(import(&files(&[
        active,
        ("keymaps/a.xml", "<keymap name='A' parent='B'/>"),
        ("keymaps/b.xml", "<keymap name='B' parent='A'/>")
    ]))
    .is_err());
    assert!(import(&files(&[
        active,
        ("keymaps/a.xml", "<keymap name='A'/>"),
        ("keymaps/b.xml", "<keymap name='A'/>")
    ]))
    .is_err());
    assert!(import(&files(&[("options/keymap.xml", "<other/>")])).is_err());
    assert!(import(&files(&[(
        "options/keymap.xml",
        "<application><component name='KeymapManager'><active_keymap/></component></application>"
    )]))
    .is_err());
}

#[test]
fn macos_defaults_cover_navigation_and_breakpoint_actions() {
    let result = import(&files(&[])).unwrap();
    let entries = result["bindings"].as_array().unwrap();
    for (id, key, modifiers) in [
        ("toggle-breakpoint", "f8", vec!["meta"]),
        ("view-breakpoints", "f8", vec!["shift", "meta"]),
        ("find-action", "a", vec!["shift", "meta"]),
        ("go-to-implementation", "b", vec!["alt", "meta"]),
        ("find-in-file", "f", vec!["meta"]),
        ("find-usages", "f7", vec!["alt"]),
    ] {
        assert!(
            entries.contains(&json!({"commandID":id,"keys":[{"key":key,"modifiers":modifiers}]})),
            "missing {id}"
        );
    }
}

#[test]
fn child_schemes_mask_claimed_parent_keys_and_do_not_promote_chords() {
    let source = files(&[
        ("options/keymap.xml", "<application><component name='KeymapManager'><active_keymap name='Mine'/></component></application>"),
        ("keymaps/mine.xml", "<keymap name='Mine' parent='Mac OS X 10.5+'><action id='UnknownAction'><keyboard-shortcut first-keystroke='meta L'/></action><action id='FindNext'><keyboard-shortcut first-keystroke='meta K' second-keystroke='meta S'/></action></keymap>"),
    ]);
    let result = import(&source).unwrap();
    let entries = result["bindings"].as_array().unwrap();
    assert!(entries.contains(&json!({"commandID":"go-to-line", "keys":[]})));
    assert!(entries.contains(&json!({"commandID":"find-next", "keys":[]})));
    assert!(!entries
        .iter()
        .flat_map(|entry| entry["keys"].as_array().unwrap())
        .any(|key| key["key"] == "s"));
}

#[test]
fn classic_scheme_keeps_its_own_line_and_find_bindings() {
    let source = files(&[("options/keymap.xml", "<application><component name='KeymapManager'><active_keymap name='Mac OS X'/></component></application>")]);
    let result = import(&source).unwrap();
    let entries = result["bindings"].as_array().unwrap();
    assert!(entries
        .contains(&json!({"commandID":"go-to-line", "keys":[{"key":"g", "modifiers":["meta"]}]})));
    assert!(entries.contains(&json!({"commandID":"find-next", "keys":[{"key":"f3", "modifiers":[]}, {"key":"l", "modifiers":["control"]}]})));
}
