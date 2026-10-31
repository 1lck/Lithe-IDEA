//! Maven 工具窗的领域模型。
//!
//! 数据全部来自共享 Core 的 `maven.*` 命令：这里只做 camelCase JSON 的
//! 反序列化与展示分类，不复制 Core 的扫描、依赖解析或作用域仲裁规则。
//! 对应实现见 `windows/tauri/src/features/maven/types/maven.types.ts`。
//!
//! 路径约定：项目节点的 `relativePath` 是工作区相对路径；模块节点的
//! `relativePath` 是**相对 Maven 反应堆根**的路径，与 Core 的
//! `MavenModuleResponse` 一致。

use lithe_ui::i18n::tr;
use serde_json::Value;

/// Maven 生命周期阶段。
///
/// 顺序与 `shared/fixtures/maven/platform-contract-v1.json` 一致。
pub const LIFECYCLE_PHASES: [&str; 9] = [
    "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy",
];

/// 默认选中的生命周期阶段。
pub const DEFAULT_PHASE: &str = "compile";

/// Maven 源码根的类型。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceRootKind {
    MainJava,
    MainResources,
    TestJava,
    TestResources,
    GeneratedMain,
    GeneratedTest,
}

impl SourceRootKind {
    /// 从 Core 的 `MavenSourceRootKind` 解析；未知值按主源码处理。
    pub fn from_wire(value: &str) -> Self {
        match value {
            "mainResources" => Self::MainResources,
            "testJava" => Self::TestJava,
            "testResources" => Self::TestResources,
            "generatedMain" => Self::GeneratedMain,
            "generatedTest" => Self::GeneratedTest,
            _ => Self::MainJava,
        }
    }

    /// 展示名。
    pub fn title(self) -> &'static str {
        match self {
            Self::MainJava => tr("main Java"),
            Self::MainResources => tr("main resources"),
            Self::TestJava => tr("test Java"),
            Self::TestResources => tr("test resources"),
            Self::GeneratedMain => tr("generated main"),
            Self::GeneratedTest => tr("generated test"),
        }
    }

    /// 图标色调分类：测试源码用成功色，生成源码用警告色，其余用主色。
    pub fn tone(self) -> SourceRootTone {
        match self {
            Self::MainJava | Self::MainResources => SourceRootTone::Primary,
            Self::TestJava | Self::TestResources => SourceRootTone::Success,
            Self::GeneratedMain | Self::GeneratedTest => SourceRootTone::Warning,
        }
    }
}

/// 源码根的图标色调分类。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceRootTone {
    Primary,
    Success,
    Warning,
}

/// 一条源码根。
#[derive(Clone, Debug)]
pub struct SourceRoot {
    /// 模块相对路径，`/` 分隔。
    pub path: String,
    pub kind: SourceRootKind,
}

/// 一个 Maven Profile。
#[derive(Clone, Debug)]
pub struct Profile {
    pub id: String,
    pub is_active_by_default: bool,
}

/// 一个 Maven 反应堆模块。
#[derive(Clone, Debug)]
pub struct Module {
    /// 相对反应堆根的路径；根模块是 `.`。
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub source_roots: Vec<SourceRoot>,
    pub modules: Vec<Module>,
}

impl Module {
    fn from_json(value: &Value) -> Option<Self> {
        let artifact_id = value.get("artifactId")?.as_str()?.to_string();
        Some(Self {
            relative_path: string_field(value.get("relativePath")).unwrap_or_else(|| ".".into()),
            group_id: optional_string(value.get("groupId")),
            artifact_id,
            version: optional_string(value.get("version")),
            packaging: value
                .get("packaging")
                .and_then(Value::as_str)
                .unwrap_or("jar")
                .to_string(),
            source_roots: source_roots(value.get("sourceRoots")),
            modules: modules(value.get("modules")),
        })
    }

    /// 该模块在反应堆里的完整路径（相对反应堆根）。
    ///
    /// Core 的模块 `relativePath` 已经是反应堆相对路径，因此直接使用。
    pub fn path(&self) -> &str {
        &self.relative_path
    }
}

/// Maven 反应堆根（`maven.scan` 的返回值）。
#[derive(Clone, Debug)]
pub struct MavenProject {
    /// 反应堆根在工作区里的相对路径；工作区根是 `.`。
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub source_roots: Vec<SourceRoot>,
    pub modules: Vec<Module>,
    pub profiles: Vec<Profile>,
    /// 仓库里存在 `mvnw` / `mvnw.cmd`。
    pub has_wrapper: bool,
}

