//! 右侧 Maven 导航工具窗口：项目树 + 生命周期阶段 + 依赖 + 自定义 goal，对齐 Tauri
//! `windows/tauri/src/features/maven/` 的导航语义。
//!
//! 本面板只负责导航展示与事件发射：点击阶段行 / 自定义 goal 执行按钮发射
//! [`MavenEvent::RunGoal`]，实际命令执行由外部经底部 Terminal 完成（`view.rs`
//! 拼出 `mvn -f "<pom>" <goal>`）。工程结构（`maven.scan`）与依赖加载
//! （`maven.dependencyPlan` + `maven.dependencies`）经 [`CoreClient`] 在
//! `cx.spawn` 里异步调用 core 命令；本地 pom 发现（[`find_pom_files`]）先行，
//! core 失败只落工程/依赖状态，不阻塞导航展示。

use std::collections::{HashMap, HashSet};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, ClickEvent, Context, Entity, EventEmitter, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window,
};

use crate::core::CoreClient;
use crate::theme::ThemeColors;

/// 对齐 Tauri `MAVEN_LIFECYCLE_PHASES` 的 Maven 生命周期阶段。
pub const MAVEN_LIFECYCLE_PHASES: [&str; 9] = [
    "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy",
];

/// pom 扫描最大递归深度。
const MAX_POM_SCAN_DEPTH: usize = 5;

/// pom 扫描跳过的目录名：构建产物与常见工具目录。
const POM_SCAN_SKIP_DIRS: [&str; 9] = [
    "target",
    "node_modules",
    ".git",
    ".idea",
    "dist",
    "build",
    "out",
    ".vscode",
    "vendor",
];

/// 递归扫描 root 下的 `pom.xml`，返回排序后的绝对路径列表，不新增依赖。
pub fn find_pom_files(root: &str) -> Vec<String> {
    let mut out = Vec::new();
    let base = std::path::PathBuf::from(root);
    let base = if base.is_absolute() {
        base
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(&base))
            .unwrap_or(base)
    };
    walk_pom_dir(&base, 0, &mut out);
    out.sort();
    out
}

fn walk_pom_dir(dir: &std::path::Path, depth: usize, out: &mut Vec<String>) {
    if depth > MAX_POM_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if POM_SCAN_SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            walk_pom_dir(&path, depth + 1, out);
        } else if name == "pom.xml" {
            out.push(path.to_string_lossy().into_owned());
        }
    }
}

/// Lifecycle 组的展开键。
fn lifecycle_key(owner: &str) -> String {
    format!("{owner}:lifecycle")
}

/// 依赖组的展开键。
fn deps_key(owner: &str) -> String {
    format!("{owner}:dependencies")
}

/// 源码根目录组的展开键。
fn source_roots_key(owner: &str) -> String {
    format!("{owner}:source-roots")
}

/// 模块节点的展开键与 owner 键：根项目为 `project`，子模块为
/// `module:{relativePath}`（与 `maven.scan` 的模块路径约定一致）。
fn owner_key(relative_path: &str) -> String {
    if relative_path == "." || relative_path.is_empty() {
        "project".to_string()
    } else {
        format!("module:{relative_path}")
    }
}

/// owner 键反推模块相对路径：根项目为 `.`。
fn relative_for_owner(owner: &str) -> String {
    owner.strip_prefix("module:").unwrap_or(".").to_string()
}

/// 模块相对路径对应的 pom 绝对路径。
fn pom_for_relative(root: &str, relative_path: &str) -> String {
    let mut path = std::path::PathBuf::from(root);
    if !relative_path.is_empty() && relative_path != "." {
        path.push(relative_path);
    }
    path.push("pom.xml");
    path.to_string_lossy().into_owned()
}

/// pom 行的显示路径：相对 root，根 pom 显示 `pom.xml`。
fn display_pom_path(root: &str, pom: &str) -> String {
    std::path::Path::new(pom)
        .strip_prefix(root)
        .map(|rel| {
            let s = rel.to_string_lossy().into_owned();
            if s.is_empty() {
                pom.to_string()
            } else {
                s
            }
        })
        .unwrap_or_else(|_| pom.to_string())
}

/// 传给 `maven.scan` 的 workspace 相对 pom 路径：core 只接受相对路径，
/// 绝对路径会被 core 侧忽略（扫描退化为无工程，不报错）。
fn relative_pom_paths(root: &str, poms: &[String]) -> Vec<String> {
    poms.iter()
        .map(|pom| {
            std::path::Path::new(pom)
                .strip_prefix(root)
                .map(|rel| rel.to_string_lossy().replace('\\', "/"))
                .unwrap_or_else(|_| pom.clone())
        })
        .collect()
}

/// 对齐 Tauri `projectStatus` 的工程状态：`idle` / `loading` / `ready` / `failed`；
/// 依赖加载另有 `Cancelled`（用户主动取消，可重试）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MavenStatus {
    Idle,
    Loading,
    Ready,
    Failed(String),
    Cancelled,
}

/// 依赖列表行的完整字段，对齐 core `maven.dependencies` 返回的
/// `dependencies[]`（含嵌套 `children` 与 `resolution` 标记）。
#[derive(Debug, Clone)]
pub struct MavenDep {
    pub group: String,
    pub artifact: String,
    pub version: String,
    pub dep_type: String,
    pub classifier: Option<String>,
    pub scope: String,
    /// `resolved` / `omittedConflict` / `omittedDuplicate`……
    pub resolution: String,
    pub selected_version: Option<String>,
    pub children: Vec<MavenDep>,
}

