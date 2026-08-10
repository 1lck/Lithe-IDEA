#include "git_log_panel.h"

#include "git_reference_tree.h"
#include "workbench_ui_theme.h"

#include <QAbstractItemView>
#include <QBrush>
#include <QColor>
#include <QFont>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMenu>
#include <QPainter>
#include <QPen>
#include <QPushButton>
#include <QSplitter>
#include <QStyledItemDelegate>
#include <QToolButton>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QVBoxLayout>

#include <array>
#include <algorithm>
#include <cmath>

namespace lithe::windows {
namespace {

constexpr int RelativePathRole = Qt::UserRole;
constexpr int GitCommitHashRole = Qt::UserRole + 7;
constexpr int RefFullNameRole = Qt::UserRole + 20;
constexpr int RefKindRole = Qt::UserRole + 21;
constexpr int RefShortNameRole = Qt::UserRole + 22;
constexpr int CommitIndexRole = Qt::UserRole + 30;

QString fromUtf8(std::string_view value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

class GitHistoryDelegate final : public QStyledItemDelegate {
public:
    GitHistoryDelegate(const algorithms::GitGraphLayout* layout, QObject* parent)
        : QStyledItemDelegate(parent), layout_(layout) {}

    QSize sizeHint(const QStyleOptionViewItem& option,
                   const QModelIndex& index) const override {
        auto size = QStyledItemDelegate::sizeHint(option, index);
        size.setHeight(std::max(size.height(), 40));
        return size;
    }

    void paint(QPainter* painter,
               const QStyleOptionViewItem& option,
               const QModelIndex& index) const override {
        const int commitIndex = index.data(CommitIndexRole).toInt();
        if (layout_ == nullptr || commitIndex < 0 ||
            static_cast<std::size_t>(commitIndex) >= layout_->rows.size()) {
            QStyledItemDelegate::paint(painter, option, index);
            return;
        }

        painter->save();
        if (option.state & QStyle::State_Selected) {
            painter->fillRect(option.rect, ui::Theme::subtleSelection());
        } else if (option.state & QStyle::State_MouseOver) {
            painter->fillRect(option.rect, QColor(255, 255, 255, 8));
        }

        constexpr int LaneSpacing = 16;
        constexpr int GraphPadding = 12;
        const auto& row = layout_->rows[static_cast<std::size_t>(commitIndex)];
        const auto graphWidth = std::max(64,
            GraphPadding * 2 + static_cast<int>(layout_->laneCount) * LaneSpacing);

        const auto colorFor = [](std::size_t colorIndex) {
            static const std::array<QColor, 6> colors{
                QColor(56, 189, 248), QColor(248, 113, 113), QColor(110, 231, 183),
                QColor(196, 181, 253), QColor(251, 191, 36), QColor(103, 232, 249),
            };
            return colors[colorIndex % colors.size()];
        };
        const auto xForLane = [&](std::size_t lane) {
            return option.rect.left() + GraphPadding +
                static_cast<int>(lane) * LaneSpacing;
        };
        const auto top = option.rect.top();
        const auto center = option.rect.center().y();
        const auto bottom = option.rect.bottom();

        painter->setRenderHint(QPainter::Antialiasing, true);
        for (std::size_t lane = 0; lane < row.incomingLaneColors.size(); ++lane) {
            QPen pen(colorFor(row.incomingLaneColors[lane]));
            pen.setWidth(2);
            painter->setPen(pen);
            painter->drawLine(xForLane(lane), top, xForLane(lane), center);
        }

        const auto currentX = xForLane(row.lane);
        for (const auto& edge : row.parentEdges) {
            QPen pen(colorFor(edge.colorIndex));
            pen.setWidth(2);
            if (edge.isMissing) pen.setStyle(Qt::DashLine);
            painter->setPen(pen);
            const auto targetX = edge.targetLane ? xForLane(*edge.targetLane) : currentX;
            painter->drawLine(currentX, center, targetX, bottom);
        }
        painter->setPen(QPen(colorFor(row.incomingLaneColors.empty()
                                          ? row.lane
                                          : row.incomingLaneColors[row.lane %
                                                                   row.incomingLaneColors.size()]),
                              2));
        painter->setBrush(option.state & QStyle::State_Selected
                              ? ui::Theme::accent()
                              : ui::Theme::editor());
        painter->drawEllipse(QPointF(currentX, center), 5.0, 5.0);

        const auto subject = index.data(Qt::DisplayRole).toString();
        const auto author = index.data(Qt::UserRole + 40).toString();
        const auto date = index.data(Qt::UserRole + 41).toString();
        const auto decorations = index.data(Qt::UserRole + 42).toString();

        QFont subjectFont = option.font;
        subjectFont.setPointSize(subjectFont.pointSize());
        painter->setFont(subjectFont);
        painter->setPen(ui::Theme::primaryText());

        const int textLeft = option.rect.left() + graphWidth;
        const int textRight = option.rect.right() - 8;
        int cursorX = textLeft;

        QFontMetrics metrics(subjectFont);
        const QString elidedSubject = metrics.elidedText(
            subject, Qt::ElideRight, std::max(80, textRight - textLeft - 220));
        painter->drawText(QRect(cursorX, option.rect.top() + 6, textRight - cursorX, 18),
                          Qt::AlignLeft | Qt::AlignVCenter, elidedSubject);
        cursorX += metrics.horizontalAdvance(elidedSubject) + 10;

        if (!decorations.isEmpty()) {
            const auto labels = decorations.split(QLatin1Char(','), Qt::SkipEmptyParts);
            for (const auto& raw : labels) {
                const auto label = raw.trimmed();
                if (label.isEmpty()) continue;
                const auto pill = metrics.boundingRect(label).adjusted(-8, -2, 8, 2);
                QRect badge(cursorX, option.rect.top() + 8, pill.width(), 18);
                if (badge.right() > textRight - 140) break;
                QColor badgeColor = ui::Theme::accent();
                if (label.startsWith(QStringLiteral("origin/"))) {
                    badgeColor = QColor(56, 189, 248);
                } else if (label.startsWith(QStringLiteral("tag:"))) {
                    badgeColor = ui::Theme::warning();
                } else if (label.contains(QStringLiteral("HEAD"))) {
                    badgeColor = ui::Theme::success();
                } else {
                    badgeColor = QColor(110, 231, 183);
                }
                painter->setBrush(badgeColor.darker(170));
                painter->setPen(Qt::NoPen);
                painter->drawRoundedRect(badge, 999, 999);
                painter->setPen(badgeColor.lighter(130));
                QFont badgeFont = option.font;
                badgeFont.setPointSize(std::max(9, badgeFont.pointSize() - 1));
                painter->setFont(badgeFont);
                painter->drawText(badge, Qt::AlignCenter, label);
                cursorX = badge.right() + 8;
            }
        }

        QFont metaFont = option.font;
        metaFont.setPointSize(std::max(9, metaFont.pointSize() - 1));
        painter->setFont(metaFont);
        painter->setPen(ui::Theme::secondaryText());
        const QString meta = QStringLiteral("%1    %2").arg(author, date);
        painter->drawText(QRect(textRight - 210, option.rect.top() + 6, 202, 18),
                          Qt::AlignRight | Qt::AlignVCenter, meta);
        painter->restore();
    }

private:
    const algorithms::GitGraphLayout* layout_ = nullptr;
};

void addTreeChildren(QTreeWidgetItem* parent,
                     const std::vector<algorithms::GitReferenceTreeNode>& nodes) {
    for (const auto& node : nodes) {
        auto* item = new QTreeWidgetItem(parent);
        item->setText(0, fromUtf8(node.name));
        if (node.reference) {
            item->setData(0, RefFullNameRole, fromUtf8(node.reference->fullName));
            item->setData(0, RefKindRole, fromUtf8(node.reference->kind));
            item->setData(0, RefShortNameRole, fromUtf8(node.reference->shortName));
            if (node.reference->isCurrent) {
                auto font = item->font(0);
                font.setBold(true);
                item->setFont(0, font);
            }
        }
        if (!node.children.empty()) {
            addTreeChildren(item, node.children);
            item->setExpanded(true);
        }
    }
}

void applyVisibility(QTreeWidgetItem* item, const QString& query) {
    bool anyChildVisible = false;
    for (int i = 0; i < item->childCount(); ++i) {
        applyVisibility(item->child(i), query);
        if (!item->child(i)->isHidden()) anyChildVisible = true;
    }
    const bool selfMatch = query.isEmpty() ||
        item->text(0).contains(query, Qt::CaseInsensitive) ||
        item->data(0, RefFullNameRole).toString().contains(query, Qt::CaseInsensitive);
    item->setHidden(!(selfMatch || anyChildVisible));
}

QColor statusColor(const QString& status) {
    if (status.startsWith(QLatin1Char('A'))) return ui::Theme::success();
    if (status.startsWith(QLatin1Char('D'))) return ui::Theme::error();
    if (status.startsWith(QLatin1Char('M')) || status.startsWith(QLatin1Char('R'))) {
        return ui::Theme::warning();
    }
    return ui::Theme::secondaryText();
}

void appendPathSegments(QTreeWidget* tree,
                        const QString& path,
                        const QString& status,
                        const QString& rootName) {
    const auto parts = path.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    if (parts.isEmpty()) return;

    QTreeWidgetItem* parent = nullptr;
    for (int i = 0; i < tree->topLevelItemCount(); ++i) {
        if (tree->topLevelItem(i)->text(0) == rootName) {
            parent = tree->topLevelItem(i);
            break;
        }
    }
    if (parent == nullptr) {
        parent = new QTreeWidgetItem(tree);
        parent->setText(0, rootName);
        parent->setFlags(Qt::ItemIsEnabled);
        parent->setExpanded(true);
        parent->setForeground(0, QBrush(ui::Theme::primaryText()));
    }

    for (int i = 0; i + 1 < parts.size(); ++i) {
        QTreeWidgetItem* child = nullptr;
        for (int c = 0; c < parent->childCount(); ++c) {
            if (parent->child(c)->text(0) == parts[i] &&
                parent->child(c)->data(0, RelativePathRole).toString().isEmpty()) {
                child = parent->child(c);
                break;
            }
        }
        if (child == nullptr) {
            child = new QTreeWidgetItem(parent);
            child->setText(0, parts[i]);
            child->setFlags(Qt::ItemIsEnabled);
            child->setExpanded(true);
            child->setForeground(0, QBrush(ui::Theme::primaryText()));
        }
        parent = child;
    }

    auto* fileItem = new QTreeWidgetItem(parent);
    const QString statusMark = status.left(1).isEmpty() ? QStringLiteral("M") : status.left(1);
    fileItem->setText(0, QStringLiteral("%1  %2").arg(statusMark, parts.last()));
    fileItem->setData(0, RelativePathRole, path);
    fileItem->setForeground(0, QBrush(statusColor(status)));
    fileItem->setToolTip(0, path);
    // Colored status glyph for IDEA-like file tree.
    fileItem->setData(0, Qt::DecorationRole, QVariant());
}

} // namespace

GitLogPanel::GitLogPanel(QWidget* parent) : QWidget(parent) {
    setObjectName(QStringLiteral("GitLogPanel"));
    setStyleSheet(ui::gitPanelStyleSheet());

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* toolbar = new QWidget(this);
    toolbar->setProperty("gitToolHeader", true);
    ui::applyToolHeaderBackground(toolbar);
    auto* toolbarLayout = new QHBoxLayout(toolbar);
    toolbarLayout->setContentsMargins(12, 8, 10, 8);
    toolbarLayout->setSpacing(8);

    titleLabel_ = new QLabel(QStringLiteral("Git"), toolbar);
    titleLabel_->setProperty("gitTitle", true);
    toolbarLayout->addWidget(titleLabel_);

    logTargetButton_ = new QPushButton(QStringLiteral("Log"), toolbar);
    logTargetButton_->setProperty("secondaryAction", true);
    logTargetButton_->setCursor(Qt::PointingHandCursor);
    toolbarLayout->addWidget(logTargetButton_);

    showAllButton_ = ui::makeIconButton(toolbar, QStringLiteral("Show all references"),
                                        QStringLiteral("+"));
    moreButton_ = ui::makeIconButton(toolbar, QStringLiteral("Git tool window actions"),
                                     QStringLiteral("⋯"));
    toolbarLayout->addWidget(showAllButton_);
    toolbarLayout->addWidget(moreButton_);
    toolbarLayout->addStretch(1);

    refreshButton_ = ui::makeIconButton(toolbar, QStringLiteral("Refresh Git log"),
                                        QStringLiteral("↻"));
    fetchButton_ = ui::makeIconButton(toolbar, QStringLiteral("Fetch"), QStringLiteral("⬇"));
    pushButton_ = ui::makeIconButton(toolbar, QStringLiteral("Push"), QStringLiteral("⬆"));
    mergeButton_ = ui::makeIconButton(toolbar, QStringLiteral("Merge…"), QStringLiteral("⑂"));
    rebaseButton_ = ui::makeIconButton(toolbar, QStringLiteral("Rebase…"), QStringLiteral("⤴"));
    pullButton_ = ui::makeIconButton(toolbar, QStringLiteral("Pull"), QStringLiteral("⇓"));
    compareButton_ = ui::makeIconButton(toolbar, QStringLiteral("Compare…"),
                                        QStringLiteral("⇄"));
    toolbarLayout->addWidget(refreshButton_);
    toolbarLayout->addWidget(fetchButton_);
    toolbarLayout->addWidget(pushButton_);
    toolbarLayout->addWidget(mergeButton_);
    toolbarLayout->addWidget(rebaseButton_);
    toolbarLayout->addWidget(pullButton_);
    toolbarLayout->addWidget(compareButton_);
    root->addWidget(toolbar);
    root->addWidget(ui::makeDivider(this));

    auto* moreMenu = new QMenu(moreButton_);
    moreMenu->addAction(QStringLiteral("Fetch All Remotes"), this, &GitLogPanel::fetchRequested);
    moreMenu->addAction(QStringLiteral("Update Current Branch"), this, &GitLogPanel::pullRequested);
    moreMenu->addAction(QStringLiteral("Refresh Log"), this, &GitLogPanel::refreshRequested);
    moreMenu->addSeparator();
    moreMenu->addAction(QStringLiteral("Merge…"), this, &GitLogPanel::mergeRequested);
    moreMenu->addAction(QStringLiteral("Rebase…"), this, &GitLogPanel::rebaseRequested);
    moreMenu->addAction(QStringLiteral("Compare…"), this, &GitLogPanel::compareRequested);
    moreButton_->setMenu(moreMenu);
    moreButton_->setPopupMode(QToolButton::InstantPopup);

    auto* splitter = new QSplitter(Qt::Horizontal, this);
    splitter->setHandleWidth(1);

    auto* left = new QWidget(splitter);
    auto* leftLayout = new QVBoxLayout(left);
    leftLayout->setContentsMargins(0, 0, 0, 0);
    leftLayout->setSpacing(0);

    auto* leftToolbar = new QWidget(left);
    leftToolbar->setProperty("gitToolHeader", true);
    ui::applyToolHeaderBackground(leftToolbar);
    auto* leftToolbarLayout = new QHBoxLayout(leftToolbar);
    leftToolbarLayout->setContentsMargins(10, 8, 10, 8);
    referenceSearch_ = new QLineEdit(leftToolbar);
    referenceSearch_->setPlaceholderText(QStringLiteral("Filter branches"));
    referenceSearch_->setClearButtonEnabled(true);
    leftToolbarLayout->addWidget(referenceSearch_);
    leftLayout->addWidget(leftToolbar);
    leftLayout->addWidget(ui::makeDivider(left));

    referenceTree_ = new QTreeWidget(left);
    referenceTree_->setHeaderHidden(true);
    referenceTree_->setUniformRowHeights(true);
    referenceTree_->setIndentation(18);
    leftLayout->addWidget(referenceTree_, 1);
    splitter->addWidget(left);

    auto* center = new QWidget(splitter);
    auto* centerLayout = new QVBoxLayout(center);
    centerLayout->setContentsMargins(0, 0, 0, 0);
    centerLayout->setSpacing(0);

    auto* historyToolbar = new QWidget(center);
    historyToolbar->setProperty("gitToolHeader", true);
    ui::applyToolHeaderBackground(historyToolbar);
    auto* historyToolbarLayout = new QHBoxLayout(historyToolbar);
    historyToolbarLayout->setContentsMargins(12, 8, 12, 8);
    historyToolbarLayout->setSpacing(10);
    historySearch_ = new QLineEdit(historyToolbar);
    historySearch_->setPlaceholderText(QStringLiteral("Text or hash"));
    historySearch_->setClearButtonEnabled(true);
    historySearch_->setFixedWidth(240);
    historyToolbarLayout->addWidget(historySearch_);
    branchFilterLabel_ = new QLabel(QStringLiteral("Branch: All"), historyToolbar);
    branchFilterLabel_->setProperty("gitMeta", true);
    historyToolbarLayout->addWidget(branchFilterLabel_);
    historyToolbarLayout->addStretch(1);
    centerLayout->addWidget(historyToolbar);
    centerLayout->addWidget(ui::makeDivider(center));

    historyList_ = new QListWidget(center);
    historyList_->setUniformItemSizes(true);
    historyList_->setItemDelegate(new GitHistoryDelegate(&graphLayout_, historyList_));
    historyList_->setMouseTracking(true);
    centerLayout->addWidget(historyList_, 1);
    splitter->addWidget(center);

    auto* right = new QWidget(splitter);
    auto* rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(0, 0, 0, 0);
    rightLayout->setSpacing(0);

    auto* filesToolbar = new QWidget(right);
    filesToolbar->setProperty("gitToolHeader", true);
    ui::applyToolHeaderBackground(filesToolbar);
    auto* filesToolbarLayout = new QHBoxLayout(filesToolbar);
    filesToolbarLayout->setContentsMargins(12, 8, 12, 8);
    filesHeader_ = new QLabel(QStringLiteral("0 file(s)"), filesToolbar);
    filesHeader_->setProperty("gitMeta", true);
    filesToolbarLayout->addWidget(filesHeader_);
    filesToolbarLayout->addStretch(1);
    rightLayout->addWidget(filesToolbar);
    rightLayout->addWidget(ui::makeDivider(right));

    auto* rightSplitter = new QSplitter(Qt::Vertical, right);
    rightSplitter->setHandleWidth(1);
    commitFilesTree_ = new QTreeWidget(rightSplitter);
    commitFilesTree_->setHeaderHidden(true);
    commitFilesTree_->setUniformRowHeights(true);
    commitFilesTree_->setIndentation(14);
    rightSplitter->addWidget(commitFilesTree_);

    auto* metaPane = new QWidget(rightSplitter);
    auto* metaLayout = new QVBoxLayout(metaPane);
    metaLayout->setContentsMargins(14, 14, 14, 14);
    metaLayout->setSpacing(10);
    commitSubject_ = new QLabel(metaPane);
    commitSubject_->setWordWrap(true);
    commitSubject_->setProperty("gitTitle", true);
    commitHashAuthor_ = new QLabel(metaPane);
    commitHashAuthor_->setProperty("gitMeta", true);
    commitHashAuthor_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    commitDate_ = new QLabel(metaPane);
    commitDate_->setProperty("gitMeta", true);
    commitRefs_ = new QLabel(metaPane);
    commitRefs_->setWordWrap(true);
    commitRefs_->setStyleSheet(
        QStringLiteral("color: %1; font-size: 12px;").arg(ui::Theme::rgba(ui::Theme::accent())));
    metaLayout->addWidget(commitSubject_);
    metaLayout->addWidget(commitHashAuthor_);
    metaLayout->addWidget(commitDate_);
    metaLayout->addWidget(commitRefs_);
    metaLayout->addStretch(1);
    rightSplitter->addWidget(metaPane);
    rightSplitter->setStretchFactor(0, 3);
    rightSplitter->setStretchFactor(1, 1);
    rightLayout->addWidget(rightSplitter, 1);
    splitter->addWidget(right);

    splitter->setStretchFactor(0, 2);
    splitter->setStretchFactor(1, 5);
    splitter->setStretchFactor(2, 3);
    splitter->setSizes({240, 560, 320});
    root->addWidget(splitter, 1);

    connect(refreshButton_, &QToolButton::clicked, this, &GitLogPanel::refreshRequested);
    connect(fetchButton_, &QToolButton::clicked, this, &GitLogPanel::fetchRequested);
    connect(pushButton_, &QToolButton::clicked, this, &GitLogPanel::pushRequested);
    connect(mergeButton_, &QToolButton::clicked, this, &GitLogPanel::mergeRequested);
    connect(rebaseButton_, &QToolButton::clicked, this, &GitLogPanel::rebaseRequested);
    connect(pullButton_, &QToolButton::clicked, this, &GitLogPanel::pullRequested);
    connect(compareButton_, &QToolButton::clicked, this, &GitLogPanel::compareRequested);
    connect(showAllButton_, &QToolButton::clicked, this, &GitLogPanel::showAllReferencesRequested);
    connect(logTargetButton_, &QPushButton::clicked, this, &GitLogPanel::showAllReferencesRequested);
    connect(referenceSearch_, &QLineEdit::textChanged, this, &GitLogPanel::filterReferenceTree);
    connect(historySearch_, &QLineEdit::textChanged, this, &GitLogPanel::filterHistory);
    connect(referenceTree_, &QTreeWidget::itemDoubleClicked,
            this, &GitLogPanel::onReferenceActivated);
    connect(historyList_, &QListWidget::itemClicked, this, &GitLogPanel::onHistoryItemClicked);
    connect(historyList_, &QListWidget::itemDoubleClicked,
            this, &GitLogPanel::onHistoryItemActivated);
    connect(commitFilesTree_, &QTreeWidget::itemDoubleClicked,
            this, &GitLogPanel::onCommitFileActivated);
}

QString GitLogPanel::selectedCommitHash() const {
    return selectedCommitHash_;
}

void GitLogPanel::setSelectedCommitHash(const QString& hash) {
    selectedCommitHash_ = hash;
}

void GitLogPanel::prepareForHistoryLoad() {
    selectedCommitHash_.clear();
    historyList_->clear();
    commitFilesTree_->clear();
    commitSubject_->clear();
    commitHashAuthor_->clear();
    commitDate_->clear();
    commitRefs_->clear();
    filesHeader_->setText(QStringLiteral("0 files"));
    commitsCache_.clear();
}

void GitLogPanel::applyState(const app::GitFeatureState& state) {
    if (state.history && !state.isLoadingHistory) {
        rebuildReferenceTree(state);
        rebuildHistory(state);
        if (state.status && state.status->branch) {
            logTargetLabel_ = fromUtf8(*state.status->branch);
            logTargetButton_->setText(QStringLiteral("Log: %1").arg(logTargetLabel_));
            branchFilterLabel_->setText(QStringLiteral("Branch: %1").arg(logTargetLabel_));
        } else {
            logTargetButton_->setText(QStringLiteral("Log"));
            branchFilterLabel_->setText(QStringLiteral("Branch: All"));
        }
    }
    rebuildDetails(state);
    updateBusyState(state);
}

void GitLogPanel::updateBusyState(const app::GitFeatureState& state) {
    const bool busy = state.isWriting || state.isPerformingBranchOperation ||
        state.isResolvingGitOperation;
    for (auto* button : {refreshButton_, fetchButton_, pushButton_, mergeButton_,
                         rebaseButton_, pullButton_, compareButton_}) {
        if (button != nullptr) button->setEnabled(!busy);
    }
}

void GitLogPanel::rebuildReferenceTree(const app::GitFeatureState& state) {
    referenceTree_->clear();
    std::vector<algorithms::GitReferenceInfo> infos;
    infos.reserve(state.history->references.size());
    for (const auto& reference : state.history->references) {
        infos.push_back({reference.fullName, reference.shortName, reference.kind,
                         reference.isCurrent, reference.upstreamShortName});
    }

    std::vector<algorithms::GitReferenceInfo> local;
    std::vector<algorithms::GitReferenceInfo> remote;
    std::vector<algorithms::GitReferenceInfo> tags;
    std::optional<algorithms::GitReferenceInfo> head;
    for (const auto& info : infos) {
        if (info.kind == "local") {
            if (info.isCurrent) head = info;
            local.push_back(info);
        } else if (info.kind == "remote") {
            remote.push_back(info);
        } else if (info.kind == "tag") {
            tags.push_back(info);
        }
    }

    if (head) {
        auto* headRoot = new QTreeWidgetItem(referenceTree_);
        headRoot->setText(0, QStringLiteral("HEAD (current branch)"));
        headRoot->setFlags(Qt::ItemIsEnabled);
        auto* current = new QTreeWidgetItem(headRoot);
        current->setText(0, fromUtf8(head->shortName));
        current->setData(0, RefFullNameRole, fromUtf8(head->fullName));
        current->setData(0, RefKindRole, fromUtf8(head->kind));
        current->setData(0, RefShortNameRole, fromUtf8(head->shortName));
        auto font = current->font(0);
        font.setBold(true);
        current->setFont(0, font);
        headRoot->setExpanded(true);
    }

    auto addGroup = [&](const QString& title,
                        const std::vector<algorithms::GitReferenceInfo>& group) {
        if (group.empty()) return;
        auto* root = new QTreeWidgetItem(referenceTree_);
        root->setText(0, title);
        root->setFlags(Qt::ItemIsEnabled);
        addTreeChildren(root, algorithms::buildGitReferenceTree(group));
        root->setExpanded(true);
    };

    addGroup(QStringLiteral("Local"), local);
    addGroup(QStringLiteral("Remote"), remote);
    addGroup(QStringLiteral("Tags"), tags);
    filterReferenceTree(referenceSearch_->text());
}

void GitLogPanel::rebuildHistory(const app::GitFeatureState& state) {
    commitsCache_ = state.history->commits;
    std::vector<algorithms::GitGraphCommit> graphCommits;
    graphCommits.reserve(commitsCache_.size());
    for (const auto& commit : commitsCache_) {
        graphCommits.push_back(
            {commit.hash, commit.parentHashes, commit.decorations, commit.subject});
    }
    graphLayout_ = algorithms::layoutGitGraph(graphCommits);
    filterHistory(historyFilterQuery_);
}

void GitLogPanel::filterHistory(const QString& query) {
    historyFilterQuery_ = query.trimmed();
    historyList_->clear();
    for (std::size_t i = 0; i < commitsCache_.size(); ++i) {
        const auto& commit = commitsCache_[i];
        if (!historyFilterQuery_.isEmpty()) {
            const auto haystack = QStringLiteral("%1 %2 %3 %4 %5")
                .arg(fromUtf8(commit.subject),
                     fromUtf8(commit.hash),
                     fromUtf8(commit.shortHash),
                     fromUtf8(commit.authorName),
                     fromUtf8(commit.decorations));
            if (!haystack.contains(historyFilterQuery_, Qt::CaseInsensitive)) continue;
        }
        auto* item = new QListWidgetItem(fromUtf8(commit.subject), historyList_);
        item->setData(GitCommitHashRole, fromUtf8(commit.hash));
        item->setData(CommitIndexRole, static_cast<int>(i));
        item->setData(Qt::UserRole + 40, fromUtf8(commit.authorName));
        item->setData(Qt::UserRole + 41, fromUtf8(commit.date));
        item->setData(Qt::UserRole + 42, fromUtf8(commit.decorations));
        if (!commit.decorations.empty()) {
            item->setToolTip(fromUtf8(commit.decorations));
        }
        if (commit.hash == selectedCommitHash_.toStdString()) item->setSelected(true);
    }
    historyList_->viewport()->update();
}

void GitLogPanel::rebuildDetails(const app::GitFeatureState& state) {
    if (state.commit && !state.isLoadingCommit) {
        const auto& commit = state.commit->commit;
        commitSubject_->setText(fromUtf8(commit.subject));
        commitHashAuthor_->setText(
            QStringLiteral("%1  %2 <%3>")
                .arg(fromUtf8(commit.shortHash),
                     fromUtf8(commit.authorName),
                     fromUtf8(commit.authorEmail)));
        commitDate_->setText(fromUtf8(commit.date));
        commitRefs_->setText(commit.decorations.empty()
                                 ? QString()
                                 : fromUtf8(commit.decorations));
        commitRefs_->setVisible(!commit.decorations.empty());
    }

    if (state.commitFiles && !state.isLoadingCommitFiles) {
        commitFilesTree_->clear();
        filesHeader_->setText(
            QStringLiteral("%1 file(s)")
                .arg(static_cast<qulonglong>(state.commitFiles->files.size())));

        const QString rootName = QStringLiteral("Workspace");
        for (const auto& file : state.commitFiles->files) {
            appendPathSegments(commitFilesTree_, fromUtf8(file.path),
                               fromUtf8(file.status), rootName);
        }
    }
}

void GitLogPanel::filterReferenceTree(const QString& query) {
    for (int i = 0; i < referenceTree_->topLevelItemCount(); ++i) {
        applyVisibility(referenceTree_->topLevelItem(i), query.trimmed());
    }
}

void GitLogPanel::onReferenceActivated(QTreeWidgetItem* item, int) {
    if (item == nullptr) return;
    const auto fullName = item->data(0, RefFullNameRole).toString();
    if (fullName.isEmpty()) return;
    emit checkoutReferenceRequested(
        fullName,
        item->data(0, RefKindRole).toString(),
        item->data(0, RefShortNameRole).toString());
}

void GitLogPanel::onHistoryItemClicked(QListWidgetItem* item) {
    if (item == nullptr) return;
    const auto hash = item->data(GitCommitHashRole).toString();
    if (hash.isEmpty()) return;
    selectedCommitHash_ = hash;
    emit commitSelected(hash);
}

void GitLogPanel::onHistoryItemActivated(QListWidgetItem* item) {
    onHistoryItemClicked(item);
}

void GitLogPanel::onCommitFileActivated(QTreeWidgetItem* item, int) {
    if (item == nullptr) return;
    const auto path = item->data(0, RelativePathRole).toString();
    if (path.isEmpty()) return;
    emit commitFileActivated(path);
}

} // namespace lithe::windows
