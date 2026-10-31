//! Lithe 的三套主题 token。
//!
//! Lithe 的色值来自 `gpui/ARCHITECTURE.md` 的冻结表；Codex 与 Linear 不是在这里
//! 另抄一份，而是按 `macos/Sources/Lithe/Theme/LitheTheme.swift` 的
//! `Palette.make` 公式在 sRGB 空间里换算，保证两端观感一致。

use gpui_kit::{Hsla, Rgba, rgb};

/// Lithe 支持的主题族。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LitheThemeKind {
    Lithe,
    Codex,
    Linear,
}

/// 工作台使用的颜色 token。
///
/// 组件只能从这里取色，不能在视图调用点写死十六进制。
#[derive(Clone, Copy, Debug)]
pub struct LitheTokens {
    pub window: Hsla,
    pub titlebar: Hsla,
    pub tool_header: Hsla,
    pub sidebar: Hsla,
    pub editor: Hsla,
    pub raised: Hsla,
    pub selection: Hsla,
    pub subtle_selection: Hsla,
    pub hover: Hsla,
    pub pressed: Hsla,
    pub divider: Hsla,
    pub panel_border: Hsla,
    pub primary_text: Hsla,
    pub secondary_text: Hsla,
    pub tertiary_text: Hsla,
    /// 工具窗口（活动栏）按钮图标：未选中态。
    pub tool_window_button_text: Hsla,
    /// 工具窗口（活动栏）按钮图标：选中态（压在 selection 底色上）。
    pub tool_window_selected_text: Hsla,
    pub accent: Hsla,
    pub run: Hsla,
    pub success: Hsla,
    pub warning: Hsla,
    pub error: Hsla,
    pub link: Hsla,
    pub diff_inserted: Hsla,
    pub diff_deleted: Hsla,
    pub diff_modified: Hsla,
}

impl LitheTokens {
    pub fn for_theme(kind: LitheThemeKind, dark: bool) -> Self {
        match kind {
            LitheThemeKind::Lithe => lithe(dark),
            LitheThemeKind::Codex => codex(dark),
            LitheThemeKind::Linear => linear(dark),
        }
    }
}

// ---------------------------------------------------------------------------
// Lithe：ARCHITECTURE.md 的冻结色值
// ---------------------------------------------------------------------------

fn lithe(dark: bool) -> LitheTokens {
    if dark {
        LitheTokens {
            window: hex(0x28292C),
            titlebar: hex(0x28292C),
            tool_header: hex(0x191A1C),
            sidebar: hex(0x191A1C),
            editor: hex(0x191A1C),
            raised: hex(0x2A2D31),
            selection: hex(0x3574F0),
            subtle_selection: hex(0x34383D),
            hover: white_alpha(0.09),
            pressed: white_alpha(0.095),
            divider: hex(0x2E3036),
            panel_border: hex(0x434546),
            primary_text: hex(0xDFE1E5),
            secondary_text: white_alpha(0.50),
            tertiary_text: white_alpha(0.34),
            // LitheTheme.swift:219 `toolWindowButtonText: isDark ? RGBA(0x9DA0A8)
            // : secondaryText`：深色是固定的不透明灰，不能沿用 secondaryText 的
            // 白色 50%。
            tool_window_button_text: hex(0x9DA0A8),
            // LitheTheme.swift:220 `toolWindowSelectedText` 明暗都是不透明白。
            tool_window_selected_text: gpui_kit::white(),
            accent: hex(0x3574F0),
            run: hex(0x59A869),
            success: hex(0x47B863),
            warning: hex(0xE8A033),
            error: hex(0xEB5454),
            link: hex(0x6BAEFF),
            diff_inserted: hex(0x294436),
            diff_deleted: hex(0x484A4A),
            diff_modified: hex(0x385570),
        }
    } else {
        LitheTokens {
            window: hex(0xEEF1F5),
            titlebar: hex(0xE8EBEF),
            tool_header: hex(0xFBFBFB),
            sidebar: hex(0xFFFFFF),
            editor: hex(0xFFFFFF),
            raised: hex(0xF7F8FA),
            selection: hex(0x3574F0),
            subtle_selection: hex(0xE9EBEF),
            hover: hex(0xF2F3F5),
            pressed: hex(0xE1E3E7),
            divider: hex(0xD8DADF),
            panel_border: hex(0xC9CCD2),
            primary_text: hex(0x1F2329),
            secondary_text: hex(0x5F6570),
            tertiary_text: hex(0x818892),
            // LitheTheme.swift:219 浅色直接取 `secondaryText`，即
            // `adaptive(light: (0.373, 0.396, 0.439, 1))`（LitheTheme.swift:188）。
            tool_window_button_text: hex(0x5F6570),
            // LitheTheme.swift:220 明暗都是不透明白。
            tool_window_selected_text: gpui_kit::white(),
            accent: hex(0x3574F0),
            run: hex(0x2E7D32),
            success: hex(0x1B8B3C),
            warning: hex(0xB06909),
            error: hex(0xC72D2D),
            link: hex(0x1A5CB8),
            diff_inserted: hex(0xBEE6BE),
            diff_deleted: hex(0xD6D6D6),
            diff_modified: hex(0xC2D8F2),
        }
    }
}

