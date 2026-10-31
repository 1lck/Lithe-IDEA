//! Maven 项目级与机器本地配置的持久化与生效解析。
//!
//! 与 Tauri 宿主（`windows/tauri/src-tauri/src/maven.rs`）共享同一存储：
//! - 可移植配置（profiles 等）在项目 `.lithe/maven/config.json`；
//! - 机器本地配置（settings.xml / 本地仓库 / Maven 可执行 / JAVA_HOME）按
//!   `sha256(lowercase(root) + NUL + reactor_path)` 存宿主数据目录。
//! 读取时 Tauri 目录（`%APPDATA%\app.lithe.windows`）优先、gpui 目录兜底，
//! 写入双写，保证两个产品看到同一份配置。
//!
//! 生效解析与 Tauri `assemble_effective_configuration` 一致：保存值非空优先，
//! 否则用检测值；检测的 Maven 可执行文件走启动路径同一解析（`resolve_toolchain`），
//! 保证「报告值 = 启动值」。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// 机器本地配置文件版本；与 Tauri `MAVEN_CONFIGURATION_VERSION` 一致。
const CONFIGURATION_VERSION: u32 = 1;

/// 四个机器本地字段的已保存值；`None` / 空串表示「自动检测」。
#[derive(Clone, Debug, Default)]
pub struct MavenLocalSettings {
    pub settings_path: Option<String>,
    pub local_repository_path: Option<String>,
    pub maven_executable_path: Option<String>,
    pub java_home_path: Option<String>,
}

/// 一个字段的生效值与检测值；`None` 表示检测未找到。
#[derive(Clone, Debug, Default)]
pub struct FieldResolution {
    /// 保存值非空时等于保存值（已解析存在性），否则等于检测值。
    pub effective: Option<String>,
    pub detected: Option<String>,
}

/// 四个字段的解析结果，供设置页展示「当前生效 / 检测到」。
#[derive(Clone, Debug, Default)]
pub struct MavenEffectiveSettings {
    pub settings_path: FieldResolution,
    pub local_repository_path: FieldResolution,
    pub maven_executable_path: FieldResolution,
    pub java_home_path: FieldResolution,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocalConfigurationFile {
    version: u32,
    #[serde(default)]
    settings_path: Option<String>,
    #[serde(default)]
    local_repository_path: Option<String>,
    #[serde(default)]
    maven_executable_path: Option<String>,
    #[serde(default)]
    java_home_path: Option<String>,
}

/// Tauri 宿主的数据目录（Windows `%APPDATA%\app.lithe.windows` 等）。
fn tauri_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("app.lithe.windows"))
    }
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join("Library/Application Support/app.lithe.windows"))
    }
    #[cfg(target_os = "linux")]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
            })
            .map(|base| base.join("app.lithe.windows"))
    }
}

/// gpui 自己的数据目录（Windows `%APPDATA%\Lithe`，与 recent projects 一致）。
fn gpui_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("Lithe"))
    }
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library/Application Support/Lithe"))
    }
    #[cfg(target_os = "linux")]
    {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
            .map(|base| base.join("lithe"))
    }
}

/// 机器本地配置文件名：与 Tauri `local_path` 的哈希一致。
fn local_file_name(root: &Path, reactor_path: &str) -> String {
    let identity = format!(
        "{}\0{}",
        root.to_string_lossy().to_lowercase(),
        reactor_path.replace('\\', "/")
    );
    let mut digest = Sha256::new();
    digest.update(identity.as_bytes());
    format!("{:x}.json", digest.finalize())
}

/// 候选存储目录：Tauri 在前（既有真源），gpui 兜底。
fn candidate_dirs(root: &Path, reactor_path: &str) -> Vec<PathBuf> {
    let file_name = local_file_name(root, reactor_path);
    [tauri_data_dir(), gpui_data_dir()]
        .into_iter()
        .flatten()
        .map(|directory| directory.join("maven").join(&file_name))
        .collect()
}

