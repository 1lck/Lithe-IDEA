//! Drives the actual provider executable through Lithe Core, with bounded host replies.
use base64::{engine::general_purpose::STANDARD, Engine as _};
use lithe_core::{diagnostics::core_events, execute_json};
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
fn core(command: &str, payload: Value) -> Value {
    let reply: Value = serde_json::from_str(&execute_json(
        &json!({"id":"test", "command":command,"payload":payload}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["ok"], true, "{command}: {reply}");
    reply["data"].clone()
}
struct Session {
    id: String,
    plugin: String,
    root: PathBuf,
    events: Vec<Value>,
}
impl Drop for Session {
    fn drop(&mut self) {
        let _ = execute_json(
            &json!({"id":"cleanup", "command":"lsp.stopServer", "payload":{"sessionId":self.id}})
                .to_string(),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let result: Value = serde_json::from_str(&execute_json(&json!({"id":"cleanup", "command":"lsp.destroyServer", "payload":{"sessionId":self.id}}).to_string())).unwrap();
            if result["ok"] == true {
                break;
            }
            let _ = execute_json(&json!({"id":"cleanup", "command":"lsp.waitEvents", "payload":{"sessionId":self.id,"timeoutMilliseconds":100}}).to_string());
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
impl Session {
    fn new(provider: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "keymap-provider-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        // Core's fact queue is process-wide; a per-provider identity keeps the
        // parallel cases from satisfying each other's diagnostic assertion.
        let plugin = format!("org.example.keymap.{provider}");
        let started = core(
            "lsp.startServer",
            json!({"providerId":"pluginBackend:test", "pluginId":plugin,
            "executablePath":env!("CARGO_BIN_EXE_lithe-editor-keymap-import"), "arguments":[],
            "rootUri":format!("file://{}/",root.display()), "workingDirectory":root,
            "hostServices":["lithe/host/keymapImport/listInputs", "lithe/host/keymapImport/readChunk"],
            "keymapImportProviders":[provider], "initializeTimeoutMilliseconds":5000,"requestTimeoutMilliseconds":5000,"shutdownTimeoutMilliseconds":200}),
        );
        let mut session = Self {
            id: started["sessionId"].as_str().unwrap().into(),
            plugin,
            root,
            events: vec![],
        };
        session.wait(|event| event["type"] == "keymapImportProviders");
        session.wait(|event| event["type"] == "stateChanged" && event["state"] == "ready");
        session
    }
    fn wait(&mut self, predicate: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(i) = self.events.iter().position(&predicate) {
                return self.events.remove(i);
            }
            assert!(
                Instant::now() < deadline,
                "timed out; events: {:?}",
                self.events
            );
            let batch = core(
                "lsp.waitEvents",
                json!({"sessionId":self.id, "timeoutMilliseconds":100}),
            );
            self.events
                .extend(batch["events"].as_array().unwrap().iter().cloned());
        }
    }
    /// Waits for Core to accept the SDK's `lithe/log` fact into the host writer's queue.
    fn recorded_fact(&mut self, event: &str, operation: &str) -> core_events::CoreEvent {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut seen = Vec::new();
        loop {
            let drained = core_events::drain().events;
            if let Some(fact) = drained.iter().find(|fact| {
                fact.event == event
                    && fact.fields.get("plugin") == Some(&json!(self.plugin))
                    && fact.fields.get("operation") == Some(&json!(operation))
            }) {
                return fact.clone();
            }
            seen.extend(drained.into_iter().map(|fact| (fact.event, fact.fields)));
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {event} {operation}; drained: {seen:?}"
            );
            // The session's bounded event wait paces the poll without a sleep.
            let batch = core(
                "lsp.waitEvents",
                json!({"sessionId":self.id, "timeoutMilliseconds":100}),
            );
            self.events
                .extend(batch["events"].as_array().unwrap().iter().cloned());
        }
    }
    fn respond(&self, request: &Value, result: Value) {
        core(
            "lsp.hostResponse",
            json!({"sessionId":self.id,"hostRequestID":request["result"]["hostRequestID"],"result":result}),
        );
    }
    fn run(&mut self, provider: &str, path: &str, contents: &str) -> Value {
        core(
            "lsp.keymapImportRequest",
            json!({"sessionId":self.id,"operationId":"import", "providerID":provider,"snapshotID":"test-token","timeoutMilliseconds":5000}),
        );
        let list = self.wait(|event| {
            event["type"] == "hostRequest"
                && event["method"] == "lithe/host/keymapImport/listInputs"
        });
        self.respond(
            &list,
            json!({"files":[{"id":"file-0","path":path,"byteCount":contents.len()}]}),
        );
        let read = self.wait(|event| {
            event["type"] == "hostRequest" && event["method"] == "lithe/host/keymapImport/readChunk"
        });
        self.respond(&read, json!({"data":STANDARD.encode(contents)}));
        let done = self
            .wait(|event| event["type"] == "requestCompleted" && event["operationId"] == "import");
        let reply = done["result"]["value"]["response"]["result"].clone();
        let allowed = [
            "save",
            "settings",
            "navigate-back",
            "navigate-forward",
            "search-in-project",
            "replace-in-project",
            "find-in-file",
            "replace-in-file",
            "find-next",
            "find-previous",
            "go-to-definition",
            "go-to-implementation",
            "find-usages",
            "toggle-breakpoint",
            "view-breakpoints",
            "find-action",
            "go-to-line",
            "toggle-terminal",
            "debug",
            "debug-start-or-continue",
            "run",
            "debug-resume",
            "debug-step-over",
            "debug-step-into",
            "debug-step-out",
            "stop-debug",
        ];
        core(
            "keymap.decodeImport",
            json!({"commandIDs":allowed,"reply":reply}),
        )
    }
}

#[test]
fn vscode_source_runs_through_real_core_and_provider() {
    let mut session = Session::new("vscode");
    let result = session.run(
        "vscode",
        "keybindings.json",
        r#"[{"key":"cmd+alt+n","command":"editor.action.nextMatchFindAction"}]"#,
    );
    let actions = result["bindings"].as_array().unwrap();
    assert!(actions
        .iter()
        .any(|entry| entry["commandID"] == "toggle-breakpoint" && entry["keys"][0]["key"] == "f9"));
    assert!(actions
        .iter()
        .any(|entry| entry["commandID"] == "find-next" && entry["keys"][0]["key"] == "n"));
    // The SDK reports the import result through litheLogging 1; Core binds the
    // plugin identity and routes it to that plugin's host channel.
    let fact = session.recorded_fact("plugins.operation.finished", "lithe/keymap/import");
    assert_eq!(fact.channel, "plugins/org.example.keymap.vscode/host");
}

#[test]
fn idea_source_runs_through_real_core_and_provider() {
    let mut session = Session::new("idea");
    let result = session.run("idea", "options/keymap.xml", "<application><component name='KeymapManager'><active_keymap name='Mac OS X 10.5+'/></component></application>");
    let actions = result["bindings"].as_array().unwrap();
    assert!(actions
        .iter()
        .any(|entry| entry["commandID"] == "find-action" && entry["keys"][0]["key"] == "a"));
    assert!(actions
        .iter()
        .any(|entry| entry["commandID"] == "toggle-breakpoint" && entry["keys"][0]["key"] == "f8"));
}
