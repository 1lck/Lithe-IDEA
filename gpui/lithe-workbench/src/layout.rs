//! 工作台壳的布局刻度。
//!
//! 用 `h_resizable` 表达顶部一行（左工具窗 / 编辑区 / 右工具窗）；底部 dock
//! 与顶部行之间是一条独立的拖动间隙，尺寸集中在这里，业务视图不感知锚点结构。
//! 工作台持有一个 `ResizableState`，在切换工作区或隐藏侧边 dock 时清空，
//! 让持久化宽度重新作为初始尺寸生效。

use gpui_kit::{Pixels, px};

/// 顶部一行（左工具窗 / 编辑区 / 右工具窗）的分栏组 id。
///
/// 组 id 参与 GPUI 的 keyed state；工作台同时把分栏状态实体保存在
/// `Workbench` 里（`with_state`），这样切换项目时可以显式清空状态，让新
/// 工作区持久化的宽度重新作为初始尺寸生效。
pub(crate) const HORIZONTAL_GROUP_ID: &str = "lithe-dock-horizontal";

/// 底部工具窗与顶部一行之间的拖动间隙。
///
/// 对齐 Windows/Tauri 的 `--lithe-bottom-pane-gap`（6px）：这 6px 既是视觉
/// 间隙，也是唯一的拖动命中范围。`gpui-base` 分栏组自带的命中带是 9px 且
/// 跨过分栏边界，无法满足这个对齐要求，所以底部 dock 不用 `v_resizable`。
pub(crate) const BOTTOM_PANE_GAP: Pixels = px(6.);

/// 左侧工具窗默认宽度，对齐 macOS 原型的默认侧栏。
pub(crate) const LEFT_PANEL_INITIAL_WIDTH: Pixels = px(300.);

/// 左侧工具窗最小宽度；再窄就放不下树行图标与缩进。
pub(crate) const LEFT_PANEL_MIN_WIDTH: Pixels = px(180.);

/// 左侧工具窗最大宽度，避免把编辑区挤到无法阅读。
pub(crate) const LEFT_PANEL_MAX_WIDTH: Pixels = px(520.);

/// 右侧工具窗默认宽度（Database / Services / Extensions / Maven）。
pub(crate) const RIGHT_PANEL_INITIAL_WIDTH: Pixels = px(320.);

/// 右侧活动栏宽度：对齐 Tauri `PluginActivityRail` 的 `w-9.5` 与
/// `COLLAPSED_ACTIVITY_RAIL_WIDTH`（38px）。
pub(crate) const RIGHT_ACTIVITY_RAIL_WIDTH: Pixels = px(38.);

/// 右侧活动栏按钮间距：对齐 Tauri 的 `gap-2.5`（10px）。
pub(crate) const RIGHT_ACTIVITY_RAIL_GAP: Pixels = px(10.);

/// 右侧活动栏顶部内边距：对齐 Tauri 的 `pt-1`（4px）。
pub(crate) const RIGHT_ACTIVITY_RAIL_PADDING_TOP: Pixels = px(4.);

/// 右侧工具窗最小宽度。
pub(crate) const RIGHT_PANEL_MIN_WIDTH: Pixels = px(200.);

/// 右侧工具窗最大宽度。
pub(crate) const RIGHT_PANEL_MAX_WIDTH: Pixels = px(600.);

/// 编辑区的最小宽度。窗口本身的最小尺寸由 `lithe-desktop` 保证。
pub(crate) const EDITOR_MIN_WIDTH: Pixels = px(320.);

/// 编辑区的最大宽度。`h_resizable` 要求区间有上界；这个值只是防呆，
/// 实际窗口不会达到。
pub(crate) const EDITOR_MAX_WIDTH: Pixels = px(4096.);

/// 底部 dock 初始高度，对齐契约的 260pt。
pub(crate) const BOTTOM_PANEL_INITIAL_HEIGHT: Pixels = px(260.);

/// 底部 dock 最小高度：再窄就放不下工具窗标题和一行结果。
pub(crate) const BOTTOM_PANEL_MIN_HEIGHT: Pixels = px(120.);

/// 底部 dock 最大高度，避免把主编辑区挤到无法阅读。
pub(crate) const BOTTOM_PANEL_MAX_HEIGHT: Pixels = px(500.);

/// 命令面板宽度。比设置面板窄，保持“快速跳转”的轻量感。
pub(crate) const COMMAND_PALETTE_WIDTH: Pixels = px(560.);

/// 命令面板距窗口顶部的距离：靠近顶栏但给顶栏留出呼吸空间。
pub(crate) const COMMAND_PALETTE_TOP: Pixels = px(96.);

/// 命令面板列表的最大高度；条目更多时列表内部滚动。
pub(crate) const COMMAND_PALETTE_MAX_HEIGHT: Pixels = px(320.);

/// 未保存标签关闭确认面板的尺寸。固定 420×180，居中绘制在主窗口内。
pub(crate) const CONFIRM_CLOSE_PANEL_WIDTH: Pixels = px(420.);
pub(crate) const CONFIRM_CLOSE_PANEL_HEIGHT: Pixels = px(180.);

/// Markdown 预览工具条高度（标签条下方的一条轻量工具条）。
///
/// 只在活动文件是 `.md` / `.markdown` 时渲染；工具条本身不承担保存，预览
/// 展示的始终是磁盘内容。
pub(crate) const MARKDOWN_TOOLBAR_HEIGHT: Pixels = px(28.);

// --- 顶栏下拉菜单 ---------------------------------------------------------
// 项目切换器和分支切换器共用同一套位置与宽度：紧贴 40pt 顶栏下方，左对齐
// 12pt，宽 320pt。菜单在窗口根节点上绝对定位，不参与主区分栏。

/// 顶栏菜单宽度。
pub(crate) const TOP_MENU_WIDTH: Pixels = px(320.);

/// 顶栏菜单距窗口左边缘的距离。
///
/// 第一版先对齐项目入口的左边缘：应用图标列 38 + 组间距 4 + 汉堡 30 +
/// 组间距 4 = 76。项目和分支菜单共用同一位置；后续改成按触发器锚定后，
/// 这个常量会删除。
pub(crate) const TOP_MENU_LEFT: Pixels = px(76.);

/// 顶栏菜单与顶栏之间的间隙。与 `LitheMetrics::TOP_BAR_HEIGHT`（f32）相加
/// 后再转成 `Pixels`，因此这里保持 f32 而不是 `Pixels`。
pub(crate) const TOP_MENU_TOP_GAP: f32 = 4.0;

/// 菜单列表的最大高度；超出后列表内部滚动，菜单本身不撑出窗口。
pub(crate) const TOP_MENU_LIST_MAX_HEIGHT: Pixels = px(380.);

/// 项目切换菜单最多展示的最近项目数量。
pub(crate) const TOP_MENU_MAX_RECENT_PROJECTS: usize = 10;
