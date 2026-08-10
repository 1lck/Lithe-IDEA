#include "git_changes_panel.h"

#include "workbench_ui_theme.h"

#include <QBrush>
#include <QCheckBox>
#include <QColor>
#include <QFont>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QStackedWidget>
#include <QToolButton>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QVBoxLayout>

#include <algorithm>
#include <unordered_set>
#include <string_view>

namespace lithe::windows {
namespace {

constexpr int RelativePathRole = Qt::UserRole;
constexpr int ChangeStagedRole = Qt::UserRole + 1;
constexpr int ShelfIdRole = Qt::UserRole + 2;
constexpr int StashReferenceRole = Qt::UserRole + 3;

QString fromUtf8(std::string_view value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

bool isUnmergedStatus(const std::string& status) {
    return status == "U" || status == "AA" || status == "DD" || status == "AU" ||
        status == "UA" || status == "DU" || status == "UD";
}

QColor statusColor(const std::string& status) {
    if (isUnmergedStatus(status)) return ui::Theme::error();
    if (status == "A" || status.starts_with('A')) return ui::Theme::success();
    if (status == "D" || status.starts_with('D')) return ui::Theme::error();
    if (status == "M" || status.starts_with('M') || status.starts_with('R')) {
        return ui::Theme::warning();
    }
    return ui::Theme::secondaryText();
}

QString fileNameOf(const QString& path) {
    const auto slash = path.lastIndexOf(QLatin1Char('/'));
    return slash >= 0 ? path.mid(slash + 1) : path;
}

QString parentPathOf(const QString& path) {
    const auto slash = path.lastIndexOf(QLatin1Char('/'));
    return slash >= 0 ? path.left(slash) : QString();
}

} // namespace

GitChangesPanel::GitChangesPanel(QWidget* parent) : QWidget(parent) {
    setObjectName(QStringLiteral("GitChangesPanel"));
    setStyleSheet(ui::gitPanelStyleSheet());

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* tabHeader = new QWidget(this);
    tabHeader->setProperty("gitToolHeader", true);
    ui::applyToolHeaderBackground(tabHeader);
    auto* tabLayout = new QHBoxLayout(tabHeader);
    tabLayout->setContentsMargins(10, 8, 10, 8);
    tabLayout->setSpacing(6);
    commitTabButton_ = ui::makeTabButton(tabHeader, QStringLiteral("Commit"));
    shelfTabButton_ = ui::makeTabButton(tabHeader, QStringLiteral("Shelf"));
    commitTabButton_->setProperty("tabButton", true);
    shelfTabButton_->setProperty("tabButton", true);
    commitTabButton_->setChecked(true);
    tabLayout->addWidget(commitTabButton_);
    tabLayout->addWidget(shelfTabButton_);
    tabLayout->addStretch(1);
    root->addWidget(tabHeader);
    root->addWidget(ui::makeDivider(this));

    pages_ = new QStackedWidget(this);
    root->addWidget(pages_, 1);

    commitPage_ = new QWidget(pages_);
    auto* commitLayout = new QVBoxLayout(commitPage_);
    commitLayout->setContentsMargins(0, 0, 0, 0);
    commitLayout->setSpacing(0);

    operationBar_ = new QWidget(commitPage_);
    auto* operationLayout = new QHBoxLayout(operationBar_);
    operationLayout->setContentsMargins(10, 8, 10, 8);
    operationLayout->setSpacing(8);
    operationTitle_ = new QLabel(operationBar_);
    operationProgress_ = new QLabel(operationBar_);
    operationProgress_->setProperty("gitMeta", true);
    continueButton_ = new QPushButton(QStringLiteral("Continue"), operationBar_);
    abortButton_ = new QPushButton(QStringLiteral("Abort"), operationBar_);
    skipButton_ = new QPushButton(QStringLiteral("Skip"), operationBar_);
    filterConflictsButton_ = new QPushButton(QStringLiteral("Filter Conflicts"), operationBar_);
    clearConflictFilterButton_ = new QPushButton(QStringLiteral("Clear Filter"), operationBar_);
    for (auto* button : {continueButton_, abortButton_, skipButton_,
                         filterConflictsButton_, clearConflictFilterButton_}) {
        button->setProperty("secondaryAction", true);
    }
    operationLayout->addWidget(operationTitle_);
    operationLayout->addWidget(operationProgress_);
    operationLayout->addStretch(1);
    operationLayout->addWidget(continueButton_);
    operationLayout->addWidget(abortButton_);
    operationLayout->addWidget(skipButton_);
    operationLayout->addWidget(filterConflictsButton_);
    operationLayout->addWidget(clearConflictFilterButton_);
    operationBar_->setVisible(false);
    commitLayout->addWidget(operationBar_);
    operationDivider_ = ui::makeDivider(commitPage_);
    operationDivider_->setVisible(false);
    commitLayout->addWidget(operationDivider_);

    stashRestoreNotice_ = new QWidget(commitPage_);
    auto* stashRestoreLayout = new QHBoxLayout(stashRestoreNotice_);
    stashRestoreLayout->setContentsMargins(10, 8, 10, 8);
    stashRestoreLabel_ = new QLabel(stashRestoreNotice_);
    stashRestoreLabel_->setWordWrap(true);
    stashRestoreFilterButton_ = new QPushButton(QStringLiteral("Filter Conflict Files"),
                                                stashRestoreNotice_);
    stashRestoreDismissButton_ = new QPushButton(QStringLiteral("Dismiss"), stashRestoreNotice_);
    stashRestoreFilterButton_->setProperty("secondaryAction", true);
    stashRestoreDismissButton_->setProperty("secondaryAction", true);
    stashRestoreLayout->addWidget(stashRestoreLabel_, 1);
    stashRestoreLayout->addWidget(stashRestoreFilterButton_);
    stashRestoreLayout->addWidget(stashRestoreDismissButton_);
    stashRestoreNotice_->setVisible(false);
    commitLayout->addWidget(stashRestoreNotice_);

    auto* toolbar = new QWidget(commitPage_);
    toolbar->setProperty("gitToolHeader", true);
    ui::applyToolHeaderBackground(toolbar);
    auto* toolbarLayout = new QHBoxLayout(toolbar);
    toolbarLayout->setContentsMargins(10, 8, 10, 8);
    toolbarLayout->setSpacing(4);
    refreshButton_ = ui::makeIconButton(toolbar, QStringLiteral("Refresh changes"),
                                        QStringLiteral("↻"));
    discardButton_ = ui::makeIconButton(toolbar, QStringLiteral("Discard selected change"),
                                        QStringLiteral("↩"));
    stageAllToolbarButton_ = ui::makeIconButton(toolbar, QStringLiteral("Stage all changes"),
                                                QStringLiteral("⬇"));
    previewButton_ = ui::makeIconButton(toolbar, QStringLiteral("Preview first change"),
                                        QStringLiteral("👁"));
    toolbarLayout->addWidget(refreshButton_);
    toolbarLayout->addWidget(discardButton_);
    toolbarLayout->addWidget(stageAllToolbarButton_);
    toolbarLayout->addWidget(previewButton_);
    toolbarLayout->addStretch(1);
    branchLabel_ = new QLabel(toolbar);
    branchLabel_->setProperty("gitMeta", true);
    branchLabel_->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    toolbarLayout->addWidget(branchLabel_);
    commitLayout->addWidget(toolbar);
    commitLayout->addWidget(ui::makeDivider(commitPage_));

    cleanState_ = new QWidget(commitPage_);
    auto* cleanLayout = new QVBoxLayout(cleanState_);
    cleanLayout->setContentsMargins(12, 24, 12, 24);
    cleanLayout->setAlignment(Qt::AlignCenter);
    auto* check = new QLabel(QStringLiteral("✓"), cleanState_);
    check->setAlignment(Qt::AlignCenter);
    check->setFixedSize(72, 72);
    {
        QFont font = check->font();
        font.setPointSize(28);
        font.setBold(true);
        check->setFont(font);
    }
    check->setStyleSheet(QStringLiteral(
        "QLabel {"
        "  color: white;"
        "  background-color: %1;"
        "  border-radius: 36px;"
        "}").arg(ui::Theme::rgba(ui::Theme::success())));
    cleanLabel_ = new QLabel(QStringLiteral("Working tree is clean"), cleanState_);
    cleanLabel_->setAlignment(Qt::AlignCenter);
    cleanLabel_->setStyleSheet(
        QStringLiteral("color: %1; font-size: 13px;")
            .arg(ui::Theme::rgba(ui::Theme::secondaryText())));
    cleanLayout->addWidget(check, 0, Qt::AlignHCenter);
    cleanLayout->addWidget(cleanLabel_);
    commitLayout->addWidget(cleanState_, 1);

    conflictEmptyLabel_ = new QLabel(
        QStringLiteral("No files match the conflict filter."), commitPage_);
    conflictEmptyLabel_->setAlignment(Qt::AlignCenter);
    conflictEmptyLabel_->setWordWrap(true);
    conflictEmptyLabel_->setVisible(false);
    conflictEmptyLabel_->setStyleSheet(
        QStringLiteral("color: %1;").arg(ui::Theme::rgba(ui::Theme::secondaryText())));
    commitLayout->addWidget(conflictEmptyLabel_);

    changesTree_ = new QTreeWidget(commitPage_);
    changesTree_->setHeaderHidden(true);
    changesTree_->setRootIsDecorated(true);
    changesTree_->setUniformRowHeights(true);
    changesTree_->setIndentation(16);
    changesTree_->setVisible(false);
    commitLayout->addWidget(changesTree_, 1);

    auto* composer = new QWidget(commitPage_);
    composer->setProperty("gitComposer", true);
    ui::applyToolHeaderBackground(composer);
    auto* composerLayout = new QVBoxLayout(composer);
    composerLayout->setContentsMargins(14, 12, 14, 14);
    composerLayout->setSpacing(12);

    auto* composerTop = new QHBoxLayout();
    composerTop->setSpacing(10);
    amendCheck_ = new QCheckBox(QStringLiteral("Amend"), composer);
    aiButton_ = new QPushButton(QStringLiteral("AI"), composer);
    aiButton_->setProperty("secondaryAction", true);
    aiButton_->setFixedWidth(56);
    stagedCountLabel_ = new QLabel(QStringLiteral("0 staged"), composer);
    stagedCountLabel_->setProperty("gitMeta", true);
    composerTop->addWidget(amendCheck_);
    composerTop->addStretch(1);
    composerTop->addWidget(aiButton_);
    composerTop->addWidget(stagedCountLabel_);
    composerLayout->addLayout(composerTop);

    commitEditor_ = new QPlainTextEdit(composer);
    commitEditor_->setPlaceholderText(QStringLiteral("Commit message"));
    commitEditor_->setMinimumHeight(70);
    commitEditor_->setMaximumHeight(140);
    composerLayout->addWidget(commitEditor_);

    auto* composerActions = new QHBoxLayout();
    composerActions->setSpacing(10);
    commitButton_ = new QPushButton(QStringLiteral("Commit"), composer);
    commitAndPushButton_ = new QPushButton(QStringLiteral("Commit and Push…"), composer);
    commitButton_->setProperty("secondaryAction", true);
    commitAndPushButton_->setProperty("secondaryAction", true);
    settingsButton_ = new QPushButton(QStringLiteral("⚙"), composer);
    settingsButton_->setFlat(true);
    settingsButton_->setFixedSize(32, 32);
    settingsButton_->setToolTip(QStringLiteral("Open AI and commit settings"));
    settingsButton_->setCursor(Qt::PointingHandCursor);
    composerActions->addWidget(commitButton_);
    composerActions->addWidget(commitAndPushButton_);
    composerActions->addStretch(1);
    composerActions->addWidget(settingsButton_);
    composerLayout->addLayout(composerActions);
    commitLayout->addWidget(composer);

    pages_->addWidget(commitPage_);

    shelfPage_ = new QWidget(pages_);
    auto* shelfLayout = new QVBoxLayout(shelfPage_);
    shelfLayout->setContentsMargins(10, 10, 10, 10);
    shelfLayout->setSpacing(8);
    auto* shelfHeader = new QHBoxLayout();
    auto* shelvesTitle = new QLabel(QStringLiteral("Lithe Shelves"), shelfPage_);
    shelvesTitle->setProperty("gitMeta", true);
    shelfHeader->addWidget(shelvesTitle);
    shelfHeader->addStretch(1);
    refreshShelfButton_ = new QPushButton(QStringLiteral("Refresh"), shelfPage_);
    refreshShelfButton_->setProperty("secondaryAction", true);
    shelfHeader->addWidget(refreshShelfButton_);
    shelfLayout->addLayout(shelfHeader);

    shelvesList_ = new QListWidget(shelfPage_);
    shelfLayout->addWidget(shelvesList_, 1);
    auto* shelfActions = new QHBoxLayout();
    applyShelfButton_ = new QPushButton(QStringLiteral("Apply"), shelfPage_);
    dropShelfButton_ = new QPushButton(QStringLiteral("Drop"), shelfPage_);
    applyShelfButton_->setProperty("secondaryAction", true);
    dropShelfButton_->setProperty("secondaryAction", true);
    shelfActions->addWidget(applyShelfButton_);
    shelfActions->addWidget(dropShelfButton_);
    shelfActions->addStretch(1);
    shelfLayout->addLayout(shelfActions);

    auto* stashesTitle = new QLabel(QStringLiteral("Git Stashes"), shelfPage_);
    stashesTitle->setProperty("gitMeta", true);
    shelfLayout->addWidget(stashesTitle);
    stashesList_ = new QListWidget(shelfPage_);
    shelfLayout->addWidget(stashesList_, 1);
    auto* stashActions = new QHBoxLayout();
    applyStashButton_ = new QPushButton(QStringLiteral("Apply"), shelfPage_);
    popStashButton_ = new QPushButton(QStringLiteral("Pop"), shelfPage_);
    dropStashButton_ = new QPushButton(QStringLiteral("Drop"), shelfPage_);
    for (auto* button : {applyStashButton_, popStashButton_, dropStashButton_}) {
        button->setProperty("secondaryAction", true);
    }
    stashActions->addWidget(applyStashButton_);
    stashActions->addWidget(popStashButton_);
    stashActions->addWidget(dropStashButton_);
    stashActions->addStretch(1);
    shelfLayout->addLayout(stashActions);
    pages_->addWidget(shelfPage_);

    connect(commitTabButton_, &QPushButton::clicked, this, [this] { selectTab(0); });
    connect(shelfTabButton_, &QPushButton::clicked, this, [this] { selectTab(1); });
    connect(continueButton_, &QPushButton::clicked, this, &GitChangesPanel::continueOperationRequested);
    connect(abortButton_, &QPushButton::clicked, this, &GitChangesPanel::abortOperationRequested);
    connect(skipButton_, &QPushButton::clicked, this, &GitChangesPanel::skipOperationRequested);
    connect(filterConflictsButton_, &QPushButton::clicked,
            this, &GitChangesPanel::filterConflictsRequested);
    connect(clearConflictFilterButton_, &QPushButton::clicked,
            this, &GitChangesPanel::clearConflictFilterRequested);
    connect(stashRestoreFilterButton_, &QPushButton::clicked,
            this, &GitChangesPanel::filterStashRestoreConflictsRequested);
    connect(stashRestoreDismissButton_, &QPushButton::clicked,
            this, &GitChangesPanel::dismissStashRestoreNoticeRequested);
    connect(refreshButton_, &QToolButton::clicked, this, &GitChangesPanel::refreshRequested);
    connect(discardButton_, &QToolButton::clicked, this, [this] {
        if (!selectedChangePath_.isEmpty()) emit discardPathRequested(selectedChangePath_);
    });
    connect(stageAllToolbarButton_, &QToolButton::clicked, this, &GitChangesPanel::stageAllRequested);
    connect(previewButton_, &QToolButton::clicked, this, &GitChangesPanel::previewFirstChangeRequested);
    connect(commitButton_, &QPushButton::clicked, this, &GitChangesPanel::commitRequested);
    connect(commitAndPushButton_, &QPushButton::clicked, this, &GitChangesPanel::commitAndPushRequested);
    connect(aiButton_, &QPushButton::clicked, this, &GitChangesPanel::generateAiMessageRequested);
    connect(settingsButton_, &QPushButton::clicked, this, &GitChangesPanel::settingsRequested);
    connect(changesTree_, &QTreeWidget::itemDoubleClicked, this,
            [this](QTreeWidgetItem* item, int) {
        if (item == nullptr) return;
        const auto path = item->data(0, RelativePathRole).toString();
        if (!path.isEmpty()) emit changeActivated(path);
    });
    connect(changesTree_, &QTreeWidget::itemClicked, this, &GitChangesPanel::onChangeItemClicked);
    connect(changesTree_, &QTreeWidget::itemChanged, this, &GitChangesPanel::onChangeItemChanged);
    connect(applyShelfButton_, &QPushButton::clicked, this, [this] {
        const auto* item = shelvesList_->currentItem();
        if (item == nullptr) return;
        emit applyShelfRequested(item->data(ShelfIdRole).toString());
    });
    connect(dropShelfButton_, &QPushButton::clicked, this, [this] {
        const auto* item = shelvesList_->currentItem();
        if (item == nullptr) return;
        emit dropShelfRequested(item->data(ShelfIdRole).toString());
    });
    connect(applyStashButton_, &QPushButton::clicked, this, [this] {
        const auto* item = stashesList_->currentItem();
        if (item == nullptr) return;
        emit applyStashRequested(item->data(StashReferenceRole).toString());
    });
    connect(popStashButton_, &QPushButton::clicked, this, [this] {
        const auto* item = stashesList_->currentItem();
        if (item == nullptr) return;
        emit popStashRequested(item->data(StashReferenceRole).toString());
    });
    connect(dropStashButton_, &QPushButton::clicked, this, [this] {
        const auto* item = stashesList_->currentItem();
        if (item == nullptr) return;
        emit dropStashRequested(item->data(StashReferenceRole).toString());
    });
    connect(refreshShelfButton_, &QPushButton::clicked, this, [this] {
        emit refreshShelvesRequested();
        emit refreshStashesRequested();
    });
}

void GitChangesPanel::selectTab(int index) {
    if (pages_ != nullptr) pages_->setCurrentIndex(index);
    if (commitTabButton_ != nullptr) commitTabButton_->setChecked(index == 0);
    if (shelfTabButton_ != nullptr) shelfTabButton_->setChecked(index == 1);
    if (index == 1) {
        emit refreshShelvesRequested();
        emit refreshStashesRequested();
    }
}

QString GitChangesPanel::commitMessage() const {
    return commitEditor_ == nullptr ? QString() : commitEditor_->toPlainText();
}

void GitChangesPanel::setCommitMessage(const QString& message) {
    if (commitEditor_ != nullptr) commitEditor_->setPlainText(message);
}

void GitChangesPanel::clearCommitMessage() {
    if (commitEditor_ != nullptr) commitEditor_->clear();
}

bool GitChangesPanel::isAmendChecked() const {
    return amendCheck_ != nullptr && amendCheck_->isChecked();
}

void GitChangesPanel::setAmendChecked(bool checked) {
    if (amendCheck_ != nullptr) amendCheck_->setChecked(checked);
}

void GitChangesPanel::focusCommitMessage() {
    if (commitEditor_ != nullptr) commitEditor_->setFocus();
}

void GitChangesPanel::applyState(const app::GitFeatureState& state) {
    updateOperationBar(state);
    updateStashRestoreNotice(state);
    updateBranchLabel(state);
    if (state.status && !state.isLoadingStatus) {
        rebuildChangesTree(state);
    }
    rebuildShelfList(state);
    if (state.stashes && !state.isLoadingStashes) {
        rebuildStashList(state);
    }
    updateCommitActions(state);
}

void GitChangesPanel::updateBranchLabel(const app::GitFeatureState& state) {
    if (branchLabel_ == nullptr) return;
    if (state.status && state.status->branch) {
        branchLabel_->setText(fromUtf8(*state.status->branch));
    } else {
        branchLabel_->clear();
    }
}

void GitChangesPanel::updateOperationBar(const app::GitFeatureState& state) {
    const auto model = app::makeOperationBarModel(
        state.operationState, state.isResolvingGitOperation,
        !state.conflictFilterPaths.empty());
    operationBar_->setVisible(model.visible);
    if (operationDivider_ != nullptr) operationDivider_->setVisible(model.visible);
    if (!model.visible) return;
    operationTitle_->setText(fromUtf8(model.title));
    operationProgress_->setText(fromUtf8(model.progress));
    operationProgress_->setVisible(!model.progress.empty());
    continueButton_->setEnabled(model.canContinue);
    abortButton_->setEnabled(model.canAbort);
    skipButton_->setVisible(model.canSkip ||
                            (state.operationState && state.operationState->canSkip()));
    skipButton_->setEnabled(model.canSkip);
    filterConflictsButton_->setEnabled(!model.conflictedPaths.empty());
    clearConflictFilterButton_->setEnabled(model.filterActive);
}

void GitChangesPanel::updateStashRestoreNotice(const app::GitFeatureState& state) {
    const auto model = app::makeStashRestoreNoticeModel(
        state.pendingStashRestoreConflict, state.stashRestoreNoticeVisible);
    stashRestoreNotice_->setVisible(model.visible);
    if (!model.visible) return;
    stashRestoreLabel_->setText(
        QStringLiteral("%1 could not restore cleanly (%2 conflicted file(s)).")
            .arg(fromUtf8(model.operationTitle))
            .arg(static_cast<qulonglong>(model.conflictedPaths.size())));
    stashRestoreFilterButton_->setEnabled(!model.conflictedPaths.empty());
}

void GitChangesPanel::rebuildChangesTree(const app::GitFeatureState& state) {
    suppressingChangeSignals_ = true;
    changesTree_->clear();

    const auto visiblePaths = app::filterChangesByConflictPaths(
        state.status->changes, state.conflictFilterPaths);
    std::unordered_set<std::string> allowed(visiblePaths.begin(), visiblePaths.end());

    std::vector<const GitChangeDto*> tracked;
    std::vector<const GitChangeDto*> untracked;
    std::size_t stagedCount = 0;
    for (const auto& change : state.status->changes) {
        if (!allowed.contains(change.path)) continue;
        if (change.staged) ++stagedCount;
        if (change.untracked) untracked.push_back(&change);
        else tracked.push_back(&change);
    }

    const bool filterActive = !state.conflictFilterPaths.empty();
    const bool hasVisible = !tracked.empty() || !untracked.empty();
    const bool hasAnyChanges = !state.status->changes.empty();

    cleanState_->setVisible(!hasAnyChanges);
    conflictEmptyLabel_->setVisible(app::shouldShowConflictFilterEmptyState(
        filterActive, state.status->changes.size(), tracked.size() + untracked.size()));
    changesTree_->setVisible(hasVisible);

    auto addSection = [&](const QString& title, const std::vector<const GitChangeDto*>& items) {
        if (items.empty()) return;
        auto* section = new QTreeWidgetItem(changesTree_);
        section->setText(0, QStringLiteral("%1  ·  %2 file(s)")
                                .arg(title)
                                .arg(static_cast<qulonglong>(items.size())));
        section->setFlags(Qt::ItemIsEnabled);
        section->setExpanded(true);
        section->setForeground(0, QBrush(ui::Theme::primaryText()));
        {
            QFont font = section->font(0);
            font.setBold(true);
            font.setLetterSpacing(QFont::PercentageSpacing, 98);
            section->setFont(0, font);
        }
        for (const auto* change : items) {
            auto* item = new QTreeWidgetItem(section);
            const auto path = fromUtf8(change->path);
            const auto name = fileNameOf(path);
            const auto parent = parentPathOf(path);
            const auto label = parent.isEmpty()
                ? QStringLiteral("%1  %2").arg(fromUtf8(change->status), name)
                : QStringLiteral("%1  %2  %3").arg(fromUtf8(change->status), name, parent);
            item->setText(0, label);
            item->setData(0, RelativePathRole, path);
            item->setData(0, ChangeStagedRole, change->staged);
            item->setFlags(Qt::ItemIsEnabled | Qt::ItemIsSelectable | Qt::ItemIsUserCheckable);
            item->setCheckState(0, change->staged ? Qt::Checked : Qt::Unchecked);
            item->setForeground(0, QBrush(statusColor(change->status)));
            item->setToolTip(0, path);
            if (path == selectedChangePath_) item->setSelected(true);
        }
    };

    addSection(QStringLiteral("Changes"), tracked);
    addSection(QStringLiteral("Unversioned Files"), untracked);
    stagedCountLabel_->setText(QStringLiteral("%1 staged").arg(static_cast<qulonglong>(stagedCount)));
    discardButton_->setEnabled(!selectedChangePath_.isEmpty());
    previewButton_->setEnabled(hasAnyChanges);
    stageAllToolbarButton_->setEnabled(hasAnyChanges);
    suppressingChangeSignals_ = false;
}

void GitChangesPanel::rebuildShelfList(const app::GitFeatureState& state) {
    shelvesList_->clear();
    for (const auto& shelf : state.shelves) {
        auto* item = new QListWidgetItem(
            QStringLiteral("%1  (%2 file(s))")
                .arg(fromUtf8(shelf.message))
                .arg(static_cast<qulonglong>(shelf.paths.size())),
            shelvesList_);
        item->setData(ShelfIdRole, fromUtf8(shelf.id));
        item->setToolTip(fromUtf8(shelf.id));
    }
    applyShelfButton_->setEnabled(shelvesList_->count() > 0);
    dropShelfButton_->setEnabled(shelvesList_->count() > 0);
}

void GitChangesPanel::rebuildStashList(const app::GitFeatureState& state) {
    stashesList_->clear();
    for (const auto& stash : state.stashes->stashes) {
        auto* item = new QListWidgetItem(
            QStringLiteral("%1  %2")
                .arg(fromUtf8(stash.reference), fromUtf8(stash.message)),
            stashesList_);
        item->setData(StashReferenceRole, fromUtf8(stash.reference));
    }
    const bool has = stashesList_->count() > 0;
    applyStashButton_->setEnabled(has);
    popStashButton_->setEnabled(has);
    dropStashButton_->setEnabled(has);
}

void GitChangesPanel::updateCommitActions(const app::GitFeatureState& state) {
    const bool busy = state.isWriting || state.isPerformingBranchOperation ||
        state.isResolvingGitOperation;
    const bool blocked = app::commitBlockedByConflicts(state.status, {});
    const bool hasMessage = !commitMessage().trimmed().isEmpty();
    const bool hasStaged = state.status &&
        std::any_of(state.status->changes.begin(), state.status->changes.end(),
                    [](const GitChangeDto& change) { return change.staged; });
    const bool canCommit = !busy && !blocked && hasMessage && hasStaged;
    commitButton_->setEnabled(canCommit);
    commitAndPushButton_->setEnabled(canCommit);
    aiButton_->setEnabled(!busy && hasStaged);
    amendCheck_->setEnabled(!busy);
    refreshButton_->setEnabled(!busy);
}

void GitChangesPanel::onChangeItemClicked(QTreeWidgetItem* item, int) {
    if (item == nullptr) return;
    const auto path = item->data(0, RelativePathRole).toString();
    if (path.isEmpty()) return;
    selectedChangePath_ = path;
    discardButton_->setEnabled(true);
}

void GitChangesPanel::onChangeItemChanged(QTreeWidgetItem* item, int column) {
    if (suppressingChangeSignals_ || item == nullptr || column != 0) return;
    const auto path = item->data(0, RelativePathRole).toString();
    if (path.isEmpty()) return;
    const bool wasStaged = item->data(0, ChangeStagedRole).toBool();
    const bool nowStaged = item->checkState(0) == Qt::Checked;
    if (wasStaged == nowStaged) return;
    item->setData(0, ChangeStagedRole, nowStaged);
    if (nowStaged) emit stagePathRequested(path);
    else emit unstagePathRequested(path);
}

} // namespace lithe::windows
