//! Opt-in native integration: real Core stdio transport and typed VCS requests.
//! The unified Windows lane supplies an absolute LITHE_VCS_TEST_NODE executable.
use super::*;
use crate::plugin_host::lifecycle::LifecycleState;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;

static NEXT: AtomicU64 = AtomicU64::new(1);
struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove native VCS fixture after Core disposal");
    }
}

#[tokio::test]
#[ignore = "native integration; unified Windows lane supplies LITHE_VCS_TEST_NODE"]
async fn real_core_stdio_resolve_and_cleanup_use_only_the_frozen_typed_arguments() {
    let node =
        PathBuf::from(std::env::var_os("LITHE_VCS_TEST_NODE").expect("explicit integration Node"));
    assert!(node.is_absolute() && node.is_file());
    for operation in [
        super::super::actions::WriteOperation::Resolve {
            paths: vec!["conflict.txt".into()],
        },
        super::super::actions::WriteOperation::Cleanup {},
    ] {
        let fixture = Fixture(std::env::temp_dir().join(format!(
            "lithe-vcs-core-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )));
        std::fs::create_dir_all(&fixture.0).unwrap();
        let script = fixture.0.join("provider.mjs");
        let receipt = fixture.0.join("writes.jsonl");
        std::fs::write(&script, include_str!("vcs_session_fixture.mjs")).unwrap();
        std::fs::write(fixture.0.join("conflict.txt"), "resolved contents").unwrap();
        let root = fixture
            .0
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let context = Context {
            host: "native-vcs-integration".into(),
            scope: Scope {
                workspace_id: "fixture".into(),
                workspace_root: root.clone(),
                incarnation: "one".into(),
            },
            generation: 1,
            registration: 1,
            request_id: format!("request-{}", operation.name()),
            root: Root {
                id: String::new(),
                vcs: "fixture".into(),
                path: root.clone(),
                mapped: false,
            },
            root_identity: "fixture-directory".into(),
            plugin_id: "fixture.vcs".into(),
            package_identity: "controlled-test-bytes".into(),
            settings_revision: 0,
        };
        let lifecycle = LifecycleState::default();
        let owner = Owner::new(context, lifecycle.acquire("fixture.vcs").unwrap());
        owner.mark_mutation();
        let sessions = Sessions::default();
        sessions.insert(owner.clone(), || true).unwrap();
        let payload = json!({"providerId":format!("vcsProvider:fixture:{}", operation.name()),
            "pluginId":"fixture.vcs", "executablePath":node,
            "arguments":[script,receipt,root], "environment":{},
            "rootUri":url::Url::from_directory_path(&fixture.0).unwrap().as_str(),
            "workingDirectory":root, "initializeTimeoutMilliseconds":2000, "requestTimeoutMilliseconds":2000});
        // No assertion can bypass native cleanup. Deadline cancellation leaves
        // the original owner registered, including a late-starting process.
        let result = tokio::time::timeout(Duration::from_secs(5), async {
            owner.start(move || Ok((payload, None))).await?;
            let status = owner.status(|| Ok(())).await?;
            if status["changes"][0]["status"] != "conflicted"
                || owner.capabilities()[operation.capability()] != 1
            {
                return Err("fixture negotiation/status mismatch".into());
            }
            owner.write(&operation, || Ok(()), || Ok(())).await
        })
        .await;
        let cleaned =
            tokio::time::timeout(Duration::from_secs(13), sessions.cleanup(owner.clone())).await;
        assert_eq!(cleaned.expect("bounded native integration cleanup"), Ok(()));
        assert!(owner.lease.lock().unwrap().is_none());
        assert_eq!(
            result.expect("bounded real Core VCS request").unwrap(),
            json!({})
        );
        let writes: Vec<Value> = std::fs::read_to_string(&receipt)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(writes.len(), 1);
        assert_eq!(
            writes[0]["method"],
            format!("lithe/vcs/{}", operation.name())
        );
    }
}
