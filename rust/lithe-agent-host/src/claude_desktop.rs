//! Readable replay of sessions started in Claude Desktop.
//!
//! Claude Desktop runs Claude Code with its own `ccd_turn` MCP server. The
//! model there rarely writes prose: it reports progress through `update_plan`
//! and ends a turn with a `wrap_up` recap, which Desktop renders as a checklist
//! and a card. Resumed in Lithe, both would be anonymous rows in the collapsed
//! process area and the transcript would look empty. This presenter turns them
//! into what Desktop shows: an ACP `plan` update and an agent message. It
//! applies to the adapter's replay and to the earlier history read from disk
//! alike; Lithe never offers the `ccd_turn` tools, so live turns are unaffected.

use std::collections::{HashMap, HashSet};

use serde_json::{json, Value};

/// Tool Claude Desktop's model uses to end a turn with a recap and a question.
const WRAP_UP_TOOL: &str = "mcp__ccd_turn__wrap_up";
/// Tool Claude Desktop's model uses to set or advance its step checklist.
const UPDATE_PLAN_TOOL: &str = "mcp__ccd_turn__update_plan";

/// One checklist step; `status` is an ACP plan status
/// (`pending`, `in_progress` or `completed`).
#[derive(Clone)]
struct Step {
    content: String,
    status: &'static str,
}

#[derive(Default)]
pub(crate) struct Presenter {
    /// Tool call ids already shown another way; their follow-up
    /// `tool_call_update`s (status, the tool's acknowledgement) are dropped.
    absorbed: HashSet<String>,
    /// Latest checklist per session. `update_plan` may only advance or tick
    /// steps of the list set earlier, so each call is applied to this state.
    plans: HashMap<String, Vec<Step>>,
}

impl Presenter {
    /// `update` as the client should see it, or None when it is absorbed.
    pub(crate) fn present(&mut self, session_id: &str, update: Value) -> Option<Value> {
        let Some(id) = update["toolCallId"].as_str().map(str::to_owned) else {
            return Some(update);
        };
        let shown = match update["sessionUpdate"].as_str() {
            Some("tool_call") if update["name"] == WRAP_UP_TOOL => {
                wrap_up_text(&update["rawInput"]).map(|text| {
                    json!({
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": text},
                    })
                })
            }
            Some("tool_call") if update["name"] == UPDATE_PLAN_TOOL => {
                let steps = self.plans.entry(session_id.to_owned()).or_default();
                apply_plan(steps, &update["rawInput"]).then(|| plan_update(steps))
            }
            Some("tool_call_update") if self.absorbed.contains(&id) => return None,
            _ => None,
        };
        match shown {
            Some(shown) => {
                self.absorbed.insert(id);
                Some(shown)
            }
            None => Some(update),
        }
    }
}

/// The recap followed by the question, as separate paragraphs. The suggested
/// replies are buttons in Desktop; the prompt the user chose follows in the
/// transcript, so they are not repeated here.
fn wrap_up_text(input: &Value) -> Option<String> {
    let text = ["recap", "ask"]
        .iter()
        .filter_map(|key| input[key].as_str().map(str::trim).filter(|v| !v.is_empty()))
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.is_empty()).then_some(text)
}

/// Applies one `update_plan` input and reports whether it changed anything.
/// Inputs either replace the list (`items`), tick steps by one-based index
/// (`done`) and start one (`start`), or `advance`: finish the running step
/// and start the next pending one.
fn apply_plan(steps: &mut Vec<Step>, input: &Value) -> bool {
    if let Some(items) = input["items"].as_array() {
        *steps = items
            .iter()
            .filter_map(|item| {
                Some(Step {
                    content: item["content"].as_str()?.to_owned(),
                    status: status(item["status"].as_str()),
                })
            })
            .collect();
        return !steps.is_empty();
    }
    if steps.is_empty() {
        return false;
    }
    let mut changed = false;
    let mut set = |index: usize, value: &'static str| {
        if let Some(step) = index.checked_sub(1).and_then(|i| steps.get_mut(i)) {
            step.status = value;
            changed = true;
        }
    };
    for index in input["done"].as_array().into_iter().flatten() {
        set(index.as_u64().unwrap_or(0) as usize, "completed");
    }
    if let Some(index) = input["start"].as_u64() {
        set(index as usize, "in_progress");
    }
    if input["advance"] == true {
        let running = steps.iter().position(|s| s.status == "in_progress");
        if let Some(index) = running {
            steps[index].status = "completed";
        }
        let from = running.map_or(0, |index| index + 1);
        if let Some(next) = steps[from..].iter_mut().find(|s| s.status == "pending") {
            next.status = "in_progress";
        }
        changed = true;
    }
    changed
}

