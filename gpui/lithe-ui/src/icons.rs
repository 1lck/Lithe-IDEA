//! Lithe 图标集。
//!
//! 这里只做「业务语义 -> Lucide 图标名」的映射，尺寸、颜色由调用方决定。
//! 使用 gpui-kit 组件自带的 `IconName`（默认资源包），保证默认 `Assets`
//! 也能解析；等 IDEA SVG 迁移完成后再逐个替换。

use gpui_kit::component::{Icon, IconName};

/// 工作台需要的图标语义。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LitheIcon {
    Project,
    Changes,
    Search,
    PullRequests,
    GitLog,
    LocalHistory,
    Terminal,
    Agent,
    References,
    Problems,
    Spring,
    Run,
    Tests,
    Debug,
    BuildOutput,
    Notifications,
    /// 右侧活动栏的扩展入口（Tauri `PuzzlePieceIcon`）。
    Extensions,
    /// Maven 工具窗入口（Tauri `MavenIcon`，JetBrains 字形，Apache 2.0）。
    Maven,
    Settings,
    Refresh,
    Collapse,
    Close,
    ChevronDown,
    ChevronRight,
    File,
    Folder,
    FolderOpen,
    Java,
    NodeJs,
    Rust,
    Python,
    Go,
    Markdown,
    Plus,
    More,
    /// 顶栏全局菜单触发器（三条横线）。
    Menu,
    /// Git 分支入口。
    GitBranch,
    /// 自动换行折行图标（对齐 Tauri `WrapText`）。
    WrapText,
    /// Maven 项目 / 模块 / 依赖节点（对齐 Tauri `PackageIcon`）。
    Package,
    /// Maven 运行按钮的停止字形（对齐 Tauri `StopIcon`）。
    Stop,
    /// 警告提示（对齐 Tauri `WarningIcon`）。
    Warning,
    /// 恢复默认（对齐 Tauri `ArrowCounterClockwiseIcon`）。
    Restore,
    /// 最小化（对齐 Tauri `MinusIcon`）。
    Minus,
    /// 清空输出（对齐 Tauri `TrashIcon`）。
    Trash,
    /// Maven 设置入口（对齐 Tauri `SlidersHorizontalIcon`）。
    Sliders,
    /// 全部折叠（对齐 Tauri `ArrowsInIcon`）。
    CollapseAll,
}

pub fn icon(icon: LitheIcon) -> gpui_kit::component::Icon {
    // 这两个图标不在 gpui-kit 的默认图标包里，但全量目录提供，直接取全量
    // `IconName`，避免另画 SVG。
    match icon {
        // 顶栏全局主菜单图标：对齐 Tauri Windows 专用的四条横杠图标（windowsMenu@20x20.svg）。
        LitheIcon::Menu => Icon::default().data(WINDOWS_MENU_ICON_SVG),
        LitheIcon::GitBranch => Icon::new(gpui_kit::assets::IconName::GitBranch),
        // 默认图标包里没有拼图，全量目录里有 `puzzle`。
        LitheIcon::Extensions => Icon::new(gpui_kit::assets::IconName::Puzzle),
        // Maven 没有通用图标；直接内嵌 Tauri `maven-icon.tsx` 的同一条路径，
        // 保持两个平台字形一致（Apache 2.0，JetBrains Maven glyph）。
        LitheIcon::Maven => Icon::default().data(MAVEN_ICON_SVG),
        // 左侧活动栏工具窗图标：内嵌 Tauri 原版 JetBrains ExpUI 矢量路径，保持两个平台 100% 逐像素对齐。
        LitheIcon::Project => Icon::default().data(PROJECT_ICON_SVG),
        LitheIcon::Changes => Icon::default().data(COMMIT_ICON_SVG),
        LitheIcon::Search => Icon::default().data(SEARCH_ICON_SVG),
        LitheIcon::Run => Icon::default().data(RUN_ICON_SVG),
        LitheIcon::Terminal => Icon::default().data(TERMINAL_ICON_SVG),
        LitheIcon::Problems => Icon::default().data(PROBLEMS_ICON_SVG),
        LitheIcon::GitLog => Icon::default().data(VCS_ICON_SVG),
        LitheIcon::WrapText => Icon::default().data(WRAP_TEXT_ICON_SVG),
        // 全量目录图标：默认图标包没有 package / rotate-ccw / trash。
        LitheIcon::Package => Icon::new(gpui_kit::assets::IconName::Package),
        LitheIcon::Restore => Icon::new(gpui_kit::assets::IconName::RotateCcw),
        LitheIcon::Trash => Icon::new(gpui_kit::assets::IconName::Trash),
        LitheIcon::Sliders => Icon::new(gpui_kit::assets::IconName::SlidersHorizontal),
        LitheIcon::CollapseAll => Icon::new(gpui_kit::assets::IconName::ChevronsDownUp),
        LitheIcon::Java => Icon::default().data(JAVA_CUP_ICON_SVG),
        LitheIcon::Spring => Icon::default().data(SPRING_LEAF_ICON_SVG),
        LitheIcon::NodeJs => Icon::default().data(NODEJS_ICON_SVG),
        LitheIcon::Rust => Icon::default().data(RUST_ICON_SVG),
        LitheIcon::Python => Icon::default().data(PYTHON_ICON_SVG),
        LitheIcon::Go => Icon::default().data(GO_ICON_SVG),
        _ => Icon::new(name_for(icon)),
    }
}

