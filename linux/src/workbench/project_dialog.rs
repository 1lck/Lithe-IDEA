//! 新建/克隆项目对话框：复刻 Tauri 端 `new-project-content.tsx` 的两步流程。
//!
//! - New 模式：source 列表（搜索 + 3 个来源行）→ details 表单 → 创建。
//! - Clone 模式：直接进 details（仓库 URL + 自动推导名称 + 位置）。
//! - 名称校验、URL 推导名、starter 命令逐条移植自
//!   `windows/tauri/src/features/window/lib/new-project-model.ts`。
//! - 文案键与 `windows/tauri/src/i18n/locale.ts` 的 `newProject.*` /
//!   `welcome.*` 对齐，`{path}` / `{query}` 占位在渲染时替换。
//! - 遮罩 + 卡片布局仿 `settings_dialog.rs`，行样式与键盘输入仿
//!   `sidebar.rs` / `quick_open.rs`（只读展示行 + `on_key_down` 追加）。
//! - 执行：空项目同步 `create_dir_all`；模板项目同步建目录并把 starter
//!   命令随事件交给父级发往新终端；clone 在
//!   `cx.background_executor()` 后台跑 `git clone`，避免阻塞 UI。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, AnyElement, Context, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Window,
};

/// 对话框模式：新建项目向导，或直接克隆仓库。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectDialogMode {
    New,
    Clone,
}

/// 向导步骤：来源选择 → 详情表单 → 创建中（Clone 模式跳过来源选择）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProjectDialogStep {
    Source,
    Details,
    Creating,
}

/// 新建来源（clone 走 [`ProjectDialogMode::Clone`]，不在 New 列表中）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NewProjectSource {
    Empty,
    Nextjs,
    ViteReact,
}

/// 包管理器：详情页循环切换按钮在三者之间轮换。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PackageManager {
    Npm,
    Pnpm,
    Bun,
}

impl PackageManager {
    /// 按钮展示文本，与 Tauri `packageManagerOptions` 的 label 一致。
    fn label(self) -> &'static str {
        match self {
            PackageManager::Npm => "npm",
            PackageManager::Pnpm => "pnpm",
            PackageManager::Bun => "Bun",
        }
    }
}

/// 当前接收键盘输入的字段（对话框内只有一个焦点句柄，按点击行切换）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ActiveField {
    Search,
    ProjectName,
    RepositoryUrl,
    Location,
}

/// 对话框对外事件。
#[derive(Debug, Clone)]
pub enum ProjectDialogEvent {
    /// 项目已就绪：`path` 为新项目目录；模板项目附带 starter 命令，
    /// 父级打开目录后应把该命令原样发往新终端。
    OpenedProject {
        path: String,
        starter: Option<String>,
    },
    /// 请求关闭对话框。
    Close,
}

/// Windows 保留名（不含扩展名的首段命中即跨平台不合法）。
const WINDOWS_RESERVED_NAMES: &[&str] = &[
    "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
];

/// 文件名保留字符（含路径分隔符）。
const RESERVED_CHARS: [char; 9] = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];

/// 居中新建项目面板（宽 560px，高 480px）。
pub struct ProjectDialog {
    mode: ProjectDialogMode,
    step: ProjectDialogStep,
    source: NewProjectSource,
    /// 来源搜索串。
    query: String,
    selected_index: usize,
    project_name: String,
    repository_url: String,
    location_path: String,
    package_manager: PackageManager,
    /// 名称是否被用户亲手改过；未改过时 URL 变化会自动推导名称。
    name_was_edited: bool,
    error_message: Option<String>,
    active_field: ActiveField,
    focus_handle: FocusHandle,
}

impl EventEmitter<ProjectDialogEvent> for ProjectDialog {}

