#include "workbench_editor_area.h"

#include "workbench_code_editor.h"
#include "workbench_ui_state.h"

#include <QAbstractItemView>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QPushButton>
#include <QSizePolicy>
#include <QStackedWidget>
#include <QTabBar>
#include <QVBoxLayout>

namespace lithe::windows {

namespace {

QListWidget* makeResultList(QWidget* parent, const QString& objectName) {
    auto* list = new QListWidget(parent);
    list->setObjectName(objectName);
    list->setMaximumHeight(170);
    list->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    list->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    list->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    list->setVisible(false);
    return list;
}

QPushButton* makeFindButton(QWidget* parent,
                            const QString& objectName,
                            const QString& text) {
    auto* button = new QPushButton(text, parent);
    button->setObjectName(objectName);
    return button;
}

}

WorkbenchEditorArea::WorkbenchEditorArea(QWidget* parent)
    : QWidget(parent) {
    setObjectName(QStringLiteral("workbench.editorArea"));
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(6);

    findBar_ = new QWidget(this);
    findBar_->setObjectName(QStringLiteral("workbench.editorArea.findBar"));
    auto* findLayout = new QHBoxLayout(findBar_);
    findLayout->setContentsMargins(0, 0, 0, 0);
    findField_ = new QLineEdit(findBar_);
    findField_->setObjectName(QStringLiteral("workbench.editorArea.findField"));
    findField_->setPlaceholderText(QStringLiteral("Find in editor"));
    findLayout->addWidget(findField_, 1);
    auto* previous = makeFindButton(findBar_,
                                    QStringLiteral("workbench.editorArea.findPrevious"),
                                    QStringLiteral("Previous"));
    auto* next = makeFindButton(findBar_,
                                QStringLiteral("workbench.editorArea.findNext"),
                                QStringLiteral("Next"));
    findStatus_ = new QLabel(findBar_);
    findStatus_->setObjectName(QStringLiteral("workbench.editorArea.findStatus"));
    findStatus_->setMinimumWidth(72);
    findLayout->addWidget(previous);
    findLayout->addWidget(next);
    findLayout->addWidget(findStatus_);
    auto* close = makeFindButton(findBar_,
                                 QStringLiteral("workbench.editorArea.findClose"),
                                 QStringLiteral("Close"));
    findLayout->addWidget(close);
    findBar_->setVisible(false);
    layout->addWidget(findBar_);

    editorTabs_ = new QTabBar(this);
    editorTabs_->setObjectName(QStringLiteral("workbench.editorArea.editorTabs"));
    editorTabs_->setTabsClosable(true);
    editorTabs_->setMovable(true);
    editorTabs_->setExpanding(false);
    editorTabs_->setDocumentMode(true);
    layout->addWidget(editorTabs_);

    editorStack_ = new QStackedWidget(this);
    editorStack_->setObjectName(QStringLiteral("workbench.editorArea.editorStack"));
    editorStack_->setMinimumHeight(kEditorTopMinHeight);

    emptyState_ = new QLabel(editorStack_);
    emptyState_->setObjectName(QStringLiteral("workbench.editorArea.emptyState"));
    emptyState_->setAlignment(Qt::AlignCenter);
    emptyState_->setText(QStringLiteral("Open a file from the workspace tree"));
    emptyState_->setWordWrap(true);
    editorStack_->addWidget(emptyState_);

    editor_ = new WorkbenchCodeEditor(editorStack_);
    editor_->setObjectName(QStringLiteral("workbench.editorArea.editor"));
    editor_->setPlaceholderText(QStringLiteral("Open a file from the workspace tree"));
    editor_->setMinimumHeight(kEditorTopMinHeight);
    editor_->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    editorStack_->addWidget(editor_);
    editorStack_->setCurrentWidget(emptyState_);
    layout->addWidget(editorStack_, 1);

    searchResults_ = makeResultList(
        this, QStringLiteral("workbench.editorArea.searchResults"));
    javaNavigationResults_ = makeResultList(
        this, QStringLiteral("workbench.editorArea.javaNavigationResults"));
    diagnostics_ = makeResultList(
        this, QStringLiteral("workbench.editorArea.diagnostics"));
    layout->addWidget(searchResults_);
    layout->addWidget(javaNavigationResults_);
    layout->addWidget(diagnostics_);

    connect(editorTabs_, &QTabBar::currentChanged, this,
            &WorkbenchEditorArea::tabChanged);
    connect(editorTabs_, &QTabBar::tabCloseRequested, this,
            &WorkbenchEditorArea::tabCloseRequested);
    connect(previous, &QPushButton::clicked, this,
            &WorkbenchEditorArea::findPreviousRequested);
    connect(next, &QPushButton::clicked, this,
            &WorkbenchEditorArea::findNextRequested);
    connect(findField_, &QLineEdit::returnPressed, this,
            &WorkbenchEditorArea::findNextRequested);
    connect(close, &QPushButton::clicked, this, [this] {
        findBar_->setVisible(false);
        emit findBarCloseRequested();
    });
    connect(searchResults_, &QListWidget::itemActivated, this,
            &WorkbenchEditorArea::searchResultActivated);
    connect(javaNavigationResults_, &QListWidget::itemActivated, this,
            &WorkbenchEditorArea::javaNavigationResultActivated);
    connect(diagnostics_, &QListWidget::itemActivated, this,
            &WorkbenchEditorArea::diagnosticActivated);
}

WorkbenchCodeEditor* WorkbenchEditorArea::editor() const {
    return editor_;
}

QTabBar* WorkbenchEditorArea::editorTabs() const {
    return editorTabs_;
}

QWidget* WorkbenchEditorArea::findBar() const {
    return findBar_;
}

QLineEdit* WorkbenchEditorArea::findField() const {
    return findField_;
}

QLabel* WorkbenchEditorArea::findStatus() const {
    return findStatus_;
}

QListWidget* WorkbenchEditorArea::searchResults() const {
    return searchResults_;
}

QListWidget* WorkbenchEditorArea::javaNavigationResults() const {
    return javaNavigationResults_;
}

QListWidget* WorkbenchEditorArea::diagnostics() const {
    return diagnostics_;
}

QLabel* WorkbenchEditorArea::emptyState() const {
    return emptyState_;
}

void WorkbenchEditorArea::setEmptyStateVisible(bool visible) {
    editorStack_->setCurrentWidget(visible ? static_cast<QWidget*>(emptyState_)
                                           : static_cast<QWidget*>(editor_));
}

}
