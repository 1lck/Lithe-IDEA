//! Controlled downloads for declarative marketplace sources.
//!
//! The engine performs every HTTP round trip through an injected
//! [`HttpTransport`], so tests drive the real redirect, budget, deadline, and
//! cancellation logic against a local server while production keeps its
//! HTTPS-only policy. Redirects are resolved manually — a response never
//! silently drags the client to another origin, every hop is re-checked
//! against the fetch policy, and the hop count is bounded. A downloaded
//! artifact is written to a private `create_new` file under the caller's
//! runtime download root only after its SHA-256 matches the digest the
//! Core-validated index published: a completed download is a byte-exact
//! archive, never verified package content.

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::sync::Notify;

/// A cooperative cancellation handle shared with a download's owner. Once
/// cancelled, network waits wake immediately. Cancellation and final file/cache
/// publication share a lock: cancellation before that commit prevents publication;
/// once publication starts, its result belongs to the caller and is not revoked.
#[derive(Clone, Default)]
pub struct CancelToken(Arc<CancelState>);

#[derive(Default)]
struct CancelState {
    cancelled: AtomicBool,
    notify: Notify,
    publication: Mutex<()>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        let _publication = self
            .0
            .publication
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        self.0.cancelled.store(true, Ordering::SeqCst);
        self.0.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::SeqCst)
    }

    async fn cancelled(&self) {
        // Register before checking the flag, including when the future has not
        // yet been polled by select. No cancellation can fall between the two.
        let notified = self.0.notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if !self.is_cancelled() {
            notified.await;
        }
    }

    pub(super) fn check(&self, deadline: Instant) -> Result<(), FetchFailure> {
        if self.is_cancelled() {
            Err(FetchFailure::Cancelled)
        } else if Instant::now() >= deadline {
            Err(FetchFailure::DeadlineExceeded)
        } else {
            Ok(())
        }
    }

    pub(super) fn commit<T>(
        &self,
        deadline: Instant,
        publish: impl FnOnce() -> T,
    ) -> Result<T, FetchFailure> {
        let _publication = self
            .0
            .publication
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        self.check(deadline)?;
        Ok(publish())
    }
}

/// Competes every network wait with cancellation and the same absolute deadline.
async fn wait_for<T>(
    cancel: &CancelToken,
    deadline: Instant,
    operation: impl Future<Output = Result<T, FetchFailure>>,
) -> Result<T, FetchFailure> {
    cancel.check(deadline)?;
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(FetchFailure::Cancelled),
        _ = tokio::time::sleep_until(deadline.into()) => Err(FetchFailure::DeadlineExceeded),
        result = operation => {
            cancel.check(deadline)?;
            result
        }
    }
}

/// Owns a private runtime file until its atomic rename succeeds. Callers supply
/// only their writable state/download root; this never targets packaged resources.
/// The file handle closes before cleanup, including write/flush/rename failures.
pub(super) struct PendingFile {
    path: PathBuf,
    published: bool,
}

impl PendingFile {
    pub(super) fn write(path: PathBuf, bytes: &[u8]) -> std::io::Result<Self> {
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        let pending = Self {
            path,
            published: false,
        };
        let result = (move || {
            use std::io::Write;
            let mut file = file;
            file.write_all(bytes)?;
            file.flush()
        })();
        result?;
        Ok(pending)
    }

    pub(super) fn publish(self, target: &Path) -> std::io::Result<()> {
        self.publish_with(target, |source, target| std::fs::rename(source, target))
    }

    pub(super) fn publish_with(
        mut self,
        target: &Path,
        rename: impl FnOnce(&Path, &Path) -> std::io::Result<()>,
    ) -> std::io::Result<()> {
        rename(&self.path, target)?;
        self.published = true;
        Ok(())
    }
}

