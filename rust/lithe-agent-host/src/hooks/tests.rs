use super::*;
use std::fs;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("lithe-hooks-test-{}", uuid::Uuid::new_v4())))
    }
    fn directory(&self) -> PathBuf {
        self.0.join("library")
    }
    fn profile(&self, agent: &str) -> PathBuf {
        self.0.join("profiles").join(agent)
    }
    fn native(&self, agent: &str) -> PathBuf {
        self.profile(agent).join(if agent == "codex-acp" {
            "hooks.json"
        } else {
            "settings.json"
        })
    }
    fn write(&self, agent: &str, content: &str) {
        fs::create_dir_all(self.profile(agent)).unwrap();
        fs::write(self.native(agent), content).unwrap();
    }
    fn run(&self, action: Action) -> Result<Library, Error> {
        execute_in(
            Request {
                data_directory: self.directory(),
                action,
            },
            &|agent| Ok(self.profile(agent)),
            &|| false,
            &Mutex::new(()),
        )
    }
    fn read(&self) -> Library {
        self.run(Action::Read {}).unwrap()
    }
    fn save(&self, hook: Hook, before: &Library) -> Library {
        self.run(Action::Save {
            hook,
            expected_revision: before.revision.clone(),
            files: guards(before),
        })
        .unwrap()
    }
    fn sync(&self, before: &Library) -> Library {
        self.run(Action::Sync {
            expected_revision: before.revision.clone(),
            files: guards(before),
        })
        .unwrap()
    }
    fn doc(&self, agent: &str) -> Value {
        serde_json::from_slice(&fs::read(self.native(agent)).unwrap()).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if self.0.exists() {
            fs::remove_dir_all(&self.0).expect("remove owned Hook fixture");
        }
    }
}
fn guards(library: &Library) -> Vec<FileGuard> {
    library
        .targets
        .iter()
        .filter_map(|t| t.file.clone())
        .collect()
}
fn hook() -> Hook {
    Hook {
        id: uuid::Uuid::new_v4().to_string(),
        name: "notify".into(),
        description: "一轮结束时提醒".into(),
        event: Event::TurnEnd,
        matcher: Matcher::All,
        command: "printf done".into(),
        timeout_seconds: None,
        agents: AGENTS.iter().map(|a| (*a).into()).collect(),
        enabled: true,
        pending_removal: false,
    }
}

