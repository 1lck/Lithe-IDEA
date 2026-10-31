//! 运行配置的读取、生成与解析。
//!
//! Core 的 `runConfig.*` 命令是纯函数：`generate` 返回文档，宿主负责原子写入
//! `.lithe`。本模块只处理这类文件 I/O 和 JSON 映射，视图层不直接碰 Core。

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use lithe_core_client::CoreClient;
use serde_json::{Value, json};

use super::model::{
    RunConfiguration, RunDiagnostic, RunEditorOptions, RunSaveScope, RunToolchainPaths,
};
use super::session;
use super::toolchain::{self, DiscoveredToolchains, GenericRuntime};

/// 一次加载得到的最终配置。
pub struct LoadedRunConfigurations {
    pub configurations: Vec<RunConfiguration>,
    pub default_id: Option<String>,
    pub diagnostics: Vec<RunDiagnostic>,
}

/// 设置页读取的项目快照。
pub struct RunSettingsSnapshot {
    /// Core 认为项目已经有可运行配置；否则只显示 Identify Again。
    pub ready: bool,
    pub requires_generation: bool,
    pub configurations: Vec<RunConfiguration>,
    pub diagnostics: Vec<RunDiagnostic>,
    /// 文档级项目工具链默认值。
    pub toolchain: RunToolchainPaths,
    pub discovered: DiscoveredToolchains,
    /// Maven 工具窗显式保存的选择，启动时会作为回退。
    pub maven_executable_path: String,
    pub maven_java_home_path: String,
}

/// 编辑器保存时 Core 返回的三份文档。
pub struct RunEditorDocuments {
    pub local_document: String,
    pub project_document: Option<String>,
    pub toolchain_document: Option<String>,
}

/// 工作区文件清单；`generate` 与默认加载都需要它。
fn workspace_paths(client: &CoreClient, root: &Path) -> Result<Vec<String>, String> {
    let root_text = root.to_string_lossy().to_string();
    let snapshot = client
        .execute_raw(
            "workspace.snapshot",
            json!({ "root": root_text, "includeTree": false }),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not scan the project")
            )
        })?;
    Ok(snapshot
        .get("files")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default())
}

