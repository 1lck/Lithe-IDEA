//! Linux 端 LSP 接线：把编辑器文档同步给 Core 管理的语言服务器，并把
//! `lsp.pollEvents` 返回的诊断映射到诊断面板。
//!
//! Core 拥有进程、JSON-RPC framing、生命周期和诊断状态；本模块只做
//! 平台侧的语言/可执行文件探测、路径与 URI 规范化，以及事件投影。

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Value};

use crate::workbench::bottom_panel::DiagnosticEntry;

/// 一个可在本机通过 PATH 启动的语言服务器定义。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LanguageProvider {
    /// 与 Core `providerId` 一致的稳定标识。
    pub id: &'static str,
    /// PATH 中查找的可执行文件名。
    pub executable: &'static str,
    /// 以 stdio 启动服务器所需的固定参数。
    pub arguments: &'static [&'static str],
    /// 对应文件扩展名的 LSP `languageId` 前缀。
    pub language_id: &'static str,
    /// 扩展名匹配集合，全部小写且不含点。
    pub extensions: &'static [&'static str],
}

/// Core 对 JDT LS 使用的 provider 标识；不要使用发行包 wrapper 的 `jdtls` 名称。
pub const JAVA_PROVIDER_ID: &str = "java";

const JDTLS_EQUINOX_PREFIX: &str = "org.eclipse.equinox.launcher_";
const JDTLS_DEBUG_PREFIX: &str = "com.microsoft.java.debug.plugin-";
const JDTLS_TEST_LIST: &str = "extensions.txt";
const MAX_BUILD_FILE_DEPTH: usize = 32;

/// JDT LS 发行包内与当前平台/架构对应的配置目录名。
///
/// 上游 JDT LS 按平台打包不同目录名（`config_linux` / `config_win` /
/// `config_mac`，ARM 变体带 `_arm` 后缀）；名字必须与解压出的目录一致，
/// 否则初始化会找不到 bundle。
fn jdtls_configuration_name() -> &'static str {
    #[cfg(all(target_os = "linux", any(target_arch = "aarch64", target_arch = "arm")))]
    {
        "config_linux_arm"
    }
    #[cfg(all(
        target_os = "linux",
        not(any(target_arch = "aarch64", target_arch = "arm"))
    ))]
    {
        "config_linux"
    }
    #[cfg(target_os = "windows")]
    {
        "config_win"
    }
    #[cfg(target_os = "macos")]
    {
        "config_mac"
    }
}

/// 当前平台解析出的 JDT LS 直启资源。
///
/// 这些路径只属于本平台适配器；Core 负责把它们转换为 JVM 参数和 JDT 初始化选项。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JdtlsLaunchResources {
    /// Equinox launcher JAR。
    pub launcher_jar_path: String,
    /// 当前平台的 Eclipse configuration 目录。
    pub configuration_directory: String,
    /// Lombok agent JAR。
    pub lombok_agent_path: String,
    /// Java Debug Server bundle JAR。
    pub java_debug_bundle_path: String,
    /// Java Test extension bundles，按稳定路径顺序提交。
    pub java_extension_bundle_paths: Vec<String>,
}

/// Linux 主机解析出的 Java 语言服务器启动计划。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JavaLspLaunch {
    /// Core provider 必须是 `java`。
    pub provider_id: String,
    /// LSP language id。
    pub language_id: String,
    /// 直接启动时为 bundled Java，兼容 wrapper 时为 wrapper 路径。
    pub executable_path: String,
    /// 外部 wrapper 的兼容参数；直启资源由 Core 适配。
    pub arguments: Vec<String>,
    /// JDT LS 使用的 Java 可执行文件。
    pub runtime_executable_path: Option<String>,
    /// JDT LS 直启资源；外部 wrapper 回退时不提交该字段。
    pub jdtls_launch_resources: Option<JdtlsLaunchResources>,
    /// JDT LS 的 JAVA_HOME。
    pub java_home_path: Option<String>,
    /// 用于 Core workspace fingerprint 的发行包版本。
    pub jdtls_version: String,
}

/// 一条已由 Workbench 轮询收到的 Core LSP 请求结果。
#[derive(Debug, Clone)]
pub struct LspOperationResult {
    /// Core 事件所属的会话。
    pub session_id: String,
    /// 成功结果；失败时为空。
    pub result: Option<Value>,
    /// Core 返回的稳定错误码、消息和诊断详情。
    pub error: Option<String>,
}

/// Run 读取的 Java session 快照。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JavaLspStatus {
    /// 当前 Core session；没有会话时为空。
    pub session_id: Option<String>,
    /// `idle`、`starting`、`initializing`、`ready`、`failed` 或 `stopped`。
    pub state: String,
    /// 当前工作区最近一次 Java session 错误。
    pub error: Option<String>,
    /// Core 轮询返回的项目准备快照。
    pub project_preparation: Option<Value>,
    /// 拒绝旧工作区回调的代数。
    pub generation: u64,
}

const RUST_ANALYZER: LanguageProvider = LanguageProvider {
    id: "rust-analyzer",
    executable: "rust-analyzer",
    arguments: &[],
    language_id: "rust",
    extensions: &["rs"],
};

const CLANGD: LanguageProvider = LanguageProvider {
    id: "clangd",
    executable: "clangd",
    arguments: &[],
    language_id: "c",
    extensions: &["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx"],
};

const PYRIGHT: LanguageProvider = LanguageProvider {
    id: "pyright",
    executable: "pyright-langserver",
    arguments: &["--stdio"],
    language_id: "python",
    extensions: &["py", "pyi"],
};

const TYPESCRIPT: LanguageProvider = LanguageProvider {
    id: "typescript-language-server",
    executable: "typescript-language-server",
    arguments: &["--stdio"],
    language_id: "typescript",
    extensions: &["ts", "tsx", "js", "jsx", "mjs", "cjs"],
};

const GOPLS: LanguageProvider = LanguageProvider {
    id: "gopls",
    executable: "gopls",
    arguments: &[],
    language_id: "go",
    extensions: &["go"],
};

