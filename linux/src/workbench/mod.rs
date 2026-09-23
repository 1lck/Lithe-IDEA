pub mod activity_rail;
pub mod bottom_panel;
pub mod editor;
pub mod sidebar;
pub mod status_bar;
pub mod terminal;
pub mod toolbar;
pub mod view;

#[allow(unused_imports)]
pub use activity_rail::{ActivityRailEvent, ActivityRailView, ActivityTab};
#[allow(unused_imports)]
pub use bottom_panel::BottomPanelView;
#[allow(unused_imports)]
pub use editor::EditorView;
#[allow(unused_imports)]
pub use sidebar::SidebarView;
#[allow(unused_imports)]
pub use status_bar::StatusBarView;
#[allow(unused_imports)]
pub use terminal::TerminalView;
#[allow(unused_imports)]
pub use toolbar::ToolbarView;
pub use view::WorkbenchView;
