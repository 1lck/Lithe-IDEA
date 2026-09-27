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
        .set_write_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    writeln!(
        untrusted,
        "{}",
        serde_json::json!({"token": "wrong-fixture-token", "prompt": "untrusted"})
    )
    .unwrap();
    untrusted.set_nonblocking(true).unwrap();
    let mut peer = TcpStream::connect(&env["LITHE_GIT_ASKPASS_ADDRESS"]).unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    peer.set_write_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    writeln!(peer, "{}", serde_json::json!({"token": env["LITHE_GIT_ASKPASS_TOKEN"], "prompt": "Password for fixture:"})).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut challenge = None;
    let mut rejection_observed = false;
    // The two TCP frames may arrive in either order or in fragments. Continue
    // pumping the owned session until both the prompt and rejection complete;
    // blocking on the rejected peer early would stop the only transport driver.
    while challenge.is_none() || !rejection_observed {
        for received in session.poll().unwrap() {
            assert!(challenge.is_none(), "Unexpected additional AskPass prompt");
            challenge = Some(received);
        }
        if !rejection_observed {
            match untrusted.read(&mut [0u8; 1]) {
                Ok(0) => rejection_observed = true,
                Ok(_) => panic!("Untrusted peer received a response"),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => panic!("Could not observe untrusted peer rejection: {error}"),
            }
        }
        assert!(
            Instant::now() < deadline,
            "AskPass prompt and peer rejection did not complete before deadline"
        );
        std::thread::yield_now();
    }
    let challenge = challenge.unwrap();
    assert!(challenge.secret);
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