/// Tauri 与 GPUI 共用的应用缓存根目录；Core 在下面按工作区保存上次识别结果。
///
/// 必须与 Tauri `appCacheDir()` 指向同一目录，否则 GPUI 在 JDT 尚未接入时读不到
/// Tauri 已缓存的 Java 入口，重新生成会丢掉 `java.main` 并让用户覆盖变成孤儿。
fn run_configuration_cache_directory() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(|base| PathBuf::from(base).join("app.lithe.windows"))
    }
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join("Library/Caches/app.lithe.windows"))
    }
    #[cfg(target_os = "linux")]
    {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
            .map(|base| base.join("app.lithe.windows"))
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

/// `runConfig.generate` 的公共请求体；带上缓存目录才能沿用上次 Java 入口。
fn generate_payload(root_text: &str, paths: Vec<String>) -> Value {
    let mut payload = json!({ "root": root_text, "paths": paths });
    if let Some(cache_directory) = run_configuration_cache_directory() {
        payload["cacheDirectory"] = json!(cache_directory.to_string_lossy());
    }
    payload
}

/// 读取工作区运行配置；需要时先让 Core 重新生成。
pub fn load_configurations(
    client: &CoreClient,
    root: &Path,
) -> Result<LoadedRunConfigurations, String> {
    let root_text = root.to_string_lossy().to_string();
    let paths = workspace_paths(client, root)?;

    // 损坏的 generated.json 不应让项目永久无法运行：inspect 失败时按缺失处理，
    // 下面的 generate 会用新文档覆盖它。其它错误仍会在 generate 阶段报告。
    let inspected = client
        .execute_raw("runConfig.inspect", json!({ "root": root_text }))
        .unwrap_or_else(|_| json!({ "status": "missing" }));

    let needs_generation = inspected
        .get("status")
        .and_then(Value::as_str)
        .is_none_or(|status| status != "ready")
        || inspected
            .get("diagnostics")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .any(|diagnostic| {
                matches!(
                    diagnostic.get("code").and_then(Value::as_str),
                    Some("staleFingerprint" | "staleJavaEntrypoint")
                )
            });

    if needs_generation {
        let generated = client
            .execute_raw(
                "runConfig.generate",
                generate_payload(&root_text, paths),
            )
            .map_err(|error| {
                format!(
                    "{}: {error}",
                    lithe_ui::i18n::tr("Could not read run configuration")
                )
            })?;
        write_generated_documents(root, &generated)?;
    }

    // 工具链候选必须随请求上报：Core 只在候选里找到「同 id + 同 type」的条目时
    // 才把 requirements 声明的工具链视为已选择，否则即使机器上装了 JDK，每个
    // Java 配置都会被判成 “No local java toolchain is selected”。
    let toolchain_candidates = session::toolchain_candidates(root);
    let resolved = client
        .execute_raw(
            "runConfig.resolve",
            json!({
                "root": root_text,
                "toolchainCandidates": toolchain_candidates,
            }),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read run configuration")
            )
        })?;

    // `resolve` 可能在 `inspect` 之后发现新生成的 Java 入口缺少主类。
    // 已经生成过就不再循环；第二次仍失败时把诊断交给界面。
    let configurations = parse_configurations(&resolved);
    let diagnostics = parse_diagnostics(&resolved);
    let default_id = resolved
        .get("defaultRunConfiguration")
        .and_then(Value::as_str)
        .map(str::to_string);

    Ok(LoadedRunConfigurations {
        configurations,
        default_id,
        diagnostics,
    })
}

fn parse_configurations(resolved: &Value) -> Vec<RunConfiguration> {
    resolved
        .get("configurations")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(RunConfiguration::from_json)
                .collect()
        })
        .unwrap_or_default()
}

fn parse_diagnostics(resolved: &Value) -> Vec<RunDiagnostic> {
    resolved
        .get("diagnostics")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(RunDiagnostic::from_json).collect())
        .unwrap_or_default()
}

