//! Windows 平台实现。
//!
//! 文件选择使用 rfd（原生 IFileDialog），打开 URL 使用 `cmd /C start`。

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::dialog;
use crate::recent_projects;
use crate::{FileFilter, PlatformFuture, PlatformServices};

pub(crate) struct WindowsPlatform;

impl PlatformServices for WindowsPlatform {
    fn pick_folder(&self, title: String) -> PlatformFuture<Option<PathBuf>> {
        // 必须用异步对话框：同步 `FileDialog` 会在这里启动模态消息循环，
        // 重入 GPUI 的窗口借用并 abort。
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
        // 与 `pick_file` 一样走异步对话框：同步 `FileDialog` 会在这里启动
        // 模态消息循环，重入 GPUI 的窗口借用并 abort。
        dialog::save_file(title, default_name, filters)
    }

    fn open_url(&self, url: &str) -> bool {
        // rundll32 直接把 URL 交给 shell 的协议处理器，不经过 cmd，
        // 避免 URL 里的 &、^、| 被命令解释器拆分。
        // 使用 spawn 立即返回，只报告“进程能否启动”。
        Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", url])
            .spawn()
            .is_ok()
    }

    fn reveal_path(&self, path: &Path) -> bool {
        let text = path.to_string_lossy();
        let clean_path = if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
            format!(r"\\{rest}")
        } else if let Some(rest) = text.strip_prefix(r"\\?\") {
            rest.to_string()
        } else {
            text.into_owned()
        };
        Command::new("explorer")
            .arg(format!("/select,{clean_path}"))
            .spawn()
            .is_ok()
    }

    fn recent_projects(&self) -> Vec<PathBuf> {
        recent_projects::load()
    }

    fn remember_project(&self, path: &Path) {
        recent_projects::remember(path);
    }
}
