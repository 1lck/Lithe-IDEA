//! 应用设置模型与设置页视图（模块根）。
//!
//! `AppSettings` 持久化到与 `lithe-platform::recent_projects` 相同的应用数据
//! 目录：Windows `%APPDATA%\Lithe`、macOS
//! `$HOME/Library/Application Support/Lithe`、Linux
//! `$XDG_CONFIG_HOME/lithe`（未设置时退回 `$HOME/.config/lithe`），文件名固定
//! 为 `settings.json`。
//!
//! 读取失败、内容损坏或字段越界时回退到安全的默认值；写入先写同目录临时文件
//! 再 rename，任何 I/O 失败都静默丢弃，不写日志也不 panic。设置页构造期不读
//! 写磁盘、不发起异步任务；只有用户修改设置时才调用 [`AppSettings::save`]。
//!
//! 设置页的导航结构与 macOS 对齐：7 个分组、19 个页面，其中 AI 分组下的
//! Library 是二级折叠分组。外部子系统（插件、完整 LSP、Provider / MCP /
//! Skills / Hooks）只显示真实状态或说明，不做假开关。
//!
//! 颜色全部来自 [`LitheTokens`]，字号与圆角优先使用 [`LitheMetrics`]；设置页
//! 特有的导航宽度、行高等尺寸收敛在 [`state`] 常量里。
//!
//! 拆分布局（原 `settings.rs` 6000+ 行按功能等价拆分，行为不变）：
//! - [`state`]：`AppSettings`、页面枚举与各页状态结构；
//! - [`controls`]：可复用行控件与卡片；
//! - [`pages`]：逐页渲染与写入方法；
//! - [`source_backed`]：Source-backed 公共助手（发现 → 草稿 → 确认 → 回读）。

mod controls;
mod pages;
mod source_backed;
mod state;
pub(crate) mod update_check;

use std::rc::Rc;

use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Icon, IconName, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, ClickEvent, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, StatefulInteractiveElement as _, Styled,
    Subscription, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use crate::settings::state::{
    LIBRARY_PAGES, SIDEBAR_LAYOUT, SETTINGS_CONTENT_MIN_WIDTH, SETTINGS_NAV_GAP,
    SETTINGS_NAV_GROUP_HEIGHT, SETTINGS_NAV_ITEM_PADDING, SETTINGS_NAV_ROW_HEIGHT,
    SETTINGS_NAV_WIDTH, SETTINGS_SECTION_GAP, ChoiceAction, SettingsGroup, SettingsPage,
    SidebarEntry, StepperAction, ToggleAction,
};
pub use state::{AppSettings, SettingsContext};
// logging.rs 通过 `crate::settings::app_data_dir()` 复用目录约定。
pub(crate) use state::app_data_dir;

/// 设置写入回调。
type ChangeHandler = Rc<dyn Fn(&AppSettings, &mut Window, &mut App) + 'static>;
/// 打开 Agent 面板回调。
type OpenHandler = Rc<dyn Fn(&mut Window, &mut App) + 'static>;
/// 运行配置保存/重新识别后的通知回调；工作台用它刷新 Run 面板。
type RunChangedHandler = Rc<dyn Fn(&mut App) + 'static>;

