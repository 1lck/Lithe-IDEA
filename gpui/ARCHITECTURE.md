# Lithe GPUI 工作台：工程契约

这份文档是并行开发的接口冻结面。所有 crate 必须按这里的公开 API 互相调用；实现可以变，签名不能私自改。需要改签名时先停下来说明原因。

## 目标与边界

- 以 macOS 现有界面为原型，用 Rust/GPUI 重建工作台，代码按 macOS、Windows、Linux 三端可编译来写。
- 业务能力全部来自 `../rust/lithe-core`，界面不复制业务规则。
- 不参考、不依赖 `windows/tauri`。
- 本轮只做 Phase 0 骨架：壳、主题、核心客户端、平台抽象、项目树、编辑器 WebView、桌面入口。
- **禁止运行任何编译、构建、测试、格式化命令**：`cargo`、`rustc`、`rustfmt`、`bun`、`npm`、`make`、`xcodebuild` 等全部不允许。只允许读文件和写文件。

## 依赖方向

```text
lithe-desktop
  ├── lithe-workbench
  │     ├── lithe-features
  │     │     ├── lithe-ui
  │     │     ├── lithe-core-client
  │     │     └── lithe-platform
  │     ├── lithe-ui
  │     ├── lithe-core-client
  │     └── lithe-platform
  ├── lithe-ui
  ├── lithe-core-client
  └── lithe-platform
```

`lithe-features` 不得依赖 `lithe-workbench`，避免循环依赖。

## 顶部菜单栏

应用菜单栏是三端统一的自绘实现，不使用 macOS 原生菜单：

- `lithe-ui/src/components/menu_bar.rs` 提供 `LitheMenuBar`（触发器行）与
  `MenuSpec` / `MenuItemSpec`（声明式菜单树），下拉菜单复用 gpui-kit 的
  `PopupMenu`（定位、子菜单、键盘上下选择、Esc/外部点击关闭、滚动）。
- 菜单树由 `lithe-workbench/src/app_menu.rs::build_menus` 生成，手势与快捷键
  最终都收敛到 `Workbench::run_menu_command` 的字符串命令 id。
- 视觉按 macOS 原型：13pt 标签、22pt 触发器、左勾选位、右对齐 ⌘ 快捷键；
  快捷键文案三端一致显示 ⌘，真实绑定由工作台的 `KeyBinding` 同时注册
  `cmd-*` / `ctrl-*`。
- 不在 UI 层写 `cfg(target_os)` 分支；平台差异只留在 `lithe-platform`。

## 菜单命令与工作台能力

- 菜单数据由 `lithe-workbench/src/app_menu.rs` 的 `build_menus` 生成，只组装声明式描述（`MenuSpec` / `MenuItemSpec`），不持实体、不做 I/O。
- 所有菜单项与快捷键收敛到统一的 `MenuCommand`；它实现在 `lithe_ui::components::menu_bar`，`app_menu` 只做再导出，派发入口是 `Workbench::run_menu_command`。
- `app_menu.rs` 的 `command_handled` 是唯一白名单：没有接线到 `run_menu_command` 的条目一律禁用，不给出假可用的菜单项。

已实现：

| 能力 | 位置与行为 |
| --- | --- |
| Quick Open | `lithe-features/src/quick_open.rs`；打开面板时在 `background_spawn` 里递归扫描项目文件，输入时做模糊过滤（子串命中优先，其次文件名 / 相对路径的子序列匹配） |
| Save As | 编辑器 → JS 往返（Monaco 发起保存请求）→ Rust 在后台写盘 → `EditorEvent::SavedAs` → 工作台迁移标签路径与脏状态 |
| Local History | `lithe-features/src/local_history.rs`；每次保存记一份快照，按绝对路径哈希分目录，每文件保留 50 份；恢复只写编辑器缓冲并标记未保存，不直接写盘 |
| 通用输入弹窗 | `lithe-ui/src/components/prompt.rs` 的 `LithePrompt`；New File / New Folder / New Project / 新建 Java 类型与包共用 |
| 终端分屏 | Terminal > Split Right / Split Down；复用两个独立 `TerminalPanel`，各自持有 PTY 与 WebView；已分屏时只切换方向，不重建实体 |
| 编辑器分屏 | Split Editor 打开只读副窗格，只观察当前活动文件；不接收编辑、不参与 Save / Save As，写盘仍只经过主编辑器 |

