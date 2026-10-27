use super::*;
use std::fs;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let token = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "lithe-generator-test-{}-{token}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn transaction(&self) -> Transaction {
        Transaction::create(Parent::open(&self.0).unwrap(), "Example", "test").unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("remove generator fixture");
    }
}

fn fixture_plan(id: &str) -> Value {
    let package =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../shared/contracts/plugins/v1/fixtures");
    let manifest: Value = serde_json::from_str(
        &fs::read_to_string(package.join("project-generator.plugin.json")).unwrap(),
    )
    .unwrap();
    core("project.generationPlan", json!({"manifest":manifest,"generatorID":id,"packagePath":package,
        "form":{"projectName":"Example","runtimes":{"jdk":{"home":"C:/fixture/jdk","version":"21"}}}}), "plan").unwrap()
}
struct NoCommand;
impl Executor for NoCommand {
    fn command(
        &self,
        _: usize,
        _: &Value,
        _: &Path,
        _: Instant,
        _: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        panic!("files plan must not run a command")
    }
}
fn bounded() -> (Instant, impl Fn() -> Result<()>) {
    let deadline = Instant::now() + Duration::from_secs(3);
    (deadline, move || {
        if Instant::now() >= deadline {
            Err(Error::new("generator.timeout"))
        } else {
            Ok(())
        }
    })
}

#[test]
fn real_core_files_plan_publishes_a_complete_project_without_changing_package() {
    let fixture = Fixture::new();
    let plan = fixture_plan("app");
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../../shared/contracts/plugins/v1/fixtures/project-generator-templates/app/README.md",
    );
    let original = fs::read(&source).unwrap();
    transaction::execute(&mut transaction, &plan, &NoCommand, deadline, &checkpoint).unwrap();
    assert!(!fixture.0.join("Example").exists());
    #[cfg(windows)]
    {
        let target = transaction.publish(&checkpoint).unwrap();
        assert!(target.join("README.md").is_file());
        assert!(target.join(".gitignore").is_file());
        assert!(fs::read_to_string(target.join("README.md"))
            .unwrap()
            .contains("Example"));
    }
    assert_eq!(fs::read(source).unwrap(), original);
    transaction.cleanup().unwrap();
}

#[cfg(windows)]
#[test]
fn activated_maven_sample_form_writes_main_java_through_the_windows_transaction() {
    let fixture = Fixture::new();
    let package =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../shared/contracts/plugins/v1/fixtures");
    let manifest: Value = serde_json::from_str(
        &fs::read_to_string(package.join("project-generator.plugin.json")).unwrap(),
    )
    .unwrap();
    let form = json!({"projectName":"Example","values":{"buildSystem":"maven","sample":true,"groupId":"org.example"},
        "edited":["groupId"],"runtimes":{"jdk":{"home":"C:/fixture/jdk","version":"21"}}});
    let evaluation = core(
        "project.generatorForm",
        json!({"manifest":manifest,"generatorID":"app","form":form}),
        "form",
    )
    .unwrap();
    assert_eq!(evaluation["valid"], true);
    assert!(evaluation["activeRequirements"]
        .as_array()
        .unwrap()
        .contains(&json!(1)));
    let plan = core(
        "project.generationPlan",
        json!({"manifest":manifest,"generatorID":"app","packagePath":package,"form":form}),
        "plan",
    )
    .unwrap();
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    transaction::execute(&mut transaction, &plan, &NoCommand, deadline, &checkpoint).unwrap();
    let target = transaction.publish(&checkpoint).unwrap();
    assert!(target.join("src/org/example/Main.java").is_file());
    assert!(fs::read_to_string(target.join("src/org/example/Main.java"))
        .unwrap()
        .contains("package org.example;"));
    assert!(plan["openFiles"]
        .as_array()
        .unwrap()
        .contains(&json!("src/org/example/Main.java")));
    assert!(!transaction.stage.exists());
    transaction.cleanup().unwrap();
}