/// 设置页视图。
pub struct SettingsView {
    settings: AppSettings,
    context: SettingsContext,
    page: SettingsPage,
    /// 每个顶层分组是否展开；默认全部展开，导航自身可滚动。
    expanded_groups: [bool; 6],
    /// AI › Library 二级分组是否展开。
    library_expanded: bool,
    /// 侧栏搜索框。输入变化只触发本视图重绘，导航按标题过滤。
    search: Entity<InputState>,
    /// 搜索框的变更订阅，与设置页同生命周期。
    _search_subscription: Subscription,
    /// General › Hidden Paths 的两个模式输入框（多行 Textarea，对齐 Tauri）。
    hidden_directories: Entity<gpui_kit::component::input::TextareaState>,
    hidden_files: Entity<gpui_kit::component::input::TextareaState>,
    /// General › Git strategy 的会话内选择（对齐 Tauri 未持久化的本地 state）。
    git_strategy: &'static str,
    /// Updates 页本地状态（检查更新状态机）。
    updates: pages::updates::UpdatesState,
    on_change: Option<ChangeHandler>,
    on_open_agent: Option<OpenHandler>,
    /// Maven 项目配置：已保存值与 4 个字段草稿（对齐 Tauri MavenSettingsForm）。
    maven_saved: crate::maven::configuration::MavenLocalSettings,
    maven_effective: Option<crate::maven::configuration::MavenEffectiveSettings>,
    maven_inputs: [Entity<InputState>; 4],
    maven_error: Option<String>,
    /// 项目切换后待写入草稿输入框的值；输入框 API 需要 Window，
    /// 推迟到 Render 顶部应用。
    maven_pending_inputs: Option<[String; 4]>,
    /// Maven 项目的 reactor 路径；聚合根固定 "."。
    maven_reactor: String,
    /// Maven 项目配置写前冲突保护：apply 时磁盘上的已保存值与本页快照不一致。
    maven_conflict: bool,
    /// 用户级 Maven `~/.m2/settings.xml`（Source-backed）。
    maven_user: pages::project::MavenUserState,
    maven_user_input: Entity<InputState>,
    /// 用户级 Maven 回读后待回填输入框的草稿值；渲染帧应用。
    maven_user_pending: Option<String>,
    /// 字体下拉没有 Window 路径，选择先挂 pending；`Some(None)` 清除回默认。
    editor_font_pending: Option<Option<String>>,
    /// Terminal 页检测到本机 shell 的缓存；`None` 表示尚未发现。
    terminal_shells: Option<Vec<pages::terminal::TerminalShellRow>>,
    terminal_shells_error: Option<String>,
    /// AI & Commit 页：激活 Provider 的文本字段输入框与状态。
    ai_commit: pages::ai_commit::AiCommitState,
    ai_commit_name_input: Entity<InputState>,
    ai_commit_endpoint_input: Entity<InputState>,
    ai_commit_model_input: Entity<InputState>,
    ai_commit_subject_input: Entity<InputState>,
    ai_commit_diff_input: Entity<InputState>,
    ai_commit_key_input: Entity<InputState>,
    ai_commit_custom_input: Entity<gpui_kit::component::input::TextareaState>,
    /// Provider 切换/导入后的输入框回填；渲染帧应用。
    ai_commit_inputs_pending: Option<pages::ai_commit::AiCommitInputs>,
    /// input Change 事件在订阅里没有 Window：写入先挂 pending，渲染帧提交。
    ai_commit_text_pending: Option<(pages::ai_commit::AiCommitTextField, String)>,
    ai_commit_number_pending: Option<(pages::ai_commit::AiCommitNumberField, String)>,
    ai_commit_pending_protocol: Option<&'static str>,
    ai_commit_pending_token_field: Option<&'static str>,
    ai_commit_pending_authentication: Option<&'static str>,
    ai_commit_pending_effort: Option<&'static str>,
    ai_commit_pending_custom: bool,
    ai_commit_inputs_seeded: bool,
    _ai_commit_subscriptions: [Subscription; 6],
    /// Hooks 页：agent.hooks Library 状态与编辑器四个文本输入框。
    hooks: pages::hooks::HooksState,
    hook_name_input: Entity<InputState>,
    hook_instruction_input: Entity<InputState>,
    hook_command_input: Entity<InputState>,
    hook_timeout_input: Entity<InputState>,
    /// MCP 页：配置文本域与后台读文件后的回填。
    mcp: pages::mcp::McpState,
    mcp_config_input: Entity<gpui_kit::component::input::TextareaState>,
    mcp_pending_text: Option<(String, String)>,
    /// Keymap 页的搜索输入框。
    keymap_search: Entity<InputState>,
    /// Agents 页：宿主安装状态缓存（首次渲染探测一次）。
    agents: pages::agents::AgentsState,
    /// Run Configurations 页状态：配置列表、工具链默认值和编辑器草稿。
    run: state::RunConfigurationsState,
    run_argument_input: Entity<InputState>,
    run_vm_input: Entity<InputState>,
    run_working_input: Entity<InputState>,
    run_environment_input: Entity<gpui_kit::component::input::TextareaState>,
    run_editor_pending: Option<state::RunEditorInputs>,
    on_run_configurations_changed: Option<RunChangedHandler>,
    /// Logs and Diagnostics 页：日志快照、时间线筛选与三个文本输入框。
    logs: state::LogsState,
    logs_search_input: Entity<InputState>,
    logs_since_input: Entity<InputState>,
    logs_until_input: Entity<InputState>,
    _logs_subscriptions: [Subscription; 3],
    /// Git 执行设置（Source-backed：git.executionInspect / executionConfigure）。
    git_execution: pages::git::GitExecutionState,
    /// Git 身份（Source-backed：git.command 读写 user.name / user.email）。
    git_identity: pages::git::GitIdentityState,
    git_identity_name_input: Entity<InputState>,
    git_identity_email_input: Entity<InputState>,
    /// 身份回读后待回填输入框的值；输入框 API 需要 Window，渲染帧应用。
    git_identity_pending_inputs: Option<(String, String)>,
}

/// AI Commit 页输入框实体的克隆集合（在 `SettingsView::new` 构造期创建）。
#[allow(clippy::type_complexity)]
fn ai_commit_input_entities(
    window: &mut Window,
    cx: &mut Context<SettingsView>,
) -> (
    Entity<InputState>,
    Entity<InputState>,
    Entity<InputState>,
    Entity<InputState>,
    Entity<InputState>,
    Entity<InputState>,
    Entity<gpui_kit::component::input::TextareaState>,
) {
    let name = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Profile name")));
    let endpoint =
        cx.new(|cx| InputState::new(window, cx).placeholder(tr("Endpoint (https://api.example.com/v1)")));
    let model = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Model")));
    let subject = cx.new(|cx| InputState::new(window, cx));
    let diff = cx.new(|cx| InputState::new(window, cx));
    // 密钥字段用 password 掩码；保存与撤销后清空，永不回显。
    let key = cx.new(|cx| {
        InputState::new(window, cx)
            .masked(true)
            .placeholder(tr("API key"))
    });
    let custom = cx.new(|cx| {
        gpui_kit::component::input::TextareaState::new(window, cx)
            .placeholder(tr("Custom commit instructions"))
            .auto_grow(3, 8)
    });
    (name, endpoint, model, subject, diff, key, custom)
}