调试（Stop / Breakpoint）未接入：`lithe-core` 已有 DAP 命令面（`debug.*`），但 GPUI 宿主缺少 DAP 传输层与调试 UI，菜单项保持禁用。

启动参数：`--open-project <path>` 在 `Workbench::new` 构造期解析；路径是有效目录时直接打开，缺失或无效时静默忽略，保持欢迎页 / 最近项目行为。

## 必读源码

gpui-kit 的真实接口以本地仓库为准，禁止按记忆编造：

- umbrella 导出：`C:\Users\momo\Desktop\pro\github\gpui-kit\crates\kit\src\lib.rs`
- 组件导出：`C:\Users\momo\Desktop\pro\github\gpui-kit\crates\component\src\lib.rs`
- 主题：`crates/component/src/theme/mod.rs`、`theme/theme_color.rs`
- 组件：`title_bar.rs`、`status_bar.rs`、`tab/tab_bar.rs`、`resizable.rs`、`tree.rs`、`sidebar/`
- WebView：`crates/webview/src/lib.rs`、`examples/webview/src/main.rs`

macOS 设计真源：

- `macos/Sources/Lithe/Theme/LitheTheme.swift`（颜色、字体、尺寸）
- `macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`（顶栏、活动栏、状态栏、工具窗）
- `macos/Sources/Lithe/Views/Components/`（共享控件）
- `macos/Sources/Lithe/Application/Features/WorkbenchFeatureModel.swift`（工具窗清单）
- `docs/visual-qa/01-java-editor-project-tree.png`（目标外观）

## 设计 token

Lithe 主题（深色）：

| token | 值 |
| --- | --- |
| window | `#28292C` |
| titlebar | `#28292C` |
| tool_header | `#191A1C` |
| sidebar / editor | `#191A1C` |
| raised | `#2A2D31` |
| selection / accent | `#3574F0` |
| subtle_selection | `#34383D` |
| hover | `rgba(255,255,255,0.09)` |
| pressed | `rgba(255,255,255,0.095)` |
| divider | `#2E3036` |
| panel_border | `#434546` |
| primary_text | `#DFE1E5` |
| secondary_text | `rgba(255,255,255,0.50)` |
| tertiary_text | `rgba(255,255,255,0.34)` |
| success | `#47B863` |
| warning | `#E8A033` |
| error | `#EB5454` |
| link | `#6BAEFF` |
| diff_inserted | `#294436` |
| diff_deleted | `#484A4A` |
| diff_modified | `#385570` |

Lithe 主题（浅色）：

| token | 值 |
| --- | --- |
| window | `#EEF1F5` |
| titlebar | `#E8EBEF` |
| tool_header | `#FBFBFB` |
| sidebar / editor | `#FFFFFF` |
| raised | `#F7F8FA` |
| selection / accent | `#3574F0` |
| subtle_selection | `#E9EBEF` |
| hover | `#F2F3F5` |
| pressed | `#E1E3E7` |
| divider | `#D8DADF` |
| panel_border | `#C9CCD2` |
| primary_text | `#1F2329` |
| secondary_text | `#5F6570` |
| tertiary_text | `#818892` |
| success | `#1B8B3C` |
| warning | `#B06909` |
| error | `#C72D2D` |
| link | `#1A5CB8` |
| diff_inserted | `#BEE6BE` |
| diff_deleted | `#D6D6D6` |
| diff_modified | `#C2D8F2` |

Codex 与 Linear 主题从 `LitheTheme.swift` 的 `Palette.make` 读取，不在这里复制第二份。

尺寸：

