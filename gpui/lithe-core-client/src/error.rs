//! 跨边界错误类型。
//!
//! Core 的失败响应（`rust/lithe-core/src/protocol/error.rs`）形如：
//! `{ "code": "invalid_request", "message": "...", "details": "..." }`。
//! `code` 是稳定的 snake_case 分类，`details` 在 Core 里是字符串，但这里保留为
//! `serde_json::Value`，以便兼容未来可能出现的结构化诊断，同时不丢信息。

use serde::Deserialize;
use serde_json::Value;
use std::fmt;

/// Core 调用或响应解析失败时使用的稳定错误码。
///
/// 解析失败、字段缺失等客户端侧问题统一归到这个 code，避免调用方依赖
/// serde 的错误文本。
pub const DECODE_FAILED: &str = "decode_failed";

/// 无法从 Core 响应中取得更具体分类时使用的错误码。
pub const UNKNOWN: &str = "unknown";

/// 客户端请求参数不合法时使用的错误码，与 Core 的 `ErrorCode::InvalidRequest`
/// 序列化结果保持一致。
pub const INVALID_REQUEST: &str = "invalid_request";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// 一次 Core 调用的结构化失败。
pub struct CoreError {
    /// 机器可读的稳定分类，例如 `invalid_request`、`workspace_not_found`。
    #[serde(default = "default_code")]
    pub code: String,
    /// 可直接展示给用户的摘要。
    #[serde(default)]
    pub message: String,
    /// 不宜直接展示、但可用于诊断的附加上下文。
    #[serde(default)]
    pub details: Option<Value>,
}

fn default_code() -> String {
    UNKNOWN.to_string()
}

impl CoreError {
    /// 创建一个不带诊断上下文的错误。
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            details: None,
        }
    }

    /// 附加诊断上下文；不会改变稳定错误码。
    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }

    /// 构造客户端侧解析失败错误。
    pub(crate) fn decode_failed(message: impl Into<String>, details: Option<Value>) -> Self {
        Self {
            code: DECODE_FAILED.to_string(),
            message: message.into(),
            details,
        }
    }

    /// 构造客户端侧请求参数错误。
    pub(crate) fn invalid_request(message: impl Into<String>) -> Self {
        Self::new(INVALID_REQUEST, message)
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{} [{}]", self.message, self.code)?;
        if let Some(details) = self.details.as_ref().filter(|value| !value.is_null()) {
            match details {
                Value::String(text) if text.is_empty() => {}
                Value::String(text) => write!(formatter, ": {text}")?,
                other => write!(formatter, ": {other}")?,
            }
        }
        Ok(())
    }
}

impl std::error::Error for CoreError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_core_error_payload() {
        let error: CoreError = serde_json::from_str(
            r#"{"code":"workspace_not_found","message":"Workspace does not exist","details":"missing"}"#,
        )
        .expect("core error shape should decode");
        assert_eq!(error.code, "workspace_not_found");
        assert_eq!(error.message, "Workspace does not exist");
        assert_eq!(error.details, Some(Value::String("missing".to_string())));
    }

    #[test]
    fn display_includes_code_and_details() {
        let error = CoreError::new("invalid_request", "bad path")
            .with_details(Value::String("must be relative".to_string()));
        assert_eq!(
            error.to_string(),
            "bad path [invalid_request]: must be relative"
        );
    }
}
