//! Deterministic local-pin validation and component-wise inheritance regressions.

use crate::toolchain::pins;
use serde_json::{json, Value};

/// Loads inert contract data; none of its fictional paths are probed.
fn fixture() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/proposals/toolchains/fixtures/local.json"
    )))
    .unwrap()
}

/// Exercises the pure input boundary with a selected directory and arbitrary tool.
fn resolve(document: &Value, directory: &str, tool: &str) -> Value {
    pins::resolve(&json!({"document":document,"directory":directory,"tool":tool})).unwrap()
}

/// Produces a valid inert pin for independent validation scenarios.
fn pin(home: &str) -> Value {
    json!({"home":home,"version":"21.0.4","provider":"host:manual"})
}

#[test]
fn toolchain_pins_contract_fixture_inherits_the_nearest_ancestor() {
    let document = fixture();
    pins::validate(&document).unwrap();
    for (directory, expected) in [
        (".", "."),
        ("apps", "."),
        ("apps/web", "apps/web"),
        ("apps/web/src/main", "apps/web"),
        (".config/tools/settings", ".config/tools"),
    ] {
        let result = resolve(&document, directory, "java");
        assert_eq!(result["sourceDirectory"], expected, "{directory}");
        assert_eq!(result["pin"], document["pins"][expected]["java"]);
    }
}

#[test]
fn toolchain_pins_do_not_match_sibling_prefixes_or_other_tools() {
    let document = fixture();
    assert_eq!(
        resolve(&document, "apps/website/src", "java")["sourceDirectory"],
        "."
    );
    assert_eq!(
        resolve(&document, "apps/web/src", "node"),
        json!({"pin":null,"sourceDirectory":null})
    );
    assert_eq!(
        resolve(&json!({"version":1,"toolchains":{}}), ".", "java"),
        json!({"pin":null,"sourceDirectory":null})
    );
    assert_eq!(
        resolve(&json!({"version":1,"toolchains":{},"pins":{}}), ".", "java"),
        json!({"pin":null,"sourceDirectory":null})
    );
}

#[test]
fn toolchain_pins_retain_dormant_namespaced_values_and_legacy_data() {
    let document = json!({
        "version":1,
        "toolchains":{"project-jdk":{"home":"relative legacy home","javaHome":"legacy JDK"},"custom old key":{"executable":"legacy-command"}},
        "pins":{".":{"dev.lithe.fixture.disabled:compiler":pin("/opt/lithe-fixtures/compiler")}}
    });
    let before = document.clone();
    let result = resolve(&document, "src", "dev.lithe.fixture.disabled:compiler");
    assert_eq!(
        result["pin"],
        document["pins"]["."]["dev.lithe.fixture.disabled:compiler"]
    );
    assert_eq!(document, before);
    assert!(resolve(&document, ".", "java")["pin"].is_null());
}

#[test]
fn toolchain_pins_validate_every_entry_not_only_the_requested_tool() {
    let mut document = fixture();
    document["pins"]["unrelated"] =
        json!({"node":{"home":"relative","version":"22","provider":"host:manual"}});
    let error =
        pins::resolve(&json!({"document":document,"directory":".","tool":"java"})).unwrap_err();
    assert_eq!(error.code(), "plugin.toolchain.invalidParams");
    assert_eq!(error.field(), Some("document.pins.unrelated.node.home"));
}

#[test]
fn toolchain_pins_reject_non_normalized_directories_but_allow_dotted_names() {
    for directory in [
        "",
        "/root",
        "../parent",
        "src/../lib",
        "src/./lib",
        "src//lib",
        "src/",
        "src\\lib",
        "C:/root",
        "src\nlib",
    ] {
        let mut document = fixture();
        document["pins"][directory] = json!({"java":pin("/opt/lithe-fixtures/java")});
        assert!(
            pins::validate(&document).is_err(),
            "document key {directory:?}"
        );
        assert!(
            pins::resolve(&json!({"document":fixture(),"directory":directory,"tool":"java"}))
                .is_err(),
            "requested directory {directory:?}"
        );
    }
    for directory in [".config/tools", "foo.bar/.hidden", "a..b", "."] {
        assert!(
            pins::resolve(&json!({"document":fixture(),"directory":directory,"tool":"java"}))
                .is_ok(),
            "{directory}"
        );
    }
}