/// 把 AI Commit 输入框的 Change 事件绑定成 pending（订阅回调没有 Window，
/// 实际写盘在渲染帧的 flush 里完成）。
#[allow(clippy::too_many_arguments)]
fn bind_ai_commit_subscription(
    name: &Entity<InputState>,
    name_field: pages::ai_commit::AiCommitTextField,
    endpoint: &Entity<InputState>,
    endpoint_field: pages::ai_commit::AiCommitTextField,
    model: &Entity<InputState>,
    model_field: pages::ai_commit::AiCommitTextField,
    subject: &Entity<InputState>,
    diff: &Entity<InputState>,
    custom: &Entity<gpui_kit::component::input::TextareaState>,
    cx: &mut Context<SettingsView>,
) -> [Subscription; 6] {
    // 文本字段 → (字段, 值) pending。闭包要 `move` 取得 `field` 的所有权，
    // 且调用时会可变借用 cx，因此绑定为 `mut`。
    let mut bind_text =
        |entity: &Entity<InputState>, field: pages::ai_commit::AiCommitTextField| {
            cx.subscribe(entity, move |this, entity, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    let value = entity.read(cx).value().to_string();
                    this.ai_commit.text_pending = Some((field, value));
                    cx.notify();
                }
            })
        };
    let name_subscription = bind_text(name, name_field);
    let endpoint_subscription = bind_text(endpoint, endpoint_field);
    let model_subscription = bind_text(model, model_field);
    // 数字字段 → (字段, 值) pending。
    let mut bind_number =
        |entity: &Entity<InputState>, field: pages::ai_commit::AiCommitNumberField| {
            cx.subscribe(entity, move |this, entity, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    let value = entity.read(cx).value().to_string();
                    this.ai_commit.number_pending = Some((field, value));
                    cx.notify();
                }
            })
        };
    let subject_subscription = bind_number(subject, pages::ai_commit::AiCommitNumberField::Subject);
    let diff_subscription = bind_number(diff, pages::ai_commit::AiCommitNumberField::Diff);
    let custom_subscription =
        cx.subscribe(custom, |this, _entity, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.ai_commit.pending_custom = true;
                cx.notify();
            }
        });
    [name_subscription, endpoint_subscription, model_subscription, subject_subscription, diff_subscription, custom_subscription]
}

