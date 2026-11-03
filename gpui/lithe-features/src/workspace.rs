//! 项目树。
//!
//! 交互对齐 macOS `ProjectSidebarView`：27pt 行高、19pt 缩进、16pt 图标，
//! 选中态是蓝底白字，悬停是 `tokens.hover`。目录展开时才向 Core 请求一层
//! 子项，避免一次性扫描整棵工作区。
//!
//! # 路径身份
//!
//! 树节点的身份统一使用 Core 的**工作区相对路径**：根目录是空字符串 `""`，
//! 子项用 `/` 分隔。`expanded`、`loaded`、`loading` 都以这个字符串为键；
//! 点击文件时才与 `root` 拼接成绝对路径交给 `on_open_file`。这样即使多个
//! 工作区里出现同名文件，也不会在模型中互相覆盖。
//!
//! # 异步
//!
//! `CoreClient::list_directories` 是阻塞 API。每次展开都会通过
//! `cx.spawn` + `cx.background_spawn` 把磁盘扫描放到后台，再把结果合并回
//! 视图。`generation` 用来丢弃 `set_root` 之前仍在飞行中的旧结果，防止旧
//! 工作区的子项污染新工作区。
//!
//! # 文件操作
//!
//! 右键目录/文件行打开自绘上下文菜单（新建、复制路径、在文件管理器中显示、
//! 重命名、移到回收站、刷新）；新建和重命名使用面板内的模态输入覆盖层，
//! 删除先弹确认覆盖层并**移到系统回收站**，只有回收站失败后才提供一次显式
//! 的永久删除。所有磁盘 I/O（含路径安全校验里的 `canonicalize`）都在
//! `cx.background_spawn` 里执行，结果回到视图线程后才修改状态。构造期不创建
//! `InputState`、不 spawn；输入框和首帧初始化都通过 `Render` 里的 `defer_in`
//! 排到当前借用释放之后。
//!
//! 目标路径统一按 `root.join(relative)` 计算，并对**父目录**做
//! `canonicalize`，要求它仍在规范化后的工作区根内；空名称、绝对路径和
//! `..` 段一律拒绝。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, Context, Entity, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, MouseButton, MouseDownEvent, ParentElement,
    Pixels, Point, Render, SharedString, StatefulInteractiveElement as _, Styled, Subscription,
    Window, anchored, deferred, div, px, white,
};
use lithe_core_client::{CoreClient, WorkspaceNode};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, current_tokens, icon};

/// 防御性上限：损坏或环状的树数据不能让渲染栈无限递归。
const MAX_TREE_DEPTH: usize = 64;

/// 右键菜单宽度。
const CONTEXT_MENU_WIDTH: f32 = 180.0;
/// 右键菜单项高度。
const CONTEXT_MENU_ITEM_HEIGHT: f32 = 28.0;
/// 新建 / 重命名覆盖层宽度。
const NAME_DIALOG_WIDTH: f32 = 420.0;
/// 删除确认覆盖层宽度。
const DELETE_DIALOG_WIDTH: f32 = 420.0;

type OpenFileHandler = Rc<dyn Fn(PathBuf, &mut Window, &mut App) + 'static>;

/// 把树行的工作区相对路径拼成 `on_open_file` 回调要求的绝对路径。
///
/// 单独拆出来是为了让「点击文件回传绝对路径」这个契约可以被测试固定：
/// 回调方（工作台）按绝对路径做标签身份与历史记录，拼错就会打开错误文件。
fn absolute_from_relative(root: &Path, relative: &str) -> PathBuf {
    root.join(relative)
}

/// 「Copy Path」写进剪贴板的文本。
fn absolute_copy_text(root: &Path, relative: &str) -> String {
    absolute_from_relative(root, relative).display().to_string()
}

/// 「Copy Relative Path」写进剪贴板的文本。
///
/// 树节点的相对路径本身就是 `/` 分隔；工作区根没有相对路径，按 macOS
/// `copyProjectItemPath` 的约定写成 `.`，避免复制出空字符串。
fn relative_copy_text(relative: &str) -> String {
    if relative.is_empty() {
        ".".to_string()
    } else {
        relative.to_string()
    }
}

/// 右键菜单里的一项。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MenuAction {
    NewFile,
    NewFolder,
    CopyPath,
    CopyRelativePath,
    Reveal,
    Rename,
    MoveToTrash,
    Refresh,
}

impl MenuAction {
    /// 菜单项的 ElementId 后缀，重复渲染时保持稳定。
    fn id(self) -> &'static str {
        match self {
            MenuAction::NewFile => "new-file",
            MenuAction::NewFolder => "new-folder",
            MenuAction::CopyPath => "copy-path",
            MenuAction::CopyRelativePath => "copy-relative-path",
            MenuAction::Reveal => "reveal",
            MenuAction::Rename => "rename",
            MenuAction::MoveToTrash => "move-to-trash",
            MenuAction::Refresh => "refresh",
        }
    }
}

/// 「在文件管理器中显示」的平台文案：macOS 对齐 Finder，其余平台对齐资源管理器。
fn reveal_label() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        tr("Show in Finder")
    }
    #[cfg(not(target_os = "macos"))]
    {
        tr("Reveal in File Explorer")
    }
}

/// 右键菜单的锚点与目标行。
#[derive(Clone)]
struct ContextMenu {
    /// 目标行的工作区相对路径；根目录为空字符串。
    path: String,
    /// 目标行显示名，重命名时预填。
    name: String,
    is_directory: bool,
    /// 触发右键时的窗口坐标；`anchored` 按窗口坐标定位。
    position: Point<Pixels>,
}

/// 输入覆盖层的用途。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NameDialogKind {
    NewFile,
    NewFolder,
    Rename,
}

impl NameDialogKind {
    fn title(self) -> &'static str {
        match self {
            NameDialogKind::NewFile => tr("New File"),
            NameDialogKind::NewFolder => tr("New Folder"),
            NameDialogKind::Rename => tr("Rename"),
        }
    }

    fn submit_label(self) -> &'static str {
        match self {
            NameDialogKind::NewFile | NameDialogKind::NewFolder => tr("Create"),
            NameDialogKind::Rename => tr("Rename"),
        }
    }
}

/// 新建 / 重命名输入覆盖层。
struct NameDialog {
    kind: NameDialogKind,
    /// 新建目标或重命名所在目录（工作区相对路径，根为 `""`）。
    directory: String,
    /// 重命名时的源路径；新建时为空。
    target: Option<String>,
    /// 重命名预填的当前名称。
    initial: String,
    /// 重命名目标是否为目录；决定成功后清理哪段缓存。
    target_is_directory: bool,
    /// `InputState::new` 需要 `Window`，因此首次 `Render` 时才创建。
    input: Option<Entity<InputState>>,
    /// 输入事件订阅必须与对话框同生命周期。
    _subscription: Option<Subscription>,
    /// 输入框或路径校验错误；文件系统错误也会写到这里。
    error: Option<SharedString>,
    /// 输入框创建后是否还需要聚焦并全选。
    pending_focus: bool,
}

/// 删除（移到回收站）确认覆盖层状态。
#[derive(Clone)]
struct TrashRequest {
    /// 要删除的工作区相对路径；根目录不允许删除。
    path: String,
    is_directory: bool,
    /// 上一次移到回收站失败的原因；成功前覆盖层保持打开。
    error: Option<SharedString>,
    /// 回收站不可用（平台不支持 / 权限失败等）时是否允许用户显式永久删除。
    ///
    /// 只有一次真实的“移到回收站”失败后才会置位；「文件已不存在」这类非破坏
    /// 性失败不置位。永久删除必须由用户在详情里再点一次，绝不能在回收站失败
    /// 后自动执行。
    permanent_delete_available: bool,
}

