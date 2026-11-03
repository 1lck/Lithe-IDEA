//! Core `runConfig.createLaunchPlan` 响应的解析。
//!
//! Core 返回平台中立的启动计划：可执行文件引用、参数、环境引用与
//! classpath/modulepath 路径；进程生命周期由父模块 [`super`] 负责。

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;

/// 启动计划里的可执行文件引用。
#[derive(Clone, Debug)]
pub(super) enum ExecutableRef {
    Command(String),
    Toolchain {
        name: String,
        /// `project-jdk` may name a sibling tool such as `javac`.
        tool: Option<String>,
    },
}

/// 环境变量的两种来源。
#[derive(Clone, Debug)]
pub(super) enum EnvironmentRef {
    Literal(String),
    ToolchainHome(String),
}

/// 一次启动的完整计划。
pub(super) struct LaunchPlan {
    pub(super) executable: ExecutableRef,
    pub(super) arguments: Vec<String>,
    pub(super) working_directory: String,
    pub(super) environment: BTreeMap<String, EnvironmentRef>,
    pub(super) env: BTreeMap<String, String>,
    pub(super) classpath: Vec<String>,
    pub(super) modulepath: Vec<String>,
    pub(super) pre_launch_steps: Vec<LaunchStep>,
}

/// pre-launch 步骤，例如 Java 独立源文件的编译。
pub(super) struct LaunchStep {
    pub(super) executable: ExecutableRef,
    pub(super) arguments: Vec<String>,
    pub(super) working_directory: Option<String>,
    pub(super) classpath: Vec<String>,
}

impl LaunchPlan {
    /// 解析 Core 的 `runConfig.createLaunchPlan` 响应。
    pub(super) fn from_json(value: &Value) -> Result<Self, String> {
        let executable =
            parse_executable(value.get("executable").ok_or_else(|| {
                lithe_ui::i18n::tr("Could not read run configuration").to_string()
            })?)?;
        let arguments = string_array(value.get("arguments"));
        let working_directory = value
            .get("workingDirectory")
            .and_then(Value::as_str)
            .unwrap_or(".")
            .to_string();
        let env = string_map(value.get("env"));
        let mut environment = BTreeMap::new();
        if let Some(object) = value.get("environment").and_then(Value::as_object) {
            for (key, reference) in object {
                if let Some(toolchain) = reference.get("toolchain").and_then(Value::as_str) {
                    environment.insert(
                        key.clone(),
                        EnvironmentRef::ToolchainHome(toolchain.to_string()),
                    );
                } else if let Some(literal) = reference.as_str() {
                    environment.insert(key.clone(), EnvironmentRef::Literal(literal.to_string()));
                }
            }
        }
        let classpath = string_array(value.get("classpath"));
        let modulepath = string_array(value.get("modulepath"));
        let pre_launch_steps = value
            .get("preLaunchSteps")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|step| {
                        let executable = parse_executable(step.get("executable")?).ok()?;
                        Some(LaunchStep {
                            executable,
                            arguments: string_array(step.get("arguments")),
                            working_directory: step
                                .get("workingDirectory")
                                .and_then(Value::as_str)
                                .map(str::to_string),
                            classpath: string_array(step.get("classpath")),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        Ok(Self {
            executable,
            arguments,
            working_directory,
            environment,
            env,
            classpath,
            modulepath,
            pre_launch_steps,
        })
    }
}

fn parse_executable(value: &Value) -> Result<ExecutableRef, String> {
    if let Some(command) = value.get("command").and_then(Value::as_str) {
        return Ok(ExecutableRef::Command(command.to_string()));
    }
    if let Some(toolchain) = value.get("toolchain").and_then(Value::as_str) {
        return Ok(ExecutableRef::Toolchain {
            name: toolchain.to_string(),
            tool: value
                .get("tool")
                .and_then(Value::as_str)
                .map(str::to_string),
        });
    }
    Err(lithe_ui::i18n::tr("Could not read run configuration").to_string())
}

fn string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
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

/// Core 的 classpath/modulepath 是项目相对路径；JVM 需要宿主绝对路径。
pub(super) fn resolve_plan_paths(root: &Path, paths: &[String]) -> Vec<String> {
    paths
        .iter()
        .map(|value| {
            let path = Path::new(value);
            if path.is_absolute() {
                value.clone()
            } else {
                root.join(path).to_string_lossy().into_owned()
            }
        })
        .collect()
}
