//! 插件命令到 Tools 菜单的投影。
//!
//! 事实来源是 Windows/Tauri 的声明式插件宿主：`windows/tauri/src/features/plugins/
//! declarative-plugin-ui.ts` 只把「已启用且已接受、声明了 `menu` placement、且命令
//! 引用的工具窗仍存在」的命令注册进菜单；点击后执行同一个动作，即打开（或聚焦）
//! 该插件自己声明的工具窗。Tauri 的菜单条再用
//! `command.placements?.includes("menu")` 过滤一次。
//!
//! GPUI 侧目前没有插件宿主桥接（安装、会话、工具窗都由 Tauri 宿主拥有），因此
//! 本模块只做「声明 → 菜单项」的纯投影，不发起 I/O、不持有窗口实体：
//!
//! - 输入：插件清单里已有的 `ui.toolWindows[].id` 与 `ui.commands[]`；这些字段
//!   已由 Core 的 `plugins.declarative.validate` 校验，契约无需改动。
//! - 输出：`PluginMenuEntry` 与现成的 [`MenuItemSpec`]，工作台只需把
//!   [`PluginMenuRegistry::items`] 追加到 Tools 菜单，并在 `run_menu_command`
//!   里用 [`PluginMenuRegistry::resolve_menu_command`] 走与其他菜单项相同的
//!   字符串命令分发，不新建旁路。
//!
//! 插件标题属于插件内容，不是应用界面翻译，按 Tauri 行为原样显示，不经过 `tr`。

use gpui_kit::SharedString;
use lithe_ui::components::menu_bar::MenuItemSpec;
use serde_json::Value;

/// 插件命令在菜单派发层使用的稳定前缀。
///
/// 完整 id 形如 `plugin.command.<契约命令 id>`；契约命令 id 本身已带插件 id
/// 前缀（Core 校验要求 `<pluginId>.` 开头），因此拼接后全局唯一。
pub const PLUGIN_MENU_COMMAND_PREFIX: &str = "plugin.command.";

/// 契约 v1 `ui.commands[].placements` 支持的宿主位置。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PluginCommandPlacement {
    /// 命令面板。
    CommandPalette,
    /// 工具栏按钮。
    Toolbar,
    /// 应用菜单（Tauri 的 `includes("menu")`）。
    Menu,
}

impl PluginCommandPlacement {
    /// 按契约 v1 的 camelCase 拼写解析；未知值返回 `None`，由调用方忽略。
    pub fn from_manifest_str(value: &str) -> Option<Self> {
        match value {
            "commandPalette" => Some(Self::CommandPalette),
            "toolbar" => Some(Self::Toolbar),
            "menu" => Some(Self::Menu),
            _ => None,
        }
    }
}

/// 一个插件命令，只保留菜单投影需要字段。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginMenuCommandDeclaration {
    /// 契约 v1 的 `ui.commands[].id`，全局唯一。
    pub id: String,
    /// 菜单显示名，来自插件清单的 `title`。
    pub title: String,
    /// 命令打开的工具窗 id。
    pub tool_window_id: String,
    /// 命令声明的宿主位置。
    pub placements: Vec<PluginCommandPlacement>,
    /// 菜单排序键，越小越靠前。
    pub order: i32,
}

/// 菜单投影所需的插件级只读声明。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginMenuSource {
    /// 插件 id。
    pub plugin_id: String,
    /// 插件显示名，用于归属说明与菜单分组。
    pub display_name: String,
    /// 插件是否启用；禁用的插件不进入菜单（对齐 Tauri）。
    pub enabled: bool,
    /// 插件包是否通过校验；被拒绝的包永远不进入菜单。
    pub accepted: bool,
    /// 该插件当前拥有的工具窗 id。
    pub tool_window_ids: Vec<String>,
    /// 该插件声明的全部命令。
    pub commands: Vec<PluginMenuCommandDeclaration>,
}

