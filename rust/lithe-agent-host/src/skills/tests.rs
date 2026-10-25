use super::*;
use std::fs;
use std::time::Duration;

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("lithe-skills-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join("home")).unwrap();
        fs::create_dir_all(root.join("project")).unwrap();
        Self(fs::canonicalize(root).unwrap())
    }
    fn run(&self, payload: Value) -> Result<Value, Error> {
        let mut payload = payload;
        payload["workspace"] = json!(self.0.join("project"));
        execute_at(
            serde_json::from_value(payload).unwrap(),
            &self.0.join("home"),
            &self.0.join("home/.claude"),
            &|| false,
        )
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn create(agent: &str, scope: &str, name: &str) -> Value {
    json!({"action":"create", "agentId":agent, "scope":scope, "name":name,
        "description":"Use for Unicode 中文, quotes \" and newlines\nonly", "instructions":"# Workflow\n\n1. Inspect\n2. Explain"})
}

#[test]
fn claude_toggles_preserve_documents_other_settings_and_scope() {
    let fixture = Sandbox::new();
    let user = fixture
        .run(create("claude-acp", "user", "same-name"))
        .unwrap();
    let repo = fixture
        .run(create("claude-acp", "repo", "same-name"))
        .unwrap();
    let user_settings = fixture.0.join("home/.claude/settings.json");
    let local_settings = fixture.0.join("project/.claude/settings.local.json");
    fs::write(
        &user_settings,
        r#"{"env":{"EXAMPLE":"keep"},"skillOverrides":{"unrelated":"name-only"}}"#,
    )
    .unwrap();
    let document = fs::read(user["path"].as_str().unwrap()).unwrap();
    let toggle = |scope: &str, source: &Value, enabled: bool| {
        fixture.run(json!({"action":"setEnabled", "agentId":"claude-acp", "scope":scope,"source":source,"enabled":enabled}))
    };
    let result = toggle("user", &user["path"], false).unwrap();
    assert!(result["skills"]
        .as_array()
        .unwrap()
        .iter()
        .all(|skill| skill["enabled"] == false));
    assert!(
        !local_settings.exists(),
        "a global toggle must not write project settings"
    );
    let result = toggle("repo", &repo["path"], true).unwrap();
    assert!(result["skills"]
        .as_array()
        .unwrap()
        .iter()
        .all(|skill| skill["enabled"] == (skill["scope"] == "repo")));
    assert!(!fixture.0.join("project/.claude/settings.json").exists());
    toggle("user", &user["path"], true).unwrap();
    let config: Value = serde_json::from_slice(&fs::read(user_settings).unwrap()).unwrap();
    assert_eq!(config["env"]["EXAMPLE"], "keep");
    assert_eq!(config["skillOverrides"]["unrelated"], "name-only");
    assert_eq!(config["skillOverrides"]["same-name"], "on");
    assert_eq!(fs::read(user["path"].as_str().unwrap()).unwrap(), document);
}

#[test]
fn claude_invalid_settings_are_never_replaced_and_hide_unknown_state() {
    let fixture = Sandbox::new();
    let result = fixture
        .run(create("claude-acp", "repo", "test-skill"))
        .unwrap();
    let target = fixture.0.join("project/.claude/settings.local.json");
    for invalid in [
        "invalid JSON",
        "[]",
        r#"{"skillOverrides":[]}"#,
        r#"{"skillOverrides":{"other":"unexpected"}}"#,
    ] {
        fs::write(&target, invalid).unwrap();
        let listing = fixture
            .run(json!({"action":"list","agentId":"claude-acp"}))
            .unwrap();
        assert_eq!(listing["skills"][0]["enabled"], Value::Null);
        assert!(!listing["issues"].as_array().unwrap().is_empty());
        assert!(fixture.run(json!({"action":"setEnabled","agentId":"claude-acp","scope":"repo","source":result["path"],"enabled":false})).is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), invalid);
    }
}

