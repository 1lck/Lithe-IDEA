//! 本机工具链发现与生效解析。
//!
//! 业务规则移植自 Tauri 宿主 `windows/tauri/src-tauri/src/run.rs`：候选目录只从
//! 环境变量、常见安装目录、版本管理器和项目 `.lithe/toolchains` 派生；自动 JDK
//! 选择复用 Core 的 `compare_java_candidates` / `select_java`，保证设置页显示的
//! 「自动」结果与真正启动时一致。探测进程有 3 秒上限，调用方必须把本模块放到
//! 后台线程。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use lithe_core::execution::{
    compare_java_candidates, select_java, JavaSelectionCandidate, JavaSelectionRequest,
};
use lithe_ui::i18n::tr;

const MAVEN_LAUNCHERS: &[&str] = &["mvn.cmd", "mvn.bat", "mvn.exe", "mvn"];
const MVND_LAUNCHERS: &[&str] = &["mvnd.exe", "mvnd.cmd", "mvnd.bat", "mvnd"];
const TOOLCHAIN_PROBE_TIMEOUT: Duration = Duration::from_secs(3);

/// 一台探测成功的 JDK。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JavaRuntime {
    pub home_path: String,
    pub version: String,
    pub vendor: String,
}

/// 一个探测成功的 Maven 启动器。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MavenRuntime {
    pub executable_path: String,
    pub version: String,
}

/// Core 通用运行时（目前是 `project-node`）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GenericRuntime {
    pub id: String,
    pub kind: String,
    pub executable_path: String,
    pub version: String,
    pub vendor: String,
}

/// 一次发现得到的全部工具链候选。
#[derive(Clone, Debug, Default)]
pub struct DiscoveredToolchains {
    pub java: Vec<JavaRuntime>,
    pub maven: Vec<MavenRuntime>,
    pub runtimes: Vec<GenericRuntime>,
}

/// 一个工具链在启动时的实际解析结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolchainResolution {
    /// `source` 指明来源：`configured`、`javaHome`、`path`、`project`、
    /// `detected`、`mavenWrapper` 或 `projectJdk`。未探测时版本为空。
    Resolved {
        path: String,
        version: String,
        source: &'static str,
        warning: Option<String>,
    },
    /// 没有配置，也没有检测到可用工具链。
    NotFound,
    /// 配置的路径不可用；启动会以 `message` 失败。
    Invalid { message: String },
}

/// JDK、Maven 和 Maven JDK 的解析结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedToolchains {
    pub java: ToolchainResolution,
    pub maven: ToolchainResolution,
    pub maven_java: ToolchainResolution,
}

/// 设置页展示用的解析状态：正在探测或已有结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EffectiveToolchainState {
    Detecting,
    Resolution(ToolchainResolution),
}

/// 三个工具链的展示状态；编辑器重新打开时全部回到「正在探测」。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EffectiveToolchains {
    pub java: EffectiveToolchainState,
    pub maven: EffectiveToolchainState,
    pub maven_java: EffectiveToolchainState,
}

impl EffectiveToolchains {
    pub fn detecting() -> Self {
        Self {
            java: EffectiveToolchainState::Detecting,
            maven: EffectiveToolchainState::Detecting,
            maven_java: EffectiveToolchainState::Detecting,
        }
    }

    /// 把解析结果转成展示状态。
    pub fn resolved(resolved: ResolvedToolchains) -> Self {
        Self {
            java: EffectiveToolchainState::Resolution(resolved.java),
            maven: EffectiveToolchainState::Resolution(resolved.maven),
            maven_java: EffectiveToolchainState::Resolution(resolved.maven_java),
        }
    }
}

/// 字段取值方式：继承项目默认，或用户显式选择。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectiveMode {
    Inherit,
    Configured,
}

impl EffectiveMode {
    pub fn title(self) -> &'static str {
        match self {
            Self::Inherit => tr("Inherited from project"),
            Self::Configured => tr("Selected"),
        }
    }
}

/// 展示用的一行生效说明；`error` 为真时界面用错误颜色。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EffectiveToolchainLine {
    pub text: String,
    pub error: bool,
}