impl ProjectDialog {
    /// 新建对话框：位置默认取用户主目录（不引入新依赖，不读真实 home 库）。
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            mode: ProjectDialogMode::New,
            step: ProjectDialogStep::Source,
            source: NewProjectSource::Empty,
            query: String::new(),
            selected_index: 0,
            project_name: String::new(),
            repository_url: String::new(),
            location_path: default_project_location(),
            package_manager: PackageManager::Npm,
            name_was_edited: false,
            error_message: None,
            active_field: ActiveField::Search,
            focus_handle: cx.focus_handle(),
        }
    }

    /// 切换模式并重置整个表单（New 进来源选择，Clone 直接进详情）。
    pub fn set_mode(&mut self, mode: ProjectDialogMode, cx: &mut Context<Self>) {
        self.mode = mode;
        self.step = match mode {
            ProjectDialogMode::New => ProjectDialogStep::Source,
            ProjectDialogMode::Clone => ProjectDialogStep::Details,
        };
        self.source = NewProjectSource::Empty;
        self.query.clear();
        self.selected_index = 0;
        self.project_name.clear();
        self.repository_url.clear();
        self.location_path = default_project_location();
        self.package_manager = PackageManager::Npm;
        self.name_was_edited = false;
        self.error_message = None;
        self.active_field = match mode {
            ProjectDialogMode::New => ActiveField::Search,
            ProjectDialogMode::Clone => ActiveField::RepositoryUrl,
        };
        cx.notify();
    }

    /// 系统目录选择框；取消/失败（含无 zenity 等后端缺失）返回 `None`，
    /// 调用方一律视为取消。
    pub fn pick_folder(initial: Option<&str>) -> Option<String> {
        let mut dialog = rfd::FileDialog::new();
        if let Some(dir) = initial.map(str::trim).filter(|s| !s.is_empty()) {
            dialog = dialog.set_directory(dir);
        }
        dialog
            .pick_folder()
            .map(|path| path.to_string_lossy().to_string())
    }

    /// 移植 `getProjectNameError`：返回 i18n 键，渲染时再解析为文案。
    fn name_error_key(&self) -> Option<&'static str> {
        let name = self.project_name.trim();
        if name.is_empty() {
            return Some("newProject.errorEnterName");
        }
        if name == "." || name == ".." {
            return Some("newProject.errorPathTraversalName");
        }
        if name
            .chars()
            .any(|c| (c as u32) < 32 || RESERVED_CHARS.contains(&c))
        {
            return Some("newProject.errorReservedCharacters");
        }
        if name.ends_with('.') || name.ends_with(' ') {
            return Some("newProject.errorTrailingPeriodOrSpace");
        }
        let base = name.split('.').next().unwrap_or("").to_lowercase();
        if WINDOWS_RESERVED_NAMES.contains(&base.as_str()) {
            return Some("newProject.errorCrossPlatformName");
        }
        None
    }

    /// 移植 `inferProjectNameFromRepositoryUrl`：去尾斜杠、取末段、去 `.git`
    /// （大小写不敏感）。无 URL 解码依赖，跳过 `decodeURIComponent`。
    fn infer_name_from_url(url: &str) -> String {
        let trimmed = url.trim().trim_end_matches(['/', '\\']);
        if trimmed.is_empty() {
            return String::new();
        }
        let last = trimmed
            .rsplit(|c| c == '/' || c == ':' || c == '\\')
            .find(|segment| !segment.is_empty())
            .unwrap_or("");
        if last.len() >= 4 && last[last.len() - 4..].eq_ignore_ascii_case(".git") {
            last[..last.len() - 4].to_string()
        } else {
            last.to_string()
        }
    }

    /// 移植 `getStarterCommand`：命令字符串与 `new-project-model.ts` 逐字一致。
    fn starter_command(source: NewProjectSource, pm: PackageManager) -> Option<String> {
        match source {
            NewProjectSource::Empty => None,
            NewProjectSource::Nextjs => {
                let runner = match pm {
                    PackageManager::Npm => "npx --yes",
                    PackageManager::Pnpm => "pnpm dlx",
                    PackageManager::Bun => "bunx",
                };
                let flag = match pm {
                    PackageManager::Npm => "--use-npm",
                    PackageManager::Pnpm => "--use-pnpm",
                    PackageManager::Bun => "--use-bun",
                };
                Some(format!(
                    "{runner} create-next-app@latest . --typescript --tailwind --eslint --app --src-dir --import-alias \"@/*\" {flag}"
                ))
            }
            NewProjectSource::ViteReact => {
                let create = match pm {
                    PackageManager::Npm => "npm create vite@latest . -- --template react-ts",
                    PackageManager::Pnpm => "pnpm create vite@latest . --template react-ts",
                    PackageManager::Bun => "bun create vite@latest . --template react-ts",
                };
                let install = match pm {
                    PackageManager::Npm => "npm install",
                    PackageManager::Pnpm => "pnpm install",
                    PackageManager::Bun => "bun install",
                };
                Some(format!("{create} && {install}"))
            }
        }
    }

    /// 目标目录 = 位置 + 名称（对齐 `getNewProjectPath` 的拼接语义）。
    fn destination_path(&self) -> String {
        let base = self.location_path.trim().trim_end_matches('/');
        let name = self.project_name.trim();
        if base.is_empty() {
            return name.to_string();
        }
        format!("{base}/{name}")
    }

    /// 是否允许创建（对齐 Tauri `canCreate`）。
    fn can_create(&self) -> bool {
        if self.step != ProjectDialogStep::Details {
            return false;
        }
        if self.name_error_key().is_some() {
            return false;
        }
        if self.location_path.trim().is_empty() {
            return false;
        }
        if self.mode == ProjectDialogMode::Clone && self.repository_url.trim().is_empty() {
            return false;
        }
        true
    }

    /// 选中来源并进入详情表单。
    fn choose_source(&mut self, source: NewProjectSource, cx: &mut Context<Self>) {
        self.source = source;
        self.step = ProjectDialogStep::Details;
        self.project_name.clear();
        self.repository_url.clear();
        self.name_was_edited = false;
        self.error_message = None;
        self.active_field = ActiveField::ProjectName;
        cx.notify();
    }

    /// 从详情返回来源选择。
    fn back_to_source(&mut self, cx: &mut Context<Self>) {
        self.step = ProjectDialogStep::Source;
        self.query.clear();
        self.selected_index = 0;
        self.error_message = None;
        self.active_field = ActiveField::Search;
        cx.notify();
    }

    /// 包管理器循环切换：npm → pnpm → Bun → npm。
    fn cycle_package_manager(&mut self, cx: &mut Context<Self>) {
        self.package_manager = match self.package_manager {
            PackageManager::Npm => PackageManager::Pnpm,
            PackageManager::Pnpm => PackageManager::Bun,
            PackageManager::Bun => PackageManager::Npm,
        };
        cx.notify();
    }

    /// 用系统对话框重选父目录；取消则保持原值。
    fn choose_location(&mut self, cx: &mut Context<Self>) {
        if let Some(dir) = Self::pick_folder(Some(self.location_path.trim())) {
            self.location_path = dir;
            self.error_message = None;
            cx.notify();
        }
    }

    /// 往当前输入字段追加文本（URL 变化时自动推导名称）。
    fn push_text(&mut self, text: &str) {
        match self.active_field {
            ActiveField::Search => {
                self.query.push_str(text);
                self.selected_index = 0;
            }
            ActiveField::ProjectName => {
                self.project_name.push_str(text);
                self.name_was_edited = true;
                self.error_message = None;
            }
            ActiveField::RepositoryUrl => {
                self.repository_url.push_str(text);
                self.error_message = None;
                if !self.name_was_edited {
                    self.project_name = Self::infer_name_from_url(&self.repository_url);
                }
            }
            ActiveField::Location => {
                self.location_path.push_str(text);
                self.error_message = None;
            }
        }
    }

    /// 当前输入字段退格（URL 退格同样触发名称重推导）。
    fn pop_text(&mut self) {
        match self.active_field {
            ActiveField::Search => {
                self.query.pop();
                self.selected_index = 0;
            }
            ActiveField::ProjectName => {
                self.project_name.pop();
                self.error_message = None;
            }
            ActiveField::RepositoryUrl => {
                self.repository_url.pop();
                self.error_message = None;
                if !self.name_was_edited {
                    self.project_name = Self::infer_name_from_url(&self.repository_url);
                }
            }
            ActiveField::Location => {
                self.location_path.pop();
                self.error_message = None;
            }
        }
    }

    /// 执行创建：
    /// - Empty / 模板：目标存在即报错，否则同步建目录后发射事件
    ///   （模板附带 starter 命令，父级负责发往新终端）；
    /// - Clone：先进 Creating，再后台跑 `git clone`，成功发射事件，
    ///   失败回 Details 并显示 stderr。
    fn begin_create(&mut self, cx: &mut Context<Self>) {
        if !self.can_create() {
            return;
        }
        let dest = self.destination_path();
        if std::path::Path::new(&dest).exists() {
            let template = crate::i18n::menu_text(cx, "newProject.errorDestinationExists");
            self.error_message = Some(template.replace("{path}", &dest));
            cx.notify();
            return;
        }

        if self.mode == ProjectDialogMode::Clone {
            self.step = ProjectDialogStep::Creating;
            self.error_message = None;
            cx.notify();
            let url = self.repository_url.trim().to_string();
            let dest_for_clone = dest.clone();
            cx.spawn(async move |this, cx| {
                let output = cx
                    .background_executor()
                    .spawn(async move {
                        std::process::Command::new("git")
                            .args(["clone", url.as_str(), dest_for_clone.as_str()])
                            .output()
                    })
                    .await;
                match output {
                    Ok(result) if result.status.success() => {
                        let _ = this.update(cx, |_this, cx| {
                            cx.emit(ProjectDialogEvent::OpenedProject {
                                path: dest,
                                starter: None,
                            });
                        });
                    }
                    Ok(result) => {
                        let stderr = String::from_utf8_lossy(&result.stderr).trim().to_string();
                        let message = if stderr.is_empty() {
                            format!("git clone failed: {}", result.status)
                        } else {
                            stderr
                        };
                        let _ = this.update(cx, |this, cx| {
                            this.step = ProjectDialogStep::Details;
                            this.error_message = Some(message);
                            cx.notify();
                        });
                    }
                    Err(err) => {
                        let message = format!("git clone failed: {err}");
                        let _ = this.update(cx, |this, cx| {
                            this.step = ProjectDialogStep::Details;
                            this.error_message = Some(message);
                            cx.notify();
                        });
                    }
                }
            })
            .detach();
            return;
        }

        match std::fs::create_dir_all(&dest) {
            Ok(()) => {
                let starter = Self::starter_command(self.source, self.package_manager);
                cx.emit(ProjectDialogEvent::OpenedProject {
                    path: dest,
                    starter,
                });
            }
            Err(err) => {
                self.error_message = Some(err.to_string());
                cx.notify();
            }
        }
    }

    /// New 模式来源选择项（Clone 不在列表中）。
    fn filtered_ids(&self, cx: &gpui_kit::App) -> Vec<NewProjectSource> {
        let query = self.query.trim().to_lowercase();
        const ALL: [NewProjectSource; 3] = [
            NewProjectSource::Empty,
            NewProjectSource::Nextjs,
            NewProjectSource::ViteReact,
        ];
        if query.is_empty() {
            return ALL.to_vec();
        }
        ALL.into_iter()
            .filter(|source| {
                let label = source.label(cx).to_lowercase();
                let desc = crate::i18n::menu_text(cx, source.description_key()).to_lowercase();
                label.contains(query.as_str())
                    || desc.contains(query.as_str())
                    || source
                        .keywords()
                        .iter()
                        .any(|kw| kw.contains(query.as_str()))
            })
            .collect()
    }
}

