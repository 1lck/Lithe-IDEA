//! Linux 端 LSP 接线：把编辑器文档同步给 Core 管理的语言服务器，并把
//! `lsp.pollEvents` 返回的诊断映射到诊断面板。
//!
//! Core 拥有进程、JSON-RPC framing、生命周期和诊断状态；本模块只做
//! 平台侧的语言/可执行文件探测、路径与 URI 规范化，以及事件投影。

use std::collections::HashMap;

use serde_json::{json, Value};

use crate::workbench::bottom_panel::DiagnosticEntry;

/// 一个可在本机通过 PATH 启动的语言服务器定义。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LanguageProvider {
    /// 与 Core `providerId` 一致的稳定标识。
    pub id: &'static str,
    /// PATH 中查找的可执行文件名。
    pub executable: &'static str,
    /// 以 stdio 启动服务器所需的固定参数。
    pub arguments: &'static [&'static str],
    /// 对应文件扩展名的 LSP `languageId` 前缀。
    pub language_id: &'static str,
    /// 扩展名匹配集合，全部小写且不含点。
    pub extensions: &'static [&'static str],
}

const RUST_ANALYZER: LanguageProvider = LanguageProvider {
    id: "rust-analyzer",
    executable: "rust-analyzer",
    arguments: &[],
    language_id: "rust",
    extensions: &["rs"],
};

const CLANGD: LanguageProvider = LanguageProvider {
    id: "clangd",
    executable: "clangd",
    arguments: &[],
    language_id: "c",
    extensions: &["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx"],
};

const PYRIGHT: LanguageProvider = LanguageProvider {
    id: "pyright",
    executable: "pyright-langserver",
    arguments: &["--stdio"],
    language_id: "python",
    extensions: &["py", "pyi"],
};

const TYPESCRIPT: LanguageProvider = LanguageProvider {
    id: "typescript-language-server",
    executable: "typescript-language-server",
    arguments: &["--stdio"],
    language_id: "typescript",
    extensions: &["ts", "tsx", "js", "jsx", "mjs", "cjs"],
};

const GOPLS: LanguageProvider = LanguageProvider {
    id: "gopls",
    executable: "gopls",
    arguments: &[],
    language_id: "go",
    extensions: &["go"],
};

const JDTLS: LanguageProvider = LanguageProvider {
    id: "jdtls",
    executable: "jdtls",
    arguments: &[],
    language_id: "java",
    extensions: &["java"],
};

const PROVIDERS: &[LanguageProvider] = &[RUST_ANALYZER, CLANGD, PYRIGHT, TYPESCRIPT, GOPLS, JDTLS];

/// 按文件扩展名选择语言服务器；未知扩展名返回 `None`。
pub fn provider_for_path(path: &str) -> Option<LanguageProvider> {
    let extension = file_extension(path)?;
    PROVIDERS
        .iter()
        .copied()
        .find(|provider| provider.extensions.contains(&extension.as_str()))
}

fn file_extension(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
}

/// provider 的默认 `languageId` 对同族扩展名需要细分，例如 clangd 的 C/C++
/// 与 typescript-language-server 的 TS/JS 使用不同的语言标识。
pub fn language_id_for_path(path: &str, provider: LanguageProvider) -> &'static str {
    let extension = file_extension(path).unwrap_or_default();
    match provider.id {
        "clangd" => match extension.as_str() {
            "cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx" => "cpp",
            _ => "c",
        },
        "typescript-language-server" => match extension.as_str() {
            "js" | "jsx" | "mjs" | "cjs" => "javascript",
            _ => "typescript",
        },
        _ => provider.language_id,
    }
}

/// 在 `PATH` 中查找可执行文件；只返回可执行且存在的绝对路径。
pub fn find_in_path(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if !candidate.is_file() {
            continue;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let executable = std::fs::metadata(&candidate)
                .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
                .unwrap_or(false);
            if !executable {
                continue;
            }
        }
        return Some(candidate.to_string_lossy().into_owned());
    }
    None
}

/// 把相对工作区路径解析成绝对路径；已经是绝对路径时原样返回。
pub fn absolute_path(root: &str, path: &str) -> String {
    let candidate = std::path::Path::new(path);
    if candidate.is_absolute() {
        path.to_string()
    } else {
        std::path::Path::new(root)
            .join(path)
            .to_string_lossy()
            .replace('\\', "/")
    }
}

/// 构造 LSP `file://` URI，保留 `/`，其余字节做百分号编码。
pub fn file_uri(root: &str, path: &str) -> String {
    let absolute = absolute_path(root, path);
    let mut encoded = String::with_capacity(absolute.len() + 8);
    for byte in absolute.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(byte as char)
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    format!("file://{encoded}")
}