/// 读取设置页需要的项目快照：inspect、工具链发现、resolve，以及 Maven 回退。
///
/// 发现和解析都可能启动探测进程，调用方必须放到后台线程。
pub fn load_settings_snapshot(
    client: &CoreClient,
    root: &Path,
) -> Result<RunSettingsSnapshot, String> {
    let root_text = root.to_string_lossy().to_string();
    let read_error =
        |error: lithe_core_client::CoreError| -> String {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read run configuration")
            )
        };
    let inspect = |client: &CoreClient| -> Result<Value, String> {
        client
            .execute_raw(
                "runConfig.inspect",
                json!({ "root": root_text, "checkFingerprint": false }),
            )
            .map_err(read_error)
    };
    let mut inspected = inspect(client)?;
    // 与 Tauri `loadProject` 一致：新进程还没有识别结果时先自动识别一次，
    // 不能把“尚未生成”误显示成“项目没有运行配置”。缓存目录会带回上次的
    // Java 入口，避免在没有 JDT 的 GPUI 里丢掉 `java.main`。
    let needs_generation = inspected.get("status").and_then(Value::as_str) != Some("ready")
        || inspected
            .get("requiresGeneration")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    if needs_generation {
        generate_configurations(client, root)?;
        inspected = inspect(client)?;
    }
    let inspection_diagnostics = parse_diagnostics(&inspected);
    let requires_generation = inspected
        .get("requiresGeneration")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    if inspected.get("status").and_then(Value::as_str) != Some("ready") {
        return Ok(RunSettingsSnapshot {
            ready: false,
            requires_generation,
            configurations: Vec::new(),
            diagnostics: inspection_diagnostics,
            toolchain: RunToolchainPaths::default(),
            discovered: DiscoveredToolchains::default(),
            maven_executable_path: String::new(),
            maven_java_home_path: String::new(),
        });
    }

    // 第一轮只报自动发现出的候选，让 Core 告诉我们文档里保存了什么。
    let automatic = toolchain::discover(Some(root));
    let automatic_paths = effective_runtime_executable_paths(&automatic.runtimes, &BTreeMap::new());
    let automatic_selection = RunToolchainPaths {
        runtime_executable_paths: automatic_paths,
        ..RunToolchainPaths::default()
    };
    let preliminary = client
        .execute_raw(
            "runConfig.resolve",
            json!({
                "root": root_text,
                "toolchainCandidates": selected_toolchain_candidates(&automatic, &automatic_selection),
            }),
        )
        .map_err(read_error)?;
    let toolchain = parse_toolchain_paths(
        preliminary.get("toolchain"),
        preliminary.get("localToolchains"),
    );

    // Maven 工具窗的显式选择是启动时的回退；显示也要用同一结果。
    let maven = crate::maven::configuration::load_local(root, ".");
    let maven_executable_path = maven.maven_executable_path.unwrap_or_default();
    let maven_java_home_path = maven.java_home_path.unwrap_or_default();
    let effective_toolchain = RunToolchainPaths {
        maven_executable_path: if toolchain.maven_executable_path.is_empty() {
            maven_executable_path.clone()
        } else {
            toolchain.maven_executable_path.clone()
        },
        ..toolchain.clone()
    };
    let has_selected_toolchain = !toolchain.java_home_path.is_empty()
        || !effective_toolchain.maven_executable_path.is_empty()
        || toolchain
            .runtime_executable_paths
            .values()
            .any(|value| !value.is_empty());

    let (discovered, resolved) = if has_selected_toolchain {
        let discovered = toolchain::discover_with_overrides(
            Some(root),
            Some(&toolchain.java_home_path),
            Some(&effective_toolchain.maven_executable_path),
            Some(&toolchain.runtime_executable_paths),
        );
        let runtime_paths = effective_runtime_executable_paths(
            &discovered.runtimes,
            &toolchain.runtime_executable_paths,
        );
        let selection = RunToolchainPaths {
            java_home_path: effective_toolchain.java_home_path.clone(),
            maven_executable_path: effective_toolchain.maven_executable_path.clone(),
            maven_java_home_path: effective_toolchain.maven_java_home_path.clone(),
            runtime_executable_paths: runtime_paths,
        };
        let resolved = client
            .execute_raw(
                "runConfig.resolve",
                json!({
                    "root": root_text,
                    "toolchainCandidates": selected_toolchain_candidates(&discovered, &selection),
                }),
            )
            .map_err(read_error)?;
        (discovered, resolved)
    } else {
        (automatic, preliminary)
    };

    let mut diagnostics = inspection_diagnostics;
    diagnostics.extend(parse_diagnostics(&resolved));
    Ok(RunSettingsSnapshot {
        ready: true,
        requires_generation,
        configurations: parse_configurations(&resolved),
        diagnostics,
        toolchain,
        discovered,
        maven_executable_path,
        maven_java_home_path,
    })
}

/// 重新识别项目并写回生成层，返回生成的条目数。
pub fn generate_configurations(client: &CoreClient, root: &Path) -> Result<usize, String> {
    let root_text = root.to_string_lossy().to_string();
    let paths = workspace_paths(client, root)?;
    let generated = client
        .execute_raw(
            "runConfig.generate",
            generate_payload(&root_text, paths),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read run configuration")
            )
        })?;
    write_generated_documents(root, &generated)?;
    Ok(generated
        .get("entryCount")
        .and_then(Value::as_u64)
        .unwrap_or(0) as usize)
}

