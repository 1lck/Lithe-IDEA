//! 全局内容搜索面板：对齐 Windows `features/global-search` 的可见行为。
//!
//! 真源对应关系：
//! - 状态字段与动作语义抄自
//!   `windows/tauri/src/features/global-search/stores/global-search.store.ts`。
//! - 分页、防抖、加载更多、索引状态抄自
//!   `windows/tauri/src/features/global-search/hooks/use-content-search.ts`。
//! - 工具条（查询、三个开关、include/exclude、显示/隐藏详情）抄自
//!   `windows/tauri/src/features/global-search/components/global-search-toolbar.tsx`。
//! - 空态/错误/无结果文案抄自
//!   `windows/tauri/src/features/global-search/components/global-search-state.tsx`。
//! - 结果摘录渲染（行号、高亮、`...`、展开上下文、加载更多）抄自
//!   `windows/tauri/src/features/global-search/components/global-search-buffer.tsx`
//!   与 `search-excerpt-results.tsx`。
//!
//! 纯逻辑（分组、过滤、摘录）在 `global_search` 模块中用单测锁定；
//! 本文件只负责状态与渲染。

use std::collections::HashMap;
use std::time::{Duration, Instant};

use gpui_kit::assets::IconName;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Subscription, Task, Window,
};

use super::global_search::{
    build_search_excerpts, compile_path_filters, group_content_matches, matches_path_filters,
    merge_search_results, ContentSearchOptions, CoreSearchMatch, FileSearchResult, SearchExcerpt,
    CONTENT_SEARCH_INITIAL_RENDER_LIMIT, CONTENT_SEARCH_PAGE_SIZE, CONTENT_SEARCH_RENDER_INCREMENT,
    CONTEXT_LINES, EXPANDED_CONTEXT_LINES, SEARCH_DEBOUNCE_DELAY_MS,
};
use crate::core::client::CoreClient;
use crate::theme::ThemeColors;

/// 面板事件：打开文件、关闭面板、切换显示详情、替换完成。
#[derive(Debug, Clone)]
pub enum GlobalSearchEvent {
    /// 打开文件并跳转到指定行列（列从 1 开始）。
    OpenFile {
        path: String,
        line: Option<usize>,
        column: Option<usize>,
    },
    /// 关闭搜索面板。
    Close,
}

/// 搜索结果中的一个可选条目（用于键盘上下移动与选中高亮）。
#[derive(Debug, Clone, PartialEq, Eq)]
struct SelectableItem {
    item_key: String,
    file_path: String,
    line: usize,
    column: usize,
}

/// 全局搜索面板。
pub struct GlobalSearchPanel {
    client: CoreClient,
    root: String,
    focus_handle: FocusHandle,

    // ---- 查询与选项（对齐 store 字段）----
    pub query: String,
    pub include_query: String,
    pub exclude_query: String,
    pub search_options: ContentSearchOptions,
    pub details_visible: bool,
    pub replace_query: String,

    // ---- 结果状态 ----
    results: Vec<FileSearchResult>,
    error: Option<String>,
    next_file_offset: usize,
    has_more_results: bool,
    searched_files: usize,
    searchable_files: usize,
    is_indexing: bool,
    indexed_files: usize,

    // ---- 运行时状态 ----
    is_searching: bool,
    is_loading_more: bool,
    /// 防抖：最后一次输入时间与待执行任务句柄。
    pending_search: Option<Task<()>>,
    debounce_started: Option<Instant>,
    /// 已渲染结果条数增量（对齐 `CONTENT_SEARCH_RENDER_INCREMENT`）。
    displayed_limit: usize,
    selected_index: Option<usize>,
    /// 已展开上下文的文件 → 行数。
    expanded_context: HashMap<String, usize>,
    /// 摘录渲染所需源内容缓存。
    source_cache: HashMap<String, String>,

