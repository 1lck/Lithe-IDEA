//! 工作区搜索面板（对齐 Tauri 左侧活动栏的「在文件中查找 / 替换」）。
//!
//! 顶部是查找 / 替换模式切换、搜索框、搜索选项（大小写 / 整词 / 正则）、
//! 结果计数与详情开关；替换模式额外显示替换行，详情展开后是 include /
//! exclude 路径过滤。下面是按文件分组的结果列表，支持键盘上下选择、Enter
//! 打开、加载更多与单条 / 整批替换。
//!
//! # 数据边界
//!
//! 搜索与替换的全部业务规则都在 `rust/lithe-core`，本视图只通过
//! `CoreClient::execute_raw` 发送 Core 已有命令：
//!
//! - `workspace.search`：文件名 + 内容匹配，payload 与
//!   `rust/lithe-core/src/project/files.rs` 的 `SearchRequest` 一致。
//! - `workspace.replacePreview`：计算替换后的全文，**不写盘**。
//! - `file.read` / `file.write`：读取原文、写回替换结果。
//!
//! 视图不复制匹配语义（大小写、整词、正则一律交给 Core），也不改 Core 的
//! 命令面。
//!
//! # 分页
//!
//! Core 的 `SearchRequest` 没有 offset 字段；Tauri 本地路径的 `file_offset`
//! 也不生效。因此「加载更多」用增大 `maxResults` 重新查询再合并的方式实现，
//! 不做无法验证的增量协议。
//!
//! # 路径过滤
//!
//! Core 只接受 `fileMask`（逗号分隔的 `*.java` 形式），没有 include/exclude
//! glob。这里的 include / exclude 在结果侧按工作区相对路径过滤，语义与 Tauri
//! 的 `createPathFilterPredicate` 一致：支持 `**`、`*`、`?`，其余字符按字面量。
//!
//! # 异步
//!
//! `CoreClient::execute_raw` 是阻塞调用，必须放进 `cx.background_spawn`。
//! 面板在 `new` 里不创建 `InputState`、也不发起任何任务：`InputState::new`
//! 需要 `Window`，而构造期 `cx.spawn` 会在 `App::run` 的可变借用内再次借用
//! App，触发 `RefCell already borrowed` panic。因此输入框在首帧 `Render` 中
//! 懒创建，重新搜索与聚焦通过 `cx.defer_in` 排到当前借用释放之后。
//!
//! # 过期结果
//!
//! 每次查询（输入变化、Enter、切换选项、切换根目录、加载更多）都会递增
//! `generation`。后台任务回到主线程后先比较 `generation`，只接受最新一次查询
//! 的结果。去抖计时器也在后台执行器里等待，不阻塞渲染线程；计时结束后同样要
//! 再检查一次 `generation`，所以连续输入不会把旧查询发出去。

use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gpui_kit::assets::IconName;
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::{Button, ButtonVariants as _, Toggle, ToggleVariants as _};
use gpui_kit::component::collapsible::Collapsible;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::tab::{Tab, TabBar};
use gpui_kit::component::{Disableable as _, Icon, Size};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, Context, Entity, FocusHandle, FontWeight, Hsla,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement, Render, SharedString,
    StatefulInteractiveElement as _, Styled, Subscription, Window, div, px,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, current_tokens, icon};
use serde_json::{Value, json};

mod filters;
mod replace;

use filters::{filter_groups, parse_path_filters};
use replace::{ReplaceOutcome, replace_paths};

/// 输入停止后等待多久再查询；对齐 Tauri 的 `SEARCH_DEBOUNCE_DELAY`。
const SEARCH_DEBOUNCE: Duration = Duration::from_millis(200);
/// 单次搜索的结果上限，和架构文档里的 payload 一致。
const SEARCH_MAX_RESULTS: usize = 200;
/// 每次「加载更多」把上限翻到多少；Core 的 `max_results` 上限是 10000。
const SEARCH_LOAD_MORE_STEP: usize = 400;
/// 搜索栏行高。
const SEARCH_HEADER_HEIGHT: f32 = 36.0;
/// 详情区（替换 + 路径过滤）单行高度。
const SEARCH_DETAIL_ROW_HEIGHT: f32 = 28.0;
/// 结果文件分组标题行高。
const SEARCH_GROUP_HEADER_HEIGHT: f32 = 24.0;
/// 单条匹配行高。
const SEARCH_MATCH_ROW_HEIGHT: f32 = 22.0;
/// 面板左右内边距。
const SEARCH_HORIZONTAL_PADDING: f32 = 8.0;
/// 匹配行相对面板左边的缩进。
const SEARCH_RESULT_INDENT: f32 = 22.0;
/// 行号列的固定宽度，保证预览文本左对齐。
const SEARCH_LINE_NUMBER_WIDTH: f32 = 44.0;
/// 搜索选项按钮尺寸。
const SEARCH_OPTION_BUTTON_SIZE: f32 = 22.0;

type OpenLocationHandler = Rc<dyn Fn(PathBuf, u32, &mut Window, &mut App) + 'static>;

/// 面板当前展示的状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SearchStatus {
    /// 还没有输入查询。
    Idle,
    /// 去抖等待中或 Core 正在执行搜索。
    Searching,
    /// 有结果，按文件分组展示。
    Ready,
    /// 查询完成但没有匹配。
    NoResults,
    /// 没有工作区、路径非法或 Core 返回错误。
    Error,
}

