//! 工作台配色真源：对齐 Tauri 端 `lithe-dark` / `lithe-light` 主题 token。
//!
//! 调色板在运行时通过 [`set_palette`] 切换，[`ThemeColors`] 的访问器读取当前
//! 调色板，因此所有视图无需持有 `Context` 即可跟随主题变化。

use std::sync::RwLock;

use gpui_kit::Rgba;

#[allow(unused_imports)]
pub use gpui_kit::assets::IconName;
#[allow(unused_imports)]
pub use gpui_kit::component::Icon;

/// 由 `0xRRGGBB` 构造不透明颜色。
pub const fn const_rgb(hex: u32) -> Rgba {
    const_rgba(hex, 1.0)
}

/// 由 `0xRRGGBB` 与 alpha 构造颜色。
pub const fn const_rgba(hex: u32, a: f32) -> Rgba {
    let r = ((hex >> 16) & 0xFF) as f32 / 255.0;
    let g = ((hex >> 8) & 0xFF) as f32 / 255.0;
    let b = (hex & 0xFF) as f32 / 255.0;
    Rgba { r, g, b, a }
}

/// 在两个颜色之间按 `t`（0..=1）线性插值，保留 `a` 的 alpha。
pub fn mix(from: Rgba, to: Rgba, t: f32) -> Rgba {
    let t = t.clamp(0.0, 1.0);
    Rgba {
        r: from.r + (to.r - from.r) * t,
        g: from.g + (to.g - from.g) * t,
        b: from.b + (to.b - from.b) * t,
        a: from.a,
    }
}

/// 一套完整的工作台配色，字段名与 Tauri 主题 token 对应。
///
/// 部分 token（git/syntax/terminal 等）当前视图尚未消费，但作为主题真源保留，
/// 供后续编辑器高亮与终端渲染直接取用。
#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub struct ThemePalette {
    pub background: Rgba,
    pub surface: Rgba,
    pub foreground: Rgba,
    pub muted_foreground: Rgba,
    pub subtle_foreground: Rgba,
    pub border: Rgba,
    pub accent: Rgba,
    pub selected: Rgba,
    pub selection: Rgba,
    pub primary: Rgba,
    pub destructive: Rgba,
    pub success: Rgba,
    pub warning: Rgba,
    pub info: Rgba,
    pub git_modified: Rgba,
    pub git_added: Rgba,
    pub git_deleted: Rgba,
    pub git_untracked: Rgba,
    pub git_renamed: Rgba,
    pub terminal_black: Rgba,
    pub terminal_red: Rgba,
    pub terminal_green: Rgba,
    pub terminal_yellow: Rgba,
    pub terminal_blue: Rgba,
    pub terminal_magenta: Rgba,
    pub terminal_cyan: Rgba,
    pub terminal_white: Rgba,
    pub syntax_comment: Rgba,
    pub syntax_keyword: Rgba,
    pub syntax_string: Rgba,
    pub syntax_number: Rgba,
    pub syntax_function: Rgba,
    pub syntax_variable: Rgba,
    pub syntax_type: Rgba,
    pub syntax_constant: Rgba,
    pub syntax_property: Rgba,
}

