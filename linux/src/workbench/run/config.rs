//! Run 配置文档、工具链读取和 Linux 启动计划的纯适配。
//!
//! 这里不判断 Java 入口是否存在，也不从源码文本推导项目模型；这些事实由
//! Core/JDT 生成。Linux 只保存 Core 返回的文档，并把平台路径和工具链选择
//! 解析成 `std::process::Command` 所需的形状。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{json, Value};

const SIDECAR_VERSION: u32 = 1;
const RUN_VERSION: u32 = 2;
const MAX_JAVA_SOURCES: usize = 8_000;
const MAX_JAVA_WALK_DEPTH: usize = 32;
const LITHE_GITIGNORE_ENTRIES: &[&str] = &[
    "run/local.json",
    "toolchains/local.json",
    "run/classes/",
    "**/*.tmp",
];

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Core 解析后的一个有效运行配置。
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct RunConfigItem {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub kind: String,
    pub detail: String,
    pub execution: String,
    pub category: String,
    pub cwd: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub toolchains: BTreeMap<String, String>,
    pub extensions: Value,
    pub main_class: Option<String>,
    pub source: Option<String>,
    pub module: Option<String>,
    pub raw: Value,
}

impl RunConfigItem {
    /// 从 `runConfig.resolve` 的有效配置项构造展示模型。
    pub fn from_value(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let id = object.get("id")?.as_str()?.to_string();
        let name = object
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(&id)
            .to_string();
        let provider = object
            .get("provider")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let command = object.get("command").and_then(Value::as_str);
        let extensions = object
            .get("extensions")
            .cloned()
            .unwrap_or_else(|| json!({}));
        let toolchains = string_map(object.get("toolchains"));
        let args = string_array(object.get("args")).unwrap_or_default();
        let env = string_map(object.get("env"));
        let module = extensions
            .get("maven")
            .and_then(|maven| maven.get("module"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let main_class = extensions
            .get("maven")
            .and_then(|maven| maven.get("mainClass"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let source = extensions
            .get("java")
            .and_then(|java| java.get("source"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let kind = if provider.starts_with("java.") {
            "java".to_string()
        } else if provider.contains("maven") || toolchains.contains_key("maven") {
            "maven".to_string()
        } else if command.is_some_and(|value| {
            let lower = value.to_ascii_lowercase();
            lower.contains("npm")
                || lower.contains("node")
                || lower.contains("pnpm")
                || lower.contains("yarn")
        }) {
            "npm".to_string()
        } else {
            "process".to_string()
        };
        let detail = main_class
            .clone()
            .or_else(|| module.clone())
            .or_else(|| source.clone())
            .or_else(|| {
                let value = args.join(" ");
                (!value.is_empty()).then_some(value)
            })
            .or_else(|| command.map(str::to_string))
            .unwrap_or_else(|| provider.clone());
        Some(Self {
            id,
            name,
            provider,
            kind,
            detail,
            execution: object
                .get("execution")
                .and_then(Value::as_str)
                .unwrap_or("application")
                .to_string(),
            category: object
                .get("category")
                .and_then(Value::as_str)
                .unwrap_or("project")
                .to_string(),
            cwd: object
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .unwrap_or(".")
                .to_string(),
            args,
            env,
            toolchains,
            extensions,
            main_class,
            source,
            module,
            raw: value.clone(),
        })
    }

    pub fn uses_maven(&self) -> bool {
        self.toolchains.contains_key("maven")
            || self.provider.contains("maven")
            || (self.provider == "java.main"
                && self
                    .extensions
                    .get("maven")
                    .and_then(|value| value.get("module"))
                    .is_some())
    }

    pub fn java_home_path(&self) -> Option<&str> {
        self.extensions
            .get("java")
            .and_then(|java| java.get("homePath"))
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
    }

    pub fn maven_executable_path(&self) -> Option<&str> {
        self.extensions
            .get("java")
            .and_then(|java| java.get("mavenExecutablePath"))
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
    }

    pub fn maven_java_home_path(&self) -> Option<&str> {
        self.extensions
            .get("java")
            .and_then(|java| java.get("mavenJavaHomePath"))
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
    }
}

/// 判断一次异步结果是否仍属于当前请求；旧 reload/execution token 必须被拒绝。
pub fn sequence_is_current(current: u64, expected: u64) -> bool {
    current == expected
}

/// Core resolve 返回的项目快照。
#[derive(Debug, Clone)]
pub struct ResolvedRunProject {
    pub configurations: Vec<RunConfigItem>,
    pub default_configuration_id: Option<String>,
    pub diagnostics: Vec<String>,
}

/// 解析 Core 的有效配置数组，保留稳定顺序并提取可展示错误。
pub fn parse_resolved_configurations(value: &Value) -> Result<ResolvedRunProject, String> {
    let configurations = value
        .get("configurations")
        .and_then(Value::as_array)
        .ok_or_else(|| "Run configuration resolve returned no configurations array".to_string())?;
    let parsed = configurations
        .iter()
        .filter_map(RunConfigItem::from_value)
        .collect::<Vec<_>>();
    let default_configuration_id = value
        .get("defaultRunConfiguration")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_string);
    let diagnostics = value
        .get("diagnostics")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    item.get("message")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .or_else(|| item.as_str().map(str::to_string))
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(ResolvedRunProject {
        configurations: parsed,
        default_configuration_id,
        diagnostics,
    })
}

/// Tauri 持久化规则中的默认配置：优先框架服务，其次非 Current File。
pub fn default_generated_configuration_id(generated: &Value) -> Option<String> {
    let configurations = generated.get("configurations").and_then(Value::as_array)?;
    let framework = configurations.iter().find(|item| {
        matches!(
            item.get("provider").and_then(Value::as_str),
            Some("spring-boot.maven" | "quarkus.maven" | "micronaut.maven")
        )
    });
    framework
        .or_else(|| {
            configurations
                .iter()
                .find(|item| item.get("id").and_then(Value::as_str) != Some("current-file"))
        })
        .and_then(|item| item.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// 只列出 Java 文件路径，不读取源码、不判断 main；入口事实仍由 Core/JDT 提供。
pub fn list_java_sources(root: &str) -> Vec<String> {
    fn walk(root: &Path, directory: &Path, depth: usize, output: &mut Vec<String>) {
        if depth > MAX_JAVA_WALK_DEPTH || output.len() >= MAX_JAVA_SOURCES {
            return;
        }
        let Ok(entries) = fs::read_dir(directory) else {
            return;
        };
        let mut entries = entries.filter_map(Result::ok).collect::<Vec<_>>();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            if output.len() >= MAX_JAVA_SOURCES {
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                if name.starts_with('.') || is_build_directory(&name) {
                    continue;
                }
                walk(root, &path, depth + 1, output);
            } else if file_type.is_file() && name.to_ascii_lowercase().ends_with(".java") {
                if let Ok(relative) = path.strip_prefix(root) {
                    output.push(relative.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }

    let root_path = Path::new(root);
    let mut output = Vec::new();
    walk(root_path, root_path, 0, &mut output);
    output.sort();
    output.dedup();
    output
}

fn is_build_directory(name: &str) -> bool {
    matches!(
        name,
        "target"
            | "build"
            | "out"
            | "dist"
            | "node_modules"
            | "vendor"
            | "coverage"
            | "bin"
            | "obj"
            | ".gradle"
    )
}

/// Linux 主机保存的机器工具链选择。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolchainPaths {
    pub java_home_path: String,
    pub maven_executable_path: String,
    pub maven_java_home_path: String,
    pub runtime_executable_paths: BTreeMap<String, String>,
    pub maven_settings_path: String,
    pub local_repository_path: String,
}

/// 读取 canonical Core 形状以及旧 Linux 扁平键；canonical 值优先。
pub fn read_toolchain_paths(root: &str) -> ToolchainPaths {
    let mut result = ToolchainPaths::default();
    let local_path = Path::new(root).join(".lithe/run/local.json");
    if let Ok(text) = fs::read_to_string(local_path) {
        if let Ok(document) = serde_json::from_str::<Value>(&text) {
            let toolchain = document.get("toolchain");
            result.java_home_path = first_toolchain_value(toolchain, &["javaHomePath", "javaHome"])
                .or_else(|| nested_toolchain_value(toolchain, "java", "homePath"))
                .unwrap_or_default();
            result.maven_executable_path =
                first_toolchain_value(toolchain, &["mavenExecutablePath", "mavenExecutable"])
                    .or_else(|| nested_toolchain_value(toolchain, "maven", "executablePath"))
                    .unwrap_or_default();
            result.maven_java_home_path =
                first_toolchain_value(toolchain, &["mavenJavaHomePath", "mavenJavaHome"])
                    .or_else(|| nested_toolchain_value(toolchain, "maven", "javaHomePath"))
                    .unwrap_or_default();
        }
    }
    let local_toolchains_path = Path::new(root).join(".lithe/toolchains/local.json");
    if let Ok(text) = fs::read_to_string(local_toolchains_path) {
        if let Ok(document) = serde_json::from_str::<Value>(&text) {
            if let Some(entries) = document.get("toolchains").and_then(Value::as_object) {
                for (id, entry) in entries {
                    if let Some(executable) = entry
                        .get("executable")
                        .and_then(Value::as_str)
                        .filter(|value| !value.trim().is_empty())
                    {
                        result
                            .runtime_executable_paths
                            .insert(id.clone(), executable.to_string());
                    }
                }
            }
        }
    }
    result
}

fn first_toolchain_value(toolchain: Option<&Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        toolchain
            .and_then(|value| value.get(*key))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

fn nested_toolchain_value(toolchain: Option<&Value>, group: &str, key: &str) -> Option<String> {
    toolchain
        .and_then(|value| value.get(group))
        .and_then(|value| value.get(key))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// 构造 Core resolve 所需的候选；候选只描述已发现的真实路径，不执行安装探测。
pub fn toolchain_candidates(root: &str, paths: &ToolchainPaths) -> Vec<Value> {
    let mut candidates = Vec::new();
    let mut add = |id: &str, kind: &str, path: &str| {
        if path.trim().is_empty() {
            return;
        }
        let candidate = Path::new(root).join(path);
        let exists = candidate.is_file() || candidate.is_dir();
        if exists {
            candidates.push(json!({
                "id": id,
                "type": kind,
                "version": "",
                "vendor": ""
            }));
        }
    };
    add("project-jdk", "java", &paths.java_home_path);
    add("project-maven", "maven", &paths.maven_executable_path);
    if let Some(node) = paths.runtime_executable_paths.get("project-node") {
        add("project-node", "node", node);
    }
    candidates
}

/// 写回项目 local 层；保留配置覆盖和旧文档其它字段。
pub fn write_toolchain_paths(root: &str, paths: &ToolchainPaths) -> Result<(), String> {
    let path = Path::new(root).join(".lithe/run/local.json");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut document = match fs::read_to_string(&path) {
        Ok(text) => {
            let value: Value = serde_json::from_str(&text)
                .map_err(|error| format!("Run local configuration is invalid JSON: {error}"))?;
            if !value.is_object() {
                return Err("Run local configuration must be a JSON object.".to_string());
            }
            value
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            json!({"version": RUN_VERSION, "configurations": []})
        }
        Err(error) => return Err(error.to_string()),
    };
    if document.get("version").is_none() {
        document["version"] = json!(RUN_VERSION);
    }
    let mut toolchain = document
        .get("toolchain")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for legacy in ["javaHome", "mavenExecutable", "mavenJavaHome"] {
        toolchain.remove(legacy);
    }
    toolchain.insert("javaHomePath".to_string(), json!(paths.java_home_path));
    toolchain.insert(
        "mavenExecutablePath".to_string(),
        json!(paths.maven_executable_path),
    );
    toolchain.insert(
        "mavenJavaHomePath".to_string(),
        json!(paths.maven_java_home_path),
    );
    toolchain.insert(
        "java".to_string(),
        json!({"homePath": paths.java_home_path}),
    );
    toolchain.insert(
        "maven".to_string(),
        json!({
            "executablePath": paths.maven_executable_path,
            "javaHomePath": paths.maven_java_home_path
        }),
    );
    document["toolchain"] = Value::Object(toolchain);
    write_json_atomically(&path, &document)
}

/// 写 Core 生成结果及三个 `.lithe` 辅助文档；任一写入失败会恢复已写文件。
pub fn write_generated_documents(
    root: &str,
    generated: &Value,
    requirements: &Value,
    default_configuration_id: Option<&str>,
) -> Result<(), String> {
    let root_path = Path::new(root);
    if !root_path.is_dir() {
        return Err("The project directory is unavailable.".to_string());
    }
    let lithe = root_path.join(".lithe");
    let run_dir = lithe.join("run");
    let toolchain_dir = lithe.join("toolchains");
    let generated_path = run_dir.join("generated.json");
    let requirements_path = toolchain_dir.join("requirements.json");
    let ignore_path = lithe.join(".gitignore");
    let manifest_path = lithe.join("project.json");

    fs::create_dir_all(&run_dir).map_err(|error| error.to_string())?;
    fs::create_dir_all(&toolchain_dir).map_err(|error| error.to_string())?;

    let manifest = if manifest_path.exists() {
        fs::read(&manifest_path).map_err(|error| error.to_string())?
    } else {
        let mut value = json!({"version": SIDECAR_VERSION});
        if let Some(id) = default_configuration_id.filter(|id| !id.trim().is_empty()) {
            value["defaultRunConfiguration"] = json!(id);
        }
        serde_json::to_vec_pretty(&value).map_err(|error| error.to_string())?
    };
    let ignore = ensure_gitignore(&ignore_path)?;
    let generated_bytes =
        serde_json::to_vec_pretty(generated).map_err(|error| error.to_string())?;
    let requirements_bytes =
        serde_json::to_vec_pretty(requirements).map_err(|error| error.to_string())?;
    let documents = [
        (generated_path, generated_bytes),
        (requirements_path, requirements_bytes),
        (ignore_path, ignore),
        (manifest_path, manifest),
    ];
    write_document_transaction(&documents)
}

fn ensure_gitignore(path: &Path) -> Result<Vec<u8>, String> {
    let existing = if path.is_file() {
        fs::read_to_string(path).map_err(|error| error.to_string())?
    } else {
        String::new()
    };
    let mut lines = existing.lines().map(str::to_string).collect::<Vec<_>>();
    for entry in LITHE_GITIGNORE_ENTRIES {
        if !lines.iter().any(|line| line.trim() == *entry) {
            lines.push((*entry).to_string());
        }
    }
    Ok(format!("{}\n", lines.join("\n")).into_bytes())
}

fn write_document_transaction(documents: &[(PathBuf, Vec<u8>)]) -> Result<(), String> {
    let snapshots = documents
        .iter()
        .map(|(path, _)| {
            if path.exists() {
                fs::read(path).map(Some).map_err(|error| error.to_string())
            } else {
                Ok(None)
            }
        })
        .collect::<Result<Vec<_>, String>>()?;
    let mut completed: Vec<&Path> = Vec::new();
    for (path, contents) in documents {
        if let Err(error) = write_bytes_atomically(path, contents) {
            let mut rollback_error = None;
            for completed_path in completed.iter().rev() {
                let index = documents
                    .iter()
                    .position(|(candidate, _)| candidate == completed_path)
                    .unwrap_or(0);
                let result = match &snapshots[index] {
                    Some(previous) => write_bytes_atomically(completed_path, previous),
                    None => fs::remove_file(completed_path).or_else(|error| {
                        if error.kind() == std::io::ErrorKind::NotFound {
                            Ok(())
                        } else {
                            Err(error.to_string())
                        }
                    }),
                };
                if let Err(error) = result {
                    rollback_error = Some(error);
                }
            }
            return match rollback_error {
                Some(rollback) => Err(format!("{error}; rollback failed: {rollback}")),
                None => Err(error),
            };
        }
        completed.push(path.as_path());
    }
    Ok(())
}

fn write_json_atomically(path: &Path, value: &Value) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
    write_bytes_atomically(path, &bytes)
}

fn write_bytes_atomically(path: &Path, contents: &[u8]) -> Result<(), String> {
    if path.exists() {
        if fs::read(path).ok().as_deref() == Some(contents) {
            return Ok(());
        }
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("document.json");
    let temporary = path.with_file_name(format!(
        ".{file_name}.{}.tmp",
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    fs::write(&temporary, contents).map_err(|error| error.to_string())?;
    // Windows 的 `rename` 不会覆盖已存在目标，先移除旧文件。
    #[cfg(windows)]
    {
        let _ = fs::remove_file(path);
    }
    match fs::rename(&temporary, path) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            Err(error.to_string())
        }
    }
}

/// Core `createLaunchPlan` 的 Linux 形状。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchExecutable {
    pub toolchain: Option<String>,
    pub command: Option<String>,
    pub tool: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreLaunchStep {
    pub executable: LaunchExecutable,
    pub arguments: Vec<String>,
    pub classpath: Vec<String>,
    pub modulepath: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub executable: LaunchExecutable,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub environment: BTreeMap<String, Value>,
    pub env: BTreeMap<String, String>,
    pub pre_launch_steps: Vec<PreLaunchStep>,
    pub classpath: Vec<String>,
    pub modulepath: Vec<String>,
}

impl LaunchPlan {
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let executable = value
            .get("executable")
            .ok_or_else(|| "Launch plan has no executable".to_string())?;
        let executable = LaunchExecutable::from_value(executable)?;
        let arguments = string_array(value.get("arguments"))
            .ok_or_else(|| "Launch plan arguments must be an array of strings".to_string())?;
        let pre_launch_steps = value
            .get("preLaunchSteps")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .map(PreLaunchStep::from_value)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            executable,
            arguments,
            working_directory: value
                .get("workingDirectory")
                .and_then(Value::as_str)
                .filter(|cwd| !cwd.is_empty())
                .unwrap_or(".")
                .to_string(),
            environment: value
                .get("environment")
                .and_then(Value::as_object)
                .map(|entries| {
                    entries
                        .iter()
                        .map(|(key, value)| (key.clone(), value.clone()))
                        .collect()
                })
                .unwrap_or_default(),
            env: string_map(value.get("env")),
            pre_launch_steps,
            classpath: string_array(value.get("classpath")).unwrap_or_default(),
            modulepath: string_array(value.get("modulepath")).unwrap_or_default(),
        })
    }
}

impl LaunchExecutable {
    fn from_value(value: &Value) -> Result<Self, String> {
        let object = value
            .as_object()
            .ok_or_else(|| "Launch executable must be an object".to_string())?;
        let toolchain = object
            .get("toolchain")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let command = object
            .get("command")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let tool = object
            .get("tool")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        if toolchain.is_none() && command.is_none() {
            return Err("Launch executable names neither a toolchain nor a command".to_string());
        }
        Ok(Self {
            toolchain,
            command,
            tool,
        })
    }
}

impl PreLaunchStep {
    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(Self {
            executable: LaunchExecutable::from_value(
                value
                    .get("executable")
                    .ok_or_else(|| "Pre-launch step has no executable".to_string())?,
            )?,
            arguments: string_array(value.get("arguments")).ok_or_else(|| {
                "Pre-launch step arguments must be an array of strings".to_string()
            })?,
            classpath: string_array(value.get("classpath")).unwrap_or_default(),
            modulepath: string_array(value.get("modulepath")).unwrap_or_default(),
        })
    }
}

/// 为 Core 构造 Maven 上下文；上下文只承载项目默认值，不重新推断模块。
pub fn maven_context_for_configuration(item: &RunConfigItem, toolchains: &ToolchainPaths) -> Value {
    let maven = item.extensions.get("maven");
    let profiles = maven
        .and_then(|value| value.get("profiles"))
        .and_then(Value::as_array)
        .map(|items| {
            let mut values = items
                .iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>();
            values.sort();
            values.dedup();
            values
        })
        .unwrap_or_default();
    let reactor_path = maven
        .and_then(|value| value.get("reactorPath"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or(item.cwd.as_str())
        .to_string();
    json!({
        "version": 1,
        "reactorPath": reactor_path,
        "profiles": profiles,
        "settingsPath": if toolchains.maven_settings_path.is_empty() { Value::Null } else { json!(toolchains.maven_settings_path) },
        "localRepositoryPath": if toolchains.local_repository_path.is_empty() { Value::Null } else { json!(toolchains.local_repository_path) },
        "skipTests": maven.and_then(|value| value.get("skipTests")).and_then(Value::as_bool).unwrap_or(false),
        "mavenExecutablePath": item.maven_executable_path().or(Some(toolchains.maven_executable_path.as_str())).filter(|value| !value.is_empty()).map(Value::from).unwrap_or(Value::Null),
        "javaHomePath": item
            .maven_java_home_path()
            .or(Some(toolchains.maven_java_home_path.as_str()))
            .filter(|value| !value.is_empty())
            .map(Value::from)
            .unwrap_or(Value::Null),
    })
}

/// POSIX 下把 Core 的结构化路径合并到已有 JVM 参数，避免第二个 `-cp` 覆盖它。
pub fn merge_java_paths(
    arguments: &[String],
    paths: &[String],
    default_flag: &str,
    existing_flags: &[&str],
) -> Vec<String> {
    if paths.is_empty() {
        return arguments.to_vec();
    }
    let joined = paths.join(":");
    let mut result = arguments.to_vec();
    for index in (0..result.len().saturating_sub(1)).rev() {
        if existing_flags.iter().any(|flag| *flag == result[index]) {
            result[index + 1] = format!("{joined}:{}", result[index + 1]);
            return result;
        }
    }
    let mut with_path = vec![default_flag.to_string(), joined];
    with_path.append(&mut result);
    with_path
}

/// 生成 `runConfig.createLaunchPlan` 请求；Linux 不填充 JDT 专属元数据。
pub fn create_launch_plan_request(
    root: &str,
    item: &RunConfigItem,
    current_file: Option<&str>,
    maven_context: Option<&Value>,
    java_launch: Option<&Value>,
) -> Value {
    let mut payload = json!({
        "root": root,
        "configurationId": item.id,
    });
    if let Some(current_file) = current_file {
        payload["currentFile"] = json!(current_file);
    }
    if let Some(context) = maven_context {
        payload["mavenContext"] = context.clone();
    }
    if let Some(launch) = java_launch {
        payload["javaLaunch"] = launch.clone();
    }
    payload
}

fn string_array(value: Option<&Value>) -> Option<Vec<String>> {
    value?
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_string))
        .collect()
}

fn string_map(value: Option<&Value>) -> BTreeMap<String, String> {
    value
        .and_then(Value::as_object)
        .map(|object| {
            object
                .iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| (key.clone(), value.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn fixture(name: &str) -> Fixture {
        let path = std::env::temp_dir().join(format!(
            "lithe-linux-config-{name}-{}-{}",
            std::process::id(),
            TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).expect("fixture");
        Fixture(path)
    }

    fn core_data(command: &str, payload: Value) -> Value {
        let request = json!({
            "id": format!("linux-test-{command}"),
            "command": command,
            "payload": payload
        });
        let response: Value = serde_json::from_str(&lithe_core::execute_json(&request.to_string()))
            .expect("core response");
        assert_eq!(response["ok"], true, "core response: {response}");
        response["data"].clone()
    }

    fn write_generated(root: &Path, configurations: Value) {
        let path = root.join(".lithe/run/generated.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            path,
            serde_json::to_vec(&json!({"version": 2, "configurations": configurations})).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn core_plan_keeps_process_and_spring_goals_without_compile_fallback() {
        let fixture = fixture("core-plan");
        let root = fixture.0.to_string_lossy().into_owned();
        write_generated(
            &fixture.0,
            json!([
                {
                    "id": "process",
                    "name": "Node process",
                    "provider": "npm.script",
                    "command": "node",
                    "args": ["server.js"],
                    "toolchains": {"runtime": "project-node"}
                },
                {
                    "id": "spring",
                    "name": "Spring service",
                    "provider": "spring-boot.maven",
                    "toolchains": {"java": "project-jdk", "maven": "project-maven"},
                    "extensions": {"maven": {"module": "."}}
                }
            ]),
        );
        let process = core_data(
            "runConfig.createLaunchPlan",
            json!({"root": root, "configurationId": "process"}),
        );
        assert_eq!(process["executable"]["command"], "node");
        assert!(process.get("preLaunchSteps").is_none());
        let spring = core_data(
            "runConfig.createLaunchPlan",
            json!({"root": root, "configurationId": "spring"}),
        );
        let arguments = spring["arguments"].as_array().unwrap();
        assert!(arguments.iter().any(|value| value == "spring-boot:run"));
        assert!(!arguments.iter().any(|value| value == "compile"));
        assert!(spring.get("preLaunchSteps").is_none());
    }

    #[test]
    fn core_plan_uses_javac_then_java_for_standalone_current_file() {
        let fixture = fixture("standalone-plan");
        let root = fixture.0.to_string_lossy().into_owned();
        fs::create_dir_all(fixture.0.join("src")).unwrap();
        fs::write(
            fixture.0.join("src/App.java"),
            "package demo; class App { public static void main(String[] args) {} }",
        )
        .unwrap();
        write_generated(
            &fixture.0,
            json!([{
                "id": "current-file",
                "name": "Current File",
                "provider": "java.current-file",
                "toolchains": {"java": "project-jdk"},
                "extensions": {"java": {}, "maven": {"module": "."}}
            }]),
        );
        let plan = core_data(
            "runConfig.createLaunchPlan",
            json!({
                "root": root,
                "configurationId": "current-file",
                "currentFile": "src/App.java"
            }),
        );
        assert_eq!(plan["executable"]["toolchain"], "project-jdk");
        assert_eq!(plan["preLaunchSteps"][0]["executable"]["tool"], "javac");
        assert!(plan["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "demo.App"));
    }

    #[test]
    fn maven_java_main_without_jdt_metadata_fails_explicitly() {
        let fixture = fixture("jdt-not-ready");
        let root = fixture.0.to_string_lossy().into_owned();
        fs::create_dir_all(fixture.0.join("src")).unwrap();
        fs::write(fixture.0.join("src/App.java"), "class App {}").unwrap();
        write_generated(
            &fixture.0,
            json!([{
                "id": "java-main:demo.App",
                "name": "App",
                "provider": "java.main",
                "toolchains": {"java": "project-jdk", "maven": "project-maven"},
                "extensions": {
                    "java": {"source": "src/App.java"},
                    "maven": {"module": ".", "mainClass": "demo.App"}
                }
            }]),
        );
        let request = json!({
            "id": "linux-test-jdt-not-ready",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "java-main:demo.App"}
        });
        let response: Value =
            serde_json::from_str(&lithe_core::execute_json(&request.to_string())).unwrap();
        assert_eq!(response["ok"], false, "{response}");
        assert!(response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Java project launch metadata is unavailable"));
    }

    #[test]
    fn core_toolchain_defaults_are_read_from_canonical_nested_document() {
        let fixture = fixture("toolchain");
        let root = fixture.0.to_string_lossy().into_owned();
        write_generated(
            &fixture.0,
            json!([{
                "id": "current-file",
                "name": "Current File",
                "provider": "java.current-file",
                "toolchains": {"java": "project-jdk"},
                "extensions": {"maven": {"module": "."}}
            }]),
        );
        let local = fixture.0.join(".lithe/run/local.json");
        fs::create_dir_all(local.parent().unwrap()).unwrap();
        fs::write(
            local,
            r#"{"version":2,"toolchain":{"java":{"homePath":"/fixture/jdk"},"maven":{"executablePath":"/fixture/mvn","javaHomePath":"/fixture/maven-jdk"}},"configurations":[]}"#,
        )
        .unwrap();
        let resolved = core_data(
            "runConfig.resolve",
            json!({"root": root, "toolchainCandidates": []}),
        );
        let config = &resolved["configurations"][0];
        assert_eq!(config["extensions"]["java"]["homePath"], "/fixture/jdk");
        assert_eq!(
            config["extensions"]["java"]["mavenJavaHomePath"],
            "/fixture/maven-jdk"
        );
    }

    #[test]
    fn stale_sequence_rejects_previous_reload_and_execution() {
        assert!(sequence_is_current(7, 7));
        assert!(!sequence_is_current(6, 7));
    }

    #[test]
    fn posix_classpath_merges_into_existing_flag() {
        let arguments = vec!["-cp".to_string(), "old".to_string(), "demo.App".to_string()];
        let merged = merge_java_paths(
            &arguments,
            &["one".to_string(), "two".to_string()],
            "-cp",
            &["-cp", "-classpath", "--class-path"],
        );
        assert_eq!(merged, vec!["-cp", "one:two:old", "demo.App"]);
    }

    #[test]
    fn toolchain_reader_accepts_legacy_keys_and_writer_replaces_them() {
        let fixture = fixture("toolchain-compat");
        let local = fixture.0.join(".lithe/run/local.json");
        fs::create_dir_all(local.parent().unwrap()).unwrap();
        fs::write(
            &local,
            r#"{"version":2,"toolchain":{"javaHome":"/legacy/jdk","mavenExecutable":"/legacy/mvn","mavenJavaHome":"/legacy/maven-jdk"},"configurations":[]}"#,
        )
        .unwrap();
        let paths = read_toolchain_paths(&fixture.0.to_string_lossy());
        assert_eq!(paths.java_home_path, "/legacy/jdk");
        assert_eq!(paths.maven_executable_path, "/legacy/mvn");
        assert_eq!(paths.maven_java_home_path, "/legacy/maven-jdk");
        write_toolchain_paths(
            &fixture.0.to_string_lossy(),
            &ToolchainPaths {
                java_home_path: "/canonical/jdk".to_string(),
                maven_executable_path: "/canonical/mvn".to_string(),
                maven_java_home_path: "/canonical/maven-jdk".to_string(),
                ..ToolchainPaths::default()
            },
        )
        .unwrap();
        let value: Value = serde_json::from_str(&fs::read_to_string(local).unwrap()).unwrap();
        assert_eq!(value["toolchain"]["javaHomePath"], "/canonical/jdk");
        assert_eq!(value["toolchain"]["mavenExecutablePath"], "/canonical/mvn");
        assert_eq!(
            value["toolchain"]["mavenJavaHomePath"],
            "/canonical/maven-jdk"
        );
        assert!(value["toolchain"].get("javaHome").is_none());
        assert!(value["toolchain"].get("mavenExecutable").is_none());
        assert!(value["toolchain"].get("mavenJavaHome").is_none());
    }

    #[test]
    fn generated_documents_write_all_lithe_sidecars_and_preserve_gitignore() {
        let fixture = fixture("documents");
        fs::create_dir_all(fixture.0.join(".lithe")).unwrap();
        fs::write(
            fixture.0.join(".lithe/.gitignore"),
            "custom/\nrun/local.json\n",
        )
        .unwrap();
        write_generated_documents(
            &fixture.0.to_string_lossy(),
            &json!({"version": 2, "configurations": [{"id": "x", "name": "X", "provider": "npm.script", "command": "node"}]}),
            &json!({"version": 1, "toolchains": {}}),
            Some("x"),
        )
        .unwrap();
        assert!(fixture.0.join(".lithe/run/generated.json").is_file());
        assert!(fixture
            .0
            .join(".lithe/toolchains/requirements.json")
            .is_file());
        let ignore = fs::read_to_string(fixture.0.join(".lithe/.gitignore")).unwrap();
        assert!(ignore.starts_with("custom/\nrun/local.json\n"));
        assert!(ignore.contains("run/classes/\n"));
        let manifest: Value = serde_json::from_str(
            &fs::read_to_string(fixture.0.join(".lithe/project.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(manifest["defaultRunConfiguration"], "x");
    }
}