#[test]
fn claude_toggles_reject_missing_or_foreign_paths_and_missing_state() {
    let fixture = Sandbox::new();
    let result = fixture
        .run(create("claude-acp", "repo", "test-skill"))
        .unwrap();
    for payload in [
        json!({"action":"setEnabled","agentId":"claude-acp","scope":"repo","source":result["path"]}),
        json!({"action":"setEnabled","agentId":"claude-acp","scope":"user","source":result["path"],"enabled":false}),
        json!({"action":"setEnabled","agentId":"claude-acp","scope":"repo","source":fixture.0.join("foreign/SKILL.md"),"enabled":false}),
    ] {
        assert!(fixture.run(payload).is_err());
    }
    assert!(!fixture
        .0
        .join("project/.claude/settings.local.json")
        .exists());
}

#[test]
fn claude_settings_cancel_and_busy_lock_never_change_existing_bytes() {
    use fs2::FileExt;
    let fixture = Sandbox::new();
    let target = fixture.0.join("home/.claude/settings.json");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    fs::write(&target, "{\"other\":true}").unwrap();
    assert!(settings::write_override(&target, "test", false, &|| true).is_err());
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(target.parent().unwrap().join(".lithe-skill-settings.lock"))
        .unwrap();
    lock.try_lock_exclusive().unwrap();
    assert!(settings::write_override(&target, "test", false, &|| false).is_err());
    drop(lock);
    assert_eq!(fs::read_to_string(&target).unwrap(), "{\"other\":true}");
    assert_eq!(
        fs::read_dir(target.parent().unwrap()).unwrap().count(),
        2,
        "no temporary settings survive failure"
    );
}

#[cfg(unix)]
#[test]
fn claude_settings_reject_symlinks_and_preserve_permissions() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let fixture = Sandbox::new();
    let target = fixture.0.join("home/.claude/settings.json");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    let outside = fixture.0.join("outside.json");
    fs::write(&outside, "{}").unwrap();
    symlink(&outside, &target).unwrap();
    assert!(settings::write_override(&target, "test", false, &|| false).is_err());
    assert_eq!(fs::read_to_string(&outside).unwrap(), "{}");
    fs::remove_file(&target).unwrap();
    fs::write(&target, "{}").unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o640)).unwrap();
    settings::write_override(&target, "test", false, &|| false).unwrap();
    assert_eq!(
        fs::metadata(&target).unwrap().permissions().mode() & 0o777,
        0o640
    );
}
const DOCUMENT: &str =
    "---\nname: sample-skill\ndescription: Test skill\n---\n\nRead the supporting files.\n";

