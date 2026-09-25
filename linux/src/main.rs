//! Linux 工作台入口：初始化设置与主题，打开主窗口。

mod core;
mod i18n;
mod keybindings;
mod lsp;
mod settings;
mod theme;
mod workbench;

use gpui_kit::component::{Root, Theme, ThemeMode};
use gpui_kit::*;
use workbench::WorkbenchView;

fn main() {
    // TEMP_DIAG: 临时日志，用于定位 XIM/IME 问题。
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("gpui=debug".parse().unwrap())
                .add_directive("gpui_pre_linux=debug".parse().unwrap())
                .add_directive("xim=debug".parse().unwrap()),
        )
        .init();
    // 工作台使用大量 Lucide 图标，默认 `Assets` 仅内嵌 101 个，需用全量目录。
    let app = gpui_kit::application().with_assets(gpui_kit::assets::AllAssets);

    app.run(move |cx| {
        gpui_kit::init(cx);

        // 先加载持久化设置，再据此决定 gpui-component 主题与工作台调色板。
        settings::init(cx);
        let is_dark = {
            let settings = settings::get(cx);
            let theme_id = settings::resolved_theme_id(settings, false);
            !crate::theme::ThemePalette::is_light(&theme_id)
        };
        let theme_id = settings::resolved_theme_id(settings::get(cx), false);
        settings::apply_theme(&theme_id);

        Theme::change(
            if is_dark {
                ThemeMode::Dark
            } else {
                ThemeMode::Light
            },
            None,
            cx,
        );

        cx.open_window(WindowOptions::default(), |window, cx| {
            let view = cx.new(|cx| WorkbenchView::new(window, cx));
            cx.new(|cx| Root::new(view, window, cx))
        })
        .expect("Failed to open window");
    });
}
