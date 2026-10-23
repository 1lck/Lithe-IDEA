use super::*;

struct Fixture {
    path: PathBuf,
    write_lock: Mutex<()>,
}
impl Fixture {
    fn new() -> Self {
        Self {
            path: std::env::temp_dir().join(format!("lithe-shared-{}", uuid::Uuid::new_v4())),
            write_lock: Mutex::new(()),
        }
    }
    fn profile(&self, agent: &str) -> Result<PathBuf, InstructionError> {
        Ok(self.path.join(agent))
    }
    fn read(&self) -> Library {
        self.run(Action::Read {}).unwrap()
    }
    fn run(&self, action: Action) -> Result<Library, InstructionError> {
        execute_in(
            Request {
                data_directory: self.path.join("library"),
                action,
            },
            &|agent| self.profile(agent),
            &|| false,
            &self.write_lock,
        )
    }
    fn save(&self, library: &Library, text: &str) -> Library {
        self.run(Action::Save {
            content: text.into(),
            expected_revision: library.file.revision.clone(),
            files: library
                .agents
                .iter()
                .filter_map(|agent| agent.file.as_ref().map(guard))
                .collect(),
        })
        .unwrap()
    }
    fn toggle(
        &self,
        library: &Library,
        agent: &str,
        enabled: bool,
    ) -> Result<Library, InstructionError> {
        self.run(Action::SetEnabled {
            agent_id: agent.into(),
            enabled,
            expected_revision: library.file.revision.clone(),
            file: guard(
                library
                    .agents
                    .iter()
                    .find(|row| row.agent_id == agent)
                    .unwrap()
                    .file
                    .as_ref()
                    .unwrap(),
            ),
        })
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
fn guard(file: &InstructionFile) -> FileGuard {
    FileGuard {
        agent_id: file.agent_id.clone(),
        path: file.path.clone(),
        revision: file.revision.clone(),
    }
}
fn enabled(library: &Library, agent: &str) -> bool {
    library
        .agents
        .iter()
        .find(|row| row.agent_id == agent)
        .unwrap()
        .enabled
        == Some(true)
}

#[test]
fn shared_sync_preserves_own_bytes_checks_revisions_and_reports_partial_failures() {
    let fixture = Fixture::new();
    let first = fixture.read();
    assert!(
        !fixture.path.exists(),
        "opening settings must not create any files"
    );
    let locked = fixture.write_lock.try_lock().unwrap();
    assert_eq!(
        fixture
            .run(Action::Save {
                content: "not written".into(),
                expected_revision: first.file.revision.clone(),
                files: vec![]
            })
            .err()
            .unwrap()
            .reason,
        "busy"
    );
    assert!(!fixture.path.exists());
    drop(locked);
    let codex = fixture.profile("codex-acp").unwrap();
    let claude = fixture.profile("claude-acp").unwrap();
    fs::create_dir_all(&codex).unwrap();
    fs::create_dir_all(&claude).unwrap();
    let own_codex = "# 私有规则\r\n无结尾换行";
    fs::write(codex.join("AGENTS.md"), own_codex).unwrap();
    fs::write(claude.join("CLAUDE.md"), "Claude only\n").unwrap();
    let library = fixture.save(&first, "共享中文\nKeep identifiers.");
    assert!(!enabled(&library, "codex-acp"));
    let library = fixture.toggle(&library, "codex-acp", true).unwrap();
    let library = fixture.toggle(&library, "claude-acp", true).unwrap();
    assert!(enabled(&library, "codex-acp") && enabled(&library, "claude-acp"));
    let library = fixture.save(&library, "第二版");
    assert!(library
        .agents
        .iter()
        .all(|row| !row.needs_sync && row.issue.is_none()));
    assert!(fs::read_to_string(codex.join("AGENTS.md"))
        .unwrap()
        .starts_with(own_codex));
    let stale = library;
    fs::write(
        codex.join("AGENTS.md"),
        format!(
            "外部修改{}",
            fs::read_to_string(codex.join("AGENTS.md")).unwrap()
        ),
    )
    .unwrap();
    let library = fixture.save(&stale, "第三版");
    let row = &library.agents[0];
    assert!(row.needs_sync && row.issue.is_some());
    assert!(
        !library.agents[1].needs_sync,
        "another Agent can complete despite one conflict"
    );
    assert_eq!(
        fixture
            .toggle(&stale, "codex-acp", false)
            .err()
            .unwrap()
            .reason,
        "file_changed"
    );
    let library = fixture.save(&library, "第三版");
    assert!(library.agents.iter().all(|row| !row.needs_sync));
    let library = fixture.toggle(&library, "codex-acp", false).unwrap();
    assert!(!enabled(&library, "codex-acp") && enabled(&library, "claude-acp"));
    assert_eq!(
        fs::read_to_string(codex.join("AGENTS.md")).unwrap(),
        format!("外部修改{own_codex}")
    );
    let _ = fixture.toggle(&library, "claude-acp", false).unwrap();
    assert_eq!(
        fs::read_to_string(claude.join("CLAUDE.md")).unwrap(),
        "Claude only\n"
    );
    // Reopening uses disk snapshots; no in-memory preference can claim a stale switch.
    let reopened = fixture.read();
    assert!(reopened.agents.iter().all(|row| row.enabled == Some(false)));
    assert_eq!(reopened.file.content, "第三版");
    fs::write(codex.join("AGENTS.override.md"), "override text").unwrap();
    let library = fixture.read();
    let library = fixture.toggle(&library, "codex-acp", true).unwrap();
    assert!(library.agents[0]
        .file
        .as_ref()
        .unwrap()
        .path
        .ends_with("AGENTS.override.md"));
    let _ = fixture.toggle(&library, "codex-acp", false).unwrap();
    assert_eq!(
        fs::read_to_string(codex.join("AGENTS.override.md")).unwrap(),
        "override text"
    );
    // Malformed or duplicate markers are left untouched and the switch becomes unknown.
    fs::write(claude.join("CLAUDE.md"), BEGIN).unwrap();
    let library = fixture.read();
    assert!(library.agents[1].enabled.is_none() && library.agents[1].issue.is_some());
    assert_eq!(
        fixture
            .toggle(&library, "claude-acp", true)
            .err()
            .unwrap()
            .reason,
        "invalid_markers"
    );
    assert_eq!(fs::read_to_string(claude.join("CLAUDE.md")).unwrap(), BEGIN);
}

#[test]
fn marked_ranges_roundtrip_and_reject_ambiguous_boundaries() {
    for own in ["", "no newline", "ends in LF\n", "CRLF\r\n", "中文\n\n"] {
        for shared in ["", "中文", "line\n", "line\r\n"] {
            let combined = format!("{own}\n{BEGIN}\n{shared}\n{END}\nextra");
            let managed = block(&combined).unwrap().unwrap();
            assert_eq!(managed.text, shared);
            assert_eq!(
                without_block(&combined, Some(&managed)),
                format!("{own}extra")
            );
        }
    }
    for malformed in [
        BEGIN.to_string(),
        END.to_string(),
        format!("\n{BEGIN}\n{BEGIN}\nx\n{END}\n"),
        format!("{BEGIN}\nx\n{END}"),
    ] {
        assert!(block(&malformed).is_err());
    }
    assert!(validate_text(BEGIN).is_err());
    assert!(validate_text(&"x".repeat(MAX_BYTES + 1)).is_err());
    let request: Request =
        serde_json::from_value(serde_json::json!({"dataDirectory":"/fixture", "action":"read"}))
            .unwrap();
    assert!(matches!(request.action, Action::Read {}));
}
