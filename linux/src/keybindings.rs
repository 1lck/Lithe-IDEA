//! 快捷键真源：把「按键 → 动作 id」集中成一张表，供按键分发与菜单展示共用。
//!
//! 背景（对齐 Tauri `features/keymaps`）：Tauri 侧以 `defaultKeymaps` 为唯一真源，
//! 菜单项从注册表读取展示文本，按键事件也从同一张表解析动作，两者不会漂移。
//! Linux 侧原先把快捷键硬编码在 `view.rs` 的 `on_key_down` 里，又另在
//! `toolbar.rs` 的菜单表写一遍展示文本，存在两处真源。
//!
//! 本模块把「菜单表已有的快捷键展示文本」作为唯一输入，编译期生成按键索引，
//! 因此新增菜单项时：只要菜单写了快捷键，按键就自动生效，不需要改两份代码。
//!
//! 不变量：
//! - 同一个按键序列在本表中最多映射一个动作 id；
//! - 动作 id 必须能在 `WorkbenchView::handle_action` 找到分支，否则视为无效绑定；
//! - 双击 Shift 不是普通按键绑定（需要跨事件计时），单独由
//!   [`DoubleShiftRecognizer`] 处理，见 `view.rs` 的按键监听。

use std::collections::HashMap;

use crate::workbench::toolbar::menu_shortcut_entries;

/// 双击 Shift 触发全局搜索的时间窗（秒）。
///
/// 对齐 Tauri `DOUBLE_SHIFT_THRESHOLD_SECONDS`（IntelliJ 同款手势）。
pub const DOUBLE_SHIFT_THRESHOLD_SECONDS: f64 = 0.35;

/// 双击 Shift 对应的动作 id（Tauri `searchEverywhere`）。
pub const DOUBLE_SHIFT_ACTION: &str = "view.global_search";

/// 一条按键绑定：展示用快捷键文本 + 目标动作 id。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeymapEntry {
    /// 菜单里展示的写法（如 `Ctrl+Shift+P`），也是解析输入。
    pub shortcut: &'static str,
    /// 稳定动作 id，与 `WorkbenchView::handle_action` 的分支一致。
    pub action: &'static str,
}

/// 全局快捷键表，由菜单表派生，保证「菜单显示什么键，什么键就生效」。
pub fn default_keymap() -> Vec<KeymapEntry> {
    menu_shortcut_entries()
        .iter()
        .map(|(shortcut, action)| KeymapEntry { shortcut, action })
        .collect()
}

/// 解析后的按键索引：归一化按键序列 → 动作 id。
///
/// GPUI 侧查表用 [`KeyStrokeId`]，避免每次按键都做字符串拼接。
pub struct KeymapIndex {
    by_id: HashMap<KeyStrokeId, &'static str>,
    /// 无法解析的展示文本（应当为空；保留用于诊断与测试断言）。
    invalid: Vec<&'static str>,
}

impl KeymapIndex {
    /// 从 [`default_keymap`] 构建索引。
    pub fn build() -> Self {
        let mut by_id = HashMap::new();
        let mut invalid = Vec::new();
        for entry in default_keymap() {
            match KeyStrokeId::parse(entry.shortcut) {
                Some(id) => {
                    // 冲突时保留先出现的绑定，并按菜单顺序稳定覆盖：
                    // 菜单表本身若有重复键，后写会覆盖先写，这里显式记录。
                    by_id.insert(id, entry.action);
                }
                None => invalid.push(entry.shortcut),
            }
        }
        Self { by_id, invalid }
    }

    /// 精确查表：修饰键与主键完全一致才算命中。
    pub fn lookup(&self, id: &KeyStrokeId) -> Option<&'static str> {
        self.by_id.get(id).copied()
    }

    /// 解析失败的展示文本（用于测试）。
    pub fn invalid_shortcuts(&self) -> &[&'static str] {
        &self.invalid
    }

    /// 已生效的绑定数量（用于测试）。
    pub fn len(&self) -> usize {
        self.by_id.len()
    }

    /// 是否为空表。
    pub fn is_empty(&self) -> bool {
        self.by_id.is_empty()
    }
}

