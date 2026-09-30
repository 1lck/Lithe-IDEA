//! 工作台文件/目录图标查找：复刻 Windows 图标主题语义。
//!
//! basename 转小写后先查 `filenames` 精确匹配，再按 `.` 切分做多后缀候选
//! （如 `a.d.ts` 依次试 `.d.ts`、`.ts`，空首段无候选）查 `fileExtensions`；
//! 目录按小写目录名查 `folders`/`expandedFolders`；都未命中用默认图标；
//! 浅色主题优先 `lightIconDefinitions` 同 id 的路径，无则回退深色路径。
//! 查找表与 SVG 字节由 `linux/build.rs` 在编译期生成，运行期只做查表、
//! 构造与进程级缓存。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

include!(concat!(env!("OUT_DIR"), "/file_icons_generated.rs"));

/// 进程级解码图标缓存：键为（图标定义 id，是否深色主题）。
static ICON_CACHE: OnceLock<Mutex<HashMap<(String, bool), Arc<gpui_kit::Image>>>> = OnceLock::new();

/// 取路径最后一段，同时处理 `/` 与 `\`（与 Windows 端 basename 语义一致）。
fn basename(path: &str) -> &str {
    path.rsplit(|c| c == '/' || c == '\\')
        .next()
        .unwrap_or(path)
}

/// 转小写待查名；basename 为空时回退整串转小写（对齐 Windows 端的 `||` 兜底）。
fn lookup_name(path: &str) -> String {
    let base = basename(path);
    if base.is_empty() {
        path.to_lowercase()
    } else {
        base.to_lowercase()
    }
}

/// 多后缀候选：`a.d.ts` 依次产出 `.d.ts`、`.ts`；首段为空（点文件）时无候选。
fn extension_candidates(lower_name: &str) -> Vec<String> {
    let parts: Vec<&str> = lower_name.split('.').collect();
    if parts.len() < 2 || parts[0].is_empty() {
        return Vec::new();
    }
    (1..parts.len())
        .map(|i| format!(".{}", parts[i..].join(".")))
        .collect()
}

/// 按定义 id 取 SVG 字节并构造缓存的 [`gpui_kit::Image`]；SVG 缺失返回 `None`。
///
/// 浅色主题先查浅色 definition，无专属路径时回退深色路径。
fn load_icon(def: &str, is_dark: bool) -> Option<Arc<gpui_kit::Image>> {
    if def.is_empty() {
        return None;
    }
    let cache = ICON_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = (def.to_string(), is_dark);
    if let Some(hit) = cache.lock().expect("文件图标缓存锁中毒").get(&key) {
        return Some(hit.clone());
    }
    let bytes = svg_bytes_for_def(def, is_dark)
        .or_else(|| (!is_dark).then(|| svg_bytes_for_def(def, true)).flatten())?;
    let image = Arc::new(gpui_kit::Image::from_bytes(
        gpui_kit::ImageFormat::Svg,
        bytes.to_vec(),
    ));
    cache
        .lock()
        .expect("文件图标缓存锁中毒")
        .insert(key, image.clone());
    Some(image)
}

/// 按文件名查找文件图标；只取 basename，未命中任何表时用默认文件图标。
///
/// 入参与查表键均转小写匹配；对应 SVG 缺失时返回 `None`。
pub fn file_image(file_name: &str, is_dark: bool) -> Option<Arc<gpui_kit::Image>> {
    let name = lookup_name(file_name);
    let def = filename_def(&name)
        .or_else(|| {
            extension_candidates(&name)
                .iter()
                .find_map(|ext| file_extension_def(ext))
        })
        .unwrap_or_else(default_file_def);
    load_icon(def, is_dark)
}

/// 按目录名查找目录图标；只取 basename，未命中时用默认目录图标。
///
/// `expanded` 为真时优先查 `expandedFolders`，再查 `folders`，最后用
/// `defaultFolderOpen`（缺失则用 `defaultFolder`）；为假时只查 `folders`。
pub fn folder_image(dir_name: &str, expanded: bool, is_dark: bool) -> Option<Arc<gpui_kit::Image>> {
    let name = lookup_name(dir_name);
    let def = if expanded {
        expanded_folder_def(&name)
            .or_else(|| folder_def(&name))
            .unwrap_or_else(|| {
                let open = default_folder_open_def();
                if open.is_empty() {
                    default_folder_def()
                } else {
                    open
                }
            })
    } else {
        folder_def(&name).unwrap_or_else(default_folder_def)
    };
    load_icon(def, is_dark)
}
