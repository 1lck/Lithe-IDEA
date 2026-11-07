//! `java.*` commands that still answer from the Windows host. Copied from Core's
//! `tests/languages.rs`; Core keeps its own copy until the macOS migration lands.

use super::support::execute_json;
use serde_json::Value;

#[test]
fn java_workspace_policy_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../../shared/fixtures/lsp/java-workspace-policy-v1.json"
    ))
    .expect("Java workspace-policy fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("Java workspace-policy fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.workspacePolicy",
            "payload": {
                "workspacePaths": case["workspacePaths"],
                "changedPaths": case["changedPaths"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("Java workspace-policy response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn jdt_workspace_fingerprint_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../../shared/fixtures/lsp/jdt-workspace-fingerprint-v1.json"
    ))
    .expect("JDT workspace-fingerprint fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT workspace-fingerprint fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.jdtWorkspaceFingerprint",
            "payload": {
                "buildFiles": case["buildFiles"],
                "directMavenModules": case["directMavenModules"],
                "gradleWrapperDistribution": case["gradleWrapperDistribution"],
                "jdtlsVersion": case["jdtlsVersion"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT workspace-fingerprint response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(
            response["data"]["workspaceFingerprint"], case["workspaceFingerprint"],
            "case {}",
            case["name"]
        );
    }
}

#[test]
fn jdt_cache_retention_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../../shared/fixtures/lsp/jdt-cache-retention-v1.json"
    ))
    .expect("JDT cache-retention fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT cache-retention fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.jdtCacheRetention",
            "payload": {
                "nowUnixSeconds": case["nowUnixSeconds"],
                "activeWorkspaceKey": case["activeWorkspaceKey"],
                "entries": case["entries"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT cache-retention response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn java_run_markers_match_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../../shared/fixtures/java/run-markers-v1.json"
    ))
    .expect("Java Run-marker fixture should be valid JSON");
    for case in fixture["cases"]
        .as_array()
        .expect("Java Run-marker fixture should contain cases")
    {
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": case["name"],
                "command": "java.runMarkers",
                "payload": case["request"]
            })
            .to_string(),
        ))
        .expect("Java Run-marker response should be JSON");
        assert_eq!(response["ok"], true, "case {}: {response}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn java_source_definition_finds_types_and_members() {
    let definition = serde_json::json!({
        "id": "java-definition",
        "command": "java.sourceDefinition",
        "payload": {
            "source": "class App {\n    void run() {}\n}",
            "declarationName": "App",
            "memberName": "run"
        }
    });
    let definition_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&definition).expect("definition request should encode"),
    ))
    .expect("definition response should be JSON");
    assert_eq!(definition_response["data"]["line"], 1);
    let member_lookup = |member: &str, declarations_only: bool| -> Value {
        let request = serde_json::json!({
            "id": "java-member",
            "command": "java.sourceDefinition",
            "payload": {
                "source": "class App {\n    void run() { save(); total = 1; }\n    String 名字, total;\n    void save() {}\n}",
                "declarationName": "App",
                "memberName": member,
                "declarationsOnly": declarations_only
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("member request should encode"),
        ))
        .expect("member response should be JSON");
        response["data"].clone()
    };
    // The call and the assignment on line 1 come first but declare nothing.
    assert_eq!(member_lookup("save", true)["line"], 3);
    assert_eq!(member_lookup("total", true)["line"], 2);
    assert_eq!(member_lookup("total", true)["utf16Column"], 15);
    assert!(member_lookup("missing", true).is_null());
    assert_eq!(member_lookup("missing", false)["line"], 0);
}

