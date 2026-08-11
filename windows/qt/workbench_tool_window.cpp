#include "workbench_tool_window.h"

#include "ui_translation.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QStackedWidget>
#include <QTabBar>
#include <QVBoxLayout>

namespace lithe::windows {

namespace {

constexpr std::array<BottomToolKind, 6> kToolKinds{
    BottomToolKind::Terminal,
    BottomToolKind::Build,
    BottomToolKind::Problems,
    BottomToolKind::Debug,
    BottomToolKind::Git,
    BottomToolKind::Diff,
};

}

WorkbenchToolWindow::WorkbenchToolWindow(QWidget* parent)
    : QWidget(parent) {
    setObjectName(QStringLiteral("workbench.toolWindow"));
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    auto* header = new QWidget(this);
    header->setObjectName(QStringLiteral("workbench.toolWindow.header"));
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(10, 4, 6, 4);
    headerLayout->setSpacing(8);
    title_ = new QLabel(header);
    title_->setObjectName(QStringLiteral("workbench.toolWindow.title"));
    title_->setText(titleFor(kind_));
    headerLayout->addWidget(title_);

    toolSelector_ = new QTabBar(header);
    toolSelector_->setObjectName(QStringLiteral("workbench.toolWindow.selector"));
    toolSelector_->setExpanding(false);
    toolSelector_->setUsesScrollButtons(false);
    for (const auto kind : kToolKinds) toolSelector_->addTab(titleFor(kind));
    headerLayout->addWidget(toolSelector_);
    headerLayout->addStretch(1);

    auto* hide = new QPushButton(QStringLiteral("-"), header);
    hide->setObjectName(QStringLiteral("workbench.toolWindow.hideButton"));
    hide->setToolTip(QStringLiteral("Hide tool window"));
    hide->setFixedWidth(30);
    headerLayout->addWidget(hide);
    layout->addWidget(header);

    pages_ = new QStackedWidget(this);
    pages_->setObjectName(QStringLiteral("workbench.toolWindow.pages"));
    pages_->setMinimumHeight(kBottomToolMinHeight);
    layout->addWidget(pages_, 1);

    for (std::size_t index = 0; index < kToolKinds.size(); ++index) {
        const auto kind = kToolKinds[index];
        auto* pageWidget = new QWidget(pages_);
        pageWidget->setObjectName(QStringLiteral("workbench.toolWindow.page.%1")
                                      .arg(titleFor(kind).toLower()));
        pageWidget->setMinimumHeight(kBottomToolMinHeight);
        auto* pageLayout = new QVBoxLayout(pageWidget);
        pageLayout->setContentsMargins(8, 8, 8, 8);
        auto* placeholder = new QLabel(pageWidget);
        placeholder->setObjectName(QStringLiteral("workbench.toolWindow.empty.%1")
                                       .arg(titleFor(kind).toLower()));
        placeholder->setAlignment(Qt::AlignCenter);
        placeholder->setText(QStringLiteral("No %1 panel is active.")
                                 .arg(titleFor(kind)));
        pageLayout->addWidget(placeholder, 1);
        pages_->addWidget(pageWidget);
        pageWidgets_[index] = pageWidget;
        placeholders_[index] = placeholder;
    }
    pages_->setCurrentIndex(0);

    connect(toolSelector_, &QTabBar::currentChanged, this, [this](int index) {
        if (index < 0 || index >= static_cast<int>(kToolKinds.size())) return;
        const auto nextKind = kToolKinds[static_cast<std::size_t>(index)];
        if (kind_ == nextKind && pages_->currentIndex() == index) return;
        kind_ = nextKind;
        pages_->setCurrentIndex(index);
        title_->setText(titleFor(kind_));
        emit toolChanged(kind_);
    });
    connect(hide, &QPushButton::clicked, this, &WorkbenchToolWindow::hideRequested);
}

BottomToolKind WorkbenchToolWindow::kind() const {
    return kind_;
}

void WorkbenchToolWindow::setKind(BottomToolKind kind) {
    const auto index = indexFor(kind);
    if (index < 0) return;
    toolSelector_->setCurrentIndex(index);
}

QTabBar* WorkbenchToolWindow::toolSelector() const {
    return toolSelector_;
}

QStackedWidget* WorkbenchToolWindow::pages() const {
    return pages_;
}

QWidget* WorkbenchToolWindow::page(BottomToolKind kind) const {
    const auto index = indexFor(kind);
    return index < 0 ? nullptr : pageWidgets_[static_cast<std::size_t>(index)];
}

void WorkbenchToolWindow::setPanel(BottomToolKind kind, QWidget* panel) {
    const auto index = indexFor(kind);
    if (index < 0 || panel == nullptr) return;
    auto* pageWidget = pageWidgets_[static_cast<std::size_t>(index)];
    auto* pageLayout = pageWidget == nullptr ? nullptr : pageWidget->layout();
    if (pageLayout == nullptr) return;
    if (auto* placeholder = placeholders_[static_cast<std::size_t>(index)]) {
        pageLayout->removeWidget(placeholder);
        delete placeholder;
        placeholders_[static_cast<std::size_t>(index)] = nullptr;
    }
    panel->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    pageLayout->addWidget(panel);
}

int WorkbenchToolWindow::indexFor(BottomToolKind kind) {
    for (std::size_t index = 0; index < kToolKinds.size(); ++index) {
        if (kToolKinds[index] == kind) return static_cast<int>(index);
    }
    return -1;
}

QString WorkbenchToolWindow::titleFor(BottomToolKind kind) {
    switch (kind) {
    case BottomToolKind::Terminal: return uiText(QStringLiteral("Terminal"));
    case BottomToolKind::Build: return uiText(QStringLiteral("Maven"));
    case BottomToolKind::Problems: return uiText(QStringLiteral("Problems"));
    case BottomToolKind::Debug: return uiText(QStringLiteral("Debug"));
    case BottomToolKind::Git: return uiText(QStringLiteral("Git"));
    case BottomToolKind::Diff: return uiText(QStringLiteral("Diff"));
    }
    return QStringLiteral("Tool Window");
}

}
