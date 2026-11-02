//! 键盘输入到 ANSI 字节序列的转换。
//!
//! 将 GPUI 的 `KeyDownEvent` 转换为终端 PTY 可以接收的字节流。

use gpui_kit::KeyDownEvent;

/// 将按键事件转换为要发送给 PTY 的字节序列。
pub fn to_pty_bytes(event: &KeyDownEvent) -> Option<Vec<u8>> {
    let keystroke = &event.keystroke;
    let key = keystroke.key.as_str();
    let modifiers = &keystroke.modifiers;

    // 1. 处理 Ctrl 组合键（如 Ctrl+C, Ctrl+D, Ctrl+Z, Ctrl+L 等）
    if modifiers.control && !modifiers.alt && !modifiers.platform {
        if key.len() == 1 {
            let ch = key.chars().next().unwrap();
            if ch.is_ascii_alphabetic() {
                // Ctrl+A = 1, Ctrl+Z = 26
                let code = (ch.to_ascii_uppercase() as u8).saturating_sub(0x40);
                return Some(vec![code]);
            }
        }
        match key {
            "@" | "`" | "2" => return Some(vec![0x00]),
            "[" | "3" => return Some(vec![0x1B]),
            "\\" | "4" => return Some(vec![0x1C]),
            "]" | "5" => return Some(vec![0x1D]),
            "^" | "6" => return Some(vec![0x1E]),
            "_" | "7" | "/" => return Some(vec![0x1F]),
            "?" | "8" => return Some(vec![0x7F]),
            _ => {}
        }
    }

    // 2. 特殊功能键
    match key {
        "enter" => return Some(vec![b'\r']),
        "backspace" => return Some(vec![0x7F]),
        "tab" => {
            if modifiers.shift {
                return Some(b"\x1b[Z".to_vec());
            } else {
                return Some(vec![b'\t']);
            }
        }
        "escape" => return Some(vec![0x1B]),
        "up" => return Some(b"\x1b[A".to_vec()),
        "down" => return Some(b"\x1b[B".to_vec()),
        "right" => return Some(b"\x1b[C".to_vec()),
        "left" => return Some(b"\x1b[D".to_vec()),
        "home" => return Some(b"\x1b[H".to_vec()),
        "end" => return Some(b"\x1b[F".to_vec()),
        "pageup" => return Some(b"\x1b[5~".to_vec()),
        "pagedown" => return Some(b"\x1b[6~".to_vec()),
        "insert" => return Some(b"\x1b[2~".to_vec()),
        "delete" => return Some(b"\x1b[3~".to_vec()),
        "f1" => return Some(b"\x1bOP".to_vec()),
        "f2" => return Some(b"\x1bOQ".to_vec()),
        "f3" => return Some(b"\x1bOR".to_vec()),
        "f4" => return Some(b"\x1bOS".to_vec()),
        "f5" => return Some(b"\x1b[15~".to_vec()),
        "f6" => return Some(b"\x1b[17~".to_vec()),
        "f7" => return Some(b"\x1b[18~".to_vec()),
        "f8" => return Some(b"\x1b[19~".to_vec()),
        "f9" => return Some(b"\x1b[20~".to_vec()),
        "f10" => return Some(b"\x1b[21~".to_vec()),
        "f11" => return Some(b"\x1b[23~".to_vec()),
        "f12" => return Some(b"\x1b[24~".to_vec()),
        "space" => return Some(vec![b' ']),
        _ => {}
    }

    // 3. 常规字符输入（排除单独按修饰键如 shift/ctrl/alt/cmd）
    if modifiers.control || modifiers.platform {
        return None;
    }

    if let Some(key_char) = &keystroke.key_char {
        if !key_char.is_empty() {
            return Some(key_char.as_bytes().to_vec());
        }
    }

    if key.chars().count() == 1 {
        return Some(key.as_bytes().to_vec());
    }

    None
}
