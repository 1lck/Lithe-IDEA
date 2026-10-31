//! 平台服务层。
//!
//! 这里实现 `ARCHITECTURE.md` 约定的最小平台接口：选择文件/目录、打开 URL、
//! 最近项目。调用方只依赖 [`PlatformServices`]，平台差异收敛在
//! `macos` / `windows` / `linux` 三个实现模块中。

mod dialog;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
mod recent_projects;
#[cfg(target_os = "windows")]
mod windows;

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

/// 平台对话框返回的 future。
///
/// 不使用 `Send` bound：macOS 的模态对话框只能在主线程完成，GPUI 侧要用
/// `cx.spawn_in`（主线程任务），而不是 `background_spawn`。
pub type PlatformFuture<T> = Pin<Box<dyn Future<Output = T> + 'static>>;

/// 文件选择框的过滤器。
///
/// `extensions` 由调用方提供，按惯例不带前导点，例如 `["rs", "toml"]`。
#[derive(Debug, Clone)]
pub struct FileFilter {
    pub name: String,
    pub extensions: Vec<String>,
}

/// 平台相关能力的统一入口。
///
/// 实现必须可跨线程共享。返回 `None` 表示用户取消或系统能力不可用，
/// 不表示发生了需要向上报告的错误。
///
/// 选择框返回异步 future：不能在 GPUI 的鼠标/键盘事件回调里同步打开原生
/// 模态框，否则 Windows 对话框消息循环会重入 GPUI 窗口借用并直接 abort。
/// 调用方应在事件回调里 `cx.spawn_in(window, ...)`，await 结果后再更新视图。
pub trait PlatformServices: Send + Sync + 'static {
    /// 选择单个文件夹；用户取消时返回 `None`。
    fn pick_folder(&self, title: String) -> PlatformFuture<Option<PathBuf>>;

    /// 选择单个文件；`filters` 为空时不附加任何过滤条件。
    fn pick_file(&self, title: String, filters: Vec<FileFilter>)
    -> PlatformFuture<Option<PathBuf>>;

    /// 选择保存路径；`default_name` 只作为文件名建议，不写盘。
    ///
    /// 返回 `None` 表示用户取消或系统不支持保存对话框。拿到路径后是否
    /// 覆盖已有文件由原生对话框确认，本层不额外检查文件是否存在。
    fn pick_save_path(
        &self,
        title: String,
        default_name: String,
        filters: Vec<FileFilter>,
    ) -> PlatformFuture<Option<PathBuf>>;

    /// 用系统默认方式打开 URL；命令无法启动时为 `false`。
    /// 启动后是否被系统正确处理不由本层判断。
    fn open_url(&self, url: &str) -> bool;

    /// 在系统文件管理器中定位并选中指定路径；无法启动时为 `false`。
    fn reveal_path(&self, path: &Path) -> bool;

    /// 最近打开过的项目，最近使用的排在最前面。
    fn recent_projects(&self) -> Vec<PathBuf>;

    /// 记录一次项目打开，并同步更新持久化列表。
    fn remember_project(&self, path: &Path);
}

/// 返回当前平台的服务实现。
#[cfg(target_os = "macos")]
pub fn current() -> Arc<dyn PlatformServices> {
    Arc::new(macos::MacPlatform)
}

/// 返回当前平台的服务实现。
#[cfg(target_os = "windows")]
pub fn current() -> Arc<dyn PlatformServices> {
    Arc::new(windows::WindowsPlatform)
}

/// 返回当前平台的服务实现。
#[cfg(target_os = "linux")]
pub fn current() -> Arc<dyn PlatformServices> {
    Arc::new(linux::LinuxPlatform)
}

/// 返回当前平台的服务实现。
///
/// 未知平台会得到显式的 `UnsupportedPlatform`：对话框与 URL 打开不可用，
/// 最近项目仍写入平台候选目录，保证欢迎页不会因此崩溃。
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
pub fn current() -> Arc<dyn PlatformServices> {
    Arc::new(UnsupportedPlatform)
}

/// 未知平台的兜底实现。
///
/// 没有可用的原生选择框或 URL 打开器，但最近项目列表仍使用 XDG 目录，
/// 因此这里只禁用两项能力，不影响欢迎页加载历史。
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
struct UnsupportedPlatform;

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
impl PlatformServices for UnsupportedPlatform {
    fn pick_folder(&self, _title: String) -> PlatformFuture<Option<PathBuf>> {
        Box::pin(async { None })
    }

    fn pick_file(
        &self,
        _title: String,
        _filters: Vec<FileFilter>,
    ) -> PlatformFuture<Option<PathBuf>> {
        Box::pin(async { None })
    }

    /// 未知平台没有原生保存对话框，直接报告“用户取消”。
    fn pick_save_path(
        &self,
        _title: String,
        _default_name: String,
        _filters: Vec<FileFilter>,
    ) -> PlatformFuture<Option<PathBuf>> {
        Box::pin(async { None })
    }

    fn open_url(&self, _url: &str) -> bool {
        false
    }

    fn reveal_path(&self, _path: &Path) -> bool {
        false
    }

    fn recent_projects(&self) -> Vec<PathBuf> {
        recent_projects::load()
    }

    fn remember_project(&self, path: &Path) {
        recent_projects::remember(path);
    }
}
