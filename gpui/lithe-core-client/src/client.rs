//! 通过 `lithe_core::execute_json` 调用共享 Core 的阻塞客户端。
//!
//! 所有方法都是同步阻塞的：它们把请求编码成 JSON，调用 Core 的同步入口，
//! 再解析返回的 JSON。在 GPUI 中必须放到后台线程（例如
//! `cx.background_spawn`）执行，绝不能在渲染线程直接调用。

use crate::command::CoreCommand;
use crate::error::CoreError;
use crate::response::CoreResponse;
use crate::types::{
    DirectoryListing, DirectoryListingResponse, FileReadResult, FileWriteResponse,
    WorkspaceSnapshot,
};
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::path::Path;

#[derive(Debug, Default, Clone, Copy)]
/// 无状态 Core 客户端。
///
/// Core 的 `execute_json` 自身是进程内同步调用，因此客户端无需持有连接或锁。
pub struct CoreClient;

impl CoreClient {
    /// 创建一个客户端。
    pub fn new() -> Self {
        Self
    }

    /// 发送 `core.ping`，确认 Core 可用。
    ///
    /// # Blocking
    ///
    /// 阻塞调用；调用方必须放在后台线程或 `cx.background_spawn` 中。
    pub fn ping(&self) -> Result<(), CoreError> {
        self.execute::<Value>(CoreCommand::Ping)?;
        Ok(())
    }

    /// 构建工作区的完整项目树。
    ///
    /// 成功时返回 Core 的 `WorkspaceSnapshotResponse`
    /// （`root`、`files`、`nestedWorktrees`）。
    ///
    /// # Blocking
    ///
    /// 会扫描磁盘；调用方必须放在后台线程或 `cx.background_spawn` 中。
    pub fn workspace_snapshot(&self, root: &Path) -> Result<WorkspaceSnapshot, CoreError> {
        let root = root_string(root)?;
        self.execute(CoreCommand::WorkspaceSnapshot { root })
    }

    /// 按目录逐个加载项目树子项，避免一次性构建整棵树。
    ///
    /// 请求中的路径是工作区相对目录；空字符串表示根目录。Core 会跳过已不存在
    /// 或不可见的目录，因此返回数量可能少于请求数量，顺序保持请求顺序。
    ///
    /// # Blocking
    ///
    /// 会访问磁盘；调用方必须放在后台线程或 `cx.background_spawn` 中。
    pub fn list_directories(
        &self,
        root: &Path,
        paths: &[String],
    ) -> Result<Vec<DirectoryListing>, CoreError> {
        let root = root_string(root)?;
        let response: DirectoryListingResponse =
            self.execute(CoreCommand::WorkspaceListDirectories {
                root,
                paths: paths.to_vec(),
            })?;
        Ok(response.directories)
    }

    /// 读取一个工作区相对 UTF-8 文件。
    ///
    /// # Blocking
    ///
    /// 会访问磁盘；调用方必须放在后台线程或 `cx.background_spawn` 中。
    pub fn read_file(&self, root: &Path, path: &str) -> Result<FileReadResult, CoreError> {
        let root = root_string(root)?;
        self.execute(CoreCommand::FileRead {
            root,
            path: path.to_string(),
        })
    }

    /// 替换一个工作区相对 UTF-8 文件，返回写入的字节数。
    ///
    /// 父目录不存在时 Core 会创建；路径逃逸工作区会返回
    /// `permission_denied`/`invalid_request`。
    ///
    /// # Blocking
    ///
    /// 会写磁盘；调用方必须放在后台线程或 `cx.background_spawn` 中。
    pub fn write_file(&self, root: &Path, path: &str, text: &str) -> Result<usize, CoreError> {
        let root = root_string(root)?;
        let response: FileWriteResponse = self.execute(CoreCommand::FileWrite {
            root,
            path: path.to_string(),
            text: text.to_string(),
        })?;
        Ok(response.bytes_written)
    }

    /// 直接执行一条原始命令，返回成功响应的 `data`。
    ///
    /// 命令名与 payload 由调用方负责；Core 未知命令会返回 `not_supported`。
    /// 这是给尚未类型化命令预留的逃生通道。
    ///
    /// # Blocking
    ///
    /// 阻塞调用；调用方必须放在后台线程或 `cx.background_spawn` 中。
    pub fn execute_raw(&self, command: &str, payload: Value) -> Result<Value, CoreError> {
        let response = self.send(command, payload)?;
        // 不是所有命令都会返回 data；成功但省略 data 时用 Null 表示，
        // 不把它误判成解码失败。
        if let Some(error) = response.error {
            return Err(error);
        }
        if !response.ok {
            return Err(CoreError::decode_failed(
                "Core reported failure without an error",
                None,
            ));
        }
        Ok(response.data.unwrap_or(Value::Null))
    }

    /// 请求 Core 协作式取消一个正在执行的操作。
    ///
    /// 返回 Core 是否找到并标记了该操作。对应
    /// `lithe_core::cancel_operation(operation_id)`。
    ///
    /// # Blocking
    ///
    /// 该函数本身不等待操作结束，但仍按本 crate 约定视为阻塞入口。
    pub fn cancel(&self, operation_id: &str) -> bool {
        lithe_core::cancel_operation(operation_id)
    }

    /// 执行类型化命令并把 `data` 反序列化为 `T`。
    fn execute<T: DeserializeOwned>(&self, command: CoreCommand) -> Result<T, CoreError> {
        let response = self.send(command.name(), command.payload())?;
        response.into_data()
    }

    /// 构造请求信封并调用 Core，返回解析后的外层响应。
    ///
    /// 请求信封字段来自 `rust/lithe-core/src/protocol/command.rs` 的
    /// `CoreRequest`：`command` 是稳定命令名，`payload` 是命令特有对象。
    /// `id`/`operationId`/`timeoutMilliseconds` 均可选；本客户端不生成它们。
    fn send(&self, command: &str, payload: Value) -> Result<CoreResponse, CoreError> {
        let request = serde_json::json!({
            "command": command,
            "payload": payload,
        });
        let request_text = serde_json::to_string(&request).map_err(|error| {
            CoreError::decode_failed(
                "Could not encode core request",
                Some(Value::String(error.to_string())),
            )
        })?;
        let response_text = lithe_core::execute_json(&request_text);
        CoreResponse::parse(&response_text)
    }
}

/// 把 `Path` 转成 Core 需要的 UTF-8 字符串。
///
/// Core 的请求模型使用 `String`；非 UTF-8 路径无法无损表示，因此直接报
/// `invalid_request`，而不是静默改写路径。
fn root_string(root: &Path) -> Result<String, CoreError> {
    root.to_str()
        .map(|value| value.to_string())
        .ok_or_else(|| CoreError::invalid_request("Workspace root is not valid UTF-8"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_utf8_root_without_panicking() {
        #[cfg(unix)]
        {
            use std::ffi::OsStr;
            use std::os::unix::ffi::OsStrExt;
            let path = Path::new(OsStr::from_bytes(b"/tmp/\xff"));
            let error = root_string(path).expect_err("invalid UTF-8 must fail");
            assert_eq!(error.code, crate::error::INVALID_REQUEST);
        }
        #[cfg(not(unix))]
        {
            let error = root_string(Path::new("C:/project"));
            assert!(error.is_ok());
        }
    }
}