#[test]
fn opening_the_library_is_read_only_and_does_not_expose_native_secrets() {
    let fixture = Fixture::new();
    assert!(fixture.read().hooks.is_empty());
    assert!(!fixture.0.exists());
    fixture.write("claude-acp", r#"{"env":{"API_KEY":"fixture-secret"}}"#);
    let encoded = serde_json::to_string(&fixture.read()).unwrap();
    assert!(!encoded.contains("fixture-secret"));
}

#[test]
fn saves_both_native_formats_without_executing_commands_or_replacing_other_settings() {
    let fixture = Fixture::new();
    let own = json!({"hooks": [{"type": "command", "command": "own-hook"}], "matcher": "custom"});
    fixture.write("claude-acp", &json!({"env": {"TOKEN": "fixture"}, "hooks": {"Stop": [own.clone()]}, "disableAllHooks": true}).to_string());
    let mut wanted = hook();
    wanted.command = format!("touch {}", fixture.0.join("must-not-exist").display());
    let saved = fixture.save(wanted.clone(), &fixture.read());
    assert!(!saved.hooks[0].needs_sync);
    assert_eq!(saved.hooks[0].configured_agents.len(), 2);
    assert_eq!(fixture.doc("claude-acp")["env"]["TOKEN"], "fixture");
    assert_eq!(fixture.doc("claude-acp")["hooks"]["Stop"][0], own);
    assert_eq!(
        fixture.doc("codex-acp")["hooks"]["Stop"][0],
        entry(&wanted, "codex-acp")
    );
    assert!(
        saved
            .targets
            .iter()
            .find(|t| t.agent_id == "claude-acp")
            .unwrap()
            .disabled
    );
    assert!(!fixture.0.join("must-not-exist").exists());
    assert!(fixture.doc("codex-acp")["hooks"]["Stop"][0]["hooks"][0]
        .get("timeout")
        .is_none());
}

#[test]
fn portable_tool_filters_and_timeouts_use_the_agents_own_names() {
    let fixture = Fixture::new();
    let mut wanted = hook();
    wanted.event = Event::AfterTool;
    wanted.matcher = Matcher::Edit;
    wanted.timeout_seconds = Some(30);
    fixture.save(wanted, &fixture.read());
    assert_eq!(
        fixture.doc("codex-acp")["hooks"]["PostToolUse"][0]["matcher"],
        "apply_patch"
    );
    assert_eq!(
        fixture.doc("claude-acp")["hooks"]["PostToolUse"][0]["matcher"],
        "Edit|Write|MultiEdit"
    );
    assert_eq!(
        fixture.doc("claude-acp")["hooks"]["PostToolUse"][0]["hooks"][0]["timeout"],
        30
    );
    for event in [
        Event::TurnEnd,
        Event::AfterTool,
        Event::BeforeTool,
        Event::Prompt,
        Event::SessionStart,
    ] {
        let mut wanted = hook();
        wanted.event = event;
        wanted.matcher = Matcher::All;
        assert!(entry(&wanted, "codex-acp").get("matcher").is_none());
    }
}

#[test]
fn editing_disabling_and_deleting_preserve_codex_trust_positions_and_user_hooks() {
    let fixture = Fixture::new();
    let own = json!({"hooks": [{"type": "command", "command": "user-command"}]});
    fixture.write(
        "codex-acp",
        &json!({"hooks": {"Stop": [own.clone()]}}).to_string(),
    );
    let trust_path = fixture.profile("codex-acp").join("config.toml");
    fs::write(
        &trust_path,
        "# user-owned trust state\n[features]\nhooks = true\n",
    )
    .unwrap();
    let trust = fs::read(&trust_path).unwrap();
    let mut wanted = hook();
    let first = fixture.save(wanted.clone(), &fixture.read());
    wanted.command = "printf updated".into();
    let second = fixture.save(wanted.clone(), &first);
    assert_eq!(fixture.doc("codex-acp")["hooks"]["Stop"][0], own);
    assert_eq!(
        fixture.doc("codex-acp")["hooks"]["Stop"][1],
        json!({"hooks": []})
    );
    assert_eq!(
        fixture.doc("codex-acp")["hooks"]["Stop"][2]["hooks"][0]["command"],
        wanted.command
    );
    wanted.enabled = false;
    let disabled = fixture.save(wanted.clone(), &second);
    assert!(disabled.hooks[0].configured_agents.is_empty());
    assert!(!disabled.hooks[0].needs_sync);
    wanted.enabled = true;
    let enabled = fixture.save(wanted.clone(), &disabled);
    let removed = fixture
        .run(Action::Remove {
            id: wanted.id,
            expected_revision: enabled.revision.clone(),
            files: guards(&enabled),
        })
        .unwrap();
    assert!(removed.hooks.is_empty());
    assert_eq!(fixture.doc("codex-acp")["hooks"]["Stop"][0], own);
    assert_eq!(fs::read(trust_path).unwrap(), trust);
}

#[test]
fn saving_an_unrelated_hook_keeps_an_existing_trusted_command_at_its_position() {
    let fixture = Fixture::new();
    let first = fixture.save(hook(), &fixture.read());
    let original = fixture.doc("codex-acp")["hooks"]["Stop"][0].clone();
    let mut other = hook();
    other.name = "other".into();
    other.command = "printf other".into();
    let second = fixture.save(other, &first);
    assert!(second.hooks.iter().all(|h| !h.needs_sync));
    assert_eq!(fixture.doc("codex-acp")["hooks"]["Stop"][0], original);
    assert_eq!(
        fixture.doc("codex-acp")["hooks"]["Stop"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn stale_source_is_rejected_and_native_conflicts_report_partial_success_then_retry() {
    let fixture = Fixture::new();
    let before = fixture.read();
    fixture.write("codex-acp", r#"{"external":true}"#);
    let saved = fixture.save(hook(), &before);
    assert!(saved.hooks[0].needs_sync);
    assert_eq!(saved.hooks[0].configured_agents, ["claude-acp"]);
    assert!(saved.targets[0].issue.is_some());
    assert_eq!(fixture.doc("codex-acp"), json!({"external": true}));
    assert_eq!(
        fixture
            .run(Action::Save {
                hook: hook(),
                expected_revision: before.revision,
                files: vec![]
            })
            .unwrap_err()
            .reason,
        "file_changed"
    );
    let retried = fixture.sync(&fixture.read());
    assert!(!retried.hooks[0].needs_sync);
    assert_eq!(fixture.doc("codex-acp")["external"], true);
}

#[test]
fn malformed_native_settings_are_preserved_while_the_other_agent_can_sync() {
    let fixture = Fixture::new();
    fixture.write("claude-acp", "{ invalid settings");
    let saved = fixture.save(hook(), &fixture.read());
    assert!(saved.hooks[0].needs_sync);
    assert_eq!(saved.hooks[0].configured_agents, ["codex-acp"]);
    assert_eq!(
        fs::read_to_string(fixture.native("claude-acp")).unwrap(),
        "{ invalid settings"
    );
}

#[test]
fn externally_edited_owned_commands_are_never_removed_or_duplicated() {
    let fixture = Fixture::new();
    let saved = fixture.save(hook(), &fixture.read());
    let mut changed = fixture.doc("codex-acp");
    changed["hooks"]["Stop"][0]["hooks"][0]["command"] = json!("user-modified");
    fixture.write("codex-acp", &changed.to_string());
    let reread = fixture.read();
    assert!(reread.hooks[0].needs_sync);
    let removed = fixture
        .run(Action::Remove {
            id: saved.hooks[0].hook.id.clone(),
            expected_revision: reread.revision.clone(),
            files: guards(&reread),
        })
        .unwrap();
    assert!(removed.hooks[0].hook.pending_removal);
    assert!(removed.targets[0].issue.is_some());
    assert_eq!(fixture.doc("codex-acp"), changed);
    // Removing the external entry explicitly makes the pending operation retryable.
    fixture.write("codex-acp", "{}");
    assert!(fixture.sync(&fixture.read()).hooks.is_empty());
}

#[test]
fn journals_survive_a_crash_before_or_after_a_native_write_without_duplicate_execution() {
    for native_committed in [false, true] {
        let fixture = Fixture::new();
        let saved = fixture.save(hook(), &fixture.read());
        let source = storage::read("library", fixture.directory().join("hooks.json")).unwrap();
        let mut stored = decode(&source).unwrap();
        stored.hooks[0].command = "printf replacement".into();
        let native = native_file("codex-acp", &|agent| Ok(fixture.profile(agent))).unwrap();
        let (next, planned) = plan(&stored, &native).unwrap();
        stored.placements.extend(planned);
        storage::save(&source, &stored).unwrap();
        if native_committed {
            storage::write_native(&native, &next).unwrap();
        }
        let recovered = fixture.sync(&fixture.read());
        assert!(recovered.hooks.iter().all(|h| !h.needs_sync));
        let doc = fixture.doc("codex-acp");
        let running = doc["hooks"]["Stop"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|g| g["hooks"].as_array().unwrap());
        assert_eq!(running.count(), 1);
        assert_eq!(recovered.hooks[0].hook.id, saved.hooks[0].hook.id);
    }
}

#[test]
fn cancellation_before_start_has_no_side_effects_and_between_targets_is_retryable() {
    let fixture = Fixture::new();
    let request = Request {
        data_directory: fixture.directory(),
        action: Action::Read {},
    };
    assert_eq!(
        execute_in(
            request,
            &|agent| Ok(fixture.profile(agent)),
            &|| true,
            &Mutex::new(())
        )
        .unwrap_err()
        .reason,
        "cancelled"
    );
    assert!(!fixture.0.exists());
    let before = fixture.read();
    let result = execute_in(
        Request {
            data_directory: fixture.directory(),
            action: Action::Save {
                hook: hook(),
                expected_revision: before.revision.clone(),
                files: guards(&before),
            },
        },
        &|agent| Ok(fixture.profile(agent)),
        &|| fixture.native("codex-acp").exists(),
        &Mutex::new(()),
    )
    .unwrap();
    assert!(result.hooks[0].needs_sync);
    assert!(!fixture.native("claude-acp").exists());
    assert!(!fixture.sync(&fixture.read()).hooks[0].needs_sync);
}

#[test]
fn validates_names_events_timeout_agent_selection_and_strict_requests_before_writing() {
    let mut invalid = hook();
    invalid.name = "../escape".into();
    assert!(validate(&invalid).is_err());
    let mut invalid = hook();
    invalid.timeout_seconds = Some(0);
    assert!(validate(&invalid).is_err());
    let mut invalid = hook();
    invalid.timeout_seconds = Some(86401);
    assert!(validate(&invalid).is_err());
    let mut invalid = hook();
    invalid.agents = vec!["unknown".into()];
    assert!(validate(&invalid).is_err());
    let mut invalid = hook();
    invalid.matcher = Matcher::Shell;
    assert!(validate(&invalid).is_err());
    let mut invalid = hook();
    invalid.description = "汉".repeat(201);
    assert!(validate(&invalid).is_err());
    assert!(serde_json::from_value::<Request>(
        json!({"dataDirectory": "/fixture", "action": "read", "command": "must-not-run"})
    )
    .is_err());
}

#[test]
fn duplicate_json_keys_and_identical_user_owned_commands_are_never_overwritten_or_claimed() {
    let fixture = Fixture::new();
    let wanted = hook();
    fixture.write(
        "codex-acp",
        &json!({"hooks": {"Stop": [entry(&wanted, "codex-acp")]}}).to_string(),
    );
    let duplicate = "{\"env\":{\"TOKEN\":\"first\",\"TOKEN\":\"second\"}}";
    fixture.write("claude-acp", duplicate);
    let result = fixture.save(wanted.clone(), &fixture.read());
    assert!(result.targets.iter().all(|t| t.issue.is_some()));
    assert!(result.hooks[0].configured_agents.is_empty());
    assert_eq!(
        fixture.doc("codex-acp")["hooks"]["Stop"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        fs::read_to_string(fixture.native("claude-acp")).unwrap(),
        duplicate
    );
    let source = storage::read("library", fixture.directory().join("hooks.json")).unwrap();
    assert!(decode(&source).unwrap().placements.is_empty());
}

#[test]
fn os_library_lock_is_nonblocking_and_released_with_its_owner() {
    let fixture = Fixture::new();
    let first = storage::lock(&fixture.directory()).unwrap();
    assert_eq!(
        storage::lock(&fixture.directory()).unwrap_err().reason,
        "busy"
    );
    drop(first);
    assert!(storage::lock(&fixture.directory()).is_ok());
}

#[cfg(unix)]
#[test]
fn symlinked_native_files_are_not_followed_and_readonly_permissions_are_preserved() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let fixture = Fixture::new();
    fixture.write("codex-acp", "{}");
    let outside = fixture.0.join("outside.json");
    fs::write(&outside, "{}").unwrap();
    fs::remove_file(fixture.native("codex-acp")).unwrap();
    symlink(&outside, fixture.native("codex-acp")).unwrap();
    fixture.write("claude-acp", "{}");
    fs::set_permissions(
        fixture.native("claude-acp"),
        fs::Permissions::from_mode(0o400),
    )
    .unwrap();
    let saved = fixture.save(hook(), &fixture.read());
    assert!(saved.targets.iter().all(|t| t.issue.is_some()));
    assert_eq!(fs::read_to_string(outside).unwrap(), "{}");
    assert_eq!(
        fs::metadata(fixture.native("claude-acp"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o400
    );
}
