use crate::plugins::declarative::{
    discover_tests_command, run_plan_command, test_plan_command, validate_command,
};
use serde_json::{json, Value};

macro_rules! contract_file {
    ($path:literal) => {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/",
            $path
        ))
    };
}

const PHP_FIXTURE: &str = contract_file!("fixtures/php-support.plugin.json");
const HELLO_FIXTURE: &str = contract_file!("fixtures/hello-lithe.plugin.json");
const GO_FIXTURE: &str = contract_file!("fixtures/go-support.plugin.json");
const INVALID_MANIFESTS: &str = contract_file!("fixtures/invalid-manifests.json");
const COMMAND_PLANS: &str = contract_file!("fixtures/command-plans.json");
const OFFICIAL_PHP: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/PhpSupport/plugin.json"
));
const OFFICIAL_GO: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/GoSupport/plugin.json"
));

fn fixture(name: &str) -> Value {
    let source = match name {
        "php-support.plugin.json" => PHP_FIXTURE,
        "go-support.plugin.json" => GO_FIXTURE,
        "hello-lithe.plugin.json" => HELLO_FIXTURE,
        other => panic!("unknown fixture {other}"),
    };
    serde_json::from_str(source).expect("fixture manifest is JSON")
}

fn validate(manifest: Value) -> Value {
    validate_command(json!({ "manifest": manifest })).expect("payload is well formed")
}

#[test]
fn contract_fixtures_and_official_plugins_validate() {
    for source in [
        PHP_FIXTURE,
        GO_FIXTURE,
        HELLO_FIXTURE,
        OFFICIAL_PHP,
        OFFICIAL_GO,
    ] {
        let outcome = validate(serde_json::from_str(source).unwrap());
        assert_eq!(outcome["status"], "ok", "{outcome}");
    }
}

#[test]
fn validation_normalizes_order_and_spelling_without_touching_arguments() {
    let mut manifest = fixture("php-support.plugin.json");
    manifest["languages"][0]["fileExtensions"] = json!(["PHTML", ".php", "php"]);
    manifest["permissions"] = json!(["process.test", "process.run", "languageServer.launch"]);
    let outcome = validate(manifest);
    let plugin = &outcome["plugin"];
    assert_eq!(
        plugin["languages"][0]["fileExtensions"],
        json!(["php", "phtml"])
    );
    assert_eq!(
        plugin["permissions"],
        json!(["languageServer.launch", "process.run", "process.test"])
    );
    // Argument order is the command line and must survive normalization.
    assert_eq!(
        plugin["executionProviders"][0]["run"]["arguments"],
        json!(["${file}", "${userArguments}"])
    );
}

/// A leading `.` is optional notation only for extensions. In complete file
/// names and project markers it is part of the name, so hidden files such as
/// `.toolrc` keep matching after normalization.
#[test]
fn validation_keeps_the_leading_dot_of_hidden_file_names() {
    let mut manifest = fixture("go-support.plugin.json");
    manifest["languages"][0]["fileExtensions"] = json!([".go"]);
    manifest["languages"][0]["fileNames"] = json!([".toolrc"]);
    manifest["languages"][0]["projectFileNames"] = json!(["go.mod", ".env.example"]);
    manifest["executionProviders"][0]["test"]["projectMarkers"] = json!([".toolrc", "go.mod"]);
    let outcome = validate(manifest);
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let language = &outcome["plugin"]["languages"][0];
    assert_eq!(language["fileExtensions"], json!(["go"]));
    assert_eq!(language["fileNames"], json!([".toolrc"]));
    assert_eq!(
        language["projectFileNames"],
        json!([".env.example", "go.mod"])
    );
    assert_eq!(
        outcome["plugin"]["executionProviders"][0]["test"]["projectMarkers"],
        json!([".toolrc", "go.mod"])
    );
}

/// Every host must reject these manifests with the same stable code, so a
/// package refused on one platform is never accepted by the other.
#[test]
fn invalid_manifest_fixtures_report_their_stable_codes() {
    let fixtures: Value = serde_json::from_str(INVALID_MANIFESTS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let mut manifest = fixture(case["base"].as_str().unwrap());
        for edit in case["edits"].as_array().unwrap() {
            apply_edit(&mut manifest, edit);
        }
        let outcome = validate(manifest);
        assert_eq!(outcome["status"], "rejected", "{}: {outcome}", case["name"]);
        assert_eq!(
            outcome["error"]["code"], case["expectedCode"],
            "{}: {outcome}",
            case["name"]
        );
    }
}

