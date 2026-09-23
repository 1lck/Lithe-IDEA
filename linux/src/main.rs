mod core;
mod theme;
mod workbench;

use gpui_kit::component::{Root, Theme, ThemeMode};
use gpui_kit::*;
use workbench::WorkbenchView;

fn main() {
    let app = gpui_kit::application().with_assets(gpui_kit::assets::Assets);

    app.run(move |cx| {
        gpui_kit::init(cx);
        Theme::change(ThemeMode::Dark, None, cx);

        cx.open_window(WindowOptions::default(), |window, cx| {
            let view = cx.new(|cx| WorkbenchView::new(window, cx));
            cx.new(|cx| Root::new(view, window, cx))
        })
        .expect("Failed to open window");
    });
}
