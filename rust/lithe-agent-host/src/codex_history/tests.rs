//! Archived Codex history: scope, paging and the one state-changing request.
use super::*;
use tokio::io::{AsyncBufReadExt, DuplexStream, ReadHalf, WriteHalf};

const WORKSPACE: &str = "/fixture/workspace";

fn launch(env: Vec<(String, String)>, subscription_cli: Option<PathBuf>) -> ResolvedLaunch {
    ResolvedLaunch {
        command: PathBuf::from("/fixture/codex-acp"),
        args: Vec::new(),
        cwd: PathBuf::from(WORKSPACE),
        env,
        gateway: None,
        secret: String::new(),
        subscription_cli,
        claude_subscription: false,
        codex_home: None,
    }
}

fn thread(id: &str, cwd: &str) -> Value {
    json!({"id": id, "cwd": cwd, "name": null, "preview": format!("Preview {id}"), "updatedAt": 1789993000, "recencyAt": 1789893000})
}

/// Answer each `thread/list` request with `page(index, params)`, then report
/// every params object it received.
async fn serve_pages(
    server: DuplexStream,
    pages: usize,
    page: impl Fn(usize) -> Value,
) -> Vec<Value> {
    let (reader, mut writer) = tokio::io::split(server);
    let mut lines = BufReader::new(reader).lines();
    let mut received = Vec::new();
    for index in 0..pages {
        let request: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(request["method"], "thread/list");
        received.push(request["params"].clone());
        writer
            .write_all(
                format!("{}\n", json!({"id": request["id"], "result": page(index)})).as_bytes(),
            )
            .await
            .unwrap();
    }
    received
}

fn client(client: DuplexStream) -> (WriteHalf<DuplexStream>, BufReader<ReadHalf<DuplexStream>>) {
    let (reader, writer) = tokio::io::split(client);
    (writer, BufReader::new(reader))
}

#[test]
fn only_codex_launches_have_archived_history_in_their_provider_scope() {
    let subscription = CodexHistory::for_launch(&launch(
        vec![("CODEX_PATH".into(), "/fixture/other".into())],
        Some(PathBuf::from("/fixture/codex")),
    ))
    .unwrap();
    assert_eq!(subscription.executable, PathBuf::from("/fixture/codex"));
    assert_eq!(subscription.model_provider, "openai");

    let gateway = CodexHistory::for_launch(&launch(
        vec![("CODEX_PATH".into(), "/fixture/codex".into())],
        None,
    ))
    .unwrap();
    assert_eq!(gateway.executable, PathBuf::from("/fixture/codex"));
    assert_eq!(gateway.model_provider, "custom-gateway");

    let claude = launch(
        vec![("CLAUDE_CODE_EXECUTABLE".into(), "/fixture/claude".into())],
        None,
    );
    assert!(CodexHistory::for_launch(&claude).is_none());
}

#[test]
fn workspace_paths_compare_like_codex_acp() {
    assert_eq!(normalize_path("/w/project/"), "/w/project");
    assert_eq!(normalize_path("/w/./other/../project//"), "/w/project");
    assert_ne!(normalize_path("/W/Project"), normalize_path("/w/project"));
    assert_eq!(normalize_path("C:\\Work\\Project\\"), "c:/work/project");
    assert_eq!(normalize_path("c:/work/project"), "c:/work/project");
    assert_eq!(
        normalize_path("\\\\Server\\Share\\Repo"),
        "//server/share/repo"
    );
}

#[test]
fn updated_at_seconds_become_utc_timestamps() {
    assert_eq!(iso8601(0).as_deref(), Some("1970-01-01T00:00:00Z"));
    assert_eq!(iso8601(951782400).as_deref(), Some("2000-02-29T00:00:00Z"));
    assert_eq!(iso8601(1789893000).as_deref(), Some("2026-09-20T08:30:00Z"));
    assert_eq!(iso8601(4133980799).as_deref(), Some("2100-12-31T23:59:59Z"));
    assert_eq!(iso8601(-1), None);
    assert_eq!(iso8601(i64::MAX), None);
}

