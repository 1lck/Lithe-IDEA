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

bool samePath(const QString& left, const QString& right) {
    auto normalizedLeft = left;
    auto normalizedRight = right;
    normalizedLeft.replace(u'\\', u'/');
    normalizedRight.replace(u'\\', u'/');
    return QString::compare(normalizedLeft, normalizedRight, Qt::CaseInsensitive) == 0;
}

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

    statusBanner_ = new QWidget(this);
    statusBanner_->setObjectName(QStringLiteral("workbench.editorArea.documentStatus"));
    statusBanner_->setAccessibleName(QStringLiteral("Document status"));
    auto* statusLayout = new QHBoxLayout(statusBanner_);
    statusLayout->setContentsMargins(8, 5, 8, 5);
    statusBannerText_ = new QLabel(statusBanner_);
    statusBannerText_->setWordWrap(true);
    statusLayout->addWidget(statusBannerText_, 1);
    statusPrimary_ = new QPushButton(statusBanner_);
    statusSecondary_ = new QPushButton(statusBanner_);
    statusPrimary_->setAccessibleName(QStringLiteral("Primary document recovery action"));
    statusSecondary_->setAccessibleName(QStringLiteral("Secondary document recovery action"));
    statusLayout->addWidget(statusPrimary_);
    statusLayout->addWidget(statusSecondary_);
    statusBanner_->setVisible(false);
    layout->addWidget(statusBanner_);

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
    editor_->setProperty("documentPath", QString{});
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
    connect(statusPrimary_, &QPushButton::clicked, this, [this] {
        const auto path = statusBanner_->property("documentPath").toString();
        const auto kind = statusBanner_->property("statusKind").toString();
        if (kind == QStringLiteral("modified")) emit keepEditorVersionRequested(path);
        else if (kind == QStringLiteral("deleted")) emit recreateDeletedFileRequested(path);
    });
    connect(statusSecondary_, &QPushButton::clicked, this, [this] {
        const auto path = statusBanner_->property("documentPath").toString();
        const auto kind = statusBanner_->property("statusKind").toString();
        if (kind == QStringLiteral("modified")) emit loadDiskVersionRequested(path);
        else if (kind == QStringLiteral("deleted")) emit closeDeletedFileRequested(path);
    });
}

WorkbenchCodeEditor* WorkbenchEditorArea::editor() const {
    return editor_;
}

WorkbenchCodeEditor* WorkbenchEditorArea::ensureEditor(const QString& relativePath) {
    if (auto* existing = editorForPath(relativePath)) return existing;
    WorkbenchCodeEditor* editor = nullptr;
    if (editor_ != nullptr && editor_->property("documentPath").toString().isEmpty()) {
        editor = editor_;
    } else {
        editor = new WorkbenchCodeEditor(editorStack_);
        editor->setObjectName(QStringLiteral("workbench.editorArea.editor"));
        editor->setPlaceholderText(QStringLiteral("Loading document…"));
        editor->setMinimumHeight(kEditorTopMinHeight);
        editor->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        editorStack_->addWidget(editor);
        emit editorCreated(editor);
    }
    editor->setProperty("documentPath", relativePath);
    return editor;
}

WorkbenchCodeEditor* WorkbenchEditorArea::editorForPath(const QString& relativePath) const {
    for (int index = 0; index < editorStack_->count(); ++index) {
        auto* editor = dynamic_cast<WorkbenchCodeEditor*>(editorStack_->widget(index));
        if (editor != nullptr && samePath(editor->property("documentPath").toString(), relativePath)) {
            return editor;
        }
    }
    return nullptr;
}

WorkbenchCodeEditor* WorkbenchEditorArea::setActiveEditor(const QString& relativePath) {
    auto* editor = ensureEditor(relativePath);
    editor_ = editor;
    editorStack_->setCurrentWidget(editor);
    return editor;
}

void WorkbenchEditorArea::removeEditor(const QString& relativePath) {
    auto* editor = editorForPath(relativePath);
    if (editor == nullptr) return;
    editorStack_->removeWidget(editor);
    if (editor == editor_) editor_ = nullptr;
    editor->deleteLater();
}

void WorkbenchEditorArea::clearEditors() {
    for (int index = editorStack_->count() - 1; index >= 0; --index) {
        auto* editor = dynamic_cast<WorkbenchCodeEditor*>(editorStack_->widget(index));
        if (editor == nullptr) continue;
        editorStack_->removeWidget(editor);
        editor->deleteLater();
    }
    editor_ = new WorkbenchCodeEditor(editorStack_);
    editor_->setObjectName(QStringLiteral("workbench.editorArea.editor"));
    editor_->setProperty("documentPath", QString{});
    editor_->setMinimumHeight(kEditorTopMinHeight);
    editorStack_->addWidget(editor_);
    emit editorCreated(editor_);
    editorStack_->setCurrentWidget(emptyState_);
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

void WorkbenchEditorArea::showModifiedConflict(const QString& relativePath) {
    statusBanner_->setProperty("documentPath", relativePath);
    statusBanner_->setProperty("statusKind", QStringLiteral("modified"));
    statusBannerText_->setText(QStringLiteral("This file changed on disk. Your editor version was kept."));
    statusPrimary_->setText(QStringLiteral("Keep Editor Version"));
    statusSecondary_->setText(QStringLiteral("Load Disk Version"));
    statusPrimary_->setVisible(true);
    statusSecondary_->setVisible(true);
    statusBanner_->setVisible(true);
}

void WorkbenchEditorArea::showDeletedConflict(const QString& relativePath) {
    statusBanner_->setProperty("documentPath", relativePath);
    statusBanner_->setProperty("statusKind", QStringLiteral("deleted"));
    statusBannerText_->setText(QStringLiteral("This file was deleted outside the editor. The buffer is still open."));
    statusPrimary_->setText(QStringLiteral("Recreate"));
    statusSecondary_->setText(QStringLiteral("Close"));
    statusPrimary_->setVisible(true);
    statusSecondary_->setVisible(true);
    statusBanner_->setVisible(true);
}

void WorkbenchEditorArea::showDocumentError(const QString& relativePath,
                                            const QString& message) {
    statusBanner_->setProperty("documentPath", relativePath);
    statusBanner_->setProperty("statusKind", QStringLiteral("error"));
    statusBannerText_->setText(message);
    statusPrimary_->setVisible(false);
    statusSecondary_->setVisible(false);
    statusBanner_->setVisible(true);
}

void WorkbenchEditorArea::clearDocumentStatus(const QString& relativePath) {
    if (!samePath(statusBanner_->property("documentPath").toString(), relativePath)) return;
    statusBanner_->setVisible(false);
    statusBanner_->setProperty("documentPath", QString{});
    statusBanner_->setProperty("statusKind", QString{});
}

}