impl PluginMenuSource {
    /// 从契约 v1 的原始清单构造投影输入。
    ///
    /// `enabled` / `accepted` 来自宿主扫描摘要（Tauri 的
    /// `DeclarativePluginSummary`），其余字段来自清单本身：清单里的
    /// `ui.toolWindows[].id` 与 `ui.commands[]`。字段缺失或类型错误时跳过对应
    /// 条目，不猜测默认值。
    pub fn from_manifest(manifest: &Value, enabled: bool, accepted: bool) -> Option<Self> {
        let plugin_id = manifest.get("id")?.as_str()?.to_string();
        let display_name = manifest.get("displayName")?.as_str()?.to_string();
        let ui = manifest.get("ui");
        let tool_window_ids = ui
            .and_then(|ui| ui.get("toolWindows"))
            .and_then(Value::as_array)
            .map(|windows| {
                windows
                    .iter()
                    .filter_map(|window| window.get("id")?.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        let commands = ui
            .and_then(|ui| ui.get("commands"))
            .and_then(Value::as_array)
            .map(|commands| commands.iter().filter_map(parse_command).collect())
            .unwrap_or_default();
        Some(Self {
            plugin_id,
            display_name,
            enabled,
            accepted,
            tool_window_ids,
            commands,
        })
    }
}

fn parse_command(value: &Value) -> Option<PluginMenuCommandDeclaration> {
    let id = value.get("id")?.as_str()?.to_string();
    let title = value.get("title")?.as_str()?.to_string();
    let tool_window_id = value.get("toolWindowID")?.as_str()?.to_string();
    let placements = value
        .get("placements")
        .and_then(Value::as_array)
        .map(|placements| {
            placements
                .iter()
                .filter_map(|placement| {
                    placement
                        .as_str()
                        .and_then(PluginCommandPlacement::from_manifest_str)
                })
                .collect()
        })
        .unwrap_or_default();
    let order = value.get("order").and_then(Value::as_i64).unwrap_or(0) as i32;
    Some(PluginMenuCommandDeclaration {
        id,
        title,
        tool_window_id,
        placements,
        order,
    })
}

/// 一条插件命令为什么能或不能出现在菜单里。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PluginMenuAvailability {
    /// 插件已启用、已接受，且命令引用的工具窗真实存在。
    Available,
    /// 插件已被用户禁用。
    PluginDisabled,
    /// 插件包未通过校验，已被隔离。
    PluginRejected,
    /// 命令声明的工具窗不在该插件的工具窗列表中。
    MissingToolWindow,
}

/// 可以直接交给菜单 (Tools) 的投影条目。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginMenuEntry {
    /// 直接写入 [`MenuItemSpec::Action`] 的稳定命令 id。
    pub menu_command: SharedString,
    /// 契约 v1 的 `ui.commands[].id`。
    pub declaration_id: String,
    /// 菜单显示名。
    pub label: SharedString,
    /// 所属插件 id。
    pub plugin_id: String,
    /// 所属插件显示名。
    pub plugin_display_name: String,
    /// 命令打开的工具窗 id。
    pub tool_window_id: String,
    /// 启用条件；只有 [`PluginMenuAvailability::Available`] 可点击。
    pub availability: PluginMenuAvailability,
}

impl PluginMenuEntry {
    /// 是否满足全部启用条件。
    pub fn is_available(&self) -> bool {
        self.availability == PluginMenuAvailability::Available
    }
}

/// 已解析的插件命令执行目标。
///
/// 与 Tauri 的 `openDeclarativeWebWindow(pluginId, windowId)` 对齐：菜单只负责
/// 把命令还原成「哪个插件、哪个工具窗」，真正的窗口创建/聚焦仍由插件宿主桥接
/// 负责，本模块不创建任何窗口。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginCommandTarget {
    /// 所属插件 id。
    pub plugin_id: String,
    /// 所属插件显示名。
    pub plugin_display_name: String,
    /// 契约命令 id。
    pub declaration_id: String,
    /// 要打开或聚焦的工具窗 id。
    pub tool_window_id: String,
}

/// 把契约命令 id 包装成菜单派发 id。
pub fn menu_command_id(declaration_id: &str) -> SharedString {
    SharedString::from(format!("{PLUGIN_MENU_COMMAND_PREFIX}{declaration_id}"))
}

/// 从菜单派发 id 还原契约命令 id；不是插件命令时返回 `None`。
pub fn declaration_id_from_menu_command(command: &str) -> Option<&str> {
    command
        .strip_prefix(PLUGIN_MENU_COMMAND_PREFIX)
        .filter(|rest| !rest.is_empty())
}

