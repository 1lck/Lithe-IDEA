//! 菜单和工具栏里的快捷键文案。
//!
//! 菜单数据层沿用 macOS 的符号写法（例如 `⇧⌘W`）。Windows / Linux 的界面
//! 字体没有这些字形，直接绘制会变成缺字方框，看起来像一排小图标；这里按
//! Tauri `Keybinding` 组件的规则转换成 `Ctrl+Shift+W`。macOS 保持符号不变。

use gpui_kit::SharedString;

/// 把 macOS 风格的快捷键文案转换成当前平台显示。
pub fn display_shortcut(shortcut: &'static str) -> SharedString {
    if cfg!(target_os = "macos") {
        return shortcut.into();
    }

    // 空格分隔多个和弦，例如 `⌘K ⌘I`。
    let mut chords: Vec<String> = Vec::new();
    for chord in shortcut.split_whitespace() {
        let mut modifiers: Vec<&str> = Vec::new();
        let mut key = String::new();

        for character in chord.chars() {
            match character {
                '⌘' | '⌃' => modifiers.push("Ctrl"),
                '⌥' => modifiers.push("Alt"),
                '⇧' => modifiers.push("Shift"),
                _ => key.push(character),
            }
        }

        let mut parts: Vec<String> = Vec::new();
        // 顺序与 Tauri 的 Keybinding 输出一致：Ctrl、Alt、Shift，最后是按键。
        for modifier in ["Ctrl", "Alt", "Shift"] {
            if modifiers.contains(&modifier) {
                parts.push(modifier.to_string());
            }
        }

        if !key.is_empty() {
            let key = match key.as_str() {
                "↑" => "Up",
                "↓" => "Down",
                "←" => "Left",
                "→" => "Right",
                other => other,
            };
            let key = if key.chars().count() == 1 {
                key.to_uppercase()
            } else {
                key.to_string()
            };
            parts.push(key);
        }

        chords.push(parts.join("+"));
    }

    chords.join(" ").into()
}
