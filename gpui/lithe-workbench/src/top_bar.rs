//! 40pt 工作台顶栏。
//!
//! 左侧集群以 Tauri 标题栏为原型（`title-bar.tsx`）：应用图标 → 全局菜单
//! 触发器（汉堡）→ 项目入口 → 分支入口，尺寸与间距按 `--lithe-chrome-*`
//! 变量换算；右侧仍是 macOS `WorkbenchView.topBar` 的运行/搜索/设置入口。
//! Settings 由工作台在主窗口内打开设置覆盖层；Run 执行当前选中的
//! 运行配置（没有配置时打开底部 Run 面板）；Debug 打开底部 Debug 工具窗；
//! Search Everywhere 打开左锚点 Search 工具窗。Stop 只在当前选中配置有活动
//! 会话时启用，停止动作由工作台转发给 Run 面板。
//!
//! 项目入口和分支入口在这里只负责“请求展开菜单”：菜单本身由工作台在根
//! 节点上绝对定位绘制，这样下拉层不会被 40pt 顶栏的高度裁剪。顶栏不持有
//! 菜单状态，也不读取最近项目或 Git 分支。

use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui_kit::assets::IconName;
use gpui_kit::base::Selectable as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::toolbar::Toolbar;
use gpui_kit::component::{Icon, Sizable as _, h_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Background, FontWeight, InteractiveElement as _, IntoElement, MouseButton,
    ObjectFit, ParentElement as _, RenderOnce, SharedString, StatefulInteractiveElement as _,
    Styled as _, StyledImage as _, Window, WindowControlArea, div, img, linear_color_stop,
    linear_gradient, px, rgb, white,
};
use lithe_ui::{
    APP_LOGO_PATH, LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens,
    i18n::tr, icon,
};

/// 无参数的 UI 回调：项目菜单、分支菜单、Run、Debug、Search 和 Settings 共用。
type UiCallback = Rc<dyn Fn(&mut Window, &mut App) + 'static>;

/// 顶栏项目头像边长，对齐 macOS `WorkbenchTopBarMetrics.projectAvatarSize`。
const PROJECT_AVATAR_SIZE: f32 = 20.0;

// --- 顶栏 / 工具窗标题栏刻度 -------------------------------------------------
// 左侧集群（应用图标 / 汉堡 / 项目 / 分支）逐项对齐 Tauri
// `windows/tauri/src/features/window/components/title-bar/title-bar.tsx` 与
// `--lithe-chrome-*` 变量，数值统一放在 `LitheMetrics`；右侧动作按钮沿用
// macOS `LitheTheme.MainToolbar` 的刻度。
//
/// 顶栏动作按钮的绘制边长：对齐 Tauri
/// `MAIN_TOOLBAR_ICON_BUTTON_CLASS_NAME = "size-[30px] rounded-[6px]"`。
const TOOLBAR_BUTTON_SIZE: f32 = 30.0;
/// 顶栏动作按钮圆角：对齐 Tauri 同一常量的 `rounded-[6px]`。
const TOOLBAR_BUTTON_RADIUS: f32 = 6.0;
/// Search / Settings 图标 20px：对齐 Tauri `size="icon-xs"` 按钮内
/// `<MagnifyingGlassIcon large className="size-5" />` 等 20px 图标。
const TOOLBAR_ACTION_ICON_SIZE: f32 = 20.0;


/// 工具窗标题栏图标按钮 22×22：对齐 `LitheTheme.swift:971`
/// `Metrics.toolbarIconButtonSize = 22`。
pub(crate) const TOOL_WINDOW_HEADER_BUTTON_SIZE: f32 = 22.0;
/// 工具窗标题栏图标按钮圆角 5：对齐 `LitheTheme.swift:985`
/// `Metrics.cornerRadius = 5`（`LitheIconButtonStyle` 的默认圆角）。
pub(crate) const TOOL_WINDOW_HEADER_BUTTON_RADIUS: f32 = 5.0;