impl SettingsView {
    /// 构造设置页。这里只保存状态，不读写磁盘、不 spawn 任务。
    pub fn new(settings: AppSettings, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("Search settings"))
                .clean_on_escape()
        });
        let hidden_directories_value = settings.hidden_directory_patterns.join("\n");
        let hidden_files_value = settings.hidden_file_patterns.join("\n");
        let hidden_directories = cx.new(|cx| {
            let mut state = gpui_kit::component::input::TextareaState::new(window, cx)
                .placeholder(tr("One pattern per line"))
                .auto_grow(2, 6);
            state.set_value(hidden_directories_value, window, cx);
            state
        });
        let hidden_files = cx.new(|cx| {
            let mut state = gpui_kit::component::input::TextareaState::new(window, cx)
                .placeholder(tr("One pattern per line"))
                .auto_grow(2, 6);
            state.set_value(hidden_files_value, window, cx);
            state
        });
        let _search_subscription = cx.subscribe(&search, |this, state, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                // 搜索词变化可能让当前页不可见，切到第一个匹配页。
                let query = state.read(cx).value();
                if !query.trim().is_empty() && !this.page_matches(this.page, &query) {
                    if let Some(first) = this.first_matching_page(&query) {
                        this.page = first;
                    }
                }
                cx.notify();
            }
        });

        // 日志页的三个筛选输入框：变化后丢弃旧时间线，等用户点“刷新日志”。
        let logs_search_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(tr("Filter log messages"))
        });
        let logs_since_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(tr("From (UTC ISO 8601)"))
        });
        let logs_until_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(tr("Until (UTC ISO 8601)"))
        });
        let logs_search_subscription = cx.subscribe(
            &logs_search_input,
            |this, state, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.logs.search = state.read(cx).value().to_string();
                    this.logs.timeline = None;
                    cx.notify();
                }
            },
        );
        let logs_since_subscription =
            cx.subscribe(&logs_since_input, |this, state, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.logs.since = state.read(cx).value().to_string();
                    this.logs.timeline = None;
                    cx.notify();
                }
            });
        let logs_until_subscription =
            cx.subscribe(&logs_until_input, |this, state, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.logs.until = state.read(cx).value().to_string();
                    this.logs.timeline = None;
                    cx.notify();
                }
            });

        // AI Commit 页的输入框实体与订阅（需要一次性生成，先取局部变量）。
        let (
            ai_commit_name_input,
            ai_commit_endpoint_input,
            ai_commit_model_input,
            ai_commit_subject_input,
            ai_commit_diff_input,
            ai_commit_key_input,
            ai_commit_custom_input,
        ) = ai_commit_input_entities(window, cx);

        // Hooks 页编辑器的四个输入框。
        let hook_name_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(tr("Hook name (letters, numbers, _ or -)"))
        });
        let hook_instruction_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("Description")));
        let hook_command_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("Command")));
        let hook_timeout_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("Seconds (1–86400)")));

        Self {
            settings,
            context: SettingsContext::default(),
            page: SettingsPage::General,
            expanded_groups: [true; 6],
            library_expanded: true,
            search,
            _search_subscription,
            hidden_directories,
            hidden_files,
            git_strategy: "ask",
            updates: pages::updates::UpdatesState::default(),
            on_change: None,
            on_open_agent: None,
            maven_saved: crate::maven::configuration::MavenLocalSettings::default(),
            maven_effective: None,
            maven_inputs: [
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Automatic"))),
            ],
            maven_error: None,
            maven_pending_inputs: None,
            maven_reactor: String::from("."),
            maven_conflict: false,
            maven_user: pages::project::MavenUserState::default(),
            maven_user_input: cx.new(|cx| {
                InputState::new(window, cx).placeholder(tr("Maven local repository"))
            }),
            maven_user_pending: None,
            editor_font_pending: None,
            terminal_shells: None,
            terminal_shells_error: None,
            ai_commit: pages::ai_commit::AiCommitState::default(),
            ai_commit_name_input: ai_commit_name_input.clone(),
            ai_commit_endpoint_input: ai_commit_endpoint_input.clone(),
            ai_commit_model_input: ai_commit_model_input.clone(),
            ai_commit_subject_input: ai_commit_subject_input.clone(),
            ai_commit_diff_input: ai_commit_diff_input.clone(),
            ai_commit_key_input: ai_commit_key_input.clone(),
            ai_commit_custom_input: ai_commit_custom_input.clone(),
            ai_commit_inputs_pending: None,
            ai_commit_text_pending: None,
            ai_commit_number_pending: None,
            ai_commit_pending_protocol: None,
            ai_commit_pending_token_field: None,
            ai_commit_pending_authentication: None,
            ai_commit_pending_effort: None,
            ai_commit_pending_custom: false,
            ai_commit_inputs_seeded: false,
            _ai_commit_subscriptions: {
                let subscriptions = bind_ai_commit_subscription(
                    &ai_commit_name_input,
                    pages::ai_commit::AiCommitTextField::Name,
                    &ai_commit_endpoint_input,
                    pages::ai_commit::AiCommitTextField::Endpoint,
                    &ai_commit_model_input,
                    pages::ai_commit::AiCommitTextField::Model,
                    &ai_commit_subject_input,
                    &ai_commit_diff_input,
                    &ai_commit_custom_input,
                    cx,
                );
                subscriptions
            },
            hooks: pages::hooks::HooksState::default(),
            hook_name_input: hook_name_input.clone(),
            hook_instruction_input: hook_instruction_input.clone(),
            hook_command_input: hook_command_input.clone(),
            hook_timeout_input: hook_timeout_input.clone(),
            mcp: pages::mcp::McpState::default(),
            mcp_config_input: cx.new(|cx| {
                gpui_kit::component::input::TextareaState::new(window, cx)
                    .placeholder(tr("MCP configuration"))
                    .auto_grow(4, 12)
            }),
            mcp_pending_text: None,
            keymap_search: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(tr("Search shortcuts"))
                    .clean_on_escape()
            }),
            agents: pages::agents::AgentsState::default(),
            run: state::RunConfigurationsState::new(),
            run_argument_input: cx.new(|cx| InputState::new(window, cx)),
            run_vm_input: cx.new(|cx| InputState::new(window, cx)),
            run_working_input: cx.new(|cx| InputState::new(window, cx)),
            run_environment_input: cx.new(|cx| {
                gpui_kit::component::input::TextareaState::new(window, cx)
                    .placeholder(tr("KEY=VALUE"))
                    .auto_grow(2, 6)
            }),
            run_editor_pending: None,
            on_run_configurations_changed: None,
            logs: state::LogsState::new(),
            logs_search_input,
            logs_since_input,
            logs_until_input,
            _logs_subscriptions: [
                logs_search_subscription,
                logs_since_subscription,
                logs_until_subscription,
            ],
            git_execution: pages::git::GitExecutionState::new(),
            git_identity: pages::git::GitIdentityState::new(),
            git_identity_name_input: cx.new(|cx| InputState::new(window, cx)),
            git_identity_email_input: cx.new(|cx| InputState::new(window, cx)),
            git_identity_pending_inputs: None,
        }
    }

    /// 把全部设置恢复为默认值并提交。Tauri 的 “Restore Defaults” 行为。
    pub fn restore_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings = AppSettings::default();
        self.commit(window, cx);
    }

    /// 页面标题是否命中当前搜索词。
    fn page_matches(&self, page: SettingsPage, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        if query.is_empty() {
            return true;
        }
        // 对齐 Tauri `filterSettingsCategories`：页面标题 + 关键词条 +
        // 分组名都参与大小写不敏感匹配。
        if tr(page.title()).to_lowercase().contains(&query) {
            return true;
        }
        if page
            .search_terms()
            .iter()
            .any(|term| term.to_lowercase().contains(&query))
        {
            return true;
        }
        if let Some(group) = page.group() {
            if tr(group.title()).to_lowercase().contains(&query) {
                return true;
            }
        }
        false
    }

    /// 搜索时按侧栏顺序找到第一个命中的页面。
    fn first_matching_page(&self, query: &str) -> Option<SettingsPage> {
        for entry in SIDEBAR_LAYOUT {
            match entry {
                SidebarEntry::Page(page) => {
                    if self.page_matches(page, query) {
                        return Some(page);
                    }
                }
                SidebarEntry::Group(group) => {
                    for page in group.pages() {
                        if self.page_matches(*page, query) {
                            return Some(*page);
                        }
                    }
                }
            }
        }
        None
    }

    /// 用外部状态替换当前设置并重绘。不会触发 `on_change` 或写盘。
    pub fn set_settings(&mut self, settings: AppSettings, cx: &mut Context<Self>) {
        self.settings = settings;
        cx.notify();
    }

    /// 切到「AI 与提交」页。供 Git 提交区的 AI 入口直接跳转。
    pub fn open_ai_commit_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::AiCommit;
        cx.notify();
    }

    /// 直接落到「Project · JDK & Maven」页。Maven 工具窗的设置入口使用。
    pub fn open_project_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Project;
        cx.notify();
    }

    /// 直接落到「Run Configurations」页；没有加载过就读取项目配置。
    pub fn open_run_configurations_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::RunConfigurations;
        self.ensure_run_loaded(cx);
        cx.notify();
    }

    /// 打开 Run Configurations 页并进入指定配置的编辑器。
    ///
    /// Run 面板的「Edit」入口使用；配置还没加载完时先记下 id，快照到达后再打开。
    pub fn edit_run_configuration(&mut self, id: &str, cx: &mut Context<Self>) {
        self.page = SettingsPage::RunConfigurations;
        let id = id.to_string();
        if self.run.root == self.context.project_root
            && !self.run.loading
            && self.run.ready
            && self
                .run
                .configurations
                .iter()
                .any(|configuration| configuration.id == id)
        {
            self.open_run_editor(id, cx);
        } else {
            self.run.pending_edit = Some(id);
            self.ensure_run_loaded(cx);
        }
        cx.notify();
    }

    /// 直接落到「Git」页。Git Log 标题栏的设置入口使用（对齐 Tauri
    /// `openSettingsDialog("git")`）。
    pub fn open_git_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Git;
        cx.notify();
    }

    /// 直接落到「LSP」页。Run 面板的语言服务设置入口使用（对齐 Tauri
    /// `openSettingsDialog("language")`）。
    pub fn open_language_service_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Lsp;
        cx.notify();
    }

    /// 直接落到「Keymap」页。Tools / Help 菜单的 Keyboard Shortcuts 入口使用
    /// （对齐 Tauri `openSettingsDialog("keyboard")`）。
    pub fn open_keymap_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Keymap;
        cx.notify();
    }

    /// 直接落到「Logs and Diagnostics」页。Run 面板的查看日志入口使用
    /// （对齐 Tauri `openSettingsDialog("logs")`）。
    pub fn open_logs_page(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Diagnostics;
        if !self.logs.loaded {
            // 页面首次打开时同步读取日志快照；日志本身很小，且只发生一次。
            self.logs.refresh();
        }
        cx.notify();
    }

    /// 直接落到「Updates」页并触发一次检查更新。
    ///
    /// Help > Check for Updates 与 Updates 页的「检查更新」按钮走同一个状态机
    /// （对齐 Tauri `menu_check_updates`）。检查在后台查询发布源，页面最终显示
    /// 有新版、已是最新或具体失败原因。
    pub fn open_updates_page_with_check(&mut self, cx: &mut Context<Self>) {
        self.page = SettingsPage::Updates;
        self.check_for_updates(cx);
        cx.notify();
    }

    /// 更新只读工作台上下文并重绘。上下文变化不是设置修改，不写盘。
    pub fn set_context(&mut self, context: SettingsContext, cx: &mut Context<Self>) {
        let project_changed = self.context.project_root != context.project_root;
        self.context = context;
        if project_changed {
            self.reload_maven_configuration(cx);
            self.reset_run_state();
            // Git 执行/身份设置按项目来源缓存，项目切换后重新发现。
            self.reset_git_sources();
            // 用户级 Maven 文件与项目无关，这里只清掉旧错误与输入框回填，
            // 让下一次渲染重新发现。
            self.maven_user = pages::project::MavenUserState::default();
            self.maven_user_pending = None;
            if self.page == SettingsPage::RunConfigurations {
                self.reload_run_configurations(cx);
            }
        }
        cx.notify();
    }

    /// 当前设置的只读引用。
    pub fn settings(&self) -> &AppSettings {
        &self.settings
    }

    /// 注册设置变化回调。回调在字段更新之后、写盘之前调用，参数是更新后的
    /// 设置；同一时间只保留最后一个回调。
    pub fn on_change(&mut self, handler: impl Fn(&AppSettings, &mut Window, &mut App) + 'static) {
        self.on_change = Some(Rc::new(handler));
    }

    /// 注册“打开 Agent 面板”回调；同一时间只保留最后一个回调。
    pub fn on_open_agent(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_agent = Some(Rc::new(handler));
    }

    /// 注册运行配置变化回调：保存或重新识别后通知工作台刷新 Run 面板。
    pub fn on_run_configurations_changed(&mut self, handler: impl Fn(&mut App) + 'static) {
        self.on_run_configurations_changed = Some(Rc::new(handler));
    }

    /// 设置已更新的统一收尾：回调、写盘、重绘。
    pub(super) fn commit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_change.as_ref() {
            handler(&self.settings, window, cx);
        }
        self.settings.save();
        cx.notify();
    }

    fn select_page(&mut self, page: SettingsPage, cx: &mut Context<Self>) {
        if self.page == page {
            return;
        }
        self.page = page;
        if page == SettingsPage::RunConfigurations {
            self.ensure_run_loaded(cx);
        }
        cx.notify();
    }

    fn toggle_group(&mut self, group: SettingsGroup, cx: &mut Context<Self>) {
        let index = group.index();
        self.expanded_groups[index] = !self.expanded_groups[index];
        cx.notify();
    }

    fn toggle_library(&mut self, cx: &mut Context<Self>) {
        self.library_expanded = !self.library_expanded;
        cx.notify();
    }

    fn invoke_open_agent(&self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_open_agent.as_ref() {
            handler(window, cx);
        }
    }

    // -----------------------------------------------------------------
    // 设置修改统一入口（互斥按钮 / 开关 / 步进器共用）
    // -----------------------------------------------------------------

    /// 互斥按钮行的统一入口。
    pub(super) fn apply_choice(
        &mut self,
        action: ChoiceAction,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            ChoiceAction::Theme => self.set_theme(value, window, cx),
            ChoiceAction::AppearanceMode => self.set_appearance_mode(value, window, cx),
            ChoiceAction::ProjectOpenDestination => {
                self.set_project_open_destination(value, window, cx)
            }
            ChoiceAction::EditorTabSize => self.set_editor_tab_size(value, window, cx),
            ChoiceAction::EditorTabLayout => self.set_editor_tab_layout(value, window, cx),
            ChoiceAction::AiCommitLanguage => self.set_ai_commit_language(value, window, cx),
            ChoiceAction::GitDiffView => self.set_git_default_diff_view(value, window, cx),
            ChoiceAction::GitFetchSubmodules => self.set_git_fetch_submodules(value, window, cx),
            ChoiceAction::GitFetchTags => self.set_git_fetch_tags(value, window, cx),
            ChoiceAction::KeymapPreset => self.set_keymap_preset(value, window, cx),
            ChoiceAction::Language => self.set_language(value, window, cx),
            ChoiceAction::JavaProjectImport => {
                self.set_java_project_import_on_open(value, window, cx)
            }
            ChoiceAction::UpdateChannel => self.set_update_channel(value, window, cx),
            ChoiceAction::RunServices => self.set_run_services_on_exit(value, window, cx),
            ChoiceAction::TerminalOnQuit => self.set_terminal_on_quit(value, window, cx),
            ChoiceAction::AgentTasks => self.set_agent_tasks(value, window, cx),
            ChoiceAction::BackgroundServices => self.set_background_services(value, window, cx),
            ChoiceAction::CommitFormat => self.set_ai_commit_format(value, window, cx),
        }
    }

    /// Git / Keymap / AI 布尔开关的统一入口。
    pub(super) fn apply_toggle(
        &mut self,
        action: ToggleAction,
        checked: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Tauri `git-settings.tsx`：prune 关掉时如果 tags 还是 prune，回退 inherit。
        if action == ToggleAction::GitFetchPrune && !checked && self.settings.git_fetch_tags == "prune"
        {
            self.settings.git_fetch_tags = "inherit".to_string();
        }
        let target = match action {
            ToggleAction::GitIntegration => &mut self.settings.git_integration,
            ToggleAction::GitAutoRefresh => &mut self.settings.git_auto_refresh,
            ToggleAction::GitConfirmDiscard => &mut self.settings.git_confirm_discard,
            ToggleAction::GitFolderView => &mut self.settings.git_changes_folder_view,
            ToggleAction::GitUntracked => &mut self.settings.git_show_untracked,
            ToggleAction::GitStagedFirst => &mut self.settings.git_show_staged_first,
            ToggleAction::GitOpenDiff => &mut self.settings.git_open_diff_on_click,
            ToggleAction::GitCompactBadges => &mut self.settings.git_compact_badges,
            ToggleAction::GitCollapseEmpty => &mut self.settings.git_collapse_empty,
            ToggleAction::GitInlineBlame => &mut self.settings.git_inline_blame,
            ToggleAction::GitGutter => &mut self.settings.git_gutter,
            ToggleAction::GitFetchPrune => &mut self.settings.git_fetch_prune,
            ToggleAction::GitChangelists => &mut self.settings.show_git_changelists,
            ToggleAction::VimMode => &mut self.settings.vim_mode,
            ToggleAction::AiAutocomplete => &mut self.settings.ai_autocomplete,
            ToggleAction::AiCommitEnabled => &mut self.settings.ai_commit_enabled,
            ToggleAction::AutoCompletion => &mut self.settings.auto_completion,
            ToggleAction::ParameterHints => &mut self.settings.parameter_hints,
            ToggleAction::SemanticTokens => &mut self.settings.semantic_tokens,
        };
        if *target == checked {
            return;
        }
        *target = checked;
        self.commit(window, cx);
    }

    /// 步进器的统一入口。
    pub(super) fn apply_step(
        &mut self,
        action: StepperAction,
        delta: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            StepperAction::EditorFontSize => self.adjust_editor_font_size(delta, window, cx),
            StepperAction::TerminalFontSize => self.adjust_terminal_font_size(delta, window, cx),
            StepperAction::TerminalScrollback => self.adjust_terminal_scrollback(delta, window, cx),
            StepperAction::GracefulStop => self.adjust_graceful_stop(delta, window, cx),
        }
    }

    /// 步进器“恢复默认”的统一入口；值本来就在默认值时直接返回，不写盘。
    pub(super) fn apply_reset(&mut self, action: StepperAction, window: &mut Window, cx: &mut Context<Self>) {
        use state::{
            DEFAULT_GRACEFUL_STOP_SECONDS, DEFAULT_TERMINAL_FONT_SIZE, DEFAULT_TERMINAL_SCROLLBACK,
        };
        let changed = match action {
            StepperAction::EditorFontSize => self.settings.reset_editor_font_size(),
            StepperAction::TerminalFontSize => {
                if (self.settings.terminal_font_size - DEFAULT_TERMINAL_FONT_SIZE).abs()
                    < f32::EPSILON
                {
                    false
                } else {
                    self.settings.terminal_font_size = DEFAULT_TERMINAL_FONT_SIZE;
                    true
                }
            }
            StepperAction::TerminalScrollback => {
                if self.settings.terminal_scrollback == DEFAULT_TERMINAL_SCROLLBACK {
                    false
                } else {
                    self.settings.terminal_scrollback = DEFAULT_TERMINAL_SCROLLBACK;
                    true
                }
            }
            StepperAction::GracefulStop => {
                if self.settings.graceful_stop_seconds == DEFAULT_GRACEFUL_STOP_SECONDS {
                    false
                } else {
                    self.settings.graceful_stop_seconds = DEFAULT_GRACEFUL_STOP_SECONDS;
                    true
                }
            }
        };

        if changed {
            self.commit(window, cx);
        }
    }

    // -----------------------------------------------------------------
    // 导航
    // -----------------------------------------------------------------

    fn render_nav(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let query = self.search.read(cx).value();
        let searching = !query.trim().is_empty();
        let mut any_visible = false;
        let mut items = div().flex().flex_col();

        for entry in SIDEBAR_LAYOUT {
            match entry {
                SidebarEntry::Group(group) => {
                    if self.group_visible(group, &query) {
                        any_visible = true;
                        items = items.child(self.render_group(group, tokens, cx));
                    }
                }
                SidebarEntry::Page(page) => {
                    if self.page_matches(page, &query) {
                        any_visible = true;
                        items = items.child(self.render_page_item(page, 0, tokens, cx));
                    }
                }
            }
        }

        div()
            .id("lithe-settings:nav")
            .w(px(SETTINGS_NAV_WIDTH))
            .h_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .bg(tokens.sidebar)
            // Tauri：搜索框距顶部 12、左右 8、底部 12。
            .child(
                div().px(px(8.0)).pt(px(12.0)).pb(px(12.0)).child(
                    Input::new(&self.search).small().prefix(
                        Icon::new(IconName::Search)
                            .with_size(px(14.0))
                            .text_color(tokens.tertiary_text),
                    ),
                ),
            )
            .child(
                div()
                    .id("lithe-settings:nav-scroll")
                    .flex_1()
                    .min_h(px(0.0))
                    .pb(px(12.0))
                    .overflow_y_scroll()
                    .when(searching && !any_visible, |this| {
                        this.child(
                            div()
                                .px(px(12.0))
                                .py(px(8.0))
                                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(tr("No settings found")),
                        )
                    })
                    .child(items),
            )
            .into_any_element()
    }

    /// 分组标题或任一子页面命中搜索词时显示该分组。
    fn group_visible(&self, group: SettingsGroup, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        query.is_empty()
            || tr(group.title()).to_lowercase().contains(&query)
            || group
                .pages()
                .iter()
                .any(|page| self.page_matches(*page, &query))
    }

    fn render_group(
        &self,
        group: SettingsGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let mut column = div()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_NAV_GAP))
            .child(self.render_group_header(group, tokens, cx));

        if self.expanded_groups[group.index()] || searching {
            if group == SettingsGroup::Ai {
                // AI 的条目顺序与 macOS 一致：Providers / Agents / Library / AI & Commit。
                column = column
                    .child(self.render_page_item(SettingsPage::AiProviders, 1, tokens, cx))
                    .child(self.render_page_item(SettingsPage::Agents, 1, tokens, cx));

                let query = self.search.read(cx).value();
                let library_visible = !searching
                    || LIBRARY_PAGES
                        .iter()
                        .any(|page| self.page_matches(*page, &query));
                if library_visible {
                    column = column.child(self.render_library_header(tokens, cx));
                    if self.library_expanded || searching {
                        for page in LIBRARY_PAGES {
                            column = column.child(self.render_page_item(page, 2, tokens, cx));
                        }
                    }
                }

                column = column.child(self.render_page_item(SettingsPage::AiCommit, 1, tokens, cx));
            } else {
                for page in group.pages() {
                    column = column.child(self.render_page_item(*page, 1, tokens, cx));
                }
            }
        }

        column.into_any_element()
    }

    fn render_group_header(
        &self,
        group: SettingsGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let expanded = self.expanded_groups[group.index()] || searching;
        let contains_selection = self.page.group() == Some(group);

        div()
            .id(group.id())
            .w_full()
            .h(px(SETTINGS_NAV_GROUP_HEIGHT))
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(4.0))
            .px(px(SETTINGS_NAV_ITEM_PADDING))
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(if contains_selection {
                tokens.primary_text
            } else {
                tokens.secondary_text
            })
            .child(
                // Tauri 用 CaretDown/CaretRight 图标（size-3），不是文本箭头。
                lithe_ui::icon(if expanded {
                    LitheIcon::ChevronDown
                } else {
                    LitheIcon::ChevronRight
                })
                .with_size(px(12.0))
                .flex_shrink_0()
                .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .truncate()
                    .child(tr(group.title())),
            )
            .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                this.toggle_group(group, cx);
            }))
            .into_any_element()
    }

    fn render_library_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let searching = !self.search.read(cx).value().trim().is_empty();
        let expanded = self.library_expanded || searching;

        div()
            .id("lithe-settings:nav:library")
            .w_full()
            .h(px(SETTINGS_NAV_GROUP_HEIGHT))
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(4.0))
            .pl(px(40.0))
            .pr(px(SETTINGS_NAV_ITEM_PADDING))
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(tokens.secondary_text)
            .child(
                lithe_ui::icon(if expanded {
                    LitheIcon::ChevronDown
                } else {
                    LitheIcon::ChevronRight
                })
                .with_size(px(12.0))
                .flex_shrink_0()
                .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .truncate()
                    .child(tr("Library")),
            )
            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                this.toggle_library(cx);
            }))
            .into_any_element()
    }

    fn render_page_item(
        &self,
        page: SettingsPage,
        depth: usize,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let query = self.search.read(cx).value();
        if !self.page_matches(page, &query) {
            return div().into_any_element();
        }

        let selected = self.page == page;
        // Tauri：顶层页面 pl-6（24），分组内页面 pl-10（40），Library 二级
        // 页面再缩进一级（56）。
        let padding_left = match depth {
            0 => 24.0,
            1 => 40.0,
            _ => 56.0,
        };

        div()
            .id(page.id())
            .w_full()
            .h(px(SETTINGS_NAV_ROW_HEIGHT))
            .flex_shrink_0()
            .flex()
            .items_center()
            .pl(px(padding_left))
            .pr(px(SETTINGS_NAV_ITEM_PADDING))
            .cursor_pointer()
            // Tauri 选中态：`bg-primary/15`，方角，全宽。
            .when(selected, |this| this.bg(tokens.selection.alpha(0.15)))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(if depth == 0 {
                FontWeight::SEMIBOLD
            } else {
                FontWeight::NORMAL
            })
            .text_color(if selected {
                tokens.primary_text
            } else {
                tokens.secondary_text
            })
            .child(tr(page.title()))
            .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                this.select_page(page, cx);
            }))
            .into_any_element()
    }

    // -----------------------------------------------------------------
    // 内容区
    // -----------------------------------------------------------------

    fn render_content(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let page = self.page;
        let body = match page {
            SettingsPage::General => self.render_general(tokens, cx),
            SettingsPage::Updates => self.render_updates(tokens, cx),
            SettingsPage::Editor => self.render_editor(tokens, cx),
            SettingsPage::Keymap => self.render_keymap(tokens, cx),
            SettingsPage::ProcessTermination => self.render_process_termination(tokens, cx),
            SettingsPage::Plugins => self.render_plugins(tokens),
            SettingsPage::DeclarativePlugins => self.render_declarative_plugins(tokens, cx),
            SettingsPage::Git => self.render_git(tokens, cx),
            SettingsPage::Project => self.render_project(tokens, cx),
            SettingsPage::RunConfigurations => self.render_run_configurations(tokens, cx),
            SettingsPage::Lsp => self.render_lsp(tokens, cx),
            SettingsPage::Terminal => self.render_terminal(tokens, cx),
            SettingsPage::Diagnostics => self.render_diagnostics(tokens, cx),
            SettingsPage::AiProviders => self.render_ai_providers(tokens, cx),
            SettingsPage::Agents => self.render_agents(tokens, cx),
            SettingsPage::Instructions | SettingsPage::Skills => {
                self.render_agent_library_page(page, tokens, cx)
            }
            SettingsPage::Hooks => self.render_hooks(tokens, cx),
            SettingsPage::Mcp => self.render_mcp(tokens, cx),
            SettingsPage::AiCommit => self.render_ai_commit(tokens, cx),
        };

        div()
            .id("lithe-settings:content")
            .flex_1()
            .min_w(px(SETTINGS_CONTENT_MIN_WIDTH))
            .min_h(px(0.0))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            // Tauri：px-4 pt-4 pb-5。
            .px(px(16.0))
            .pt(px(16.0))
            .pb(px(20.0))
            .bg(tokens.editor)
            .child(body)
            .into_any_element()
    }

    /// 内容区顶部固定 48pt 面包屑：分组 › 页面。
    fn render_breadcrumb(&self, tokens: LitheTokens) -> gpui_kit::AnyElement {
        let page = self.page;
        let mut row = div().flex().items_center().gap(px(6.0)).child(
            div()
                .flex_shrink_0()
                .child(tr(page.title()))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE)),
        );

        if page != SettingsPage::Plugins {
            if let Some(group) = page.group() {
                let mut trail = div()
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .text_color(tokens.secondary_text)
                    .child(tr(group.title()))
                    .child(
                        lithe_ui::icon(lithe_ui::LitheIcon::ChevronRight)
                            .with_size(px(12.0))
                            .text_color(tokens.tertiary_text),
                    );

                // Library 是 AI 下的二级分组，面包屑保持三级。
                if LIBRARY_PAGES.contains(&page) {
                    trail = trail.child(tr("Library")).child(
                        lithe_ui::icon(lithe_ui::LitheIcon::ChevronRight)
                            .with_size(px(12.0))
                            .text_color(tokens.tertiary_text),
                    );
                }

                row = trail.child(
                    div()
                        .text_color(tokens.primary_text)
                        .child(tr(page.title())),
                );
            }
        }

        div()
            .w_full()
            .h(px(48.0))
            .flex_shrink_0()
            .flex()
            .items_center()
            .px(px(16.0))
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(tokens.primary_text)
            .child(row)
            .into_any_element()
    }
}

