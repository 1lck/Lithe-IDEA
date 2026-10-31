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

    /// 侧栏图标（完全对齐 Tauri `RunLanguageIcon` 专属生态图标）。
    pub fn icon(self) -> LitheIcon {
        match self {
            Self::Java => LitheIcon::Java,
            Self::NodeJs => LitheIcon::NodeJs,
            Self::Python => LitheIcon::Python,
            Self::Rust => LitheIcon::Rust,
            Self::Go => LitheIcon::Go,
            Self::Infrastructure => LitheIcon::Terminal,
            Self::Tools => LitheIcon::BuildOutput,
            Self::Swift
            | Self::Php
            | Self::Ruby
            | Self::DotNet
            | Self::Other => LitheIcon::File,
        }
    }
}

/// 运行配置编辑器的保存范围。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunSaveScope {
    /// 只影响当前项目在这台电脑上的配置。
    Local,
    /// 跟随项目进入版本库的团队配置。
    Project,
}

impl RunSaveScope {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Project => "project",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Local => tr("This computer"),
            Self::Project => tr("Project"),
        }
    }

    pub fn hint(self) -> &'static str {
        match self {
            Self::Local => tr(
                "Saved only for this project on this computer in .lithe/run/local.json and excluded from Git.",
            ),
            Self::Project => tr(
                "Saved in .lithe/run/configurations.json for the whole team. Local JDK paths are never shared.",
            ),
        }
    }
}

/// 文档级的项目工具链默认值。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RunToolchainPaths {
    pub java_home_path: String,
    pub maven_executable_path: String,
    pub maven_java_home_path: String,
    /// 通用运行时的显式可执行文件，例如 `project-node`。
    pub runtime_executable_paths: BTreeMap<String, String>,
}

impl RunToolchainPaths {
    /// 一次启动实际采用的工具链：配置覆盖 → 项目默认 → Maven 工具窗的显式选择。
    ///
    /// 只有 Maven 工具窗里明确保存过的值才参与回退；它自动解析出的安装目录
    /// 本来就会被宿主选中，传进来只会把「自动」显示成「已选择」。
    pub fn launch_selection(
        &self,
        project: &Self,
        maven_executable_path: &str,
        maven_java_home_path: &str,
    ) -> Self {
        let fallback = |value: &str, project: &str, maven: &str| {
            if !value.is_empty() {
                value.to_string()
            } else if !project.is_empty() {
                project.to_string()
            } else {
                maven.to_string()
            }
        };
        Self {
            java_home_path: if self.java_home_path.is_empty() {
                project.java_home_path.clone()
            } else {
                self.java_home_path.clone()
            },
            maven_executable_path: fallback(
                &self.maven_executable_path,
                &project.maven_executable_path,
                maven_executable_path,
            ),
            maven_java_home_path: fallback(
                &self.maven_java_home_path,
                &project.maven_java_home_path,
                maven_java_home_path,
            ),
            runtime_executable_paths: self.runtime_executable_paths.clone(),
        }
    }
}

/// 运行配置编辑器的草稿字段，对齐 Tauri `RunOptions`。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RunEditorOptions {
    pub working_directory_path: String,
    pub program_arguments: String,
    pub vm_arguments: String,
    pub environment: BTreeMap<String, String>,
    /// `None` 表示继承项目上下文里的 Skip Tests。
    pub maven_skip_tests: Option<bool>,
    pub java_home_path: String,
    pub maven_executable_path: String,
    pub maven_java_home_path: String,
}

