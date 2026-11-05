//! AI inline edit planning and decoding: model resolution, budgets, prompt, and output cleanup.
//!
//! The platform resolves its provider catalog entry into credential-free facts
//! and performs HTTP with the credential it owns. Core decides which model
//! limits apply, how much surrounding text is sent, the exact request body,
//! and what counts as a usable replacement.

use super::provider_request::{
    encode_body, endpoint_url, response_text, strip_fence, ChatTokenField, EndpointError,
    PromptRequest, ResponseError, WireProtocol,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

/// Output-token ceiling; also the limit assumed for models that publish none.
const INLINE_EDIT_OUTPUT_TOKENS: usize = 4_096;
/// Unicode scalars of context kept on each side of the selection.
pub(crate) const INLINE_EDIT_CONTEXT_CHARACTERS: usize = 12_000;
/// Upper bound on the UTF-8 size of all edit text crossing the boundary.
const INLINE_EDIT_REQUEST_BYTES: usize = 2 * 1024 * 1024;
const INLINE_EDIT_TEMPERATURE: f64 = 0.2;
const DEFAULT_INSTRUCTION: &str = "Improve this code while preserving behavior.";
const SYSTEM_PROMPT: &str = "You are Lithe inline edit. Return only the replacement text for the selected text. Do not include markdown fences, explanations, or surrounding unchanged context.";

/// Credential-free facts about the provider the user selected.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderFacts {
    /// Contract protocol name, for example `chatCompletions`.
    wire_protocol: String,
    /// Base URL or complete protocol endpoint; blank when the user has not configured one.
    endpoint: String,
    /// Whether the host must attach a nonempty credential.
    requires_api_key: bool,
    /// Explicit trust for a local or user-entered plain HTTP endpoint.
    #[serde(default)]
    allows_insecure_http: bool,
    /// Whether model ids absent from every listing are still sent to this provider.
    #[serde(default)]
    accepts_unlisted_models: bool,
    /// Chat Completions output-limit field; defaults to the widely accepted `max_tokens`.
    #[serde(default)]
    chat_token_limit_field: Option<String>,
    /// False for models that only accept their default sampling temperature.
    #[serde(default = "default_true")]
    supports_temperature: bool,
}

fn default_true() -> bool {
    true
}

