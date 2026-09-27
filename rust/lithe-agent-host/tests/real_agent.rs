//! Opt-in end-to-end check against a real ACP agent and API gateway.
//!
//! Ignored by default because it needs an installed agent, network access, and
//! a real key. Run it explicitly with:
//!
//! ```text
//! LITHE_ACP_E2E_COMMAND=/path/to/codex-acp \
//! LITHE_ACP_E2E_BASE_URL=https://host/v1 LITHE_ACP_E2E_API_KEY=... \
//! cargo test -p lithe-agent-host --test real_agent -- --ignored --nocapture
//! ```
//!
//! `LITHE_ACP_E2E_MODEL` optionally selects the provider model and
//! `LITHE_ACP_E2E_ARGS` holds newline-separated arguments. With
//! `LITHE_ACP_E2E_DATA_DIR` set instead of a command, the Codex adapter is
//! installed there with the user's npm (if missing) and launched as a catalog
//! agent, covering the one-click install path.

use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use lithe_agent_host::{
    install, AgentCommand, AgentEvent, AgentHandle, AgentLaunch, ProviderCredentials,
    ProviderProtocol,
};

const TURN_DEADLINE: Duration = Duration::from_secs(180);

struct Session {
    handle: AgentHandle,
    events: mpsc::Receiver<AgentEvent>,
}

impl Session {
    fn next(&self, deadline: Instant, what: &str) -> AgentEvent {
        let remaining = deadline.saturating_duration_since(Instant::now());
        self.events
            .recv_timeout(remaining)
            .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
    }

    /// Wait for the first event accepted by `select`, collecting agent text for
    /// `session_id` on the way.
    fn wait<T>(
        &self,
        what: &str,
        session_id: Option<&str>,
        text: &mut String,
        mut select: impl FnMut(&AgentEvent) -> Option<T>,
    ) -> T {
        let deadline = Instant::now() + TURN_DEADLINE;
        loop {
            let event = self.next(deadline, what);
            if let AgentEvent::Update {
                session_id: id,
                update,
            } = &event
            {
                if Some(id.as_str()) == session_id
                    && update["sessionUpdate"] == "agent_message_chunk"
                {
                    text.push_str(update["content"]["text"].as_str().unwrap_or_default());
                }
            }
            if let AgentEvent::Stopped { message } = &event {
                panic!("agent stopped while waiting for {what}: {message:?}");
            }
            if let AgentEvent::RequestFailed { message, .. } = &event {
                panic!("request failed while waiting for {what}: {message}");
            }
            if let Some(value) = select(&event) {
                return value;
            }
        }
    }

    fn send(&self, command: AgentCommand) {
        self.handle
            .send(command)
            .expect("connection accepts command");
    }

    fn new_session(&self, token: &str) -> String {
        self.send(AgentCommand::NewSession {
            token: token.into(),
        });
        self.wait(
            "session creation",
            None,
            &mut String::new(),
            |event| match event {
                AgentEvent::SessionCreated {
                    token: t,
                    session_id,
                    ..
                } if t == token => Some(session_id.clone()),
                _ => None,
            },
        )
    }

    fn prompt(&self, session_id: &str, text: &str) -> (String, String) {
        self.send(AgentCommand::Prompt {
            session_id: session_id.into(),
            text: text.into(),
            files: vec![],
        });
        let mut reply = String::new();
        let reason = self.wait(
            "turn end",
            Some(session_id),
            &mut reply,
            |event| match event {
                AgentEvent::TurnFinished {
                    session_id: id,
                    stop_reason,
                } if id == session_id => Some(stop_reason.clone()),
                _ => None,
            },
        );
        (reason, reply)
    }
}

fn required(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} must be set for this ignored test"))
}