#[test]
fn toolchain_pins_accept_cross_platform_absolute_paths_without_io() {
    for home in [
        "/opt/lithe-fixtures/java",
        "/",
        "C:\\Toolchains\\Java",
        "D:/Tools/Java",
        "C:\\",
        "\\\\server\\share\\tools",
        "\\\\server\\share",
        "\\\\server\\share\\",
        "//server/share/tools",
    ] {
        let document = json!({"version":1,"toolchains":{},"pins":{".":{"java":pin(home)}}});
        assert_eq!(resolve(&document, ".", "java")["pin"]["home"], home);
    }
    for home in [
        "relative",
        "~/java",
        "C:relative",
        "\\rooted",
        "\\\\server",
        "\\\\?\\C:\\tools",
        "\\\\.\\tools",
        "C:/tools/../java",
        "/opt/../java",
        "/opt//java",
        "//",
        "C://",
        "/opt/./java",
        "C:/tools:stream",
        "C:/tools./java",
        "C:/tools /java",
        "/opt/ja\nva",
    ] {
        let document = json!({"version":1,"toolchains":{},"pins":{".":{"java":pin(home)}}});
        assert!(pins::validate(&document).is_err(), "{home:?}");
    }
}

#[test]
fn toolchain_pins_reject_invalid_tools_providers_and_unknown_fields() {
    for tool in [
        "",
        "Java",
        "dev..fixture:tool",
        "dev.fixture:",
        "dev.fixture:Tool",
        "a:b:c",
        "a/b",
    ] {
        assert!(
            pins::resolve(&json!({"document":fixture(),"directory":".","tool":tool})).is_err(),
            "{tool:?}"
        );
        let document = json!({"version":1,"toolchains":{},"pins":{".":{tool:pin("/opt/lithe-fixtures/java")}}});
        assert!(pins::validate(&document).is_err(), "{tool:?}");
    }
    for provider in [
        "mise",
        "host:",
        "host:Manual",
        "Host:manual",
        "1host:manual",
        "dev..fixture:mise",
        "host:manual:extra",
    ] {
        let mut document = fixture();
        document["pins"]["."]["java"]["provider"] = json!(provider);
        assert!(pins::validate(&document).is_err(), "{provider}");
    }
    let mut document = fixture();
    document["extra"] = json!(true);
    assert!(pins::validate(&document).is_err());
    let mut document = fixture();
    document["pins"]["."]["java"]["extra"] = json!(true);
    assert!(pins::validate(&document).is_err());
    let document = json!({"version":1,"toolchains":{"old":{"unknown":"path"}}});
    assert!(pins::validate(&document).is_err());
    assert!(pins::resolve(
        &json!({"document":fixture(),"directory":".","tool":"java","unknown":true})
    )
    .is_err());
}

#[test]
fn toolchain_pins_reject_missing_fields_and_wrong_shapes() {
    for document in [
        Value::Null,
        json!({}),
        json!({"version":2,"toolchains":{}}),
        json!({"version":1,"toolchains":[]}),
        json!({"version":1,"toolchains":{},"pins":null}),
        json!({"version":1,"toolchains":{},"pins":{".":[]}}),
    ] {
        assert!(pins::validate(&document).is_err(), "{document}");
    }
    for property in ["home", "version", "provider"] {
        let mut document = fixture();
        document["pins"]["."]["java"]
            .as_object_mut()
            .unwrap()
            .remove(property);
        assert!(pins::validate(&document).is_err(), "missing {property}");
        let mut document = fixture();
        document["pins"]["."]["java"][property] = json!(42);
        assert!(pins::validate(&document).is_err(), "numeric {property}");
    }
}

#[test]
fn toolchain_pins_enforce_collection_and_text_limits_before_resolution() {
    let mut document = json!({"version":1,"toolchains":{},"pins":{}});
    for index in 0..1025 {
        document["pins"][format!("dir-{index}")] = json!({});
    }
    assert_eq!(
        pins::validate(&document).unwrap_err().code(),
        "plugin.toolchain.limitExceeded"
    );
    let mut document = json!({"version":1,"toolchains":{},"pins":{".":{}}});
    for index in 0..65 {
        document["pins"]["."][format!("tool-{index}")] = pin("/opt/lithe-fixtures/tool");
    }
    assert_eq!(
        pins::validate(&document).unwrap_err().code(),
        "plugin.toolchain.limitExceeded"
    );
    for (property, length) in [("home", 4097), ("version", 129), ("provider", 257)] {
        let mut document = fixture();
        document["pins"]["."]["java"][property] = json!("x".repeat(length));
        assert_eq!(
            pins::validate(&document).unwrap_err().code(),
            "plugin.toolchain.limitExceeded",
            "{property}"
        );
    }
    let mut document = fixture();
    document["pins"]["x".repeat(2049)] = json!({});
    assert_eq!(
        pins::validate(&document).unwrap_err().code(),
        "plugin.toolchain.limitExceeded"
    );
}