impl Render for SettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 项目切换后把 Maven 字段的已保存值写进草稿输入框；输入框 API
        // 需要 Window，统一在拿到 Window 的渲染帧应用。
        if let Some(values) = self.maven_pending_inputs.take() {
            for (input, text) in self.maven_inputs.iter().zip(values) {
                input.update(cx, |state, cx| state.set_value(text, window, cx));
            }
        }
        // 打开 Run 配置编辑器或选择工作目录后，把草稿写入输入框。
        if let Some(values) = self.run_editor_pending.take() {
            self.run_argument_input
                .update(cx, |state, cx| state.set_value(values.arguments, window, cx));
            self.run_vm_input
                .update(cx, |state, cx| state.set_value(values.vm_arguments, window, cx));
            self.run_working_input.update(cx, |state, cx| {
                state.set_value(values.working_directory, window, cx)
            });
            self.run_environment_input.update(cx, |state, cx| {
                state.set_value(values.environment, window, cx)
            });
        }
        // Git 身份回读后的输入框回填。
        if let Some((name, email)) = self.git_identity_pending_inputs.take() {
            self.git_identity_name_input
                .update(cx, |state, cx| state.set_value(name, window, cx));
            self.git_identity_email_input
                .update(cx, |state, cx| state.set_value(email, window, cx));
        }
        // 用户级 Maven 回读后的输入框回填。
        if let Some(value) = self.maven_user_pending.take() {
            self.maven_user_input
                .update(cx, |state, cx| state.set_value(value, window, cx));
        }
        // AI & Commit 页的 pending（订阅/弹窗没有 Window 的写入路径）。
        self.apply_ai_commit_pending(window, cx);
        // Hooks 页编辑器的输入框回填。
        self.apply_hooks_pending(window, cx);
        // MCP 页配置文件预读回填。
        if let Some((text, path)) = self.mcp_pending_text.take() {
            if text.is_empty() {
                self.mcp.error = Some(tr("The configuration file is empty or missing.").to_string());
            }
            self.mcp_config_input.update(cx, |state, cx| {
                state.set_value(text, window, cx)
            });
            let _ = path;
        }
        // Editor 字体下拉的 pending 应用（需要 Window 的 commit 路径）。
        self.apply_editor_font_pending(window, cx);
        // 字体清单进程内稳定，只算一次；渲染帧里有 Window。
        pages::editor::snapshot_editor_font_choices(window);
        let tokens = current_tokens(cx);
        div()
            .id("lithe-settings")
            .size_full()
            .flex()
            .flex_row()
            .bg(tokens.window)
            .text_color(tokens.primary_text)
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .child(self.render_nav(tokens, cx))
            .child(div().w(px(1.0)).h_full().flex_shrink_0().bg(tokens.divider))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .h_full()
                    .flex()
                    .flex_col()
                    .bg(tokens.editor)
                    .child(self.render_breadcrumb(tokens))
                    .child(self.render_content(tokens, cx)),
            )
    }
}

// 折叠图标随展开状态切换；这里复用 lithe_ui 的图标枚举。
use lithe_ui::LitheIcon;
