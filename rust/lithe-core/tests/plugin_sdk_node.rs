//! End-to-end check of the official Node.js plugin SDK (`sdk/node`) against
//! Rust Core, through the same JSON commands a host sends.
//!
//! The SDK's sample backend is launched exactly as a host launches a build
//! provider: Core validates its manifest and expands the launch plan, the
//! runtime version is checked, and `lsp.startServer` starts it. The test then
//! drives the typed build requests, a multi-step plugin function with
//! progress, a plugin failure, cancellation of a running tool, runtime
//! registration, and state recovery across a restart. It runs only when
//! `LITHE_PLUGIN_SDK_NODE` names a Node.js 20.3 or newer executable;
//! `scripts/verify-plugin-sdk.sh` sets it.

use lithe_core::execute_json;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const PLUGIN_ID: &str = "org.example.sample-build";
const BUILD_SYSTEM: &str = "sample";
/// Bound for any single wait; a broken backend fails here instead of in CI.
const WAIT: Duration = Duration::from_secs(20);

fn core(command: &str, payload: Value) -> Value {
    let request = json!({ "id": format!("sdk-{command}"), "command": command, "payload": payload });
    let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
        .expect("Core response should be JSON");
    assert_eq!(response["ok"], true, "{command} failed: {response}");
    response["data"].clone()
}

fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repository root")
}

/// Every file of a directory with its contents, to prove the package is unchanged.
fn listing(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut files = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).expect("readable directory") {
            let path = entry.expect("directory entry").path();
            if path.is_dir() {
                pending.push(path);
            } else {
                let contents = fs::read(&path).expect("readable file");
                files.insert(path.strip_prefix(root).unwrap().to_path_buf(), contents);
            }
        }
    }
    files
}