| 名称 | 值 |
| --- | --- |
| `TOP_BAR_HEIGHT` | 40.0 |
| `ACTIVITY_RAIL_WIDTH` | 40.0 |
| `ACTIVITY_BUTTON_SIZE` | 30.0 |
| `ACTIVITY_ICON_SIZE` | 20.0 |
| `ACTIVITY_SLOT_WIDTH` | 37.0 |
| `ACTIVITY_SLOT_HEIGHT` | 40.0 |
| `TOOL_WINDOW_HEADER_HEIGHT` | 41.0 |
| `EDITOR_TAB_HEIGHT` | 34.0 |
| `STATUS_BAR_HEIGHT` | 24.0 |
| `TREE_ROW_HEIGHT` | 24.0 |
| `PROJECT_TREE_ROW_HEIGHT` | 27.0 |
| `TREE_ICON_SIZE` | 16.0 |
| `TREE_INDENT` | 19.0 |
| `PANE_RADIUS` | 10.0 |
| `CONTROL_RADIUS` | 6.0 |
| `MENU_RADIUS` | 8.0 |
| `TAB_UNDERLINE_HEIGHT` | 3.0 |
| `UI_FONT_SIZE` | 14.0 |
| `SETTINGS_FONT_SIZE` | 13.0 |
| `SMALL_FONT_SIZE` | 12.0 |
| `CODE_FONT_SIZE` | 13.0 |
| `MIN_PANE_SIZE` | 30.0 |

字体系列：界面 `Inter`，代码 `JetBrains Mono`。本轮不复制字体二进制；`install_fonts` 设置主题字体并保留 TODO，缺失时由 GPUI 回退。

## `lithe-ui` 公开 API