/// 读取文档级工具链默认值；保存编辑器前重新读取，避免旧草稿覆盖设置页改动。
pub fn inspect_defaults(client: &CoreClient, root: &Path) -> Result<RunToolchainPaths, String> {
    let inspected = client
        .execute_raw(
            "runConfig.inspect",
            json!({
                "root": root.to_string_lossy().to_string(),
                "checkFingerprint": false,
            }),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read run configuration")
            )
        })?;
    Ok(parse_toolchain_paths(
        inspected.get("toolchain"),
        inspected.get("localToolchains"),
    ))
}

/// 保存运行配置编辑器；Java/Maven 默认值在保存时重新读取。
pub fn save_editor_changes(
    client: &CoreClient,
    root: &Path,
    configuration_id: &str,
    scope: RunSaveScope,
    options: &RunEditorOptions,
    toolchain: &RunToolchainPaths,
) -> Result<RunEditorDocuments, String> {
    let root_text = root.to_string_lossy().to_string();
    let mut project_toolchain = inspect_defaults(client, root)?;
    project_toolchain.runtime_executable_paths = toolchain.runtime_executable_paths.clone();

    let scoped = |value: &str| -> Option<String> {
        if scope != RunSaveScope::Project || value.trim().is_empty() {
            return Some(value.to_string());
        }
        project_scoped_path(&root_text, value)
    };
    let working_directory = if options.working_directory_path.trim().is_empty() {
        Some(String::new())
    } else if scope == RunSaveScope::Project {
        project_scoped_path(&root_text, &options.working_directory_path)
    } else {
        Some(options.working_directory_path.clone())
    };
    let (Some(working_directory), Some(java_home_path), Some(maven_executable_path), Some(maven_java_home_path)) = (
        working_directory,
        scoped(&options.java_home_path),
        scoped(&options.maven_executable_path),
        scoped(&options.maven_java_home_path),
    ) else {
        return Err(lithe_ui::i18n::tr("Project paths must stay inside the workspace.").to_string());
    };

    let saved = client
        .execute_raw(
            "runConfig.saveEditorChanges",
            json!({
                "root": root_text,
                "scope": scope.wire(),
                "configurationId": configuration_id,
                "workingDirectory": working_directory,
                "jvmArguments": options.vm_arguments,
                "arguments": options.program_arguments,
                "environment": options.environment,
                "mavenProfiles": [],
                "mavenSkipTests": options.maven_skip_tests,
                "javaHomePath": java_home_path,
                "mavenExecutablePath": maven_executable_path,
                "mavenJavaHomePath": maven_java_home_path,
                "toolchain": {
                    "javaHomePath": project_toolchain.java_home_path,
                    "mavenExecutablePath": project_toolchain.maven_executable_path,
                    "mavenJavaHomePath": project_toolchain.maven_java_home_path,
                    "runtimeExecutablePaths": project_toolchain.runtime_executable_paths,
                },
            }),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not save run configuration")
            )
        })?;

    Ok(RunEditorDocuments {
        local_document: saved
            .get("localDocument")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                lithe_ui::i18n::tr("Could not read run configuration").to_string()
            })?
            .to_string(),
        project_document: saved
            .get("projectDocument")
            .and_then(Value::as_str)
            .map(str::to_string),
        toolchain_document: saved
            .get("toolchainDocument")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

/// 原子写入编辑器保存产生的文档。
pub fn write_editor_documents(root: &Path, documents: &RunEditorDocuments) -> Result<(), String> {
    let run_directory = root.join(".lithe").join("run");
    fs::create_dir_all(&run_directory).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    atomic_write(&run_directory.join("local.json"), &documents.local_document)?;
    if let Some(project_document) = &documents.project_document {
        atomic_write(&run_directory.join("configurations.json"), project_document)?;
    }
    if let Some(toolchain_document) = &documents.toolchain_document {
        let toolchain_directory = root.join(".lithe").join("toolchains");
        fs::create_dir_all(&toolchain_directory).map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not save run configuration")
            )
        })?;
        atomic_write(
            &toolchain_directory.join("local.json"),
            toolchain_document,
        )?;
    }
    update_gitignore(root)
}

