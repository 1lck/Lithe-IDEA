//! Agent 对话面板：直接复用 `lithe-agent-host` 的 ACP 连接与事件流。
//!
//! # 边界
//!
//! ACP 协议、安装发现、会话与进程树都归 `rust/lithe-agent-host`。本视图只负责
//! 选择已安装的 adapter、把 [`AgentEvent`] 投影成对话，以及把用户操作翻译成
//! [`AgentCommand`]。不复制业务规则，也不接触凭据。
//!
//! # 线程与重入
//!
//! `AgentHandle` 的 `emit` 回调运行在 host 的 worker 线程上。它只做两件事：
//! `serde_json::to_string(&event)` 和把消息 `send_blocking` 进 `async_channel`，
//! 绝不碰 GPUI。所有实体更新、命令发送和 handle 生命周期都在主线程完成。
//!
//! 构造发生在 `App::run` 的可变借用内，此时 spawn 会再次借 App 并触发
//! `RefCell already borrowed`。因此 `new` 只记录状态；发现 adapter、打开连接和
//! 启动事件泵都排到首帧 `Render` 的 `defer_in` 之后。
//!
//! # 过期事件
//!
//! 重连或切换工作区时 `generation` 递增，emit 回调把当时的 generation 一起投递。
//! 主线程只处理与当前 generation 相同的事件，避免旧连接在关闭过程中发出的事件
//! 污染新一轮对话。
//!
//! # 已知限制
//!
//! 本轮固定使用 catalog 中第一个已安装的 adapter，并且总是新建会话；会话列表、
//! 历史恢复、模型选择、配额和安装按钮都不在范围内。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement, Render, SharedString, StatefulInteractiveElement as _, Styled,
    Subscription, Window, div, px,
};
use lithe_agent_host::catalog::{CATALOG, CatalogAgent, find};
use lithe_agent_host::{AgentAuthentication, AgentCommand, AgentEvent, AgentHandle, AgentLaunch};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens, icon};
use serde_json::Value;

// --- 视图内部派生尺寸 ------------------------------------------------------
// LitheMetrics 只包含跨工具窗共享的刻度；下面的间距仅属于 Agent 面板，
// 因此留在本文件，避免为一个视图扩充冻结的 `lithe-ui` 契约。
/// transcript 的四周内边距。
const TRANSCRIPT_PADDING: f32 = 12.0;
/// transcript 中相邻条目的间距。
const TRANSCRIPT_GAP: f32 = 10.0;
/// 用户气泡与 assistant 文本的最大宽度。
const TRANSCRIPT_MAX_WIDTH: f32 = 620.0;
/// composer 的四周内边距。
const COMPOSER_PADDING: f32 = 10.0;
/// 工具活动最多保留的条数；更早的行会被丢弃。
const MAX_TOOL_ROWS: usize = 50;

/// 事件泵里的一条消息：generation 用于丢弃旧连接的事件。
struct WireEvent {
    generation: u64,
    /// `AgentEvent` 的 JSON 序列化结果。
    payload: String,
}

/// 面板的连接状态。所有状态都有明确的界面文案。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ConnectionState {
    /// catalog 中没有找到任何已安装的 adapter。
    NoAgent,
    /// 正在发现 adapter、启动进程或完成 ACP 握手。
    Connecting,
    /// 连接已就绪，可以创建会话与发送 prompt。
    Ready,
    /// 启动失败、认证失败或连接已停止。
    Error,
}

/// 对话中的一条内容。
enum ChatItem {
    /// 用户输入，右对齐气泡。
    User(String),
    /// assistant 的流式文本，左对齐。
    Assistant(String),
    /// assistant 的思考片段，灰色并带 `Thinking:` 前缀。
    Thinking(String),
    /// 一行工具活动。
    Tool {
        /// ACP 的 `toolCallId`，用于把 `tool_call_update` 合并到同一行。
        id: String,
        title: String,
        status: String,
    },
}

/// 等待用户决定的权限请求。
#[derive(Clone)]
struct PermissionPrompt {
    request_id: String,
    /// 第一个选项的 id；没有选项时无法 Allow。
    option_id: Option<String>,
    /// 第一个选项的显示名，通常就是「Allow once」之类的文案。
    label: String,
    /// 工具调用的标题，帮助用户判断这次请求。
    description: String,
}