```rust
pub use icons::{icon, LitheIcon};
pub use metrics::LitheMetrics;
pub use theme::{current_tokens, install_theme, toggle_dark};
pub use tokens::{LitheThemeKind, LitheTokens};
pub use fonts::{install_fonts, MONO_FONT_FAMILY, UI_FONT_FAMILY};
pub mod components;
pub mod i18n;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LitheThemeKind { Lithe, Codex, Linear }

#[derive(Clone, Copy, Debug)]
pub struct LitheTokens {
    pub window: Hsla,
    pub titlebar: Hsla,
    pub tool_header: Hsla,
    pub sidebar: Hsla,
    pub editor: Hsla,
    pub raised: Hsla,
    pub selection: Hsla,
    pub subtle_selection: Hsla,
    pub hover: Hsla,
    pub pressed: Hsla,
    pub divider: Hsla,
    pub panel_border: Hsla,
    pub primary_text: Hsla,
    pub secondary_text: Hsla,
    pub tertiary_text: Hsla,
    pub accent: Hsla,
    pub run: Hsla,
    pub success: Hsla,
    pub warning: Hsla,
    pub error: Hsla,
    pub link: Hsla,
    pub diff_inserted: Hsla,
    pub diff_deleted: Hsla,
    pub diff_modified: Hsla,
}

impl LitheTokens {
    pub fn for_theme(kind: LitheThemeKind, dark: bool) -> Self;
}

pub fn install_theme(cx: &mut App, kind: LitheThemeKind, dark: bool);
pub fn toggle_dark(cx: &mut App);
pub fn current_tokens(cx: &App) -> LitheTokens;

pub fn install_fonts(cx: &mut App);
pub const UI_FONT_FAMILY: &str = "Inter";
pub const MONO_FONT_FAMILY: &str = "JetBrains Mono";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LitheIcon {
    Project, Changes, Search, PullRequests, GitLog, Terminal, Agent,
    References, Problems, Spring, Run, Tests, Debug, BuildOutput,
    Notifications, Settings, Refresh, Collapse, Close,
    ChevronDown, ChevronRight, File, Folder, FolderOpen, Java, Markdown, Plus, More,
}

pub fn icon(icon: LitheIcon) -> gpui_kit::component::Icon;

pub mod i18n {
    /// Phase 0 的临时静态表；后续由 shared/i18n 生成 Rust 目标替换。
    pub fn tr(key: &'static str) -> &'static str;
}

pub mod components {
    pub mod activity_rail;
    pub mod editor_tabs;
    pub mod status_bar;
    pub mod tool_window_header;
}

// components::activity_rail
pub struct ActivityRailItem {
    pub id: &'static str,
    pub icon: LitheIcon,
    pub label: &'static str,
}
impl ActivityRailItem {
    pub fn new(id: &'static str, icon: LitheIcon, label: &'static str) -> Self;
}

pub struct ActivityRail;
impl ActivityRail {
    pub fn new(id: impl Into<ElementId>) -> Self;
    pub fn items(self, items: impl IntoIterator<Item = ActivityRailItem>) -> Self;
    pub fn active(self, id: &'static str) -> Self;
    pub fn on_select(self, handler: impl Fn(&'static str, &mut Window, &mut App) + 'static) -> Self;
}
impl RenderOnce for ActivityRail { /* ... */ }

// components::tool_window_header
pub struct ToolWindowHeader;
impl ToolWindowHeader {
    pub fn new(title: impl Into<SharedString>) -> Self;
    pub fn actions(self, actions: impl IntoIterator<Item = AnyElement>) -> Self;
    pub fn on_collapse(self, handler: impl Fn(&mut Window, &mut App) + 'static) -> Self;
}
impl RenderOnce for ToolWindowHeader { /* ... */ }

// components::editor_tabs
pub struct EditorTabItem {
    pub id: SharedString,
    pub title: SharedString,
    pub icon: Option<LitheIcon>,
    pub modified: bool,
}
impl EditorTabItem {
    pub fn new(id: impl Into<SharedString>, title: impl Into<SharedString>) -> Self;
}

pub struct EditorTabs;
impl EditorTabs {
    pub fn new(id: impl Into<ElementId>) -> Self;
    pub fn tabs(self, tabs: impl IntoIterator<Item = EditorTabItem>) -> Self;
    pub fn active(self, id: impl Into<SharedString>) -> Self;
    pub fn on_select(self, handler: impl Fn(SharedString, &mut Window, &mut App) + 'static) -> Self;
    pub fn on_close(self, handler: impl Fn(SharedString, &mut Window, &mut App) + 'static) -> Self;
}
impl RenderOnce for EditorTabs { /* ... */ }

// components::status_bar
pub struct StatusBarItem {
    pub id: SharedString,
    pub text: SharedString,
    pub icon: Option<LitheIcon>,
}
impl StatusBarItem {
    pub fn new(id: impl Into<SharedString>, text: impl Into<SharedString>) -> Self;
    pub fn icon(self, icon: LitheIcon) -> Self;
}

pub struct LitheStatusBar;
impl LitheStatusBar {
    pub fn new(left: impl IntoIterator<Item = StatusBarItem>,
               right: impl IntoIterator<Item = StatusBarItem>) -> Self;
}
impl RenderOnce for LitheStatusBar { /* ... */ }
```

## `lithe-core-client` 公开 API

所有方法都是阻塞调用；调用方必须放在 `cx.background_spawn` 或后台线程里，不得直接阻塞渲染线程。