fn read_local_file(path: &Path) -> Option<MavenLocalSettings> {
    let contents = std::fs::read(path).ok()?;
    let file: LocalConfigurationFile = serde_json::from_slice(&contents).ok()?;
    if file.version != CONFIGURATION_VERSION {
        return None;
    }
    Some(MavenLocalSettings {
        settings_path: file.settings_path.filter(|value| !value.trim().is_empty()),
        local_repository_path: file
            .local_repository_path
            .filter(|value| !value.trim().is_empty()),
        maven_executable_path: file
            .maven_executable_path
            .filter(|value| !value.trim().is_empty()),
        java_home_path: file.java_home_path.filter(|value| !value.trim().is_empty()),
    })
}

fn write_local_file(path: &Path, file: &LocalConfigurationFile) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("Unable to create Maven configuration directory: {error}"))?;
    }
    let contents = serde_json::to_vec_pretty(file)
        .map_err(|error| format!("Unable to encode Maven configuration: {error}"))?;
    // 先写临时文件再替换，与 Tauri 的原子写一致，避免半份配置被读到。
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, contents)
        .map_err(|error| format!("Unable to write Maven configuration: {error}"))?;
    std::fs::rename(&temporary, path)
        .map_err(|error| format!("Unable to replace Maven configuration: {error}"))
}

/// 读取机器本地配置；Tauri 目录优先，两处都没有时返回全空（自动检测）。
pub fn load_local(root: &Path, reactor_path: &str) -> MavenLocalSettings {
    for path in candidate_dirs(root, reactor_path) {
        if let Some(settings) = read_local_file(&path) {
            return settings;
        }
    }
    MavenLocalSettings::default()
}

/// 保存机器本地配置；双写 Tauri 与 gpui 目录，任一失败即报错。
pub fn save_local(
    root: &Path,
    reactor_path: &str,
    settings: &MavenLocalSettings,
) -> Result<(), String> {
    let file = LocalConfigurationFile {
        version: CONFIGURATION_VERSION,
        settings_path: settings.settings_path.clone(),
        local_repository_path: settings.local_repository_path.clone(),
        maven_executable_path: settings.maven_executable_path.clone(),
        java_home_path: settings.java_home_path.clone(),
    };
    for path in candidate_dirs(root, reactor_path) {
        write_local_file(&path, &file)?;
    }
    Ok(())
}

fn user_home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

/// settings.xml 候选链：用户目录 → Maven 安装的 `conf/settings.xml`（仅当
/// 可执行文件位于安装的 `bin` 目录；wrapper 在项目里，不算）。
fn settings_candidates(home: Option<&Path>, maven_executable_path: Option<&str>) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(home) = home {
        candidates.push(home.join(".m2").join("settings.xml"));
    }
    if let Some(executable) = maven_executable_path {
        let executable = Path::new(executable);
        let is_installation = executable
            .parent()
            .filter(|parent| {
                parent
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.eq_ignore_ascii_case("bin"))
            })
            .filter(|_| {
                executable
                    .file_stem()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.eq_ignore_ascii_case("mvn"))
            })
            .and_then(|bin| bin.parent())
            .map(|installation| installation.to_path_buf());
        if let Some(installation) = is_installation {
            candidates.push(installation.join("conf").join("settings.xml"));
        }
    }
    candidates
}

/// settings.xml 生效路径：保存值优先，否则第一个存在的候选。
fn effective_settings_path(
    configured: Option<&str>,
    home: Option<&Path>,
    maven_executable_path: Option<&str>,
) -> Option<String> {
    if let Some(configured) = configured.map(str::trim).filter(|value| !value.is_empty()) {
        return Some(configured.to_string());
    }
    settings_candidates(home, maven_executable_path)
        .into_iter()
        .find(|candidate| candidate.is_file())
        .map(|path| path.to_string_lossy().into_owned())
}

/// 顶层 `<localRepository>` 文本；文档合法但未声明时返回 `None`。
fn parse_local_repository(settings: &str) -> Option<String> {
    // 轻量解析：Maven settings 的 <localRepository> 只出现在 settings 层级下，
    // 这里按标签文本匹配即可，避免为读取一个值引入完整 XML 解析器。
    let mut rest = settings;
    while let Some(start) = rest.find("<localRepository>") {
        let after = &rest[start + "<localRepository>".len()..];
        if let Some(end) = after.find("</localRepository>") {
            let value = after[..end].trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
            rest = &after[end..];
        } else {
            break;
        }
    }
    None
}

