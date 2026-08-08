#include "ui_theme.h"

#include <QApplication>
#include <QColor>
#include <QPalette>
#include <QString>

#include <cassert>

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    lithe::windows::applyUiTheme(application);
    const auto style = application.styleSheet();
    assert(style.contains(QStringLiteral("#202226")));
    assert(style.contains(QStringLiteral("QPushButton:hover")));
    assert(style.contains(QStringLiteral("QTreeWidget::item:selected")));
    assert(style.contains(QStringLiteral("QTreeWidget::item:pressed")));
    assert(style.contains(QStringLiteral("QListWidget::item:pressed")));
    assert(style.contains(QStringLiteral("QTableWidget::item:pressed")));
    assert(application.palette().color(QPalette::Highlight) == QColor(QStringLiteral("#2e7181")));
    return 0;
}