```rust
pub struct CoreClient;
impl CoreClient {
    pub fn new() -> Self;
    pub fn ping(&self) -> Result<(), CoreError>;
    pub fn workspace_snapshot(&self, root: &Path) -> Result<WorkspaceSnapshot, CoreError>;
    pub fn list_directories(&self, root: &Path, paths: &[String]) -> Result<Vec<DirectoryListing>, CoreError>;
    pub fn read_file(&self, root: &Path, path: &str) -> Result<FileReadResult, CoreError>;
    pub fn write_file(&self, root: &Path, path: &str, text: &str) -> Result<usize, CoreError>;
    pub fn execute_raw(&self, command: &str, payload: serde_json::Value) -> Result<serde_json::Value, CoreError>;
    pub fn cancel(&self, operation_id: &str) -> bool;
}

#[derive(Debug, Clone)]
pub struct CoreError {
    pub code: String,
    pub message: String,
    pub details: Option<serde_json::Value>,
}
impl std::fmt::Display for CoreError { /* ... */ }
impl std::error::Error for CoreError {}

#[derive(Debug, Clone)]
pub struct WorkspaceNode {
    pub path: String,
    pub name: String,
    pub is_directory: bool,
    pub children: Vec<WorkspaceNode>,
}
impl WorkspaceNode {
    pub fn children_loaded(&self) -> bool;
}

#[derive(Debug, Clone)]
pub struct WorkspaceSnapshot {
    pub root: WorkspaceNode,
    pub files: Vec<String>,
    pub nested_worktrees: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct DirectoryListing {
    pub path: String,
    pub children: Vec<WorkspaceNode>,
}

#[derive(Debug, Clone)]
pub struct FileReadResult {
    pub path: String,
    pub text: String,
}
```

命令名与 payload 必须与 `rust/lithe-core/src/protocol/command.rs`、`project/files.rs`、`protocol/contracts.rs` 一致：`core.ping`、`workspace.snapshot`、`workspace.listDirectories`、`file.read`、`file.write`。响应外层是 `{ id, ok, data, error }`。

## `lithe-platform` 公开 API

```rust
pub type PlatformFuture<T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + 'static>>;

pub struct FileFilter {
    pub name: String,
    pub extensions: Vec<String>,
}

pub trait PlatformServices: Send + Sync + 'static {
    fn pick_folder(&self, title: String) -> PlatformFuture<Option<PathBuf>>;
    fn pick_file(&self, title: String, filters: Vec<FileFilter>) -> PlatformFuture<Option<PathBuf>>;
    fn open_url(&self, url: &str) -> bool;
    fn recent_projects(&self) -> Vec<PathBuf>;
    fn remember_project(&self, path: &Path);
}

pub fn current() -> std::sync::Arc<dyn PlatformServices>;
```

`current()` 按 `cfg(target_os)` 返回 macOS / Windows / Linux 实现。最近项目存到各平台应用数据目录；本轮用标准库环境变量推导，不新增依赖。

选择框必须异步调用：在 GPUI 事件回调里同步打开原生模态框，会让 Windows 的对话框消息循环重入 GPUI 窗口借用并直接 abort。正确写法是在事件回调里 `cx.spawn_in(window, async move |this, cx| { let path = platform.pick_folder(title).await; ... })`。

## `lithe-features` 公开 API

```rust
pub mod editor;
pub mod welcome;
pub mod workspace;

pub use editor::EditorSurface;
pub use welcome::WelcomeView;
pub use workspace::ProjectTree;

// workspace::ProjectTree
impl ProjectTree {
    pub fn new(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self;
    pub fn set_root(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>);
    pub fn root(&self) -> Option<PathBuf>;
    pub fn expand(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>);
    pub fn collapse(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>);
    pub fn on_open_file(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static);
}
impl Render for ProjectTree { /* ... */ }

// editor::EditorSurface
impl EditorSurface {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self;
    pub fn open_file(&mut self, root: PathBuf, path: PathBuf, text: String, window: &mut Window, cx: &mut Context<Self>);
    pub fn clear(&mut self, window: &mut Window, cx: &mut Context<Self>);
    pub fn current_path(&self) -> Option<&Path>;
    pub fn mark_dirty(&mut self, dirty: bool, window: &mut Window, cx: &mut Context<Self>);
}
impl Render for EditorSurface { /* ... */ }

// welcome::WelcomeView
impl WelcomeView {
    pub fn new(platform: Arc<dyn PlatformServices>, cx: &mut Context<Self>) -> Self;
    pub fn on_open_project(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static);
    pub fn refresh_recent(&mut self, cx: &mut Context<Self>);
}
impl Render for WelcomeView { /* ... */ }
```