/// 归一化按键标识：修饰键集合 + 归一化主键名。
///
/// GPUI 的 `Keystroke.key` 对字母是小写、对符号是字面符号（如 `=`、`/`、`` ` ``），
/// 而菜单展示文本用 `Ctrl+=` 这类可读写法。这里把两侧都归一到同一形式。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyStrokeId {
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    pub platform: bool,
    /// 归一化主键：字母小写，`+`/`=`/`-` 等符号原样，功能键小写（`f11`）。
    pub key: String,
}

impl KeyStrokeId {
    /// 从菜单展示文本解析（如 `Ctrl+Shift+P`、`Alt+Up`、`F11`、`Ctrl+/`）。
    ///
    /// 无法识别时返回 `None`，由调用方归入 `invalid` 报告。
    pub fn parse(shortcut: &str) -> Option<Self> {
        let trimmed = shortcut.trim();
        if trimmed.is_empty() {
            return None;
        }
        let mut control = false;
        let mut alt = false;
        let mut shift = false;
        let mut platform = false;
        let mut key: Option<String> = None;

        for part in trimmed.split('+') {
            if part.is_empty() {
                // `Ctrl++`（加号本身）在菜单里写成 `Ctrl+=`，因此空段非法。
                return None;
            }
            match part {
                "Ctrl" | "Control" | "CmdOrCtrl" => control = true,
                "Alt" | "Option" => alt = true,
                "Shift" => shift = true,
                "Meta" | "Cmd" | "Command" | "Super" | "Win" => platform = true,
                other => {
                    if key.is_some() {
                        // 多主键（含空格分段的序列）不由本表表达。
                        return None;
                    }
                    key = Some(normalize_key(other));
                }
            }
        }

        let key = key?;
        Some(Self {
            control,
            alt,
            shift,
            platform,
            key,
        })
    }

    /// 从 GPUI `KeyDownEvent` 的按键与修饰键状态构建。
    pub fn from_event(key: &str, modifiers: &gpui_kit::Modifiers) -> Self {
        Self {
            control: modifiers.control,
            alt: modifiers.alt,
            shift: modifiers.shift,
            platform: modifiers.platform,
            key: normalize_key(key),
        }
    }
}

/// 主键名归一化：字母统一小写，其余原样；并把菜单里的可读名映射到 GPUI 名。
fn normalize_key(key: &str) -> String {
    match key {
        "Up" => "up".to_string(),
        "Down" => "down".to_string(),
        "Left" => "left".to_string(),
        "Right" => "right".to_string(),
        "Enter" | "Return" => "enter".to_string(),
        "Esc" | "Escape" => "escape".to_string(),
        "Space" => "space".to_string(),
        "Tab" => "tab".to_string(),
        "Backspace" => "backspace".to_string(),
        "Delete" => "delete".to_string(),
        "Home" => "home".to_string(),
        "End" => "end".to_string(),
        "PageUp" => "pageup".to_string(),
        "PageDown" => "pagedown".to_string(),
        "`" | "~" => "`".to_string(),
        "=" | "+" => "=".to_string(),
        "-" | "_" => "-".to_string(),
        other => other.to_ascii_lowercase(),
    }
}

/// 双击 Shift 手势识别器：移植 Tauri `DoubleShiftGestureRecognizer`。
///
/// 语义与 Tauri 一致：
/// - 只统计「独立按下 Shift」（按下时没有 Ctrl/Alt/Meta 同时按下）；
/// - 两次独立 Shift 抬起的时间差落在 [`DOUBLE_SHIFT_THRESHOLD_SECONDS`] 内才算双击；
/// - 期间出现其它按键或非 Shift 修饰键会取消手势，避免误触。
///
/// 时间戳由调用方提供（GPUI 事件不带时间，`view.rs` 用 `Instant`）。
#[derive(Debug, Default)]
pub struct DoubleShiftRecognizer {
    shift_was_down: bool,
    current_press_is_standalone: bool,
    last_standalone_tap: Option<f64>,
}