fn open(workspace: &std::path::Path) -> Session {
    let (sender, events) = mpsc::channel();
    let data_directory = std::env::var_os("LITHE_ACP_E2E_DATA_DIR").map(std::path::PathBuf::from);
    if let Some(data) = &data_directory {
        if install::installed_version(data, lithe_agent_host::catalog::find("codex-acp").unwrap())
            .is_none()
        {
            install::install(data, "codex-acp", &|| false).expect("adapter installs with npm");
        }
    }
    let launch = AgentLaunch {
        agent_id: data_directory.as_ref().map(|_| "codex-acp".to_owned()),
        command: std::env::var("LITHE_ACP_E2E_COMMAND").ok(),
        args: std::env::var("LITHE_ACP_E2E_ARGS")
            .map(|args| {
                args.lines()
                    .filter(|line| !line.is_empty())
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default(),
        cwd: workspace.to_path_buf(),
        data_directory,
        provider: ProviderCredentials {
            protocol: ProviderProtocol::Responses,
            base_url: required("LITHE_ACP_E2E_BASE_URL"),
            api_key: required("LITHE_ACP_E2E_API_KEY"),
            name: Some("Lithe end-to-end test".into()),
            model: std::env::var("LITHE_ACP_E2E_MODEL").ok(),
            allow_insecure_http: false,
        },
    };
    let handle = AgentHandle::open(
        launch,
        Arc::new(move |event| {
            let _ = sender.send(event);
        }),
    )
    .expect("valid launch configuration");
    let session = Session { handle, events };
    session.wait("ready", None, &mut String::new(), |event| {
        matches!(event, AgentEvent::Ready { .. }).then_some(())
    });
    session
}

#[test]
#[ignore = "requires a real ACP agent, network access, and an API key"]
fn real_agent_conversation_cancel_history_and_cleanup() {
    let workspace = TemporaryProject::new();
    let session = open(&workspace.0);

    let first = session.new_session("first");
    let (reason, reply) = session.prompt(
        &first,
        "Remember the code word LITHE-HERON. Reply with exactly: STORED",
    );
    assert_eq!(reason, "end_turn");
    assert!(reply.contains("STORED"), "unexpected reply {reply:?}");

    // A lost startup cancel must result in bounded connection recovery, never
    // an immediately accepted second prompt in the same unfinished turn.
    let second = session.new_session("second");
    session.send(AgentCommand::Prompt {
        session_id: second.clone(),
        text: "Write a numbered list of 40 facts about the ocean. Do not use tools.".into(),
        files: vec![],
    });
    session.send(AgentCommand::Cancel {
        session_id: second.clone(),
    });
    let started = Instant::now();
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        match session.next(deadline, "cancellation or recovery") {
            AgentEvent::TurnFinished {
                session_id,
                stop_reason,
            } if session_id == second => {
                assert!(["cancelled", "end_turn"].contains(&stop_reason.as_str()));
                break;
            }
            AgentEvent::Stopped { message } => {
                assert!(message.unwrap_or_default().contains("Reconnect"));
                break;
            }
            _ => {}
        }
    }
    assert!(started.elapsed() < Duration::from_secs(20));
    session.handle.close();

    let resumed = open(&workspace.0);
    resumed.send(AgentCommand::ListSessions {
        token: "list".into(),
    });
    let listed = resumed.wait(
        "session list",
        None,
        &mut String::new(),
        |event| match event {
            AgentEvent::Sessions { sessions, .. } => Some(
                sessions
                    .iter()
                    .map(|s| s.session_id.clone())
                    .collect::<Vec<_>>(),
            ),
            _ => None,
        },
    );
    assert!(
        listed.contains(&first),
        "first session missing from {listed:?}"
    );
    // A new process resumes the first conversation with its context.
    resumed.send(AgentCommand::LoadSession {
        token: "load".into(),
        session_id: first.clone(),
    });
    resumed.wait("session load", None, &mut String::new(), |event| {
        matches!(event, AgentEvent::SessionLoaded { .. }).then_some(())
    });
    let (reason, reply) = resumed.prompt(
        &first,
        "What code word did I ask you to remember? Reply with the code word only.",
    );
    assert_eq!(reason, "end_turn");
    assert!(
        reply.contains("LITHE-HERON"),
        "context was not restored: {reply:?}"
    );
    resumed.handle.close();
}

struct TemporaryProject(std::path::PathBuf);

impl TemporaryProject {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("lithe-acp-workflow-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).expect("temporary project");
        Self(path)
    }
}

impl Drop for TemporaryProject {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
#[ignore = "requires a real ACP agent, network access, Node.js, and an API key"]
fn real_agent_reads_edits_tests_and_continues_in_temporary_project() {
    let workspace = TemporaryProject::new();
    std::fs::write(
        workspace.0.join("sum.cjs"),
        "module.exports = (a, b) => a - b;\n",
    )
    .unwrap();
    std::fs::write(workspace.0.join("sum.test.cjs"),
        "const assert = require('node:assert/strict');\nconst sum = require('./sum.cjs');\nassert.equal(sum(2, 3), 5);\nconsole.log('LITHE_TEST_PASSED');\n").unwrap();
    let session = open(&workspace.0);
    let id = session.new_session("workflow");
    session.send(AgentCommand::Prompt {
        session_id: id.clone(),
        text: "Work only in this temporary project. Read sum.cjs and sum.test.cjs, fix the implementation, then execute node sum.test.cjs. Do not install dependencies, access network, or change any file outside this directory. Report the actual test result.".into(),
        files: vec![],
    });
    let mut tools = 0;
    let mut result_seen = false;
    let mut reply = String::new();
    let reason = session.wait("read/edit/test workflow", Some(&id), &mut reply, |event| {
        match event {
            AgentEvent::Permission {
                request_id,
                request,
                ..
            } => {
                let option = request["options"]
                    .as_array()
                    .and_then(|options| options.iter().find(|o| o["kind"] == "allow_once"))
                    .and_then(|o| o["optionId"].as_str())
                    .map(String::from);
                session.send(AgentCommand::Permission {
                    request_id: request_id.clone(),
                    option_id: option,
                });
            }
            AgentEvent::Update { update, .. } => {
                if update["sessionUpdate"] == "tool_call" {
                    tools += 1;
                }
                if update["sessionUpdate"] == "tool_call_update"
                    && update.to_string().contains("LITHE_TEST_PASSED")
                {
                    result_seen = true;
                }
            }
            AgentEvent::TurnFinished { stop_reason, .. } => return Some(stop_reason.clone()),
            _ => {}
        }
        None
    });
    assert_eq!(reason, "end_turn");
    assert!(tools >= 2, "expected file and execution tools");
    assert!(result_seen, "tool output must contain the test marker");
    assert!(!std::fs::read_to_string(workspace.0.join("sum.cjs"))
        .unwrap()
        .contains("a - b"));
    assert_eq!(
        std::fs::read_dir(&workspace.0).unwrap().count(),
        2,
        "no extra generated files"
    );
    let (reason, reply) = session.prompt(
        &id,
        "What command did you just execute and did it pass? Do not use tools.",
    );
    assert_eq!(reason, "end_turn");
    assert!(reply.contains("sum.test.cjs"));
    session.handle.close();
}

#[test]
#[ignore = "requires a real Codex ACP agent and API key configuration"]
fn real_agent_configuration_options_are_selectable() {
    let workspace = TemporaryProject::new();
    let session = open(&workspace.0);
    session.send(AgentCommand::NewSession {
        token: "config".into(),
    });
    let (id, options) =
        session.wait(
            "session configuration",
            None,
            &mut String::new(),
            |event| match event {
                AgentEvent::SessionCreated {
                    session_id,
                    config_options,
                    ..
                } => Some((
                    session_id.clone(),
                    serde_json::to_value(config_options).unwrap(),
                )),
                _ => None,
            },
        );
    let options = options.as_array().expect("Codex reports config options");
    for category in ["model", "mode", "thought_level"] {
        let option = options
            .iter()
            .find(|option| option["category"] == category)
            .unwrap_or_else(|| panic!("missing category {category}"));
        let config_id = option["id"].as_str().unwrap();
        let current = option["currentValue"].as_str().unwrap();
        // Change reasoning to another supported value; model and permission
        // round trips preserve the user's effective defaults without a prompt.
        let value = if category == "thought_level" {
            option["options"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|choice| choice["value"].as_str())
                .find(|value| *value != current)
                .unwrap_or(current)
        } else {
            current
        };
        session.send(AgentCommand::SetConfigOption {
            token: category.into(),
            session_id: id.clone(),
            config_id: config_id.into(),
            value: value.into(),
        });
        let updated = session.wait(
            "config acknowledgement",
            None,
            &mut String::new(),
            |event| match event {
                AgentEvent::SessionConfigured {
                    token,
                    config_options,
                    ..
                } if token == category => Some(serde_json::to_value(config_options).unwrap()),
                _ => None,
            },
        );
        let actual = updated
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["id"] == config_id)
            .unwrap();
        assert_eq!(actual["currentValue"], value);
    }
    session.handle.close();
}
