//! LSP 诊断到 Problems 面板的转换。
//!
//! Core 的 `lsp.pollEvents` 把 JDT 的 `publishDiagnostics` 原样转成
//! `{type:"diagnostics", uri, diagnostics:[...]}`；这里只做三件事：URI 转本地
//! 路径、严重级别换成本面板的位掩码、行列号换成 1 基。界面与 IPC 都不参与。

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::editor::DiagnosticItem;

// Problems 面板的严重级别是位掩码：`status.rs` 用 `severity & 8` 判断错误、
// `severity & 4` 判断警告，因此这里不能直接沿用 LSP 的 1/2/3/4。
pub(crate) const SEVERITY_ERROR: u8 = 8;
pub(crate) const SEVERITY_WARNING: u8 = 4;
pub(crate) const SEVERITY_INFO: u8 = 2;
pub(crate) const SEVERITY_HINT: u8 = 1;

/// 解析一条 Core `diagnostics` 事件；URI 无法转成本地路径时返回 `None`。
///
/// 空诊断数组是合法事件：它表示这个文件的旧诊断应该被清除。
pub(crate) fn diagnostics_event(event: &Value) -> Option<(PathBuf, Vec<DiagnosticItem>)> {
    let uri = event.get("uri").and_then(Value::as_str)?;
    let path = document_path(uri)?;
    let items = event
        .get("diagnostics")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| diagnostic_item(&path, item))
                .collect()
        })
        .unwrap_or_default();
    Some((path, items))
}

/// 把一条 LSP 诊断转成 Problems 面板的条目；行号与列号都从 0 基换成 1 基。
fn diagnostic_item(path: &Path, item: &Value) -> Option<DiagnosticItem> {
    let line = item.pointer("/range/start/line").and_then(Value::as_u64)?;
    let column = item
        .pointer("/range/start/character")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    Some(DiagnosticItem {
        path: path.to_path_buf(),
        severity: panel_severity(item.get("severity").and_then(Value::as_i64)),
        message: item
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        line: u32::try_from(line).unwrap_or(u32::MAX).saturating_add(1),
        column: u32::try_from(column)
            .unwrap_or(u32::MAX)
            .saturating_add(1),
        source: item
            .get("source")
            .and_then(Value::as_str)
            .filter(|source| !source.is_empty())
            .map(str::to_string),
    })
}

/// LSP 的 `DiagnosticSeverity`（1..=4）转成面板位掩码。
///
/// 缺省级别按 LSP 语义视为错误，与编辑器现有渲染保持一致。
fn panel_severity(severity: Option<i64>) -> u8 {
    match severity {
        Some(2) => SEVERITY_WARNING,
        Some(3) => SEVERITY_INFO,
        Some(4) => SEVERITY_HINT,
        _ => SEVERITY_ERROR,
    }
}

/// 把 `file:` URI 转成本地路径。
///
/// 只接受 file 方案；`file:///C:/a/b.java` 在 Windows 上还原成盘符路径，
/// `file:///home/u/b.java` 保持 POSIX 形式。JDT 会对空格、中文等字符做
/// 百分号编码，这里统一解码。
fn document_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file:")?;
    let text = match rest.strip_prefix("//") {
        Some(without_slashes) => match without_slashes.find('/') {
            Some(index) => {
                let authority = &without_slashes[..index];
                let path = &without_slashes[index..];
                if authority.is_empty() || authority.eq_ignore_ascii_case("localhost") {
                    path.to_string()
                } else if is_drive(authority) {
                    // `file://C:/...`：第二条斜杠后直接是盘符，整段都算路径。
                    without_slashes.to_string()
                } else {
                    // Windows UNC：`file://server/share/a.java` → `\\server\share\a.java`
                    format!("//{authority}{path}")
                }
            }
            // `file://C:/...`：JDT 偶尔省略第三条斜杠。
            None => without_slashes.to_string(),
        },
        // 非 authority 形式（`file:/C:/...`）按路径处理。
        None => rest.to_string(),
    };
    // `file:/C:/...`：只剩一条斜杠时，Windows 盘符前多出的根斜杠要去掉。
    let trimmed = text
        .strip_prefix('/')
        .filter(|without_root| is_windows_path(without_root))
        .map(str::to_string);
    let text = trimmed.unwrap_or(text);
    let decoded = percent_decode(&text);
    if decoded.is_empty() {
        return None;
    }
    Some(local_path(&decoded))
}

/// 解码 URI 的百分号转义；非法转义按原样保留。
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                decoded.push(high * 16 + low);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// URI 路径落成本地路径：Windows 盘符/UNC 统一反斜杠，盘符统一大写，
/// 这样与工作区根做 `strip_prefix` 比较时不会因大小写或分隔符失配。
fn local_path(text: &str) -> PathBuf {
    let text = uppercase_drive(text);
    if cfg!(windows) && is_windows_path(&text) {
        PathBuf::from(text.replace('/', "\\"))
    } else {
        PathBuf::from(text)
    }
}

fn is_drive(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

fn is_windows_path(text: &str) -> bool {
    let bytes = text.as_bytes();
    let drive = bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'/' || bytes[2] == b'\\');
    drive || text.starts_with("//")
}