impl ThemePalette {
    /// `lithe-dark`：分层中性表面与 Lithe 蓝强调色。
    pub const fn dark() -> Self {
        Self {
            background: const_rgb(0x1e1f22),
            surface: const_rgb(0x2b2d30),
            foreground: const_rgb(0xdfe1e5),
            muted_foreground: const_rgb(0xb4b8bf),
            subtle_foreground: const_rgb(0x8b929e),
            border: const_rgb(0x43454a),
            accent: const_rgb(0x393b40),
            selected: const_rgb(0x2e436e),
            selection: const_rgba(0x214283, 1.0),
            primary: const_rgb(0x3574f0),
            destructive: const_rgb(0xdb5c5c),
            success: const_rgb(0x57965c),
            warning: const_rgb(0xd6ae58),
            info: const_rgb(0x548af7),
            git_modified: const_rgb(0xd9a441),
            git_added: const_rgb(0x4cc38a),
            git_deleted: const_rgb(0xf16d75),
            git_untracked: const_rgb(0x58a6e7),
            git_renamed: const_rgb(0xc8a2f4),
            terminal_black: const_rgb(0x0f1012),
            terminal_red: const_rgb(0xf16d75),
            terminal_green: const_rgb(0x4cc38a),
            terminal_yellow: const_rgb(0xd9a441),
            terminal_blue: const_rgb(0x58a6e7),
            terminal_magenta: const_rgb(0xc8a2f4),
            terminal_cyan: const_rgb(0x61c0bf),
            terminal_white: const_rgb(0xc4c9d1),
            syntax_comment: const_rgb(0x7a7e85),
            syntax_keyword: const_rgb(0xcf8e6d),
            syntax_string: const_rgb(0x6aab73),
            syntax_number: const_rgb(0x2aacb8),
            syntax_function: const_rgb(0x56a8f5),
            syntax_variable: const_rgb(0xbcbec4),
            syntax_type: const_rgb(0xbcbec4),
            syntax_constant: const_rgb(0xc77dbb),
            syntax_property: const_rgb(0xc77dbb),
        }
    }

    /// `lithe-light`：清晰中性表面与高对比文本。
    pub const fn light() -> Self {
        Self {
            background: const_rgb(0xffffff),
            surface: const_rgb(0xf7f8fa),
            foreground: const_rgb(0x1f2328),
            muted_foreground: const_rgb(0x4f5965),
            subtle_foreground: const_rgb(0x68717d),
            border: const_rgb(0xdfe1e5),
            accent: const_rgb(0xedf3ff),
            selected: const_rgb(0xd4e2ff),
            selection: const_rgba(0x3574f0, 0.2),
            primary: const_rgb(0x3574f0),
            destructive: const_rgb(0xcf3f4f),
            success: const_rgb(0x27864f),
            warning: const_rgb(0xa86400),
            info: const_rgb(0x3574f0),
            git_modified: const_rgb(0xa86400),
            git_added: const_rgb(0x27864f),
            git_deleted: const_rgb(0xcf3f4f),
            git_untracked: const_rgb(0x0877c1),
            git_renamed: const_rgb(0x7656a8),
            terminal_black: const_rgb(0x1f2328),
            terminal_red: const_rgb(0xcf3f4f),
            terminal_green: const_rgb(0x27864f),
            terminal_yellow: const_rgb(0xa86400),
            terminal_blue: const_rgb(0x0877c1),
            terminal_magenta: const_rgb(0x8a4fb0),
            terminal_cyan: const_rgb(0x147d83),
            terminal_white: const_rgb(0x68717d),
            syntax_comment: const_rgb(0x68717d),
            syntax_keyword: const_rgb(0xb83280),
            syntax_string: const_rgb(0x287d3c),
            syntax_number: const_rgb(0xa15c00),
            syntax_function: const_rgb(0x14777d),
            syntax_variable: const_rgb(0x7656a8),
            syntax_type: const_rgb(0x4169a8),
            syntax_constant: const_rgb(0xa15c00),
            syntax_property: const_rgb(0x075e9e),
        }
    }

    /// 按主题 id 解析内置调色板；未知 id 返回 `None`，由调用方回退。
    pub fn for_theme_id(theme_id: &str) -> Option<Self> {
        match theme_id {
            "lithe-light" => Some(Self::light()),
            "lithe-dark" => Some(Self::dark()),
            _ => None,
        }
    }

    /// 该主题是否为浅色外观。
    pub fn is_light(theme_id: &str) -> bool {
        theme_id == "lithe-light"
    }

    /// `border-strong`：边框与前景按 72/28 混合。
    pub fn border_strong(&self) -> Rgba {
        mix(self.border, self.foreground, 0.28)
    }

