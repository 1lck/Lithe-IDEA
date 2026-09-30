use gpui::prelude::*;
use gpui::{rems, svg, App, Rems, Window};
use rgitui_theme::Color;

/// Icon names mapping to SVG assets loaded by path from the `assets/icons/` directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IconName {
    // Git
    GitBranch,
    GitCommit,
    GitMerge,
    GitPullRequest,
    GitCompare,

    // File states
    FileAdded,
    FileModified,
    FileDeleted,
    FileRenamed,
    FileConflict,

    // Navigation
    ChevronRight,
    ChevronDown,
    ChevronLeft,
    ChevronUp,
    ArrowUp,
    ArrowDown,

    // Actions
    Plus,
    Minus,
    Check,
    X,
    Search,
    Refresh,
    Copy,
    Trash,
    Edit,
    Eye,
    EyeOff,
    ExternalLink,
    Settings,
    Undo,
    Redo,

    // Objects
    Star,
    Pin,
    Clock,
    User,
    Folder,
    File,
    Tag,
    Stash,
    Terminal,

    // AI
    Sparkle,

    // Status
    Info,
    CheckCircle,
    HalfCircle,
    XCircle,
    AlertTriangle,
    Lock,

    // Misc
    Dot,
    DotOutline,
    Menu,

    // Window controls
    Maximize,
    Minimize,
    Close,
    Restore,
    MoreHorizontal,
    GripVertical,
}

impl IconName {
    /// SVG asset path for this icon, relative to the `assets/icons/` directory.
    pub fn path(&self) -> &'static str {
        match self {
            IconName::GitBranch => "icons/git-branch.svg",
            IconName::GitCommit => "icons/git-commit.svg",
            IconName::GitMerge => "icons/git-merge.svg",
            IconName::GitPullRequest => "icons/git-pull-request.svg",
            IconName::GitCompare => "icons/git-compare.svg",
            IconName::FileAdded => "icons/file-plus.svg",
            IconName::FileModified => "icons/file-diff.svg",
            IconName::FileDeleted => "icons/file-minus.svg",
            IconName::FileRenamed => "icons/file-symlink.svg",
            IconName::FileConflict => "icons/alert-triangle.svg",
            IconName::ChevronRight => "icons/chevron-right.svg",
            IconName::ChevronDown => "icons/chevron-down.svg",
            IconName::ChevronLeft => "icons/chevron-left.svg",
            IconName::ChevronUp => "icons/chevron-up.svg",
            IconName::ArrowUp => "icons/arrow-up.svg",
            IconName::ArrowDown => "icons/arrow-down.svg",
            IconName::Plus => "icons/plus.svg",
            IconName::Minus => "icons/minus.svg",
            IconName::Check => "icons/check.svg",
            IconName::X => "icons/x.svg",
            IconName::Search => "icons/search.svg",
            IconName::Refresh => "icons/refresh-cw.svg",
            IconName::Copy => "icons/copy.svg",
            IconName::Trash => "icons/trash.svg",
            IconName::Edit => "icons/edit.svg",
            IconName::Eye => "icons/eye.svg",
            IconName::EyeOff => "icons/eye-off.svg",
            IconName::ExternalLink => "icons/external-link.svg",
            IconName::Settings => "icons/settings.svg",
            IconName::Undo => "icons/undo.svg",
            IconName::Redo => "icons/redo.svg",
            IconName::Star => "icons/star.svg",
            IconName::Pin => "icons/pin.svg",
            IconName::Clock => "icons/clock.svg",
            IconName::User => "icons/user.svg",
            IconName::Folder => "icons/folder.svg",
            IconName::File => "icons/file.svg",
            IconName::Tag => "icons/tag.svg",
            IconName::Stash => "icons/archive.svg",
            IconName::Terminal => "icons/terminal.svg",
            IconName::Sparkle => "icons/sparkle.svg",
            IconName::Info => "icons/info.svg",
            IconName::CheckCircle => "icons/check-circle.svg",
            IconName::HalfCircle => "icons/half-circle.svg",
            IconName::XCircle => "icons/x-circle.svg",
            IconName::AlertTriangle => "icons/alert-triangle.svg",
            IconName::Lock => "icons/lock.svg",
            IconName::Dot => "icons/dot.svg",
            IconName::DotOutline => "icons/dot-outline.svg",
            IconName::Menu => "icons/menu.svg",
            IconName::MoreHorizontal => "icons/more-horizontal.svg",
            IconName::Maximize => "icons/maximize.svg",
            IconName::Minimize => "icons/minimize.svg",
            IconName::Close => "icons/close.svg",
            IconName::Restore => "icons/restore.svg",
            IconName::GripVertical => "icons/grip-vertical.svg",
        }
    }
}

/// Icon sizes.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum IconSize {
    XSmall,
    Small,
    #[default]
    Medium,
    Large,
    Custom(Rems),
}

impl IconSize {
    pub fn rems(&self) -> Rems {
        match self {
            IconSize::XSmall => rems(0.75), // 12px
            IconSize::Small => rems(0.875), // 14px
            IconSize::Medium => rems(1.0),  // 16px
            IconSize::Large => rems(1.5),   // 24px
            IconSize::Custom(r) => *r,
        }
    }
}

/// An SVG icon with semantic color and size.
#[derive(IntoElement)]
pub struct Icon {
    name: IconName,
    color: Color,
    size: IconSize,
}

impl Icon {
    pub fn new(name: IconName) -> Self {
        Self {
            name,
            color: Color::Default,
            size: IconSize::Medium,
        }
    }

    pub fn color(mut self, color: Color) -> Self {
        self.color = color;
        self
    }

    pub fn size(mut self, size: IconSize) -> Self {
        self.size = size;
        self
    }
}

impl RenderOnce for Icon {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let icon_color = self.color.icon_color(cx);
        let size = self.size.rems();

        svg()
            .path(self.name.path())
            .text_color(icon_color)
            .size(size)
            .flex_shrink_0()
            .min_w(size)
            .min_h(size)
    }
}