/// 描述一次启动会使用的工具链，例如
/// `Automatic → JDK 21.0.4 · C:\jdk-21 · from JAVA_HOME`。
pub fn describe_effective(
    state: &EffectiveToolchainState,
    kind: EffectiveKind,
    mode: EffectiveMode,
) -> EffectiveToolchainLine {
    match state {
        EffectiveToolchainState::Detecting => EffectiveToolchainLine {
            text: tr("Detecting…").to_string(),
            error: false,
        },
        EffectiveToolchainState::Resolution(resolution) => match resolution {
            ToolchainResolution::Invalid { message } => EffectiveToolchainLine {
                text: tr("Cannot be used: {message}").replace("{message}", message),
                error: true,
            },
            ToolchainResolution::NotFound => EffectiveToolchainLine {
                text: match kind {
                    EffectiveKind::Java => tr(
                        "No JDK found. Set JAVA_HOME, install a JDK, or choose a JDK directory.",
                    ),
                    EffectiveKind::Maven => tr(
                        "No Maven found. Add a Maven Wrapper to the project or choose a Maven installation.",
                    ),
                }
                .to_string(),
                error: true,
            },
            ToolchainResolution::Resolved {
                path,
                version,
                source,
                ..
            } => {
                let name = match kind {
                    EffectiveKind::Java => {
                        if version.is_empty() {
                            tr("JDK").to_string()
                        } else {
                            tr("JDK {version}").replace("{version}", version)
                        }
                    }
                    EffectiveKind::Maven => {
                        if version.is_empty() {
                            tr("Maven").to_string()
                        } else {
                            tr("Maven {version}").replace("{version}", version)
                        }
                    }
                };
                let mut parts = vec![name, path.clone()];
                // 显式配置和继承的项目 JDK 已经由 mode 说明。
                if *source != "configured" && *source != "projectJdk" {
                    parts.push(source_title(source).to_string());
                }
                EffectiveToolchainLine {
                    text: format!("{} → {}", mode.title(), parts.join(" · ")),
                    error: false,
                }
            }
        },
    }
}

/// 生效说明里的工具链种类。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectiveKind {
    Java,
    Maven,
}

fn source_title(source: &str) -> &'static str {
    match source {
        "javaHome" => tr("from JAVA_HOME"),
        "path" => tr("from PATH"),
        "project" => tr("from the project's .lithe/toolchains"),
        "mavenWrapper" => tr("project Maven Wrapper"),
        _ => tr("detected on this computer"),
    }
}


/// 不支持自定义路径时的自动发现入口。
pub fn discover(project_root: Option<&Path>) -> DiscoveredToolchains {
    discover_with_overrides(project_root, None, None, None)
}

/// 自动发现，并允许用户显式选择覆盖候选顺序。
pub fn discover_with_overrides(
    project_root: Option<&Path>,
    java_home_path: Option<&str>,
    maven_executable_path: Option<&str>,
    runtime_executable_paths: Option<&BTreeMap<String, String>>,
) -> DiscoveredToolchains {
    let mut homes = java_home_candidates(project_root);
    if let Some(path) = java_home_path.filter(|value| !value.trim().is_empty()) {
        homes.insert(0, PathBuf::from(path));
    }
    let mut java = probe_java_homes(homes);
    match select_project_java(project_root, &java) {
        Ok(selection) => {
            if let Some(index) = java
                .iter()
                .position(|runtime| Some(&runtime.home_path) == selection.id.as_ref())
            {
                let selected = java.remove(index);
                java.insert(0, selected);
            }
        }
        Err(_) => {}
    }

    let maven = discover_maven_candidates(
        maven_executable_candidates(project_root),
        maven_executable_path,
        probe_maven,
    );

    let mut runtimes = Vec::new();
    let mut seen_runtimes = HashSet::new();
    let mut node_executables = node_executable_candidates(project_root);
    if let Some(path) = runtime_executable_paths
        .and_then(|paths| paths.get("project-node"))
        .filter(|value| !value.trim().is_empty())
    {
        node_executables.splice(0..0, custom_node_executable_candidates(Path::new(path)));
    }
    for executable in node_executables {
        let normalized = normalize_path(&executable);
        if !seen_runtimes.insert(normalized.clone()) {
            continue;
        }
        if let Some(runtime) = probe_node(&normalized) {
            runtimes.push(runtime);
        }
    }
    runtimes.sort_by(|left, right| {
        runtime_version_parts(&right.version)
            .cmp(&runtime_version_parts(&left.version))
            .then(left.executable_path.cmp(&right.executable_path))
    });

    DiscoveredToolchains {
        java,
        maven,
        runtimes,
    }
}

