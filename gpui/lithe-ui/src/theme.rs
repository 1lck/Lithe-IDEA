//! 把 Lithe token 安装成 gpui-kit 的全局主题。
//!
//! gpui-kit 的 `Theme` 同时保存两份颜色（`colors` 的纯色与 `tokens` 的可渲染
//! 背景），并且 Base 层还有一份投影。这里统一走 `Theme::update`，由它负责
//! 同步这些副本并刷新窗口；不要直接改 `Theme::global_mut`。

use gpui_kit::component::{Theme, ThemeColor, ThemeMode};
use gpui_kit::{App, Global, px, white};

use crate::fonts::{MONO_FONT_FAMILY, UI_FONT_FAMILY};
use crate::{LitheMetrics, LitheThemeKind, LitheTokens};

/// 记住当前安装的主题族与明暗，`toggle_dark` / `current_tokens` 需要它。
#[derive(Clone, Copy, Debug)]
struct LitheThemeState {
    kind: LitheThemeKind,
    dark: bool,
    tokens: LitheTokens,
}

impl Global for LitheThemeState {}

/// 安装主题。
///
/// 必须在 `gpui_kit::init(cx)` 之后调用：`Theme::change` 依赖 component 层
/// 已经注册的 `ThemeRegistry`。
pub fn install_theme(cx: &mut App, kind: LitheThemeKind, dark: bool) {
    let tokens = LitheTokens::for_theme(kind, dark);

    // 先切换模式：`Theme::update` 里改 `mode` 会用该模式注册的主题覆盖颜色，
    // 所以颜色必须放在第二次 update 里写。
    Theme::change(
        if dark {
            ThemeMode::Dark
        } else {
            ThemeMode::Light
        },
        None,
        cx,
    );

    Theme::update(cx, |theme| {
        theme.colors = theme_color(&tokens);
        theme.font_family = UI_FONT_FAMILY.into();
        theme.mono_font_family = MONO_FONT_FAMILY.into();
        theme.font_size = px(LitheMetrics::UI_FONT_SIZE);
        theme.mono_font_size = px(LitheMetrics::CODE_FONT_SIZE);
        theme.radius = px(LitheMetrics::CONTROL_RADIUS);
        theme.radius_lg = px(LitheMetrics::PANE_RADIUS);
    });

    cx.set_global(LitheThemeState { kind, dark, tokens });
}

pub fn toggle_dark(cx: &mut App) {
    let (kind, dark) = cx
        .try_global::<LitheThemeState>()
        .map(|state| (state.kind, state.dark))
        // 还没安装过主题时按 Lithe 深色处理，反转后进入浅色。
        .unwrap_or((LitheThemeKind::Lithe, true));
    install_theme(cx, kind, !dark);
}

pub fn current_tokens(cx: &App) -> LitheTokens {
    cx.try_global::<LitheThemeState>()
        .map(|state| state.tokens)
        .unwrap_or_else(|| LitheTokens::for_theme(LitheThemeKind::Lithe, true))
}