`EditorSurface` 本轮用 gpui-webview 加载一个最小 HTML 页面显示文件内容，保留 Monaco 接入点。它必须持有 `Entity<WebView>`，不得在 render 里重复创建。

### 路径约定

- `ProjectTree::new` 收到空 `PathBuf` 表示“还没有打开项目”，不得拿空路径请求 Core；此时 `root()` 返回 `None`。
- `ProjectTree::on_open_file` 传绝对路径（`root.join(workspace_relative)`）。
- `EditorSurface::open_file` 的第一个参数是工作区根，第二个是用于展示/标签身份的路径；调用方可以传绝对路径，但传给 Core 读写的始终是 `/` 分隔的工作区相对路径。
- 标签身份用绝对路径；Windows 下折叠大小写，避免同一文件因写法不同产生两个标签。

## `lithe-workbench` 公开 API

```rust
pub struct Workbench;
impl Workbench {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self;
    pub fn open_project(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>);
}
impl Render for Workbench { /* ... */ }
```

工作台负责组装：40pt 顶栏、40pt 左侧活动栏、项目工具窗（41pt 标题 + `ProjectTree`）、编辑区（多行标签 + `EditorSurface`）、底部工具窗（Git / Search）、24pt 状态栏。阶段 0 用 `h_resizable`/`v_resizable` 实现分栏，Dock 留到下一阶段；但布局必须集中在 `Workbench`，方便替换。

## Git / Search 面板（Phase 1）

### `lithe-features::git::GitPanel`

```rust
pub struct GitPanel;
impl GitPanel {
    pub fn new(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self;
    pub fn set_root(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>);
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>);
    pub fn on_open_file(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static);
}
impl Render for GitPanel { /* ... */ }
```

- 工具窗内分三块：Changes（暂存/未暂存/未跟踪）、提交消息 + Commit、Log。
- Core 命令：`git.status`、`git.diff`、`git.historyPage`；提交用 `git.command`，参数 `["commit","-m",message]`，不要拼 shell。
- 路径全部是工作区相对路径；`git.status` 请求带 `includeIndexOnlyChanges: true`。
- 选择文件后调用 `git.diff`，用 gpui-kit `diff::Diff` 渲染。
- 所有 Core 调用阻塞，必须 `cx.spawn` + `cx.background_spawn`。

### `lithe-features::search::SearchPanel`

```rust
pub struct SearchPanel;
impl SearchPanel {
    pub fn new(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self;
    pub fn set_root(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>);
    pub fn focus(&mut self, window: &mut Window, cx: &mut Context<Self>);
    pub fn on_open_location(
        &mut self,
        handler: impl Fn(PathBuf, u32, &mut Window, &mut App) + 'static,
    );
}
impl Render for SearchPanel { /* ... */ }
```

- 输入 + 300ms 去抖，调用 `workspace.search`；结果按文件分组。
- 点击结果回传绝对路径与 1-based 行号。
- 空结果、错误、搜索中都要有明确状态。

### 工作台底部工具区

- 默认隐藏；`v_resizable` 分上下，底部默认 260pt，最小 120，最大 500。
- 底部 tab：Git / Search；活动栏 `changes`/`git-log` 显示 Git，`search` 显示 Search，`project` 保持左侧项目栏。
- 打开项目时把 root 同步给两个面板。
- 面板回传的路径复用工作台现有 `open_file_from_tree` 链路。

## 设置、主题与命令面板（Phase 1）

### `AppSettings`（`lithe-features::settings`）

```rust
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    // Appearance & Behavior
    pub theme: String,                     // "lithe" | "codex" | "linear"
    pub dark: bool,
    pub update_channel: String,            // "stable" | "preview"
    pub auto_check_updates: bool,
    pub editor_font_size: f32,
    pub editor_wrap: bool,
    pub editor_minimap: bool,
    pub editor_line_numbers: bool,
    pub editor_scroll_beyond_last_line: bool,
    // Process termination policy (stored; enforced once long-lived services land)
    pub run_services_on_exit: String,      // "ask" | "terminate"
    pub terminal_on_quit: String,          // "ask" | "terminate"
    pub agent_tasks: String,               // "ask" | "keep" | "terminate"
    pub background_services: String,       // "ask" | "keep" | "terminate"
    pub graceful_stop_seconds: u32,
    // Terminal
    pub terminal_font_size: f32,
    pub terminal_scrollback: u32,
    // AI
    pub ai_commit_enabled: bool,
    pub ai_commit_format: String,          // "conventional" | "plain" | "gitmoji"
}
```

