#include "ui_theme.h"

#include <QApplication>
#include <QColor>
#include <QPalette>
#include <QString>

namespace lithe::windows {

void applyUiTheme(QApplication& application) {
    QPalette palette;
    palette.setColor(QPalette::Window, QColor(QStringLiteral("#202226")));
    palette.setColor(QPalette::WindowText, QColor(QStringLiteral("#d7d9df")));
    palette.setColor(QPalette::Base, QColor(QStringLiteral("#191a1e")));
    palette.setColor(QPalette::AlternateBase, QColor(QStringLiteral("#23252a")));
    palette.setColor(QPalette::Text, QColor(QStringLiteral("#d7d9df")));
    palette.setColor(QPalette::Button, QColor(QStringLiteral("#2b2e35")));
    palette.setColor(QPalette::ButtonText, QColor(QStringLiteral("#d7d9df")));
    palette.setColor(QPalette::BrightText, QColor(QStringLiteral("#ffffff")));
    palette.setColor(QPalette::Highlight, QColor(QStringLiteral("#2e7181")));
    palette.setColor(QPalette::HighlightedText, QColor(QStringLiteral("#ffffff")));
    palette.setColor(QPalette::PlaceholderText, QColor(QStringLiteral("#858b98")));
    application.setPalette(palette);
    application.setStyleSheet(QStringLiteral(R"(
        QMainWindow, QDialog {
            background: #202226;
            color: #d7d9df;
        }
        QMenuBar, QToolBar {
            background: #25272c;
            border: 0;
            spacing: 4px;
        }
        QMenuBar::item, QToolButton {
            padding: 5px 8px;
            border-radius: 4px;
        }
        QMenuBar::item:selected, QToolButton:hover {
            background: #30343b;
        }
        QMenu {
            background: #282b31;
            border: 1px solid #41454e;
            padding: 5px;
        }
        QMenu::item {
            padding: 6px 24px 6px 10px;
            border-radius: 4px;
        }
        QMenu::item:selected {
            background: #2e7181;
            color: #ffffff;
        }
        QLineEdit, QPlainTextEdit, QTextEdit, QComboBox, QSpinBox, QDoubleSpinBox {
            background: #191a1e;
            border: 1px solid #3c4049;
            border-radius: 5px;
            padding: 5px 7px;
            selection-background-color: #2e7181;
        }
        QLineEdit:hover, QPlainTextEdit:hover, QTextEdit:hover, QComboBox:hover,
        QSpinBox:hover, QDoubleSpinBox:hover {
            border-color: #59616d;
        }
        QLineEdit:focus, QPlainTextEdit:focus, QTextEdit:focus, QComboBox:focus,
        QSpinBox:focus, QDoubleSpinBox:focus {
            border: 1px solid #4c9db0;
        }
        QPushButton {
            background: #2b2e35;
            border: 1px solid #454a54;
            border-radius: 5px;
            min-height: 26px;
            padding: 4px 11px;
        }
        QPushButton:hover {
            background: #343841;
            border-color: #64707e;
        }
        QPushButton:pressed {
            background: #202329;
        }
        QPushButton:focus {
            border-color: #4c9db0;
        }
        QPushButton:disabled {
            color: #707580;
            background: #25272c;
            border-color: #34373e;
        }
        QTreeWidget, QListWidget, QTableWidget, QTabWidget::pane {
            background: #191a1e;
            alternate-background-color: #202226;
            border: 1px solid #30343b;
        }
        QTreeWidget::item, QListWidget::item, QTableWidget::item {
            min-height: 25px;
            padding: 3px 5px;
            border-radius: 3px;
        }
        QTreeWidget::item:hover, QListWidget::item:hover, QTableWidget::item:hover {
            background: #292d34;
        }
        QTreeWidget::item:selected, QListWidget::item:selected, QTableWidget::item:selected {
            background: #2e7181;
            color: #ffffff;
        }
        QTreeWidget::item:pressed, QListWidget::item:pressed, QTableWidget::item:pressed {
            background: #214f5b;
            color: #ffffff;
        }
        QTabBar::tab {
            background: #25272c;
            border: 0;
            border-bottom: 2px solid transparent;
            padding: 7px 12px;
        }
        QTabBar::tab:hover {
            background: #30343b;
        }
        QTabBar::tab:selected {
            background: #2b2e35;
            border-bottom-color: #4c9db0;
        }
        QStatusBar {
            background: #25272c;
            color: #aeb3bd;
        }
        QSplitter::handle {
            background: #30343b;
        }
        QSplitter::handle:hover {
            background: #4c9db0;
        }
        QScrollBar:vertical, QScrollBar:horizontal {
            background: #191a1e;
            margin: 0;
        }
        QScrollBar::handle:vertical, QScrollBar::handle:horizontal {
            background: #41464f;
            border-radius: 4px;
            min-height: 24px;
            min-width: 24px;
        }
        QScrollBar::handle:hover {
            background: #59616d;
        }
        QScrollBar::add-line, QScrollBar::sub-line,
        QScrollBar::add-page, QScrollBar::sub-page {
            background: transparent;
            border: 0;
        }
    )"));
}

}