/// 自动换行折行图标（对齐 Lucide / Tauri `WrapText`）。
const WRAP_TEXT_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="3" x2="21" y1="6" y2="6"/><line x1="3" x2="15" y1="12" y2="12"/><polyline points="15 8 19 12 15 16"/><path d="M19 12h2a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2H3"/></svg>"#;

/// Java 咖啡杯图标（对齐 Tauri `JavaCupIcon`）。
const JAVA_CUP_ICON_SVG: &[u8] = br#"<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linecap="round"><path d="M3.5 5.5h7.25c.97 0 1.75.78 1.75 1.75S11.72 9 10.75 9H10.5"/><path d="M3.75 5.5h6.5v4.25a2.75 2.75 0 0 1-2.75 2.75h-1A2.75 2.75 0 0 1 3.75 9.75V5.5Z"/><path d="M4.25 13.25h5.5"/></svg>"#;

/// Spring Boot 绿叶图标（对齐 Tauri Lucide `Leaf`）。
const SPRING_LEAF_ICON_SVG: &[u8] = br#"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z"/><path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12"/></svg>"#;

/// Node.js 绿色立体包图标（对齐 Tauri `node.svg`）。
const NODEJS_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none"><path d="m8 1.5 5.5 3.1v6.2L8 14l-5.5-3.2V4.6L8 1.5Z" stroke="#5FAE64" stroke-width="1.3" stroke-linejoin="round"/><path d="M2.5 4.6 8 7.8l5.5-3.2M8 7.8V14" stroke="#5FAE64" stroke-width="1.1" stroke-linecap="round"/></svg>"#;

/// Rust 橙色齿轮/文字图标（对齐 Tauri `lang-rust-color.svg`）。
const RUST_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="5.2" stroke="#ffa359" stroke-width="1.5"/><path d="M6 5.5h2.5c.8 0 1.5.5 1.5 1.25s-.7 1.25-1.5 1.25H6v2.5M6 8h2.3l1.7 2.5" stroke="#ffa359" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>"#;

/// Python 双色图标（对齐 Tauri `lang-python-color.svg`）。
const PYTHON_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none"><path fill="#69b1ff" d="M7.8 8h1.8c1.1 0 1.8-.7 1.8-1.7V5q0-.2.2-.2h.7c.7 0 1.3.3 1.6.9.4.7.4 1.4.4 2.1-.2 1-.7 1.5-1.5 1.6H8.2c-.1 0-.2 0-.2.1v.4h2.7c.3 0 .3.3.3.3v1c0 .5-.2.9-.7 1-.4.2-.8.3-1.2.4-1.2.2-2.4 0-3-.2-.3-.3-.5-.6-.5-1.1v-2.7c0-1.1.6-1.7 1.7-1.7.5 0 1.1 0 1.5.1"/><path fill="#ffd452" d="M8.2 8H6.4c-1.1 0-1.8.7-1.8 1.7V11q0 .2-.2.2h-.7c-.7 0-1.3-.3-1.6-.9-.4-.7-.4-1.4-.4-2.1.2-1 .7-1.5 1.5-1.6h4.6c.1 0 .2 0 .2-.1v-.4H5.7c-.3 0-.3-.3-.3-.3V4.9c0-.5.2-.9.7-1 .4-.2.8-.3 1.2-.4 1.2-.2 2.4 0 3 .2.3.3.5.6.5 1.1v2.7c0 1.1-.6 1.7-1.7 1.7-.5 0-1.1 0-1.5-.1"/></svg>"#;