struct GenerateCollected;
impl Executor for GenerateCollected {
    fn command(
        &self,
        _: usize,
        step: &Value,
        stage: &Path,
        _: Instant,
        checkpoint: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        checkpoint()?;
        assert_eq!(step["command"], "mvn");
        assert!(step["arguments"]
            .as_array()
            .unwrap()
            .contains(&json!("-DartifactId=example")));
        let child = stage.join(step["collect"].as_str().unwrap());
        fs::create_dir(&child).unwrap();
        fs::write(child.join("pom.xml"), "<project />").unwrap();
        Ok(())
    }
}
#[cfg(windows)]
#[test]
fn real_core_command_plan_collects_then_publishes_once() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    transaction::execute(
        &mut transaction,
        &fixture_plan("archetype"),
        &GenerateCollected,
        deadline,
        &checkpoint,
    )
    .unwrap();
    let target = transaction.publish(&checkpoint).unwrap();
    assert!(target.join("pom.xml").is_file());
    assert!(!target.join("example").exists());
    assert!(!transaction.stage.exists());
    transaction.cleanup().unwrap();
}

#[test]
fn existing_destination_is_never_changed_even_if_it_appears_after_generation() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    transaction::execute(
        &mut transaction,
        &fixture_plan("app"),
        &NoCommand,
        deadline,
        &checkpoint,
    )
    .unwrap();
    fs::create_dir(fixture.0.join("Example")).unwrap();
    fs::write(fixture.0.join("Example/owned.txt"), "existing").unwrap();
    assert_eq!(
        transaction.publish(&checkpoint).unwrap_err().code,
        "generator.destinationExists"
    );
    transaction.cleanup().unwrap();
    assert_eq!(
        fs::read_to_string(fixture.0.join("Example/owned.txt")).unwrap(),
        "existing"
    );
    assert!(!fixture.0.join("Example/README.md").exists());
}

#[cfg(windows)]
#[test]
fn two_staging_transactions_cannot_overwrite_one_target() {
    let fixture = Fixture::new();
    let mut first =
        Transaction::create(Parent::open(&fixture.0).unwrap(), "Example", "first").unwrap();
    let mut second =
        Transaction::create(Parent::open(&fixture.0).unwrap(), "Example", "second").unwrap();
    let (deadline, checkpoint) = bounded();
    let plan = fixture_plan("app");
    transaction::execute(&mut first, &plan, &NoCommand, deadline, &checkpoint).unwrap();
    transaction::execute(&mut second, &plan, &NoCommand, deadline, &checkpoint).unwrap();
    first.publish(&checkpoint).unwrap();
    assert_eq!(
        second.publish(&checkpoint).unwrap_err().code,
        "generator.destinationExists"
    );
    second.cleanup().unwrap();
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
}

#[test]
fn selected_java_runtime_is_saved_using_the_existing_core_configuration_document() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    let plan = fixture_plan("app");
    transaction::execute(&mut transaction, &plan, &NoCommand, deadline, &checkpoint).unwrap();
    preset_runtime(&transaction, &plan).unwrap();
    let document: Value = serde_json::from_str(
        &fs::read_to_string(transaction.stage.join(".lithe/run/local.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(document["version"], 2);
    assert_eq!(document["toolchain"]["java"]["homePath"], "C:/fixture/jdk");
    transaction.cleanup().unwrap();
}

struct FailedCommand;
impl Executor for FailedCommand {
    fn command(
        &self,
        _: usize,
        _: &Value,
        stage: &Path,
        _: Instant,
        _: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        fs::write(stage.join("partial.txt"), "partial").unwrap();
        Err(Error::new("generator.commandFailed"))
    }
}
#[test]
fn command_failure_cleans_partial_files_and_never_publishes() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    assert_eq!(
        transaction::execute(
            &mut transaction,
            &fixture_plan("archetype"),
            &FailedCommand,
            deadline,
            &checkpoint
        )
        .unwrap_err()
        .code,
        "generator.commandFailed"
    );
    transaction.cleanup().unwrap();
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
}

struct CancelCommand(Arc<AtomicBool>);
impl Executor for CancelCommand {
    fn command(
        &self,
        _: usize,
        _: &Value,
        stage: &Path,
        _: Instant,
        checkpoint: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        fs::write(stage.join("partial.txt"), "partial").unwrap();
        self.0.store(true, Ordering::Release);
        checkpoint()
    }
}
#[test]
fn cancellation_at_command_boundary_cleans_the_transaction() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let cancelled = Arc::new(AtomicBool::new(false));
    let (deadline, budget) = bounded();
    let checkpoint = || {
        budget()?;
        if cancelled.load(Ordering::Acquire) {
            Err(Error::new("generator.cancelled"))
        } else {
            Ok(())
        }
    };
    assert_eq!(
        transaction::execute(
            &mut transaction,
            &fixture_plan("archetype"),
            &CancelCommand(cancelled.clone()),
            deadline,
            &checkpoint
        )
        .unwrap_err()
        .code,
        "generator.cancelled"
    );
    transaction.cleanup().unwrap();
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
}