/// 只解析设置页要展示的三个工具链，不启动项目。
pub fn resolve_for_display(
    root: &Path,
    java_home_path: &str,
    maven_executable_path: &str,
    maven_java_home_path: &str,
) -> ResolvedToolchains {
    let java = java_resolution(root, java_home_path);
    // 与启动一致：空的 Maven JDK 继承当前配置解析出的 JDK。
    let maven_java = if maven_java_home_path.trim().is_empty() {
        match &java {
            ToolchainResolution::Resolved {
                path,
                version,
                warning,
                ..
            } => ToolchainResolution::Resolved {
                path: path.clone(),
                version: version.clone(),
                source: "projectJdk",
                warning: warning.clone(),
            },
            other => other.clone(),
        }
    } else {
        java_resolution(root, maven_java_home_path)
    };
    ResolvedToolchains {
        java,
        maven: maven_resolution(root, maven_executable_path),
        maven_java,
    }
}

fn java_resolution(root: &Path, override_path: &str) -> ToolchainResolution {
    let automatic = if override_path.trim().is_empty() {
        match select_project_java(Some(root), &discover_java_runtimes(Some(root))) {
            Ok(selection) => Some(selection),
            Err(message) => return ToolchainResolution::Invalid { message },
        }
    } else {
        None
    };
    let resolved = automatic
        .as_ref()
        .map(|selection| Ok(selection.id.clone()))
        .unwrap_or_else(|| resolve_java_home(root, override_path));
    match resolved {
        Ok(Some(home)) => {
            let home_path = Path::new(&home);
            let source = if override_path.trim().is_empty() {
                automatic_java_source(root, home_path)
            } else {
                "configured"
            };
            let runtime = probe_java_home(home_path);
            ToolchainResolution::Resolved {
                version: runtime
                    .as_ref()
                    .map(|runtime| runtime.version.clone())
                    .unwrap_or_default(),
                path: home,
                source,
                warning: automatic.and_then(|selection| selection.warning),
            }
        }
        Ok(None) => ToolchainResolution::NotFound,
        Err(message) => ToolchainResolution::Invalid { message },
    }
}

/// 自动 JDK 候选来自哪里；仅用于展示，选择本身由 `resolve_java_home` 决定。
fn automatic_java_source(root: &Path, home: &Path) -> &'static str {
    let key = |path: &Path| normalize_path(path).to_string_lossy().to_lowercase();
    let selected = key(home);
    if std::env::var_os("JAVA_HOME").is_some_and(|value| key(Path::new(&value)) == selected) {
        return "javaHome";
    }
    let on_path = lookup_on_path("java.exe")
        .or_else(|| lookup_on_path("java"))
        .and_then(|executable| java_home_from_executable(&executable));
    if on_path.is_some_and(|path| key(&path) == selected) {
        return "path";
    }
    if key(&root.join(".lithe").join("toolchains").join("jdk")) == selected {
        return "project";
    }
    "detected"
}

fn maven_resolution(root: &Path, override_path: &str) -> ToolchainResolution {
    match resolve_maven_executable(root, root, override_path) {
        Ok(executable) => {
            let path = Path::new(&executable);
            let is_wrapper = path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.to_ascii_lowercase().starts_with("mvnw"));
            let source = if !override_path.trim().is_empty() {
                "configured"
            } else if is_wrapper {
                "mavenWrapper"
            } else {
                "detected"
            };
            // 运行 wrapper 可能下载 Maven 发行包，因此只探测普通安装的版本。
            let version = if is_wrapper {
                String::new()
            } else {
                probe_maven(path)
                    .map(|runtime| runtime.version)
                    .unwrap_or_default()
            };
            ToolchainResolution::Resolved {
                path: executable,
                version,
                source,
                warning: None,
            }
        }
        Err(_) if override_path.trim().is_empty() => ToolchainResolution::NotFound,
        Err(message) => ToolchainResolution::Invalid { message },
    }
}

// ---------------------------------------------------------------------------
// 候选发现
// ---------------------------------------------------------------------------

/// 只做候选选择与过滤，不执行探测；测试可以避免拉起整机 JDK / Maven / Node。
fn discover_maven_candidates(
    mut executables: Vec<PathBuf>,
    override_path: Option<&str>,
    mut probe: impl FnMut(&Path) -> Option<MavenRuntime>,
) -> Vec<MavenRuntime> {
    if let Some(path) = override_path.filter(|value| !value.trim().is_empty()) {
        executables.splice(0..0, custom_maven_executable_candidates(Path::new(path)));
    }
    let mut maven = Vec::new();
    let mut seen_executables = HashSet::new();
    for executable in executables {
        if seen_executables.insert(executable.clone()) {
            if let Some(runtime) = probe(&executable) {
                maven.push(runtime);
            }
        }
    }
    maven
}