/// 工具窗的两种模式。
///
/// `Find` 保持「在文件中查找」的原始行为；`Replace` 额外显示替换行，并允许
/// 执行单条或整批替换。对齐 Tauri 的 `replaceVisible` 语义：进入替换模式时
/// 详情区（include / exclude）一并展开。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SearchMode {
    /// 只查找。
    #[default]
    Find,
    /// 查找并替换。
    Replace,
}

/// 匹配选项；字段名与 Core `SearchRequest` 的 camelCase 一一对应。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct SearchOptions {
    case_sensitive: bool,
    whole_words: bool,
    regular_expression: bool,
}

/// 同一个文件里的一条匹配。
struct SearchLine {
    /// 1-based 行号；文件级命中没有行号时按第 1 行处理。
    line: u32,
    /// 匹配行预览（Core 已 trim）。
    preview: SharedString,
}

/// 按工作区相对路径聚合的一组匹配。
struct SearchFileGroup {
    /// 工作区相对路径，使用 `/` 分隔；也作为分组身份。
    path: String,
    /// 文件名。
    name: String,
    /// 相对路径的目录部分；根目录文件为空字符串。
    directory: String,
    /// 该文件的匹配行。
    matches: Vec<SearchLine>,
}

/// 结果列表里的一行，用于键盘导航与选中态。
#[derive(Clone)]
struct FlattenedRow {
    /// 稳定身份：`path:line`。
    id: String,
    /// 工作区相对路径。
    path: String,
    /// 1-based 行号。
    line: u32,
}

/// 工作区搜索面板。
pub struct SearchPanel {
    client: CoreClient,
    /// 空路径表示“还没有打开项目”，与 `ProjectTree` 的约定一致。
    root: Option<PathBuf>,
    /// `InputState::new` 需要 `Window`，因此首帧渲染时才创建。
    input: Option<Entity<InputState>>,
    /// 替换输入框同样在首帧渲染时创建。
    replace_input: Option<Entity<InputState>>,
    /// include / exclude 输入框同样在首帧渲染时创建。
    include_input: Option<Entity<InputState>>,
    exclude_input: Option<Entity<InputState>>,
    /// 输入事件订阅必须和面板实体同生命周期。
    _input_subscriptions: Vec<Subscription>,
    /// 最近一次输入框里的文本；切换根目录后用它重新搜索。
    query: String,
    /// 替换文本；仅在详情展开时使用。
    replacement: String,
    /// include 过滤表达式（逗号/换行分隔的 glob）。
    include: String,
    /// exclude 过滤表达式（逗号/换行分隔的 glob）。
    exclude: String,
    /// 是否展开 include / exclude 路径过滤。
    details_visible: bool,
    /// 当前是查找模式还是替换模式。
    mode: SearchMode,
    /// 匹配选项。
    options: SearchOptions,
    /// 按文件分组的结果，保持 Core 返回的顺序。
    results: Vec<SearchFileGroup>,
    /// 扁平化的匹配行，供键盘导航。
    rows: Vec<FlattenedRow>,
    /// 当前结果的总匹配数。
    total_matches: usize,
    /// Core 是否报告还有更多结果（结果数达到本次上限）。
    has_more: bool,
    /// 本次查询使用的 `maxResults`。
    max_results: usize,
    /// 键盘选中的行下标。
    selected_index: usize,
    status: SearchStatus,
    /// 可见错误文案；不 panic，也不会清空搜索框。
    error: Option<SharedString>,
    /// 最近一次操作的结果提示（例如为什么不能替换全部）。
    notice: Option<SharedString>,
    /// 最近一次替换的统计；查询或模式变化时清空。
    replace_outcome: Option<ReplaceOutcome>,
    /// 递增后丢弃过期的去抖与 Core 结果。
    generation: u64,
    /// 是否有替换操作正在进行，防止重复点击。
    replacing: bool,
    /// 结果区焦点，用于键盘上下选择与 Enter 打开。
    result_focus: FocusHandle,
    /// 点击结果时回调，参数是绝对路径与 1-based 行号。
    on_open_location: Option<OpenLocationHandler>,
}

