use super::*;

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("lithe-instructions-{}", uuid::Uuid::new_v4())))
    }
    fn write(&self, name: &str, bytes: &[u8]) {
        fs::create_dir_all(&self.0).unwrap();
        fs::write(self.0.join(name), bytes).unwrap();
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn request(file: &InstructionFile, content: &str) -> SaveRequest {
    SaveRequest {
        agent_id: file.agent_id.clone(),
        content: content.into(),
        expected_path: file.path.clone(),
        expected_revision: file.revision.clone(),
    }
}

#[test]
fn native_sources_follow_override_and_agent_boundaries_without_creating_files() {
    let directory = Directory::new();
    let empty = read_in("codex-acp", &directory.0).unwrap();
    assert!(!empty.exists);
    assert!(!directory.0.exists(), "opening settings is read only");
    directory.write("AGENTS.md", "base 中文\n".as_bytes());
    directory.write("CLAUDE.md", b"claude");
    directory.write("AGENTS.override.md", b" \n");
    assert_eq!(
        read_in("codex-acp", &directory.0).unwrap().content,
        "base 中文\n"
    );
    directory.write("AGENTS.override.md", b"override");
    assert_eq!(
        read_in("codex-acp", &directory.0).unwrap().content,
        "override"
    );
    assert_eq!(
        read_in("claude-acp", &directory.0).unwrap().content,
        "claude"
    );
    assert_eq!(
        read_in("custom", &directory.0).unwrap_err().reason,
        "unsupported_agent"
    );
}

#[test]
fn save_roundtrip_guards_external_edits_and_native_precedence() {
    // All saves in this case share the native save lock; no environment mutation.
    let directory = Directory::new();
    let missing = read_in("codex-acp", &directory.0).unwrap();
    let saved = save_in(request(&missing, "中文\r\nexact bytes\n"), &directory.0).unwrap();
    assert_eq!(saved.content, "中文\r\nexact bytes\n");
    assert!(saved.exists);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&saved.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&directory.0).unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::set_permissions(&saved.path, fs::Permissions::from_mode(0o640)).unwrap();
    }
    let updated = save_in(request(&saved, "base"), &directory.0).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&updated.path).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
    let original_permissions = fs::metadata(&updated.path).unwrap().permissions();
    let mut readonly = original_permissions.clone();
    readonly.set_readonly(true);
    fs::set_permissions(&updated.path, readonly).unwrap();
    assert_eq!(
        save_in(request(&updated, "read only overwrite"), &directory.0)
            .unwrap_err()
            .reason,
        "file_access"
    );
    assert_eq!(fs::read_to_string(&updated.path).unwrap(), "base");
    fs::set_permissions(&updated.path, original_permissions).unwrap();
    directory.write("AGENTS.md", b"external edit");
    assert_eq!(
        save_in(request(&updated, "overwrite"), &directory.0)
            .unwrap_err()
            .reason,
        "file_changed"
    );
    assert_eq!(fs::read_to_string(&updated.path).unwrap(), "external edit");
    directory.write("AGENTS.override.md", b"override");
    assert_eq!(
        save_in(request(&updated, "overwrite"), &directory.0)
            .unwrap_err()
            .reason,
        "file_changed"
    );
    let active = read_in("codex-acp", &directory.0).unwrap();
    let effective = save_in(request(&active, ""), &directory.0).unwrap();
    assert!(effective.path.ends_with("AGENTS.md"));
    assert_eq!(effective.content, "external edit");
    let cleared = save_in(request(&effective, ""), &directory.0).unwrap();
    assert_eq!(cleared.content, "");
    let claude = read_in("claude-acp", &directory.0).unwrap();
    let claude = save_in(request(&claude, "Claude only"), &directory.0).unwrap();
    assert_eq!(claude.content, "Claude only");
    assert_eq!(read_in("codex-acp", &directory.0).unwrap().content, "");
    let mut wrong_path = request(&claude, "bad");
    wrong_path.expected_path = directory.0.join("arbitrary.md");
    assert_eq!(
        save_in(wrong_path, &directory.0).unwrap_err().reason,
        "file_changed"
    );
    let oversized = "x".repeat(MAX_BYTES + 1);
    assert_eq!(
        save_in(request(&claude, &oversized), &directory.0)
            .unwrap_err()
            .reason,
        "file_too_large"
    );
    assert!(!fs::read_dir(&directory.0).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".lithe-")));
}

#[test]
fn profile_resolution_respects_explicit_configuration_and_rejects_relative_paths() {
    let directory = Directory::new();
    assert_eq!(
        resolve_profile(Some(directory.0.clone()), None).unwrap(),
        directory.0
    );
    assert_eq!(
        resolve_profile(None, Some(directory.0.clone())).unwrap(),
        directory.0
    );
    assert_eq!(
        resolve_profile(Some(PathBuf::from("relative")), Some(directory.0.clone()))
            .unwrap_err()
            .reason,
        "profile_relative"
    );
    assert_eq!(
        resolve_profile(None, None).unwrap_err().reason,
        "profile_missing"
    );
}

#[test]
fn rejects_non_text_and_non_regular_files_and_distinguishes_absence() {
    let directory = Directory::new();
    let absent = read_in("claude-acp", &directory.0).unwrap();
    directory.write("CLAUDE.md", b"");
    assert_ne!(
        read_in("claude-acp", &directory.0).unwrap().revision,
        absent.revision
    );
    directory.write("CLAUDE.md", &[0xff]);
    assert_eq!(
        read_in("claude-acp", &directory.0).unwrap_err().reason,
        "invalid_utf8"
    );
    directory.write("CLAUDE.md", &vec![b'x'; MAX_BYTES + 1]);
    assert_eq!(
        read_in("claude-acp", &directory.0).unwrap_err().reason,
        "file_too_large"
    );
    fs::remove_file(directory.0.join("CLAUDE.md")).unwrap();
    fs::create_dir(directory.0.join("CLAUDE.md")).unwrap();
    assert_eq!(
        read_in("claude-acp", &directory.0).unwrap_err().reason,
        "unsafe_file"
    );
    #[cfg(unix)]
    {
        fs::remove_dir(directory.0.join("CLAUDE.md")).unwrap();
        directory.write("target.md", b"keep");
        std::os::unix::fs::symlink(directory.0.join("target.md"), directory.0.join("CLAUDE.md"))
            .unwrap();
        assert_eq!(
            read_in("claude-acp", &directory.0).unwrap_err().reason,
            "unsafe_file"
        );
        assert_eq!(fs::read(directory.0.join("target.md")).unwrap(), b"keep");
    }
}
