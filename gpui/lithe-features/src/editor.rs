//! 编辑区：用 gpui-webview 承载 Monaco，并实现 `gpui/editor/PROTOCOL.md`
//! 的 Rust 侧。
//!
//! # 线程与重入边界
//!
//! wry 的 IPC 回调可能不在 GPUI 的主线程上，而且它一定发生在 GPUI 的借用
//! 之外。因此回调只做两件事：解析 JSON、把消息塞进 `async_channel`。任何
//! 实体更新、文件写入和 `evaluate_script` 都禁止出现在回调里。
//!
//! 消息泵在首帧 `Render` 里通过 `cx.defer_in` 启动，原因与 [`ProjectTree`]
//! 相同：实体构造发生在 `App::run` 的可变借用内，构造期 `cx.spawn` 会在异步
//! 上下文再次借 App 时触发 `RefCell already borrowed`。
//!
//! # 生命周期
//!
//! `Entity<WebView>` 在 [`EditorSurface::new`] 里创建一次，`load_url` 也只调用
//! 一次。`render` 不再触发导航，否则原生视图会闪烁并丢失焦点。
//!
//! [`ProjectTree`]: crate::workspace::ProjectTree

use std::borrow::Cow;
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, Entity, EventEmitter, Hsla, IntoElement, ParentElement, Render, Rgba,
    SharedString, Styled, Window, div, px,
};
use gpui_webview::WebView;
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens};
use serde_json::{Value, json};
use wry::http::{Request, Response, StatusCode, header::CONTENT_TYPE};

/// 协议里唯一的自定义协议名。
const EDITOR_PROTOCOL: &str = "lithe-gpui";

/// 宿主菜单/命令面板允许转发的 Monaco action id。
///
/// 菜单文案来自 i18n 且可能被本地化，直接拼进脚本等于把界面文本变成任意 JS；
/// 所以宿主只按名字匹配这里的 id，白名单之外的命令一律拒绝。新增菜单项必须
/// 同时在这里登记。
const MENU_COMMANDS: &[&str] = &[
    "undo",
    "redo",
    "editor.action.clipboardCutAction",
    "editor.action.clipboardCopyAction",
    "editor.action.clipboardPasteAction",
    "editor.action.selectAll",
    "actions.find",
    "editor.action.startFindReplaceAction",
    "editor.action.nextMatchFindAction",
    "editor.action.previousMatchFindAction",
    "editor.action.commentLine",
    "editor.action.formatDocument",
    "editor.action.gotoLine",
    "editor.action.revealDefinition",
    "editor.action.referenceSearch.trigger",
    "editor.action.showHover",
    "editor.action.quickFix",
    "editor.action.triggerParameterHints",
    "editor.action.copyLinesDownAction",
    "editor.action.deleteLines",
    "editor.action.moveLinesUpAction",
    "editor.action.moveLinesDownAction",
    "editor.action.formatSelection",
    "editor.action.goToImplementation",
    "editor.action.goToTypeDefinition",
    "editor.action.rename",
];

/// 前端发来的消息。IPC 回调只负责构造它，真正的处理在主线程的消息泵里。
struct WireMessage {
    /// 空字符串表示不需要回复。
    request_id: String,
    /// 统一信封里的 `payload` 对象。
    payload: Value,
}

/// 一个已打开文档的 Rust 侧状态。
struct DocumentState {
    /// Monaco 模型 id：工作区相对路径（`/` 分隔），无法相对时退化为规范化绝对路径。
    id: String,
    /// 调用方传入的路径；事件里回传它，工作台按绝对路径匹配标签。
    absolute_path: PathBuf,
    /// 最近一次 `open_file`/`save` 提供的工作区根。
    root: PathBuf,
    /// 传给 Core 的工作区相对路径，始终 `/` 分隔。
    relative: String,
    filename: String,
    language: String,
    readonly: bool,
    dirty: bool,
    revision: u64,
    /// 最近一次已知的完整文本。只用于页面重载后重新 `open`，不是编辑源的真相。
    text: String,
}

/// 一条编辑器诊断。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiagnosticItem {
    pub path: PathBuf,
    pub severity: u8,
    pub message: String,
    pub line: u32,
    pub column: u32,
    pub source: Option<String>,
}

/// 编辑器向工作台广播的事件。
#[derive(Clone, Debug)]
pub enum EditorEvent {
    DirtyChanged {
        path: PathBuf,
        dirty: bool,
    },
    Saved {
        path: PathBuf,
    },
    SaveFailed {
        path: PathBuf,
        message: String,
    },
    /// 另存为成功。`from` 是写盘前的路径，工作台据此关闭旧标签并打开 `to`。
    SavedAs {
        from: PathBuf,
        to: PathBuf,
    },
    CursorChanged {
        line: u32,
        column: u32,
    },
    /// Monaco 汇总的全部已打开模型的 markers 快照。
    ///
    /// 只在整份列表变化时发出；事务替换语义，工作台应丢弃旧数据而不是合并。
    Diagnostics {
        items: Vec<DiagnosticItem>,
    },
}

impl EventEmitter<EditorEvent> for EditorSurface {}

/// 基于 WebView 的编辑区。
pub struct EditorSurface {
    /// WebView 只创建一次。资源缺失或平台构建失败时为 `None`，render 降级成错误文本。
    webview: Option<Entity<WebView>>,
    webview_error: Option<SharedString>,
    /// IPC 回调 -> 主线程消息泵。
    receiver: async_channel::Receiver<WireMessage>,
    /// 首帧 Render 只启动一次消息泵。
    pump_started: bool,
    /// 已打开的文档，键是 Monaco 模型 id。
    documents: HashMap<String, DocumentState>,
    /// 当前活动文档的 id。
    current: Option<String>,
    current_path: Option<PathBuf>,
    /// 当前活动文档的脏状态；`mark_dirty` 与 `dirty` 消息都会更新它。
    dirty: bool,
    cursor_line: u32,
    cursor_column: u32,
    /// 最近一次上报的诊断快照。前端每次发全量列表，用它抑制重复事件。
    diagnostics: Vec<DiagnosticItem>,
    /// 保存失败、前端 `failure` 等需要展示的错误。构建期错误单独放在
    /// `webview_error`，因为那时还没有页面。
    error: Option<SharedString>,
    /// 文档集合代数：`clear`（切换项目、关闭最后一个标签）时递增。异步 LSP
    /// 结果返回后必须与当前代数一致，避免旧工作区的数据落进新文档。
    generation: u64,
    /// 编辑器外观偏好；由设置页写入，ready 和 set_preferences 时下发。
    editor_font_size: f32,
    editor_wrap: bool,
    editor_minimap: bool,
    editor_line_numbers: bool,
    editor_scroll_beyond_last_line: bool,
    /// 空白字符是否可见；菜单 View > Render Whitespace 切换。
    editor_render_whitespace: bool,
    /// 字体连字（Monaco `fontLigatures`）。
    editor_font_ligatures: bool,
    /// Code Lens（Monaco `codeLens`）。
    editor_code_lens: bool,
    /// Tab 宽度（Monaco `tabSize`）。
    editor_tab_size: u32,
}