/// 一次实际执行的磁盘操作。只携带所有权数据，便于移动到后台执行器。
enum FileOperation {
    CreateFile {
        relative: String,
    },
    CreateFolder {
        relative: String,
    },
    Rename {
        from: String,
        to: String,
    },
    /// 移到系统回收站；失败时上层显示原因，并让用户显式决定是否永久删除。
    MoveToTrash {
        relative: String,
    },
    /// 永久删除。只作为回收站不可用时的显式回退，不能由菜单直接触发。
    DeletePermanently {
        relative: String,
        is_directory: bool,
    },
}

impl FileOperation {
    /// 在后台执行操作。所有路径安全校验都在这里完成，因为
    /// `canonicalize` 本身也是磁盘 I/O。
    fn execute(self, root: PathBuf) -> Result<(), String> {
        let canonical_root = std::fs::canonicalize(&root).map_err(|error| error.to_string())?;
        match self {
            FileOperation::CreateFile { relative } => {
                let target = checked_target(&canonical_root, &relative)?;
                // `create_new` 拒绝覆盖已有文件：重名时让用户改名字，而不是
                // 静默清空同名的旧文件。
                std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&target)
                    .map(|_| ())
                    .map_err(|error| error.to_string())
            }
            FileOperation::CreateFolder { relative } => {
                let target = checked_target(&canonical_root, &relative)?;
                std::fs::create_dir(&target).map_err(|error| error.to_string())
            }
            FileOperation::Rename { from, to } => {
                let source = checked_target(&canonical_root, &from)?;
                let target = checked_target(&canonical_root, &to)?;
                if !source.exists() {
                    return Err(tr("File no longer exists").to_string());
                }
                // Windows 的 rename 遇到已存在的目标会失败，Unix 则会静默
                // 覆盖。这里统一先拒绝，避免跨平台行为不一致造成数据丢失。
                if target.exists() && source != target {
                    return Err(tr("A file with this name already exists").to_string());
                }
                std::fs::rename(&source, &target).map_err(|error| error.to_string())
            }
            FileOperation::MoveToTrash { relative } => {
                let target = checked_target(&canonical_root, &relative)?;
                if !target.exists() {
                    return Err(tr("File no longer exists").to_string());
                }
                // 三端回收站逻辑收敛在平台层；这里只透出失败原因。
                lithe_platform::current().move_to_trash(&target)
            }
            FileOperation::DeletePermanently {
                relative,
                is_directory,
            } => {
                let target = checked_target(&canonical_root, &relative)?;
                if is_directory {
                    std::fs::remove_dir_all(&target).map_err(|error| error.to_string())
                } else {
                    std::fs::remove_file(&target).map_err(|error| error.to_string())
                }
            }
        }
    }
}

/// 工作区项目树。
pub struct ProjectTree {
    client: CoreClient,
    root: Option<PathBuf>,
    /// 已展开的目录（工作区相对路径，根为 `""`）。
    expanded: HashSet<String>,
    /// 已加载的目录 -> 直接子项缓存。未命中的目录首次展开时才请求 Core。
    loaded: HashMap<String, Vec<WorkspaceNode>>,
    /// 正在请求中的目录，避免重复点击触发并发请求。
    loading: HashSet<String>,
    /// 本次加载返回前又被要求刷新的目录；结果回来后补一次请求。
    refresh_after_load: HashSet<String>,
    /// 当前选中的行（仍使用工作区相对路径）。
    selected: Option<String>,
    /// 当前编辑器打开的文件（工作区相对路径）；行高亮并自动展开定位，
    /// 对齐 Tauri 文件树的 active 行。
    active_file: Option<String>,
    /// 一行状态文本；错误不会 panic，也不会清空已加载的树。
    error: Option<SharedString>,
    /// `set_root` 时递增，用于丢弃旧根目录的异步结果。
    generation: u64,
    /// 隐藏目录名 / 文件名模式（设置页注入；支持精确名与 `*` 通配）。
    hidden_directory_patterns: Vec<String>,
    hidden_file_patterns: Vec<String>,
    /// 是否显示隐藏文件（名字以 `.` 开头的条目）。
    ///
    /// 对齐 Tauri `showHiddenFilesInFileTree`（默认显示）。行投影时过滤，
    /// 不触碰目录缓存，切换后下一次渲染立即生效。
    show_dotfiles: bool,
    /// 首次渲染时再发起根目录加载。
    ///
    /// 不能在 `new` 里 `cx.spawn`：实体构造发生在 `App::run` 的可变借用内，
    /// 异步上下文再借 App 会触发 `RefCell already borrowed` panic。构造时只
    /// 记下待加载状态，等首帧渲染用 `defer_in` 排到当前借用释放之后。
    pending_initial_load: bool,
    /// 当前打开的右键菜单。
    menu: Option<ContextMenu>,
    /// 当前打开的新建 / 重命名覆盖层。
    dialog: Option<NameDialog>,
    /// 当前打开的删除（移到回收站）确认覆盖层。
    pending_delete: Option<TrashRequest>,
    /// 文件操作进行中；阻止菜单项和确认按钮重复触发。
    busy: bool,
    /// 菜单与删除确认的键盘焦点；Escape 关闭。构造期创建不需要 Window。
    overlay_focus: FocusHandle,
    on_open_file: Option<OpenFileHandler>,
}

/// 渲染用的扁平行。只复制展示需要的字段，避免在 render 期间持有树的借用。
struct TreeRow {
    path: String,
    name: String,
    is_directory: bool,
    depth: usize,
    expanded: bool,
    is_active: bool,
}

impl ProjectTree {
    pub fn new(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self {
        // 空路径表示“还没有打开项目”，不是当前目录。否则启动时会拿空根
        // 去请求 Core，用户还没选项目就先看到一条错误。
        let root = if root.as_os_str().is_empty() {
            None
        } else {
            Some(root)
        };
        let has_root = root.is_some();
        let mut this = Self {
            client,
            root,
            expanded: HashSet::new(),
            loaded: HashMap::new(),
            loading: HashSet::new(),
            refresh_after_load: HashSet::new(),
            selected: None,
            active_file: None,
            error: None,
            generation: 0,
            hidden_directory_patterns: Vec::new(),
            hidden_file_patterns: Vec::new(),
            show_dotfiles: true,
            pending_initial_load: has_root,
            menu: None,
            dialog: None,
            pending_delete: None,
            busy: false,
            overlay_focus: cx.focus_handle(),
            on_open_file: None,
        };
        // 只准备展开状态，不在构造期发起异步请求；真正的加载在首帧
        // `Render` 里通过 `defer_in` 触发。
        this.prepare_root();
        this
    }

    /// 清空旧根状态并标记根节点展开，但不发起加载。
    fn prepare_root(&mut self) {
        self.expanded.clear();
        self.loaded.clear();
        self.loading.clear();
        self.refresh_after_load.clear();
        self.selected = None;
        self.error = None;
        self.generation = self.generation.wrapping_add(1);
        // 旧工作区的菜单/覆盖层不能带到新根上。
        self.menu = None;
        self.dialog = None;
        self.pending_delete = None;
        self.busy = false;

        if self.root.is_some() {
            self.expanded.insert(String::new());
        }
    }

    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        // 与 `new` 保持同一语义：空路径表示没有打开项目。
        self.root = if root.as_os_str().is_empty() {
            None
        } else {
            Some(root)
        };
        self.pending_initial_load = false;
        self.reset_root(cx);
        cx.notify();
    }

