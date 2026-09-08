//! Deterministic DAP adapter fixture used by Windows process lifecycle tests.

use serde_json::Value;
use std::io::{self, Read, Write};

fn frame(payload: &str) -> Vec<u8> {
    format!("Content-Length: {}\r\n\r\n{}", payload.len(), payload).into_bytes()
}

fn read_frame(input: &mut impl Read) -> Option<Value> {
    let mut bytes = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        if input.read(&mut byte).ok()? == 0 {
            return None;
        }
        bytes.push(byte[0]);
        if bytes.ends_with(b"\r\n\r\n") {
            let header = String::from_utf8(bytes).ok()?;
            let length = header
                .lines()
                .find_map(|line| line.strip_prefix("Content-Length: "))?
                .parse::<usize>()
                .ok()?;
            let mut body = vec![0_u8; length];
            input.read_exact(&mut body).ok()?;
            return serde_json::from_slice(&body).ok();
        }
    }
}

fn write_frame(output: &mut impl Write, payload: &str, fragmented: bool) {
    let bytes = frame(payload);
    if fragmented {
        let midpoint = bytes.len() / 2;
        let _ = output.write_all(&bytes[..midpoint]);
        let _ = output.flush();
        let _ = output.write_all(&bytes[midpoint..]);
    } else {
        let _ = output.write_all(&bytes);
    }
    let _ = output.flush();
}

fn main() {
    let mode = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "normal".to_string());
    eprintln!("fake-dap-adapter:{mode}");
    if mode == "eof-live" {
        return;
    }

    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();
    let Some(initialize) = read_frame(&mut stdin) else {
        let payload = if mode == "reject-initialize" {
            r#"{"seq":1,"type":"response","request_seq":1,"success":false,"command":"initialize","message":"rejected"}"#
        } else {
            r#"{"seq":1,"type":"event","event":"terminated"}"#
        };
        write_frame(&mut stdout, payload, mode == "fragmented");
        return;
    };
    let initialize_seq = initialize["seq"].as_i64().unwrap_or(1);
    if mode == "reject-initialize" {
        write_frame(
            &mut stdout,
            &format!(
                r#"{{"seq":1,"type":"response","request_seq":{initialize_seq},"success":false,"command":"initialize","message":"rejected"}}"#
            ),
            false,
        );
        return;
    }
    write_frame(
        &mut stdout,
        &format!(
            r#"{{"seq":1,"type":"response","request_seq":{initialize_seq},"success":true,"command":"initialize","body":{{"supportsConfigurationDoneRequest":true}}}}"#
        ),
        mode == "fragmented",
    );
    write_frame(
        &mut stdout,
        r#"{"seq":2,"type":"event","event":"initialized"}"#,
        mode == "fragmented",
    );
    let Some(launch) = read_frame(&mut stdin) else {
        return;
    };
    let launch_seq = launch["seq"].as_i64().unwrap_or(2);
    if mode == "reject-launch" {
        write_frame(
            &mut stdout,
            &format!(
                r#"{{"seq":3,"type":"response","request_seq":{launch_seq},"success":false,"command":"launch","message":"rejected"}}"#
            ),
            false,
        );
        return;
    }
    write_frame(
        &mut stdout,
        &format!(
            r#"{{"seq":3,"type":"response","request_seq":{launch_seq},"success":true,"command":"launch"}}"#
        ),
        mode == "fragmented",
    );
    if mode == "hold" {
        while read_frame(&mut stdin).is_some() {}
        return;
    }
    let _ = read_frame(&mut stdin);
    if mode == "startup-stopped" {
        write_frame(
            &mut stdout,
            r#"{"seq":4,"type":"event","event":"stopped","reason":"entry","body":{"threadId":1}}"#,
            false,
        );
        while read_frame(&mut stdin).is_some() {}
        return;
    }
    write_frame(
        &mut stdout,
        r#"{"seq":4,"type":"event","event":"terminated"}"#,
        mode == "fragmented",
    );
}
