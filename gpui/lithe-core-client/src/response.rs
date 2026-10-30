//! Core 响应外层解析。
//!
//! Core 的 `execute_json` 返回 `rust/lithe-core/src/protocol/contracts.rs` 中
//! `CoreResponse` 的 JSON 形式：
//!
//! ```json
//! { "id": "...", "ok": true, "data": { }, "error": { } }
//! ```
//!
//! 成功响应省略 `error`，失败响应省略 `data`；两者都按可选字段解析。

use crate::error::CoreError;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
/// 反序列化后的 Core 响应外层。
pub struct CoreResponse {
    /// 调用方提供的关联标识；客户端当前不主动生成。
    #[serde(default)]
    pub id: Option<String>,
    /// 成功与否的判别字段。
    #[serde(default)]
    pub ok: bool,
    /// 成功时的命令特有 payload。
    #[serde(default)]
    pub data: Option<Value>,
    /// 失败时的结构化错误。
    #[serde(default)]
    pub error: Option<CoreError>,
}

impl CoreResponse {
    /// 解析一份 `execute_json` 输出。
    ///
    /// 解析失败统一返回 `decode_failed`，保证调用方看到稳定的错误码，
    /// 而不是依赖 serde 的具体报错文本。
    pub fn parse(json: &str) -> Result<Self, CoreError> {
        serde_json::from_str(json).map_err(|error| {
            CoreError::decode_failed(
                "Could not decode core response",
                Some(Value::String(error.to_string())),
            )
        })
    }

    /// 报告响应是否成功（成功且没有附带错误）。
    pub fn is_success(&self) -> bool {
        self.ok && self.error.is_none()
    }

    /// 取走成功 payload 并按 `T` 反序列化。
    ///
    /// 失败优先返回 Core 的原始错误；成功但缺少 `data` 或 `data` 形状不匹配时
    /// 返回 `decode_failed`。
    pub fn into_data<T: DeserializeOwned>(self) -> Result<T, CoreError> {
        if let Some(error) = self.error {
            return Err(error);
        }
        if !self.ok {
            return Err(CoreError::decode_failed(
                "Core reported failure without an error",
                None,
            ));
        }
        let data = self.data.ok_or_else(|| {
            CoreError::decode_failed("Core success response did not include data", None)
        })?;
        serde_json::from_value(data).map_err(|error| {
            CoreError::decode_failed(
                "Core response data did not match the expected type",
                Some(Value::String(error.to_string())),
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turns_core_failure_into_error() {
        let response = CoreResponse::parse(
            r#"{"id":"1","ok":false,"error":{"code":"invalid_request","message":"bad","details":"why"}}"#,
        )
        .expect("envelope should decode");
        assert!(!response.is_success());
        let error = response
            .into_data::<Value>()
            .expect_err("failure must fail");
        assert_eq!(error.code, "invalid_request");
        assert_eq!(error.message, "bad");
        assert_eq!(error.details, Some(Value::String("why".to_string())));
    }

    #[test]
    fn decodes_success_payload() {
        let response = CoreResponse::parse(r#"{"ok":true,"data":{"text":"hi"}}"#)
            .expect("envelope should decode");
        assert!(response.is_success());
        let data: Value = response.into_data().expect("data should decode");
        assert_eq!(data["text"], "hi");
    }

    #[test]
    fn reports_stable_code_for_malformed_json() {
        let error = CoreResponse::parse("not json").expect_err("must fail");
        assert_eq!(error.code, crate::error::DECODE_FAILED);
    }
}
