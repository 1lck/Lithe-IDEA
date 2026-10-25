//! Readable replay of sessions started in Claude Desktop.
//!
//! Claude Desktop runs Claude Code with its own MCP servers (`ccd_turn`,
//! `ccd_session`, `ccd_pr`, `ccd_view`, `visualize`, `terminal`, …). The model
//! there reports progress, ends turns, proposes follow-up tasks and binds pull
//! requests through those tools, and Desktop draws each as part of its UI.
//! Resumed in Lithe, they would be anonymous `mcp__…` rows in the collapsed
//! process area and the transcript would look empty or cryptic.
//!
//! This presenter turns them into what Desktop shows, in two ways:
//!
//! - Standard ACP where it has a shape: `wrap_up` becomes the turn's agent
//!   message, `update_plan` a `plan` update, files a pane showed become tool
//!   locations.
//! - A card for mechanisms ACP has no shape for, as `_meta.lithe.claudeDesktop`
//!   on the tool call (see `shared/contracts/application-boundary.md`). Every
//!   such call keeps a readable English title and kind, so a client that does
//!   not draw the card still shows a sensible tool row.
//!
//! It applies to the adapter's replay and to the earlier history read from disk
//! alike. Lithe never offers these tools, so live turns are unaffected.

use std::collections::{HashMap, HashSet};

use serde_json::{json, Value};

/// Tool Claude Desktop's model uses to end a turn with a recap and a question.
const WRAP_UP_TOOL: &str = "mcp__ccd_turn__wrap_up";
/// Tool Claude Desktop's model uses to set or advance its step checklist.
const UPDATE_PLAN_TOOL: &str = "mcp__ccd_turn__update_plan";
/// Widget source above this many characters is not carried in the card.
const WIDGET_CODE_LIMIT: usize = 256 * 1024;
/// Limit for prompts, summaries and other free text carried in a card.
const CARD_TEXT_LIMIT: usize = 16 * 1024;

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
    /// Readable title and kind per retitled call, kept so a later update that
    /// restates the adapter's own title does not undo them.
    titles: HashMap<String, (String, &'static str)>,
    /// Task cards by tool call id, kept so a later call can change their state.
    tasks: HashMap<String, Value>,
    /// Desktop task id (`task_…`) → tool call id of the card that proposed it.
    task_ids: HashMap<String, String>,
    /// Calls that change a task card once their result arrives, by tool call id.
    task_changes: HashMap<String, TaskChange>,
}

/// A `dismiss_task` or `start_session` call held back until its result says
/// whether the card it targets really changed.
struct TaskChange {
    task: String,
    /// State a successful result means.
    state: &'static str,
    /// The call as a readable tool row, shown only if the call fails.
    call: Value,
}

impl Presenter {
    /// `update` as the client should see it: usually one update, none when it
    /// is absorbed, two when a turn's recap also offers suggested replies.
    pub(crate) fn present(&mut self, session_id: &str, update: Value) -> Vec<Value> {
        if update["sessionUpdate"] == "agent_message_chunk" {
            return vec![present_pr_created(update)];
        }
        let Some(id) = update["toolCallId"].as_str().map(str::to_owned) else {
            return vec![update];
        };
        match update["sessionUpdate"].as_str() {
            Some("tool_call") => self.tool_call(session_id, id, update),
            Some("tool_call_update") => self.tool_call_update(id, update),
            _ => vec![update],
        }
    }