#[test]
fn traversal_ads_reserved_names_and_template_overwrite_are_rejected() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    for path in [
        "../escape",
        "nested/../escape",
        "C:/escape",
        "file:stream",
        "a\\b",
        "a/CON.txt",
        "a/trailing.",
    ] {
        assert!(transaction.write(path, b"bad").is_err(), "{path}");
    }
    transaction.write("safe.txt", b"first").unwrap();
    assert!(transaction.write("safe.txt", b"second").is_err());
    assert_eq!(
        fs::read(transaction.stage.join("safe.txt")).unwrap(),
        b"first"
    );
    transaction.cleanup().unwrap();
}

#[cfg(windows)]
#[test]
fn hard_link_output_is_rejected_without_touching_its_source() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    let outside = fixture.0.join("outside.txt");
    fs::write(&outside, "owned").unwrap();
    fs::hard_link(&outside, transaction.stage.join("linked.txt")).unwrap();
    let (_, checkpoint) = bounded();
    assert_eq!(
        transaction.validate(&checkpoint).unwrap_err().code,
        "generator.linkRejected"
    );
    transaction.cleanup().unwrap();
    assert_eq!(fs::read_to_string(outside).unwrap(), "owned");
}

#[test]
fn archive_plan_requires_an_explicit_native_archive_executor() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let (deadline, checkpoint) = bounded();
    assert_eq!(
        transaction::execute(
            &mut transaction,
            &fixture_plan("initializr"),
            &NoCommand,
            deadline,
            &checkpoint
        )
        .unwrap_err()
        .code,
        "generator.archiveUnavailable"
    );
    transaction.cleanup().unwrap();
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
}

#[test]
fn production_catalog_does_not_bypass_closed_host_capabilities() {
    let package = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/contracts/plugins/v1/fixtures/project-generator.plugin.json");
    let manifest: Value = serde_json::from_str(&fs::read_to_string(package).unwrap()).unwrap();
    let catalog = core("project.generatorCatalog", json!({"plugins":[{"manifest":manifest,"enabled":true}],"hostCapabilities":super::super::host_capabilities()}), "catalog").unwrap();
    assert!(catalog["generators"].as_array().unwrap().is_empty());
    assert!(!catalog["issues"].as_array().unwrap().is_empty());
}

fn retained_operation(
    lifecycle: &super::super::lifecycle::LifecycleState,
    transaction: Transaction,
    unconfirmed_writer: bool,
) -> Operation {
    let target = transaction.stage.clone();
    Operation {
        owner: "main".into(),
        plugin: "fixture.generator".into(),
        target,
        cancelled: AtomicBool::new(true),
        download_cancel: super::super::marketplace_download::CancelToken::new(),
        publication: Mutex::new(()),
        finished: AtomicBool::new(true),
        changed: tokio::sync::Notify::new(),
        lease: Mutex::new(Some(lifecycle.acquire("fixture.generator").unwrap())),
        cleanup: Mutex::new(Some(if unconfirmed_writer {
            RetainedCleanup::UnconfirmedWriter {
                _transaction: transaction,
            }
        } else {
            RetainedCleanup::Filesystem(transaction)
        })),
    }
}