设置页完整导航（与 macOS 对齐）：

```text
Appearance & Behavior
  General / Updates / Editor / Keymap / Process Termination
Plugins
Version Control
  Git
Build, Execution, Deployment
  Project · JDK & Maven / Run Configurations
Languages & Frameworks
  LSP
Tools
  Terminal / Logs and Diagnostics
AI
  AI Providers / Agents / Library ▸ (Instructions / Skills / Hooks / MCP) / AI & Commit
```

外部子系统（插件、完整 LSP、Provider/MCP/Skills/Hooks）只显示真实状态或说明，不做假开关。

### `SettingsView` 上下文与回调

```rust
#[derive(Clone, Debug, Default)]
pub struct SettingsContext {
    pub project_root: Option<PathBuf>,
    pub branch: String,
    pub memory: String,
    pub agent_status: String,
}

impl SettingsView {
    pub fn new(settings: AppSettings, cx: &mut Context<Self>) -> Self;
    pub fn set_settings(&mut self, settings: AppSettings, cx: &mut Context<Self>);
    pub fn set_context(&mut self, context: SettingsContext, cx: &mut Context<Self>);
    pub fn settings(&self) -> &AppSettings;
    pub fn on_change(&mut self, handler: impl Fn(&AppSettings, &mut Window, &mut App) + 'static);
    pub fn on_open_run(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static);
    pub fn on_open_agent(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static);
}
```

### `EditorSurface` / `TerminalPanel` 外观

```rust
pub fn EditorSurface::set_preferences(
    &mut self,
    font_size: f32,
    wrap: bool,
    minimap: bool,
    line_numbers: bool,
    scroll_beyond_last_line: bool,
    window: &mut Window,
    cx: &mut Context<Self>,
);

pub fn TerminalPanel::set_preferences(
    &mut self,
    font_size: f32,
    scrollback: u32,
    window: &mut Window,
    cx: &mut Context<Self>,
);
```

Workbench 在设置变化时应用主题、编辑器偏好、终端偏好；打开设置时下发 `SettingsContext`
（项目路径、分支、内存、Agent 状态）。`on_open_run` / `on_open_agent` 关闭设置并打开对应底部 tab。

### 工作台动作

- `actions!`：`OpenProject`、`ToggleSettings`、`ToggleTheme`、`ShowGit`、`ShowSearch`、`CommandPalette`。
- 快捷键同时注册 `cmd-*` 和 `ctrl-*`：`O`、`,`、`shift-F`、`shift-G`、`shift-P`。
- 根视图 `on_action` 分发；Settings 用主窗口内覆盖层，不新开窗口。
- 命令面板用 gpui-kit `command::Command`；条目至少包含上述动作和 `Toggle Dark`。
- 状态栏或顶栏显示当前主题；切换主题立即 `install_theme` 并重绘。

## 终端（Phase 1）

采用 `xterm.js`（WebView 内容岛）+ `rust/lithe-terminal`（portable-pty）。
不自行实现 VT 解析和字形绘制；Wayland 限制与 Monaco 相同，首批只支持 X11。

### `lithe-features::terminal::TerminalPanel`

```rust
pub struct TerminalPanel;
impl TerminalPanel {
    pub fn new(root: PathBuf, window: &mut Window, cx: &mut Context<Self>) -> Self;
    pub fn set_root(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>);
    pub fn focus(&mut self, window: &mut Window, cx: &mut Context<Self>);
}
impl Render for TerminalPanel { /* ... */ }
```

