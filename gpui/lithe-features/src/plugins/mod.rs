//! 插件契约在 GPUI 侧的只读投影。
//!
//! GPUI 构建尚未接入插件宿主桥接；这里只把已有的契约 v1 声明（清单里的
//! `ui.toolWindows` 与 `ui.commands`）投影成工作台可以消费的数据，不做安装、
//! 扫描、窗口创建或进程启动。

pub mod menu_commands;

pub use menu_commands::{
    PLUGIN_MENU_COMMAND_PREFIX, PluginCommandPlacement, PluginCommandTarget,
    PluginMenuAvailability, PluginMenuCommandDeclaration, PluginMenuEntry, PluginMenuRegistry,
    PluginMenuSource, declaration_id_from_menu_command, menu_command_id, menu_items,
    project_menu_entries,
};
