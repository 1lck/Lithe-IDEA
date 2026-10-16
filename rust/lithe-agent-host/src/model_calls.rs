//! Passive observation of individual model API calls made by an Agent.
//!
//! ACP reports only turn-level usage and context occupancy. When the user opts
//! in, the loopback proxy in [`crate::model_proxy`] forwards each provider
//! request unchanged and this module derives per-call facts from the bytes it
//! has already seen: request composition, first-token latency, streaming mode
//! and the provider's own usage counters. Parsing is strictly best effort. A
//! provider format change can only remove fields from the observation; it can
//! never alter or fail the forwarded exchange.
//! Decision: .agents/notes/implemented/architecture/2026-10-13-agent-model-call-observation.md

use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;

/// Bound on one buffered SSE line or non-streaming body kept for parsing.
/// Larger payloads are still forwarded; only their observation is dropped.
const MAX_OBSERVED_BYTES: usize = 32 * 1024 * 1024;

/// Provider wire protocol of an observed call, inferred from the request path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ModelApi {
    AnthropicMessages,
    Responses,
    ChatCompletions,
}

impl ModelApi {
    /// Only generation endpoints are model calls. Token counting, model
    /// listing and other auxiliary requests are forwarded without an event.
    pub(crate) fn from_path(path: &str) -> Option<Self> {
        let path = path.split('?').next().unwrap_or(path).trim_end_matches('/');
        if path.ends_with("/messages") {
            Some(Self::AnthropicMessages)
        } else if path.ends_with("/responses") {
            Some(Self::Responses)
        } else if path.ends_with("/chat/completions") {
            Some(Self::ChatCompletions)
        } else {
            None
        }
    }
}

/// Provider-reported counters normalized to disjoint buckets.
///
/// `input_tokens` excludes cache reads and writes for every protocol, so the
/// prompt size is always the sum of the three input buckets.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCallUsage {
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    /// Reasoning tokens when the provider reports them; already part of
    /// `output_tokens` for OpenAI-compatible protocols.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_tokens: Option<u64>,
}

impl ModelCallUsage {
    fn prompt_tokens(&self) -> u64 {
        self.input_tokens + self.cache_read_tokens + self.cache_write_tokens
    }
}

/// Estimated split of one request's prompt. Byte sizes of the serialized
/// sections are scaled to the provider-reported prompt tokens when available;
/// otherwise a four-bytes-per-token approximation is used.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextComposition {
    pub system_prompt_tokens: u64,
    /// Built-in tool definitions sent by the Agent.
    pub tool_tokens: u64,
    /// Tool definitions whose names use the `mcp__` prefix.
    pub mcp_tool_tokens: u64,
    pub message_tokens: u64,
    pub tool_count: u32,
    pub mcp_tool_count: u32,
    /// `true` when the split was scaled to the provider's prompt counters.
    pub scaled_to_usage: bool,
}

/// One forwarded generation request, as reported in the `modelCall` event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCall {
    pub api: ModelApi,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Upstream HTTP status (200 for a WebSocket response), or 502 for
    /// transport failure. A WebSocket error supplies its explicit status.
    pub status: u16,
    /// True for SSE and WebSocket streaming responses.
    pub streaming: bool,
    /// Milliseconds from forwarding the request to the first generated delta.
    /// Absent for non-streaming responses and streams without output.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_token_ms: Option<u64>,
    /// Milliseconds from forwarding the request to the end of the response.
    pub duration_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ModelCallUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<ContextComposition>,
}

/// Serialized byte sizes of the parts of one generation request.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct RequestShape {
    pub(crate) model: Option<String>,
    system_bytes: u64,
    /// Standalone instructions are replaced rather than inherited by a
    /// Responses continuation; system/developer input items remain in history.
    instruction_bytes: u64,
    tool_bytes: u64,
    mcp_tool_bytes: u64,
    message_bytes: u64,
    tool_count: u32,
    mcp_tool_count: u32,
}