/// 基于 `lithe-agent-host` 的对话面板。
pub struct AgentPanel {
    /// 工作区根，作为 ACP 会话的 `cwd`。
    root: PathBuf,
    /// 应用数据目录；adapter 安装目录由 host 从它推导。
    data_directory: Option<PathBuf>,
    /// emit 回调 -> 主线程事件泵。
    receiver: async_channel::Receiver<WireEvent>,
    sender: async_channel::Sender<WireEvent>,
    /// 当前连接。事件泵与 Drop 之外只在主线程访问。
    handle: Option<AgentHandle>,
    /// 当前选中的 catalog 条目。
    selected_agent: Option<&'static CatalogAgent>,
    /// 选中 adapter 的已安装版本。
    installed_version: Option<String>,
    /// `Ready` 事件报告的 adapter 名称与版本，作为 catalog 缺失时的回退。
    runtime_agent: Option<(String, String)>,
    state: ConnectionState,
    /// 可见错误；与 `state` 分开保存，方便在 Ready 状态下也显示请求错误。
    error: Option<SharedString>,
    /// 是否需要用户先在终端登录。
    auth_required: bool,
    /// 当前会话 id；`None` 表示尚未创建。
    session_id: Option<String>,
    /// 会话创建前排队的 prompt。
    queued_prompt: Option<String>,
    messages: Vec<ChatItem>,
    /// 当前 turn 是否仍在进行。
    busy: bool,
    /// 是否已经请求停止当前 turn。
    cancelling: bool,
    permission: Option<PermissionPrompt>,
    /// 多行输入框；首帧懒创建。
    input: Option<Entity<TextareaState>>,
    /// 输入事件订阅必须和面板实体同生命周期。
    _input_subscription: Option<Subscription>,
    /// 每次重连/切换工作区递增；旧异步结果与旧事件据此丢弃。
    generation: u64,
    /// 事件泵只启动一次。
    pump_started: bool,
    /// 本轮是否已经安排连接；`set_root`/重连会重置它。
    started: bool,
}

impl AgentPanel {
    pub fn new(root: PathBuf, _window: &mut Window, _cx: &mut Context<Self>) -> Self {
        let (sender, receiver) = async_channel::unbounded::<WireEvent>();
        // 构造期只记录状态，不发现 adapter、不打开连接、不 spawn。
        Self {
            root,
            data_directory: app_data_dir(),
            receiver,
            sender,
            handle: None,
            selected_agent: None,
            installed_version: None,
            runtime_agent: None,
            state: ConnectionState::Connecting,
            error: None,
            auth_required: false,
            session_id: None,
            queued_prompt: None,
            messages: Vec::new(),
            busy: false,
            cancelling: false,
            permission: None,
            input: None,
            _input_subscription: None,
            generation: 0,
            pump_started: false,
            started: false,
        }
    }

    /// 供设置页展示的连接状态摘要。
    ///
    /// 返回可直接显示的一行文字；`Error` 状态带上最近一次错误原因，其余
    /// 状态复用面板内的本地化标签。
    pub fn status_summary(&self) -> String {
        let label = self.state_label();
        if self.state != ConnectionState::Error {
            return label.to_string();
        }
        match self.error.as_ref() {
            Some(error) => format!("{label}: {error}"),
            None => label.to_string(),
        }
    }

    /// 切换工作区根：关闭旧连接，清空对话，并在下一帧重新发现/连接。
    pub fn set_root(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        self.root = root;
        self.reset_connection(window, cx);
    }

    /// 把键盘焦点交给 composer。输入框尚未创建时先懒创建。
    pub fn focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let input = self.ensure_input(window, cx);
        // 焦点变更排到本帧之后，避免在布局/绘制借用内改焦点。
        cx.defer_in(window, move |_this, window, cx| {
            input.update(cx, |state, cx| state.focus(window, cx));
        });
        cx.notify();
    }
}

impl Drop for AgentPanel {
    fn drop(&mut self) {
        // host 的 close 自带 3s 上限；Drop 不额外等待或轮询。
        self.close_handle();
    }
}

// ---------------------------------------------------------------------------
// 连接生命周期
// ---------------------------------------------------------------------------

impl AgentPanel {
    /// 首帧只启动一次事件泵，并在需要时安排一次连接。
    fn ensure_started(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.ensure_pump(window, cx);
        if self.started {
            return;
        }
        self.started = true;
        let epoch = self.generation;
        cx.defer_in(window, move |this, window, cx| {
            // 等待期间用户可能已经切换工作区或点了重连。
            if this.generation == epoch {
                this.begin_connect(window, cx);
            }
        });
    }

