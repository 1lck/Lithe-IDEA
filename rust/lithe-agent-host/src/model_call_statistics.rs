//! Shared accounting rules for observed model calls.
//!
//! The Host attaches one [`ModelCallStatistics`] contribution to every
//! `modelCall` event, so both desktop products count the same request the same
//! way: which calls are conversation steps, which failed, which count as
//! non-streaming, which timings describe generation speed, and which request
//! describes the current context. Platforms only add contributions with
//! [`ModelCallStatistics::merge`]; they never reinterpret a raw call.
//! Contract: `shared/fixtures/agent/model-call-statistics-v1.json`.

use std::collections::HashSet;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::model_calls::{ContextComposition, ModelCall};

/// Additive statistics of one or more observed calls.
///
/// Every counter is a sum, `reasoning_tokens` is a sum over the calls that
/// reported it, and `context` is the latest composition that may describe the
/// conversation's current prompt. Merging contributions in event order yields
/// the totals of a turn or a session.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCallStatistics {
    /// Observed provider requests, including auxiliary ones.
    pub requests: u64,
    /// Requests that are steps of the conversation (not auxiliary).
    pub steps: u64,
    /// Steps whose HTTP status is 400 or higher, including transport failures.
    pub failed_steps: u64,
    /// Successful steps answered without streaming. A failed response is an
    /// error body, not a non-streaming answer, so it is never counted here.
    pub non_streaming_steps: u64,
    /// Milliseconds of complete step requests, including time to first token.
    pub duration_ms: u64,
    /// Provider prompt tokens outside the cache, from every request with usage.
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    /// Sum of reported reasoning tokens; absent when no call reported any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_tokens: Option<u64>,
    /// Requests whose response carried usage counters. Token sums cover only
    /// these, so `requests > calls_with_usage` marks the sums as a lower bound.
    pub calls_with_usage: u64,
    /// Sum and count of first-token latencies of streaming steps.
    pub first_token_ms: u64,
    pub first_token_count: u64,
    /// Streaming time after the first token and the output produced in it;
    /// their ratio is the generation speed.
    pub generation_ms: u64,
    pub generated_tokens: u64,
    /// Composition that replaces the current context, or absent when this
    /// contribution does not describe the conversation's prompt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<ContextComposition>,
}

impl ModelCallStatistics {
    /// Contribution of one call. `sends_tools` is the per-session memory that
    /// the conversation's main requests carry tool definitions; once set, only
    /// tool-carrying requests describe the current context, because tool-less
    /// ones are background requests the marker did not recognize.
    pub fn of_call(call: &ModelCall, sends_tools: &mut bool) -> Self {
        let mut statistics = Self {
            requests: 1,
            ..Self::default()
        };
        if let Some(usage) = call.usage {
            statistics.calls_with_usage = 1;
            statistics.input_tokens = usage.input_tokens;
            statistics.cache_read_tokens = usage.cache_read_tokens;
            statistics.cache_write_tokens = usage.cache_write_tokens;
            statistics.output_tokens = usage.output_tokens;
            statistics.reasoning_tokens = usage.reasoning_tokens;
        }
        if call.auxiliary {
            // Its tokens were spent, but a title request is neither a step nor
            // a measure of latency, generation speed, or the current context.
            return statistics;
        }
        let failed = call.status >= 400;
        statistics.steps = 1;
        statistics.failed_steps = u64::from(failed);
        statistics.non_streaming_steps = u64::from(!call.streaming && !failed);
        statistics.duration_ms = call.duration_ms;
        if let (true, Some(first_token)) = (call.streaming, call.first_token_ms) {
            statistics.first_token_ms = first_token;
            statistics.first_token_count = 1;
            if let Some(usage) = call.usage.filter(|_| call.duration_ms > first_token) {
                statistics.generation_ms = call.duration_ms - first_token;
                statistics.generated_tokens = usage.output_tokens;
            }
        }
        if let Some(context) = call.context {
            let carries_tools = context.tool_count + context.mcp_tool_count > 0;
            if carries_tools || !*sends_tools {
                statistics.context = Some(context);
            }
            *sends_tools |= carries_tools;
        }
        statistics
    }

    /// Adds a later contribution. A later context replaces an earlier one.
    pub fn merge(&mut self, later: &Self) {
        self.requests += later.requests;
        self.steps += later.steps;
        self.failed_steps += later.failed_steps;
        self.non_streaming_steps += later.non_streaming_steps;
        self.duration_ms += later.duration_ms;
        self.input_tokens += later.input_tokens;
        self.cache_read_tokens += later.cache_read_tokens;
        self.cache_write_tokens += later.cache_write_tokens;
        self.output_tokens += later.output_tokens;
        if let Some(reasoning) = later.reasoning_tokens {
            self.reasoning_tokens = Some(self.reasoning_tokens.unwrap_or(0) + reasoning);
        }
        self.calls_with_usage += later.calls_with_usage;
        self.first_token_ms += later.first_token_ms;
        self.first_token_count += later.first_token_count;
        self.generation_ms += later.generation_ms;
        self.generated_tokens += later.generated_tokens;
        if later.context.is_some() {
            self.context = later.context;
        }
    }
}

