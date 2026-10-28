//! Local IDE capability broker. Native applications own every product action;
//! this adapter owns authentication, bounded delivery, connection files and shutdown.

pub mod catalog;

use axum::{
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    routing::post,
    Json, Router,
};
use catalog::{failure, Permissions};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};
use tokio::sync::oneshot;
use uuid::Uuid;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_PENDING: usize = 16;

/// One authenticated request to the connected workspace's application dispatcher.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Call {
    pub name: String,
    pub arguments: Value,
}

struct Pending {
    call: Call,
    reply: oneshot::Sender<Value>,
    claimed: bool,
    created: Instant,
}
/// Native push notification. The receiver must claim the request before executing it.
/// Returning an error fails only that delivery; it never replays an operation.
pub type RequestDispatcher = Arc<dyn Fn(String) -> Result<(), String> + Send + Sync>;

fn prune_pending(pending: &mut BTreeMap<String, Pending>) {
    let expired: Vec<_> = pending
        .iter()
        .filter(|(_, p)| p.reply.is_closed() || p.created.elapsed() >= REQUEST_TIMEOUT)
        .map(|(id, _)| id.clone())
        .collect();
    for id in expired {
        if let Some(p) = pending.remove(&id) {
            let _ = p.reply.send(failure(
                "TIMEOUT",
                "The IDE request expired. Inspect operations before retrying a mutation.",
            ));
        }
    }
}

struct Broker {
    enabled: AtomicBool,
    token: String,
    permissions: Permissions,
    pending: Mutex<BTreeMap<String, Pending>>,
    last_poll: Mutex<Instant>,
    dispatcher: Mutex<Option<RequestDispatcher>>,
    queued: tokio::sync::Notify,
}
struct Host {
    broker: Arc<Broker>,
    task: tokio::task::JoinHandle<()>,
    connection: PathBuf,
    _lock: File,
    owner: String,
}
impl Drop for Host {
    fn drop(&mut self) {
        self.broker.enabled.store(false, Ordering::Release);
        self.task.abort();
        if let Ok(mut pending) = self.broker.pending.lock() {
            for (_, p) in std::mem::take(&mut *pending) {
                let _ = p.reply.send(failure(
                    "DISCONNECTED",
                    "IDE access was disabled or the project was closed",
                ));
            }
        }
        if let Err(error) = std::fs::remove_file(&self.connection) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Could not remove IDE MCP connection: {error}");
            }
        }
    }
}
static HOSTS: OnceLock<Mutex<BTreeMap<String, Host>>> = OnceLock::new();
static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();
fn hosts() -> &'static Mutex<BTreeMap<String, Host>> {
    HOSTS.get_or_init(Default::default)
}
fn runtime() -> Result<&'static tokio::runtime::Runtime, String> {
    // Serialize first use: dropping a losing runtime can block or panic inside
    // a Tokio context when two windows open their first connection concurrently.
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(Clone::clone)
}

/// Private connection descriptor: created only in the platform's writable app-data directory.
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub endpoint: String,
    pub token: String,
}

fn private_file(path: &std::path::Path, truncate: bool) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options
        .create(true)
        .write(true)
        .read(true)
        .truncate(truncate);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Open {
    directory: PathBuf,
    workspace_key: String,
    helper_path: PathBuf,
    permissions: Permissions,
    #[serde(default)]
    owner_id: String,
}