impl SearchPanel {
    pub fn new(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self {
        // 构造期只记录状态，不创建输入框、不 spawn。真正的初始化在首帧
        // `Render` 里通过 `ensure_inputs` 完成。
        Self {
            client,
            root: if root.as_os_str().is_empty() {
                None
            } else {
                Some(root)
            },
            input: None,
            replace_input: None,
            include_input: None,
            exclude_input: None,
            _input_subscriptions: Vec::new(),
            query: String::new(),
            replacement: String::new(),
            include: String::new(),
            exclude: String::new(),
            details_visible: false,
            mode: SearchMode::Find,
            options: SearchOptions::default(),
            results: Vec::new(),
            rows: Vec::new(),
            total_matches: 0,
            has_more: false,
            max_results: SEARCH_MAX_RESULTS,
            selected_index: 0,
            status: SearchStatus::Idle,
            error: None,
            notice: None,
            replace_outcome: None,
            generation: 0,
            replacing: false,
            result_focus: cx.focus_handle(),
            on_open_location: None,
        }
    }

    /// 切换工作区根目录。已有查询会排到当前借用释放之后重新执行。
    pub fn set_root(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        self.root = if root.as_os_str().is_empty() {
            None
        } else {
            Some(root)
        };
        // 让所有在途的去抖与 Core 请求失效。
        self.generation = self.generation.wrapping_add(1);
        self.clear_results();
        self.notice = None;
        self.replace_outcome = None;

        let query = self.query.trim().to_string();
        if query.is_empty() {
            self.status = SearchStatus::Idle;
            cx.notify();
            return;
        }

        if self.root.is_none() {
            self.status = SearchStatus::Error;
            self.error = Some(SharedString::from(tr("Open a project first")));
            cx.notify();
            return;
        }

        let generation = self.generation;
        self.status = SearchStatus::Searching;
        // 根目录切换可能发生在其他实体的更新回调里，`defer_in` 保证新的
        // 搜索在本次 App 借用释放之后才发起。
        cx.defer_in(window, move |this, _window, cx| {
            if this.generation == generation {
                this.start_search(query, cx);
            }
        });
        cx.notify();
    }

    /// 聚焦搜索框。输入框尚未创建时先懒创建。
    pub fn focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let input = self.ensure_inputs(window, cx).0;
        // 焦点变更排到本帧之后，避免在布局/绘制借用内改焦点。
        cx.defer_in(window, move |_this, window, cx| {
            input.update(cx, |state, cx| state.focus(window, cx));
        });
        cx.notify();
    }