    pub fn root(&self) -> Option<PathBuf> {
        self.root.clone()
    }

    /// 重新加载整棵树。
    ///
    /// 清空 `loaded` / `loading` 缓存并递增 `generation`，让仍在飞行中的旧
    /// 请求作废；保留 `expanded` 和 `selected`，然后重新请求根目录和所有
    /// 已展开目录。磁盘扫描仍走 `background_spawn`，本方法只负责发起请求。
    /// 没有工作区根时只清空缓存并重绘。
    pub fn refresh(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.loaded.clear();
        self.loading.clear();
        self.refresh_after_load.clear();
        self.error = None;
        self.generation = self.generation.wrapping_add(1);

        if self.root.is_none() {
            cx.notify();
            return;
        }

        // 根节点始终保持展开；其余已展开目录按路径深度排序，根先发起请求。
        self.expanded.insert(String::new());
        let mut directories: Vec<String> = self.expanded.iter().cloned().collect();
        directories.sort_by_key(|path| path.matches('/').count());
        for path in directories {
            self.load_directory(path, cx);
        }
        cx.notify();
    }

    /// 展开目录；若该目录尚未加载，则发起一次后台请求。
    ///
    /// `window` 由契约保留给后续「展开并滚动到可见」的实现，本轮不需要。
    pub fn expand(&mut self, path: &str, _window: &mut Window, cx: &mut Context<Self>) {
        let already_expanded = self.expanded.contains(path);
        self.expanded.insert(path.to_string());
        // 第一次展开、或上次加载失败后重试时才请求 Core。
        if !already_expanded || !self.loaded.contains_key(path) {
            self.load_directory(path.to_string(), cx);
        }
        cx.notify();
    }

    /// 折叠目录。已加载的子项仍保留在缓存里，重新展开时无需再次访问磁盘。
    pub fn collapse(&mut self, path: &str, _window: &mut Window, cx: &mut Context<Self>) {
        if self.expanded.remove(path) {
            cx.notify();
        }
    }

    /// 点击文件时回调。参数是 `root.join(relative_path)` 得到的绝对路径。
    /// 注入隐藏路径模式；模式变化后清空目录缓存并重载。
    pub fn set_hidden_patterns(
        &mut self,
        directories: Vec<String>,
        files: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        if self.hidden_directory_patterns == directories && self.hidden_file_patterns == files {
            return;
        }
        self.hidden_directory_patterns = directories;
        self.hidden_file_patterns = files;
        // 缓存里可能已经藏着应被隐藏的节点；清空后按新模式重新加载。
        self.loaded.clear();
        self.expanded.clear();
        cx.notify();
    }

    /// 切换隐藏文件的显示；下一次渲染按新状态投影行。
    pub fn set_show_dotfiles(&mut self, visible: bool, cx: &mut Context<Self>) {
        if self.show_dotfiles == visible {
            return;
        }
        self.show_dotfiles = visible;
        cx.notify();
    }

    /// 一个名字是否命中隐藏模式：精确名或 `*` 通配（前缀 / 后缀）。
    fn name_hidden(name: &str, patterns: &[String]) -> bool {
        patterns.iter().any(|pattern| {
            let pattern = pattern.trim();
            if pattern.is_empty() {
                return false;
            }
            if let Some(suffix) = pattern.strip_prefix('*') {
                name.ends_with(suffix)
            } else if let Some(prefix) = pattern.strip_suffix('*') {
                name.starts_with(prefix)
            } else {
                name == pattern
            }
        })
    }

    pub fn on_open_file(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static) {
        self.on_open_file = Some(Rc::new(handler));
    }

