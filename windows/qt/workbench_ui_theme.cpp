#include "workbench_ui_theme.h"
#include "workbench_icons.h"

#include <QFrame>
#include <QPalette>
#include <QPushButton>
#include <QSizePolicy>
#include <QToolButton>

namespace lithe::windows::ui {
namespace {

QColor makeColor(int r, int g, int b, int a = 255) {
    return QColor(r, g, b, a);
}

} // namespace

// Palette aligned with Sources/Lithe/Theme/LitheTheme.swift.
QColor Theme::sidebar() { return makeColor(23, 25, 27); }
QColor Theme::toolHeader() { return makeColor(31, 33, 36); }
QColor Theme::editor() { return makeColor(19, 20, 22); }
QColor Theme::raised() { return makeColor(42, 45, 48); }
QColor Theme::divider() { return QColor(255, 255, 255, 19); }
QColor Theme::primaryText() { return QColor(255, 255, 255, 219); }
QColor Theme::secondaryText() { return QColor(255, 255, 255, 128); }
QColor Theme::tertiaryText() { return QColor(255, 255, 255, 87); }
QColor Theme::accent() { return makeColor(79, 148, 250); }
QColor Theme::success() { return makeColor(71, 184, 99); }
QColor Theme::warning() { return makeColor(232, 161, 51); }
QColor Theme::error() { return makeColor(235, 84, 84); }
QColor Theme::subtleSelection() { return makeColor(52, 56, 61); }
QColor Theme::inputBackground() { return makeColor(17, 18, 20); }
QColor Theme::inputBorder() { return QColor(255, 255, 255, 31); }
QColor Theme::inputFocusBorder() { return QColor(79, 148, 250, 217); }
QColor Theme::panelBorder() { return QColor(255, 255, 255, 33); }

QString Theme::rgba(const QColor& color) {
    return QStringLiteral("rgba(%1, %2, %3, %4)")
        .arg(color.red())
        .arg(color.green())
        .arg(color.blue())
        .arg(color.alpha());
}

QFrame* makeDivider(QWidget* parent, Qt::Orientation orientation) {
    auto* divider = new QFrame(parent);
    divider->setFrameShape(QFrame::NoFrame);
    if (orientation == Qt::Horizontal) {
        divider->setFixedHeight(1);
        divider->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    } else {
        divider->setFixedWidth(1);
        divider->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Expanding);
    }
    divider->setStyleSheet(
        QStringLiteral("background-color: %1; border: none;").arg(Theme::rgba(Theme::divider())));
    return divider;
}

void applyToolHeaderBackground(QWidget* widget) {
    if (widget == nullptr) return;
    widget->setAutoFillBackground(true);
    QPalette palette = widget->palette();
    palette.setColor(QPalette::Window, Theme::toolHeader());
    widget->setPalette(palette);
}