impl NewProjectSource {
    /// 来源图标。
    fn icon(self) -> IconName {
        match self {
            NewProjectSource::Empty => IconName::Folder,
            NewProjectSource::Nextjs => IconName::Package,
            NewProjectSource::ViteReact => IconName::Code,
        }
    }

    /// 来源标题：Empty 走 i18n，模板用固定英文产品名。
    fn label(self, cx: &gpui_kit::App) -> String {
        match self {
            NewProjectSource::Empty => {
                crate::i18n::menu_text(cx, "welcome.emptyProject").to_string()
            }
            NewProjectSource::Nextjs => "Next.js".to_string(),
            NewProjectSource::ViteReact => "Vite + React".to_string(),
        }
    }

    /// 来源描述 i18n 键。
    fn description_key(self) -> &'static str {
        match self {
            NewProjectSource::Empty => "welcome.emptyProjectDescription",
            NewProjectSource::Nextjs => "welcome.nextjsDescription",
            NewProjectSource::ViteReact => "welcome.viteReactDescription",
        }
    }

    /// 来源徽标 i18n 键。
    fn badge_key(self) -> &'static str {
        match self {
            NewProjectSource::Empty => "welcome.builtIn",
            NewProjectSource::Nextjs | NewProjectSource::ViteReact => "welcome.webApp",
        }
    }

    /// 搜索关键词（与 Tauri `keywords` 一致）。
    fn keywords(self) -> &'static [&'static str] {
        match self {
            NewProjectSource::Empty => &["blank", "folder", "local", "empty"],
            NewProjectSource::Nextjs => &["react", "typescript", "tailwind", "frontend"],
            NewProjectSource::ViteReact => &["react", "typescript", "frontend"],
        }
    }
}