const JDTLS: LanguageProvider = LanguageProvider {
    id: "java",
    executable: "jdtls",
    arguments: &[],
    language_id: "java",
    extensions: &["java"],
};

const PROVIDERS: &[LanguageProvider] = &[RUST_ANALYZER, CLANGD, PYRIGHT, TYPESCRIPT, GOPLS, JDTLS];

/// 按文件扩展名选择语言服务器；未知扩展名返回 `None`。
pub fn provider_for_path(path: &str) -> Option<LanguageProvider> {
    let extension = file_extension(path)?;
    PROVIDERS
        .iter()
        .copied()
        .find(|provider| provider.extensions.contains(&extension.as_str()))
}

fn file_extension(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
}

/// provider 的默认 `languageId` 对同族扩展名需要细分，例如 clangd 的 C/C++
/// 与 typescript-language-server 的 TS/JS 使用不同的语言标识。
pub fn language_id_for_path(path: &str, provider: LanguageProvider) -> &'static str {
    let extension = file_extension(path).unwrap_or_default();
    match provider.id {
        "clangd" => match extension.as_str() {
            "cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx" => "cpp",
            _ => "c",
        },
        "typescript-language-server" => match extension.as_str() {
            "js" | "jsx" | "mjs" | "cjs" => "javascript",
            _ => "typescript",
        },
        _ => provider.language_id,
    }
}

/// 在 `PATH` 中查找可执行文件；只返回可执行且存在的绝对路径。
///
/// Unix 要求文件带执行位；Windows 按 `PATHEXT`（缺省 ` .COM;.EXE;.BAT;
/// .CMD`）逐个候选名尝试，因为 Windows 上 `java` 实际是 `java.exe`。
pub fn find_in_path(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for candidate in executable_candidates(&dir, name) {
            if !candidate.is_file() {
                continue;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                let executable = std::fs::metadata(&candidate)
                    .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
                    .unwrap_or(false);
                if !executable {
                    continue;
                }
            }
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

/// 列出在 `dir` 下应该尝试的可执行文件名。
///
/// Windows 上同名可执行文件通常带扩展名，因此除原名外还要按 `PATHEXT`
/// 补全；已经带扩展名或非 Windows 平台时只尝试原名，避免产生无意义探测。
fn executable_candidates(dir: &Path, name: &str) -> Vec<PathBuf> {
    #[cfg(windows)]
    {
        let mut candidates = vec![dir.join(name)];
        if Path::new(name).extension().is_none() {
            let pathext =
                std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
            for extension in pathext.split(';').filter(|value| !value.is_empty()) {
                candidates.push(dir.join(format!("{name}{extension}")));
            }
        }
        candidates
    }
    #[cfg(not(windows))]
    {
        vec![dir.join(name)]
    }
}

/// 发行包布局解析：可执行文件同级或上一级的
/// `share/LanguageServers/<name>`（tar.gz 解包为 `<root>/bin/<exe>` 与
/// `<root>/share/LanguageServers/…`，扁平安装则同级）。开发环境没有打包
/// 运行时目录时返回 `None`，由调用方回退到工作区 `.artifacts`。
fn installed_runtime_root(name: &str) -> Option<PathBuf> {
    let exe_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    [
        exe_dir.join("share").join("LanguageServers").join(name),
        exe_dir
            .join("..")
            .join("share")
            .join("LanguageServers")
            .join(name),
        exe_dir.join("LanguageServers").join(name),
    ]
    .into_iter()
    .find(|candidate| candidate.is_dir())
}

/// 解析 Linux Java 语言服务器资源。
///
/// 查找顺序与其他端对齐：环境变量覆盖 → 安装目录 `share/LanguageServers`
/// （发行包布局，见 `scripts/package-linux.sh`）→ 工作区 `.artifacts`
/// （开发路径）。只有全部候选都不存在时，才允许回退到外部 `jdtls`
/// wrapper。正式目录存在但资源不完整时直接返回错误，避免悄悄退回另一套
/// JDT 安装。
pub fn resolve_java_lsp_launch(root: &str) -> Result<JavaLspLaunch, String> {
    let workspace = Path::new(root);
    let explicit_jdtls_root = std::env::var_os("LITHE_JDTLS_ROOT")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty());
    let jdtls_root = explicit_jdtls_root.clone().unwrap_or_else(|| {
        installed_runtime_root("jdtls")
            .unwrap_or_else(|| workspace.join(".artifacts").join("jdtls-linux"))
    });
    let explicit_jdk_root = std::env::var_os("LITHE_JDK_ROOT")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty());
    let jdk_root = explicit_jdk_root.clone().unwrap_or_else(|| {
        installed_runtime_root("jdk")
            .unwrap_or_else(|| workspace.join(".artifacts").join("jdk-linux"))
    });

    if jdtls_root.exists() {
        let resources = resolve_direct_jdtls_resources(&jdtls_root)?;
        let java_executable = resolve_java_executable(&jdk_root).ok_or_else(|| {
            format!(
                "Java language-server runtime is missing. Set LITHE_JDK_ROOT or provide {}/bin/java.",
                jdk_root.display()
            )
        })?;
        let java_home = Path::new(&java_executable)
            .parent()
            .and_then(Path::parent)
            .map(|path| path.to_string_lossy().into_owned());
        return Ok(JavaLspLaunch {
            provider_id: JAVA_PROVIDER_ID.to_string(),
            language_id: JAVA_PROVIDER_ID.to_string(),
            executable_path: java_executable.clone(),
            arguments: Vec::new(),
            runtime_executable_path: Some(java_executable),
            jdtls_launch_resources: Some(resources),
            java_home_path: java_home,
            jdtls_version: read_jdtls_version(&jdtls_root),
        });
    }

    if explicit_jdtls_root.is_some() {
        return Err(format!(
            "JDT LS resource root does not exist: {}. Set LITHE_JDTLS_ROOT to a complete JDT LS installation.",
            jdtls_root.display()
        ));
    }

    resolve_wrapper_java_lsp_launch(&jdk_root)
}