    /// 事件泵只启动一次；重连复用同一个 channel。
    fn ensure_pump(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pump_started {
            return;
        }
        self.pump_started = true;

        let receiver = self.receiver.clone();
        cx.defer_in(window, move |_this, window, cx| {
            cx.spawn_in(window, async move |this, cx| {
                while let Ok(message) = receiver.recv().await {
                    if this
                        .update_in(cx, |this, _window, cx| this.handle_event(message, cx))
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .detach();
        });
    }

    /// 递增 generation、关闭旧连接并清空对话，然后把新连接排到下一帧。
    fn reset_connection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // 先递增，保证旧连接的 Stopped 与仍在飞行的发现结果都被丢弃。
        self.generation = self.generation.wrapping_add(1);
        self.close_handle();
        self.clear_conversation();
        self.started = false;
        self.state = ConnectionState::Connecting;
        self.error = None;
        self.auth_required = false;
        self.selected_agent = None;
        self.installed_version = None;
        self.runtime_agent = None;
        self.ensure_started(window, cx);
        cx.notify();
    }

    /// 连接按钮：走一遍与 `set_root` 相同的发现/连接流程。
    fn reconnect(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.reset_connection(window, cx);
    }

    /// 发现 adapter 并打开连接。调用方已经保证主线程。
    fn begin_connect(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.close_handle();
        self.clear_conversation();
        self.state = ConnectionState::Connecting;
        self.error = None;
        self.auth_required = false;
        self.selected_agent = None;
        self.installed_version = None;
        self.runtime_agent = None;

        if self.root.as_os_str().is_empty() || !self.root.is_absolute() {
            self.set_error(SharedString::from(tr("Open a project first")), cx);
            return;
        }
        let Some(data_directory) = self.data_directory.clone() else {
            self.set_error(
                SharedString::from(tr("The Lithe data directory is unavailable.")),
                cx,
            );
            return;
        };

        let root = self.root.clone();
        let discovery_directory = data_directory.clone();
        cx.spawn_in(window, async move |this, cx| {
            // 安装发现会检测 Node/npm 与 adapter marker，属于阻塞调用。
            let discovered = cx
                .background_spawn(async move {
                    let status = lithe_agent_host::install::status(&discovery_directory, &|| false);
                    status
                        .agents
                        .into_iter()
                        .find(|agent| agent.installed_version.is_some())
                        .map(|agent| (agent.id, agent.installed_version))
                })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                if this.generation != generation {
                    return;
                }
                match discovered {
                    Some((agent_id, installed_version)) => match find(&agent_id) {
                        Some(agent) => this.open_agent(
                            agent,
                            installed_version,
                            &root,
                            &data_directory,
                            generation,
                            cx,
                        ),
                        None => this.set_error(
                            SharedString::from(format!("Unknown agent `{agent_id}`")),
                            cx,
                        ),
                    },
                    None => {
                        // 没有已安装的 adapter：展示安装提示，不打开连接。
                        this.state = ConnectionState::NoAgent;
                        this.error = None;
                        this.selected_agent = None;
                        this.installed_version = None;
                        cx.notify();
                    }
                }
            });
        })
        .detach();

        cx.notify();
    }

    /// 打开 host 连接。launch 的失败由 host 通过 `Stopped` 事件报告。
    fn open_agent(
        &mut self,
        agent: &'static CatalogAgent,
        installed_version: Option<String>,
        root: &Path,
        data_directory: &Path,
        generation: u64,
        cx: &mut Context<Self>,
    ) {
        let authentication = match agent.id {
            "claude-acp" => AgentAuthentication::ClaudeSubscription,
            "codex-acp" => AgentAuthentication::CodexSubscription,
            // 其他 adapter 没有订阅登录方式；ApiKey 会因缺少 provider 而失败，
            // 错误通过 Stopped 显示，符合本轮「只做基础对话」的范围。
            _ => AgentAuthentication::ApiKey,
        };
        let launch = AgentLaunch {
            agent_id: Some(agent.id.to_string()),
            command: None,
            args: Vec::new(),
            cwd: root.to_path_buf(),
            data_directory: Some(data_directory.to_path_buf()),
            authentication,
            provider: None,
            observe_model_calls: false,
            observe_subagents: false,
            process_scope: None,
            claude_config_dir: None,
            codex_home: None,
            context_limits: Default::default(),
        };

        let sender = self.sender.clone();
        let emit: Arc<dyn Fn(AgentEvent) + Send + Sync + 'static> = Arc::new(move |event| {
            // worker 线程：只序列化并投递，绝不碰 GPUI。
            if let Ok(payload) = serde_json::to_string(&event) {
                let _ = sender.send_blocking(WireEvent {
                    generation,
                    payload,
                });
            }
        });

        self.selected_agent = Some(agent);
        self.installed_version = installed_version;
        match AgentHandle::open(launch, emit) {
            Ok(handle) => {
                self.handle = Some(handle);
                self.state = ConnectionState::Connecting;
                self.error = None;
            }
            Err(message) => {
                self.set_error(SharedString::from(message), cx);
            }
        }
        cx.notify();
    }

    /// 停止当前连接。host 内部限定清理时间。
    fn close_handle(&mut self) {
        if let Some(handle) = self.handle.take() {
            handle.close();
        }
    }

    /// 清空对话与请求状态，但保留连接对象。
    fn clear_conversation(&mut self) {
        self.messages.clear();
        self.session_id = None;
        self.queued_prompt = None;
        self.permission = None;
        self.busy = false;
        self.cancelling = false;
        self.error = None;
        self.auth_required = false;
    }

    fn set_error(&mut self, message: SharedString, cx: &mut Context<Self>) {
        self.error = Some(message);
        self.state = ConnectionState::Error;
        self.busy = false;
        self.cancelling = false;
        cx.notify();
    }
}