impl RunEditorOptions {
    /// 草稿里的工具链覆盖；Node 默认值不在配置覆盖里。
    pub fn toolchain_paths(&self) -> RunToolchainPaths {
        RunToolchainPaths {
            java_home_path: self.java_home_path.clone(),
            maven_executable_path: self.maven_executable_path.clone(),
            maven_java_home_path: self.maven_java_home_path.clone(),
            runtime_executable_paths: BTreeMap::new(),
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
    /// Maven 扩展里的 JVM 参数。
    pub jvm_arguments: Vec<String>,
    /// Maven 扩展里的程序参数；非 Maven 配置回退到顶层 `args`。
    pub program_arguments: Vec<String>,
    pub maven_profiles: Vec<String>,
    pub maven_skip_tests: Option<bool>,
    pub java_home_path: String,
    pub maven_executable_path: String,
    pub maven_java_home_path: String,
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
        let java_extension = extensions.get("java");
        let maven_extension = extensions.get("maven");
        let jvm_arguments = string_list(maven_extension.and_then(|maven| maven.get("jvmArguments")));
        let program_arguments = string_list(
            maven_extension
                .and_then(|maven| maven.get("programArguments"))
                .or_else(|| value.get("args")),
        );
        let maven_profiles = string_list(maven_extension.and_then(|maven| maven.get("profiles")));
        let maven_skip_tests = maven_extension
            .and_then(|maven| maven.get("skipTests"))
            .and_then(Value::as_bool);
        let string_field = |extension: Option<&Value>, key: &str| {
            extension
                .and_then(|object| object.get(key))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        };
        // 在把 `extensions` 移进结果前先读完扩展字段，避免同时持有借用。
        let java_home_path = string_field(java_extension, "homePath");
        let maven_executable_path = string_field(java_extension, "mavenExecutablePath");
        let maven_java_home_path = string_field(java_extension, "mavenJavaHomePath");

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
            jvm_arguments,
            program_arguments,
            maven_profiles,
            maven_skip_tests,
            java_home_path,
            maven_executable_path,
            maven_java_home_path,
        })
    }

    /// 配置是否依赖 Java 工具链。
    pub fn uses_java(&self) -> bool {
        self.toolchains.contains_key("java") || self.uses_maven()
    }

    /// 配置是否依赖 Maven 工具链。
    pub fn uses_maven(&self) -> bool {
        self.toolchains.contains_key("maven")
    }

    /// 配置是否依赖宿主发现的 Node.js 运行时。
    pub fn uses_node(&self) -> bool {
        self.toolchains
            .get("runtime")
            .is_some_and(|runtime| runtime == "project-node")
    }

    /// 编辑器里的初始草稿；配置值来自 Core 合并后的结果。
    pub fn editor_options(&self) -> RunEditorOptions {
        RunEditorOptions {
            working_directory_path: if self.cwd.trim().is_empty() || self.cwd.trim() == "." {
                String::new()
            } else {
                self.cwd.clone()
            },
            program_arguments: self.program_arguments.join(" "),
            vm_arguments: self.jvm_arguments.join(" "),
            environment: self.env.clone(),
            maven_skip_tests: self.maven_skip_tests,
            java_home_path: self.java_home_path.clone(),
            maven_executable_path: self.maven_executable_path.clone(),
            maven_java_home_path: self.maven_java_home_path.clone(),
        }
    }

    /// 配置来源标题，对齐 Tauri `run.source.*`。
    pub fn source_title(&self) -> &'static str {
        match self.source.as_deref() {
            Some("project") => tr("Project configuration"),
            Some("local") => tr("This computer"),
            _ => tr("Automatically generated"),
        }
    }

    /// 配置类型名称，用于列表副标题和详情。
    pub fn kind_title(&self) -> String {
        kind_title(&self.provider)
    }

    pub fn icon(&self) -> LitheIcon {
        let namespace = self.provider.split('.').next().unwrap_or("");
        match namespace {
            "spring-boot" => LitheIcon::Spring,
            "java" => LitheIcon::Java,
            "maven" => LitheIcon::Maven,
            "gradle" => LitheIcon::BuildOutput,
            "npm" | "pnpm" | "yarn" | "bun" | "node" | "nodejs" => LitheIcon::NodeJs,
            "cargo" | "rust" => LitheIcon::Rust,
            "python" => LitheIcon::Python,
            "go" => LitheIcon::Go,
            "compose" | "docker" => LitheIcon::Terminal,
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
    /// 工具链 requirement 诊断对应的 requirement id（如 `project-jdk`）。
    pub toolchain: Option<String>,
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
            toolchain: value
                .get("toolchain")
                .and_then(Value::as_str)
                .map(str::to_string),
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

    /// 是否是 Core 的工具链 requirement 检查结果。
    pub fn is_requirement(&self) -> bool {
        matches!(
            self.code.as_str(),
            "missingToolchain" | "toolchainVersionMismatch" | "toolchainVendorMismatch"
        )
    }
}

/// 某个工具链的 requirement 诊断文本；`configuration_id` 为空时统计所有配置，
/// 因为项目默认值会作用于每一条配置。
pub fn requirement_messages(
    diagnostics: &[RunDiagnostic],
    toolchain: &str,
    configuration_id: Option<&str>,
) -> Vec<String> {
    let mut messages = Vec::new();
    for diagnostic in diagnostics {
        if !diagnostic.is_requirement()
            || diagnostic.toolchain.as_deref() != Some(toolchain)
            || configuration_id.is_some_and(|id| diagnostic.id.as_deref() != Some(id))
        {
            continue;
        }
        if !messages.contains(&diagnostic.message) {
            messages.push(diagnostic.message.clone());
        }
    }
    messages
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

/// Core 的参数/档案列表：数组按原样，字符串按空白切分。
fn string_list(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect(),
        Some(Value::String(text)) => text
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        _ => Vec::new(),
    }
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

/// 对应 Tauri / Core `ProjectPreparation` 的阶段枚举。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreparationPhase {
    Starting,
    Importing,
    Configuring,
    Building,
    Ready,
    Failed,
    Stopped,
}

impl PreparationPhase {
    pub fn label(self) -> &'static str {
        match self {
            Self::Starting => tr("Starting Java service"),
            Self::Importing => tr("Importing Java project and dependencies"),
            Self::Configuring => tr("Synchronizing Java project configuration"),
            Self::Building => tr("Building Java project"),
            Self::Ready => tr("Java project model is ready"),
            Self::Failed => tr("Java project preparation failed — view details"),
            Self::Stopped => tr("Java project preparation stopped"),
        }
    }
}

