//! 工作台的尺寸刻度。
//!
//! 数值来自 `gpui/ARCHITECTURE.md`、macOS `LitheTheme.Metrics`，以及外壳组件
//! 自己的原型实现（`WorkbenchView.swift` 的 `ActivityBarMetrics` /
//! `WorkbenchTopBarMetrics`、`EditorAreaView.swift` 的标签条、
//! `LitheToolWindowHeader.swift`）。组件里不要再写裸数字，统一通过
//! `LitheMetrics` 引用。

pub struct LitheMetrics;

impl LitheMetrics {
    pub const TOP_BAR_HEIGHT: f32 = 40.0;
    /// 顶栏左侧内边距。Tauri 的 Windows 标题栏用 `pl-0`：应用图标列与下方
    /// 活动栏同宽对齐；右侧仍保留 8pt。见
    /// `windows/tauri/src/features/window/components/title-bar/title-bar.tsx`。
    pub const TOP_BAR_PADDING_LEFT: f32 = 0.0;
    pub const TOP_BAR_PADDING_RIGHT: f32 = 8.0;
    /// 顶栏一级分组之间的间距。Tauri `--lithe-chrome-gap`（默认密度 4px）。
    pub const TOP_BAR_ITEM_GAP: f32 = 4.0;
    /// 同一分组内（项目 / 分支）的间距。Tauri `--lithe-chrome-gap-tight`。
    pub const TOP_BAR_GROUP_GAP: f32 = 2.0;
    /// 应用图标列宽，对齐 Tauri `COLLAPSED_ACTIVITY_RAIL_WIDTH`。
    pub const TOP_BAR_BRAND_WIDTH: f32 = 38.0;
    /// 应用图标绘制边长：Tauri 的 `size-5`（20px）放大 1.19 倍。
    pub const TOP_BAR_BRAND_LOGO_SIZE: f32 = 24.0;
    /// 工具条触发器（汉堡 / 项目 / 分支）高度。Tauri `ToolbarComboButton` 30px。
    pub const TOP_BAR_TRIGGER_HEIGHT: f32 = 30.0;
    /// 工具条触发器圆角。Tauri 12px arc，即 6px radius。
    pub const TOP_BAR_TRIGGER_RADIUS: f32 = 6.0;
    /// 项目 / 分支触发器左右内边距。Tauri `pl-2.5` / `pr-1.5`。
    pub const TOP_BAR_TRIGGER_PADDING_LEFT: f32 = 10.0;
    pub const TOP_BAR_TRIGGER_PADDING_RIGHT: f32 = 6.0;
    /// 触发器内图标 / 文字间距。Tauri `gap-1.5` = 6px。
    pub const TOP_BAR_TRIGGER_GAP: f32 = 6.0;
    /// 触发器图标尺寸。Tauri 工具栏用 20px（ActivityBarMetrics.iconSize）。
    pub const TOP_BAR_ICON_SIZE: f32 = 20.0;
    /// 触发器文字字号。Tauri `ui-text-chrome` = 13px。
    pub const TOP_BAR_LABEL_FONT_SIZE: f32 = 13.0;
    /// 下拉箭头尺寸。Tauri `General.ChevronDown` 原生 16px。
    pub const TOP_BAR_CHEVRON_SIZE: f32 = 16.0;
    /// 箭头与文字的净间距。Tauri 用 `-ml-1` 把 6px 的 item gap 压到 2px。
    pub const TOP_BAR_CHEVRON_GAP: f32 = 2.0;
    /// 项目入口最大宽度。Tauri `max-w-56` = 224px。
    pub const TOP_BAR_PROJECT_MAX_WIDTH: f32 = 224.0;
    /// 分支入口最大宽度，避免长分支名挤掉右侧动作。
    pub const TOP_BAR_BRANCH_MAX_WIDTH: f32 = 240.0;
    /// 窗口控制按钮宽度。对齐 Tauri `window-controls.tsx` 在 Windows 的
    /// `w-14 min-w-14`（56px）。
    pub const WINDOW_CONTROL_WIDTH: f32 = 56.0;
    /// 窗口控制图标尺寸，对齐 Tauri 的 16px 字形。
    pub const WINDOW_CONTROL_ICON_SIZE: f32 = 16.0;
    /// 顶部菜单栏高度。macOS 原型把菜单交给系统菜单栏，GPUI 在 Windows /
    /// Linux 把它画成窗口内独立一行，取 VS Code/IntelliJ 常用的 30pt。
    pub const MENU_BAR_HEIGHT: f32 = 30.0;
    /// 菜单栏单个顶级触发器的可视高度（30pt 行内上下各留 4pt）。
    pub const MENU_BAR_ITEM_HEIGHT: f32 = 22.0;
    /// 顶级触发器左右内边距。
    pub const MENU_BAR_ITEM_PADDING_X: f32 = 8.0;
    /// 顶级触发器之间的间距。
    pub const MENU_BAR_ITEM_GAP: f32 = 1.0;
    /// 顶级菜单标签字号，对齐 macOS 菜单栏的 13pt。
    pub const MENU_BAR_FONT_SIZE: f32 = 13.0;
    /// 下拉菜单最小宽度，避免短菜单过窄。
    pub const MENU_POPUP_MIN_WIDTH: f32 = 200.0;
    /// 下拉菜单最大高度，超出后内部滚动。
    pub const MENU_POPUP_MAX_HEIGHT: f32 = 520.0;
    /// 菜单项右侧快捷键文案字号，对齐 Tauri `ui-text-sm`（13pt）。
    pub const MENU_SHORTCUT_FONT_SIZE: f32 = 12.0;
    pub const ACTIVITY_RAIL_WIDTH: f32 = 40.0;
    /// 活动栏每组入口的最大可视高度。依据 macOS `ActivityBarMetrics`
    /// 的 `toolViewportHeight = 280`（WorkbenchView.swift:30）：条目超过
    /// 7 个时这一组在栏内独立滚动，不把另一组挤出窗口。
    pub const ACTIVITY_RAIL_VIEWPORT_HEIGHT: f32 = 280.0;
    pub const ACTIVITY_BUTTON_SIZE: f32 = 30.0;
    pub const ACTIVITY_ICON_SIZE: f32 = 20.0;
    pub const ACTIVITY_SLOT_WIDTH: f32 = 37.0;
    pub const ACTIVITY_SLOT_HEIGHT: f32 = 40.0;
    pub const TOOL_WINDOW_HEADER_HEIGHT: f32 = 41.0;
    pub const EDITOR_TAB_HEIGHT: f32 = 34.0;
    pub const STATUS_BAR_HEIGHT: f32 = 24.0;
    pub const TREE_ROW_HEIGHT: f32 = 24.0;
    pub const PROJECT_TREE_ROW_HEIGHT: f32 = 27.0;
    pub const TREE_ICON_SIZE: f32 = 16.0;
    pub const TREE_INDENT: f32 = 19.0;
    pub const PANE_RADIUS: f32 = 10.0;
    pub const CONTROL_RADIUS: f32 = 6.0;
    pub const MENU_RADIUS: f32 = 8.0;
    pub const TAB_UNDERLINE_HEIGHT: f32 = 3.0;
    pub const UI_FONT_SIZE: f32 = 14.0;
    pub const SETTINGS_FONT_SIZE: f32 = 13.0;
    pub const SMALL_FONT_SIZE: f32 = 12.0;
    pub const CODE_FONT_SIZE: f32 = 13.0;
    pub const MIN_PANE_SIZE: f32 = 30.0;