/// 标题行左侧留白。
///
/// macOS 的原生红黄绿按钮画在窗口左上角（`TitleBar::title_bar_options`
/// 把 traffic light 放在 `(9, 9)`），Tauri 的标题栏在 macOS 用 94pt 留白；
/// 其他平台从窗口左边缘直接开始。
#[cfg(target_os = "macos")]
const TITLE_ROW_LEADING_INSET: f32 = 94.0;
#[cfg(not(target_os = "macos"))]
const TITLE_ROW_LEADING_INSET: f32 = 0.0;

/// 标题行右侧留白。
///
/// Windows / Linux 的窗口按钮自己贴到右边缘，不能再加内边距；macOS 没有
/// 自绘按钮，保留原来的 8pt。
#[cfg(target_os = "macos")]
const TITLE_ROW_TRAILING_INSET: f32 = LitheMetrics::TOP_BAR_PADDING_RIGHT;
#[cfg(not(target_os = "macos"))]
const TITLE_ROW_TRAILING_INSET: f32 = 0.0;

/// 项目头像的 9 组渐变色，逐项复制 macOS `ProjectIdentityAppearance.palette`
/// 的 `(avatarStart, avatarEnd)`。颜色索引由项目绝对路径的 FNV-1a 哈希决定。
const PROJECT_AVATAR_PALETTE: [(u32, u32); 9] = [
    (0xE08855, 0xE9806F),
    (0xB08B14, 0xBB7F19),
    (0xA1A359, 0x87AA59),
    (0x3B92B8, 0x6183EC),
    (0x3574F0, 0x7A64F0),
    (0xC84D8F, 0xA956CF),
    (0x955AE0, 0xA84DE0),
    (0x24A394, 0x279CCD),
    (0x5FAD65, 0x3D968B),
];

pub(crate) struct TopBar {
    project_name: SharedString,
    /// 当前项目绝对路径；没有项目时为 `None`。只用于头像颜色哈希，不参与
    /// 文案或文件 I/O。
    project_root: Option<PathBuf>,
    branch: SharedString,
    /// 展开态的菜单栏元素。`Some` 时汉堡和项目 / 分支入口让位，菜单栏在
    /// 汉堡原来的位置原位展开（Tauri 紧凑菜单栏行为）。
    compact_menu: Option<AnyElement>,
    /// 项目 / 分支下拉是否展开，用于触发器的持续按下态。
    project_menu_open: bool,
    branch_menu_open: bool,
    /// 汉堡按钮：切换全局菜单。
    on_toggle_menu: Option<UiCallback>,
    on_toggle_project_menu: Option<UiCallback>,
    on_toggle_branch_menu: Option<UiCallback>,
    /// Search Everywhere 单独回调：打开左侧 Search 工具窗。
    on_search: Option<UiCallback>,
    /// Settings 单独回调：它打开的是覆盖层，不再走“未实现”占位。
    on_settings: Option<UiCallback>,
}

impl TopBar {
    pub(crate) fn new() -> Self {
        Self {
            project_name: tr("No Project").into(),
            project_root: None,
            // 分支默认 main，工作台打开项目后从 `git.status` 的 `data.branch`
            // 覆盖。
            branch: tr("main").into(),
            compact_menu: None,
            project_menu_open: false,
            branch_menu_open: false,
            on_toggle_menu: None,
            on_toggle_project_menu: None,
            on_toggle_branch_menu: None,
            on_search: None,
            on_settings: None,
        }
    }

    pub(crate) fn project_name(mut self, name: impl Into<SharedString>) -> Self {
        self.project_name = name.into();
        self
    }

    /// 当前项目绝对路径。头像只读它的哈希，不做规范化或文件 I/O；工作台已经
    /// 持有规范化后的项目根。
    pub(crate) fn project_root(mut self, root: Option<PathBuf>) -> Self {
        self.project_root = root;
        self
    }

    /// 当前分支。由工作台从 `git.status` 的 `data.branch` 取得；取不到时保持
    /// 默认 `main`，顶栏不额外显示错误。
    pub(crate) fn branch(mut self, branch: impl Into<SharedString>) -> Self {
        self.branch = branch.into();
        self
    }