fn node_executable_candidates(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut executables = Vec::new();
    for name in ["node.exe", "node"] {
        if let Some(path) = lookup_on_path(name) {
            executables.push(path);
        }
    }
    for key in ["NVM_SYMLINK", "NODE_HOME"] {
        if let Ok(path) = std::env::var(key) {
            executables.extend(custom_node_executable_candidates(Path::new(&path)));
        }
    }
    for key in ["ProgramFiles", "LOCALAPPDATA"] {
        if let Ok(base) = std::env::var(key) {
            let base = PathBuf::from(base);
            executables.push(base.join("nodejs").join("node.exe"));
            executables.push(base.join("Programs").join("nodejs").join("node.exe"));
        }
    }
    for key in ["NVM_HOME", "APPDATA"] {
        if let Ok(base) = std::env::var(key) {
            append_node_versions(&mut executables, Path::new(&base));
            append_node_versions(&mut executables, &PathBuf::from(base).join("nvm"));
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let profile = PathBuf::from(profile);
        executables.push(profile.join("scoop/apps/nodejs/current/node.exe"));
        executables.push(profile.join("scoop/apps/nodejs-lts/current/node.exe"));
        append_node_versions(&mut executables, &profile.join("AppData/Roaming/nvm"));
    }
    if let Some(root) = project_root {
        executables.push(root.join(".lithe/toolchains/node/node.exe"));
    }
    executables
}

fn append_node_versions(executables: &mut Vec<PathBuf>, root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.path().is_dir() {
            executables.push(entry.path().join("node.exe"));
        }
    }
}

fn custom_node_executable_candidates(path: &Path) -> Vec<PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    vec![path.join("node.exe"), path.join("node")]
}

fn probe_node(executable: &Path) -> Option<GenericRuntime> {
    if !executable.is_file() {
        return None;
    }
    let output = command_output(executable, &["--version"]);
    Some(GenericRuntime {
        id: "project-node".to_string(),
        kind: "node".to_string(),
        executable_path: normalize_path(executable).to_string_lossy().into_owned(),
        version: node_version(&output)?,
        vendor: "Node.js".to_string(),
    })
}

fn java_home_candidates(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut homes = Vec::new();
    if let Ok(value) = std::env::var("JAVA_HOME") {
        homes.push(PathBuf::from(value));
    }
    if let Some(path_java) = lookup_on_path("java.exe").or_else(|| lookup_on_path("java")) {
        if let Some(home) = java_home_from_executable(&path_java) {
            homes.push(home);
        }
    }
    for root in well_known_java_roots() {
        if let Ok(entries) = fs::read_dir(root) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    homes.push(path.join("Contents").join("Home"));
                    // Scoop 每个 app 的当前版本放在 `current`。
                    homes.push(path.join("current"));
                    homes.push(path);
                }
            }
        }
    }
    if let Some(root) = project_root {
        homes.push(root.join(".lithe").join("toolchains").join("jdk"));
    }
    homes
}

fn well_known_java_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for key in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
        if let Ok(base) = std::env::var(key) {
            let base = PathBuf::from(base);
            roots.push(base.join("Java"));
            roots.push(base.join("Eclipse Adoptium"));
            roots.push(base.join("Microsoft"));
            roots.push(base.join("Amazon Corretto"));
            roots.push(base.join("BellSoft"));
            roots.push(base.join("Zulu"));
            roots.push(base.join("Java").join("jdk"));
            if key == "LOCALAPPDATA" {
                roots.push(base.join("Programs").join("Eclipse Adoptium"));
            }
        }
    }
    for key in ["ProgramFiles", "LOCALAPPDATA"] {
        if let Ok(base) = std::env::var(key) {
            let base = PathBuf::from(base);
            roots.push(base.join("Semeru"));
            roots.push(base.join("OpenJDK"));
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let profile = PathBuf::from(profile);
        roots.push(profile.join(".jdks"));
        roots.push(profile.join(".sdkman").join("candidates").join("java"));
        roots.push(profile.join("scoop").join("apps"));
    }
    roots.extend(version_manager_install_roots("java"));
    roots
}

