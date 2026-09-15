//! Owned AskPass transport. Secrets travel only over a token-authenticated loopback socket.
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const MAX_FRAME: usize = 16 * 1024;
const PROMPT_TIMEOUT: Duration = Duration::from_secs(180);
type Answer = Option<String>;
static ANSWERS: OnceLock<Mutex<HashMap<String, mpsc::SyncSender<Answer>>>> = OnceLock::new();
fn answers() -> &'static Mutex<HashMap<String, mpsc::SyncSender<Answer>>> {
    ANSWERS.get_or_init(Mutex::default)
}
fn nonce() -> io::Result<String> {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(io::Error::other)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Challenge {
    pub request_id: String,
    pub prompt: String,
    pub secret: bool,
    pub attempt: usize,
}
#[derive(Deserialize, Serialize)]
struct WireRequest {
    token: String,
    prompt: String,
}

struct Pending {
    stream: TcpStream,
    input: Vec<u8>,
    request_id: Option<String>,
    response: Option<mpsc::Receiver<Answer>>,
    deadline: Instant,
}
impl Drop for Pending {
    fn drop(&mut self) {
        if let Some(id) = &self.request_id {
            if let Ok(mut map) = answers().lock() {
                map.remove(id);
            }
        }
        self.input.fill(0);
    }
}

/// One invocation owns its listener, outstanding prompts, and reply registrations.
pub struct Session {
    listener: TcpListener,
    token: String,
    pending: Vec<Pending>,
    attempts: HashMap<String, usize>,
    helper: std::path::PathBuf,
}
impl Session {
    pub fn new() -> io::Result<Self> {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let executable = std::env::current_exe()?;
        // AskPass is an executable path, including spaces. The child environment
        // selects the early helper mode without requiring shell interpretation.
        Ok(Self {
            listener,
            token: nonce()?,
            pending: Vec::new(),
            attempts: HashMap::new(),
            helper: executable,
        })
    }
    pub fn configure(&self, command: &mut Command) -> io::Result<()> {
        command
            .env("GIT_ASKPASS", &self.helper)
            .env("SSH_ASKPASS", &self.helper)
            .env("LITHE_GIT_ASKPASS_MODE", "1")
            .env("SSH_ASKPASS_REQUIRE", "force")
            .env("DISPLAY", "lithe-askpass")
            .env(
                "LITHE_GIT_ASKPASS_ADDRESS",
                self.listener.local_addr()?.to_string(),
            )
            .env("LITHE_GIT_ASKPASS_TOKEN", &self.token);
        Ok(())
    }
    /// Nonblocking polling shares the process cancellation loop; no detached worker survives it.
    pub fn poll(&mut self) -> io::Result<Vec<Challenge>> {
        while self.pending.len() < 4 {
            match self.listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(true)?;
                    self.pending.push(Pending {
                        stream,
                        input: Vec::new(),
                        request_id: None,
                        response: None,
                        deadline: Instant::now() + Duration::from_secs(10),
                    });
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }
        let mut prompts = Vec::new();
        let token = &self.token;
        let attempts = &mut self.attempts;
        self.pending.retain_mut(|pending| {
            if Instant::now() >= pending.deadline {
                return false;
            }
            if let Some(receiver) = &pending.response {
                match receiver.try_recv() {
                    Ok(answer) => {
                        // A bounded credential frame fits in a fresh loopback send buffer.
                        // Failure closes the connection; it never logs or retries the secret.
                        if let Some(answer) = answer {
                            let mut bytes = answer.into_bytes();
                            bytes.push(b'\n');
                            let result = pending.stream.write_all(&bytes);
                            bytes.fill(0);
                            if let Err(error) = result {
                                eprintln!("Git authentication response failed: {error}");
                            }
                        }
                        return false;
                    }
                    Err(mpsc::TryRecvError::Disconnected) => return false,
                    Err(mpsc::TryRecvError::Empty) => return true,
                }
            }
            let mut bytes = [0u8; 2048];
            match pending.stream.read(&mut bytes) {
                Ok(0) => return false,
                Ok(count) => pending.input.extend_from_slice(&bytes[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
                Err(_) => return false,
            }
            if pending.input.len() > MAX_FRAME {
                return false;
            }
            if !pending.input.ends_with(b"\n") {
                return true;
            }
            let Ok(request) = serde_json::from_slice::<WireRequest>(&pending.input) else {
                return false;
            };
            if request.token != *token || request.prompt.len() > 8192 {
                return false;
            }
            if attempts.len() >= 16 && !attempts.contains_key(&request.prompt) {
                return false;
            }
            let attempt = attempts.entry(request.prompt.clone()).or_default();
            *attempt += 1;
            if *attempt > 3 {
                return false;
            }
            let Ok(id) = nonce() else {
                return false;
            };
            let (sender, receiver) = mpsc::sync_channel(1);
            let Ok(mut registry) = answers().lock() else {
                return false;
            };
            registry.insert(id.clone(), sender);
            pending.request_id = Some(id.clone());
            pending.response = Some(receiver);
            pending.deadline = Instant::now() + PROMPT_TIMEOUT;
            let lower = request.prompt.to_ascii_lowercase();
            let secret = !lower.contains("username")
                && !lower.contains("yes/no")
                && !lower.contains("(yes/");
            prompts.push(Challenge {
                request_id: id,
                prompt: request.prompt,
                secret,
                attempt: *attempt,
            });
            true
        });
        Ok(prompts)
    }
}

/// Replies once to a currently owned prompt. Null means cancel; stale replies fail.
pub fn respond(request_id: &str, answer: Answer) -> bool {
    if answer
        .as_ref()
        .is_some_and(|value| value.len() > 8192 || value.contains(['\0', '\r', '\n']))
    {
        return false;
    }
    let sender = answers()
        .lock()
        .ok()
        .and_then(|mut map| map.remove(request_id));
    sender.is_some_and(|sender| sender.send(answer).is_ok())
}

/// Early application mode invoked by Git, before GUI/runtime initialization.
pub fn helper_main(prompt: &str) -> i32 {
    fn run(prompt: &str) -> io::Result<()> {
        let address = std::env::var("LITHE_GIT_ASKPASS_ADDRESS").map_err(io::Error::other)?;
        let address: std::net::SocketAddr = address.parse().map_err(io::Error::other)?;
        if !address.ip().is_loopback() {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let token = std::env::var("LITHE_GIT_ASKPASS_TOKEN").map_err(io::Error::other)?;
        let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(5))?;
        stream.set_read_timeout(Some(PROMPT_TIMEOUT))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let mut request = serde_json::to_vec(&WireRequest {
            token,
            prompt: prompt.to_string(),
        })?;
        if request.len() > MAX_FRAME {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        request.push(b'\n');
        stream.write_all(&request)?;
        let mut answer = Vec::new();
        stream.take(MAX_FRAME as u64).read_to_end(&mut answer)?;
        if !answer.ends_with(b"\n") {
            answer.fill(0);
            return Err(io::ErrorKind::Interrupted.into());
        }
        let result = io::stdout().write_all(&answer);
        answer.fill(0);
        result
    }
    if run(prompt).is_ok() {
        0
    } else {
        1
    }
}

/// Owns an explicit retry decision after a failed process has already been reaped.
pub struct Confirmation {
    pub request_id: String,
    receiver: mpsc::Receiver<Answer>,
}
impl Confirmation {
    pub fn new() -> io::Result<Self> {
        let request_id = nonce()?;
        let (sender, receiver) = mpsc::sync_channel(1);
        answers()
            .lock()
            .map_err(|_| io::Error::other("Authentication registry unavailable"))?
            .insert(request_id.clone(), sender);
        Ok(Self {
            request_id,
            receiver,
        })
    }
    /// A worker-thread wait observes both its own deadline and the owning request cancellation.
    pub fn wait(&self, mut cancelled: impl FnMut() -> bool) -> io::Result<bool> {
        let deadline = Instant::now() + PROMPT_TIMEOUT;
        while Instant::now() < deadline {
            if cancelled() {
                return Ok(false);
            }
            match self.receiver.try_recv() {
                Ok(value) => return Ok(value.as_deref() == Some("retry")),
                Err(mpsc::TryRecvError::Disconnected) => return Ok(false),
                Err(mpsc::TryRecvError::Empty) => std::thread::sleep(Duration::from_millis(10)),
            }
        }
        Err(io::ErrorKind::TimedOut.into())
    }
}
impl Drop for Confirmation {
    fn drop(&mut self) {
        if let Ok(mut map) = answers().lock() {
            map.remove(&self.request_id);
        }
    }
}