fn open(args: Value) -> Result<Value, String> {
    use sha2::{Digest, Sha256};
    let args: Open = serde_json::from_value(args).map_err(|e| e.to_string())?;
    if !args.directory.is_absolute()
        || !args.helper_path.is_absolute()
        || args.workspace_key.is_empty()
    {
        return Err("The platform must supply absolute writable storage and helper paths".into());
    }
    if !args.helper_path.is_file() {
        return Err("The packaged lithe-mcp helper is missing. Reinstall or rebuild Lithe.".into());
    }
    std::fs::create_dir_all(&args.directory).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&args.directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
    }
    let key = format!("{:x}", Sha256::digest(args.workspace_key.as_bytes()));
    let lock = private_file(&args.directory.join(format!("{key}.lock")), false)
        .map_err(|e| e.to_string())?;
    lock.try_lock_exclusive()
        .map_err(|_| "This project already has an MCP connection in another window".to_owned())?;
    let connection = args.directory.join(format!("{key}.json"));
    let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .map_err(|e| e.to_string())?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let endpoint = format!(
        "http://127.0.0.1:{}/call",
        listener.local_addr().map_err(|e| e.to_string())?.port()
    );
    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let descriptor = Connection {
        endpoint,
        token: token.clone(),
    };
    let broker = Arc::new(Broker {
        enabled: AtomicBool::new(true),
        token,
        permissions: args.permissions,
        pending: Mutex::new(BTreeMap::new()),
        last_poll: Mutex::new(Instant::now()),
        dispatcher: Mutex::new(None),
        queued: tokio::sync::Notify::new(),
    });
    let runtime = runtime()?;
    let _enter = runtime.enter();
    let listener = tokio::net::TcpListener::from_std(listener).map_err(|e| e.to_string())?;
    let router = Router::new()
        .route("/call", post(call))
        .layer(DefaultBodyLimit::max(64 * 1024))
        .with_state(broker.clone());
    let mut file = private_file(&connection, true).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec(&descriptor).map_err(|e| e.to_string())?)
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    let task = runtime.spawn(async move {
        if let Err(error) = axum::serve(listener, router).await {
            eprintln!("IDE MCP broker stopped: {error}");
        }
    });
    let id = Uuid::new_v4().to_string();
    let configuration = json!({"mcpServers":{"lithe":{"command":args.helper_path,"args":["--connection",connection]}}});
    hosts().lock().map_err(|_| "IDE host unavailable")?.insert(
        id.clone(),
        Host {
            broker,
            task,
            connection,
            _lock: lock,
            owner: args.owner_id,
        },
    );
    Ok(json!({"hostID":id,"configuration":configuration}))
}

