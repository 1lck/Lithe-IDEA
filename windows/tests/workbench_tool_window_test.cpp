#include "workbench_tool_window.h"

#include "ui_translation.h"

#include <QApplication>
#include <QLabel>
#include <QPushButton>
#include <QStackedWidget>
#include <QTabBar>

#include <cassert>

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    assert(lithe::windows::installUiTranslator("zh_CN"));
    lithe::windows::WorkbenchToolWindow toolWindow;
    toolWindow.resize(900, 320);
    toolWindow.show();
    application.processEvents();

    using lithe::windows::BottomToolKind;
    assert(toolWindow.objectName() == QStringLiteral("workbench.toolWindow"));
    assert(toolWindow.kind() == BottomToolKind::Terminal);
    assert(toolWindow.toolSelector() != nullptr);
    assert(toolWindow.pages() != nullptr);
    assert(toolWindow.pages()->count() == 6);
    assert(toolWindow.pages()->currentIndex() == 0);
    assert(toolWindow.pages()->minimumHeight() >= 260);

    const auto labels = {QStringLiteral("终端"), QStringLiteral("Maven"),
                         QStringLiteral("问题"), QStringLiteral("调试"),
                         QStringLiteral("Git"), QStringLiteral("差异")};
    int index = 0;
    for (const auto& label : labels) {
        assert(toolWindow.toolSelector()->tabText(index) == label);
        assert(toolWindow.page(static_cast<BottomToolKind>(index)) != nullptr);
        ++index;
    }

    BottomToolKind changedKind = BottomToolKind::Terminal;
    int changeCount = 0;
    int hideCount = 0;
    QObject::connect(&toolWindow, &lithe::windows::WorkbenchToolWindow::toolChanged,
                     [&changedKind, &changeCount](BottomToolKind kind) {
        changedKind = kind;
        ++changeCount;
    });
    QObject::connect(&toolWindow, &lithe::windows::WorkbenchToolWindow::hideRequested,
                     [&hideCount] { ++hideCount; });

    toolWindow.setKind(BottomToolKind::Debug);
    assert(toolWindow.kind() == BottomToolKind::Debug);
    assert(changedKind == BottomToolKind::Debug);
    assert(changeCount == 1);
    assert(toolWindow.pages()->currentIndex() == 3);
    toolWindow.setKind(static_cast<BottomToolKind>(99));
    assert(toolWindow.kind() == BottomToolKind::Debug);
    assert(changeCount == 1);

    auto* hideButton = toolWindow.findChild<QPushButton*>(
        QStringLiteral("workbench.toolWindow.hideButton"));
    assert(hideButton != nullptr);
    hideButton->clicked();
    assert(hideCount == 1);

    auto* panel = new QLabel(QStringLiteral("Maven output"));
    toolWindow.setPanel(BottomToolKind::Build, panel);
    assert(panel->parentWidget() == toolWindow.page(BottomToolKind::Build));
    assert(toolWindow.page(BottomToolKind::Build)->findChild<QLabel*>() == panel);

    return 0;
}
