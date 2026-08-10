#pragma once

#include "git_feature.h"
#include "git_workflow_ui.h"

#include <QWidget>

#include <optional>
#include <string>
#include <vector>

class QCheckBox;
class QFrame;
class QLabel;
class QListWidget;
class QPlainTextEdit;
class QPushButton;
class QStackedWidget;
class QToolButton;
class QTreeWidget;
class QTreeWidgetItem;

namespace lithe::windows {

/// Left sidebar: Commit / Shelf tabs, operation banners, and commit composer.
class GitChangesPanel final : public QWidget {
    Q_OBJECT

public:
    explicit GitChangesPanel(QWidget* parent = nullptr);

    void applyState(const app::GitFeatureState& state);

    QString commitMessage() const;
    void setCommitMessage(const QString& message);
    void clearCommitMessage();
    bool isAmendChecked() const;
    void setAmendChecked(bool checked);
    void focusCommitMessage();

signals:
    void changeActivated(const QString& relativePath);
    void stagePathRequested(const QString& relativePath);
    void unstagePathRequested(const QString& relativePath);
    void stageAllRequested();
    void commitRequested();
    void commitAndPushRequested();
    void generateAiMessageRequested();
    void refreshRequested();
    void discardPathRequested(const QString& relativePath);
    void previewFirstChangeRequested();
    void settingsRequested();
    void continueOperationRequested();
    void abortOperationRequested();
    void skipOperationRequested();
    void filterConflictsRequested();
    void clearConflictFilterRequested();
    void filterStashRestoreConflictsRequested();
    void dismissStashRestoreNoticeRequested();
    void applyShelfRequested(const QString& shelfId);
    void dropShelfRequested(const QString& shelfId);
    void applyStashRequested(const QString& reference);
    void popStashRequested(const QString& reference);
    void dropStashRequested(const QString& reference);
    void refreshShelvesRequested();
    void refreshStashesRequested();

private:
    void rebuildChangesTree(const app::GitFeatureState& state);
    void rebuildShelfList(const app::GitFeatureState& state);
    void rebuildStashList(const app::GitFeatureState& state);
    void updateOperationBar(const app::GitFeatureState& state);
    void updateStashRestoreNotice(const app::GitFeatureState& state);
    void updateCommitActions(const app::GitFeatureState& state);
    void updateBranchLabel(const app::GitFeatureState& state);
    void onChangeItemChanged(QTreeWidgetItem* item, int column);
    void onChangeItemClicked(QTreeWidgetItem* item, int column);
    void selectTab(int index);

    QPushButton* commitTabButton_ = nullptr;
    QPushButton* shelfTabButton_ = nullptr;
    QStackedWidget* pages_ = nullptr;

    QWidget* commitPage_ = nullptr;
    QWidget* operationBar_ = nullptr;
    QFrame* operationDivider_ = nullptr;
    QLabel* operationTitle_ = nullptr;
    QLabel* operationProgress_ = nullptr;
    QPushButton* continueButton_ = nullptr;
    QPushButton* abortButton_ = nullptr;
    QPushButton* skipButton_ = nullptr;
    QPushButton* filterConflictsButton_ = nullptr;
    QPushButton* clearConflictFilterButton_ = nullptr;

    QWidget* stashRestoreNotice_ = nullptr;
    QLabel* stashRestoreLabel_ = nullptr;
    QPushButton* stashRestoreFilterButton_ = nullptr;
    QPushButton* stashRestoreDismissButton_ = nullptr;

    QToolButton* refreshButton_ = nullptr;
    QToolButton* discardButton_ = nullptr;
    QToolButton* stageAllToolbarButton_ = nullptr;
    QToolButton* previewButton_ = nullptr;
    QLabel* branchLabel_ = nullptr;

    QWidget* cleanState_ = nullptr;
    QLabel* cleanLabel_ = nullptr;
    QLabel* conflictEmptyLabel_ = nullptr;
    QTreeWidget* changesTree_ = nullptr;

    QCheckBox* amendCheck_ = nullptr;
    QPushButton* aiButton_ = nullptr;
    QLabel* stagedCountLabel_ = nullptr;
    QPlainTextEdit* commitEditor_ = nullptr;
    QPushButton* commitButton_ = nullptr;
    QPushButton* commitAndPushButton_ = nullptr;
    QPushButton* settingsButton_ = nullptr;

    QWidget* shelfPage_ = nullptr;
    QListWidget* shelvesList_ = nullptr;
    QListWidget* stashesList_ = nullptr;
    QPushButton* applyShelfButton_ = nullptr;
    QPushButton* dropShelfButton_ = nullptr;
    QPushButton* applyStashButton_ = nullptr;
    QPushButton* popStashButton_ = nullptr;
    QPushButton* dropStashButton_ = nullptr;
    QPushButton* refreshShelfButton_ = nullptr;

    QString selectedChangePath_;
    bool suppressingChangeSignals_ = false;
};

} // namespace lithe::windows
