//! 读取与编辑用户自己的 Maven 设置（`~/.m2/settings.xml`）。
//!
//! 这是 Maven 的原生用户级配置，不是 Lithe 的私有副本：每个项目和命令行构建
//! 都会读它，因此设置页在没有项目打开时也能编辑。只编辑 `<localRepository>`；
//! mirrors、servers 及其凭据不会返回给界面。写入时带上基于的 revision，
//! 若期间被其他程序修改过则拒绝，避免过期页面覆盖用户的文件。
//!
//! 结构与错误前缀照抄 Tauri 宿主版 `windows/tauri/src-tauri/src/maven/user_settings.rs`；
//! 文档改写复用共享 Core 的 `lithe_core::settings_with_local_repository`。

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use quick_xml::events::Event;
use quick_xml::Reader;

// 错误前缀由界面翻译；其余内容是操作系统诊断文本。
/// 页面读取后文件又被改动了。
pub(crate) const CONFLICT_ERROR: &str = "mavenUserSettingsChanged";
/// 文件不是合法的 UTF-8 settings 文档。
pub(crate) const INVALID_ERROR: &str = "mavenUserSettingsInvalid";
/// 没有填写仓库路径。
pub(crate) const EMPTY_ERROR: &str = "mavenUserSettingsEmptyRepository";
/// 无法确定拥有 `.m2` 的用户主目录。
pub(crate) const NO_HOME_ERROR: &str = "mavenUserSettingsNoHome";

/// 新建文件从 Maven 官方文档给出的最小 settings 文档开始。
const NEW_SETTINGS_DOCUMENT: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<settings xmlns=\"http://maven.apache.org/SETTINGS/1.2.0\">\n</settings>\n";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenUserSettingsSnapshot {
    /// Maven 读取的用户级设置路径。
    pub path: String,
    pub status: MavenUserSettingsStatus,
    /// `<localRepository>` 的原文（未展开 `${user.home}`）。
    pub local_repository: Option<String>,
    /// settings 未声明任何仓库时 Maven 内置的默认仓库。
    pub default_local_repository: String,
    /// 下一次写入必须匹配的内容标识；文件不存在时为 `None`。
    pub revision: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MavenUserSettingsStatus {
    Missing,
    Readable,
    /// 文件存在但不是合法的 settings 文档。
    Invalid,
}

/// 跨平台解析用户主目录；与 `configuration::user_home` 的候选链一致。
pub(crate) fn user_home() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .filter(|home| !home.as_os_str().is_empty())
        .ok_or_else(|| NO_HOME_ERROR.to_string())
}

fn settings_path(home: &Path) -> PathBuf {
    home.join(".m2").join("settings.xml")
}

fn revision(contents: &[u8]) -> String {
    format!("{:x}", Sha256::digest(contents))
}

pub(crate) fn read(home: &Path) -> Result<MavenUserSettingsSnapshot, String> {
    let path = settings_path(home);
    let default_local_repository = home.join(".m2").join("repository");
    let mut settings = MavenUserSettingsSnapshot {
        path: path.to_string_lossy().into_owned(),
        status: MavenUserSettingsStatus::Missing,
        local_repository: None,
        default_local_repository: default_local_repository.to_string_lossy().into_owned(),
        revision: None,
    };
    let contents = match fs::read(&path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(settings),
        // 读不了的文件不能伪装成空文件。
        Err(error) => return Err(error.to_string()),
    };
    settings.revision = Some(revision(&contents));
    match std::str::from_utf8(&contents)
        .ok()
        .map(|text| read_local_repository(text.trim_start_matches('\u{feff}')))
    {
        Some(Ok(local_repository)) => {
            settings.status = MavenUserSettingsStatus::Readable;
            settings.local_repository = local_repository;
        }
        _ => settings.status = MavenUserSettingsStatus::Invalid,
    }
    Ok(settings)
}