// ---------------------------------------------------------------------------
// Codex / Linear：按 LitheTheme.swift 的 Palette.make 换算
// ---------------------------------------------------------------------------

fn codex(dark: bool) -> LitheTokens {
    let (surface, ink, accent, added, removed, contrast) = if dark {
        (
            hex(0x111111),
            hex(0xFCFCFC),
            hex(0x0169CC),
            hex(0x00A240),
            hex(0xE02E2A),
            0.60,
        )
    } else {
        (
            hex(0xFFFFFF),
            hex(0x0D0D0D),
            hex(0x0169CC),
            hex(0x00A240),
            hex(0xE02E2A),
            0.45,
        )
    };
    derived_chrome(surface, ink, accent, added, removed, contrast, dark)
}

fn linear(dark: bool) -> LitheTokens {
    let (surface, ink, accent, added, removed, contrast) = if dark {
        (
            hex(0x0F0F11),
            hex(0xE3E4E6),
            hex(0x606ACC),
            hex(0x69C967),
            hex(0xFF7E78),
            0.60,
        )
    } else {
        (
            hex(0xFCFCFD),
            hex(0x1B1B1B),
            hex(0x5E6AD2),
            hex(0x52A450),
            hex(0xC94446),
            0.45,
        )
    };
    derived_chrome(surface, ink, accent, added, removed, contrast, dark)
}

/// `Palette.make` 里 Codex / Linear 共用的推导部分。
fn derived_chrome(
    surface: Hsla,
    ink: Hsla,
    accent: Hsla,
    diff_added: Hsla,
    diff_removed: Hsla,
    contrast: f32,
    dark: bool,
) -> LitheTokens {
    // Swift: (isDark ? 0.075 : 0.055) * (contrast / 0.45)
    let strong_chrome_amount = (if dark { 0.075 } else { 0.055 }) * (contrast / 0.45);
    let subtle_accent = mix(surface, accent, if dark { 0.20 } else { 0.11 });
    // `Diff` 枚举用的是 IDEA 配色，与主题族无关；这里沿用同一组值。
    let (diff_inserted, diff_deleted, diff_modified) = if dark {
        (hex(0x294436), hex(0x484A4A), hex(0x385570))
    } else {
        (hex(0xBEE6BE), hex(0xD6D6D6), hex(0xC2D8F2))
    };

    let chrome_surface = mix(surface, ink, strong_chrome_amount);

    LitheTokens {
        window: chrome_surface,
        titlebar: chrome_surface,
        tool_header: surface,
        sidebar: surface,
        editor: surface,
        raised: mix(surface, ink, if dark { 0.085 } else { 0.018 }),
        selection: accent,
        subtle_selection: subtle_accent,
        hover: ink.alpha(if dark { 0.065 } else { 0.055 }),
        pressed: ink.alpha(if dark { 0.11 } else { 0.095 }),
        divider: ink.alpha(if dark { 0.10 } else { 0.12 }),
        panel_border: ink.alpha(0.16),
        primary_text: ink,
        secondary_text: ink.alpha(if dark { 0.62 } else { 0.60 }),
        tertiary_text: ink.alpha(if dark { 0.43 } else { 0.42 }),
        // Codex / Linear 没有独立的 toolWindowButtonText 定义，走
        // `Palette.make` 的通用推导（LitheTheme.swift:166）：
        // `toolWindowButtonText: ink.withAlpha(isDark ? 0.62 : 0.60)`。
        // 与上面的 secondaryText 同式，但按 Swift 源码单独写一次，避免两者
        // 将来被分别调整时失去对应关系。
        tool_window_button_text: ink.alpha(if dark { 0.62 } else { 0.60 }),
        // LitheTheme.swift:167 `toolWindowSelectedText: RGBA(0xffffff)`，不随明暗变化。
        tool_window_selected_text: gpui_kit::white(),
        accent,
        // Swift runAction: 深色 0x59A869 / 浅色 0x2E7D32。
        run: if dark { hex(0x59A869) } else { hex(0x2E7D32) },
        success: diff_added,
        warning: if dark { hex(0xE6A23C) } else { hex(0xA96500) },
        error: diff_removed,
        link: accent,
        diff_inserted,
        diff_deleted,
        diff_modified,
    }
}

// ---------------------------------------------------------------------------
// 颜色工具
// ---------------------------------------------------------------------------

fn hex(value: u32) -> Hsla {
    Hsla::from(rgb(value))
}

fn white_alpha(alpha: f32) -> Hsla {
    gpui_kit::white().alpha(alpha)
}

/// 在 sRGB 空间按 Swift `RGBA.mixed` 的语义混合（含 alpha）。
fn mix(from: Hsla, to: Hsla, amount: f32) -> Hsla {
    let amount = amount.clamp(0., 1.);
    let from = Rgba::from(from);
    let to = Rgba::from(to);
    Hsla::from(Rgba {
        r: from.r + (to.r - from.r) * amount,
        g: from.g + (to.g - from.g) * amount,
        b: from.b + (to.b - from.b) * amount,
        a: from.a + (to.a - from.a) * amount,
    })
}