/// Measure the request sections. Unknown or malformed bodies yield `None` and
/// the call is still reported with timing and usage.
pub(crate) fn request_shape(api: ModelApi, body: &[u8]) -> Option<RequestShape> {
    let request: Value = serde_json::from_slice(body).ok()?;
    let request = request.as_object()?;
    let mut shape = RequestShape {
        model: request
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_owned),
        ..RequestShape::default()
    };
    for tool in request
        .get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let name = tool
            .get("name")
            .or_else(|| {
                tool.get("function")
                    .and_then(|function| function.get("name"))
            })
            .and_then(Value::as_str)
            .unwrap_or_default();
        let bytes = serialized_len(tool);
        if name.starts_with("mcp__") {
            shape.mcp_tool_bytes += bytes;
            shape.mcp_tool_count += 1;
        } else {
            shape.tool_bytes += bytes;
            shape.tool_count += 1;
        }
    }
    let (system, messages) = match api {
        ModelApi::AnthropicMessages => (request.get("system"), request.get("messages")),
        ModelApi::Responses => (request.get("instructions"), request.get("input")),
        ModelApi::ChatCompletions => (None, request.get("messages")),
    };
    shape.instruction_bytes = system.map(text_len).unwrap_or_default();
    shape.system_bytes += shape.instruction_bytes;
    match messages {
        Some(Value::Array(items)) => {
            for item in items {
                // OpenAI-compatible protocols carry instructions as messages.
                let role = item.get("role").and_then(Value::as_str);
                if api != ModelApi::AnthropicMessages
                    && matches!(role, Some("system" | "developer"))
                {
                    shape.system_bytes += item.get("content").map(text_len).unwrap_or_default();
                } else {
                    shape.message_bytes += serialized_len(item);
                }
            }
        }
        Some(other) => shape.message_bytes += text_len(other),
        None => {}
    }
    Some(shape)
}

impl RequestShape {
    /// Reconstruct only sizes of a validated WebSocket continuation. No
    /// request or response text survives an observed message.
    pub(crate) fn continue_responses(
        &mut self,
        previous: &Self,
        output: &Self,
        inherits_instructions: bool,
        inherits_tools: bool,
    ) {
        self.system_bytes += previous
            .system_bytes
            .saturating_sub(previous.instruction_bytes)
            + output.system_bytes;
        self.message_bytes += previous.message_bytes + output.message_bytes;
        if inherits_instructions {
            self.instruction_bytes = previous.instruction_bytes;
            self.system_bytes += previous.instruction_bytes;
        }
        if inherits_tools {
            self.tool_bytes = previous.tool_bytes;
            self.mcp_tool_bytes = previous.mcp_tool_bytes;
            self.tool_count = previous.tool_count;
            self.mcp_tool_count = previous.mcp_tool_count;
        }
        if self.model.is_none() {
            self.model = previous.model.clone();
        }
    }

    /// Measure completed output items exactly as subsequent Responses input.
    pub(crate) fn response_output(output: &Value) -> Option<Self> {
        let items = output.as_array()?;
        let shapes: Vec<_> = items.iter().map(Self::response_item).collect();
        Some(Self::sum_outputs(shapes.iter()))
    }

    pub(crate) fn response_item(item: &Value) -> Self {
        let mut shape = Self::default();
        if matches!(
            item.get("role").and_then(Value::as_str),
            Some("system" | "developer")
        ) {
            shape.system_bytes = item.get("content").map(text_len).unwrap_or_default();
        } else {
            shape.message_bytes = serialized_len(item);
        }
        shape
    }

    pub(crate) fn sum_outputs<'a>(outputs: impl Iterator<Item = &'a Self>) -> Self {
        outputs.fold(Self::default(), |mut sum, item| {
            sum.system_bytes += item.system_bytes;
            sum.message_bytes += item.message_bytes;
            sum
        })
    }

    fn composition(&self, usage: Option<&ModelCallUsage>) -> ContextComposition {
        let sections = [
            self.system_bytes,
            self.tool_bytes,
            self.mcp_tool_bytes,
            self.message_bytes,
        ];
        let prompt = usage
            .map(ModelCallUsage::prompt_tokens)
            .filter(|tokens| *tokens > 0);
        let tokens = match prompt {
            Some(prompt) => allocate(prompt, sections),
            None => sections.map(|bytes| bytes.div_ceil(4)),
        };
        ContextComposition {
            system_prompt_tokens: tokens[0],
            tool_tokens: tokens[1],
            mcp_tool_tokens: tokens[2],
            message_tokens: tokens[3],
            tool_count: self.tool_count,
            mcp_tool_count: self.mcp_tool_count,
            scaled_to_usage: prompt.is_some(),
        }
    }
}