fn resolve_direct_jdtls_resources(root: &Path) -> Result<JdtlsLaunchResources, String> {
    let launcher_jar_path = first_sorted_file(root.join("plugins"), JDTLS_EQUINOX_PREFIX, ".jar")?
        .ok_or_else(|| {
            format!(
                "JDT LS launcher is missing under {}. Expected {}*.jar.",
                root.join("plugins").display(),
                JDTLS_EQUINOX_PREFIX
            )
        })?;
    let configuration_directory = root.join(jdtls_configuration_name());
    if !configuration_directory.is_dir() {
        return Err(format!(
            "JDT LS platform configuration is missing: {}",
            configuration_directory.display()
        ));
    }
    let lombok_agent_path = root.join("lombok").join("lombok.jar");
    if !lombok_agent_path.is_file() {
        return Err(format!(
            "JDT LS Lombok agent is missing: {}",
            lombok_agent_path.display()
        ));
    }
    let java_debug_bundle_path =
        first_sorted_file(root.join("java-debug"), JDTLS_DEBUG_PREFIX, ".jar")?.ok_or_else(
            || {
                format!(
                    "JDT LS Java Debug bundle is missing under {}.",
                    root.join("java-debug").display()
                )
            },
        )?;
    let java_extension_bundle_paths = resolve_java_test_bundles(root)?;
    Ok(JdtlsLaunchResources {
        launcher_jar_path: path_string(&launcher_jar_path),
        configuration_directory: path_string(&configuration_directory),
        lombok_agent_path: path_string(&lombok_agent_path),
        java_debug_bundle_path: path_string(&java_debug_bundle_path),
        java_extension_bundle_paths: java_extension_bundle_paths
            .iter()
            .map(|path| path_string(path))
            .collect(),
    })
}

fn resolve_java_test_bundles(root: &Path) -> Result<Vec<PathBuf>, String> {
    let directory = root.join("java-test").join("extensions");
    if !directory.is_dir() {
        return Err(format!(
            "JDT LS Java Test extensions are missing: {}",
            directory.display()
        ));
    }
    let list_path = root.join("java-test").join(JDTLS_TEST_LIST);
    let mut bundles = match fs::read_to_string(&list_path) {
        Ok(text) => {
            let mut values = Vec::new();
            for name in text.lines().map(str::trim).filter(|name| !name.is_empty()) {
                if name.contains(['/', '\\']) || name == ".." {
                    return Err(format!(
                        "JDT LS Java Test bundle list contains a path instead of a file name: {name}"
                    ));
                }
                let path = directory.join(name);
                if !path.is_file() {
                    return Err(format!(
                        "JDT LS Java Test bundle is missing: {}",
                        path.display()
                    ));
                }
                values.push(path);
            }
            values
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let entries = fs::read_dir(&directory).map_err(|error| {
                format!(
                    "Failed to inspect JDT LS Java Test bundles at {}: {error}",
                    directory.display()
                )
            })?;
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| {
                    path.is_file() && path.extension().and_then(|ext| ext.to_str()) == Some("jar")
                })
                .collect()
        }
        Err(error) => {
            return Err(format!(
                "Failed to read JDT LS Java Test bundle list at {}: {error}",
                list_path.display()
            ))
        }
    };
    bundles.sort();
    bundles.dedup();
    if bundles.is_empty() {
        return Err(format!(
            "JDT LS Java Test extension directory contains no bundles: {}",
            directory.display()
        ));
    }
    Ok(bundles)
}

fn first_sorted_file(
    directory: PathBuf,
    prefix: &str,
    suffix: &str,
) -> Result<Option<PathBuf>, String> {
    let entries = match fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "Failed to inspect JDT LS resources at {}: {error}",
                directory.display()
            ))
        }
    };
    let mut files = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(prefix) && name.ends_with(suffix))
        })
        .collect::<Vec<_>>();
    files.sort();
    Ok(files.into_iter().next())
}

fn resolve_java_executable(jdk_root: &Path) -> Option<String> {
    let candidate = jdk_root.join("bin").join("java");
    candidate.is_file().then(|| path_string(&candidate))
}

fn resolve_wrapper_java_lsp_launch(jdk_root: &Path) -> Result<JavaLspLaunch, String> {
    let mut candidates = Vec::new();
    if let Some(executable) = std::env::var_os("LITHE_JDTLS_EXECUTABLE") {
        candidates.push(PathBuf::from(executable));
    }
    if let Some(home) = std::env::var_os("JDTLS_HOME") {
        let home = PathBuf::from(home);
        candidates.push(home.join("bin").join("jdtls"));
        candidates.push(home.join("jdtls"));
    }
    for name in ["jdtls", "jdtls.py"] {
        if let Some(executable) = find_in_path(name) {
            candidates.push(PathBuf::from(executable));
        }
    }
    let executable = candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .ok_or_else(|| {
            "JDT LS is not installed. Set LITHE_JDTLS_ROOT to the bundled resources or LITHE_JDTLS_EXECUTABLE to a compatible wrapper."
                .to_string()
        })?;
    let runtime = resolve_java_executable(jdk_root)
        .or_else(|| {
            std::env::var_os("JAVA_HOME").and_then(|home| {
                let path = PathBuf::from(home).join("bin").join("java");
                path.is_file().then(|| path_string(&path))
            })
        })
        .or_else(|| find_in_path("java"));
    let java_home = runtime
        .as_deref()
        .and_then(|path| Path::new(path).parent())
        .and_then(Path::parent)
        .map(|path| path.to_string_lossy().into_owned());
    Ok(JavaLspLaunch {
        provider_id: JAVA_PROVIDER_ID.to_string(),
        language_id: JAVA_PROVIDER_ID.to_string(),
        executable_path: path_string(&executable),
        arguments: Vec::new(),
        runtime_executable_path: runtime,
        jdtls_launch_resources: None,
        java_home_path: java_home,
        jdtls_version: "external-wrapper".to_string(),
    })
}