    /// 定位指定文件并在树中逐级展开其父目录。
    /// 同步当前编辑器打开的文件：行高亮 + 自动展开祖先目录。
    ///
    /// 路径未变化时不动（Workbench 每帧同步调用，靠这里去重）。
    pub fn set_active_file(
        &mut self,
        path: Option<&Path>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let relative = path.and_then(|path| {
            let root = self.root.as_ref()?;
            path.strip_prefix(root).ok().map(|rel| {
                rel.components()
                    .map(|component| component.as_os_str().to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join("/")
            })
        });
        if self.active_file == relative {
            return;
        }
        self.active_file = relative.clone();
        if let Some(relative) = relative.as_deref() {
            let mut current = String::new();
            let components: Vec<&str> = relative.split('/').collect();
            for component in components.iter().take(components.len().saturating_sub(1)) {
                if current.is_empty() {
                    current = component.to_string();
                } else {
                    current = format!("{current}/{component}");
                }
                self.expand(&current, window, cx);
            }
        }
        cx.notify();
    }

    pub fn reveal_path(&mut self, path: &Path, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = &self.root else {
            return;
        };
        if let Ok(rel) = path.strip_prefix(root) {
            let mut current = String::new();
            if let Some(parent) = rel.parent() {
                for component in parent.components() {
                    let seg = component.as_os_str().to_string_lossy();
                    if current.is_empty() {
                        current = seg.to_string();
                    } else {
                        current = format!("{current}/{seg}");
                    }
                    self.expand(&current, window, cx);
                }
            }
            cx.notify();
        }
    }

    /// 重置到新的工作区根：清空缓存、展开根节点并重新加载。
    fn reset_root(&mut self, cx: &mut Context<Self>) {
        self.prepare_root();

        // 没有工作区根时只清空状态；空路径不是合法的 Core 工作区。
        if self.root.is_none() {
            return;
        }
        self.load_directory(String::new(), cx);
    }

    /// 请求一个目录的直接子项。
    ///
    /// 阻塞的 Core 调用包在 `background_spawn` 里；结果回主线程后再检查
    /// `generation`，保证旧工作区的扫描结果不会写进当前树。
    fn load_directory(&mut self, path: String, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        if self.loaded.contains_key(&path) || self.loading.contains(&path) {
            return;
        }

        let generation = self.generation;
        let client = self.client;
        self.loading.insert(path.clone());

        cx.spawn(async move |this, cx| {
            let requested = path.clone();
            // 根目录的 `path` 是空字符串，因此这里首次展开等价于
            // `list_directories(root, &["".to_string()])`。
            let result = cx
                .background_spawn(async move { client.list_directories(&root, &[requested]) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    // 工作区已经切换，丢弃这次结果。
                    return;
                }

                this.loading.remove(&path);
                match result {
                    Ok(listings) => {
                        // 本次只请求一个目录；Core 会跳过不存在或不可见的目录，
                        // 因此找不到对应项时按“已知空目录”处理。若 Core 规范化了
                        // 返回路径，单个结果仍然可信，直接采用。
                        let index = listings
                            .iter()
                            .position(|listing| listing.path == path)
                            .unwrap_or(0);
                        let children = listings
                            .into_iter()
                            .nth(index)
                            .map(|listing| listing.children)
                            .unwrap_or_default();
                        this.loaded.insert(path.clone(), children);
                        this.error = None;
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }

                // 新建 / 重命名 / 删除发生在本次加载飞行期间时，等这次结果
                // 落盘（可能已经过期）后再补一次请求。
                if this.refresh_after_load.remove(&path) {
                    this.loaded.remove(&path);
                    this.load_directory(path.clone(), cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 丢弃一个目录的缓存；若用户当前正展开它，则重新加载。
    fn refresh_directory(&mut self, path: String, cx: &mut Context<Self>) {
        self.loaded.remove(&path);
        // 折叠的目录下次展开时会重新加载，不需要现在访问磁盘。
        if !path.is_empty() && !self.expanded.contains(&path) {
            return;
        }
        if self.loading.contains(&path) {
            self.refresh_after_load.insert(path);
            return;
        }
        self.load_directory(path, cx);
    }

    /// 忘记某个路径及其所有子路径的缓存、展开与选中状态。
    ///
    /// 目录被删除或重命名后，旧路径下的键都不再有效；继续保留会让展开的
    /// 子目录在下次渲染时指向不存在的路径。
    fn forget_path(&mut self, path: &str) {
        if path.is_empty() {
            return;
        }
        let prefix = format!("{path}/");
        self.loaded
            .retain(|key, _| key != path && !key.starts_with(&prefix));
        self.loading
            .retain(|key| key != path && !key.starts_with(&prefix));
        self.expanded
            .retain(|key| key != path && !key.starts_with(&prefix));
        self.refresh_after_load
            .retain(|key| key != path && !key.starts_with(&prefix));
        if let Some(selected) = self.selected.as_deref() {
            if selected == path || selected.starts_with(&prefix) {
                self.selected = None;
            }
        }
    }

    /// 由模型投影出当前可见的扁平行，供渲染直接消费。
    fn visible_rows(&self) -> Vec<TreeRow> {
        let Some(root) = self.root.as_ref() else {
            return Vec::new();
        };

        let root_expanded = self.expanded.contains("");
        let mut rows = vec![TreeRow {
            is_active: self.active_file.as_deref() == Some(String::new()).as_deref(),
            path: String::new(),
            name: root_display_name(root),
            is_directory: true,
            depth: 0,
            expanded: root_expanded,
        }];

        if root_expanded {
            self.push_children("", 1, &mut rows, 0);
        }
        rows
    }

    fn push_children(&self, parent: &str, depth: usize, rows: &mut Vec<TreeRow>, guard: usize) {
        if depth > MAX_TREE_DEPTH || guard > MAX_TREE_DEPTH {
            return;
        }
        let Some(children) = self.loaded.get(parent) else {
            return;
        };

        for child in children {
            // 空路径会与根节点冲突；自引用会让展开集合形成环。两者都跳过。
            if child.path.is_empty() || child.path == parent {
                continue;
            }
            // 头栏「隐藏文件」开关关闭时，藏起名字以 `.` 开头的条目；设置页的
            // 隐藏路径模式仍独立生效。两条都发生在行投影层，不影响缓存。
            let dotfile_hidden = !self.show_dotfiles && child.name.starts_with('.');
            let hidden = dotfile_hidden
                || (if child.is_directory {
                    Self::name_hidden(&child.name, &self.hidden_directory_patterns)
                } else {
                    Self::name_hidden(&child.name, &self.hidden_file_patterns)
                });
            if hidden {
                continue;
            }

            let expanded = child.is_directory && self.expanded.contains(&child.path);
            rows.push(TreeRow {
                path: child.path.clone(),
                name: node_display_name(&child.path, &child.name),
                is_directory: child.is_directory,
                depth,
                expanded,
                is_active: self.active_file.as_deref() == Some(child.path.as_str()),
            });

            if expanded {
                self.push_children(&child.path, depth + 1, rows, guard + 1);
            }
        }
    }

    /// 点击一行：目录切换展开，文件交给上层打开。
    fn activate_row(
        &mut self,
        path: String,
        is_directory: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.selected = Some(path.clone());

        if is_directory {
            if self.expanded.contains(&path) {
                self.collapse(&path, window, cx);
            } else {
                self.expand(&path, window, cx);
            }
            return;
        }

        if let Some(root) = self.root.clone() {
            let absolute = absolute_from_relative(&root, &path);
            if let Some(handler) = self.on_open_file.as_ref() {
                handler(absolute, window, cx);
            }
        }
        cx.notify();
    }

    // --- 右键菜单与文件操作 ------------------------------------------------

    /// 打开某一行附近的上下文菜单，并让菜单取得键盘焦点（Escape 关闭）。
    fn open_context_menu(
        &mut self,
        path: String,
        name: String,
        is_directory: bool,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.busy {
            return;
        }
        // 右键同时选中该行，菜单和树的状态保持一致。
        self.selected = Some(path.clone());
        self.menu = Some(ContextMenu {
            path,
            name,
            is_directory,
            position,
        });
        self.overlay_focus.focus(window, cx);
        cx.notify();
    }

    /// 执行菜单项。菜单本身先关闭，再打开覆盖层。
    ///
    /// 复制路径、在文件管理器中显示、刷新都是即时动作，不打开任何覆盖层。
    fn activate_menu_entry(
        &mut self,
        action: MenuAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.menu.take() else {
            return;
        };
        match action {
            MenuAction::NewFile | MenuAction::NewFolder => {
                // 目录内创建；文件则创建在它的父目录。
                let directory = if menu.is_directory {
                    menu.path
                } else {
                    parent_of(&menu.path)
                };
                let kind = if action == MenuAction::NewFile {
                    NameDialogKind::NewFile
                } else {
                    NameDialogKind::NewFolder
                };
                self.begin_name_dialog(kind, directory, None, String::new(), false, cx);
            }
            MenuAction::CopyPath => {
                self.copy_path_text(&menu, false, cx);
            }
            MenuAction::CopyRelativePath => {
                self.copy_path_text(&menu, true, cx);
            }
            MenuAction::Reveal => {
                if let Some(root) = self.root.clone() {
                    let absolute = absolute_from_relative(&root, &menu.path);
                    // 系统文件管理器启动失败时把原因留在状态栏，不静默忽略。
                    if lithe_platform::current().reveal_path(&absolute) {
                        self.error = None;
                    } else {
                        self.error = Some(SharedString::from(tr("File operation failed")));
                    }
                }
                cx.notify();
            }
            MenuAction::Rename => {
                if menu.path.is_empty() {
                    // 工作区根不能被重命名。
                    return;
                }
                let directory = parent_of(&menu.path);
                self.begin_name_dialog(
                    NameDialogKind::Rename,
                    directory,
                    Some(menu.path),
                    menu.name,
                    menu.is_directory,
                    cx,
                );
            }
            MenuAction::MoveToTrash => {
                if menu.path.is_empty() {
                    // 工作区根不能被删除。
                    return;
                }
                self.pending_delete = Some(TrashRequest {
                    path: menu.path,
                    is_directory: menu.is_directory,
                    error: None,
                    permanent_delete_available: false,
                });
                self.overlay_focus.focus(window, cx);
                cx.notify();
            }
            MenuAction::Refresh => {
                if menu.path.is_empty() {
                    // 根节点：整棵树重载，对齐 macOS 的 refreshWorkspace。
                    self.refresh(window, cx);
                    return;
                }
                // 目录刷新自己；文件刷新所在目录。
                let directory = if menu.is_directory {
                    menu.path
                } else {
                    parent_of(&menu.path)
                };
                self.refresh_directory(directory, cx);
                cx.notify();
            }
        }
    }

    /// 把绝对路径或工作区相对路径写进剪贴板。
    ///
    /// 相对路径沿用树节点的 `/` 分隔；根目录的相对路径按 macOS 的约定写成
    /// `.`，避免复制出空字符串。
    fn copy_path_text(&mut self, menu: &ContextMenu, relative: bool, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            self.error = Some(SharedString::from(tr("No project open")));
            cx.notify();
            return;
        };
        let text = if relative {
            relative_copy_text(&menu.path)
        } else {
            absolute_copy_text(&root, &menu.path)
        };
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text));
        self.error = None;
        cx.notify();
    }

    /// 打开新建 / 重命名输入覆盖层。
    fn begin_name_dialog(
        &mut self,
        kind: NameDialogKind,
        directory: String,
        target: Option<String>,
        initial: String,
        target_is_directory: bool,
        cx: &mut Context<Self>,
    ) {
        self.menu = None;
        self.error = None;
        self.dialog = Some(NameDialog {
            kind,
            directory,
            target,
            initial,
            target_is_directory,
            input: None,
            _subscription: None,
            error: None,
            pending_focus: true,
        });
        cx.notify();
    }

    /// 确保当前覆盖层的输入框已经创建，并只订阅一次输入事件。
    ///
    /// 输入框需要 `Window`，因此只能在 `Render` 里惰性创建；重命名时用
    /// `default_value` 预填当前名称。
    fn ensure_name_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Entity<InputState>> {
        if self.dialog.is_none() {
            return None;
        }
        if let Some(input) = self.dialog.as_ref().and_then(|dialog| dialog.input.clone()) {
            return Some(input);
        }

        let initial = self
            .dialog
            .as_ref()
            .map(|dialog| dialog.initial.clone())
            .unwrap_or_default();
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("Name"))
                .default_value(initial)
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this: &mut Self, _input, event: &InputEvent, _window, cx| match event {
                InputEvent::PressEnter { .. } => this.submit_name_dialog(cx),
                InputEvent::Change => {
                    // 用户改动名称后清掉上一次的校验提示。
                    if let Some(dialog) = this.dialog.as_mut() {
                        dialog.error = None;
                    }
                    cx.notify();
                }
                InputEvent::Focus | InputEvent::Blur => {}
            },
        );

        if let Some(dialog) = self.dialog.as_mut() {
            dialog.input = Some(input.clone());
            dialog._subscription = Some(subscription);
        }
        Some(input)
    }

    /// 校验并提交输入覆盖层。
    fn submit_name_dialog(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(input) = self.dialog.as_ref().and_then(|dialog| dialog.input.clone()) else {
            return;
        };
        let raw = input.read(cx).value().to_string();
        let name = match validate_new_name(&raw) {
            Ok(name) => name,
            Err(message) => {
                self.set_dialog_error(message);
                cx.notify();
                return;
            }
        };

        let Some(dialog) = self.dialog.as_ref() else {
            return;
        };
        let kind = dialog.kind;
        let directory = dialog.directory.clone();
        let target = dialog.target.clone();
        let target_is_directory = dialog.target_is_directory;

        // 目录本身来自 Core，仍需拒绝 `..` 等不合法相对路径。
        if !is_safe_relative(&directory) {
            self.set_dialog_error(tr("Invalid name"));
            cx.notify();
            return;
        }
        let relative = join_relative(&directory, &name);
        if !is_safe_relative(&relative) {
            self.set_dialog_error(tr("Invalid name"));
            cx.notify();
            return;
        }

        let (operation, forget, reselect) = match kind {
            NameDialogKind::NewFile => (FileOperation::CreateFile { relative }, None, None),
            NameDialogKind::NewFolder => (FileOperation::CreateFolder { relative }, None, None),
            NameDialogKind::Rename => {
                let Some(from) = target else {
                    // 没有源路径说明状态异常；直接关闭覆盖层，不发起危险操作。
                    self.dialog = None;
                    cx.notify();
                    return;
                };
                if from == relative {
                    // 名称没变，等同于取消。
                    self.dialog = None;
                    cx.notify();
                    return;
                }
                let forget = target_is_directory.then(|| from.clone());
                let reselect = if target_is_directory {
                    None
                } else {
                    Some((from.clone(), relative.clone()))
                };
                (
                    FileOperation::Rename { from, to: relative },
                    forget,
                    reselect,
                )
            }
        };

        self.run_operation(operation, vec![directory], forget, reselect, cx);
    }

    /// 确认把目标移到回收站。破坏性操作必须经过覆盖层，不能从菜单直接执行。
    fn confirm_move_to_trash(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(request) = self.pending_delete.clone() else {
            return;
        };
        if request.path.is_empty() || !is_safe_relative(&request.path) {
            self.error = Some(SharedString::from(tr("Invalid name")));
            cx.notify();
            return;
        }

        let directory = parent_of(&request.path);
        self.run_operation(
            FileOperation::MoveToTrash {
                relative: request.path.clone(),
            },
            vec![directory],
            Some(request.path),
            None,
            cx,
        );
    }

    /// 回收站不可用时的显式回退：永久删除。
    ///
    /// 只有 `permanent_delete_available` 为真（上一次移到回收站确实失败）时才
    /// 允许进入，避免把永久删除做成任何一次误触就能到达的默认行为。
    fn confirm_permanent_delete(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(request) = self.pending_delete.clone() else {
            return;
        };
        if !request.permanent_delete_available {
            return;
        }
        if request.path.is_empty() || !is_safe_relative(&request.path) {
            self.error = Some(SharedString::from(tr("Invalid name")));
            cx.notify();
            return;
        }

        let directory = parent_of(&request.path);
        self.run_operation(
            FileOperation::DeletePermanently {
                relative: request.path.clone(),
                is_directory: request.is_directory,
            },
            vec![directory],
            Some(request.path),
            None,
            cx,
        );
    }

    fn set_dialog_error(&mut self, message: &'static str) {
        if let Some(dialog) = self.dialog.as_mut() {
            dialog.error = Some(SharedString::from(message));
        }
    }

    /// 把文件操作派发到后台，成功后刷新受影响的目录并清理旧缓存。
    ///
    /// 结果回主线程时先检查 `generation`，工作区已经切换就丢弃；失败只写
    /// 状态，不 panic，也不清空已有树数据。
    fn run_operation(
        &mut self,
        operation: FileOperation,
        refresh_dirs: Vec<String>,
        forget: Option<String>,
        reselect: Option<(String, String)>,
        cx: &mut Context<Self>,
    ) {
        if self.busy {
            return;
        }
        let Some(root) = self.root.clone() else {
            self.error = Some(SharedString::from(tr("No project open")));
            cx.notify();
            return;
        };

        let generation = self.generation;
        // 只有“移到回收站”失败才允许把永久删除作为显式回退暴露出来。
        let trash_attempt = matches!(operation, FileOperation::MoveToTrash { .. });
        self.busy = true;
        self.error = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { operation.execute(root) })
                .await;

            let _ = this.update(cx, |this, cx| {
                // 工作区已切换：`prepare_root` 已经清理 busy/覆盖层。
                if this.generation != generation {
                    return;
                }
                this.busy = false;
                match result {
                    Ok(()) => {
                        this.dialog = None;
                        this.pending_delete = None;
                        this.menu = None;
                        this.error = None;
                        if let Some(path) = forget.as_deref() {
                            this.forget_path(path);
                        }
                        if let Some((from, to)) = reselect.as_ref() {
                            if this.selected.as_deref() == Some(from.as_str()) {
                                this.selected = Some(to.clone());
                            }
                        }
                        for directory in refresh_dirs.iter() {
                            this.refresh_directory(directory.clone(), cx);
                        }
                    }
                    Err(detail) => {
                        // 树顶部只放稳定的总结文案；具体系统错误留在覆盖层里。
                        this.error = Some(SharedString::from(tr("File operation failed")));
                        if let Some(dialog) = this.dialog.as_mut() {
                            dialog.error = Some(SharedString::from(detail.clone()));
                        }
                        if let Some(delete) = this.pending_delete.as_mut() {
                            // 「文件已不存在」只是目标已经消失，回收站本身可用，
                            // 属于非破坏性失败：不把永久删除作为回退暴露出来。
                            let missing_target = detail.as_str() == tr("File no longer exists");
                            delete.error = Some(SharedString::from(detail));
                            // 回收站失败后不自动永久删除：只把回退按钮显示出来，
                            // 由用户在下一次点击里显式确认。
                            if trash_attempt && !missing_target {
                                delete.permanent_delete_available = true;
                            }
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn render_row(&self, row: TreeRow, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected = self.selected.as_deref() == Some(row.path.as_str());
        // 活动文件（编辑器正打开）行强高亮，与手动选中的行区分，对齐 Tauri。
        let active = row.is_active;
        let highlighted = active || selected;
        let foreground = if highlighted {
            white()
        } else {
            tokens.primary_text
        };
        let icon_color = if highlighted {
            white()
        } else if row.is_directory {
            tokens.secondary_text
        } else {
            file_icon_color(&row.name, tokens)
        };

        let row_icon = if row.is_directory {
            if row.expanded {
                LitheIcon::FolderOpen
            } else {
                LitheIcon::Folder
            }
        } else {
            LitheIcon::File
        };
        let (disclosure, type_icon) = if row.is_directory {
            let direction = if row.expanded {
                LitheIcon::ChevronDown
            } else {
                LitheIcon::ChevronRight
            };
            (
                div()
                    .size(px(LitheMetrics::TREE_ICON_SIZE))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        icon(direction)
                            .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                            .text_color(icon_color),
                    )
                    .into_any_element(),
                // 目录图标走 row_icon（Folder / FolderOpen）。
                None,
            )
        } else {
            // 文件行用等宽占位符对齐目录的 disclosure 槽位；图标按扩展名着色。
            (
                div()
                    .size(px(LitheMetrics::TREE_ICON_SIZE))
                    .flex_shrink_0()
                    .into_any_element(),
                Some(file_type_icon(&row.name)),
            )
        };

        let click_path = row.path.clone();
        let click_is_directory = row.is_directory;
        let menu_path = row.path.clone();
        let menu_name = row.name.clone();
        let menu_is_directory = row.is_directory;

        div()
            .id(format!("lithe-project-tree:row:{}", row.path))
            .w_full()
            .h(px(LitheMetrics::PROJECT_TREE_ROW_HEIGHT))
            .flex_shrink_0()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.0))
            .px(px(4.0))
            .pl(px(row.depth as f32 * LitheMetrics::TREE_INDENT + 4.0))
            .pr(px(8.0))
            .rounded(px(4.0))
            .when(highlighted, |this| this.bg(tokens.selection))
            .when(!highlighted, |this| {
                this.hover(|style| style.bg(tokens.hover))
            })
            .cursor_pointer()
            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                this.activate_row(click_path.clone(), click_is_directory, window, cx);
            }))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    this.open_context_menu(
                        menu_path.clone(),
                        menu_name.clone(),
                        menu_is_directory,
                        event.position,
                        window,
                        cx,
                    );
                }),
            )
            .child(disclosure)
            .child(match type_icon {
                // 已知扩展名用类型图标（对齐 Tauri 的按类型着色意图）。
                Some(icon_name) => gpui_kit::component::Icon::new(icon_name)
                    .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                    .text_color(icon_color)
                    .into_any_element(),
                None => icon(row_icon)
                    .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                    .text_color(icon_color)
                    .into_any_element(),
            })
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_1()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .when(row.depth == 0, |this| {
                        this.font_weight(FontWeight::SEMIBOLD)
                    })
                    .text_color(foreground)
                    .child(row.name),
            )
            .into_any_element()
    }

    /// 右键菜单：延迟到窗口前景层，按触发时的窗口坐标锚定。
    fn render_context_menu(
        &self,
        menu: &ContextMenu,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut items = div().w_full().flex().flex_col();
        if menu.is_directory {
            items = items.child(render_menu_item(
                MenuAction::NewFile,
                tr("New File"),
                false,
                tokens,
                cx,
            ));
            items = items.child(render_menu_item(
                MenuAction::NewFolder,
                tr("New Folder"),
                false,
                tokens,
                cx,
            ));
            items = items.child(render_menu_separator(tokens));
        }
        // 复制与定位对目录、文件和根节点都适用，对齐 macOS 的
        // Copy Path / Copy Relative Path / Show in Finder。
        items = items
            .child(render_menu_item(
                MenuAction::CopyPath,
                tr("Copy Path"),
                false,
                tokens,
                cx,
            ))
            .child(render_menu_item(
                MenuAction::CopyRelativePath,
                tr("Copy Relative Path"),
                false,
                tokens,
                cx,
            ))
            .child(render_menu_item(
                MenuAction::Reveal,
                reveal_label(),
                false,
                tokens,
                cx,
            ));
        // 工作区根只能作为新建、复制和定位的目标，不能重命名或删除。
        if !menu.path.is_empty() {
            items = items
                .child(render_menu_separator(tokens))
                .child(render_menu_item(
                    MenuAction::Rename,
                    tr("Rename"),
                    false,
                    tokens,
                    cx,
                ))
                .child(render_menu_item(
                    MenuAction::MoveToTrash,
                    tr("Move to Trash"),
                    true,
                    tokens,
                    cx,
                ));
        }
        items = items
            .child(render_menu_separator(tokens))
            .child(render_menu_item(
                MenuAction::Refresh,
                tr("Refresh"),
                false,
                tokens,
                cx,
            ));

        deferred(
            anchored().position(menu.position).snap_to_window().child(
                div()
                    .id("lithe-project-tree:menu")
                    .w(px(CONTEXT_MENU_WIDTH))
                    .py(px(4.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .occlude()
                    .track_focus(&self.overlay_focus)
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                        if event.keystroke.key == "escape" {
                            this.menu = None;
                            cx.notify();
                        }
                    }))
                    // 点击菜单外部（包括树的其余区域）关闭菜单。
                    .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                        if this.menu.take().is_some() {
                            cx.notify();
                        }
                    }))
                    .child(items),
            ),
        )
        .into_any_element()
    }

    /// 新建 / 重命名输入覆盖层。
    fn render_name_dialog(
        &self,
        dialog: &NameDialog,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let input = match dialog.input.as_ref() {
            Some(input) => Input::new(input)
                .w_full()
                .aria_label(tr("Name"))
                .into_any_element(),
            None => div()
                .w_full()
                .h(px(LitheMetrics::TREE_ROW_HEIGHT))
                .into_any_element(),
        };

        let busy = self.busy;
        let mut error_line = None;
        if let Some(error) = dialog.error.clone() {
            error_line = Some(
                div()
                    .w_full()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }

        div()
            .id("lithe-project-tree:name-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .occlude()
            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                if !this.busy {
                    this.dialog = None;
                    cx.notify();
                }
            }))
            .child(
                div()
                    .id("lithe-project-tree:name-dialog")
                    .w(px(NAME_DIALOG_WIDTH))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .flex()
                    .flex_col()
                    .gap(px(10.0))
                    .track_focus(&self.overlay_focus)
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                        if event.keystroke.key == "escape" && !this.busy {
                            this.dialog = None;
                            cx.notify();
                        }
                    }))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(dialog.kind.title()),
                    )
                    .child(input)
                    .when_some(error_line, |this, error| this.child(error))
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-project-tree:name-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .disabled(busy)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dialog = None;
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("lithe-project-tree:name-submit")
                                    .primary()
                                    .small()
                                    .label(dialog.kind.submit_label())
                                    .disabled(busy)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.submit_name_dialog(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 删除二次确认覆盖层：默认动作是「移到回收站」。
    ///
    /// 回收站失败后，同一覆盖层会显示失败原因和一个额外的显式「删除」（永久）
    /// 按钮；它只在 `permanent_delete_available` 为真时出现，保证永久删除
    /// 永远需要用户多一次点击。
    fn render_delete_dialog(
        &self,
        request: &TrashRequest,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let busy = self.busy;
        // 永久删除只是回收站不可用时的次要回退：标题与主按钮始终是「移到回收站」，
        // 用户可以随时重试，不会因为一次失败就失去可撤销的默认路径。
        let permanent = request.permanent_delete_available;
        let title = tr("Move to Trash");
        let display = self
            .root
            .as_ref()
            .map(|root| root.join(&request.path).display().to_string())
            .unwrap_or_else(|| request.path.clone());

        let mut error_line = None;
        if let Some(error) = request.error.clone() {
            error_line = Some(
                div()
                    .w_full()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }

        // 只在回收站确实失败后出现：永久删除是不可撤销的回退，必须多一次点击。
        let mut warning_line = None;
        if permanent {
            warning_line = Some(
                div()
                    .w_full()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("This action cannot be undone by Lithe.")),
            );
        }

        // 主按钮固定为「移到回收站」：失败后仍是可重试的默认动作。
        let primary = Button::new("lithe-project-tree:delete-confirm")
            .danger()
            .small()
            .label(tr("Move to Trash"))
            .disabled(busy)
            .on_click(cx.listener(|this, _, _, cx| {
                this.confirm_move_to_trash(cx);
            }));
        // 回收站确实不可用时才出现的次要危险按钮；它不替换主按钮。
        let permanent_fallback = permanent.then(|| {
            Button::new("lithe-project-tree:delete-permanent")
                .danger()
                .small()
                .label(tr("Delete"))
                .disabled(busy)
                .on_click(cx.listener(|this, _, _, cx| {
                    this.confirm_permanent_delete(cx);
                }))
        });

        div()
            .id("lithe-project-tree:delete-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .occlude()
            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                if !this.busy {
                    this.pending_delete = None;
                    cx.notify();
                }
            }))
            .child(
                div()
                    .id("lithe-project-tree:delete-dialog")
                    .w(px(DELETE_DIALOG_WIDTH))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .flex()
                    .flex_col()
                    .gap(px(10.0))
                    .track_focus(&self.overlay_focus)
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                        if event.keystroke.key == "escape" && !this.busy {
                            this.pending_delete = None;
                            cx.notify();
                        }
                    }))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(title),
                    )
                    .child(
                        div()
                            .w_full()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(display),
                    )
                    .when_some(error_line, |this, error| this.child(error))
                    .when_some(warning_line, |this, warning| this.child(warning))
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-project-tree:delete-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .disabled(busy)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.pending_delete = None;
                                        cx.notify();
                                    })),
                            )
                            .when_some(permanent_fallback, |this, button| this.child(button))
                            .child(primary),
                    ),
            )
            .into_any_element()
    }

    /// 把树内容和当前覆盖层组合成一个完整的根元素。
    fn wrap_with_overlays(
        &self,
        content: AnyElement,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut root = div()
            .id("lithe-project-tree:root")
            .relative()
            .size_full()
            .child(content);

        if let Some(menu) = self.menu.clone() {
            root = root.child(self.render_context_menu(&menu, tokens, cx));
        }
        if let Some(dialog) = self.dialog.as_ref() {
            root = root.child(self.render_name_dialog(dialog, tokens, cx));
        }
        if let Some(delete) = self.pending_delete.as_ref() {
            root = root.child(self.render_delete_dialog(delete, tokens, cx));
        }
        root.into_any_element()
    }
}