impl Drop for PendingFile {
    fn drop(&mut self) {
        if !self.published {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Upper bounds for one controlled fetch. Production call sites use
/// [`MAX_INDEX_JSON_BYTES`] for index documents and [`MAX_ARTIFACT_BYTES`]
/// for plugin archives; tests pass smaller budgets to exercise the boundary
/// without moving real payloads.
#[derive(Debug, Clone, Copy)]
pub struct FetchLimits {
    /// Maximum accepted response body across one target, redirects included.
    pub max_bytes: u64,
    /// Maximum number of redirects followed for one target.
    pub max_redirects: usize,
}

/// Index documents beyond this size are refused instead of parsed.
pub const MAX_INDEX_JSON_BYTES: u64 = 8 * 1024 * 1024;
/// Plugin archives beyond this size are refused; the same budget the disk
/// install path enforces on decompressed content.
pub const MAX_ARTIFACT_BYTES: u64 = 128 * 1024 * 1024;
/// Redirect hops beyond this count are refused.
pub const MAX_REDIRECT_HOPS: usize = 5;

/// Scheme policy for one fetch. Production fetches are HTTPS-only; the
/// loopback constructor is compiled for tests only so the real engine can be
/// exercised against a local HTTP server without ever weakening the shipped
/// policy.
#[derive(Debug, Clone, Copy)]
pub struct FetchPolicy {
    loopback_http_allowed: bool,
}

impl FetchPolicy {
    /// The production policy: every request target and redirect hop must be
    /// `https`.
    pub fn https_only() -> Self {
        Self {
            loopback_http_allowed: false,
        }
    }

    #[cfg(test)]
    pub fn loopback_http_for_tests() -> Self {
        Self {
            loopback_http_allowed: true,
        }
    }

    fn allows(&self, url: &url::Url) -> bool {
        match url.scheme() {
            "https" => true,
            "http" if self.loopback_http_allowed => matches!(
                url.host_str(),
                Some("127.0.0.1") | Some("::1") | Some("localhost")
            ),
            _ => false,
        }
    }
}

/// Every failure a controlled fetch can produce, with a stable kind the
/// marketplace surface can branch on without parsing messages.
#[derive(Debug, Clone, PartialEq)]
pub enum FetchFailure {
    Cancelled,
    DeadlineExceeded,
    /// A request or redirect target was refused by the fetch policy.
    DisallowedTarget {
        url: String,
    },
    /// A redirect response carried no usable `Location`.
    RedirectWithoutLocation {
        status: u16,
    },
    TooManyRedirects {
        hops: usize,
    },
    BudgetExceeded {
        limit: u64,
    },
    /// The final response was not a success status.
    HttpError {
        status: u16,
        url: String,
    },
    /// The transport failed (connection error, truncated body, ...).
    Transport(String),
    /// The downloaded bytes do not match the published digest.
    DigestMismatch {
        expected: String,
    },
}

impl FetchFailure {
    /// Stable failure kind for the marketplace surface.
    pub fn kind(&self) -> &'static str {
        match self {
            FetchFailure::Cancelled => "cancelled",
            FetchFailure::DeadlineExceeded => "deadline",
            FetchFailure::DisallowedTarget { .. } => "disallowedTarget",
            FetchFailure::RedirectWithoutLocation { .. } => "redirectWithoutLocation",
            FetchFailure::TooManyRedirects { .. } => "tooManyRedirects",
            FetchFailure::BudgetExceeded { .. } => "budgetExceeded",
            FetchFailure::HttpError { .. } => "httpError",
            FetchFailure::Transport(_) => "transport",
            FetchFailure::DigestMismatch { .. } => "digestMismatch",
        }
    }

    pub fn message(&self) -> String {
        match self {
            FetchFailure::Cancelled => "the fetch was cancelled".to_string(),
            FetchFailure::DeadlineExceeded => "the fetch exceeded its deadline".to_string(),
            FetchFailure::DisallowedTarget { url } => {
                format!("the fetch target {url} is not allowed by the source policy")
            }
            FetchFailure::RedirectWithoutLocation { status } => {
                format!("the redirect response {status} carries no Location header")
            }
            FetchFailure::TooManyRedirects { hops } => {
                format!("the fetch exceeded {hops} redirects")
            }
            FetchFailure::BudgetExceeded { limit } => {
                format!("the response exceeds the {limit} byte budget")
            }
            FetchFailure::HttpError { status, url } => {
                format!("the fetch of {url} returned HTTP {status}")
            }
            FetchFailure::Transport(error) => format!("the fetch failed: {error}"),
            FetchFailure::DigestMismatch { expected } => {
                format!("the downloaded archive does not match the published digest {expected}")
            }
        }
    }
}

/// One HTTP response as the engine sees it: status, lowercased headers, and
/// the body capped at the transport's budget.
#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

/// Performs one HTTP GET. Implementations enforce the body budget while the
/// response streams (a body that grows past `max_bytes` fails with
/// [`FetchFailure::BudgetExceeded`]) and respect the deadline and cancel
/// token during every network wait. Redirect handling stays with the engine, so a
/// 3xx response's body is buffered but ignored.
pub trait HttpTransport: Send + Sync {
    fn get<'a>(
        &'a self,
        url: &'a str,
        max_bytes: u64,
        deadline: Instant,
        cancel: &'a CancelToken,
    ) -> Pin<Box<dyn Future<Output = Result<HttpResponse, FetchFailure>> + Send + 'a>>;
}

/// The production transport: the shared `tauri_plugin_http` reqwest client
/// with redirects disabled (the engine resolves every hop itself), a per
/// request timeout bounded by the remaining deadline, and streaming chunk
/// reads that stop at the budget.
#[derive(Clone)]
pub struct ReqwestTransport {
    client: tauri_plugin_http::reqwest::Client,
    #[cfg(test)]
    on_chunk: Option<Arc<dyn Fn(usize) + Send + Sync>>,
}

impl ReqwestTransport {
    /// Builds the shared client. Redirects are never followed automatically:
    /// every hop must pass the fetch policy first.
    pub fn new() -> Result<Self, String> {
        let client = tauri_plugin_http::reqwest::Client::builder()
            .redirect(tauri_plugin_http::reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| format!("the marketplace HTTP client could not be built: {error}"))?;
        Ok(Self {
            client,
            #[cfg(test)]
            on_chunk: None,
        })
    }
}

impl Default for ReqwestTransport {
    fn default() -> Self {
        Self::new().expect("the marketplace HTTP client builds")
    }
}

impl HttpTransport for ReqwestTransport {
    fn get<'a>(
        &'a self,
        url: &'a str,
        max_bytes: u64,
        deadline: Instant,
        cancel: &'a CancelToken,
    ) -> Pin<Box<dyn Future<Output = Result<HttpResponse, FetchFailure>> + Send + 'a>> {
        Box::pin(async move {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(FetchFailure::DeadlineExceeded);
            }
            let response = wait_for(cancel, deadline, async {
                self.client
                    .get(url)
                    .timeout(remaining)
                    .send()
                    .await
                    .map_err(transport_error)
            })
            .await?;
            let status = response.status().as_u16();
            let headers = response
                .headers()
                .iter()
                .map(|(name, value)| {
                    (
                        name.as_str().to_ascii_lowercase(),
                        value.to_str().unwrap_or_default().to_string(),
                    )
                })
                .collect::<HashMap<_, _>>();
            let mut body = Vec::new();
            let mut response = response;
            while let Some(chunk) = wait_for(cancel, deadline, async {
                response.chunk().await.map_err(transport_error)
            })
            .await?
            {
                if body.len() as u64 + chunk.len() as u64 > max_bytes {
                    return Err(FetchFailure::BudgetExceeded { limit: max_bytes });
                }
                body.extend_from_slice(&chunk);
                #[cfg(test)]
                if let Some(on_chunk) = &self.on_chunk {
                    on_chunk(body.len());
                }
            }
            Ok(HttpResponse {
                status,
                headers,
                body,
            })
        })
    }
}