    fn tool_call(&mut self, session_id: &str, id: String, update: Value) -> Vec<Value> {
        let Some(name) = update["name"].as_str().map(str::to_owned) else {
            return vec![update];
        };
        let input = update["rawInput"].clone();
        match name.as_str() {
            WRAP_UP_TOOL => {
                let Some(text) = wrap_up_text(&input) else {
                    return vec![update];
                };
                self.absorbed.insert(id.clone());
                let mut shown = vec![json!({
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text},
                })];
                // The suggested replies are buttons in Desktop's next-step box.
                if let Some(actions) = next_step_actions(&input) {
                    let mut replies = json!({
                        "sessionUpdate": "tool_call",
                        "toolCallId": format!("{id}#next"),
                        "title": "Suggested replies",
                        "kind": "other",
                        "status": "completed",
                    });
                    set_card(&mut replies, json!({"card": "nextStep", "actions": actions}));
                    shown.push(replies);
                }
                shown
            }
            UPDATE_PLAN_TOOL => {
                let steps = self.plans.entry(session_id.to_owned()).or_default();
                if apply_plan(steps, &input) {
                    self.absorbed.insert(id);
                    return vec![plan_update(steps)];
                }
                self.retitle(id, update, "Updated the task list", "think")
            }
            "mcp__ccd_session__dismiss_task" => {
                // Shown as the state of the card it withdraws, once the result confirms it.
                if let Some(task) = str_field(&input, "task_id") {
                    let call = readable_call(update, "Withdrew a suggested task");
                    self.task_changes.insert(id.clone(), TaskChange { task: task.to_owned(), state: "withdrawn", call });
                }
                self.absorbed.insert(id);
                Vec::new()
            }
            "mcp__ccd_session__start_session" if str_field(&input, "proposal_id").is_some() => {
                // Starting a proposed card: the card itself changes state.
                let task = str_field(&input, "proposal_id").unwrap_or_default().to_owned();
                let call = readable_call(update, "Started a suggested task");
                self.task_changes.insert(id.clone(), TaskChange { task, state: "started", call });
                self.absorbed.insert(id);
                Vec::new()
            }
            _ => {
                let Some(described) = describe(&name, &input) else {
                    return vec![update];
                };
                let mut update = update;
                if !described.locations.is_empty() {
                    update["locations"] = Value::Array(described.locations);
                }
                if let Some(card) = described.card {
                    if card["card"] == "task" {
                        self.tasks.insert(id.clone(), card.clone());
                    }
                    set_card(&mut update, card);
                }
                self.retitle(id, update, &described.title, described.kind)
            }
        }
    }

    fn tool_call_update(&mut self, id: String, mut update: Value) -> Vec<Value> {
        if self.task_changes.contains_key(&id) {
            return self.finish_task_change(&id, update);
        }
        if self.absorbed.contains(&id) {
            return Vec::new();
        }
        if self.tasks.contains_key(&id) {
            if let Some(task) = task_id_in(&result_text(&update)) {
                self.task_ids.insert(task, id.clone());
            }
        }
        if let Some((title, kind)) = self.titles.get(&id) {
            if update.get("title").is_some() {
                update["title"] = json!(title);
                update["kind"] = json!(kind);
            }
        }
        vec![update]
    }

    /// A held-back task call got an update: wait out progress, apply a success
    /// to its card, and keep a failure visible, since nothing changed.
    fn finish_task_change(&mut self, id: &str, update: Value) -> Vec<Value> {
        let status = update["status"].as_str();
        if !matches!(status, Some("completed" | "failed")) {
            return Vec::new();
        }
        let Some(change) = self.task_changes.remove(id) else {
            return vec![update];
        };
        self.absorbed.remove(id);
        if status == Some("failed") {
            return vec![change.call, update];
        }
        // dismiss_task reports a task the user already started instead of withdrawing it.
        let text = result_text(&update);
        let state = if text.contains("already started") || text.contains("no longer pending") {
            "started"
        } else {
            change.state
        };
        self.change_task(&change.task, state)
    }

    fn retitle(&mut self, id: String, mut update: Value, title: &str, kind: &'static str) -> Vec<Value> {
        update["title"] = json!(title);
        update["kind"] = json!(kind);
        self.titles.insert(id, (title.to_owned(), kind));
        vec![update]
    }

    /// The card that proposed `task`, now in `state`.
    fn change_task(&mut self, task: &str, state: &'static str) -> Vec<Value> {
        let Some(call) = self.task_ids.get(task).cloned() else {
            return Vec::new();
        };
        let Some(card) = self.tasks.get_mut(&call) else {
            return Vec::new();
        };
        card["state"] = json!(state);
        let mut update = json!({"sessionUpdate": "tool_call_update", "toolCallId": call});
        set_card(&mut update, card.clone());
        vec![update]
    }
}

/// `call` as an ordinary tool row with a readable title.
fn readable_call(mut call: Value, title: &str) -> Value {
    call["title"] = json!(title);
    call["kind"] = json!("other");
    call
}

/// Whether a tool's input feeds a card, plan or reply, so a replay must carry
/// it whole instead of cut for a tool-detail preview.
pub(crate) fn carries_card_input(name: &str) -> bool {
    name.strip_prefix("mcp__")
        .and_then(|rest| rest.split_once("__"))
        .is_some_and(|(server, _)| {
            matches!(
                server,
                "ccd_turn" | "ccd_session" | "ccd_pr" | "ccd_directory" | "ccd_view" | "ccd_host" | "visualize"
            )
        })
}