fn read_jdtls_version(root: &Path) -> String {
    fs::read_to_string(root.join("manifest.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| {
            value
                .get("version")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|version| !version.trim().is_empty())
        .unwrap_or_else(|| "direct-resources".to_string())
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// 生成带 JDT LS 资源和 Core 所需上下文的 `lsp.startServer` 载荷。
pub fn java_start_payload(
    launch: &JavaLspLaunch,
    root: &str,
    cache_directory: &str,
    workspace_fingerprint: Option<&str>,
    maven_context: Option<&Value>,
) -> Value {
    let mut payload = json!({
        "providerId": launch.provider_id,
        "executablePath": launch.executable_path,
        "arguments": launch.arguments,
        "rootUri": file_uri(root, root),
        "workingDirectory": absolute_path(root, root),
        "runtimeExecutablePath": launch.runtime_executable_path,
        "initializeTimeoutMilliseconds": 30_000,
        "requestTimeoutMilliseconds": 30_000,
        "shutdownTimeoutMilliseconds": 2_000,
        "cacheDirectory": cache_directory,
    });
    if let Some(resources) = &launch.jdtls_launch_resources {
        payload["jdtlsLaunchResources"] =
            serde_json::to_value(resources).expect("resources encode");
    }
    if let Some(java_home) = &launch.java_home_path {
        payload["environment"] = json!({ "JAVA_HOME": java_home });
    }
    if let Some(fingerprint) = workspace_fingerprint.filter(|value| !value.is_empty()) {
        payload["workspaceFingerprint"] = json!(fingerprint);
    }
    if let Some(context) = maven_context {
        payload["mavenContext"] = context.clone();
    }
    payload
}

/// 为 JDT LS 提供最小且可序列化的 Maven 上下文。
///
/// Linux 不从 Maven 命令行或源码推断项目模型；Core 会用这个上下文配置 JDT 的
/// settings、Profile 和递归模块导入。缺少机器本地 Maven 选择时保留空值。
pub fn maven_context_for_workspace(root: &str) -> Option<Value> {
    let workspace = Path::new(root);
    let reactor = workspace.ancestors().find_map(|directory| {
        directory
            .strip_prefix(workspace)
            .ok()
            .filter(|_| directory.join("pom.xml").is_file())
            .map(|_| directory)
    })?;
    let reactor_path = reactor
        .strip_prefix(workspace)
        .ok()
        .map(|path| path.to_string_lossy().replace('\\', "/"))
        .filter(|path| !path.is_empty())
        .unwrap_or_else(|| ".".to_string());
    let local_repository = std::env::var_os("LITHE_MAVEN_LOCAL_REPOSITORY")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    let settings = std::env::var_os("LITHE_MAVEN_SETTINGS")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    let java_home = std::env::var_os("LITHE_JDK_ROOT")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            let bundled = workspace.join(".artifacts").join("jdk-linux");
            bundled
                .join("bin")
                .join("java")
                .is_file()
                .then_some(bundled)
        });
    let maven_executable = std::env::var_os("LITHE_MAVEN_EXECUTABLE")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    Some(json!({
        "version": 1,
        "reactorPath": reactor_path,
        "profiles": Vec::<String>::new(),
        "settingsPath": settings.map(|path| path_string(&path)),
        "localRepositoryPath": local_repository.map(|path| path_string(&path)),
        "skipTests": false,
        "mavenExecutablePath": maven_executable.map(|path| path_string(&path)),
        "javaHomePath": java_home.map(|path| path_string(&path)),
    }))
}

/// 构造 Core `java.jdtWorkspaceFingerprint` 的平台观察载荷。
pub fn workspace_fingerprint_request(root: &str, jdtls_version: &str) -> Value {
    let workspace = Path::new(root);
    let mut build_files = Vec::new();
    let mut direct_maven_modules = Vec::new();
    collect_build_observations(
        workspace,
        workspace,
        0,
        &mut build_files,
        &mut direct_maven_modules,
    );
    build_files.sort_by(|left, right| left["path"].as_str().cmp(&right["path"].as_str()));
    direct_maven_modules.sort();
    direct_maven_modules.dedup();
    json!({
        "buildFiles": build_files,
        "directMavenModules": direct_maven_modules,
        "jdtlsVersion": jdtls_version,
    })
}

fn collect_build_observations(
    root: &Path,
    directory: &Path,
    depth: usize,
    build_files: &mut Vec<Value>,
    modules: &mut Vec<String>,
) {
    if depth > MAX_BUILD_FILE_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            if name.starts_with('.') || matches!(name.as_str(), "target" | "build" | "node_modules")
            {
                continue;
            }
            collect_build_observations(root, &path, depth + 1, build_files, modules);
            continue;
        }
        if !file_type.is_file() || !is_build_file(&name) {
            continue;
        }
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let modified = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|value| value.as_millis() as u64)
            .unwrap_or(0);
        build_files.push(json!({
            "path": relative.to_string_lossy().replace('\\', "/"),
            "modifiedUnixMilliseconds": modified,
            "sizeBytes": metadata.len(),
        }));
        if name == "pom.xml" {
            collect_maven_modules(&path, root, modules);
        }
    }
}

fn is_build_file(name: &str) -> bool {
    matches!(
        name,
        "pom.xml"
            | "build.gradle"
            | "build.gradle.kts"
            | "settings.gradle"
            | "settings.gradle.kts"
            | "gradle.properties"
    )
}

fn collect_maven_modules(path: &Path, root: &Path, output: &mut Vec<String>) {
    let Ok(text) = fs::read_to_string(path) else {
        return;
    };
    let mut remaining = text.as_str();
    while let Some(start) = remaining.find("<module") {
        let after = &remaining[start + "<module".len()..];
        let Some(open_end) = after.find('>') else {
            break;
        };
        let value = &after[open_end + 1..];
        let Some(close) = value.find("</module>") else {
            break;
        };
        let module = value[..close].trim();
        if !module.is_empty() && module != "." && !module.contains("..") {
            let module_path = path.parent().unwrap_or(root).join(module);
            if let Ok(relative) = module_path.strip_prefix(root) {
                let relative = relative.to_string_lossy().replace('\\', "/");
                if !relative.contains('/') && relative != "." {
                    output.push(relative);
                }
            }
        }
        remaining = &value[close + "</module>".len()..];
    }
}

