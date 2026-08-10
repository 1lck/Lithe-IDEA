#pragma once

#include "diff_collapse.h"
#include "diff_split_layout.h"
#include "diff_types.h"

#include <QWidget>

#include <optional>
#include <string>
#include <unordered_set>
#include <vector>

class QLabel;
class QPushButton;
class QScrollArea;
class QToolButton;

namespace lithe::windows {

/// IDEA-style diff review: tab chrome, commit bar, version headers, dual panes.
class DiffSplitWidget final : public QWidget {
    Q_OBJECT

public:
    explicit DiffSplitWidget(QWidget* parent = nullptr);

    void clear();
    void setDiff(const std::vector<algorithms::DiffRow>& rows,
                 const std::unordered_set<std::string>& expandedRegionIDs);
    void setFileChrome(const QString& fileName,
                       const QString& statusBadge,
                       const QString& modeBadge);
    void setCommitContext(const QString& shortHash, const QString& subject);
    void setVersionTitles(const QString& leftTitle,
                          const QString& leftPath,
                          const QString& rightTitle,
                          const QString& rightPath);
    void setHunkActionsVisible(bool visible);
    void setSelectedHunkId(const QString& hunkId);
    QString selectedHunkId() const;
    void scrollToHunk(const QString& hunkId);
    void navigateDifference(int delta);

signals:
    void hunkSelected(const QString& hunkId);
    void expandRegionRequested(const QString& regionId);
    void closeRequested();
    void stageHunkRequested();
    void unstageHunkRequested();
    void discardHunkRequested();

protected:
    void resizeEvent(QResizeEvent* event) override;

private:
    class Canvas;

    void rebuildLayout();
    void syncScrollExtents();
    void notifyHunkSelected(const QString& hunkId);
    void notifyExpandRegion(const QString& regionId);
    void collectDifferenceHunks();
    void updateNavigateButtons();

    QWidget* tabChrome_ = nullptr;
    QLabel* fileNameLabel_ = nullptr;
    QLabel* statusBadgeLabel_ = nullptr;
    QLabel* modeBadgeLabel_ = nullptr;
    QToolButton* closeButton_ = nullptr;

    QWidget* commitBar_ = nullptr;
    QLabel* commitHashLabel_ = nullptr;
    QLabel* commitSubjectLabel_ = nullptr;

    QWidget* toolbar_ = nullptr;
    QToolButton* prevDiffButton_ = nullptr;
    QToolButton* nextDiffButton_ = nullptr;
    QPushButton* stageHunkButton_ = nullptr;
    QPushButton* unstageHunkButton_ = nullptr;
    QPushButton* discardHunkButton_ = nullptr;

    QWidget* versionHeader_ = nullptr;
    QLabel* leftVersionTitle_ = nullptr;
    QLabel* leftVersionPath_ = nullptr;
    QLabel* rightVersionTitle_ = nullptr;
    QLabel* rightVersionPath_ = nullptr;
    QScrollArea* scroll_ = nullptr;
    Canvas* canvas_ = nullptr;

    std::vector<algorithms::DiffDisplayRow> displayRows_;
    std::vector<algorithms::DiffRowKind> kinds_;
    algorithms::DiffSplitLayout layout_;
    QString selectedHunkId_;
    QStringList differenceHunkIds_;
    int differenceIndex_ = -1;
};

} // namespace lithe::windows