/// One completed controlled fetch: the body, the URL it was finally served
/// from, and how many redirect hops were followed.
#[derive(Debug, Clone)]
pub struct FetchOutcome {
    pub body: Vec<u8>,
    pub final_url: String,
    pub hops: usize,
}

/// Follows at most `limits.max_redirects` hops from `initial_url`, checking
/// every target (the initial URL included) against the fetch policy and the
/// embedded-credential rule, the deadline, and the cancel token. The body is
/// capped at `limits.max_bytes`.
pub async fn fetch_controlled(
    transport: &dyn HttpTransport,
    initial_url: &str,
    limits: FetchLimits,
    policy: FetchPolicy,
    cancel: &CancelToken,
    deadline: Instant,
) -> Result<FetchOutcome, FetchFailure> {
    let mut url = initial_url.to_string();
    let mut hops = 0usize;
    loop {
        cancel.check(deadline)?;
        check_target(&url, policy)?;
        let response = wait_for(
            cancel,
            deadline,
            transport.get(&url, limits.max_bytes, deadline, cancel),
        )
        .await?;
        if (300..400).contains(&response.status) {
            if hops >= limits.max_redirects {
                return Err(FetchFailure::TooManyRedirects { hops });
            }
            let location =
                response
                    .header("location")
                    .ok_or(FetchFailure::RedirectWithoutLocation {
                        status: response.status,
                    })?;
            let target = resolved_target(&url, location)?;
            check_target(&target, policy)?;
            url = target;
            hops += 1;
            continue;
        }
        if !(200..300).contains(&response.status) {
            return Err(FetchFailure::HttpError {
                status: response.status,
                url,
            });
        }
        return Ok(FetchOutcome {
            body: response.body,
            final_url: url,
            hops,
        });
    }
}

/// A downloaded, digest-bound artifact waiting for the install flow.
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadedArtifact {
    /// Private file under the download root; consumed by the install
    /// transaction or removed with it.
    pub path: PathBuf,
    /// Lowercase hex SHA-256 of the file bytes.
    pub sha256: String,
    pub final_url: String,
    pub bytes: u64,
}

/// Downloads one artifact and binds it to `expected_sha256`
/// (case-insensitive hex) before writing it to a private `create_new` file
/// under `download_root`. A digest mismatch, any failure, or cancellation
/// leaves no file behind; the returned archive is byte-exact published
/// content, not verified package content.
pub async fn download_artifact(
    download_root: &Path,
    transport: &dyn HttpTransport,
    url: &str,
    expected_sha256: &str,
    limits: FetchLimits,
    policy: FetchPolicy,
    cancel: &CancelToken,
    deadline: Instant,
) -> Result<DownloadedArtifact, FetchFailure> {
    let outcome = fetch_controlled(transport, url, limits, policy, cancel, deadline).await?;
    cancel.check(deadline)?;
    let digest = format!("{:x}", Sha256::digest(&outcome.body));
    cancel.check(deadline)?;
    if !digest.eq_ignore_ascii_case(expected_sha256) {
        return Err(FetchFailure::DigestMismatch {
            expected: expected_sha256.to_string(),
        });
    }
    std::fs::create_dir_all(download_root).map_err(|error| {
        FetchFailure::Transport(format!("the download root is unusable: {error}"))
    })?;
    let path = download_root.join(format!(
        "marketplace-download-{}-{}.zip",
        std::process::id(),
        unique_suffix()
    ));
    let pending = PendingFile::write(path.with_extension("zip.tmp"), &outcome.body)
        .map_err(|error| FetchFailure::Transport(format!("the download file failed: {error}")))?;
    // The token's commit lock is held only for publication, never for hashing,
    // writing or flushing. A losing cancellation drops the pending-file owner.
    cancel
        .commit(deadline, || pending.publish(&path))?
        .map_err(|error| {
            FetchFailure::Transport(format!("the download publish failed: {error}"))
        })?;
    Ok(DownloadedArtifact {
        path,
        sha256: digest,
        final_url: outcome.final_url,
        bytes: outcome.body.len() as u64,
    })
}