/// 判断 Run 是否可以消费 Java 准备结果。
///
/// Core 的 `ServiceReady` 只表示协议和项目导入完成；Maven Profile 等准备任务
/// 仍由 `projectPreparation.blocksRun` 门禁。Core 允许非阻塞的部分 Profile
/// 失败继续进入目标项目构建，Linux 不在 UI 侧另造一套状态机。
pub fn java_lsp_allows_run(status: &JavaLspStatus) -> bool {
    if status.state != "ready" {
        return false;
    }
    status
        .project_preparation
        .as_ref()
        .and_then(|value| value.get("blocksRun"))
        .and_then(Value::as_bool)
        .is_some_and(|value| !value)
}

/// Core Java 入口发现请求。
pub fn java_entrypoints_request(session_id: &str) -> Value {
    json!({
        "sessionId": session_id,
        "operation": "javaEntrypoints",
    })
}

/// Core `vscode.java.buildWorkspace` 请求。
pub fn java_build_request(
    session_id: &str,
    source_path: &str,
    main_class: &str,
    project_name: Option<&str>,
) -> Value {
    let arguments = serde_json::to_string(&json!({
        "mainClass": main_class,
        "projectName": project_name,
        "filePath": source_path,
        "isFullBuild": false,
    }))
    .expect("Java build command encodes");
    json!({
        "sessionId": session_id,
        "operation": "executeCommand",
        "command": {
            "title": "Build Java Workspace",
            "command": "vscode.java.buildWorkspace",
            "arguments": [arguments],
        },
    })
}

/// Core `vscode.java.resolveClasspath` 请求。
pub fn java_classpath_request(
    session_id: &str,
    main_class: &str,
    project_name: Option<&str>,
) -> Value {
    json!({
        "sessionId": session_id,
        "operation": "executeCommand",
        "command": {
            "title": "Resolve Java Runtime Classpath",
            "command": "vscode.java.resolveClasspath",
            "arguments": [main_class, project_name.unwrap_or(""), "runtime"],
        },
    })
}

/// 校验 Core 的 Java 入口结果并保留其稳定 workspace-relative 结构。
pub fn parse_java_entrypoints(value: &Value) -> Result<Value, String> {
    let value = unwrap_command_value(value);
    let entries = value
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| "Java language service returned no entry-point list.".to_string())?;
    let schema_version = value
        .get("schemaVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| "Java entry-point result has no schema version.".to_string())?;
    if schema_version != 1 {
        return Err("Unsupported Java entry-point schema version.".to_string());
    }
    let mut entries = entries.clone();
    entries.sort_by(|left, right| {
        left.get("sourcePath")
            .and_then(Value::as_str)
            .cmp(&right.get("sourcePath").and_then(Value::as_str))
            .then_with(|| {
                left.get("mainClass")
                    .and_then(Value::as_str)
                    .cmp(&right.get("mainClass").and_then(Value::as_str))
            })
    });
    entries.dedup();
    let normalized = json!({
        "schemaVersion": schema_version,
        "entries": entries,
        "diagnostics": value.get("diagnostics").cloned().unwrap_or_else(|| json!([])),
    });
    Ok(normalized)
}

/// 从 Core 的入口列表选择配置对应的唯一目标，不读取 Java 源码。
pub fn select_java_entrypoint(
    value: &Value,
    source_path: &str,
    configured_main_class: Option<&str>,
) -> Result<Value, String> {
    let entries = value
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| "Java entry-point result has no entries.".to_string())?;
    let source_matches = entries
        .iter()
        .filter(|entry| entry.get("sourcePath").and_then(Value::as_str) == Some(source_path))
        .collect::<Vec<_>>();
    let selected = if source_matches.len() == 1 {
        source_matches[0].clone()
    } else {
        source_matches
            .into_iter()
            .find(|entry| {
                configured_main_class.is_some_and(|main| {
                    entry.get("mainClass").and_then(Value::as_str) == Some(main)
                })
            })
            .cloned()
            .ok_or_else(|| {
                format!(
                    "Java language service could not identify one launch target for {source_path}."
                )
            })?
    };
    if selected.get("mainClass").and_then(Value::as_str).is_none() {
        return Err("Java entry-point result is missing mainClass.".to_string());
    }
    Ok(selected)
}

/// 校验 Core `vscode.java.buildWorkspace` 的成功结果。
pub fn parse_java_build_result(value: &Value) -> Result<(), String> {
    let value = unwrap_command_value(value);
    let status = value
        .as_i64()
        .or_else(|| value.get("value").and_then(Value::as_i64));
    if status == Some(1) {
        Ok(())
    } else {
        Err("Java language service returned an unexpected project build status.".to_string())
    }
}

/// 解析 Core `vscode.java.resolveClasspath` 的 `[modulePaths, classPaths]`。
pub fn parse_java_classpath(value: &Value) -> Result<(Vec<String>, Vec<String>), String> {
    let value = unwrap_command_value(value);
    let paths = value.as_array().ok_or_else(|| {
        "Java language service returned an invalid runtime classpath.".to_string()
    })?;
    if paths.len() != 2 {
        return Err(
            "Java language service returned an invalid runtime classpath shape.".to_string(),
        );
    }
    let module_paths = string_array(paths[0].clone())
        .ok_or_else(|| "Java module paths must be an array of strings.".to_string())?;
    let class_paths = string_array(paths[1].clone())
        .ok_or_else(|| "Java class paths must be an array of strings.".to_string())?;
    if module_paths.is_empty() && class_paths.is_empty() {
        return Err("Java language service returned no runtime paths.".to_string());
    }
    Ok((module_paths, class_paths))
}

/// 组合 JDT 返回的目标和路径；Linux 不在这里拼接 classpath 字符串。
pub fn java_launch_payload(entrypoint: &Value, classpath: &Value) -> Result<Value, String> {
    let main_class = entrypoint
        .get("mainClass")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Java entry-point result is missing mainClass.".to_string())?;
    let (module_paths, class_paths) = parse_java_classpath(classpath)?;
    Ok(json!({
        "mainClass": main_class,
        "projectName": entrypoint.get("projectName").cloned().unwrap_or(Value::Null),
        "classPaths": class_paths,
        "modulePaths": module_paths,
    }))
}