impl MavenProject {
    /// 反序列化 `maven.scan` 的 `data`。
    ///
    /// Core 在没有找到可读 `pom.xml` 时返回 `data: null`，此时返回 `None`，
    /// 调用方据此显示「未检测到 Maven 项目」而不是错误。
    pub fn from_json(value: &Value) -> Option<Self> {
        if value.is_null() {
            return None;
        }
        let artifact_id = value.get("artifactId")?.as_str()?.to_string();
        Some(Self {
            relative_path: string_field(value.get("relativePath")).unwrap_or_else(|| ".".into()),
            group_id: optional_string(value.get("groupId")),
            artifact_id,
            version: optional_string(value.get("version")),
            packaging: value
                .get("packaging")
                .and_then(Value::as_str)
                .unwrap_or("jar")
                .to_string(),
            source_roots: source_roots(value.get("sourceRoots")),
            modules: modules(value.get("modules")),
            profiles: value
                .get("profiles")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| {
                            let id = item.get("id")?.as_str()?.to_string();
                            Some(Profile {
                                id,
                                is_active_by_default: item
                                    .get("isActiveByDefault")
                                    .and_then(Value::as_bool)
                                    .unwrap_or(false),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default(),
            has_wrapper: value
                .get("hasWrapper")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }
}

/// 依赖项的仲裁结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DependencyResolution {
    Resolved,
    OmittedDuplicate,
    OmittedConflict,
}

impl DependencyResolution {
    fn from_wire(value: &str) -> Self {
        match value {
            "omittedDuplicate" => Self::OmittedDuplicate,
            "omittedConflict" => Self::OmittedConflict,
            _ => Self::Resolved,
        }
    }

    /// 被仲裁掉的依赖是否需要告警图标。
    pub fn is_omitted(self) -> bool {
        !matches!(self, Self::Resolved)
    }
}

/// 一个依赖项。
#[derive(Clone, Debug)]
pub struct Dependency {
    pub module_path: String,
    pub group_id: String,
    pub artifact_id: String,
    pub version: String,
    /// 依赖类型（`jar` / `war` / `test-jar` …）。
    pub dependency_type: String,
    pub classifier: Option<String>,
    pub scope: String,
    pub resolution: DependencyResolution,
    /// 冲突时被选中的版本。
    pub selected_version: Option<String>,
    /// 依赖管理替换前的版本。
    pub premanaged_version: Option<String>,
    /// 依赖管理替换前的 scope。
    pub premanaged_scope: Option<String>,
    /// 声明时的 scope（作用域仲裁加宽之前）。
    pub original_scope: Option<String>,
    /// 作用域仲裁加宽但未应用到的 scope。
    pub ignored_scope: Option<String>,
    pub children: Vec<Dependency>,
}

impl Dependency {
    pub(crate) fn from_json(value: &Value) -> Option<Self> {
        Some(Self {
            module_path: string_field(value.get("modulePath")).unwrap_or_else(|| ".".into()),
            group_id: value
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            artifact_id: value.get("artifactId")?.as_str()?.to_string(),
            version: value
                .get("version")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            dependency_type: value
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("jar")
                .to_string(),
            classifier: optional_string(value.get("classifier")),
            scope: value
                .get("scope")
                .and_then(Value::as_str)
                .unwrap_or("compile")
                .to_string(),
            resolution: DependencyResolution::from_wire(
                value
                    .get("resolution")
                    .and_then(Value::as_str)
                    .unwrap_or("resolved"),
            ),
            selected_version: optional_string(value.get("selectedVersion")),
            premanaged_version: optional_string(value.get("premanagedVersion")),
            premanaged_scope: optional_string(value.get("premanagedScope")),
            original_scope: optional_string(value.get("originalScope")),
            ignored_scope: optional_string(value.get("ignoredScope")),
            children: value
                .get("children")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(Dependency::from_json).collect())
                .unwrap_or_default(),
        })
    }

    /// 依赖项副标题：`groupId:version:type[:classifier] [scope]` 加仲裁说明。
    ///
    /// 对齐 Tauri `utils/maven-dependency-subtitle.ts`。
    pub fn subtitle(&self) -> String {
        let mut text = format!(
            "{}:{}:{}",
            self.group_id, self.version, self.dependency_type
        );
        if let Some(classifier) = self.classifier.as_ref() {
            if !classifier.is_empty() {
                text.push(':');
                text.push_str(classifier);
            }
        }
        if !self.scope.is_empty() {
            text.push_str(" [");
            text.push_str(&self.scope);
            text.push(']');
        }

        let mut markers: Vec<String> = Vec::new();
        if let Some(value) = self.premanaged_version.as_ref() {
            markers.push(tr("version managed from {value}").replace("{value}", value));
        }
        if let Some(value) = self.premanaged_scope.as_ref() {
            markers.push(tr("scope managed from {value}").replace("{value}", value));
        }
        if let Some(value) = self.original_scope.as_ref() {
            markers.push(tr("scope updated from {value}").replace("{value}", value));
        }
        if let Some(value) = self.ignored_scope.as_ref() {
            markers.push(tr("scope not updated to {value}").replace("{value}", value));
        }
        match self.resolution {
            DependencyResolution::OmittedConflict => {
                let mut marker = tr("conflict with").to_string();
                if let Some(version) = self.selected_version.as_ref() {
                    marker.push_str(" -> ");
                    marker.push_str(version);
                }
                markers.push(marker);
            }
            DependencyResolution::OmittedDuplicate => {
                markers.push(tr("duplicate omitted").to_string());
            }
            DependencyResolution::Resolved => {}
        }
        if !markers.is_empty() {
            text.push_str(" (");
            text.push_str(&markers.join("; "));
            text.push(')');
        }
        text
    }
}

/// Maven 项目的加载状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectStatus {
    Idle,
    Loading,
    Ready,
    Failed,
}

/// Maven 任务的运行状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskStatus {
    Idle,
    Running,
    Stopping,
    Failed,
    Cancelled,
}

/// Maven 启动上下文。
///
/// 字段与 Core 的 `MavenLaunchContextRequest` 一一对应；Core 会校验
/// `version == 1` 并据此生成 `-P` / `-s` / `-Dmaven.repo.local` 等参数。
#[derive(Clone, Debug, Default)]
pub struct LaunchContext {
    pub reactor_path: String,
    pub profiles: Vec<String>,
    pub settings_path: Option<String>,
    pub local_repository_path: Option<String>,
    pub skip_tests: bool,
    pub maven_executable_path: Option<String>,
    pub java_home_path: Option<String>,
}

impl LaunchContext {
    /// 构造 Core 请求里的 `context` 对象。
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "version": 1,
            "reactorPath": self.reactor_path,
            "profiles": self.profiles,
            "settingsPath": self.settings_path,
            "localRepositoryPath": self.local_repository_path,
            "skipTests": self.skip_tests,
            "mavenExecutablePath": self.maven_executable_path,
            "javaHomePath": self.java_home_path,
        })
    }
}

