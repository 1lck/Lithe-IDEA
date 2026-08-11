#pragma once

#include <QColor>

namespace lithe::windows::ui {

// Semantic colors shared by the workbench.
inline const QColor Window{QStringLiteral("#202124")};
inline const QColor Titlebar{QStringLiteral("#2b2d30")};
inline const QColor Sidebar{QStringLiteral("#242629")};
inline const QColor Editor{QStringLiteral("#1e1f22")};
inline const QColor Raised{QStringLiteral("#303236")};
inline const QColor Selection{QStringLiteral("#2f506e")};
inline const QColor SubtleSelection{QStringLiteral("#35383d")};
inline const QColor Hover{QStringLiteral("#34373c")};
inline const QColor Pressed{QStringLiteral("#29455e")};
inline const QColor Accent{QStringLiteral("#4a88c7")};
inline const QColor PrimaryText{QStringLiteral("#d9d9da")};
inline const QColor SecondaryText{QStringLiteral("#9b9da1")};
inline const QColor Divider{QStringLiteral("#3c3f43")};

inline constexpr int SidebarRowHeight = 25;
inline constexpr int ToolbarHeight = 42;
inline constexpr int IconButtonSize = 28;
inline constexpr int FileIconSize = 14;
inline constexpr int SidebarIndent = 14;
inline constexpr int TabIconSlot = 14;
inline constexpr int ActivityRailWidth = 48;
inline constexpr int PanelHeaderHeight = 32;
inline constexpr int EditorTabHeight = 34;
inline constexpr int ToolWindowHeaderHeight = 34;
inline constexpr int StatusBarHeight = 26;

} // namespace lithe::windows::ui