#[cfg(windows)]
#[test]
fn finished_filesystem_cleanup_retries_the_same_directory_before_releasing_its_lease() {
    use std::os::windows::fs::OpenOptionsExt;
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    transaction.write("locked.txt", b"partial").unwrap();
    let stage = transaction.stage.clone();
    let lock = fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(stage.join("locked.txt"))
        .unwrap();
    let lifecycle = super::super::lifecycle::LifecycleState::default();
    let operation = retained_operation(&lifecycle, transaction, false);
    assert_eq!(
        operation.cleanup_finished().unwrap_err().code,
        "generator.cleanupFailed"
    );
    assert!(operation.lease.lock().unwrap().is_some());
    assert!(stage.is_dir());
    drop(lock);
    operation.cleanup_finished().unwrap();
    assert!(!stage.exists());
    assert!(operation.lease.lock().unwrap().is_none());
    operation.cleanup_finished().unwrap();
}

#[test]
fn uncertain_writer_cleanup_never_removes_staging_or_releases_its_lease() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    transaction.write("partial.txt", b"writer output").unwrap();
    let stage = transaction.stage.clone();
    let lifecycle = super::super::lifecycle::LifecycleState::default();
    let operation = retained_operation(&lifecycle, transaction, true);
    for _ in 0..2 {
        assert_eq!(
            operation.cleanup_finished().unwrap_err().code,
            "generator.cleanupFailed"
        );
        assert!(operation.lease.lock().unwrap().is_some());
        assert_eq!(
            fs::read(stage.join("partial.txt")).unwrap(),
            b"writer output"
        );
    }
    drop(operation);
}

#[test]
fn one_owner_cannot_cancel_another_operations_download_or_remove_its_stage() {
    let first = Fixture::new();
    let second = Fixture::new();
    let lifecycle = super::super::lifecycle::LifecycleState::default();
    let mut operation = retained_operation(&lifecycle, first.transaction(), false);
    operation.owner = "main".into();
    let mut other = retained_operation(&lifecycle, second.transaction(), false);
    other.owner = "workspace-other".into();
    other.cancelled.store(false, Ordering::Release);
    operation.cancel();
    operation.cleanup_finished().unwrap();
    assert!(operation.download_cancel.is_cancelled());
    assert!(!other.download_cancel.is_cancelled());
    assert!(other
        .checkpoint(Instant::now() + Duration::from_secs(3))
        .is_ok());
    assert!(other.target.is_dir());
    assert!(other.lease.lock().unwrap().is_some());
    other.cleanup_finished().unwrap();
}

struct ArchiveTransport {
    responses: Mutex<std::collections::VecDeque<super::super::marketplace_download::HttpResponse>>,
    requests: Mutex<Vec<String>>,
    before_response: Option<Box<dyn Fn() + Send + Sync>>,
}
impl ArchiveTransport {
    fn zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        use std::io::Write;
        let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        for (name, bytes) in entries {
            writer
                .start_file(*name, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(bytes).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }
    fn new(body: Vec<u8>) -> Self {
        Self {
            responses: Mutex::new(std::collections::VecDeque::from([
                super::super::marketplace_download::HttpResponse {
                    status: 200,
                    headers: HashMap::new(),
                    body,
                },
            ])),
            requests: Mutex::new(Vec::new()),
            before_response: None,
        }
    }
}
impl super::super::marketplace_download::HttpTransport for ArchiveTransport {
    fn get<'a>(
        &'a self,
        url: &'a str,
        max_bytes: u64,
        _: Instant,
        _: &'a super::super::marketplace_download::CancelToken,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<
                    Output = std::result::Result<
                        super::super::marketplace_download::HttpResponse,
                        super::super::marketplace_download::FetchFailure,
                    >,
                > + Send
                + 'a,
        >,
    > {
        Box::pin(async move {
            self.requests.lock().unwrap().push(url.into());
            if let Some(before_response) = &self.before_response {
                before_response();
            }
            let response = self
                .responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected archive request");
            if response.body.len() as u64 > max_bytes {
                return Err(
                    super::super::marketplace_download::FetchFailure::BudgetExceeded {
                        limit: max_bytes,
                    },
                );
            }
            Ok(response)
        })
    }
}
struct NetworkArchive<'a> {
    transport: &'a ArchiveTransport,
    token: super::super::marketplace_download::CancelToken,
}
impl Executor for NetworkArchive<'_> {
    fn command(
        &self,
        _: usize,
        _: &Value,
        _: &Path,
        _: Instant,
        _: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        panic!("archive plan must not run commands")
    }
    fn archive(
        &self,
        step: &Value,
        stage: &Path,
        deadline: Instant,
        checkpoint: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        archive::execute(
            self.transport,
            step["url"].as_str().unwrap(),
            stage,
            "generator-fixture-archive",
            &self.token,
            deadline,
            checkpoint,
        )
    }
}