    /// `tab-hover-bg`：强调色 72% 叠在背景之上。
    pub fn tab_hover(&self) -> Rgba {
        mix(self.background, self.accent, 0.72)
    }
}

static CURRENT_PALETTE: RwLock<ThemePalette> = RwLock::new(ThemePalette::dark());

/// 切换当前工作台调色板；调用方随后需刷新窗口。
pub fn set_palette(palette: ThemePalette) {
    if let Ok(mut current) = CURRENT_PALETTE.write() {
        *current = palette;
    }
}

/// 当前生效的工作台调色板。
pub fn palette() -> ThemePalette {
    CURRENT_PALETTE
        .read()
        .map(|p| *p)
        .unwrap_or_else(|_| ThemePalette::dark())
}

/// 语义化颜色访问器。旧命名保留为别名，避免视图层大范围重写。
pub struct ThemeColors;

#[allow(dead_code)]
impl ThemeColors {
    // ---- Tauri token 命名 ----
    #[inline]
    pub fn background() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn surface() -> Rgba {
        palette().surface
    }
    #[inline]
    pub fn foreground() -> Rgba {
        palette().foreground
    }
    #[inline]
    pub fn muted_foreground() -> Rgba {
        palette().muted_foreground
    }
    #[inline]
    pub fn subtle_foreground() -> Rgba {
        palette().subtle_foreground
    }
    #[inline]
    pub fn border() -> Rgba {
        palette().border
    }
    #[inline]
    pub fn border_strong() -> Rgba {
        palette().border_strong()
    }
    #[inline]
    pub fn accent() -> Rgba {
        palette().accent
    }
    #[inline]
    pub fn selected() -> Rgba {
        palette().selected
    }
    #[inline]
    pub fn selection() -> Rgba {
        palette().selection
    }
    #[inline]
    pub fn primary() -> Rgba {
        palette().primary
    }
    #[inline]
    pub fn destructive() -> Rgba {
        palette().destructive
    }
    #[inline]
    pub fn success() -> Rgba {
        palette().success
    }
    #[inline]
    pub fn warning() -> Rgba {
        palette().warning
    }
    #[inline]
    pub fn info() -> Rgba {
        palette().info
    }
    #[inline]
    pub fn git_modified() -> Rgba {
        palette().git_modified
    }
    #[inline]
    pub fn git_added() -> Rgba {
        palette().git_added
    }
    #[inline]
    pub fn git_deleted() -> Rgba {
        palette().git_deleted
    }
    #[inline]
    pub fn git_untracked() -> Rgba {
        palette().git_untracked
    }
    #[inline]
    pub fn git_renamed() -> Rgba {
        palette().git_renamed
    }

    // ---- 兼容旧访问器（映射到 Tauri token） ----
    #[inline]
    pub fn bg_titlebar() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn bg_activity_rail() -> Rgba {
        palette().surface
    }
    #[inline]
    pub fn bg_sidebar() -> Rgba {
        palette().surface
    }
    #[inline]
    pub fn bg_editor() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn bg_tab_bar() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn bg_tab_active() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn bg_tab_hover() -> Rgba {
        palette().tab_hover()
    }
    #[inline]
    pub fn bg_bottom_panel() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn bg_statusbar() -> Rgba {
        palette().background
    }
    #[inline]
    pub fn accent_blue() -> Rgba {
        palette().primary
    }
    #[inline]
    pub fn accent_green() -> Rgba {
        palette().success
    }
    #[inline]
    pub fn accent_yellow() -> Rgba {
        palette().warning
    }
    #[inline]
    pub fn accent_red() -> Rgba {
        palette().destructive
    }
    #[inline]
    pub fn text_primary() -> Rgba {
        palette().foreground
    }
    #[inline]
    pub fn text_muted() -> Rgba {
        palette().subtle_foreground
    }
    #[inline]
    pub fn subtle_selection() -> Rgba {
        palette().accent
    }
}