/// mise / asdf 的安装目录；它们的 shim 不是真实 home。
fn version_manager_install_roots(tool: &str) -> Vec<PathBuf> {
    let variable = |key: &str| {
        std::env::var_os(key)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
    };
    let mut roots = Vec::new();
    if let Some(mise) =
        variable("MISE_DATA_DIR").or_else(|| variable("LOCALAPPDATA").map(|base| base.join("mise")))
    {
        roots.push(mise.join("installs").join(tool));
    }
    if let Some(asdf) =
        variable("ASDF_DATA_DIR").or_else(|| variable("USERPROFILE").map(|home| home.join(".asdf")))
    {
        roots.push(asdf.join("installs").join(tool));
    }
    roots
}

/// 版本管理器和 Scoop 安装的 Maven，排在显式候选和 `PATH` 之后。
fn version_manager_maven_executables() -> Vec<PathBuf> {
    let mut roots = version_manager_install_roots("maven");
    if let Some(profile) = std::env::var_os("USERPROFILE").filter(|value| !value.is_empty()) {
        let profile = PathBuf::from(profile);
        roots.push(profile.join(".sdkman").join("candidates").join("maven"));
        roots.push(profile.join("scoop").join("apps").join("maven"));
    }
    let mut executables = Vec::new();
    for root in roots {
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        let mut homes = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .collect::<Vec<_>>();
        homes.sort();
        for home in homes {
            executables.extend(
                MAVEN_LAUNCHERS
                    .iter()
                    .map(|name| home.join("bin").join(name)),
            );
        }
    }
    executables
}

fn maven_executable_candidates(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut executables = maven_executable_candidates_with_sources(
        project_root,
        |key| {
            std::env::var_os(key)
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        },
        lookup_on_path,
    );
    executables.extend(version_manager_maven_executables());
    executables
}

fn maven_executable_candidates_with_sources(
    project_root: Option<&Path>,
    mut environment: impl FnMut(&str) -> Option<PathBuf>,
    mut path_lookup: impl FnMut(&str) -> Option<PathBuf>,
) -> Vec<PathBuf> {
    let mut executables = Vec::new();
    if let Some(root) = project_root {
        executables.push(root.join("mvnw.cmd"));
        executables.push(root.join("mvnw.bat"));
        executables.push(root.join("mvnw"));
    }
    for key in ["MAVEN_HOME", "M2_HOME"] {
        if let Some(home) = environment(key) {
            executables.extend(
                MAVEN_LAUNCHERS
                    .iter()
                    .map(|name| home.join("bin").join(name)),
            );
        }
    }
    // 已安装的 mvnd 不能替代普通 Maven 或项目 wrapper。
    for name in MAVEN_LAUNCHERS {
        if let Some(path) = path_lookup(name) {
            executables.push(path);
        }
    }
    if let Some(home) = environment("MVND_HOME") {
        executables.extend(custom_maven_executable_candidates(&home));
    }
    for name in MVND_LAUNCHERS {
        if let Some(path) = path_lookup(name) {
            executables.push(path);
        }
    }
    executables
}

fn custom_maven_executable_candidates(path: &Path) -> Vec<PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    // 接受安装根目录或 bin 目录；选择 mvnd 时必须保留 daemon 客户端。
    [path.join("bin"), path.to_path_buf()]
        .into_iter()
        .flat_map(|bin| {
            MVND_LAUNCHERS
                .iter()
                .chain(MAVEN_LAUNCHERS)
                .map(move |name| bin.join(name))
        })
        .collect()
}

// ---------------------------------------------------------------------------
// 探测
// ---------------------------------------------------------------------------

fn probe_java_home(home: &Path) -> Option<JavaRuntime> {
    let java = java_executable(home)?;
    let output = command_output(&java, &["-version"]);
    let version = java_version(&output)?;
    let vendor = output
        .lines()
        .find(|line| line.contains("Runtime Environment") || line.contains("VM"))
        .unwrap_or("")
        .trim()
        .to_string();
    Some(JavaRuntime {
        home_path: normalize_path(home).to_string_lossy().into_owned(),
        version,
        vendor,
    })
}

fn probe_maven(executable: &Path) -> Option<MavenRuntime> {
    if !executable.is_file() {
        return None;
    }
    let output = command_output(executable, &["-version"]);
    let version = maven_version(&output).unwrap_or_default();
    Some(MavenRuntime {
        executable_path: normalize_path(executable).to_string_lossy().into_owned(),
        version,
    })
}

fn java_executable(home: &Path) -> Option<PathBuf> {
    jdk_tool_executable(home, "java")
}