- WebView 资源目录：`LITHE_GPUI_TERMINAL_DIR` 优先，否则
  `CARGO_MANIFEST_DIR/../terminal/dist`；缺少 `index.html` 时显示错误，不 panic。
- 资源协议名 `lithe-terminal-gpui`，Windows URL
  `http://lithe-terminal-gpui.localhost/index.html`，其他平台
  `lithe-terminal-gpui://localhost/index.html`。
- PTY 不在 `new` 中创建：首次 `Render`（或需要时）用 `cx.defer_in` 创建并启动
  消息泵，避免构造期借 App。`TerminalManager::create_terminal` 的 handler 只把
  `TerminalEvent::Output` 投递到 `async_channel`，不碰 GPUI。
- JS → Rust（`window.ipc.postMessage(JSON)`）：
  - `{type:"ready"}`
  - `{type:"input", data:"..."}`
  - `{type:"resize", rows, cols}`
- Rust → JS（`evaluate_script`，只主线程）：
  - `window.lithe.write("<base64>")`
  - `window.lithe.configure({ dark, background, foreground, cursor, selection, fontFamily, fontSize })`
  - `window.lithe.focus()`
  - `window.lithe.clear()`
- 输出字节用 base64 传给 JS，避免 JSON 数组膨胀。
- `set_root` 关闭旧终端并重建；`Drop` 关闭终端。
- 关闭/退出只更新面板状态，不 panic。

### 工作台

- 底部 tab 增加 Terminal；活动栏 `terminal` 打开它。
- `open_project` 把 root 同步给终端面板。







## `lithe-desktop` 公开 API

只负责启动：`gpui_kit::application()` → `gpui_kit::init(cx)` → `install_fonts` → `install_theme` → `open_window` → `cx.new(Workbench::new)`。窗口默认 1280×800，最小 980×640。

## 编码约定

- Rust 标识符用英文，注释用中文解释不明显的约束。
- 禁止在视图调用点写十六进制颜色；只用 `LitheTokens` 或主题 token。
- 重复元素用业务 ID 生成 `ElementId`，不用下标。
- 不用 `unwrap()` 处理用户输入或 I/O；错误转换成可见状态。
- 字符串先用 `lithe_ui::i18n::tr("...")`，不直接散落字面量。
- 每个 crate 只写自己的目录；不要改 `gpui/Cargo.toml` 或其他 crate。
- 不新增依赖；如果确实需要，停下来在报告里说明。
- 不运行编译、构建、测试或格式化命令。

## GPUI 运行时约束

- **不要在构造期发起异步任务。** `cx.new(|cx| View::new(...))` 发生在
  `App::run` 的可变借用内，此时 `cx.spawn` / `background_spawn` 再借 App 会
  触发 `RefCell already borrowed` panic。需要首帧加载时，在 `Render` 里用
  `cx.defer_in(window, ...)` 把任务排到当前借用释放之后。`ProjectTree` 的
  根目录加载就是按这个方式实现的。
- **`h_flex()` 默认 `items_center`。** 需要子项在交叉轴拉伸到整高时，
  显式加 `.items_stretch()`；否则分栏、侧栏会按内容高度垂直居中。
- 原生 WebView 在 `new` 中只创建一次；只在打开/清空文件时调用
  `load_url`，不要在 `render` 里导航。

## 本轮文件归属

| crate | 负责人 | 允许写 |
| --- | --- | --- |
| `lithe-ui` | Agent A | `gpui/lithe-ui/src/**` |
| `lithe-core-client` | Agent B | `gpui/lithe-core-client/src/**` |
| `lithe-platform` | Agent C | `gpui/lithe-platform/src/**` |
| `lithe-workbench` | Agent D | `gpui/lithe-workbench/src/**` |
| `lithe-features` | Agent E | `gpui/lithe-features/src/**` |
| `lithe-desktop` | Agent F | `gpui/lithe-desktop/src/**` |

每个 crate 的 `src/lib.rs` 必须导出上述公开 API。