/// Attaches a native window's request channel without changing its authorization.
/// Notifications contain only an ID: delayed events cannot execute expired work.
pub fn attach_dispatcher(
    host_id: &str,
    owner: &str,
    dispatcher: RequestDispatcher,
) -> Result<(), String> {
    let broker = {
        let hosts = hosts().lock().map_err(|_| "IDE host unavailable")?;
        let host = hosts
            .get(host_id)
            .ok_or("IDE access is no longer enabled")?;
        if host.owner != owner {
            return Err("IDE connection belongs to another window".into());
        }
        host.broker.clone()
    };
    let queued = {
        let mut slot = broker
            .dispatcher
            .lock()
            .map_err(|_| "IDE dispatcher unavailable")?;
        if slot.is_some() {
            return Err("IDE dispatcher is already attached".into());
        }
        let pending = broker.pending.lock().map_err(|_| "IDE queue unavailable")?;
        if !broker.enabled.load(Ordering::Acquire) {
            return Err("IDE access is no longer enabled".into());
        }
        *slot = Some(dispatcher.clone());
        pending
            .iter()
            .filter(|(_, p)| {
                !p.claimed && !p.reply.is_closed() && p.created.elapsed() < REQUEST_TIMEOUT
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>()
    };
    for id in queued {
        deliver(&broker, &dispatcher, id);
    }
    Ok(())
}

fn deliver(broker: &Broker, dispatcher: &RequestDispatcher, id: String) {
    // Never call platform code under queue/host locks; a receiver may respond inline.
    if dispatcher(id.clone()).is_err() {
        if let Ok(mut pending) = broker.pending.lock() {
            if pending.get(&id).is_some_and(|p| !p.claimed) {
                if let Some(request) = pending.remove(&id) {
                    let _ = request.reply.send(failure(
                        "DISPATCHER_UNAVAILABLE",
                        "The project could not receive this request. Retry after the IDE responds.",
                    ));
                }
            }
        }
    }
}

// Constant-time comparison avoids making the bearer check depend on a matching prefix.
fn authorized(headers: &HeaderMap, token: &str) -> bool {
    if headers.contains_key("origin") {
        return false;
    }
    let expected = format!("Bearer {token}");
    let value = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    value.len() == expected.len()
        && value
            .bytes()
            .zip(expected.bytes())
            .fold(0u8, |d, (a, b)| d | (a ^ b))
            == 0
}

struct PendingLease {
    broker: Arc<Broker>,
    id: String,
}
impl Drop for PendingLease {
    fn drop(&mut self) {
        if let Ok(mut p) = self.broker.pending.lock() {
            p.remove(&self.id);
        }
    }
}

async fn call(
    State(broker): State<Arc<Broker>>,
    headers: HeaderMap,
    Json(request): Json<Call>,
) -> (StatusCode, Json<Value>) {
    let response = |value| (StatusCode::OK, Json(value));
    if !authorized(&headers, &broker.token) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(failure(
                "UNAUTHORIZED",
                "IDE connection authorization failed",
            )),
        );
    }
    if let Err(error) = catalog::validate(&request.name, &request.arguments, &broker.permissions) {
        return response(error);
    }
    let (dispatcher, receiver, id) = {
        // Event-driven native hosts do not depend on WebView timer heartbeats.
        // Hold registration through enqueue so attaching cannot miss a pending request.
        let dispatcher = match broker.dispatcher.lock() {
            Ok(dispatcher) => dispatcher,
            Err(_) => return response(failure("UNAVAILABLE", "IDE dispatcher unavailable")),
        };
        if dispatcher.is_none()
            && broker
                .last_poll
                .lock()
                .map(|t| t.elapsed() > Duration::from_secs(15))
                .unwrap_or(true)
        {
            return response(failure(
                "DISCONNECTED",
                "IDE project dispatcher is not responding",
            ));
        }
        let (sender, receiver) = oneshot::channel();
        let id = Uuid::new_v4().to_string();
        {
            let Ok(mut pending) = broker.pending.lock() else {
                return response(failure("UNAVAILABLE", "IDE request queue unavailable"));
            };
            // An already established HTTP connection can outlive the listener.
            // Check under the queue lock so revocation cannot miss a late insertion.
            if !broker.enabled.load(Ordering::Acquire) {
                return response(failure("DISCONNECTED", "IDE access was disabled"));
            }
            prune_pending(&mut pending);
            if pending.len() >= MAX_PENDING {
                return response(failure("BUSY", "Too many pending IDE operations"));
            }
            pending.insert(
                id.clone(),
                Pending {
                    call: request,
                    reply: sender,
                    claimed: false,
                    created: Instant::now(),
                },
            );
        }
        (dispatcher.clone(), receiver, id)
    };
    broker.queued.notify_one();
    if let Some(dispatcher) = dispatcher {
        deliver(&broker, &dispatcher, id.clone());
    }
    let _lease = PendingLease { broker, id };
    let result = match tokio::time::timeout(REQUEST_TIMEOUT, receiver).await {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => failure("DISCONNECTED", "IDE access was disabled"),
        Err(_) => failure(
            "TIMEOUT",
            "The IDE did not respond in time. Inspect operations before retrying a mutation.",
        ),
    };
    response(result)
}