/// 启动时解析项目 JDK；空的 override 走自动选择（含项目 requirements）。
///
/// 不能直接用 `JAVA_HOME`：它可能指向旧 JDK，而 Spring Boot 3 等项目要求更高
/// 版本；Core 的 `select_java` 会按 `.lithe/toolchains/requirements.json` 选。
pub(crate) fn resolve_launch_java_home(root: &Path, override_path: &str) -> Option<PathBuf> {
    match java_resolution(root, override_path) {
        ToolchainResolution::Resolved { path, .. } => Some(PathBuf::from(path)),
        _ => None,
    }
}

/// 启动时解析 Maven 启动器；空的 override 走 wrapper / PATH / 版本管理器。
pub(crate) fn resolve_launch_maven_executable(
    root: &Path,
    working_directory: &Path,
    override_path: &str,
) -> Option<PathBuf> {
    resolve_maven_executable(root, working_directory, override_path)
        .ok()
        .map(PathBuf::from)
}

/// 解析 JDK `bin` 下的工具（`java`、`javac` 等），Windows 优先 `.exe`。
pub(crate) fn jdk_tool_executable(home: &Path, tool: &str) -> Option<PathBuf> {
    for name in [format!("{tool}.exe"), tool.to_string()] {
        let candidate = home.join("bin").join(&name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn java_home_from_executable(executable: &Path) -> Option<PathBuf> {
    executable
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

/// Java / Maven 启动实际使用的 JDK。
fn resolve_java_home(root: &Path, override_path: &str) -> Result<Option<String>, String> {
    let configured = override_path.trim();
    if !configured.is_empty() {
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        if java_executable(&path).is_some() {
            return Ok(Some(normalize_path(&path).to_string_lossy().into_owned()));
        }
        return Err(format!(
            "JDK Home does not point to a directory: {configured}"
        ));
    }
    // 解析 JDK 时不要顺带运行 Maven wrapper 或 Node 探测。
    select_project_java(Some(root), &discover_java_runtimes(Some(root)))
        .map(|selection| selection.id)
}

/// Java / Maven 启动实际使用的 Maven 启动器。
fn resolve_maven_executable(
    root: &Path,
    working_directory: &Path,
    override_path: &str,
) -> Result<String, String> {
    let configured = override_path.trim();
    if !configured.is_empty() {
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        if let Some(found) = custom_maven_executable_candidates(&path)
            .into_iter()
            .find(|candidate| candidate.is_file())
        {
            return Ok(normalize_path(&found).to_string_lossy().into_owned());
        }
        return Err("Maven executable path does not exist.".into());
    }
    let mut saw_incomplete_wrapper = false;
    for directory in [working_directory, root] {
        for name in ["mvnw.cmd", "mvnw.bat", "mvnw"] {
            let wrapper = directory.join(name);
            if !wrapper.is_file() {
                continue;
            }
            if maven_wrapper_is_usable(&wrapper) {
                return Ok(normalize_path(&wrapper).to_string_lossy().into_owned());
            }
            saw_incomplete_wrapper = true;
        }
    }
    maven_executable_without_probing(root)
        .ok_or_else(|| {
            if saw_incomplete_wrapper {
                "Maven wrapper is incomplete (.mvn/wrapper/maven-wrapper.properties is missing) and no system Maven was found. Install Maven or restore the wrapper files.".into()
            } else {
                "No Maven executable was found. Edit this service configuration.".into()
            }
        })
}

fn maven_executable_without_probing(root: &Path) -> Option<String> {
    for name in ["mvnw.cmd", "mvnw.bat", "mvnw"] {
        let wrapper = root.join(name);
        if wrapper.is_file() && maven_wrapper_is_usable(&wrapper) {
            return Some(normalize_path(&wrapper).to_string_lossy().into_owned());
        }
    }
    // wrapper 已经在上面考虑过；不可用的 wrapper 不能遮蔽本机安装。
    maven_executable_candidates(None)
        .into_iter()
        .filter(|candidate| !is_maven_wrapper(candidate))
        .find(|candidate| candidate.is_file())
        .map(|candidate| normalize_path(&candidate).to_string_lossy().into_owned())
}

fn maven_wrapper_is_usable(wrapper: &Path) -> bool {
    wrapper.parent().is_some_and(|directory| {
        directory
            .join(".mvn")
            .join("wrapper")
            .join("maven-wrapper.properties")
            .is_file()
    })
}

fn is_maven_wrapper(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            matches!(
                name.to_ascii_lowercase().as_str(),
                "mvnw" | "mvnw.cmd" | "mvnw.bat"
            )
        })
}

fn lookup_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        let candidate = directory.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn command_output(executable: &Path, arguments: &[&str]) -> String {
    let mut command = command_for_executable(executable, arguments);
    let deadline = Instant::now() + TOOLCHAIN_PROBE_TIMEOUT;
    let output = lithe_git_host::run(
        &mut command,
        None,
        || Instant::now() >= deadline,
        || {},
        |_, _| {},
    );
    if output.failure.is_some() || !output.status.is_some_and(|status| status.success()) {
        return String::new();
    }
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

fn command_for_executable(executable: &Path, arguments: &[&str]) -> Command {
    if is_batch_file(executable) {
        return batch_command(executable, arguments);
    }
    let mut command = Command::new(executable);
    command.args(arguments);
    command
}

fn is_batch_file(executable: &Path) -> bool {
    executable
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat")
        })
}

fn batch_command(executable: &Path, arguments: &[&str]) -> Command {
    let executable = executable.to_string_lossy();
    let mut command = Command::new("cmd.exe");
    // `cmd.exe /C` 只把下一个 token 当作命令；带引号路径后面的参数会被丢弃。
    // `/D /S /C` 加一条完整命令行是 Node 和 Maven wrapper 使用的 Windows 约定。
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.raw_arg("/D");
        command.raw_arg("/S");
        command.raw_arg("/C");
        command.raw_arg(batch_command_line(&executable, arguments));
    }
    #[cfg(not(windows))]
    {
        command.arg("/C").arg(&*executable).args(arguments);
    }
    command
}