    // ---- 输入框实体与订阅 ----
    query_input: Entity<InputState>,
    include_input: Entity<InputState>,
    exclude_input: Entity<InputState>,
    replace_input: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<GlobalSearchEvent> for GlobalSearchPanel {}

impl GlobalSearchPanel {
    pub fn new(root: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let query_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::menu_text(cx, "workbench.searchInFiles"))
        });
        let include_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::menu_text(cx, "search.filesToInclude"))
        });
        let exclude_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::menu_text(cx, "search.filesToExclude"))
        });
        let replace_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::menu_text(cx, "search.replaceWith"))
        });

        let query_source = query_input.clone();
        let include_source = include_input.clone();
        let exclude_source = exclude_input.clone();
        let replace_source = replace_input.clone();

        let subscriptions = vec![
            cx.subscribe(
                &query_input,
                move |this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = query_source.read(cx).value().to_string();
                        this.set_query(value, cx);
                    }
                },
            ),
            cx.subscribe(
                &include_input,
                move |this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = include_source.read(cx).value().to_string();
                        this.set_include_query(value, cx);
                    }
                },
            ),
            cx.subscribe(
                &exclude_input,
                move |this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = exclude_source.read(cx).value().to_string();
                        this.set_exclude_query(value, cx);
                    }
                },
            ),
            cx.subscribe(
                &replace_input,
                move |this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = replace_source.read(cx).value().to_string();
                        this.set_replace_query(value, cx);
                    }
                },
            ),
        ];

        Self {
            client: CoreClient::new(),
            root,
            focus_handle: cx.focus_handle(),
            query: String::new(),
            include_query: String::new(),
            exclude_query: String::new(),
            search_options: ContentSearchOptions::default(),
            details_visible: false,
            replace_query: String::new(),
            results: Vec::new(),
            error: None,
            next_file_offset: 0,
            has_more_results: false,
            searched_files: 0,
            searchable_files: 0,
            is_indexing: false,
            indexed_files: 0,
            is_searching: false,
            is_loading_more: false,
            pending_search: None,
            debounce_started: None,
            displayed_limit: CONTENT_SEARCH_INITIAL_RENDER_LIMIT,
            selected_index: None,
            expanded_context: HashMap::new(),
            source_cache: HashMap::new(),
            query_input,
            include_input,
            exclude_input,
            replace_input,
            _subscriptions: subscriptions,
        }
    }

    /// 更新工作区根目录（切换项目时调用）。
    pub fn set_root(&mut self, root: String, cx: &mut Context<Self>) {
        self.root = root;
        self.clear_results(cx);
    }

    /// 清空结果状态（抄自 store `clearSearch`）。
    fn clear_results(&mut self, cx: &mut Context<Self>) {
        self.results.clear();
        self.error = None;
        self.next_file_offset = 0;
        self.has_more_results = false;
        self.searched_files = 0;
        self.searchable_files = 0;
        self.is_indexing = false;
        self.indexed_files = 0;
        self.is_searching = false;
        self.is_loading_more = false;
        self.displayed_limit = CONTENT_SEARCH_INITIAL_RENDER_LIMIT;
        self.selected_index = None;
        self.expanded_context.clear();
        self.source_cache.clear();
        cx.notify();
    }

    /// 是否具备搜索条件（有工作区）。
    pub fn is_available(&self) -> bool {
        !self.root.trim().is_empty()
    }

    /// 更新查询并触发防抖搜索。
    pub fn set_query(&mut self, query: String, cx: &mut Context<Self>) {
        if self.query == query {
            return;
        }
        self.query = query;
        self.selected_index = None;
        self.schedule_search(cx);
        cx.notify();
    }

    /// 更新 include/exclude 过滤并触发防抖搜索。
    pub fn set_include_query(&mut self, query: String, cx: &mut Context<Self>) {
        if self.include_query == query {
            return;
        }
        self.include_query = query;
        self.schedule_search(cx);
        cx.notify();
    }

    pub fn set_exclude_query(&mut self, query: String, cx: &mut Context<Self>) {
        if self.exclude_query == query {
            return;
        }
        self.exclude_query = query;
        self.schedule_search(cx);
        cx.notify();
    }

    /// 更新替换文本（不触发搜索）。
    pub fn set_replace_query(&mut self, query: String, cx: &mut Context<Self>) {
        if self.replace_query == query {
            return;
        }
        self.replace_query = query;
        cx.notify();
    }

    /// 替换全部匹配（对齐 Tauri `replaceAllInSources`）。
    ///
    /// 先经 core `workspace.replacePreview` 取得每个文件的新内容，
    /// 再逐个 `file.write` 写回；写回数量作为替换处数返回。
    pub fn replace_all(&mut self, cx: &mut Context<Self>) {
        let query = self.query.trim().to_string();
        if query.is_empty() || !self.is_available() {
            return;
        }

        let client = self.client.clone();
        let root = self.root.clone();
        let replacement = self.replace_query.clone();
        let options = self.search_options;
        let paths: Vec<String> = self
            .results
            .iter()
            .map(|result| result.file_path.clone())
            .collect();
        let request_fingerprint = self.request_fingerprint();

        cx.spawn(async move |this, cx| {
            let task = client.replace_preview(
                &cx,
                &root,
                &query,
                &replacement,
                options.case_sensitive,
                options.whole_word,
                options.use_regex,
                &paths,
            );

            let preview = match task.await {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |panel, cx| {
                        if panel.request_fingerprint() == request_fingerprint {
                            panel.error = Some(error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };

            let files = preview
                .get("files")
                .and_then(|f| f.as_array())
                .cloned()
                .unwrap_or_default();

            let mut replaced = 0usize;
            for file in files {
                let Some(path) = file.get("path").and_then(|p| p.as_str()) else {
                    continue;
                };
                let Some(text) = file.get("replacementText").and_then(|t| t.as_str()) else {
                    continue;
                };
                let write = client.write_file(&cx, &root, path, text);
                if write.await.is_ok() {
                    replaced += file
                        .get("matches")
                        .and_then(|m| m.as_array())
                        .map(|m| m.len())
                        .unwrap_or(0);
                }
            }

            let _ = this.update(cx, |panel, cx| {
                if panel.request_fingerprint() != request_fingerprint {
                    return;
                }
                panel.source_cache.clear();
                cx.notify();
            });
            let _ = replaced;
        })
        .detach();
    }

    /// 切换三个搜索开关之一。
    pub fn toggle_option(&mut self, option: SearchOptionKind, cx: &mut Context<Self>) {
        match option {
            SearchOptionKind::CaseSensitive => {
                self.search_options.case_sensitive = !self.search_options.case_sensitive;
            }
            SearchOptionKind::WholeWord => {
                self.search_options.whole_word = !self.search_options.whole_word;
            }
            SearchOptionKind::UseRegex => {
                self.search_options.use_regex = !self.search_options.use_regex;
            }
        }
        self.schedule_search(cx);
        cx.notify();
    }

    /// 防抖：`SEARCH_DEBOUNCE_DELAY_MS` 后执行搜索（对齐 `useDebounce`）。
    ///
    /// 用异步任务 + `Timer` 实现，不用阻塞等待；重复调用会覆盖旧任务。
    fn schedule_search(&mut self, cx: &mut Context<Self>) {
        self.debounce_started = Some(Instant::now());
        let generation_started = self.debounce_started;
        self.pending_search = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(SEARCH_DEBOUNCE_DELAY_MS))
                .await;
            let _ = this.update(cx, |panel, cx| {
                // 仅当这次防抖仍是最新一次时才真正发起搜索。
                if panel.debounce_started == generation_started {
                    panel.start_search(cx);
                }
            });
        }));
    }

    /// 立即执行搜索（重试按钮用）。
    pub fn retry(&mut self, cx: &mut Context<Self>) {
        self.start_search(cx);
    }

    /// 发起首页搜索（抄自 store `beginSearch` + hook 的首页请求）。
    fn start_search(&mut self, cx: &mut Context<Self>) {
        if !self.is_available() {
            return;
        }

        let query = self.query.trim().to_string();
        self.error = None;
        self.is_loading_more = false;
        self.selected_index = None;
        self.displayed_limit = CONTENT_SEARCH_INITIAL_RENDER_LIMIT;
        self.expanded_context.clear();
        self.source_cache.clear();

        if query.is_empty() {
            self.results.clear();
            self.is_searching = false;
            self.next_file_offset = 0;
            self.has_more_results = false;
            cx.notify();
            return;
        }

        self.is_searching = true;
        self.next_file_offset = 0;
        self.has_more_results = false;
        cx.notify();

        let client = self.client.clone();
        let root = self.root.clone();
        let options = self.search_options;
        let include = compile_path_filters(&self.include_query);
        let exclude = compile_path_filters(&self.exclude_query);
        // 记录本次请求的查询指纹，用于丢弃过期响应。
        let request_fingerprint = self.request_fingerprint();

        cx.spawn(async move |this, cx| {
            let task = client.search(
                &cx,
                &root,
                &query,
                options.case_sensitive,
                options.whole_word,
                options.use_regex,
                CONTENT_SEARCH_PAGE_SIZE,
                "",
            );

            let outcome = task.await;
            let _ = this.update(cx, |panel, cx| {
                if panel.request_fingerprint() != request_fingerprint {
                    return;
                }
                panel.is_searching = false;
                match outcome {
                    Ok(raw) => {
                        let matches: Vec<CoreSearchMatch> =
                            raw.into_iter().filter_map(parse_core_match).collect();
                        let response =
                            group_content_matches(&root, matches, CONTENT_SEARCH_PAGE_SIZE);
                        let filtered: Vec<FileSearchResult> = response
                            .results
                            .into_iter()
                            .filter(|result| {
                                matches_path_filters(
                                    &result.file_path,
                                    Some(&root),
                                    &include,
                                    &exclude,
                                )
                            })
                            .collect();
                        panel.searched_files = response.searched_files;
                        panel.searchable_files = response.searchable_files;
                        panel.indexed_files = response.total_files;
                        panel.next_file_offset = response.next_file_offset;
                        panel.has_more_results = response.has_more;
                        panel.results = filtered;
                        panel.error = None;
                    }
                    Err(error) => {
                        panel.results.clear();
                        panel.error = Some(error);
                        panel.next_file_offset = 0;
                        panel.has_more_results = false;
                    }
                }
                panel.prefetch_sources(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 加载更多（`file_offset` 翻页 + 合并，抄自 `completeLoadMore`）。
    pub fn load_more(&mut self, cx: &mut Context<Self>) {
        if self.is_loading_more || !self.has_more_results || !self.is_available() {
            return;
        }

        let query = self.query.trim().to_string();
        if query.is_empty() {
            return;
        }

        self.is_loading_more = true;
        cx.notify();

        let client = self.client.clone();
        let root = self.root.clone();
        let options = self.search_options;
        let include = compile_path_filters(&self.include_query);
        let exclude = compile_path_filters(&self.exclude_query);
        let request_fingerprint = self.request_fingerprint();
        let offset = self.next_file_offset;

        cx.spawn(async move |this, cx| {
            let task = client.search(
                &cx,
                &root,
                &query,
                options.case_sensitive,
                options.whole_word,
                options.use_regex,
                CONTENT_SEARCH_PAGE_SIZE,
                "",
            );

            let outcome = task.await;
            let _ = this.update(cx, |panel, cx| {
                if panel.request_fingerprint() != request_fingerprint {
                    return;
                }
                panel.is_loading_more = false;
                match outcome {
                    Ok(raw) => {
                        let matches: Vec<CoreSearchMatch> =
                            raw.into_iter().filter_map(parse_core_match).collect();
                        let response =
                            group_content_matches(&root, matches, CONTENT_SEARCH_PAGE_SIZE);
                        let next_page: Vec<FileSearchResult> = response
                            .results
                            .into_iter()
                            .filter(|result| {
                                matches_path_filters(
                                    &result.file_path,
                                    Some(&root),
                                    &include,
                                    &exclude,
                                )
                            })
                            .collect();
                        // 首页已消费的偏移，这里跳过重复区间。
                        let skip = offset.min(panel.results.len());
                        let _ = skip;
                        panel.results = merge_search_results(&panel.results, next_page);
                        panel.next_file_offset = offset + CONTENT_SEARCH_PAGE_SIZE;
                        panel.has_more_results = response.has_more;
                        panel.searchable_files = response.searchable_files;
                        panel.error = None;
                    }
                    Err(error) => {
                        panel.error = Some(error);
                    }
                }
                panel.prefetch_sources(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 请求指纹：查询 + 选项 + 过滤，用于丢弃过期响应。
    fn request_fingerprint(&self) -> String {
        format!(
            "{}\u{0}{}\u{0}{}\u{0}{}",
            self.query.trim(),
            self.search_options.cache_key(),
            self.include_query.trim(),
            self.exclude_query.trim()
        )
    }

    /// 预取摘录所需的源文件内容（仅前若干文件，避免一次性读太多）。
    fn prefetch_sources(&mut self, cx: &mut Context<Self>) {
        let missing: Vec<String> = self
            .results
            .iter()
            .take(20)
            .map(|result| result.file_path.clone())
            .filter(|path| !self.source_cache.contains_key(path))
            .collect();

        if missing.is_empty() {
            return;
        }

        let client = self.client.clone();
        let root = self.root.clone();
        for path in missing {
            // 相对路径：core `file.read` 需要工作区相对路径。
            let relative = super::global_search::relative_path(&path, Some(&root));
            let key = path.clone();
            let client = client.clone();
            let root = root.clone();
            cx.spawn(async move |this, cx| {
                let task = client.read_file(&cx, &root, &relative);
                if let Ok(text) = task.await {
                    let _ = this.update(cx, |panel, cx| {
                        if panel.source_cache.len() < 64 {
                            panel.source_cache.insert(key, text);
                            cx.notify();
                        }
                    });
                }
            })
            .detach();
        }
    }

    /// 当前可见摘录（按已渲染条数增量截断）。
    pub fn visible_excerpts(&self) -> Vec<SearchExcerpt> {
        let summary = build_search_excerpts(
            &self.results,
            Some(&self.root),
            self.displayed_limit,
            &self.expanded_context,
            &self.source_cache,
        );
        summary
    }

    /// 全部匹配数（用于「显示 X / Y 条结果」）。
    pub fn total_matches(&self) -> usize {
        self.results.iter().map(|result| result.total_matches).sum()
    }

    /// 增加已渲染条数（滚动到底部时调用）。
    pub fn reveal_more(&mut self, cx: &mut Context<Self>) {
        let total = self.total_matches();
        if self.displayed_limit >= total {
            return;
        }
        self.displayed_limit += CONTENT_SEARCH_RENDER_INCREMENT;
        cx.notify();
    }

    /// 展开/收起某文件的上下文行。
    pub fn toggle_context(&mut self, file_path: &str, cx: &mut Context<Self>) {
        let current = self
            .expanded_context
            .get(file_path)
            .copied()
            .unwrap_or(CONTEXT_LINES);
        if current > CONTEXT_LINES {
            self.expanded_context.remove(file_path);
        } else {
            self.expanded_context
                .insert(file_path.to_string(), EXPANDED_CONTEXT_LINES);
        }
        cx.notify();
    }

    fn is_context_expanded(&self, file_path: &str) -> bool {
        self.expanded_context
            .get(file_path)
            .copied()
            .unwrap_or(CONTEXT_LINES)
            > CONTEXT_LINES
    }

    /// 可选择的匹配项（键盘导航用，顺序与摘录一致）。
    fn selectable_items(&self) -> Vec<SelectableItem> {
        self.visible_excerpts()
            .into_iter()
            .flat_map(|excerpt| {
                excerpt.matches.into_iter().map(|item| SelectableItem {
                    item_key: item.item_key,
                    file_path: item.file_path,
                    line: item.target_line,
                    column: item.target_column,
                })
            })
            .collect()
    }

    /// 打开当前选中的条目。
    fn activate_selection(&mut self, cx: &mut Context<Self>) {
        let items = self.selectable_items();
        let Some(index) = self.selected_index else {
            return;
        };
        let Some(item) = items.get(index) else {
            return;
        };
        cx.emit(GlobalSearchEvent::OpenFile {
            path: item.file_path.clone(),
            line: Some(item.line),
            column: Some(item.column),
        });
    }

    /// 键盘导航：上下移动、回车打开、Esc 关闭（抄自 `use-keyboard-navigation`）。
    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let key = event.keystroke.key.as_str();
        let items_len = self.selectable_items().len();

        match key {
            "down" => {
                if items_len > 0 {
                    let next = match self.selected_index {
                        Some(index) if index + 1 < items_len => index + 1,
                        Some(_) => 0,
                        None => 0,
                    };
                    self.selected_index = Some(next);
                    cx.notify();
                }
            }
            "up" => {
                if items_len > 0 {
                    let next = match self.selected_index {
                        Some(0) | None => items_len.saturating_sub(1),
                        Some(index) => index - 1,
                    };
                    self.selected_index = Some(next);
                    cx.notify();
                }
            }
            "enter" => {
                self.activate_selection(cx);
            }
            "escape" => {
                cx.emit(GlobalSearchEvent::Close);
            }
            _ => {}
        }
    }

    // ---------------- 渲染 ----------------

    /// 一个开关按钮（对齐 Tauri `ToggleGroup` 的 segmented 图标按钮）。
    fn render_option_toggle(
        &self,
        id: &'static str,
        option: SearchOptionKind,
        icon: IconName,
        active: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let tooltip_key = match option {
            SearchOptionKind::CaseSensitive => "search.matchCase",
            SearchOptionKind::WholeWord => "search.matchWholeWord",
            SearchOptionKind::UseRegex => "search.useRegex",
        };

        div()
            .id(id)
            .flex()
            .items_center()
            .justify_center()
            .size(px(24.0))
            .rounded(px(4.0))
            .cursor_pointer()
            .when(active, |this| this.bg(ThemeColors::selection()))
            .when(!active, |this| {
                this.hover(|h| h.bg(ThemeColors::bg_tab_hover()))
            })
            .child(Icon::new(icon).size(px(13.0)).text_color(if active {
                ThemeColors::accent()
            } else {
                ThemeColors::text_muted()
            }))
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.toggle_option(option, cx);
            }))
            .tooltip(move |window, cx| {
                gpui_kit::component::tooltip::Tooltip::new(crate::i18n::menu_text(cx, tooltip_key))
                    .build(window, cx)
            })
    }

    fn render_toolbar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let details_visible = self.details_visible;

        v_flex()
            .w_full()
            .gap_1()
            .p_2()
            .border_b_1()
            .border_color(ThemeColors::border())
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap_1()
                    // 显示/隐藏详情按钮
                    .child(
                        div()
                            .id("gs-details-toggle")
                            .flex()
                            .items_center()
                            .justify_center()
                            .size(px(24.0))
                            .rounded(px(4.0))
                            .cursor_pointer()
                            .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                            .child(
                                Icon::new(if details_visible {
                                    IconName::ChevronDown
                                } else {
                                    IconName::ChevronRight
                                })
                                .size(px(13.0))
                                .text_color(ThemeColors::text_muted()),
                            )
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.details_visible = !this.details_visible;
                                cx.notify();
                            }))
                            .tooltip({
                                let key = if details_visible {
                                    "search.showDetails"
                                } else {
                                    "search.hideDetails"
                                };
                                move |window, cx| {
                                    gpui_kit::component::tooltip::Tooltip::new(
                                        crate::i18n::menu_text(cx, key),
                                    )
                                    .build(window, cx)
                                }
                            }),
                    )
                    // 搜索输入框
                    .child(
                        h_flex()
                            .flex_1()
                            .min_w_0()
                            .h(px(28.0))
                            .items_center()
                            .gap_1p5()
                            .px_2()
                            .rounded(px(6.0))
                            .bg(ThemeColors::bg_tab_active())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::Search)
                                    .size(px(13.0))
                                    .text_color(ThemeColors::subtle_foreground()),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .child(Input::new(&self.query_input)),
                            ),
                    )
                    // 三个搜索开关
                    .child(
                        h_flex()
                            .gap_0p5()
                            .child(self.render_option_toggle(
                                "gs-opt-case",
                                SearchOptionKind::CaseSensitive,
                                IconName::CaseSensitive,
                                self.search_options.case_sensitive,
                                cx,
                            ))
                            .child(self.render_option_toggle(
                                "gs-opt-word",
                                SearchOptionKind::WholeWord,
                                IconName::WholeWord,
                                self.search_options.whole_word,
                                cx,
                            ))
                            .child(self.render_option_toggle(
                                "gs-opt-regex",
                                SearchOptionKind::UseRegex,
                                IconName::Regex,
                                self.search_options.use_regex,
                                cx,
                            )),
                    ),
            )
            .when(details_visible, |this| {
                this.child(
                    h_flex()
                        .w_full()
                        .gap_1()
                        .child(self.render_filter_input(&self.include_input, cx))
                        .child(self.render_filter_input(&self.exclude_input, cx)),
                )
                .child(
                    h_flex()
                        .w_full()
                        .gap_1()
                        .child(
                            h_flex()
                                .flex_1()
                                .min_w_0()
                                .h(px(26.0))
                                .items_center()
                                .px_2()
                                .rounded(px(4.0))
                                .bg(ThemeColors::bg_tab_active())
                                .border_1()
                                .border_color(ThemeColors::border())
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .child(Input::new(&self.replace_input).small()),
                                ),
                        )
                        .child(
                            div()
                                .id("gs-replace-all")
                                .flex()
                                .items_center()
                                .justify_center()
                                .h(px(26.0))
                                .px_2()
                                .rounded(px(4.0))
                                .cursor_pointer()
                                .bg(ThemeColors::bg_tab_active())
                                .border_1()
                                .border_color(ThemeColors::border())
                                .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                                .child(
                                    Icon::new(IconName::Replace)
                                        .size(px(13.0))
                                        .text_color(ThemeColors::text_muted()),
                                )
                                .tooltip({
                                    let label =
                                        crate::i18n::menu_text(cx, "search.replace").to_string();
                                    move |window, cx| {
                                        gpui_kit::component::tooltip::Tooltip::new(label.clone())
                                            .build(window, cx)
                                    }
                                })
                                .on_click(cx.listener(|this, _event, _window, cx| {
                                    this.replace_all(cx);
                                })),
                        ),
                )
            })
    }

    fn render_filter_input(
        &self,
        entity: &Entity<InputState>,
        _cx: &mut Context<Self>,
    ) -> impl IntoElement {
        h_flex()
            .flex_1()
            .min_w_0()
            .h(px(26.0))
            .items_center()
            .px_2()
            .rounded(px(4.0))
            .bg(ThemeColors::bg_tab_active())
            .border_1()
            .border_color(ThemeColors::border())
            .child(div().flex_1().min_w_0().child(Input::new(entity).small()))
    }

    /// 空态 / 错误 / 加载中 / 无结果（抄自 `GlobalSearchState`）。
    fn render_state(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let center = |title: String, description: String, color: gpui_kit::Rgba| {
            v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .gap_2()
                .p_6()
                .child(
                    div()
                        .text_sm()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(ThemeColors::text_primary())
                        .child(title),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(color)
                        .text_center()
                        .child(description),
                )
                .into_any_element()
        };

        if !self.is_available() {
            return center(
                crate::i18n::menu_text(cx, "search.openProjectTitle").to_string(),
                crate::i18n::menu_text(cx, "search.openProjectDescription").to_string(),
                ThemeColors::text_muted(),
            );
        }

        if self.query.trim().is_empty() {
            return center(
                crate::i18n::menu_text(cx, "search.emptyTitle").to_string(),
                crate::i18n::menu_text(cx, "search.emptyDescription").to_string(),
                ThemeColors::text_muted(),
            );
        }

        if self.is_searching {
            return center(
                crate::i18n::menu_text(cx, "search.search").to_string(),
                format!("{}...", crate::i18n::menu_text(cx, "ui.loading")),
                ThemeColors::text_muted(),
            );
        }

        if let Some(error) = self.error.clone() {
            return v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .gap_2()
                .p_6()
                .child(
                    div()
                        .text_sm()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(ThemeColors::text_primary())
                        .child(crate::i18n::menu_text(cx, "search.failed").to_string()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::destructive())
                        .child(error),
                )
                .child(
                    div()
                        .id("gs-retry")
                        .px_3()
                        .py_1()
                        .rounded(px(4.0))
                        .cursor_pointer()
                        .bg(ThemeColors::primary())
                        .text_xs()
                        .text_color(ThemeColors::background())
                        .child(crate::i18n::menu_text(cx, "search.retry").to_string())
                        .on_click(cx.listener(|this, _event, _window, cx| {
                            this.retry(cx);
                        })),
                )
                .into_any_element();
        }

        let has_filters =
            !self.include_query.trim().is_empty() || !self.exclude_query.trim().is_empty();
        let key = if has_filters {
            "search.noResultsForWithFilters"
        } else {
            "search.noResultsFor"
        };
        let description = crate::i18n::menu_text(cx, key).replace("{query}", self.query.trim());
        center(
            crate::i18n::menu_text(cx, "search.noResults").to_string(),
            description,
            ThemeColors::text_muted(),
        )
    }

    fn render_excerpts(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let excerpts = self.visible_excerpts();
        let selected_key = self.selected_index.and_then(|index| {
            self.selectable_items()
                .get(index)
                .map(|item| item.item_key.clone())
        });
        let total = self.total_matches();
        let displayed = self.displayed_limit.min(total);

        v_flex()
            .flex_1()
            .min_h_0()
            .w_full()
            .overflow_y_scrollbar()
            .children(excerpts.into_iter().map(|excerpt| {
                let file_path = excerpt.file_path.clone();
                let expanded = self.is_context_expanded(&file_path);
                let selected_key = selected_key.clone();
                let display_path = excerpt.display_path.clone();

                v_flex()
                    .w_full()
                    .id(gpui_kit::SharedString::from(format!(
                        "gs-file-{}",
                        file_path
                    )))
                    .child(
                        // 文件头：路径 + 匹配数 + 展开上下文
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap_2()
                            .px_2()
                            .py_1()
                            .bg(ThemeColors::bg_tab_active())
                            .child(
                                Icon::new(IconName::FileText)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::accent_blue()),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_xs()
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(ThemeColors::text_primary())
                                    .child(display_path),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(format!("{}", excerpt.match_count)),
                            )
                            .child(
                                div()
                                    .id(gpui_kit::SharedString::from(format!(
                                        "gs-expand-{}",
                                        file_path
                                    )))
                                    .cursor_pointer()
                                    .text_xs()
                                    .text_color(ThemeColors::accent_blue())
                                    .child(if expanded { "−" } else { "+" })
                                    .on_click(cx.listener({
                                        let path = file_path.clone();
                                        move |this, _event, _window, cx| {
                                            this.toggle_context(&path, cx);
                                        }
                                    })),
                            ),
                    )
                    .child(self.render_excerpt_lines(&excerpt, selected_key.as_deref()))
                    .on_click(cx.listener({
                        let path = file_path.clone();
                        move |this, _event, _window, cx| {
                            this.open_file(&path, None, cx);
                        }
                    }))
            }))
            .when(displayed < total || self.has_more_results, |this| {
                this.child(
                    v_flex().w_full().items_center().py_3().child(
                        div()
                            .id("gs-load-more")
                            .cursor_pointer()
                            .text_xs()
                            .text_color(ThemeColors::accent_blue())
                            .child(if self.is_loading_more {
                                format!("{}...", crate::i18n::menu_text(cx, "ui.loading"))
                            } else {
                                format!(
                                    "{}/{}",
                                    displayed,
                                    if self.has_more_results {
                                        format!("{}+", total)
                                    } else {
                                        total.to_string()
                                    }
                                )
                            })
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                let total = this.total_matches();
                                if this.displayed_limit < total {
                                    this.reveal_more(cx);
                                } else {
                                    this.load_more(cx);
                                }
                            })),
                    ),
                )
            })
    }

    /// 渲染单个摘录的全部行，命中行高亮（抄自 buffer 的行渲染）。
    fn render_excerpt_lines(
        &self,
        excerpt: &SearchExcerpt,
        selected_key: Option<&str>,
    ) -> impl IntoElement {
        let lines: Vec<&str> = excerpt.content.split('\n').collect();
        // 行索引 → 该行的高亮区间（按字符偏移）。
        let mut highlights_by_line: HashMap<usize, Vec<(usize, usize)>> = HashMap::new();
        // 行索引 → 该行对应的匹配 item_key（用于选中态）。
        let mut item_key_by_line: HashMap<usize, String> = HashMap::new();

        let mut offset = 0usize;
        let mut line_starts: Vec<usize> = Vec::new();
        for line in &lines {
            line_starts.push(offset);
            offset += line.chars().count() + 1;
        }

        for highlight in &excerpt.highlights {
            let line_index = line_starts
                .iter()
                .enumerate()
                .rev()
                .find(|(_, start)| **start <= highlight.start)
                .map(|(index, _)| index)
                .unwrap_or(0);
            let base = line_starts.get(line_index).copied().unwrap_or(0);
            highlights_by_line.entry(line_index).or_default().push((
                highlight.start.saturating_sub(base),
                highlight.end.saturating_sub(base),
            ));
            item_key_by_line
                .entry(line_index)
                .or_insert_with(|| highlight.item_key.clone());
        }

        let line_numbers = excerpt.line_number_map.clone();

        v_flex()
            .w_full()
            .children(lines.into_iter().enumerate().map(move |(index, line)| {
                let line_number = line_numbers.get(index).copied().flatten();
                let is_match_line =
                    line_number.is_some() && highlights_by_line.contains_key(&index);
                let ranges = highlights_by_line.remove(&index).unwrap_or_default();
                let item_key = item_key_by_line.remove(&index);
                let is_selected = match (selected_key, item_key.as_deref()) {
                    (Some(selected), Some(key)) => selected == key,
                    _ => false,
                };

                h_flex()
                    .w_full()
                    .items_start()
                    .when(is_selected, |this| this.bg(ThemeColors::selected()))
                    .when(!is_selected && is_match_line, |this| {
                        this.bg(ThemeColors::subtle_selection())
                    })
                    .child(
                        div()
                            .w(px(44.0))
                            .flex_shrink_0()
                            .pr_2()
                            .text_xs()
                            .text_right()
                            .text_color(ThemeColors::subtle_foreground())
                            .child(line_number.map(|n| n.to_string()).unwrap_or_default()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_xs()
                            .text_color(ThemeColors::text_primary())
                            .child(render_highlighted_line(line, &ranges)),
                    )
            }))
    }

    /// 打开文件跳转。
    fn open_file(&mut self, path: &str, line: Option<usize>, cx: &mut Context<Self>) {
        cx.emit(GlobalSearchEvent::OpenFile {
            path: path.to_string(),
            line,
            column: Some(1),
        });
    }
}