fn unwrap_command_value(value: &Value) -> &Value {
    value.get("value").unwrap_or(value)
}

fn string_array(value: Value) -> Option<Vec<String>> {
    value
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_string))
        .collect()
}

/// 从一次 `lsp.pollEvents` 响应中提取属于指定会话的请求结果。
pub fn operation_results_from_poll(
    value: &Value,
    session_id: &str,
) -> Vec<(String, LspOperationResult)> {
    value
        .get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|event| {
            event.get("type").and_then(Value::as_str) == Some("requestCompleted")
                && event.get("sessionId").and_then(Value::as_str) == Some(session_id)
        })
        .filter_map(|event| {
            let operation_id = event
                .get("operationId")
                .and_then(Value::as_str)?
                .to_string();
            let error = event.get("error").and_then(format_lsp_error);
            Some((
                operation_id.clone(),
                LspOperationResult {
                    session_id: session_id.to_string(),
                    result: event.get("result").cloned(),
                    error,
                },
            ))
        })
        .collect()
}

fn format_lsp_error(error: &Value) -> Option<String> {
    let code = error
        .get("code")
        .and_then(Value::as_str)
        .unwrap_or("lspError");
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Language-server request failed.");
    let mut text = format!("{code}: {message}");
    if let Some(details) = error
        .get("details")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        text.push_str(&format!(" ({details})"));
    }
    if let Some(report) = error.get("javaBuildReport") {
        text.push_str(&format!(
            " [javaBuildReport={}]",
            serde_json::to_string(report).unwrap_or_else(|_| "{}".to_string())
        ));
    }
    Some(text)
}

/// 读取当前 Java session 的可观察生命周期状态。
#[allow(dead_code)]
pub fn java_lifecycle_state(value: &Value) -> Option<String> {
    java_lifecycle_state_for(value, None)
}

