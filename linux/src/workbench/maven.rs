//! 右侧 Maven 导航工具窗口：项目树 + 生命周期阶段 + 依赖 + 自定义 goal，对齐 Tauri
//! `windows/tauri/src/features/maven/` 的导航语义。
//!
//! 本面板只负责导航展示与事件发射：点击阶段行 / 自定义 goal 执行按钮发射
//! [`MavenEvent::RunGoal`]，实际命令执行由外部经底部 Terminal 完成（`view.rs`
//! 拼出 `mvn -f "<pom>" <goal>`）。工程结构（`maven.scan`）与依赖加载
//! （`maven.dependencyPlan` + `maven.dependencies`）经 [`CoreClient`] 在
//! `cx.spawn` 里异步调用 core 命令；本地 pom 发现（[`find_pom_files`]）先行，
//! core 失败只落工程/依赖状态，不阻塞导航展示。

use std::collections::HashSet;

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, EventEmitter, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window,
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
fn lifecycle_key(pom: &str) -> String {
    format!("{pom}#lifecycle")
}

/// 依赖组的展开键。
fn deps_key(pom: &str) -> String {
    format!("{pom}#deps")
}

/// phase 行的稳定节点 id，同时用作选中键。
fn phase_id(pom: &str, phase: &str) -> String {
    format!("{pom}#lifecycle#{phase}")
}

