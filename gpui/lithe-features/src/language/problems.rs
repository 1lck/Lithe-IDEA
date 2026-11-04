//! Problems 面板的会话状态（对齐 macOS `ProblemsView` 的 `@State`）。
//!
//! 视图状态挂在 Java 语言服务模型上：GPUI 的 `Workbench` 结构体没有独立的
//! Problems 面板实体，而诊断快照本来就属于语言服务，两者生命周期一致——
//! 切换工作区时诊断被清空，面板范围、过滤与预览也随之复位，和 macOS 里
//! 工具窗内容随工作区重建的效果一致。

use std::path::PathBuf;

use gpui_kit::component::VirtualListScrollHandle;
use gpui_kit::ScrollStrategy;

/// 预览允许读取的文件大小上限。
///
/// macOS 的 Monaco 预览按需渲染，没有在视图层设上限；GPUI 的预览把全文
/// 行切成 `Vec<String>` 常驻在状态里，必须给一个明确的预算，避免打开超大
/// 生成文件时把整份文本留在内存里。超过上限时显示"无法预览"，不读取文件。
pub const PREVIEW_MAX_BYTES: u64 = 2 * 1024 * 1024;

/// 预览读取失败的原因。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreviewFailure {
    /// 文件超过 [`PREVIEW_MAX_BYTES`]。
    TooLarge,
    /// 读盘或按 UTF-8 解码失败。
    ReadFailed,
}

/// 一份预览文档快照。
#[derive(Default)]
pub struct ProblemPreview {
    pub path: Option<PathBuf>,
    /// 需要定位的 0 基行号。
    pub target_row: usize,
    /// 需要定位的 0 基列号（UTF-16，和编辑器一致）。
    pub target_column: usize,
    /// 按 `\n` 切分后的文本行；不保留行尾的 `\r`。
    pub lines: Vec<String>,
    pub loading: bool,
    pub failure: Option<PreviewFailure>,
}

/// Problems 面板的范围，对齐 macOS `ProblemsPanelScope`。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ProblemsScope {
    /// 只显示当前编辑器打开的文件。
    #[default]
    File,
    /// 显示整个项目的诊断（macOS 的 "Project Errors"）。
    ProjectErrors,
}

/// Problems 面板的会话状态。
pub struct ProblemsPanelState {
    pub scope: ProblemsScope,
    /// 当前选中的诊断 id（[`crate::editor::DiagnosticItem::id`]）。
    pub selected: Option<String>,
    /// 右侧源码预览是否展开。
    pub preview_enabled: bool,
    pub preview: ProblemPreview,
    /// 预览加载代次：只有最后一次请求可以写回状态。
    pub preview_generation: u64,
    /// 已折叠的文件分组（文件头点击切换）。
    pub collapsed_files: Vec<PathBuf>,
    /// 诊断列表与预览列表的滚动句柄。
    pub list_scroll: VirtualListScrollHandle,
    pub preview_scroll: VirtualListScrollHandle,
}

impl Default for ProblemsPanelState {
    fn default() -> Self {
        Self {
            scope: ProblemsScope::default(),
            selected: None,
            preview_enabled: false,
            preview: ProblemPreview::default(),
            preview_generation: 0,
            collapsed_files: Vec::new(),
            list_scroll: VirtualListScrollHandle::new(),
            preview_scroll: VirtualListScrollHandle::new(),
        }
    }
}

impl ProblemsPanelState {
    /// 切换范围；列表回到顶部，和 macOS 切换分段后重建列表一致。
    pub fn set_scope(&mut self, scope: ProblemsScope) {
        if self.scope == scope {
            return;
        }
        self.scope = scope;
        self.list_scroll.scroll_to_item(0, ScrollStrategy::Top);
    }

    /// 选中一条诊断。id 相同不做任何事，避免重复加载预览。
    pub fn select(&mut self, id: &str) {
        if self.selected.as_deref() == Some(id) {
            return;
        }
        self.selected = Some(id.to_string());
    }

    /// 文件分组是否折叠。
    pub fn is_collapsed(&self, path: &std::path::Path) -> bool {
        self.collapsed_files.iter().any(|entry| entry == path)
    }

    /// 切换文件分组的折叠状态。
    pub fn toggle_collapsed(&mut self, path: &std::path::Path) {
        if let Some(index) = self
            .collapsed_files
            .iter()
            .position(|entry| entry == path)
        {
            self.collapsed_files.remove(index);
        } else {
            self.collapsed_files.push(path.to_path_buf());
        }
    }

    /// 丢弃预览文档；关闭预览、切换诊断或诊断消失时调用。
    pub fn discard_preview(&mut self) {
        self.preview = ProblemPreview::default();
        self.preview_generation = self.preview_generation.wrapping_add(1);
    }

    /// 开始一次预览加载：清掉旧文档、记录目标位置并推进代次。
    pub fn begin_preview(&mut self, path: PathBuf, target_row: usize, target_column: usize) -> u64 {
        self.preview_generation = self.preview_generation.wrapping_add(1);
        self.preview = ProblemPreview {
            path: Some(path),
            target_row,
            target_column,
            lines: Vec::new(),
            loading: true,
            failure: None,
        };
        self.preview_generation
    }

    /// 写回一次加载结果；代次过期时丢弃。
    pub fn finish_preview(
        &mut self,
        generation: u64,
        result: Result<Vec<String>, PreviewFailure>,
    ) -> bool {
        if generation != self.preview_generation {
            return false;
        }
        self.preview.loading = false;
        match result {
            Ok(lines) => {
                self.preview.lines = lines;
                self.preview.failure = None;
                let target = self.preview.target_row;
                self.preview_scroll.scroll_to_item(target, ScrollStrategy::Center);
            }
            Err(failure) => {
                self.preview.lines.clear();
                self.preview.failure = Some(failure);
            }
        }
        true
    }
}

/// 读取一份预览文档。
///
/// 在后台线程调用；行按 `\n` 切分，`\r\n` 的 `\r` 在切分后去掉。
pub fn read_preview(path: &std::path::Path) -> Result<Vec<String>, PreviewFailure> {
    let metadata = std::fs::metadata(path).map_err(|_| PreviewFailure::ReadFailed)?;
    if metadata.len() > PREVIEW_MAX_BYTES {
        return Err(PreviewFailure::TooLarge);
    }
    let text = std::fs::read_to_string(path).map_err(|_| PreviewFailure::ReadFailed)?;
    Ok(text
        .split('\n')
        .map(|line| line.trim_end_matches('\r').to_string())
        .collect())
}
