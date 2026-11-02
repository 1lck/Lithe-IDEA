//! Explicit real-Core/Node integration; enabled by the native timing lane only.
use super::*;
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

const BACKEND: &str = r#"
const fs = require('node:fs');
const mode = process.argv[2], log = process.argv[3];
let input = Buffer.alloc(0);
function send(value) { const body = Buffer.from(JSON.stringify(value)); process.stdout.write('Content-Length: '+body.length+'\r\n\r\n'); process.stdout.write(body); }
process.stdin.on('data', chunk => {
 input = Buffer.concat([input,chunk]);
 while (true) {
  const end = input.indexOf('\r\n\r\n'); if (end < 0) return;
  const match = /Content-Length: (\d+)/i.exec(input.subarray(0,end).toString());
  if (!match) process.exit(2);
  const count = Number(match[1]); if (input.length < end+4+count) return;
  const message = JSON.parse(input.subarray(end+4,end+4+count)); input=input.subarray(end+4+count);
  fs.appendFileSync(log, message.method+'\n');
  if (message.method==='initialize' && mode!=='hang-initialize') send({jsonrpc:'2.0',id:message.id,result:{capabilities:{experimental:{litheToolchains:{version:mode==='refused'?2:1,providers:['fixture']}}}}});
  if (message.method==='toolchains/query' && mode==='exit-query') process.exit(0);
  if (message.method==='toolchains/query' && mode!=='hang') {
   if (mode==='error') send({jsonrpc:'2.0',id:message.id,error:{code:-32073,message:'fixture unavailable',data:{code:'plugin.toolchain.providerUnavailable'}}});
   else send({jsonrpc:'2.0',id:message.id,result:{...message.params,installations:[],statements:[],watch:[]}});
  }
  if (message.method==='shutdown') send({jsonrpc:'2.0',id:message.id,result:null});
  if (message.method==='exit') process.exit(0);
 }
});
process.stdin.on('end',()=>process.exit(0));
"#;

struct Fixture {
    root: PathBuf,
    launch: Value,
}
impl Fixture {
    fn new(mode: &str) -> Option<Self> {
        let Ok(node) = std::env::var("LITHE_TEST_NODE") else {
            eprintln!(
                "Real toolchain integration not enabled; set LITHE_TEST_NODE to an explicit Node executable"
            );
            return None;
        };
        assert!(PathBuf::from(&node).is_absolute());
        let root = std::env::temp_dir().join(format!(
            "lithe-toolchain-session-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let script = root.join("backend.cjs");
        fs::write(&script, BACKEND).unwrap();
        let launch = json!({"providerId":"toolchain-fixture","pluginId":"dev.example.query","toolchainProviders":["fixture"],
            "executablePath":node,"arguments":[script,mode,root.join("messages.log")],"environment":{},
            "rootUri":url::Url::from_directory_path(&root).unwrap().as_str(),"workingDirectory":root});
        Some(Self { root, launch })
    }
    fn messages(&self) -> String {
        fs::read_to_string(self.root.join("messages.log")).unwrap_or_default()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn start(fixture: &Fixture) -> BackendSession {
    let mut session =
        BackendSession::launch(fixture.launch.clone(), Duration::from_secs(5), || Ok(())).unwrap();
    session
        .initialize(Duration::from_secs(5), || Ok(()))
        .unwrap();
    session
}

#[test]
fn real_core_backend_retains_ownership_after_initialization_timeout() {
    let Some(fixture) = Fixture::new("hang-initialize") else {
        return;
    };
    let mut session =
        BackendSession::launch(fixture.launch.clone(), Duration::from_secs(5), || Ok(())).unwrap();
    assert!(
        session
            .initialize(Duration::from_millis(100), || Ok(()))
            .is_err()
    );
    session.close().unwrap();
    session.close().unwrap();
    assert!(!fixture.messages().contains("toolchains/query"));
}

fn params() -> Value {
    json!({"providerID":"fixture","operationID":"integration","generation":1})
}

#[test]
fn real_core_backend_negotiates_reuses_the_session_and_preserves_raw_errors() {
    for mode in ["ok", "error"] {
        let Some(fixture) = Fixture::new(mode) else {
            return;
        };
        let mut session = start(&fixture);
        for _ in 0..2 {
            let wire = session
                .query("fixture", &params(), Duration::from_secs(2), || Ok(()))
                .unwrap();
            assert!(wire["id"].is_number() || wire["id"].is_string(), "{wire}");
            assert_eq!(wire["response"]["id"], wire["id"]);
            if mode == "error" {
                assert_eq!(wire["response"]["error"]["code"], -32073);
            } else {
                assert_eq!(wire["response"]["result"]["operationID"], "integration");
            }
        }
        session.close().unwrap();
        session.close().unwrap();
        let messages = fixture.messages();
        assert_eq!(
            messages
                .lines()
                .filter(|line| *line == "initialize")
                .count(),
            1
        );
        assert_eq!(
            messages
                .lines()
                .filter(|line| *line == "toolchains/query")
                .count(),
            2
        );
        assert!(messages.lines().any(|line| line == "shutdown"));
    }
}

#[test]
fn real_core_backend_refuses_unnegotiated_providers_before_writing_a_query() {
    let Some(fixture) = Fixture::new("refused") else {
        return;
    };
    let mut session = start(&fixture);
    assert!(
        session
            .query("fixture", &params(), Duration::from_secs(1), || Ok(()))
            .is_err()
    );
    session.close().unwrap();
    assert!(!fixture.messages().contains("toolchains/query"));
}

#[test]
fn real_core_backend_bounds_a_silent_request_and_reaps_the_session() {
    for mode in ["hang", "exit-query"] {
        let Some(fixture) = Fixture::new(mode) else {
            return;
        };
        let mut session = start(&fixture);
        assert!(
            session
                .query("fixture", &params(), Duration::from_millis(100), || Ok(()))
                .is_err()
        );
        session.close().unwrap();
        if mode == "hang" {
            assert!(fixture.messages().contains("shutdown"));
        }
    }
}

#[test]
fn real_core_backend_revocation_prevents_new_requests_and_still_closes() {
    let Some(fixture) = Fixture::new("ok") else {
        return;
    };
    let mut session = start(&fixture);
    assert_eq!(
        session.query("fixture", &params(), Duration::from_secs(1), || Err(
            "revoked".into()
        )),
        Err("revoked".into())
    );
    session.close().unwrap();
    assert!(!fixture.messages().contains("toolchains/query"));
}