/// Where the platform found the selected model.
#[derive(Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum ModelListing {
    /// Static catalog shipped with the application.
    Catalog,
    /// Model list fetched from the provider at runtime.
    Discovered,
    /// Not present in any listing.
    Unlisted,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelFacts {
    id: String,
    listing: ModelListing,
    /// Published token limit of the model, when the listing has one.
    #[serde(default)]
    max_tokens: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EditFacts {
    /// Text before the selection; Core keeps only its last characters.
    before_selection: String,
    selected_text: String,
    /// Text after the selection; Core keeps only its first characters.
    #[serde(default)]
    after_selection: String,
    /// User instruction; blank selects the default improvement instruction.
    #[serde(default)]
    instruction: String,
    #[serde(default)]
    file_path: String,
    #[serde(default)]
    language_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanRequest {
    provider: ProviderFacts,
    model: ModelFacts,
    edit: EditFacts,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DecodeRequest {
    wire_protocol: String,
    response: Value,
}

fn failure(code: &'static str) -> CoreError {
    // Codes only: edit text and provider responses never enter diagnostics.
    CoreError::new(ErrorCode::InvalidRequest, code)
}

/// `ai.inlineEdit.plan`: returns the URL, body, and credential placement for one edit request.
pub(crate) fn plan_command(payload: Value) -> Result<Value, CoreError> {
    let request: PlanRequest =
        serde_json::from_value(payload).map_err(|_| failure("AI_INLINE_EDIT_INVALID_REQUEST"))?;
    plan(request).map_err(failure)
}

fn plan(request: PlanRequest) -> Result<Value, &'static str> {
    let PlanRequest {
        provider,
        model,
        edit,
    } = request;
    let edit_bytes = edit.before_selection.len()
        + edit.selected_text.len()
        + edit.after_selection.len()
        + edit.instruction.len()
        + edit.file_path.len()
        + edit.language_id.len();
    if edit_bytes > INLINE_EDIT_REQUEST_BYTES {
        return Err("AI_INLINE_EDIT_INVALID_REQUEST");
    }
    let model_id = model.id.trim();
    if model_id.is_empty() {
        return Err("AI_INLINE_EDIT_MODEL_MISSING");
    }
    if model_id.len() > 512 {
        return Err("AI_INLINE_EDIT_INVALID_REQUEST");
    }
    // A listed model without a published limit, or an unlisted model on a
    // provider that accepts any id, gets the conservative default.
    let model_limit = match model.listing {
        ModelListing::Catalog | ModelListing::Discovered => model.max_tokens,
        ModelListing::Unlisted if provider.accepts_unlisted_models => None,
        ModelListing::Unlisted => return Err("AI_INLINE_EDIT_MODEL_NOT_FOUND"),
    };
    let output_tokens = model_limit
        .filter(|limit| *limit > 0)
        .map_or(INLINE_EDIT_OUTPUT_TOKENS, |limit| {
            usize::try_from(limit).unwrap_or(usize::MAX)
        })
        .min(INLINE_EDIT_OUTPUT_TOKENS);
    let protocol = WireProtocol::parse(&provider.wire_protocol)
        .ok_or("AI_INLINE_EDIT_UNSUPPORTED_PROVIDER")?;
    if provider.endpoint.trim().is_empty() {
        return Err("AI_INLINE_EDIT_ENDPOINT_MISSING");
    }
    let url = endpoint_url(
        &provider.endpoint,
        protocol,
        model_id,
        provider.allows_insecure_http,
    )
    .map_err(|error| match error {
        EndpointError::Invalid => "AI_INLINE_EDIT_INVALID_ENDPOINT",
        EndpointError::Insecure => "AI_INLINE_EDIT_INSECURE_ENDPOINT",
    })?;
    let chat_token_field = match provider.chat_token_limit_field.as_deref() {
        None | Some("max_tokens") => ChatTokenField::MaxTokens,
        Some("max_completion_tokens") => ChatTokenField::MaxCompletionTokens,
        Some(_) => return Err("AI_INLINE_EDIT_INVALID_REQUEST"),
    };
    let user = user_prompt(&edit);
    let body = encode_body(
        protocol,
        &PromptRequest {
            model: model_id,
            system: SYSTEM_PROMPT,
            user: &user,
            output_tokens,
            reasoning_effort: None,
            temperature: provider
                .supports_temperature
                .then_some(INLINE_EDIT_TEMPERATURE),
            chat_token_field,
        },
    );
    let (header, scheme) = match protocol {
        WireProtocol::Responses | WireProtocol::ChatCompletions => ("Authorization", "bearer"),
        WireProtocol::AnthropicMessages => ("x-api-key", "raw"),
        WireProtocol::GeminiGenerateContent => ("x-goog-api-key", "raw"),
    };
    let mut headers = json!({"Content-Type": "application/json", "Accept": "application/json"});
    if protocol == WireProtocol::AnthropicMessages {
        headers["anthropic-version"] = json!("2023-06-01");
    }
    Ok(json!({
        "url": url.to_string(),
        "body": body,
        "headers": headers,
        "credential": {
            "required": provider.requires_api_key,
            "header": header,
            "scheme": scheme,
        },
    }))
}

fn user_prompt(edit: &EditFacts) -> String {
    let before = tail(&edit.before_selection, INLINE_EDIT_CONTEXT_CHARACTERS);
    let after: String = edit
        .after_selection
        .chars()
        .take(INLINE_EDIT_CONTEXT_CHARACTERS)
        .collect();
    let instruction = match edit.instruction.trim() {
        "" => DEFAULT_INSTRUCTION,
        instruction => instruction,
    };
    let file_context = [
        (!edit.file_path.is_empty()).then(|| format!("File: {}", edit.file_path)),
        (!edit.language_id.is_empty()).then(|| format!("Language: {}", edit.language_id)),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join("\n");
    [
        file_context,
        format!("Instruction:\n{instruction}"),
        format!("Before selection:\n{before}"),
        format!("Selected text:\n{}", edit.selected_text),
        format!("After selection:\n{after}"),
    ]
    .into_iter()
    .filter(|part| !part.is_empty())
    .collect::<Vec<_>>()
    .join("\n\n")
}

fn tail(text: &str, characters: usize) -> &str {
    let count = text.chars().count();
    if count <= characters {
        return text;
    }
    let start = text
        .char_indices()
        .nth(count - characters)
        .map_or(text.len(), |(index, _)| index);
    &text[start..]
}

/// `ai.inlineEdit.decode`: extracts the replacement text of a complete provider response.
///
/// An empty replacement is a valid result the caller reports itself; a
/// generation cut off by the output limit is rejected so partial code is never applied.
pub(crate) fn decode_command(payload: Value) -> Result<Value, CoreError> {
    let request: DecodeRequest =
        serde_json::from_value(payload).map_err(|_| failure("AI_INLINE_EDIT_INVALID_REQUEST"))?;
    let protocol = WireProtocol::parse(&request.wire_protocol)
        .ok_or_else(|| failure("AI_INLINE_EDIT_UNSUPPORTED_PROVIDER"))?;
    if !request.response.is_object() {
        return Err(failure("AI_INLINE_EDIT_INVALID_RESPONSE"));
    }
    let text = response_text(protocol, &request.response)
        .map_err(|ResponseError::OutputLimit| failure("AI_INLINE_EDIT_OUTPUT_LIMIT"))?;
    Ok(json!({ "editedText": strip_fence(&text) }))
}
