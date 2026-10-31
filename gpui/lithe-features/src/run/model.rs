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

/// 配置浏览侧栏的语言分类。
///
/// 逐条对齐 Tauri `run-configuration-language.ts`：只按 provider 命名空间和
/// `category` 归类，**不**参与启动计划、工具链选择或执行语义。`java` 覆盖
/// maven / gradle / spring-boot 等 JVM 生态，`nodejs` 覆盖 npm / pnpm / yarn /
/// bun，`tools` 是 make / just / procfile 这类通用任务。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RunLanguage {
    Java,
    NodeJs,
    Python,
    Rust,
    Go,
    Swift,
    Php,
    Ruby,
    DotNet,
    /// 外部依赖：Docker Compose 之类。
    Infrastructure,
    /// 通用构建工具。
    Tools,
    /// 没归类的 provider。
    Other,
}

impl RunLanguage {
    /// 侧栏展示顺序，对齐 Tauri `RUN_LANGUAGE_TITLES` 的键序。
    pub const ORDER: [Self; 12] = [
        Self::Java,
        Self::NodeJs,
        Self::Python,
        Self::Rust,
        Self::Go,
        Self::Swift,
        Self::Php,
        Self::Ruby,
        Self::DotNet,
        Self::Infrastructure,
        Self::Tools,
        Self::Other,
    ];

    /// 从 Core 的 provider / category 推断分类。
    ///
    /// provider 形如 `maven.spring-boot`、`npm.script`，只看第一段的命名空间；
    /// 拿不到的命名空间一律进 `Other`，不再回退到 Java——之前按子串猜测会把
    /// npm / cargo / make 全部误判成 Java，导致 Rust 和 Node 项目的配置显示在
    /// Java 分类下，切到其它分类后列表为空。
    pub fn from_configuration(provider: &str, category: Option<&str>) -> Self {
        if category == Some("infrastructure") {
            return Self::Infrastructure;
        }
        let namespace = provider.split('.').next().unwrap_or(provider);
        match namespace {
            "java" | "maven" | "gradle" | "spring-boot" | "quarkus" | "micronaut" => Self::Java,
            // npm 元数据不能证明源码语言：JS/TS 统一留在同一个生态分类里。
            "npm" | "pnpm" | "yarn" | "bun" | "node" | "nodejs" | "javascript" | "typescript" => {
                Self::NodeJs
            }
            "python" => Self::Python,
            "cargo" | "rust" => Self::Rust,
            "go" => Self::Go,
            "swift" => Self::Swift,
            "php" => Self::Php,
            "ruby" => Self::Ruby,
            "dotnet" | "csharp" | "fsharp" => Self::DotNet,
            "docker" | "compose" => Self::Infrastructure,
            "make" | "just" | "procfile" => Self::Tools,
            _ => Self::Other,
        }
    }

    /// 稳定 key：用于元素 id 和“记住用户切到哪个分类”，不参与界面文案。
    pub fn key(self) -> &'static str {
        match self {
            Self::Java => "java",
            Self::NodeJs => "nodejs",
            Self::Python => "python",
            Self::Rust => "rust",
            Self::Go => "go",
            Self::Swift => "swift",
            Self::Php => "php",
            Self::Ruby => "ruby",
            Self::DotNet => "dotnet",
            Self::Infrastructure => "infrastructure",
            Self::Tools => "tools",
            Self::Other => "other",
        }
    }

    /// 从 [`Self::key`] 恢复；未知 key 返回 `None`。
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ORDER
            .into_iter()
            .find(|language| language.key() == key)
    }

    /// 侧栏分组标题。
    ///
    /// 必须经过 `tr`：生成脚本靠字面量扫描收词条，绕过它会在系统语言与应用
    /// 语言不一致时漏出错误语言。注意 `"Go"` 是 View > Go 菜单的动词（转到），
    /// 编程语言 Go 的词条 key 是 `"Go language"`——`provider_title` 也用它。
    pub fn title(self) -> &'static str {
        match self {
            Self::Java => tr("Java"),
            Self::NodeJs => tr("Node.js"),
            Self::Python => tr("Python"),
            Self::Rust => tr("Rust"),
            Self::Go => tr("Go language"),
            Self::Swift => tr("Swift"),
            Self::Php => tr("PHP"),
            Self::Ruby => tr("Ruby"),
            Self::DotNet => tr(".NET"),
            Self::Infrastructure => tr("Infrastructure"),
            Self::Tools => tr("Build tools"),
            Self::Other => tr("Other"),
        }
    }

    /// 侧栏图标。GPUI 的 `LitheIcon` 没有逐语言图标，已实现的生态用最接近的
    /// 现有图标，其余用通用代码图标。
    pub fn icon(self) -> LitheIcon {
        match self {
            Self::Java => LitheIcon::Java,
            Self::Infrastructure => LitheIcon::Terminal,
            Self::Tools => LitheIcon::BuildOutput,
            Self::NodeJs
            | Self::Python
            | Self::Rust
            | Self::Go
            | Self::Swift
            | Self::Php
            | Self::Ruby
            | Self::DotNet
            | Self::Other => LitheIcon::File,
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
    /// 语言分类。`infrastructure` 字段来自 Core 的 `category`，与
    /// `RunLanguage::from_configuration` 保持同一判据。
    pub fn language(&self) -> RunLanguage {
        RunLanguage::from_configuration(
            &self.provider,
            self.infrastructure.then_some("infrastructure"),
        )
    }

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

    /// Maven 反应堆根（工作区相对）；没有 Maven 扩展时返回 `None`。
    pub fn maven_reactor_path(&self) -> Option<&str> {
        self.extensions
            .get("maven")
            .and_then(|maven| maven.get("reactorPath"))
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
