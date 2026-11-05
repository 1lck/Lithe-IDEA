//! Credential-free provider request model shared by every AI generation feature.
//!
//! Commit messages, pull request descriptions, and inline edits all send one
//! system prompt plus one user prompt to a provider wire protocol. This module
//! owns endpoint normalization, request bodies, and response text extraction;
//! callers own prompts, budgets, and their own stable error codes. Native hosts
//! add credentials and perform HTTP.

use serde_json::{json, Value};

/// Wire protocols Core can encode and decode. Names describe the protocol, not a vendor product.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WireProtocol {
    /// OpenAI Responses (`/responses`).
    Responses,
    /// OpenAI-compatible Chat Completions (`/chat/completions`).
    ChatCompletions,
    /// Anthropic Messages (`/v1/messages`).
    AnthropicMessages,
    /// Google Generative Language `generateContent` (`/models/{model}:generateContent`).
    GeminiGenerateContent,
}

impl WireProtocol {
    /// Parses the contract name of a protocol; unknown names are not guessed.
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name {
            "responses" => Some(Self::Responses),
            "chatCompletions" => Some(Self::ChatCompletions),
            "anthropicMessages" => Some(Self::AnthropicMessages),
            "geminiGenerateContent" => Some(Self::GeminiGenerateContent),
            _ => None,
        }
    }
}

/// Why an endpoint cannot carry a request. Callers map these onto their own codes.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum EndpointError {
    /// Not an absolute URL with a host, or it embeds user info, a query, or a fragment.
    Invalid,
    /// Plain HTTP without the explicit opt-in for a trusted endpoint.
    Insecure,
}

/// Validates a provider endpoint and appends the protocol path exactly once.
///
/// A query is rejected so credentials can never travel in the URL, and user
/// info is rejected so the host's authentication header is the only secret.
pub(crate) fn endpoint_url(
    endpoint: &str,
    protocol: WireProtocol,
    model: &str,
    allows_insecure_http: bool,
) -> Result<url::Url, EndpointError> {
    let mut url = url::Url::parse(endpoint.trim()).map_err(|_| EndpointError::Invalid)?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(EndpointError::Invalid);
    }
    if url.scheme() != "https" && !(url.scheme() == "http" && allows_insecure_http) {
        return Err(EndpointError::Insecure);
    }
    let path = url.path().trim_end_matches('/').to_owned();
    let path = match protocol {
        WireProtocol::Responses => with_suffix(&path, "responses"),
        WireProtocol::ChatCompletions => with_suffix(&path, "chat/completions"),
        WireProtocol::AnthropicMessages => {
            if path.ends_with("/messages") {
                path
            } else if path.ends_with("/v1") {
                format!("{path}/messages")
            } else {
                format!("{path}/v1/messages")
            }
        }
        WireProtocol::GeminiGenerateContent => {
            // The model is one path segment; encoding keeps `/` or `?` in an id from
            // selecting another resource.
            let model: String = url::form_urlencoded::byte_serialize(model.as_bytes()).collect();
            let base = path
                .rsplit_once(":generateContent")
                .and_then(|(prefix, _)| prefix.rsplit_once('/').map(|(base, _)| base.to_owned()))
                .unwrap_or(path);
            format!("{base}/{model}:generateContent")
        }
    };
    url.set_path(&path);
    Ok(url)
}

fn with_suffix(path: &str, suffix: &str) -> String {
    if path.ends_with(&format!("/{suffix}")) {
        path.to_owned()
    } else {
        format!("{path}/{suffix}")
    }
}

/// Output-limit field accepted by a Chat Completions server.
#[derive(Clone, Copy, Debug)]
pub(crate) enum ChatTokenField {
    /// Modern field that also bounds reasoning tokens.
    MaxCompletionTokens,
    /// Legacy field accepted by older gateways.
    MaxTokens,
}

/// Protocol-neutral request content. Every field is credential free.
pub(crate) struct PromptRequest<'a> {
    pub(crate) model: &'a str,
    pub(crate) system: &'a str,
    pub(crate) user: &'a str,
    /// Upper bound on generated tokens, including reasoning where the protocol counts it.
    pub(crate) output_tokens: usize,
    /// `None` keeps the server default; Anthropic and Gemini never receive it.
    pub(crate) reasoning_effort: Option<&'a str>,
    /// `None` keeps the server default sampling temperature.
    pub(crate) temperature: Option<f64>,
    pub(crate) chat_token_field: ChatTokenField,
}

