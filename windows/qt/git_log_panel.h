#pragma once

#include "git_feature.h"
#include "git_graph_layout.h"

#include <QWidget>

#include <string>

class QLabel;
class QLineEdit;
class QListWidget;
class QListWidgetItem;
class QMenu;
class QPlainTextEdit;
class QPushButton;
class QToolButton;
class QTreeWidget;
class QTreeWidgetItem;

namespace lithe::windows {

/// Bottom tool window: branch tree | commit graph | commit details/files.
class GitLogPanel final : public QWidget {
    Q_OBJECT

public:
    explicit GitLogPanel(QWidget* parent = nullptr);

    void applyState(const app::GitFeatureState& state);
    QString selectedCommitHash() const;
    void setSelectedCommitHash(const QString& hash);
    void prepareForHistoryLoad();

signals:
    void refreshRequested();
    void fetchRequested();
    void pushRequested();
    void mergeRequested();
    void rebaseRequested();
    void pullRequested();
    void compareRequested();
    void showAllReferencesRequested();
    void checkoutReferenceRequested(const QString& fullName,
                                    const QString& kind,
                                    const QString& shortName);
    void commitSelected(const QString& hash);
    void commitFileActivated(const QString& relativePath);

private:
    void rebuildReferenceTree(const app::GitFeatureState& state);
    void rebuildHistory(const app::GitFeatureState& state);
    void rebuildDetails(const app::GitFeatureState& state);
    void filterReferenceTree(const QString& query);
    void filterHistory(const QString& query);
    void onReferenceActivated(QTreeWidgetItem* item, int column);
    void onHistoryItemActivated(QListWidgetItem* item);
    void onHistoryItemClicked(QListWidgetItem* item);
    void onCommitFileActivated(QTreeWidgetItem* item, int column);
    void updateBusyState(const app::GitFeatureState& state);

    QLabel* titleLabel_ = nullptr;
    QPushButton* logTargetButton_ = nullptr;
    QToolButton* moreButton_ = nullptr;
    QToolButton* showAllButton_ = nullptr;

    QLineEdit* referenceSearch_ = nullptr;
    QTreeWidget* referenceTree_ = nullptr;

    QLineEdit* historySearch_ = nullptr;
    QLabel* branchFilterLabel_ = nullptr;
    QListWidget* historyList_ = nullptr;

    QLabel* filesHeader_ = nullptr;
    QTreeWidget* commitFilesTree_ = nullptr;
    QLabel* commitSubject_ = nullptr;
    QLabel* commitHashAuthor_ = nullptr;
    QLabel* commitDate_ = nullptr;
    QLabel* commitRefs_ = nullptr;

    QToolButton* refreshButton_ = nullptr;
    QToolButton* fetchButton_ = nullptr;
    QToolButton* pushButton_ = nullptr;
    QToolButton* mergeButton_ = nullptr;
    QToolButton* rebaseButton_ = nullptr;
    QToolButton* pullButton_ = nullptr;
    QToolButton* compareButton_ = nullptr;

    algorithms::GitGraphLayout graphLayout_;
    QString selectedCommitHash_;
    QString logTargetLabel_;
    QString historyFilterQuery_;
    std::vector<GitCommitDto> commitsCache_;
};

} // namespace lithe::windows
