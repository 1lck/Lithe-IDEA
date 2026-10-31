//! Linux 平台实现。
//!
//! 文件选择使用 rfd（默认走 xdg-desktop-portal），打开 URL 使用 `xdg-open`。

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::dialog;
use crate::recent_projects;
use crate::{FileFilter, PlatformFuture, PlatformServices};

pub(crate) struct LinuxPlatform;

impl PlatformServices for LinuxPlatform {
    fn pick_folder(&self, title: String) -> PlatformFuture<Option<PathBuf>> {
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
        // 与 `pick_file` 统一使用异步对话框（默认走 xdg-desktop-portal），
        // 不混用同步 `FileDialog` 阻塞 UI 线程。
        dialog::save_file(title, default_name, filters)
    }

    fn open_url(&self, url: &str) -> bool {
        // xdg-open 交给桌面环境的默认应用处理。
        // 使用 spawn 立即返回，只报告“进程能否启动”。
        Command::new("xdg-open").arg(url).spawn().is_ok()
    }

    fn reveal_path(&self, path: &Path) -> bool {
        let target = if path.is_file() {
            path.parent().unwrap_or(path)
        } else {
            path
        };
        Command::new("xdg-open").arg(target).spawn().is_ok()
    }

    fn recent_projects(&self) -> Vec<PathBuf> {
        recent_projects::load()
    }

    fn remember_project(&self, path: &Path) {
        recent_projects::remember(path);
    }
}