#[test]
fn create_is_native_scoped_non_overwriting_and_round_trips_document() {
    let fixture = Sandbox::new();
    for agent in ["codex-acp", "claude-acp"] {
        for scope in ["user", "repo"] {
            let result = fixture.run(create(agent, scope, "new-skill")).unwrap();
            let path = PathBuf::from(result["path"].as_str().unwrap());
            let parent = if scope == "user" {
                fixture.0.join("home")
            } else {
                fixture.0.join("project")
            };
            assert!(path.starts_with(parent));
            assert!(path.to_string_lossy().contains(if agent == "codex-acp" {
                ".agents"
            } else {
                ".claude"
            }));
            let bytes = fs::read(&path).unwrap();
            let parsed = files::read_document(&path).unwrap();
            assert!(parsed.contains("中文"));
            assert_eq!(files::metadata(&bytes, "").unwrap().0, "new-skill");
            assert!(fixture.run(create(agent, scope, "new-skill")).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
}

#[test]
fn import_keeps_full_package_and_never_changes_the_source() {
    let fixture = Sandbox::new();
    let source = fixture.0.join("external");
    fs::create_dir_all(source.join("scripts")).unwrap();
    fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
    fs::write(source.join("scripts/helper.sh"), "#!/bin/sh\nexit 0\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            source.join("scripts/helper.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
    }
    let result = fixture
        .run(json!({"action":"import", "agentId":"codex-acp", "scope":"repo", "source":source}))
        .unwrap();
    let copied = PathBuf::from(result["path"].as_str().unwrap());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(copied.parent().unwrap().join("scripts/helper.sh"))
                .unwrap()
                .permissions()
                .mode(),
            fs::metadata(source.join("scripts/helper.sh"))
                .unwrap()
                .permissions()
                .mode()
        );
    }
    assert_eq!(fs::read(&copied).unwrap(), DOCUMENT.as_bytes());
    assert_eq!(
        fs::read(copied.parent().unwrap().join("scripts/helper.sh")).unwrap(),
        fs::read(source.join("scripts/helper.sh")).unwrap()
    );
    assert_eq!(
        fs::read(source.join("SKILL.md")).unwrap(),
        DOCUMENT.as_bytes()
    );
    assert!(fixture
        .run(json!({"action":"import", "agentId":"codex-acp", "scope":"repo", "source":source}))
        .is_err());
}

#[test]
fn single_file_import_and_claude_directory_fallback_are_supported() {
    let fixture = Sandbox::new();
    let source = fixture.0.join("SKILL.md");
    fs::write(&source, DOCUMENT).unwrap();
    assert!(fixture
        .run(json!({"action":"import", "agentId":"claude-acp", "scope":"user", "source":source}))
        .is_ok());
    let directory = fixture.0.join("folder-skill");
    fs::create_dir(&directory).unwrap();
    fs::write(
        directory.join("SKILL.md"),
        "---\ndescription: Folder fallback\n---\n\nInstructions\n",
    )
    .unwrap();
    assert!(fixture
        .run(json!({"action":"import", "agentId":"codex-acp", "scope":"user", "source":directory}))
        .is_err());
    let result = fixture
        .run(json!({"action":"import", "agentId":"claude-acp", "scope":"user", "source":directory}))
        .unwrap();
    assert!(result["path"].as_str().unwrap().contains("folder-skill"));
}

#[test]
fn directory_inventory_reports_configured_visibility_and_malformed_issues() {
    let fixture = Sandbox::new();
    fixture
        .run(create("claude-acp", "user", "user-skill"))
        .unwrap();
    fixture
        .run(create("claude-acp", "repo", "project-skill"))
        .unwrap();
    let bad = fixture.0.join("project/.claude/skills/broken");
    fs::create_dir(&bad).unwrap();
    fs::write(bad.join("SKILL.md"), "---\nname: [invalid\n---\n").unwrap();
    let result = fixture
        .run(json!({"action":"list", "agentId":"claude-acp"}))
        .unwrap();
    assert_eq!(result["source"], "directory");
    assert_eq!(result["skills"].as_array().unwrap().len(), 2);
    assert!(result["skills"]
        .as_array()
        .unwrap()
        .iter()
        .all(|row| row["enabled"] == true));
    assert_eq!(result["issues"].as_array().unwrap().len(), 1);
    let directory = PathBuf::from(result["directories"]["repo"].as_str().unwrap());
    assert!(directory.ends_with(PathBuf::from(".claude").join("skills")));
}

#[test]
fn invalid_names_yaml_and_missing_workspace_do_not_publish_any_skill() {
    let fixture = Sandbox::new();
    for name in ["../escape", "UPPER", "", "a--b", "/absolute", "a/b"] {
        assert!(fixture.run(create("codex-acp", "repo", name)).is_err());
    }
    let payload = create("codex-acp", "repo", "valid-name");
    assert!(execute_at(
        serde_json::from_value(payload).unwrap(),
        &fixture.0.join("home"),
        &fixture.0.join("home/.claude"),
        &|| false
    )
    .is_err());
    let source = fixture.0.join("SKILL.md");
    for text in [
        "No frontmatter",
        "---\nname: no-close",
        "---\n[]\n---\n",
        "---\nname: test\n---\nBody",
    ] {
        fs::write(&source, text).unwrap();
        assert!(fixture
            .run(json!({"action":"import", "agentId":"codex-acp", "scope":"user", "source":source}))
            .is_err());
    }
    assert!(!fixture.0.join("project/.agents").exists());
}

#[cfg(unix)]
#[test]
fn linked_destinations_and_import_resources_are_rejected_without_partial_publish() {
    use std::os::unix::fs::symlink;
    let fixture = Sandbox::new();
    let outside = fixture.0.join("outside");
    fs::create_dir(&outside).unwrap();
    symlink(&outside, fixture.0.join("project/.agents")).unwrap();
    assert!(fixture
        .run(create("codex-acp", "repo", "linked-skill"))
        .is_err());
    assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
    let source = fixture.0.join("package");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
    symlink(&outside, source.join("assets")).unwrap();
    assert!(fixture
        .run(json!({"action":"import", "agentId":"codex-acp", "scope":"user", "source":source}))
        .is_err());
    let root = fixture.0.join("home/.agents/skills");
    assert_eq!(
        fs::read_dir(root).unwrap().count(),
        0,
        "failed import cleans staging and publishes nothing"
    );
}

#[test]
fn cancel_during_package_copy_cleans_staging_and_preserves_existing_skill() {
    let fixture = Sandbox::new();
    fixture
        .run(create("codex-acp", "user", "existing"))
        .unwrap();
    let source = fixture.0.join("package");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
    fs::write(source.join("other.txt"), "resource").unwrap();
    let calls = std::cell::Cell::new(0);
    let cancel = || {
        calls.set(calls.get() + 1);
        calls.get() >= 5
    };
    let request: Request = serde_json::from_value(
        json!({"action":"import", "agentId":"codex-acp", "scope":"user", "source":source}),
    )
    .unwrap();
    assert!(matches!(
        execute_at(
            request,
            &fixture.0.join("home"),
            &fixture.0.join("home/.claude"),
            &cancel
        ),
        Err(Error::Cancelled)
    ));
    let root = fixture.0.join("home/.agents/skills");
    assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
    assert!(root.join("existing/SKILL.md").is_file());
}

#[test]
fn publication_cannot_replace_an_existing_empty_directory() {
    let fixture = Sandbox::new();
    let source = fixture.0.join("stage");
    let target = fixture.0.join("target");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
    // The final native move must reject a destination created after staging,
    // even when the competing directory is empty.
    fs::create_dir(&target).unwrap();
    assert!(files::publish(&source, &target).is_err());
    assert_eq!(fs::read_dir(target).unwrap().count(), 0);
    assert!(source.join("SKILL.md").is_file());
}

#[test]
fn publication_preserves_existing_files_and_directory_contents() {
    for directory in [false, true] {
        let fixture = Sandbox::new();
        let source = fixture.0.join("stage");
        let target = fixture.0.join("target");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
        let existing = if directory {
            fs::create_dir(&target).unwrap();
            target.join("keep.txt")
        } else {
            target.clone()
        };
        fs::write(&existing, "keep existing bytes").unwrap();
        assert!(files::publish(&source, &target).is_err());
        assert_eq!(fs::read_to_string(existing).unwrap(), "keep existing bytes");
        assert_eq!(
            fs::read_to_string(source.join("SKILL.md")).unwrap(),
            DOCUMENT
        );
    }
}

#[test]
fn publication_moves_a_complete_package_to_a_missing_unicode_destination() {
    let fixture = Sandbox::new();
    let source = fixture.0.join("stage with spaces");
    let target = fixture.0.join("skill 中文");
    fs::create_dir_all(source.join("scripts")).unwrap();
    fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
    fs::write(source.join("scripts/example.txt"), "resource bytes").unwrap();
    files::publish(&source, &target).unwrap();
    assert!(!source.exists());
    assert_eq!(
        fs::read_to_string(target.join("SKILL.md")).unwrap(),
        DOCUMENT
    );
    assert_eq!(
        fs::read_to_string(target.join("scripts/example.txt")).unwrap(),
        "resource bytes"
    );
}

#[cfg(windows)]
#[test]
fn publication_rejects_nul_paths_without_publishing_the_truncated_name() {
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    let fixture = Sandbox::new();
    let source = fixture.0.join("stage");
    let prefix = fixture.0.join("target");
    let mut name: Vec<u16> = prefix.as_os_str().encode_wide().collect();
    name.extend([0, b'x' as u16]);
    let target = PathBuf::from(std::ffi::OsString::from_wide(&name));
    fs::create_dir(&source).unwrap();
    fs::write(source.join("SKILL.md"), DOCUMENT).unwrap();
    assert!(files::publish(&source, &target).is_err());
    assert!(!prefix.exists());
    assert_eq!(
        fs::read_to_string(source.join("SKILL.md")).unwrap(),
        DOCUMENT
    );
}

#[test]
fn native_response_keeps_disabled_scope_and_rejects_foreign_workspace() {
    let fixture = Sandbox::new();
    let cwd = fixture.0.join("project");
    let value = json!({"data":[{"cwd":cwd, "skills":[
        {"name":"native-skill", "description":"Reported", "path":fixture.0.join("SKILL.md"), "scope":"system", "enabled":false}],"errors":[]}]});
    let listing = parse_codex(&value, &cwd).unwrap();
    assert_eq!(listing.skills[0].enabled, Some(false));
    assert_eq!(listing.skills[0].scope, "system");
    assert!(parse_codex(&value, &fixture.0.join("foreign")).is_err());
}

#[cfg(unix)]
#[tokio::test]
async fn native_discovery_uses_the_selected_account_directory() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Sandbox::new();
    let executable = fixture.0.join("fake-codex");
    let home = fixture.0.join("account");
    let response = json!({"data":[{"cwd":fixture.0.join("project"), "skills":[], "errors":[]}]});
    let script = format!("#!/bin/sh\nprintf '%s' \"$CODEX_HOME\" > '{}'/home.log\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *'\"method\":\"initialize\"'*) printf '%s\\n' '{{\"id\":1,\"result\":{{}}}}' ;;\n    *'\"method\":\"skills/list\"'*) printf '%s\\n' '{{\"id\":2,\"result\":{response}}}' ;;\n  esac\ndone\n", fixture.0.display());
    fs::write(&executable, script).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    tokio::time::timeout(
        Duration::from_secs(5),
        CodexHistory::skills(executable, fixture.0.join("project"), Some(home.clone()), &|| false),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(fs::read_to_string(fixture.0.join("home.log")).unwrap(), home.to_str().unwrap());
}

#[cfg(unix)]
#[tokio::test]
async fn native_discovery_only_initializes_and_lists_without_creating_or_prompting() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Sandbox::new();
    let executable = fixture.0.join("fake-codex");
    let response = json!({"data":[{"cwd":fixture.0.join("project"), "skills":[], "errors":[]}]});
    let script = format!("#!/bin/sh\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> '{}'/requests.log\n  case \"$line\" in\n    *'\"method\":\"initialize\"'*) printf '%s\\n' '{{\"id\":1,\"result\":{{}}}}' ;;\n    *'\"method\":\"skills/list\"'*) printf '%s\\n' '{{\"id\":2,\"result\":{response}}}' ;;\n  esac\ndone\n", fixture.0.display());
    fs::write(&executable, script).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(5),
        CodexHistory::skills(executable, fixture.0.join("project"), None, &|| false),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, response);
    let requests: Vec<Value> = fs::read_to_string(fixture.0.join("requests.log"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        requests
            .iter()
            .map(|row| row["method"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["initialize", "initialized", "skills/list"]
    );
    assert_eq!(requests[2]["params"]["forceReload"], true);
}

#[cfg(unix)]
#[tokio::test]
async fn native_toggle_validates_path_writes_native_config_and_reads_back() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Sandbox::new();
    let executable = fixture.0.join("fake-codex");
    let path = fixture.0.join("project/.agents/skills/test/SKILL.md");
    let listing = |enabled| json!({"data":[{"cwd":fixture.0.join("project"),"skills":[{"name":"test","description":"Test","path":path,"scope":"repo","enabled":enabled}],"errors":[]}]});
    let script = format!("#!/bin/sh\nwhile IFS= read -r line; do\n printf '%s\\n' \"$line\" >> '{}'/requests.log\n case \"$line\" in\n *'\"method\":\"initialize\"'*) printf '%s\\n' '{{\"id\":1,\"result\":{{}}}}' ;;\n *'\"id\":2,'*) printf '%s\\n' '{{\"id\":2,\"result\":{}}}' ;;\n *'\"id\":3,'*) printf '%s\\n' '{{\"id\":3,\"result\":{{}}}}' ;;\n *'\"id\":4,'*) printf '%s\\n' '{{\"id\":4,\"result\":{}}}' ;;\n esac\ndone\n", fixture.0.display(), listing(true), listing(false));
    fs::write(&executable, script).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(5),
        CodexHistory::set_skill_enabled(
            executable.clone(),
            fixture.0.join("project"),
            path.clone(),
            false,
            None,
            &|| false,
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, listing(false));
    let requests: Vec<Value> = fs::read_to_string(fixture.0.join("requests.log"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        requests
            .iter()
            .map(|row| row["method"].as_str().unwrap())
            .collect::<Vec<_>>(),
        [
            "initialize",
            "initialized",
            "skills/list",
            "skills/config/write",
            "skills/list"
        ]
    );
    assert_eq!(requests[3]["params"], json!({"path":path,"enabled":false}));
    fs::remove_file(fixture.0.join("requests.log")).unwrap();
    let rejected = tokio::time::timeout(
        Duration::from_secs(5),
        CodexHistory::set_skill_enabled(
            executable,
            fixture.0.join("project"),
            fixture.0.join("foreign/SKILL.md"),
            false,
            None,
            &|| false,
        ),
    )
    .await
    .unwrap();
    assert_eq!(rejected, Err("unknown skill"));
    assert!(!fs::read_to_string(fixture.0.join("requests.log"))
        .unwrap()
        .contains("skills/config/write"));
}

#[cfg(unix)]
#[test]
fn shared_skill_fixture_preserves_native_scopes_plugins_and_disabled_state() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/agent/skills-management-v1.json"
    ))
    .unwrap();
    let listing = parse_codex(&fixture["nativeCodex"], Path::new("/fixture/workspace")).unwrap();
    assert_eq!(
        serde_json::to_value(listing).unwrap(),
        fixture["normalizedCodex"]
    );
}