/// 从 `maven.dependencies` 的返回体递归解析依赖树，缺失三元组直接丢弃。
fn parse_dep(item: &serde_json::Value) -> Option<MavenDep> {
    let children = item
        .get("children")
        .and_then(|value| value.as_array())
        .map(|items| items.iter().filter_map(parse_dep).collect())
        .unwrap_or_default();
    Some(MavenDep {
        group: item.get("groupId")?.as_str()?.to_string(),
        artifact: item.get("artifactId")?.as_str()?.to_string(),
        version: item
            .get("version")
            .and_then(|value| value.as_str())
            .unwrap_or_default()
            .to_string(),
        dep_type: item
            .get("type")
            .and_then(|value| value.as_str())
            .unwrap_or("jar")
            .to_string(),
        classifier: item
            .get("classifier")
            .and_then(|value| value.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        scope: item
            .get("scope")
            .and_then(|value| value.as_str())
            .unwrap_or_default()
            .to_string(),
        resolution: item
            .get("resolution")
            .and_then(|value| value.as_str())
            .unwrap_or("resolved")
            .to_string(),
        selected_version: item
            .get("selectedVersion")
            .and_then(|value| value.as_str())
            .map(str::to_string),
        children,
    })
}

fn parse_deps(data: &serde_json::Value) -> Vec<MavenDep> {
    data.get("dependencies")
        .and_then(|value| value.as_array())
        .map(|items| items.iter().filter_map(parse_dep).collect())
        .unwrap_or_default()
}

/// 依赖副标题：`groupId:version:type[:classifier] [scope] [(标记)]`，
/// 与 Tauri `renderDependency` 的 subtitle 口径一致。
fn dep_subtitle(dep: &MavenDep, cx: &gpui_kit::App) -> String {
    let classifier = dep
        .classifier
        .as_deref()
        .map(|c| format!(":{c}"))
        .unwrap_or_default();
    let marker = if dep.resolution == "omittedConflict" {
        let arrow = dep
            .selected_version
            .as_deref()
            .map(|v| format!(" -> {v}"))
            .unwrap_or_default();
        format!(
            " ({}{arrow})",
            crate::i18n::menu_text(cx, "maven.omittedConflict")
        )
    } else if dep.resolution == "omittedDuplicate" {
        format!(
            " ({})",
            crate::i18n::menu_text(cx, "maven.omittedDuplicate")
        )
    } else {
        String::new()
    };
    format!(
        "{}:{}:{}{} [{}]{marker}",
        dep.group, dep.version, dep.dep_type, classifier, dep.scope
    )
}

/// 扫描得到的模块节点：`maven.scan` 响应体的内存子集
///（`relativePath` / `artifactId` / `packaging` / `sourceRoots` / `modules`）。
#[derive(Debug, Clone, Default)]
pub struct MavenModuleNode {
    pub relative_path: String,
    pub artifact_id: String,
    pub packaging: String,
    pub source_roots: Vec<(String, String)>,
    pub modules: Vec<MavenModuleNode>,
}

/// 扫描得到的 profile：`profiles[]` 的 `id` 与默认激活态。
#[derive(Debug, Clone)]
pub struct MavenProfileItem {
    pub id: String,
    pub active_by_default: bool,
}

fn parse_module_node(value: &serde_json::Value) -> Option<MavenModuleNode> {
    Some(MavenModuleNode {
        relative_path: value
            .get("relativePath")
            .and_then(|v| v.as_str())
            .unwrap_or(".")
            .to_string(),
        artifact_id: value
            .get("artifactId")
            .and_then(|v| v.as_str())?
            .to_string(),
        packaging: value
            .get("packaging")
            .and_then(|v| v.as_str())
            .unwrap_or("jar")
            .to_string(),
        source_roots: value
            .get("sourceRoots")
            .and_then(|v| v.as_array())
            .map(|roots| {
                roots
                    .iter()
                    .filter_map(|root| {
                        Some((
                            root.get("path")?.as_str()?.to_string(),
                            root.get("kind")
                                .and_then(|v| v.as_str())
                                .unwrap_or_default()
                                .to_string(),
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default(),
        modules: value
            .get("modules")
            .and_then(|v| v.as_array())
            .map(|items| items.iter().filter_map(parse_module_node).collect())
            .unwrap_or_default(),
    })
}

fn parse_profiles(value: &serde_json::Value) -> Vec<MavenProfileItem> {
    value
        .get("profiles")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    Some(MavenProfileItem {
                        id: item.get("id")?.as_str()?.to_string(),
                        active_by_default: item
                            .get("isActiveByDefault")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Maven 导航面板派发的事件：执行只发射，由外部经底部 Maven 页执行；
/// 依赖行点击发射 `OpenFile`（打开模块 pom），设置按钮发射 `OpenSettings`。
#[derive(Debug, Clone)]
pub enum MavenEvent {
    RunGoal {
        pom_path: String,
        phase: String,
        /// 展示用目标（`{phase} · {artifactId}`，对齐 Tauri 任务标题）。
        target: String,
        profiles: Vec<String>,
        skip_tests: bool,
    },
    OpenFile(String),
    OpenSettings,
    Close,
}

/// 右侧 Maven 导航工具窗口：模块树 + 生命周期 + 依赖 + Profiles + 自定义 goal，
/// 对齐 Tauri `MavenPane` 的树语义（caret 与标签分离、子节点引导线、
/// 单击选中、phase 双击运行）。
pub struct MavenView {
    pub root: String,
    /// 本地 pom 兜底列表：core 无工程时沿用旧平铺展示。
    poms: Vec<String>,
    /// 扫描得到的反应堆根节点（`relativePath == "."`）。
    project: Option<MavenModuleNode>,
    profiles: Vec<MavenProfileItem>,
    selected_profiles: HashSet<String>,
    skip_tests: bool,
    expanded: HashSet<String>,
    /// 选中的模块相对路径；`None` 为根项目。
    selected_module: Option<String>,
    selected_phase: String,
    project_status: MavenStatus,
    dependencies: HashMap<String, Vec<MavenDep>>,
    dep_status: HashMap<String, MavenStatus>,
    dep_seq: HashMap<String, u64>,
    dep_ops: HashMap<String, String>,
    custom_goal: String,
    goal_input: Option<Entity<InputState>>,
    _goal_subscription: Option<Subscription>,
    client: CoreClient,
    scan_seq: u64,
}

impl EventEmitter<MavenEvent> for MavenView {}

impl MavenView {
    pub fn new(root: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            root,
            poms: Vec::new(),
            project: None,
            profiles: Vec::new(),
            selected_profiles: HashSet::new(),
            skip_tests: false,
            expanded: HashSet::new(),
            selected_module: None,
            selected_phase: "compile".to_string(),
            project_status: MavenStatus::Idle,
            dependencies: HashMap::new(),
            dep_status: HashMap::new(),
            dep_seq: HashMap::new(),
            dep_ops: HashMap::new(),
            custom_goal: String::new(),
            goal_input: None,
            _goal_subscription: None,
            client: CoreClient::new(),
            scan_seq: 0,
        };
        view.reload(cx);
        view
    }

    pub fn set_root(&mut self, root: String, cx: &mut Context<Self>) {
        self.root = root;
        self.project = None;
        self.profiles.clear();
        self.selected_profiles.clear();
        self.selected_module = None;
        self.dependencies.clear();
        self.dep_status.clear();
        self.reload(cx);
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.project = None;
        self.profiles.clear();
        self.selected_profiles.clear();
        self.dependencies.clear();
        self.dep_status.clear();
        self.reload(cx);
    }

    pub fn has_projects(&self) -> bool {
        self.project.is_some() || !self.poms.is_empty()
    }

    /// 全部折叠（对齐 Tauri `collapseAll`）。
    fn collapse_all(&mut self, cx: &mut Context<Self>) {
        self.expanded.clear();
        cx.notify();
    }

    /// 重扫 pom 列表（core 无工程时的兜底展示），默认展开全部。
    fn rescan(&mut self) {
        self.poms = find_pom_files(&self.root);
        self.expanded.clear();
        for pom in &self.poms {
            self.expanded.insert(pom.clone());
            self.expanded.insert(lifecycle_key(pom));
        }
    }

    /// 本地重扫 + core `maven.scan` 拿模块结构：
    /// payload `{root, paths}`（相对 pom 路径）。成功解析模块树、
    /// Profiles 与默认选中（`isActiveByDefault`），初始展开根项目与
    /// Profiles（对齐 Tauri 初次展开）；失败只落 `project_status`，
    /// 导航照常展示本地 pom 兜底。
    fn reload(&mut self, cx: &mut Context<Self>) {
        // 无工作区（欢迎页）时不发起扫描：空根只会得到失败态，
        // 且入口本身因 `has_projects` 为假而不展示。
        if self.root.trim().is_empty() {
            self.poms.clear();
            self.project = None;
            self.project_status = MavenStatus::Idle;
            return;
        }
        self.rescan();
        self.project_status = MavenStatus::Loading;
        self.scan_seq += 1;
        let seq = self.scan_seq;
        cx.notify();

        let client = self.client.clone();
        let root = self.root.clone();
        let paths = relative_pom_paths(&self.root, &self.poms);
        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({ "root": root, "paths": paths });
            let result = client
                .execute::<serde_json::Value, serde_json::Value>(&cx, "maven.scan", payload)
                .await;
            let _ = this.update(cx, |view, cx| {
                if view.scan_seq != seq {
                    return;
                }
                match result {
                    Ok(data) => {
                        view.project = parse_module_node(&data);
                        view.profiles = parse_profiles(&data);
                        view.selected_profiles = view
                            .profiles
                            .iter()
                            .filter(|p| p.active_by_default)
                            .map(|p| p.id.clone())
                            .collect();
                        view.selected_module = None;
                        view.selected_phase = "compile".to_string();
                        view.expanded.clear();
                        view.expanded.insert("project".to_string());
                        if !view.profiles.is_empty() {
                            view.expanded.insert("profiles".to_string());
                        }
                        view.project_status = MavenStatus::Ready;
                    }
                    Err(err) => {
                        view.project = None;
                        view.profiles.clear();
                        view.selected_profiles.clear();
                        view.project_status = MavenStatus::Failed(err);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn toggle_node(&mut self, key: &str, cx: &mut Context<Self>) {
        if !self.expanded.remove(key) {
            self.expanded.insert(key.to_string());
        }
        cx.notify();
    }

    /// 依赖组展开即加载、收起即保留缓存（对齐 Tauri 展开加载语义）。
    fn toggle_deps(&mut self, relative_path: &str, cx: &mut Context<Self>) {
        let key = deps_key(&owner_key(relative_path));
        if !self.expanded.remove(&key) {
            self.expanded.insert(key);
            self.load_deps(relative_path, cx);
        } else {
            cx.notify();
        }
    }

    /// 取消指定模块的依赖加载（序号递增丢弃迟到结果，对齐 Tauri 取消）。
    fn cancel_deps(&mut self, relative_path: &str, cx: &mut Context<Self>) {
        let seq = self.dep_seq.get(relative_path).copied().unwrap_or(0) + 1;
        self.dep_seq.insert(relative_path.to_string(), seq);
        if let Some(op) = self.dep_ops.remove(relative_path) {
            self.client.cancel(&op);
        }
        self.dep_status
            .insert(relative_path.to_string(), MavenStatus::Cancelled);
        cx.notify();
    }

    /// 选中 phase（单击语义，不执行）。
    fn select_phase(&mut self, relative_path: &str, phase: &str, cx: &mut Context<Self>) {
        self.selected_module = if relative_path == "." {
            None
        } else {
            Some(relative_path.to_string())
        };
        self.selected_phase = phase.to_string();
        cx.notify();
    }

    /// 发射执行事件：标题 `{phase} · {artifactId}`（对齐 Tauri 任务标题）。
    fn emit_run_goal(&mut self, relative_path: &str, phase: &str, cx: &mut Context<Self>) {
        self.select_phase(relative_path, phase, cx);
        let artifact = self
            .find_module(relative_path)
            .map(|m| m.artifact_id.clone())
            .or_else(|| self.project.as_ref().map(|p| p.artifact_id.clone()))
            .unwrap_or_else(|| crate::i18n::menu_text(cx, "maven.project").to_string());
        let mut profiles: Vec<String> = self.selected_profiles.iter().cloned().collect();
        profiles.sort();
        cx.emit(MavenEvent::RunGoal {
            pom_path: pom_for_relative(&self.root, relative_path),
            phase: phase.to_string(),
            target: artifact,
            profiles,
            skip_tests: self.skip_tests,
        });
    }

    /// 运行当前选中 scope（头部运行按钮，对齐 Tauri `runSelected`）。
    fn run_selected(&mut self, cx: &mut Context<Self>) {
        if self.project.is_none() {
            return;
        }
        let relative = self
            .selected_module
            .clone()
            .unwrap_or_else(|| ".".to_string());
        let phase = self.selected_phase.clone();
        self.emit_run_goal(&relative, &phase, cx);
    }

    /// 在模块树中按相对路径查找节点（含根）。
    fn find_module(&self, relative_path: &str) -> Option<&MavenModuleNode> {
        if relative_path == "." || relative_path.is_empty() {
            return self.project.as_ref();
        }
        fn walk<'a>(node: &'a MavenModuleNode, rel: &str) -> Option<&'a MavenModuleNode> {
            if node.relative_path == rel {
                return Some(node);
            }
            node.modules.iter().find_map(|child| walk(child, rel))
        }
        self.project
            .as_ref()
            .and_then(|root| walk(root, relative_path))
    }

    /// 先 `maven.dependencyPlan` 校验模块并拿出确定的离线调用计划
    /// （payload `{root, context: {version: 1, reactorPath: ".", profiles, skipTests}, module}`，
    /// 返回 `MavenLaunchPlanResponse`），再 `maven.dependencies`
    /// （payload `{modulePath, output}`，返回 `{modulePath, dependencies[]}`）
    /// 递归解析依赖树。Linux 侧无 Maven 进程宿主，`output` 为空即返回空列表；
    /// 真实树需在终端运行 `dependency:tree`，失败文案直接展示。
    /// 每个模块独立序号与 operationId，支持取消（对齐 Tauri 各模块独立加载）。
    fn load_deps(&mut self, relative_path: &str, cx: &mut Context<Self>) {
        let seq = self.dep_seq.get(relative_path).copied().unwrap_or(0) + 1;
        self.dep_seq.insert(relative_path.to_string(), seq);
        self.dep_status
            .insert(relative_path.to_string(), MavenStatus::Loading);
        self.dependencies.remove(relative_path);
        cx.notify();

        let client = self.client.clone();
        let root = self.root.clone();
        let module = relative_path.to_string();
        let mut profiles: Vec<String> = self.selected_profiles.iter().cloned().collect();
        profiles.sort();
        let skip_tests = self.skip_tests;
        let op = uuid::Uuid::new_v4().to_string();
        self.dep_ops.insert(relative_path.to_string(), op.clone());
        cx.spawn(async move |this, cx| {
            let plan = client
                .execute_with_operation_id::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "maven.dependencyPlan",
                    serde_json::json!({
                        "root": root,
                        "context": {
                            "version": 1,
                            "reactorPath": ".",
                            "profiles": profiles,
                            "skipTests": skip_tests,
                        },
                        "module": module,
                    }),
                    Some(op),
                )
                .await;
            let outcome: Result<Vec<MavenDep>, String> = match plan {
                Ok(_) => match client
                    .execute::<serde_json::Value, serde_json::Value>(
                        &cx,
                        "maven.dependencies",
                        serde_json::json!({ "modulePath": module, "output": "" }),
                    )
                    .await
                {
                    Ok(data) => Ok(parse_deps(&data)),
                    Err(err) => Err(err),
                },
                Err(err) => Err(err),
            };
            let _ = this.update(cx, |view, cx| {
                if view.dep_seq.get(&module).copied().unwrap_or(0) != seq {
                    return;
                }
                view.dep_ops.remove(&module);
                match outcome {
                    Ok(deps) => {
                        view.dependencies.insert(module.clone(), deps);
                        view.dep_status.insert(module.clone(), MavenStatus::Ready);
                    }
                    Err(err) => {
                        view.dep_status
                            .insert(module.clone(), MavenStatus::Failed(err));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 懒创建自定义 goal 输入框（参考 `settings_dialog.rs::ensure_input`）。
    fn ensure_goal_input(
        slot: &mut Option<Entity<InputState>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(entity) = slot.clone() {
            return entity;
        }
        let entity = cx.new(|cx| InputState::new(window, cx));
        *slot = Some(entity.clone());
        entity
    }
}

/// pom 所在目录相对 root 的模块路径：根 pom 为 `.`（兜底展示用）。
fn relative_for_pom(root: &str, pom: &str) -> String {
    let relative = std::path::Path::new(pom)
        .parent()
        .and_then(|dir| dir.strip_prefix(root).ok())
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let trimmed = relative.trim_matches('/').to_string();
    if trimmed.is_empty() {
        ".".to_string()
    } else {
        trimmed
    }
}

/// 子节点容器：左缩进 + 引导线，对齐 Tauri `ml-4 border-l pl-1`。
fn child_container(children: Vec<gpui_kit::AnyElement>) -> gpui_kit::AnyElement {
    div()
        .w_full()
        .ml(px(16.0))
        .pl(px(4.0))
        .border_l_1()
        .border_color(ThemeColors::border())
        .children(children)
        .into_any_element()
}

impl MavenView {
    /// 分发 caret/标签的折叠动作：普通节点切 `expanded`，依赖组附带加载。
    fn dispatch_toggle(&mut self, key: &str, cx: &mut Context<Self>) {
        if let Some(owner) = key.strip_suffix(":dependencies") {
            self.toggle_deps(&relative_for_owner(owner), cx);
        } else {
            self.toggle_node(key, cx);
        }
    }
}

impl Render for MavenView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 自定义 goal 输入框懒创建 + 一次性订阅 Change 事件，值同步到 custom_goal。
        let goal_entity = Self::ensure_goal_input(&mut self.goal_input, window, cx);
        if self._goal_subscription.is_none() {
            let entity = goal_entity.clone();
            self._goal_subscription = Some(cx.subscribe(
                &goal_entity,
                move |this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        this.custom_goal = entity.read(cx).value().to_string();
                    }
                },
            ));
        }

        // 快照后构建行，避免在闭包里同时借用 self 与 cx。
        let expanded = self.expanded.clone();
        let project = self.project.clone();
        let profiles = self.profiles.clone();
        let selected_profiles = self.selected_profiles.clone();
        let skip_tests = self.skip_tests;
        let selected_module = self.selected_module.clone();
        let selected_phase = self.selected_phase.clone();
        let project_status = self.project_status.clone();
        let dep_status = self.dep_status.clone();
        let dependencies = self.dependencies.clone();
        let custom_goal = self.custom_goal.clone();
        let poms = self.poms.clone();

        let title_text = match project.as_ref() {
            Some(node) => format!(
                "{} · {}",
                crate::i18n::menu_text(cx, "maven.title"),
                node.artifact_id
            ),
            None => crate::i18n::menu_text(cx, "maven.title").to_string(),
        };
        let status_banner: Option<(bool, String)> = match &project_status {
            MavenStatus::Loading => Some((
                false,
                crate::i18n::menu_text(cx, "maven.scanning").to_string(),
            )),
            MavenStatus::Failed(err) => Some((true, err.clone())),
            MavenStatus::Idle | MavenStatus::Ready | MavenStatus::Cancelled => None,
        };
        let has_project = project.is_some();

        // 当前选中 scope 的执行信息（头部运行按钮与自定义 goal 共用）。
        let scope_rel = selected_module.clone().unwrap_or_else(|| ".".to_string());
        let scope_pom = pom_for_relative(&self.root, &scope_rel);
        let scope_target = project
            .as_ref()
            .and_then(|root| {
                if scope_rel == "." {
                    Some(root.artifact_id.clone())
                } else {
                    find_module_in(root, &scope_rel).map(|m| m.artifact_id.clone())
                }
            })
            .unwrap_or_else(|| display_pom_path(&self.root, &scope_pom));
        let scope_profiles: Vec<String> = {
            let mut ids: Vec<String> = selected_profiles.iter().cloned().collect();
            ids.sort();
            ids
        };

        let mut body = Vec::new();
        if let Some(root_node) = project.clone() {
            if !profiles.is_empty() {
                body.push(self.render_profiles_node(&profiles, &selected_profiles, &expanded, cx));
            }
            body.push(self.render_module_node(
                &root_node,
                None,
                &expanded,
                &selected_module,
                &selected_phase,
                &dep_status,
                &dependencies,
                cx,
            ));
        } else if !poms.is_empty() {
            // core 无工程时的 pom 兜底：按 pom 所在目录合成 owner 行。
            for pom in &poms {
                let rel = relative_for_pom(&self.root, pom);
                let owner = owner_key(&rel);
                let selected = if rel == "." {
                    selected_module.is_none()
                } else {
                    selected_module.as_deref() == Some(rel.as_str())
                };
                body.push(self.render_owner_row(
                    format!("legacy-{owner}"),
                    OwnerToggle::Key(owner.clone()),
                    IconName::Package,
                    display_pom_path(&self.root, pom),
                    None,
                    selected,
                    OwnerSelect::Module(if rel == "." { None } else { Some(rel.clone()) }),
                    cx,
                ));
                if expanded.contains(&owner) {
                    let mut children = Vec::new();
                    children.push(self.render_lifecycle_node(
                        &owner,
                        &rel,
                        &expanded,
                        &selected_module,
                        &selected_phase,
                        cx,
                    ));
                    children.push(self.render_deps_node(
                        &owner,
                        &rel,
                        &self.root,
                        &expanded,
                        &dep_status,
                        &dependencies,
                        cx,
                    ));
                    body.push(child_container(children));
                }
            }
        }

        let body_element = match (&project, &project_status) {
            (None, MavenStatus::Failed(err)) if poms.is_empty() => v_flex()
                .flex_1()
                .w_full()
                .items_center()
                .justify_center()
                .gap_2()
                .p_4()
                .child(
                    Icon::new(IconName::TriangleAlert)
                        .size(px(28.0))
                        .text_color(ThemeColors::destructive()),
                )
                .child(
                    div()
                        .text_xs()
                        .font_weight(FontWeight::BOLD)
                        .text_color(ThemeColors::text_primary())
                        .child(crate::i18n::menu_text(cx, "maven.loadFailed")),
                )
                .child(
                    div()
                        .w_full()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(err.clone()),
                )
                .child(
                    Button::new("maven-retry")
                        .small()
                        .primary()
                        .label(crate::i18n::menu_text(cx, "ui.retry"))
                        .on_click(cx.listener(|this, _event, _window, cx| {
                            this.refresh(cx);
                        })),
                )
                .into_any_element(),
            (None, _) if body.is_empty() => div()
                .flex_1()
                .w_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(
                    cx,
                    match project_status {
                        MavenStatus::Loading => "maven.scanning",
                        _ => "maven.notDetected",
                    },
                ))
                .into_any_element(),
            _ => div()
                .flex_1()
                .w_full()
                .min_h_0()
                .overflow_y_scrollbar()
                .px_2()
                .py_1()
                .children(body)
                .into_any_element(),
        };

        let goal_entity_for_run = goal_entity.clone();
        let run_scope = (scope_pom.clone(), scope_target.clone());
        let run_profiles = scope_profiles.clone();
        v_flex()
            .size_full()
            .bg(ThemeColors::bg_sidebar())
            .border_l_1()
            .border_color(ThemeColors::border())
            .child(
                h_flex()
                    .h(px(32.0))
                    .w_full()
                    .bg(ThemeColors::bg_sidebar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .justify_between()
                    .px_3()
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(ThemeColors::text_muted())
                            .child(title_text),
                    )
                    .child(
                        Button::new("maven-close")
                            .small()
                            .ghost()
                            .icon(IconName::Close)
                            .tooltip(crate::i18n::menu_text(cx, "ui.close"))
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(MavenEvent::Close);
                            })),
                    ),
            )
            .child(
                // 工具栏：运行选中 / 执行目标文本 / reload / 跳过测试 /
                // 全部折叠 / 设置，对齐 Tauri 第二行。
                h_flex()
                    .h(px(32.0))
                    .w_full()
                    .flex_shrink_0()
                    .items_center()
                    .gap_1()
                    .px_2()
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .child(
                        Button::new("maven-run-selected")
                            .small()
                            .ghost()
                            .icon(IconName::Play)
                            .tooltip(crate::i18n::menu_text(cx, "maven.runSelected"))
                            .disabled(!has_project)
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.run_selected(cx);
                            })),
                    )
                    .child(
                        Button::new("maven-exec-goal")
                            .small()
                            .ghost()
                            .icon(IconName::Terminal)
                            .tooltip(crate::i18n::menu_text(cx, "maven.executeGoal"))
                            .disabled(custom_goal.trim().is_empty() || run_scope.0.is_empty())
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                let goal = goal_entity_for_run.read(cx).value().to_string();
                                let goal = goal.trim().to_string();
                                if goal.is_empty() {
                                    return;
                                }
                                this.emit_text_goal(
                                    &run_scope.0,
                                    &goal,
                                    &run_scope.1,
                                    &run_profiles,
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("maven-reload")
                            .small()
                            .ghost()
                            .icon(IconName::RotateCw)
                            .tooltip(crate::i18n::menu_text(cx, "maven.reloadProjects"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.refresh(cx);
                            })),
                    )
                    .child(
                        Button::new("maven-skip-tests")
                            .small()
                            .when(skip_tests, |b| b.primary())
                            .when(!skip_tests, |b| b.ghost())
                            .icon(IconName::Check)
                            .tooltip(crate::i18n::menu_text(cx, "maven.skipTests"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.skip_tests = !this.skip_tests;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("maven-collapse-all")
                            .small()
                            .ghost()
                            .icon(IconName::FoldVertical)
                            .tooltip(crate::i18n::menu_text(cx, "maven.collapseAll"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.collapse_all(cx);
                            })),
                    )
                    .child(
                        Button::new("maven-settings")
                            .small()
                            .ghost()
                            .icon(IconName::Settings)
                            .tooltip(crate::i18n::menu_text(cx, "maven.settings"))
                            .disabled(!has_project)
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(MavenEvent::OpenSettings);
                            })),
                    ),
            )
            .when_some(status_banner, |this, (is_error, text)| {
                this.child(
                    div()
                        .w_full()
                        .px_3()
                        .py_1p5()
                        .text_xs()
                        .border_b_1()
                        .border_color(ThemeColors::border())
                        .text_color(if is_error {
                            ThemeColors::accent_red()
                        } else {
                            ThemeColors::text_muted()
                        })
                        .child(text),
                )
            })
            .child(body_element)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap_1p5()
                    .p_2()
                    .border_t_1()
                    .border_color(ThemeColors::border())
                    .child(
                        div()
                            .flex_1()
                            .child(Input::new(&goal_entity).cleanable(true)),
                    )
                    .child(
                        Button::new("maven-run-goal")
                            .small()
                            .primary()
                            .icon(IconName::Play)
                            .tooltip(crate::i18n::menu_text(cx, "maven.executeGoal"))
                            .disabled(custom_goal.trim().is_empty() || scope_pom.is_empty())
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                let goal = this.custom_goal.trim().to_string();
                                if goal.is_empty() {
                                    return;
                                }
                                this.emit_text_goal(
                                    &scope_pom,
                                    &goal,
                                    &scope_target,
                                    &scope_profiles,
                                    cx,
                                );
                            })),
                    ),
            )
    }
}

/// owner 行标签点击行为：选中模块，或仅折叠（依赖组等由 caret 覆盖时）。
#[derive(Clone)]
enum OwnerSelect {
    Module(Option<String>),
    Toggle,
}

/// owner 行折叠行为：普通节点切展开态，依赖组附带加载。
#[derive(Clone)]
enum OwnerToggle {
    Key(String),
    Deps(String),
}

/// 在模块树中按相对路径查找节点（含根）。
fn find_module_in<'a>(
    root: &'a MavenModuleNode,
    relative_path: &str,
) -> Option<&'a MavenModuleNode> {
    if relative_path == "." || relative_path.is_empty() {
        return Some(root);
    }
    fn walk<'a>(node: &'a MavenModuleNode, rel: &str) -> Option<&'a MavenModuleNode> {
        if node.relative_path == rel {
            return Some(node);
        }
        node.modules.iter().find_map(|child| walk(child, rel))
    }
    walk(root, relative_path)
}