/// 准备结果态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreparationStatus {
    Idle,
    Loading,
    Ready,
    Failed,
}

/// 项目准备状态（完全对齐 Tauri `ProjectPreparation` 与 Core `lsp/languages/project_preparation.rs`）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectPreparation {
    pub phase: PreparationPhase,
    pub status: PreparationStatus,
    pub blocks_run: bool,
    pub import_percent: Option<u8>,
    pub current_project: Option<String>,
    pub download_artifact: Option<String>,
}

impl ProjectPreparation {
    pub fn starting() -> Self {
        Self {
            phase: PreparationPhase::Starting,
            status: PreparationStatus::Loading,
            blocks_run: true,
            import_percent: None,
            current_project: None,
            download_artifact: None,
        }
    }

    pub fn ready() -> Self {
        Self {
            phase: PreparationPhase::Ready,
            status: PreparationStatus::Ready,
            blocks_run: false,
            import_percent: None,
            current_project: None,
            download_artifact: None,
        }
    }
}

fn kind_title(provider: &str) -> String {
    let namespace = provider.split('.').next().unwrap_or(provider);
    match namespace {
        "spring-boot" => tr("Spring Boot").to_string(),
        "quarkus" => tr("Quarkus").to_string(),
        "micronaut" => tr("Micronaut").to_string(),
        "java" => {
            if provider == "java.current-file" {
                tr("Current File").to_string()
            } else {
                tr("Java Application").to_string()
            }
        }
        "maven" => tr("Maven Module").to_string(),
        "gradle" => tr("Gradle").to_string(),
        "npm" => tr("npm").to_string(),
        "pnpm" => tr("pnpm").to_string(),
        "yarn" => tr("Yarn").to_string(),
        "bun" => tr("Bun").to_string(),
        "cargo" | "rust" => tr("Cargo").to_string(),
        "go" => tr("Go").to_string(),
        "python" => tr("Python").to_string(),
        "make" => tr("Make").to_string(),
        "compose" => tr("Docker Compose").to_string(),
        "docker" => tr("Docker").to_string(),
        "procfile" => tr("Procfile").to_string(),
        "just" => tr("Just").to_string(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                None => provider.to_string(),
            }
        }
    }
}