    /// 点击结果时回调；参数是绝对路径与 1-based 行号。
    pub fn on_open_location(
        &mut self,
        handler: impl Fn(PathBuf, u32, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_location = Some(Rc::new(handler));
    }

    /// 切到查找模式；「在文件中查找」入口调用它可回到原始行为。
    pub fn open_find(&mut self, cx: &mut Context<Self>) {
        self.set_mode(SearchMode::Find, cx);
    }

    /// 切到替换模式；「在文件中替换」入口调用它。
    ///
    /// 对齐 Tauri `replaceVisible`：进入替换模式时展开 include / exclude 详情，
    /// 但替换行本身由模式控制，收起详情不会隐藏替换能力。
    pub fn open_replace(&mut self, cx: &mut Context<Self>) {
        self.set_mode(SearchMode::Replace, cx);
        if !self.details_visible {
            self.details_visible = true;
            cx.notify();
        }
    }

    /// 切换查找 / 替换模式；集成方也可直接用于菜单或快捷键接线。
    pub fn set_mode(&mut self, mode: SearchMode, cx: &mut Context<Self>) {
        if self.mode == mode {
            return;
        }
        self.mode = mode;
        self.replace_outcome = None;
        cx.notify();
    }

    /// 当前模式，供集成方判断菜单项状态。
    pub fn mode(&self) -> SearchMode {
        self.mode
    }

    /// 确保四个输入框已经创建，并且只订阅一次输入事件。
    ///
    /// 返回（搜索框，替换框，include 框，exclude 框）。
    fn ensure_inputs(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (
        Entity<InputState>,
        Entity<InputState>,
        Entity<InputState>,
        Entity<InputState>,
    ) {
        if let (Some(input), Some(replace), Some(include), Some(exclude)) = (
            self.input.clone(),
            self.replace_input.clone(),
            self.include_input.clone(),
            self.exclude_input.clone(),
        ) {
            return (input, replace, include, exclude);
        }

        let input =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("Search the workspace")));
        let replace = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Replace with...")));
        let include = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Files to include")));
        let exclude = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Files to exclude")));

        let query_subscription = cx.subscribe_in(&input, window, {
            let input = input.clone();
            move |this, _input, event: &InputEvent, _window, cx| match event {
                InputEvent::Change => {
                    let query = input.read(cx).value().to_string();
                    this.on_query_changed(query, cx);
                }
                InputEvent::PressEnter { .. } => {
                    // Enter 立即搜索，并让仍在等待的去抖任务因 generation
                    // 变化而失效。
                    let query = input.read(cx).value().to_string();
                    this.run_query(query, cx);
                }
                InputEvent::Focus | InputEvent::Blur => {}
            }
        });

        let replace_subscription = cx.subscribe_in(&replace, window, {
            let replace = replace.clone();
            move |this, _replace, event: &InputEvent, _window, cx| match event {
                InputEvent::Change => {
                    this.replacement = replace.read(cx).value().to_string();
                    // 替换文本变了，上一次的统计不再代表当前输入。
                    this.replace_outcome = None;
                }
                // 对齐 Tauri：替换框回车执行「替换」当前选中项。
                InputEvent::PressEnter { .. } => this.replace_current(cx),
                InputEvent::Focus | InputEvent::Blur => {}
            }
        });

        let include_subscription = cx.subscribe_in(&include, window, {
            let include = include.clone();
            move |this, _include, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.include = include.read(cx).value().to_string();
                    this.on_filters_changed(cx);
                }
            }
        });

        let exclude_subscription = cx.subscribe_in(&exclude, window, {
            let exclude = exclude.clone();
            move |this, _exclude, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.exclude = exclude.read(cx).value().to_string();
                    this.on_filters_changed(cx);
                }
            }
        });

        self.input = Some(input.clone());
        self.replace_input = Some(replace.clone());
        self.include_input = Some(include.clone());
        self.exclude_input = Some(exclude.clone());
        self._input_subscriptions = vec![
            query_subscription,
            replace_subscription,
            include_subscription,
            exclude_subscription,
        ];
        (input, replace, include, exclude)
    }

    /// 清空结果与派生状态，但保留查询文本与选项。
    fn clear_results(&mut self) {
        self.results.clear();
        self.rows.clear();
        self.total_matches = 0;
        self.has_more = false;
        self.selected_index = 0;
        self.error = None;
    }

    /// 输入变化：空查询直接回到 Idle，其余情况启动去抖。
    fn on_query_changed(&mut self, query: String, cx: &mut Context<Self>) {
        self.query = query;
        self.replace_outcome = None;
        self.generation = self.generation.wrapping_add(1);
        self.max_results = SEARCH_MAX_RESULTS;
        let generation = self.generation;
        let query = self.query.trim().to_string();

        if query.is_empty() {
            self.clear_results();
            self.notice = None;
            self.status = SearchStatus::Idle;
            cx.notify();
            return;
        }

        self.clear_results();
        self.notice = None;
        self.status = SearchStatus::Searching;

        cx.spawn(async move |this, cx| {
            // 计时器跑在后台执行器上，不占用 UI 线程。
            cx.background_executor().timer(SEARCH_DEBOUNCE).await;
            let _ = this.update(cx, |this, cx| {
                // 用户又输入了、切换了根目录或按了 Enter 时丢弃本次。
                if this.generation == generation {
                    this.start_search(query, cx);
                }
            });
        })
        .detach();

        cx.notify();
    }

    /// include / exclude 变化：立刻按新过滤条件重查。
    ///
    /// Core 没有路径 glob，过滤发生在结果侧，因此必须重新查询才能把之前被
    /// 过滤掉的结果补回来。
    fn on_filters_changed(&mut self, cx: &mut Context<Self>) {
        self.replace_outcome = None;
        self.generation = self.generation.wrapping_add(1);
        self.max_results = SEARCH_MAX_RESULTS;
        let generation = self.generation;
        let query = self.query.trim().to_string();

        if query.is_empty() {
            self.status = SearchStatus::Idle;
            cx.notify();
            return;
        }

        self.start_search(query, cx);
        // `start_search` 已经把 generation 记在任务里；这里再触发一次重绘。
        let _ = generation;
        cx.notify();
    }

    /// 切换一个匹配选项并立即重查。
    fn toggle_option(&mut self, option: SearchOption, cx: &mut Context<Self>) {
        self.replace_outcome = None;
        match option {
            SearchOption::CaseSensitive => {
                self.options.case_sensitive = !self.options.case_sensitive;
            }
            SearchOption::WholeWords => self.options.whole_words = !self.options.whole_words,
            SearchOption::RegularExpression => {
                self.options.regular_expression = !self.options.regular_expression;
            }
        }
        self.generation = self.generation.wrapping_add(1);
        self.max_results = SEARCH_MAX_RESULTS;

        let query = self.query.trim().to_string();
        if query.is_empty() {
            cx.notify();
            return;
        }
        self.start_search(query, cx);
        cx.notify();
    }

    /// 立即执行一次查询（Enter、搜索按钮）。
    fn run_query(&mut self, query: String, cx: &mut Context<Self>) {
        self.query = query;
        self.replace_outcome = None;
        self.generation = self.generation.wrapping_add(1);
        self.max_results = SEARCH_MAX_RESULTS;
        let query = self.query.trim().to_string();

        if query.is_empty() {
            self.clear_results();
            self.notice = None;
            self.status = SearchStatus::Idle;
            cx.notify();
            return;
        }

        self.start_search(query, cx);
        cx.notify();
    }

    /// 把查询派发到后台。调用方负责已经递增 `generation`。
    fn start_search(&mut self, query: String, cx: &mut Context<Self>) {
        self.clear_results();
        self.status = SearchStatus::Searching;

        let Some(root) = self.root.clone() else {
            self.status = SearchStatus::Error;
            self.error = Some(SharedString::from(tr("Open a project first")));
            cx.notify();
            return;
        };
        // Core 的请求模型使用 UTF-8 字符串；无法无损表示的路径直接报错。
        let Some(root_string) = root.to_str().map(str::to_string) else {
            self.status = SearchStatus::Error;
            self.error = Some(SharedString::from(tr("Workspace path is not valid UTF-8")));
            cx.notify();
            return;
        };

        let generation = self.generation;
        let client = self.client;
        let options = self.options;
        let max_results = self.max_results;
        let include_filters = parse_path_filters(&self.include);
        let exclude_filters = parse_path_filters(&self.exclude);

        cx.spawn(async move |this, cx| {
            let payload = json!({
                "root": root_string,
                "query": query,
                "caseSensitive": options.case_sensitive,
                "wholeWords": options.whole_words,
                "regularExpression": options.regular_expression,
                "maxResults": max_results,
                // 只有内容命中，避免把文件名命中混进「在文件中查找」。
                "maxFileResults": 0,
                "fileMask": "",
            });
            let result = cx
                .background_spawn(async move { client.execute_raw("workspace.search", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    // 根目录已切换或用户已发起更新的查询。
                    return;
                }
                match result {
                    Ok(data) => {
                        let all_groups = parse_groups(&data);
                        // Core 先按文件枚举再截断，路径过滤只能发生在结果侧。
                        let groups = filter_groups(all_groups, &include_filters, &exclude_filters);
                        let empty = groups.is_empty();
                        this.total_matches = groups.iter().map(|group| group.matches.len()).sum();
                        this.rows = flatten_rows(&groups);
                        this.has_more = this.rows.len() >= this.max_results
                            || this.total_matches >= this.max_results;
                        this.results = groups;
                        this.selected_index = 0;
                        this.error = None;
                        this.status = if empty {
                            SearchStatus::NoResults
                        } else {
                            SearchStatus::Ready
                        };
                    }
                    Err(error) => {
                        this.clear_results();
                        this.error = Some(SharedString::from(error.to_string()));
                        this.status = SearchStatus::Error;
                    }
                }
                cx.notify();
            });
        })
        .detach();

        cx.notify();
    }

    /// 加载更多：放大 `maxResults` 重新查询。
    fn load_more(&mut self, cx: &mut Context<Self>) {
        if !self.has_more || self.status == SearchStatus::Searching {
            return;
        }
        let query = self.query.trim().to_string();
        if query.is_empty() {
            return;
        }
        self.max_results = (self.max_results + SEARCH_LOAD_MORE_STEP).min(10_000);
        self.generation = self.generation.wrapping_add(1);
        self.notice = None;
        self.replace_outcome = None;
        self.start_search(query, cx);
    }

    /// 选中上一行 / 下一行。
    fn move_selection(&mut self, delta: i64, cx: &mut Context<Self>) {
        if self.rows.is_empty() {
            return;
        }
        let last = self.rows.len() - 1;
        let next = (self.selected_index as i64 + delta).clamp(0, last as i64);
        let next = usize::try_from(next).unwrap_or(0);
        if next != self.selected_index {
            self.selected_index = next;
            cx.notify();
        }
    }

    /// 打开当前键盘选中的匹配。
    fn open_selected(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(row) = self.rows.get(self.selected_index).cloned() else {
            return;
        };
        self.open_location(row.path, row.line, window, cx);
    }

    /// 把工作区相对路径与行号交给上层打开。
    fn open_location(
        &mut self,
        relative: String,
        line: u32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.as_ref() else {
            return;
        };
        let absolute = root.join(&relative);
        if let Some(handler) = self.on_open_location.as_ref() {
            handler(absolute, line.max(1), window, cx);
        }
    }

    /// 替换当前选中的匹配。
    ///
    /// 走 Core 的 `workspace.replacePreview` 计算替换后的全文，再用 `file.write`
    /// 写回，因此匹配语义（整词、正则捕获组、转义）与搜索完全一致。
    fn replace_current(&mut self, cx: &mut Context<Self>) {
        if self.replacing {
            return;
        }
        let Some(row) = self.rows.get(self.selected_index).cloned() else {
            return;
        };
        self.run_replace(vec![row.path.clone()], Some(row.line), cx);
    }

    /// 替换全部结果。
    fn replace_all(&mut self, cx: &mut Context<Self>) {
        if self.replacing {
            return;
        }
        let paths: Vec<String> = self
            .results
            .iter()
            .map(|group| group.path.clone())
            .collect();
        if paths.is_empty() {
            return;
        }
        // 「全部」必须在结果完整时才允许，避免只替换了前 N 条却宣称全部。
        if self.has_more {
            self.notice = Some(SharedString::from(tr(
                "Load all search results before replacing all",
            )));
            cx.notify();
            return;
        }
        self.run_replace(paths, None, cx);
    }

    /// 共用的替换流程：预览 → 写回 → 重新搜索。
    fn run_replace(&mut self, paths: Vec<String>, only_line: Option<u32>, cx: &mut Context<Self>) {
        let query = self.query.trim().to_string();
        if query.is_empty() {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_string) = root.to_str().map(str::to_string) else {
            return;
        };

        let generation = self.generation;
        let client = self.client;
        let options = self.options;
        let replacement = self.replacement.clone();
        self.replacing = true;
        self.error = None;
        self.notice = None;
        self.replace_outcome = None;

        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    replace_paths(
                        client,
                        &root,
                        &root_string,
                        &query,
                        &replacement,
                        options,
                        &paths,
                        only_line,
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                this.replacing = false;
                if this.generation != generation {
                    return;
                }
                match result {
                    Ok(outcome) => {
                        // 成功 / 失败条数保留在面板里，由替换行下方的状态行展示；
                        // 不再用一句覆盖式文案，方便用户确认批量结果。
                        this.replace_outcome = Some(outcome);
                        // 写盘后重新搜索，让面板反映真实磁盘状态。
                        let query = this.query.trim().to_string();
                        if !query.is_empty() {
                            this.generation = this.generation.wrapping_add(1);
                            this.max_results = SEARCH_MAX_RESULTS;
                            this.start_search(query, cx);
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error));
                        this.status = SearchStatus::Error;
                    }
                }
                cx.notify();
            });
        })
        .detach();

        cx.notify();
    }

    /// 渲染搜索选项按钮。
    ///
    /// `Toggle` 自带选中态绘制与 `icon` 入口；这里只传图标名和当前状态，
    /// 不自行拼一套按钮外观。
    fn render_option(
        &self,
        id: &'static str,
        icon_name: IconName,
        tooltip: &'static str,
        active: bool,
        option: SearchOption,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Toggle::new(id)
            .ghost()
            .with_size(px(SEARCH_OPTION_BUTTON_SIZE))
            .checked(active)
            .tooltip(tooltip)
            .icon(Icon::new(icon_name).with_size(px(14.0)))
            .on_click(cx.listener(move |this, _checked: &bool, _window, cx| {
                this.toggle_option(option, cx);
            }))
            .into_any_element()
    }

    /// 渲染顶部：模式切换行 + 搜索行。
    fn render_header(
        &self,
        input: &Entity<InputState>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let searching = self.status == SearchStatus::Searching;
        // 计数用 shared 里带参数的整句词条（「{arg1} 个结果」），既避免
        // `tr("Results")` 命中测试运行器的「测试结果」，也不用自己拼接语序。
        let count_text = if self.query.trim().is_empty() {
            String::new()
        } else if searching {
            tr("Searching...").to_string()
        } else {
            let label = tr("{arg1} results").replace("{arg1}", &self.total_matches.to_string());
            if self.has_more {
                format!("{label}+")
            } else {
                label
            }
        };

        // 模式切换用 gpui-kit 的分段 TabBar，而不是自己画两个按钮：
        // `Find` 保持原始查找行为，`Replace` 才展开替换行。
        let mode_row = div()
            .w_full()
            .h(px(SEARCH_DETAIL_ROW_HEIGHT))
            .flex()
            .flex_row()
            .items_center()
            .justify_between()
            .child(
                TabBar::new("lithe-search:mode")
                    .segmented()
                    .with_size(Size::XSmall)
                    .child(Tab::new().label(tr("Find")))
                    .child(Tab::new().label(tr("Replace")))
                    .selected_index(if self.mode == SearchMode::Replace { 1 } else { 0 })
                    .on_click(cx.listener(|this, index: &usize, _window, cx| {
                        this.set_mode(
                            if *index == 0 {
                                SearchMode::Find
                            } else {
                                SearchMode::Replace
                            },
                            cx,
                        );
                    })),
            )
            .when(!count_text.is_empty(), |this| {
                this.child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(count_text),
                )
            });

        let search_row = div()
            .w_full()
            .h(px(SEARCH_HEADER_HEIGHT))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.0))
            // 在捕获阶段接管 ↑/↓：`InputState` 把方向键绑给了光标移动，冒泡阶段
            // 拿不到。Tauri 的搜索框里方向键就是切换结果，这里保持一致。
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                match event.keystroke.key.as_str() {
                    "up" => {
                        this.move_selection(-1, cx);
                        cx.stop_propagation();
                    }
                    "down" => {
                        this.move_selection(1, cx);
                        cx.stop_propagation();
                    }
                    _ => {}
                }
            }))
            // 折叠按钮在搜索框**前面**（对齐 Tauri `SearchReplaceToggle`）。
            // Tauri 用同一个 ChevronRight 旋转 90°；这里直接换等效图标，
            // 避免依赖 Transformation 的矩阵 API。
            .child(
                Button::new("lithe-search:details")
                    .ghost()
                    .with_size(px(SEARCH_OPTION_BUTTON_SIZE))
                    .icon(if self.details_visible {
                        IconName::ChevronDown
                    } else {
                        IconName::ChevronRight
                    })
                    .tooltip(if self.details_visible {
                        tr("Hide details")
                    } else {
                        tr("Show details")
                    })
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.details_visible = !this.details_visible;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .child(Input::new(input).w_full().cleanable(true)),
            )
            .child(self.render_option(
                "lithe-search:option-case",
                IconName::CaseSensitive,
                tr("Match case"),
                self.options.case_sensitive,
                SearchOption::CaseSensitive,
                cx,
            ))
            .child(self.render_option(
                "lithe-search:option-whole",
                IconName::WholeWord,
                tr("Match whole word"),
                self.options.whole_words,
                SearchOption::WholeWords,
                cx,
            ))
            .child(self.render_option(
                "lithe-search:option-regex",
                IconName::Regex,
                tr("Use regular expression"),
                self.options.regular_expression,
                SearchOption::RegularExpression,
                cx,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .child(mode_row)
            .child(search_row)
            .into_any_element()
    }

    /// 渲染替换行：替换输入框、单条替换 / 全部替换，以及结果统计。
    ///
    /// 替换行只在 `Replace` 模式出现；`Find` 模式回到 Tauri「Global Search」
    /// 的原始查找界面。
    fn render_replace(
        &self,
        replace_input: &Entity<InputState>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let can_replace = !self.rows.is_empty() && !self.replacing;
        let can_replace_all = can_replace && !self.has_more;

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .pt(px(4.0))
            .child(
                div()
                    .w_full()
                    .h(px(SEARCH_DETAIL_ROW_HEIGHT))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(4.0))
                    .child(
                        Icon::new(IconName::Replace)
                            .with_size(px(14.0))
                            .text_color(tokens.tertiary_text),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .child(Input::new(replace_input).w_full().cleanable(true)),
                    )
                    .child(
                        Button::new("lithe-search:replace")
                            .label(tr("Replace"))
                            .compact()
                            .disabled(!can_replace)
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.replace_current(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-search:replace-all")
                            .label(tr("Replace all"))
                            .compact()
                            .disabled(!can_replace_all)
                            // 对齐 Tauri：结果不完整时按钮禁用，并用提示说明原因。
                            .tooltip(if can_replace_all {
                                tr("Replace all")
                            } else {
                                tr("Load all search results before replacing all")
                            })
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.replace_all(cx);
                            })),
                    ),
            )
            .when_some(self.render_replace_status(tokens), |this, status| {
                this.child(status)
            })
            .into_any_element()
    }

    /// 一次替换后的成功 / 失败条数；没有变化时返回 `None`。
    fn render_replace_status(&self, tokens: LitheTokens) -> Option<AnyElement> {
        let outcome = self.replace_outcome?;
        if outcome.matches == 0 && outcome.failed == 0 {
            return None;
        }

        let mut row = div()
            .w_full()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.0))
            .text_size(px(LitheMetrics::SMALL_FONT_SIZE));
        if outcome.matches > 0 {
            row = row.child(
                div().text_color(tokens.secondary_text).child(SharedString::from(
                    tr("Replaced {count} matches")
                        .replace("{count}", &outcome.matches.to_string()),
                )),
            );
        }
        if outcome.failed > 0 {
            row = row.child(
                div().text_color(tokens.error).child(SharedString::from(
                    tr("Failed: {count}").replace("{count}", &outcome.failed.to_string()),
                )),
            );
        }
        Some(row.into_any_element())
    }

    /// 渲染 include / exclude 过滤行。
    fn render_filters(
        &self,
        include_input: &Entity<InputState>,
        exclude_input: &Entity<InputState>,
    ) -> AnyElement {
        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .pt(px(4.0))
            .child(
                div()
                    .w_full()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(4.0))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .child(Input::new(include_input).w_full().cleanable(true)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .child(Input::new(exclude_input).w_full().cleanable(true)),
                    ),
            )
            .into_any_element()
    }

    /// 渲染一个文件分组：文件名 + 路径标题，下面是匹配行。
    fn render_group(
        &self,
        group: &SearchFileGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut rows = div().w_full().flex().flex_col();

        for item in &group.matches {
            let path = group.path.clone();
            let line = item.line;
            let row_id = format!("{}:{}", group.path, line);
            // 扁平行下标用于选中态；同一 path+line 在 flatten_rows 里是唯一的。
            let index = self.rows.iter().position(|row| row.id == row_id);
            let selected = index == Some(self.selected_index) && !self.rows.is_empty();

            rows = rows.child(
                div()
                    .id(format!("lithe-search:match:{row_id}"))
                    .w_full()
                    .h(px(SEARCH_MATCH_ROW_HEIGHT))
                    .flex_shrink_0()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.0))
                    .pl(px(SEARCH_RESULT_INDENT))
                    .pr(px(SEARCH_HORIZONTAL_PADDING))
                    .when(selected, |this| this.bg(tokens.subtle_selection))
                    .hover(|style| style.bg(tokens.hover))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        // 点击同时成为替换目标；否则「替换」只会作用在键盘选中行。
                        if let Some(index) = index {
                            this.selected_index = index;
                        }
                        this.open_location(path.clone(), line, window, cx);
                    }))
                    .child(
                        div()
                            .w(px(SEARCH_LINE_NUMBER_WIDTH))
                            .flex_shrink_0()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(format!("{line}")),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(item.preview.clone()),
                    ),
            );
        }

        div()
            .w_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .w_full()
                    .h(px(SEARCH_GROUP_HEADER_HEIGHT))
                    .flex_shrink_0()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(6.0))
                    .px(px(SEARCH_HORIZONTAL_PADDING))
                    .child(
                        icon(LitheIcon::File)
                            .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .max_w(px(260.0))
                            .flex_shrink_0()
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(group.name.clone()),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(group.directory.clone()),
                    )
                    // 对齐 Tauri：文件头右侧显示该文件的命中数，纯数字不需要翻译。
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(group.matches.len().to_string()),
                    ),
            )
            .child(rows)
            .into_any_element()
    }
}