/// Largest string of such an input a replay carries; the widget source limit
/// is the largest of the card fields.
pub(crate) const CARD_INPUT_LIMIT: usize = WIDGET_CODE_LIMIT;

/// Readable presentation of one Desktop tool call.
struct Described {
    title: String,
    kind: &'static str,
    locations: Vec<Value>,
    card: Option<Value>,
}

impl Described {
    fn row(title: impl Into<String>, kind: &'static str) -> Self {
        Self { title: title.into(), kind, locations: Vec::new(), card: None }
    }

    fn card(title: impl Into<String>, card: Value) -> Self {
        Self { card: Some(card), ..Self::row(title, "other") }
    }
}

/// Title, kind and card for a Desktop tool, or None for any other tool.
fn describe(name: &str, input: &Value) -> Option<Described> {
    let (server, tool) = name.strip_prefix("mcp__")?.split_once("__")?;
    let field = |key: &str| str_field(input, key);
    let described = match (server, tool) {
        ("ccd_session", "mark_chapter") => {
            let title = field("title")?;
            Described::card(
                format!("Chapter: {title}"),
                json!({"card": "chapter", "title": title, "summary": field("summary")}),
            )
        }
        ("ccd_session", "spawn_task") => {
            task_card(field("title")?, field("tldr"), field("prompt"), "proposed")
        }
        ("ccd_session", "start_session") => task_card(
            field("title")?,
            None,
            field("prompt"),
            // The model may only propose; a start the user asked for runs at once.
            if field("initiation") == Some("own_initiative") { "proposed" } else { "started" },
        ),
        ("ccd_session", "hand_off_to_session") => {
            let plan = field("remaining_plan");
            let summary = plan.and_then(|plan| plan.lines().map(str::trim).find(|line| !line.is_empty()));
            task_card(field("title")?, summary, plan, "handedOff")
        }
        ("ccd_session", "read_widget_context") => Described::row("Read the widget's context", "read"),
        ("ccd_pr", "get_status") => Described::row("Checked the pull request status", "read"),
        ("ccd_pr", action @ ("bind_pr" | "unbind_pr" | "set_monitor" | "set_auto_merge")) => {
            let url = field("url");
            let action = match action {
                "bind_pr" => "bound",
                "unbind_pr" => "unbound",
                "set_monitor" => "monitored",
                _ => "autoMerge",
            };
            let mut card = json!({"card": "pullRequest", "action": action, "url": url});
            if let Some(number) = url.and_then(pr_number) {
                card["number"] = json!(number);
            }
            match action {
                "monitored" => card["autoFix"] = json!(input["auto_fix"] == true),
                "autoMerge" => card["enabled"] = json!(input["enabled"] != false),
                _ => {}
            }
            let title = url.map_or("Pull request".to_owned(), |url| format!("Pull request {url}"));
            Described::card(title, card)
        }
        ("ccd_directory", action @ ("change_directory" | "request_directory")) => {
            let path = field("path")?;
            let action = if action == "change_directory" { "changed" } else { "requested" };
            Described::card(
                format!("Working folder {path}"),
                json!({"card": "directory", "action": action, "path": path}),
            )
        }
        ("ccd_view", "show_pane") => match field("path") {
            Some(path) => Described {
                locations: vec![json!({"path": path})],
                ..Described::row(format!("Showed {path}"), "read")
            },
            None => Described::row(format!("Showed the {} pane", field("pane").unwrap_or("side")), "other"),
        },
        ("ccd_host", tool @ ("open_in_editor" | "reveal_path")) => {
            let path = field("path")?;
            let verb = if tool == "open_in_editor" { "Opened" } else { "Revealed" };
            let mut location = json!({"path": path});
            if let Some(line) = input["line"].as_u64().filter(|line| *line > 0) {
                location["line"] = json!(line);
            }
            Described { locations: vec![location], ..Described::row(format!("{verb} {path}"), "read") }
        }
        ("visualize", "show_widget") => {
            let title = humanize(field("title").unwrap_or("visualization"));
            let code = field("widget_code").filter(|code| code.chars().count() <= WIDGET_CODE_LIMIT);
            Described::card(
                format!("Visualization: {title}"),
                json!({"card": "widget", "title": title, "code": code}),
            )
        }
        ("visualize", "read_me") => Described::row("Read the visualization guide", "read"),
        ("terminal", "run_in_terminal") => Described::row(
            field("command").map_or("Ran a command in a terminal tab".to_owned(), first_line),
            "execute",
        ),
        ("terminal", "read_terminal") => Described::row("Read a terminal tab", "read"),
        ("Claude_Browser", "navigate") => Described::row(
            field("url").map_or("Opened a page".to_owned(), |url| format!("Opened {url}")),
            "fetch",
        ),
        (server, tool) => {
            let area = match server {
                "ccd_turn" | "ccd_session" | "ccd_session_mgmt" | "ccd_sidebar" | "ccd_window"
                | "ccd_view" | "ccd_settings" | "ccd_host" | "ccd_pr" | "ccd_directory"
                | "ccd_connectors" => "Claude Desktop",
                "Claude_Browser" => "Browser",
                "computer-use" => "Computer use",
                "terminal" => "Terminal",
                "scheduled-tasks" => "Scheduled tasks",
                "visualize" => "Visualization",
                // Desktop names a claude.ai connector by its id, which says nothing to the user.
                _ if is_connector_id(server) => "Connector",
                _ => return None,
            };
            let kind = match tool.split('_').next() {
                Some("list" | "get" | "read" | "search" | "find") => "read",
                _ => "other",
            };
            Described::row(format!("{area}: {}", humanize(tool)), kind)
        }
    };
    Some(described)
}