/// 把 LSP `file://` URI 映射回工作区相对路径；工作区外返回 `None`。
pub fn workspace_relative_path(root: &str, uri: &str) -> Option<String> {
    let encoded = uri.strip_prefix("file://")?;
    let decoded = percent_decode(encoded);
    let root = root.replace('\\', "/");
    let root = root.trim_end_matches('/');
    let decoded = decoded.replace('\\', "/");
    if decoded == root {
        return Some(String::new());
    }
    decoded
        .strip_prefix(&format!("{root}/"))
        .map(|value| value.to_string())
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(byte) = hex.and_then(|value| u8::from_str_radix(value, 16).ok()) {
                decoded.push(byte);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// 当前语言服务器可用性；不可用时返回空。
pub fn resolve_provider(path: &str) -> Option<(LanguageProvider, String)> {
    let provider = provider_for_path(path)?;
    let executable = find_in_path(provider.executable)?;
    Some((provider, executable))
}

/// `lsp.startServer` 的最小有效载荷。平台只提供进程与工作区信息，
/// 初始化参数与工作区指纹由 Core 的 provider 适配层负责。
pub fn start_payload(
    provider: LanguageProvider,
    executable: &str,
    root: &str,
    cache_directory: &str,
) -> Value {
    let mut arguments: Vec<String> = provider
        .arguments
        .iter()
        .map(|value| value.to_string())
        .collect();
    if provider.id == "jdtls" {
        // jdtls 要求显式 data 目录；configuration 目录由发行包脚本补齐。
        arguments.push("-data".to_string());
        arguments.push(cache_directory.to_string());
    }
    json!({
        "providerId": provider.id,
        "executablePath": executable,
        "arguments": arguments,
        "rootUri": file_uri(root, root),
        "workingDirectory": absolute_path(root, root),
        "initializeTimeoutMilliseconds": 30_000,
        "requestTimeoutMilliseconds": 30_000,
        "shutdownTimeoutMilliseconds": 2_000,
        "cacheDirectory": cache_directory,
    })
}

pub fn parse_session_id(value: &Value) -> Option<String> {
    value
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_string)
}

pub fn sync_payload(session_id: &str, uri: &str, language_id: &str, text: &str) -> Value {
    json!({
        "sessionId": session_id,
        "uri": uri,
        "languageId": language_id,
        "text": text,
    })
}

pub fn poll_payload(session_id: &str) -> Value {
    json!({ "sessionId": session_id })
}

/// 语言服务器退出后 Core 只允许在收到终态事件后销毁会话。
pub fn session_finished(value: &Value) -> bool {
    value
        .get("events")
        .and_then(Value::as_array)
        .map(|events| {
            events.iter().any(|event| {
                let kind = event.get("type").and_then(Value::as_str);
                let state = event.get("state").and_then(Value::as_str);
                matches!(kind, Some("stateChanged")) && matches!(state, Some("stopped" | "failed"))
            })
        })
        .unwrap_or(false)
}

/// 把一次 poll 的诊断事件投影为面板条目；无 URI 或工作区外的事件被丢弃。
pub fn diagnostics_from_poll(value: &Value, root: &str) -> HashMap<String, Vec<DiagnosticEntry>> {
    let mut by_file: HashMap<String, Vec<DiagnosticEntry>> = HashMap::new();
    let Some(events) = value.get("events").and_then(Value::as_array) else {
        return by_file;
    };
    for event in events {
        if event.get("type").and_then(Value::as_str) != Some("diagnostics") {
            continue;
        }
        let Some(uri) = event.get("uri").and_then(Value::as_str) else {
            continue;
        };
        let Some(path) = workspace_relative_path(root, uri) else {
            continue;
        };
        let diagnostics = event
            .get("diagnostics")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .map(|diagnostic| DiagnosticEntry {
                        severity: severity_name(diagnostic.get("severity").and_then(Value::as_i64)),
                        file_path: path.clone(),
                        line: diagnostic
                            .pointer("/range/start/line")
                            .and_then(Value::as_u64)
                            .unwrap_or(0) as u32,
                        column: diagnostic
                            .pointer("/range/start/utf16Column")
                            .and_then(Value::as_u64)
                            .unwrap_or(0) as u32,
                        message: diagnostic
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        source: diagnostic
                            .get("source")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                        code: diagnostic
                            .get("code")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        by_file.insert(path, diagnostics);
    }
    by_file
}

fn severity_name(severity: Option<i64>) -> String {
    match severity {
        Some(1) => "error".to_string(),
        Some(2) => "warning".to_string(),
        Some(3) => "info".to_string(),
        Some(4) => "hint".to_string(),
        _ => "info".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_and_decodes_file_uris() {
        let uri = file_uri("/work space", "src/主 file.rs");
        assert_eq!(uri, "file:///work%20space/src/%E4%B8%BB%20file.rs");
        assert_eq!(
            workspace_relative_path("/work space", &uri).as_deref(),
            Some("src/主 file.rs")
        );
    }

    #[test]
    fn selects_provider_by_extension() {
        assert_eq!(
            provider_for_path("src/main.rs").map(|p| p.id),
            Some("rust-analyzer")
        );
        assert_eq!(
            provider_for_path("src/App.tsx").map(|p| p.id),
            Some("typescript-language-server")
        );
        assert_eq!(provider_for_path("README.md").map(|p| p.id), None);
    }

    #[test]
    fn refines_language_id_for_shared_providers() {
        let clangd = provider_for_path("src/native.cpp").expect("clangd");
        assert_eq!(language_id_for_path("src/native.cpp", clangd), "cpp");
        assert_eq!(language_id_for_path("src/native.c", clangd), "c");
        let tsserver = provider_for_path("src/app.js").expect("tsserver");
        assert_eq!(language_id_for_path("src/app.js", tsserver), "javascript");
        assert_eq!(language_id_for_path("src/app.ts", tsserver), "typescript");
    }

    #[test]
    fn projects_diagnostics_inside_the_workspace() {
        let value = serde_json::json!({
            "events": [{
                "type": "diagnostics",
                "uri": "file:///work/src/main.rs",
                "diagnostics": [{
                    "severity": 1,
                    "message": "mismatched types",
                    "range": { "start": { "line": 4, "utf16Column": 7 } }
                }]
            }]
        });
        let diagnostics = diagnostics_from_poll(&value, "/work");
        let entries = diagnostics.get("src/main.rs").expect("diagnostics");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].severity, "error");
        assert_eq!(entries[0].line, 4);
        assert_eq!(entries[0].column, 7);
    }
}
