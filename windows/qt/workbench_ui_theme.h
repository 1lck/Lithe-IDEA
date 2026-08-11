#pragma once

#include <QColor>
#include <QString>

class QFrame;
class QPushButton;
class QToolButton;
class QWidget;

namespace lithe::windows::ui {

/// Lithe dark-theme palette aligned with the shared Lithe theme tokens.
struct Theme {
    static QColor sidebar();
    static QColor toolHeader();
    static QColor editor();
    static QColor raised();
    static QColor divider();
    static QColor primaryText();
    static QColor secondaryText();
    static QColor tertiaryText();
    static QColor accent();
    static QColor success();
    static QColor warning();
    static QColor error();
    static QColor subtleSelection();
    static QColor inputBackground();
    static QColor inputBorder();
    static QColor inputFocusBorder();
    static QColor panelBorder();

    static QString rgba(const QColor& color);
};

QFrame* makeDivider(QWidget* parent, Qt::Orientation orientation = Qt::Horizontal);
void applyToolHeaderBackground(QWidget* widget);
QToolButton* makeIconButton(QWidget* parent, const QString& tooltip, const QString& glyph);
QPushButton* makeTabButton(QWidget* parent, const QString& text);
void setTabButtonChecked(QPushButton* button, bool checked);
QString gitPanelStyleSheet();
QString litheDialogStyleSheet();

} // namespace lithe::windows::ui