pub(crate) fn write_local_repository(
    home: &Path,
    local_repository: &str,
    expected_revision: Option<&str>,
) -> Result<MavenUserSettingsSnapshot, String> {
    let local_repository = local_repository.trim();
    if local_repository.is_empty() {
        return Err(EMPTY_ERROR.into());
    }
    let path = settings_path(home);
    let current = match fs::read(&path) {
        Ok(contents) => Some(contents),
        Err(error) if error.kind() == ErrorKind::NotFound => None,
        Err(error) => return Err(error.to_string()),
    };
    if current.as_deref().map(revision).as_deref() != expected_revision {
        return Err(CONFLICT_ERROR.into());
    }
    let source = match &current {
        Some(contents) => std::str::from_utf8(contents)
            .map_err(|_| INVALID_ERROR.to_string())?
            .to_string(),
        None => NEW_SETTINGS_DOCUMENT.to_string(),
    };
    // 保留用户编辑器写入的 BOM。
    let (bom, document) = match source.strip_prefix('\u{feff}') {
        Some(rest) => ("\u{feff}", rest),
        None => ("", source.as_str()),
    };
    // 写入器是流式事件处理，未闭合元素会被原样带过去，先校验一遍。
    if read_local_repository(document).is_err() {
        return Err(INVALID_ERROR.into());
    }
    let rewritten = lithe_core::settings_with_local_repository(document, local_repository)
        .map_err(|error| {
            format!(
                "{INVALID_ERROR}: {}",
                error.details.unwrap_or(error.message)
            )
        })?;
    // settings 文件常被放进 dotfiles 仓库并做成链接；把链接替换成普通文件
    // 会让它脱离那个仓库，因此沿链接写入真实目标。
    let target = if current.is_some() {
        fs::canonicalize(&path).map_err(|error| error.to_string())?
    } else {
        path.clone()
    };
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    // 先写同目录临时文件再 rename（与 AppSettings::save 的原子写一致）。
    let temporary = target.with_extension("xml.tmp");
    fs::write(&temporary, format!("{bom}{rewritten}").as_bytes())
        .map_err(|error| error.to_string())?;
    fs::rename(&temporary, &target).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        error.to_string()
    })?;
    read(home)
}

/// 文档不是合法的 Maven settings 文件。
#[derive(Debug, PartialEq, Eq)]
pub(super) struct InvalidSettings;