/// 本地仓库生效路径：保存值 → settings.xml 的 `<localRepository>` → `~/.m2/repository`。
fn effective_local_repository(
    configured: Option<&str>,
    settings_path: Option<&str>,
    home: Option<&Path>,
) -> Option<String> {
    if let Some(configured) = configured.map(str::trim).filter(|value| !value.is_empty()) {
        return Some(configured.to_string());
    }
    for candidate in settings_path.into_iter() {
        if let Ok(contents) = std::fs::read_to_string(candidate) {
            if let Some(repository) = parse_local_repository(&contents) {
                let expanded = match home {
                    Some(home) => repository.replace("${user.home}", &home.to_string_lossy()),
                    None => repository,
                };
                return Some(expanded);
            }
        }
    }
    home.map(|home| {
        home.join(".m2")
            .join("repository")
            .to_string_lossy()
            .into_owned()
    })
}

/// 解析四个字段的生效值与检测值。
///
/// - Maven 可执行：保存值先按相对路径补根目录并校验存在，否则走启动路径的
///   `resolve_toolchain`（与实际启动完全一致）；
/// - JAVA_HOME：保存值校验 `bin/java` 存在，否则读 Core 解析出的启动环境；
/// - settings.xml / 本地仓库：保存值优先，否则按 settings 候选链与
///   `<localRepository>` 解析，最后落到 `~/.m2` 默认值。
pub fn resolve_effective(
    root: &Path,
    reactor_path: &str,
    settings: &MavenLocalSettings,
    launch_java_home: Option<String>,
) -> MavenEffectiveSettings {
    let home = user_home();
    let working_directory = if reactor_path.trim().is_empty() {
        root.to_path_buf()
    } else {
        root.join(reactor_path)
    };

    // 检测值：无保存覆盖时的解析结果。
    let detected_maven = crate::maven::detected_maven_executable(root, &working_directory);
    let detected_java = launch_java_home.clone();

    let resolve_override = |configured: &Option<String>, root: &Path| -> Option<String> {
        let configured = configured
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())?;
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        if path.is_file() || path.is_dir() {
            Some(path.to_string_lossy().into_owned())
        } else {
            None
        }
    };

    let selected_maven = match settings.maven_executable_path.as_deref() {
        Some(configured) if !configured.trim().is_empty() => {
            resolve_override(&settings.maven_executable_path, root)
                .or_else(|| detected_maven.clone())
        }
        _ => detected_maven.clone(),
    };
    let selected_java = match settings.java_home_path.as_deref() {
        Some(configured) if !configured.trim().is_empty() => {
            resolve_override(&settings.java_home_path, root).or(detected_java.clone())
        }
        _ => detected_java.clone(),
    };

    let effective_maven = if settings
        .maven_executable_path
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
    {
        selected_maven.clone()
    } else {
        detected_maven.clone()
    };
    let effective_java = if settings
        .java_home_path
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
    {
        selected_java.clone()
    } else {
        detected_java.clone()
    };

    let detected_settings =
        effective_settings_path(None, home.as_deref(), detected_maven.as_deref());
    let effective_maven_for_settings = effective_maven.clone().or_else(|| detected_maven.clone());
    let effective_settings = effective_settings_path(
        settings.settings_path.as_deref(),
        home.as_deref(),
        effective_maven_for_settings.as_deref(),
    );
    let detected_settings_for_repo =
        effective_settings_path(None, home.as_deref(), detected_maven.as_deref());
    let detected_repository = effective_local_repository(
        None,
        detected_settings
            .as_deref()
            .or(detected_settings_for_repo.as_deref()),
        home.as_deref(),
    );
    let effective_repository = effective_local_repository(
        settings.local_repository_path.as_deref(),
        effective_settings.as_deref(),
        home.as_deref(),
    );

    MavenEffectiveSettings {
        settings_path: FieldResolution {
            effective: effective_settings,
            detected: detected_settings,
        },
        local_repository_path: FieldResolution {
            effective: effective_repository,
            detected: detected_repository,
        },
        maven_executable_path: FieldResolution {
            effective: effective_maven,
            detected: detected_maven,
        },
        java_home_path: FieldResolution {
            effective: effective_java,
            detected: detected_java,
        },
    }
}