// ---------------------------------------------------------------------------
// 命令与事件
// ---------------------------------------------------------------------------

impl AgentPanel {
    /// 把命令交给当前连接。错误不会 panic，而是进入可见状态。
    fn send_command(&mut self, command: AgentCommand) -> Result<(), String> {
        match self.handle.as_ref() {
            Some(handle) => handle.send(command),
            None => Err(tr("The agent is not connected.").to_string()),
        }
    }

    /// 主线程处理一条事件。JSON 由 worker 线程序列化，这里只按语义投影。
    fn handle_event(&mut self, message: WireEvent, cx: &mut Context<Self>) {
        if message.generation != self.generation {
            return;
        }
        let Ok(value) = serde_json::from_str::<Value>(&message.payload) else {
            return;
        };

        match value.get("kind").and_then(Value::as_str) {
            Some("authenticationRequired") => {
                self.auth_required = true;
                self.state = ConnectionState::Error;
                self.error = Some(SharedString::from(tr(
                    "Sign in to the agent in a terminal, or authenticate here.",
                )));
            }
            Some("authenticating") => {
                self.auth_required = false;
                self.state = ConnectionState::Connecting;
                self.error = None;
            }
            Some("ready") => {
                self.state = ConnectionState::Ready;
                self.auth_required = false;
                self.error = None;
                let name = value
                    .get("agentName")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let version = value
                    .get("agentVersion")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if !name.is_empty() {
                    self.runtime_agent = Some((name, version));
                }
                let token = format!("gpui-session-{}", self.generation);
                if let Err(message) = self.send_command(AgentCommand::NewSession { token }) {
                    self.set_error(SharedString::from(message), cx);
                }
            }
            Some("sessionCreated") => {
                let session_id = value
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if session_id.is_empty() {
                    self.set_error(
                        SharedString::from(tr("The agent did not return a session id.")),
                        cx,
                    );
                } else {
                    self.session_id = Some(session_id.clone());
                    self.state = ConnectionState::Ready;
                    // 会话建立前输入的 prompt 在这里补发。
                    if let Some(text) = self.queued_prompt.take() {
                        self.busy = true;
                        if let Err(message) = self.send_command(AgentCommand::Prompt {
                            session_id,
                            text,
                            files: Vec::new(),
                        }) {
                            self.busy = false;
                            self.error = Some(SharedString::from(message));
                        }
                    }
                }
            }
            Some("update") => {
                if let Some(update) = value.get("update") {
                    self.apply_update(update);
                }
            }
            Some("permission") => {
                let request_id = value
                    .get("requestId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if request_id.is_empty() {
                    return;
                }
                let request = value.get("request").cloned().unwrap_or(Value::Null);
                self.permission = Some(parse_permission(request_id, &request));
            }
            Some("turnCancelling") => {
                self.cancelling = true;
            }
            Some("turnFinished") => {
                self.busy = false;
                self.cancelling = false;
                self.permission = None;
                self.error = None;
            }
            Some("requestFailed") => {
                self.busy = false;
                self.cancelling = false;
                self.permission = None;
                if let Some(message) = value
                    .get("message")
                    .and_then(Value::as_str)
                    .filter(|message| !message.trim().is_empty())
                {
                    self.error = Some(SharedString::from(message.to_string()));
                }
            }
            Some("stopped") => {
                self.busy = false;
                self.cancelling = false;
                self.permission = None;
                self.auth_required = false;
                self.session_id = None;
                self.queued_prompt = None;
                // worker 已经结束；close 只做一次有界回收。
                self.close_handle();
                let message = value
                    .get("message")
                    .and_then(Value::as_str)
                    .filter(|message| !message.trim().is_empty())
                    .unwrap_or(tr("The agent connection stopped."));
                self.state = ConnectionState::Error;
                self.error = Some(SharedString::from(message.to_string()));
            }
            // Sessions/SessionsPage/Quota/ModelCall 等本轮忽略。
            _ => return,
        }

        cx.notify();
    }