impl MavenView {
    /// 树父节点行：caret 与标签分离，选中高亮，对齐 Tauri `TreeNode` 头部。
    #[allow(clippy::too_many_arguments)]
    fn render_owner_row(
        &self,
        id: String,
        toggle: OwnerToggle,
        icon: IconName,
        title: String,
        subtitle: Option<String>,
        selected: bool,
        select: OwnerSelect,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let caret_key = match &toggle {
            OwnerToggle::Key(key) => key.clone(),
            OwnerToggle::Deps(owner) => format!("{owner}:dependencies"),
        };
        let expanded = self.expanded.contains(&caret_key);
        let chevron = if expanded {
            IconName::ChevronDown
        } else {
            IconName::ChevronRight
        };
        let label_base_id = format!("{id}-label");
        let label = h_flex()
            .id(label_base_id)
            .flex_1()
            .min_w_0()
            .items_center()
            .gap_1p5()
            .py_1()
            .pr_2()
            .cursor_pointer()
            .child(
                Icon::new(icon)
                    .size(px(14.0))
                    .text_color(ThemeColors::text_primary()),
            )
            .child(
                div()
                    .truncate()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .child(title),
            )
            .when_some(subtitle, |el, text| {
                el.child(
                    div()
                        .truncate()
                        .font_family("monospace")
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(text),
                )
            });
        let label = match select {
            OwnerSelect::Module(rel) => {
                label.on_click(cx.listener(move |this, _event, _window, cx| {
                    this.selected_module = rel.clone();
                    cx.notify();
                }))
            }
            OwnerSelect::Toggle => {
                let toggle = toggle.clone();
                label.on_click(cx.listener(move |this, _event, _window, cx| {
                    let key = match &toggle {
                        OwnerToggle::Key(key) => key.clone(),
                        OwnerToggle::Deps(owner) => format!("{owner}:dependencies"),
                    };
                    this.dispatch_toggle(&key, cx);
                }))
            }
        };
        h_flex()
            .id(id.clone())
            .min_h(px(28.0))
            .w_full()
            .items_center()
            .rounded_sm()
            .when(selected, |row| row.bg(ThemeColors::subtle_selection()))
            .when(!selected, |row| {
                row.hover(|h| h.bg(ThemeColors::bg_tab_hover()))
            })
            .child(
                div()
                    .id(format!("{id}-caret"))
                    .flex_shrink_0()
                    .size(px(24.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .child(
                        Icon::new(chevron)
                            .size(px(12.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        let key = match &toggle {
                            OwnerToggle::Key(key) => key.clone(),
                            OwnerToggle::Deps(owner) => format!("{owner}:dependencies"),
                        };
                        this.dispatch_toggle(&key, cx);
                    })),
            )
            .child(label)
            .into_any_element()
    }

    /// Profiles 节点：勾选进 `launchPlan` 上下文。
    fn render_profiles_node(
        &self,
        profiles: &[MavenProfileItem],
        selected: &HashSet<String>,
        expanded: &HashSet<String>,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let mut out = vec![self.render_owner_row(
            "maven-profiles".to_string(),
            OwnerToggle::Key("profiles".to_string()),
            IconName::Folder,
            crate::i18n::menu_text(cx, "maven.profiles").to_string(),
            None,
            false,
            OwnerSelect::Toggle,
            cx,
        )];
        if expanded.contains("profiles") {
            let mut children = Vec::new();
            for profile in profiles {
                let checked = selected.contains(&profile.id);
                let id = profile.id.clone();
                children.push(
                    h_flex()
                        .id(format!("maven-profile-{id}"))
                        .h(px(28.0))
                        .w_full()
                        .items_center()
                        .gap_2()
                        .px_2()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_xs()
                        .text_color(ThemeColors::text_primary())
                        .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                        .child(
                            div()
                                .flex_shrink_0()
                                .size(px(14.0))
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded_sm()
                                .border_1()
                                .border_color(ThemeColors::border())
                                .when(checked, |el| {
                                    el.bg(ThemeColors::accent_blue())
                                        .border_color(ThemeColors::accent_blue())
                                })
                                .child(Icon::new(IconName::Check).size(px(10.0)).text_color(
                                    if checked {
                                        ThemeColors::foreground()
                                    } else {
                                        ThemeColors::background()
                                    },
                                )),
                        )
                        .child(div().flex_1().truncate().child(profile.id.clone()))
                        .on_click(cx.listener(move |this, _event, _window, cx| {
                            if !this.selected_profiles.remove(&id) {
                                this.selected_profiles.insert(id.clone());
                            }
                            cx.notify();
                        }))
                        .into_any_element(),
                );
            }
            out.push(child_container(children));
        }
        div().w_full().children(out).into_any_element()
    }

    /// 模块节点（含根项目）：sourceRoots + lifecycle + dependencies + 嵌套模块。
    #[allow(clippy::too_many_arguments)]
    fn render_module_node(
        &self,
        node: &MavenModuleNode,
        _parent: Option<String>,
        expanded: &HashSet<String>,
        selected_module: &Option<String>,
        selected_phase: &str,
        dep_status: &HashMap<String, MavenStatus>,
        dependencies: &HashMap<String, Vec<MavenDep>>,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let owner = owner_key(&node.relative_path);
        let selected = if node.relative_path == "." {
            selected_module.is_none()
        } else {
            selected_module.as_deref() == Some(node.relative_path.as_str())
        };
        let select_rel = if node.relative_path == "." {
            None
        } else {
            Some(node.relative_path.clone())
        };
        let mut out = vec![self.render_owner_row(
            format!("maven-{owner}"),
            OwnerToggle::Key(owner.clone()),
            IconName::Package,
            node.artifact_id.clone(),
            Some(node.packaging.clone()),
            selected,
            OwnerSelect::Module(select_rel),
            cx,
        )];
        if expanded.contains(&owner) {
            let mut children = Vec::new();
            if !node.source_roots.is_empty() {
                let key = source_roots_key(&owner);
                children.push(self.render_owner_row(
                    format!("maven-{key}"),
                    OwnerToggle::Key(key.clone()),
                    IconName::Folder,
                    crate::i18n::menu_text(cx, "maven.sourceRoots").to_string(),
                    None,
                    false,
                    OwnerSelect::Toggle,
                    cx,
                ));
                if expanded.contains(&key) {
                    let mut root_rows = Vec::new();
                    for (path, kind) in &node.source_roots {
                        root_rows.push(
                            h_flex()
                                .w_full()
                                .items_center()
                                .gap_1p5()
                                .h(px(24.0))
                                .px_2()
                                .text_xs()
                                .child(
                                    Icon::new(IconName::FileText)
                                        .size(px(12.0))
                                        .text_color(ThemeColors::text_muted()),
                                )
                                .child(div().flex_1().truncate().child(path.clone()))
                                .when(!kind.is_empty(), |el| {
                                    el.child(
                                        div()
                                            .font_family("monospace")
                                            .text_xs()
                                            .text_color(ThemeColors::text_muted())
                                            .child(kind.clone()),
                                    )
                                })
                                .into_any_element(),
                        );
                    }
                    children.push(child_container(root_rows));
                }
            }
            children.push(self.render_lifecycle_node(
                &owner,
                &node.relative_path,
                expanded,
                selected_module,
                selected_phase,
                cx,
            ));
            children.push(self.render_deps_node(
                &owner,
                &node.relative_path,
                &self.root,
                expanded,
                dep_status,
                dependencies,
                cx,
            ));
            for child in &node.modules {
                children.push(self.render_module_node(
                    child,
                    Some(owner.clone()),
                    expanded,
                    selected_module,
                    selected_phase,
                    dep_status,
                    dependencies,
                    cx,
                ));
            }
            out.push(child_container(children));
        }
        div().w_full().children(out).into_any_element()
    }

    /// Lifecycle 节点：phase 单击选中、双击运行（对齐 Tauri 单击/双击语义）。
    fn render_lifecycle_node(
        &self,
        owner: &str,
        relative_path: &str,
        expanded: &HashSet<String>,
        selected_module: &Option<String>,
        selected_phase: &str,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let key = lifecycle_key(owner);
        let mut out = vec![self.render_owner_row(
            format!("maven-{key}"),
            OwnerToggle::Key(key.clone()),
            IconName::Cog,
            crate::i18n::menu_text(cx, "maven.lifecycle").to_string(),
            None,
            false,
            OwnerSelect::Toggle,
            cx,
        )];
        if expanded.contains(&key) {
            let mut rows = Vec::new();
            for phase in MAVEN_LIFECYCLE_PHASES {
                let is_selected = selected_phase == phase
                    && (if relative_path == "." {
                        selected_module.is_none()
                    } else {
                        selected_module.as_deref() == Some(relative_path)
                    });
                let rel = relative_path.to_string();
                let phase_owned = phase.to_string();
                rows.push(
                    h_flex()
                        .id(format!("maven-{owner}-phase-{phase}"))
                        .h(px(28.0))
                        .w_full()
                        .items_center()
                        .gap_1p5()
                        .px_2()
                        .rounded_sm()
                        .cursor_pointer()
                        .text_xs()
                        .when(is_selected, |row| {
                            row.bg(ThemeColors::subtle_selection())
                                .text_color(ThemeColors::text_primary())
                        })
                        .when(!is_selected, |row| {
                            row.text_color(ThemeColors::text_primary())
                                .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                        })
                        .child(Icon::new(IconName::Play).size(px(12.0)).text_color(
                            if is_selected {
                                ThemeColors::accent_green()
                            } else {
                                ThemeColors::text_muted()
                            },
                        ))
                        .child(div().flex_1().truncate().child(phase))
                        .on_click(cx.listener(move |this, event: &ClickEvent, _window, cx| {
                            let double = matches!(
                                event,
                                ClickEvent::Mouse(m) if m.down.click_count >= 2
                            );
                            if double {
                                this.emit_run_goal(&rel, &phase_owned, cx);
                            } else {
                                this.select_phase(&rel, &phase_owned, cx);
                            }
                        }))
                        .into_any_element(),
                );
            }
            out.push(child_container(rows));
        }
        div().w_full().children(out).into_any_element()
    }

    /// 依赖节点：嵌套树 + Tauri 同式副标题 + 加载/失败重试/取消/空态。
    #[allow(clippy::too_many_arguments)]
    fn render_deps_node(
        &self,
        owner: &str,
        relative_path: &str,
        root: &str,
        expanded: &HashSet<String>,
        dep_status: &HashMap<String, MavenStatus>,
        dependencies: &HashMap<String, Vec<MavenDep>>,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let key = deps_key(owner);
        let mut out = vec![self.render_owner_row(
            format!("maven-{key}"),
            OwnerToggle::Deps(owner.to_string()),
            IconName::Package,
            crate::i18n::menu_text(cx, "maven.dependencies").to_string(),
            None,
            false,
            OwnerSelect::Toggle,
            cx,
        )];
        if expanded.contains(&key) {
            let status = dep_status
                .get(relative_path)
                .cloned()
                .unwrap_or(MavenStatus::Idle);
            let pom = pom_for_relative(root, relative_path);
            let rel = relative_path.to_string();
            let content = match &status {
                MavenStatus::Loading => div()
                    .w_full()
                    .h(px(32.0))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .child(crate::i18n::menu_text(cx, "maven.dependencyLoading")),
                    )
                    .child(
                        Button::new(format!("maven-deps-cancel-{owner}"))
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "ui.cancel"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.cancel_deps(&rel, cx);
                            })),
                    )
                    .into_any_element(),
                MavenStatus::Failed(err) => v_flex()
                    .w_full()
                    .gap_1()
                    .px_2()
                    .py_1p5()
                    .child(
                        div()
                            .w_full()
                            .text_xs()
                            .text_color(ThemeColors::accent_red())
                            .child(err.clone()),
                    )
                    .child(
                        Button::new(format!("maven-deps-retry-{owner}"))
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "ui.retry"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.load_deps(&rel, cx);
                            })),
                    )
                    .into_any_element(),
                MavenStatus::Cancelled => div()
                    .w_full()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py_1()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .child(crate::i18n::menu_text(cx, "maven.dependencyCancelled")),
                    )
                    .child(
                        Button::new(format!("maven-deps-retry-{owner}"))
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "ui.retry"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.load_deps(&rel, cx);
                            })),
                    )
                    .into_any_element(),
                MavenStatus::Idle | MavenStatus::Ready => match dependencies.get(relative_path) {
                    Some(deps) if !deps.is_empty() => div()
                        .w_full()
                        .children(Self::render_dep_rows(deps, &pom, owner, cx))
                        .into_any_element(),
                    _ => div()
                        .w_full()
                        .px_2()
                        .py_1()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(crate::i18n::menu_text(cx, "maven.noDependencies"))
                        .into_any_element(),
                },
            };
            out.push(child_container(vec![content]));
        }
        div().w_full().children(out).into_any_element()
    }

    /// 依赖行递归渲染：标题 artifactId + Tauri 同式副标题；omitted 警告色；
    /// 点击打开所属模块 pom（对齐 Tauri 点击开 pom）。
    fn render_dep_rows(
        deps: &[MavenDep],
        pom: &str,
        owner: &str,
        cx: &mut Context<Self>,
    ) -> Vec<gpui_kit::AnyElement> {
        deps.iter()
            .enumerate()
            .map(|(index, dep)| {
                let omitted = dep.resolution != "resolved";
                let pom_owned = pom.to_string();
                let mut out = vec![h_flex()
                    .id(format!("maven-{owner}-dep-{index}-{}", dep.artifact))
                    .min_h(px(28.0))
                    .w_full()
                    .items_center()
                    .gap_1p5()
                    .px_2()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(IconName::Package)
                            .size(px(12.0))
                            .text_color(if omitted {
                                ThemeColors::warning()
                            } else {
                                ThemeColors::text_primary()
                            }),
                    )
                    .child(div().truncate().child(dep.artifact.clone()))
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .font_family("monospace")
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child(dep_subtitle(dep, cx)),
                    )
                    .on_click(cx.listener(move |_this, _event, _window, cx| {
                        cx.emit(MavenEvent::OpenFile(pom_owned.clone()));
                    }))
                    .into_any_element()];
                if !dep.children.is_empty() {
                    out.push(child_container(Self::render_dep_rows(
                        &dep.children,
                        pom,
                        owner,
                        cx,
                    )));
                }
                div().w_full().children(out).into_any_element()
            })
            .collect()
    }

    /// 自定义 goal 文本执行：标题 `{goal} · {target}`（对齐 Tauri 任务标题）。
    fn emit_text_goal(
        &mut self,
        pom_path: &str,
        goal: &str,
        target: &str,
        profiles: &[String],
        cx: &mut Context<Self>,
    ) {
        cx.emit(MavenEvent::RunGoal {
            pom_path: pom_path.to_string(),
            phase: goal.to_string(),
            target: target.to_string(),
            profiles: profiles.to_vec(),
            skip_tests: self.skip_tests,
        });
    }
}
