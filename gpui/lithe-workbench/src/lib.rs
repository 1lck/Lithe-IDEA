//! Lithe GPUI 工作台外壳（Phase 0）。
//!
//! 本 crate 只负责把 `lithe-ui` 的视觉组件、`lithe-features` 的业务视图和
//! `lithe-platform` 的平台能力组装成窗口壳；业务规则不在这里实现。
//!
//! ```ignore
//! let workbench = cx.new(|cx| Workbench::new(window, cx));
//! ```

extern crate gpui_kit as gpui;

mod activity_rail;
mod app_menu;
mod commit_header;
mod layout;
mod project_header;
mod top_bar;
mod workbench;
mod workspace_layout;

pub use workbench::Workbench;