#[test]
fn command_plan_fixtures_match_golden_expansions() {
    let fixtures: Value = serde_json::from_str(COMMAND_PLANS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let payload = json!({
            "manifest": fixture(case["plugin"].as_str().unwrap()),
            "languageID": case["languageID"],
            "request": case["request"],
        });
        let outcome = match case["operation"].as_str().unwrap() {
            "runPlan" => run_plan_command(payload),
            "discoverTests" => discover_tests_command(payload),
            "testPlan" => test_plan_command(payload),
            other => panic!("unknown operation {other}"),
        }
        .expect("payload is well formed");
        let expected = &case["expected"];
        if expected["status"] == "rejected" {
            assert_eq!(outcome["status"], "rejected", "{}: {outcome}", case["name"]);
            assert_eq!(
                outcome["error"]["code"], expected["code"],
                "{}: {outcome}",
                case["name"]
            );
        } else {
            assert_eq!(&outcome, expected, "{}", case["name"]);
        }
    }
}

#[test]
fn malformed_payload_is_a_core_failure_not_a_rejection() {
    assert!(run_plan_command(json!({ "manifest": {} })).is_err());
    assert!(validate_command(json!("plugin.json")).is_err());
}

fn apply_edit(manifest: &mut Value, edit: &Value) {
    let path = edit["path"].as_str().unwrap();
    let (parent_path, key) = path.rsplit_once('/').unwrap();
    let parent = manifest
        .pointer_mut(parent_path)
        .unwrap_or_else(|| panic!("missing edit parent {parent_path}"));
    match edit["op"].as_str().unwrap() {
        "set" => match parent {
            Value::Object(object) => {
                object.insert(key.to_string(), edit["value"].clone());
            }
            Value::Array(array) => array[key.parse::<usize>().unwrap()] = edit["value"].clone(),
            _ => panic!("edit parent {parent_path} is not a container"),
        },
        "remove" => {
            parent.as_object_mut().unwrap().remove(key);
        }
        other => panic!("unknown edit op {other}"),
    }
}

/// Data-only UI must activate by stable identity, normalize presentation order,
/// and stay unable to invoke a foreign window or inject executable content.
#[test]
fn ui_contributions_are_normalized_without_interpreting_text() {
    let mut manifest = fixture("hello-lithe.plugin.json");
    manifest["ui"]["commands"][0]["placements"] =
        json!(["menu", "toolbar", "menu", "commandPalette"]);
    manifest["ui"]["toolWindows"][0]["text"] = json!("<script>not executable</script>");
    let outcome = validate(manifest);
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"]["ui"]["commands"][0]["placements"],
        json!(["commandPalette", "toolbar", "menu"])
    );
    assert_eq!(
        outcome["plugin"]["ui"]["toolWindows"][0]["text"],
        "<script>not executable</script>"
    );
    for placement in ["left", "bottom", "right"] {
        let mut manifest = fixture("hello-lithe.plugin.json");
        manifest["ui"]["toolWindows"][0]["placement"] = json!(placement);
        let result = validate(manifest);
        assert_eq!(result["status"], "ok", "{result}");
        assert_eq!(
            result["plugin"]["ui"]["toolWindows"][0]["placement"],
            placement
        );
    }
}

/// Icon trust boundaries are shared; native decoding remains with the macOS host.
#[test]
fn ui_icon_declarations_validate_and_preserve_theme_resources() {
    for icon in [
        json!({"host":"database"}),
        json!({"path":"icons/mark.svg"}),
        json!({"path":"icons/mark.png", "darkPath":"icons/mark-dark.png", "mode":"original"}),
    ] {
        let mut manifest = fixture("hello-lithe.plugin.json");
        manifest["ui"]["toolWindows"][0]["icon"] = icon.clone();
        manifest["ui"]["commands"][0]["icon"] = icon.clone();
        let result = validate(manifest);
        assert_eq!(result["status"], "ok", "{result}");
        let mut expected = icon;
        if expected.get("mode").is_none() {
            expected["mode"] = json!("template");
        }
        assert_eq!(result["plugin"]["ui"]["toolWindows"][0]["icon"], expected);
        assert_eq!(result["plugin"]["ui"]["commands"][0]["icon"], expected);
    }
    for icon in [
        json!({}),
        json!({"host":"unknown"}),
        json!({"host":"run","path":"a.svg"}),
        json!({"host":"run","mode":"original"}),
        json!({"path":"../a.svg"}),
        json!({"path":"/a.svg"}),
        json!({"path":"https://host/a.svg"}),
        json!({"path":"a.gif"}),
        json!({"path":"a.svg","darkPath":"../dark.svg"}),
        json!({"path":"a.svg","size":48}),
        json!({"path":"a.svg","color":"red"}),
        json!({"path":"a.svg","mode":"script"}),
        json!({"path":"a//b.svg"}),
        json!({"path":"a/./b.svg"}),
    ] {
        for target in ["toolWindows", "commands"] {
            let mut manifest = fixture("hello-lithe.plugin.json");
            manifest["ui"][target][0]["icon"] = icon.clone();
            assert_eq!(validate(manifest)["status"], "rejected", "{target}: {icon}");
        }
    }
}