/// Temporary workspace and host state directories, removed even when an
/// assertion fails.
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("lithe-plugin-sdk-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("fixture directory");
        // The backend sees canonical paths (macOS /var is /private/var).
        Self {
            root: root.canonicalize().expect("fixture path"),
        }
    }

    fn workspace(&self) -> PathBuf {
        self.root.join("workspace")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// One running backend session. Dropping it stops the process and removes
/// the session, so a failed assertion leaves no backend behind.
struct Session {
    id: String,
    events: Vec<Value>,
}

impl Session {
    fn start(node: &str, arguments: &[Value], workspace: &Path) -> Self {
        let started = core(
            "lsp.startServer",
            json!({
                "providerId": format!("buildProvider:{PLUGIN_ID}:{BUILD_SYSTEM}"),
                "pluginId": PLUGIN_ID,
                "executablePath": node,
                "arguments": arguments,
                // Directory URI with a trailing slash, as the macOS host sends it.
                "rootUri": format!("file://{}/", workspace.display()),
                "workingDirectory": workspace,
                "initializeTimeoutMilliseconds": WAIT.as_millis() as u64,
                "requestTimeoutMilliseconds": WAIT.as_millis() as u64,
                "shutdownTimeoutMilliseconds": 5000,
            }),
        );
        let mut session = Self {
            id: started["sessionId"]
                .as_str()
                .expect("session ID")
                .to_string(),
            events: Vec::new(),
        };
        session.await_event("the session to become ready", |event| {
            event["type"] == "stateChanged" && event["state"] == "ready"
        });
        session
    }

    /// Waits for the first event, already received or new, that `matches`.
    fn await_event(&mut self, description: &str, matches: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(event) = self.events.iter().find(|event| matches(event)) {
                return event.clone();
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(
                !remaining.is_zero(),
                "timed out waiting for {description}; events: {:#?}",
                self.events
            );
            let drained = core(
                "lsp.waitEvents",
                json!({ "sessionId": self.id, "timeoutMilliseconds": remaining.as_millis().min(1000) as u64 }),
            );
            self.events
                .extend(drained["events"].as_array().cloned().unwrap_or_default());
        }
    }

    fn completion(&mut self, operation: &str) -> Value {
        self.await_event(&format!("operation {operation} to end"), |event| {
            // Every terminal outcome, cancellation included, is one requestCompleted.
            event["operationId"] == operation && event["type"] == "requestCompleted"
        })
    }

    fn invoke(&mut self, operation: &str, function: &str, params: Value) {
        core(
            "lsp.functionRequest",
            json!({
                "sessionId": self.id,
                "operationId": operation,
                "function": { "pluginID": PLUGIN_ID, "functionID": function },
                "params": params,
            }),
        );
    }

    fn call(&mut self, operation: &str, function: &str, params: Value) -> Value {
        self.invoke(operation, function, params);
        self.completion(operation)
    }

    /// The registry after the latest `functionsChanged` event.
    fn functions(&mut self) -> Vec<String> {
        let latest = self
            .events
            .iter()
            .rev()
            .find(|event| event["type"] == "functionsChanged")
            .expect("a functionsChanged event");
        serde_json::from_value(latest["result"]["functions"].clone()).expect("function IDs")
    }

    fn build_request(&mut self, operation: &str, plan: &Value) -> Value {
        core(
            "lsp.buildRequest",
            json!({
                "sessionId": self.id,
                "operationId": operation,
                "method": plan["provider"]["method"],
                "params": plan["provider"]["params"],
            }),
        );
        let completed = self.completion(operation);
        assert!(completed.get("error").is_none(), "{completed}");
        completed["result"]["value"].clone()
    }

    fn stop(&mut self) {
        core("lsp.stopServer", json!({ "sessionId": self.id }));
        self.await_event("the backend to stop", |event| {
            event["type"] == "stateChanged" && event["state"] == "stopped"
        });
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let request = json!({ "id": "sdk-cleanup", "command": "lsp.stopServer", "payload": { "sessionId": self.id } });
        let _ = execute_json(&request.to_string());
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            let destroy = json!({ "id": "sdk-cleanup", "command": "lsp.destroyServer", "payload": { "sessionId": self.id } });
            let response: Value =
                serde_json::from_str(&execute_json(&destroy.to_string())).unwrap_or(Value::Null);
            if response["ok"] == true {
                return;
            }
            let wait = json!({ "id": "sdk-cleanup", "command": "lsp.waitEvents", "payload": { "sessionId": self.id, "timeoutMilliseconds": 200 } });
            let _ = execute_json(&wait.to_string());
        }
    }
}

#[cfg(unix)]
fn is_alive(pid: u32) -> bool {
    Command::new("kill")
        .args(["-0", &pid.to_string()])
        .status()
        .is_ok_and(|status| status.success())
}