    /// 把一条 ACP `SessionUpdate` 投影到 transcript。
    fn apply_update(&mut self, update: &Value) {
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("agent_message_chunk") => {
                if let Some(text) = update
                    .get("content")
                    .and_then(|content| content.get("text"))
                    .and_then(Value::as_str)
                {
                    self.append_assistant(text);
                }
            }
            Some("agent_thought_chunk") => {
                if let Some(text) = update
                    .get("content")
                    .and_then(|content| content.get("text"))
                    .and_then(Value::as_str)
                {
                    self.append_thinking(text);
                }
            }
            Some("tool_call") | Some("tool_call_update") => {
                let id = update
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if id.is_empty() {
                    return;
                }
                let title = update
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let status = update
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                self.upsert_tool(id, title, status);
            }
            // 其他 sessionUpdate（usage、plan、commands 等）本轮不展示。
            _ => {}
        }
    }

    /// 连续的 assistant chunk 合并进同一个气泡。
    fn append_assistant(&mut self, text: &str) {
        if let Some(ChatItem::Assistant(existing)) = self.messages.last_mut() {
            existing.push_str(text);
        } else {
            self.messages.push(ChatItem::Assistant(text.to_string()));
        }
    }

    /// 连续的 thinking chunk 合并成一段灰色前缀文本。
    fn append_thinking(&mut self, text: &str) {
        if let Some(ChatItem::Thinking(existing)) = self.messages.last_mut() {
            existing.push_str(text);
        } else {
            self.messages.push(ChatItem::Thinking(text.to_string()));
        }
    }

    /// 新建或更新一行工具活动，并保证最多保留最近 `MAX_TOOL_ROWS` 行。
    fn upsert_tool(&mut self, id: String, title: String, status: String) {
        let existing = self.messages.iter_mut().find_map(|item| match item {
            ChatItem::Tool {
                id: tool_id,
                title: tool_title,
                status: tool_status,
            } if *tool_id == id => Some((tool_title, tool_status)),
            _ => None,
        });
        if let Some((tool_title, tool_status)) = existing {
            if !title.is_empty() {
                *tool_title = title;
            }
            if !status.is_empty() {
                *tool_status = status;
            }
            return;
        }

        self.messages.push(ChatItem::Tool { id, title, status });
        // 「最近 50 条」：超出后从最旧的一行开始丢弃。
        while self
            .messages
            .iter()
            .filter(|item| matches!(item, ChatItem::Tool { .. }))
            .count()
            > MAX_TOOL_ROWS
        {
            let Some(index) = self
                .messages
                .iter()
                .position(|item| matches!(item, ChatItem::Tool { .. }))
            else {
                break;
            };
            self.messages.remove(index);
        }
    }

    /// 用户点击 Send 或按 Enter：记录消息并发送 prompt。
    fn submit_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || self.cancelling || self.handle.is_none() {
            return;
        }
        let Some(input) = self.input.clone() else {
            return;
        };
        let text = input.read(cx).value().trim().to_string();
        if text.is_empty() {
            return;
        }

        self.error = None;
        self.messages.push(ChatItem::User(text.clone()));
        input.update(cx, |state, cx| state.set_value("", window, cx));

        match self.session_id.clone() {
            Some(session_id) => {
                self.busy = true;
                if let Err(message) = self.send_command(AgentCommand::Prompt {
                    session_id,
                    text,
                    files: Vec::new(),
                }) {
                    self.busy = false;
                    self.error = Some(SharedString::from(message));
                }
            }
            None => {
                // Ready 但会话尚未创建：等 `sessionCreated` 立即补发。
                // 先标记 busy，避免在等待期间重复提交覆盖排队的 prompt。
                self.busy = true;
                self.queued_prompt = Some(text);
            }
        }
        cx.notify();
    }

    /// 请求停止当前 turn。真正的结束由 `turnFinished` 事件确认。
    fn stop(&mut self, cx: &mut Context<Self>) {
        if !self.busy || self.cancelling {
            return;
        }
        let Some(session_id) = self.session_id.clone() else {
            return;
        };
        self.cancelling = true;
        if let Err(message) = self.send_command(AgentCommand::Cancel { session_id }) {
            self.cancelling = false;
            self.error = Some(SharedString::from(message));
        }
        cx.notify();
    }

    /// 认证按钮：要求 host 打开上游登录流程。
    fn authenticate(&mut self, cx: &mut Context<Self>) {
        self.auth_required = false;
        self.state = ConnectionState::Connecting;
        self.error = None;
        if let Err(message) = self.send_command(AgentCommand::Authenticate) {
            self.error = Some(SharedString::from(message));
        }
        cx.notify();
    }

    /// 回答权限请求；`None` 表示拒绝。
    fn answer_permission(
        &mut self,
        request_id: String,
        option_id: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if let Err(message) = self.send_command(AgentCommand::Permission {
            request_id,
            option_id,
        }) {
            self.error = Some(SharedString::from(message));
        }
        self.permission = None;
        cx.notify();
    }
}