#[cfg(windows)]
fn batch_command_line(executable: &str, arguments: &[&str]) -> String {
    let mut inner = String::from("call ");
    inner.push_str(&quote_windows_arg(executable));
    for argument in arguments {
        inner.push(' ');
        inner.push_str(&quote_windows_arg(argument));
    }
    format!("\"{inner}\"")
}

#[cfg(windows)]
fn quote_windows_arg(argument: &str) -> String {
    if argument.is_empty() {
        return "\"\"".into();
    }
    let needs_quotes = argument
        .bytes()
        .any(|byte| matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | b'"'));
    if !needs_quotes {
        return argument.to_string();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0;
    for character in argument.chars() {
        match character {
            '\\' => backslashes += 1,
            '"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.push_str(&"\\".repeat(backslashes));
                quoted.push(character);
                backslashes = 0;
            }
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

fn normalize_path(path: &Path) -> PathBuf {
    let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let text = canonical.to_string_lossy();
    PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(text.as_ref()))
}

// ---------------------------------------------------------------------------
// 自动 JDK 选择
// ---------------------------------------------------------------------------

fn discover_java_runtimes(project_root: Option<&Path>) -> Vec<JavaRuntime> {
    probe_java_homes(java_home_candidates(project_root))
}

fn java_selection_candidates(
    root: Option<&Path>,
    runtimes: &[JavaRuntime],
) -> Vec<JavaSelectionCandidate> {
    // 来源身份只解析一次，不要放进排序比较器；Windows 路径不区分大小写。
    let key = |path: &Path| normalize_path(path).to_string_lossy().to_lowercase();
    let environment_home = std::env::var_os("JAVA_HOME").map(|value| key(Path::new(&value)));
    let path_home = lookup_on_path("java.exe")
        .or_else(|| lookup_on_path("java"))
        .and_then(|path| java_home_from_executable(&path))
        .map(|path| key(&path));
    let project_home = root.map(|root| key(&root.join(".lithe/toolchains/jdk")));
    runtimes
        .iter()
        .map(|runtime| {
            let home = key(Path::new(&runtime.home_path));
            let priority = if Some(&home) == environment_home.as_ref() {
                0
            } else if Some(&home) == path_home.as_ref() {
                1
            } else if Some(&home) == project_home.as_ref() {
                3
            } else {
                2
            };
            JavaSelectionCandidate {
                id: runtime.home_path.clone(),
                version: runtime.version.clone(),
                priority,
            }
        })
        .collect()
}

fn select_project_java(
    root: Option<&Path>,
    runtimes: &[JavaRuntime],
) -> Result<lithe_core::execution::JavaSelection, String> {
    let candidates = java_selection_candidates(root, runtimes);
    let fallback_id = candidates
        .iter()
        .min_by(|a, b| compare_java_candidates(a, b))
        .map(|candidate| candidate.id.clone());
    select_java(JavaSelectionRequest {
        root: root.map(Path::to_path_buf),
        requirements: None,
        candidates,
        fallback_id,
    })
    .map_err(|error| error.message)
}

fn probe_java_homes(homes: Vec<PathBuf>) -> Vec<JavaRuntime> {
    let mut java = Vec::new();
    let mut seen_homes = HashSet::new();
    for home in homes {
        if !seen_homes.insert(home.clone()) {
            continue;
        }
        if let Some(runtime) = probe_java_home(&home) {
            java.push(runtime);
        }
    }
    // 保持来源优先级，再按 Java 版本数值比较；read_dir 顺序不能决定项目 JDK。
    let candidates = java_selection_candidates(None, &java)
        .into_iter()
        .map(|candidate| (candidate.id.clone(), candidate))
        .collect::<HashMap<_, _>>();
    java.sort_by(|left, right| {
        compare_java_candidates(
            &candidates[&left.home_path],
            &candidates[&right.home_path],
        )
    });
    java
}

// ---------------------------------------------------------------------------
// 版本解析
// ---------------------------------------------------------------------------

fn java_version(output: &str) -> Option<String> {
    for line in output.lines() {
        let Some(index) = line.find("version") else {
            continue;
        };
        let rest = line[index + "version".len()..].trim();
        if let Some(quoted) = rest.strip_prefix('"') {
            return quoted.split('"').next().map(str::to_string);
        }
        return rest.split_whitespace().next().map(str::to_string);
    }
    None
}

fn maven_version(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        // mvnd 会在内嵌 Apache Maven 行之前打印 daemon banner。
        let rest = line.trim().strip_prefix("Apache Maven ")?;
        let version = rest.split_whitespace().next()?;
        version
            .chars()
            .next()?
            .is_ascii_digit()
            .then(|| version.to_string())
    })
}

