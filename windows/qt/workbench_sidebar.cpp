#include "workbench_sidebar.h"

#include "ui_translation.h"
#include "ui_tokens.h"
#include "workbench_icons.h"

#include <QAbstractItemView>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QSize>
#include <QStackedWidget>
#include <QTabBar>
#include <QToolButton>
#include <QTreeWidget>
#include <QStyle>
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
    list->setMouseTracking(true);
}

}

WorkbenchSidebar::WorkbenchSidebar(QWidget* parent)
    : QWidget(parent) {
    setObjectName(QStringLiteral("workbench.sidebar"));
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    auto* shellLayout = new QHBoxLayout(this);
    shellLayout->setContentsMargins(0, 0, 0, 0);
    shellLayout->setSpacing(0);

    auto* toolRail = new QWidget(this);
    toolRail->setObjectName(QStringLiteral("workbench.sidebar.toolRail"));
    toolRail->setFixedWidth(ui::ActivityRailWidth);
    auto* railLayout = new QVBoxLayout(toolRail);
    railLayout->setContentsMargins(6, 8, 6, 8);
    railLayout->setSpacing(6);
    const auto addRailButton = [this, railLayout](const QString& resource,
                                                   QStyle::StandardPixmap fallback,
                                                   const QString& tooltip,
                                                   int page) {
        auto* button = new QToolButton(this);
        button->setObjectName(QStringLiteral("workbench.sidebar.railButton%1").arg(page));
        button->setProperty("toolRail", true);
        button->setIcon(resource.isEmpty() ? style()->standardIcon(fallback)
                                           : workbenchActionIcon(resource));
        button->setToolTip(tooltip);
        button->setCheckable(true);
        button->setAutoRaise(true);
        button->setIconSize(QSize(18, 18));
        button->setFixedSize(36, 32);
        railLayout->addWidget(button);
        connect(button, &QToolButton::clicked, this, [this, page] {
            destinationSelector_->setCurrentIndex(page);
        });
        return button;
    };
    auto* projectRailButton = addRailButton(QStringLiteral("toolwindows/toolWindowProject.svg"),
                                             QStyle::SP_DirOpenIcon,
                                             uiText(QStringLiteral("Project")), 0);
    auto* changesRailButton = addRailButton(QStringLiteral("toolwindows/toolWindowVcs.svg"),
                                             QStyle::SP_FileDialogDetailedView,
                                             uiText(QStringLiteral("Changes")), 1);
    auto* searchRailButton = addRailButton(QStringLiteral("actions/search.svg"),
                                            QStyle::SP_FileDialogContentsView,
                                            uiText(QStringLiteral("Search")), 2);
    railLayout->addStretch(1);
    const auto addToolButton = [this, railLayout](const QString& resource,
                                                  QStyle::StandardPixmap fallback,
                                                  const QString& tooltip,
                                                  auto signal) {
        auto* button = new QToolButton(this);
        button->setProperty("toolRail", true);
        button->setIcon(resource.isEmpty()
            ? style()->standardIcon(fallback)
            : workbenchActionIcon(resource));
        button->setToolTip(tooltip);
        button->setAutoRaise(true);
        button->setIconSize(QSize(17, 17));
        button->setFixedSize(36, 32);
        railLayout->addWidget(button);
        connect(button, &QToolButton::clicked, this, signal);
    };
    addToolButton(QString{}, QStyle::SP_ComputerIcon,
                  uiText(QStringLiteral("Terminal")),
                  &WorkbenchSidebar::terminalRequested);
    addToolButton(QStringLiteral("toolwindows/toolWindowVcs.svg"), QStyle::SP_FileIcon,
                  uiText(QStringLiteral("Git")),
                  &WorkbenchSidebar::gitRequested);
    addToolButton(QStringLiteral("toolwindows/toolWindowProblems.svg"), QStyle::SP_MessageBoxWarning,
                  uiText(QStringLiteral("Problems")),
                  &WorkbenchSidebar::problemsRequested);
    addToolButton(QStringLiteral("maven/toolWindowMaven.svg"), QStyle::SP_DriveHDIcon,
                  uiText(QStringLiteral("Maven")),
                  &WorkbenchSidebar::mavenRequested);
    addToolButton(QStringLiteral("toolwindows/toolWindowDebugger.svg"), QStyle::SP_MessageBoxInformation,
                  uiText(QStringLiteral("Debug")),
                  &WorkbenchSidebar::debugRequested);
    addToolButton(QStringLiteral("general/gear.svg"), QStyle::SP_FileDialogDetailedView,
                  uiText(QStringLiteral("Settings")),
                  &WorkbenchSidebar::settingsRequested);
    shellLayout->addWidget(toolRail);

    auto* content = new QWidget(this);
    content->setObjectName(QStringLiteral("workbench.sidebar.content"));
    auto* layout = new QVBoxLayout(content);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    shellLayout->addWidget(content, 1);

    destinationSelector_ = new QTabBar(this);
    destinationSelector_->setObjectName(
        QStringLiteral("workbench.sidebar.destinationSelector"));
    destinationSelector_->setExpanding(false);
    destinationSelector_->setUsesScrollButtons(false);
    destinationSelector_->addTab(uiText(QStringLiteral("Project")));
    destinationSelector_->addTab(uiText(QStringLiteral("Changes")));
    destinationSelector_->addTab(uiText(QStringLiteral("Search")));
    destinationSelector_->setVisible(false);

    pages_ = new QStackedWidget(this);
    pages_->setObjectName(QStringLiteral("workbench.sidebar.pages"));
    layout->addWidget(pages_, 1);

    auto* projectPage = new QWidget(pages_);
    projectPage->setObjectName(QStringLiteral("workbench.sidebar.projectPage"));
    auto* projectLayout = new QVBoxLayout(projectPage);
    projectLayout->setContentsMargins(0, 0, 0, 0);
    projectLayout->setSpacing(0);
    auto* projectHeader = new QWidget(projectPage);
    projectHeader->setObjectName(QStringLiteral("workbench.sidebar.header"));
    projectHeader->setFixedHeight(ui::PanelHeaderHeight);
    auto* projectHeaderLayout = new QHBoxLayout(projectHeader);
    projectHeaderLayout->setContentsMargins(10, 0, 6, 0);
    auto* projectTitle = new QLabel(uiText(QStringLiteral("Project")), projectHeader);
    projectTitle->setProperty("chromeRole", QStringLiteral("panelTitle"));
    projectHeaderLayout->addWidget(projectTitle);
    projectHeaderLayout->addStretch(1);
    auto* projectRefresh = new QToolButton(projectHeader);
    projectRefresh->setObjectName(QStringLiteral("workbench.sidebar.refresh"));
    projectRefresh->setIcon(style()->standardIcon(QStyle::SP_BrowserReload));
    projectRefresh->setToolTip(uiText(QStringLiteral("Refresh")));
    projectRefresh->setAutoRaise(true);
    projectRefresh->setFixedSize(28, 28);
    projectHeaderLayout->addWidget(projectRefresh);
    projectLayout->addWidget(projectHeader);
    connect(projectRefresh, &QToolButton::clicked,
            this, &WorkbenchSidebar::projectRefreshRequested);
    projectStatus_ = makeStatusLabel(projectPage, "workbench.sidebar.projectStatus");
    projectStatus_->setText(QStringLiteral("No project loaded."));
    projectLayout->addWidget(projectStatus_);
    projectTree_ = new QTreeWidget(projectPage);
    projectTree_->setObjectName(QStringLiteral("workbench.sidebar.projectTree"));
    projectTree_->setHeaderHidden(true);
    projectTree_->setContextMenuPolicy(Qt::CustomContextMenu);
    projectTree_->setIconSize(QSize(ui::FileIconSize, ui::FileIconSize));
    projectTree_->setIndentation(ui::SidebarIndent);
    projectTree_->setUniformRowHeights(true);
    projectTree_->setAnimated(false);
    configureList(projectTree_);
    projectLayout->addWidget(projectTree_, 1);
    pages_->addWidget(projectPage);

    auto* changesPage = new QWidget(pages_);
    changesPage->setObjectName(QStringLiteral("workbench.sidebar.changesPage"));
    auto* changesLayout = new QVBoxLayout(changesPage);
    changesLayout->setContentsMargins(0, 0, 0, 0);
    changesLayout->setSpacing(0);
    auto* changesTitle = new QLabel(uiText(QStringLiteral("Changes")), changesPage);
    changesTitle->setProperty("chromeRole", QStringLiteral("panelTitle"));
    changesTitle->setContentsMargins(10, 0, 0, 0);
    changesTitle->setFixedHeight(ui::PanelHeaderHeight);
    changesLayout->addWidget(changesTitle);
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
    auto* searchTitle = new QLabel(uiText(QStringLiteral("Search")), searchPage);
    searchTitle->setProperty("chromeRole", QStringLiteral("panelTitle"));
    searchTitle->setContentsMargins(10, 0, 0, 0);
    searchTitle->setFixedHeight(ui::PanelHeaderHeight);
    searchLayout->addWidget(searchTitle);
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
    connect(destinationSelector_, &QTabBar::currentChanged,
            this, [projectRailButton, changesRailButton, searchRailButton](int index) {
        projectRailButton->setChecked(index == 0);
        changesRailButton->setChecked(index == 1);
        searchRailButton->setChecked(index == 2);
    });
    projectRailButton->setChecked(true);
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