impl Render for ProjectDialog {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 请求聚焦以接收按键输入（与 quick_open 相同）。
        window.focus(&self.focus_handle, cx);

        let is_creating = self.step == ProjectDialogStep::Creating;
        let is_clone = self.mode == ProjectDialogMode::Clone;

        // 全屏半透明遮罩：创建中禁用关闭，点击空白处关闭。
        div()
            .id("project-dialog-backdrop")
            .track_focus(&self.focus_handle)
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                if this.step == ProjectDialogStep::Creating {
                    return;
                }
                let key = event.keystroke.key.as_str();
                match key {
                    "escape" => match (this.mode, this.step) {
                        (ProjectDialogMode::New, ProjectDialogStep::Details) => {
                            this.back_to_source(cx);
                        }
                        _ => cx.emit(ProjectDialogEvent::Close),
                    },
                    "enter" => match this.step {
                        ProjectDialogStep::Source => {
                            let ids = this.filtered_ids(cx);
                            let index = this.selected_index.min(ids.len().saturating_sub(1));
                            if let Some(id) = ids.get(index).copied() {
                                this.choose_source(id, cx);
                            }
                        }
                        ProjectDialogStep::Details => this.begin_create(cx),
                        ProjectDialogStep::Creating => {}
                    },
                    "up" | "arrowup" => {
                        if this.step == ProjectDialogStep::Source {
                            let total = this.filtered_ids(cx).len();
                            if total > 0 {
                                this.selected_index = (this.selected_index + total - 1) % total;
                                cx.notify();
                            }
                        }
                    }
                    "down" | "arrowdown" => {
                        if this.step == ProjectDialogStep::Source {
                            let total = this.filtered_ids(cx).len();
                            if total > 0 {
                                this.selected_index = (this.selected_index + 1) % total;
                                cx.notify();
                            }
                        }
                    }
                    "backspace" => {
                        // 来源选择页的退格改搜索串，其余页改当前字段。
                        if this.step == ProjectDialogStep::Source {
                            this.active_field = ActiveField::Search;
                        }
                        this.pop_text();
                        cx.notify();
                    }
                    "space" => {
                        if this.step == ProjectDialogStep::Source {
                            this.active_field = ActiveField::Search;
                        }
                        this.push_text(" ");
                        cx.notify();
                    }
                    _ => {
                        // 无修饰键时把可打印字符追加到当前字段。
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            let mut changed = false;
                            if let Some(ch) = &event.keystroke.key_char {
                                if this.step == ProjectDialogStep::Source {
                                    this.active_field = ActiveField::Search;
                                }
                                this.push_text(ch);
                                changed = true;
                            } else if key.chars().count() == 1 {
                                if this.step == ProjectDialogStep::Source {
                                    this.active_field = ActiveField::Search;
                                }
                                this.push_text(key);
                                changed = true;
                            }
                            if changed {
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|this, _event, _window, cx| {
                    if this.step != ProjectDialogStep::Creating {
                        cx.emit(ProjectDialogEvent::Close);
                    }
                }),
            )
            .child(
                v_flex()
                    .id("project-dialog-card")
                    .w(px(560.0))
                    .h(px(480.0))
                    .bg(crate::theme::ThemeColors::surface())
                    .border_1()
                    .border_color(crate::theme::ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            // 卡片内点击不冒泡到遮罩，避免误关闭。
                            cx.stop_propagation();
                        }),
                    )
                    .child(self.render_header(is_clone, is_creating, cx))
                    .child(match self.step {
                        ProjectDialogStep::Source => self.render_source_body(cx).into_any_element(),
                        ProjectDialogStep::Details => {
                            self.render_details_body(is_clone, cx).into_any_element()
                        }
                        ProjectDialogStep::Creating => {
                            self.render_creating_body(is_clone, cx).into_any_element()
                        }
                    })
                    .when(self.step == ProjectDialogStep::Details, |card| {
                        card.child(self.render_footer(is_clone, cx))
                    }),
            )
    }
}