/// 菜单分组之间的细分隔线；与菜单同宽、不可点击。
fn render_menu_separator(tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .h(px(1.0))
        .my(px(4.0))
        .flex_shrink_0()
        .bg(tokens.panel_border)
        .into_any_element()
}

/// 单个菜单项。`cx.listener` 需要视图上下文，因此作为自由函数接收 `cx`。
fn render_menu_item(
    action: MenuAction,
    label: &'static str,
    danger: bool,
    tokens: LitheTokens,
    cx: &mut Context<ProjectTree>,
) -> AnyElement {
    div()
        .id(format!("lithe-project-tree:menu:{}", action.id()))
        .w_full()
        .h(px(CONTEXT_MENU_ITEM_HEIGHT))
        .px(px(10.0))
        .flex()
        .flex_row()
        .items_center()
        .cursor_pointer()
        .hover(|style| style.bg(tokens.hover))
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(if danger {
            tokens.error
        } else {
            tokens.primary_text
        })
        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
            this.activate_menu_entry(action, window, cx);
        }))
        .child(label)
        .into_any_element()
}

impl Render for ProjectTree {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 首帧把根目录加载排到当前 App 借用释放之后；不能在构造期 spawn。
        if self.pending_initial_load {
            self.pending_initial_load = false;
            cx.defer_in(window, |this, _window, cx| {
                if this.root.is_some() {
                    this.load_directory(String::new(), cx);
                }
            });
        }

