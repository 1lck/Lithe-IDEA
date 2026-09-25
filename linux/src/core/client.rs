use gpui_kit::{BackgroundExecutor, Global, Task};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreRequestEnvelope {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    operation_id: Option<String>,
    command: String,
    payload: Value,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCoreResponseEnvelope {
    #[allow(dead_code)]
    id: Option<String>,
    ok: bool,
    data: Option<Value>,
    error: Option<CoreResponseError>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreResponseError {
    pub code: Value,
    pub message: String,
    #[serde(default)]
    pub details: Option<String>,
}

impl std::fmt::Display for CoreResponseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.code {
            Value::String(code) => write!(f, "{code}: {}", self.message),
            other => write!(f, "{other}: {}", self.message),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CoreClient;

impl Global for CoreClient {}

impl CoreClient {
    pub fn new() -> Self {
        Self
    }

    /// 执行 Core 命令并返回异步任务 Task
    pub fn execute<T, R>(
        &self,
        cx: &gpui_kit::AsyncApp,
        command: &str,
        payload: T,
    ) -> Task<Result<R, String>>
    where
        T: Serialize,
        R: serde::de::DeserializeOwned + Send + 'static,
    {
        self.execute_with_operation_id(cx, command, payload, None)
    }

    /// 执行带 operation_id 的 Core 命令，方便后续取消
    pub fn execute_with_operation_id<T, R>(
        &self,
        cx: &gpui_kit::AsyncApp,
        command: &str,
        payload: T,
        operation_id: Option<String>,
    ) -> Task<Result<R, String>>
    where
        T: Serialize,
        R: serde::de::DeserializeOwned + Send + 'static,
    {
        self.execute_with_executor(cx.background_executor(), command, payload, operation_id)
    }

    /// 基于指定 BackgroundExecutor 执行 Core 命令
    pub fn execute_with_executor<T, R>(
        &self,
        executor: &BackgroundExecutor,
        command: &str,
        payload: T,
        operation_id: Option<String>,
    ) -> Task<Result<R, String>>
    where
        T: Serialize,
        R: serde::de::DeserializeOwned + Send + 'static,
    {
        let id = Uuid::new_v4().to_string();
        let payload_value = match serde_json::to_value(payload) {
            Ok(v) => v,
            Err(e) => {
                let err = format!("Failed to serialize command payload: {e}");
                return executor.spawn(async move { Err(err) });
            }
        };

        let request = CoreRequestEnvelope {
            id: Some(id),
            operation_id,
            command: command.to_string(),
            payload: payload_value,
        };

        let request_json = match serde_json::to_string(&request) {
            Ok(j) => j,
            Err(e) => {
                let err = format!("Failed to serialize request envelope: {e}");
                return executor.spawn(async move { Err(err) });
            }
        };

        executor.spawn(async move {
            let response_json = lithe_core::execute_json(&request_json);
            Self::parse_response::<R>(&response_json)
        })
    }

    /// 取消正在执行的操作
    #[allow(dead_code)]
    pub fn cancel_operation(&self, operation_id: &str) -> bool {
        lithe_core::cancel_operation(operation_id)
    }

    /// 取消正在执行的操作（别名）
    #[allow(dead_code)]
    pub fn cancel(&self, operation_id: &str) -> bool {
        self.cancel_operation(operation_id)
    }

    /// 获取工作区快照
    pub fn snapshot(&self, cx: &gpui_kit::AsyncApp, root: &str) -> Task<Result<Value, String>> {
        self.execute(
            cx,
            "workspace.snapshot",
            serde_json::json!({
                "root": root,
            }),
        )
    }

    /// 读取文件内容
    pub fn read_file(
        &self,
        cx: &gpui_kit::AsyncApp,
        root: &str,
        path: &str,
    ) -> Task<Result<String, String>> {
        let task: Task<Result<Value, String>> = self.execute(
            cx,
            "file.read",
            serde_json::json!({
                "root": root,
                "path": path,
            }),
        );

        cx.background_executor().spawn(async move {
            let value = task.await?;
            let text = value
                .get("text")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            Ok(text)
        })
    }

    /// 写入文件内容
    pub fn write_file(
        &self,
        cx: &gpui_kit::AsyncApp,
        root: &str,
        path: &str,
        text: &str,
    ) -> Task<Result<(), String>> {
        let task: Task<Result<Value, String>> = self.execute(
            cx,
            "file.write",
            serde_json::json!({
                "root": root,
                "path": path,
                "text": text,
            }),
        );

        cx.background_executor().spawn(async move {
            task.await?;
            Ok(())
        })
    }

    /// 在工作区中搜索文本或文件（对齐 Tauri `workspace.search` 的完整参数）。
    ///
    /// `max_results` 默认与 Tauri `CONTENT_SEARCH_PAGE_SIZE`（140）一致；
    /// `file_mask` 为逗号分隔的文件掩码，空串表示不过滤。
    #[allow(dead_code)]
    pub fn search(
        &self,
        cx: &gpui_kit::AsyncApp,
        root: &str,
        query: &str,
        case_sensitive: bool,
        whole_words: bool,
        regular_expression: bool,
        max_results: usize,
        file_mask: &str,
    ) -> Task<Result<Vec<Value>, String>> {
        let task: Task<Result<Value, String>> = self.execute(
            cx,
            "workspace.search",
            serde_json::json!({
                "root": root,
                "query": query,
                "caseSensitive": case_sensitive,
                "wholeWords": whole_words,
                "regularExpression": regular_expression,
                "maxResults": max_results,
                "fileMask": file_mask,
            }),
        );

        cx.background_executor().spawn(async move {
            let value = task.await?;
            let matches = value
                .get("matches")
                .and_then(|m| m.as_array())
                .cloned()
                .unwrap_or_default();
            Ok(matches)
        })
    }

    /// 工作区替换预览（对齐 Tauri `workspace.replacePreview`）。
    ///
    /// 返回 `files` 数组：每项含 `path`、`replacementText`，调用方据此写回。
    #[allow(dead_code)]
    pub fn replace_preview(
        &self,
        cx: &gpui_kit::AsyncApp,
        root: &str,
        query: &str,
        replacement: &str,
        case_sensitive: bool,
        whole_words: bool,
        regular_expression: bool,
        paths: &[String],
    ) -> Task<Result<Value, String>> {
        self.execute(
            cx,
            "workspace.replacePreview",
            serde_json::json!({
                "root": root,
                "query": query,
                "replacement": replacement,
                "caseSensitive": case_sensitive,
                "wholeWords": whole_words,
                "regularExpression": regular_expression,
                "paths": paths,
            }),
        )
    }

    /// 获取 Git 状态
    pub fn git_status(&self, cx: &gpui_kit::AsyncApp, root: &str) -> Task<Result<Value, String>> {
        self.execute(
            cx,
            "git.status",
            serde_json::json!({
                "root": root,
            }),
        )
    }

    /// 解析 Core 返回的 JSON envelope
    fn parse_response<R: serde::de::DeserializeOwned>(response_json: &str) -> Result<R, String> {
        let envelope: RawCoreResponseEnvelope = serde_json::from_str(response_json)
            .map_err(|e| format!("Failed to parse core response JSON: {e}"))?;

        if envelope.ok {
            let data = envelope.data.unwrap_or(Value::Null);
            serde_json::from_value::<R>(data)
                .map_err(|e| format!("Failed to deserialize response data: {e}"))
        } else {
            let error_str = if let Some(err) = envelope.error {
                match &err.details {
                    Some(details) if !details.is_empty() => {
                        format!("{err} ({details})")
                    }
                    _ => err.to_string(),
                }
            } else {
                "Unknown error from lithe core".to_string()
            };
            Err(error_str)
        }
    }
}