#[test]
fn the_node_sdk_sample_backend_serves_build_requests_and_plugin_functions() {
    let Some(node) = std::env::var_os("LITHE_PLUGIN_SDK_NODE") else {
        eprintln!("skipped: set LITHE_PLUGIN_SDK_NODE to run the Node.js SDK end-to-end check");
        return;
    };
    let node = node.into_string().expect("UTF-8 Node.js path");
    let package = repository_root().join("sdk/node/examples/sample-build");
    let manifest: Value =
        serde_json::from_slice(&fs::read(package.join("plugin.json")).expect("sample manifest"))
            .expect("sample manifest JSON");
    let package_before = listing(&package);

    // The manifest passes the same validation as an installed plugin.
    let validated = core(
        "plugins.declarative.validate",
        json!({ "manifest": manifest }),
    );
    assert_eq!(validated["status"], "ok", "{validated}");

    let fixture = Fixture::new();
    let workspace = fixture.workspace();
    for project in ["app", "broken", "slow"] {
        fs::create_dir_all(workspace.join(project)).expect("project directory");
    }
    let slow_pid = workspace.join("slow/slow.pid");
    fs::write(
        workspace.join("lithe-sample.json"),
        json!({
            "projects": [
                {
                    "name": "app", "path": "app",
                    "build": ["node", "-e", "console.log('built app')"],
                    "dependencies": [{ "name": "left-pad", "version": "1.3.0" }]
                },
                { "name": "broken", "path": "broken", "build": ["node", "-e", "process.exit(2)"] },
                {
                    "name": "slow", "path": "slow",
                    "build": ["node", "-e", "require('fs').writeFileSync('slow.pid', String(process.pid)); setInterval(() => {}, 1000)"]
                }
            ]
        })
        .to_string(),
    )
    .expect("workspace file");

    // The host expands the launch plan and checks the runtime it found.
    let plan = core(
        "plugins.declarative.languageServerLaunchPlan",
        json!({
            "manifest": manifest,
            "buildSystemID": BUILD_SYSTEM,
            "request": {
                "pluginDirectory": package,
                "stateDirectory": fixture.root.join("state"),
                "workspaceStateDirectory": fixture.root.join("workspace-state"),
                "architecture": if cfg!(target_arch = "aarch64") { "arm64" } else { "x86_64" },
            }
        }),
    );
    assert_eq!(plan["status"], "ok", "{plan}");
    let plan = &plan["plan"];
    assert_eq!(plan["launch"]["tool"], "node");
    let version = Command::new(&node)
        .args(
            plan["launch"]["versionArguments"]
                .as_array()
                .expect("version probe")
                .iter()
                .map(|argument| argument.as_str().unwrap()),
        )
        .output()
        .expect("Node.js version probe");
    let check = core(
        "plugins.declarative.checkRuntimeVersion",
        json!({
            "tool": "node",
            "minimumVersion": plan["launch"]["minimumVersion"],
            "output": String::from_utf8_lossy(&version.stdout),
        }),
    );
    assert_eq!(check["check"]["satisfied"], true, "{check}");
    for directory in plan["requiredDirectories"].as_array().unwrap() {
        let path = match directory.as_str() {
            Some("state") => fixture.root.join("state"),
            _ => fixture.root.join("workspace-state"),
        };
        fs::create_dir_all(path).expect("host state directory");
    }
    let arguments = plan["arguments"].as_array().unwrap().clone();

    let mut session = Session::start(&node, &arguments, &workspace);
    assert_eq!(session.functions(), ["snapshot.read", "workspace.build"]);

    // Typed build requests: Core plans them and decodes the answers.
    let build = |operation: &str, request: Value| {
        core(
            operation,
            json!({ "manifest": manifest, "buildSystemID": BUILD_SYSTEM, "request": request }),
        )
    };
    let model_plan = build("build.modelPlan", json!({ "root": "." }))["plan"].clone();
    assert_eq!(model_plan["provider"]["method"], "lithe/build/model");
    let model_result = session.build_request("model", &model_plan);
    let model = build(
        "build.decodeModel",
        json!({ "workspaceRoot": workspace, "root": ".", "result": model_result }),
    );
    let names: Vec<_> = model["model"]["projects"]
        .as_array()
        .expect("decoded projects")
        .iter()
        .map(|project| project["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(names, ["app", "broken", "slow"], "{model}");

    let dependency_plan = build(
        "build.dependencyPlan",
        json!({ "root": ".", "project": { "name": "app", "path": "app" } }),
    )["plan"]
        .clone();
    let dependencies_result = session.build_request("dependencies", &dependency_plan);
    let dependencies = build(
        "build.decodeDependencies",
        json!({ "workspaceRoot": workspace, "root": ".", "project": "app", "result": dependencies_result }),
    );
    assert_eq!(
        dependencies["dependencies"]["dependencies"][0]["name"], "left-pad",
        "{dependencies}"
    );

    // A multi-step function: prepare, run the tool, record a snapshot.
    let built = session.call(
        "build-app",
        "workspace.build",
        json!({ "projects": ["app"] }),
    );
    assert_eq!(
        built["result"]["value"],
        json!({ "generation": 1, "status": "succeeded", "projects": [{ "name": "app", "exitCode": 0 }] }),
        "{built}"
    );
    let progress: Vec<_> = session
        .events
        .iter()
        .filter(|event| event["type"] == "requestProgress" && event["operationId"] == "build-app")
        .map(|event| event["result"]["message"].clone())
        .collect();
    assert_eq!(progress, ["Preparing", "Building app", "Done"]);
    // The backend registered snapshot.clear once a snapshot existed.
    session.await_event("snapshot.clear to be registered", |event| {
        event["type"] == "functionsChanged"
            && event["result"]["functions"]
                .as_array()
                .is_some_and(|functions| functions.contains(&json!("snapshot.clear")))
    });

    // A plugin failure keeps Lithe's stable code and forwards the plugin's own.
    let failed = session.call(
        "build-broken",
        "workspace.build",
        json!({ "projects": ["broken"] }),
    );
    assert_eq!(
        failed["error"]["code"], "plugin.function.failed",
        "{failed}"
    );
    assert_eq!(failed["error"]["pluginErrorCode"], "sample.buildFailed");

    // Cancelling a running build ends the tool the backend started.
    session.invoke(
        "build-slow",
        "workspace.build",
        json!({ "projects": ["slow"] }),
    );
    let deadline = Instant::now() + WAIT;
    let pid = loop {
        if let Some(pid) = fs::read_to_string(&slow_pid)
            .ok()
            .and_then(|text| text.trim().parse::<u32>().ok())
        {
            break pid;
        }
        assert!(Instant::now() < deadline, "the slow tool never started");
        session.events.extend(
            core(
                "lsp.waitEvents",
                json!({ "sessionId": session.id, "timeoutMilliseconds": 50 }),
            )["events"]
                .as_array()
                .cloned()
                .unwrap_or_default(),
        );
    };
    core(
        "lsp.cancelOperation",
        json!({ "sessionId": session.id, "operationId": "build-slow" }),
    );
    assert_eq!(
        session.completion("build-slow")["error"]["code"],
        "requestCancelled"
    );
    #[cfg(unix)]
    {
        let deadline = Instant::now() + WAIT;
        while is_alive(pid) {
            assert!(
                Instant::now() < deadline,
                "the cancelled tool {pid} is still running"
            );
            // test-stability: allow(rust-real-sleep) reason: the cancelled tool is a separate OS process that offers no notification channel to the test; the deadline above bounds the loop.
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    #[cfg(not(unix))]
    let _ = pid;

    // State survives a restart: the new process reads the recorded snapshot.
    session.stop();
    drop(session);
    let mut restarted = Session::start(&node, &arguments, &workspace);
    restarted.await_event("snapshot.clear to be offered again", |event| {
        event["type"] == "functionsChanged"
            && event["result"]["functions"]
                .as_array()
                .is_some_and(|functions| functions.contains(&json!("snapshot.clear")))
    });
    let snapshot = restarted.call("read", "snapshot.read", json!({}));
    assert_eq!(snapshot["result"]["value"]["generation"], 2, "{snapshot}");
    assert_eq!(snapshot["result"]["value"]["status"], "failed");
    assert_eq!(
        restarted.call("clear", "snapshot.clear", json!({}))["result"]["value"],
        Value::Null
    );
    assert_eq!(
        restarted.call("read-again", "snapshot.read", json!({}))["result"]["value"],
        Value::Null
    );
    restarted.stop();
    drop(restarted);

    // The backend wrote only to the host's state directory, never the package.
    assert!(
        listing(&package) == package_before,
        "the plugin package changed at runtime"
    );
    let state: Vec<_> = fs::read_dir(fixture.root.join("workspace-state"))
        .expect("workspace state directory")
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert!(
        state.is_empty(),
        "cleared state left files behind: {state:?}"
    );
}