QToolButton* makeIconButton(QWidget* parent, const QString& tooltip, const QString& glyph) {
    auto* button = new QToolButton(parent);
    button->setToolTip(tooltip);
    button->setAutoRaise(true);
    button->setFixedSize(28, 28);
    button->setCursor(Qt::PointingHandCursor);
    button->setIconSize(QSize(16, 16));

    // Prefer IDEA SVG / drawn icons over emoji glyphs.
    if (glyph == QLatin1String("refresh") || glyph == QLatin1String("↻")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("actions/refresh.svg"));
    } else if (glyph == QLatin1String("gear") || glyph == QLatin1String("⚙")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("general/gear.svg"));
    } else if (glyph == QLatin1String("more") || glyph == QLatin1String("⋯")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("actions/more.svg"));
    } else if (glyph == QLatin1String("search")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("actions/search.svg"));
    } else if (glyph == QLatin1String("vcs") || glyph == QLatin1String("git")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("toolwindows/toolWindowVcs.svg"));
    } else if (glyph == QLatin1String("diff") || glyph == QLatin1String("⇄")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("vcs/diff.svg"));
    } else if (glyph == QLatin1String("branch") || glyph == QLatin1String("⑂")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("vcs/branch.svg"));
    } else if (glyph == QLatin1String("commit")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("vcs/commit.svg"));
    } else if (glyph == QLatin1String("plus") || glyph == QLatin1String("+")) {
        button->setIcon(drawnIcon(QStringLiteral("plus")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("discard") || glyph == QLatin1String("↩")) {
        button->setIcon(drawnIcon(QStringLiteral("discard")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("stage") || glyph == QLatin1String("⬇")) {
        button->setIcon(drawnIcon(QStringLiteral("stage")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("preview") || glyph == QLatin1String("👁")) {
        button->setIcon(drawnIcon(QStringLiteral("eye")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("up") || glyph == QLatin1String("↑")) {
        button->setIcon(drawnIcon(QStringLiteral("up")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("down") || glyph == QLatin1String("↓") ||
               glyph == QLatin1String("⇓")) {
        button->setIcon(drawnIcon(QStringLiteral("down")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("close") || glyph == QLatin1String("✕")) {
        button->setIcon(drawnIcon(QStringLiteral("close")));
        button->setText({});
        button->setToolButtonStyle(Qt::ToolButtonIconOnly);
    } else if (glyph == QLatin1String("fetch") || glyph == QLatin1String("push") ||
               glyph == QLatin1String("⬆")) {
        IdeaIcons::applyToToolButton(button, QStringLiteral("vcs/diff.svg"));
    } else {
        button->setText(glyph);
        button->setToolButtonStyle(Qt::ToolButtonTextOnly);
    }
    if (button->icon().isNull() && button->text().isEmpty()) {
        button->setText(glyph);
        button->setToolButtonStyle(Qt::ToolButtonTextOnly);
    }
    return button;
}

QPushButton* makeTabButton(QWidget* parent, const QString& text) {
    auto* button = new QPushButton(text, parent);
    button->setCheckable(true);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setFixedHeight(30);
    return button;
}

void setTabButtonChecked(QPushButton* button, bool checked) {
    if (button == nullptr) return;
    button->setChecked(checked);
}

QString gitPanelStyleSheet() {
    const auto sidebar = Theme::rgba(Theme::sidebar());
    const auto toolHeader = Theme::rgba(Theme::toolHeader());
    const auto editor = Theme::rgba(Theme::editor());
    const auto raised = Theme::rgba(Theme::raised());
    const auto primary = Theme::rgba(Theme::primaryText());
    const auto secondary = Theme::rgba(Theme::secondaryText());
    const auto accent = Theme::rgba(Theme::accent());
    const auto selection = Theme::rgba(Theme::subtleSelection());
    const auto inputBg = Theme::rgba(Theme::inputBackground());
    const auto inputBorder = Theme::rgba(Theme::inputBorder());
    const auto divider = Theme::rgba(Theme::divider());
    const auto focusBorder = Theme::rgba(Theme::inputFocusBorder());

    return QStringLiteral(
        "GitChangesPanel, GitLogPanel {"
        "  background-color: %1;"
        "  color: %2;"
        "}"
        "GitChangesPanel QPushButton[tabButton=\"true\"] {"
        "  background: transparent;"
        "  border: none;"
        "  border-radius: 5px;"
        "  color: %3;"
        "  padding: 4px 12px;"
        "  font-size: 12.5px;"
        "  font-weight: 400;"
        "  min-height: 26px;"
        "}"
        "GitChangesPanel QPushButton[tabButton=\"true\"]:hover {"
        "  background-color: rgba(255, 255, 255, 14);"
        "}"
        "GitChangesPanel QPushButton[tabButton=\"true\"]:checked {"
        "  background-color: %5;"
        "  color: %2;"
        "  font-weight: 600;"
        "}"
        "GitChangesPanel QToolButton, GitLogPanel QToolButton {"
        "  background: transparent;"
        "  border: none;"
        "  border-radius: 5px;"
        "  color: %3;"
        "  font-size: 13px;"
        "  padding: 2px;"
        "}"
        "GitChangesPanel QToolButton:hover, GitLogPanel QToolButton:hover {"
        "  background-color: rgba(255, 255, 255, 14);"
        "  color: %2;"
        "}"
        "GitChangesPanel QToolButton:pressed, GitLogPanel QToolButton:pressed {"
        "  background-color: rgba(255, 255, 255, 24);"
        "}"
        "GitChangesPanel QToolButton:disabled, GitLogPanel QToolButton:disabled {"
        "  color: rgba(255, 255, 255, 40);"
        "}"
        "GitChangesPanel QTreeWidget, GitLogPanel QTreeWidget,"
        "GitChangesPanel QListWidget, GitLogPanel QListWidget {"
        "  background-color: %1;"
        "  border: none;"
        "  color: %2;"
        "  outline: none;"
        "  padding: 2px;"
        "  font-size: 12.5px;"
        "}"
        "GitChangesPanel QTreeWidget::item, GitLogPanel QTreeWidget::item,"
        "GitChangesPanel QListWidget::item, GitLogPanel QListWidget::item {"
        "  padding: 4px 8px;"
        "  border-radius: 4px;"
        "  margin: 1px 4px;"
        "  min-height: 22px;"
        "}"
        "GitChangesPanel QTreeWidget::item:hover, GitLogPanel QTreeWidget::item:hover,"
        "GitChangesPanel QListWidget::item:hover, GitLogPanel QListWidget::item:hover {"
        "  background-color: rgba(255, 255, 255, 14);"
        "}"
        "GitChangesPanel QTreeWidget::item:selected, GitLogPanel QTreeWidget::item:selected,"
        "GitChangesPanel QListWidget::item:selected, GitLogPanel QListWidget::item:selected {"
        "  background-color: %4;"
        "  color: %2;"
        "}"
        "GitChangesPanel QTreeWidget::indicator, GitLogPanel QTreeWidget::indicator {"
        "  width: 14px;"
        "  height: 14px;"
        "  border: 1px solid %7;"
        "  border-radius: 3px;"
        "  background: %6;"
        "}"
        "GitChangesPanel QTreeWidget::indicator:checked {"
        "  background-color: %8;"
        "  border-color: %8;"
        "  image: none;"
        "}"
        "GitChangesPanel QPlainTextEdit, GitLogPanel QPlainTextEdit {"
        "  background-color: %11;"
        "  border: 1px solid %10;"
        "  border-radius: 4px;"
        "  color: %2;"
        "  padding: 6px 8px;"
        "  selection-background-color: %4;"
        "  font-size: 12.5px;"
        "}"
        "GitChangesPanel QPlainTextEdit:focus, GitLogPanel QPlainTextEdit:focus {"
        "  border-color: %12;"
        "}"
        "GitChangesPanel QLineEdit, GitLogPanel QLineEdit {"
        "  background-color: %6;"
        "  border: 1px solid %7;"
        "  border-radius: 4px;"
        "  color: %2;"
        "  padding: 4px 8px;"
        "  selection-background-color: %4;"
        "  font-size: 11.5px;"
        "  min-height: 24px;"
        "}"
        "GitChangesPanel QLineEdit:focus, GitLogPanel QLineEdit:focus {"
        "  border-color: %12;"
        "}"
        "GitChangesPanel QCheckBox, GitLogPanel QCheckBox {"
        "  color: %2;"
        "  spacing: 6px;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QCheckBox::indicator {"
        "  width: 14px;"
        "  height: 14px;"
        "  border: 1px solid %7;"
        "  border-radius: 3px;"
        "  background: %6;"
        "}"
        "GitChangesPanel QCheckBox::indicator:checked {"
        "  background-color: %8;"
        "  border-color: %8;"
        "}"
        "GitChangesPanel QPushButton[primaryAction=\"true\"] {"
        "  background-color: %8;"
        "  border: 1px solid %8;"
        "  border-radius: 5px;"
        "  color: rgb(255, 255, 255);"
        "  padding: 5px 14px;"
        "  min-height: 26px;"
        "  font-weight: 600;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QPushButton[primaryAction=\"true\"]:hover {"
        "  background-color: rgb(110, 168, 255);"
        "  border-color: rgb(110, 168, 255);"
        "}"
        "GitChangesPanel QPushButton[primaryAction=\"true\"]:disabled {"
        "  background-color: rgba(79, 148, 250, 45);"
        "  border-color: rgba(79, 148, 250, 45);"
        "  color: rgba(255, 255, 255, 90);"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"],"
        "GitLogPanel QPushButton[secondaryAction=\"true\"] {"
        "  background-color: transparent;"
        "  border: 1px solid %7;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 5px 12px;"
        "  min-height: 26px;"
        "  font-weight: 500;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"]:hover,"
        "GitLogPanel QPushButton[secondaryAction=\"true\"]:hover {"
        "  background-color: rgba(255, 255, 255, 12);"
        "  border-color: rgba(255, 255, 255, 45);"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"]:pressed,"
        "GitLogPanel QPushButton[secondaryAction=\"true\"]:pressed {"
        "  background-color: rgba(255, 255, 255, 20);"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"]:disabled,"
        "GitLogPanel QPushButton[secondaryAction=\"true\"]:disabled {"
        "  color: rgba(255, 255, 255, 40);"
        "  border-color: rgba(255, 255, 255, 16);"
        "  background-color: transparent;"
        "}"
        "GitChangesPanel QPushButton[aiAction=\"true\"] {"
        "  background-color: rgba(42, 45, 48, 180);"
        "  border: none;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 2px 8px;"
        "  min-height: 24px;"
        "  font-size: 10.5px;"
        "  font-weight: 500;"
        "}"
        "GitChangesPanel QPushButton[aiAction=\"true\"]:hover {"
        "  background-color: %5;"
        "}"
        "GitChangesPanel QPushButton[aiAction=\"true\"]:disabled {"
        "  color: rgba(255, 255, 255, 40);"
        "}"
        "GitLogPanel QLabel[gitTitle=\"true\"],"
        "GitChangesPanel QLabel[gitTitle=\"true\"] {"
        "  color: %2;"
        "  font-size: 13.5px;"
        "  font-weight: 600;"
        "  letter-spacing: -0.01em;"
        "}"
        "GitLogPanel QLabel[gitMeta=\"true\"],"
        "GitChangesPanel QLabel[gitMeta=\"true\"] {"
        "  color: %3;"
        "  font-size: 11px;"
        "}"
        "GitLogPanel QLabel[gitChip=\"true\"] {"
        "  background-color: %5;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 4px 10px;"
        "  font-size: 12px;"
        "  font-weight: 500;"
        "}"
        "GitLogPanel QWidget[gitToolHeader=\"true\"],"
        "GitChangesPanel QWidget[gitToolHeader=\"true\"] {"
        "  background-color: %9;"
        "  border-bottom: 1px solid %10;"
        "}"
        "GitChangesPanel QWidget[gitComposer=\"true\"] {"
        "  background-color: %9;"
        "  border-top: 1px solid %10;"
        "}"
        "GitChangesPanel QWidget[gitEmptyState=\"true\"] {"
        "  background-color: %1;"
        "}"
        "QSplitter::handle {"
        "  background-color: %10;"
        "  margin: 0px;"
        "}"
        "QSplitter::handle:hover {"
        "  background-color: rgba(79, 148, 250, 90);"
        "}"
    )
        .arg(sidebar, primary, secondary, selection, raised, inputBg, inputBorder, accent,
             toolHeader, divider, editor, focusBorder);
}

QString litheDialogStyleSheet() {
    const auto popup = Theme::rgba(Theme::raised());
    const auto primary = Theme::rgba(Theme::primaryText());
    const auto secondary = Theme::rgba(Theme::secondaryText());
    const auto accent = Theme::rgba(Theme::accent());
    const auto selection = Theme::rgba(Theme::subtleSelection());
    const auto inputBg = Theme::rgba(Theme::inputBackground());
    const auto inputBorder = Theme::rgba(Theme::inputBorder());
    const auto focusBorder = Theme::rgba(Theme::inputFocusBorder());
    const auto divider = Theme::rgba(Theme::divider());

    return QStringLiteral(
        "QDialog {"
        "  background-color: %1;"
        "  color: %2;"
        "}"
        "QDialog QLabel {"
        "  color: %2;"
        "  font-size: 12.5px;"
        "}"
        "QDialog QLabel[dialogTitle=\"true\"] {"
        "  font-size: 14px;"
        "  font-weight: 600;"
        "}"
        "QDialog QLabel[dialogMeta=\"true\"] {"
        "  color: %3;"
        "  font-size: 11.5px;"
        "}"
        "QDialog QListWidget {"
        "  background-color: %5;"
        "  border: 1px solid %6;"
        "  border-radius: 6px;"
        "  color: %2;"
        "  outline: none;"
        "  padding: 4px;"
        "}"
        "QDialog QListWidget::item {"
        "  padding: 7px 10px;"
        "  border-radius: 4px;"
        "  margin: 1px 2px;"
        "}"
        "QDialog QListWidget::item:hover {"
        "  background-color: rgba(255, 255, 255, 12);"
        "}"
        "QDialog QListWidget::item:selected {"
        "  background-color: %4;"
        "  color: %2;"
        "}"
        "QDialog QLineEdit {"
        "  background-color: %5;"
        "  border: 1px solid %6;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 6px 10px;"
        "  min-height: 28px;"
        "  selection-background-color: %4;"
        "}"
        "QDialog QLineEdit:focus {"
        "  border-color: %8;"
        "}"
        "QDialog QPushButton {"
        "  background-color: transparent;"
        "  border: 1px solid %6;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 6px 14px;"
        "  min-height: 28px;"
        "  font-size: 12px;"
        "}"
        "QDialog QPushButton:hover {"
        "  background-color: rgba(255, 255, 255, 12);"
        "  border-color: rgba(255, 255, 255, 40);"
        "}"
        "QDialog QPushButton:default,"
        "QDialog QPushButton[primaryAction=\"true\"] {"
        "  background-color: %7;"
        "  border-color: %7;"
        "  color: white;"
        "  font-weight: 600;"
        "}"
        "QDialog QPushButton:default:hover,"
        "QDialog QPushButton[primaryAction=\"true\"]:hover {"
        "  background-color: rgb(110, 168, 255);"
        "  border-color: rgb(110, 168, 255);"
        "}"
        "QDialog QPushButton[destructiveAction=\"true\"] {"
        "  border-color: rgba(235, 84, 84, 160);"
        "  color: rgb(255, 170, 170);"
        "}"
        "QDialog QFrame[dialogDivider=\"true\"] {"
        "  background-color: %9;"
        "  max-height: 1px;"
        "  border: none;"
        "}"
    )
        .arg(popup, primary, secondary, selection, inputBg, inputBorder, accent, focusBorder,
             divider);
}

} // namespace lithe::windows::ui