        let tokens = current_tokens(cx);
        let rows = self.visible_rows();

        // 输入框只能在拿到 Window 的帧里创建。创建后把聚焦与全选排到当前
        // 借用释放之后，避免在布局阶段改焦点。
        let name_input = self.ensure_name_input(window, cx);
        if let Some(input) = name_input {
            let needs_focus = self
                .dialog
                .as_mut()
                .map(|dialog| std::mem::replace(&mut dialog.pending_focus, false))
                .unwrap_or(false);
            if needs_focus {
                cx.defer_in(window, move |_this, window, cx| {
                    input.update(cx, |state, cx| {
                        state.focus(window, cx);
                        state.select_all(window, cx);
                    });
                });
            }
        }

        let mut tree = div()
            .id("lithe-project-tree")
            .size_full()
            .flex()
            .flex_col()
            .bg(tokens.sidebar)
            .text_color(tokens.primary_text);

        // 错误只占一行状态文本，不打断树本身的浏览。
        if let Some(error) = self.error.clone() {
            tree = tree.child(
                div()
                    .w_full()
                    .h(px(22.0))
                    .flex_shrink_0()
                    .px(px(10.0))
                    .flex()
                    .items_center()
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.error)
                            .child(error),
                    ),
            );
        }

        if self.root.is_none() {
            let content = tree.child(empty_tree_state(tokens)).into_any_element();
            return self.wrap_with_overlays(content, tokens, cx);
        }

        let mut list = div().w_full().flex().flex_col();
        for row in rows {
            list = list.child(self.render_row(row, tokens, cx));
        }

        let content = tree
            .child(
                div()
                    .id("lithe-project-tree:scroll")
                    .w_full()
                    .flex_1()
                    .overflow_y_scroll()
                    .child(list),
            )
            .into_any_element();
        self.wrap_with_overlays(content, tokens, cx)
    }
}

