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
                } if t == token => Some(session_id.clone()),
                _ => None,
            },
        )
    }

    fn prompt(&self, session_id: &str, text: &str) -> (String, String) {
        self.send(AgentCommand::Prompt {
            session_id: session_id.into(),
            text: text.into(),
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
    let workspace = std::env::temp_dir().join(format!("lithe-acp-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&workspace).expect("workspace");
    let session = open(&workspace);

    let first = session.new_session("first");
    let (reason, reply) = session.prompt(
        &first,
        "Remember the code word LITHE-HERON. Reply with exactly: STORED",
    );
    assert_eq!(reason, "end_turn");
    assert!(reply.contains("STORED"), "unexpected reply {reply:?}");

    // Cancel immediately after sending, the window in which codex-acp can drop
    // a cancel. The turn must still end at once and the session stay usable.
    let second = session.new_session("second");
    session.send(AgentCommand::Prompt {
        session_id: second.clone(),
        text: "Write a numbered list of 40 facts about the ocean. Do not use tools.".into(),
    });
    session.send(AgentCommand::Cancel {
        session_id: second.clone(),
    });
    let started = Instant::now();
    let reason = session.wait(
        "cancelled turn",
        None,
        &mut String::new(),
        |event| match event {
            AgentEvent::TurnFinished {
                session_id,
                stop_reason,
            } if *session_id == second => Some(stop_reason.clone()),
            _ => None,
        },
    );
    assert_eq!(reason, "cancelled");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "cancel waited for the agent"
    );

    session.send(AgentCommand::ListSessions {
        token: "list".into(),
    });
    let listed = session.wait(
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
    session.handle.close();

    // A new process resumes the first conversation with its context.
    let resumed = open(&workspace);
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
    let _ = std::fs::remove_dir_all(&workspace);
}