/// Checks one request target against the fetch policy and the
/// embedded-credential rule, mirroring the rule the AI commit client applies
/// to redirect targets.
fn check_target(url: &str, policy: FetchPolicy) -> Result<(), FetchFailure> {
    let target = url::Url::parse(url).map_err(|error| FetchFailure::DisallowedTarget {
        url: format!("{url} ({error})"),
    })?;
    if !policy.allows(&target) || !target.username().is_empty() || target.password().is_some() {
        return Err(FetchFailure::DisallowedTarget {
            url: target.to_string(),
        });
    }
    Ok(())
}

/// Resolves a `Location` header against the current target.
fn resolved_target(current: &str, location: &str) -> Result<String, FetchFailure> {
    let base = url::Url::parse(current).map_err(|error| FetchFailure::DisallowedTarget {
        url: format!("{current} ({error})"),
    })?;
    let target = base
        .join(location)
        .map_err(|error| FetchFailure::DisallowedTarget {
            url: format!("{location} ({error})"),
        })?;
    Ok(target.to_string())
}

/// Flattens a reqwest error with its whole source chain: the top message
/// alone ("error sending request") hides whether the connection was refused,
/// reset, or proxied away.
fn transport_error(error: tauri_plugin_http::reqwest::Error) -> FetchFailure {
    if error.is_timeout() {
        return FetchFailure::DeadlineExceeded;
    }
    let mut message = error.to_string();
    let mut cause = std::error::Error::source(&error);
    while let Some(error) = cause {
        message.push_str(&format!(": {error}"));
        cause = error.source();
    }
    FetchFailure::Transport(message)
}

