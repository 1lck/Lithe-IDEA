#include "workbench_sidebar.h"

#include "ui_translation.h"

#include <QAbstractItemView>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QStackedWidget>
#include <QTabBar>
#include <QTreeWidget>
#include <QVBoxLayout>

namespace lithe::windows {

namespace {

QLabel* makeStatusLabel(QWidget* parent, const char* objectName) {
    auto* label = new QLabel(parent);
    label->setObjectName(QString::fromLatin1(objectName));
    label->setAlignment(Qt::AlignLeft | Qt::AlignVCenter);
    label->setWordWrap(true);
    return label;
}

void configureList(QAbstractItemView* list) {
    list->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    list->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    list->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
}

}

WorkbenchSidebar::WorkbenchSidebar(QWidget* parent)
    : QWidget(parent) {
    setObjectName(QStringLiteral("workbench.sidebar"));
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(8);

    destinationSelector_ = new QTabBar(this);
    destinationSelector_->setObjectName(
        QStringLiteral("workbench.sidebar.destinationSelector"));
    destinationSelector_->setExpanding(false);
    destinationSelector_->setUsesScrollButtons(false);
    destinationSelector_->addTab(uiText(QStringLiteral("Project")));
    destinationSelector_->addTab(uiText(QStringLiteral("Changes")));
    destinationSelector_->addTab(uiText(QStringLiteral("Search")));
    layout->addWidget(destinationSelector_);

    pages_ = new QStackedWidget(this);
    pages_->setObjectName(QStringLiteral("workbench.sidebar.pages"));
    layout->addWidget(pages_, 1);

    auto* projectPage = new QWidget(pages_);
    projectPage->setObjectName(QStringLiteral("workbench.sidebar.projectPage"));
    auto* projectLayout = new QVBoxLayout(projectPage);
    projectLayout->setContentsMargins(0, 0, 0, 0);
    projectLayout->setSpacing(6);
    projectStatus_ = makeStatusLabel(projectPage, "workbench.sidebar.projectStatus");
    projectStatus_->setText(QStringLiteral("No project loaded."));
    projectLayout->addWidget(projectStatus_);
    projectTree_ = new QTreeWidget(projectPage);
    projectTree_->setObjectName(QStringLiteral("workbench.sidebar.projectTree"));
    projectTree_->setHeaderHidden(true);
    projectTree_->setContextMenuPolicy(Qt::CustomContextMenu);
    configureList(projectTree_);
    projectLayout->addWidget(projectTree_, 1);
    pages_->addWidget(projectPage);

    auto* changesPage = new QWidget(pages_);
    changesPage->setObjectName(QStringLiteral("workbench.sidebar.changesPage"));
    auto* changesLayout = new QVBoxLayout(changesPage);
    changesLayout->setContentsMargins(0, 0, 0, 0);
    changesLayout->setSpacing(6);
    changesStatus_ = makeStatusLabel(changesPage, "workbench.sidebar.changesStatus");
    changesStatus_->setText(QStringLiteral("No changes."));
    changesLayout->addWidget(changesStatus_);
    changesList_ = new QListWidget(changesPage);
    changesList_->setObjectName(QStringLiteral("workbench.sidebar.changesList"));
    configureList(changesList_);
    changesLayout->addWidget(changesList_, 1);
    pages_->addWidget(changesPage);

    auto* searchPage = new QWidget(pages_);
    searchPage->setObjectName(QStringLiteral("workbench.sidebar.searchPage"));
    auto* searchLayout = new QVBoxLayout(searchPage);
    searchLayout->setContentsMargins(0, 0, 0, 0);
    searchLayout->setSpacing(6);
    searchField_ = new QLineEdit(searchPage);
    searchField_->setObjectName(QStringLiteral("workbench.sidebar.searchField"));
    searchField_->setPlaceholderText(QStringLiteral("Search workspace"));
    searchField_->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    searchLayout->addWidget(searchField_);
    searchStatus_ = makeStatusLabel(searchPage, "workbench.sidebar.searchStatus");
    searchStatus_->setText(QStringLiteral("Enter a search query."));
    searchLayout->addWidget(searchStatus_);
    searchResults_ = new QListWidget(searchPage);
    searchResults_->setObjectName(QStringLiteral("workbench.sidebar.searchResults"));
    configureList(searchResults_);
    searchLayout->addWidget(searchResults_, 1);
    pages_->addWidget(searchPage);

    connect(destinationSelector_, &QTabBar::currentChanged, this, [this](int index) {
        if (index < 0 || index > static_cast<int>(SidebarPage::Search)) return;
        const auto nextPage = static_cast<SidebarPage>(index);
        if (page_ == nextPage) return;
        page_ = nextPage;
        pages_->setCurrentIndex(index);
        emit pageChanged(page_);
    });
    connect(projectTree_, &QTreeWidget::itemActivated,
            this, &WorkbenchSidebar::projectItemActivated);
    connect(projectTree_, &QTreeWidget::customContextMenuRequested,
            this, &WorkbenchSidebar::projectContextMenuRequested);
    connect(changesList_, &QListWidget::itemActivated,
            this, &WorkbenchSidebar::changesItemActivated);
    connect(searchResults_, &QListWidget::itemActivated,
            this, &WorkbenchSidebar::searchResultActivated);
    connect(searchField_, &QLineEdit::returnPressed, this, [this] {
        const auto query = searchField_->text().trimmed();
        if (!query.isEmpty()) emit searchSubmitted(query);
    });
}

void WorkbenchSidebar::setPage(SidebarPage page) {
    const auto index = static_cast<int>(page);
    if (index < 0 || index > static_cast<int>(SidebarPage::Search)) return;
    destinationSelector_->setCurrentIndex(index);
}

WorkbenchSidebar::SidebarPage WorkbenchSidebar::page() const {
    return page_;
}

QTreeWidget* WorkbenchSidebar::projectTree() const {
    return projectTree_;
}

QListWidget* WorkbenchSidebar::changesList() const {
    return changesList_;
}

QLineEdit* WorkbenchSidebar::searchField() const {
    return searchField_;
}

QListWidget* WorkbenchSidebar::searchResults() const {
    return searchResults_;
}

void WorkbenchSidebar::setStatus(QLabel* label, const QString& text) {
    label->setText(text);
    label->setVisible(true);
}

void WorkbenchSidebar::showProjectLoading() {
    projectTree_->clear();
    setStatus(projectStatus_, QStringLiteral("Loading project..."));
}

void WorkbenchSidebar::showProjectEmpty() {
    projectTree_->clear();
    setStatus(projectStatus_, QStringLiteral("No project loaded."));
}

void WorkbenchSidebar::showProjectError() {
    projectTree_->clear();
    setStatus(projectStatus_, QStringLiteral("Unable to load project."));
}

void WorkbenchSidebar::showProjectReady() {
    projectStatus_->setVisible(false);
}

void WorkbenchSidebar::showChangesLoading() {
    changesList_->clear();
    setStatus(changesStatus_, QStringLiteral("Loading changes..."));
}

void WorkbenchSidebar::showChangesEmpty() {
    changesList_->clear();
    setStatus(changesStatus_, QStringLiteral("No changes."));
}

void WorkbenchSidebar::showChangesError() {
    changesList_->clear();
    setStatus(changesStatus_, QStringLiteral("Unable to load changes."));
}

void WorkbenchSidebar::showSearchIdle() {
    searchField_->clear();
    searchResults_->clear();
    setStatus(searchStatus_, QStringLiteral("Enter a search query."));
}

void WorkbenchSidebar::showSearchLoading() {
    searchResults_->clear();
    setStatus(searchStatus_, QStringLiteral("Searching..."));
}

void WorkbenchSidebar::showSearchEmpty() {
    searchResults_->clear();
    setStatus(searchStatus_, QStringLiteral("No search results."));
}

void WorkbenchSidebar::showSearchError() {
    searchResults_->clear();
    setStatus(searchStatus_, QStringLiteral("Unable to search."));
}

}