impl EditorSurface {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (sender, receiver) = async_channel::unbounded::<WireMessage>();
        let asset_dir = editor_asset_dir();
        let index_path = asset_dir.join("index.html");

        let (webview, webview_error) = if !index_path.is_file() {
            let message = format!("{}: {}", tr("Editor unavailable"), index_path.display());
            (None, Some(SharedString::from(message)))
        } else {
            let builder = wry::WebViewBuilder::new();
            #[cfg(debug_assertions)]
            let builder = builder.with_devtools(true);

            let protocol_dir = asset_dir;
            let builder = builder
                .with_custom_protocol(EDITOR_PROTOCOL.into(), move |_webview_id, request| {
                    asset_response(&protocol_dir, request)
                })
                .with_ipc_handler(move |request| {
                    // 只解析并投递；这里绝不能借 GPUI、写文件或执行脚本。
                    if let Some(message) = decode_ipc(request.body()) {
                        let _ = sender.send_blocking(message);
                    }
                });

            match WebView::build(builder, window, cx) {
                Ok(mut built) => {
                    // 唯一的导航入口：整个生命周期只在这里加载页面。
                    built.load_url(editor_url());
                    (Some(cx.new(|_| built)), None)
                }
                Err(error) => (
                    None,
                    Some(SharedString::from(format!(
                        "{}: {error}",
                        tr("Editor unavailable")
                    ))),
                ),
            }
        };