fn root_display_name(root: &Path) -> String {
    let name = root
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    if !name.is_empty() {
        return name;
    }

    let display = root.display().to_string();
    if display.is_empty() {
        tr("Project").to_string()
    } else {
        display
    }
}

/// 按扩展名选择文件类型图标，对齐 Tauri 文件树「不同文件不同图标」的意图。
/// 完整图标主题引擎（IDEA 资产包 + Java 语义图标）属独立子系统；这里用
/// gpui 内置图标集按类别区分。
fn file_type_icon(name: &str) -> gpui_kit::assets::IconName {
    use gpui_kit::assets::IconName;
    let lower = name.to_ascii_lowercase();
    let extension = lower.rsplit_once('.').map(|(_, ext)| ext).unwrap_or("");
    match extension {
        "java" => IconName::Code,
        "md" | "txt" | "log" => IconName::FileText,
        "xml" | "json" | "yml" | "yaml" | "properties" | "toml" | "ini" | "cfg" | "conf" => {
            IconName::Settings
        }
        "sql" => IconName::HardDrive,
        "js" | "ts" | "jsx" | "tsx" | "py" | "rs" | "go" | "kt" | "kts" | "groovy" | "gradle"
        | "cs" | "c" | "h" | "cpp" | "hpp" | "sh" | "ps1" | "bat" | "cmd" => IconName::Terminal,
        "jar" | "zip" | "class" | "war" => IconName::Package,
        "gitignore" | "gitattributes" | "patch" | "diff" => IconName::GitBranch,
        "html" | "htm" | "css" | "scss" | "less" | "vue" => IconName::Eye,
        _ => IconName::File,
    }
}