/// Resolves the member at the first occurrence of `marker` in `source`, the
/// marker being the text up to and including the start of the name.
fn referenced_member_line(source: &str, marker: &str, member: &str) -> Value {
    let offset = source.find(marker).expect("marker should exist") + marker.len() - member.len();
    let before = &source[..offset];
    let line = before.matches('\n').count();
    let column = before[before.rfind('\n').map_or(0, |index| index + 1)..]
        .encode_utf16()
        .count();
    let request = serde_json::json!({
        "id": "java-reference",
        "command": "java.sourceDefinition",
        "payload": {
            "source": source,
            "declarationName": "Main",
            "memberName": member,
            "declarationsOnly": true,
            "reference": { "line": line, "utf16Column": column }
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("reference request should encode"),
    ))
    .expect("reference response should be JSON");
    assert_eq!(response["ok"], true, "{response}");
    response["data"]["line"].clone()
}

#[test]
fn java_member_definition_stays_inside_the_named_type() {
    let lookup = |declaration: &str| -> Value {
        let request = serde_json::json!({
            "id": "java-member",
            "command": "java.sourceDefinition",
            "payload": {
                "source": "class Main {\n  class Nested {\n    void save() {}\n  }\n  void save() {}\n}\nclass Other {\n  void only() {}\n}",
                "declarationName": declaration,
                "memberName": "save",
                "declarationsOnly": true
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("member request should encode"),
        ))
        .expect("member response should be JSON");
        response["data"]["line"].clone()
    };
    assert_eq!(lookup("Main"), 4);
    assert_eq!(lookup("Nested"), 2);
    assert!(lookup("Other").is_null());
    assert!(lookup("Missing").is_null());
}

#[test]
fn java_member_reference_binds_to_the_type_it_is_used_in() {
    let source = "class Main {\n  class Nested {\n    void save() {}\n    void use() { save(); }\n  }\n  void save() {}\n  void run() { this.save(); }\n}";
    assert_eq!(referenced_member_line(source, "use() { save", "save"), 2);
    assert_eq!(referenced_member_line(source, "this.save", "save"), 5);

    let outer = "class Main {\n  void save() {}\n  class Nested {\n    void use() { save(); this.save(); }\n  }\n}";
    assert_eq!(referenced_member_line(outer, "use() { save", "save"), 1);
    assert!(referenced_member_line(outer, "this.save", "save").is_null());
}

#[test]
fn java_member_reference_keeps_methods_and_fields_apart() {
    let source = "class Main {\n  int save;\n  void save() {}\n  void run() { save(); int x = this.save; }\n}";
    assert_eq!(referenced_member_line(source, "run() { save", "save"), 2);
    assert_eq!(referenced_member_line(source, "this.save", "save"), 1);
}

#[test]
fn java_member_reference_answers_nothing_syntax_cannot_prove() {
    let unknown_receiver =
        "class Main {\n  void save() {}\n  void run(Main other) { other.save(); }\n}";
    assert!(referenced_member_line(unknown_receiver, "other.save", "save").is_null());
    let method_reference = "class Main {\n  void save() {}\n  Runnable run = this::save;\n}";
    assert!(referenced_member_line(method_reference, "this::save", "save").is_null());

    // `Base` may declare `save`, and it would win over `Main.save`.
    let inherited = "class Main {\n  void save() {}\n  class Nested extends Base {\n    void use() { save(); }\n  }\n}";
    assert!(referenced_member_line(inherited, "use() { save", "save").is_null());
    let anonymous = "class Main {\n  void save() {}\n  Object task = new Object() {\n    void use() { save(); }\n  };\n}";
    assert!(referenced_member_line(anonymous, "use() { save", "save").is_null());

    for (shadowed, marker) in [
        ("class Main {\n  int value;\n  int run() { int value = 1; return value; }\n}", "return value"),
        ("class Main {\n  int value;\n  int run(int value) { return value; }\n}", "return value"),
        ("class Main {\n  int value;\n  void run() { for (int value : items) { use(value); } }\n}", "use(value"),
        ("class Main {\n  int value;\n  void run() { try {} catch (Exception value) { use(value); } }\n}", "use(value"),
        ("class Main {\n  int value;\n  Fn run = value -> use(value);\n}", "use(value"),
        ("class Main {\n  int value;\n  Fn run = (value, other) -> use(value);\n}", "use(value"),
        ("class Main {\n  int value;\n  void run(Object o) { if (o instanceof String value) { use(value); } }\n}", "use(value"),
    ] {
        assert!(
            referenced_member_line(shadowed, marker, "value").is_null(),
            "{shadowed}"
        );
    }
    // `this.` skips the local, and a local in a nested type's method does not count.
    let qualified = "class Main {\n  int value;\n  int run(int value) { return this.value; }\n}";
    assert_eq!(referenced_member_line(qualified, "this.value", "value"), 1);
    let plain = "class Main {\n  int value;\n  int run() { return value; }\n}";
    assert_eq!(referenced_member_line(plain, "return value", "value"), 1);
}

#[test]
fn java_member_reference_covers_enum_and_record_scopes() {
    let enumeration = "enum Main {\n  ONE;\n  int total;\n  int run() { return total; }\n}";
    assert_eq!(
        referenced_member_line(enumeration, "return total", "total"),
        2
    );
    // A record component is a field, so the outer field must not answer.
    let record =
        "class Main {\n  int x;\n  record Point(int x) {\n    int run() { return x; }\n  }\n}";
    assert_eq!(referenced_member_line(record, "return x", "x"), 2);
}

#[test]
fn java_member_reference_ignores_a_position_outside_the_source() {
    let source = "class Main {\n  void save() {}\n  void run() { save(); }\n}";
    let request = serde_json::json!({
        "id": "java-reference",
        "command": "java.sourceDefinition",
        "payload": {
            "source": source,
            "declarationName": "Main",
            "memberName": "save",
            "declarationsOnly": true,
            "reference": { "line": 9, "utf16Column": 0 }
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("reference request should encode"),
    ))
    .expect("reference response should be JSON");
    assert!(response["data"].is_null());
}