#[cfg(windows)]
fn create_junction(link: &Path, target: &Path) {
    let link_deadline = Instant::now() + Duration::from_secs(5);
    let mut command = std::process::Command::new("cmd");
    command
        .args(["/D", "/C", "mklink", "/J"])
        .arg(link)
        .arg(target);
    let outcome = lithe_git_host::run(
        &mut command,
        None,
        || Instant::now() >= link_deadline,
        || {},
        |_, _| {},
    );
    assert!(
        outcome.failure.is_none() && outcome.status.is_some_and(|status| status.success()),
        "junction creation failed: {}",
        String::from_utf8_lossy(&outcome.stderr)
    );
}

#[cfg(windows)]
#[test]
fn archive_download_rechecks_stage_identity_and_retains_the_original_cleanup_owner() {
    for junction in [false, true] {
        let fixture = Fixture::new();
        let mut transaction = fixture.transaction();
        let stage = transaction.stage.clone();
        let moved = fixture.0.join("original-staging");
        let replacement = fixture.0.join("prepared-replacement");
        let replacement_contents = if junction {
            let outside = fixture.0.join("junction-target");
            fs::create_dir(&outside).unwrap();
            fs::write(outside.join("owned.txt"), b"user bytes").unwrap();
            create_junction(&replacement, &outside);
            outside
        } else {
            fs::create_dir(&replacement).unwrap();
            fs::write(replacement.join("owned.txt"), b"user bytes").unwrap();
            stage.clone()
        };
        let mut transport =
            ArchiveTransport::new(ArchiveTransport::zip(&[("untrusted.txt", b"no write")]));
        let swapped_stage = stage.clone();
        let moved_stage = moved.clone();
        transport.before_response = Some(Box::new(move || {
            // Replace staging only after the pre-fetch transaction check. No
            // worker or clock race controls this security regression scenario.
            fs::rename(&swapped_stage, &moved_stage).unwrap();
            fs::rename(&replacement, &swapped_stage).unwrap();
        }));
        let executor = NetworkArchive {
            transport: &transport,
            token: super::super::marketplace_download::CancelToken::new(),
        };
        let (deadline, checkpoint) = bounded();
        let error = transaction::execute(
            &mut transaction,
            &fixture_plan("initializr"),
            &executor,
            deadline,
            &checkpoint,
        )
        .unwrap_err();
        assert!(matches!(
            error.code.as_str(),
            "generator.stale" | "generator.linkRejected"
        ));
        assert_eq!(transport.requests.lock().unwrap().len(), 1);
        assert_eq!(
            fs::read(replacement_contents.join("owned.txt")).unwrap(),
            b"user bytes"
        );
        assert_eq!(fs::read_dir(&replacement_contents).unwrap().count(), 1);
        assert_eq!(fs::read_dir(&moved).unwrap().count(), 0);
        let lifecycle = super::super::lifecycle::LifecycleState::default();
        let operation = retained_operation(&lifecycle, transaction, false);
        assert_eq!(
            operation.cleanup_finished().unwrap_err().code,
            "generator.cleanupFailed"
        );
        assert!(operation.lease.lock().unwrap().is_some());
        assert_eq!(fs::read_dir(&replacement_contents).unwrap().count(), 1);

        // Only the owned test replacement is removed. Restoring the original
        // identity makes the retained operation's cleanup retry succeed.
        if !junction {
            fs::remove_file(stage.join("owned.txt")).unwrap();
        }
        fs::remove_dir(&stage).unwrap();
        fs::rename(&moved, &stage).unwrap();
        operation.cleanup_finished().unwrap();
        assert!(operation.lease.lock().unwrap().is_none());
        assert!(!stage.exists());
    }
}