/// 按 Tauri 语义投影全部声明了 `menu` placement 的命令。
///
/// 顺序是确定的：先按插件 id，再按命令 `(order, id)`。不可用的命令仍保留在
/// 结果里并带上原因，供菜单决定「灰掉」还是「不显示」；Tauri 本身在注册阶段
/// 就过滤掉不可用插件，所以 [`menu_items`] 只输出可用项。
pub fn project_menu_entries(sources: &[PluginMenuSource]) -> Vec<PluginMenuEntry> {
    let mut ordered: Vec<&PluginMenuSource> = sources.iter().collect();
    ordered.sort_by(|left, right| left.plugin_id.cmp(&right.plugin_id));

    let mut entries = Vec::new();
    for source in ordered {
        let mut commands: Vec<&PluginMenuCommandDeclaration> = source
            .commands
            .iter()
            .filter(|command| command.placements.contains(&PluginCommandPlacement::Menu))
            .collect();
        commands.sort_by(|left, right| (left.order, &left.id).cmp(&(right.order, &right.id)));

        for command in commands {
            let availability = if !source.accepted {
                PluginMenuAvailability::PluginRejected
            } else if !source.enabled {
                PluginMenuAvailability::PluginDisabled
            } else if !source
                .tool_window_ids
                .iter()
                .any(|window| window == &command.tool_window_id)
            {
                PluginMenuAvailability::MissingToolWindow
            } else {
                PluginMenuAvailability::Available
            };
            entries.push(PluginMenuEntry {
                menu_command: menu_command_id(&command.id),
                declaration_id: command.id.clone(),
                label: SharedString::from(command.title.clone()),
                plugin_id: source.plugin_id.clone(),
                plugin_display_name: source.display_name.clone(),
                tool_window_id: command.tool_window_id.clone(),
                availability,
            });
        }
    }
    entries
}

/// 把投影结果转成现有菜单声明；只输出可用项，与 Tauri 的注册过滤一致。
///
/// 复用 [`MenuItemSpec`]（底层是 gpui-kit `PopupMenu`），不另造菜单渲染。
pub fn menu_items(entries: &[PluginMenuEntry]) -> Vec<MenuItemSpec> {
    entries
        .iter()
        .filter(|entry| entry.is_available())
        .map(|entry| MenuItemSpec::Action {
            label: entry.label.clone(),
            command: entry.menu_command.clone(),
            shortcut: None,
            checked: false,
            disabled: false,
        })
        .collect()
}

/// 插件命令声明的工作台侧快照。
///
/// 工作台持有一个实例，插件扫描/启用状态变化时调用 [`Self::set_sources`]；
/// 返回 `true` 表示菜单内容需要重建（与 `MenuState::signature` 的缓存策略一致）。
#[derive(Default)]
pub struct PluginMenuRegistry {
    sources: Vec<PluginMenuSource>,
    entries: Vec<PluginMenuEntry>,
    revision: u64,
}

impl PluginMenuRegistry {
    /// 空注册表：没有插件命令，Tools 菜单保持固定项。
    pub fn new() -> Self {
        Self::default()
    }

    /// 用最新扫描结果替换快照；内容未变时返回 `false` 且不递增版本。
    pub fn set_sources(&mut self, sources: Vec<PluginMenuSource>) -> bool {
        if self.sources == sources {
            return false;
        }
        self.entries = project_menu_entries(&sources);
        self.sources = sources;
        self.revision = self.revision.wrapping_add(1);
        true
    }

    /// 当前快照。
    pub fn sources(&self) -> &[PluginMenuSource] {
        &self.sources
    }

    /// 全部 `menu` placement 的投影条目，含不可用项。
    pub fn entries(&self) -> &[PluginMenuEntry] {
        &self.entries
    }

    /// 直接追加到 Tools 菜单的菜单项（只含可用项）。
    pub fn items(&self) -> Vec<MenuItemSpec> {
        menu_items(&self.entries)
    }