/// Local-only bridge entry point; external clients can call only the catalog above.
pub fn execute(action: &str, args: Value) -> Result<Value, String> {
    if action == "output" {
        return Ok(catalog::output_page(
            args["snapshot"].clone(),
            args["cursor"].as_str(),
        ));
    }
    if action == "closeOwner" {
        let owner = args["ownerID"].as_str().ok_or("Missing ownerID")?;
        hosts()
            .lock()
            .map_err(|_| "IDE host unavailable")?
            .retain(|_, host| host.owner != owner);
        return Ok(json!({"closed":true}));
    }
    if action == "open" {
        return open(args);
    }
    if action == "catalog" {
        return Ok(json!({"version":1,"tools":catalog::tools()}));
    }
    if action == "validate" {
        let permissions: Permissions =
            serde_json::from_value(args["permissions"].clone()).map_err(|e| e.to_string())?;
        return Ok(
            match catalog::validate(
                args["name"].as_str().unwrap_or(""),
                &args["arguments"],
                &permissions,
            ) {
                Ok(()) => {
                    let name = args["name"].as_str().unwrap_or("");
                    let mutation = name != "lithe_operation_stop"
                        && catalog::tools().iter().any(|tool| {
                            tool["name"] == name && tool["annotations"]["readOnlyHint"] == false
                        });
                    json!({"ok":true,"mutation":mutation})
                }
                Err(e) => e,
            },
        );
    }
    let id = args["hostID"].as_str().ok_or("Missing hostID")?;
    let mut hosts = hosts().lock().map_err(|_| "IDE host unavailable")?;
    if action == "close" {
        hosts.remove(id);
        return Ok(json!({"closed":true}));
    }
    let host = hosts.get(id).ok_or("IDE access is no longer enabled")?;
    let mut pending = host
        .broker
        .pending
        .lock()
        .map_err(|_| "IDE queue unavailable")?;
    match action {
        "claim" => {
            let request_id = args["requestID"].as_str().ok_or("Missing requestID")?;
            prune_pending(&mut pending);
            let request = pending.get_mut(request_id).filter(|p| !p.claimed).map(|p| {
                p.claimed = true;
                json!({"requestID":request_id,"name":p.call.name,"arguments":p.call.arguments,
                        "remainingMilliseconds":REQUEST_TIMEOUT.saturating_sub(p.created.elapsed()).as_millis() as u64})
            });
            Ok(json!({"request":request}))
        }
        "poll" => {
            *host
                .broker
                .last_poll
                .lock()
                .map_err(|_| "IDE host unavailable")? = Instant::now();
            prune_pending(&mut pending);
            let requests: Vec<_> = pending
                .iter_mut()
                .filter(|(_, p)| !p.claimed)
                .take(1)
                .map(|(id, p)| {
                    p.claimed = true;
                    json!({"requestID":id,"name":p.call.name,"arguments":p.call.arguments})
                })
                .collect();
            Ok(json!({"requests":requests}))
        }
        "respond" => {
            let request_id = args["requestID"].as_str().ok_or("Missing requestID")?;
            let delivered = pending
                .remove(request_id)
                .is_some_and(|p| p.reply.send(args["result"].clone()).is_ok());
            Ok(json!({"delivered":delivered}))
        }
        _ => Err("Unknown IDE host action".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct SessionFixture {
        root: PathBuf,
        id: String,
    }
    impl Drop for SessionFixture {
        fn drop(&mut self) {
            let _ = execute("close", json!({"hostID":self.id}));
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[tokio::test]
    async fn broker_routes_only_authorized_calls_and_closes_without_changing_packaged_inputs() {
        let root = std::env::temp_dir().join(format!("lithe-ide-host-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(root.join("installation/helpers")).unwrap();
        let helper = root.join("installation/helpers/lithe-mcp");
        std::fs::write(&helper, b"immutable packaged input").unwrap();
        let mut fixture = SessionFixture {
            root: root.clone(),
            id: String::new(),
        };
        let args = json!({"directory":root.join("app-data/mcp"),"workspaceKey":"fixture-project","helperPath":helper,"permissions":{"configure":false,"execute":false},"ownerId":format!("fixture-owner-{}", Uuid::new_v4())});
        let owner = args["ownerId"].clone();
        let opened = open(args.clone()).unwrap();
        fixture.id = opened["hostID"].as_str().unwrap().into();
        assert!(
            open(args).is_err(),
            "another window must not steal the project descriptor"
        );
        let (connection_path, broker) = {
            let h = hosts().lock().unwrap();
            let host = &h[&fixture.id];
            (host.connection.clone(), host.broker.clone())
        };
        let connection: Connection =
            serde_json::from_slice(&std::fs::read(&connection_path).unwrap()).unwrap();
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(3))
            .build()
            .unwrap();
        let denied: Value = client
            .post(&connection.endpoint)
            .bearer_auth(&connection.token)
            .json(&json!({"name":"lithe_maven_execute","arguments":{"goals":["verify"]}}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(denied["error"]["code"], "PERMISSION_DENIED");
        assert_eq!(
            execute("poll", json!({"hostID":fixture.id})).unwrap()["requests"],
            json!([])
        );
        // Drive the HTTP future and the application dispatcher together; the Notify
        // is the queue boundary, so neither task relies on scheduling sleeps.
        let response = client
            .post(&connection.endpoint)
            .bearer_auth(&connection.token)
            .json(&json!({"name":"lithe_project_inspect","arguments":{}}))
            .send();
        let application = async {
            tokio::time::timeout(Duration::from_secs(3), broker.queued.notified())
                .await
                .unwrap();
            let requests = execute("poll", json!({"hostID":fixture.id})).unwrap();
            let request = &requests["requests"][0];
            assert_eq!(request["name"], "lithe_project_inspect");
            execute("respond",json!({"hostID":fixture.id,"requestID":request["requestID"],"result":{"workspaceID":"fixture-project"}})).unwrap();
        };
        let (response, ()) = tokio::join!(response, application);
        assert_eq!(
            response.unwrap().json::<Value>().await.unwrap()["workspaceID"],
            "fixture-project"
        );
        execute("closeOwner", json!({"ownerID":"unrelated-window"})).unwrap();
        assert!(
            connection_path.exists(),
            "another window must not revoke this connection"
        );
        execute("closeOwner", json!({"ownerID":owner})).unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            format!("Bearer {}", connection.token).parse().unwrap(),
        );
        let (_, late) = call(
            State(broker),
            headers,
            Json(Call {
                name: "lithe_project_inspect".into(),
                arguments: json!({}),
            }),
        )
        .await;
        assert_eq!(late.0["error"]["code"], "DISCONNECTED");
        assert!(!connection_path.exists());
        assert_eq!(std::fs::read(&helper).unwrap(), b"immutable packaged input");
        assert_eq!(
            std::fs::read_dir(root.join("installation/helpers"))
                .unwrap()
                .count(),
            1
        );
    }
    fn push_fixture() -> (SessionFixture, Arc<Broker>, HeaderMap) {
        let root = std::env::temp_dir().join(format!("lithe-ide-push-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let helper = root.join("helper");
        std::fs::write(&helper, b"read-only").unwrap();
        let mut fixture = SessionFixture {
            root: root.clone(),
            id: String::new(),
        };
        let opened = open(
            json!({"directory":root.join("data"),"workspaceKey":"fixture", "helperPath":helper,
            "permissions":{"configure":true,"execute":true},"ownerId":"fixture-owner"}),
        )
        .unwrap();
        fixture.id = opened["hostID"].as_str().unwrap().into();
        let broker = hosts().lock().unwrap()[&fixture.id].broker.clone();
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            format!("Bearer {}", broker.token).parse().unwrap(),
        );
        (fixture, broker, headers)
    }

    async fn notification(rx: &mut tokio::sync::mpsc::UnboundedReceiver<String>) -> Option<String> {
        // test-stability: allow(rust-unbounded-receive) reason: Tokio's async receiver has no recv_timeout; the enclosing two-second timeout bounds this await without blocking the executor.
        tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .expect("native request notification deadline")
    }

    fn inspection() -> Json<Call> {
        Json(Call {
            name: "lithe_project_inspect".into(),
            arguments: json!({}),
        })
    }

    #[tokio::test]
    async fn push_dispatch_recovers_after_idle_without_heartbeat_and_claims_only_once() {
        let (fixture, broker, headers) = push_fixture();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let dispatcher: RequestDispatcher =
            Arc::new(move |id| tx.send(id).map_err(|e| e.to_string()));
        assert!(attach_dispatcher(&fixture.id, "other-owner", dispatcher.clone()).is_err());
        attach_dispatcher(&fixture.id, "fixture-owner", dispatcher.clone()).unwrap();
        assert!(attach_dispatcher(&fixture.id, "fixture-owner", dispatcher).is_err());
        *broker.last_poll.lock().unwrap() = Instant::now() - Duration::from_secs(3600);
        let application = async {
            let id = notification(&mut rx).await.unwrap();
            let args = json!({"hostID":fixture.id,"requestID":id});
            let claimed = execute("claim", args.clone()).unwrap();
            assert_eq!(claimed["request"]["name"], "lithe_project_inspect");
            assert!(execute("claim", args).unwrap()["request"].is_null());
            execute(
                "respond",
                json!({"hostID":fixture.id,"requestID":id,"result":{"ok":true}}),
            )
            .unwrap();
        };
        let (response, ()) = tokio::join!(call(State(broker), headers, inspection()), application);
        assert_eq!(response.1 .0["ok"], true);
    }

    #[tokio::test]
    async fn attaching_after_enqueue_delivers_the_existing_request_once() {
        let (fixture, broker, headers) = push_fixture();
        let application = async {
            tokio::time::timeout(Duration::from_secs(2), broker.queued.notified())
                .await
                .unwrap();
            let host = fixture.id.clone();
            attach_dispatcher(
                &fixture.id,
                "fixture-owner",
                Arc::new(move |id| {
                    assert!(
                        execute("claim", json!({"hostID":host,"requestID":id}))?["request"]
                            .is_object()
                    );
                    execute(
                        "respond",
                        json!({"hostID":host,"requestID":id,"result":{"ok":true}}),
                    )?;
                    Ok(())
                }),
            )
            .unwrap();
        };
        let (response, ()) = tokio::join!(
            call(State(broker.clone()), headers, inspection()),
            application
        );
        assert_eq!(response.1 .0["ok"], true);
        assert!(broker.pending.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn delayed_push_cannot_claim_expired_or_cancelled_work() {
        let (fixture, broker, headers) = push_fixture();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        attach_dispatcher(
            &fixture.id,
            "fixture-owner",
            Arc::new(move |id| tx.send(id).map_err(|e| e.to_string())),
        )
        .unwrap();
        let application = async {
            let id = notification(&mut rx).await.unwrap();
            // Simulate a suspended UI deterministically, without waiting for the deadline.
            broker.pending.lock().unwrap().get_mut(&id).unwrap().created =
                Instant::now() - REQUEST_TIMEOUT;
            assert!(
                execute("claim", json!({"hostID":fixture.id,"requestID":id})).unwrap()["request"]
                    .is_null()
            );
        };
        let (response, ()) = tokio::join!(
            call(State(broker.clone()), headers.clone(), inspection()),
            application
        );
        assert_eq!(response.1 .0["error"]["code"], "TIMEOUT");
        let id = {
            let call = call(State(broker.clone()), headers, inspection());
            tokio::pin!(call);
            tokio::select! {
                _ = &mut call => panic!("unanswered call completed"),
                id = notification(&mut rx) => id.unwrap(),
            }
            // Dropping the HTTP handler cancels ownership of the queued request.
        };
        assert!(
            execute("claim", json!({"hostID":fixture.id,"requestID":id})).unwrap()["request"]
                .is_null()
        );
        assert!(broker.pending.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn failed_push_does_not_revoke_authorization_or_replay_a_request() {
        let (fixture, broker, headers) = push_fixture();
        let failing = Arc::new(AtomicBool::new(true));
        let switch = failing.clone();
        let host = fixture.id.clone();
        attach_dispatcher(
            &fixture.id,
            "fixture-owner",
            Arc::new(move |id| {
                if switch.load(Ordering::Acquire) {
                    return Err("receiver unavailable".into());
                }
                // Inline delivery also proves no broker lock is held while calling the adapter.
                let request = execute("claim", json!({"hostID":host,"requestID":id}))?;
                assert!(request["request"].is_object());
                execute(
                    "respond",
                    json!({"hostID":host,"requestID":id,"result":{"ok":true}}),
                )?;
                Ok(())
            }),
        )
        .unwrap();
        let response = call(State(broker.clone()), headers.clone(), inspection()).await;
        assert_eq!(response.1 .0["error"]["code"], "DISPATCHER_UNAVAILABLE");
        assert!(broker.pending.lock().unwrap().is_empty());
        assert!(broker.enabled.load(Ordering::Acquire));
        failing.store(false, Ordering::Release);
        let response = call(State(broker), headers, inspection()).await;
        assert_eq!(response.1 .0["ok"], true);
    }

    #[tokio::test]
    async fn closing_owner_rejects_a_queued_push_and_releases_the_channel() {
        let (fixture, broker, headers) = push_fixture();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        attach_dispatcher(
            &fixture.id,
            "fixture-owner",
            Arc::new(move |id| tx.send(id).map_err(|e| e.to_string())),
        )
        .unwrap();
        let application = async {
            let id = notification(&mut rx).await.unwrap();
            execute("close", json!({"hostID":fixture.id})).unwrap();
            assert!(execute("claim", json!({"hostID":fixture.id,"requestID":id})).is_err());
        };
        let (response, ()) = tokio::join!(call(State(broker), headers, inspection()), application);
        assert_eq!(response.1 .0["error"]["code"], "DISCONNECTED");
        assert!(notification(&mut rx).await.is_none());
    }

    #[test]
    fn browser_origin_and_wrong_token_are_rejected() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Bearer secret".parse().unwrap());
        assert!(authorized(&h, "secret"));
        assert!(!authorized(&h, "secrex"));
        h.insert("origin", "http://localhost".parse().unwrap());
        assert!(!authorized(&h, "secret"));
    }
}