#[cfg(windows)]
#[test]
fn archive_step_reuses_the_real_core_extractor_before_exclusive_publication() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let transport = ArchiveTransport::new(ArchiveTransport::zip(&[
        ("pom.xml", b"<project/>"),
        ("src/App.java", b"class App {}"),
    ]));
    let executor = NetworkArchive {
        transport: &transport,
        token: super::super::marketplace_download::CancelToken::new(),
    };
    let plan = fixture_plan("initializr");
    let (deadline, checkpoint) = bounded();
    transaction::execute(&mut transaction, &plan, &executor, deadline, &checkpoint).unwrap();
    assert_eq!(
        transport.requests.lock().unwrap().as_slice(),
        [plan["steps"][0]["url"].as_str().unwrap()]
    );
    assert!(!fixture.0.join("Example").exists());
    assert_eq!(
        fs::read_dir(&transaction.stage).unwrap().count(),
        2,
        "private archive must be removed"
    );
    let target = transaction.publish(&checkpoint).unwrap();
    assert_eq!(
        fs::read_to_string(target.join("src/App.java")).unwrap(),
        "class App {}"
    );
    transaction.cleanup().unwrap();
}

#[test]
fn hostile_archive_or_preexisting_target_file_is_never_published_or_overwritten() {
    for name in [
        "../escape.txt",
        "nested/../escape.txt",
        "nested\\escape.txt",
        "owned.txt",
    ] {
        let fixture = Fixture::new();
        let mut transaction = fixture.transaction();
        transaction.write("owned.txt", b"user bytes").unwrap();
        let transport = ArchiveTransport::new(ArchiveTransport::zip(&[(name, b"bad")]));
        let executor = NetworkArchive {
            transport: &transport,
            token: super::super::marketplace_download::CancelToken::new(),
        };
        let (deadline, checkpoint) = bounded();
        assert_eq!(
            transaction::execute(
                &mut transaction,
                &fixture_plan("initializr"),
                &executor,
                deadline,
                &checkpoint
            )
            .unwrap_err()
            .code,
            "generator.archiveInvalid"
        );
        assert_eq!(
            fs::read(transaction.stage.join("owned.txt")).unwrap(),
            b"user bytes"
        );
        assert!(!fixture.0.join("escape.txt").exists());
        assert!(!fixture.0.join("Example").exists());
        transaction.cleanup().unwrap();
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
    }
}

#[cfg(windows)]
#[test]
fn nested_archive_directories_are_preserved_and_a_late_target_never_changes() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let transport = ArchiveTransport::new(ArchiveTransport::zip(&[(
        "wrapper/src/App.java",
        b"class App {}",
    )]));
    let executor = NetworkArchive {
        transport: &transport,
        token: super::super::marketplace_download::CancelToken::new(),
    };
    let (deadline, checkpoint) = bounded();
    transaction::execute(
        &mut transaction,
        &fixture_plan("initializr"),
        &executor,
        deadline,
        &checkpoint,
    )
    .unwrap();
    // The shared plan has no strip field. Preserve the ZIP's enclosing folder
    // rather than guessing it is a disposable archive wrapper.
    assert!(transaction.stage.join("wrapper/src/App.java").is_file());
    assert!(!transaction.stage.join("src").exists());
    fs::create_dir(fixture.0.join("Example")).unwrap();
    fs::write(fixture.0.join("Example/owned.txt"), b"user bytes").unwrap();
    assert_eq!(
        transaction.publish(&checkpoint).unwrap_err().code,
        "generator.destinationExists"
    );
    transaction.cleanup().unwrap();
    assert_eq!(
        fs::read(fixture.0.join("Example/owned.txt")).unwrap(),
        b"user bytes"
    );
    assert_eq!(fs::read_dir(fixture.0.join("Example")).unwrap().count(), 1);
}