/// 文档级工具链：`toolchain` 是全局选择，`localToolchains` 保存通用运行时。
fn parse_toolchain_paths(toolchain: Option<&Value>, local_toolchains: Option<&Value>) -> RunToolchainPaths {
    let string_at = |value: Option<&Value>, keys: &[&str]| -> String {
        let mut current = value;
        for key in keys {
            current = current.and_then(|value| value.get(*key));
        }
        current.and_then(Value::as_str).unwrap_or("").to_string()
    };
    let mut runtime_executable_paths = BTreeMap::new();
    if let Some(toolchains) = local_toolchains
        .and_then(|value| value.get("toolchains"))
        .and_then(Value::as_object)
    {
        for (id, entry) in toolchains {
            if let Some(executable) = entry
                .get("executable")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
            {
                runtime_executable_paths.insert(id.clone(), executable.to_string());
            }
        }
    }
    RunToolchainPaths {
        java_home_path: string_at(toolchain, &["java", "homePath"]),
        maven_executable_path: string_at(toolchain, &["maven", "executablePath"]),
        maven_java_home_path: string_at(toolchain, &["maven", "javaHomePath"]),
        runtime_executable_paths,
    }
}

/// 每个运行时 id 实际生效的可执行文件：有配置时只认同名同路径的候选。
fn effective_runtime_executable_paths(
    runtimes: &[GenericRuntime],
    configured: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let ids: BTreeSet<&str> = runtimes.iter().map(|runtime| runtime.id.as_str()).collect();
    ids.into_iter()
        .filter_map(|id| {
            let configured_path = configured.get(id).filter(|value| !value.is_empty());
            let runtime = match configured_path {
                Some(path) => runtimes
                    .iter()
                    .find(|runtime| runtime.id == id && same_windows_path(&runtime.executable_path, path)),
                None => runtimes.iter().find(|runtime| runtime.id == id),
            }?;
            Some((id.to_string(), runtime.executable_path.clone()))
        })
        .collect()
}

/// Core `runConfig.resolve` 的工具链候选；只上报确实探测到的条目。
fn selected_toolchain_candidates(
    discovered: &DiscoveredToolchains,
    selected: &RunToolchainPaths,
) -> Vec<Value> {
    let mut candidates = Vec::new();
    let java = if selected.java_home_path.is_empty() {
        discovered.java.first()
    } else {
        discovered
            .java
            .iter()
            .find(|runtime| same_windows_path(&runtime.home_path, &selected.java_home_path))
    };
    if let Some(java) = java {
        candidates.push(json!({
            "id": "project-jdk",
            "type": "java",
            "version": java.version,
            "vendor": java.vendor,
        }));
    }
    let maven = if selected.maven_executable_path.is_empty() {
        discovered.maven.first()
    } else {
        discovered.maven.iter().find(|runtime| {
            maven_selection_matches_runtime(
                &selected.maven_executable_path,
                &runtime.executable_path,
            )
        })
    };
    if let Some(maven) = maven {
        candidates.push(json!({
            "id": "project-maven",
            "type": "maven",
            "version": maven.version,
            "vendor": "",
        }));
    }
    let runtime_paths =
        effective_runtime_executable_paths(&discovered.runtimes, &selected.runtime_executable_paths);
    for (id, executable_path) in runtime_paths {
        if let Some(runtime) = discovered.runtimes.iter().find(|candidate| {
            candidate.id == id && same_windows_path(&candidate.executable_path, &executable_path)
        }) {
            candidates.push(json!({
                "id": runtime.id,
                "type": runtime.kind,
                "version": runtime.version,
                "vendor": runtime.vendor,
            }));
        }
    }
    candidates
}