#[test]
fn viewing_history_preserves_activity_but_a_new_turn_advances_it() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/agent/history-activity-v1.json"
    ))
    .unwrap();
    for stage in ["initial", "afterViewing", "afterMessage"] {
        let (threads, _) = parse_page(&fixture[stage]["upstream"], WORKSPACE).unwrap();
        let sessions: Vec<_> = threads
            .into_iter()
            .map(|thread| AgentSessionSummary {
                session_id: thread.id,
                title: thread.title,
                updated_at: thread.updated_at,
            })
            .collect();
        assert_eq!(
            serde_json::to_value(sessions).unwrap(),
            fixture[stage]["event"]["sessions"]
        );
    }
    assert_eq!(
        fixture["initial"]["event"],
        fixture["afterViewing"]["event"]
    );
    assert_ne!(
        fixture["initial"]["event"],
        fixture["afterMessage"]["event"]
    );
}

#[test]
fn missing_or_invalid_activity_never_falls_back_to_metadata_time() {
    for activity in [
        Value::Null,
        json!("1789893000"),
        json!(-1),
        json!(true),
        json!(i64::MAX),
    ] {
        let mut row = thread("unknown", WORKSPACE);
        row["recencyAt"] = activity;
        let (threads, _) = parse_page(&json!({"data": [row]}), WORKSPACE).unwrap();
        assert_eq!(threads[0].updated_at, None);
    }
}

#[test]
fn pages_keep_only_this_workspace_and_prefer_the_user_title() {
    let page = json!({
        "data": [
            {"id": "named", "cwd": "/fixture/workspace/", "name": "Renamed", "preview": "First prompt", "updatedAt": 1789993000, "recencyAt": 1789893000},
            {"id": "preview", "cwd": WORKSPACE, "name": " ", "preview": "First prompt"},
            {"id": "elsewhere", "cwd": "/fixture/other", "name": "Other"},
            {"id": "no-cwd", "name": "Unknown"},
            {"id": "", "cwd": WORKSPACE}
        ],
        "nextCursor": "page-2"
    });
    let (threads, next) = parse_page(&page, WORKSPACE).unwrap();
    assert_eq!(
        threads,
        vec![
            HistoryThread {
                id: "named".into(),
                title: Some("Renamed".into()),
                updated_at: Some("2026-09-20T08:30:00Z".into()),
            },
            HistoryThread {
                id: "preview".into(),
                title: Some("First prompt".into()),
                updated_at: None,
            },
        ]
    );
    assert_eq!(next.as_deref(), Some("page-2"));
    assert_eq!(
        parse_page(&json!({"data": [], "nextCursor": ""}), WORKSPACE)
            .unwrap()
            .1,
        None
    );
    assert!(parse_page(&json!({}), WORKSPACE).is_err());
}

#[tokio::test]
async fn listing_follows_cursors_past_foreign_pages_without_duplicates() {
    let (local, server) = tokio::io::duplex(64 * 1024);
    let (mut writer, mut reader) = client(local);
    let mut on_page = |_: &[HistoryThread]| {};
    let peer = serve_pages(server, 3, |index| match index {
        0 => json!({"data": [thread("a", WORKSPACE)], "nextCursor": "c1"}),
        // Another workspace fills this page; the history has not ended.
        1 => json!({"data": [thread("x", "/fixture/other")], "nextCursor": "c2"}),
        _ => json!({"data": [thread("a", WORKSPACE), thread("b", WORKSPACE)], "nextCursor": null}),
    });
    let (result, received) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(
            list_pages(
                &mut writer,
                &mut reader,
                "openai",
                WORKSPACE,
                true,
                &mut on_page
            ),
            peer
        )
    })
    .await
    .expect("bounded in-memory listing");
    let (threads, complete) = result.unwrap();
    assert!(complete);
    let ids: Vec<_> = threads.iter().map(|thread| thread.id.as_str()).collect();
    assert_eq!(ids, ["a", "b"]);
    assert_eq!(received[0]["archived"], true);
    assert_eq!(received[0]["sortKey"], "recency_at");
    assert_eq!(received[0]["useStateDbOnly"], true);
    assert_eq!(received[0]["cursor"], Value::Null);
    assert_eq!(received[0]["modelProviders"], json!(["openai"]));
    assert_eq!(received[0]["sourceKinds"], json!(SOURCE_KINDS));
    assert_eq!(received[1]["cursor"], "c1");
    assert_eq!(received[2]["cursor"], "c2");
}