/// Go 蓝青色图标（对齐 Tauri `lang-go-color.svg`）。
const GO_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none"><path fill="#68cdf2" fill-rule="evenodd" d="M4.41 4.57A3.2 3.2 0 0 1 6.87 5q.74.49 1.08 1.29.08.12-.1.16l-1.55.4c-.14.03-.15.04-.27-.1a1 1 0 0 0-.44-.34 1.6 1.6 0 0 0-1.68.14q-.95.61-.94 1.73c0 .73.52 1.33 1.25 1.43q.95.1 1.58-.6l.25-.34h-1.8c-.19 0-.24-.12-.17-.27.12-.28.34-.76.47-1a.3.3 0 0 1 .24-.14h2.98a4 4 0 0 1 .64-1.19 4 4 0 0 1 2.6-1.52 3.5 3.5 0 0 1 2.64.46q1.13.73 1.31 2.04a3.5 3.5 0 0 1-1.06 3.09q-.93.92-2.23 1.17l-.74.08a3.5 3.5 0 0 1-2.27-.8 3 3 0 0 1-.93-1.42 4 4 0 0 1-.39.61 4 4 0 0 1-2.64 1.56 3.3 3.3 0 0 1-2.5-.6 3 3 0 0 1-1.18-2.03 3.5 3.5 0 0 1 .8-2.67 4 4 0 0 1 2.6-1.58M13.1 7.5a1.53 1.53 0 0 0-1.9-1.21q-1.3.3-1.62 1.59a1.5 1.5 0 0 0 .85 1.72q.77.33 1.52-.05a2 2 0 0 0 1.18-1.74q0-.17-.03-.3" clip-rule="evenodd"/></svg>"#;