/// 读取指定 Java session 的最新生命周期状态。
pub fn java_lifecycle_state_for(value: &Value, session_id: Option<&str>) -> Option<String> {
    value
        .get("events")
        .and_then(Value::as_array)?
        .iter()
        .rev()
        .find_map(|event| {
            let session_matches = session_id.is_none_or(|session_id| {
                event.get("sessionId").and_then(Value::as_str) == Some(session_id)
            });
            (event.get("type").and_then(Value::as_str) == Some("stateChanged")
                && event.get("providerId").and_then(Value::as_str) == Some(JAVA_PROVIDER_ID)
                && session_matches)
                .then(|| {
                    event
                        .get("state")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .flatten()
        })
}

pub fn absolute_path(root: &str, path: &str) -> String {
    let candidate = std::path::Path::new(path);
    if candidate.is_absolute() {
        path.to_string()
    } else {
        std::path::Path::new(root)
            .join(path)
            .to_string_lossy()
            .replace('\\', "/")
    }
}

/// 构造 LSP `file://` URI，保留 `/`，其余字节做百分号编码。
pub fn file_uri(root: &str, path: &str) -> String {
    let absolute = absolute_path(root, path);
    let mut encoded = String::with_capacity(absolute.len() + 8);
    for byte in absolute.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(byte as char)
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    format!("file://{encoded}")
}

/// 把 LSP `file://` URI 映射回工作区相对路径；工作区外返回 `None`。
pub fn workspace_relative_path(root: &str, uri: &str) -> Option<String> {
    let encoded = uri.strip_prefix("file://")?;
    let decoded = percent_decode(encoded);
    let root = root.replace('\\', "/");
    let root = root.trim_end_matches('/');
    let decoded = decoded.replace('\\', "/");
    if decoded == root {
        return Some(String::new());
    }
    decoded
        .strip_prefix(&format!("{root}/"))
        .map(|value| value.to_string())
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(byte) = hex.and_then(|value| u8::from_str_radix(value, 16).ok()) {
                decoded.push(byte);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// 当前语言服务器可用性；不可用时返回空。
pub fn resolve_provider(path: &str) -> Option<(LanguageProvider, String)> {
    let provider = provider_for_path(path)?;
    let executable = find_in_path(provider.executable)?;
    Some((provider, executable))
}

/// `lsp.startServer` 的最小有效载荷。平台只提供进程与工作区信息，
/// 初始化参数与工作区指纹由 Core 的 provider 适配层负责。
pub fn start_payload(
    provider: LanguageProvider,
    executable: &str,
    root: &str,
    cache_directory: &str,
) -> Value {
    let arguments: Vec<String> = provider
        .arguments
        .iter()
        .map(|value| value.to_string())
        .collect();
    json!({
        "providerId": provider.id,
        "executablePath": executable,
        "arguments": arguments,
        "rootUri": file_uri(root, root),
        "workingDirectory": absolute_path(root, root),
        "initializeTimeoutMilliseconds": 30_000,
        "requestTimeoutMilliseconds": 30_000,
        "shutdownTimeoutMilliseconds": 2_000,
        "cacheDirectory": cache_directory,
    })
}

pub fn parse_session_id(value: &Value) -> Option<String> {
    value
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_string)
}

pub fn sync_payload(session_id: &str, uri: &str, language_id: &str, text: &str) -> Value {
    json!({
        "sessionId": session_id,
        "uri": uri,
        "languageId": language_id,
        "text": text,
    })
}

pub fn poll_payload(session_id: &str) -> Value {
    json!({ "sessionId": session_id })
}

/// 语言服务器退出后 Core 只允许在收到终态事件后销毁会话。
#[allow(dead_code)]
pub fn session_finished(value: &Value) -> bool {
    value
        .get("events")
        .and_then(Value::as_array)
        .map(|events| {
            events.iter().any(|event| {
                let kind = event.get("type").and_then(Value::as_str);
                let state = event.get("state").and_then(Value::as_str);
                matches!(kind, Some("stateChanged")) && matches!(state, Some("stopped" | "failed"))
            })
        })
        .unwrap_or(false)
}

/// 只接受指定 session 的终态事件，避免混合 fixture 或旧 session 结束新 session。
pub fn session_finished_for(value: &Value, session_id: &str) -> bool {
    value
        .get("events")
        .and_then(Value::as_array)
        .map(|events| {
            events.iter().any(|event| {
                event.get("sessionId").and_then(Value::as_str) == Some(session_id)
                    && event.get("type").and_then(Value::as_str) == Some("stateChanged")
                    && matches!(
                        event.get("state").and_then(Value::as_str),
                        Some("stopped" | "failed")
                    )
            })
        })
        .unwrap_or(false)
}

/// 把一次 poll 的诊断事件投影为面板条目；无 URI 或工作区外的事件被丢弃。
pub fn diagnostics_from_poll(value: &Value, root: &str) -> HashMap<String, Vec<DiagnosticEntry>> {
    let mut by_file: HashMap<String, Vec<DiagnosticEntry>> = HashMap::new();
    let Some(events) = value.get("events").and_then(Value::as_array) else {
        return by_file;
    };
    for event in events {
        if event.get("type").and_then(Value::as_str) != Some("diagnostics") {
            continue;
        }
        let Some(uri) = event.get("uri").and_then(Value::as_str) else {
            continue;
        };
        let Some(path) = workspace_relative_path(root, uri) else {
            continue;
        };
        let diagnostics = event
            .get("diagnostics")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .map(|diagnostic| DiagnosticEntry {
                        severity: severity_name(diagnostic.get("severity").and_then(Value::as_i64)),
                        file_path: path.clone(),
                        line: diagnostic
                            .pointer("/range/start/line")
                            .and_then(Value::as_u64)
                            .unwrap_or(0) as u32,
                        column: diagnostic
                            .pointer("/range/start/utf16Column")
                            .and_then(Value::as_u64)
                            .unwrap_or(0) as u32,
                        message: diagnostic
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        source: diagnostic
                            .get("source")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                        code: diagnostic
                            .get("code")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        by_file.insert(path, diagnostics);
    }
    by_file
}

/// 只投影指定 session 的诊断事件。
pub fn diagnostics_from_poll_for(
    value: &Value,
    root: &str,
    session_id: &str,
) -> HashMap<String, Vec<DiagnosticEntry>> {
    let mut filtered = value.clone();
    if let Some(events) = filtered.get_mut("events").and_then(Value::as_array_mut) {
        events.retain(|event| event.get("sessionId").and_then(Value::as_str) == Some(session_id));
    }
    diagnostics_from_poll(&filtered, root)
}

fn severity_name(severity: Option<i64>) -> String {
    match severity {
        Some(1) => "error".to_string(),
        Some(2) => "warning".to_string(),
        Some(3) => "info".to_string(),
        Some(4) => "hint".to_string(),
        _ => "info".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_and_decodes_file_uris() {
        let uri = file_uri("/work space", "src/主 file.rs");
        assert_eq!(uri, "file:///work%20space/src/%E4%B8%BB%20file.rs");
        assert_eq!(
            workspace_relative_path("/work space", &uri).as_deref(),
            Some("src/主 file.rs")
        );
    }

    #[test]
    fn selects_provider_by_extension() {
        assert_eq!(
            provider_for_path("src/main.rs").map(|p| p.id),
            Some("rust-analyzer")
        );
        assert_eq!(
            provider_for_path("src/App.tsx").map(|p| p.id),
            Some("typescript-language-server")
        );
        assert_eq!(
            provider_for_path("src/App.java").map(|p| p.id),
            Some("java")
        );
        assert_eq!(provider_for_path("README.md").map(|p| p.id), None);
    }

    #[test]
    fn refines_language_id_for_shared_providers() {
        let clangd = provider_for_path("src/native.cpp").expect("clangd");
        assert_eq!(language_id_for_path("src/native.cpp", clangd), "cpp");
        assert_eq!(language_id_for_path("src/native.c", clangd), "c");
        let tsserver = provider_for_path("src/app.js").expect("tsserver");
        assert_eq!(language_id_for_path("src/app.js", tsserver), "javascript");
        assert_eq!(language_id_for_path("src/app.ts", tsserver), "typescript");
    }

    #[test]
    fn projects_diagnostics_inside_the_workspace() {
        let value = serde_json::json!({
            "events": [{
                "type": "diagnostics",
                "uri": "file:///work/src/main.rs",
                "diagnostics": [{
                    "severity": 1,
                    "message": "mismatched types",
                    "range": { "start": { "line": 4, "utf16Column": 7 } }
                }]
            }]
        });
        let diagnostics = diagnostics_from_poll(&value, "/work");
        let entries = diagnostics.get("src/main.rs").expect("diagnostics");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].severity, "error");
        assert_eq!(entries[0].line, 4);
        assert_eq!(entries[0].column, 7);
    }

    fn fixture(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lithe-linux-lsp-{name}-{}-{}",
            std::process::id(),
            name.len()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("fixture");
        path
    }

    fn direct_jdtls_fixture(root: &Path) -> JdtlsLaunchResources {
        let plugins = root.join("plugins");
        let debug = root.join("java-debug");
        let extensions = root.join("java-test").join("extensions");
        fs::create_dir_all(&plugins).unwrap();
        fs::create_dir_all(root.join(jdtls_configuration_name())).unwrap();
        fs::create_dir_all(root.join("lombok")).unwrap();
        fs::create_dir_all(&debug).unwrap();
        fs::create_dir_all(&extensions).unwrap();
        fs::write(plugins.join("org.eclipse.equinox.launcher_2.jar"), b"jar").unwrap();
        fs::write(plugins.join("org.eclipse.equinox.launcher_1.jar"), b"jar").unwrap();
        fs::write(root.join("lombok").join("lombok.jar"), b"jar").unwrap();
        fs::write(debug.join("com.microsoft.java.debug.plugin-2.jar"), b"jar").unwrap();
        fs::write(debug.join("com.microsoft.java.debug.plugin-1.jar"), b"jar").unwrap();
        fs::write(extensions.join("z.jar"), b"jar").unwrap();
        fs::write(extensions.join("a.jar"), b"jar").unwrap();
        fs::write(
            root.join("java-test").join("extensions.txt"),
            "z.jar\na.jar\n",
        )
        .unwrap();
        resolve_direct_jdtls_resources(root).expect("direct resources")
    }

    #[test]
    fn direct_resources_are_sorted_and_payload_uses_java_provider() {
        let root = fixture("resources");
        let jdtls = root.join("jdtls");
        let jdk = root.join("jdk");
        fs::create_dir_all(jdk.join("bin")).unwrap();
        fs::write(jdk.join("bin").join("java"), b"java").unwrap();
        let resources = direct_jdtls_fixture(&jdtls);
        assert!(resources
            .launcher_jar_path
            .ends_with("org.eclipse.equinox.launcher_1.jar"));
        assert!(resources
            .java_debug_bundle_path
            .ends_with("com.microsoft.java.debug.plugin-1.jar"));
        assert_eq!(
            resources.java_extension_bundle_paths,
            vec![
                path_string(&jdtls.join("java-test/extensions/a.jar")),
                path_string(&jdtls.join("java-test/extensions/z.jar")),
            ]
        );
        let launch = JavaLspLaunch {
            provider_id: JAVA_PROVIDER_ID.to_string(),
            language_id: JAVA_PROVIDER_ID.to_string(),
            executable_path: path_string(&jdk.join("bin/java")),
            arguments: Vec::new(),
            runtime_executable_path: Some(path_string(&jdk.join("bin/java"))),
            jdtls_launch_resources: Some(resources),
            java_home_path: Some(path_string(&jdk)),
            jdtls_version: "1.61.0".to_string(),
        };
        let payload = java_start_payload(
            &launch,
            &root.to_string_lossy(),
            "/tmp/lithe-jdt-cache",
            Some("build=fingerprint"),
            Some(&json!({"version": 1, "reactorPath": "."})),
        );
        assert_eq!(payload["providerId"], "java");
        assert_eq!(
            payload["runtimeExecutablePath"],
            path_string(&jdk.join("bin/java"))
        );
        assert_eq!(
            payload["jdtlsLaunchResources"]["launcherJarPath"],
            path_string(&jdtls.join("plugins/org.eclipse.equinox.launcher_1.jar"))
        );
        assert_eq!(
            payload["jdtlsLaunchResources"]["configurationDirectory"],
            path_string(&jdtls.join(jdtls_configuration_name()))
        );
        assert_eq!(
            payload["jdtlsLaunchResources"]["lombokAgentPath"],
            path_string(&jdtls.join("lombok/lombok.jar"))
        );
        assert_eq!(
            payload["jdtlsLaunchResources"]["javaDebugBundlePath"],
            path_string(&jdtls.join("java-debug/com.microsoft.java.debug.plugin-1.jar"))
        );
        assert_eq!(
            payload["jdtlsLaunchResources"]["javaExtensionBundlePaths"],
            serde_json::json!([
                path_string(&jdtls.join("java-test/extensions/a.jar")),
                path_string(&jdtls.join("java-test/extensions/z.jar"))
            ])
        );
        assert_eq!(payload["workspaceFingerprint"], "build=fingerprint");
        assert_eq!(payload["mavenContext"]["reactorPath"], ".");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_direct_resources_return_an_actionable_error() {
        let root = fixture("missing-resources");
        let jdtls = root.join("jdtls");
        fs::create_dir_all(&jdtls).unwrap();
        let error = resolve_direct_jdtls_resources(&jdtls).expect_err("missing launcher");
        assert!(error.contains("launcher") && error.contains("jdtls"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn parses_java_launch_results_without_building_a_classpath() {
        let entrypoints = parse_java_entrypoints(&json!({
            "schemaVersion": 1,
            "entries": [
                {"sourcePath": "src/App.java", "mainClass": "demo.App", "projectName": "app"},
                {"sourcePath": "src/Other.java", "mainClass": "demo.Other"}
            ]
        }))
        .expect("entrypoints");
        let selected = select_java_entrypoint(&entrypoints, "src/App.java", Some("demo.App"))
            .expect("selected");
        let launch = java_launch_payload(
            &selected,
            &json!({"value": [[ "modules/app" ], ["classes/app", "classes/lib"]]}),
        )
        .expect("launch");
        assert_eq!(launch["mainClass"], "demo.App");
        assert_eq!(launch["projectName"], "app");
        assert_eq!(launch["classPaths"][1], "classes/lib");
        assert!(launch.get("classpath").is_none());
    }

    #[test]
    fn parses_java_build_result_and_rejects_non_success_status() {
        assert!(parse_java_build_result(&json!({"value": 1})).is_ok());
        assert!(parse_java_build_result(&json!({"value": 2})).is_err());
    }

    #[test]
    fn java_run_gate_requires_core_project_preparation_ready() {
        let mut status = JavaLspStatus {
            session_id: Some("java-1".to_string()),
            state: "ready".to_string(),
            error: None,
            project_preparation: Some(json!({"status": "loading", "blocksRun": true})),
            generation: 1,
        };
        assert!(!java_lsp_allows_run(&status));
        status.project_preparation = Some(json!({"status": "ready", "blocksRun": false}));
        assert!(java_lsp_allows_run(&status));
        status.project_preparation = Some(json!({"status": "ready", "blocksRun": true}));
        assert!(!java_lsp_allows_run(&status));
        status.project_preparation = Some(json!({"status": "failed", "blocksRun": false}));
        assert!(java_lsp_allows_run(&status));
    }

    #[test]
    fn operation_results_reject_events_from_another_session() {
        let value = json!({
            "events": [
                {
                    "type": "requestCompleted",
                    "sessionId": "old",
                    "operationId": "op-old",
                    "result": {"value": 1}
                },
                {
                    "type": "requestCompleted",
                    "sessionId": "current",
                    "operationId": "op-current",
                    "error": {
                        "code": "javaBuildCompilationErrors",
                        "message": "compilation failed",
                        "details": "markerScope=launchTarget",
                        "javaBuildReport": {"recovery": "none"}
                    }
                }
            ]
        });
        let results = operation_results_from_poll(&value, "current");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, "op-current");
        assert!(results[0]
            .1
            .error
            .as_deref()
            .unwrap()
            .contains("javaBuildCompilationErrors"));
    }
}