#[tokio::test]
async fn listing_reports_when_the_page_bound_truncated_it() {
    let (local, server) = tokio::io::duplex(64 * 1024);
    let (mut writer, mut reader) = client(local);
    let mut on_page = |_: &[HistoryThread]| {};
    let peer = serve_pages(
        server,
        MAX_SESSION_LIST_PAGES,
        |index| json!({"data": [thread(&format!("t{index}"), WORKSPACE)], "nextCursor": format!("c{index}")}),
    );
    let (result, received) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(
            list_pages(
                &mut writer,
                &mut reader,
                "custom-gateway",
                WORKSPACE,
                true,
                &mut on_page
            ),
            peer
        )
    })
    .await
    .expect("bounded in-memory listing");
    let (threads, complete) = result.unwrap();
    assert!(!complete);
    assert_eq!(threads.len(), MAX_SESSION_LIST_PAGES);
    assert_eq!(received.len(), MAX_SESSION_LIST_PAGES);
}

#[tokio::test]
async fn active_history_publishes_matching_rows_before_later_pages_without_duplicates() {
    let (local, server) = tokio::io::duplex(64 * 1024);
    let (mut writer, mut reader) = client(local);
    let workspace = workspace_context::WorkspaceContext::new(Path::new(WORKSPACE)).unwrap();
    let published = Mutex::new(Vec::<Vec<AgentSessionSummary>>::new());
    let mut on_page = |threads: &[HistoryThread]| {
        published.lock().unwrap().push(
            threads
                .iter()
                .map(|thread| thread.summary(&workspace))
                .collect(),
        );
    };
    let peer = serve_pages(server, 4, |index| {
        if index > 0 {
            // Each next request is observed before its response is sent. The first
            // page must already be visible, even while the scan is incomplete.
            let pages = published.lock().unwrap();
            assert_eq!(
                pages.len(),
                1,
                "Foreign and duplicate-only pages add no rows"
            );
            assert_eq!(pages[0][0].session_id, "a");
            assert_eq!(pages[0][0].title.as_deref(), Some("Preview a"));
            assert_eq!(
                pages[0][0].updated_at.as_deref(),
                Some("2026-09-20T08:30:00Z")
            );
        }
        match index {
            0 => json!({"data": [thread("a", WORKSPACE)], "nextCursor": "c1"}),
            1 => json!({"data": [thread("foreign", "/fixture/other")], "nextCursor": "c2"}),
            2 => json!({"data": [thread("a", WORKSPACE)], "nextCursor": "c3"}),
            _ => json!({"data": [thread("b", WORKSPACE)], "nextCursor": null}),
        }
    });
    let (result, received) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(
            list_pages(
                &mut writer,
                &mut reader,
                "openai",
                WORKSPACE,
                false,
                &mut on_page
            ),
            peer
        )
    })
    .await
    .expect("bounded incremental official history listing");
    let (threads, complete) = result.unwrap();
    assert!(complete);
    assert_eq!(
        threads
            .iter()
            .map(|thread| thread.id.as_str())
            .collect::<Vec<_>>(),
        ["a", "b"]
    );
    assert_eq!(
        published.lock().unwrap().len(),
        1,
        "The final page belongs to the full snapshot"
    );
    assert!(received
        .iter()
        .all(|params| params["useStateDbOnly"] == true
            && params["sortKey"] == "recency_at"
            && params["archived"] == false));
}