/// 搜索选项种类，用于按钮回调。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SearchOption {
    CaseSensitive,
    WholeWords,
    RegularExpression,
}

impl Render for SearchPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        // 首帧懒创建输入框；这里不 spawn，只构建实体与订阅。
        let (input, replace_input, include_input, exclude_input) = self.ensure_inputs(window, cx);

        let mut header = div()
            .w_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .px(px(SEARCH_HORIZONTAL_PADDING))
            // 搜索工具窗没有标题栏，顶部间距由面板自己给。
            .pt(px(SEARCH_HORIZONTAL_PADDING / 2.0))
            .bg(tokens.tool_header)
            .child(self.render_header(&input, tokens, cx));

        // 替换行由模式控制，收起详情只隐藏 include / exclude，不隐藏替换能力。
        if self.mode == SearchMode::Replace {
            header = header.child(self.render_replace(&replace_input, tokens, cx));
        }
        header = header.child(
            Collapsible::new()
                .open(self.details_visible)
                .content(self.render_filters(&include_input, &exclude_input)),
        );
        // 操作提示不受详情折叠影响，例如「替换全部前需加载全部结果」。
        if let Some(notice) = self.notice.clone() {
            header = header.child(
                div()
                    .w_full()
                    .truncate()
                    .pt(px(2.0))
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(notice),
            );
        }

        let body: AnyElement = match self.status {
            SearchStatus::Ready => {
                let mut list = div().w_full().flex().flex_col();
                for group in &self.results {
                    list = list.child(self.render_group(group, tokens, cx));
                }
                // 还有更多时在底部给一个显式入口；滚动加载留到有真实 offset
                // 分页时再做，避免用重复请求模拟。
                if self.has_more {
                    list = list.child(
                        div()
                            .id("lithe-search:load-more")
                            .w_full()
                            .h(px(SEARCH_MATCH_ROW_HEIGHT + 6.0))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.link)
                            .cursor_pointer()
                            .hover(|style| style.bg(tokens.hover))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.load_more(cx);
                            }))
                            .child(tr("Load more")),
                    );
                }
                div()
                    .id("lithe-search:results")
                    .w_full()
                    .flex_1()
                    .min_h(px(0.0))
                    .overflow_y_scroll()
                    .track_focus(&self.result_focus)
                    .key_context(SEARCH_CONTEXT)
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        match event.keystroke.key.as_str() {
                            "up" => {
                                this.move_selection(-1, cx);
                                cx.stop_propagation();
                            }
                            "down" => {
                                this.move_selection(1, cx);
                                cx.stop_propagation();
                            }
                            "enter" => {
                                this.open_selected(window, cx);
                                cx.stop_propagation();
                            }
                            _ => {}
                        }
                    }))
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        window.focus(&this.result_focus, cx);
                        cx.notify();
                    }))
                    .child(list)
                    .into_any_element()
            }
            SearchStatus::Idle => centered_status(
                SharedString::from(tr("Type to search the workspace")),
                tokens.secondary_text,
            ),
            SearchStatus::Searching => centered_status(
                SharedString::from(tr("Searching...")),
                tokens.secondary_text,
            ),
            SearchStatus::NoResults => {
                centered_status(SharedString::from(tr("No results")), tokens.secondary_text)
            }
            SearchStatus::Error => centered_status(
                self.error
                    .clone()
                    .unwrap_or_else(|| SharedString::from(tr("Search failed"))),
                tokens.error,
            ),
        };

        div()
            .id("lithe-search-panel")
            .size_full()
            .flex()
            .flex_col()
            .bg(tokens.sidebar)
            .text_color(tokens.primary_text)
            .child(header)
            .child(body)
    }
}

