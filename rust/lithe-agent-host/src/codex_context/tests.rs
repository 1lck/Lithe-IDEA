//! Bounded recovery, stale tickets, hostile loopback requests, and cancellation.

use super::*;

fn report(loads: &Loads, session: &str, ticket: &str, used: u64, size: u64) {
    dispatch(
        loads,
        "report",
        json!({"sessionId": session, "ticket": ticket, "used": used, "size": size}),
    );
}

#[tokio::test(start_paused = true)]
async fn native_zero_and_compacted_counts_remain_actual_historical_reports() {
    let loads = Loads::default();
    for used in [18700, 1000, 0] {
        let capture = capture(&loads, "session-a").unwrap();
        report(&loads, "session-a", &capture.ticket, used, 258400);
        let value = capture.finish().await.unwrap();
        assert_eq!(value["used"], used);
        assert_eq!(value["size"], 258400);
        assert_eq!(value["_meta"]["lithe"]["contextUsageSource"], "history");
        assert!(loads.lock().unwrap().is_empty());
    }
}

#[tokio::test(start_paused = true)]
async fn late_wrong_session_and_replaced_loads_cannot_supply_a_snapshot() {
    let loads = Loads::default();
    let old = capture(&loads, "session-a").unwrap();
    let old_ticket = old.ticket.clone();
    let current = capture(&loads, "session-a").unwrap();
    drop(old);
    assert_eq!(
        dispatch(&loads, "capture", json!({"sessionId":"session-a"}))["ticket"],
        current.ticket
    );
    report(&loads, "session-a", &old_ticket, 999, 1000);
    report(&loads, "session-b", &current.ticket, 999, 1000);
    report(&loads, "session-a", &current.ticket, 999, 0);
    // Virtual time reaches the optional report deadline; no real sleep occurs.
    assert!(current.finish().await.is_none());
    assert!(loads.lock().unwrap().is_empty());
    report(&loads, "session-a", &old_ticket, 1, 1000);
    assert!(loads.lock().unwrap().is_empty());
}

#[tokio::test(start_paused = true)]
async fn capture_count_is_bounded_and_abandoned_loads_release_their_slots() {
    let loads = Loads::default();
    let mut captures = (0..MAX_LOADS)
        .map(|id| capture(&loads, &format!("session-{id}")).unwrap())
        .collect::<Vec<_>>();
    assert!(capture(&loads, "overflow").is_none());
    captures.pop();
    assert!(capture(&loads, "overflow").is_some());
    drop(captures);
    assert!(loads.lock().unwrap().is_empty());
}

#[tokio::test(start_paused = true)]
async fn queued_native_reports_cannot_override_a_new_load_or_an_acp_report() {
    let recovery = Recovery::start().await.unwrap();
    let old = recovery.capture("session-a").unwrap();
    report(&recovery.loads, "session-a", &old.ticket, 100, 1000);
    let current = recovery.capture("session-a").unwrap();
    assert!(old.finish().await.is_none());
    report(&recovery.loads, "session-a", &current.ticket, 100, 1000);
    recovery.prefer_upstream_report("session-a");
    assert!(current.finish().await.is_none());
}

#[tokio::test]
async fn loopback_requires_the_launch_capability_and_bounds_message_bodies() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let recovery = Recovery::start().await.unwrap();
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(1))
            .no_proxy()
            .build()
            .unwrap();
        let authority = url::Url::parse(recovery.url())
            .unwrap()
            .origin()
            .ascii_serialization();
        assert_eq!(
            client
                .post(format!("{authority}/wrong/capture"))
                .body("{}")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        let capture = recovery.capture("session-a").unwrap();
        let response = client
            .post(format!("{}/capture", recovery.url()))
            .body(r#"{"sessionId":"session-a"}"#)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        let response: Value = serde_json::from_slice(&response).unwrap();
        assert_eq!(response["ticket"], capture.ticket);
        assert_eq!(
            client
                .post(format!("{}/report", recovery.url()))
                .body("x".repeat(MAX_BODY + 1))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::BAD_REQUEST
        );
        let payload =
            json!({"sessionId":"session-a", "ticket":capture.ticket, "used":125300, "size":300000});
        client
            .post(format!("{}/report", recovery.url()))
            .body(payload.to_string())
            .send()
            .await
            .unwrap();
        assert_eq!(capture.finish().await.unwrap()["used"], 125300);
        drop(recovery);
    })
    .await
    .expect("loopback exchange finishes within its local deadline");
}