#[test]
fn oversized_import_is_bounded_and_never_published() {
    let fixture = Sandbox::new();
    let source = fixture.0.join("SKILL.md");
    let file = fs::File::create(&source).unwrap();
    file.set_len(8 * 1024 * 1024 + 1).unwrap();
    assert!(fixture
        .run(json!({"action":"import", "agentId":"codex-acp", "scope":"user", "source":source}))
        .is_err());
    assert!(!fixture.0.join("home/.agents").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn cancelled_discovery_reaps_the_probe_even_while_initialization_is_stalled() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Sandbox::new();
    let executable = fixture.0.join("stalled-codex");
    let pid_file = fixture.0.join("probe.pid");
    fs::write(
        &executable,
        format!(
            "#!/bin/sh\nprintf '%s' \"$$\" > '{}'\nwhile IFS= read -r line; do :; done\n",
            pid_file.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    // The child announces startup before the cancellation check becomes true.
    // No real-time sleep coordinates the test; the production poll remains bounded.
    let cancelled = || pid_file.exists();
    let result = tokio::time::timeout(
        Duration::from_secs(5),
        CodexHistory::skills(executable, fixture.0.join("project"), None, &cancelled),
    )
    .await
    .unwrap();
    assert_eq!(result, Err("cancelled"));
    let pid: i32 = fs::read_to_string(pid_file).unwrap().parse().unwrap();
    // A terminated but unreaped child would still answer kill(pid, 0).
    assert_eq!(
        unsafe { libc::kill(pid, 0) },
        -1,
        "probe must be reaped before discovery returns"
    );
}
