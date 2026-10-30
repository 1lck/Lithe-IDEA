//! Core 运行配置的视图模型。
//!
//! Core 的 `runConfig.resolve` 返回的是稳定的 camelCase JSON；这里只做
//! 反序列化和展示分类，不复制 Core 的合并、校验或生成规则。

use std::collections::BTreeMap;

use lithe_ui::LitheIcon;
use lithe_ui::i18n::tr;
use serde_json::Value;

/// 一个运行配置启动后的行为类别。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RunExecution {
    Application,
    Service,
    Task,
    Group,
}

impl RunExecution {
    pub fn from_wire(value: &str) -> Self {
        match value {
            "service" => Self::Service,
            "task" => Self::Task,
            "group" => Self::Group,
            _ => Self::Application,
        }
    }

    /// 运行面板作用域栏的固定显示顺序，对齐 macOS
    /// `RunConfigurationExecution.displayOrder`。
    pub const DISPLAY_ORDER: [Self; 4] =
        [Self::Service, Self::Application, Self::Task, Self::Group];

    pub fn title(self) -> &'static str {
        match self {
            Self::Application => tr("Applications"),
            Self::Service => tr("Services"),
            Self::Task => tr("Tasks"),
            Self::Group => tr("Groups"),
        }
    }
}

/// 配置的作用域筛选。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunScope {
    All,
    Pinned,
    Execution(RunExecution),
}

impl RunScope {
    pub fn title(self) -> &'static str {
        match self {
            Self::All => tr("All configurations"),
            Self::Pinned => tr("Pinned"),
            Self::Execution(execution) => execution.title(),
        }
    }
}

/// 一条 Core 运行配置。
#[derive(Clone, Debug)]
pub struct RunConfiguration {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub execution: RunExecution,
    /// `infrastructure` 表示 Docker Compose 之类的外部依赖。
    pub infrastructure: bool,
    pub cwd: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub toolchains: BTreeMap<String, String>,
    pub source: Option<String>,
    pub extensions: Value,
}

impl RunConfiguration {
    pub fn from_json(value: &Value) -> Option<Self> {
        let id = value.get("id")?.as_str()?.to_string();
        let name = value
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(&id)
            .to_string();
        let provider = value
            .get("provider")
            .and_then(Value::as_str)
            .unwrap_or("process")
            .to_string();
        let execution = RunExecution::from_wire(
            value
                .get("execution")
                .and_then(Value::as_str)
                .unwrap_or("application"),
        );
        let infrastructure = value
            .get("category")
            .and_then(Value::as_str)
            .is_some_and(|category| category == "infrastructure");
        let cwd = value
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or(".")
            .to_string();
        let args = value
            .get("args")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let env = string_map(value.get("env"));
        let toolchains = string_map(value.get("toolchains"));
        let source = value
            .get("source")
            .and_then(Value::as_str)
            .map(str::to_string);
        let extensions = value
            .get("extensions")
            .cloned()
            .unwrap_or_else(|| Value::Object(Default::default()));

        Some(Self {
            id,
            name,
            provider,
            execution,
            infrastructure,
            cwd,
            args,
            env,
            toolchains,
            source,
            extensions,
        })
    }

    /// 配置类型名称，用于列表副标题和详情。
    pub fn kind_title(&self) -> String {
        kind_title(&self.provider)
    }

    pub fn icon(&self) -> LitheIcon {
        match self.provider.split('.').next().unwrap_or("") {
            "java" | "maven" => LitheIcon::Java,
            "spring-boot" => LitheIcon::Spring,
            "compose" => LitheIcon::Terminal,
            "gradle" => LitheIcon::BuildOutput,
            _ => LitheIcon::Run,
        }
    }

    /// 工作目录：Core 保证 project-relative 或 `.`。
    pub fn working_directory(&self) -> &str {
        if self.cwd.trim().is_empty() {
            "."
        } else {
            &self.cwd
        }
    }

    pub fn maven_program_arguments(&self) -> Option<String> {
        self.extensions
            .get("maven")
            .and_then(|maven| maven.get("programArguments"))
            .and_then(argument_text)
    }

    pub fn maven_jvm_arguments(&self) -> Option<String> {
        self.extensions
            .get("maven")
            .and_then(|maven| maven.get("jvmArguments"))
            .and_then(argument_text)
    }

    pub fn main_class(&self) -> Option<&str> {
        self.extensions
            .get("maven")
            .and_then(|maven| maven.get("mainClass"))
            .and_then(Value::as_str)
    }

    pub fn module(&self) -> Option<&str> {
        self.extensions
            .get("maven")
            .and_then(|maven| maven.get("module"))
            .and_then(Value::as_str)
    }
}

/// Core `resolve` 返回的一条诊断。
#[derive(Clone, Debug)]
pub struct RunDiagnostic {
    pub id: Option<String>,
    pub code: String,
    pub message: String,
}

impl RunDiagnostic {
    pub fn from_json(value: &Value) -> Option<Self> {
        Some(Self {
            id: value.get("id").and_then(Value::as_str).map(str::to_string),
            code: value
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("runConfiguration")
                .to_string(),
            message: value
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        })
    }

    pub fn is_blocking(&self) -> bool {
        matches!(
            self.code.as_str(),
            "staleFingerprint"
                | "staleJavaEntrypoint"
                | "missingToolchain"
                | "toolchainVendorMismatch"
                | "missingModule"
                | "missingWorkingDirectory"
                | "missingMainClass"
        )
    }
}

/// Core 的 Maven 参数既可能是字符串，也可能是字符串数组。
fn argument_text(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string).or_else(|| {
        value.as_array().map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        })
    })
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

fn kind_title(provider: &str) -> String {
    let namespace = provider.split('.').next().unwrap_or(provider);
    match namespace {
        "npm" => tr("Node.js").to_string(),
        "cargo" => tr("Rust").to_string(),
        "go" => tr("Go language").to_string(),
        "python" => tr("Python").to_string(),
        "make" => tr("Make").to_string(),
        "compose" => tr("Docker Compose").to_string(),
        "procfile" => tr("Procfile").to_string(),
        "gradle" => tr("Gradle").to_string(),
        "just" => tr("Just").to_string(),
        "maven" => tr("Maven").to_string(),
        "java" => tr("Java").to_string(),
        "spring-boot" => tr("Spring Boot").to_string(),
        "quarkus" => tr("Quarkus").to_string(),
        "micronaut" => tr("Micronaut").to_string(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                None => provider.to_string(),
            }
        }
    }
}
