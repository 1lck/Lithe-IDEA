pub mod activity_rail;
pub mod bottom_panel;
pub mod command_palette;
pub mod editor;
pub mod maven;
pub mod quick_open;
pub mod search_everywhere;
pub mod settings_dialog;
pub mod sidebar;
pub mod status_bar;
pub mod terminal;
pub mod toolbar;
pub mod view;
pub mod welcome_screen;

#[allow(unused_imports)]
pub use activity_rail::{
    ActivityRailEvent, ActivityRailView, PluginActivityRailView, PluginRailEvent,
};
#[allow(unused_imports)]
pub use bottom_panel::BottomPanelView;
#[allow(unused_imports)]
pub use command_palette::{CommandPaletteEvent, CommandPaletteModal};
#[allow(unused_imports)]
pub use editor::EditorView;
#[allow(unused_imports)]
pub use maven::{MavenEvent, MavenView};
#[allow(unused_imports)]
pub use quick_open::{QuickOpenEvent, QuickOpenModal};
#[allow(unused_imports)]
pub use search_everywhere::{SearchEverywhereEvent, SearchEverywhereModal, SearchScope};
#[allow(unused_imports)]
pub use settings_dialog::{SettingsCategory, SettingsDialog, SettingsEvent};
#[allow(unused_imports)]
pub use sidebar::{SidebarEvent, SidebarTab, SidebarView};
#[allow(unused_imports)]
pub use status_bar::{StatusBarEvent, StatusBarView};
#[allow(unused_imports)]
pub use toolbar::{ToolbarEvent, ToolbarView};
pub use view::WorkbenchView;
#[allow(unused_imports)]
pub use welcome_screen::{RecentProject, WelcomeEvent, WelcomeScreenView};
