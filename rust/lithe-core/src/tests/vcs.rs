//! VCS providers declared by API level 3 plugins: manifest validation,
//! install review, launch plans, root detection over real directories, and
//! reply decoding, checked against `shared/fixtures/vcs/model-v1.json` and
//! the Subversion provider manifest fixture.

use super::support::temporary_root;
use crate::plugins::declarative::{language_server_launch_plan_command, validate_command};
use crate::plugins::marketplace::install_review_command;
use crate::protocol::ErrorCode;
use crate::vcs::{
    negotiated_capabilities, vcs_decode_reply_command, vcs_detect_roots_command,
    vcs_owner_of_command,
};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const MODEL: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/fixtures/vcs/model-v1.json"
));
const SVN_PROVIDER: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
));

fn model() -> Value {
    serde_json::from_str(MODEL).expect("the VCS model fixture is JSON")
}

fn svn_provider() -> Value {
    serde_json::from_str(SVN_PROVIDER).expect("the provider fixture is JSON")
}

fn validate(manifest: Value) -> Value {
    validate_command(json!({ "manifest": manifest })).expect("well-formed payload")
}

/// Removes its directory when dropped, so a failed assertion cleans up too.
struct Sandbox(PathBuf);

impl Sandbox {
    fn new(label: &str) -> Self {
        let root = temporary_root(label);
        fs::create_dir_all(&root).unwrap();
        // Detection reports resolved paths, and the temporary directory is
        // itself behind a link on macOS.
        Self(root.canonicalize().unwrap())
    }

