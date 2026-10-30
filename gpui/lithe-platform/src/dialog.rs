//! 原生文件对话框的异步封装。
//!
//! 不能使用 `rfd::FileDialog` 的同步 API：它在 GPUI 的鼠标/键盘事件回调里
//! 会运行自己的模态消息循环，Windows 上重入 GPUI 窗口借用会直接 abort
//! （`STATUS_STACK_BUFFER_OVERRUN`）。`AsyncFileDialog` 在 Windows 上把对话框
//! 放到独立线程，在 macOS 上使用模态 future；调用方在 GPUI 主线程 await 即可。

use std::path::PathBuf;

use crate::{FileFilter, PlatformFuture};

/// 异步选择单个目录。
pub(crate) fn pick_folder(title: String) -> PlatformFuture<Option<PathBuf>> {
    Box::pin(async move {
        rfd::AsyncFileDialog::new()
            .set_title(title)
            .pick_folder()
            .await
            .map(|handle| handle.path().to_path_buf())
    })
}

/// 异步选择单个文件。
pub(crate) fn pick_file(
    title: String,
    filters: Vec<FileFilter>,
) -> PlatformFuture<Option<PathBuf>> {
    Box::pin(async move {
        let mut dialog = rfd::AsyncFileDialog::new().set_title(title);
        for filter in filters {
            // 空扩展名列表在部分后端会生成匹配不到任何文件的过滤器，
            // 直接跳过，保持“未指定过滤条件”的语义。
            if filter.extensions.is_empty() {
                continue;
            }
            let FileFilter { name, extensions } = filter;
            dialog = dialog.add_filter(name, extensions.as_slice());
        }
        dialog
            .pick_file()
            .await
            .map(|handle| handle.path().to_path_buf())
    })
}

/// 异步选择保存路径。
///
/// `default_name` 只作为对话框里的文件名建议；本层不会创建或写入文件，
/// 落盘由调用方拿到路径后自行完成。
pub(crate) fn save_file(
    title: String,
    default_name: String,
    filters: Vec<FileFilter>,
) -> PlatformFuture<Option<PathBuf>> {
    Box::pin(async move {
        // 与 `pick_file` 保持一致：同样使用异步对话框，避免同步模态循环
        // 重入 GPUI 窗口借用。
        let mut dialog = rfd::AsyncFileDialog::new()
            .set_title(title)
            .set_file_name(default_name);
        for filter in filters {
            // 空扩展名列表会被部分后端渲染成匹配不到任何文件的过滤器，
            // 与 `pick_file` 一样直接跳过。
            if filter.extensions.is_empty() {
                continue;
            }
            let FileFilter { name, extensions } = filter;
            dialog = dialog.add_filter(name, extensions.as_slice());
        }
        // 覆盖确认由各平台原生对话框负责；用户取消时返回 `None`。
        dialog
            .save_file()
            .await
            .map(|handle| handle.path().to_path_buf())
    })
}