fn status(value: Option<&str>) -> &'static str {
    match value {
        Some("completed") => "completed",
        Some("in_progress") => "in_progress",
        _ => "pending",
    }
}

fn plan_update(steps: &[Step]) -> Value {
    let entries: Vec<Value> = steps
        .iter()
        .map(|step| json!({"content": step.content, "status": step.status, "priority": "medium"}))
        .collect();
    json!({"sessionUpdate": "plan", "entries": entries})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(name: &str, id: &str, input: Value) -> Value {
        json!({"sessionUpdate": "tool_call", "toolCallId": id, "name": name,
               "title": name, "status": "pending", "rawInput": input})
    }

    fn done(id: &str) -> Value {
        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"})
    }

    fn statuses(update: &Value) -> Vec<&str> {
        update["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["status"].as_str().unwrap())
            .collect()
    }

    #[test]
    fn a_wrap_up_becomes_the_turn_answer_and_its_updates_are_absorbed() {
        let mut presenter = Presenter::default();
        let input = json!({"recap": "PR opened.", "ask": "Mark it ready?",
                           "actions": [{"label": "Yes", "message": "yes"}]});
        let shown = presenter
            .present("s", call(WRAP_UP_TOOL, "w", input))
            .unwrap();
        assert_eq!(shown["sessionUpdate"], "agent_message_chunk");
        assert_eq!(shown["content"]["text"], "PR opened.\n\nMark it ready?");
        assert!(presenter.present("s", done("w")).is_none());
    }

    #[test]
    fn plan_calls_become_plan_updates_that_track_incremental_progress() {
        let mut presenter = Presenter::default();
        let items = json!({"items": [
            {"content": "a", "status": "in_progress"},
            {"content": "b", "status": "pending"},
            {"content": "c", "status": "pending"},
        ]});
        let set = presenter
            .present("s", call(UPDATE_PLAN_TOOL, "p1", items))
            .unwrap();
        assert_eq!(set["sessionUpdate"], "plan");
        assert_eq!(statuses(&set), ["in_progress", "pending", "pending"]);
        assert!(presenter.present("s", done("p1")).is_none());

        let advanced = presenter
            .present("s", call(UPDATE_PLAN_TOOL, "p2", json!({"advance": true})))
            .unwrap();
        assert_eq!(statuses(&advanced), ["completed", "in_progress", "pending"]);

        let ticked = presenter
            .present(
                "s",
                call(UPDATE_PLAN_TOOL, "p3", json!({"done": [2], "start": 3})),
            )
            .unwrap();
        assert_eq!(statuses(&ticked), ["completed", "completed", "in_progress"]);
    }

    #[test]
    fn other_tools_empty_calls_and_unknown_sessions_pass_through() {
        let mut presenter = Presenter::default();
        let empty = call(WRAP_UP_TOOL, "w", json!({}));
        assert_eq!(presenter.present("s", empty.clone()), Some(empty));
        assert_eq!(presenter.present("s", done("w")), Some(done("w")));
        // An increment without a list to apply it to stays a plain tool call.
        let orphan = call(UPDATE_PLAN_TOOL, "p", json!({"advance": true}));
        assert_eq!(presenter.present("t", orphan.clone()), Some(orphan));
        let text = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}});
        assert_eq!(presenter.present("s", text.clone()), Some(text));
    }
}