    fn directory(&self, relative: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(&path).unwrap();
        path
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn the_provider_fixture_validates_and_is_reviewed_with_its_tool() {
    let outcome = validate(svn_provider());
    assert_eq!(outcome["status"], "ok", "{outcome}");

    let review = install_review_command(json!({ "manifest": svn_provider() })).unwrap();
    assert_eq!(review["status"], "ok", "{review}");
    let programs = review["review"]["programs"].as_array().unwrap();
    let provider = programs
        .iter()
        .find(|program| program["kind"] == "runtimeVcsProvider")
        .unwrap_or_else(|| panic!("no provider program: {programs:?}"));
    assert_eq!(provider["vcs"], "svn");
    assert_eq!(provider["tool"], "node", "{provider}");
    assert_eq!(provider["entry"], "provider/main.mjs");
    assert_eq!(
        provider["vcsTool"],
        json!({ "commands": ["svn"], "validationArguments": ["--version", "--quiet"] })
    );
    assert_eq!(provider["mayUseNetwork"], true);
    assert!(
        programs.contains(&json!({ "kind": "runtime", "tool": "node", "minimumVersion": "20.3" })),
        "{programs:?}"
    );
}

/// A provider changes the working copy and starts its own process, so the
/// manifest must ask for both, name its activation event, and say which
/// contract versions it needs; Git stays reserved for the built-in support.
#[test]
fn provider_manifests_state_permissions_activation_and_requirements() {
    let rejected = |mutate: fn(&mut Value)| {
        let mut manifest = svn_provider();
        mutate(&mut manifest);
        let outcome = validate(manifest);
        assert_eq!(outcome["status"], "rejected", "{outcome}");
        outcome["error"].clone()
    };
    let missing_permission = rejected(|manifest| {
        manifest["permissions"] = json!(["languageServer.launch"]);
    });
    assert_eq!(
        missing_permission["field"], "permissions",
        "{missing_permission}"
    );
    let missing_launch = rejected(|manifest| manifest["permissions"] = json!(["process.vcs"]));
    assert_eq!(missing_launch["field"], "permissions", "{missing_launch}");
    let missing_activation = rejected(|manifest| manifest["activationEvents"] = json!([]));
    assert_eq!(
        missing_activation["field"], "activationEvents",
        "{missing_activation}"
    );
    let missing_requirement = rejected(|manifest| {
        manifest["requires"] = json!({ "serverProcess": 1 });
    });
    assert!(
        missing_requirement.to_string().contains("vcsProviders"),
        "{missing_requirement}"
    );
    let reserved = rejected(|manifest| {
        manifest["vcsProviders"][0]["id"] = json!("git");
        manifest["activationEvents"] = json!(["onVcsRoot:git"]);
    });
    assert_eq!(reserved["code"], "plugin.vcs.reserved", "{reserved}");
    let level_two = rejected(|manifest| manifest["pluginAPIVersion"] = json!(2));
    assert_ne!(level_two["code"], "plugin.vcs.reserved", "{level_two}");
    let escaping = rejected(|manifest| {
        manifest["vcsProviders"][0]["metadataPaths"] = json!(["../wc.db"]);
    });
    assert_eq!(
        escaping["field"], "vcsProviders[0].metadataPaths[0]",
        "{escaping}"
    );
    let path_tool = rejected(|manifest| {
        manifest["vcsProviders"][0]["tool"]["commands"] = json!(["/usr/bin/svn"]);
    });
    assert_eq!(
        path_tool["field"], "vcsProviders[0].tool.commands",
        "{path_tool}"
    );
}

#[test]
fn a_launch_plan_names_the_vcs_provider_it_starts() {
    let request = json!({
        "pluginDirectory": "/plugins/svn",
        "stateDirectory": "/state/svn",
        "workspaceStateDirectory": "/state/svn/workspace",
        "architecture": "arm64"
    });
    let plan = language_server_launch_plan_command(json!({
        "manifest": svn_provider(),
        "vcsProviderID": "svn",
        "request": request,
    }))
    .unwrap();
    assert_eq!(plan["status"], "ok", "{plan}");
    let plan = &plan["plan"];
    assert_eq!(plan["vcsProvider"]["vcs"], "svn", "{plan}");
    assert_eq!(
        plan["vcsProvider"]["origin"],
        json!({ "kind": "plugin", "pluginID": "dev.lithe.fixture.vcs-provider" })
    );
    assert_eq!(plan["vcsProvider"]["metadataPaths"], json!([".svn/wc.db"]));

    let unknown = language_server_launch_plan_command(json!({
        "manifest": svn_provider(),
        "vcsProviderID": "hg",
        "request": request,
    }))
    .unwrap();
    assert_eq!(unknown["status"], "rejected", "{unknown}");
    let both = language_server_launch_plan_command(json!({
        "manifest": svn_provider(),
        "languageID": "java",
        "vcsProviderID": "svn",
        "request": request,
    }))
    .unwrap_err();
    assert!(matches!(both.code, ErrorCode::InvalidRequest), "{both:?}");
}

fn under(path: &Value, root: &Path) -> bool {
    path.as_str()
        .is_some_and(|path| Path::new(path).starts_with(root))
}

/// Builds each case's markers in a fresh directory and checks the roots,
/// ambiguous directories, unused mappings, and file ownership. Roots found
/// above the case's directory belong to the machine running the test and
/// are left out.
#[test]
fn root_detection_matches_the_contract_cases() {
    let model = model();
    for case in model["rootDetectionCases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let sandbox = Sandbox::new("vcs-roots");
        for marker in case["markers"].as_array().unwrap() {
            let directory = sandbox.directory(marker["directory"].as_str().unwrap());
            let path = directory.join(marker["name"].as_str().unwrap());
            match marker["type"].as_str().unwrap() {
                "directory" => fs::create_dir_all(path).unwrap(),
                _ => fs::write(path, "gitdir: elsewhere\n").unwrap(),
            }
        }
        let workspace = sandbox.directory(case["workspace"].as_str().unwrap_or(""));
        let outcome = vcs_detect_roots_command(json!({
            "workspaceRoot": workspace.to_string_lossy(),
            "plugins": [{ "manifest": svn_provider() }],
            "mappings": case.get("mappings").cloned().unwrap_or(json!([])),
        }))
        .unwrap();
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
        let detection = &outcome["detection"];
        assert_eq!(detection["truncated"], false, "{name}");

        let roots: Vec<&Value> = detection["roots"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|root| under(&root["path"], &sandbox.0))
            .collect();
        let found: Vec<Value> = roots
            .iter()
            .map(|root| json!({ "id": root["id"], "vcs": root["vcs"], "mapped": root["mapped"] }))
            .collect();
        let expected: Vec<Value> = case["expectedRoots"]
            .as_array()
            .unwrap()
            .iter()
            .map(|root| {
                json!({
                    "id": root["id"],
                    "vcs": root["vcs"],
                    "mapped": root.get("mapped").cloned().unwrap_or(json!(false)),
                })
            })
            .collect();
        assert_eq!(found, expected, "{name}: {detection}");
        assert_eq!(detection["ambiguous"], case["expectedAmbiguous"], "{name}");
        assert_eq!(
            detection["unusedMappings"],
            case.get("expectedUnusedMappings")
                .cloned()
                .unwrap_or(json!([])),
            "{name}"
        );

        let ownership = case["expectedOwnership"].as_array().unwrap();
        let owners = vcs_owner_of_command(json!({
            "roots": roots.iter().map(|root| root["id"].clone()).collect::<Vec<_>>(),
            "ambiguous": detection["ambiguous"]
                .as_array()
                .unwrap()
                .iter()
                .map(|directory| directory["id"].clone())
                .collect::<Vec<_>>(),
            "paths": ownership.iter().map(|entry| entry["path"].clone()).collect::<Vec<_>>(),
        }))
        .unwrap();
        assert_eq!(owners["status"], "ok", "{name}: {owners}");
        let expected: Vec<Value> = ownership
            .iter()
            .map(|entry| json!({ "path": entry["path"], "root": entry["root"] }))
            .collect();
        assert_eq!(owners["owners"], json!(expected), "{name}");
    }
}

/// The built-in Git entry and the plugin's descriptor are what a host shows;
/// a second plugin claiming the same VCS loses to the official namespace
/// whatever order the host lists plugins in, and a malformed manifest is
/// reported by its position without hiding the others.
#[test]
fn detection_lists_providers_and_reports_conflicts_and_rejections() {
    let model = model();
    let sandbox = Sandbox::new("vcs-providers");
    // `com.` sorts before `dev.`, so only the namespace rule lets the
    // official fixture win.
    let mut community = svn_provider();
    community["id"] = json!("com.example.svn");
    let mut broken = svn_provider();
    broken["vcsProviders"][0]["id"] = json!("SVN");
    for plugins in [
        vec![community.clone(), broken.clone(), svn_provider()],
        vec![svn_provider(), broken.clone(), community.clone()],
    ] {
        let outcome = vcs_detect_roots_command(json!({
            "workspaceRoot": sandbox.0.to_string_lossy(),
            "plugins": plugins
                .into_iter()
                .map(|manifest| json!({ "manifest": manifest }))
                .collect::<Vec<_>>(),
        }))
        .unwrap();
        let detection = &outcome["detection"];
        let providers = detection["providers"].as_array().unwrap();
        assert_eq!(providers[0], model["providers"][0], "{detection}");
        assert_eq!(providers.len(), 2, "{detection}");
        assert_eq!(providers[1], {
            let mut descriptor = model["providers"][1].clone();
            descriptor.as_object_mut().unwrap().remove("capabilities");
            descriptor["metadataPaths"] = json!([".svn/wc.db"]);
            descriptor["tool"] =
                json!({ "commands": ["svn"], "validationArguments": ["--version", "--quiet"] });
            descriptor["mayUseNetwork"] = json!(true);
            descriptor
        });
        assert_eq!(
            detection["conflicts"],
            json!([{
                "pluginID": "com.example.svn",
                "vcs": "svn",
                "by": "dev.lithe.fixture.vcs-provider"
            }])
        );
        let rejected = detection["rejected"].as_array().unwrap();
        assert_eq!(rejected.len(), 1, "{detection}");
        assert_eq!(rejected[0]["index"], 1);
    }

    let error = vcs_detect_roots_command(json!({ "workspaceRoot": "relative/path" }))
        .expect_err("a relative workspace is a malformed call");
    assert!(matches!(error.code, ErrorCode::InvalidRequest), "{error:?}");
}

#[test]
fn ownership_queries_reject_malformed_ids_and_paths() {
    for payload in [
        json!({ "roots": ["../a"], "paths": ["x"] }),
        json!({ "roots": [""], "ambiguous": ["/abs"], "paths": ["x"] }),
        json!({ "roots": [""], "paths": ["../x"] }),
        json!({ "roots": [""], "paths": ["a\\b"] }),
    ] {
        let error = vcs_owner_of_command(payload.clone()).expect_err("malformed");
        assert!(matches!(error.code, ErrorCode::InvalidRequest), "{payload}");
    }
}

fn decode(operation: &str, capabilities: &Value, request: &Value, reply: &Value) -> Value {
    vcs_decode_reply_command(json!({
        "operation": operation,
        "capabilities": capabilities,
        "request": request,
        "reply": reply,
    }))
    .expect("well-formed payload")
}

/// A normalized snapshot is a fixed point: decoding it again changes
/// nothing, so hosts can rely on the fixture as the decoded shape.
#[test]
fn status_snapshots_are_the_decoded_shape() {
    let model = model();
    for case in model["statusSnapshots"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let capabilities = &case["capabilities"];
        assert!(
            negotiated_capabilities(capabilities).is_some(),
            "{name}: the capabilities must be a valid negotiation"
        );
        let outcome = decode("status", capabilities, &json!({}), &case["snapshot"]);
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
        assert_eq!(outcome["result"], case["snapshot"], "{name}");
    }
    // The Subversion provider's capabilities survive negotiation unchanged.
    let svn = &model["providers"][1]["capabilities"];
    assert_eq!(json!(negotiated_capabilities(svn).expect("complete")), *svn);
}

#[test]
fn plugin_replies_match_the_validation_cases() {
    let model = model();
    let capabilities = &model["providers"][1]["capabilities"];
    for case in model["pluginReplyValidationCases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let operation = case["operation"].as_str().unwrap_or("status");
        let request = case.get("request").cloned().unwrap_or(json!({}));
        let outcome = decode(operation, capabilities, &request, &case["reply"]);
        if let Some(code) = case.get("expectedError") {
            assert_eq!(outcome["status"], "rejected", "{name}: {outcome}");
            assert_eq!(outcome["error"]["code"], *code, "{name}");
        } else if let Some(changes) = case.get("expectedChanges") {
            assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
            assert_eq!(outcome["result"]["changes"], *changes, "{name}");
        } else {
            assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
            assert_eq!(outcome["result"], case["expectedResult"], "{name}");
        }
    }
    let error = vcs_decode_reply_command(json!({
        "operation": "push",
        "capabilities": capabilities,
        "reply": {},
    }))
    .expect_err("push has no reply shape in version 1");
    assert!(matches!(error.code, ErrorCode::InvalidRequest), "{error:?}");
}
