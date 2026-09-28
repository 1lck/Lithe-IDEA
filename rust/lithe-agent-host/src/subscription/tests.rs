//! Regression coverage for account-scoped subscription observations.
use super::*;

#[test]
fn windows_use_reported_duration_and_preserve_unknown_usage() {
    let result = windows(&json!({"rateLimits": {
        "primary": {"windowDurationMins":10080,"usedPercent":70,"resetsAt":1800000000},
        "secondary": {"windowDurationMins":300,"usedPercent":null}
    }}))
    .unwrap();
    assert_eq!(result[0].limit_seconds, 604800);
    assert_eq!(result[1].limit_seconds, 18000);
    assert_eq!(result[1].used_percent, None);
}

#[test]
fn missing_duration_and_invalid_usage_never_become_unused_windows() {
    assert!(windows(&json!({"rateLimits":{"primary":{"usedPercent":5}}})).is_err());
    let result =
        windows(&json!({"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":101}}}))
            .unwrap();
    assert_eq!(result[0].used_percent, None);
}

#[test]
fn multiple_buckets_are_ordered_and_do_not_duplicate_legacy_snapshot() {
    let window = json!({"primary":{"windowDurationMins":300,"usedPercent":50}});
    let result =
        windows(&json!({"rateLimits":window,"rateLimitsByLimitId":{"z":window,"a":window}}))
            .unwrap();
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].id, "a:primary");
}

#[test]
fn quota_requires_the_same_subscription_identity() {
    let expected = Account {
        email: Some("person@example.test".into()),
        plan: Some("plus".into()),
    };
    assert!(check_account(
        &json!({"account":{"type":"chatgpt","email":"person@example.test"}}),
        &expected
    )
    .is_ok());
    assert_eq!(
        check_account(&json!({"account":{"type":"apiKey"}}), &expected),
        Err("unauthorized")
    );
    assert_eq!(
        check_account(
            &json!({"account":{"type":"chatgpt","email":"other@example.test"}}),
            &expected
        ),
        Err("accountChanged")
    );
    assert_eq!(
        check_account(&json!({"account":{"type":"chatgpt"}}), &expected),
        Err("accountChanged")
    );
}

#[test]
fn subscription_environment_removes_api_overrides_without_changing_cli_home() {
    let mut command = std::process::Command::new("fixture-codex");
    command
        .env("CODEX_HOME", "/fixture/codex-home")
        .env("OPENAI_API_KEY", "fixture-key");
    isolate_environment(&mut command);
    let entries: std::collections::BTreeMap<_, _> = command.get_envs().collect();
    assert_eq!(
        entries.get(std::ffi::OsStr::new("OPENAI_API_KEY")),
        Some(&None)
    );
    assert_eq!(
        entries.get(std::ffi::OsStr::new("CODEX_HOME")),
        Some(&Some(std::ffi::OsStr::new("/fixture/codex-home")))
    );
}

#[tokio::test]
async fn probe_only_reads_identity_and_limits_and_rechecks_account() {
    let (client, server) = tokio::io::duplex(8192);
    let (reader, mut writer) = tokio::io::split(client);
    let mut reader = BufReader::new(reader);
    let expected = Account {
        email: Some("person@example.test".into()),
        plan: None,
    };
    let peer = async {
        let (reader, mut writer) = tokio::io::split(server);
        let mut lines = BufReader::new(reader).lines();
        for method in [
            "initialize",
            "initialized",
            "account/read",
            "account/rateLimits/read",
            "account/read",
        ] {
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], method);
            if method == "initialized" {
                continue;
            }
            let result = match method {
                "account/read" => {
                    json!({"account":{"type":"chatgpt","email":"person@example.test"}})
                }
                "account/rateLimits/read" => {
                    json!({"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}})
                }
                _ => json!({}),
            };
            writer
                .write_all(format!("{}\n", json!({"id":request["id"],"result":result})).as_bytes())
                .await
                .unwrap();
        }
    };
    let (result, ()) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(exchange(&mut writer, &mut reader, &expected), peer)
    })
    .await
    .expect("bounded in-memory protocol exchange");
    assert_eq!(result.unwrap().windows[0].used_percent, Some(25.0));
}

#[cfg(unix)]
#[tokio::test]
async fn dropping_a_probe_closes_descendant_pipes() {
    use std::os::unix::process::CommandExt;
    let mut command = std::process::Command::new("sh");
    command
        .args(["-c", "sh -c 'printf ready; cat' & wait"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let mut command = tokio::process::Command::from(command);
    command.kill_on_drop(true);
    let mut child = ProbeProcess(command.spawn().unwrap());
    let input = child.0.stdin.take().unwrap();
    let mut output = child.0.stdout.take().unwrap();
    let mut ready = [0; 5];
    tokio::time::timeout(Duration::from_secs(5), output.read_exact(&mut ready))
        .await
        .expect("bounded child readiness")
        .unwrap();
    assert_eq!(&ready, b"ready");
    // Keep stdin open: only process-tree cleanup can release the inherited stdout.
    drop(child);
    let mut remaining = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), output.read_to_end(&mut remaining))
        .await
        .expect("probe cancellation killed descendants")
        .unwrap();
    drop(input);
}

#[tokio::test(start_paused = true)]
async fn missing_account_confirmation_has_a_bounded_deadline() {
    let (_sender, mut status) = tokio::sync::watch::channel(None);
    let error = wait_status(&mut status, true).await.unwrap_err();
    assert!(error.to_string().contains("confirm its account in time"));
}