/// 读取顶层 `<localRepository>`；区分「未声明」（`Ok(None)`）与「不是合法
/// settings 文档」（`Err`）。不能改写一个读不出来的文件。
///
/// 与 Tauri `maven/settings_xml.rs` 同一语义：命名空间前缀按本地名匹配、
/// 只读 settings 的直接子元素、拒绝 DOCTYPE 与未闭合文档。
pub(crate) fn read_local_repository(settings: &str) -> Result<Option<String>, InvalidSettings> {
    let mut reader = Reader::from_str(settings);
    reader.config_mut().expand_empty_elements = true;
    reader.config_mut().check_comments = true;
    let mut depth: usize = 0;
    let mut root_seen = false;
    let mut collecting = false;
    let mut repository: Option<String> = None;

    // 读到 EOF：未闭合结束标签前出现的合法路径不能当成有效值。
    loop {
        match reader.read_event().map_err(|_| InvalidSettings)? {
            Event::Start(element) => {
                for attribute in element.attributes() {
                    attribute.map_err(|_| InvalidSettings)?;
                }
                if depth == 0 {
                    if root_seen || element.local_name().as_ref() != b"settings" {
                        return Err(InvalidSettings);
                    }
                    root_seen = true;
                } else if collecting {
                    return Err(InvalidSettings);
                } else if depth == 1 && element.local_name().as_ref() == b"localRepository" {
                    if repository.is_some() {
                        return Err(InvalidSettings);
                    }
                    repository = Some(String::new());
                    collecting = true;
                }
                depth += 1;
            }
            Event::End(_) => {
                depth = depth.checked_sub(1).ok_or(InvalidSettings)?;
                if depth == 1 {
                    collecting = false;
                }
            }
            Event::Text(text) => {
                let text = text.unescape().map_err(|_| InvalidSettings)?;
                if collecting {
                    repository.as_mut().ok_or(InvalidSettings)?.push_str(&text);
                } else if depth == 0 && !text.trim().is_empty() {
                    return Err(InvalidSettings);
                }
            }
            Event::CData(text) => {
                if depth == 0 {
                    return Err(InvalidSettings);
                }
                if collecting {
                    repository
                        .as_mut()
                        .ok_or(InvalidSettings)?
                        .push_str(&text.decode().map_err(|_| InvalidSettings)?);
                }
            }
            // 不展开外部实体，也不尝试读 DTD。
            Event::DocType(_) => return Err(InvalidSettings),
            Event::Eof => break,
            _ => {}
        }
    }
    if depth != 0 || !root_seen {
        return Err(InvalidSettings);
    }
    Ok(repository
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_home() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "lithe-gpui-maven-user-settings-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir(&path).expect("temporary home");
        path
    }

    #[test]
    fn a_missing_file_reports_maven_defaults_without_creating_anything() {
        let home = temporary_home();
        let settings = read(&home).expect("read");
        assert_eq!(settings.status, MavenUserSettingsStatus::Missing);
        assert_eq!(settings.local_repository, None);
        assert_eq!(settings.revision, None);
        assert!(settings.default_local_repository.ends_with("repository"));
        assert!(!home.join(".m2").exists());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn the_first_write_creates_a_settings_document() {
        let home = temporary_home();
        let written = write_local_repository(&home, " D:/maven/repository ", None).expect("write");
        assert_eq!(written.status, MavenUserSettingsStatus::Readable);
        assert_eq!(
            written.local_repository.as_deref(),
            Some("D:/maven/repository")
        );
        assert!(written.revision.is_some());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn a_write_changes_only_the_repository_and_keeps_secrets_on_disk() {
        let home = temporary_home();
        let path = settings_path(&home);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let original = "<settings>\n  <!-- team mirror -->\n  <localRepository>${user.home}/.m2/old</localRepository>\n  <servers><server><id>corp</id><password>fixture-secret</password></server></servers>\n</settings>\n";
        fs::write(&path, original).unwrap();
        let read_back = read(&home).expect("read");

        let written =
            write_local_repository(&home, "D:/R&D/repository", read_back.revision.as_deref())
                .expect("write");
        assert_eq!(
            written.local_repository.as_deref(),
            Some("D:/R&D/repository")
        );
        let contents = fs::read_to_string(&path).unwrap();
        assert!(contents.contains("<!-- team mirror -->"));
        assert!(contents.contains("<password>fixture-secret</password>"));
        assert!(contents.contains("<localRepository>D:/R&amp;D/repository</localRepository>"));
        // 读取模型不携带文档其余内容。
        assert!(!format!("{written:?}").contains("fixture-secret"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn a_stale_revision_is_refused_and_leaves_the_file_unchanged() {
        let home = temporary_home();
        let path = settings_path(&home);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "<settings/>").unwrap();
        let stale = read(&home).expect("read").revision;
        fs::write(&path, "<settings><offline>true</offline></settings>").unwrap();

        let error = write_local_repository(&home, "D:/repository", stale.as_deref())
            .expect_err("conflict");
        assert!(error.starts_with(CONFLICT_ERROR));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "<settings><offline>true</offline></settings>"
        );

        // 页面读到「文件不存在」之后文件被创建，同样是冲突。
        let created = write_local_repository(&home, "D:/repository", None);
        assert!(created.unwrap_err().starts_with(CONFLICT_ERROR));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn an_invalid_document_is_reported_and_not_rewritten() {
        let home = temporary_home();
        let path = settings_path(&home);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "<settings><localRepository>D:/repo").unwrap();
        let settings = read(&home).expect("read");
        assert_eq!(settings.status, MavenUserSettingsStatus::Invalid);

        let result = write_local_repository(&home, "D:/repository", settings.revision.as_deref());
        assert!(result.is_err());
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "<settings><localRepository>D:/repo"
        );
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn an_empty_repository_is_rejected() {
        let home = temporary_home();
        let result = write_local_repository(&home, "  ", None);
        assert_eq!(result.unwrap_err(), EMPTY_ERROR);
        assert!(!settings_path(&home).exists());
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn distinguishes_an_undeclared_repository_from_an_invalid_document() {
        assert_eq!(read_local_repository("<settings/>"), Ok(None));
        assert_eq!(
            read_local_repository("<settings><offline>true</offline></settings>"),
            Ok(None)
        );
        assert_eq!(
            read_local_repository("<settings><localRepository>D:/repo"),
            Err(InvalidSettings)
        );
        assert_eq!(
            read_local_repository(
                "<settings><localRepository><![CDATA[D:/R&D]]> /repo</localRepository></settings>"
            ),
            Ok(Some("D:/R&D /repo".into()))
        );
        assert_eq!(
            read_local_repository(
                r#"<s:settings xmlns:s="http://maven.apache.org/SETTINGS/1.2.0"><s:localRepository>${user.home}/.m2/team</s:localRepository></s:settings>"#
            ),
            Ok(Some("${user.home}/.m2/team".into()))
        );
    }
}