/// 类型图标的着色（IDE 习惯：Java 蓝、配置黄、数据库青、脚本绿…）。
fn file_icon_color(name: &str, tokens: LitheTokens) -> gpui_kit::Hsla {
    let lower = name.to_ascii_lowercase();
    let extension = lower.rsplit_once('.').map(|(_, ext)| ext).unwrap_or("");
    match extension {
        "java" => tokens.accent,
        "md" | "txt" | "log" => tokens.secondary_text,
        "xml" | "json" | "yml" | "yaml" | "properties" | "toml" | "ini" | "cfg" | "conf" => {
            tokens.warning
        }
        "sql" => tokens.success,
        "js" | "ts" | "jsx" | "tsx" | "py" | "rs" | "go" | "kt" | "kts" | "groovy" | "gradle"
        | "cs" | "c" | "h" | "cpp" | "hpp" | "sh" | "ps1" | "bat" | "cmd" => tokens.success,
        "jar" | "zip" | "class" | "war" => tokens.warning,
        "gitignore" | "gitattributes" | "patch" | "diff" => tokens.warning,
        "html" | "htm" | "css" | "scss" | "less" | "vue" => tokens.accent,
        _ => tokens.secondary_text,
    }
}

fn node_display_name(path: &str, name: &str) -> String {
    if !name.is_empty() {
        return name.to_string();
    }
    path.rsplit('/')
        .next()
        .filter(|segment| !segment.is_empty())
        .unwrap_or(path)
        .to_string()
}

fn empty_tree_state(tokens: LitheTokens) -> impl IntoElement {
    div()
        .flex_1()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .px(px(12.0))
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(tokens.secondary_text)
        .child(tr("No project open"))
}

/// 校验用户输入的名称。
///
/// 只接受单个路径段：拒绝空名称、`.`、`..`、路径分隔符、NUL、控制字符和
/// 带盘符/根前缀的输入。返回去掉首尾空白后的名称。
fn validate_new_name(raw: &str) -> Result<String, &'static str> {
    let name = raw.trim();
    if name.is_empty() || name == "." || name == ".." {
        return Err(tr("Invalid name"));
    }
    if name.contains('/') || name.contains('\\') || name.contains('\0') {
        return Err(tr("Invalid name"));
    }
    if name.chars().any(char::is_control) {
        return Err(tr("Invalid name"));
    }
    if Path::new(name).is_absolute() {
        return Err(tr("Invalid name"));
    }
    // Windows 下 `C:name` 有盘符前缀但不是绝对路径，同样必须拒绝。
    if Path::new(name).components().count() != 1 {
        return Err(tr("Invalid name"));
    }
    Ok(name.to_string())
}

/// 判断 Core 给出的工作区相对路径是否可安全拼接。
///
/// 根目录 `""` 视为安全；其余路径必须由非空、非 `.`、非 `..` 的 `/` 分隔
/// 段组成，且不能是绝对路径或含反斜杠/NUL。
fn is_safe_relative(relative: &str) -> bool {
    if relative.is_empty() {
        return true;
    }
    if relative.contains('\\') || relative.contains('\0') {
        return false;
    }
    if Path::new(relative).is_absolute() {
        return false;
    }
    relative
        .split('/')
        .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

/// `root.join(relative)` 后对父目录做 `canonicalize`，要求它仍在根内。
///
/// 返回“规范化父目录 + 原始文件名”的目标路径；这样即使相对路径里混入
/// 符号链接，也不会把写入/删除带到工作区之外。
fn checked_target(root: &Path, relative: &str) -> Result<PathBuf, String> {
    if relative.is_empty() || !is_safe_relative(relative) {
        return Err(tr("Invalid name").to_string());
    }

    let absolute = root.join(relative);
    let parent = absolute
        .parent()
        .ok_or_else(|| tr("Invalid name").to_string())?;
    let name = absolute
        .file_name()
        .ok_or_else(|| tr("Invalid name").to_string())?;
    let canonical_parent = std::fs::canonicalize(parent).map_err(|error| error.to_string())?;
    if !canonical_parent.starts_with(root) {
        return Err(tr("Path is outside the project").to_string());
    }
    Ok(canonical_parent.join(name))
}

/// 工作区相对路径的父目录；根目录下的文件返回 `""`。
fn parent_of(path: &str) -> String {
    match path.rsplit_once('/') {
        Some((parent, _)) => parent.to_string(),
        None => String::new(),
    }
}

/// 拼接工作区相对路径；根目录为空字符串，不能产生前导 `/`。
fn join_relative(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 项目树点击文件时必须回传绝对路径：工作台用绝对路径做标签身份、
    /// 导航历史和工作区归属校验，回传相对路径会打开错误文件或直接失败。
    #[test]
    fn open_handler_receives_absolute_path_built_from_workspace_root() {
        let root = Path::new("/work/project");
        assert_eq!(
            absolute_from_relative(root, "src/main.rs"),
            PathBuf::from("/work/project/src/main.rs")
        );
    }

    /// 树节点身份是 `/` 分隔的工作区相对路径；拼接不能在中间引入反斜杠。
    #[test]
    fn nested_relative_path_keeps_single_separator_between_segments() {
        let root = Path::new("/work/project");
        let joined = absolute_from_relative(root, "a/b/c.txt");
        assert_eq!(joined, PathBuf::from("/work/project/a/b/c.txt"));
        assert_eq!(joined.components().count(), 6);
    }

    /// 「Copy Relative Path」必须复制 `/` 分隔的工作区相对路径；工作区根没有
    /// 相对路径，对齐 macOS `copyProjectItemPath` 复制 `.`，不能复制空字符串。
    #[test]
    fn copy_relative_text_uses_workspace_relative_path() {
        assert_eq!(relative_copy_text("src/main.rs"), "src/main.rs");
        assert_eq!(relative_copy_text("a/b/c.txt"), "a/b/c.txt");
        assert_eq!(relative_copy_text(""), ".");
    }
}