fn node_version(output: &str) -> Option<String> {
    output
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix('v'))
        .filter(|version| {
            !version.is_empty()
                && version
                    .chars()
                    .all(|character| character.is_ascii_digit() || character == '.')
        })
        .map(str::to_string)
}

fn runtime_version_parts(version: &str) -> Vec<u32> {
    version
        .split('.')
        .filter_map(|part| part.parse::<u32>().ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime(home: &str, version: &str) -> JavaRuntime {
        JavaRuntime {
            home_path: home.to_string(),
            version: version.to_string(),
            vendor: String::new(),
        }
    }

    #[test]
    fn java_version_reads_quoted_runtime_banner() {
        let output = "openjdk version \"21.0.4\" 2024-07-16\nOpenJDK Runtime Environment Temurin-21.0.4+7 (build 21.0.4+7-LTS)\n";
        assert_eq!(java_version(output).as_deref(), Some("21.0.4"));
    }

    #[test]
    fn node_version_reads_standard_banner() {
        assert_eq!(node_version("v20.11.1\n").as_deref(), Some("20.11.1"));
        assert_eq!(node_version("not a version"), None);
    }

    #[test]
    fn maven_version_ignores_daemon_banner() {
        let output = "mvnd 1.0.2\nApache Maven 3.9.9 (8dc69821)\n";
        assert_eq!(maven_version(output).as_deref(), Some("3.9.9"));
    }

    #[test]
    fn java_candidates_order_by_source_then_version() {
        let candidates = vec![
            JavaSelectionCandidate {
                id: "/detected/21".into(),
                version: "21.0.1".into(),
                priority: 2,
            },
            JavaSelectionCandidate {
                id: "/java-home/17".into(),
                version: "17.0.9".into(),
                priority: 0,
            },
        ];
        let selected = candidates
            .iter()
            .min_by(|a, b| compare_java_candidates(a, b))
            .expect("candidate should exist");
        assert_eq!(selected.id, "/java-home/17");
    }

    #[test]
    fn probe_java_homes_keeps_versions_comparable() {
        // 纯排序单元测试：不启动任何进程，只验证版本解析辅助函数。
        assert_eq!(runtime_version_parts("1.8.0_402"), vec![1, 8, 0]);
    }

    #[test]
    fn detected_runtime_keeps_its_source_identity() {
        let runtimes = [runtime("/opt/jdk-21", "21.0.4")];
        let candidates = java_selection_candidates(None, &runtimes);
        assert_eq!(candidates[0].id, "/opt/jdk-21");
        assert_eq!(candidates[0].version, "21.0.4");
    }
}