    /// 快照版本号；变化即代表菜单需要重建。
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// 统一分发入口：把菜单命令 id 还原成插件命令目标。
    ///
    /// 不是插件命令、命令未声明 `menu`、或启用条件不满足时返回 `None`；
    /// 集成方应在 `Workbench::run_menu_command` 的最前面调用它，命中后走插件
    /// 宿主桥接打开工具窗，未命中则继续原有命令分发。
    pub fn resolve_menu_command(&self, command: &str) -> Option<PluginCommandTarget> {
        let declaration_id = declaration_id_from_menu_command(command)?;
        let entry = self
            .entries
            .iter()
            .find(|entry| entry.declaration_id == declaration_id)?;
        entry.is_available().then(|| PluginCommandTarget {
            plugin_id: entry.plugin_id.clone(),
            plugin_display_name: entry.plugin_display_name.clone(),
            declaration_id: entry.declaration_id.clone(),
            tool_window_id: entry.tool_window_id.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn manifest(commands: Value, windows: Value) -> Value {
        json!({
            "id": "hello-lithe",
            "displayName": "Hello Lithe",
            "ui": { "toolWindows": windows, "commands": commands }
        })
    }

    fn source(commands: Value, enabled: bool, accepted: bool) -> PluginMenuSource {
        PluginMenuSource::from_manifest(
            &manifest(commands, json!([{ "id": "hello-lithe.ui.welcome" }])),
            enabled,
            accepted,
        )
        .expect("manifest")
    }

    #[test]
    fn only_menu_placement_reaches_the_tools_menu() {
        let source = source(
            json!([
                {
                    "id": "hello-lithe.ui.welcome",
                    "title": "Welcome",
                    "toolWindowID": "hello-lithe.ui.welcome",
                    "placements": ["menu", "commandPalette"],
                    "order": 1
                },
                {
                    "id": "hello-lithe.ui.toolbar",
                    "title": "Toolbar only",
                    "toolWindowID": "hello-lithe.ui.welcome",
                    "placements": ["toolbar"]
                }
            ]),
            true,
            true,
        );

        let entries = project_menu_entries(&[source]);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].label.as_ref(), "Welcome");
        assert_eq!(
            entries[0].menu_command.as_ref(),
            "plugin.command.hello-lithe.ui.welcome"
        );
        assert_eq!(entries[0].availability, PluginMenuAvailability::Available);
    }

    #[test]
    fn unavailable_plugins_keep_a_reason_and_are_not_rendered() {
        let disabled = source(
            json!([{
                "id": "hello-lithe.ui.welcome",
                "title": "Welcome",
                "toolWindowID": "hello-lithe.ui.welcome",
                "placements": ["menu"]
            }]),
            false,
            true,
        );
        let entries = project_menu_entries(&[disabled]);
        assert_eq!(entries[0].availability, PluginMenuAvailability::PluginDisabled);
        assert!(menu_items(&entries).is_empty());
    }

    #[test]
    fn missing_tool_window_is_not_available() {
        let source = source(
            json!([{
                "id": "hello-lithe.ui.welcome",
                "title": "Welcome",
                "toolWindowID": "hello-lithe.ui.missing",
                "placements": ["menu"]
            }]),
            true,
            true,
        );
        let entries = project_menu_entries(&[source]);
        assert_eq!(entries[0].availability, PluginMenuAvailability::MissingToolWindow);
        assert!(menu_items(&entries).is_empty());
    }

    #[test]
    fn dispatch_resolution_round_trips_and_rejects_foreign_commands() {
        let mut registry = PluginMenuRegistry::new();
        assert!(registry.set_sources(vec![source(
            json!([{
                "id": "hello-lithe.ui.welcome",
                "title": "Welcome",
                "toolWindowID": "hello-lithe.ui.welcome",
                "placements": ["menu"]
            }]),
            true,
            true,
        )]));
        assert!(!registry.set_sources(registry.sources().to_vec()));

        let target = registry
            .resolve_menu_command("plugin.command.hello-lithe.ui.welcome")
            .expect("plugin command");
        assert_eq!(target.plugin_id, "hello-lithe");
        assert_eq!(target.tool_window_id, "hello-lithe.ui.welcome");

        assert!(registry.resolve_menu_command("file.save").is_none());
        assert!(registry.resolve_menu_command("plugin.command.unknown").is_none());
        assert_eq!(registry.items().len(), 1);
        assert_eq!(registry.revision(), 1);
    }

    #[test]
    fn unknown_placements_are_ignored_instead_of_dropping_the_command() {
        let source = source(
            json!([{
                "id": "hello-lithe.ui.welcome",
                "title": "Welcome",
                "toolWindowID": "hello-lithe.ui.welcome",
                "placements": ["menu", "future"]
            }]),
            true,
            true,
        );
        let entries = project_menu_entries(&[source]);
        assert_eq!(entries.len(), 1);
    }
}
