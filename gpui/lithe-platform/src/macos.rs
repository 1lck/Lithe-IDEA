//! macOS 平台实现。
//!
//! 行为对齐现有的 `MacPlatformUI`：目录/文件单选、解析别名、打开 URL 交给
//! LaunchServices；这里通过 rfd 与 `open` 命令复现，不直接依赖 AppKit。

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::dialog;
use crate::recent_projects;
use crate::{FileFilter, PlatformFuture, PlatformServices};

pub(crate) struct MacPlatform;

impl PlatformServices for MacPlatform {
    fn pick_folder(&self, title: String) -> PlatformFuture<Option<PathBuf>> {
        // macOS 的 NSOpenPanel 只能在主线程完成；`AsyncFileDialog` 用模态
        // future 处理这一点，调用方不要在事件回调里同步阻塞。
        dialog::pick_folder(title)
    }

    fn pick_file(
        &self,
        title: String,
        filters: Vec<FileFilter>,
    ) -> PlatformFuture<Option<PathBuf>> {
        dialog::pick_file(title, filters)
    }

    fn pick_save_path(
        &self,
        title: String,
        default_name: String,
        filters: Vec<FileFilter>,
    ) -> PlatformFuture<Option<PathBuf>> {
        // NSSavePanel 同样只能在主线程完成；`AsyncFileDialog` 用模态 future
        // 处理这一点，调用方不要在事件回调里同步阻塞。
        dialog::save_file(title, default_name, filters)
    }

    fn open_url(&self, url: &str) -> bool {
        // 与 NSWorkspace.open 等价：由 LaunchServices 选择默认浏览器或应用。
        // 使用 spawn 立即返回，避免个别 handler 启动慢时阻塞 UI 线程；
        // 这里只报告“进程能否启动”，不等待目标应用退出。
        Command::new("open").arg(url).spawn().is_ok()
    }

    fn reveal_path(&self, path: &Path) -> bool {
        Command::new("open").arg("-R").arg(path).spawn().is_ok()
    }

    fn recent_projects(&self) -> Vec<PathBuf> {
        recent_projects::load()
    }

    fn remember_project(&self, path: &Path) {
        recent_projects::remember(path);
    }
}