/// Lithe token 到 gpui-kit `ThemeColor` 的语义映射。
fn theme_color(tokens: &LitheTokens) -> ThemeColor {
    let mut colors = ThemeColor::default();

    // 基础画布与文本。
    colors.background = tokens.editor;
    colors.foreground = tokens.primary_text;
    colors.border = tokens.divider;
    colors.input = tokens.panel_border;
    colors.ring = tokens.selection;
    colors.caret = tokens.primary_text;

    // `accent` 在 gpui-kit 里是 MenuItem/ListItem 的悬停底色。
    colors.accent = tokens.subtle_selection;
    colors.accent_foreground = tokens.primary_text;
    colors.accordion = tokens.raised;

    // 主操作：Lithe 的 selection/accent 是蓝底白字。
    let on_selection = white();
    colors.primary = tokens.selection;
    colors.primary_hover = tokens.selection;
    colors.primary_active = tokens.selection;
    colors.primary_foreground = on_selection;

    colors.secondary = tokens.raised;
    colors.secondary_hover = tokens.hover;
    colors.secondary_active = tokens.pressed;
    colors.secondary_foreground = tokens.primary_text;

    colors.muted = tokens.subtle_selection;
    colors.muted_foreground = tokens.secondary_text;

    colors.danger = tokens.error;
    colors.danger_hover = tokens.error;
    colors.danger_active = tokens.error;
    colors.danger_foreground = on_selection;

    colors.success = tokens.success;
    colors.success_hover = tokens.success;
    colors.success_active = tokens.success;
    colors.success_foreground = on_selection;

    colors.warning = tokens.warning;
    colors.warning_hover = tokens.warning;
    colors.warning_active = tokens.warning;
    colors.warning_foreground = tokens.primary_text;

    colors.info = tokens.link;
    colors.info_hover = tokens.link;
    colors.info_active = tokens.link;
    colors.info_foreground = on_selection;

    // 列表 / 侧栏。
    colors.list = tokens.sidebar;
    colors.list_hover = tokens.hover;
    colors.list_active = tokens.selection;
    colors.list_active_border = tokens.selection;
    colors.list_even = tokens.sidebar;
    colors.list_head = tokens.tool_header;

    colors.sidebar = tokens.sidebar;
    colors.sidebar_foreground = tokens.primary_text;
    colors.sidebar_accent = tokens.subtle_selection;
    colors.sidebar_accent_foreground = tokens.primary_text;
    colors.sidebar_border = tokens.divider;
    colors.sidebar_primary = tokens.selection;
    colors.sidebar_primary_foreground = on_selection;

    // 浮层。
    colors.popover = tokens.raised;
    colors.popover_foreground = tokens.primary_text;
    colors.overlay = tokens.window.alpha(0.60);
    colors.window_border = tokens.panel_border;

    // 顶栏 / 状态栏。
    colors.title_bar = tokens.titlebar;
    colors.title_bar_border = tokens.divider;
    colors.status_bar = tokens.titlebar;
    colors.status_bar_border = tokens.divider;

    // 标签页。
    colors.tab = tokens.editor;
    colors.tab_active = tokens.editor;
    colors.tab_active_foreground = tokens.primary_text;
    colors.tab_foreground = tokens.secondary_text;
    colors.tab_bar = tokens.tool_header;
    colors.tab_bar_segmented = tokens.raised;

    // 表格。
    colors.table = tokens.editor;
    colors.table_active = tokens.selection;
    colors.table_active_border = tokens.selection;
    colors.table_even = tokens.editor;
    colors.table_head = tokens.tool_header;
    colors.table_head_foreground = tokens.secondary_text;
    colors.table_foot = tokens.tool_header;
    colors.table_foot_foreground = tokens.secondary_text;
    colors.table_hover = tokens.hover;
    colors.table_row_border = tokens.divider;

    // 按钮。
    colors.button = tokens.raised;
    colors.button_hover = tokens.hover;
    colors.button_active = tokens.pressed;
    colors.button_foreground = tokens.primary_text;
    colors.button_primary = tokens.selection;
    colors.button_primary_hover = tokens.selection;
    colors.button_primary_active = tokens.selection;
    colors.button_primary_foreground = on_selection;
    colors.button_secondary = tokens.raised;
    colors.button_secondary_hover = tokens.hover;
    colors.button_secondary_active = tokens.pressed;
    colors.button_secondary_foreground = tokens.primary_text;
    colors.button_danger = tokens.error;
    colors.button_danger_hover = tokens.error;
    colors.button_danger_active = tokens.error;
    colors.button_danger_foreground = on_selection;
    colors.button_success = tokens.success;
    colors.button_success_hover = tokens.success;
    colors.button_success_active = tokens.success;
    colors.button_success_foreground = on_selection;
    colors.button_warning = tokens.warning;
    colors.button_warning_hover = tokens.warning;
    colors.button_warning_active = tokens.warning;
    colors.button_warning_foreground = tokens.primary_text;
    colors.button_info = tokens.link;
    colors.button_info_hover = tokens.link;
    colors.button_info_active = tokens.link;
    colors.button_info_foreground = on_selection;

    // 表单 / 容器。
    colors.group_box = tokens.raised;
    colors.group_box_foreground = tokens.primary_text;
    colors.description_list_label = tokens.raised;
    colors.description_list_label_foreground = tokens.primary_text;
    colors.drag_border = tokens.selection;
    colors.drop_target = tokens.subtle_selection;

    // 语义色。
    // gpui-kit 的 `selection` 是文字选区底色，必须半透明才能露出文字；
    // Lithe 的 `selection` 是不透明强调色，只用于按钮/列表选中态。
    colors.selection = tokens.selection.alpha(0.30);
    colors.link = tokens.link;
    colors.link_hover = tokens.link;
    colors.link_active = tokens.link;

    // 滚动条。
    colors.scrollbar = tokens.editor;
    colors.scrollbar_thumb = tokens.tertiary_text;
    colors.scrollbar_thumb_hover = tokens.secondary_text;

    // 其余控件。
    colors.progress_bar = tokens.selection;
    colors.skeleton = tokens.raised;
    colors.slider_bar = tokens.subtle_selection;
    colors.slider_thumb = tokens.selection;
    colors.switch = tokens.selection;
    colors.switch_thumb = white();

    // 图表：Lithe 没有单独的数据可视化配色，用语义色占位。
    colors.chart_1 = tokens.selection;
    colors.chart_2 = tokens.success;
    colors.chart_3 = tokens.warning;
    colors.chart_4 = tokens.error;
    colors.chart_5 = tokens.link;
    colors.chart_bullish = tokens.success;
    colors.chart_bearish = tokens.error;
    colors.chart_grid = tokens.divider;

    // 基础色相：gpui-kit 兼容字段，映射到语义色，Lithe 无独立色板。
    colors.red = tokens.error;
    colors.red_light = tokens.error;
    colors.green = tokens.success;
    colors.green_light = tokens.success;
    colors.blue = tokens.link;
    colors.blue_light = tokens.link;
    colors.yellow = tokens.warning;
    colors.yellow_light = tokens.warning;
    colors.magenta = tokens.accent;
    colors.magenta_light = tokens.accent;
    colors.cyan = tokens.link;
    colors.cyan_light = tokens.link;

    colors
}