/// Split `total` proportionally to `weights` with the largest-remainder method,
/// so the parts always add up to the provider-reported total.
fn allocate(total: u64, weights: [u64; 4]) -> [u64; 4] {
    let sum: u128 = weights.iter().map(|weight| u128::from(*weight)).sum();
    if sum == 0 {
        // Without measurable sections the whole prompt is conversation input.
        return [0, 0, 0, total];
    }
    let mut parts = [0u64; 4];
    let mut remainders = [(0u128, 0usize); 4];
    for (index, weight) in weights.iter().enumerate() {
        let exact = u128::from(total) * u128::from(*weight);
        parts[index] = (exact / sum) as u64;
        remainders[index] = (exact % sum, index);
    }
    let mut left = total - parts.iter().sum::<u64>();
    // Stable ordering keeps the result deterministic for equal remainders.
    remainders.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    for (_, index) in remainders {
        if left == 0 {
            break;
        }
        parts[index] += 1;
        left -= 1;
    }
    parts
}

fn serialized_len(value: &Value) -> u64 {
    serde_json::to_vec(value).map_or(0, |bytes| bytes.len() as u64)
}

/// Text payload size without JSON quoting, for string or block-array content.
fn text_len(value: &Value) -> u64 {
    match value {
        Value::String(text) => text.len() as u64,
        Value::Null => 0,
        other => serialized_len(other),
    }
}

/// Incrementally observes one response body as it is forwarded.
pub(crate) struct ResponseObserver {
    api: ModelApi,
    status: u16,
    streaming: bool,
    started: Instant,
    first_token: Option<Duration>,
    usage: Option<ModelCallUsage>,
    /// Partial SSE line, or the whole body for non-streaming responses.
    buffer: Vec<u8>,
    /// Data lines of the SSE event being assembled.
    event_data: String,
    overflowed: bool,
}

impl ResponseObserver {
    pub(crate) fn new(api: ModelApi, status: u16, streaming: bool, started: Instant) -> Self {
        Self {
            api,
            status,
            streaming,
            started,
            first_token: None,
            usage: None,
            buffer: Vec::new(),
            event_data: String::new(),
            overflowed: false,
        }
    }