/// A UUID in its 8-4-4-4-12 form.
fn is_connector_id(server: &str) -> bool {
    let groups: Vec<_> = server.split('-').collect();
    groups.len() == 5
        && groups.iter().zip([8, 4, 4, 4, 12]).all(|(group, len)| {
            group.len() == len && group.chars().all(|c| c.is_ascii_hexdigit())
        })
}

fn task_card(title: &str, summary: Option<&str>, prompt: Option<&str>, state: &str) -> Described {
    Described::card(
        format!("Suggested task: {title}"),
        json!({
            "card": "task",
            "title": title,
            "summary": summary.map(|text| truncate(text, CARD_TEXT_LIMIT)),
            "prompt": prompt.map(|text| truncate(text, CARD_TEXT_LIMIT)),
            "state": state,
        }),
    )
}

fn set_card(update: &mut Value, card: Value) {
    if !update["_meta"].is_object() {
        update["_meta"] = json!({});
    }
    if !update["_meta"]["lithe"].is_object() {
        update["_meta"]["lithe"] = json!({});
    }
    update["_meta"]["lithe"]["claudeDesktop"] = card;
}

fn str_field<'a>(input: &'a Value, key: &str) -> Option<&'a str> {
    input[key].as_str().map(str::trim).filter(|value| !value.is_empty())
}

/// The recap followed by the question, as separate paragraphs.
fn wrap_up_text(input: &Value) -> Option<String> {
    let text = ["recap", "ask"]
        .iter()
        .filter_map(|key| str_field(input, key))
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.is_empty()).then_some(text)
}

/// Suggested replies that send a message. A label-only action only closes
/// Desktop's box, so it has nothing to offer here.
fn next_step_actions(input: &Value) -> Option<Vec<Value>> {
    let actions: Vec<Value> = input["actions"]
        .as_array()?
        .iter()
        .filter_map(|action| {
            let label = str_field(action, "label")?;
            let message = str_field(action, "message")?;
            Some(json!({"label": label, "message": truncate(message, CARD_TEXT_LIMIT)}))
        })
        .take(4)
        .collect();
    (!actions.is_empty()).then_some(actions)
}

/// Desktop asks the model to wrap a created PR's URL in `<pr-created>` so it
/// can draw a status card; elsewhere the tag is noise around a link.
fn present_pr_created(mut update: Value) -> Value {
    const OPEN: &str = "<pr-created>";
    const CLOSE: &str = "</pr-created>";
    let Some(text) = update["content"]["text"].as_str().filter(|text| text.contains(OPEN)) else {
        return update;
    };
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        let after = &rest[start + OPEN.len()..];
        let Some(end) = after.find(CLOSE) else { break };
        let url = after[..end].trim();
        out.push_str(&rest[..start]);
        if url.starts_with("https://") && !url.contains(char::is_whitespace) {
            match pr_number(url) {
                Some(number) => out.push_str(&format!("[Pull request #{number}]({url})")),
                None => out.push_str(&format!("[{url}]({url})")),
            }
        } else {
            out.push_str(&rest[start..start + OPEN.len() + end + CLOSE.len()]);
        }
        rest = &after[end + CLOSE.len()..];
    }
    out.push_str(rest);
    update["content"]["text"] = json!(out);
    update
}

