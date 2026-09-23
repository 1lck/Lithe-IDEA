use gpui_kit::Rgba;
#[allow(unused_imports)]
pub use gpui_kit::assets::IconName;
#[allow(unused_imports)]
pub use gpui_kit::component::Icon;

pub const fn const_rgb(hex: u32) -> Rgba {
    let r = ((hex >> 16) & 0xFF) as f32 / 255.0;
    let g = ((hex >> 8) & 0xFF) as f32 / 255.0;
    let b = (hex & 0xFF) as f32 / 255.0;
    Rgba { r, g, b, a: 1.0 }
}

pub struct ThemeColors;

#[allow(dead_code)]
impl ThemeColors {
    pub const BG_TITLEBAR: Rgba = const_rgb(0x1e1f22);
    pub const BG_ACTIVITY_RAIL: Rgba = const_rgb(0x18191c);
    pub const BG_SIDEBAR: Rgba = const_rgb(0x1e1f22);
    pub const BG_EDITOR: Rgba = const_rgb(0x2b2d30);
    pub const BG_TAB_BAR: Rgba = const_rgb(0x1e1f22);
    pub const BG_TAB_ACTIVE: Rgba = const_rgb(0x2b2d30);
    pub const BG_TAB_HOVER: Rgba = const_rgb(0x26282c);
    pub const BG_BOTTOM_PANEL: Rgba = const_rgb(0x1e1f22);
    pub const BG_STATUSBAR: Rgba = const_rgb(0x18191c);
    pub const BORDER: Rgba = const_rgb(0x323438);
    pub const ACCENT_BLUE: Rgba = const_rgb(0x3574f0);
    pub const ACCENT_GREEN: Rgba = const_rgb(0x39a36b);
    pub const ACCENT_YELLOW: Rgba = const_rgb(0xd29922);
    pub const ACCENT_RED: Rgba = const_rgb(0xe02e2a);
    pub const TEXT_PRIMARY: Rgba = const_rgb(0xdfdfe0);
    pub const TEXT_MUTED: Rgba = const_rgb(0x818594);
    pub const SUBTLE_SELECTION: Rgba = const_rgb(0x26282d);

    #[inline]
    pub fn bg_titlebar() -> Rgba {
        Self::BG_TITLEBAR
    }
    #[inline]
    pub fn bg_activity_rail() -> Rgba {
        Self::BG_ACTIVITY_RAIL
    }
    #[inline]
    pub fn bg_sidebar() -> Rgba {
        Self::BG_SIDEBAR
    }
    #[inline]
    pub fn bg_editor() -> Rgba {
        Self::BG_EDITOR
    }
    #[inline]
    pub fn bg_tab_bar() -> Rgba {
        Self::BG_TAB_BAR
    }
    #[inline]
    pub fn bg_tab_active() -> Rgba {
        Self::BG_TAB_ACTIVE
    }
    #[inline]
    pub fn bg_tab_hover() -> Rgba {
        Self::BG_TAB_HOVER
    }
    #[inline]
    pub fn bg_bottom_panel() -> Rgba {
        Self::BG_BOTTOM_PANEL
    }
    #[inline]
    pub fn bg_statusbar() -> Rgba {
        Self::BG_STATUSBAR
    }
    #[inline]
    pub fn border() -> Rgba {
        Self::BORDER
    }
    #[inline]
    pub fn accent_blue() -> Rgba {
        Self::ACCENT_BLUE
    }
    #[inline]
    pub fn accent_green() -> Rgba {
        Self::ACCENT_GREEN
    }
    #[inline]
    pub fn accent_yellow() -> Rgba {
        Self::ACCENT_YELLOW
    }
    #[inline]
    pub fn accent_red() -> Rgba {
        Self::ACCENT_RED
    }
    #[inline]
    pub fn text_primary() -> Rgba {
        Self::TEXT_PRIMARY
    }
    #[inline]
    pub fn text_muted() -> Rgba {
        Self::TEXT_MUTED
    }
    #[inline]
    pub fn subtle_selection() -> Rgba {
        Self::SUBTLE_SELECTION
    }
}