    // --- 派生刻度：不新增契约常量，只把组件内重复出现的尺寸收敛到这里。---
    /// 工具窗标题字号（13pt Bold）。依据 `LitheToolWindowHeader.swift:30`。
    pub const TOOL_WINDOW_TITLE_FONT_SIZE: f32 = 13.0;
    /// 工具窗标题栏内元素间距。依据 `LitheToolWindowHeader.swift:28` 的
    /// `HStack(spacing: 8)`。
    pub const TOOL_WINDOW_HEADER_GAP: f32 = 8.0;
    /// 工具窗标题栏左内边距。依据 `LitheToolWindowHeader.swift:47`。
    pub const TOOL_WINDOW_HEADER_LEADING: f32 = 12.0;
    /// 工具窗标题栏右内边距。依据 `LitheToolWindowHeader.swift:48`。
    pub const TOOL_WINDOW_HEADER_TRAILING: f32 = 8.0;
    /// 工具窗动作区按钮间距。依据 `LitheTheme.swift:520` 的
    /// `ActionToolbar.actionSpacing = 4`。
    pub const TOOL_WINDOW_ACTION_GAP: f32 = 4.0;
    /// 工具窗动作按钮边长，对齐 IDEA ActionToolbar 的 22pt
    /// （`LitheTheme.swift:971` 的 `toolbarIconButtonSize`）。
    pub const TOOLBAR_ICON_BUTTON_SIZE: f32 = 22.0;
    /// 工具栏图标尺寸。依据 `LitheTheme.swift:970` 的 `toolbarIconSize = 16`。
    pub(crate) const TOOLBAR_ICON_SIZE: f32 = 16.0;
    /// 工具栏图标按钮圆角。依据 `LitheIconButtonStyle` 默认
    /// `cornerRadius = LitheTheme.Metrics.cornerRadius`（5pt，`LitheTheme.swift:985`）。
    pub(crate) const TOOLBAR_ICON_BUTTON_RADIUS: f32 = 5.0;
    /// 活动栏选中态的圆角。依据 `WorkbenchView.swift:42` 的 `cornerRadius: 6`。
    /// 活动栏在 `lithe-workbench` 里也参与绘制，因此保持 `pub`。
    pub const ACTIVITY_BUTTON_RADIUS: f32 = 6.0;
    /// 活动栏未读红点直径。依据 `WorkbenchView.swift:1303` 的 7pt。
    pub const ACTIVITY_BADGE_SIZE: f32 = 7.0;
    /// 未读红点距槽位右边缘的距离。依据 `WorkbenchView.swift:1305` 的
    /// `.offset(x: -2, y: 3)`（槽位按 trailing 对齐）。
    pub const ACTIVITY_BADGE_TRAILING_OFFSET: f32 = 2.0;
    /// 未读红点距槽位上边缘的距离，同上 `.offset(y: 3)`。
    pub const ACTIVITY_BADGE_TOP_OFFSET: f32 = 3.0;

