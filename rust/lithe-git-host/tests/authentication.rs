//! Loopback transport tests own their sockets and require no Git, GUI, or network service.
use lithe_git_host::authentication::{respond, Confirmation, Session};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::Command;
use std::time::{Duration, Instant};

#[test]
fn prompt_response_is_single_use_and_cancellation_drops_pending_challenges() {
    let mut session = Session::new().unwrap();
    let mut command = Command::new("unused-fixture");
    session.configure(&mut command).unwrap();
    let env = command
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.unwrap().to_string_lossy().into_owned(),
            )
        })
        .collect::<std::collections::HashMap<_, _>>();
    assert_eq!(
        env["GIT_ASKPASS"],
        std::env::current_exe().unwrap().to_string_lossy()
    );
    assert_eq!(env["SSH_ASKPASS"], env["GIT_ASKPASS"]);
    assert_eq!(env["LITHE_GIT_ASKPASS_MODE"], "1");
    let mut untrusted = TcpStream::connect(&env["LITHE_GIT_ASKPASS_ADDRESS"]).unwrap();
    untrusted
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    untrusted
        .set_write_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    writeln!(
        untrusted,
        "{}",
        serde_json::json!({"token": "wrong-fixture-token", "prompt": "untrusted"})
    )
    .unwrap();
    let mut peer = TcpStream::connect(&env["LITHE_GIT_ASKPASS_ADDRESS"]).unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    peer.set_write_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    writeln!(peer, "{}", serde_json::json!({"token": env["LITHE_GIT_ASKPASS_TOKEN"], "prompt": "Password for fixture:"})).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let challenge = loop {
        if let Some(challenge) = session.poll().unwrap().pop() {
            break challenge;
        }
        assert!(
            Instant::now() < deadline,
            "AskPass frame was not received before deadline"
        );
        std::thread::yield_now();
    };
    assert!(challenge.secret);
    let mut rejected = String::new();
    untrusted.read_to_string(&mut rejected).unwrap();
    assert!(rejected.is_empty());
    assert!(!respond(
        &challenge.request_id,
        Some("invalid\nresponse".into())
    ));
    assert!(!respond(&challenge.request_id, Some("x".repeat(8193))));
    assert!(respond(
        &challenge.request_id,
        Some("fixture-answer".into())
    ));
    assert!(!respond(&challenge.request_id, Some("replayed".into())));
    session.poll().unwrap();
    let mut answer = String::new();
    peer.read_to_string(&mut answer).unwrap();
    assert_eq!(answer, "fixture-answer\n");
    drop(session);
    assert!(!respond(&challenge.request_id, None));
}

#[test]
fn retry_decisions_and_stale_responses_are_bounded() {
    let confirmation = Confirmation::new().unwrap();
    assert!(respond(&confirmation.request_id, Some("retry".into())));
    assert!(confirmation.wait(|| false).unwrap());
    let confirmation = Confirmation::new().unwrap();
    let id = confirmation.request_id.clone();
    assert!(!confirmation.wait(|| true).unwrap());
    drop(confirmation);
    assert!(!respond(&id, Some("retry".into())));
}
