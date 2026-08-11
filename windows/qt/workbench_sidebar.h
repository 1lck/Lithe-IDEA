#pragma once

#include <QWidget>

class QLabel;
class QListWidget;
class QListWidgetItem;
class QLineEdit;
class QPoint;
class QString;
class QStackedWidget;
class QTabBar;
class QTreeWidget;
class QTreeWidgetItem;

namespace lithe::windows {

class WorkbenchSidebar final : public QWidget {
    Q_OBJECT

public:
    enum class SidebarPage {
        Project = 0,
        Changes = 1,
        Search = 2,
    };
    Q_ENUM(SidebarPage)

    explicit WorkbenchSidebar(QWidget* parent = nullptr);

    void setPage(SidebarPage page);
    SidebarPage page() const;

    QTreeWidget* projectTree() const;
    QListWidget* changesList() const;
    QLineEdit* searchField() const;
    QListWidget* searchResults() const;

    void showProjectLoading();
    void showProjectEmpty();
    void showProjectError();
    void showProjectReady();
    void showChangesLoading();
    void showChangesEmpty();
    void showChangesError();
    void showSearchIdle();
    void showSearchLoading();
    void showSearchEmpty();
    void showSearchError();

signals:
    void pageChanged(SidebarPage page);
    void projectItemActivated(QTreeWidgetItem* item, int column);
    void projectContextMenuRequested(const QPoint& position);
    void changesItemActivated(QListWidgetItem* item);
    void searchSubmitted(const QString& query);
    void searchResultActivated(QListWidgetItem* item);

private:
    void setStatus(QLabel* label, const QString& text);

    SidebarPage page_ = SidebarPage::Project;
    QTabBar* destinationSelector_ = nullptr;
    QStackedWidget* pages_ = nullptr;
    QTreeWidget* projectTree_ = nullptr;
    QListWidget* changesList_ = nullptr;
    QLineEdit* searchField_ = nullptr;
    QListWidget* searchResults_ = nullptr;
    QLabel* projectStatus_ = nullptr;
    QLabel* changesStatus_ = nullptr;
    QLabel* searchStatus_ = nullptr;
};

}
