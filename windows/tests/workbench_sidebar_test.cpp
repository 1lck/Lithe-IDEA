#include "workbench_sidebar.h"

#include "ui_translation.h"

#include <QApplication>
#include <QKeyEvent>
#include <QLabel>
#include <QListWidget>
#include <QLineEdit>
#include <QPoint>
#include <QSizePolicy>
#include <QStackedWidget>
#include <QTabBar>
#include <QTreeWidget>
#include <QString>

#include <cassert>

namespace {

QLabel* statusLabel(lithe::windows::WorkbenchSidebar& sidebar, const char* name) {
    return sidebar.findChild<QLabel*>(QString::fromLatin1(name));
}

void assertVisibleStatus(lithe::windows::WorkbenchSidebar& sidebar,
                         const char* name,
                         const QString& text) {
    auto* status = statusLabel(sidebar, name);
    assert(status != nullptr);
    assert(status->isVisible());
    assert(status->text() == text);
}

void pressReturn(QWidget* widget) {
    QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
    QApplication::sendEvent(widget, &event);
}

}

int main(int argc, char* argv[]) {
    QApplication application(argc, argv);
    assert(lithe::windows::installUiTranslator("zh_CN"));
    lithe::windows::WorkbenchSidebar sidebar;
    sidebar.show();
    application.processEvents();

    assert(sidebar.page() == lithe::windows::WorkbenchSidebar::SidebarPage::Project);
    auto* destinationSelector = sidebar.findChild<QTabBar*>(
        QStringLiteral("workbench.sidebar.destinationSelector"));
    assert(destinationSelector != nullptr);
    assert(destinationSelector->tabText(0) == QStringLiteral("项目"));
    assert(destinationSelector->tabText(1) == QStringLiteral("更改"));
    assert(destinationSelector->tabText(2) == QStringLiteral("搜索"));
    auto* pages = sidebar.findChild<QStackedWidget*>(
        QStringLiteral("workbench.sidebar.pages"));
    assert(pages != nullptr);
    assert(pages->currentIndex() == 0);

    assert(sidebar.objectName() == QStringLiteral("workbench.sidebar"));
    assert(sidebar.findChild<QTabBar*>(
               QStringLiteral("workbench.sidebar.destinationSelector")) == destinationSelector);
    assert(pages->objectName() == QStringLiteral("workbench.sidebar.pages"));
    assert(sidebar.projectTree()->objectName() ==
           QStringLiteral("workbench.sidebar.projectTree"));
    assert(sidebar.changesList()->objectName() ==
           QStringLiteral("workbench.sidebar.changesList"));
    assert(sidebar.searchField()->objectName() ==
           QStringLiteral("workbench.sidebar.searchField"));
    assert(sidebar.searchResults()->objectName() ==
           QStringLiteral("workbench.sidebar.searchResults"));
    assert(sidebar.projectTree()->sizePolicy().verticalPolicy() == QSizePolicy::Expanding);
    assert(sidebar.changesList()->sizePolicy().verticalPolicy() == QSizePolicy::Expanding);
    assert(sidebar.searchResults()->sizePolicy().verticalPolicy() == QSizePolicy::Expanding);

    sidebar.setPage(lithe::windows::WorkbenchSidebar::SidebarPage::Changes);
    assert(sidebar.page() == lithe::windows::WorkbenchSidebar::SidebarPage::Changes);
    assert(pages->currentIndex() == 1);
    assert(!pages->widget(0)->isVisible());
    assert(pages->currentWidget()->isVisible());
    sidebar.setPage(lithe::windows::WorkbenchSidebar::SidebarPage::Search);
    assert(sidebar.page() == lithe::windows::WorkbenchSidebar::SidebarPage::Search);
    assert(pages->currentIndex() == 2);
    assert(!pages->widget(1)->isVisible());
    assert(pages->currentWidget()->isVisible());

    QString submittedQuery;
    int searchSubmissionCount = 0;
    QObject::connect(&sidebar, &lithe::windows::WorkbenchSidebar::searchSubmitted,
                     [&submittedQuery, &searchSubmissionCount](const QString& query) {
        submittedQuery = query;
        ++searchSubmissionCount;
    });
    sidebar.searchField()->setText(QStringLiteral("  workspace search  "));
    pressReturn(sidebar.searchField());
    assert(searchSubmissionCount == 1);
    assert(submittedQuery == QStringLiteral("workspace search"));
    sidebar.searchField()->setText(QStringLiteral(" \t "));
    pressReturn(sidebar.searchField());
    assert(searchSubmissionCount == 1);

    QTreeWidgetItem* activatedProjectItem = nullptr;
    int activatedProjectColumn = -1;
    QPoint contextMenuPosition;
    QObject::connect(&sidebar, &lithe::windows::WorkbenchSidebar::projectItemActivated,
                     [&activatedProjectItem, &activatedProjectColumn](QTreeWidgetItem* item,
                                                                       int column) {
        activatedProjectItem = item;
        activatedProjectColumn = column;
    });
    QObject::connect(&sidebar,
                     &lithe::windows::WorkbenchSidebar::projectContextMenuRequested,
                     [&contextMenuPosition](const QPoint& position) {
        contextMenuPosition = position;
    });
    auto* projectItem = new QTreeWidgetItem({QStringLiteral("src")});
    sidebar.projectTree()->addTopLevelItem(projectItem);
    sidebar.projectTree()->itemActivated(projectItem, 2);
    sidebar.projectTree()->customContextMenuRequested(QPoint(17, 23));
    assert(activatedProjectItem == projectItem);
    assert(activatedProjectColumn == 2);
    assert(contextMenuPosition == QPoint(17, 23));

    QListWidgetItem* activatedChangeItem = nullptr;
    QListWidgetItem* activatedSearchItem = nullptr;
    QObject::connect(&sidebar, &lithe::windows::WorkbenchSidebar::changesItemActivated,
                     [&activatedChangeItem](QListWidgetItem* item) {
        activatedChangeItem = item;
    });
    QObject::connect(&sidebar, &lithe::windows::WorkbenchSidebar::searchResultActivated,
                     [&activatedSearchItem](QListWidgetItem* item) {
        activatedSearchItem = item;
    });
    auto* changeItem = new QListWidgetItem(QStringLiteral("M src/main.cpp"));
    auto* searchItem = new QListWidgetItem(QStringLiteral("src/main.cpp:10"));
    sidebar.changesList()->addItem(changeItem);
    sidebar.searchResults()->addItem(searchItem);
    sidebar.changesList()->itemActivated(changeItem);
    sidebar.searchResults()->itemActivated(searchItem);
    assert(activatedChangeItem == changeItem);
    assert(activatedSearchItem == searchItem);

    sidebar.setPage(lithe::windows::WorkbenchSidebar::SidebarPage::Project);
    sidebar.showProjectLoading();
    assert(sidebar.projectTree()->topLevelItemCount() == 0);
    assertVisibleStatus(sidebar, "workbench.sidebar.projectStatus",
                        QStringLiteral("Loading project..."));
    sidebar.showProjectEmpty();
    assertVisibleStatus(sidebar, "workbench.sidebar.projectStatus",
                        QStringLiteral("No project loaded."));
    sidebar.showProjectError();
    assertVisibleStatus(sidebar, "workbench.sidebar.projectStatus",
                        QStringLiteral("Unable to load project."));
    auto* readyProjectItem = new QTreeWidgetItem({QStringLiteral("src")});
    sidebar.projectTree()->addTopLevelItem(readyProjectItem);
    sidebar.showProjectReady();
    assert(sidebar.projectTree()->topLevelItemCount() == 1);
    auto* projectStatus = statusLabel(
        sidebar, "workbench.sidebar.projectStatus");
    assert(projectStatus != nullptr);
    assert(!projectStatus->isVisible());

    sidebar.setPage(lithe::windows::WorkbenchSidebar::SidebarPage::Changes);
    sidebar.showChangesLoading();
    assert(sidebar.changesList()->count() == 0);
    assertVisibleStatus(sidebar, "workbench.sidebar.changesStatus",
                        QStringLiteral("Loading changes..."));
    sidebar.showChangesEmpty();
    assertVisibleStatus(sidebar, "workbench.sidebar.changesStatus",
                        QStringLiteral("No changes."));
    sidebar.showChangesError();
    assertVisibleStatus(sidebar, "workbench.sidebar.changesStatus",
                        QStringLiteral("Unable to load changes."));

    sidebar.setPage(lithe::windows::WorkbenchSidebar::SidebarPage::Search);
    sidebar.showSearchIdle();
    assertVisibleStatus(sidebar, "workbench.sidebar.searchStatus",
                        QStringLiteral("Enter a search query."));
    sidebar.showSearchLoading();
    assert(sidebar.searchResults()->count() == 0);
    assertVisibleStatus(sidebar, "workbench.sidebar.searchStatus",
                        QStringLiteral("Searching..."));
    sidebar.showSearchEmpty();
    assertVisibleStatus(sidebar, "workbench.sidebar.searchStatus",
                        QStringLiteral("No search results."));
    sidebar.showSearchError();
    assertVisibleStatus(sidebar, "workbench.sidebar.searchStatus",
                        QStringLiteral("Unable to search."));
    return 0;
}
