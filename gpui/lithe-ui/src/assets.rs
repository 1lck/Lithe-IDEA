//! 应用资产源。
//!
//! Lithe 界面只需要两类别处拿不到的资源：
//! - 默认图标包之外的 Lucide 图标（例如顶栏分支入口要用的 `git-branch`）；
//! - 品牌图（顶栏最左侧应用图标）。
//!
//! 图标直接复用 gpui-kit 的全量资源包；品牌图与 Tauri 的
//! `windows/tauri/public/logo.png` 逐字节一致，不重画、不重新导出。gpui-kit
//! 没有提供“组合资产源”的公开工具，因此这里用一层很薄的适配把两份来源拼在
//! 一起，避免把整张品牌图改写成 SVG。

use std::borrow::Cow;

use gpui_kit::assets::AllAssets;
use gpui_kit::{AssetSource, Result, SharedString};

/// 品牌图在资产源里的路径。
///
/// 与图标目录分开，避免和 gpui-kit 的 `icons/**` 冲突。
pub const APP_LOGO_PATH: &str = "lithe/logo.png";

/// 顶栏应用图标。文件来自 Tauri 的 `public/logo.png`。
const APP_LOGO: &[u8] = include_bytes!("../assets/logo.png");

/// Lithe 的资产源：gpui-kit 全量图标 + 品牌图。
#[derive(Clone, Copy, Debug, Default)]
pub struct LitheAssets;

impl AssetSource for LitheAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if path == APP_LOGO_PATH {
            return Ok(Some(Cow::Borrowed(APP_LOGO)));
        }

        AllAssets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut paths = AllAssets.list(path)?;
        if APP_LOGO_PATH.starts_with(path) {
            paths.push(APP_LOGO_PATH.into());
        }
        Ok(paths)
    }
}
