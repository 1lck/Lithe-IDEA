#include "workbench_editor_area.h"
#include "workbench_code_editor.h"

#include <QApplication>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QPushButton>
#include <QSizePolicy>
#include <QStackedWidget>
#include <QTabBar>

#include <cassert>

namespace {

void pressReturn(QWidget* widget) {
    QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
    QApplication::sendEvent(widget, &event);
}

QPushButton* button(lithe::windows::WorkbenchEditorArea& area, const char* objectName) {
    return area.findChild<QPushButton*>(QString::fromLatin1(objectName));
}

}

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    lithe::windows::WorkbenchEditorArea area;
    area.resize(900, 620);
    area.show();
    application.processEvents();

    assert(area.objectName() == QStringLiteral("workbench.editorArea"));
    assert(area.editor() != nullptr);
    assert(area.editorTabs() != nullptr);
    assert(area.findBar() != nullptr);
    assert(area.findField() != nullptr);
    assert(area.findStatus() != nullptr);
    assert(area.searchResults() != nullptr);
    assert(area.javaNavigationResults() != nullptr);
    assert(area.diagnostics() != nullptr);
    assert(area.emptyState() != nullptr);

    auto* editorStack = area.findChild<QStackedWidget*>(
        QStringLiteral("workbench.editorArea.editorStack"));
    assert(editorStack != nullptr);
    assert(editorStack->currentWidget() == area.emptyState());
    assert(area.emptyState()->isVisible());
    assert(!area.editor()->isVisible());
    assert(area.editor()->minimumHeight() >= 220);
    assert(area.editor()->sizePolicy().verticalPolicy() == QSizePolicy::Expanding);
    assert(!area.findBar()->isVisible());
    assert(!area.searchResults()->isVisible());
    assert(!area.javaNavigationResults()->isVisible());
    assert(!area.diagnostics()->isVisible());

    area.setEmptyStateVisible(false);
    assert(editorStack->currentWidget() == area.editor());
    assert(area.editor()->isVisible());
    assert(!area.emptyState()->isVisible());
    area.setEmptyStateVisible(true);
    assert(editorStack->currentWidget() == area.emptyState());

    int changedIndex = -1;
    int closeIndex = -1;
    int previousCount = 0;
    int nextCount = 0;
    int closeFindCount = 0;
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::tabChanged,
                     [&changedIndex](int index) { changedIndex = index; });
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::tabCloseRequested,
                     [&closeIndex](int index) { closeIndex = index; });
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::findPreviousRequested,
                     [&previousCount] { ++previousCount; });
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::findNextRequested,
                     [&nextCount] { ++nextCount; });
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::findBarCloseRequested,
                     [&closeFindCount] { ++closeFindCount; });

    area.editorTabs()->addTab(QStringLiteral("Main.cpp"));
    area.editorTabs()->setCurrentIndex(0);
    assert(changedIndex == 0);
    area.editorTabs()->tabCloseRequested(0);
    assert(closeIndex == 0);

    area.findBar()->setVisible(true);
    area.findField()->setText(QStringLiteral("needle"));
    pressReturn(area.findField());
    assert(nextCount == 1);
    button(area, "workbench.editorArea.findPrevious")->clicked();
    button(area, "workbench.editorArea.findNext")->clicked();
    button(area, "workbench.editorArea.findClose")->clicked();
    assert(previousCount == 1);
    assert(nextCount == 2);
    assert(closeFindCount == 1);

    QListWidgetItem* searchItem = new QListWidgetItem(QStringLiteral("src/main.cpp:10"));
    QListWidgetItem* navigationItem = new QListWidgetItem(QStringLiteral("Main#run"));
    QListWidgetItem* diagnosticItem = new QListWidgetItem(QStringLiteral("Line 10: warning"));
    area.searchResults()->addItem(searchItem);
    area.javaNavigationResults()->addItem(navigationItem);
    area.diagnostics()->addItem(diagnosticItem);
    QListWidgetItem* activatedSearch = nullptr;
    QListWidgetItem* activatedNavigation = nullptr;
    QListWidgetItem* activatedDiagnostic = nullptr;
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::searchResultActivated,
                     [&activatedSearch](QListWidgetItem* item) { activatedSearch = item; });
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::javaNavigationResultActivated,
                     [&activatedNavigation](QListWidgetItem* item) { activatedNavigation = item; });
    QObject::connect(&area, &lithe::windows::WorkbenchEditorArea::diagnosticActivated,
                     [&activatedDiagnostic](QListWidgetItem* item) { activatedDiagnostic = item; });
    area.searchResults()->itemActivated(searchItem);
    area.javaNavigationResults()->itemActivated(navigationItem);
    area.diagnostics()->itemActivated(diagnosticItem);
    assert(activatedSearch == searchItem);
    assert(activatedNavigation == navigationItem);
    assert(activatedDiagnostic == diagnosticItem);
    return 0;
}