/// 解析权限请求：取第一个选项作为 Allow，缺省时只能 Deny。
fn parse_permission(request_id: String, request: &Value) -> PermissionPrompt {
    let option = request
        .get("options")
        .and_then(Value::as_array)
        .and_then(|options| options.first());
    let option_id = option
        .and_then(|option| option.get("optionId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let label = option
        .and_then(|option| option.get("name"))
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .unwrap_or(tr("Allow"))
        .to_string();
    let description = request
        .get("toolCall")
        .and_then(|tool_call| {
            tool_call
                .get("title")
                .and_then(Value::as_str)
                .or_else(|| tool_call.get("kind").and_then(Value::as_str))
        })
        .filter(|title| !title.trim().is_empty())
        .unwrap_or(tr("The agent needs your permission to continue."))
        .to_string();

    PermissionPrompt {
        request_id,
        option_id,
        label,
        description,
    }
}

// ---------------------------------------------------------------------------
// 输入框
// ---------------------------------------------------------------------------

impl AgentPanel {
    /// 确保多行 composer 已经创建，并只订阅一次输入事件。
    fn ensure_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<TextareaState> {
        if let Some(input) = self.input.clone() {
            return input;
        }

        let input: Entity<TextareaState> = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder(tr("Ask the agent…"))
                // Enter 发送；Shift+Enter 换行。
                .submit_on_enter(true)
                .auto_grow(2, 8)
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            move |this, _input, event: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { shift, .. } = event {
                    if !*shift {
                        // Enter 与 Ctrl/Cmd+Enter 都发送；Shift+Enter 已被输入框
                        // 自己处理成换行，不会走到这里发送。
                        this.submit_prompt(window, cx);
                    }
                }
            },
        );

        self.input = Some(input.clone());
        self._input_subscription = Some(subscription);
        input
    }
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

impl AgentPanel {
    /// 顶部显示的名称/版本：优先 catalog 名称与本地安装版本。
    fn agent_label(&self) -> SharedString {
        if let Some(agent) = self.selected_agent {
            let version = self.installed_version.as_deref().unwrap_or_default();
            if version.is_empty() {
                return SharedString::from(agent.name);
            }
            return SharedString::from(format!("{} {}", agent.name, version));
        }
        if let Some((name, version)) = &self.runtime_agent {
            if version.is_empty() {
                return SharedString::from(name.clone());
            }
            return SharedString::from(format!("{name} {version}"));
        }
        SharedString::from(tr("No agent"))
    }

    fn state_label(&self) -> &'static str {
        match self.state {
            ConnectionState::NoAgent => tr("No agent installed"),
            ConnectionState::Connecting => tr("Connecting…"),
            ConnectionState::Ready => tr("Ready"),
            ConnectionState::Error => tr("Error"),
        }
    }

    fn render_no_agent(tokens: LitheTokens) -> AnyElement {
        let mut items = v_flex().w_full().max_w(px(540.0)).gap(px(8.0));
        items = items
            .child(
                div()
                    .text_size(px(LitheMetrics::UI_FONT_SIZE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("No Agent installed")),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Install an ACP adapter to start a conversation:")),
            );
        for agent in CATALOG {
            items = items.child(
                div()
                    .w_full()
                    .px(px(8.0))
                    .py(px(5.0))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .bg(tokens.raised)
                    .font_family(MONO_FONT_FAMILY)
                    .text_size(px(LitheMetrics::CODE_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(format!("npm install -g {}", agent.package)),
            );
        }
        items = items.child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(tr(
                    "Lithe does not provide an install button yet. Install it in a terminal, then choose Reconnect.",
                )),
        );

        v_flex()
            .w_full()
            .flex_1()
            .min_h(px(0.0))
            .items_center()
            .justify_center()
            .p(px(TRANSCRIPT_PADDING))
            .child(items)
            .into_any_element()
    }

    fn render_transcript(&self, tokens: LitheTokens) -> AnyElement {
        if self.state == ConnectionState::NoAgent {
            return Self::render_no_agent(tokens);
        }
        if self.messages.is_empty() {
            let (text, color) = match self.state {
                ConnectionState::Connecting => {
                    (tr("Starting the agent…").to_string(), tokens.secondary_text)
                }
                ConnectionState::Ready => (
                    tr("Send a message to start the conversation.").to_string(),
                    tokens.secondary_text,
                ),
                ConnectionState::Error => (
                    self.error
                        .as_ref()
                        .map(|error| error.to_string())
                        .unwrap_or_else(|| tr("The agent is not connected.").to_string()),
                    tokens.error,
                ),
                ConnectionState::NoAgent => unreachable!(),
            };
            return centered_status(SharedString::from(text), color);
        }

        let mut list = v_flex()
            .w_full()
            .gap(px(TRANSCRIPT_GAP))
            .p(px(TRANSCRIPT_PADDING));
        for item in &self.messages {
            list = list.child(render_item(item, tokens));
        }

        v_flex()
            .id("lithe-agent-transcript")
            .w_full()
            .flex_1()
            .min_h(px(0.0))
            .overflow_y_scroll()
            .child(list)
            .into_any_element()
    }
}

impl Render for AgentPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 首帧（以及 set_root/重连后的首帧）在这里排定连接与事件泵。
        self.ensure_started(window, cx);
        let input = self.ensure_input(window, cx);
        let input_value = input.read(cx).value();
        let can_send = self.handle.is_some()
            && !self.busy
            && !self.cancelling
            && !input_value.trim().is_empty();

        let tokens = current_tokens(cx);
        let status_color = match self.state {
            ConnectionState::Ready => tokens.success,
            ConnectionState::Error => tokens.error,
            ConnectionState::NoAgent => tokens.warning,
            ConnectionState::Connecting => tokens.secondary_text,
        };

        let header = h_flex()
            .w_full()
            .h(px(LitheMetrics::TOOL_WINDOW_HEADER_HEIGHT))
            .flex_shrink_0()
            .gap(px(8.0))
            .px(px(COMPOSER_PADDING))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                icon(LitheIcon::Agent)
                    .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                    .text_color(tokens.secondary_text),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Agent")),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_1()
                    .truncate()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(self.agent_label()),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(status_color)
                    .child(self.state_label()),
            )
            .child(
                Button::new("lithe-agent:stop")
                    .ghost()
                    .xsmall()
                    .label(tr("Stop"))
                    .disabled(!self.busy || self.cancelling)
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| this.stop(cx))),
            )
            .child(
                Button::new("lithe-agent:reconnect")
                    .ghost()
                    .xsmall()
                    .label(tr("Reconnect"))
                    .on_click(
                        cx.listener(|this, _: &ClickEvent, window, cx| this.reconnect(window, cx)),
                    ),
            );

        // 错误条与认证按钮放在标题栏下方，避免遮蔽 transcript。
        let error_strip = self.error.as_ref().map(|message| {
            h_flex()
                .w_full()
                .flex_shrink_0()
                .gap(px(8.0))
                .px(px(COMPOSER_PADDING))
                .py(px(6.0))
                .bg(tokens.raised)
                .child(
                    div()
                        .min_w(px(0.0))
                        .flex_1()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.error)
                        .child(message.clone()),
                )
                .when(self.auth_required, |this| {
                    this.child(
                        Button::new("lithe-agent:authenticate")
                            .small()
                            .label(tr("Authenticate"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.authenticate(cx)
                            })),
                    )
                })
        });

        // 权限条：Allow 使用 ACP 返回的第一个选项，Deny 发送 None。
        let permission_bar = self.permission.as_ref().map(|permission| {
            let deny_id = permission.request_id.clone();
            let allow_id = permission.request_id.clone();
            let allow_option = permission.option_id.clone();
            h_flex()
                .w_full()
                .gap(px(8.0))
                .px(px(COMPOSER_PADDING))
                .py(px(8.0))
                .bg(tokens.raised)
                .border_t_1()
                .border_color(tokens.divider)
                .child(
                    div()
                        .min_w(px(0.0))
                        .flex_1()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(permission.description.clone()),
                )
                .child(
                    Button::new("lithe-agent:permission-allow")
                        .primary()
                        .small()
                        .label(permission.label.clone())
                        .disabled(permission.option_id.is_none())
                        .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                            this.answer_permission(allow_id.clone(), allow_option.clone(), cx)
                        })),
                )
                .child(
                    Button::new("lithe-agent:permission-deny")
                        .ghost()
                        .small()
                        .label(tr("Deny"))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                            this.answer_permission(deny_id.clone(), None, cx)
                        })),
                )
                .into_any_element()
        });

        let composer = v_flex()
            .w_full()
            .flex_shrink_0()
            .gap(px(6.0))
            .p(px(COMPOSER_PADDING))
            .border_t_1()
            .border_color(tokens.divider)
            .bg(tokens.tool_header)
            .when_some(permission_bar, |this, bar| this.child(bar))
            .child(
                h_flex()
                    .w_full()
                    .gap(px(8.0))
                    .items_start()
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .child(Textarea::new(&input).w_full()),
                    )
                    .child(
                        Button::new("lithe-agent:send")
                            .primary()
                            .small()
                            .label(tr("Send"))
                            .disabled(!can_send)
                            .loading(self.busy)
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                this.submit_prompt(window, cx)
                            })),
                    ),
            )
            .child(
                div()
                    .w_full()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("Enter sends · Shift+Enter for a new line")),
            );

        let mut root = v_flex()
            .size_full()
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(header);
        if let Some(strip) = error_strip {
            root = root.child(strip);
        }
        root = root.child(self.render_transcript(tokens));
        if self.state != ConnectionState::NoAgent {
            root = root.child(composer);
        }
        root
    }
}