/// Maven 选择可能是安装根目录，也可能是 `bin` 下的启动器。
fn maven_selection_matches_runtime(selection: &str, executable: &str) -> bool {
    if same_windows_path(selection, executable) {
        return true;
    }
    let home = selection.replace(['\\', '/'], "/");
    let home = home.trim_end_matches('/');
    [
        "mvnd.exe", "mvnd.cmd", "mvnd.bat", "mvnd", "mvn.cmd", "mvn.bat", "mvn.exe", "mvn",
    ]
    .iter()
    .any(|name| {
        same_windows_path(&format!("{home}/bin/{name}"), executable)
            || same_windows_path(&format!("{home}/{name}"), executable)
    })
}

/// Windows 路径比较：大小写、斜杠和结尾分隔符不敏感。
pub(crate) fn same_windows_path(left: &str, right: &str) -> bool {
    if left.is_empty() || right.is_empty() {
        return false;
    }
    let normalize = |value: &str| {
        let mut value = value.replace('\\', "/");
        while value.ends_with('/') {
            value.pop();
        }
        value.to_lowercase()
    };
    normalize(left) == normalize(right)
}

/// 绝对路径不受保存范围限制。
fn is_absolute_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    (bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/'))
        || value.starts_with('/')
        || value.starts_with("\\\\")
}

/// 工作区内的相对路径；`file_path` 等于根目录时返回 `.`。
pub(crate) fn workspace_relative_path(root: &str, file_path: &str) -> Option<String> {
    let normalized_root = root.trim_end_matches(['\\', '/']).replace('\\', "/");
    let normalized_file = file_path.replace('\\', "/");
    if normalized_file.to_lowercase() == normalized_root.to_lowercase() {
        return Some(".".to_string());
    }
    if !normalized_file
        .to_lowercase()
        .starts_with(&(normalized_root.to_lowercase() + "/"))
    {
        return None;
    }
    Some(normalized_file[normalized_root.len() + 1..].to_string())
}

/// 项目范围保存时，路径必须是工作区相对路径；空值表示 `.`。
pub(crate) fn project_scoped_path(root: &str, value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Some(".".to_string());
    }
    if let Some(relative) = workspace_relative_path(root, trimmed) {
        return Some(relative);
    }
    if is_absolute_path(trimmed) {
        return None;
    }
    Some(trimmed.replace('\\', "/"))
}

/// 环境变量按 key 排序后每行 `KEY=VALUE`。
pub(crate) fn environment_text(environment: &BTreeMap<String, String>) -> String {
    environment
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// 从 `KEY=VALUE` 文本恢复环境变量；空行和 `#` 注释忽略。
pub(crate) fn environment_from_text(text: &str) -> BTreeMap<String, String> {
    let mut environment = BTreeMap::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some(separator) = trimmed.find('=') else {
            continue;
        };
        if separator == 0 {
            continue;
        }
        environment.insert(
            trimmed[..separator].to_string(),
            trimmed[separator + 1..].to_string(),
        );
    }
    environment
}

/// 原子写入 Core 生成的两份文档，并维护 `.lithe/.gitignore`。
fn write_generated_documents(root: &Path, generated: &Value) -> Result<(), String> {
    let run_directory = root.join(".lithe").join("run");
    let toolchain_directory = root.join(".lithe").join("toolchains");
    fs::create_dir_all(&run_directory).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    fs::create_dir_all(&toolchain_directory).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;

    let document = generated
        .get("generated")
        .cloned()
        .ok_or_else(|| lithe_ui::i18n::tr("Could not read run configuration").to_string())?;
    write_json(&run_directory.join("generated.json"), &document)?;

    let requirements = generated
        .get("toolchainRequirements")
        .cloned()
        .unwrap_or_else(|| json!({ "version": 1, "toolchains": {} }));
    write_json(
        &toolchain_directory.join("requirements.json"),
        &requirements,
    )?;

    update_gitignore(root)?;
    Ok(())
}

fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    let text = serde_json::to_string_pretty(value).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    atomic_write(path, &text)
}

