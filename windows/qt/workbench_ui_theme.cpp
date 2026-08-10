#include "workbench_ui_theme.h"

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

QColor Theme::sidebar() { return makeColor(30, 30, 30); }
QColor Theme::toolHeader() { return makeColor(37, 37, 37); }
QColor Theme::editor() { return makeColor(30, 30, 30); }
QColor Theme::raised() { return makeColor(45, 45, 45); }
QColor Theme::divider() { return QColor(255, 255, 255, 10); }
QColor Theme::primaryText() { return QColor(255, 255, 255, 240); }
QColor Theme::secondaryText() { return QColor(255, 255, 255, 140); }
QColor Theme::tertiaryText() { return QColor(255, 255, 255, 90); }
QColor Theme::accent() { return makeColor(96, 165, 250); }
QColor Theme::success() { return makeColor(34, 197, 94); }
QColor Theme::warning() { return makeColor(251, 146, 60); }
QColor Theme::error() { return makeColor(239, 68, 68); }
QColor Theme::subtleSelection() { return makeColor(50, 50, 50); }
QColor Theme::inputBackground() { return makeColor(37, 37, 37); }
QColor Theme::inputBorder() { return QColor(255, 255, 255, 20); }
QColor Theme::inputFocusBorder() { return QColor(96, 165, 250, 180); }
QColor Theme::panelBorder() { return QColor(255, 255, 255, 15); }

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
    button->setText(glyph);
    button->setToolTip(tooltip);
    button->setAutoRaise(true);
    button->setFixedSize(28, 28);
    button->setCursor(Qt::PointingHandCursor);
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
        "  font-size: 12px;"
        "  font-weight: 500;"
        "  min-height: 26px;"
        "}"
        "GitChangesPanel QPushButton[tabButton=\"true\"]:hover {"
        "  background-color: rgba(255, 255, 255, 4);"
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
        "  font-size: 14px;"
        "  padding: 2px;"
        "}"
        "GitChangesPanel QToolButton:hover, GitLogPanel QToolButton:hover {"
        "  background-color: rgba(255, 255, 255, 6);"
        "  color: %2;"
        "}"
        "GitChangesPanel QToolButton:pressed, GitLogPanel QToolButton:pressed {"
        "  background-color: rgba(255, 255, 255, 10);"
        "}"
        "GitChangesPanel QToolButton:disabled, GitLogPanel QToolButton:disabled {"
        "  color: rgba(255, 255, 255, 30);"
        "}"
        "GitChangesPanel QTreeWidget, GitLogPanel QTreeWidget,"
        "GitChangesPanel QListWidget, GitLogPanel QListWidget {"
        "  background-color: %1;"
        "  border: none;"
        "  color: %2;"
        "  outline: none;"
        "  padding: 2px;"
        "}"
        "GitChangesPanel QTreeWidget::item, GitLogPanel QTreeWidget::item,"
        "GitChangesPanel QListWidget::item, GitLogPanel QListWidget::item {"
        "  padding: 3px 6px;"
        "  border-radius: 4px;"
        "  margin: 1px 2px;"
        "}"
        "GitChangesPanel QTreeWidget::item:hover, GitLogPanel QTreeWidget::item:hover,"
        "GitChangesPanel QListWidget::item:hover, GitLogPanel QListWidget::item:hover {"
        "  background-color: rgba(255, 255, 255, 4);"
        "}"
        "GitChangesPanel QTreeWidget::item:selected, GitLogPanel QTreeWidget::item:selected,"
        "GitChangesPanel QListWidget::item:selected, GitLogPanel QListWidget::item:selected {"
        "  background-color: %4;"
        "  color: %2;"
        "}"
        "GitChangesPanel QPlainTextEdit, GitLogPanel QPlainTextEdit {"
        "  background-color: %6;"
        "  border: 1px solid %7;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 7px 9px;"
        "  selection-background-color: %4;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QPlainTextEdit:focus, GitLogPanel QPlainTextEdit:focus {"
        "  border-color: %8;"
        "}"
        "GitChangesPanel QLineEdit, GitLogPanel QLineEdit {"
        "  background-color: %6;"
        "  border: 1px solid %7;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 4px 8px;"
        "  selection-background-color: %4;"
        "  font-size: 12px;"
        "  min-height: 24px;"
        "}"
        "GitChangesPanel QLineEdit:focus, GitLogPanel QLineEdit:focus {"
        "  border-color: %8;"
        "}"
        "GitChangesPanel QCheckBox, GitLogPanel QCheckBox {"
        "  color: %2;"
        "  spacing: 6px;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QPushButton[primaryAction=\"true\"] {"
        "  background-color: %8;"
        "  border: 1px solid %8;"
        "  border-radius: 5px;"
        "  color: rgb(255, 255, 255);"
        "  padding: 5px 14px;"
        "  min-height: 28px;"
        "  font-weight: 600;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QPushButton[primaryAction=\"true\"]:hover {"
        "  background-color: rgb(125, 186, 255);"
        "  border-color: rgb(125, 186, 255);"
        "}"
        "GitChangesPanel QPushButton[primaryAction=\"true\"]:disabled {"
        "  background-color: rgba(96, 165, 250, 40);"
        "  border-color: rgba(96, 165, 250, 40);"
        "  color: rgba(255, 255, 255, 70);"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"],"
        "GitLogPanel QPushButton[secondaryAction=\"true\"] {"
        "  background-color: transparent;"
        "  border: 1px solid %7;"
        "  border-radius: 5px;"
        "  color: %2;"
        "  padding: 5px 14px;"
        "  min-height: 28px;"
        "  font-weight: 500;"
        "  font-size: 12px;"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"]:hover,"
        "GitLogPanel QPushButton[secondaryAction=\"true\"]:hover {"
        "  background-color: rgba(255, 255, 255, 5);"
        "  border-color: rgba(255, 255, 255, 35);"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"]:pressed,"
        "GitLogPanel QPushButton[secondaryAction=\"true\"]:pressed {"
        "  background-color: rgba(255, 255, 255, 8);"
        "}"
        "GitChangesPanel QPushButton[secondaryAction=\"true\"]:disabled,"
        "GitLogPanel QPushButton[secondaryAction=\"true\"]:disabled {"
        "  color: rgba(255, 255, 255, 30);"
        "  border-color: rgba(255, 255, 255, 12);"
        "  background-color: transparent;"
        "}"
        "GitLogPanel QLabel[gitTitle=\"true\"] {"
        "  color: %2;"
        "  font-size: 13px;"
        "  font-weight: 600;"
        "  letter-spacing: -0.01em;"
        "}"
        "GitLogPanel QLabel[gitMeta=\"true\"] {"
        "  color: %3;"
        "  font-size: 11px;"
        "}"
        "GitChangesPanel QLabel[gitMeta=\"true\"] {"
        "  color: %3;"
        "  font-size: 11px;"
        "}"
        "GitLogPanel QWidget[gitToolHeader=\"true\"] {"
        "  background-color: %9;"
        "  border-bottom: 1px solid %10;"
        "}"
        "GitChangesPanel QWidget[gitToolHeader=\"true\"] {"
        "  background-color: %9;"
        "  border-bottom: 1px solid %10;"
        "}"
        "GitChangesPanel QWidget[gitComposer=\"true\"] {"
        "  background-color: %9;"
        "  border-top: 1px solid %10;"
        "}"
        "QSplitter::handle {"
        "  background-color: %10;"
        "  margin: 0px;"
        "}"
        "QSplitter::handle:hover {"
        "  background-color: rgba(96, 165, 250, 80);"
        "}"
    )
        .arg(sidebar, primary, secondary, selection, raised, inputBg, inputBorder, accent,
             toolHeader, divider);
}

} // namespace lithe::windows::ui