/// Encodes one non-streaming request body for the selected protocol.
pub(crate) fn encode_body(protocol: WireProtocol, request: &PromptRequest<'_>) -> Value {
    let mut body = match protocol {
        WireProtocol::Responses => {
            let mut body = json!({"model": request.model, "input": [{"role":"system","content":request.system},{"role":"user","content":request.user}],"max_output_tokens":request.output_tokens,"store":false});
            if let Some(effort) = request.reasoning_effort {
                body["reasoning"] = json!({ "effort": effort });
            }
            body
        }
        WireProtocol::ChatCompletions => {
            let mut body = json!({"model": request.model,"messages":[{"role":"system","content":request.system},{"role":"user","content":request.user}]});
            let field = match request.chat_token_field {
                ChatTokenField::MaxCompletionTokens => "max_completion_tokens",
                ChatTokenField::MaxTokens => "max_tokens",
            };
            body[field] = json!(request.output_tokens);
            if let Some(effort) = request.reasoning_effort {
                body["reasoning_effort"] = json!(effort);
            }
            body
        }
        WireProtocol::AnthropicMessages => {
            json!({"model":request.model,"system":request.system,"messages":[{"role":"user","content":request.user}],"max_tokens":request.output_tokens})
        }
        WireProtocol::GeminiGenerateContent => json!({
            "systemInstruction": {"parts": [{"text": request.system}]},
            "contents": [{"role": "user", "parts": [{"text": request.user}]}],
            "generationConfig": {"maxOutputTokens": request.output_tokens}
        }),
    };
    if let Some(temperature) = request.temperature {
        match protocol {
            WireProtocol::GeminiGenerateContent => {
                body["generationConfig"]["temperature"] = json!(temperature)
            }
            _ => body["temperature"] = json!(temperature),
        }
    }
    body
}

/// Why a response carries no usable text.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ResponseError {
    /// The provider stopped because it exhausted the output budget; the text is partial.
    OutputLimit,
}

/// Extracts the generated text of a complete, non-streaming response.
///
/// Missing content yields an empty string so each feature reports its own
/// empty-result code; a truncated generation is never returned as text.
pub(crate) fn response_text(
    protocol: WireProtocol,
    response: &Value,
) -> Result<String, ResponseError> {
    let exhausted = match protocol {
        WireProtocol::Responses => {
            response
                .pointer("/incomplete_details/reason")
                .and_then(Value::as_str)
                == Some("max_output_tokens")
        }
        WireProtocol::ChatCompletions => {
            response
                .pointer("/choices/0/finish_reason")
                .and_then(Value::as_str)
                == Some("length")
        }
        WireProtocol::AnthropicMessages => {
            response.get("stop_reason").and_then(Value::as_str) == Some("max_tokens")
        }
        WireProtocol::GeminiGenerateContent => {
            response
                .pointer("/candidates/0/finishReason")
                .and_then(Value::as_str)
                == Some("MAX_TOKENS")
        }
    };
    if exhausted {
        return Err(ResponseError::OutputLimit);
    }
    let joined = |items: Option<&Vec<Value>>, kind: Option<&str>| {
        items
            .into_iter()
            .flatten()
            .filter(|item| kind.is_none_or(|kind| item["type"] == kind))
            .filter_map(|item| item["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n")
    };
    Ok(match protocol {
        WireProtocol::ChatCompletions => response
            .pointer("/choices/0/message/content")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        WireProtocol::Responses => response
            .get("output_text")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| {
                response["output"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .flat_map(|item| item["content"].as_array().into_iter().flatten())
                    .filter(|item| item["type"] == "output_text")
                    .filter_map(|item| item["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n")
            }),
        WireProtocol::AnthropicMessages => joined(response["content"].as_array(), Some("text")),
        // Gemini parts concatenate without separators: one answer may be split mid-line.
        WireProtocol::GeminiGenerateContent => response
            .pointer("/candidates/0/content/parts")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|part| part.get("thought").and_then(Value::as_bool) != Some(true))
            .filter_map(|part| part["text"].as_str())
            .collect::<String>(),
    })
}

/// Removes one Markdown fence wrapping the whole trimmed text, keeping the inner text intact.
///
/// Only a fence whose info string is a single language token is removed, so
/// prose that merely starts and ends with backticks stays untouched.
pub(crate) fn strip_fence(text: &str) -> &str {
    let trimmed = text.trim();
    let Some(inner) = trimmed
        .strip_prefix("```")
        .and_then(|inner| inner.strip_suffix("```"))
    else {
        return trimmed;
    };
    let Some((info, body)) = inner.split_once('\n') else {
        return trimmed;
    };
    let info = info.strip_suffix('\r').unwrap_or(info);
    if !info
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return trimmed;
    }
    match body.strip_suffix('\n') {
        Some(body) => body.strip_suffix('\r').unwrap_or(body),
        None => trimmed,
    }
}
