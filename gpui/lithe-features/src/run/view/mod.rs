//! Run 工具窗：运行配置、会话控制和控制台。
//!
//! 视图只持有 UI 状态与进程树句柄；Core 调用、文件写入和子进程读取都在
//! `config` / `session` 模块里完成后回到视图线程。Run 按钮、Stop 和重跑都
//! 走同一条 `start_configuration` / `stop_configuration` 链路。

mod actions;
mod console;
mod details;
mod list;
mod render;
mod state;
mod toolbar;

use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gpui_kit::component::menu::PopupMenu;
use gpui_kit::component::resizable::ResizableState;
use gpui_kit::{App, Entity, EventEmitter, FocusHandle, SharedString, Subscription, Window};
use lithe_core_client::CoreClient;

use crate::console::{ConsoleHost, ConsoleScroll};

use self::state::SessionState;
// 把 run 的兄弟模块绑定到本模块，供子模块以 super:: 路径解析。
use super::config;
use super::java_decision::{self, JavaLaunchDecision};
use super::model::{
    self, RunConfiguration, RunDiagnostic, RunScope,
};
use super::session;

use crate::language::{JavaLanguageServiceModel, JavaLaunchTarget};

/// Run 面板状态变化。工作台用它刷新顶栏 Run/Stop 和配置名。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunPanelEvent {
    /// 会话或选中配置变化，工作台重新读取顶栏状态。
    StateChanged,
    /// 标题栏的隐藏按钮请求收起底部 dock；由工作台改写布局并持久化。
    HideRequested,
}

impl EventEmitter<RunPanelEvent> for RunPanel {}

impl ConsoleHost for RunPanel {
    fn console(&mut self) -> &mut ConsoleScroll {
        &mut self.console
    }
}

/// 启动前保存回调：工作台用它把脏缓冲写盘，面板不直接持有编辑器实体。
///
/// 与 `GitPanel::on_open_file` 等回调同形，避免 `lithe-features` 反向依赖
/// `lithe-workbench`。对齐 Tauri `run.store.ts` 在启动前强制
/// `saveWorkspaceBeforeLaunch` 的语义。
type BeforeLaunchHandler = Rc<dyn Fn(&mut App) + 'static>;

/// 打开设置页编辑指定配置；工作台注入，面板不直接依赖设置视图。
type OpenSettingsHandler = Rc<dyn Fn(&str, &mut Window, &mut App) + 'static>;

gpui_kit::actions!(
    lithe_run_console,
    [
        // 复制运行控制台当前选中的文本；没有选中时复制全部输出。
        CopySelection
    ]
);

/// 控制台自己的键上下文。只有控制台获得焦点时才绑定 ⌘C / Ctrl+C，避免抢走
/// 编辑器、终端 WebView 和设置页输入框原本的复制键。
const CONSOLE_CONTEXT: &str = "LitheRunConsole";

/// 标题栏高度。对齐 macOS `LitheToolWindowHeader` 的 41pt。
#[allow(dead_code)]
const HEADER_HEIGHT: f32 = 41.0;
#[allow(dead_code)]
const TOOLBAR_HEIGHT: f32 = 36.0;
#[allow(dead_code)]
const SCOPE_RAIL_WIDTH: f32 = 36.0;
/// 配置列表默认宽度。对齐 macOS `lithe.run.configurationListWidth` 的 280。
const CONFIGURATION_LIST_DEFAULT_WIDTH: f32 = 280.0;
/// 配置列表最小宽度。对齐 macOS `RunServicesLayout.configurationMinimum`。
const CONFIGURATION_LIST_MIN_WIDTH: f32 = 240.0;
/// 配置列表最大宽度。对齐 macOS `configurationMaximum` 的 480 上限。
const CONFIGURATION_LIST_MAX_WIDTH: f32 = 480.0;
/// 输出区最小宽度。对齐 macOS `RunServicesLayout.outputMinimum`；低于它时
/// 整个分栏退化成横向滚动，而不是把两栏压到互相压字。
const OUTPUT_MIN_WIDTH: f32 = 320.0;
/// 控制台左侧动作条宽度。对齐 macOS `LitheTheme.ActionStripe.width` 的图标按钮列。
#[allow(dead_code)]
const CONSOLE_ACTION_STRIPE_WIDTH: f32 = 28.0;
/// 控制台单行高度估算。macOS 用 TextKit 量出真实行框；GPUI 的纯文本视图没有
/// 逐行句柄，堆栈跳转按“行号 × 行高”换算滚动偏移，关闭软换行时与真实位置一致。
#[allow(dead_code)]
const CONSOLE_LINE_HEIGHT: f32 = 18.0;
const GROUP_HEADER_HEIGHT: f32 = 26.0;
const CONFIGURATION_ROW_HEIGHT: f32 = 30.0;
const PANEL_PADDING: f32 = 12.0;
const STATUS_LINE_HEIGHT: f32 = 24.0;
/// 虚拟化列表的可视区外预排版高度。滚轮快速拖动时避免露出一片空白。
const CONSOLE_LIST_OVERDRAW: f32 = 400.0;
/// 保留的输出行数上限。
///
/// 旧实现保留 20 万字符并整段 `drain(..)` 裁剪：那是 O(n) 的整段搬移，而且
/// 每次都让 `SelectableText` 对全文重新排版，输出越快越卡。现在按行存储、
/// 按行淘汰，裁剪只丢头部行，配合虚拟化列表只排版可视行。
const MAX_OUTPUT_LINES: usize = 5_000;
/// 输出合批窗口。Maven 这类工具每秒可能打印上百行；窗口内先攒着，
/// 到期一次性并入行缓冲，避免每个数据块都触发一次重排。
const OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(33);

