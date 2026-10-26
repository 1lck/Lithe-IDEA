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
fn archive_plan_is_unavailable_before_any_executor_call() {
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