fn uppercase_drive(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) if first.is_ascii_lowercase() && text.as_bytes().get(1) == Some(&b':') => {
            format!("{}{}", first.to_ascii_uppercase(), chars.as_str())
        }
        _ => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn converts_windows_file_uri_with_space_and_chinese() {
        let path =
            document_path("file:///C:/Users/momo/%E6%B5%8B%E8%AF%95%20dir/A.java").unwrap();
        // `%E6%B5%8B%E8%AF%95` 是「测试」，`%20` 是空格。
        #[cfg(windows)]
        assert_eq!(path.to_string_lossy(), r"C:\Users\momo\测试 dir\A.java");
        #[cfg(not(windows))]
        assert_eq!(path.to_string_lossy(), "C:/Users/momo/测试 dir/A.java");
    }

    #[test]
    fn converts_posix_file_uri() {
        let path = document_path("file:///home/momo/my%20project/A.java").unwrap();
        assert_eq!(path.to_string_lossy(), "/home/momo/my project/A.java");
    }

    #[test]
    fn normalizes_drive_letter_and_accepts_localhost() {
        #[cfg(windows)]
        assert_eq!(
            document_path("file:///d:/repo/a.java")
                .unwrap()
                .to_string_lossy(),
            r"D:\repo\a.java"
        );
        #[cfg(not(windows))]
        assert_eq!(
            document_path("file:///d:/repo/a.java")
                .unwrap()
                .to_string_lossy(),
            "D:/repo/a.java"
        );
        assert_eq!(
            document_path("file://localhost/home/a.java")
                .unwrap()
                .to_string_lossy(),
            "/home/a.java"
        );
    }

    #[test]
    fn accepts_file_uris_with_a_missing_slash() {
        // JDT 偶尔只写两条斜杠，盘符会被误当成 URI authority。
        #[cfg(windows)]
        assert_eq!(
            document_path("file://C:/repo/a.java")
                .unwrap()
                .to_string_lossy(),
            r"C:\repo\a.java"
        );
        #[cfg(not(windows))]
        assert_eq!(
            document_path("file://C:/repo/a.java")
                .unwrap()
                .to_string_lossy(),
            "C:/repo/a.java"
        );
        #[cfg(windows)]
        assert_eq!(
            document_path("file:///C:/repo/a.java")
                .unwrap()
                .to_string_lossy(),
            r"C:\repo\a.java"
        );
    }

    #[test]
    fn rejects_non_file_uris_and_empty_paths() {
        assert!(document_path("https://example.com/A.java").is_none());
        assert!(document_path("untitled:Untitled-1").is_none());
        assert!(document_path("file://").is_none());
    }

    #[test]
    fn keeps_malformed_percent_escapes() {
        assert_eq!(percent_decode("a%zz%2"), "a%zz%2");
        assert_eq!(percent_decode("a%2Fb"), "a/b");
    }

    #[test]
    fn maps_lsp_severity_to_panel_bits() {
        assert_eq!(panel_severity(Some(1)), SEVERITY_ERROR);
        assert_eq!(panel_severity(Some(2)), SEVERITY_WARNING);
        assert_eq!(panel_severity(Some(3)), SEVERITY_INFO);
        assert_eq!(panel_severity(Some(4)), SEVERITY_HINT);
        assert_eq!(panel_severity(None), SEVERITY_ERROR);
    }

    #[test]
    fn parses_diagnostics_with_one_based_positions() {
        let event = json!({
            "type": "diagnostics",
            "uri": "file:///C:/repo/src/Main.java",
            "diagnostics": [
                {
                    "range": { "start": { "line": 11, "character": 4 } },
                    "severity": 1,
                    "message": "cannot find symbol",
                    "source": "Java",
                    "code": "100"
                },
                {
                    "range": { "start": { "line": 0, "character": 0 } },
                    "severity": 2,
                    "message": "unused import"
                }
            ]
        });
        let (path, items) = diagnostics_event(&event).unwrap();
        assert!(path.ends_with("Main.java"));
        assert_eq!(items.len(), 2);
        assert_eq!((items[0].line, items[0].column), (12, 5));
        assert_eq!(items[0].severity, SEVERITY_ERROR);
        assert_eq!(items[0].source.as_deref(), Some("Java"));
        assert_eq!(items[0].path, path);
        assert_eq!(items[1].severity, SEVERITY_WARNING);
        assert_eq!(items[1].source, None);
    }

    #[test]
    fn empty_diagnostics_keeps_the_file_path_for_clearing() {
        let event = json!({
            "type": "diagnostics",
            "uri": "file:///C:/repo/src/Main.java",
            "diagnostics": []
        });
        let (path, items) = diagnostics_event(&event).unwrap();
        assert!(path.ends_with("Main.java"));
        assert!(items.is_empty());
    }

    #[test]
    fn skips_items_without_a_range() {
        let event = json!({
            "type": "diagnostics",
            "uri": "file:///C:/repo/src/Main.java",
            "diagnostics": [{ "severity": 1, "message": "no range" }]
        });
        let (_, items) = diagnostics_event(&event).unwrap();
        assert!(items.is_empty());
    }
}