/// 运行工具窗。
pub struct RunPanel {
    client: CoreClient,
    root: Option<PathBuf>,
    configurations: Vec<RunConfiguration>,
    default_id: Option<String>,
    selected_id: Option<String>,
    #[allow(dead_code)]
    scope: RunScope,
    pinned: HashSet<String>,
    sessions: BTreeMap<String, SessionState>,
    diagnostics: Vec<RunDiagnostic>,
    loading: bool,
    error: Option<SharedString>,
    generation: u64,
    pending_initial_load: bool,
    /// 顶栏 Run 在没有配置时先打开面板；配置加载完成后自动启动一次。
    pending_run: bool,
    /// 用户点击重新运行时等待当前进程退出后再启动。
    restart_pending: Option<String>,
    wrap_output: bool,
    show_details: bool,
    /// 配置列表与输出之间的分栏状态；切项目时重置，让默认宽度重新生效。
    split_state: Entity<ResizableState>,
    /// 配置列表当前宽度。拖拽结束回写，作为下一次重置的初始尺寸。
    configuration_width: f32,
    /// 批量选择模式：勾选多个配置后用工具条统一 Run / Stop。
    batch_selection: bool,
    /// 批量选择模式下被勾选的配置 id。
    checked: HashSet<String>,
    /// 折叠的分组名称（对齐 Tauri 的折叠状态）。
    collapsed_groups: HashSet<String>,
    /// 标题栏 more 菜单实体；打开期间持有，关闭时释放。
    /// 工具条「…」弹出菜单与其触发位置；渲染期用 `anchored` 挂到前景层。
    more_menu: Option<(Entity<PopupMenu>, gpui_kit::Point<gpui_kit::Pixels>)>,
    _more_menu_subscription: Option<Subscription>,
    /// 当前浏览的语言分类（Java / Go / Python 等），对齐 Tauri `RunConfigurationBrowser`。
    selected_language: Option<String>,
    /// 控制台的虚拟化列表、平滑滚动与插入符状态。
    console: ConsoleScroll,
    /// 是否跟随最新输出；跳转堆栈帧后暂停，「回到最新」恢复。
    console_follow_tail: bool,
    /// 控制台焦点：只有它获得焦点时才响应复制快捷键。
    console_focus: FocusHandle,
    /// 尚未合并进会话状态的输出。按配置 id 累积，由定时器统一刷新。
    pending_output: BTreeMap<String, String>,
    /// 是否已经有一个刷新任务在等待；避免每个输出块都排一个定时器。
    output_flush_scheduled: bool,
    /// 启动前保存回调查调；由工作台注入，见 [`BeforeLaunchHandler`]。
    on_before_launch: Option<BeforeLaunchHandler>,
    /// 打开 Run 配置设置页回调；由工作台注入。
    on_open_settings: Option<OpenSettingsHandler>,
    /// 顶部项目准备状态是否展开（Run 面板自己的详情状态）。
    preparation_expanded: bool,
    /// 应用级 Java 语言服务模型；准备状态的唯一来源。
    java_language: Entity<JavaLanguageServiceModel>,
    /// 等待 Java 项目准备完成后要启动的配置 id。
    pending_java_launch: Option<String>,
    /// Java/Spring Boot 启动前的构建检查结果；有待决项时暂停启动。
    launch_decision: Option<JavaLaunchDecision>,
    /// 构建失败但 classpath 已解析的启动目标；用户选择“仍然运行”时使用。
    launch_decision_target: Option<JavaLaunchTarget>,
    /// 用户选择「对此工作区始终继续」后跳过后续构建检查。
    skip_build_check: bool,
}