/// Tauri Windows 全局菜单图标（四条横杠，windowsMenu@20x20.svg）。
const WINDOWS_MENU_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><rect x="2" y="2.5" width="16" height="1.5" rx="0.75" fill="currentColor"/><rect x="2" y="7" width="16" height="1.5" rx="0.75" fill="currentColor"/><rect x="2" y="11.5" width="16" height="1.5" rx="0.75" fill="currentColor"/><rect x="2" y="16" width="16" height="1.5" rx="0.75" fill="currentColor"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/toolwindows/project@20x20.svg`。
const PROJECT_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path d="M10.5199 5.57617L10.7285 5.75H11H17C17.6904 5.75 18.25 6.30964 18.25 7V15.1667C18.25 16.0671 17.553 16.75 16.75 16.75H3.25C2.44705 16.75 1.75 16.0671 1.75 15.1667V4.83333C1.75 3.93294 2.44705 3.25 3.25 3.25H7.63795C7.69643 3.25 7.75307 3.2705 7.798 3.30794L10.5199 5.57617Z" stroke="currentColor" stroke-width="1.5"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/toolwindows/commit@20x20.svg`。
const COMMIT_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path fill-rule="evenodd" clip-rule="evenodd" d="M19.25 9.25C19.6642 9.25 20 9.58579 20 10C20 10.4142 19.6642 10.75 19.25 10.75L13.9298 10.75C13.5787 12.6006 11.9528 14 10 14C8.04721 14 6.42125 12.6006 6.0702 10.75L0.75 10.75C0.335787 10.75 -1.92951e-07 10.4142 -1.74846e-07 10C-1.5674e-07 9.58579 0.335787 9.25 0.75 9.25L6.0702 9.25C6.42125 7.39935 8.04721 6 10 6C11.9528 6 13.5787 7.39935 13.9298 9.25L19.25 9.25ZM10 12.5C11.3807 12.5 12.5 11.3807 12.5 10C12.5 8.61929 11.3807 7.5 10 7.5C8.61929 7.5 7.5 8.61929 7.5 10C7.5 11.3807 8.61929 12.5 10 12.5Z" fill="currentColor"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/general/search@20x20.svg`。
const SEARCH_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path fill-rule="evenodd" clip-rule="evenodd" d="M14.5 9C14.5 12.0376 12.0376 14.5 9 14.5C5.96243 14.5 3.5 12.0376 3.5 9C3.5 5.96243 5.96243 3.5 9 3.5C12.0376 3.5 14.5 5.96243 14.5 9ZM13.3584 14.478C12.1625 15.4307 10.6478 16 9 16C5.13401 16 2 12.866 2 9C2 5.13401 5.13401 2 9 2C12.866 2 16 5.13401 16 9C16 10.6478 15.4307 12.1625 14.478 13.3584C14.5086 13.3812 14.5379 13.4065 14.5657 13.4343L18.5657 17.4343C18.8781 17.7467 18.8781 18.2533 18.5657 18.5657C18.2533 18.8781 17.7467 18.8781 17.4343 18.5657L13.4343 14.5657C13.4065 14.5379 13.3812 14.5086 13.3584 14.478Z" fill="currentColor"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/toolwindows/run@20x20.svg`。
const RUN_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path d="M16.125 11.0825L5.625 17.1447C4.79167 17.6258 3.75 17.0244 3.75 16.0622L3.75 3.93782C3.75 2.97557 4.79167 2.37417 5.625 2.85529L16.125 8.91747C16.9583 9.39859 16.9583 10.6014 16.125 11.0825Z" stroke="currentColor" stroke-width="1.5"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/toolwindows/terminal@20x20.svg`。
const TERMINAL_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none"><path fill-rule="evenodd" clip-rule="evenodd" d="M9 13.2788C9 12.8646 9.33579 12.5288 9.75 12.5288L14.25 12.5C14.6642 12.5 15 12.8358 15 13.25C15 13.6642 14.6642 14 14.25 14L9.75 14.0288C9.33579 14.0288 9 13.693 9 13.2788Z" fill="currentColor"/><rect x="1.75" y="2.75" width="16.5" height="14.5" rx="1.25" stroke="currentColor" stroke-width="1.5"/><path d="M5.75 11.75L8.5 9L5.75 6.25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/toolwindows/vcs.svg` 的矢量路径。
const VCS_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none"><circle cx="4.5" cy="4" r="2" stroke="currentColor" stroke-width="1.5"/><path d="M4.5 11.5H8.5C9.60457 11.5 10.5 10.6046 10.5 9.5V8" stroke="currentColor" stroke-width="1.5"/><path d="M4.5 6.5L4.5 14.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="10.5" cy="6" r="2" stroke="currentColor" stroke-width="1.5"/></svg>"#;

/// Tauri `windows/tauri/src/ui/icons/idea/expui/toolwindows/problems.svg` 的矢量路径。
const PROBLEMS_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.5"/><path d="M8 4.6L8 8.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><circle cx="8" cy="11.2" r="0.75" fill="currentColor"/></svg>"#;

/// Tauri `windows/tauri/src/features/maven/components/maven-icon.tsx` 的
/// 16×16 路径；`currentColor` 让图标跟随按钮文字色。
const MAVEN_ICON_SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="currentColor" d="M13.1621 3.20095C15.2238 3.20095 15.582 4.93562 15.2238 6.49867L13.8964 12.5115C13.801 12.9438 13.3555 13.2206 12.9015 13.1297C12.4476 13.0388 12.1569 12.6146 12.2524 12.1823L13.5034 6.49867C14.0739 4.02014 10.839 4.32583 9.52649 6.16628L8.11076 12.5159C8.0153 12.9482 7.56989 13.2251 7.1159 13.1342C7.09727 13.1304 7.07892 13.1261 7.06087 13.1213C6.6287 13.015 6.35674 12.6025 6.44951 12.1823L7.7054 6.4947C7.96685 5.37561 7.42991 4.82527 6.65007 4.72885C5.72182 4.6293 4.4504 5.17572 3.74084 6.17069L3.7399 6.16398L3.73837 6.16628L2.31807 12.522C2.22161 12.9542 1.77556 13.2301 1.32178 13.1382C0.867995 13.0464 0.578324 12.6215 0.674778 12.1894L2.5029 3.99827C2.59936 3.5661 3.04541 3.29022 3.49919 3.38208C4.01496 3.48649 4.22722 3.95949 4.12783 4.41318C5.07731 3.66511 6.18382 3.13659 7.44866 3.20608C8.6834 3.2309 9.28702 3.89438 9.48446 4.76224C10.6229 3.78903 11.5848 3.20095 13.1621 3.20095Z"/></svg>"#;

