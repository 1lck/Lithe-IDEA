#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Lithe 桌面入口。
//!
//! 入口只负责平台选择、GPUI Kit 初始化、主题/字体安装和主窗口创建；
//! 工作台的布局与业务都在 `lithe-workbench` 中，这里不重复组装界面。

use gpui_kit::component::TitleBar;
use gpui_kit::{AppContext as _, WindowBounds, WindowOptions, px, size};
use lithe_ui::{LitheAssets, LitheThemeKind, install_fonts, install_theme};
use lithe_workbench::Workbench;

/// 创建平台后端之前的进程级准备。
fn configure_environment() {
    // Windows：GPUI 的 DirectComposition 合成后端在部分显卡驱动、虚拟机和远程桌面
    // 会话里会黑屏或直接创建窗口失败，gpui-kit 的示例统一在启动前关掉它。
    #[cfg(target_os = "windows")]
    {
        // SAFETY: 这行发生在 `gpui_kit::application()` 之前。那时进程刚启动，
        // 还没有 GPUI 平台线程或其他线程并发读写环境变量；Rust 2024 把
        // `set_var` 标记为 unsafe，正是因为并发修改环境变量会产生数据竞争，
        // 此刻的单线程状态满足它的安全前提。
        unsafe {
            std::env::set_var("GPUI_DISABLE_DIRECT_COMPOSITION", "true");
        }
    }
}

fn main() {
    configure_environment();

    // Linux：gpui-kit 默认可能选择 Wayland，但 Lithe 的窗口控制与编辑器 WebView
    // 依赖 X11 语义，所以显式走 X11；Wayland 会话由 XWayland 承载。
    #[cfg(target_os = "linux")]
    let app = gpui_kit::platform::linux(gpui_kit::WindowingModes::X11);
    // macOS / Windows 使用平台默认后端。
    #[cfg(not(target_os = "linux"))]
    let app = gpui_kit::application();

    // Lithe 资产源：gpui-kit 全量图标（含默认图标包之外的 `git-branch`）
    // 加上顶栏的品牌图。
    app.with_assets(LitheAssets).run(move |cx| {
        // 顺序不可交换：`gpui_kit::init` 先注册 Component 的 `Theme` 与窗口扩展，
        // `install_theme` 才能在其上写入 Lithe token；字体随后覆盖主题字体族。
        gpui_kit::init(cx);
        install_fonts(cx);
        install_theme(cx, LitheThemeKind::Lithe, true);

        // 窗口自绘标题栏，初始标题必须写进 `TitlebarOptions`；窗口的系统标题
        // 只在原生装饰可见的阶段（例如 macOS 全屏切换动画）才会用到。
        let mut titlebar = TitleBar::title_bar_options();
        titlebar.title = Some("Lithe".into());

        let options = WindowOptions {
            // 默认 1280×800 并居中；最小 980×640 保证活动栏 + 工具窗 + 编辑区
            // 与状态栏同时可见时仍可正常操作。
            window_bounds: Some(WindowBounds::centered(size(px(1280.), px(800.)), cx)),
            window_min_size: Some(size(px(980.), px(640.))),
            titlebar: Some(titlebar),
            // 与 `TitleBar::window_options()` 的默认值一致，这里显式写出：
            // 标题栏自己处理拖动和双击，避免 macOS 再叠加一次系统行为。
            app_owns_titlebar_drag: true,
            // Linux 使用客户端装饰，`TitleBar` 才能提供最小化/最大化/关闭按钮；
            // 平台不支持时会回退到服务端装饰，此时 `TitleBar` 会自行隐藏这些按钮。
            #[cfg(target_os = "linux")]
            window_decorations: Some(gpui_kit::WindowDecorations::Client),
            // 桌面环境用它在任务栏/启动器里归并同一应用的窗口。
            app_id: Some("lithe-desktop".into()),
            ..TitleBar::window_options()
        };

        let opened = gpui_kit::open_window(options, cx, |window, cx| {
            cx.new(|cx| Workbench::new(window, cx))
        });

        // 启动失败不 panic：把原因写到 stderr，并让进程带非零退出码结束，
        // 方便开发期与 CI 直接看到失败原因。
        let _ = match opened {
            Ok(window) => window,
            Err(error) => {
                eprintln!("无法创建 Lithe 主窗口：{error}");
                std::process::exit(1);
            }
        };
    });
}