    /// 编辑器标签条四周内边距。依据 `EditorAreaView.swift:347-348` 的
    /// `padding(.horizontal, 2)` / `padding(.vertical, 2)`。
    pub(crate) const EDITOR_TAB_STRIP_PADDING: f32 = 2.0;
    /// 编辑器标签之间的间距。依据 `EditorAreaView.swift:344` 的
    /// `EditorTabFlowLayout(horizontalSpacing: 4, verticalSpacing: 2)`；
    /// GPUI 的 `gap` 不能分轴设置，取水平间距。
    pub(crate) const EDITOR_TAB_ITEM_SPACING: f32 = 4.0;
    /// 编辑器标签文字左内边距。依据 `EditorAreaView.swift:743` 的
    /// `padding(.leading, 8)`。
    pub(crate) const EDITOR_TAB_LEADING_PADDING: f32 = 8.0;
    /// 编辑器标签内元素间距。依据 `EditorAreaView.swift:737` 的
    /// `HStack(spacing: 7)`（图标 / 标题 / 修改点）。
    pub(crate) const EDITOR_TAB_GAP: f32 = 7.0;
    /// 编辑器标签文字字号。依据 `EditorAreaView.swift:765` 的 `uiFont(size: 13)`。
    pub(crate) const EDITOR_TAB_FONT_SIZE: f32 = 13.0;
    /// 编辑器标签关闭按钮的点击区。依据
    /// `LitheToolWindowTabStyle.swift:231` 的 `.frame(width: 22, height: 22)`。
    pub(crate) const EDITOR_TAB_CLOSE_SIZE: f32 = 22.0;
    /// 编辑器标签关闭按钮图标。依据 `LitheToolWindowTabStyle.swift:227`
    /// 的 `size: 16`。
    pub(crate) const EDITOR_TAB_CLOSE_ICON_SIZE: f32 = 16.0;
    /// 关闭按钮到标签右边缘的距离。依据 `EditorAreaView.swift:724` 的
    /// `padding(.trailing, 4)`。
    pub(crate) const EDITOR_TAB_CLOSE_TRAILING: f32 = 4.0;
    /// 修改点的直径。依据 `EditorAreaView.swift:1686` 的 6pt。
    pub(crate) const MODIFIED_DOT_SIZE: f32 = 6.0;

    /// 状态栏字号。依据 `WorkbenchView.swift:1693` 的 `LitheTheme.smallFont`
    ///（12pt，`LitheTheme.swift:826`）。
    pub(crate) const STATUS_BAR_FONT_SIZE: f32 = 12.0;
    /// 状态栏条目图标尺寸。依据 `WorkbenchView.swift:1762` 的面包屑图标 12pt。
    pub(crate) const STATUS_BAR_ICON_SIZE: f32 = 12.0;
    /// 状态栏左右内边距。依据 `WorkbenchView.swift:1695` 的
    /// `padding(.horizontal, 9)`。
    pub(crate) const STATUS_BAR_HORIZONTAL_PADDING: f32 = 9.0;
    /// 状态栏条目间距。依据 `WorkbenchView.swift:1837` 的
    /// `compactStatusItems` 的 `HStack(spacing: 10)`。
    pub(crate) const STATUS_BAR_ITEM_GAP: f32 = 10.0;
    /// 状态栏条目内图标与文字间距。依据 `WorkbenchView.swift:1760` 的
    /// `HStack(spacing: 4)`。
    pub(crate) const STATUS_BAR_ICON_GAP: f32 = 4.0;
}