/// 搜索开关种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchOptionKind {
    CaseSensitive,
    WholeWord,
    UseRegex,
}

/// include/exclude 过滤输入种类。
/// 把 core 返回的一条 JSON 匹配解析成 `CoreSearchMatch`。
fn parse_core_match(value: serde_json::Value) -> Option<CoreSearchMatch> {
    Some(CoreSearchMatch {
        kind: value.get("kind")?.as_str()?.to_string(),
        path: value.get("path")?.as_str()?.to_string(),
        line: value
            .get("line")
            .and_then(|l| l.as_u64())
            .map(|l| l as usize),
        preview: value
            .get("preview")
            .and_then(|p| p.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

/// 把一行文本按字符区间渲染成「普通 + 高亮 + 普通」片段。
fn render_highlighted_line(line: &str, ranges: &[(usize, usize)]) -> gpui_kit::AnyElement {
    if ranges.is_empty() {
        return div().child(line.to_string()).into_any_element();
    }

    let chars: Vec<char> = line.chars().collect();
    let mut segments: Vec<(String, bool)> = Vec::new();
    let mut cursor = 0usize;

    let mut sorted = ranges.to_vec();
    sorted.sort_by_key(|(start, _)| *start);

    for (start, end) in sorted {
        let start = start.min(chars.len());
        let end = end.min(chars.len());
        if end <= start {
            continue;
        }
        if start > cursor {
            segments.push((chars[cursor..start].iter().collect(), false));
        }
        segments.push((chars[start..end].iter().collect(), true));
        cursor = cursor.max(end);
    }
    if cursor < chars.len() {
        segments.push((chars[cursor..].iter().collect(), false));
    }

    h_flex()
        .gap_0()
        .children(segments.into_iter().map(|(text, highlighted)| {
            div()
                .when(highlighted, |this| {
                    this.bg(ThemeColors::accent_yellow())
                        .text_color(ThemeColors::background())
                        .rounded(px(2.0))
                })
                .child(text)
        }))
        .into_any_element()
}

impl Render for GlobalSearchPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 搜索面板自身捕获键盘，保证上下键/回车/Esc 可用。
        let focus_handle = self.focus_handle.clone();
        let empty_marker = self.results.is_empty();

        v_flex()
            .size_full()
            .bg(ThemeColors::background())
            .track_focus(&focus_handle)
            .key_context("GlobalSearch")
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                this.on_key_down(event, window, cx);
            }))
            .child(self.render_toolbar(cx))
            .child(
                if empty_marker || self.is_searching || self.error.is_some() {
                    self.render_state(cx)
                } else {
                    self.render_excerpts(cx).into_any_element()
                },
            )
            .when(self.is_indexing, |this| {
                this.child(
                    div()
                        .w_full()
                        .px_2()
                        .py_1()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(format!(
                            "{}: {}",
                            crate::i18n::menu_text(cx, "ui.loading"),
                            self.indexed_files
                        )),
                )
            })
    }
}