/// Per-connection memory of which sessions' main requests carry tools.
/// Bounded by the sessions a connection prompts, which the connection owns.
#[derive(Default)]
pub(crate) struct StatisticsTracker {
    sessions_sending_tools: Mutex<HashSet<String>>,
}

impl StatisticsTracker {
    /// Contribution of a call attributed to `session_id`. Unattributed calls
    /// are dropped by both products, so they keep no per-session memory.
    pub(crate) fn contribution(&self, session_id: Option<&str>, call: &ModelCall) -> ModelCallStatistics {
        let Some(session_id) = session_id else {
            return ModelCallStatistics::of_call(call, &mut false);
        };
        let Ok(mut sessions) = self.sessions_sending_tools.lock() else {
            return ModelCallStatistics::of_call(call, &mut false);
        };
        let mut sends_tools = sessions.contains(session_id);
        let statistics = ModelCallStatistics::of_call(call, &mut sends_tools);
        if sends_tools {
            sessions.insert(session_id.to_owned());
        }
        statistics
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model_calls::{ModelApi, ModelCallUsage};
    use serde_json::Value;

    fn call(value: &Value) -> ModelCall {
        let usage = value.get("usage").map(|usage| ModelCallUsage {
            input_tokens: usage["inputTokens"].as_u64().unwrap(),
            cache_read_tokens: usage["cacheReadTokens"].as_u64().unwrap(),
            cache_write_tokens: usage["cacheWriteTokens"].as_u64().unwrap(),
            output_tokens: usage["outputTokens"].as_u64().unwrap(),
            reasoning_tokens: usage["reasoningTokens"].as_u64(),
        });
        let context = value.get("context").map(|context| ContextComposition {
            system_prompt_tokens: context["systemPromptTokens"].as_u64().unwrap(),
            tool_tokens: context["toolTokens"].as_u64().unwrap(),
            mcp_tool_tokens: context["mcpToolTokens"].as_u64().unwrap(),
            message_tokens: context["messageTokens"].as_u64().unwrap(),
            tool_count: context["toolCount"].as_u64().unwrap() as u32,
            mcp_tool_count: context["mcpToolCount"].as_u64().unwrap() as u32,
            scaled_to_usage: context["scaledToUsage"].as_bool().unwrap(),
        });
        ModelCall {
            api: serde_json::from_value::<ModelApiName>(value["api"].clone()).unwrap().0,
            model: None,
            status: value["status"].as_u64().unwrap() as u16,
            streaming: value["streaming"].as_bool().unwrap_or(false),
            first_token_ms: value["firstTokenMs"].as_u64(),
            duration_ms: value["durationMs"].as_u64().unwrap(),
            usage,
            context,
            auxiliary: value["auxiliary"].as_bool().unwrap_or(false),
        }
    }

    /// `ModelApi` is output-only on the wire; the fixture names it by its value.
    struct ModelApiName(ModelApi);
    impl<'de> Deserialize<'de> for ModelApiName {
        fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
            Ok(Self(match String::deserialize(deserializer)?.as_str() {
                "anthropicMessages" => ModelApi::AnthropicMessages,
                "responses" => ModelApi::Responses,
                _ => ModelApi::ChatCompletions,
            }))
        }
    }

    /// Every fixture case fixes each call's contribution and the merged
    /// totals both desktop products must display.
    #[test]
    fn fixture_contributions_and_totals_match() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/agent/model-call-statistics-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let tracker = StatisticsTracker::default();
            let mut total = ModelCallStatistics::default();
            let events = case["events"].as_array().unwrap();
            for (index, event) in events.iter().enumerate() {
                let contribution =
                    tracker.contribution(event["sessionId"].as_str(), &call(&event["call"]));
                let expected: ModelCallStatistics =
                    serde_json::from_value(event["statistics"].clone()).unwrap();
                assert_eq!(contribution, expected, "{name} call {index}");
                assert_eq!(
                    serde_json::to_value(&contribution).unwrap(),
                    event["statistics"],
                    "{name} call {index} wire shape"
                );
                total.merge(&contribution);
            }
            let expected: ModelCallStatistics =
                serde_json::from_value(case["total"].clone()).unwrap();
            assert_eq!(total, expected, "{name} total");
        }
    }

    /// Sessions keep separate tool memory: one session's tool-carrying
    /// request must not freeze another session's tool-less composition.
    #[test]
    fn tool_memory_is_per_session() {
        let tracker = StatisticsTracker::default();
        let tools = call(&serde_json::json!({"api":"responses","status":200,"durationMs":1,
            "context":{"systemPromptTokens":1,"toolTokens":1,"mcpToolTokens":0,"messageTokens":1,"toolCount":1,"mcpToolCount":0,"scaledToUsage":false}}));
        let toolless = call(&serde_json::json!({"api":"responses","status":200,"durationMs":1,
            "context":{"systemPromptTokens":1,"toolTokens":0,"mcpToolTokens":0,"messageTokens":9,"toolCount":0,"mcpToolCount":0,"scaledToUsage":false}}));
        assert!(tracker.contribution(Some("a"), &tools).context.is_some());
        assert!(tracker.contribution(Some("a"), &toolless).context.is_none());
        assert!(tracker.contribution(Some("b"), &toolless).context.is_some());
    }
}