/// 结果区键盘上下选择所用的焦点上下文名。
const SEARCH_CONTEXT: &str = "LitheSearchResults";

/// 居中的状态文案，用于未输入、搜索中、无结果与错误。
fn centered_status(text: SharedString, color: Hsla) -> AnyElement {
    div()
        .w_full()
        .flex_1()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .px(px(12.0))
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(color)
        .child(text)
        .into_any_element()
}

/// 把 `workspace.search` 的 `data` 解析成按文件分组的模型。
///
/// Core 响应形如 `{ "matches": [{ "kind", "path", "line", "preview", ... }] }`。
/// 这里只读取面板需要的字段；未知字段（符号名、匹配区间、ignored 状态）忽略。
/// 同一个文件内相同行号只保留一条，保证 `path+line` 的 ElementId 唯一。
fn parse_groups(data: &Value) -> Vec<SearchFileGroup> {
    let Some(matches) = data.get("matches").and_then(Value::as_array) else {
        return Vec::new();
    };

    let mut groups: Vec<SearchFileGroup> = Vec::new();
    let mut group_index: HashMap<String, usize> = HashMap::new();

    for item in matches {
        // 只要内容命中；文件名命中会让「在文件中查找」出现无行号的行。
        let kind = item
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("content");
        if kind != "content" {
            continue;
        }
        let Some(path) = item.get("path").and_then(Value::as_str) else {
            continue;
        };
        if path.is_empty() {
            continue;
        }

        // 内容命中一定有行号；缺失时按第 1 行处理，点击仍可打开文件。
        let line = item
            .get("line")
            .and_then(Value::as_u64)
            .map(|line| line.clamp(1, u32::MAX as u64) as u32)
            .unwrap_or(1);
        let preview = item
            .get("preview")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        let preview = if preview.is_empty() {
            path.to_string()
        } else {
            preview
        };

        let index = match group_index.get(path) {
            Some(index) => *index,
            None => {
                let (directory, name) = split_path(path);
                let index = groups.len();
                groups.push(SearchFileGroup {
                    path: path.to_string(),
                    name,
                    directory,
                    matches: Vec::new(),
                });
                group_index.insert(path.to_string(), index);
                index
            }
        };

        let group = &mut groups[index];
        if group.matches.iter().any(|existing| existing.line == line) {
            continue;
        }
        group.matches.push(SearchLine {
            line,
            preview: SharedString::from(preview),
        });
    }

    groups
}

/// 把分组结果展开成键盘导航用的扁平行。
fn flatten_rows(groups: &[SearchFileGroup]) -> Vec<FlattenedRow> {
    let mut rows = Vec::new();
    for group in groups {
        for item in &group.matches {
            rows.push(FlattenedRow {
                id: format!("{}:{}", group.path, item.line),
                path: group.path.clone(),
                line: item.line,
            });
        }
    }
    rows
}

/// 拆分工作区相对路径；目录部分对根目录文件为空字符串。
fn split_path(path: &str) -> (String, String) {
    match path.rsplit_once('/') {
        Some((directory, name)) if !name.is_empty() => (directory.to_string(), name.to_string()),
        _ => (String::new(), path.to_string()),
    }
}