/// 头部 / 各步骤主体 / 底部渲染。
impl ProjectDialog {
    /// 头部：返回按钮 + 图标标题 + 关闭按钮（创建中隐藏可关闭项）。
    fn render_header(
        &self,
        is_clone: bool,
        is_creating: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let (icon, title) = if is_creating {
            (
                if is_clone {
                    IconName::GitBranch
                } else {
                    self.source.icon()
                },
                crate::i18n::menu_text(
                    cx,
                    if is_clone {
                        "newProject.cloningRepository"
                    } else {
                        "newProject.creatingProject"
                    },
                )
                .to_string(),
            )
        } else {
            match (self.mode, self.step) {
                (ProjectDialogMode::New, ProjectDialogStep::Source) => (
                    IconName::Folder,
                    crate::i18n::menu_text(cx, "welcome.newProject").to_string(),
                ),
                (_, ProjectDialogStep::Details) if is_clone => (
                    IconName::GitBranch,
                    crate::i18n::menu_text(cx, "welcome.cloneRepository").to_string(),
                ),
                _ => (self.source.icon(), self.source.label(cx)),
            }
        };
        // 返回行为：来源页/Clone 详情关闭对话框，New 详情返回来源页。
        let (back_tooltip, back_to_source) = match (self.mode, self.step) {
            (ProjectDialogMode::New, ProjectDialogStep::Details) => (
                crate::i18n::menu_text(cx, "newProject.backToStarters").to_string(),
                true,
            ),
            _ => (
                crate::i18n::menu_text(cx, "welcome.backToProjects").to_string(),
                false,
            ),
        };

        h_flex()
            .h(px(44.0))
            .w_full()
            .items_center()
            .gap_2()
            .px_3()
            .border_b_1()
            .border_color(crate::theme::ThemeColors::border())
            .bg(crate::theme::ThemeColors::surface())
            .when(!is_creating, |header| {
                header.child(
                    Button::new("project-dialog-header-back")
                        .small()
                        .ghost()
                        .icon(IconName::ArrowLeft)
                        .tooltip(back_tooltip)
                        .on_click(cx.listener(move |this, _event, _window, cx| {
                            if back_to_source {
                                this.back_to_source(cx);
                            } else {
                                cx.emit(ProjectDialogEvent::Close);
                            }
                        })),
                )
            })
            .child(
                Icon::new(icon)
                    .size(px(16.0))
                    .text_color(crate::theme::ThemeColors::primary()),
            )
            .child(
                div()
                    .flex_1()
                    .truncate()
                    .text_sm()
                    .font_weight(FontWeight::BOLD)
                    .text_color(crate::theme::ThemeColors::foreground())
                    .child(title),
            )
            .when(!is_creating, |header| {
                header.child(
                    Button::new("project-dialog-close")
                        .small()
                        .ghost()
                        .icon(IconName::Close)
                        .tooltip(crate::i18n::menu_text(cx, "ui.close"))
                        .on_click(cx.listener(|_this, _event, _window, cx| {
                            cx.emit(ProjectDialogEvent::Close);
                        })),
                )
            })
    }