        Self {
            webview,
            webview_error,
            receiver,
            pump_started: false,
            documents: HashMap::new(),
            current: None,
            current_path: None,
            dirty: false,
            cursor_line: 0,
            cursor_column: 0,
            diagnostics: Vec::new(),
            error: None,
            generation: 0,
            editor_font_size: LitheMetrics::CODE_FONT_SIZE,
            editor_wrap: false,
            editor_minimap: false,
            editor_line_numbers: true,
            editor_scroll_beyond_last_line: false,
            editor_render_whitespace: false,
            editor_font_ligatures: false,
            editor_code_lens: false,
            editor_tab_size: 4,
        }
    }

    /// 更新编辑器外观并立即下发。
    ///
    /// 主题切换或设置页修改字号/换行/minimap/行号/滚动越界时由工作台调用；
    /// 页面尚未 ready 时只更新状态，ready 消息会用最新值发送 `configure`。
    pub fn set_preferences(
        &mut self,
        font_size: f32,
        wrap: bool,
        minimap: bool,
        line_numbers: bool,
        scroll_beyond_last_line: bool,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let font_size = font_size.clamp(9.0, 32.0);
        // 即使偏好数值没变也要下发：主题切换时背景/前景来自 current_tokens，
        // 工作台复用这个入口刷新 Monaco 主题。
        self.editor_font_size = font_size;
        self.editor_wrap = wrap;
        self.editor_minimap = minimap;
        self.editor_line_numbers = line_numbers;
        self.editor_scroll_beyond_last_line = scroll_beyond_last_line;
        if self.webview.is_some() {
            self.send_configure(cx);
        }
        cx.notify();
    }

    /// 切换空白字符渲染（View > Render Whitespace）。
    ///
    /// 单独成方法而不是加进 [`Self::set_preferences`]：那组参数对应设置页里
    /// 会持久化的偏好，空白字符只是一个随菜单点击生效的显示开关。值没变时
    /// 直接返回，避免每次点菜单都重发整份 `configure`。
    pub fn set_render_whitespace(&mut self, visible: bool, cx: &mut Context<Self>) {
        if self.editor_render_whitespace == visible {
            return;
        }
        self.editor_render_whitespace = visible;
        if self.webview.is_some() {
            self.send_configure(cx);
        }
        cx.notify();
    }

    /// 字体连字、Code Lens 与 Tab 宽度；设置页修改后由工作台下发。
    pub fn set_editor_extras(
        &mut self,
        ligatures: bool,
        code_lens: bool,
        tab_size: u32,
        cx: &mut Context<Self>,
    ) {
        let tab_size = tab_size.clamp(1, 8);
        if self.editor_font_ligatures == ligatures
            && self.editor_code_lens == code_lens
            && self.editor_tab_size == tab_size
        {
            return;
        }
        self.editor_font_ligatures = ligatures;
        self.editor_code_lens = code_lens;
        self.editor_tab_size = tab_size;
        if self.webview.is_some() {
            self.send_configure(cx);
        }
        cx.notify();
    }

    /// 打开（或重新激活）一个文件。
    ///
    /// `root` 是工作区根，`path` 通常是绝对路径；文件写入 Core 时一律换成
    /// `/` 分隔的工作区相对路径。`text` 只在首次创建模型时使用，同一 id 再次
    /// 打开不会覆盖前端已有的模型。
    pub fn open_file(
        &mut self,
        root: PathBuf,
        path: PathBuf,
        text: String,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (id, relative, absolute_path) = document_identity(&root, &path);
        let filename = filename_for(&absolute_path);
        let language = language_for(&absolute_path);

        let document = self
            .documents
            .entry(id.clone())
            .or_insert_with(|| DocumentState {
                id: id.clone(),
                absolute_path: absolute_path.clone(),
                root: root.clone(),
                relative: relative.clone(),
                filename: filename.clone(),
                language: language.clone(),
                readonly: false,
                dirty: false,
                revision: 0,
                text: String::new(),
            });
        // 刷新缓存快照；前端对已存在的 id 会忽略 `text`。
        document.absolute_path = absolute_path.clone();
        document.root = root;
        document.relative = relative;
        document.filename = filename;
        document.language = language;
        document.text = text;

        self.dirty = self
            .documents
            .get(&id)
            .map(|document| document.dirty)
            .unwrap_or(false);
        self.current = Some(id.clone());
        self.current_path = Some(absolute_path);
        self.error = None;

        if let Some(script) = self.documents.get(&id).map(open_script) {
            self.evaluate(script, cx);
        }
        cx.notify();
    }

    /// 清空编辑区与所有文档状态。
    pub fn clear(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        // 清空即作废所有已发出的异步 LSP 请求，防止旧项目的回复污染新项目。
        self.generation = self.generation.wrapping_add(1);
        self.documents.clear();
        // 旧工作区的诊断随之作废。这里不发事件：`clear` 由工作台在自身更新
        // 过程中调用，同步 emit 会重入它的实体更新；Problems 的清空由工作台在
        // 切换项目时自行处理。丢掉快照只是让下一次上报不会被误判为“未变化”。
        self.diagnostics.clear();
        self.current = None;
        self.current_path = None;
        self.dirty = false;
        self.error = None;
        self.evaluate("window.lithe && window.lithe.clear();".to_string(), cx);
        cx.notify();
    }

    pub fn current_path(&self) -> Option<&Path> {
        self.current_path.as_deref()
    }

    /// 控制原生 WebView 是否可见。
    ///
    /// Windows 上 WebView 是覆盖在 GPUI 之上的原生子视图，设置页、命令面板等
    /// GPUI 覆盖层会被它挡住。打开覆盖层时由工作台临时隐藏，关闭后恢复。
    pub fn set_webview_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if let Some(webview) = self.webview.as_ref() {
            let _ = webview.update(cx, |webview, _| {
                let _ = webview.set_visible(visible);
                if !visible {
                    // Windows 上仅隐藏原生视图不足以让出鼠标命中区，
                    // 同时把 bounds 置零；恢复时由元素 prepaint 重新写入。
                    let _ = webview.set_bounds(wry::Rect::default());
                }
            });
            // 恢复可见时必须让元素重新 prepaint，才能在隐藏期间被清空的 bounds
            // 写回真实大小。
            cx.notify();
        }
    }

    /// 打开当前 WebView 的开发者工具（仅调试构建可用）。
    ///
    /// 这是只读调试能力，不影响发布构建：`wry::WebView::open_devtools` 只在
    /// `debug_assertions` 或 `devtools` feature 下才被编译，这里再用 `cfg`
    /// 让发布构建连调用点都不存在，菜单项在发布版表现为静默无操作。
    pub fn open_devtools(&mut self, cx: &mut Context<Self>) {
        let Some(webview) = self.webview.as_ref() else {
            return;
        };
        #[cfg(debug_assertions)]
        {
            // 与 `evaluate` 一样，原生 WebView 命令必须经由 GPUI 主线程的 update。
            webview.update(cx, |webview, _cx| {
                webview.raw().open_devtools();
            });
        }
        #[cfg(not(debug_assertions))]
        {
            let _ = &webview;
            let _ = &cx;
        }
    }

    /// 关闭一个标签并释放 Monaco 模型。
    ///
    /// 只按调用方传入的路径匹配文档；找不到时什么也不做。
    pub fn close_file(&mut self, path: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.find_document_id(&path) else {
            return;
        };

        let was_current = self.current.as_deref() == Some(id.as_str());
        self.documents.remove(&id);
        if was_current {
            self.current = None;
            self.current_path = None;
            self.dirty = false;
        }

        self.evaluate(
            format!("window.lithe && window.lithe.close({});", js_string(&id)),
            cx,
        );
        cx.notify();
    }

    /// 重新载入当前文件（File > Revert File），丢弃内存里的未保存修改。
    ///
    /// Monaco 对已存在的 id 不会用 `open` 的 `text` 覆盖模型，所以先
    /// [`Self::close_file`] 释放模型，再 [`Self::open_file`] 按同一路径新建；
    /// 新建的 [`DocumentState`] 脏状态是 `false`，正好完成脏标记归零，当前文档
    /// 仍是同一个文件。`text` 由调用方从磁盘读出，这里不碰文件系统。
    pub fn reload_current(
        &mut self,
        root: PathBuf,
        path: PathBuf,
        text: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_file(path.clone(), window, cx);
        self.open_file(root, path, text, window, cx);
    }

    /// 记录脏状态，不写文件、不重新加载页面。
    pub fn mark_dirty(&mut self, dirty: bool, _window: &mut Window, cx: &mut Context<Self>) {
        if self.dirty == dirty {
            return;
        }
        self.dirty = dirty;
        if let Some(current) = self.current.clone() {
            if let Some(document) = self.documents.get_mut(&current) {
                document.dirty = dirty;
            }
        }
        cx.notify();
    }

    /// 执行一个宿主菜单/命令面板命令。
    ///
    /// 只转发 [`MENU_COMMANDS`] 里的 action id，返回 `false` 表示命令被拒绝或
    /// 当前没有文档；调用方可以据此决定是否提示，前端不需要再兜底。
    pub fn run_command(&mut self, command: &str, cx: &mut Context<Self>) -> bool {
        let command = command.trim();
        if command.is_empty() || !MENU_COMMANDS.contains(&command) {
            return false;
        }
        if self.current.is_none() {
            return false;
        }
        self.evaluate(
            format!(
                "window.lithe && window.lithe.command({});",
                js_string(command)
            ),
            cx,
        );
        true
    }

    /// 滚动并定位到指定行（1-based）。
    ///
    /// 不用 Monaco 的 `command`（它只接受白名单 action id）：定位需要携带行号，
    /// 因此走独立的一次 `evaluate_script`。行号在前端做一次夹取，越界不会抛错。
    ///
    /// 前端 bundle 可能还没包含 `revealLine`（`gpui/editor/dist` 是生成产物），
    /// 所以这里先探测方法存在再调用，旧 bundle 上退化为只打开文件、不跳行。
    pub fn reveal_line(&mut self, line: u32, _window: &mut Window, cx: &mut Context<Self>) {
        if self.current.is_none() {
            return;
        }
        self.evaluate(
            format!(
                "window.lithe && window.lithe.revealLine && window.lithe.revealLine({});",
                line.max(1)
            ),
            cx,
        );
    }

    /// 触发前端保存（File > Save）。
    ///
    /// 没有活动文档时什么也不做：`saveActive` 在前端也守着一层，但宿主不应该
    /// 为一个空编辑区发出命令。
    pub fn save(&mut self, cx: &mut Context<Self>) {
        if self.current.is_none() {
            return;
        }
        self.evaluate("window.lithe && window.lithe.save();".to_string(), cx);
    }

    /// 触发前端保存全部（File > Save All）。
    ///
    /// 哪些文档需要保存交给前端判断：Rust 的 `dirty` 只跟当前活动文档同步，
    /// 按它逐个判断会漏掉后台标签里没保存过的修改。没有任何文档时不发调用。
    pub fn save_all(&mut self, cx: &mut Context<Self>) {
        if self.documents.is_empty() {
            return;
        }
        self.evaluate("window.lithe && window.lithe.saveAll();".to_string(), cx);
    }

    /// 让当前文档把内容写到 `target`（另存为）。
    ///
    /// 只发请求，不直接读前端内容；写盘完成后通过
    /// [`EditorEvent::SavedAs`] 通知工作台迁移标签。没有活动文档时什么也不做。
    pub fn save_as(&mut self, target: PathBuf, cx: &mut Context<Self>) {
        if self.current.is_none() {
            return;
        }
        let target = target.to_string_lossy().into_owned();
        self.evaluate(
            format!(
                "window.lithe && window.lithe.saveAs({});",
                js_string(&target)
            ),
            cx,
        );
    }

    /// 把键盘焦点交还 Monaco。
    ///
    /// 命令面板/菜单导航关闭后调用；WebView 是原生子视图，焦点留在 GPUI 时
    /// 编辑器收不到键盘输入。
    pub fn focus(&mut self, cx: &mut Context<Self>) {
        self.evaluate("window.lithe && window.lithe.focus();".to_string(), cx);
    }

    /// 切换当前 WebView 的只读模式（分屏副窗格用，防止同一文件两个可写缓冲）。
    ///
    /// 只切 Monaco 的编辑能力，不碰保存、命令等既有路径；没有 WebView 时
    /// 静默返回，因为页面没起来也就没有可写的缓冲。
    pub fn set_readonly(&mut self, readonly: bool, cx: &mut Context<Self>) {
        self.evaluate(
            format!("window.lithe && window.lithe.setReadonly({readonly});"),
            cx,
        );
    }

    /// 启动消息泵。只在首帧 `Render` 里调用一次。
    fn start_pump(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pump_started {
            return;
        }
        self.pump_started = true;

        let receiver = self.receiver.clone();
        cx.defer_in(window, move |_this, window, cx| {
            cx.spawn_in(window, async move |this, cx| {
                while let Ok(message) = receiver.recv().await {
                    let _ = this.update_in(cx, |this, window, cx| {
                        this.handle_message(message, window, cx);
                    });
                }
            })
            .detach();
        });
    }

    /// 在主线程处理一条 IPC 消息。
    fn handle_message(
        &mut self,
        message: WireMessage,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let WireMessage {
            request_id,
            payload,
        } = message;

        match payload.get("type").and_then(Value::as_str) {
            Some("ready") => {
                self.error = None;
                // 页面重载后所有模型都是新建的，上一份 markers 快照已经失效；
                // 先清掉，避免 Problems 保留一个已经不存在的错误。
                if !self.diagnostics.is_empty() {
                    self.diagnostics.clear();
                    cx.emit(EditorEvent::Diagnostics { items: Vec::new() });
                }
                self.send_configure(cx);
                self.resend_documents(cx);
                cx.notify();
            }
            Some("edit") => {
                let id = payload.get("id").and_then(Value::as_str).unwrap_or("");
                let base_revision = payload
                    .get("baseRevision")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let revision = if let Some(document) = self.documents.get_mut(id) {
                    document.revision = base_revision.saturating_add(1);
                    document.revision
                } else {
                    base_revision.saturating_add(1)
                };
                let value = json!({ "revision": revision });
                self.resolve(&request_id, &value, cx);
            }
            Some("dirty") => {
                let id = payload.get("id").and_then(Value::as_str).unwrap_or("");
                let dirty = payload
                    .get("dirty")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.set_document_dirty(id, dirty, cx);
            }
            Some("save") => {
                let id = payload
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.save_document(id, text, request_id, window, cx);
            }
            Some("saveAs") => {
                let id = payload
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let target = payload
                    .get("path")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.save_document_as(id, text, PathBuf::from(target), request_id, window, cx);
            }
            Some("focus") | Some("cursor") => {
                let line = payload
                    .get("line")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    .unwrap_or(0);
                let column = payload
                    .get("column")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    .unwrap_or(0);
                if self.cursor_line != line || self.cursor_column != column {
                    self.cursor_line = line;
                    self.cursor_column = column;
                    cx.emit(EditorEvent::CursorChanged { line, column });
                    cx.notify();
                }
            }
            Some("lsp") => {
                self.handle_lsp_request(&payload, request_id, window, cx);
            }
            Some("diagnostics") => {
                self.handle_diagnostics(&payload, cx);
            }
            Some("failure") => {
                let message = payload
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                if !message.is_empty() {
                    self.error = Some(SharedString::from(message.to_string()));
                    cx.notify();
                }
            }
            _ => {
                // 未知消息也要回复，否则前端会等满 10 秒。
                let value = json!({});
                self.resolve(&request_id, &value, cx);
            }
        }
    }

    /// 处理一条 `diagnostics` 消息。
    ///
    /// 前端上报的已经是全量快照，并且只包含已打开的文件；这里仍然丢弃缺路径/
    /// 空消息的条目，避免 Problems 里出现无法定位的行。事件只在列表真正变化
    /// 时发出 —— 输入时 markers 会连续变化，重复事件会让工作台每一轮都重绘。
    /// 诊断不参与编辑区自身渲染，所以这里不 `notify`。
    fn handle_diagnostics(&mut self, payload: &Value, cx: &mut Context<Self>) {
        let items = parse_diagnostics(payload);
        if self.diagnostics == items {
            return;
        }
        self.diagnostics = items.clone();
        cx.emit(EditorEvent::Diagnostics { items });
    }

    /// 处理一条轻量 LSP 请求。
    ///
    /// 请求携带的 `text` 是前端的当前快照；Rust 不在这里读取文档内容。Core 的
    /// 计算是阻塞的，因此放进后台执行，完成后回主线程回复。`filename` 只用于
    /// 前端展示，路径一律以 [`DocumentState::absolute_path`] 为准。
    ///
    /// 语言能力失败（Core 报错、路径不可表示、文档已关闭、项目已切换）都属于
    /// 正常情况，只回复 `null`，不写 `error` 状态。
    fn handle_lsp_request(
        &mut self,
        payload: &Value,
        request_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(request) = LspRequest::parse(payload) else {
            self.resolve(&request_id, &Value::Null, cx);
            return;
        };
        // 先取出所有权数据，避免在 `else` 分支调用 `resolve` 时仍持有
        // `documents` 的不可变借用。
        let absolute_path = self
            .documents
            .get(&request.document_id)
            .map(|document| document.absolute_path.clone());
        let Some(absolute_path) = absolute_path else {
            // 文档在请求到达前已经关闭；前端仍在等回复。
            self.resolve(&request_id, &Value::Null, cx);
            return;
        };
        let Some(file_path) = absolute_path.to_str().map(str::to_string) else {
            // Core 的请求模型使用 UTF-8 字符串，非 UTF-8 路径无法无损表示。
            self.resolve(&request_id, &Value::Null, cx);
            return;
        };

        let generation = self.generation;
        let document_id = request.document_id.clone();
        let command = request.method.command();
        let core_payload = request.into_core_payload(file_path);
        let client = CoreClient::new();

        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move { client.execute_raw(command, core_payload) })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                // 切换项目后 `generation` 已变化，关闭的文档也不在集合里；
                // 两种情况都丢弃结果，但仍然回复，避免前端等待 10 秒后超时。
                let still_valid =
                    this.generation == generation && this.documents.contains_key(&document_id);
                let value = match result {
                    Ok(data) if still_valid && !data.is_null() => data,
                    _ => Value::Null,
                };
                this.resolve(&request_id, &value, cx);
            });
        })
        .detach();
    }

    /// 更新文档脏状态；只有真正变化时才广播事件。
    fn set_document_dirty(&mut self, id: &str, dirty: bool, cx: &mut Context<Self>) {
        let Some(document) = self.documents.get_mut(id) else {
            return;
        };
        if document.dirty == dirty {
            return;
        }
        document.dirty = dirty;
        let path = document.absolute_path.clone();
        if self.current.as_deref() == Some(id) {
            self.dirty = dirty;
        }
        cx.emit(EditorEvent::DirtyChanged { path, dirty });
        cx.notify();
    }

    /// 把保存请求放到后台线程执行，完成后回主线程回复并广播事件。
    fn save_document(
        &mut self,
        id: String,
        text: String,
        request_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 协议要求 `save` 回传 open 时的 id；只有空 id 才回退到当前文档。
        // 未知 id 宁可报错，也不能把文本写进另一个文件。
        let key = if id.is_empty() {
            self.current.clone()
        } else if self.documents.contains_key(&id) {
            Some(id)
        } else {
            None
        };
        let Some(key) = key else {
            let path = self.current_path.clone().unwrap_or_default();
            let message = tr("No file open").to_string();
            let value = json!({ "saved": false, "error": message });
            self.resolve(&request_id, &value, cx);
            cx.emit(EditorEvent::SaveFailed { path, message });
            cx.notify();
            return;
        };
        let Some(document) = self.documents.get(&key) else {
            return;
        };

        let root = document.root.clone();
        let relative = document.relative.clone();
        let absolute_path = document.absolute_path.clone();
        let client = CoreClient::new();

        cx.spawn_in(window, async move |this, cx| {
            let (result, text) = cx
                .background_spawn(async move {
                    let result = client.write_file(&root, &relative, &text);
                    (result, text)
                })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                match result {
                    Ok(_bytes) => {
                        if let Some(document) = this.documents.get_mut(&key) {
                            document.text = text;
                            document.dirty = false;
                        }
                        if this.current.as_deref() == Some(key.as_str()) {
                            this.dirty = false;
                        }
                        this.error = None;

                        let value = json!({ "saved": true });
                        this.resolve(&request_id, &value, cx);
                        this.evaluate(
                            format!("window.lithe.setSaved({}, true);", js_string(&key)),
                            cx,
                        );
                        cx.emit(EditorEvent::Saved {
                            path: absolute_path.clone(),
                        });
                        // 快照只用于 File > Local History，不参与保存语义：写盘已经
                        // 成功、前端也已收到结果，记录失败会被静默吞掉，不回滚、
                        // 不改状态，也不影响这里已经完成的保存。
                        if let Some(saved) = this.documents.get(&key) {
                            crate::local_history::record(&absolute_path, &saved.text);
                        }
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.error = Some(SharedString::from(format!(
                            "{}: {message}",
                            tr("Save failed")
                        )));
                        let value = json!({ "saved": false, "error": message });
                        this.resolve(&request_id, &value, cx);
                        cx.emit(EditorEvent::SaveFailed {
                            path: absolute_path.clone(),
                            message,
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 把某个文档另存到 `target`，完成后回主线程回复并广播事件。
    ///
    /// 与 [`Self::save_document`] 的区别是写入目标由调用方给出（原生保存对话框
    /// 选中的绝对路径），不再经过 Core 的工作区相对路径，所以直接用
    /// `std::fs::write`。写盘仍然放到后台线程，主线程只做状态更新和回复。
    fn save_document_as(
        &mut self,
        id: String,
        text: String,
        target: PathBuf,
        request_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 与 `save` 相同的 id 规则：空 id 回退到当前文档，未知 id 一律拒绝，
        // 避免把文本写进调用方没有打开的路径所对应的文档。
        let key = if id.is_empty() {
            self.current.clone()
        } else if self.documents.contains_key(&id) {
            Some(id)
        } else {
            None
        };
        let Some(key) = key else {
            let path = self.current_path.clone().unwrap_or_default();
            let message = tr("No file open").to_string();
            let value = json!({ "saved": false, "error": message });
            self.resolve(&request_id, &value, cx);
            cx.emit(EditorEvent::SaveFailed { path, message });
            cx.notify();
            return;
        };
        // 失败事件沿用旧路径，和 `save` 的语义一致。
        let document_path = self
            .documents
            .get(&key)
            .map(|document| document.absolute_path.clone())
            .unwrap_or_default();

        // `target` 之后还要用于更新状态和事件，交给后台线程的是一份克隆。
        let write_target = target.clone();
        cx.spawn_in(window, async move |this, cx| {
            let (result, text) = cx
                .background_spawn(async move {
                    let result = (|| -> std::io::Result<()> {
                        // 另存为允许写到还不存在的目录，父目录先建出来；
                        // 只有文件名、没有父目录时跳过。
                        if let Some(parent) = write_target
                            .parent()
                            .filter(|path| !path.as_os_str().is_empty())
                        {
                            std::fs::create_dir_all(parent)?;
                        }
                        std::fs::write(&write_target, text.as_bytes())?;
                        Ok(())
                    })();
                    (result, text)
                })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                // 事件里的旧路径必须是写盘前的 `current_path`；取不到时只更新
                // 路径和脏状态，不发事件，免得工作台收到无法匹配标签的迁移请求。
                let from = this.current_path.clone();
                match result {
                    Ok(()) => {
                        if let Some(document) = this.documents.get_mut(&key) {
                            document.absolute_path = target.clone();
                            document.dirty = false;
                            // 缓存快照要和磁盘一致，页面重载后重新 open 才不会回退。
                            document.text = text;
                        }
                        if this.current.as_deref() == Some(key.as_str()) {
                            this.current_path = Some(target.clone());
                            this.dirty = false;
                        }
                        this.error = None;

                        let value = json!({ "saved": true });
                        this.resolve(&request_id, &value, cx);
                        this.evaluate(
                            format!("window.lithe.setSaved({}, true);", js_string(&key)),
                            cx,
                        );
                        if let Some(from) = from {
                            cx.emit(EditorEvent::SavedAs {
                                from,
                                to: target.clone(),
                            });
                        }
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.error = Some(SharedString::from(format!(
                            "{}: {message}",
                            tr("Save failed")
                        )));
                        let value = json!({ "saved": false, "error": message });
                        this.resolve(&request_id, &value, cx);
                        cx.emit(EditorEvent::SaveFailed {
                            path: document_path.clone(),
                            message,
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 回复一个带 `requestId` 的 IPC 请求。空 id 表示无需回复。
    fn resolve(&mut self, request_id: &str, value: &Value, cx: &mut Context<Self>) {
        if request_id.is_empty() {
            return;
        }
        let script = format!(
            "window.lithe.resolve({}, {});",
            js_string(request_id),
            js_json(value)
        );
        self.evaluate(script, cx);
    }

    /// 通过 `current_tokens` 生成 Monaco 主题并下发。
    fn send_configure(&mut self, cx: &mut Context<Self>) {
        let tokens = current_tokens(cx);
        let payload = json!({
            "dark": tokens.editor.l <= 0.5,
            "background": hex_color(tokens.editor),
            "foreground": hex_color(tokens.primary_text),
            "fontFamily": MONO_FONT_FAMILY,
            "fontSize": self.editor_font_size,
            "wrap": self.editor_wrap,
            "minimap": self.editor_minimap,
            "lineNumbers": if self.editor_line_numbers { "on" } else { "off" },
            "scrollBeyondLastLine": self.editor_scroll_beyond_last_line,
            "renderWhitespace": self.editor_render_whitespace,
            "fontLigatures": self.editor_font_ligatures,
            "codeLens": self.editor_code_lens,
            "tabSize": self.editor_tab_size,
        });
        self.evaluate(
            format!(
                "window.lithe && window.lithe.configure({});",
                js_json(&payload)
            ),
            cx,
        );
    }

    /// 页面（重新）就绪后重新下发缓存文档。当前文档最后发送，保持活动模型。
    fn resend_documents(&mut self, cx: &mut Context<Self>) {
        let current = self.current.clone();
        let mut scripts = Vec::with_capacity(self.documents.len());

        for (id, document) in &self.documents {
            if current.as_deref() == Some(id.as_str()) {
                continue;
            }
            scripts.push(open_script(document));
        }
        if let Some(id) = current.as_deref() {
            if let Some(document) = self.documents.get(id) {
                scripts.push(open_script(document));
            }
        }

        for script in scripts {
            self.evaluate(script, cx);
        }
    }

    /// 唯一允许调用 `evaluate_script` 的地方。调用方必须已经在主线程的
    /// update/render 回调里。
    fn evaluate(&mut self, script: String, cx: &mut Context<Self>) {
        let Some(webview) = self.webview.clone() else {
            return;
        };
        let result = webview.update(cx, |webview, _cx| webview.raw().evaluate_script(&script));
        if let Err(error) = result {
            self.error = Some(SharedString::from(format!(
                "{}: {error}",
                tr("Editor unavailable")
            )));
            cx.notify();
        }
    }

    /// 按绝对路径查找文档 id，兼容 Windows 的大小写与分隔符差异。
    fn find_document_id(&self, path: &Path) -> Option<String> {
        for document in self.documents.values() {
            if same_path(&document.absolute_path, path) {
                return Some(document.id.clone());
            }
        }
        // 调用方可能只给了工作区相对路径。项目内所有文档共享同一个根。
        let root = self
            .documents
            .values()
            .next()
            .map(|document| document.root.clone())?;
        let (id, _relative, _absolute) = document_identity(&root, path);
        self.documents.contains_key(&id).then_some(id)
    }
}

/// 一条轻量 LSP 请求中 Rust 需要的字段。
///
/// `filename` 不进入这里：路径权威是 `documents` 里的绝对路径，避免前端传的
/// 文件名和实际打开的文档不一致时把请求发到别的路径。
struct LspRequest {
    /// Monaco 模型 id，用于在 `documents` 中定位文档。
    document_id: String,
    method: LspMethod,
    /// 请求时前端的完整文档内容。
    text: String,
    /// 0-based 行号。
    line: u32,
    /// 0-based UTF-16 列号。
    character: u32,
}

#[derive(Clone, Copy)]
enum LspMethod {
    Completion,
    Hover,
    Definition,
    References,
}

impl LspMethod {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "completion" => Some(Self::Completion),
            "hover" => Some(Self::Hover),
            "definition" => Some(Self::Definition),
            "references" => Some(Self::References),
            _ => None,
        }
    }

    /// 对应的 Core 命令名。
    fn command(self) -> &'static str {
        match self {
            Self::Completion => "lsp.builtinCompletions",
            Self::Hover => "lsp.builtinHover",
            Self::Definition | Self::References => "lsp.builtinNavigation",
        }
    }

    /// 导航请求在 Core payload 里的 LSP method；其他请求不带该字段。
    fn navigation_method(self) -> Option<&'static str> {
        match self {
            Self::Definition => Some("textDocument/definition"),
            Self::References => Some("textDocument/references"),
            Self::Completion | Self::Hover => None,
        }
    }
}

impl LspRequest {
    /// 解析前端 payload。缺字段、字段类型不对或坐标无法表示时返回 `None`，
    /// 调用方统一回复 `null`。
    fn parse(payload: &Value) -> Option<Self> {
        let method = LspMethod::parse(payload.get("method")?.as_str()?)?;
        let document_id = payload.get("id")?.as_str()?;
        if document_id.is_empty() {
            return None;
        }
        // 协议字段 `filename` 只做类型校验；路径以已打开文档为准。
        if let Some(filename) = payload.get("filename") {
            filename.as_str()?;
        }
        let text = payload.get("text")?.as_str()?;
        let line = payload.get("line")?.as_u64()?;
        let character = payload.get("character")?.as_u64()?;
        Some(Self {
            document_id: document_id.to_string(),
            method,
            text: text.to_string(),
            line: u32::try_from(line).ok()?,
            character: u32::try_from(character).ok()?,
        })
    }

    /// 构造 Core 的 payload。`LspPosition` 使用 `line` + `utf16Column`。
    fn into_core_payload(self, file_path: String) -> Value {
        let mut payload = json!({
            "filePath": file_path,
            "text": self.text,
            "position": {
                "line": self.line,
                "utf16Column": self.character,
            },
        });
        if let Some(method) = self.method.navigation_method() {
            // `json!` 刚构造的 payload 一定是对象；即使不是也只跳过 method，
            // Core 会按无效请求返回失败，桥接层统一回复 null。
            if let Some(object) = payload.as_object_mut() {
                object.insert("method".to_string(), Value::String(method.to_string()));
            }
        }
        payload
    }
}

impl Render for EditorSurface {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 首帧启动 IPC 泵；不能在构造期 spawn。
        self.start_pump(window, cx);

        let tokens = current_tokens(cx);
        // dirty 由外层标签页消费；这里读一次，保证状态确实保存在 Surface 中。
        let _dirty = self.dirty;
        let error = self.error.clone();

        match self.webview.as_ref() {
            Some(webview) => {
                let webview = webview.clone();
                div()
                    .size_full()
                    .flex()
                    .flex_col()
                    .bg(tokens.editor)
                    .when_some(error, |this, error| this.child(error_strip(error, tokens)))
                    .child(div().flex_1().min_h(px(0.0)).child(webview))
            }
            None => {
                let message = self
                    .webview_error
                    .clone()
                    .unwrap_or_else(|| SharedString::from(tr("Editor unavailable")));
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(tokens.editor)
                    .px(px(16.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(message)
            }
        }
    }
}

/// 构建期/运行期错误条。单独占一行，避免被原生 WebView 覆盖。
fn error_strip(message: SharedString, tokens: LitheTokens) -> impl IntoElement {
    div()
        .w_full()
        .flex_shrink_0()
        .px(px(10.0))
        .py(px(6.0))
        .bg(tokens.raised)
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.error)
        .child(message)
}

/// `window.lithe.open(...)` 脚本。`document` 必须已经写入 `documents`。
fn open_script(document: &DocumentState) -> String {
    let payload = json!({
        "id": document.id,
        "filename": document.filename,
        "language": document.language,
        "text": document.text,
        "readonly": document.readonly,
    });
    format!("window.lithe && window.lithe.open({});", js_json(&payload))
}

/// 从统一信封里取出 `requestId` 与 `payload`。解析失败的消息直接丢弃。
fn decode_ipc(body: &str) -> Option<WireMessage> {
    let value: Value = serde_json::from_str(body).ok()?;
    let request_id = value
        .get("requestId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let payload = value.get("payload").cloned().unwrap_or(Value::Null);
    Some(WireMessage {
        request_id,
        payload,
    })
}

/// 解析 `diagnostics` 消息的 `items`。
///
/// 前端每次发全量快照，`items` 缺失或不是数组时等价于“没有诊断”；缺路径、
/// 空消息、坐标不可表示的条目一律丢弃，避免 Problems 里出现无法定位的行。
fn parse_diagnostics(payload: &Value) -> Vec<DiagnosticItem> {
    let Some(items) = payload.get("items").and_then(Value::as_array) else {
        return Vec::new();
    };
    items.iter().filter_map(diagnostic_item).collect()
}

fn diagnostic_item(value: &Value) -> Option<DiagnosticItem> {
    let path = value.get("path").and_then(Value::as_str)?.trim();
    if path.is_empty() {
        return None;
    }
    let message = value.get("message").and_then(Value::as_str)?.trim();
    if message.is_empty() {
        return None;
    }
    // 协议约定行列都 1 起算；0 视为非法，宁可不显示也不能定位到上一行。
    let position = |key: &str| -> Option<u32> {
        value
            .get(key)
            .and_then(Value::as_u64)
            .and_then(|raw| u32::try_from(raw).ok())
            .filter(|raw| *raw >= 1)
    };
    // severity 保留 Monaco 的原始位值（1=Hint, 2=Info, 4=Warning, 8=Error）。
    let severity = u8::try_from(value.get("severity").and_then(Value::as_u64)?).ok()?;
    Some(DiagnosticItem {
        path: PathBuf::from(path),
        severity,
        message: message.to_string(),
        line: position("line")?,
        column: position("column")?,
        source: value
            .get("source")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|source| !source.is_empty())
            .map(str::to_string),
    })
}

/// 编辑器资源目录：环境变量优先，否则 `CARGO_MANIFEST_DIR/../editor/dist`。
fn editor_asset_dir() -> PathBuf {
    if let Some(directory) = std::env::var_os("LITHE_GPUI_EDITOR_DIR") {
        if !directory.is_empty() {
            return PathBuf::from(directory);
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../editor/dist")
}

/// 自定义协议 URL。Windows 的 WebView2 只认 `http://<scheme>.localhost/...`。
fn editor_url() -> &'static str {
    #[cfg(target_os = "windows")]
    {
        "http://lithe-gpui.localhost/index.html"
    }
    #[cfg(not(target_os = "windows"))]
    {
        "lithe-gpui://localhost/index.html"
    }
}

/// 把 `Hsla` 转成 Monaco 需要的 `#RRGGBB`。
fn hex_color(color: Hsla) -> String {
    let rgba = Rgba::from(color);
    format!(
        "#{:02X}{:02X}{:02X}",
        color_channel(rgba.r),
        color_channel(rgba.g),
        color_channel(rgba.b)
    )
}

fn color_channel(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

/// 计算 Monaco id、Core 用的相对路径和事件用的绝对路径。
///
/// id 优先使用工作区相对路径；不在工作区内时才退化为规范化绝对路径，保证
/// 同一文件每次打开得到同一个 id。
fn document_identity(root: &Path, path: &Path) -> (String, String, PathBuf) {
    let (absolute, relative) = if path.is_absolute() {
        let relative = path.strip_prefix(root).ok().map(normalize_path);
        (path.to_path_buf(), relative)
    } else {
        (root.join(path), Some(normalize_path(path)))
    };

    let relative = relative.unwrap_or_else(|| normalize_path(&absolute));
    let id = if relative.is_empty() {
        normalize_path(&absolute)
    } else {
        relative.clone()
    };
    (id, relative, absolute)
}

/// Core 与 Monaco 都使用 `/` 分隔；Windows 的 `Path` 用 `\`。
fn normalize_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    if cfg!(windows) {
        text.replace('\\', "/")
    } else {
        text.into_owned()
    }
}

fn filename_for(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| path.display().to_string())
}

/// Monaco 只加载基础语言；未知扩展名统一走 Plain Text，避免未注册语言 id。
fn language_for(path: &Path) -> String {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("");
    match extension.to_ascii_lowercase().as_str() {
        "java" => "java",
        "md" | "markdown" => "markdown",
        _ => "plaintext",
    }
    .to_string()
}

fn same_path(left: &Path, right: &Path) -> bool {
    let left = normalize_path(left);
    let right = normalize_path(right);
    if cfg!(windows) {
        left.eq_ignore_ascii_case(&right)
    } else {
        left == right
    }
}

// ---------------------------------------------------------------------------
// 自定义协议
// ---------------------------------------------------------------------------

/// 处理一次 `lithe-gpui://` 请求。运行在 wry 的协议线程，不能碰 GPUI。
fn asset_response(root: &Path, request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    match read_asset(root, request.uri().path()) {
        Ok((content_type, body)) => build_response(StatusCode::OK, content_type, body),
        Err(status) => {
            let body = if status == StatusCode::FORBIDDEN {
                b"Forbidden".to_vec()
            } else if status == StatusCode::NOT_FOUND {
                b"Not Found".to_vec()
            } else {
                b"Internal Server Error".to_vec()
            };
            build_response(status, "text/plain; charset=utf-8", body)
        }
    }
}

fn build_response(
    status: StatusCode,
    content_type: &'static str,
    body: Vec<u8>,
) -> Response<Cow<'static, [u8]>> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, content_type)
        .header("Cache-Control", "no-cache")
        .body(Cow::Owned(body))
        .unwrap_or_else(|_| Response::new(Cow::Borrowed(&b""[..])))
}

/// 读取资源目录内的文件。拒绝 `..`、绝对路径、Windows 盘符/反斜杠，并在
/// 规范化后再次确认文件没有通过符号链接逃逸出资源目录。
fn read_asset(root: &Path, uri_path: &str) -> Result<(&'static str, Vec<u8>), StatusCode> {
    let relative = safe_relative_path(uri_path).ok_or(StatusCode::FORBIDDEN)?;

    let canonical_root =
        std::fs::canonicalize(root).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let candidate = canonical_root.join(&relative);
    let canonical = std::fs::canonicalize(&candidate).map_err(|_| StatusCode::NOT_FOUND)?;
    if !canonical.starts_with(&canonical_root) {
        return Err(StatusCode::FORBIDDEN);
    }
    if !canonical.is_file() {
        return Err(StatusCode::NOT_FOUND);
    }

    let body = std::fs::read(&canonical).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok((content_type_for(&relative), body))
}

/// `/` 是 index.html；其余路径只允许普通组件。
fn safe_relative_path(uri_path: &str) -> Option<PathBuf> {
    let decoded = percent_decode(uri_path)?;
    // `\` 和 `:` 在不同平台上语义不一致，直接拒绝最省心。
    if decoded.contains('\0') || decoded.contains('\\') || decoded.contains(':') {
        return None;
    }

    let trimmed = decoded.trim_start_matches('/');
    if trimmed.is_empty() {
        return Some(PathBuf::from("index.html"));
    }

    let mut relative = PathBuf::new();
    for component in Path::new(trimmed).components() {
        match component {
            Component::Normal(part) => relative.push(part),
            Component::CurDir => {}
            // ParentDir、RootDir、Prefix 都不允许。
            _ => return None,
        }
    }

    if relative.as_os_str().is_empty() {
        None
    } else {
        Some(relative)
    }
}

fn content_type_for(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("");
    match extension.to_ascii_lowercase().as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "wasm" => "application/wasm",
        "json" | "map" => "application/json; charset=utf-8",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        _ => "application/octet-stream",
    }
}

/// 解码 URI path 里的 `%XX`；非法编码返回 `None`。
fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return None;
            }
            let high = hex_value(bytes[index + 1])?;
            let low = hex_value(bytes[index + 2])?;
            decoded.push((high << 4) | low);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }

    String::from_utf8(decoded).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// JS 字面量
// ---------------------------------------------------------------------------

/// 把 Rust 字符串写进 JS 字符串字面量。JSON 转义对现代引擎已经足够，额外把
/// U+2028/U+2029 转义，避免它们作为行终止符拆断脚本。
fn js_string(value: &str) -> String {
    serde_json::to_string(value)
        .map(|text| escape_line_separators(&text))
        .unwrap_or_else(|_| String::from("\"\""))
}

/// 把 `Value` 直接嵌入脚本；`serde_json::Value` 的 Display 就是合法 JSON。
fn js_json(value: &Value) -> String {
    escape_line_separators(&value.to_string())
}

fn escape_line_separators(text: &str) -> String {
    text.replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}