/// 依赖项树的加载状态。
#[derive(Clone, Debug)]
pub enum DependencyLoad {
    Loading,
    Ready(Vec<Dependency>),
    Failed(String),
    Cancelled,
}

impl DependencyLoad {
    /// 是否处于进行中。
    pub fn is_loading(&self) -> bool {
        matches!(self, Self::Loading)
    }
}

/// 解析 `maven.scan` 的 `sourceRoots` 数组。
fn source_roots(value: Option<&Value>) -> Vec<SourceRoot> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let path = item.get("path")?.as_str()?.to_string();
                    Some(SourceRoot {
                        path,
                        kind: SourceRootKind::from_wire(
                            item.get("kind")
                                .and_then(Value::as_str)
                                .unwrap_or("mainJava"),
                        ),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 解析 `modules` 数组。
fn modules(value: Option<&Value>) -> Vec<Module> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Module::from_json).collect())
        .unwrap_or_default()
}

fn string_field(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(|value| value.to_string())
        .filter(|value| !value.is_empty())
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(|value| value.to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_scan_response_with_modules_and_source_roots() {
        // tr() 是进程级语言状态；断言英文原文前先固定语言。
        lithe_ui::i18n::set_language("en-US");
        let value = serde_json::json!({
            "relativePath": ".",
            "groupId": "com.example",
            "artifactId": "demo",
            "version": "1.0.0",
            "packaging": "pom",
            "sourceRoots": [{ "path": "src/main/java", "kind": "mainJava" }],
            "modules": [{
                "relativePath": "service",
                "artifactId": "service",
                "packaging": "jar",
                "sourceRoots": [{ "path": "src/test/java", "kind": "testJava" }],
                "modules": []
            }],
            "profiles": [{ "id": "dev", "isActiveByDefault": true }],
            "hasWrapper": true
        });
        let project = MavenProject::from_json(&value).expect("project should parse");
        assert_eq!(project.artifact_id, "demo");
        assert_eq!(project.packaging, "pom");
        assert!(project.has_wrapper);
        assert_eq!(project.profiles.len(), 1);
        assert_eq!(project.modules.len(), 1);
        assert_eq!(project.modules[0].relative_path, "service");
        assert_eq!(
            project.modules[0].source_roots[0].kind,
            SourceRootKind::TestJava
        );
        assert_eq!(project.modules[0].source_roots[0].kind.title(), "test Java");
    }

    #[test]
    fn treats_a_null_scan_result_as_no_project() {
        assert!(MavenProject::from_json(&Value::Null).is_none());
    }

    #[test]
    fn dependency_subtitle_matches_the_tauri_format() {
        let value = serde_json::json!({
            "modulePath": ".",
            "groupId": "org.springframework",
            "artifactId": "spring-core",
            "version": "6.1.0",
            "type": "jar",
            "scope": "compile",
            "resolution": "resolved",
            "children": []
        });
        let dependency = Dependency::from_json(&value).expect("dependency should parse");
        assert_eq!(
            dependency.subtitle(),
            "org.springframework:6.1.0:jar [compile]"
        );
    }

    #[test]
    fn dependency_subtitle_reports_conflicts() {
        lithe_ui::i18n::set_language("en-US");
        let value = serde_json::json!({
            "modulePath": ".",
            "groupId": "g",
            "artifactId": "a",
            "version": "1.0",
            "type": "jar",
            "scope": "compile",
            "resolution": "omittedConflict",
            "selectedVersion": "2.0",
            "children": []
        });
        let dependency = Dependency::from_json(&value).expect("dependency should parse");
        assert!(dependency.subtitle().contains("conflict with"));
        assert!(dependency.subtitle().contains("2.0"));
    }
}