    /// 展开态的菜单栏。传入后汉堡隐藏，菜单栏占据它的位置。
    pub(crate) fn compact_menu(mut self, menu: Option<AnyElement>) -> Self {
        self.compact_menu = menu;
        self
    }

    /// 项目 / 分支下拉的展开态，用于触发器的持续按下反馈。
    pub(crate) fn project_menu_open(mut self, open: bool) -> Self {
        self.project_menu_open = open;
        self
    }

    pub(crate) fn branch_menu_open(mut self, open: bool) -> Self {
        self.branch_menu_open = open;
        self
    }

    pub(crate) fn on_toggle_menu(mut self, handler: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_toggle_menu = Some(Rc::new(handler));
        self
    }

    /// 项目按钮：展开工作台绘制的项目切换菜单，不再直接打开文件夹。
    pub(crate) fn on_toggle_project_menu(
        mut self,
        handler: impl Fn(&mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_toggle_project_menu = Some(Rc::new(handler));
        self
    }

    /// 分支按钮：展开工作台绘制的分支切换菜单。
    pub(crate) fn on_toggle_branch_menu(
        mut self,
        handler: impl Fn(&mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_toggle_branch_menu = Some(Rc::new(handler));
        self
    }

    /// Search Everywhere 按钮：打开底部 Search 面板，复用活动栏的现有路由。
    pub(crate) fn on_search(mut self, handler: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_search = Some(Rc::new(handler));
        self
    }

    /// Settings 按钮：打开工作台内的设置覆盖层。
    pub(crate) fn on_settings(mut self, handler: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_settings = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for TopBar {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let TopBar {
            project_name,
            project_root,
            branch,
            compact_menu,
            project_menu_open,
            branch_menu_open,
            on_toggle_menu,
            on_toggle_project_menu,
            on_toggle_branch_menu,
            on_search,
            on_settings,
        } = self;

        // 左侧集群按 Tauri 标题栏拼装：应用图标 → 汉堡 → 项目 + 分支。
        // 紧凑菜单展开时，汉堡和项目 / 分支一起让位给完整菜单栏。
        // `Toolbar` 负责语义和键盘横向移动；外观尺寸由这里的样式覆盖。
        let mut bar = Toolbar::new("lithe-top-bar")
            // 顶栏是普通 GPUI 行，不再嵌进 TitleBar 的拖拽区域；否则 Windows
            // 会把它当作 HTCAPTION，子按钮收不到点击。
            .h(px(LitheMetrics::TOP_BAR_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(LitheMetrics::TOP_BAR_ITEM_GAP))
            .pl(px(LitheMetrics::TOP_BAR_PADDING_LEFT + TITLE_ROW_LEADING_INSET))
            .pr(px(TITLE_ROW_TRAILING_INSET))
            // Tauri 顶栏只铺 surface，没有额外的底部 1pt 分隔线。
            .bg(tokens.titlebar)
            // 应用图标：不可点击、不可选中，仅标记应用身份。
            .content(app_brand());

        // Tauri 紧凑菜单栏：收起时只显示汉堡；展开后汉堡消失，完整菜单栏
        // 占据同一行，项目 / 分支入口暂时隐藏。
        bar = if let Some(menu) = compact_menu {
            bar.content(div().flex_1().h_full().min_w(px(0.)).child(menu))
        } else {
            bar
                // 全局菜单触发器：替代传统的文字菜单栏。
                .content(menu_button(on_toggle_menu))
                // 项目和分支是同一个紧凑分组，组内间距 2pt。
                .content(
                    h_flex()
                        .items_center()
                        .gap(px(LitheMetrics::TOP_BAR_GROUP_GAP))
                        .child(project_entry(
                            project_name,
                            project_root,
                            project_menu_open,
                            on_toggle_project_menu,
                            tokens,
                        ))
                        .child(branch_entry(
                            branch,
                            branch_menu_open,
                            on_toggle_branch_menu,
                            tokens,
                        )),
                )
        };

        // Tauri 在 Windows 的标题栏右侧只有搜索、设置和窗口按钮；运行配置 /
        // Run / Debug / Stop 只出现在 macOS 分支。这里对齐 Windows 原型。
        //
        // 中间弹性空白是标题栏的可拖动区域：交给 Windows 的系统命中测试
        // （`HTCAPTION`），和 Tauri `runTitleBarDrag` 在非交互目标上拖动窗口
        // 的行为一致；按钮所在区域仍是普通可点击元素。
        bar.content(
            div()
                .flex_1()
                .h_full()
                .min_w(px(0.0))
                .when(cfg!(target_os = "windows"), |this| {
                    this.window_control_area(WindowControlArea::Drag)
                }),
        )
            // Search Everywhere 在 Settings 之前。Tauri 用
            // `size="icon-xs"` 再以 `size-[30px]` 覆盖，`icon-xs` 自带
            // `p-0`，图标在按钮内居中，不额外加内边距。
            .content(
                Button::new("lithe-top-bar-search")
                    .ghost()
                    .size(px(TOOLBAR_BUTTON_SIZE))
                    .p(px(0.0))
                    .rounded(px(TOOLBAR_BUTTON_RADIUS))
                    .child(icon(LitheIcon::Search).with_size(px(TOOLBAR_ACTION_ICON_SIZE)))
                    .tooltip(tr("Search Everywhere"))
                    .accessibility_label(tr("Search Everywhere"))
                    .when_some(on_search, |this, handler| {
                        this.on_click(move |_, window, cx| handler(window, cx))
                    }),
            )
            // Settings 打开主窗口内的设置覆盖层，不再走“未实现”状态栏提示。
            // 尺寸/内边距同 Search（`icon-xs` 的 `p-0`），图标 20px。
            .content(
                Button::new("lithe-top-bar-settings")
                    .ghost()
                    .size(px(TOOLBAR_BUTTON_SIZE))
                    .p(px(0.0))
                    .rounded(px(TOOLBAR_BUTTON_RADIUS))
                    .child(icon(LitheIcon::Settings).with_size(px(TOOLBAR_ACTION_ICON_SIZE)))
                    .tooltip(tr("Settings"))
                    .accessibility_label(tr("Settings"))
                    .when_some(on_settings, |this, handler| {
                        this.on_click(move |_, window, cx| handler(window, cx))
                    }),
            )
            // 标题行最右侧的窗口按钮，与菜单栏同一条水平线。
            .content(window_controls(window, tokens))
    }
}

/// 标题行右端的窗口控制按钮。
///
/// gpui-kit 的 `TitleBar` 把整行标成 `WindowControlArea::Drag`，Windows 上
/// 其中的子按钮收不到鼠标事件，所以标题栏与顶栏合并成一行时只能自己组合：
/// Windows 交给系统命中测试，Linux 客户端装饰自己接点击，macOS 原生红黄绿
/// 按钮已经在左上角，这里不画。
fn window_controls(window: &Window, tokens: LitheTokens) -> AnyElement {
    if cfg!(target_os = "macos") || cfg!(target_family = "wasm") {
        return div().into_any_element();
    }

    // Linux 回退到服务端装饰时，窗口管理器已经画了一套按钮，再画会重复。
    #[cfg(target_os = "linux")]
    if !matches!(
        window.window_decorations(),
        gpui_kit::Decorations::Client { .. }
    ) {
        return div().into_any_element();
    }

    let maximize = if window.is_maximized() {
        IconName::WindowRestore
    } else {
        IconName::WindowMaximize
    };

    h_flex()
        .id("lithe-window-controls")
        .flex_shrink_0()
        .h_full()
        .items_center()
        .child(window_control_button(
            "window-minimize",
            IconName::WindowMinimize,
            WindowControlArea::Min,
            false,
            tokens,
        ))
        .child(window_control_button(
            "window-maximize",
            maximize,
            WindowControlArea::Max,
            false,
            tokens,
        ))
        .child(window_control_button(
            "window-close",
            IconName::WindowClose,
            WindowControlArea::Close,
            true,
            tokens,
        ))
        .into_any_element()
}

fn window_control_button(
    id: &'static str,
    icon_name: IconName,
    area: WindowControlArea,
    danger: bool,
    tokens: LitheTokens,
) -> AnyElement {
    let hover_bg = if danger { tokens.error } else { tokens.hover };
    let hover_fg = if danger { white() } else { tokens.primary_text };

    div()
        .id(id)
        .flex()
        .w(px(LitheMetrics::WINDOW_CONTROL_WIDTH))
        .h_full()
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .text_color(tokens.primary_text)
        .hover(move |style| style.bg(hover_bg).text_color(hover_fg))
        .active(|style| style.bg(tokens.pressed))
        // Windows：系统按标题栏按钮处理，点击由平台完成。
        .when(cfg!(target_os = "windows"), |this| {
            this.window_control_area(area)
        })
        // Linux：客户端装饰，按钮行为由应用自己实现。
        .when(cfg!(target_os = "linux"), |this| {
            this.on_mouse_down(MouseButton::Left, |_, window, cx| {
                window.prevent_default();
                cx.stop_propagation();
            })
            .on_click(move |_, window, cx| {
                cx.stop_propagation();
                match area {
                    WindowControlArea::Min => window.minimize_window(),
                    WindowControlArea::Max => window.zoom_window(),
                    WindowControlArea::Close => window.remove_window(),
                    WindowControlArea::Drag => {}
                }
            })
        })
        .child(Icon::new(icon_name).with_size(px(LitheMetrics::WINDOW_CONTROL_ICON_SIZE)))
        .into_any_element()
}

/// 顶栏应用图标。
///
/// 与 Tauri 一样是不可交互的品牌标记：占据活动栏同宽的 38pt 槽位，
/// 只在中间画 24pt 的 logo，不接收点击、不进入焦点顺序。
fn app_brand() -> AnyElement {
    div()
        .flex_shrink_0()
        .h_full()
        .w(px(LitheMetrics::TOP_BAR_BRAND_WIDTH))
        .flex()
        .items_center()
        .justify_center()
        .overflow_hidden()
        // Tauri 的品牌图标是 `pointer-events-none`，点击穿透到标题栏后拖动
        // 窗口；这里同样把这块非交互区域交给系统命中测试。
        .when(cfg!(target_os = "windows"), |this| {
            this.window_control_area(WindowControlArea::Drag)
        })
        .child(
            img(APP_LOGO_PATH)
                .w(px(LitheMetrics::TOP_BAR_BRAND_LOGO_SIZE))
                .h(px(LitheMetrics::TOP_BAR_BRAND_LOGO_SIZE))
                .object_fit(ObjectFit::Contain),
        )
        .into_any_element()
}

/// 顶栏全局菜单触发器：30×30 ghost 按钮 + 20pt 三条横线。
fn menu_button(handler: Option<UiCallback>) -> Button {
    Button::new("lithe-top-bar-menu")
        .ghost()
        .size(px(LitheMetrics::TOP_BAR_TRIGGER_HEIGHT))
        .rounded(px(LitheMetrics::TOP_BAR_TRIGGER_RADIUS))
        .tooltip(tr("Menu"))
        .accessibility_label(tr("Menu"))
        .when_some(handler, |this, handler| {
            this.on_click(move |_, window, cx| handler(window, cx))
        })
        .child(icon(LitheIcon::Menu).with_size(px(LitheMetrics::TOP_BAR_ICON_SIZE)))
}

/// 下拉箭头：16pt，与文字净间距 2pt。
///
/// Tauri 用 `-ml-1` 把 6pt 的 item gap 压到 2pt；GPUI 用负外边距表达同一件事。
fn dropdown_chevron(tokens: LitheTokens) -> Icon {
    icon(LitheIcon::ChevronDown)
        .with_size(px(LitheMetrics::TOP_BAR_CHEVRON_SIZE))
        .ml(px(
            LitheMetrics::TOP_BAR_CHEVRON_GAP - LitheMetrics::TOP_BAR_TRIGGER_GAP,
        ))
        .text_color(tokens.secondary_text)
}

/// 顶栏项目入口：20pt 头像 + 项目名 + chevron。
///
/// 用 `Button` 而不是裸 `div`，保留键盘焦点、点击和无障碍标签；外观覆盖为
/// 30pt 高、6pt 圆角，内容包在单个 `h_flex` 里，避免按钮内部的 4pt 间距
/// 把头像和文字挤在一起。
fn project_entry(
    project_name: SharedString,
    project_root: Option<PathBuf>,
    open: bool,
    handler: Option<UiCallback>,
    tokens: LitheTokens,
) -> Button {
    Button::new("lithe-top-bar-project")
        .ghost()
        .h(px(LitheMetrics::TOP_BAR_TRIGGER_HEIGHT))
        .rounded(px(LitheMetrics::TOP_BAR_TRIGGER_RADIUS))
        .pl(px(LitheMetrics::TOP_BAR_TRIGGER_PADDING_LEFT))
        .pr(px(LitheMetrics::TOP_BAR_TRIGGER_PADDING_RIGHT))
        .max_w(px(LitheMetrics::TOP_BAR_PROJECT_MAX_WIDTH))
        .selected(open)
        .tooltip(tr("Recent Projects"))
        .accessibility_label(tr("Recent Projects"))
        .when_some(handler, |this, handler| {
            this.on_click(move |_, window, cx| handler(window, cx))
        })
        .child(
            h_flex()
                .items_center()
                .gap(px(LitheMetrics::TOP_BAR_TRIGGER_GAP))
                .child(project_avatar(
                    project_name.clone(),
                    project_root.as_deref(),
                    tokens,
                ))
                .child(
                    div()
                        .min_w(px(0.))
                        .truncate()
                        .text_size(px(LitheMetrics::TOP_BAR_LABEL_FONT_SIZE))
                        // Tauri 用 `font-medium`（500），不是半粗。
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(tokens.primary_text)
                        .child(project_name),
                )
                .child(dropdown_chevron(tokens)),
        )
}

/// 顶栏分支入口：20pt 分支图标 + 分支名 + chevron。
fn branch_entry(
    branch: SharedString,
    open: bool,
    handler: Option<UiCallback>,
    tokens: LitheTokens,
) -> Button {
    Button::new("lithe-top-bar-branch")
        .ghost()
        .h(px(LitheMetrics::TOP_BAR_TRIGGER_HEIGHT))
        .rounded(px(LitheMetrics::TOP_BAR_TRIGGER_RADIUS))
        .pl(px(LitheMetrics::TOP_BAR_TRIGGER_PADDING_LEFT))
        .pr(px(LitheMetrics::TOP_BAR_TRIGGER_PADDING_RIGHT))
        .max_w(px(LitheMetrics::TOP_BAR_BRANCH_MAX_WIDTH))
        .selected(open)
        .tooltip(tr("Branches"))
        .accessibility_label(tr("Branches"))
        .when_some(handler, |this, handler| {
            this.on_click(move |_, window, cx| handler(window, cx))
        })
        .child(
            h_flex()
                .items_center()
                .gap(px(LitheMetrics::TOP_BAR_TRIGGER_GAP))
                .child(
                    icon(LitheIcon::GitBranch)
                        .with_size(px(LitheMetrics::TOP_BAR_ICON_SIZE))
                        .text_color(tokens.secondary_text),
                )
                .child(
                    div()
                        .min_w(px(0.))
                        .truncate()
                        .text_size(px(LitheMetrics::TOP_BAR_LABEL_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(branch),
                )
                .child(dropdown_chevron(tokens)),
        )
}

/// 项目头像。
///
/// 有项目时按绝对路径哈希取 9 组渐变之一；没有项目时退回 `tokens.raised`
/// 纯色。渐变方向对齐 Tauri 的 `linear-gradient(to top right, end, start)`：
/// 起始色在右上，结束色在左下。首字母规则见 [`project_initials`]。
/// 所有计算都是同步纯函数，不读盘、不 spawn。
fn project_avatar(name: SharedString, root: Option<&Path>, tokens: LitheTokens) -> AnyElement {
    let size = PROJECT_AVATAR_SIZE;
    let background: Background = match root {
        Some(root) => {
            let (start, end) = PROJECT_AVATAR_PALETTE[project_color_index(root)];
            // 45° 与 Tauri 的 “to top right” 同向：0 端在左下，1 端在右上。
            linear_gradient(
                45.,
                linear_color_stop(rgb(end), 0.),
                linear_color_stop(rgb(start), 1.),
            )
        }
        None => tokens.raised.into(),
    };
    // Community AvatarUtils New UI：JetBrains Mono DemiBold，20pt 时字号 13pt。
    let font_size = (13.0 * size / 20.0).floor();

    div()
        .flex_shrink_0()
        .size(px(size))
        .rounded(px(size * 0.235))
        .bg(background)
        .flex()
        .items_center()
        .justify_center()
        .child(
            div()
                .font_family(MONO_FONT_FAMILY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_size(px(font_size))
                .line_height(px(size))
                .text_color(white())
                .child(project_initials(name.as_ref())),
        )
        .into_any_element()
}

/// 项目绝对路径的 FNV-1a 哈希取模 9。
///
/// 参数与 Tauri `getProjectGradientColorIndex` 一致：offset
/// `14695981039346656037`，prime `1099511628211`，逐 UTF-8 字节异或后回绕
/// 相乘。哈希前先把反斜杠统一成 `/`、去掉末尾斜杠并转小写，保证同一项目在
/// Windows 上不同写法和大小写得到同一种颜色。路径不是 UTF-8 时退回 0。
fn project_color_index(root: &Path) -> usize {
    let Some(key) = root.to_str() else {
        return 0;
    };
    let normalized = key.replace('\\', "/");
    let normalized = normalized.trim_end_matches('/').to_lowercase();
    let mut hash: u64 = 14_695_981_039_346_656_037;
    for byte in normalized.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    (hash % PROJECT_AVATAR_PALETTE.len() as u64) as usize
}

/// 头像首字母，逐条移植 Tauri 的 `getProjectAvatarInitials`。
///
/// 1. 先取驼峰首字母：跳过开头非字母字符，遇到非字母数字就停；
/// 2. 驼峰只有 1 个字母时，按空格、逗号、连字符、下划线、点、引号依次切分，
///    取第一个和最后一个词的首字母（例如 `Lithe-IDEA-issue-35-ci` → `LC`）；
/// 3. 都没有时保留驼峰结果（可能为空）。
fn project_initials(name: &str) -> String {
    let camel = camel_case_initials(name);
    if camel.chars().count() == 2 {
        return camel;
    }

    let text = name.trim();
    for delimiters in [" ", ",", "-", "_", ".", "`'\""] {
        let words: Vec<Vec<char>> = text
            .split(|character: char| delimiters.contains(character))
            .map(|word| {
                word.chars()
                    .filter(|character| character.is_alphanumeric())
                    .collect()
            })
            .filter(|word: &Vec<char>| !word.is_empty())
            .collect();
        if words.len() >= 2 {
            let first = words[0][0];
            let last = words[words.len() - 1][0];
            return [first, last]
                .into_iter()
                .collect::<String>()
                .to_uppercase();
        }
    }

    camel
}

fn camel_case_initials(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let Some(start) = characters.iter().position(|character| character.is_alphabetic()) else {
        return String::new();
    };

    let mut initials = String::new();
    for (index, character) in characters.iter().enumerate().skip(start) {
        if !character.is_alphanumeric() {
            break;
        }
        if index == start || character.is_uppercase() {
            initials.push(*character);
        }
        if initials.chars().count() == 2 {
            break;
        }
    }
    initials.to_uppercase()
}