impl DoubleShiftRecognizer {
    /// 新建识别器。
    pub fn new() -> Self {
        Self::default()
    }

    /// 普通按键按下：当前 Shift 按压不再算「独立」。
    pub fn handle_key_down(&mut self) {
        self.current_press_is_standalone = false;
        self.last_standalone_tap = None;
    }

    /// 焦点切换/窗口失焦等场景重置，避免跨上下文的两次 Shift 被拼接。
    pub fn reset(&mut self) {
        self.shift_was_down = false;
        self.current_press_is_standalone = false;
        self.last_standalone_tap = None;
    }

    /// 修饰键状态变化。返回 `true` 表示识别到双击 Shift。
    ///
    /// - `is_shift_down`：当前 Shift 是否按下；
    /// - `has_other_modifiers`：是否有 Ctrl/Alt/Meta 同时按下；
    /// - `timestamp`：秒级单调时间。
    pub fn handle_modifiers_changed(
        &mut self,
        is_shift_down: bool,
        has_other_modifiers: bool,
        timestamp: f64,
    ) -> bool {
        if is_shift_down && !self.shift_was_down {
            self.current_press_is_standalone = !has_other_modifiers;
            self.shift_was_down = true;
            return false;
        }

        if is_shift_down && self.shift_was_down {
            if has_other_modifiers {
                self.current_press_is_standalone = false;
                self.last_standalone_tap = None;
            }
            return false;
        }

        if !is_shift_down && self.shift_was_down {
            self.shift_was_down = false;
            let was_standalone = self.current_press_is_standalone;
            self.current_press_is_standalone = false;
            if !was_standalone || has_other_modifiers {
                self.last_standalone_tap = None;
                return false;
            }
            if let Some(last) = self.last_standalone_tap {
                let delta = timestamp - last;
                if delta >= 0.0 && delta < DOUBLE_SHIFT_THRESHOLD_SECONDS {
                    self.last_standalone_tap = None;
                    return true;
                }
            }
            self.last_standalone_tap = Some(timestamp);
            return false;
        }

        if has_other_modifiers {
            self.last_standalone_tap = None;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_menu_shortcuts() {
        let id = KeyStrokeId::parse("Ctrl+Shift+P").expect("parse");
        assert!(id.control && id.shift && !id.alt && !id.platform);
        assert_eq!(id.key, "p");

        let id = KeyStrokeId::parse("Alt+Up").expect("parse");
        assert!(id.alt);
        assert_eq!(id.key, "up");

        let id = KeyStrokeId::parse("F11").expect("parse");
        assert!(!id.control && id.key == "f11");

        let id = KeyStrokeId::parse("Ctrl+/").expect("parse");
        assert_eq!(id.key, "/");

        let id = KeyStrokeId::parse("Ctrl+=").expect("parse");
        assert_eq!(id.key, "=");
    }

    #[test]
    fn rejects_invalid_shortcuts() {
        assert!(KeyStrokeId::parse("").is_none());
        assert!(KeyStrokeId::parse("Ctrl+A+B").is_none());
        assert!(KeyStrokeId::parse("Ctrl+").is_none());
    }

    #[test]
    fn keymap_only_surfaces_menu_shortcuts() {
        let index = KeymapIndex::build();
        assert!(
            index.invalid_shortcuts().is_empty(),
            "菜单快捷键存在无法解析的写法: {:?}",
            index.invalid_shortcuts()
        );
        assert!(!index.is_empty());
    }

    #[test]
    fn keymap_lookup_matches_menu_labels() {
        let index = KeymapIndex::build();
        let id = KeyStrokeId::parse("Ctrl+Shift+P").expect("parse");
        assert_eq!(index.lookup(&id), Some("view.command_palette"));

        let id = KeyStrokeId::parse("Ctrl+P").expect("parse");
        assert_eq!(index.lookup(&id), Some("view.quick_open"));

        let id = KeyStrokeId::parse("Ctrl+B").expect("parse");
        assert_eq!(index.lookup(&id), Some("view.toggle_activity_rail"));

        let id = KeyStrokeId::parse("Ctrl+E").expect("parse");
        assert_eq!(index.lookup(&id), Some("view.toggle_sidebar"));

        let id = KeyStrokeId::parse("Ctrl+Shift+F").expect("parse");
        assert_eq!(index.lookup(&id), Some("view.global_search"));

        let id = KeyStrokeId::parse("Alt+Z").expect("parse");
        assert_eq!(index.lookup(&id), Some("view.toggle_wrap"));

        let id = KeyStrokeId::parse("Ctrl+/ ").expect("parse");
        assert_eq!(index.lookup(&id), Some("edit.toggle_comment"));

        let id = KeyStrokeId::parse("Ctrl+T").expect("parse");
        assert_eq!(index.lookup(&id), Some("file.new_tab"));

        let id = KeyStrokeId::parse("Ctrl+W").expect("parse");
        assert_eq!(index.lookup(&id), Some("file.close_editor"));

        let id = KeyStrokeId::parse("F11").expect("parse");
        assert_eq!(index.lookup(&id), Some("window.fullscreen"));
    }

    #[test]
    fn disabled_menu_shortcuts_are_not_bound() {
        let index = KeymapIndex::build();
        // `go.references`（禁用）与 `view.toggle_activity_rail` 共用 Ctrl+B：
        // 禁用项不得抢走可用项的按键。
        let id = KeyStrokeId::parse("Ctrl+B").expect("parse");
        assert_ne!(index.lookup(&id), Some("go.references"));
        // F5/F9 等调试快捷键后端未接入，不应绑定。
        assert_eq!(index.lookup(&KeyStrokeId::parse("F5").expect("parse")), None);
        assert_eq!(index.lookup(&KeyStrokeId::parse("F9").expect("parse")), None);
    }

    #[test]
    fn double_shift_action_targets_global_search() {
        assert_eq!(DOUBLE_SHIFT_ACTION, "view.global_search");
    }

    #[test]
    fn double_shift_triggers_within_threshold() {
        let mut r = DoubleShiftRecognizer::new();
        // 按下不触发，只有第二次独立 Shift 抬起且间隔在窗口内才触发。
        assert!(!r.handle_modifiers_changed(true, false, 1.0));
        assert!(!r.handle_modifiers_changed(false, false, 1.05));
        assert!(!r.handle_modifiers_changed(true, false, 1.1));
        assert!(r.handle_modifiers_changed(false, false, 1.2));
    }

    #[test]
    fn double_shift_ignores_slow_taps() {
        let mut r = DoubleShiftRecognizer::new();
        assert!(!r.handle_modifiers_changed(true, false, 1.0));
        assert!(!r.handle_modifiers_changed(false, false, 1.05));
        assert!(!r.handle_modifiers_changed(true, false, 2.0));
        assert!(!r.handle_modifiers_changed(false, false, 2.1));
    }

    #[test]
    fn double_shift_cancelled_by_other_keys() {
        let mut r = DoubleShiftRecognizer::new();
        assert!(!r.handle_modifiers_changed(true, false, 1.0));
        assert!(!r.handle_modifiers_changed(false, false, 1.05));
        // 中间敲了别的键，第二次 Shift 不应触发。
        r.handle_key_down();
        assert!(!r.handle_modifiers_changed(true, false, 1.1));
        assert!(!r.handle_modifiers_changed(false, false, 1.15));
    }

    #[test]
    fn double_shift_cancelled_by_other_modifiers() {
        let mut r = DoubleShiftRecognizer::new();
        assert!(!r.handle_modifiers_changed(true, false, 1.0));
        assert!(!r.handle_modifiers_changed(false, false, 1.05));
        // Shift 与 Ctrl 同按不算独立 Shift。
        assert!(!r.handle_modifiers_changed(true, true, 1.1));
        assert!(!r.handle_modifiers_changed(false, true, 1.15));
    }
}