#[test]
fn invalid_zip_and_archive_symlink_remove_the_download_before_transaction_cleanup() {
    use std::io::Cursor;
    let mut linked = zip::ZipWriter::new(Cursor::new(Vec::new()));
    linked
        .add_symlink(
            "link",
            "../owned.txt",
            zip::write::SimpleFileOptions::default(),
        )
        .unwrap();
    let linked = linked.finish().unwrap().into_inner();
    for body in [b"not a zip".to_vec(), linked] {
        let fixture = Fixture::new();
        let mut transaction = fixture.transaction();
        let transport = ArchiveTransport::new(body);
        let executor = NetworkArchive {
            transport: &transport,
            token: super::super::marketplace_download::CancelToken::new(),
        };
        let (deadline, checkpoint) = bounded();
        assert_eq!(
            transaction::execute(
                &mut transaction,
                &fixture_plan("initializr"),
                &executor,
                deadline,
                &checkpoint
            )
            .unwrap_err()
            .code,
            "generator.archiveInvalid"
        );
        assert_eq!(fs::read_dir(&transaction.stage).unwrap().count(), 0);
        transaction.cleanup().unwrap();
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
    }
}

#[cfg(windows)]
#[test]
fn real_core_refuses_archive_writes_through_a_junction_and_cleanup_keeps_its_target() {
    let fixture = Fixture::new();
    let mut transaction = fixture.transaction();
    let outside = fixture.0.join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("owned.txt"), b"user bytes").unwrap();
    let link: PathBuf = transaction.stage.join("nested").components().collect();
    let target: PathBuf = outside.components().collect();
    // Reuse the existing build/web fixture's junction technique: no Developer
    // Mode or admin permission, with the native process owner and a deadline.
    create_junction(&link, &target);
    let transport = ArchiveTransport::new(ArchiveTransport::zip(&[(
        "nested/escape.txt",
        b"untrusted",
    )]));
    let executor = NetworkArchive {
        transport: &transport,
        token: super::super::marketplace_download::CancelToken::new(),
    };
    let (deadline, checkpoint) = bounded();
    assert_eq!(
        transaction::execute(
            &mut transaction,
            &fixture_plan("initializr"),
            &executor,
            deadline,
            &checkpoint
        )
        .unwrap_err()
        .code,
        "generator.archiveInvalid"
    );
    assert!(!outside.join("escape.txt").exists());
    transaction.cleanup().unwrap();
    assert_eq!(fs::read(outside.join("owned.txt")).unwrap(), b"user bytes");
    assert_eq!(fs::read_dir(outside).unwrap().count(), 1);
}

#[test]
fn denied_archive_targets_never_reach_the_transport_or_create_downloads() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    let transport = ArchiveTransport::new(vec![]);
    let (deadline, checkpoint) = bounded();
    for url in [
        "http://fixture.invalid/project.zip",
        "https://user:secret@fixture.invalid/project.zip",
        "file:///project.zip",
    ] {
        assert_eq!(
            archive::execute(
                &transport,
                url,
                &transaction.stage,
                "generator-fixture-denied",
                &super::super::marketplace_download::CancelToken::new(),
                deadline,
                &checkpoint
            )
            .unwrap_err()
            .code,
            "generator.downloadFailed"
        );
    }
    assert!(transport.requests.lock().unwrap().is_empty());
    assert_eq!(fs::read_dir(&transaction.stage).unwrap().count(), 0);
    transaction.cleanup().unwrap();
}

#[test]
fn archive_download_cancellation_and_https_redirect_refusal_leave_no_file() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    let transport = ArchiveTransport::new(vec![]);
    let token = super::super::marketplace_download::CancelToken::new();
    token.cancel();
    let (deadline, checkpoint) = bounded();
    assert_eq!(
        archive::execute(
            &transport,
            "https://fixture.invalid/project.zip",
            &transaction.stage,
            "generator-fixture-cancelled",
            &token,
            deadline,
            &checkpoint
        )
        .unwrap_err()
        .code,
        "generator.cancelled"
    );
    assert!(transport.requests.lock().unwrap().is_empty());
    transport.responses.lock().unwrap().clear();
    transport.responses.lock().unwrap().push_back(
        super::super::marketplace_download::HttpResponse {
            status: 302,
            headers: HashMap::from([(
                "location".into(),
                "http://fixture.invalid/unsafe.zip".into(),
            )]),
            body: vec![],
        },
    );
    assert_eq!(
        archive::execute(
            &transport,
            "https://fixture.invalid/project.zip",
            &transaction.stage,
            "generator-fixture-redirect",
            &super::super::marketplace_download::CancelToken::new(),
            deadline,
            &checkpoint
        )
        .unwrap_err()
        .code,
        "generator.downloadFailed"
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    assert_eq!(fs::read_dir(&transaction.stage).unwrap().count(), 0);
    transaction.cleanup().unwrap();
}