    /// 来源选择主体：搜索行 + 来源行列表（空态显示 `noStarters`）。
    fn render_source_body(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let ids = self.filtered_ids(cx);
        let current = self.selected_index.min(ids.len().saturating_sub(1));
        let query = self.query.clone();
        let placeholder = crate::i18n::menu_text(cx, "welcome.chooseHowToStart").to_string();

        v_flex()
            .flex_1()
            .w_full()
            .min_h_0()
            .overflow_hidden()
            .child(
                h_flex()
                    .id("project-dialog-search")
                    .h(px(44.0))
                    .w_full()
                    .flex_shrink_0()
                    .items_center()
                    .gap_2p5()
                    .px_4()
                    .border_b_1()
                    .border_color(crate::theme::ThemeColors::border())
                    .cursor_pointer()
                    .child(
                        Icon::new(IconName::Search)
                            .size(px(15.0))
                            .text_color(crate::theme::ThemeColors::primary()),
                    )
                    .child(
                        h_flex()
                            .flex_1()
                            .items_center()
                            .gap_1()
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(if query.is_empty() {
                                        crate::theme::ThemeColors::subtle_foreground()
                                    } else {
                                        crate::theme::ThemeColors::foreground()
                                    })
                                    .child(if query.is_empty() {
                                        placeholder
                                    } else {
                                        query.clone()
                                    }),
                            )
                            .child(
                                div()
                                    .w(px(2.0))
                                    .h(px(16.0))
                                    .bg(crate::theme::ThemeColors::primary()),
                            ),
                    )
                    .on_click(cx.listener(|this, _event, window, cx| {
                        this.active_field = ActiveField::Search;
                        window.focus(&this.focus_handle, cx);
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .flex_1()
                    .w_full()
                    .overflow_y_scrollbar()
                    .py_1()
                    .when(ids.is_empty(), |list| {
                        let empty = crate::i18n::menu_text(cx, "welcome.noStarters")
                            .replace("{query}", &self.query);
                        list.child(
                            div()
                                .w_full()
                                .py_8()
                                .text_center()
                                .text_sm()
                                .text_color(crate::theme::ThemeColors::subtle_foreground())
                                .child(empty),
                        )
                    })
                    .children(ids.into_iter().enumerate().map(|(position, id)| {
                        let is_selected = position == current;
                        let label = id.label(cx);
                        let description =
                            crate::i18n::menu_text(cx, id.description_key()).to_string();
                        let badge = crate::i18n::menu_text(cx, id.badge_key()).to_string();
                        let icon = id.icon();
                        h_flex()
                            .id(("project-dialog-source", position))
                            .h(px(52.0))
                            .w_full()
                            .mx_2()
                            .px_2p5()
                            .items_center()
                            .gap_2p5()
                            .rounded_md()
                            .cursor_pointer()
                            .when(is_selected, |row| {
                                row.bg(crate::theme::ThemeColors::selected())
                            })
                            .when(!is_selected, |row| {
                                row.hover(|h| h.bg(crate::theme::ThemeColors::accent()))
                            })
                            .child(Icon::new(icon).size(px(16.0)).text_color(if is_selected {
                                crate::theme::ThemeColors::primary()
                            } else {
                                crate::theme::ThemeColors::muted_foreground()
                            }))
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .child(
                                        div()
                                            .text_sm()
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_color(crate::theme::ThemeColors::foreground())
                                            .child(label),
                                    )
                                    .child(
                                        div()
                                            .truncate()
                                            .text_xs()
                                            .text_color(
                                                crate::theme::ThemeColors::subtle_foreground(),
                                            )
                                            .child(description),
                                    ),
                            )
                            .child(source_badge(badge))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.choose_source(id, cx);
                            }))
                            .into_any_element()
                    })),
            )
    }

    /// 详情表单主体：URL（仅 Clone）+ 名称 + 位置 + 包管理器 + 目标预览 + 错误。
    fn render_details_body(&self, is_clone: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let name_error = self
            .name_error_key()
            .filter(|_| !self.project_name.is_empty())
            .map(|key| crate::i18n::menu_text(cx, key).to_string());
        let dest = self.destination_path();
        let show_dest = !self.location_path.trim().is_empty();
        let error = self.error_message.clone();
        let is_template = !is_clone && !matches!(self.source, NewProjectSource::Empty);

        div()
            .flex_1()
            .w_full()
            .min_h_0()
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .w_full()
                    .gap_3()
                    .p_4()
                    .when(is_clone, |body| {
                        body.child(
                            self.render_text_field(
                                "project-dialog-field-url",
                                crate::i18n::menu_text(cx, "newProject.repositoryUrl").to_string(),
                                self.repository_url.clone(),
                                "https://github.com/owner/repository.git".to_string(),
                                Some(
                                    crate::i18n::menu_text(
                                        cx,
                                        "newProject.repositoryUrlDescription",
                                    )
                                    .to_string(),
                                ),
                                None,
                                ActiveField::RepositoryUrl,
                                cx,
                            ),
                        )
                    })
                    .child(self.render_text_field(
                        "project-dialog-field-name",
                        crate::i18n::menu_text(cx, "newProject.projectName").to_string(),
                        self.project_name.clone(),
                        if is_clone {
                            "repository".to_string()
                        } else {
                            "my-project".to_string()
                        },
                        None,
                        name_error,
                        ActiveField::ProjectName,
                        cx,
                    ))
                    .child(self.render_location_row(cx))
                    .when(is_template, |body| {
                        body.child(self.render_package_manager_row(cx))
                    })
                    .when(show_dest, |body| {
                        body.child(
                            v_flex()
                                .w_full()
                                .rounded_md()
                                .border_1()
                                .border_color(crate::theme::ThemeColors::border())
                                .bg(crate::theme::ThemeColors::surface())
                                .overflow_hidden()
                                .child(
                                    div()
                                        .px_3()
                                        .py_2()
                                        .border_b_1()
                                        .border_color(crate::theme::ThemeColors::border())
                                        .text_xs()
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(crate::theme::ThemeColors::subtle_foreground())
                                        .child(
                                            crate::i18n::menu_text(
                                                cx,
                                                "newProject.projectLocation",
                                            )
                                            .to_string(),
                                        ),
                                )
                                .child(
                                    div()
                                        .px_3()
                                        .py_2()
                                        .font_family("monospace")
                                        .text_xs()
                                        .text_color(crate::theme::ThemeColors::foreground())
                                        .child(dest),
                                ),
                        )
                    })
                    .when_some(error, |body, message| {
                        body.child(
                            div()
                                .text_xs()
                                .text_color(crate::theme::ThemeColors::accent_red())
                                .child(message),
                        )
                    }),
            )
    }

    /// 单行文本字段：标签 + 只读展示行（点击聚焦）+ 描述/错误。
    #[allow(clippy::too_many_arguments)]
    fn render_text_field(
        &self,
        id: &'static str,
        label: String,
        value: String,
        placeholder: String,
        description: Option<String>,
        error: Option<String>,
        field: ActiveField,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let is_active = self.active_field == field;
        v_flex()
            .w_full()
            .gap_1p5()
            .child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(crate::theme::ThemeColors::foreground())
                    .child(label),
            )
            .child(
                h_flex()
                    .id(id)
                    .min_h(px(32.0))
                    .w_full()
                    .items_center()
                    .gap_1()
                    .px_2p5()
                    .py_1p5()
                    .rounded_sm()
                    .border_1()
                    .cursor_pointer()
                    .when(is_active, |row| {
                        row.border_color(crate::theme::ThemeColors::primary())
                            .bg(crate::theme::ThemeColors::background())
                    })
                    .when(!is_active, |row| {
                        row.border_color(crate::theme::ThemeColors::border())
                            .bg(crate::theme::ThemeColors::background())
                            .hover(|h| {
                                h.border_color(crate::theme::ThemeColors::muted_foreground())
                            })
                    })
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .text_sm()
                            .text_color(if value.is_empty() {
                                crate::theme::ThemeColors::subtle_foreground()
                            } else {
                                crate::theme::ThemeColors::foreground()
                            })
                            .child(if value.is_empty() { placeholder } else { value }),
                    )
                    .when(is_active, |row| {
                        row.child(
                            div()
                                .w(px(2.0))
                                .h(px(16.0))
                                .bg(crate::theme::ThemeColors::primary()),
                        )
                    })
                    .on_click(cx.listener(move |this, _event, window, cx| {
                        this.active_field = field;
                        window.focus(&this.focus_handle, cx);
                        cx.notify();
                    })),
            )
            .when_some(description, |this, desc| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(crate::theme::ThemeColors::subtle_foreground())
                        .child(desc),
                )
            })
            .when_some(error, |this, message| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(crate::theme::ThemeColors::accent_red())
                        .child(message),
                )
            })
    }

    /// 位置行：路径展示 + 选择父目录按钮。
    fn render_location_row(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let is_active = self.active_field == ActiveField::Location;
        let value = self.location_path.clone();
        let placeholder = crate::i18n::menu_text(cx, "newProject.chooseParentFolder").to_string();
        v_flex()
            .w_full()
            .gap_1p5()
            .child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(crate::theme::ThemeColors::foreground())
                    .child(crate::i18n::menu_text(cx, "newProject.location").to_string()),
            )
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap_2()
                    .child(
                        h_flex()
                            .id("project-dialog-field-location")
                            .flex_1()
                            .min_w_0()
                            .min_h(px(32.0))
                            .items_center()
                            .px_2p5()
                            .py_1p5()
                            .rounded_sm()
                            .border_1()
                            .cursor_pointer()
                            .font_family("monospace")
                            .when(is_active, |row| {
                                row.border_color(crate::theme::ThemeColors::primary())
                                    .bg(crate::theme::ThemeColors::background())
                            })
                            .when(!is_active, |row| {
                                row.border_color(crate::theme::ThemeColors::border())
                                .bg(crate::theme::ThemeColors::background())
                                .hover(|h| {
                                    h.border_color(crate::theme::ThemeColors::muted_foreground())
                                })
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .truncate()
                                    .text_sm()
                                    .text_color(if value.is_empty() {
                                        crate::theme::ThemeColors::subtle_foreground()
                                    } else {
                                        crate::theme::ThemeColors::foreground()
                                    })
                                    .child(if value.is_empty() { placeholder } else { value }),
                            )
                            .on_click(cx.listener(|this, _event, window, cx| {
                                this.active_field = ActiveField::Location;
                                window.focus(&this.focus_handle, cx);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("project-dialog-browse")
                            .small()
                            .ghost()
                            .icon(IconName::FolderOpen)
                            .label(crate::i18n::menu_text(cx, "newProject.chooseParentFolder"))
                            .tooltip(
                                crate::i18n::menu_text(cx, "newProject.chooseProjectLocation")
                                    .to_string(),
                            )
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.choose_location(cx);
                            })),
                    ),
            )
    }

    /// 包管理器行：标签 + 描述 + 循环切换按钮（仅模板来源）。
    fn render_package_manager_row(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .w_full()
            .gap_1p5()
            .child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(crate::theme::ThemeColors::foreground())
                    .child(crate::i18n::menu_text(cx, "newProject.packageManager").to_string()),
            )
            .child(
                h_flex()
                    .w_full()
                    .min_h(px(32.0))
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .text_xs()
                            .text_color(crate::theme::ThemeColors::subtle_foreground())
                            .child(
                                crate::i18n::menu_text(cx, "newProject.packageManagerDescription")
                                    .to_string(),
                            ),
                    )
                    .child(
                        Button::new("project-dialog-pm")
                            .small()
                            .ghost()
                            .label(self.package_manager.label())
                            .tooltip(
                                crate::i18n::menu_text(cx, "newProject.packageManager").to_string(),
                            )
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.cycle_package_manager(cx);
                            })),
                    ),
            )
    }

    /// 创建中主体：进度文案 + 目标路径（禁用关闭）。
    fn render_creating_body(&self, is_clone: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let status = crate::i18n::menu_text(
            cx,
            if is_clone {
                "newProject.cloningRepositoryStatus"
            } else {
                "newProject.preparingProject"
            },
        )
        .to_string();
        v_flex()
            .flex_1()
            .w_full()
            .items_center()
            .justify_center()
            .gap_2()
            .p_6()
            .child(
                div()
                    .text_sm()
                    .text_color(crate::theme::ThemeColors::foreground())
                    .child(format!("{status}...")),
            )
            .child(
                div()
                    .w_full()
                    .text_center()
                    .truncate()
                    .font_family("monospace")
                    .text_xs()
                    .text_color(crate::theme::ThemeColors::subtle_foreground())
                    .child(self.destination_path()),
            )
    }

    /// 底部：返回 + 创建/克隆按钮（Clone 模式无返回）。
    fn render_footer(&self, is_clone: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let can_create = self.can_create();
        let create_label = if is_clone {
            crate::i18n::menu_text(cx, "welcome.cloneRepository").to_string()
        } else {
            match self.source {
                NewProjectSource::Empty => {
                    crate::i18n::menu_text(cx, "welcome.emptyProject").to_string()
                }
                _ => crate::i18n::menu_text(cx, "welcome.newProject").to_string(),
            }
        };
        let create_icon = if is_clone {
            IconName::GitBranch
        } else {
            match self.source {
                NewProjectSource::Empty => IconName::FilePlus,
                _ => IconName::Package,
            }
        };

        h_flex()
            .h(px(44.0))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap_2()
            .px_3()
            .border_t_1()
            .border_color(crate::theme::ThemeColors::border())
            .bg(crate::theme::ThemeColors::surface())
            .when(!is_clone, |footer| {
                footer.child(
                    Button::new("project-dialog-back")
                        .small()
                        .ghost()
                        .icon(IconName::ArrowLeft)
                        .label(crate::i18n::menu_text(cx, "newProject.backToStarters"))
                        .on_click(cx.listener(|this, _event, _window, cx| {
                            this.back_to_source(cx);
                        })),
                )
            })
            .child(div().flex_1())
            .child(
                Button::new("project-dialog-create")
                    .small()
                    .primary()
                    .icon(create_icon)
                    .label(create_label)
                    .disabled(!can_create)
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.begin_create(cx);
                    })),
            )
    }
}

/// 新建/克隆项目的默认位置：用户主目录，取不到时返回空串（由表单校验提示）。
fn default_project_location() -> String {
    crate::settings::user_home_dir()
        .map(|home| home.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// 来源徽标（对齐 quick_open 的徽标样式）。
fn source_badge(label: String) -> AnyElement {
    div()
        .px_1p5()
        .py(px(1.0))
        .rounded_sm()
        .bg(crate::theme::ThemeColors::accent())
        .border_1()
        .border_color(crate::theme::ThemeColors::border())
        .text_xs()
        .text_color(crate::theme::ThemeColors::muted_foreground())
        .child(label)
        .into_any_element()
}