/// Number of a GitHub-style `…/pull/<n>` URL.
fn pr_number(url: &str) -> Option<u64> {
    let (_, tail) = url.rsplit_once("/pull/")?;
    tail.split(['/', '#', '?']).next()?.parse().ok()
}

/// Text of a tool result update's content blocks.
fn result_text(update: &Value) -> String {
    update["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| item["content"]["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// First `task_<id>` Desktop names in a tool result, past its `task_id:` label.
fn task_id_in(text: &str) -> Option<String> {
    text.match_indices("task_")
        .map(|(start, _)| {
            text[start..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect::<String>()
        })
        .find(|id| id != "task_id" && id.len() > "task_".len())
}

/// `list_sessions` → `list sessions`.
fn humanize(name: &str) -> String {
    name.replace(['_', '-'], " ")
}

fn first_line(text: &str) -> String {
    truncate(text.lines().next().unwrap_or(text), 200)
}

fn truncate(text: &str, limit: usize) -> String {
    match text.char_indices().nth(limit) {
        Some((index, _)) => format!("{}…", &text[..index]),
        None => text.to_owned(),
    }
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

    fn result(id: &str, text: &str) -> Value {
        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed",
               "content": [{"type": "content", "content": {"type": "text", "text": text}}]})
    }

    fn one(mut shown: Vec<Value>) -> Value {
        assert_eq!(shown.len(), 1, "{shown:?}");
        shown.remove(0)
    }

    fn card(update: &Value) -> &Value {
        &update["_meta"]["lithe"]["claudeDesktop"]
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
    fn a_wrap_up_becomes_the_turn_answer_with_its_suggested_replies() {
        let mut presenter = Presenter::default();
        let input = json!({"recap": "PR opened.", "ask": "Mark it ready?",
                           "actions": [{"label": "Yes", "message": "yes"}, {"label": "Not now"}]});
        let shown = presenter.present("s", call(WRAP_UP_TOOL, "w", input));
        assert_eq!(shown.len(), 2);
        assert_eq!(shown[0]["sessionUpdate"], "agent_message_chunk");
        assert_eq!(shown[0]["content"]["text"], "PR opened.\n\nMark it ready?");
        assert_eq!(shown[1]["toolCallId"], "w#next");
        assert_eq!(card(&shown[1])["card"], "nextStep");
        assert_eq!(card(&shown[1])["actions"], json!([{"label": "Yes", "message": "yes"}]));
        assert!(presenter.present("s", done("w")).is_empty());

        let recap_only = presenter.present("s", call(WRAP_UP_TOOL, "v", json!({"recap": "Done."})));
        assert_eq!(recap_only.len(), 1);
    }

    #[test]
    fn plan_calls_become_plan_updates_that_track_incremental_progress() {
        let mut presenter = Presenter::default();
        let items = json!({"items": [
            {"content": "a", "status": "in_progress"},
            {"content": "b", "status": "pending"},
            {"content": "c", "status": "pending"},
        ]});
        let set = one(presenter.present("s", call(UPDATE_PLAN_TOOL, "p1", items)));
        assert_eq!(set["sessionUpdate"], "plan");
        assert_eq!(statuses(&set), ["in_progress", "pending", "pending"]);
        assert!(presenter.present("s", done("p1")).is_empty());

        let advanced = one(presenter.present("s", call(UPDATE_PLAN_TOOL, "p2", json!({"advance": true}))));
        assert_eq!(statuses(&advanced), ["completed", "in_progress", "pending"]);

        let ticked = call(UPDATE_PLAN_TOOL, "p3", json!({"done": [2], "start": 3}));
        let ticked = one(presenter.present("s", ticked));
        assert_eq!(statuses(&ticked), ["completed", "completed", "in_progress"]);
    }

    #[test]
    fn other_tools_empty_calls_and_unknown_sessions_pass_through() {
        let mut presenter = Presenter::default();
        let empty = call(WRAP_UP_TOOL, "w", json!({}));
        assert_eq!(presenter.present("s", empty.clone()), vec![empty]);
        assert_eq!(presenter.present("s", done("w")), vec![done("w")]);
        // An increment without a list to apply it to stays a tool call, now titled.
        let orphan = call(UPDATE_PLAN_TOOL, "p", json!({"advance": true}));
        assert_eq!(one(presenter.present("t", orphan))["title"], "Updated the task list");
        let bash = call("Bash", "b", json!({"command": "ls"}));
        assert_eq!(presenter.present("s", bash.clone()), vec![bash]);
        let other_server = call("mcp__dbx__dbx_list_connections", "d", json!({}));
        assert_eq!(presenter.present("s", other_server.clone()), vec![other_server]);
        // A claude.ai connector is named by its id; a server merely resembling one is not.
        let connector = call("mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__read", "k", json!({}));
        let connector = one(presenter.present("s", connector));
        assert_eq!((connector["title"].as_str(), connector["kind"].as_str()), (Some("Connector: read"), Some("read")));
        let lookalike = call("mcp__1a59c906-04da-521d-bda7__read", "l", json!({}));
        assert_eq!(presenter.present("s", lookalike.clone()), vec![lookalike]);
        let text = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}});
        assert_eq!(presenter.present("s", text.clone()), vec![text]);
    }

    #[test]
    fn chapters_pull_requests_folders_and_widgets_become_cards_with_readable_titles() {
        let mut presenter = Presenter::default();
        let input = json!({"title": "Core", "summary": "Rust first"});
        let chapter = one(presenter.present("s", call("mcp__ccd_session__mark_chapter", "c", input)));
        assert_eq!(chapter["title"], "Chapter: Core");
        assert_eq!(card(&chapter), &json!({"card": "chapter", "title": "Core", "summary": "Rust first"}));
        // Card calls keep their own results, so a failed call stays visible as one.
        assert_eq!(presenter.present("s", done("c")), vec![done("c")]);
        // A later update restating the adapter's title keeps the readable one.
        let restated = json!({"sessionUpdate": "tool_call_update", "toolCallId": "c",
                              "title": "mcp__ccd_session__mark_chapter", "kind": "other"});
        assert_eq!(one(presenter.present("s", restated))["title"], "Chapter: Core");

        let input = json!({"url": "https://github.com/o/r/pull/31", "auto_fix": true});
        let pr = one(presenter.present("s", call("mcp__ccd_pr__set_monitor", "p", input)));
        assert_eq!(card(&pr)["card"], "pullRequest");
        assert_eq!(card(&pr)["action"], "monitored");
        assert_eq!(card(&pr)["number"], 31);
        assert_eq!(card(&pr)["autoFix"], true);

        let input = json!({"path": "/w/other"});
        let folder = one(presenter.present("s", call("mcp__ccd_directory__change_directory", "d", input)));
        assert_eq!(card(&folder), &json!({"card": "directory", "action": "changed", "path": "/w/other"}));

        let input = json!({"title": "vcs_layers", "widget_code": "<svg/>"});
        let widget = one(presenter.present("s", call("mcp__visualize__show_widget", "v", input)));
        assert_eq!(widget["title"], "Visualization: vcs layers");
        assert_eq!(card(&widget)["code"], "<svg/>");
    }

    #[test]
    fn panes_and_editor_requests_become_file_locations() {
        let mut presenter = Presenter::default();
        let input = json!({"pane": "file", "path": "notes/a.md"});
        let pane = one(presenter.present("s", call("mcp__ccd_view__show_pane", "v", input)));
        assert_eq!(pane["kind"], "read");
        assert_eq!(pane["locations"], json!([{"path": "notes/a.md"}]));
        let input = json!({"path": "/w/a.rs", "line": 12});
        let editor = one(presenter.present("s", call("mcp__ccd_host__open_in_editor", "e", input)));
        assert_eq!(editor["locations"], json!([{"path": "/w/a.rs", "line": 12}]));
        let layout = one(presenter.present("s", call("mcp__ccd_window__get_window_layout", "l", json!({}))));
        assert_eq!(layout["title"], "Claude Desktop: get window layout");
        assert_eq!(layout["kind"], "read");
        let shot = one(presenter.present("s", call("mcp__computer-use__app_screenshot", "x", json!({}))));
        assert_eq!(shot["title"], "Computer use: app screenshot");
    }

    #[test]
    fn task_cards_follow_their_proposal_withdrawal_and_start() {
        let mut presenter = Presenter::default();
        let input = json!({"title": "Fix", "tldr": "Why", "prompt": "Do it"});
        let proposed = one(presenter.present("s", call("mcp__ccd_session__spawn_task", "t1", input)));
        assert_eq!(card(&proposed)["state"], "proposed");
        assert_eq!(card(&proposed)["prompt"], "Do it");
        presenter.present("s", result("t1", "Noted (position 1, task_id: task_9edecafe). A chip is showing"));

        // The withdrawal call itself is absorbed; its result restates the card.
        let dismiss = call("mcp__ccd_session__dismiss_task", "x", json!({"task_id": "task_9edecafe"}));
        assert!(presenter.present("s", dismiss).is_empty());
        let withdrawn = one(presenter.present("s", result("x", "Task task_9edecafe withdrawn")));
        assert_eq!(withdrawn["toolCallId"], "t1");
        assert_eq!(card(&withdrawn)["state"], "withdrawn");

        let input = json!({"initiation": "own_initiative", "title": "Move", "prompt": "Go"});
        presenter.present("s", call("mcp__ccd_session__start_session", "t2", input));
        presenter.present("s", result("t2", "Proposed \"Move\" (task_id: task_0f1ad1a7). The user sees a card"));
        let start = call("mcp__ccd_session__start_session", "y", json!({"proposal_id": "task_0f1ad1a7"}));
        assert!(presenter.present("s", start).is_empty());
        assert_eq!(card(&one(presenter.present("s", done("y"))))["state"], "started");

        let dismiss = call("mcp__ccd_session__dismiss_task", "z", json!({"task_id": "task_0f1ad1a7"}));
        presenter.present("s", dismiss);
        let late = one(presenter.present("s", result("z", "Task task_0f1ad1a7 was already started")));
        assert_eq!(card(&late)["state"], "started");

        let input = json!({"title": "Stats", "remaining_plan": "\nDone: x\nNext: y"});
        let handoff = one(presenter.present("s", call("mcp__ccd_session__hand_off_to_session", "h", input)));
        assert_eq!(card(&handoff)["state"], "handedOff");
        assert_eq!(card(&handoff)["summary"], "Done: x");
    }

    #[test]
    fn failed_task_actions_stay_visible_and_progress_does_not_change_the_card() {
        let mut presenter = Presenter::default();
        presenter.present("s", call("mcp__ccd_session__spawn_task", "t1", json!({"title": "Fix", "prompt": "Do it"})));
        presenter.present("s", result("t1", "Noted (task_id: task_9edecafe)."));

        let dismiss = call("mcp__ccd_session__dismiss_task", "x", json!({"task_id": "task_9edecafe"}));
        assert!(presenter.present("s", dismiss).is_empty());
        let progress = json!({"sessionUpdate": "tool_call_update", "toolCallId": "x", "status": "in_progress"});
        assert!(presenter.present("s", progress).is_empty(), "Progress must not withdraw the card");
        let failed = json!({"sessionUpdate": "tool_call_update", "toolCallId": "x", "status": "failed",
                            "content": [{"type": "content", "content": {"type": "text", "text": "Denied"}}]});
        let shown = presenter.present("s", failed);
        assert_eq!(shown.len(), 2, "{shown:?}");
        assert_eq!(shown[0]["sessionUpdate"], "tool_call");
        assert_eq!(shown[0]["toolCallId"], "x");
        assert_eq!(shown[0]["title"], "Withdrew a suggested task");
        assert_eq!(shown[1]["status"], "failed");

        let start = call("mcp__ccd_session__start_session", "y", json!({"proposal_id": "task_9edecafe"}));
        assert!(presenter.present("s", start).is_empty());
        let failed = json!({"sessionUpdate": "tool_call_update", "toolCallId": "y", "status": "failed"});
        assert_eq!(presenter.present("s", failed)[0]["title"], "Started a suggested task");
    }

    #[test]
    fn created_pull_request_tags_become_links() {
        let mut presenter = Presenter::default();
        let chunk = |text: &str| {
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
        };
        let tagged = chunk("Opened.\n<pr-created>https://github.com/o/r/pull/7</pr-created>\n");
        let shown = one(presenter.present("s", tagged));
        assert_eq!(shown["content"]["text"], "Opened.\n[Pull request #7](https://github.com/o/r/pull/7)\n");
        // Anything but a URL is left as the model wrote it.
        let odd = chunk("<pr-created>not a url</pr-created>");
        assert_eq!(one(presenter.present("s", odd.clone())), odd);
    }
}
