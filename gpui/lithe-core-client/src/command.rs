//! 最近版本 Core 命令的客户端类型化表示。
//!
//! 命令名与 payload 字段全部来自真实 Core 实现，不按记忆编造：
//!
//! - 命令名：`rust/lithe-core/src/protocol/command.rs` 的 `CoreCommand::parse`
//! - payload 反序列化：`rust/lithe-core/src/runtime/dispatcher.rs` 与
//!   `rust/lithe-core/src/project/files.rs`
//!
//! 所有请求结构体都带 `#[serde(rename_all = "camelCase")]`，所以 Rust 侧字段
//! `hidden_directory_names` 对应的 JSON 字段是 `hiddenDirectoryNames`。

use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq, Eq)]
/// lithe-core 工作台所需的命令子集。
///
/// 变体携带构造真实 payload 所需的参数；[`CoreCommand::name`] 返回兼容命令名，
/// [`CoreCommand::payload`] 返回 camelCase JSON 对象。
pub enum CoreCommand {
    /// `core.ping`：报告 Core 与协议版本。
    ///
    /// 来源：`protocol/command.rs` 的 `"core.ping"`。payload 被 dispatcher 忽略，
    /// 这里发送空对象。
    Ping,
    /// `workspace.snapshot`：构建完整项目树。
    ///
    /// 来源：`project/files.rs` 的 `WorkspaceSnapshotRequest`
    /// （`root`、`hiddenDirectoryNames`、`hiddenFilePatterns`、`includeTree`）。
    /// `includeTree` 默认 true；这里显式发送 true，确保拿到完整树。
    WorkspaceSnapshot { root: String },
    /// `workspace.listDirectories`：按目录逐个加载可见子项。
    ///
    /// 来源：`project/files.rs` 的 `DirectoryListingRequest`
    /// （`root`、`paths`、`hiddenDirectoryNames`、`hiddenFilePatterns`）。
    /// 隐藏项列表留空即使用 Core 内置规则。
    WorkspaceListDirectories { root: String, paths: Vec<String> },
    /// `file.read`：读取一个工作区相对 UTF-8 文件。
    ///
    /// 来源：`project/files.rs` 的 `FileReadRequest`（`root`、`path`）。
    FileRead { root: String, path: String },
    /// `file.write`：替换一个工作区相对 UTF-8 文件。
    ///
    /// 来源：`project/files.rs` 的 `FileWriteRequest`（`root`、`path`、`text`）。
    FileWrite {
        root: String,
        path: String,
        text: String,
    },
}

impl CoreCommand {
    /// 返回 Core dispatcher 接受的稳定命令名。
    ///
    /// 这些字符串必须与 `protocol/command.rs` 的 `CoreCommand::parse` 完全一致；
    /// Core 不接受别名或大小写变体。
    pub fn name(&self) -> &'static str {
        match self {
            Self::Ping => "core.ping",
            Self::WorkspaceSnapshot { .. } => "workspace.snapshot",
            Self::WorkspaceListDirectories { .. } => "workspace.listDirectories",
            Self::FileRead { .. } => "file.read",
            Self::FileWrite { .. } => "file.write",
        }
    }

    /// 返回该命令的 camelCase payload 对象。
    ///
    /// 字段名来自上表列出的 Rust 请求结构体的 serde 重命名规则。
    pub fn payload(&self) -> Value {
        match self {
            Self::Ping => json!({}),
            Self::WorkspaceSnapshot { root } => json!({
                // WorkspaceSnapshotRequest
                "root": root,
                // 显式请求完整树；省略时 Core 默认也是 true。
                "includeTree": true,
            }),
            Self::WorkspaceListDirectories { root, paths } => json!({
                // DirectoryListingRequest
                "root": root,
                "paths": paths,
            }),
            Self::FileRead { root, path } => json!({
                // FileReadRequest
                "root": root,
                "path": path,
            }),
            Self::FileWrite { root, path, text } => json!({
                // FileWriteRequest
                "root": root,
                "path": path,
                "text": text,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_core_compatible_command_names() {
        assert_eq!(CoreCommand::Ping.name(), "core.ping");
        assert_eq!(
            CoreCommand::WorkspaceSnapshot {
                root: "C:/project".to_string()
            }
            .name(),
            "workspace.snapshot"
        );
        assert_eq!(
            CoreCommand::WorkspaceListDirectories {
                root: "C:/project".to_string(),
                paths: vec!["src".to_string()]
            }
            .name(),
            "workspace.listDirectories"
        );
        assert_eq!(
            CoreCommand::FileRead {
                root: "C:/project".to_string(),
                path: "README.md".to_string()
            }
            .name(),
            "file.read"
        );
        assert_eq!(
            CoreCommand::FileWrite {
                root: "C:/project".to_string(),
                path: "README.md".to_string(),
                text: "hello".to_string()
            }
            .name(),
            "file.write"
        );
    }

    #[test]
    fn serializes_camel_case_payload_fields() {
        let payload = CoreCommand::FileWrite {
            root: "C:/project".to_string(),
            path: "src/Main.java".to_string(),
            text: "class Main {}".to_string(),
        }
        .payload();
        assert_eq!(payload["root"], "C:/project");
        assert_eq!(payload["path"], "src/Main.java");
        assert_eq!(payload["text"], "class Main {}");

        let payload = CoreCommand::WorkspaceSnapshot {
            root: "C:/project".to_string(),
        }
        .payload();
        assert_eq!(payload["root"], "C:/project");
        assert_eq!(payload["includeTree"], true);
    }
}