#[test]
fn cancellation_during_private_archive_write_closes_and_removes_the_download() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    let transport = ArchiveTransport::new(ArchiveTransport::zip(&[("file.txt", b"no")]));
    let (deadline, _) = bounded();
    let checkpoint = || {
        // The transaction starts empty. Cancel as soon as its exclusive ZIP
        // exists, before any download bytes reach the file.
        if fs::read_dir(&transaction.stage).unwrap().next().is_some() {
            Err(Error::new("generator.cancelled"))
        } else {
            Ok(())
        }
    };
    let error = archive::execute(
        &transport,
        "https://fixture.invalid/project.zip",
        &transaction.stage,
        "generator-fixture-write-cancel",
        &super::super::marketplace_download::CancelToken::new(),
        deadline,
        &checkpoint,
    )
    .unwrap_err();
    assert_eq!(error.code, "generator.cancelled");
    assert_eq!(fs::read_dir(&transaction.stage).unwrap().count(), 0);
    transaction.cleanup().unwrap();
}

#[test]
fn expired_archive_budget_never_dispatches_http_or_creates_files() {
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    let transport = ArchiveTransport::new(vec![]);
    let error = archive::execute(
        &transport,
        "https://fixture.invalid/project.zip",
        &transaction.stage,
        "generator-fixture-expired",
        &super::super::marketplace_download::CancelToken::new(),
        Instant::now(),
        &|| Ok(()),
    )
    .unwrap_err();
    assert_eq!(error.code, "generator.timeout");
    assert!(transport.requests.lock().unwrap().is_empty());
    assert_eq!(fs::read_dir(&transaction.stage).unwrap().count(), 0);
    transaction.cleanup().unwrap();
}

struct StalledArchiveTransport(Mutex<Option<tokio::sync::oneshot::Sender<()>>>);
impl super::super::marketplace_download::HttpTransport for StalledArchiveTransport {
    fn get<'a>(
        &'a self,
        _: &'a str,
        _: u64,
        _: Instant,
        _: &'a super::super::marketplace_download::CancelToken,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<
                    Output = std::result::Result<
                        super::super::marketplace_download::HttpResponse,
                        super::super::marketplace_download::FetchFailure,
                    >,
                > + Send
                + 'a,
        >,
    > {
        Box::pin(async move {
            if let Some(entered) = self.0.lock().unwrap().take() {
                let _ = entered.send(());
            }
            std::future::pending().await
        })
    }
}

#[tokio::test]
async fn native_cancel_wakes_a_pending_archive_headers_wait_and_drains_before_cleanup() {
    use super::super::marketplace_download::{fetch_controlled, FetchLimits, FetchPolicy};
    let fixture = Fixture::new();
    let transaction = fixture.transaction();
    let lifecycle = super::super::lifecycle::LifecycleState::default();
    let operation = retained_operation(&lifecycle, transaction, false);
    let (entered, headers) = tokio::sync::oneshot::channel();
    let transport = StalledArchiveTransport(Mutex::new(Some(entered)));
    let fetch = fetch_controlled(
        &transport,
        "https://fixture.invalid/project.zip",
        FetchLimits {
            max_bytes: 32,
            max_redirects: 1,
        },
        FetchPolicy::https_only(),
        &operation.download_cancel,
        Instant::now() + Duration::from_secs(3),
    );
    tokio::pin!(fetch);
    let entered = tokio::time::timeout(Duration::from_secs(2), async {
        tokio::select! {
            entered = headers => entered.is_ok(),
            _ = &mut fetch => false,
        }
    })
    .await;
    // Cancel before any assertion; dropping this async fetch also disposes every
    // pending network future, so no blocking worker can outlive this fixture.
    operation.cancel();
    let result = tokio::time::timeout(Duration::from_secs(2), &mut fetch).await;
    operation.cleanup_finished().unwrap();
    assert!(entered.is_ok_and(|entered| entered));
    assert!(matches!(
        result.unwrap(),
        Err(super::super::marketplace_download::FetchFailure::Cancelled)
    ));
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
}