/// A fake `codex app-server` that records requests and answers every id.
#[cfg(unix)]
fn fake_app_server(directory: &Path, reply: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let log = directory.join("requests.log");
    let script = directory.join("codex");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\n[ \"$1\" = app-server ] || exit 2\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> '{}'\n  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\\([0-9]*\\).*/\\1/p')\n  [ -n \"$id\" ] && printf '{{\"id\":%s,{reply}}}\\n' \"$id\"\ndone\n",
            log.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

#[cfg(unix)]
struct TempDirectory(PathBuf);

#[cfg(unix)]
impl TempDirectory {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("lithe-codex-history-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

#[cfg(unix)]
impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
#[tokio::test]
async fn active_and_archived_listing_only_read_official_activity_metadata() {
    let directory = TempDirectory::new("activity");
    let mut row = thread("saved", directory.0.to_str().unwrap());
    row["updatedAt"] = json!(1789993000);
    let reply = format!("\"result\":{}", json!({"data": [row], "nextCursor": null}));
    let history = CodexHistory {
        executable: fake_app_server(&directory.0, &reply),
        cwd: directory.0.clone(),
        model_provider: SUBSCRIPTION_PROVIDER,
        codex_home: None,
    };
    let workspace = workspace_context::WorkspaceContext::new(&directory.0).unwrap();
    let emit: Emit = Arc::new(|_| {});
    tokio::time::timeout(Duration::from_secs(10), async {
        let active = history
            .list_active(&workspace, "active", &emit)
            .await
            .unwrap();
        let archived = history.list_archived(&workspace).await.unwrap();
        assert_eq!(active, archived.sessions);
        assert_eq!(
            active[0].updated_at.as_deref(),
            Some("2026-09-20T08:30:00Z")
        );
    })
    .await
    .expect("bounded official history reads");
    let requests: Vec<Value> = std::fs::read_to_string(directory.0.join("requests.log"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let methods: Vec<_> = requests
        .iter()
        .map(|request| request["method"].as_str().unwrap())
        .collect();
    assert_eq!(
        methods,
        [
            "initialize",
            "initialized",
            "thread/list",
            "initialize",
            "initialized",
            "thread/list"
        ]
    );
    let lists: Vec<_> = requests
        .iter()
        .filter(|request| request["method"] == "thread/list")
        .collect();
    assert_eq!(lists[0]["params"]["archived"], false);
    assert_eq!(lists[1]["params"]["archived"], true);
    assert!(lists
        .iter()
        .all(|request| request["params"]["useStateDbOnly"] == true));
}

#[cfg(unix)]
#[tokio::test]
async fn unarchive_sends_only_the_selected_thread_to_the_users_cli() {
    let directory = TempDirectory::new("unarchive");
    let history = CodexHistory {
        executable: fake_app_server(&directory.0, "\"result\":{\"thread\":{}}"),
        cwd: directory.0.clone(),
        model_provider: SUBSCRIPTION_PROVIDER,
        codex_home: None,
    };
    tokio::time::timeout(
        Duration::from_secs(10),
        history.unarchive("thread-1".into()),
    )
    .await
    .expect("bounded app-server exchange")
    .unwrap();
    let requests: Vec<Value> = std::fs::read_to_string(directory.0.join("requests.log"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let methods: Vec<_> = requests
        .iter()
        .map(|request| request["method"].as_str().unwrap())
        .collect();
    assert_eq!(methods, ["initialize", "initialized", "thread/unarchive"]);
    assert_eq!(requests[2]["params"], json!({"threadId": "thread-1"}));
}

#[cfg(unix)]
#[tokio::test]
async fn upstream_errors_never_reach_the_ui() {
    let directory = TempDirectory::new("error");
    let history = CodexHistory {
        executable: fake_app_server(
            &directory.0,
            "\"error\":{\"message\":\"/Users/secret/.codex failed\"}",
        ),
        cwd: directory.0.clone(),
        model_provider: GATEWAY_PROVIDER,
        codex_home: None,
    };
    let error = tokio::time::timeout(
        Duration::from_secs(10),
        history.unarchive("thread-1".into()),
    )
    .await
    .expect("bounded app-server exchange")
    .unwrap_err();
    assert_eq!(error, "Codex could not restore this archived conversation.");
}