fn name_for(icon: LitheIcon) -> IconName {
    match icon {
        LitheIcon::Project => IconName::Folder,
        // VCS 变更：Lucide 没有 Changes，用 replace 表达“文件被改写”。
        LitheIcon::Changes => IconName::Replace,
        LitheIcon::Search => IconName::Search,
        // 默认资源包里没有 git-pull-request，暂用 github 表示远端评审入口。
        LitheIcon::PullRequests => IconName::Github,
        // 提交历史：默认资源包没有 git-graph/history，用回溯箭头占位。
        LitheIcon::GitLog => IconName::Undo2,
        // 本地历史：默认资源包没有带箭头的时钟，用日历占位。
        LitheIcon::LocalHistory => IconName::Calendar,
        LitheIcon::Terminal => IconName::SquareTerminal,
        LitheIcon::Agent => IconName::Bot,
        // 引用/查找用法：默认资源包没有 link/search-check，用外部链接占位。
        LitheIcon::References => IconName::ExternalLink,
        LitheIcon::Problems => IconName::TriangleAlert,
        // Spring：没有对应 Lucide 图标，用星号占位，后续换 IDEA Spring SVG。
        LitheIcon::Spring => IconName::Asterisk,
        LitheIcon::Run => IconName::Play,
        // 测试：默认资源包没有 test-tube，用通过勾选占位。
        LitheIcon::Tests => IconName::CircleCheck,
        // Debug：默认资源包没有 bug，暂用 inspector，后续换 IDEA 虫子 SVG。
        LitheIcon::Debug => IconName::Inspector,
        LitheIcon::BuildOutput => IconName::Cpu,
        LitheIcon::Notifications => IconName::Bell,
        // 扩展与 Maven 由 `icon()` 直接处理，不会走到这里。
        LitheIcon::Extensions => unreachable!("handled in icon()"),
        LitheIcon::Maven => unreachable!("handled in icon()"),
        LitheIcon::Settings => IconName::Settings,
        LitheIcon::Refresh => IconName::RefreshCw,
        LitheIcon::Collapse => IconName::PanelLeftClose,
        LitheIcon::Close => IconName::Close,
        LitheIcon::ChevronDown => IconName::ChevronDown,
        LitheIcon::ChevronRight => IconName::ChevronRight,
        LitheIcon::File => IconName::File,
        LitheIcon::Folder => IconName::Folder,
        LitheIcon::FolderOpen => IconName::FolderOpen,
        LitheIcon::Markdown => IconName::BookOpen,
        LitheIcon::Plus => IconName::Plus,
        LitheIcon::More => IconName::Ellipsis,
        LitheIcon::Stop => IconName::Square,
        LitheIcon::Warning => IconName::TriangleAlert,
        LitheIcon::Minus => IconName::Minus,
        // 由 `icon()` 直接走 SVG 或全量目录。
        LitheIcon::Menu
        | LitheIcon::GitBranch
        | LitheIcon::WrapText
        | LitheIcon::Package
        | LitheIcon::Restore
        | LitheIcon::Trash
        | LitheIcon::Sliders
        | LitheIcon::CollapseAll
        | LitheIcon::Java
        | LitheIcon::Spring
        | LitheIcon::NodeJs
        | LitheIcon::Rust
        | LitheIcon::Python
        | LitheIcon::Go => unreachable!("handled in icon()"),
    }
}