/// 渲染一条对话内容。
fn render_item(item: &ChatItem, tokens: LitheTokens) -> AnyElement {
    match item {
        ChatItem::User(text) => h_flex().w_full().justify_end().child(
            div()
                .max_w(px(TRANSCRIPT_MAX_WIDTH))
                .rounded(px(LitheMetrics::CONTROL_RADIUS))
                .bg(tokens.subtle_selection)
                .px(px(10.0))
                .py(px(7.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(text.clone()),
        ),
        ChatItem::Assistant(text) => h_flex().w_full().justify_start().child(
            div()
                .max_w(px(TRANSCRIPT_MAX_WIDTH))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(text.clone()),
        ),
        ChatItem::Thinking(text) => h_flex().w_full().justify_start().child(
            div()
                .max_w(px(TRANSCRIPT_MAX_WIDTH))
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(format!("{} {}", tr("Thinking:"), text)),
        ),
        ChatItem::Tool { title, status, .. } => {
            let label = if title.trim().is_empty() {
                tr("Tool call").to_string()
            } else {
                title.clone()
            };
            h_flex()
                .w_full()
                .gap(px(6.0))
                .px(px(2.0))
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .child(
                    div()
                        .flex_shrink_0()
                        .text_color(tokens.tertiary_text)
                        .child("•"),
                )
                .child(
                    div()
                        .min_w(px(0.0))
                        .flex_1()
                        .truncate()
                        .text_color(tokens.secondary_text)
                        .child(label),
                )
                .child(
                    div()
                        .flex_shrink_0()
                        .text_color(tokens.tertiary_text)
                        .child(status.clone()),
                )
        }
    }
    .into_any_element()
}

/// 居中的状态文案，用于无内容、连接中与错误。
fn centered_status(text: SharedString, color: gpui_kit::Hsla) -> AnyElement {
    v_flex()
        .w_full()
        .flex_1()
        .min_h(px(0.0))
        .items_center()
        .justify_center()
        .px(px(TRANSCRIPT_PADDING))
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(color)
        .child(text)
        .into_any_element()
}

// ---------------------------------------------------------------------------
// 应用数据目录
// ---------------------------------------------------------------------------

/// macOS：`$HOME/Library/Application Support/Lithe`。
#[cfg(target_os = "macos")]
fn app_data_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support/Lithe"))
}

/// Windows：`%APPDATA%\Lithe`。
#[cfg(target_os = "windows")]
fn app_data_dir() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("Lithe"))
}

/// Linux：`$XDG_CONFIG_HOME/lithe`，否则 `$HOME/.config/lithe`。
#[cfg(target_os = "linux")]
fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

/// 未知平台：退回 XDG，保证面板仍然可用。
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn xdg_config_lithe() -> Option<PathBuf> {
    // 空字符串在 XDG 规范里等价于未设置。
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")));
    base.map(|directory| directory.join("lithe"))
}