/// 从选中行 id 反推所属 pom：只有 phase 行可反推，其余返回空。
fn selected_pom(selected: &Option<String>) -> Option<String> {
    selected
        .as_ref()
        .and_then(|id| id.split_once("#lifecycle#").map(|(pom, _)| pom.to_string()))
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

/// pom 所在目录相对 root 的模块路径：根 pom 为 `.`，与 core 的模块路径约定一致。
fn module_path_for_pom(root: &str, pom: &str) -> String {
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

/// 对齐 Tauri `projectStatus` 的工程状态：`idle` / `loading` / `ready` / `failed`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MavenStatus {
    Idle,
    Loading,
    Ready,
    Failed(String),
}

/// 依赖列表行的最小展示字段，来自 `maven.dependencies` 返回的
/// `dependencies[]`（`groupId` / `artifactId` / `version` / `scope`）。
#[derive(Debug, Clone)]
pub struct MavenDep {
    pub group: String,
    pub artifact: String,
    pub version: String,
    pub scope: String,
}

/// 从 `maven.dependencies` 的返回体解析依赖列表，缺失字段的行直接丢弃。
fn parse_deps(data: &serde_json::Value) -> Vec<MavenDep> {
    data.get("dependencies")
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    Some(MavenDep {
                        group: item.get("groupId")?.as_str()?.to_string(),
                        artifact: item.get("artifactId")?.as_str()?.to_string(),
                        version: item
                            .get("version")
                            .and_then(|value| value.as_str())
                            .unwrap_or_default()
                            .to_string(),
                        scope: item
                            .get("scope")
                            .and_then(|value| value.as_str())
                            .unwrap_or_default()
                            .to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Maven 导航面板派发的事件：执行只发射，由外部经底部 Terminal 执行。
#[derive(Debug, Clone)]
pub enum MavenEvent {
    RunGoal { pom_path: String, phase: String },
    Close,
}

/// 右侧 Maven 导航工具窗口：项目树 + 生命周期阶段 + 依赖 + 自定义 goal。
pub struct MavenView {
    pub root: String,
    poms: Vec<String>,
    expanded: HashSet<String>,
    selected: Option<String>,
    project_status: MavenStatus,
    project_name: Option<String>,
    dependencies: Vec<MavenDep>,
    dep_status: MavenStatus,
    /// 一次只展开一个模块的依赖组，存 pom 绝对路径。
    expanded_deps: Option<String>,
    custom_goal: String,
    goal_input: Option<Entity<InputState>>,
    _goal_subscription: Option<Subscription>,
    client: CoreClient,
    scan_seq: u64,
    dep_seq: u64,
}

impl EventEmitter<MavenEvent> for MavenView {}

impl MavenView {
    pub fn new(root: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            root,
            poms: Vec::new(),
            expanded: HashSet::new(),
            selected: None,
            project_status: MavenStatus::Idle,
            project_name: None,
            dependencies: Vec::new(),
            dep_status: MavenStatus::Idle,
            expanded_deps: None,
            custom_goal: String::new(),
            goal_input: None,
            _goal_subscription: None,
            client: CoreClient::new(),
            scan_seq: 0,
            dep_seq: 0,
        };
        view.reload(cx);
        view
    }

    pub fn set_root(&mut self, root: String, cx: &mut Context<Self>) {
        self.root = root;
        self.expanded_deps = None;
        self.dependencies.clear();
        self.dep_status = MavenStatus::Idle;
        self.reload(cx);
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.expanded_deps = None;
        self.dependencies.clear();
        self.dep_status = MavenStatus::Idle;
        self.reload(cx);
    }

    pub fn has_projects(&self) -> bool {
        !self.poms.is_empty()
    }

    /// 重扫 pom 列表并默认展开全部 pom 节点与 Lifecycle 组。
    fn rescan(&mut self) {
        self.poms = find_pom_files(&self.root);
        self.expanded.clear();
        for pom in &self.poms {
            self.expanded.insert(pom.clone());
            self.expanded.insert(lifecycle_key(pom));
        }
    }

    /// 本地重扫 + core `maven.scan` 拿模块结构：
    /// payload `{root, paths}`（相对 pom 路径），返回 `MavenScanResponse`
    ///（`relativePath` / `artifactId` / `modules` / `profiles` …）或 `null`
    ///（未检出工程）。失败只落 `project_status`，导航照常展示本地 pom。
    fn reload(&mut self, cx: &mut Context<Self>) {
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
                        view.project_name = data
                            .get("artifactId")
                            .and_then(|value| value.as_str())
                            .map(str::to_string);
                        view.project_status = MavenStatus::Ready;
                    }
                    Err(err) => {
                        view.project_name = None;
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

    /// 依赖组一次只展开一个：收起直接关，展开则触发依赖加载。
    fn toggle_deps(&mut self, pom: &str, cx: &mut Context<Self>) {
        if self.expanded_deps.as_deref() == Some(pom) {
            self.expanded_deps = None;
            cx.notify();
        } else {
            self.expanded_deps = Some(pom.to_string());
            self.load_deps(pom, cx);
        }
    }

    /// 先 `maven.dependencyPlan` 校验模块并拿出确定的离线调用计划
    /// （payload `{root, context: {version: 1, reactorPath: "."}, module}`，
    /// 返回 `MavenLaunchPlanResponse`），再 `maven.dependencies`
    /// （payload `{modulePath, output}`，返回 `{modulePath, dependencies[]}`）
    /// 解析依赖列表。Linux 侧无 Maven 进程宿主，`output` 为空即返回空列表；
    /// 真实树需在终端运行 `dependency:tree`，失败文案直接展示。
    fn load_deps(&mut self, pom: &str, cx: &mut Context<Self>) {
        self.dep_seq += 1;
        let seq = self.dep_seq;
        self.dep_status = MavenStatus::Loading;
        self.dependencies.clear();
        cx.notify();

        let client = self.client.clone();
        let root = self.root.clone();
        let module = module_path_for_pom(&self.root, pom);
        cx.spawn(async move |this, cx| {
            let plan = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "maven.dependencyPlan",
                    serde_json::json!({
                        "root": root,
                        "context": { "version": 1, "reactorPath": "." },
                        "module": module,
                    }),
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
                if view.dep_seq != seq {
                    return;
                }
                match outcome {
                    Ok(deps) => {
                        view.dependencies = deps;
                        view.dep_status = MavenStatus::Ready;
                    }
                    Err(err) => {
                        view.dep_status = MavenStatus::Failed(err);
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

        // 快照后构建行，避免在 `.children` 闭包里同时借用 self 与 cx。
        let root = self.root.clone();
        let poms = self.poms.clone();
        let expanded = self.expanded.clone();
        let selected = self.selected.clone();
        let project_status = self.project_status.clone();
        let project_name = self.project_name.clone();
        let expanded_deps = self.expanded_deps.clone();
        let dep_status = self.dep_status.clone();
        let dependencies = self.dependencies.clone();
        let custom_goal = self.custom_goal.clone();
        let has_projects = !poms.is_empty();

        let title_text = match &project_name {
            Some(name) => format!("{} · {name}", crate::i18n::menu_text(cx, "maven.title")),
            None => crate::i18n::menu_text(cx, "maven.title").to_string(),
        };
        let status_banner: Option<(bool, String)> = match &project_status {
            MavenStatus::Loading => Some((false, "正在扫描 Maven 项目…".to_string())),
            MavenStatus::Failed(err) => Some((true, err.clone())),
            MavenStatus::Idle | MavenStatus::Ready => None,
        };
        // 自定义 goal 的执行目标：选中 phase 行归属的 pom，否则首个 pom。
        let goal_target = selected_pom(&selected).or_else(|| poms.first().cloned());

        let mut rows = Vec::new();
        for pom in &poms {
            let pom_expanded = expanded.contains(pom);
            let chevron = if pom_expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            };
            let display = display_pom_path(&root, pom);
            rows.push(
                h_flex()
                    .id(pom.clone())
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(6.0))
                    .pr_2()
                    .gap_1p5()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(chevron)
                            .size(px(12.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        Icon::new(IconName::Box)
                            .size(px(14.0))
                            .text_color(ThemeColors::accent_blue()),
                    )
                    .child(div().flex_1().truncate().child(display))
                    .on_click(cx.listener({
                        let pom = pom.clone();
                        move |this, _event, _window, cx| {
                            this.toggle_node(&pom, cx);
                        }
                    }))
                    .into_any_element(),
            );
            if !pom_expanded {
                continue;
            }

            let group_key = lifecycle_key(pom);
            let group_expanded = expanded.contains(&group_key);
            let group_chevron = if group_expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            };
            rows.push(
                h_flex()
                    .id(group_key.clone())
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(18.0))
                    .pr_2()
                    .gap_1p5()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(group_chevron)
                            .size(px(12.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        Icon::new(IconName::Package)
                            .size(px(14.0))
                            .text_color(ThemeColors::accent_blue()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .child(crate::i18n::menu_text(cx, "maven.lifecycle")),
                    )
                    .on_click(cx.listener({
                        let group_key = group_key.clone();
                        move |this, _event, _window, cx| {
                            this.toggle_node(&group_key, cx);
                        }
                    }))
                    .into_any_element(),
            );
            if group_expanded {
                for phase in MAVEN_LIFECYCLE_PHASES {
                    let row_id = phase_id(pom, phase);
                    let is_selected = selected.as_deref() == Some(row_id.as_str());
                    rows.push(
                        h_flex()
                            .id(row_id.clone())
                            .h(px(24.0))
                            .w_full()
                            .items_center()
                            .cursor_pointer()
                            .rounded_sm()
                            .pl(px(30.0))
                            .pr_2()
                            .gap_1p5()
                            .text_xs()
                            .when(is_selected, |row| {
                                row.bg(ThemeColors::subtle_selection())
                                    .text_color(ThemeColors::text_primary())
                            })
                            .when(!is_selected, |row| {
                                row.text_color(ThemeColors::text_primary())
                                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                            })
                            .child(
                                Icon::new(IconName::Play)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::text_muted()),
                            )
                            .child(div().flex_1().truncate().child(phase))
                            .on_click(cx.listener({
                                let pom = pom.clone();
                                let phase = phase.to_string();
                                move |this, _event, _window, cx| {
                                    this.selected = Some(phase_id(&pom, &phase));
                                    cx.emit(MavenEvent::RunGoal {
                                        pom_path: pom.clone(),
                                        phase: phase.clone(),
                                    });
                                    cx.notify();
                                }
                            }))
                            .into_any_element(),
                    );
                }
            }

            // 依赖组：一次只展开一个模块，点击触发 dependencyPlan + dependencies。
            let deps_open = expanded_deps.as_deref() == Some(pom.as_str());
            let deps_chevron = if deps_open {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            };
            rows.push(
                h_flex()
                    .id(deps_key(pom))
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(18.0))
                    .pr_2()
                    .gap_1p5()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(deps_chevron)
                            .size(px(12.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        Icon::new(IconName::Package)
                            .size(px(14.0))
                            .text_color(ThemeColors::accent_blue()),
                    )
                    .child(div().flex_1().truncate().child("依赖"))
                    .on_click(cx.listener({
                        let pom = pom.clone();
                        move |this, _event, _window, cx| {
                            this.toggle_deps(&pom, cx);
                        }
                    }))
                    .into_any_element(),
            );
            if deps_open {
                match &dep_status {
                    MavenStatus::Loading => {
                        rows.push(
                            div()
                                .w_full()
                                .pl(px(30.0))
                                .pr_2()
                                .py_1()
                                .text_xs()
                                .text_color(ThemeColors::text_muted())
                                .child("正在加载依赖…")
                                .into_any_element(),
                        );
                    }
                    MavenStatus::Failed(err) => {
                        rows.push(
                            div()
                                .w_full()
                                .pl(px(30.0))
                                .pr_2()
                                .py_1()
                                .text_xs()
                                .text_color(ThemeColors::accent_red())
                                .child(err.clone())
                                .into_any_element(),
                        );
                    }
                    MavenStatus::Idle | MavenStatus::Ready if dependencies.is_empty() => {
                        rows.push(
                            div()
                                .w_full()
                                .pl(px(30.0))
                                .pr_2()
                                .py_1()
                                .text_xs()
                                .text_color(ThemeColors::text_muted())
                                .child("暂无依赖数据")
                                .into_any_element(),
                        );
                    }
                    MavenStatus::Idle | MavenStatus::Ready => {
                        for (index, dep) in dependencies.iter().enumerate() {
                            let label = format!(
                                "{}:{}:{} [{}]",
                                dep.group, dep.artifact, dep.version, dep.scope
                            );
                            rows.push(
                                h_flex()
                                    .id(format!("{pom}#dep#{index}"))
                                    .w_full()
                                    .items_center()
                                    .rounded_sm()
                                    .pl(px(30.0))
                                    .pr_2()
                                    .py_1()
                                    .gap_1p5()
                                    .text_xs()
                                    .text_color(ThemeColors::text_primary())
                                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                                    .child(div().flex_1().truncate().child(label))
                                    .into_any_element(),
                            );
                        }
                    }
                }
            }
        }

        let goal_entity_for_run = goal_entity.clone();
        let goal_target_for_run = goal_target.clone();
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
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(ThemeColors::text_muted())
                            .child(title_text),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(
                                Button::new("maven-refresh")
                                    .small()
                                    .ghost()
                                    .icon(IconName::RotateCw)
                                    .tooltip(crate::i18n::menu_text(cx, "ui.refresh"))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.refresh(cx);
                                    })),
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
            .child(if has_projects {
                div()
                    .flex_1()
                    .w_full()
                    .overflow_y_scrollbar()
                    .children(rows)
                    .into_any_element()
            } else {
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(crate::i18n::menu_text(cx, "maven.noProjects"))
                    .into_any_element()
            })
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
                            .tooltip("执行自定义 goal")
                            .disabled(
                                custom_goal.trim().is_empty() || goal_target_for_run.is_none(),
                            )
                            .on_click(cx.listener(move |_this, _event, _window, cx| {
                                let goal = goal_entity_for_run.read(cx).value().to_string();
                                let goal = goal.trim().to_string();
                                if goal.is_empty() {
                                    return;
                                }
                                if let Some(pom) = goal_target_for_run.clone() {
                                    cx.emit(MavenEvent::RunGoal {
                                        pom_path: pom,
                                        phase: goal,
                                    });
                                }
                            })),
                    ),
            )
    }
}