    pub(crate) fn feed(&mut self, chunk: &[u8], now: Instant) {
        if self.overflowed {
            return;
        }
        self.buffer.extend_from_slice(chunk);
        if !self.streaming {
            self.check_bound();
            return;
        }
        while let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line);
            self.sse_line(line.trim_end_matches(['\n', '\r']), now);
        }
        self.check_bound();
    }

    /// Complete the observation. `request` supplies the composition measured
    /// before forwarding.
    pub(crate) fn finish(mut self, request: Option<&RequestShape>, now: Instant) -> ModelCall {
        if self.streaming {
            if !self.buffer.is_empty() && !self.overflowed {
                let line = String::from_utf8_lossy(&std::mem::take(&mut self.buffer)).into_owned();
                self.sse_line(line.trim_end_matches('\r'), now);
            }
            self.dispatch_event(now);
        } else if !self.overflowed {
            if let Ok(body) = serde_json::from_slice::<Value>(&self.buffer) {
                if let Some(usage) = body.get("usage") {
                    self.merge_usage(usage);
                }
            }
        }
        ModelCall {
            api: self.api,
            model: request.and_then(|request| request.model.clone()),
            status: self.status,
            streaming: self.streaming,
            first_token_ms: self.first_token.map(millis),
            duration_ms: millis(now.saturating_duration_since(self.started)),
            usage: self.usage,
            context: request.map(|request| request.composition(self.usage.as_ref())),
        }
    }

    fn check_bound(&mut self) {
        if self.buffer.len() > MAX_OBSERVED_BYTES || self.event_data.len() > MAX_OBSERVED_BYTES {
            self.overflowed = true;
            self.buffer = Vec::new();
            self.event_data = String::new();
        }
    }

    fn sse_line(&mut self, line: &str, now: Instant) {
        if line.is_empty() {
            self.dispatch_event(now);
        } else if let Some(data) = line.strip_prefix("data:") {
            if !self.event_data.is_empty() {
                self.event_data.push('\n');
            }
            self.event_data
                .push_str(data.strip_prefix(' ').unwrap_or(data));
        }
    }

    fn dispatch_event(&mut self, now: Instant) {
        if self.event_data.is_empty() {
            return;
        }
        let data = std::mem::take(&mut self.event_data);
        let Ok(event) = serde_json::from_str::<Value>(&data) else {
            return;
        };
        self.event(&event, now);
    }

    /// SSE and WebSocket responses share provider counters and generated-delta
    /// semantics; transport framing never participates in the token estimate.
    pub(crate) fn event(&mut self, event: &Value, now: Instant) {
        if let Some(status @ 400..=599) = event.get("status").and_then(Value::as_u64) {
            self.status = status as u16;
        }
        if self.status < 400 && matches!(event["type"].as_str(), Some("error" | "response.failed"))
        {
            self.status = 502;
        }
        if self.first_token.is_none() && self.is_generated_delta(event) {
            self.first_token = Some(now.saturating_duration_since(self.started));
        }
        let usage = match self.api {
            ModelApi::AnthropicMessages => match event.get("type").and_then(Value::as_str) {
                Some("message_start") => event
                    .get("message")
                    .and_then(|message| message.get("usage")),
                Some("message_delta") => event.get("usage"),
                _ => None,
            },
            ModelApi::Responses => match event.get("type").and_then(Value::as_str) {
                Some("response.completed" | "response.incomplete" | "response.failed") => event
                    .get("response")
                    .and_then(|response| response.get("usage")),
                _ => None,
            },
            ModelApi::ChatCompletions => event.get("usage"),
        };
        if let Some(usage) = usage.cloned() {
            self.merge_usage(&usage);
        }
    }

    fn is_generated_delta(&self, event: &Value) -> bool {
        match self.api {
            ModelApi::AnthropicMessages => {
                event.get("type").and_then(Value::as_str) == Some("content_block_delta")
            }
            ModelApi::Responses => event
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|kind| kind.ends_with(".delta")),
            ModelApi::ChatCompletions => event
                .get("choices")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|choice| choice.get("delta").and_then(Value::as_object))
                .any(|delta| {
                    ["content", "reasoning_content", "reasoning", "tool_calls"]
                        .iter()
                        .any(|key| delta.get(*key).is_some_and(|value| !is_empty(value)))
                }),
        }
    }

    /// Later counters replace earlier ones field by field. Anthropic sends the
    /// prompt counters at `message_start` and the final output in `message_delta`.
    fn merge_usage(&mut self, usage: &Value) {
        if usage.is_null() {
            return;
        }
        let mut merged = self.usage.unwrap_or_default();
        let count = |value: Option<&Value>| value.and_then(Value::as_u64);
        match self.api {
            ModelApi::AnthropicMessages => {
                if let Some(value) = count(usage.get("input_tokens")) {
                    merged.input_tokens = value;
                }
                if let Some(value) = count(usage.get("cache_read_input_tokens")) {
                    merged.cache_read_tokens = value;
                }
                if let Some(value) = count(usage.get("cache_creation_input_tokens")) {
                    merged.cache_write_tokens = value;
                }
                if let Some(value) = count(usage.get("output_tokens")) {
                    merged.output_tokens = value;
                }
            }
            ModelApi::Responses | ModelApi::ChatCompletions => {
                let (input, output) = if self.api == ModelApi::Responses {
                    ("input_tokens", "output_tokens")
                } else {
                    ("prompt_tokens", "completion_tokens")
                };
                let details = if self.api == ModelApi::Responses {
                    ("input_tokens_details", "output_tokens_details")
                } else {
                    ("prompt_tokens_details", "completion_tokens_details")
                };
                // OpenAI-compatible prompts include cache reads and writes;
                // DeepSeek reports reads as `prompt_cache_hit_tokens` instead.
                let detail =
                    |key: &str| count(usage.get(details.0).and_then(|detail| detail.get(key)));
                let cached = detail("cached_tokens")
                    .or_else(|| count(usage.get("prompt_cache_hit_tokens")))
                    .unwrap_or_default();
                let written = detail("cache_write_tokens").unwrap_or_default();
                if let Some(prompt) = count(usage.get(input)) {
                    // Clamp malformed counters so the three buckets never exceed the prompt.
                    merged.cache_read_tokens = cached.min(prompt);
                    merged.cache_write_tokens = written.min(prompt - merged.cache_read_tokens);
                    merged.input_tokens =
                        prompt - merged.cache_read_tokens - merged.cache_write_tokens;
                }
                if let Some(value) = count(usage.get(output)) {
                    merged.output_tokens = value;
                }
                if let Some(value) = count(
                    usage
                        .get(details.1)
                        .and_then(|detail| detail.get("reasoning_tokens")),
                ) {
                    merged.reasoning_tokens = Some(value);
                }
            }
        }
        self.usage = Some(merged);
    }
}