/// Time- and process-derived uniqueness for private file names.
fn unique_suffix() -> String {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    format!(
        "{}-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        SEQUENCE.fetch_add(1, Ordering::SeqCst)
    )
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::time::Duration;

    /// One scripted response of the local test server. `content_length`
    /// overrides the advertised Content-Length and `body_prefix` limits how
    /// many bytes are actually written, which is how the tests model a
    /// truncated download.
    #[derive(Clone)]
    pub(crate) struct TestResponse {
        pub status: u16,
        pub headers: Vec<(String, String)>,
        pub body: Vec<u8>,
        pub content_length: Option<usize>,
        pub body_prefix: Option<usize>,
        pub pause: Option<(Arc<TestGate>, PauseAt)>,
    }

    impl TestResponse {
        pub fn ok(body: Vec<u8>) -> Self {
            Self {
                status: 200,
                headers: Vec::new(),
                body,
                content_length: None,
                body_prefix: None,
                pause: None,
            }
        }

        pub fn redirect(location: &str) -> Self {
            Self {
                status: 302,
                headers: vec![("Location".to_string(), location.to_string())],
                body: Vec::new(),
                content_length: None,
                body_prefix: None,
                pause: None,
            }
        }

        pub fn paused(body: Vec<u8>, phase: PauseAt) -> (Self, Arc<TestGate>) {
            let gate = TestGate::new();
            let mut response = Self::ok(body);
            response.pause = Some((gate.clone(), phase));
            (response, gate)
        }

        pub fn with_status(status: u16) -> Self {
            Self {
                status,
                ..Self::ok(Vec::new())
            }
        }
    }

    /// A gated response can stop before headers or after its final body bytes.
    /// The server owner releases every gate during teardown, including panic paths.
    #[derive(Clone, Copy)]
    pub(crate) enum PauseAt {
        Headers,
        Eof,
    }

    pub(crate) struct TestGate {
        entered: Notify,
        released: Mutex<bool>,
        wake: std::sync::Condvar,
    }

    impl TestGate {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                entered: Notify::new(),
                released: Mutex::new(false),
                wake: std::sync::Condvar::new(),
            })
        }

        pub async fn entered(&self) {
            tokio::time::timeout(Duration::from_secs(2), self.entered.notified())
                .await
                .expect("server reaches the controlled boundary");
        }

        fn wait(&self, deadline: Instant) {
            self.entered.notify_one();
            let released = self
                .released
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            let _ = self
                .wake
                .wait_timeout_while(
                    released,
                    deadline.saturating_duration_since(Instant::now()),
                    |released| !*released,
                )
                .expect("gate wait");
        }

        pub fn release(&self) {
            *self
                .released
                .lock()
                .unwrap_or_else(|error| error.into_inner()) = true;
            self.wake.notify_all();
        }
    }

    /// One blocking owner serves connections serially; there are no detached
    /// connection threads or global locks. Drop releases gates, shuts down the
    /// active socket and wakes accept, then joins only after a bounded done signal.
    pub(crate) struct TestHttpServer {
        pub base_url: String,
        address: std::net::SocketAddr,
        shutdown: Arc<AtomicBool>,
        active: Arc<Mutex<Option<std::net::TcpStream>>>,
        accepted: Arc<Notify>,
        gates: Vec<Arc<TestGate>>,
        done: std::sync::mpsc::Receiver<()>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl TestHttpServer {
        pub fn start(routes: Vec<(&'static str, Vec<TestResponse>)>) -> Self {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("test listener binds");
            let address = listener.local_addr().expect("addr");
            let base_url = format!("http://{address}");
            let shutdown = Arc::new(AtomicBool::new(false));
            let active = Arc::new(Mutex::new(None));
            let accepted = Arc::new(Notify::new());
            let thread_accepted = accepted.clone();
            let gates = routes
                .iter()
                .flat_map(|(_, responses)| responses.iter())
                .filter_map(|response| response.pause.as_ref().map(|(gate, _)| gate.clone()))
                .collect();
            let thread_shutdown = shutdown.clone();
            let thread_active = active.clone();
            let (done_tx, done) = std::sync::mpsc::channel();
            let thread = std::thread::spawn(move || {
                // Signal even if serving panics, so the owner can join the failure.
                struct Done(std::sync::mpsc::Sender<()>);
                impl Drop for Done {
                    fn drop(&mut self) {
                        let _ = self.0.send(());
                    }
                }
                let _done = Done(done_tx);
                let mut routes = routes;
                while !thread_shutdown.load(Ordering::SeqCst) {
                    let Ok((stream, _)) = listener.accept() else {
                        break;
                    };
                    *thread_active.lock().expect("active socket") =
                        Some(stream.try_clone().expect("socket clone"));
                    thread_accepted.notify_one();
                    if !thread_shutdown.load(Ordering::SeqCst) {
                        serve_connection(stream, &mut routes, &thread_shutdown);
                    }
                    thread_active.lock().expect("active socket").take();
                }
            });
            Self {
                base_url,
                address,
                shutdown,
                active,
                accepted,
                gates,
                done,
                thread: Some(thread),
            }
        }
    }

    impl Drop for TestHttpServer {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::SeqCst);
            for gate in &self.gates {
                gate.release();
            }
            if let Some(stream) = self
                .active
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .take()
            {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            let _ = std::net::TcpStream::connect_timeout(&self.address, Duration::from_millis(200));
            if self.done.recv_timeout(Duration::from_secs(2)).is_err() {
                // A native thread cannot be killed safely. The timing harness owns
                // this test process: fail it instead of hanging or detaching work.
                eprintln!("marketplace test server failed to stop within its cleanup deadline");
                std::process::abort();
            }
            if let Some(thread) = self.thread.take() {
                let result = thread.join();
                if !std::thread::panicking() {
                    result.expect("server thread joins");
                }
            }
        }
    }

    fn write_bounded(
        stream: &mut std::net::TcpStream,
        mut bytes: &[u8],
        stop: &AtomicBool,
        deadline: Instant,
    ) -> std::io::Result<()> {
        while !bytes.is_empty() {
            if stop.load(Ordering::SeqCst) || Instant::now() >= deadline {
                return Err(std::io::ErrorKind::TimedOut.into());
            }
            stream.set_write_timeout(Some(io_wait_bound(deadline)))?;
            let written = match stream.write(bytes) {
                Ok(written) => written,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue
                }
                Err(error) => return Err(error),
            };
            if written == 0 {
                return Err(std::io::ErrorKind::WriteZero.into());
            }
            bytes = &bytes[written..];
        }
        Ok(())
    }

    fn io_wait_bound(deadline: Instant) -> Duration {
        // Windows may leave a synchronous read pending after another socket
        // handle calls shutdown. Bound that OS wait too, so the owner stop flag
        // is observed without relying on interrupting the pending syscall.
        deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(100))
    }

    fn serve_connection(
        mut stream: std::net::TcpStream,
        routes: &mut [(&'static str, Vec<TestResponse>)],
        stop: &AtomicBool,
    ) {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 1024];
        while !stop.load(Ordering::SeqCst) && Instant::now() < deadline {
            if stream
                .set_read_timeout(Some(io_wait_bound(deadline)))
                .is_err()
            {
                return;
            }
            match stream.read(&mut chunk) {
                Ok(0) => return,
                Ok(read) => {
                    buffer.extend_from_slice(&chunk[..read]);
                    if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                    if buffer.len() > 16 * 1024 {
                        return;
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue
                }
                Err(_) => return,
            }
        }
        let request = String::from_utf8_lossy(&buffer);
        let path = request.split_whitespace().nth(1).unwrap_or_default();
        let response = routes
            .iter_mut()
            .find(|(route, _)| path == *route || path.starts_with(&format!("{route}?")))
            .map(|(_, responses)| {
                if responses.len() > 1 {
                    responses.remove(0)
                } else {
                    responses[0].clone()
                }
            })
            .unwrap_or_else(|| TestResponse::with_status(404));
        if let Some((gate, PauseAt::Headers)) = &response.pause {
            gate.wait(deadline);
        }
        // A close-delimited body lets tests park after the final chunk but before
        // EOF, without lying about Content-Length or relying on socket timing.
        let length = if matches!(&response.pause, Some((_, PauseAt::Eof))) {
            String::new()
        } else {
            format!(
                "Content-Length: {}\r\n",
                response.content_length.unwrap_or(response.body.len())
            )
        };
        let mut head = format!(
            "HTTP/1.1 {} OK\r\n{length}Connection: close\r\n",
            response.status
        );
        for (name, value) in &response.headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str("\r\n");
        let written = response
            .body_prefix
            .unwrap_or(response.body.len())
            .min(response.body.len());
        if write_bounded(&mut stream, head.as_bytes(), stop, deadline).is_err() {
            return;
        }
        if write_bounded(&mut stream, &response.body[..written], stop, deadline).is_err() {
            return;
        }
        if let Some((gate, PauseAt::Eof)) = &response.pause {
            gate.wait(deadline);
        }
    }

    /// Every test owns its private directory even when an assertion unwinds.
    pub(crate) struct TestRoot(pub PathBuf);

    impl TestRoot {
        pub fn new(label: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "lithe-marketplace-{label}-{}-{}",
                std::process::id(),
                unique_suffix()
            ));
            std::fs::create_dir_all(&root).expect("test runtime root");
            Self(root)
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let result = std::fs::remove_dir_all(&self.0);
            if !std::thread::panicking() {
                result.expect("test runtime root is removed");
            }
        }
    }

    #[tokio::test]
    async fn cancellation_wakes_registered_waiters_and_remains_sticky() {
        let cancel = CancelToken::new();
        let first = cancel.cancelled();
        let second = cancel.cancelled();
        tokio::pin!(first, second);
        tokio::select! {
            biased;
            _ = &mut first => panic!("not cancelled yet"),
            _ = &mut second => panic!("not cancelled yet"),
            _ = std::future::ready(()) => {}
        }
        cancel.cancel();
        tokio::time::timeout(Duration::from_secs(2), async {
            tokio::join!(&mut first, &mut second);
            cancel.cancelled().await;
        })
        .await
        .expect("all waiters wake, including a later registration");
    }

    #[tokio::test]
    async fn cancellation_interrupts_an_in_flight_request_before_headers() {
        let (response, gate) = TestResponse::paused(b"archive".to_vec(), PauseAt::Headers);
        let server = TestHttpServer::start(vec![("/pending", vec![response])]);
        let transport = ReqwestTransport::new().expect("transport");
        let cancel = CancelToken::new();
        let url = format!("{}/pending", server.base_url);
        let fetch = fetch_controlled(
            &transport,
            &url,
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &cancel,
            test_deadline(),
        );
        tokio::pin!(fetch);
        tokio::select! {
            result = &mut fetch => panic!("request must still be waiting: {result:?}"),
            _ = gate.entered() => {}
        }
        cancel.cancel();
        let result = tokio::time::timeout(Duration::from_secs(1), &mut fetch)
            .await
            .expect("cancel wakes send before the network deadline");
        assert_eq!(
            result.expect_err("request cancelled"),
            FetchFailure::Cancelled
        );
        // The gate remains closed until the owner's Drop. Cancellation must not
        // require the server to send headers or the request deadline to expire.
    }

    #[tokio::test]
    async fn cancelling_after_the_final_chunk_before_eof_never_publishes_an_artifact() {
        let root = TestRoot::new("cancel-eof");
        let (response, _gate) = TestResponse::paused(b"archive".to_vec(), PauseAt::Eof);
        let server = TestHttpServer::start(vec![("/pending", vec![response])]);
        let consumed = Arc::new(Notify::new());
        let mut transport = ReqwestTransport::new().expect("transport");
        let notify = consumed.clone();
        transport.on_chunk = Some(Arc::new(move |bytes| {
            if bytes == b"archive".len() {
                notify.notify_one();
            }
        }));
        let cancel = CancelToken::new();
        let url = format!("{}/pending", server.base_url);
        let digest = format!("{:x}", Sha256::digest(b"archive"));
        let download = download_artifact(
            &root.0,
            &transport,
            &url,
            &digest,
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &cancel,
            test_deadline(),
        );
        tokio::pin!(download);
        tokio::select! {
            result = &mut download => panic!("EOF is still gated: {result:?}"),
            result = tokio::time::timeout(Duration::from_secs(1), consumed.notified()) => {
                result.expect("the real client consumes the last body chunk");
            }
        }
        // This signal is emitted by the real client after appending the last
        // body chunk, so the next network wait is specifically for EOF.
        cancel.cancel();
        let result = tokio::time::timeout(Duration::from_secs(1), &mut download)
            .await
            .expect("cancel wakes the EOF wait");
        assert_eq!(
            result.expect_err("download cancelled"),
            FetchFailure::Cancelled
        );
        assert_eq!(std::fs::read_dir(&root.0).expect("root").count(), 0);
    }

    #[test]
    fn cancellation_before_publication_removes_a_fully_written_private_file() {
        let root = TestRoot::new("cancel-publication");
        let target = root.0.join("artifact.zip");
        let pending =
            PendingFile::write(root.0.join("artifact.tmp"), b"flushed bytes").expect("stage");
        let cancel = CancelToken::new();
        cancel.cancel();
        let result = cancel.commit(test_deadline(), || pending.publish(&target));
        assert_eq!(
            result.expect_err("cancel wins commit"),
            FetchFailure::Cancelled
        );
        assert_eq!(std::fs::read_dir(&root.0).expect("root").count(), 0);
    }

    #[tokio::test]
    async fn server_owner_interrupts_a_connection_still_reading_request_headers() {
        let server = TestHttpServer::start(vec![]);
        let mut connection = std::net::TcpStream::connect(server.address).expect("connect");
        tokio::time::timeout(Duration::from_secs(1), server.accepted.notified())
            .await
            .expect("connection is owned before shutdown");
        drop(server);
        assert_connection_closed(&mut connection);
    }

    #[tokio::test]
    async fn unwinding_releases_response_gates_threads_and_private_roots() {
        let root = TestRoot::new("unwind");
        let path = root.0.clone();
        let (response, gate) = TestResponse::paused(b"archive".to_vec(), PauseAt::Headers);
        let server = TestHttpServer::start(vec![("/", vec![response])]);
        let mut connection = std::net::TcpStream::connect(server.address).expect("connect");
        connection
            .set_write_timeout(Some(Duration::from_secs(1)))
            .expect("bounded write");
        connection
            .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .expect("request");
        gate.entered().await;
        let unwind = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            let _root = root;
            let _server = server;
            panic!("simulated assertion failure");
        }));
        assert!(unwind.is_err());
        assert!(
            !path.exists(),
            "RAII removes the root even during an assertion unwind"
        );
        assert_connection_closed(&mut connection);
    }

    fn assert_connection_closed(connection: &mut std::net::TcpStream) {
        use std::io::ErrorKind;
        connection
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("bounded read");
        match connection.read(&mut [0]) {
            Ok(0) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::ConnectionReset
                        | ErrorKind::ConnectionAborted
                        | ErrorKind::NotConnected
                        | ErrorKind::BrokenPipe
                        | ErrorKind::UnexpectedEof
                ) => {}
            result => panic!("owner must close the socket, not merely time out: {result:?}"),
        }
    }

    fn test_limits(max_bytes: u64) -> FetchLimits {
        FetchLimits {
            max_bytes,
            max_redirects: MAX_REDIRECT_HOPS,
        }
    }

    fn test_deadline() -> Instant {
        Instant::now() + Duration::from_secs(10)
    }

    #[tokio::test]
    async fn fetch_serves_the_body_and_reports_the_final_url() {
        let server = TestHttpServer::start(vec![(
            "/index.json",
            vec![TestResponse::ok(br#"{"ok": true}"#.to_vec())],
        )]);
        let transport = ReqwestTransport::new().expect("transport");
        let outcome = fetch_controlled(
            &transport,
            &format!("{}/index.json", server.base_url),
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect("the fetch succeeds");
        assert_eq!(outcome.body, br#"{"ok": true}"#.to_vec());
        assert_eq!(outcome.hops, 0);
        assert_eq!(outcome.final_url, format!("{}/index.json", server.base_url));
    }

    #[tokio::test]
    async fn redirects_are_followed_within_the_policy_and_reported() {
        let server = TestHttpServer::start(vec![
            ("/start", vec![TestResponse::redirect("/final")]),
            ("/final", vec![TestResponse::ok(b"final body".to_vec())]),
        ]);
        let transport = ReqwestTransport::new().expect("transport");
        let outcome = fetch_controlled(
            &transport,
            &format!("{}/start", server.base_url),
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect("the redirect chain succeeds");
        assert_eq!(outcome.body, b"final body".to_vec());
        assert_eq!(outcome.hops, 1);
        assert_eq!(outcome.final_url, format!("{}/final", server.base_url));
    }

    #[tokio::test]
    async fn insecure_and_credential_targets_are_refused() {
        // The production policy refuses every non-HTTPS target outright.
        let error = fetch_controlled(
            &ReqwestTransport::new().expect("transport"),
            "http://127.0.0.1:9/none",
            test_limits(1024),
            FetchPolicy::https_only(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect_err("plain http is refused in production");
        assert_eq!(error.kind(), "disallowedTarget");

        let server = TestHttpServer::start(vec![
            (
                "/to-insecure",
                vec![TestResponse::redirect("http://evil.example.com/x")],
            ),
            (
                "/to-credentials",
                vec![TestResponse::redirect("https://user:pass@example.com/x")],
            ),
        ]);
        let transport = ReqwestTransport::new().expect("transport");
        for path in ["/to-insecure", "/to-credentials"] {
            let error = fetch_controlled(
                &transport,
                &format!("{}{path}", server.base_url),
                test_limits(1024),
                FetchPolicy::loopback_http_for_tests(),
                &CancelToken::new(),
                test_deadline(),
            )
            .await
            .expect_err("the disallowed redirect target must be refused");
            assert_eq!(error.kind(), "disallowedTarget", "{error:?}");
        }
    }

    #[tokio::test]
    async fn too_many_redirects_is_bounded() {
        let server = TestHttpServer::start(vec![("/loop", vec![TestResponse::redirect("/loop")])]);
        let transport = ReqwestTransport::new().expect("transport");
        let error = fetch_controlled(
            &transport,
            &format!("{}/loop", server.base_url),
            FetchLimits {
                max_bytes: 1024,
                max_redirects: 3,
            },
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect_err("the redirect loop must be bounded");
        assert_eq!(error, FetchFailure::TooManyRedirects { hops: 3 });
    }

    #[tokio::test]
    async fn budget_exceeded_aborts_mid_body() {
        let server =
            TestHttpServer::start(vec![("/big", vec![TestResponse::ok(vec![b'x'; 10_000])])]);
        let transport = ReqwestTransport::new().expect("transport");
        let error = fetch_controlled(
            &transport,
            &format!("{}/big", server.base_url),
            test_limits(100),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect_err("the oversized body must abort");
        assert_eq!(error, FetchFailure::BudgetExceeded { limit: 100 });
    }

    #[tokio::test]
    async fn truncated_body_is_a_transport_error() {
        let server = TestHttpServer::start(vec![(
            "/truncated",
            vec![TestResponse {
                status: 200,
                headers: Vec::new(),
                body: vec![b'y'; 1_000],
                content_length: Some(1_000),
                body_prefix: Some(100),
                pause: None,
            }],
        )]);
        let transport = ReqwestTransport::new().expect("transport");
        let error = fetch_controlled(
            &transport,
            &format!("{}/truncated", server.base_url),
            test_limits(10_000),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect_err("the truncated body must be a transport error");
        assert_eq!(error.kind(), "transport", "{error:?}");
    }

    #[tokio::test]
    async fn deadline_and_cancel_are_honored_before_any_request() {
        let transport = ReqwestTransport::new().expect("transport");
        let error = fetch_controlled(
            &transport,
            "https://example.com/index.json",
            test_limits(1024),
            FetchPolicy::https_only(),
            &CancelToken::new(),
            Instant::now() - Duration::from_secs(1),
        )
        .await
        .expect_err("an expired deadline must fail immediately");
        assert_eq!(error, FetchFailure::DeadlineExceeded);

        let cancel = CancelToken::new();
        cancel.cancel();
        let error = fetch_controlled(
            &transport,
            "https://example.com/index.json",
            test_limits(1024),
            FetchPolicy::https_only(),
            &cancel,
            test_deadline(),
        )
        .await
        .expect_err("a cancelled fetch must fail immediately");
        assert_eq!(error, FetchFailure::Cancelled);
    }

    #[tokio::test]
    async fn http_error_status_is_reported() {
        let server =
            TestHttpServer::start(vec![("/missing", vec![TestResponse::with_status(404)])]);
        let transport = ReqwestTransport::new().expect("transport");
        let error = fetch_controlled(
            &transport,
            &format!("{}/missing", server.base_url),
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect_err("a 404 must be reported");
        assert_eq!(
            error,
            FetchFailure::HttpError {
                status: 404,
                url: format!("{}/missing", server.base_url),
            }
        );
    }

    #[tokio::test]
    async fn download_artifact_binds_the_digest_and_cleans_up_on_mismatch() {
        let server = TestHttpServer::start(vec![(
            "/plugin.zip",
            vec![TestResponse::ok(b"archive bytes".to_vec())],
        )]);
        let transport = ReqwestTransport::new().expect("transport");
        let root = TestRoot::new("download-ok");
        let download_root = &root.0;
        let digest = format!("{:x}", Sha256::digest(b"archive bytes"));
        let artifact = download_artifact(
            &download_root,
            &transport,
            &format!("{}/plugin.zip", server.base_url),
            &digest,
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect("the digest-matched download succeeds");
        assert_eq!(
            std::fs::read(&artifact.path).expect("artifact bytes"),
            b"archive bytes".to_vec()
        );
        assert_eq!(artifact.sha256, digest);
        assert_eq!(artifact.bytes, 13);
        assert!(artifact.path.starts_with(&download_root));

        // A digest mismatch leaves the private root with only the matched
        // download.
        let error = download_artifact(
            &download_root,
            &transport,
            &format!("{}/plugin.zip", server.base_url),
            &"0".repeat(64),
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect_err("the digest mismatch must be refused");
        assert_eq!(
            error,
            FetchFailure::DigestMismatch {
                expected: "0".repeat(64),
            }
        );
        let leftovers: Vec<_> = std::fs::read_dir(&download_root)
            .expect("root readable")
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(
            leftovers.len(),
            1,
            "only the matched download remains: {leftovers:?}"
        );

        // A second successful download never reuses a file name.
        let second = download_artifact(
            &download_root,
            &transport,
            &format!("{}/plugin.zip", server.base_url),
            &digest,
            test_limits(1024),
            FetchPolicy::loopback_http_for_tests(),
            &CancelToken::new(),
            test_deadline(),
        )
        .await
        .expect("the second download succeeds");
        assert_ne!(second.path, artifact.path);
    }
}
