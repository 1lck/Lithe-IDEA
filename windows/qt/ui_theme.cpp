#include "ui_theme.h"

#include "ui_tokens.h"

#include <QApplication>
#include <QColor>
#include <QPalette>
#include <QString>

namespace lithe::windows {

void applyUiTheme(QApplication& application) {
    QPalette palette;
    palette.setColor(QPalette::Window, ui::Window);
    palette.setColor(QPalette::WindowText, ui::PrimaryText);
    palette.setColor(QPalette::Base, ui::Editor);
    palette.setColor(QPalette::AlternateBase, ui::Sidebar);
    palette.setColor(QPalette::Text, ui::PrimaryText);
    palette.setColor(QPalette::Button, ui::Raised);
    palette.setColor(QPalette::ButtonText, ui::PrimaryText);
    palette.setColor(QPalette::BrightText, QColor(QStringLiteral("#ffffff")));
    palette.setColor(QPalette::Highlight, ui::Selection);
    palette.setColor(QPalette::HighlightedText, QColor(QStringLiteral("#ffffff")));
    palette.setColor(QPalette::PlaceholderText, ui::SecondaryText);
    application.setPalette(palette);
    application.setStyleSheet(QStringLiteral(R"(
        QMainWindow, QDialog { background: #202124; color: #d9d9da; }
        QMenuBar, QToolBar { background: #2b2d30; border: 0; spacing: 3px; }
        QToolBar { padding: 0 8px; border-bottom: 1px solid #3c3f43; }
        QLabel[chromeRole="title"] { color: #d9d9da; font-size: 14px; font-weight: 600; padding: 0 8px; }
        QLabel[chromeRole="secondary"] { color: #9b9da1; padding: 0 8px; }
        QLabel[chromeRole="panelTitle"] { color: #d9d9da; font-size: 13px; font-weight: 600; }
        QToolButton#workbench\.projectSwitcher,
        QToolButton#workbench\.branchSwitcher {
            min-height: 30px; padding: 0 7px; border: 0; border-radius: 3px; color: #d9d9da;
        }
        QToolButton#workbench\.projectSwitcher:hover,
        QToolButton#workbench\.branchSwitcher:hover { background: #3a3d41; }
        QComboBox#workbench\.runConfigurationSelector {
            min-height: 28px; max-height: 28px; padding: 0 8px; border-radius: 3px;
        }
        QMenuBar::item, QToolButton { padding: 4px 7px; border-radius: 3px; }
        QMenuBar::item:selected, QToolButton:hover { background: #3a3d41; }
        QToolButton:pressed { background: #29455e; }
        QToolButton:disabled { color: #6f7277; background: transparent; }
        QMenu { background: #2b2d30; border: 1px solid #4b4e53; padding: 4px; }
        QMenu::item { padding: 6px 24px 6px 10px; border-radius: 2px; }
        QMenu::item:selected { background: #2f506e; color: #ffffff; }
        QLineEdit, QPlainTextEdit, QTextEdit, QComboBox, QSpinBox, QDoubleSpinBox {
            background: #1e1f22; border: 1px solid #3c3f43; border-radius: 3px;
            padding: 5px 7px; selection-background-color: #2f506e;
        }
        QLineEdit:hover, QPlainTextEdit:hover, QTextEdit:hover, QComboBox:hover,
        QSpinBox:hover, QDoubleSpinBox:hover { border-color: #5b5f65; }
        QLineEdit:focus, QPlainTextEdit:focus, QTextEdit:focus, QComboBox:focus,
        QSpinBox:focus, QDoubleSpinBox:focus { border: 1px solid #4a88c7; }
        QPushButton {
            background: #303236; border: 1px solid #4b4e53; border-radius: 3px;
            min-height: 26px; padding: 4px 11px;
        }
        QPushButton:hover { background: #3a3d41; border-color: #646970; }
        QPushButton:pressed { background: #29455e; }
        QPushButton:focus { border-color: #4a88c7; }
        QPushButton:disabled { color: #6f7277; background: #2b2d30; border-color: #383b3f; }
        QPushButton#workbench\.toolWindow\.hideButton {
            min-width: 28px; max-width: 28px; min-height: 28px; max-height: 28px; padding: 0;
        }
        QTreeWidget, QListWidget, QTableWidget, QTabWidget::pane {
            background: #1e1f22; alternate-background-color: #242629; border: 1px solid #3c3f43;
        }
        QTreeWidget, QListWidget, QTableWidget { outline: 0; show-decoration-selected: 1; }
        QHeaderView::section {
            background: #2b2d30; color: #d9d9da; border: 0; border-bottom: 1px solid #3c3f43;
            padding: 0 10px; min-height: 28px;
        }
        QTreeWidget::item, QListWidget::item, QTableWidget::item {
            min-height: 25px; padding: 3px 5px; border-radius: 0;
        }
        QTreeWidget::item:hover, QListWidget::item:hover, QTableWidget::item:hover { background: #34373c; }
        QTreeWidget::item:selected, QListWidget::item:selected, QTableWidget::item:selected {
            background: #2f506e; color: #ffffff;
        }
        QTreeWidget::item:pressed, QListWidget::item:pressed, QTableWidget::item:pressed {
            background: #29455e; color: #ffffff;
        }
        QTabBar::tab {
            background: #2b2d30; border: 0; border-bottom: 2px solid transparent;
            padding: 0 12px; min-height: 32px; max-height: 32px;
        }
        QTabBar::tab:hover { background: #34373c; }
        QTabBar::tab:selected { background: #1e1f22; border-bottom-color: #4a88c7; }
        QTabBar::close-button { subcontrol-position: right; }
        QStatusBar {
            background: #2b2d30; color: #b5b6b8; min-height: 26px; max-height: 26px;
            border-top: 1px solid #3c3f43;
        }
        QLabel#workbench\.statusPath, QLabel#workbench\.statusInfo { color: #9b9da1; padding: 0 8px; }
        QWidget#workbench\.editorArea { background: #1e1f22; border: 0; }
        QWidget#workbench\.editorArea\.findBar,
        QWidget#workbench\.editorArea\.documentStatus { border-bottom: 1px solid #3c3f43; }
        QWidget#workbench\.toolWindow { background: #1e1f22; border-top: 1px solid #3c3f43; }
        QWidget#workbench\.toolWindow\.header { background: #2b2d30; border-bottom: 1px solid #3c3f43; }
        QTabBar#workbench\.toolWindow\.selector::tab { background: transparent; min-height: 31px; max-height: 31px; }
        QTabBar#workbench\.toolWindow\.selector::tab:selected { background: #35383d; }
        QSplitter::handle { background: #3c3f43; }
        QSplitter::handle:hover { background: #4a88c7; }
        QScrollBar:vertical, QScrollBar:horizontal { background: #1e1f22; margin: 0; }
        QScrollBar::handle:vertical, QScrollBar::handle:horizontal {
            background: #494c51; border-radius: 3px; min-height: 24px; min-width: 24px;
        }
        QScrollBar::handle:hover { background: #60646a; }
        QWidget#workbench\.sidebar\.toolRail { background: #242629; border-right: 1px solid #3c3f43; }
        QWidget#workbench\.sidebar\.content { background: #242629; border-right: 1px solid #3c3f43; }
        QWidget#workbench\.sidebar\.header { border-bottom: 1px solid #3c3f43; }
        QTreeWidget#workbench\.sidebar\.projectTree,
        QListWidget#workbench\.sidebar\.changesList,
        QListWidget#workbench\.sidebar\.searchResults { border: 0; }
        QToolButton[toolRail="true"] { color: #9b9da1; border: 0; border-radius: 3px; }
        QToolButton[toolRail="true"]:hover { background: #34373c; color: #d9d9da; }
        QToolButton[toolRail="true"]:checked {
            background: #35383d; color: #d9d9da; border-left: 2px solid #4a88c7;
        }
        QTreeWidget::branch:hover { background: #34373c; }
        QToolTip { background: #303236; color: #d9d9da; border: 1px solid #4a88c7; padding: 4px 7px; }
        QScrollBar::add-line, QScrollBar::sub-line,
        QScrollBar::add-page, QScrollBar::sub-page { background: transparent; border: 0; }
    )"));
}

}