fn is_empty(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::String(text) => text.is_empty(),
        Value::Array(items) => items.is_empty(),
        _ => false,
    }
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn observe(api: ModelApi, streaming: bool, chunks: &[(&str, u64)]) -> ModelCall {
        let start = Instant::now();
        let mut observer = ResponseObserver::new(api, 200, streaming, start);
        for (chunk, at) in chunks {
            observer.feed(chunk.as_bytes(), start + Duration::from_millis(*at));
        }
        let end = start + Duration::from_millis(chunks.last().map_or(0, |(_, at)| *at));
        observer.finish(None, end)
    }

    #[test]
    fn only_generation_endpoints_are_model_calls() {
        assert_eq!(
            ModelApi::from_path("/v1/messages"),
            Some(ModelApi::AnthropicMessages)
        );
        assert_eq!(
            ModelApi::from_path("/v1/messages?beta=true"),
            Some(ModelApi::AnthropicMessages)
        );
        assert_eq!(
            ModelApi::from_path("/v1/responses"),
            Some(ModelApi::Responses)
        );
        assert_eq!(
            ModelApi::from_path("/api/v1/chat/completions"),
            Some(ModelApi::ChatCompletions)
        );
        assert_eq!(ModelApi::from_path("/v1/messages/count_tokens"), None);
        assert_eq!(ModelApi::from_path("/v1/models"), None);
    }

    #[test]
    fn anthropic_stream_reports_first_delta_and_merged_usage() {
        // A chunk boundary inside an SSE line must not lose the event.
        let call = observe(ModelApi::AnthropicMessages, true, &[
            ("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":3000,\"cache_creation_input_tokens\":40,\"output_tokens\":1}}}\n\n", 300),
            ("data: {\"type\":\"content_block_start\"}\n\ndata: {\"type\":\"content_bl", 450),
            ("ock_delta\",\"delta\":{\"text\":\"Hi\"}}\n\n", 500),
            ("data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":250}}\n\n", 2500),
        ]);
        assert_eq!(call.first_token_ms, Some(500));
        assert_eq!(call.duration_ms, 2500);
        assert_eq!(
            call.usage,
            Some(ModelCallUsage {
                input_tokens: 12,
                cache_read_tokens: 3000,
                cache_write_tokens: 40,
                output_tokens: 250,
                reasoning_tokens: None,
            })
        );
    }

    #[test]
    fn responses_stream_normalizes_cached_input() {
        let completed = json!({"type": "response.completed", "response": {"usage": {
            "input_tokens": 5000, "input_tokens_details": {"cached_tokens": 4000},
            "output_tokens": 300, "output_tokens_details": {"reasoning_tokens": 120}
        }}});
        let call = observe(ModelApi::Responses, true, &[
            ("data: {\"type\":\"response.created\"}\r\n\r\n", 100),
            ("data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"x\"}\r\n\r\n", 900),
            (&format!("data: {completed}\r\n\r\n"), 1500),
        ]);
        assert_eq!(call.first_token_ms, Some(900));
        let usage = call.usage.unwrap();
        assert_eq!(
            (
                usage.input_tokens,
                usage.cache_read_tokens,
                usage.output_tokens
            ),
            (1000, 4000, 300)
        );
        assert_eq!(usage.reasoning_tokens, Some(120));
    }

    #[test]
    fn openai_compatible_cache_writes_are_a_separate_input_bucket() {
        for (api, usage) in [
            (
                ModelApi::Responses,
                json!({"type": "response.completed", "response": {"usage": {
                "input_tokens": 1000, "input_tokens_details": {"cached_tokens": 600, "cache_write_tokens": 300},
                "output_tokens": 10}}}),
            ),
            (
                ModelApi::ChatCompletions,
                json!({"choices": [], "usage": {
                "prompt_tokens": 1000, "prompt_tokens_details": {"cached_tokens": 600, "cache_write_tokens": 300},
                "completion_tokens": 10}}),
            ),
        ] {
            let call = observe(api, true, &[(&format!("data: {usage}\n\n"), 10)]);
            let usage = call.usage.unwrap();
            assert_eq!(
                (
                    usage.input_tokens,
                    usage.cache_read_tokens,
                    usage.cache_write_tokens
                ),
                (100, 600, 300),
                "{api:?}"
            );
        }
        // Counters larger than the prompt are clamped instead of underflowing.
        let call = observe(ModelApi::ChatCompletions, true, &[(
            "data: {\"usage\":{\"prompt_tokens\":10,\"prompt_tokens_details\":{\"cached_tokens\":8,\"cache_write_tokens\":9}}}\n\n", 5)]);
        let usage = call.usage.unwrap();
        assert_eq!(
            (
                usage.input_tokens,
                usage.cache_read_tokens,
                usage.cache_write_tokens
            ),
            (0, 8, 2)
        );
    }

    #[test]
    fn chat_stream_ignores_role_only_chunks_and_reads_deepseek_cache_hits() {
        let call = observe(ModelApi::ChatCompletions, true, &[
            ("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n", 200),
            ("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Hm\"}}]}\n\n", 700),
            ("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":900,\"prompt_cache_hit_tokens\":600,\"completion_tokens\":80}}\n\ndata: [DONE]\n\n", 1200),
        ]);
        assert_eq!(call.first_token_ms, Some(700));
        let usage = call.usage.unwrap();
        assert_eq!(
            (
                usage.input_tokens,
                usage.cache_read_tokens,
                usage.output_tokens
            ),
            (300, 600, 80)
        );
    }

    #[test]
    fn non_streaming_bodies_have_usage_but_no_first_token() {
        let call = observe(
            ModelApi::AnthropicMessages,
            false,
            &[
                ("{\"usage\":{\"input_tokens\":10,", 400),
                ("\"output_tokens\":20}}", 800),
            ],
        );
        assert!(!call.streaming);
        assert_eq!(call.first_token_ms, None);
        assert_eq!(call.usage.map(|usage| usage.output_tokens), Some(20));
    }

    #[test]
    fn malformed_or_unknown_events_only_remove_fields() {
        // Format drift must degrade to an observation without usage, not a failure.
        let call = observe(
            ModelApi::Responses,
            true,
            &[("data: {not json\n\ndata: {\"type\":\"other\"}\n\n", 50)],
        );
        assert_eq!((call.first_token_ms, call.usage), (None, None));
    }

    #[test]
    fn composition_is_scaled_to_reported_prompt_tokens() {
        let body = json!({
            "model": "claude-test",
            "system": [{"type": "text", "text": "a".repeat(400)}],
            "tools": [
                {"name": "Read", "description": "b".repeat(200), "input_schema": {}},
                {"name": "mcp__dbx__query", "description": "c".repeat(100), "input_schema": {}}
            ],
            "messages": [{"role": "user", "content": "d".repeat(600)}]
        });
        let shape =
            request_shape(ModelApi::AnthropicMessages, body.to_string().as_bytes()).unwrap();
        assert_eq!(shape.model.as_deref(), Some("claude-test"));
        let usage = ModelCallUsage {
            input_tokens: 100,
            cache_read_tokens: 900,
            ..ModelCallUsage::default()
        };
        let composition = shape.composition(Some(&usage));
        assert!(composition.scaled_to_usage);
        assert_eq!((composition.tool_count, composition.mcp_tool_count), (1, 1));
        assert_eq!(
            composition.system_prompt_tokens
                + composition.tool_tokens
                + composition.mcp_tool_tokens
                + composition.message_tokens,
            1000
        );
        assert!(composition.message_tokens > composition.system_prompt_tokens);
        assert!(composition.tool_tokens > composition.mcp_tool_tokens);
    }

    #[test]
    fn openai_instructions_and_developer_messages_count_as_system_prompt() {
        let body = json!({
            "instructions": "x".repeat(40),
            "input": [
                {"role": "developer", "content": "y".repeat(40)},
                {"role": "user", "content": "hello"}
            ],
            "tools": [{"type": "function", "name": "shell"}, {"type": "web_search"}]
        });
        let shape = request_shape(ModelApi::Responses, body.to_string().as_bytes()).unwrap();
        let composition = shape.composition(None);
        assert!(!composition.scaled_to_usage);
        assert_eq!(composition.system_prompt_tokens, 20);
        assert_eq!(composition.tool_count, 2);
        assert!(request_shape(ModelApi::Responses, b"not json").is_none());
    }

    #[test]
    fn allocation_preserves_the_total_deterministically() {
        assert_eq!(allocate(10, [1, 1, 1, 0]), [4, 3, 3, 0]);
        assert_eq!(allocate(7, [0, 0, 0, 0]), [0, 0, 0, 7]);
        assert_eq!(
            allocate(u64::MAX, [u64::MAX, 1, 0, 0])
                .iter()
                .map(|part| u128::from(*part))
                .sum::<u128>(),
            u128::from(u64::MAX)
        );
    }
}