fn atomic_write(path: &Path, text: &str) -> Result<(), String> {
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    fs::write(&temporary, text).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    fs::rename(&temporary, path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })
}

/// `.lithe` 下只有生成物与本地层；本地层和临时文件不应进入版本库。
fn update_gitignore(root: &Path) -> Result<(), String> {
    const ENTRIES: [&str; 4] = [
        "run/local.json",
        "toolchains/local.json",
        "run/classes/",
        "**/*.tmp",
    ];
    let directory = root.join(".lithe");
    let path = directory.join(".gitignore");
    let mut existing = fs::read_to_string(&path).unwrap_or_default();
    let mut changed = false;
    for entry in ENTRIES {
        if !existing.lines().any(|line| line.trim() == entry) {
            if !existing.is_empty() && !existing.ends_with('\n') {
                existing.push('\n');
            }
            existing.push_str(entry);
            existing.push('\n');
            changed = true;
        }
    }
    if changed {
        fs::write(&path, existing).map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not save run configuration")
            )
        })?;
    }
    Ok(())
}

/// 工作区根目录，空路径表示未打开项目。
pub fn normalize_root(root: PathBuf) -> Option<PathBuf> {
    if root.as_os_str().is_empty() {
        None
    } else {
        Some(root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn generates_configuration_from_package_scripts() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("lithe-run-config-{}-{unique}", std::process::id()));
        fs::create_dir_all(&root).expect("temp project should be created");
        fs::write(root.join("package.json"), r#"{"scripts":{"dev":"vite"}}"#)
            .expect("package.json should be written");
        let generated = load_configurations(&CoreClient::new(), &root);
        let _ = fs::remove_dir_all(&root);
        let loaded = generated.expect("run configuration should load");
        assert!(
            loaded
                .configurations
                .iter()
                .any(|configuration| configuration.provider == "npm.script")
        );
    }

    #[test]
    fn project_scoped_paths_only_accept_workspace_relative_values() {
        let root = r"C:\work\project";
        assert_eq!(project_scoped_path(root, "").as_deref(), Some("."));
        assert_eq!(
            project_scoped_path(root, r"C:\work\project\service\app").as_deref(),
            Some("service/app")
        );
        assert_eq!(
            project_scoped_path(root, "service/app").as_deref(),
            Some("service/app")
        );
        assert_eq!(project_scoped_path(root, r"D:\other\jdk"), None);
        assert_eq!(project_scoped_path(root, "/opt/jdk"), None);
    }

    #[test]
    fn environment_round_trips_sorted_key_value_lines() {
        let text = "B=2\n# comment\nA=1\n\nbroken\n=C";
        let environment = environment_from_text(text);
        assert_eq!(environment.get("A").map(String::as_str), Some("1"));
        assert_eq!(environment.get("B").map(String::as_str), Some("2"));
        assert_eq!(environment.len(), 2);
        assert_eq!(environment_text(&environment), "A=1\nB=2");
    }

    #[test]
    fn windows_path_comparison_ignores_case_and_separators() {
        assert!(same_windows_path(r"C:\Java\jdk-21", "c:/java/jdk-21/"));
        assert!(!same_windows_path("", ""));
        assert!(!same_windows_path(r"C:\Java\jdk-21", r"C:\Java\jdk-17"));
    }

    #[test]
    fn maven_selection_matches_install_root_and_launcher() {
        assert!(maven_selection_matches_runtime(
            r"C:\Tools\apache-maven-3.9.9",
            r"C:\Tools\apache-maven-3.9.9\bin\mvn.cmd"
        ));
        assert!(maven_selection_matches_runtime(
            r"C:\Tools\apache-maven-3.9.9\bin\mvnd.exe",
            r"C:\Tools\apache-maven-3.9.9\bin\mvnd.exe"
        ));
        assert!(!maven_selection_matches_runtime(
            r"C:\Tools\apache-maven-3.9.9",
            r"C:\Tools\other-maven\bin\mvn.cmd"
        ));
    }
}
