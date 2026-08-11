#include "workbench_window.h"

#include "diff_collapse.h"
#include "project_import_dialog.h"
#include "ui_translation.h"
#include "workbench_code_editor.h"
#include "win32_file_storage.h"

#include <QAction>
#include <QApplication>
#include <QByteArray>
#include <QColor>
#include <QCheckBox>
#include <QClipboard>
#include <QComboBox>
#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDoubleSpinBox>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QInputDialog>
#include <QIcon>
#include <QKeyEvent>
#include <QKeySequence>
#include <QLabel>
#include <QList>
#include <QLineEdit>
#include <QListWidget>
#include <QMetaObject>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QIODevice>
#include <QPainter>
#include <QPaintEvent>
#include <QPolygonF>
#include <QPen>
#include <QProcess>
#include <QPushButton>
#include <QPlainTextEdit>
#include <QPointer>
#include <QTimer>
#include <QSplitter>
#include <QStatusBar>
#include <QStyle>
#include <QStyleOptionViewItem>
#include <QStyledItemDelegate>
#include <QSignalBlocker>
#include <QStringList>
#include <QTabBar>
#include <QTabWidget>
#include <QTableWidget>
#include <QHeaderView>
#include <QAbstractItemView>
#include <QTextBlock>
#include <QTextBrowser>
#include <QTextCharFormat>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextEdit>
#include <QToolBar>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QUrl>
#include <QVBoxLayout>
#include <QWidget>

#include <filesystem>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <functional>
#include <map>
#include <sstream>
#include <string_view>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

namespace lithe::windows {

namespace {
constexpr int RelativePathRole = Qt::UserRole;
constexpr int DirectoryRole = Qt::UserRole + 1;
constexpr int HistoryContentPathRole = Qt::UserRole + 2;
constexpr int DiffHunkRole = Qt::UserRole + 3;
constexpr int NavigationLineRole = Qt::UserRole + 4;
constexpr int NavigationColumnRole = Qt::UserRole + 5;
constexpr int DiffRegionRole = Qt::UserRole + 6;
constexpr int GitCommitHashRole = Qt::UserRole + 7;
constexpr int GitStashReferenceRole = Qt::UserRole + 8;
constexpr int DiffOverviewRowRole = Qt::UserRole + 9;
constexpr int NavigationAbsolutePathRole = Qt::UserRole + 10;
constexpr int ShelfIdRole = Qt::UserRole + 11;

algorithms::DiffRowKind diffRowKind(std::string_view kind) {
    if (kind == "changed") return algorithms::DiffRowKind::Changed;
    if (kind == "addition") return algorithms::DiffRowKind::Addition;
    if (kind == "removal") return algorithms::DiffRowKind::Removal;
    if (kind == "information") return algorithms::DiffRowKind::Information;
    return algorithms::DiffRowKind::Context;
}

QColor diffBackground(algorithms::DiffRowKind kind) {
    switch (kind) {
    case algorithms::DiffRowKind::Changed: return QColor(255, 247, 204);
    case algorithms::DiffRowKind::Addition: return QColor(222, 247, 229);
    case algorithms::DiffRowKind::Removal: return QColor(255, 228, 228);
    case algorithms::DiffRowKind::Information: return QColor(228, 236, 247);
    case algorithms::DiffRowKind::Context: return QColor(248, 249, 251);
    }
    return QColor(248, 249, 251);
}

QString numberedDiffText(const std::optional<std::uint64_t>& line,
                         const std::optional<std::string>& text) {
    const auto number = line
        ? QString::number(static_cast<qulonglong>(*line)).rightJustified(6, ' ')
        : QStringLiteral("      ");
    return number + QStringLiteral("  ") +
        (text ? QString::fromUtf8(text->data(), static_cast<qsizetype>(text->size()))
              : QStringLiteral(""));
}

QString fromUtf8(std::string_view value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

std::string pathUtf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

QString normalizedRelativePath(QString path) {
    path = QDir::cleanPath(QDir::fromNativeSeparators(std::move(path)));
    return path == QStringLiteral(".") ? QString() : path;
}

QString javaProjectRoot(const QString& workspaceRoot, const QString& relativePath) {
    const auto workspace = QFileInfo(workspaceRoot).absoluteFilePath();
    if (workspace.isEmpty()) return workspaceRoot;
    QDir current(QFileInfo(QDir(workspace).filePath(relativePath)).absolutePath());
    while (!current.path().isEmpty()) {
        const auto hasProjectMarker = [&current](const QString& name) {
            return QFileInfo(current.filePath(name)).exists();
        };
        if (hasProjectMarker(QStringLiteral("pom.xml")) ||
            hasProjectMarker(QStringLiteral("build.gradle")) ||
            hasProjectMarker(QStringLiteral("build.gradle.kts")) ||
            hasProjectMarker(QStringLiteral(".git"))) {
            return current.absolutePath();
        }
        if (current.absolutePath().compare(workspace, Qt::CaseInsensitive) == 0 ||
            !current.cdUp()) break;
    }
    return workspace;
}

bool sameRelativePath(const QString& left, const QString& right) {
    return left.compare(right, Qt::CaseInsensitive) == 0;
}

bool stagedDiffContainsSensitiveFile(std::string_view patch) {
    const auto sensitivePath = [](std::string_view path) {
        while (!path.empty() && (path.back() == '\r' || path.back() == '\n')) {
            path.remove_suffix(1);
        }
        const auto metadata = path.find_first_of("\t ");
        if (metadata != std::string_view::npos) path = path.substr(0, metadata);
        return path != "/dev/null" && app::AICommitMessageService::isSensitivePath(path);
    };
    std::size_t start = 0;
    while (start <= patch.size()) {
        const auto end = patch.find('\n', start);
        const auto line = patch.substr(start,
            end == std::string_view::npos ? patch.size() - start : end - start);
        if (line.starts_with("diff --git a/")) {
            const auto separator = line.find(" b/", 13);
            if (separator != std::string_view::npos &&
                (sensitivePath(line.substr(13, separator - 13)) ||
                 sensitivePath(line.substr(separator + 3)))) {
                return true;
            }
        }
        for (const auto prefix : {std::string_view("--- a/"), std::string_view("+++ b/")}) {
            if (line.starts_with(prefix) && sensitivePath(line.substr(prefix.size()))) {
                return true;
            }
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return false;
}

template <typename Enum>
int enumIndex(Enum value) {
    return static_cast<int>(value);
}

class GitHistoryDelegate final : public QStyledItemDelegate {
public:
    GitHistoryDelegate(const algorithms::GitGraphLayout* layout, QObject* parent)
        : QStyledItemDelegate(parent), layout_(layout) {}

    QSize sizeHint(const QStyleOptionViewItem& option,
                   const QModelIndex& index) const override {
        auto size = QStyledItemDelegate::sizeHint(option, index);
        size.setHeight(std::max(size.height(), 32));
        return size;
    }

    void paint(QPainter* painter,
               const QStyleOptionViewItem& option,
               const QModelIndex& index) const override {
        if (layout_ == nullptr || index.row() < 0 ||
            static_cast<std::size_t>(index.row()) >= layout_->rows.size()) {
            QStyledItemDelegate::paint(painter, option, index);
            return;
        }

        constexpr int LaneSpacing = 16;
        constexpr int GraphPadding = 10;
        const auto& row = layout_->rows[static_cast<std::size_t>(index.row())];
        const auto graphWidth = std::max(74,
            GraphPadding * 2 + static_cast<int>(layout_->laneCount) * LaneSpacing);
        auto textOption = option;
        textOption.rect.adjust(graphWidth, 0, 0, 0);
        QStyledItemDelegate::paint(painter, textOption, index);

        const auto colorFor = [](std::size_t index) {
            static const std::array<QColor, 6> colors{
                QColor(64, 124, 206), QColor(218, 108, 77), QColor(82, 164, 102),
                QColor(157, 105, 190), QColor(205, 160, 52), QColor(74, 164, 164),
            };
            return colors[index % colors.size()];
        };
        const auto xForLane = [&](std::size_t lane) {
            return option.rect.left() + GraphPadding +
                static_cast<int>(lane) * LaneSpacing;
        };
        const auto top = option.rect.top();
        const auto center = option.rect.center().y();
        const auto bottom = option.rect.bottom();

        painter->save();
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
                                          ? row.lane : row.incomingLaneColors[row.lane %
                                                                               row.incomingLaneColors.size()]),
                              2));
        painter->setBrush(option.state & QStyle::State_Selected
                              ? option.palette.highlight()
                              : option.palette.base());
        painter->drawEllipse(QPointF(currentX, center), 4.5, 4.5);
        painter->restore();
    }

private:
    const algorithms::GitGraphLayout* layout_ = nullptr;
};

class DiffReviewTable final : public QTableWidget {
public:
    struct Connection {
        int firstRow = 0;
        int lastRow = 0;
        algorithms::DiffRowKind kind = algorithms::DiffRowKind::Changed;
    };

    using QTableWidget::QTableWidget;

    void setConnections(std::vector<Connection> connections) {
        connections_ = std::move(connections);
        viewport()->update();
    }

protected:
    void paintEvent(QPaintEvent* event) override {
        QTableWidget::paintEvent(event);
        if (connections_.empty() || model() == nullptr) return;

        QPainter painter(viewport());
        painter.setRenderHint(QPainter::Antialiasing, true);
        for (const auto& connection : connections_) {
            if (connection.firstRow < 0 || connection.lastRow < connection.firstRow ||
                connection.lastRow >= rowCount()) {
                continue;
            }
            const auto first = visualRect(model()->index(connection.firstRow, 0));
            const auto last = visualRect(model()->index(connection.lastRow, 0));
            if (!first.isValid() || !last.isValid() ||
                first.bottom() < 0 || last.top() > viewport()->height()) {
                continue;
            }

            const auto leftEdge = columnViewportPosition(0) + columnWidth(0) - 2;
            const auto rightEdge = columnViewportPosition(1) + 2;
            if (rightEdge <= leftEdge) continue;
            const auto top = std::max(0, first.top() + 3);
            const auto bottom = std::min(viewport()->height() - 3, last.bottom() - 3);
            if (bottom < 0 || top > viewport()->height() || bottom < top) continue;

            QColor color;
            switch (connection.kind) {
            case algorithms::DiffRowKind::Addition:
                color = QColor(67, 160, 93, 72);
                break;
            case algorithms::DiffRowKind::Removal:
                color = QColor(214, 75, 75, 72);
                break;
            case algorithms::DiffRowKind::Changed:
                color = QColor(205, 160, 52, 72);
                break;
            default:
                continue;
            }
            const auto bend = std::min(12, (rightEdge - leftEdge) / 3);
            QPolygonF ribbon{
                QPointF(leftEdge, top), QPointF(leftEdge + bend, top),
                QPointF(rightEdge - bend, bottom), QPointF(rightEdge, bottom),
                QPointF(rightEdge, bottom + 4), QPointF(rightEdge - bend, bottom + 4),
                QPointF(leftEdge + bend, top + 4), QPointF(leftEdge, top + 4),
            };
            painter.setPen(QPen(color.darker(125), 1));
            painter.setBrush(color);
            painter.drawPolygon(ribbon);
        }
    }

private:
    std::vector<Connection> connections_;
};
}

WorkbenchWindow::WorkbenchWindow(std::unique_ptr<DirectoryChangeSource> watcher,
                                 QWidget* parent)
    : QMainWindow(parent),
      keyValueStore_(),
      recentProjectsStore_(keyValueStore_),
      workspaceSessionStore_(keyValueStore_),
      appSettingsStore_(keyValueStore_),
      layoutPersistence_(keyValueStore_),
      appSettings_(appSettingsStore_.load()),
      runtimeLocator_(),
      runtimeService_(runtimeLocator_),
      mavenRunner_(),
      archiveRunner_(),
      archiveReader_(archiveRunner_),
      mavenBuildService_(runtimeService_, mavenRunner_),
      coordinator_(std::make_unique<app::WorkbenchCoordinator>()),
      storage_(std::make_unique<Win32FileStorage>()),
      secureStore_(),
      httpTransport_(),
      authenticodeVerifier_(),
      aiCommitService_(httpTransport_, secureStore_),
      updateService_(httpTransport_, *storage_),
      javaRunService_(std::make_unique<app::JavaRunService>(runtimeService_, *storage_)),
      javaDebugService_(std::make_unique<app::JavaDebugService>(
          runtimeService_, *javaRunService_, *storage_, [] {
              return std::make_unique<Win32ProcessSession>();
          })),
      workspaceFeature_(std::make_unique<app::WorkspaceFeatureModel>(*coordinator_)),
      documentFeature_(std::make_unique<app::DocumentFeatureModel>(*coordinator_)),
      searchFeature_(std::make_unique<app::SearchFeatureModel>(*coordinator_)),
      gitFeature_(std::make_unique<app::GitFeatureModel>(*coordinator_)),
      historyFeature_(std::make_unique<app::HistoryFeatureModel>(*coordinator_, *storage_)),
      shelfFeature_(std::make_unique<app::ShelfFeatureModel>(*coordinator_, *storage_,
                                                             appSettings_.dataDirectory)),
      mavenJavaFeature_(std::make_unique<app::MavenJavaFeatureModel>(*coordinator_)),
      mavenSession_(std::make_unique<Win32ProcessSession>()),
      javaSession_(std::make_unique<Win32ProcessSession>()),
      languageServerSession_(std::make_unique<Win32ProcessSession>()),
      languageServer_(std::make_unique<app::JavaLanguageServerClient>(
          runtimeService_, *storage_, *languageServerSession_, &archiveReader_)),
      watcher_(std::move(watcher)),
      terminal_(std::make_unique<Win32TerminalTransport>()) {
    if (qApp != nullptr) qApp->installEventFilter(this);
    setWindowTitle(uiText(QStringLiteral("Lithe")));
    setWindowIcon(QIcon(QStringLiteral(":/lithe.ico")));
    resize(1280, 800);

    auto* central = new QWidget(this);
    auto* layout = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    shellSplitter_ = new QSplitter(Qt::Horizontal, central);
    shellSplitter_->setObjectName(QStringLiteral("workbench.shellSplitter"));

    sidebar_ = new WorkbenchSidebar(shellSplitter_);
    tree_ = sidebar_->projectTree();
    tree_->setHeaderLabel(uiText(QStringLiteral("Workspace")));
    tree_->setHeaderHidden(false);
    tree_->setMinimumWidth(260);
    connect(tree_, &QTreeWidget::itemDoubleClicked, this, &WorkbenchWindow::openTreeItem);
    connect(sidebar_, &WorkbenchSidebar::projectItemActivated,
            this, &WorkbenchWindow::openTreeItem);
    connect(sidebar_, &WorkbenchSidebar::projectContextMenuRequested,
            this, &WorkbenchWindow::showTreeContextMenu);

    searchField_ = sidebar_->searchField();
    searchField_->setPlaceholderText(uiText(QStringLiteral("Search workspace")));
    connect(searchField_, &QLineEdit::returnPressed, this, &WorkbenchWindow::searchWorkspace);

    changes_ = sidebar_->changesList();
    connect(sidebar_, &WorkbenchSidebar::changesItemActivated,
            this, &WorkbenchWindow::openChangeItem);

    editorToolSplitter_ = new QSplitter(Qt::Vertical, shellSplitter_);
    editorToolSplitter_->setObjectName(QStringLiteral("workbench.editorToolSplitter"));
    editorArea_ = new WorkbenchEditorArea(editorToolSplitter_);
    toolWindow_ = new WorkbenchToolWindow(editorToolSplitter_);
    editorToolSplitter_->addWidget(editorArea_);
    editorToolSplitter_->addWidget(toolWindow_);
    editorToolSplitter_->setStretchFactor(0, 1);
    editorToolSplitter_->setStretchFactor(1, 0);

    shellSplitter_->addWidget(sidebar_);
    shellSplitter_->addWidget(editorToolSplitter_);
    shellSplitter_->setStretchFactor(0, 0);
    shellSplitter_->setStretchFactor(1, 1);
    layout->addWidget(shellSplitter_, 1);
    setCentralWidget(central);

    findBar_ = editorArea_->findBar();
    findField_ = editorArea_->findField();
    findStatus_ = editorArea_->findStatus();
    editor_ = editorArea_->editor();
    editorTabs_ = editorArea_->editorTabs();
    results_ = editorArea_->searchResults();
    navigation_ = editorArea_->javaNavigationResults();
    diagnostics_ = editorArea_->diagnostics();
    auto editorFont = editor_->font();
    editorFont.setPointSizeF(appSettings_.editorFontSize);
    editor_->setFont(editorFont);

    connect(findField_, &QLineEdit::textChanged, this,
            &WorkbenchWindow::updateFindHighlights);
    connect(editorArea_, &WorkbenchEditorArea::findNextRequested,
            this, &WorkbenchWindow::findNext);
    connect(editorArea_, &WorkbenchEditorArea::findPreviousRequested,
            this, &WorkbenchWindow::findPrevious);
    connect(editorArea_, &WorkbenchEditorArea::findBarCloseRequested,
            this, &WorkbenchWindow::hideFindBar);
    connect(editorArea_, &WorkbenchEditorArea::tabChanged,
            this, &WorkbenchWindow::switchEditorTab);
    connect(editorArea_, &WorkbenchEditorArea::tabCloseRequested,
            this, &WorkbenchWindow::closeEditorTab);
    connect(editorArea_, &WorkbenchEditorArea::searchResultActivated,
            this, &WorkbenchWindow::openSearchResult);
    connect(editorArea_, &WorkbenchEditorArea::javaNavigationResultActivated,
            this, &WorkbenchWindow::openJavaNavigationItem);
    connect(editorArea_, &WorkbenchEditorArea::diagnosticActivated,
            this, &WorkbenchWindow::openSearchResult);

    workspaceRefreshTimer_ = new QTimer(this);
    workspaceRefreshTimer_->setSingleShot(true);
    workspaceRefreshTimer_->setInterval(200);
    connect(workspaceRefreshTimer_, &QTimer::timeout,
            this, &WorkbenchWindow::loadSnapshot);

    gitRefreshTimer_ = new QTimer(this);
    gitRefreshTimer_->setSingleShot(true);
    gitRefreshTimer_->setInterval(200);
    connect(gitRefreshTimer_, &QTimer::timeout,
            this, &WorkbenchWindow::refreshGitStatus);

    layoutSaveTimer_ = new QTimer(this);
    layoutSaveTimer_->setSingleShot(true);
    layoutSaveTimer_->setInterval(150);
    connect(layoutSaveTimer_, &QTimer::timeout, this, &WorkbenchWindow::saveWorkbenchLayout);

    connect(shellSplitter_, &QSplitter::splitterMoved,
            this, [this] { scheduleWorkbenchLayoutSave(); });
    connect(editorToolSplitter_, &QSplitter::splitterMoved,
            this, [this] { scheduleWorkbenchLayoutSave(); });
    connect(sidebar_, &WorkbenchSidebar::pageChanged, this,
            [this](WorkbenchSidebar::SidebarPage page) {
        layoutState_.sidebarDestination = page == WorkbenchSidebar::SidebarPage::Project
            ? SidebarDestination::Project
            : page == WorkbenchSidebar::SidebarPage::Search
                ? SidebarDestination::Search : SidebarDestination::Git;
        scheduleWorkbenchLayoutSave();
    });
    connect(toolWindow_, &WorkbenchToolWindow::toolChanged, this,
            [this](BottomToolKind kind) {
        layoutState_.bottomToolKind = kind;
        layoutState_.bottomVisible = true;
        scheduleWorkbenchLayoutSave();
    });
    connect(toolWindow_, &WorkbenchToolWindow::hideRequested, this, [this] {
        toolWindow_->setVisible(false);
        layoutState_.bottomVisible = false;
        scheduleWorkbenchLayoutSave();
    });
    auto* mavenPanel = new QWidget(toolWindow_);
    auto* mavenPanelLayout = new QVBoxLayout(mavenPanel);
    mavenPanelLayout->setContentsMargins(8, 8, 8, 8);
    analysisStatus_ = new QLabel(mavenPanel);
    analysisStatus_->setText(uiText(QStringLiteral("Project analysis idle")));
    mavenPanelLayout->addWidget(analysisStatus_);

    auto* mavenControls = new QWidget(mavenPanel);
    auto* mavenLayout = new QHBoxLayout(mavenControls);
    mavenLayout->setContentsMargins(0, 0, 0, 0);
    auto* mavenLabel = new QLabel(uiText(QStringLiteral("Maven")), mavenControls);
    mavenLayout->addWidget(mavenLabel);
    for (const auto& phase : {QStringLiteral("clean"), QStringLiteral("test"),
                              QStringLiteral("package"), QStringLiteral("verify")}) {
        auto* action = new QPushButton(phase, mavenControls);
        mavenLayout->addWidget(action);
        connect(action, &QPushButton::clicked, this, [this, phase] {
            runMavenPhase(phase);
        });
    }
    auto* stopMaven = new QPushButton(uiText(QStringLiteral("Stop")), mavenControls);
    mavenLayout->addWidget(stopMaven);
    connect(stopMaven, &QPushButton::clicked, this, &WorkbenchWindow::stopMavenBuild);
    auto* runJava = new QPushButton(uiText(QStringLiteral("Run Java")), mavenControls);
    mavenLayout->addWidget(runJava);
    connect(runJava, &QPushButton::clicked, this, &WorkbenchWindow::runCurrentJava);
    auto* runSpring = new QPushButton(uiText(QStringLiteral("Run Spring")), mavenControls);
    mavenLayout->addWidget(runSpring);
    connect(runSpring, &QPushButton::clicked, this, &WorkbenchWindow::runSpringBoot);
    auto* stopJava = new QPushButton(uiText(QStringLiteral("Stop Java")), mavenControls);
    mavenLayout->addWidget(stopJava);
    connect(stopJava, &QPushButton::clicked, this, &WorkbenchWindow::stopJavaRun);
    mavenLayout->addStretch(1);
    mavenPanelLayout->addWidget(mavenControls);

    mavenOutput_ = new QPlainTextEdit(mavenPanel);
    mavenOutput_->setReadOnly(true);
    mavenOutput_->setLineWrapMode(QPlainTextEdit::NoWrap);
    mavenOutput_->setMaximumHeight(160);
    mavenOutput_->setPlaceholderText(uiText(QStringLiteral("Maven output")));
    mavenPanelLayout->addWidget(mavenOutput_, 1);
    toolWindow_->setPanel(BottomToolKind::Build, mavenPanel);

    debugPanel_ = new QWidget(toolWindow_);
    auto* debugLayout = new QVBoxLayout(debugPanel_);
    debugLayout->setContentsMargins(0, 0, 0, 0);
    auto* debugInspectControls = new QHBoxLayout();
    auto* threads = new QPushButton(uiText(QStringLiteral("Threads")), debugPanel_);
    auto* stack = new QPushButton(uiText(QStringLiteral("Stack")), debugPanel_);
    auto* variables = new QPushButton(uiText(QStringLiteral("Variables")), debugPanel_);
    debugInspectControls->addWidget(threads);
    debugInspectControls->addWidget(stack);
    debugInspectControls->addWidget(variables);
    debugExpression_ = new QLineEdit(debugPanel_);
    debugExpression_->setPlaceholderText(uiText(QStringLiteral("Evaluate expression")));
    debugInspectControls->addWidget(debugExpression_, 1);
    debugLayout->addLayout(debugInspectControls);

    auto* debugViews = new QSplitter(Qt::Horizontal, debugPanel_);
    debugVariables_ = new QListWidget(debugViews);
    debugVariables_->setToolTip(uiText(QStringLiteral("Double-click a variable to expand or collapse it")));
    debugThreads_ = new QListWidget(debugViews);
    debugStack_ = new QListWidget(debugViews);
    debugViews->addWidget(debugVariables_);
    debugViews->addWidget(debugThreads_);
    debugViews->addWidget(debugStack_);
    debugViews->setStretchFactor(0, 2);
    debugViews->setStretchFactor(1, 1);
    debugViews->setStretchFactor(2, 2);
    debugLayout->addWidget(debugViews);

    debugOutput_ = new QPlainTextEdit(debugPanel_);
    debugOutput_->setReadOnly(true);
    debugOutput_->setLineWrapMode(QPlainTextEdit::NoWrap);
    debugOutput_->setMaximumHeight(150);
    debugOutput_->setPlaceholderText(uiText(QStringLiteral("Debugger output")));
    debugLayout->addWidget(debugOutput_);
    toolWindow_->setPanel(BottomToolKind::Debug, debugPanel_);

    connect(threads, &QPushButton::clicked,
            this, &WorkbenchWindow::inspectDebuggerThreads);
    connect(stack, &QPushButton::clicked,
            this, &WorkbenchWindow::inspectDebuggerStack);
    connect(variables, &QPushButton::clicked,
            this, &WorkbenchWindow::inspectDebuggerVariables);
    connect(debugExpression_, &QLineEdit::returnPressed,
            this, &WorkbenchWindow::evaluateDebuggerExpression);
    connect(debugVariables_, &QListWidget::itemDoubleClicked,
            this, &WorkbenchWindow::toggleDebuggerVariable);

    debugPollTimer_ = new QTimer(this);
    debugPollTimer_->setInterval(100);
    connect(debugPollTimer_, &QTimer::timeout, this, [this] {
        if (javaDebugService_) javaDebugService_->poll();
    });
    debugPollTimer_->start();

    terminalPanel_ = new QWidget(toolWindow_);
    auto* terminalLayout = new QVBoxLayout(terminalPanel_);
    terminalLayout->setContentsMargins(0, 0, 0, 0);
    terminalOutput_ = new QPlainTextEdit(terminalPanel_);
    terminalOutput_->setReadOnly(true);
    terminalOutput_->setLineWrapMode(QPlainTextEdit::NoWrap);
    terminalOutput_->setMaximumHeight(190);
    terminalOutput_->setPlaceholderText(uiText(QStringLiteral("Terminal output")));
    terminalLayout->addWidget(terminalOutput_);
    terminalInput_ = new QLineEdit(terminalPanel_);
    terminalInput_->setPlaceholderText(uiText(QStringLiteral("Enter terminal command")));
    connect(terminalInput_, &QLineEdit::returnPressed, this, [this] {
        if (!terminal_ || !terminal_->isRunning()) return;
        terminal_->send(terminalInput_->text().toUtf8().toStdString() + "\r\n");
        terminalInput_->clear();
    });
    terminalLayout->addWidget(terminalInput_);
    toolWindow_->setPanel(BottomToolKind::Terminal, terminalPanel_);

    connect(editor_, &QPlainTextEdit::textChanged, this, [this] {
        if (suppressEditorChange_ || activePath_.isEmpty()) return;
        languageServerText_ = editor_->toPlainText().toUtf8().toStdString();
        documentFeature_->setText(languageServerText_);
        if (languageServerPath_.isEmpty()) return;
        if (languageServer_ && languageServer_->isReady() && !languageServerUri_.empty()) {
            languageServer_->didChange(languageServerUri_, languageServerText_);
        }
        if (findBar_ != nullptr && findBar_->isVisible()) updateFindHighlights();
    });
    connect(changes_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openChangeItem(item); });

    auto* gitPanel = new QWidget(toolWindow_);
    auto* gitPanelLayout = new QVBoxLayout(gitPanel);
    gitPanelLayout->setContentsMargins(8, 8, 8, 8);
    auto* diffPanel = new QWidget(toolWindow_);
    auto* diffPanelLayout = new QVBoxLayout(diffPanel);
    diffPanelLayout->setContentsMargins(8, 8, 8, 8);

    auto* gitControls = new QWidget(gitPanel);
    auto* gitControlLayout = new QHBoxLayout(gitControls);
    gitControlLayout->setContentsMargins(0, 0, 0, 0);
    auto* gitLog = new QPushButton(uiText(QStringLiteral("Git Log")), gitControls);
    auto* gitStashes = new QPushButton(uiText(QStringLiteral("Stashes")), gitControls);
    auto* shelves = new QPushButton(uiText(QStringLiteral("Shelves")), gitControls);
    auto* gitCompare = new QPushButton(uiText(QStringLiteral("Compare...")), gitControls);
    gitControlLayout->addWidget(gitLog);
    gitControlLayout->addWidget(gitStashes);
    gitControlLayout->addWidget(shelves);
    gitControlLayout->addWidget(gitCompare);
    gitControlLayout->addStretch(1);
    connect(gitLog, &QPushButton::clicked, this, &WorkbenchWindow::loadGitHistory);
    connect(gitStashes, &QPushButton::clicked, this, &WorkbenchWindow::loadGitStashes);
    connect(shelves, &QPushButton::clicked, this, &WorkbenchWindow::loadShelves);
    connect(gitCompare, &QPushButton::clicked, this, &WorkbenchWindow::compareGitReference);
    gitPanelLayout->addWidget(gitControls);

    gitHistory_ = new QListWidget(gitPanel);
    gitHistory_->setMaximumHeight(230);
    gitHistory_->setVisible(false);
    gitHistory_->setItemDelegate(new GitHistoryDelegate(&gitHistoryGraph_, gitHistory_));
    connect(gitHistory_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openGitHistoryItem(item); });
    gitPanelLayout->addWidget(gitHistory_);

    gitStashes_ = new QListWidget(gitPanel);
    gitStashes_->setMaximumHeight(180);
    gitStashes_->setVisible(false);
    connect(gitStashes_, &QListWidget::itemClicked, this,
            [this](QListWidgetItem* item) {
        selectedGitStash_ = item == nullptr
            ? QString() : item->data(GitStashReferenceRole).toString();
    });
    gitPanelLayout->addWidget(gitStashes_);

    gitStashActions_ = new QWidget(gitPanel);
    auto* gitStashActionLayout = new QHBoxLayout(gitStashActions_);
    gitStashActionLayout->setContentsMargins(0, 0, 0, 0);
    auto* applyStash = new QPushButton(uiText(QStringLiteral("Apply")), gitStashActions_);
    auto* popStash = new QPushButton(uiText(QStringLiteral("Pop")), gitStashActions_);
    auto* dropStash = new QPushButton(uiText(QStringLiteral("Drop")), gitStashActions_);
    gitStashActionLayout->addWidget(applyStash);
    gitStashActionLayout->addWidget(popStash);
    gitStashActionLayout->addWidget(dropStash);
    gitStashActionLayout->addStretch(1);
    connect(applyStash, &QPushButton::clicked,
            this, &WorkbenchWindow::applySelectedStash);
    connect(popStash, &QPushButton::clicked,
            this, &WorkbenchWindow::popSelectedStash);
    connect(dropStash, &QPushButton::clicked,
            this, &WorkbenchWindow::dropSelectedStash);
    gitStashActions_->setVisible(false);
    gitPanelLayout->addWidget(gitStashActions_);

    gitShelves_ = new QListWidget(gitPanel);
    gitShelves_->setMaximumHeight(180);
    gitShelves_->setVisible(false);
    connect(gitShelves_, &QListWidget::currentItemChanged, this,
            [this](QListWidgetItem* item, QListWidgetItem*) {
        selectedShelf_ = item == nullptr ? QString() : item->data(ShelfIdRole).toString();
        if (gitShelfActions_ != nullptr) gitShelfActions_->setVisible(true);
        setShelfActionsEnabled(true);
    });
    gitPanelLayout->addWidget(gitShelves_);

    gitShelfActions_ = new QWidget(gitPanel);
    auto* shelfActionLayout = new QHBoxLayout(gitShelfActions_);
    shelfActionLayout->setContentsMargins(0, 0, 0, 0);
    createShelfButton_ = new QPushButton(uiText(QStringLiteral("Create Shelf")), gitShelfActions_);
    restoreShelfButton_ = new QPushButton(uiText(QStringLiteral("Restore")), gitShelfActions_);
    deleteShelfButton_ = new QPushButton(uiText(QStringLiteral("Delete")), gitShelfActions_);
    shelfActionLayout->addWidget(createShelfButton_);
    shelfActionLayout->addWidget(restoreShelfButton_);
    shelfActionLayout->addWidget(deleteShelfButton_);
    shelfActionLayout->addStretch(1);
    connect(createShelfButton_, &QPushButton::clicked, this, &WorkbenchWindow::createShelf);
    connect(restoreShelfButton_, &QPushButton::clicked, this, &WorkbenchWindow::restoreSelectedShelf);
    connect(deleteShelfButton_, &QPushButton::clicked, this, &WorkbenchWindow::deleteSelectedShelf);
    gitShelfActions_->setVisible(false);
    gitPanelLayout->addWidget(gitShelfActions_);

    gitDetails_ = new QPlainTextEdit(gitPanel);
    gitDetails_->setReadOnly(true);
    gitDetails_->setLineWrapMode(QPlainTextEdit::NoWrap);
    gitDetails_->setMaximumHeight(190);
    gitDetails_->setPlaceholderText(uiText(QStringLiteral("Git commit or comparison details")));
    gitDetails_->setVisible(false);
    gitPanelLayout->addWidget(gitDetails_);

    commitFiles_ = new QListWidget(gitPanel);
    commitFiles_->setMaximumHeight(150);
    commitFiles_->setVisible(false);
    connect(commitFiles_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openCommitFile(item); });
    gitPanelLayout->addWidget(commitFiles_);

    commitEditor_ = new QPlainTextEdit(gitPanel);
    commitEditor_->setPlaceholderText(uiText(QStringLiteral("Commit message")));
    commitEditor_->setMaximumHeight(90);
    gitPanelLayout->addWidget(commitEditor_);

    auto* commitControls = new QWidget(gitPanel);
    auto* commitLayout = new QHBoxLayout(commitControls);
    commitLayout->setContentsMargins(0, 0, 0, 0);
    auto* stageAll = new QPushButton(uiText(QStringLiteral("Stage all")), commitControls);
    auto* generateMessage = new QPushButton(uiText(QStringLiteral("AI message")), commitControls);
    auto* commit = new QPushButton(uiText(QStringLiteral("Commit")), commitControls);
    amendCommit_ = new QCheckBox(uiText(QStringLiteral("Amend")), commitControls);
    commitLayout->addWidget(stageAll);
    commitLayout->addWidget(generateMessage);
    commitLayout->addWidget(commit);
    commitLayout->addWidget(amendCommit_);
    commitLayout->addStretch(1);
    connect(stageAll, &QPushButton::clicked, this, &WorkbenchWindow::stageAllChanges);
    connect(generateMessage, &QPushButton::clicked,
            this, &WorkbenchWindow::generateAICommitMessage);
    connect(commit, &QPushButton::clicked, this, &WorkbenchWindow::commitChanges);
    gitPanelLayout->addWidget(commitControls);

    diffActions_ = new QWidget(diffPanel);
    auto* diffActionLayout = new QHBoxLayout(diffActions_);
    auto* stageHunk = new QPushButton(uiText(QStringLiteral("Stage hunk")), diffActions_);
    auto* unstageHunk = new QPushButton(uiText(QStringLiteral("Unstage hunk")), diffActions_);
    auto* discardHunk = new QPushButton(uiText(QStringLiteral("Discard hunk")), diffActions_);
    diffActionLayout->addWidget(stageHunk);
    diffActionLayout->addWidget(unstageHunk);
    diffActionLayout->addWidget(discardHunk);
    connect(stageHunk, &QPushButton::clicked,
            this, &WorkbenchWindow::stageSelectedHunk);
    connect(unstageHunk, &QPushButton::clicked,
            this, &WorkbenchWindow::unstageSelectedHunk);
    connect(discardHunk, &QPushButton::clicked,
            this, &WorkbenchWindow::discardSelectedHunk);
    diffActions_->setVisible(false);
    diffPanelLayout->addWidget(diffActions_);

    diffReviewPanel_ = new QWidget(diffPanel);
    auto* diffReviewLayout = new QHBoxLayout(diffReviewPanel_);
    diffReviewLayout->setContentsMargins(0, 0, 0, 0);
    diffOverview_ = new QListWidget(diffReviewPanel_);
    diffOverview_->setFixedWidth(118);
    diffOverview_->setMaximumHeight(330);
    diffOverview_->setSelectionMode(QAbstractItemView::SingleSelection);
    diffOverview_->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    diffOverview_->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    diffOverview_->setVisible(false);
    connect(diffOverview_, &QListWidget::itemClicked, this,
            [this](QListWidgetItem* item) {
        if (item == nullptr || diff_ == nullptr) return;
        bool ok = false;
        const auto row = item->data(DiffOverviewRowRole).toInt(&ok);
        if (!ok || row < 0 || row >= diff_->rowCount()) return;
        if (auto* target = diff_->item(row, 0)) {
            selectedDiffHunk_ = target->data(DiffHunkRole).toString();
            diff_->selectRow(row);
            diff_->scrollToItem(target, QAbstractItemView::PositionAtCenter);
        }
    });
    diffReviewLayout->addWidget(diffOverview_);

    diff_ = new DiffReviewTable(diffReviewPanel_);
    diff_->setColumnCount(2);
    diff_->setHorizontalHeaderLabels({uiText(QStringLiteral("Old")), uiText(QStringLiteral("New"))});
    diff_->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    diff_->verticalHeader()->setVisible(false);
    diff_->setEditTriggers(QAbstractItemView::NoEditTriggers);
    diff_->setSelectionBehavior(QAbstractItemView::SelectRows);
    diff_->setSelectionMode(QAbstractItemView::SingleSelection);
    diff_->setWordWrap(false);
    diff_->setMinimumHeight(180);
    diff_->setMaximumHeight(330);
    diff_->setVisible(false);
    connect(diff_, &QTableWidget::itemClicked, this, [this](QTableWidgetItem* item) {
        const auto region = item->data(DiffRegionRole).toString();
        if (!region.isEmpty()) {
            expandedDiffRegions_.insert(region.toStdString());
            renderDiffReview();
            return;
        }
        selectedDiffHunk_ = item->data(DiffHunkRole).toString();
    });
    diffReviewLayout->addWidget(diff_, 1);
    diffReviewPanel_->setVisible(false);
    diffPanelLayout->addWidget(diffReviewPanel_, 1);

    history_ = new QListWidget(gitPanel);
    history_->setMaximumHeight(190);
    history_->setVisible(false);
    connect(history_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openHistoryItem(item); });
    gitPanelLayout->addWidget(history_);
    gitPanelLayout->addStretch(1);
    diffPanelLayout->addStretch(1);
    toolWindow_->setPanel(BottomToolKind::Git, gitPanel);
    toolWindow_->setPanel(BottomToolKind::Diff, diffPanel);

    buildActions();

    mavenSession_->setOutputHandler([this](const std::string& output) {
        QMetaObject::invokeMethod(this, [this, output] {
            appendMavenOutput(fromUtf8(output));
        }, Qt::QueuedConnection);
    });
    mavenSession_->setErrorHandler([this](const std::string& error) {
        QMetaObject::invokeMethod(this, [this, error] {
            appendMavenOutput(QStringLiteral("[stderr] ") + fromUtf8(error));
        }, Qt::QueuedConnection);
    });
    mavenSession_->setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        QMetaObject::invokeMethod(this, [this, event] {
            applyMavenLifecycle(event);
        }, Qt::QueuedConnection);
    });
    javaSession_->setOutputHandler([this](const std::string& output) {
        QMetaObject::invokeMethod(this, [this, output] {
            appendMavenOutput(fromUtf8(output));
        }, Qt::QueuedConnection);
    });
    javaSession_->setErrorHandler([this](const std::string& error) {
        QMetaObject::invokeMethod(this, [this, error] {
            appendMavenOutput(QStringLiteral("[java stderr] ") + fromUtf8(error));
        }, Qt::QueuedConnection);
    });
    javaSession_->setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        QMetaObject::invokeMethod(this, [this, event] {
            applyJavaLifecycle(event);
        }, Qt::QueuedConnection);
    });
    terminal_->setOutputHandler([this](const std::string& output) {
        QMetaObject::invokeMethod(this, [this, output] {
            if (terminalOutput_ == nullptr) return;
            terminalOutput_->moveCursor(QTextCursor::End);
            terminalOutput_->insertPlainText(fromUtf8(output));
        }, Qt::QueuedConnection);
    });
    terminal_->setErrorHandler([this](const std::string& error) {
        QMetaObject::invokeMethod(this, [this, error] {
            if (terminalOutput_ == nullptr) return;
            terminalOutput_->moveCursor(QTextCursor::End);
            terminalOutput_->insertPlainText(fromUtf8(error));
        }, Qt::QueuedConnection);
    });
    terminal_->setExitHandler([this] {
        QMetaObject::invokeMethod(this, [this] {
            statusBar()->showMessage(uiText(QStringLiteral("Terminal exited")), 3000);
        }, Qt::QueuedConnection);
    });

    languageServer_->setStateHandler([this](bool ready, const std::string& message) {
        QMetaObject::invokeMethod(this, [this, ready, message] {
            applyLanguageServerState(ready, message);
        }, Qt::QueuedConnection);
    });
    languageServer_->setDiagnosticsHandler(
        [this](const std::string& uri, const JsonValue& diagnostics) {
        QMetaObject::invokeMethod(this, [this, uri, diagnostics] {
            applyLanguageServerDiagnostics(uri, diagnostics);
        }, Qt::QueuedConnection);
    });
    javaDebugService_->setStateHandler([this] {
        QMetaObject::invokeMethod(this, &WorkbenchWindow::applyJavaDebugState,
                                  Qt::QueuedConnection);
    });

    statusBar()->showMessage(uiText(QStringLiteral("Rust Core %1"))
                                 .arg(fromUtf8(coordinator_->coreVersion())));
    QTimer::singleShot(0, this, &WorkbenchWindow::restoreWorkbenchLayout);
    QTimer::singleShot(0, this, &WorkbenchWindow::restoreRecentWorkspace);
}

WorkbenchWindow::~WorkbenchWindow() {
    if (qApp != nullptr) qApp->removeEventFilter(this);
    if (aiWorker_.joinable()) aiWorker_.join();
    if (updateWorker_.joinable()) updateWorker_.join();
    stopTerminal();
    if (languageServer_) languageServer_->stop();
    stopDebugger();
    stopJavaRun();
    stopMavenBuild();
    if (watcher_) watcher_->stop();
    saveWorkbenchLayout();
    saveWorkspaceSession();
    if (coordinator_) coordinator_->shutdown();
}

void WorkbenchWindow::restoreWorkbenchLayout() {
    if (shellSplitter_ == nullptr || editorToolSplitter_ == nullptr ||
        sidebar_ == nullptr || toolWindow_ == nullptr) return;

    const auto requested = workspaceRoot_.isEmpty()
        ? WorkbenchLayoutState{}
        : layoutPersistence_.load(workspaceRoot_.toStdString());
    const auto availableWidth = std::max(shellSplitter_->width(), kSidebarMinWidth + 1);
    const auto availableHeight = std::max(editorToolSplitter_->height(),
                                           kEditorTopMinHeight + kBottomToolMinHeight);
    layoutState_ = normalizeWorkbenchLayout(requested, availableWidth, availableHeight);

    const auto sidebarPage = layoutState_.sidebarDestination == SidebarDestination::Project
        ? WorkbenchSidebar::SidebarPage::Project
        : layoutState_.sidebarDestination == SidebarDestination::Search
            ? WorkbenchSidebar::SidebarPage::Search
            : WorkbenchSidebar::SidebarPage::Changes;
    {
        const QSignalBlocker sidebarBlocker(sidebar_);
        sidebar_->setPage(sidebarPage);
    }
    {
        const QSignalBlocker toolBlocker(toolWindow_);
        toolWindow_->setKind(layoutState_.bottomToolKind);
    }

    const auto rightWidth = std::max(kMinimumUsablePaneSize,
                                     availableWidth - layoutState_.sidebarWidth);
    shellSplitter_->setSizes({layoutState_.sidebarWidth, rightWidth});
    toolWindow_->setVisible(layoutState_.bottomVisible);
    if (layoutState_.bottomVisible) {
        const auto bottomHeight = std::max(kBottomToolMinHeight,
                                           availableHeight - layoutState_.editorTopHeight);
        editorToolSplitter_->setSizes({layoutState_.editorTopHeight, bottomHeight});
    } else {
        editorToolSplitter_->setSizes({availableHeight, 0});
    }
}

void WorkbenchWindow::saveWorkbenchLayout() {
    if (layoutSaveTimer_ != nullptr) layoutSaveTimer_->stop();
    if (workspaceRoot_.isEmpty() || shellSplitter_ == nullptr ||
        editorToolSplitter_ == nullptr || toolWindow_ == nullptr) return;

    const auto shellSizes = shellSplitter_->sizes();
    if (shellSizes.size() >= 2 && shellSizes[0] > 0) {
        layoutState_.sidebarWidth = shellSizes[0];
    }
    const auto editorToolSizes = editorToolSplitter_->sizes();
    if (toolWindow_->isVisible() && editorToolSizes.size() >= 2 && editorToolSizes[0] > 0) {
        layoutState_.editorTopHeight = editorToolSizes[0];
    }
    layoutState_.bottomVisible = toolWindow_->isVisible();
    std::string error;
    if (!layoutPersistence_.save(workspaceRoot_.toStdString(), layoutState_, error) &&
        !error.empty()) {
        statusBar()->showMessage(uiText(QStringLiteral("Could not save workbench layout: ")) +
                                     fromUtf8(error), 5000);
    }
}

void WorkbenchWindow::scheduleWorkbenchLayoutSave() {
    if (workspaceRoot_.isEmpty() || layoutSaveTimer_ == nullptr) return;
    layoutSaveTimer_->start();
}

void WorkbenchWindow::showToolWindow(BottomToolKind kind) {
    if (toolWindow_ == nullptr || editorToolSplitter_ == nullptr) return;
    layoutState_.bottomToolKind = kind;
    layoutState_.bottomVisible = true;
    toolWindow_->setKind(kind);
    toolWindow_->setVisible(true);
    const auto availableHeight = std::max(editorToolSplitter_->height(),
                                           kEditorTopMinHeight + kBottomToolMinHeight);
    const auto normalized = normalizeWorkbenchLayout(
        layoutState_, editorToolSplitter_->width(), availableHeight);
    layoutState_.editorTopHeight = normalized.editorTopHeight;
    editorToolSplitter_->setSizes({layoutState_.editorTopHeight,
                                   availableHeight - layoutState_.editorTopHeight});
    scheduleWorkbenchLayoutSave();
}

bool WorkbenchWindow::eventFilter(QObject* watched, QEvent* event) {
    (void)watched;
    if (event != nullptr && event->type() == QEvent::KeyPress) {
        const auto* keyEvent = static_cast<QKeyEvent*>(event);
        if (keyEvent->key() == Qt::Key_Shift && !keyEvent->isAutoRepeat()) {
            const auto now = std::chrono::steady_clock::now();
            const auto elapsed = lastShiftPress_ == std::chrono::steady_clock::time_point{}
                ? std::chrono::milliseconds::max()
                : std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - lastShiftPress_);
            lastShiftPress_ = now;
            if (elapsed <= std::chrono::milliseconds(350) &&
                !workspaceRoot_.isEmpty() &&
                (searchEverywhereDialog_ == nullptr ||
                 !searchEverywhereDialog_->isVisible())) {
                showSearchEverywhere();
            }
        }
    }
    return QMainWindow::eventFilter(watched, event);
}

void WorkbenchWindow::buildActions() {
    auto* toolbar = addToolBar(uiText(QStringLiteral("Workspace")));
    auto* open = toolbar->addAction(uiText(QStringLiteral("Open")));
    open->setShortcut(QKeySequence::Open);
    connect(open, &QAction::triggered, this, &WorkbenchWindow::chooseWorkspace);
    auto* refresh = toolbar->addAction(uiText(QStringLiteral("Refresh")));
    connect(refresh, &QAction::triggered, this, &WorkbenchWindow::refreshWorkspace);
    auto* save = toolbar->addAction(uiText(QStringLiteral("Save")));
    save->setShortcut(QKeySequence::Save);
    connect(save, &QAction::triggered, this, &WorkbenchWindow::saveDocument);

    auto* fileMenu = menuBar()->addMenu(uiText(QStringLiteral("File")));
    fileMenu->addAction(open);
    fileMenu->addAction(save);
    fileMenu->addAction(refresh);
    auto* welcome = fileMenu->addAction(uiText(QStringLiteral("Welcome / Switch Workspace")));
    connect(welcome, &QAction::triggered, this, &WorkbenchWindow::showWelcomeDialog);
    auto* markdownPreview = fileMenu->addAction(uiText(QStringLiteral("Preview Markdown")));
    connect(markdownPreview, &QAction::triggered, this, &WorkbenchWindow::showMarkdownPreview);

    auto* searchMenu = menuBar()->addMenu(uiText(QStringLiteral("Search")));
    auto* find = searchMenu->addAction(uiText(QStringLiteral("Find in Editor")));
    find->setShortcut(QKeySequence::Find);
    connect(find, &QAction::triggered, this, &WorkbenchWindow::showFindBar);
    auto* everywhere = searchMenu->addAction(uiText(QStringLiteral("Search Everywhere...")));
    everywhere->setShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_E));
    connect(everywhere, &QAction::triggered, this, &WorkbenchWindow::showSearchEverywhere);

    auto* gitMenu = menuBar()->addMenu(uiText(QStringLiteral("Git")));
    auto* blame = gitMenu->addAction(uiText(QStringLiteral("Toggle Blame")));
    connect(blame, &QAction::triggered, this, &WorkbenchWindow::toggleBlame);
    gitMenu->addSeparator();
    auto* gitLog = gitMenu->addAction(uiText(QStringLiteral("Git Log")));
    connect(gitLog, &QAction::triggered, this, &WorkbenchWindow::loadGitHistory);
    auto* gitStashes = gitMenu->addAction(uiText(QStringLiteral("Stashes")));
    connect(gitStashes, &QAction::triggered, this, &WorkbenchWindow::loadGitStashes);
    auto* gitCompare = gitMenu->addAction(uiText(QStringLiteral("Compare Reference...")));
    connect(gitCompare, &QAction::triggered, this, &WorkbenchWindow::compareGitReference);
    auto* switchBranch = gitMenu->addAction(uiText(QStringLiteral("Switch Branch...")));
    connect(switchBranch, &QAction::triggered, this, &WorkbenchWindow::switchGitReference);
    auto* createBranch = gitMenu->addAction(uiText(QStringLiteral("New Branch...")));
    connect(createBranch, &QAction::triggered, this, &WorkbenchWindow::createGitBranch);

    auto* mavenMenu = menuBar()->addMenu(uiText(QStringLiteral("Maven")));
    for (const auto& phase : {QStringLiteral("clean"), QStringLiteral("test"),
                              QStringLiteral("package"), QStringLiteral("verify")}) {
        auto* action = mavenMenu->addAction(phase);
        connect(action, &QAction::triggered, this, [this, phase] {
            runMavenPhase(phase);
        });
    }
    auto* stop = mavenMenu->addAction(uiText(QStringLiteral("Stop")));
    connect(stop, &QAction::triggered, this, &WorkbenchWindow::stopMavenBuild);

    auto* runMenu = menuBar()->addMenu(uiText(QStringLiteral("Run")));
    auto* runJava = runMenu->addAction(uiText(QStringLiteral("Run Current Java File")));
    connect(runJava, &QAction::triggered, this, &WorkbenchWindow::runCurrentJava);
    auto* runSpring = runMenu->addAction(uiText(QStringLiteral("Run Spring Boot")));
    connect(runSpring, &QAction::triggered, this, &WorkbenchWindow::runSpringBoot);
    auto* stopJava = runMenu->addAction(uiText(QStringLiteral("Stop Java")));
    connect(stopJava, &QAction::triggered, this, &WorkbenchWindow::stopJavaRun);
    auto* definition = runMenu->addAction(uiText(QStringLiteral("Go to Java Definition")));
    definition->setShortcut(QKeySequence(Qt::CTRL | Qt::Key_B));
    connect(definition, &QAction::triggered, this, &WorkbenchWindow::gotoJavaDefinition);
    auto* usages = runMenu->addAction(uiText(QStringLiteral("Find Java Usages")));
    usages->setShortcut(QKeySequence(Qt::ALT | Qt::Key_F7));
    connect(usages, &QAction::triggered, this, &WorkbenchWindow::findJavaUsages);

    auto* debugMenu = menuBar()->addMenu(uiText(QStringLiteral("Debug")));
    auto* debugJava = debugMenu->addAction(uiText(QStringLiteral("Debug Current Java File")));
    connect(debugJava, &QAction::triggered, this, &WorkbenchWindow::debugCurrentJava);
    auto* debugSpring = debugMenu->addAction(uiText(QStringLiteral("Debug Spring Boot")));
    connect(debugSpring, &QAction::triggered, this, &WorkbenchWindow::debugSpringBoot);
    auto* attach = debugMenu->addAction(uiText(QStringLiteral("Attach to JDWP...")));
    connect(attach, &QAction::triggered, this, &WorkbenchWindow::attachRemoteDebugger);
    debugMenu->addSeparator();
    auto* toggle = debugMenu->addAction(uiText(QStringLiteral("Toggle Breakpoint")));
    toggle->setShortcut(QKeySequence(Qt::Key_F9));
    connect(toggle, &QAction::triggered, this, &WorkbenchWindow::toggleBreakpoint);
    auto* continueAction = debugMenu->addAction(uiText(QStringLiteral("Continue")));
    continueAction->setShortcut(QKeySequence(Qt::Key_F5));
    connect(continueAction, &QAction::triggered, this, &WorkbenchWindow::continueDebugger);
    auto* pauseAction = debugMenu->addAction(uiText(QStringLiteral("Pause")));
    connect(pauseAction, &QAction::triggered, this, &WorkbenchWindow::pauseDebugger);
    auto* stepInto = debugMenu->addAction(uiText(QStringLiteral("Step Into")));
    stepInto->setShortcut(QKeySequence(Qt::Key_F7));
    connect(stepInto, &QAction::triggered, this, &WorkbenchWindow::stepIntoDebugger);
    auto* stepOver = debugMenu->addAction(uiText(QStringLiteral("Step Over")));
    stepOver->setShortcut(QKeySequence(Qt::Key_F8));
    connect(stepOver, &QAction::triggered, this, &WorkbenchWindow::stepOverDebugger);
    auto* stepOut = debugMenu->addAction(uiText(QStringLiteral("Step Out")));
    connect(stepOut, &QAction::triggered, this, &WorkbenchWindow::stepOutDebugger);
    auto* stopDebuggerAction = debugMenu->addAction(uiText(QStringLiteral("Stop Debugger")));
    connect(stopDebuggerAction, &QAction::triggered, this, &WorkbenchWindow::stopDebugger);

    auto* terminalMenu = menuBar()->addMenu(uiText(QStringLiteral("Terminal")));
    auto* openTerminal = terminalMenu->addAction(uiText(QStringLiteral("Open Terminal")));
    connect(openTerminal, &QAction::triggered, this, &WorkbenchWindow::startTerminal);
    auto* stopTerminalAction = terminalMenu->addAction(uiText(QStringLiteral("Stop Terminal")));
    connect(stopTerminalAction, &QAction::triggered, this, &WorkbenchWindow::stopTerminal);

    auto* toolsMenu = menuBar()->addMenu(uiText(QStringLiteral("Tools")));
    auto* commandPalette = toolsMenu->addAction(uiText(QStringLiteral("Command Palette...")));
    commandPalette->setShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_P));
    connect(commandPalette, &QAction::triggered, this, &WorkbenchWindow::showCommandPalette);
    auto* settings = toolsMenu->addAction(uiText(QStringLiteral("Settings...")));
    connect(settings, &QAction::triggered, this, &WorkbenchWindow::showSettings);
    toolsMenu->addSeparator();
    auto* aiMessage = toolsMenu->addAction(uiText(QStringLiteral("Generate AI Commit Message")));
    connect(aiMessage, &QAction::triggered,
            this, &WorkbenchWindow::generateAICommitMessage);
    auto* update = toolsMenu->addAction(uiText(QStringLiteral("Check for Updates")));
    connect(update, &QAction::triggered, this, &WorkbenchWindow::checkForUpdates);
}

void WorkbenchWindow::showSettings() {
    QDialog dialog(this);
    dialog.setWindowTitle(uiText(QStringLiteral("Settings")));
    dialog.resize(680, 500);
    auto* outer = new QVBoxLayout(&dialog);
    auto* tabs = new QTabWidget(&dialog);
    outer->addWidget(tabs, 1);

    const auto joinValues = [](const std::vector<std::string>& values) {
        QStringList result;
        for (const auto& value : values) result.push_back(fromUtf8(value));
        return result.join(QStringLiteral(", "));
    };

    auto* general = new QWidget(tabs);
    auto* generalLayout = new QVBoxLayout(general);
    generalLayout->addWidget(new QLabel(
        uiText(QStringLiteral("Windows-specific preferences for the Lithe workbench.")), general));
    auto* generalForm = new QFormLayout();
    generalForm->addRow(uiText(QStringLiteral("Workspace")),
                        new QLabel(workspaceRoot_.isEmpty()
                                       ? uiText(QStringLiteral("No workspace open")) : workspaceRoot_,
                                   general));
    generalForm->addRow(uiText(QStringLiteral("Rust Core")),
                        new QLabel(fromUtf8(coordinator_->coreVersion()), general));
    auto* language = new QComboBox(general);
    language->addItem(uiText(QStringLiteral("System default")), QStringLiteral("system"));
    language->addItem(uiText(QStringLiteral("English")), QStringLiteral("en"));
    language->addItem(uiText(QStringLiteral("Simplified Chinese")), QStringLiteral("zh_CN"));
    const auto configuredLanguage = QString::fromStdString(
        app::normalizeUiLanguage(appSettings_.uiLanguage));
    const auto languageIndex = language->findData(configuredLanguage);
    language->setCurrentIndex(languageIndex < 0 ? 0 : languageIndex);
    generalForm->addRow(uiText(QStringLiteral("Interface language")), language);
    auto* dataDirectory = new QLineEdit(general);
    dataDirectory->setText(fromUtf8(appSettings_.dataDirectory));
    dataDirectory->setPlaceholderText(uiText(QStringLiteral("Leave empty for the system default")));
    dataDirectory->setToolTip(
        uiText(QStringLiteral("Logs, shelves, and other data files are stored under this folder. "
                              "Restart Lithe to apply.")));
    generalForm->addRow(uiText(QStringLiteral("Data directory")), dataDirectory);
    generalLayout->addLayout(generalForm);
    generalLayout->addStretch(1);
    tabs->addTab(general, uiText(QStringLiteral("General")));

    auto* editorPage = new QWidget(tabs);
    auto* editorForm = new QFormLayout(editorPage);
    auto* fontSize = new QDoubleSpinBox(editorPage);
    fontSize->setRange(9.0, 32.0);
    fontSize->setSingleStep(0.5);
    fontSize->setDecimals(1);
    fontSize->setValue(appSettings_.editorFontSize);
    auto* codeVision = new QCheckBox(uiText(QStringLiteral("Show code vision and implementation markers")),
                                     editorPage);
    codeVision->setChecked(appSettings_.showCodeVision);
    auto* inlayHints = new QCheckBox(uiText(QStringLiteral("Show Java inlay hints")), editorPage);
    inlayHints->setChecked(appSettings_.showInlayHints);
    editorForm->addRow(uiText(QStringLiteral("Editor font size")), fontSize);
    editorForm->addRow(codeVision);
    editorForm->addRow(inlayHints);
    tabs->addTab(editorPage, uiText(QStringLiteral("Editor")));

    auto* projectPage = new QWidget(tabs);
    auto* projectForm = new QFormLayout(projectPage);
    auto* hiddenDirectories = new QLineEdit(projectPage);
    hiddenDirectories->setText(joinValues(appSettings_.hiddenDirectoryNames));
    hiddenDirectories->setPlaceholderText(uiText(QStringLiteral(".git, build, target")));
    auto* hiddenFiles = new QLineEdit(projectPage);
    hiddenFiles->setText(joinValues(appSettings_.hiddenFilePatterns));
    hiddenFiles->setPlaceholderText(uiText(QStringLiteral(".DS_Store, *.class")));
    projectForm->addRow(uiText(QStringLiteral("Hidden directories")), hiddenDirectories);
    projectForm->addRow(uiText(QStringLiteral("Hidden file patterns")), hiddenFiles);
    projectForm->addRow(new QLabel(
        uiText(QStringLiteral("Values are comma-separated and apply after the workspace is refreshed.")),
        projectPage));
    tabs->addTab(projectPage, uiText(QStringLiteral("Project")));

    auto* terminalPage = new QWidget(tabs);
    auto* terminalForm = new QFormLayout(terminalPage);
    auto* shellPath = new QLineEdit(terminalPage);
    shellPath->setText(fromUtf8(appSettings_.terminalShellPath));
    shellPath->setPlaceholderText(uiText(QStringLiteral("Automatic: ComSpec or cmd.exe")));
    terminalForm->addRow(uiText(QStringLiteral("Shell executable")), shellPath);
    tabs->addTab(terminalPage, uiText(QStringLiteral("Terminal")));

    auto* aiPage = new QWidget(tabs);
    auto* aiLayout = new QVBoxLayout(aiPage);
    auto* aiStatus = new QLabel(aiPage);
    aiStatus->setWordWrap(true);
    const auto updateAIStatus = [this, aiStatus] {
        const auto settings = loadAISettings();
        if (settings.providers.empty()) {
            aiStatus->setText(uiText(QStringLiteral("No AI commit-message provider configured.")));
        } else {
            aiStatus->setText(uiText(QStringLiteral("Provider: %1  Model: %2"))
                                  .arg(fromUtf8(settings.providers.front().name))
                                  .arg(fromUtf8(settings.providers.front().model)));
        }
    };
    updateAIStatus();
    aiLayout->addWidget(aiStatus);
    auto* configureAI = new QPushButton(uiText(QStringLiteral("Configure AI commit messages...")), aiPage);
    aiLayout->addWidget(configureAI);
    connect(configureAI, &QPushButton::clicked, this, [this, updateAIStatus] {
        if (configureAISettings()) updateAIStatus();
    });
    aiLayout->addStretch(1);
    tabs->addTab(aiPage, uiText(QStringLiteral("AI & Commit")));

    auto* updatesPage = new QWidget(tabs);
    auto* updatesLayout = new QVBoxLayout(updatesPage);
    auto* updatesInfo = new QLabel(
        uiText(QStringLiteral("Windows releases are checked on GitHub and downloaded only after "
                       "SHA-256 and Authenticode verification.")), updatesPage);
    updatesInfo->setWordWrap(true);
    updatesLayout->addWidget(updatesInfo);
    auto* checkUpdates = new QPushButton(uiText(QStringLiteral("Check for updates")), updatesPage);
    updatesLayout->addWidget(checkUpdates);
    connect(checkUpdates, &QPushButton::clicked, this, &WorkbenchWindow::checkForUpdates);
    updatesLayout->addStretch(1);
    tabs->addTab(updatesPage, uiText(QStringLiteral("Updates")));

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel,
                                         &dialog);
    if (auto* ok = buttons->button(QDialogButtonBox::Ok)) {
        ok->setText(uiText(QStringLiteral("OK")));
    }
    if (auto* cancel = buttons->button(QDialogButtonBox::Cancel)) {
        cancel->setText(uiText(QStringLiteral("Cancel")));
    }
    outer->addWidget(buttons);
    connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    if (dialog.exec() != QDialog::Accepted) return;

    const auto splitValues = [](const QString& text) {
        std::vector<std::string> result;
        for (const auto& value : text.split(',', Qt::SkipEmptyParts)) {
            const auto trimmed = value.trimmed();
            if (!trimmed.isEmpty()) result.push_back(trimmed.toUtf8().toStdString());
        }
        return result;
    };
    app::AppSettings next = appSettings_;
    next.editorFontSize = fontSize->value();
    next.showCodeVision = codeVision->isChecked();
    next.showInlayHints = inlayHints->isChecked();
    next.uiLanguage = language->currentData().toString().toStdString();
    next.dataDirectory = dataDirectory->text().trimmed().toStdString();
    next.hiddenDirectoryNames = splitValues(hiddenDirectories->text());
    next.hiddenFilePatterns = splitValues(hiddenFiles->text());
    next.terminalShellPath = shellPath->text().trimmed().toUtf8().toStdString();
    std::string error;
    if (!appSettingsStore_.save(next, error)) {
        statusBar()->showMessage(uiText(QStringLiteral("Could not save settings: ")) + fromUtf8(error),
                                 6000);
        return;
    }
    appSettings_ = std::move(next);
    auto font = editor_->font();
    font.setPointSizeF(appSettings_.editorFontSize);
    editor_->setFont(font);
    coordinator_->setWorkspaceVisibility(appSettings_.hiddenDirectoryNames,
                                          appSettings_.hiddenFilePatterns);
    historyFeature_->setVisibilityRules(appSettings_.hiddenDirectoryNames,
                                         appSettings_.hiddenFilePatterns);
    if (activePath_.endsWith(QStringLiteral(".java"), Qt::CaseInsensitive)) {
        applyMavenJavaState(mavenJavaFeature_->state(), true, true);
    }
    if (!workspaceRoot_.isEmpty()) loadSnapshot();
    if (effectiveUiLanguage(appSettings_.uiLanguage) !=
            effectiveUiLanguage(configuredLanguage.toStdString()) ||
        app::normalizeDataDirectory(appSettings_.dataDirectory) !=
            app::normalizeDataDirectory(next.dataDirectory)) {
        statusBar()->showMessage(
            uiText(QStringLiteral("Restart Lithe to apply the interface language or data directory.")),
            5000);
    } else {
        statusBar()->showMessage(uiText(QStringLiteral("Settings saved")), 3000);
    }
}

void WorkbenchWindow::showCommandPalette() {
    struct Command {
        QString title;
        std::function<void()> action;
    };
    const std::vector<Command> commands{
        {uiText(QStringLiteral("Open Workspace")), [this] { chooseWorkspace(); }},
        {uiText(QStringLiteral("Welcome / Switch Workspace")), [this] { showWelcomeDialog(); }},
        {uiText(QStringLiteral("Refresh Workspace")), [this] { refreshWorkspace(); }},
        {uiText(QStringLiteral("Save Document")), [this] { saveDocument(); }},
        {uiText(QStringLiteral("Find in Editor")), [this] { showFindBar(); }},
        {uiText(QStringLiteral("Preview Markdown")), [this] { showMarkdownPreview(); }},
        {uiText(QStringLiteral("Search Workspace")), [this] { searchWorkspace(); }},
        {uiText(QStringLiteral("Search Everywhere")), [this] { showSearchEverywhere(); }},
        {uiText(QStringLiteral("Git Log")), [this] { loadGitHistory(); }},
        {uiText(QStringLiteral("Git Stashes")), [this] { loadGitStashes(); }},
        {uiText(QStringLiteral("Compare Git Reference")), [this] { compareGitReference(); }},
        {uiText(QStringLiteral("Switch Git Branch")), [this] { switchGitReference(); }},
        {uiText(QStringLiteral("Create Git Branch")), [this] { createGitBranch(); }},
        {uiText(QStringLiteral("Stage All Changes")), [this] { stageAllChanges(); }},
        {uiText(QStringLiteral("Commit Changes")), [this] { commitChanges(); }},
        {uiText(QStringLiteral("Generate AI Commit Message")), [this] { generateAICommitMessage(); }},
        {uiText(QStringLiteral("Run Current Java File")), [this] { runCurrentJava(); }},
        {uiText(QStringLiteral("Run Spring Boot")), [this] { runSpringBoot(); }},
        {uiText(QStringLiteral("Stop Java")), [this] { stopJavaRun(); }},
        {uiText(QStringLiteral("Debug Current Java File")), [this] { debugCurrentJava(); }},
        {uiText(QStringLiteral("Stop Debugger")), [this] { stopDebugger(); }},
        {uiText(QStringLiteral("Open Terminal")), [this] { startTerminal(); }},
        {uiText(QStringLiteral("Stop Terminal")), [this] { stopTerminal(); }},
        {uiText(QStringLiteral("Settings")), [this] { showSettings(); }},
        {uiText(QStringLiteral("Check for Updates")), [this] { checkForUpdates(); }},
    };

    QDialog dialog(this);
    dialog.setWindowTitle(uiText(QStringLiteral("Command Palette")));
    dialog.resize(620, 420);
    auto* layout = new QVBoxLayout(&dialog);
    auto* input = new QLineEdit(&dialog);
    input->setPlaceholderText(uiText(QStringLiteral("Type a command")));
    layout->addWidget(input);
    auto* list = new QListWidget(&dialog);
    list->setSelectionMode(QAbstractItemView::SingleSelection);
    layout->addWidget(list, 1);

    const auto render = [input, list, &commands] {
        list->clear();
        const auto query = input->text().trimmed();
        for (std::size_t index = 0; index < commands.size(); ++index) {
            if (!query.isEmpty() &&
                !commands[index].title.contains(query, Qt::CaseInsensitive)) continue;
            auto* item = new QListWidgetItem(commands[index].title, list);
            item->setData(Qt::UserRole, static_cast<int>(index));
        }
        if (list->count() > 0) list->setCurrentRow(0);
    };
    const auto triggerCurrent = [&dialog, list, &commands] {
        auto* item = list->currentItem();
        if (item == nullptr && list->count() > 0) item = list->item(0);
        if (item == nullptr) return;
        const auto index = item->data(Qt::UserRole).toInt();
        if (index < 0 || index >= static_cast<int>(commands.size())) return;
        const auto action = commands[static_cast<std::size_t>(index)].action;
        dialog.accept();
        action();
    };
    connect(input, &QLineEdit::textChanged, &dialog, render);
    connect(input, &QLineEdit::returnPressed, &dialog, triggerCurrent);
    connect(list, &QListWidget::itemDoubleClicked, &dialog,
            [&triggerCurrent](QListWidgetItem*) { triggerCurrent(); });
    render();
    input->setFocus();
    dialog.exec();
}

void WorkbenchWindow::showWelcomeDialog() {
    QDialog dialog(this);
    dialog.setWindowTitle(uiText(QStringLiteral("Welcome to Lithe")));
    dialog.resize(760, 520);
    auto* outer = new QVBoxLayout(&dialog);

    auto* title = new QLabel(uiText(QStringLiteral("Welcome to Lithe")), &dialog);
    auto titleFont = title->font();
    titleFont.setPointSize(titleFont.pointSize() + 4);
    titleFont.setBold(true);
    title->setFont(titleFont);
    outer->addWidget(title);
    outer->addWidget(new QLabel(
        uiText(QStringLiteral("Open a recent project, choose a folder, or clone a repository.")),
        &dialog));

    auto* filter = new QLineEdit(&dialog);
    filter->setPlaceholderText(uiText(QStringLiteral("Search recent projects")));
    outer->addWidget(filter);
    auto* projects = new QListWidget(&dialog);
    projects->setSelectionMode(QAbstractItemView::SingleSelection);
    projects->setMinimumHeight(260);
    outer->addWidget(projects, 1);

    const auto recent = recentProjectsStore_.load();
    for (const auto& path : recent) {
        const auto root = QString::fromUtf8(path.data(), static_cast<qsizetype>(path.size()));
        auto* item = new QListWidgetItem(
            QFileInfo(root).fileName().isEmpty() ? root : QFileInfo(root).fileName(), projects);
        item->setData(Qt::UserRole, root);
        item->setToolTip(root);
        if (!QFileInfo(root).isDir()) {
            item->setText(item->text() + QStringLiteral("  (missing)"));
            item->setFlags(item->flags() & ~Qt::ItemIsEnabled);
        }
    }
    if (projects->count() == 0) {
        auto* item = new QListWidgetItem(uiText(QStringLiteral("No recent projects")), projects);
        item->setFlags(item->flags() & ~Qt::ItemIsEnabled);
    } else {
        projects->setCurrentRow(0);
    }

    connect(filter, &QLineEdit::textChanged, &dialog, [filter, projects] {
        const auto query = filter->text().trimmed();
        for (int index = 0; index < projects->count(); ++index) {
            auto* item = projects->item(index);
            item->setHidden(!query.isEmpty() &&
                            !item->toolTip().contains(query, Qt::CaseInsensitive) &&
                            !item->text().contains(query, Qt::CaseInsensitive));
        }
    });

    auto* status = new QLabel(&dialog);
    status->setWordWrap(true);
    outer->addWidget(status);
    auto* buttons = new QHBoxLayout();
    auto* openSelected = new QPushButton(uiText(QStringLiteral("Open Selected")), &dialog);
    auto* openFolder = new QPushButton(uiText(QStringLiteral("Open Folder...")), &dialog);
    auto* clone = new QPushButton(uiText(QStringLiteral("Clone...")), &dialog);
    auto* settings = new QPushButton(uiText(QStringLiteral("Settings...")), &dialog);
    auto* reveal = new QPushButton(uiText(QStringLiteral("Show in Explorer")), &dialog);
    auto* cancel = new QPushButton(uiText(QStringLiteral("Close")), &dialog);
    buttons->addWidget(openSelected);
    buttons->addWidget(openFolder);
    buttons->addWidget(clone);
    buttons->addStretch(1);
    buttons->addWidget(settings);
    buttons->addWidget(reveal);
    buttons->addWidget(cancel);
    outer->addLayout(buttons);

    const auto selectedRoot = [projects] {
        auto* item = projects->currentItem();
        return item == nullptr ? QString() : item->data(Qt::UserRole).toString();
    };
    const auto openRoot = [this, &dialog, selectedRoot, status] {
        const auto root = selectedRoot();
        if (root.isEmpty() || !QFileInfo(root).isDir()) {
            status->setText(QStringLiteral("Select an existing project first."));
            return;
        }
        dialog.accept();
        openWorkspaceRoot(root);
    };
    connect(openSelected, &QPushButton::clicked, &dialog, openRoot);
    connect(projects, &QListWidget::itemDoubleClicked, &dialog,
            [openRoot](QListWidgetItem*) { openRoot(); });
    connect(openFolder, &QPushButton::clicked, &dialog, [this, &dialog] {
        ProjectImportDialog import(*storage_, runtimeService_, &dialog);
        const auto selection = import.run(workspaceRoot_);
        if (!selection) return;
        dialog.accept();
        openWorkspaceRoot(fromUtf8(selection->workspaceRoot));
    });
    connect(clone, &QPushButton::clicked, &dialog, [this, &dialog] {
        dialog.accept();
        showCloneRepositoryDialog();
    });
    connect(settings, &QPushButton::clicked, &dialog, [this] { showSettings(); });
    connect(reveal, &QPushButton::clicked, &dialog, [selectedRoot, status] {
        const auto root = selectedRoot();
        if (root.isEmpty() || !QFileInfo(root).isDir()) {
            status->setText(QStringLiteral("Select an existing project first."));
            return;
        }
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(root).absoluteFilePath()));
    });
    connect(cancel, &QPushButton::clicked, &dialog, &QDialog::reject);
    dialog.exec();
}

void WorkbenchWindow::showCloneRepositoryDialog() {
    QDialog dialog(this);
    dialog.setWindowTitle(QStringLiteral("Clone Repository"));
    dialog.resize(620, 360);
    auto* outer = new QVBoxLayout(&dialog);
    auto* form = new QFormLayout();
    auto* remote = new QLineEdit(&dialog);
    remote->setPlaceholderText(QStringLiteral("https://github.com/example/project.git"));
    auto* parentFolder = new QLineEdit(QDir::homePath(), &dialog);
    auto* chooseParent = new QPushButton(QStringLiteral("Choose..."), &dialog);
    auto* parentRow = new QWidget(&dialog);
    auto* parentLayout = new QHBoxLayout(parentRow);
    parentLayout->setContentsMargins(0, 0, 0, 0);
    parentLayout->addWidget(parentFolder, 1);
    parentLayout->addWidget(chooseParent);
    auto* folderName = new QLineEdit(&dialog);
    folderName->setPlaceholderText(QStringLiteral("project-name"));
    form->addRow(QStringLiteral("Repository URL"), remote);
    form->addRow(QStringLiteral("Parent folder"), parentRow);
    form->addRow(QStringLiteral("Folder name"), folderName);
    outer->addLayout(form);
    auto* destination = new QLabel(&dialog);
    destination->setWordWrap(true);
    outer->addWidget(destination);
    auto* status = new QLabel(&dialog);
    status->setWordWrap(true);
    outer->addWidget(status);
    outer->addStretch(1);

    auto updateDestination = [parentFolder, folderName, destination] {
        const auto folder = folderName->text().trimmed();
        const auto path = folder.isEmpty()
            ? QString()
            : QDir(parentFolder->text().trimmed()).filePath(folder);
        destination->setText(path.isEmpty()
                                 ? QStringLiteral("Choose a destination folder.")
                                 : QStringLiteral("Destination: %1").arg(path));
    };
    const auto defaultFolderName = [](QString value) {
        value = QDir::fromNativeSeparators(value.trimmed());
        while (value.endsWith('/')) value.chop(1);
        const auto slash = value.lastIndexOf('/');
        if (slash >= 0) value = value.mid(slash + 1);
        if (value.endsWith(QStringLiteral(".git"), Qt::CaseInsensitive)) value.chop(4);
        return value.isEmpty() ? QStringLiteral("project") : value;
    };
    connect(remote, &QLineEdit::textChanged, &dialog,
            [folderName, defaultFolderName, updateDestination](const QString& value) mutable {
        if (folderName->text().trimmed().isEmpty()) folderName->setText(defaultFolderName(value));
        updateDestination();
    });
    connect(parentFolder, &QLineEdit::textChanged, &dialog,
            [updateDestination](const QString&) mutable { updateDestination(); });
    connect(folderName, &QLineEdit::textChanged, &dialog,
            [updateDestination](const QString&) mutable { updateDestination(); });
    connect(chooseParent, &QPushButton::clicked, &dialog, [parentFolder, &dialog] {
        const auto selected = QFileDialog::getExistingDirectory(
            &dialog, QStringLiteral("Choose Parent Folder"), parentFolder->text());
        if (!selected.isEmpty()) parentFolder->setText(selected);
    });

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dialog);
    buttons->button(QDialogButtonBox::Ok)->setText(QStringLiteral("Clone"));
    outer->addWidget(buttons);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    const QPointer<QDialog> dialogPointer(&dialog);
    const QPointer<QLabel> statusPointer(status);
    const QPointer<QPushButton> cloneButton(buttons->button(QDialogButtonBox::Ok));
    connect(buttons, &QDialogButtonBox::accepted, &dialog,
        [this, &dialog, dialogPointer, statusPointer, cloneButton,
             remote, parentFolder, folderName] {
        const auto remoteValue = remote->text().trimmed();
        const auto parentText = parentFolder->text().trimmed();
        const auto parentValue = parentText.isEmpty()
            ? QString() : QFileInfo(parentText).absoluteFilePath();
        const auto folderValue = QDir::fromNativeSeparators(folderName->text().trimmed());
        const auto invalidFolderName = folderValue.isEmpty() || folderValue == QStringLiteral(".") ||
            folderValue == QStringLiteral("..") ||
            QFileInfo(folderValue).fileName() != folderValue;
        if (remoteValue.isEmpty() || parentValue.isEmpty()) {
            if (statusPointer) statusPointer->setText(
                QStringLiteral("Repository and parent folder are required."));
            return;
        }
        if (invalidFolderName) {
            if (statusPointer) statusPointer->setText(
                QStringLiteral("Folder name must be a single directory name."));
            return;
        }
        if (!QFileInfo(parentValue).isDir()) {
            if (statusPointer) statusPointer->setText(QStringLiteral("The parent folder must exist."));
            return;
        }
        const auto destinationValue = QDir(parentValue).filePath(folderValue);
        if (QFileInfo(destinationValue).exists()) {
            if (statusPointer) statusPointer->setText(QStringLiteral("The destination already exists."));
            return;
        }
        if (cloneButton) cloneButton->setEnabled(false);
        if (statusPointer) statusPointer->setText(QStringLiteral("Cloning repository..."));
        const auto parentUtf8 = pathUtf8(std::filesystem::path(parentValue.toStdWString()));
        const auto destinationUtf8 = pathUtf8(std::filesystem::path(destinationValue.toStdWString()));
        gitFeature_->cloneRepository(remoteValue.toUtf8().toStdString(), destinationUtf8,
                                     parentUtf8,
            [this, dialogPointer, statusPointer, cloneButton, destinationValue](
                app::GitFeatureState state) {
            QMetaObject::invokeMethod(this, [this, dialogPointer, statusPointer, cloneButton,
                                              destinationValue, state = std::move(state)]() mutable {
                if (!dialogPointer) return;
                if (state.error) {
                    if (cloneButton) cloneButton->setEnabled(true);
                    if (statusPointer) {
                        statusPointer->setText(QStringLiteral("Clone failed: ") +
                                               fromUtf8(state.error->message));
                    }
                    return;
                }
                if (state.isWriting) return;
                dialogPointer->accept();
                openWorkspaceRoot(destinationValue);
            }, Qt::QueuedConnection);
        });
    });
    updateDestination();
    remote->setFocus();
    dialog.exec();
}

void WorkbenchWindow::showFindBar() {
    if (findBar_ == nullptr || findField_ == nullptr || editor_ == nullptr) return;
    const auto selected = editor_->textCursor().selectedText();
    if (!selected.isEmpty() && !selected.contains(QChar::ParagraphSeparator)) {
        findField_->setText(selected);
    }
    findBar_->setVisible(true);
    findField_->selectAll();
    findField_->setFocus();
    updateFindHighlights();
}

void WorkbenchWindow::hideFindBar() {
    if (findBar_ != nullptr) findBar_->setVisible(false);
    if (findField_ != nullptr) findField_->clear();
    if (findStatus_ != nullptr) findStatus_->clear();
    if (editor_ != nullptr) editor_->setExtraSelections({});
    if (editor_ != nullptr) editor_->setFocus();
}

void WorkbenchWindow::findNext() {
    findInEditor(true);
}

void WorkbenchWindow::findPrevious() {
    findInEditor(false);
}

void WorkbenchWindow::findInEditor(bool forward) {
    if (editor_ == nullptr || findField_ == nullptr) return;
    const auto query = findField_->text();
    if (query.isEmpty()) return;

    auto cursor = editor_->textCursor();
    if (cursor.hasSelection()) {
        cursor.setPosition(forward ? cursor.selectionEnd() : cursor.selectionStart());
    }
    QTextDocument::FindFlags flags;
    if (!forward) flags |= QTextDocument::FindBackward;
    auto match = editor_->document()->find(query, cursor, flags);
    if (match.isNull()) {
        QTextCursor wrapped(editor_->document());
        wrapped.setPosition(forward ? 0 : editor_->document()->characterCount() - 1);
        match = editor_->document()->find(query, wrapped, flags);
    }
    if (!match.isNull()) {
        editor_->setTextCursor(match);
        editor_->ensureCursorVisible();
    }
    updateFindHighlights();
}

void WorkbenchWindow::updateFindHighlights() {
    if (editor_ == nullptr || findField_ == nullptr || findBar_ == nullptr ||
        !findBar_->isVisible()) return;
    const auto query = findField_->text();
    QList<QTextEdit::ExtraSelection> selections;
    if (query.isEmpty()) {
        editor_->setExtraSelections(selections);
        if (findStatus_ != nullptr) findStatus_->clear();
        return;
    }

    QTextCharFormat format;
    format.setBackground(QColor(255, 232, 135));
    format.setForeground(QColor(32, 32, 32));
    QTextCursor search(editor_->document());
    while (true) {
        const auto match = editor_->document()->find(query, search);
        if (match.isNull()) break;
        selections.push_back({match, format});
        search.setPosition(match.selectionEnd());
    }
    editor_->setExtraSelections(selections);
    if (findStatus_ != nullptr) {
        findStatus_->setText(selections.empty()
                                 ? QStringLiteral("No matches")
                                 : QStringLiteral("%1 matches").arg(selections.size()));
    }
}

void WorkbenchWindow::showMarkdownPreview() {
    if (editor_ == nullptr || activePath_.isEmpty() ||
        (!activePath_.endsWith(QStringLiteral(".md"), Qt::CaseInsensitive) &&
         !activePath_.endsWith(QStringLiteral(".markdown"), Qt::CaseInsensitive))) {
        statusBar()->showMessage(uiText(QStringLiteral("Open a Markdown file before previewing it")), 5000);
        return;
    }

    QDialog dialog(this);
    dialog.setWindowTitle(QStringLiteral("Markdown Preview - ") + activePath_);
    dialog.resize(900, 680);
    auto* layout = new QVBoxLayout(&dialog);
    auto* preview = new QTextBrowser(&dialog);
    preview->setOpenExternalLinks(true);
    preview->setMarkdown(editor_->toPlainText());
    layout->addWidget(preview, 1);
    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Close, &dialog);
    layout->addWidget(buttons);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    dialog.exec();
}

void WorkbenchWindow::chooseWorkspace() {
    ProjectImportDialog dialog(*storage_, runtimeService_, this);
    const auto selection = dialog.run(workspaceRoot_);
    if (selection) openWorkspaceRoot(fromUtf8(selection->workspaceRoot));
}

void WorkbenchWindow::restoreRecentWorkspace() {
    for (const auto& path : recentProjectsStore_.load()) {
        const auto root = QString::fromUtf8(path.data(), static_cast<qsizetype>(path.size()));
        if (!QFileInfo(root).isDir()) continue;
        openWorkspaceRoot(root);
        return;
    }
    showWelcomeDialog();
}

void WorkbenchWindow::openWorkspaceRoot(const QString& selectedRoot) {
    const auto root = QDir::cleanPath(
        QFileInfo(QDir::fromNativeSeparators(selectedRoot)).absoluteFilePath());
    if (root.isEmpty() || !QFileInfo(root).isDir()) return;
    ++workspaceEpoch_;
    coordinator_->setWorkspaceVisibility(appSettings_.hiddenDirectoryNames,
                                          appSettings_.hiddenFilePatterns);
    historyFeature_->setVisibilityRules(appSettings_.hiddenDirectoryNames,
                                         appSettings_.hiddenFilePatterns);
    closeLanguageServerDocument();
    if (languageServer_) languageServer_->stop();
    languageServerRoot_.clear();
    if (watcher_) watcher_->stop();
    saveWorkspaceSession();
    // The coordinator invalidates in-flight calls when the workspace epoch
    // changes. Clear the feature-owned loading flags at the same boundary so
    // stale completions cannot leave the next workspace showing an old
    // spinner or result.
    workspaceFeature_->resetForWorkspace();
    documentFeature_->resetForWorkspace();
    searchFeature_->resetForWorkspace();
    gitFeature_->resetForWorkspace();
    historyFeature_->resetForWorkspace();
    shelfFeature_->resetForWorkspace();
    mavenJavaFeature_->resetForWorkspace();
    workspaceRoot_ = root;
    QTimer::singleShot(0, this, &WorkbenchWindow::restoreWorkbenchLayout);
    activePath_.clear();
    selectedShelf_.clear();
    if (gitShelves_ != nullptr) {
        gitShelves_->clear();
        gitShelves_->setVisible(false);
    }
    if (gitShelfActions_ != nullptr) gitShelfActions_->setVisible(false);
    librarySourcePreview_ = false;
    if (editorTabs_ != nullptr) {
        QSignalBlocker blocker(editorTabs_);
        while (editorTabs_->count() > 0) {
            editorTabs_->removeTab(editorTabs_->count() - 1);
        }
    }
    editor_->setReadOnly(false);
    editor_->clear();
    pendingWorkspaceSession_ = workspaceSessionStore_.load(root.toStdString());
    std::string persistenceError;
    if (!recentProjectsStore_.record(root.toStdString(), persistenceError) &&
        !persistenceError.empty()) {
        statusBar()->showMessage(QString::fromUtf8(persistenceError.data(),
                                                   static_cast<qsizetype>(persistenceError.size())),
                                 5000);
    }
    if (watcher_) {
        const auto watchedRoot = workspaceRoot_;
        watcher_->start(
        watchedRoot.toStdString(),
        [this, watchedRoot](const std::vector<DirectoryChangeSource::Change>& changes) {
            QMetaObject::invokeMethod(this, [this, watchedRoot, changes] {
                if (watchedRoot != workspaceRoot_) return;
                handleDirectoryChanges(changes);
            }, Qt::QueuedConnection);
        },
        [this](const std::string& error) {
            QMetaObject::invokeMethod(this, [this, error] {
                statusBar()->showMessage(QString::fromStdString(error), 5000);
            }, Qt::QueuedConnection);
        });
    }
    workspaceFeature_->open(
        std::filesystem::path(root.toStdWString()),
        [this](app::WorkspaceFeatureState state) {
            QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                applyWorkspaceState(state);
            }, Qt::QueuedConnection);
        });
    scheduleGitRefresh();
    historyFeature_->loadEntries(std::nullopt, [this](app::HistoryFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyHistoryState(state);
        }, Qt::QueuedConnection);
    });
    loadProjectAnalysis();
}

void WorkbenchWindow::refreshWorkspace() {
    if (workspaceRoot_.isEmpty()) return;
    loadSnapshot();
}

void WorkbenchWindow::scheduleWorkspaceRefresh() {
    if (workspaceRoot_.isEmpty() || workspaceRefreshTimer_ == nullptr) return;
    workspaceRefreshTimer_->start();
}

void WorkbenchWindow::scheduleGitRefresh() {
    if (workspaceRoot_.isEmpty() || gitRefreshTimer_ == nullptr) return;
    gitRefreshTimer_->start();
}

void WorkbenchWindow::handleDirectoryChanges(
    const std::vector<DirectoryChangeSource::Change>& changes) {
    if (workspaceRoot_.isEmpty() || changes.empty()) return;

    bool requiresWorkspaceRefresh = false;
    bool requiresGitRefresh = false;
    bool activeFileWasRemoved = false;
    bool activeFileWasModified = false;

    for (const auto& change : changes) {
        const auto path = normalizedRelativePath(fromUtf8(change.path));
        switch (change.kind) {
        case DirectoryChangeSource::ChangeKind::Added:
        case DirectoryChangeSource::ChangeKind::Removed:
        case DirectoryChangeSource::ChangeKind::RenamedOldName:
        case DirectoryChangeSource::ChangeKind::RenamedNewName:
        case DirectoryChangeSource::ChangeKind::RescanRequired:
            requiresWorkspaceRefresh = true;
            if ((change.kind == DirectoryChangeSource::ChangeKind::Removed ||
                 change.kind == DirectoryChangeSource::ChangeKind::RenamedOldName) &&
                !path.isEmpty() && sameRelativePath(path, activePath_)) {
                activeFileWasRemoved = true;
            }
            break;
        case DirectoryChangeSource::ChangeKind::Modified:
            // A root/directory write is a structural signal even though
            // ReadDirectoryChangesW reports it as FILE_ACTION_MODIFIED.
            if (path.isEmpty() ||
                QFileInfo(QDir(workspaceRoot_).filePath(path)).isDir()) {
                requiresWorkspaceRefresh = true;
            } else {
                requiresGitRefresh = true;
                if (sameRelativePath(path, activePath_)) activeFileWasModified = true;
            }
            break;
        }
    }

    if (requiresWorkspaceRefresh) scheduleWorkspaceRefresh();
    if (requiresGitRefresh) scheduleGitRefresh();

    if (activeFileWasRemoved) {
        const auto state = documentFeature_->state();
        if (!state.isDirty && !state.isLoading && !state.isSaving) {
            activePath_.clear();
            blamePath_.clear();
            closeLanguageServerDocument();
            suppressEditorChange_ = true;
            editor_->clearAnnotations();
            editor_->clear();
            suppressEditorChange_ = false;
    statusBar()->showMessage(uiText(QStringLiteral("The open file was removed")), 5000);
        } else {
            statusBar()->showMessage(
                uiText(QStringLiteral("The open file was removed; unsaved changes were kept")), 6000);
        }
    }

    if (!activeFileWasModified || activePath_.isEmpty()) return;
    const auto state = documentFeature_->state();
    if (state.isDirty || state.isLoading || state.isSaving) return;

    const auto expectedPath = activePath_;
    documentFeature_->open(expectedPath.toUtf8().toStdString(),
        [this, expectedPath](app::DocumentFeatureState next) {
        QMetaObject::invokeMethod(this, [this, expectedPath,
                                          next = std::move(next)]() mutable {
            if (!sameRelativePath(expectedPath, activePath_) ||
                !sameRelativePath(expectedPath, fromUtf8(next.relativePath))) return;
            applyDocumentState(next);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::refreshGitStatus() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    gitFeature_->refreshStatus([this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::loadGitHistory() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    showToolWindow(BottomToolKind::Git);
    selectedGitCommit_.clear();
    diffIsCommitReview_ = false;
    gitHistory_->clear();
    gitHistory_->setVisible(true);
    gitStashes_->setVisible(false);
    gitStashActions_->setVisible(false);
    gitShelves_->setVisible(false);
    gitShelfActions_->setVisible(false);
    gitDetails_->clear();
    gitDetails_->setVisible(false);
    if (commitFiles_ != nullptr) {
        commitFiles_->clear();
        commitFiles_->setVisible(false);
    }
    gitFeature_->refreshHistory(std::nullopt, 300,
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::openGitHistoryItem(QListWidgetItem* item) {
    if (item == nullptr || !gitFeature_) return;
    const auto hash = item->data(GitCommitHashRole).toString();
    if (hash.isEmpty()) return;
    selectedGitCommit_ = hash;
    diffIsCommitReview_ = false;
    gitDetails_->clear();
    gitDetails_->setVisible(true);
    if (commitFiles_ != nullptr) {
        commitFiles_->clear();
        commitFiles_->setVisible(false);
    }
    const auto applyState = [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    };
    gitFeature_->loadCommit(hash.toStdString(), applyState);
    gitFeature_->loadCommitFiles(hash.toStdString(), applyState);
}

void WorkbenchWindow::openCommitFile(QListWidgetItem* item) {
    if (item == nullptr || !gitFeature_ || selectedGitCommit_.isEmpty()) return;
    const auto path = item->data(RelativePathRole).toString();
    if (path.isEmpty()) return;
    diffIsCommitReview_ = true;
    selectedDiffHunk_.clear();
    if (diffActions_ != nullptr) diffActions_->setVisible(false);
    statusBar()->showMessage(uiText(QStringLiteral("Loading commit file diff...")));
    gitFeature_->loadCommitDiff(
        selectedGitCommit_.toStdString(), {path.toUtf8().toStdString()},
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::loadGitStashes() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    showToolWindow(BottomToolKind::Git);
    selectedGitStash_.clear();
    diffIsCommitReview_ = false;
    gitStashes_->clear();
    gitStashes_->setVisible(true);
    gitHistory_->setVisible(false);
    gitShelves_->setVisible(false);
    gitShelfActions_->setVisible(false);
    gitDetails_->clear();
    gitDetails_->setVisible(false);
    if (commitFiles_ != nullptr) {
        commitFiles_->clear();
        commitFiles_->setVisible(false);
    }
    gitFeature_->refreshStashes([this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::compareGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    bool accepted = false;
    const auto reference = QInputDialog::getText(
        this, uiText(QStringLiteral("Compare Git Reference")),
        uiText(QStringLiteral("Reference (branch, tag, or commit):")),
        QLineEdit::Normal, QStringLiteral("HEAD~1"), &accepted).trimmed();
    if (!accepted || reference.isEmpty()) return;
    showToolWindow(BottomToolKind::Diff);
    diffIsCommitReview_ = false;
    gitHistory_->setVisible(false);
    gitStashes_->setVisible(false);
    gitStashActions_->setVisible(false);
    gitDetails_->clear();
    gitDetails_->setVisible(true);
    if (commitFiles_ != nullptr) {
        commitFiles_->clear();
        commitFiles_->setVisible(false);
    }
    gitFeature_->loadComparison(reference.toStdString(),
        [this, reference](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, reference,
                                          state = std::move(state)]() mutable {
            if (!state.error && !state.isLoadingComparison && state.comparison) {
                statusBar()->showMessage(
                    uiText(QStringLiteral("Comparison with %1 loaded")).arg(reference), 3000);
            }
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::switchGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    const auto state = gitFeature_->state();
    if (!state.history || state.history->references.empty()) {
    statusBar()->showMessage(uiText(QStringLiteral("Load Git Log before switching branches")), 4000);
        loadGitHistory();
        return;
    }

    QStringList choices;
    for (const auto& reference : state.history->references) {
        choices.push_back(QString("%1  [%2]")
                              .arg(fromUtf8(reference.shortName))
                              .arg(fromUtf8(reference.kind)));
    }
    bool accepted = false;
    const auto selected = QInputDialog::getItem(
        this, uiText(QStringLiteral("Switch Git Reference")), uiText(QStringLiteral("Reference:")),
        choices, 0, false, &accepted);
    if (!accepted || selected.isEmpty()) return;
    const auto index = choices.indexOf(selected);
    if (index < 0 || index >= static_cast<int>(state.history->references.size())) return;
    const auto& reference = state.history->references[static_cast<std::size_t>(index)];

    gitFeature_->checkout(reference.fullName, reference.kind, [this](app::GitFeatureState result) {
        QMetaObject::invokeMethod(this, [this, result = std::move(result)]() mutable {
            applyGitState(result);
            if (result.error || result.isLoadingCheckoutPreflight) return;
            if (!result.checkoutPreflight || !result.checkoutPreflight->blockingPaths.empty()) {
                const auto count = result.checkoutPreflight
                    ? result.checkoutPreflight->blockingPaths.size() : 0;
                statusBar()->showMessage(
                    uiText(QStringLiteral("Checkout blocked by %1 local path(s)"))
                        .arg(static_cast<qulonglong>(count)), 5000);
                return;
            }
            if (result.isWriting) return;
            statusBar()->showMessage(uiText(QStringLiteral("Git reference switched")), 4000);
            loadSnapshot();
            loadGitHistory();
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::loadShelves() {
    if (workspaceRoot_.isEmpty() || !shelfFeature_) return;
    showToolWindow(BottomToolKind::Git);
    selectedShelf_.clear();
    diffIsCommitReview_ = false;
    gitShelves_->clear();
    gitShelves_->setVisible(true);
    gitShelfActions_->setVisible(true);
    setShelfActionsEnabled(true);
    gitHistory_->setVisible(false);
    gitStashes_->setVisible(false);
    gitStashActions_->setVisible(false);
    gitShelves_->setVisible(false);
    gitShelfActions_->setVisible(false);
    gitDetails_->clear();
    gitDetails_->setVisible(false);
    if (commitFiles_ != nullptr) {
        commitFiles_->clear();
        commitFiles_->setVisible(false);
    }
    shelfFeature_->load([this](app::ShelfFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyShelfState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::createShelf() {
    if (workspaceRoot_.isEmpty() || !shelfFeature_ || !gitFeature_) return;
    bool accepted = false;
    const auto label = QInputDialog::getText(
        this, uiText(QStringLiteral("Create Shelf")), uiText(QStringLiteral("Shelf name:")),
        QLineEdit::Normal, uiText(QStringLiteral("Working tree snapshot")), &accepted).trimmed();
    if (!accepted || label.isEmpty()) return;
    setShelfActionsEnabled(false);

    gitFeature_->loadShelfPatches(
        [this, label](std::optional<app::GitShelfPatches> patches,
                      std::optional<CoreError> error) {
        QMetaObject::invokeMethod(this, [this, label, patches = std::move(patches),
                                          error = std::move(error)]() mutable {
            if (error) {
                setShelfActionsEnabled(true);
                showFeatureError(error, uiText(QStringLiteral("Shelf patch request failed")));
                return;
            }
            if (!patches ||
                (patches->stagedPatch.empty() && patches->workingTreePatch.empty())) {
                setShelfActionsEnabled(true);
                statusBar()->showMessage(uiText(QStringLiteral("No Git changes to shelve")), 4000);
                return;
            }
            shelfFeature_->create(label.toUtf8().toStdString(), patches->stagedPatch,
                                  patches->workingTreePatch,
                                  [this](app::ShelfFeatureState shelfState) {
                QMetaObject::invokeMethod(this, [this, shelfState = std::move(shelfState)]() mutable {
                    setShelfActionsEnabled(true);
                    applyShelfState(shelfState);
                    if (!shelfState.error) {
                        loadShelves();
                        statusBar()->showMessage(uiText(QStringLiteral("Shelf created")), 4000);
                    }
                }, Qt::QueuedConnection);
            });
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::restoreSelectedShelf() {
    if (selectedShelf_.isEmpty() || !shelfFeature_ || !gitFeature_) {
        statusBar()->showMessage(uiText(QStringLiteral("Select a Shelf first")), 4000);
        return;
    }
    setShelfActionsEnabled(false);
    const auto id = selectedShelf_.toStdString();
    shelfFeature_->restore(id, [this](app::ShelfFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyShelfState(state);
            if (state.error || !state.restored) {
                setShelfActionsEnabled(true);
                return;
            }
            const auto staged = state.restored->stagedPatch;
            const auto workingTree = state.restored->workingTreePatch;
            const auto finish = [this](bool success) {
                setShelfActionsEnabled(true);
                if (success) {
                    loadSnapshot();
                    const auto expectedPath = activePath_;
                    const auto documentState = documentFeature_->state();
                    if (!expectedPath.isEmpty() && !documentState.isDirty &&
                        !documentState.isLoading && !documentState.isSaving) {
                        documentFeature_->open(expectedPath.toUtf8().toStdString(),
                            [this, expectedPath](app::DocumentFeatureState next) {
                            QMetaObject::invokeMethod(this, [this, expectedPath,
                                                              next = std::move(next)]() mutable {
                                if (expectedPath == activePath_) applyDocumentState(next);
                            }, Qt::QueuedConnection);
                        });
                    }
                    statusBar()->showMessage(uiText(QStringLiteral("Shelf restored")), 4000);
                }
            };
            const auto applyWorkingTree = [this, workingTree, finish]() {
                if (workingTree.empty()) {
                    finish(true);
                    return;
                }
                gitFeature_->apply(workingTree, "worktree", [this, finish](app::GitFeatureState result) {
                    QMetaObject::invokeMethod(this, [this, finish, result = std::move(result)]() mutable {
                        applyGitState(result);
                        finish(!result.error && !result.isApplying);
                    }, Qt::QueuedConnection);
                });
            };
            if (staged.empty()) {
                applyWorkingTree();
                return;
            }
            gitFeature_->apply(staged, "restoreIndex", [this, applyWorkingTree, finish](app::GitFeatureState result) mutable {
                QMetaObject::invokeMethod(this, [this, applyWorkingTree, finish,
                                                  result = std::move(result)]() mutable {
                    applyGitState(result);
                    if (result.error || result.isApplying) {
                        finish(false);
                        return;
                    }
                    applyWorkingTree();
                }, Qt::QueuedConnection);
            });
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::deleteSelectedShelf() {
    if (selectedShelf_.isEmpty() || !shelfFeature_) {
        statusBar()->showMessage(uiText(QStringLiteral("Select a Shelf first")), 4000);
        return;
    }
    if (QMessageBox::question(this, uiText(QStringLiteral("Delete Shelf")),
                              uiText(QStringLiteral("Delete the selected Shelf?"))) != QMessageBox::Yes) {
        return;
    }
    setShelfActionsEnabled(false);
    shelfFeature_->remove(selectedShelf_.toStdString(), [this](app::ShelfFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            setShelfActionsEnabled(true);
            applyShelfState(state);
            if (!state.error) {
                selectedShelf_.clear();
                loadShelves();
                statusBar()->showMessage(uiText(QStringLiteral("Shelf deleted")), 4000);
            }
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::setShelfActionsEnabled(bool enabled) {
    if (createShelfButton_ != nullptr) createShelfButton_->setEnabled(enabled);
    if (restoreShelfButton_ != nullptr) {
        restoreShelfButton_->setEnabled(enabled && !selectedShelf_.isEmpty());
    }
    if (deleteShelfButton_ != nullptr) {
        deleteShelfButton_->setEnabled(enabled && !selectedShelf_.isEmpty());
    }
}

void WorkbenchWindow::createGitBranch() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    bool accepted = false;
    const auto name = QInputDialog::getText(
        this, uiText(QStringLiteral("Create Git Branch")), uiText(QStringLiteral("Branch name:")),
        QLineEdit::Normal, QString(), &accepted).trimmed();
    if (!accepted || name.isEmpty()) return;

    GitWriteRequestDto request;
    request.operation = "createBranch";
    request.name = name.toStdString();
    request.reference = "HEAD";
    request.checkout = true;
    gitFeature_->write(std::move(request), [this, name](app::GitFeatureState result) {
        QMetaObject::invokeMethod(this, [this, name,
                                          result = std::move(result)]() mutable {
            applyGitState(result);
            if (result.error || result.isWriting) return;
            statusBar()->showMessage(uiText(QStringLiteral("Created branch %1")).arg(name), 4000);
            loadSnapshot();
            loadGitHistory();
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::applyStashOperation(const QString& operation) {
    if (workspaceRoot_.isEmpty() || !gitFeature_ || selectedGitStash_.isEmpty()) {
    statusBar()->showMessage(uiText(QStringLiteral("Select a stash first")), 4000);
        return;
    }
    if (operation == QStringLiteral("stashDrop") &&
        QMessageBox::question(this, uiText(QStringLiteral("Drop Stash")),
                              uiText(QStringLiteral("Drop %1?")).arg(selectedGitStash_)) != QMessageBox::Yes) {
        return;
    }
    const auto reference = selectedGitStash_;
    const auto finish = [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
            if (state.error || state.isWriting) return;
            loadSnapshot();
            loadGitStashes();
        }, Qt::QueuedConnection);
    };
    if (operation == QStringLiteral("stashApply")) {
        gitFeature_->applyStash(reference.toStdString(), finish);
    } else if (operation == QStringLiteral("stashPop")) {
        gitFeature_->popStash(reference.toStdString(), finish);
    } else if (operation == QStringLiteral("stashDrop")) {
        gitFeature_->dropStash(reference.toStdString(), finish);
    }
}

void WorkbenchWindow::applySelectedStash() {
    applyStashOperation(QStringLiteral("stashApply"));
}

void WorkbenchWindow::popSelectedStash() {
    applyStashOperation(QStringLiteral("stashPop"));
}

void WorkbenchWindow::dropSelectedStash() {
    applyStashOperation(QStringLiteral("stashDrop"));
}

void WorkbenchWindow::loadSnapshot() {
    if (workspaceRoot_.isEmpty()) return;
    workspaceFeature_->refresh([this](app::WorkspaceFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyWorkspaceState(state);
        }, Qt::QueuedConnection);
    });
    scheduleGitRefresh();
    historyFeature_->loadEntries(std::nullopt, [this](app::HistoryFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyHistoryState(state);
        }, Qt::QueuedConnection);
    });
    loadProjectAnalysis();
}

void WorkbenchWindow::showTreeContextMenu(const QPoint& position) {
    if (tree_ == nullptr || workspaceRoot_.isEmpty()) return;
    auto* item = tree_->itemAt(position);
    if (item == nullptr) return;
    tree_->setCurrentItem(item);

    const auto relative = item->data(0, RelativePathRole).toString();
    QMenu menu(this);
    auto* newFile = menu.addAction(uiText(QStringLiteral("New File...")));
    auto* newDirectory = menu.addAction(uiText(QStringLiteral("New Directory...")));
    menu.addSeparator();
    auto* rename = menu.addAction(uiText(QStringLiteral("Rename...")));
    auto* copy = menu.addAction(uiText(QStringLiteral("Duplicate...")));
    auto* remove = menu.addAction(uiText(QStringLiteral("Delete")));
    menu.addSeparator();
    auto* copyRelative = menu.addAction(uiText(QStringLiteral("Copy Relative Path")));
    auto* copyAbsolute = menu.addAction(uiText(QStringLiteral("Copy Absolute Path")));
    rename->setEnabled(!relative.isEmpty());
    copy->setEnabled(!relative.isEmpty());
    remove->setEnabled(!relative.isEmpty());
    connect(newFile, &QAction::triggered, this, [this] { createWorkspaceItem(false); });
    connect(newDirectory, &QAction::triggered, this,
            [this] { createWorkspaceItem(true); });
    connect(rename, &QAction::triggered, this, &WorkbenchWindow::renameWorkspaceItem);
    connect(copy, &QAction::triggered, this, &WorkbenchWindow::copyWorkspaceItem);
    connect(remove, &QAction::triggered, this, &WorkbenchWindow::deleteWorkspaceItem);
    connect(copyRelative, &QAction::triggered, this,
            [this] { copyWorkspacePath(false); });
    connect(copyAbsolute, &QAction::triggered, this,
            [this] { copyWorkspacePath(true); });
    menu.exec(tree_->viewport()->mapToGlobal(position));
}

void WorkbenchWindow::createWorkspaceItem(bool directory) {
    if (tree_ == nullptr || coordinator_ == nullptr || storage_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    auto parentPath = item->data(0, RelativePathRole).toString();
    if (!item->data(0, DirectoryRole).toBool()) parentPath = QFileInfo(parentPath).path();
    if (parentPath == QStringLiteral(".")) parentPath.clear();

    bool accepted = false;
    const auto name = QInputDialog::getText(
        this, directory ? uiText(QStringLiteral("New Directory")) : uiText(QStringLiteral("New File")),
         uiText(QStringLiteral("Name")), QLineEdit::Normal, QString(), &accepted).trimmed();
    const auto normalizedName = QDir::fromNativeSeparators(name);
    if (!accepted || normalizedName.isEmpty() || normalizedName == QStringLiteral(".") ||
        normalizedName == QStringLiteral("..") ||
        QFileInfo(normalizedName).fileName() != normalizedName) {
    if (accepted) statusBar()->showMessage(uiText(QStringLiteral("Invalid workspace item name")), 4000);
        return;
    }
    const auto relative = parentPath.isEmpty()
        ? normalizedName : parentPath + QStringLiteral("/") + normalizedName;
    const auto paths = coordinator_->workspacePaths();
    if (!paths) return;
    std::filesystem::path absolute;
    try {
        absolute = paths->toAbsolute(relative.toUtf8().toStdString());
    } catch (const std::invalid_argument&) {
    statusBar()->showMessage(uiText(QStringLiteral("Invalid workspace path")), 4000);
        return;
    }
    std::string error;
    const auto success = directory
        ? storage_->createDirectory(pathUtf8(absolute), false, error)
        : storage_->writeData(pathUtf8(absolute), {}, error);
    if (!success) {
        statusBar()->showMessage(uiText(QStringLiteral("Could not create item: ")) + fromUtf8(error), 6000);
        return;
    }
    scheduleWorkspaceRefresh();
    scheduleGitRefresh();
    statusBar()->showMessage(uiText(QStringLiteral("Created %1")).arg(relative), 3000);
}

void WorkbenchWindow::renameWorkspaceItem() {
    if (tree_ == nullptr || coordinator_ == nullptr || storage_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto oldRelative = item->data(0, RelativePathRole).toString();
    if (oldRelative.isEmpty()) return;
    bool accepted = false;
    const auto name = QInputDialog::getText(
        this, uiText(QStringLiteral("Rename Workspace Item")), uiText(QStringLiteral("Name")),
        QLineEdit::Normal, item->text(0), &accepted).trimmed();
    const auto normalizedName = QDir::fromNativeSeparators(name);
    if (!accepted || normalizedName.isEmpty() || normalizedName == QStringLiteral(".") ||
        normalizedName == QStringLiteral("..") ||
        QFileInfo(normalizedName).fileName() != normalizedName) {
        if (accepted) statusBar()->showMessage(QStringLiteral("Invalid workspace item name"), 4000);
        return;
    }
    const auto parent = QFileInfo(oldRelative).path() == QStringLiteral(".")
        ? QString() : QFileInfo(oldRelative).path();
    const auto newRelative = parent.isEmpty()
        ? normalizedName : parent + QStringLiteral("/") + normalizedName;
    if (sameRelativePath(oldRelative, newRelative)) return;
    const auto paths = coordinator_->workspacePaths();
    if (!paths) return;
    std::filesystem::path source;
    std::filesystem::path destination;
    try {
        source = paths->toAbsolute(oldRelative.toUtf8().toStdString());
        destination = paths->toAbsolute(newRelative.toUtf8().toStdString());
    } catch (const std::invalid_argument&) {
        statusBar()->showMessage(QStringLiteral("Invalid workspace path"), 4000);
        return;
    }
    std::string error;
    if (!storage_->moveItem(pathUtf8(source), pathUtf8(destination), error)) {
        statusBar()->showMessage(uiText(QStringLiteral("Could not rename item: ")) + fromUtf8(error), 6000);
        return;
    }
    if (!activePath_.isEmpty() &&
        (sameRelativePath(activePath_, oldRelative) ||
         activePath_.startsWith(oldRelative + QStringLiteral("/"), Qt::CaseInsensitive))) {
        activePath_.clear();
        blamePath_.clear();
        closeLanguageServerDocument();
        suppressEditorChange_ = true;
        editor_->clearAnnotations();
        editor_->clear();
        suppressEditorChange_ = false;
    }
    scheduleWorkspaceRefresh();
    scheduleGitRefresh();
    statusBar()->showMessage(uiText(QStringLiteral("Renamed to %1")).arg(newRelative), 3000);
}

void WorkbenchWindow::copyWorkspaceItem() {
    if (tree_ == nullptr || coordinator_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto sourceRelative = item->data(0, RelativePathRole).toString();
    if (sourceRelative.isEmpty()) return;
    const auto sourceName = item->text(0);
    const auto info = QFileInfo(sourceName);
    const auto proposedName = item->data(0, DirectoryRole).toBool()
        ? sourceName + QStringLiteral(" copy")
        : info.completeBaseName() + QStringLiteral(" copy") +
              (info.suffix().isEmpty() ? QString() : QStringLiteral(".") + info.suffix());
    bool accepted = false;
    const auto name = QInputDialog::getText(this, uiText(QStringLiteral("Duplicate Workspace Item")),
                                             uiText(QStringLiteral("Name")), QLineEdit::Normal,
                                            proposedName, &accepted).trimmed();
    const auto normalizedName = QDir::fromNativeSeparators(name);
    if (!accepted || normalizedName.isEmpty() || normalizedName == QStringLiteral(".") ||
        normalizedName == QStringLiteral("..") ||
        QFileInfo(normalizedName).fileName() != normalizedName) {
        if (accepted) statusBar()->showMessage(QStringLiteral("Invalid workspace item name"), 4000);
        return;
    }
    const auto parent = QFileInfo(sourceRelative).path() == QStringLiteral(".")
        ? QString() : QFileInfo(sourceRelative).path();
    const auto destinationRelative = parent.isEmpty()
        ? normalizedName : parent + QStringLiteral("/") + normalizedName;
    const auto paths = coordinator_->workspacePaths();
    if (!paths) return;
    std::filesystem::path source;
    std::filesystem::path destination;
    try {
        source = paths->toAbsolute(sourceRelative.toUtf8().toStdString());
        destination = paths->toAbsolute(destinationRelative.toUtf8().toStdString());
    } catch (const std::invalid_argument&) {
        statusBar()->showMessage(QStringLiteral("Invalid workspace path"), 4000);
        return;
    }
    std::error_code filesystemError;
    if (std::filesystem::exists(destination, filesystemError)) {
    statusBar()->showMessage(uiText(QStringLiteral("Destination already exists")), 5000);
        return;
    }
    if (item->data(0, DirectoryRole).toBool()) {
        std::filesystem::copy(source, destination,
                              std::filesystem::copy_options::recursive, filesystemError);
    } else {
        std::filesystem::copy_file(source, destination,
                                   std::filesystem::copy_options::none, filesystemError);
    }
    if (filesystemError) {
        statusBar()->showMessage(uiText(QStringLiteral("Could not duplicate item: ")) +
                                     fromUtf8(filesystemError.message()), 6000);
        return;
    }
    scheduleWorkspaceRefresh();
    scheduleGitRefresh();
    statusBar()->showMessage(uiText(QStringLiteral("Duplicated as %1")).arg(destinationRelative), 3000);
}

void WorkbenchWindow::deleteWorkspaceItem() {
    if (tree_ == nullptr || coordinator_ == nullptr || storage_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto relative = item->data(0, RelativePathRole).toString();
    if (relative.isEmpty()) return;
    if (QMessageBox::question(this, uiText(QStringLiteral("Delete Workspace Item")),
                              uiText(QStringLiteral("Delete %1 permanently?")).arg(relative),
                              QMessageBox::Yes | QMessageBox::No, QMessageBox::No) !=
        QMessageBox::Yes) return;
    const auto paths = coordinator_->workspacePaths();
    if (!paths) return;
    std::filesystem::path absolute;
    try {
        absolute = paths->toAbsolute(relative.toUtf8().toStdString());
    } catch (const std::invalid_argument&) {
        statusBar()->showMessage(QStringLiteral("Invalid workspace path"), 4000);
        return;
    }
    std::string error;
    if (!storage_->removeItem(pathUtf8(absolute), error)) {
        statusBar()->showMessage(uiText(QStringLiteral("Could not delete item: ")) + fromUtf8(error), 6000);
        return;
    }
    if (!activePath_.isEmpty() &&
        (sameRelativePath(activePath_, relative) ||
         activePath_.startsWith(relative + QStringLiteral("/"), Qt::CaseInsensitive))) {
        activePath_.clear();
        blamePath_.clear();
        closeLanguageServerDocument();
        suppressEditorChange_ = true;
        editor_->clearAnnotations();
        editor_->clear();
        suppressEditorChange_ = false;
    }
    scheduleWorkspaceRefresh();
    scheduleGitRefresh();
    statusBar()->showMessage(uiText(QStringLiteral("Deleted %1")).arg(relative), 3000);
}

void WorkbenchWindow::copyWorkspacePath(bool absolute) {
    if (tree_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto relative = item->data(0, RelativePathRole).toString();
    const auto value = absolute ? QDir(workspaceRoot_).filePath(relative) : relative;
    QApplication::clipboard()->setText(value);
    statusBar()->showMessage(uiText(QStringLiteral("Copied path")), 2000);
}

void WorkbenchWindow::loadProjectAnalysis() {
    if (workspaceRoot_.isEmpty()) return;
    mavenJavaFeature_->scanMaven([this](app::MavenJavaFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyMavenJavaState(state);
        }, Qt::QueuedConnection);
    });
    mavenJavaFeature_->loadRunConfigurations({}, {},
        [this](app::MavenJavaFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyMavenJavaState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::applyWorkspaceState(const app::WorkspaceFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Workspace request failed"));
        return;
    }
    if (state.isLoading || !state.snapshot) return;
    tree_->clear();
    appendTreeNode(nullptr, state.snapshot->root);
    sidebar_->showProjectReady();
    restoreWorkspaceSession();
    statusBar()->showMessage(uiText(QStringLiteral("Workspace loaded with %1 files")).arg(
        static_cast<qulonglong>(state.snapshot->files.size())));
    synchronizeJavaRunProject();
}

QTreeWidgetItem* WorkbenchWindow::findTreeItem(const QString& relativePath) const {
    std::function<QTreeWidgetItem*(QTreeWidgetItem*)> find =
        [&](QTreeWidgetItem* parent) -> QTreeWidgetItem* {
            for (int index = 0; index < parent->childCount(); ++index) {
                auto* item = parent->child(index);
                if (item->data(0, RelativePathRole).toString() == relativePath) return item;
                if (auto* found = find(item)) return found;
            }
            return nullptr;
        };
    for (int index = 0; index < tree_->topLevelItemCount(); ++index) {
        auto* item = tree_->topLevelItem(index);
        if (item->data(0, RelativePathRole).toString() == relativePath) return item;
        if (auto* found = find(item)) return found;
    }
    return nullptr;
}

void WorkbenchWindow::restoreWorkspaceSession() {
    if (!pendingWorkspaceSession_) return;
    const auto session = std::move(*pendingWorkspaceSession_);
    pendingWorkspaceSession_.reset();
    for (const auto& path : session.expandedPaths) {
        if (auto* item = findTreeItem(fromUtf8(path))) item->setExpanded(true);
    }
    for (const auto& path : session.openPaths) {
        const auto relative = fromUtf8(path);
        if (auto* item = findTreeItem(relative);
            item != nullptr && !item->data(0, DirectoryRole).toBool()) {
            ensureEditorTab(relative);
        }
    }
    if (!session.activePath.empty()) {
        if (auto* item = findTreeItem(fromUtf8(session.activePath))) {
            if (!item->data(0, DirectoryRole).toBool()) openTreeItem(item, 0);
        }
    } else if (editorTabs_ != nullptr && editorTabs_->count() > 0) {
        switchEditorTab(0);
    }
}

void WorkbenchWindow::saveWorkspaceSession() {
    if (workspaceRoot_.isEmpty()) return;
    app::WorkspaceSession session;
    if (editorTabs_ != nullptr) {
        for (int index = 0; index < editorTabs_->count(); ++index) {
            const auto path = editorTabs_->tabData(index).toString();
            if (!path.isEmpty()) session.openPaths.push_back(path.toStdString());
        }
    }
    if (session.openPaths.empty() && !activePath_.isEmpty()) {
        session.openPaths.push_back(activePath_.toStdString());
    }
    std::function<void(QTreeWidgetItem*)> collect = [&](QTreeWidgetItem* parent) {
        for (int index = 0; index < parent->childCount(); ++index) {
            auto* item = parent->child(index);
            if (item->isExpanded() && item->data(0, DirectoryRole).toBool()) {
                session.expandedPaths.push_back(
                    item->data(0, RelativePathRole).toString().toStdString());
            }
            collect(item);
        }
    };
    for (int index = 0; index < tree_->topLevelItemCount(); ++index) {
        auto* item = tree_->topLevelItem(index);
        if (item->isExpanded() && item->data(0, DirectoryRole).toBool()) {
            session.expandedPaths.push_back(
                item->data(0, RelativePathRole).toString().toStdString());
        }
        collect(item);
    }
    std::string error;
    if (!workspaceSessionStore_.save(workspaceRoot_.toStdString(), session, error) &&
        !error.empty() && statusBar() != nullptr) {
        statusBar()->showMessage(QString::fromUtf8(error.data(),
                                                   static_cast<qsizetype>(error.size())),
                                 5000);
    }
}

void WorkbenchWindow::appendTreeNode(QTreeWidgetItem* parent, const WorkspaceNodeDto& node) {
    auto* item = parent == nullptr ? new QTreeWidgetItem(tree_) : new QTreeWidgetItem(parent);
    const auto relativePath = fromUtf8(node.path);
    item->setText(0, fromUtf8(node.name));
    item->setData(0, RelativePathRole, relativePath);
    item->setData(0, DirectoryRole, node.isDirectory);
    for (const auto& child : node.children) appendTreeNode(item, child);
    if (parent == nullptr) item->setExpanded(true);
}

int WorkbenchWindow::ensureEditorTab(const QString& relativePath) {
    if (editorTabs_ == nullptr || relativePath.isEmpty()) return -1;
    for (int index = 0; index < editorTabs_->count(); ++index) {
        if (sameRelativePath(editorTabs_->tabData(index).toString(), relativePath)) return index;
    }
    QSignalBlocker blocker(editorTabs_);
    const auto label = QFileInfo(relativePath).fileName().isEmpty()
        ? relativePath : QFileInfo(relativePath).fileName();
    const auto index = editorTabs_->addTab(label);
    editorTabs_->setTabData(index, relativePath);
    editorTabs_->setTabToolTip(index, relativePath);
    if (editorArea_ != nullptr) editorArea_->setEmptyStateVisible(false);
    return index;
}

void WorkbenchWindow::switchEditorTab(int index) {
    if (editorTabs_ == nullptr || index < 0 || index >= editorTabs_->count()) return;
    const auto path = editorTabs_->tabData(index).toString();
    if (path.isEmpty() || (!librarySourcePreview_ && sameRelativePath(path, activePath_))) return;
    if (auto* item = findTreeItem(path)) {
        openTreeItem(item, 0);
    } else {
    statusBar()->showMessage(uiText(QStringLiteral("The tab file is no longer in the workspace")), 5000);
    }
}

void WorkbenchWindow::closeEditorTab(int index) {
    if (editorTabs_ == nullptr || index < 0 || index >= editorTabs_->count()) return;
    const auto path = editorTabs_->tabData(index).toString();
    if (sameRelativePath(path, activePath_) && documentFeature_->state().isDirty) {
        const auto choice = QMessageBox::warning(
            this, uiText(QStringLiteral("Unsaved Changes")),
            uiText(QStringLiteral("Save changes to %1 before closing?")).arg(path),
            QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel,
            QMessageBox::Save);
        if (choice == QMessageBox::Cancel) return;
        if (choice == QMessageBox::Save) saveDocument();
    }
    const auto wasCurrent = index == editorTabs_->currentIndex();
    {
        QSignalBlocker blocker(editorTabs_);
        editorTabs_->removeTab(index);
    }
    if (!wasCurrent) return;
    activePath_.clear();
    librarySourcePreview_ = false;
    blamePath_.clear();
    closeLanguageServerDocument();
    suppressEditorChange_ = true;
    editor_->clearAnnotations();
    editor_->clear();
    suppressEditorChange_ = false;
    if (editorTabs_->count() == 0) {
        if (editorArea_ != nullptr) editorArea_->setEmptyStateVisible(true);
        return;
    }
    const auto next = std::min(index, editorTabs_->count() - 1);
    {
        QSignalBlocker blocker(editorTabs_);
        editorTabs_->setCurrentIndex(next);
    }
    switchEditorTab(next);
}

void WorkbenchWindow::openTreeItem(QTreeWidgetItem* item, int) {
    if (item == nullptr || item->data(0, DirectoryRole).toBool() || workspaceRoot_.isEmpty()) return;
    selectedDiffHunk_.clear();
    diffIsCommitReview_ = false;
    librarySourcePreview_ = false;
    editor_->setReadOnly(false);
    activePath_ = item->data(0, RelativePathRole).toString();
    if (editorTabs_ != nullptr) {
        const auto tab = ensureEditorTab(activePath_);
        if (tab >= 0) {
            QSignalBlocker blocker(editorTabs_);
            editorTabs_->setCurrentIndex(tab);
        }
    }
    const auto openedPath = activePath_;
    if (editor_->blameVisible()) {
        blamePath_ = openedPath;
        editor_->setBlameAnnotations({});
    } else {
        blamePath_.clear();
    }
    documentFeature_->open(activePath_.toUtf8().toStdString(),
        [this, openedPath](app::DocumentFeatureState state) {
            QMetaObject::invokeMethod(this, [this, openedPath,
                                              state = std::move(state)]() mutable {
            if (!sameRelativePath(openedPath, activePath_) ||
                !sameRelativePath(openedPath, fromUtf8(state.relativePath))) return;
            applyDocumentState(state);
        }, Qt::QueuedConnection);
    });
    gitFeature_->loadDiff({activePath_.toUtf8().toStdString()}, false, false,
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
    historyFeature_->loadEntries(activePath_.toUtf8().toStdString(),
        [this](app::HistoryFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyHistoryState(state);
        }, Qt::QueuedConnection);
    });
    if (editor_->blameVisible()) {
        gitFeature_->loadBlame(openedPath.toUtf8().toStdString(),
            [this, openedPath](app::GitFeatureState state) {
            QMetaObject::invokeMethod(this, [this, openedPath,
                                              state = std::move(state)]() mutable {
                if (openedPath == activePath_) applyGitState(state);
            }, Qt::QueuedConnection);
        });
    }
}

void WorkbenchWindow::toggleBlame() {
    if (editor_ == nullptr || gitFeature_ == nullptr || activePath_.isEmpty()) {
    statusBar()->showMessage(uiText(QStringLiteral("Open a file before showing Git blame")), 5000);
        return;
    }
    const auto visible = !editor_->blameVisible();
    editor_->setBlameVisible(visible);
    if (!visible) {
        blamePath_.clear();
        editor_->setBlameAnnotations({});
        return;
    }

    const auto path = activePath_;
    blamePath_ = path;
    const auto state = gitFeature_->state();
    if (state.blame && !state.isLoadingBlame) {
        applyGitState(state);
        return;
    }
    gitFeature_->loadBlame(path.toUtf8().toStdString(),
        [this, path](app::GitFeatureState next) {
        QMetaObject::invokeMethod(this, [this, path,
                                          next = std::move(next)]() mutable {
            if (path == activePath_) applyGitState(next);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::openChangeItem(QListWidgetItem* item) {
    if (item == nullptr) return;
    const auto line = item->data(NavigationLineRole);
    const auto column = item->data(NavigationColumnRole);
    if (line.isValid() && column.isValid()) {
        pendingNavigationLine_ = line.toULongLong();
        pendingNavigationColumn_ = column.toULongLong();
    } else {
        pendingNavigationLine_.reset();
        pendingNavigationColumn_.reset();
    }
    if (auto* treeItem = findTreeItem(item->data(RelativePathRole).toString())) {
        openTreeItem(treeItem, 0);
    } else {
        pendingNavigationLine_.reset();
        pendingNavigationColumn_.reset();
    }
}

void WorkbenchWindow::openJavaNavigationItem(QListWidgetItem* item) {
    if (item == nullptr) return;
    const auto absolutePath = item->data(NavigationAbsolutePathRole).toString();
    if (absolutePath.isEmpty()) {
        openChangeItem(item);
        return;
    }
    QFile input(absolutePath);
    if (!input.open(QIODevice::ReadOnly)) {
        statusBar()->showMessage(
            QStringLiteral("Could not open Java library source: ") + absolutePath, 5000);
        return;
    }
    const auto bytes = input.readAll();
    librarySourcePreview_ = true;
    editor_->setReadOnly(true);
    const auto wasSuppressed = suppressEditorChange_;
    suppressEditorChange_ = true;
    editor_->clearAnnotations();
    editor_->setPlainText(QString::fromUtf8(bytes));
    suppressEditorChange_ = wasSuppressed;

    const auto lineValue = item->data(NavigationLineRole).toULongLong();
    const auto columnValue = item->data(NavigationColumnRole).toULongLong();
    const auto line = std::min<std::uint64_t>(
        lineValue, static_cast<std::uint64_t>(std::max(0, editor_->blockCount() - 1)));
    const auto block = editor_->document()->findBlockByNumber(static_cast<int>(line));
    if (block.isValid()) {
        const auto lastColumn = block.length() > 0
            ? static_cast<std::uint64_t>(block.length() - 1) : std::uint64_t{0};
        QTextCursor cursor(editor_->document());
        cursor.setPosition(block.position() + static_cast<int>(std::min(columnValue, lastColumn)));
        editor_->setTextCursor(cursor);
        editor_->ensureCursorVisible();
    }
    statusBar()->showMessage(
        QStringLiteral("Read-only Java source: ") + absolutePath, 5000);
}

void WorkbenchWindow::applyDocumentState(const app::DocumentFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("File request failed"));
        return;
    }
    if (state.isLoading || state.relativePath.empty()) return;
    activePath_ = fromUtf8(state.relativePath);
    suppressEditorChange_ = true;
    editor_->clearAnnotations();
    editor_->setPlainText(fromUtf8(state.text));
    suppressEditorChange_ = false;
    if (findBar_ != nullptr && findBar_->isVisible()) updateFindHighlights();
    if (pendingNavigationLine_ && pendingNavigationColumn_) {
        const auto line = std::min<std::uint64_t>(
            *pendingNavigationLine_, static_cast<std::uint64_t>(editor_->blockCount() - 1));
        const auto block = editor_->document()->findBlockByNumber(static_cast<int>(line));
        if (block.isValid()) {
            const auto lastColumn = block.length() > 0
                ? static_cast<std::uint64_t>(block.length() - 1)
                : std::uint64_t{0};
            const auto column = std::min<std::uint64_t>(*pendingNavigationColumn_, lastColumn);
            QTextCursor cursor(editor_->document());
            cursor.setPosition(block.position() + static_cast<int>(column));
            editor_->setTextCursor(cursor);
            editor_->ensureCursorVisible();
        }
        pendingNavigationLine_.reset();
        pendingNavigationColumn_.reset();
    }
    statusBar()->showMessage(activePath_);
    if (activePath_.endsWith(QStringLiteral(".java"), Qt::CaseInsensitive)) {
        if (languageServerPath_ != activePath_) closeLanguageServerDocument();
        languageServerPath_ = activePath_;
        languageServerText_ = state.text;
        ensureJavaLanguageServer();
        synchronizeLanguageServerDocument();
        const auto annotationPath = activePath_;
        mavenJavaFeature_->loadCodeVision(activePath_.toUtf8().toStdString(), {state.relativePath},
            [this, annotationPath](app::MavenJavaFeatureState analysisState) {
            QMetaObject::invokeMethod(this, [this, annotationPath,
                                              analysisState = std::move(analysisState)]() mutable {
                if (annotationPath == activePath_) applyMavenJavaState(analysisState, true, false);
            }, Qt::QueuedConnection);
        });
        mavenJavaFeature_->loadJavaStructure(state.text, {},
            [this, annotationPath](app::MavenJavaFeatureState analysisState) {
            QMetaObject::invokeMethod(this, [this, annotationPath,
                                              analysisState = std::move(analysisState)]() mutable {
                if (annotationPath == activePath_) applyMavenJavaState(analysisState, false, true);
            }, Qt::QueuedConnection);
        });
    } else {
        editor_->clearAnnotations();
        closeLanguageServerDocument();
    }
}

void WorkbenchWindow::searchWorkspace() {
    if (workspaceRoot_.isEmpty() || searchField_->text().trimmed().isEmpty()) return;
    if (sidebar_ != nullptr) sidebar_->setPage(WorkbenchSidebar::SidebarPage::Search);
    searchFeature_->search(searchField_->text().toUtf8().toStdString(),
        [this](app::SearchFeatureState state) {
            QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                applySearchState(state);
            }, Qt::QueuedConnection);
        });
}

void WorkbenchWindow::showSearchEverywhere() {
    if (workspaceRoot_.isEmpty()) {
        statusBar()->showMessage(uiText(QStringLiteral("Open a workspace before searching")), 5000);
        return;
    }
    if (searchEverywhereDialog_ == nullptr) {
        searchEverywhereDialog_ = new QDialog(this);
        searchEverywhereDialog_->setWindowTitle(QStringLiteral("Search Everywhere"));
        searchEverywhereDialog_->setModal(false);
        searchEverywhereDialog_->setMinimumSize(720, 420);
        auto* layout = new QVBoxLayout(searchEverywhereDialog_);
        searchEverywhereField_ = new QLineEdit(searchEverywhereDialog_);
        searchEverywhereField_->setPlaceholderText(
            QStringLiteral("Search files, Java types, symbols, and content"));
        layout->addWidget(searchEverywhereField_);
        searchEverywhereResults_ = new QListWidget(searchEverywhereDialog_);
        searchEverywhereResults_->setSelectionMode(QAbstractItemView::SingleSelection);
        searchEverywhereResults_->setWordWrap(false);
        layout->addWidget(searchEverywhereResults_, 1);
        connect(searchEverywhereField_, &QLineEdit::returnPressed,
                this, &WorkbenchWindow::searchEverywhere);
        connect(searchEverywhereResults_, &QListWidget::itemDoubleClicked, this,
                [this](QListWidgetItem* item) {
                    openSearchResult(item);
                    if (searchEverywhereDialog_ != nullptr) searchEverywhereDialog_->hide();
                });
    }
    searchEverywhereField_->setText(searchField_ == nullptr ? QString() : searchField_->text());
    searchEverywhereField_->selectAll();
    searchEverywhereResults_->clear();
    searchEverywhereResults_->setVisible(true);
    searchEverywhereDialog_->show();
    searchEverywhereDialog_->raise();
    searchEverywhereDialog_->activateWindow();
    searchEverywhereField_->setFocus();
}

void WorkbenchWindow::searchEverywhere() {
    if (workspaceRoot_.isEmpty() || searchEverywhereField_ == nullptr) return;
    const auto query = searchEverywhereField_->text().trimmed();
    if (query.isEmpty()) {
        if (searchEverywhereResults_ != nullptr) searchEverywhereResults_->clear();
        statusBar()->showMessage(uiText(QStringLiteral("Enter a search query")), 3000);
        return;
    }
    searchFeature_->searchEverywhere(query.toUtf8().toStdString(),
        [this](app::SearchEverywhereFeatureState state) {
            QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                applySearchEverywhereState(state);
            }, Qt::QueuedConnection);
        });
}

void WorkbenchWindow::applySearchState(const app::SearchFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Search request failed"));
        return;
    }
    if (state.isLoading) return;
    results_->clear();
    for (const auto& match : state.matches) {
        const auto line = match.line
            ? QString::number(static_cast<qulonglong>(*match.line))
            : QStringLiteral("-");
        auto* result = new QListWidgetItem(QString("%1:%2  %3")
            .arg(fromUtf8(match.path))
            .arg(line)
            .arg(fromUtf8(match.preview)), results_);
        result->setData(RelativePathRole, fromUtf8(match.path));
        if (match.line && *match.line > 0) {
            result->setData(NavigationLineRole,
                            static_cast<qulonglong>(*match.line - 1));
            result->setData(NavigationColumnRole, static_cast<qulonglong>(0));
        }
    }
    results_->setVisible(results_->count() > 0);
    statusBar()->showMessage(uiText(QStringLiteral("%1 search results")).arg(results_->count()));
}

void WorkbenchWindow::applySearchEverywhereState(
    const app::SearchEverywhereFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Search Everywhere request failed"));
        return;
    }
    if (state.isLoading || searchEverywhereResults_ == nullptr) {
    statusBar()->showMessage(uiText(QStringLiteral("Searching Everywhere...")));
        return;
    }
    searchEverywhereResults_->clear();
    for (const auto& match : state.matches) {
        const auto kind = fromUtf8(match.kind);
        const auto symbol = match.symbolName ? fromUtf8(*match.symbolName) : QString();
        const auto line = match.line
            ? QString::number(static_cast<qulonglong>(*match.line))
            : QStringLiteral("-");
        const auto detail = symbol.isEmpty() ? fromUtf8(match.preview)
                                             : symbol + QStringLiteral("  ") +
                                                   fromUtf8(match.preview);
        auto* result = new QListWidgetItem(QString("[%1] %2:%3  %4")
            .arg(kind)
            .arg(fromUtf8(match.path))
            .arg(line)
            .arg(detail), searchEverywhereResults_);
        result->setData(RelativePathRole, fromUtf8(match.path));
        if (match.line && *match.line > 0) {
            result->setData(NavigationLineRole,
                            static_cast<qulonglong>(*match.line - 1));
            result->setData(NavigationColumnRole, static_cast<qulonglong>(0));
        }
    }
    searchEverywhereResults_->setVisible(true);
    statusBar()->showMessage(uiText(QStringLiteral("%1 Search Everywhere results"))
                                 .arg(searchEverywhereResults_->count()));
}

void WorkbenchWindow::openSearchResult(QListWidgetItem* item) {
    if (item == nullptr) return;
    const auto line = item->data(NavigationLineRole);
    if (line.isValid()) {
        pendingNavigationLine_ = line.toULongLong();
        const auto column = item->data(NavigationColumnRole);
        pendingNavigationColumn_ = column.isValid()
            ? std::optional<std::uint64_t>(column.toULongLong())
            : std::optional<std::uint64_t>(0);
    } else {
        pendingNavigationLine_.reset();
        pendingNavigationColumn_.reset();
    }
    if (auto* treeItem = findTreeItem(item->data(RelativePathRole).toString())) {
        openTreeItem(treeItem, 0);
        return;
    }
    pendingNavigationLine_.reset();
    pendingNavigationColumn_.reset();
    statusBar()->showMessage(uiText(QStringLiteral("Search result is no longer in the workspace")), 5000);
}

void WorkbenchWindow::applyGitState(const app::GitFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Git request failed"));
        return;
    }
    if (state.status && !state.isLoadingStatus) {
        changes_->clear();
        for (const auto& change : state.status->changes) {
            auto* item = new QListWidgetItem(
                QString("%1  %2").arg(fromUtf8(change.status)).arg(fromUtf8(change.path)), changes_);
            item->setData(RelativePathRole, fromUtf8(change.path));
        }
        changes_->setVisible(changes_->count() > 0);
    statusBar()->showMessage(uiText(QStringLiteral("%1 Git changes")).arg(changes_->count()));
    }
    if (state.diff && !state.isLoadingDiff) {
        if (!diffReview_ || diffReview_->patch != state.diff->patch) {
            expandedDiffRegions_.clear();
            selectedDiffHunk_.clear();
        }
        diffReview_ = *state.diff;
        renderDiffReview();
        diffActions_->setVisible(!diffIsCommitReview_ && !state.diff->hunks.empty());
    statusBar()->showMessage(uiText(QStringLiteral("%1 diff hunks")).arg(
            static_cast<qulonglong>(state.diff->hunks.size())));
    }
    if (gitHistory_ != nullptr && gitHistory_->isVisible() && state.history &&
        !state.isLoadingHistory) {
        std::vector<algorithms::GitGraphCommit> graphCommits;
        graphCommits.reserve(state.history->commits.size());
        for (const auto& commit : state.history->commits) {
            graphCommits.push_back({commit.hash, commit.parentHashes,
                                    commit.decorations, commit.subject});
        }
        gitHistoryGraph_ = algorithms::layoutGitGraph(graphCommits);
        gitHistory_->clear();
        for (const auto& commit : state.history->commits) {
            const auto current = commit.decorations.empty()
                ? QString()
                : QStringLiteral("* ");
            auto* item = new QListWidgetItem(
                QString("%1%2  %3  %4  %5")
                    .arg(current)
                    .arg(fromUtf8(commit.shortHash))
                    .arg(fromUtf8(commit.subject))
                    .arg(fromUtf8(commit.date))
                    .arg(fromUtf8(commit.decorations)), gitHistory_);
            item->setData(GitCommitHashRole, fromUtf8(commit.hash));
            if (commit.hash == selectedGitCommit_.toStdString()) item->setSelected(true);
        }
        gitHistory_->viewport()->update();
    statusBar()->showMessage(uiText(QStringLiteral("%1 Git commits")).arg(gitHistory_->count()), 3000);
    }
    if (gitStashes_ != nullptr && gitStashes_->isVisible() && state.stashes &&
        !state.isLoadingStashes) {
        gitStashes_->clear();
        for (const auto& stash : state.stashes->stashes) {
            auto* item = new QListWidgetItem(
                QString("%1  %2  %3")
                    .arg(fromUtf8(stash.reference))
                    .arg(fromUtf8(stash.message))
                    .arg(fromUtf8(stash.date)), gitStashes_);
            item->setData(GitStashReferenceRole, fromUtf8(stash.reference));
            if (stash.reference == selectedGitStash_.toStdString()) {
                item->setSelected(true);
            }
        }
        gitStashActions_->setVisible(gitStashes_->count() > 0);
    statusBar()->showMessage(uiText(QStringLiteral("%1 stashes")).arg(gitStashes_->count()), 3000);
    }
    if (gitDetails_ != nullptr && gitDetails_->isVisible()) {
        QStringList details;
        if (state.commit && !state.isLoadingCommit) {
            const auto& commit = state.commit->commit;
            details << QString("%1  %2")
                .arg(fromUtf8(commit.hash))
                .arg(fromUtf8(commit.subject));
            details << QString("Author: %1 <%2>")
                .arg(fromUtf8(commit.authorName))
                .arg(fromUtf8(commit.authorEmail));
            details << QString("Date: %1").arg(fromUtf8(commit.date));
            if (!commit.decorations.empty()) {
                details << QString("Refs: %1").arg(fromUtf8(commit.decorations));
            }
        }
        if (state.commitFiles && !state.isLoadingCommitFiles) {
            if (!details.isEmpty()) details << QString();
            details << QStringLiteral("Changed files:");
            if (commitFiles_ != nullptr) commitFiles_->clear();
            for (const auto& file : state.commitFiles->files) {
                details << QString("%1  %2")
                    .arg(fromUtf8(file.status))
                    .arg(fromUtf8(file.path));
                if (commitFiles_ != nullptr) {
                    auto* item = new QListWidgetItem(
                        QString("%1  %2")
                            .arg(fromUtf8(file.status))
                            .arg(fromUtf8(file.path)), commitFiles_);
                    item->setData(RelativePathRole, fromUtf8(file.path));
                }
            }
            if (commitFiles_ != nullptr) commitFiles_->setVisible(!state.commitFiles->files.empty());
            details << QStringLiteral("Double-click a file to review its diff.");
        }
        if (state.comparison && !state.isLoadingComparison) {
            details << QStringLiteral("Compared files:");
            for (const auto& file : state.comparison->files) {
                details << QString("%1  %2")
                    .arg(fromUtf8(file.status))
                    .arg(fromUtf8(file.path));
            }
        }
        if (!details.isEmpty()) gitDetails_->setPlainText(details.join('\n'));
    }
    if (state.blame && !state.isLoadingBlame && editor_ != nullptr &&
        blamePath_ == activePath_) {
        std::vector<EditorBlameAnnotation> annotations;
        annotations.reserve(state.blame->lines.size());
        for (const auto& line : state.blame->lines) {
            if (line.line == 0) continue;
            const auto date = line.authorTime > 0
                ? QDateTime::fromSecsSinceEpoch(line.authorTime).toString(QStringLiteral("yyyy/M/d"))
                : QStringLiteral("Working tree");
            annotations.push_back({static_cast<int>(line.line - 1),
                                   fromUtf8(line.authorName), date});
        }
        editor_->setBlameAnnotations(std::move(annotations));
    }
}

void WorkbenchWindow::renderDiffReview() {
    if (diff_ == nullptr) return;
    diff_->setUpdatesEnabled(false);
    diff_->clearContents();
    diff_->setRowCount(0);
    static_cast<DiffReviewTable*>(diff_)->setConnections({});
    if (diffOverview_ != nullptr) diffOverview_->clear();
    if (!diffReview_) {
        diff_->setVisible(false);
        if (diffReviewPanel_ != nullptr) diffReviewPanel_->setVisible(false);
        diff_->setUpdatesEnabled(true);
        return;
    }

    std::unordered_set<std::string> overviewHunks;
    std::vector<DiffReviewTable::Connection> connections;
    std::optional<DiffReviewTable::Connection> activeConnection;
    const auto finishConnection = [&] {
        if (!activeConnection) return;
        connections.push_back(*activeConnection);
        activeConnection.reset();
    };
    std::vector<algorithms::DiffRow> rows;
    rows.reserve(diffReview_->rows.size());
    for (std::size_t index = 0; index < diffReview_->rows.size(); ++index) {
        const auto& source = diffReview_->rows[index];
        rows.push_back({source.oldLine,
                        source.newLine,
                        source.left,
                        source.right,
                        diffRowKind(source.kind),
                        source.hunkId.value_or(std::string{}),
                        index});
    }
    const auto display = algorithms::DiffCollapse::plan(rows, expandedDiffRegions_);
    for (const auto& displayRow : display) {
        const auto tableRow = diff_->rowCount();
        diff_->insertRow(tableRow);
        if (displayRow.isCollapsed()) {
            finishConnection();
            const auto& region = displayRow.region();
            auto* item = new QTableWidgetItem(
                QString("... %1 context lines hidden; click to expand")
                    .arg(static_cast<qulonglong>(region.hiddenRowCount())));
            item->setData(DiffRegionRole, fromUtf8(region.id));
            item->setBackground(diffBackground(algorithms::DiffRowKind::Information));
            item->setTextAlignment(Qt::AlignLeft | Qt::AlignVCenter);
            diff_->setItem(tableRow, 0, item);
            diff_->setSpan(tableRow, 0, 1, 2);
            diff_->setRowHeight(tableRow, 24);
            continue;
        }

        const auto& row = displayRow.row();
        const auto kind = row.kind;
        const auto isDifference = kind == algorithms::DiffRowKind::Changed ||
            kind == algorithms::DiffRowKind::Addition ||
            kind == algorithms::DiffRowKind::Removal;
        if (isDifference && (row.hasLeft() || row.hasRight())) {
            if (!activeConnection || activeConnection->kind != kind ||
                activeConnection->lastRow != tableRow - 1) {
                finishConnection();
                activeConnection = DiffReviewTable::Connection{tableRow, tableRow, kind};
            } else {
                activeConnection->lastRow = tableRow;
            }
        } else {
            finishConnection();
        }
        auto right = row.right;
        if (kind == algorithms::DiffRowKind::Context && !right) right = row.left;
        auto* leftItem = new QTableWidgetItem(numberedDiffText(row.oldLine, row.left));
        auto* rightItem = new QTableWidgetItem(numberedDiffText(row.newLine, right));
        const auto background = diffBackground(kind);
        leftItem->setBackground(background);
        rightItem->setBackground(background);
        leftItem->setData(DiffHunkRole, fromUtf8(row.hunkId));
        rightItem->setData(DiffHunkRole, fromUtf8(row.hunkId));
        diff_->setItem(tableRow, 0, leftItem);
        diff_->setItem(tableRow, 1, rightItem);
        if (diffOverview_ != nullptr && !row.hunkId.empty() &&
            overviewHunks.insert(row.hunkId).second) {
            auto* overview = new QListWidgetItem(
                QStringLiteral("Hunk %1").arg(diffOverview_->count() + 1), diffOverview_);
            overview->setData(DiffOverviewRowRole, tableRow);
            overview->setData(DiffHunkRole, fromUtf8(row.hunkId));
            overview->setToolTip(fromUtf8(row.hunkId));
            overview->setBackground(diffBackground(kind));
        }
        if (kind == algorithms::DiffRowKind::Information) {
            diff_->setSpan(tableRow, 0, 1, 2);
        }
        diff_->setRowHeight(tableRow, kind == algorithms::DiffRowKind::Information ? 25 : 21);
    }
    finishConnection();
    static_cast<DiffReviewTable*>(diff_)->setConnections(std::move(connections));
    const auto hasRows = diff_->rowCount() > 0;
    diff_->setVisible(hasRows);
    if (diffOverview_ != nullptr) diffOverview_->setVisible(!overviewHunks.empty());
    if (diffReviewPanel_ != nullptr) diffReviewPanel_->setVisible(hasRows);
    diff_->setUpdatesEnabled(true);
    diff_->viewport()->update();
}

void WorkbenchWindow::stageSelectedHunk() {
    applySelectedHunk(QStringLiteral("stage"));
}

void WorkbenchWindow::unstageSelectedHunk() {
    applySelectedHunk(QStringLiteral("unstage"));
}

void WorkbenchWindow::discardSelectedHunk() {
    applySelectedHunk(QStringLiteral("discard"));
}

void WorkbenchWindow::applySelectedHunk(const QString& mode) {
    if (selectedDiffHunk_.isEmpty()) return;
    const auto state = gitFeature_->state();
    if (!state.diff || state.isApplying) return;
    const auto hunk = std::find_if(state.diff->hunks.begin(), state.diff->hunks.end(),
        [this](const GitDiffHunkDto& value) {
            return value.id == selectedDiffHunk_.toUtf8().toStdString();
        });
    if (hunk == state.diff->hunks.end()) return;
    gitFeature_->apply(hunk->patch, mode.toStdString(), [this](app::GitFeatureState next) {
        QMetaObject::invokeMethod(this, [this, next = std::move(next)]() mutable {
            applyGitState(next);
            loadSnapshot();
            if (!activePath_.isEmpty()) {
                gitFeature_->loadDiff({activePath_.toUtf8().toStdString()}, false, false,
                    [this](app::GitFeatureState state) {
                    QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                        applyGitState(state);
                    }, Qt::QueuedConnection);
                });
            }
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::stageAllChanges() {
    if (!gitFeature_ || workspaceRoot_.isEmpty()) return;
    gitFeature_->stageAll([this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            if (state.error) {
                showFeatureError(state.error, QStringLiteral("Could not stage changes"));
                return;
            }
    statusBar()->showMessage(uiText(QStringLiteral("All changes staged")), 3000);
            loadSnapshot();
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::commitChanges() {
    if (!gitFeature_ || workspaceRoot_.isEmpty() || commitEditor_ == nullptr) return;
    const auto message = commitEditor_->toPlainText().trimmed();
    if (message.isEmpty()) {
    statusBar()->showMessage(uiText(QStringLiteral("Enter a commit message first")), 4000);
        commitEditor_->setFocus();
        return;
    }
    const auto amend = amendCommit_ != nullptr && amendCommit_->isChecked();
    gitFeature_->commit(message.toUtf8().toStdString(), amend,
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            if (state.error) {
                showFeatureError(state.error, QStringLiteral("Commit failed"));
                return;
            }
            if (state.isWriting) return;
            if (commitEditor_ != nullptr) commitEditor_->clear();
    statusBar()->showMessage(uiText(QStringLiteral("Commit created")), 4000);
            loadSnapshot();
        }, Qt::QueuedConnection);
    });
}

app::AICommitSettings WorkbenchWindow::loadAISettings() const {
    app::AICommitSettings settings;
    const auto endpoint = keyValueStore_.read("ai.commit.endpoint");
    const auto model = keyValueStore_.read("ai.commit.model");
    if (!endpoint || !model || endpoint->empty() || model->empty()) return settings;

    app::AICommitProvider provider;
    provider.id = "default";
    provider.name = "Default";
    provider.endpoint = *endpoint;
    provider.model = *model;
    provider.apiKeyIdentifier = "lithe/ai/default/api-key";
    if (const auto value = keyValueStore_.read("ai.commit.protocol")) {
        const auto index = QString::fromUtf8(value->data()).toInt();
        if (index >= 0 && index <= 2) {
            provider.protocol = static_cast<app::AICommitAPIProtocol>(index);
        }
    }
    if (const auto value = keyValueStore_.read("ai.commit.authentication")) {
        const auto index = QString::fromUtf8(value->data()).toInt();
        if (index >= 0 && index <= 1) {
            provider.authentication = static_cast<app::AICommitAuthentication>(index);
        }
    }
    if (const auto value = keyValueStore_.read("ai.commit.allowInsecureHTTP")) {
        provider.allowsInsecureHTTP = *value == "1";
    }
    settings.providers.push_back(std::move(provider));
    settings.activeProviderID = "default";
    if (const auto value = keyValueStore_.read("ai.commit.language")) {
        const auto index = QString::fromUtf8(value->data()).toInt();
        if (index >= 0 && index <= 1) {
            settings.language = static_cast<app::AICommitLanguage>(index);
        }
    }
    if (const auto value = keyValueStore_.read("ai.commit.format")) {
        const auto index = QString::fromUtf8(value->data()).toInt();
        if (index >= 0 && index <= 5) {
            settings.format = static_cast<app::AICommitFormat>(index);
        }
    }
    if (const auto value = keyValueStore_.read("ai.commit.customInstructions")) {
        settings.customInstructions = *value;
    }
    if (const auto value = keyValueStore_.read("ai.commit.includeBody")) {
        settings.includeBody = *value == "1";
    }
    if (const auto value = keyValueStore_.read("ai.commit.subjectMaximumLength")) {
        const auto number = QString::fromUtf8(value->data()).toULongLong();
        if (number > 0) settings.subjectMaximumLength = static_cast<std::size_t>(number);
    }
    if (const auto value = keyValueStore_.read("ai.commit.maximumDiffCharacters")) {
        const auto number = QString::fromUtf8(value->data()).toULongLong();
        if (number > 0) settings.maximumDiffCharacters = static_cast<std::size_t>(number);
    }
    if (const auto value = keyValueStore_.read("ai.commit.reasoningEffort")) {
        settings.reasoningEffort = *value;
    }
    return settings;
}

bool WorkbenchWindow::saveAISettings(const app::AICommitSettings& settings,
                                     std::string& error) {
    if (settings.providers.empty()) {
        error = "No AI provider is configured";
        return false;
    }
    const auto& provider = settings.providers.front();
    const auto write = [this, &error](const std::string& key, const std::string& value) {
        return keyValueStore_.write(key, value, error);
    };
    return write("ai.commit.endpoint", provider.endpoint) &&
        write("ai.commit.model", provider.model) &&
        write("ai.commit.protocol", std::to_string(enumIndex(provider.protocol))) &&
        write("ai.commit.authentication", std::to_string(enumIndex(provider.authentication))) &&
        write("ai.commit.allowInsecureHTTP", provider.allowsInsecureHTTP ? "1" : "0") &&
        write("ai.commit.language", std::to_string(enumIndex(settings.language))) &&
        write("ai.commit.format", std::to_string(enumIndex(settings.format))) &&
        write("ai.commit.customInstructions", settings.customInstructions) &&
        write("ai.commit.includeBody", settings.includeBody ? "1" : "0") &&
        write("ai.commit.subjectMaximumLength", std::to_string(settings.subjectMaximumLength)) &&
        write("ai.commit.maximumDiffCharacters", std::to_string(settings.maximumDiffCharacters)) &&
        write("ai.commit.reasoningEffort", settings.reasoningEffort);
}

std::optional<app::AICommitSettings> WorkbenchWindow::configureAISettings() {
    auto settings = loadAISettings();
    app::AICommitProvider provider;
    if (!settings.providers.empty()) provider = settings.providers.front();
    if (provider.endpoint.empty()) provider.endpoint = "https://api.openai.com/v1";
    if (provider.model.empty()) provider.model = "gpt-4.1-mini";
    provider.id = "default";
    provider.name = "Default";
    provider.apiKeyIdentifier = "lithe/ai/default/api-key";

    QDialog dialog(this);
    dialog.setWindowTitle(QStringLiteral("AI Commit Message Settings"));
    auto* form = new QFormLayout(&dialog);
    auto* endpoint = new QLineEdit(QString::fromUtf8(provider.endpoint.data()), &dialog);
    auto* model = new QLineEdit(QString::fromUtf8(provider.model.data()), &dialog);
    auto* apiKey = new QLineEdit(&dialog);
    apiKey->setEchoMode(QLineEdit::Password);
    apiKey->setPlaceholderText(QStringLiteral("Leave blank to keep the stored key"));
    auto* protocol = new QComboBox(&dialog);
    protocol->addItems({QStringLiteral("OpenAI Responses"),
                        QStringLiteral("OpenAI Chat Completions"),
                        QStringLiteral("Anthropic Messages")});
    protocol->setCurrentIndex(enumIndex(provider.protocol));
    auto* authentication = new QComboBox(&dialog);
    authentication->addItems({QStringLiteral("Bearer"), QStringLiteral("API key")});
    authentication->setCurrentIndex(enumIndex(provider.authentication));
    auto* language = new QComboBox(&dialog);
    language->addItems({QStringLiteral("English"), QStringLiteral("Simplified Chinese")});
    language->setCurrentIndex(enumIndex(settings.language));
    auto* format = new QComboBox(&dialog);
    format->addItems({QStringLiteral("Conventional"), QStringLiteral("Concise"),
                      QStringLiteral("Imperative"), QStringLiteral("Descriptive"),
                      QStringLiteral("Release note"), QStringLiteral("Custom")});
    format->setCurrentIndex(enumIndex(settings.format));
    auto* custom = new QLineEdit(QString::fromUtf8(settings.customInstructions.data()), &dialog);
    auto* includeBody = new QCheckBox(QStringLiteral("Allow a short commit body"), &dialog);
    includeBody->setChecked(settings.includeBody);
    auto* insecure = new QCheckBox(QStringLiteral("Allow insecure HTTP"), &dialog);
    insecure->setChecked(provider.allowsInsecureHTTP);
    form->addRow(QStringLiteral("Endpoint"), endpoint);
    form->addRow(QStringLiteral("Model"), model);
    form->addRow(QStringLiteral("API key"), apiKey);
    form->addRow(QStringLiteral("Protocol"), protocol);
    form->addRow(QStringLiteral("Authentication"), authentication);
    form->addRow(QStringLiteral("Language"), language);
    form->addRow(QStringLiteral("Format"), format);
    form->addRow(QStringLiteral("Custom instructions"), custom);
    form->addRow(includeBody);
    form->addRow(insecure);
    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dialog);
    form->addRow(buttons);
    connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    if (dialog.exec() != QDialog::Accepted) return std::nullopt;

    provider.endpoint = endpoint->text().trimmed().toUtf8().toStdString();
    provider.model = model->text().trimmed().toUtf8().toStdString();
    provider.protocol = static_cast<app::AICommitAPIProtocol>(protocol->currentIndex());
    provider.authentication = static_cast<app::AICommitAuthentication>(
        authentication->currentIndex());
    provider.allowsInsecureHTTP = insecure->isChecked();
    settings.language = static_cast<app::AICommitLanguage>(language->currentIndex());
    settings.format = static_cast<app::AICommitFormat>(format->currentIndex());
    settings.customInstructions = custom->text().toUtf8().toStdString();
    settings.includeBody = includeBody->isChecked();
    settings.providers = {provider};
    settings.activeProviderID = provider.id;
    if (provider.endpoint.empty() || provider.model.empty()) {
    statusBar()->showMessage(uiText(QStringLiteral("AI endpoint and model are required")), 5000);
        return std::nullopt;
    }
    const auto key = apiKey->text().toUtf8().toStdString();
    if (!key.empty()) {
        std::string secureError;
        if (!secureStore_.write(provider.apiKeyIdentifier, key, secureError)) {
            statusBar()->showMessage(QStringLiteral("Could not store the AI API key: ") +
                                         fromUtf8(secureError), 5000);
            return std::nullopt;
        }
    }
    std::string persistenceError;
    if (!saveAISettings(settings, persistenceError)) {
        statusBar()->showMessage(QStringLiteral("Could not save AI settings: ") +
                                     fromUtf8(persistenceError), 5000);
        return std::nullopt;
    }
    return settings;
}

void WorkbenchWindow::startAIGeneration(app::AICommitInput input,
                                        app::AICommitSettings settings) {
    if (aiGenerating_.exchange(true)) return;
    if (aiWorker_.joinable()) aiWorker_.join();
    const auto workspaceEpoch = workspaceEpoch_;
    statusBar()->showMessage(uiText(QStringLiteral("Generating commit message...")));
    aiWorker_ = std::thread([this, workspaceEpoch, input = std::move(input),
                              settings = std::move(settings)] {
        app::AICommitError error;
        auto message = aiCommitService_.generate(input, settings, error);
        aiGenerating_.store(false);
        QMetaObject::invokeMethod(this, [this, workspaceEpoch, message = std::move(message),
                                          error = std::move(error)]() mutable {
            if (workspaceEpoch_ != workspaceEpoch) return;
            if (!error.message.empty()) {
                statusBar()->showMessage(QStringLiteral("AI message failed: ") +
                                             fromUtf8(error.message), 8000);
                return;
            }
            if (commitEditor_ != nullptr) commitEditor_->setPlainText(fromUtf8(message));
    statusBar()->showMessage(uiText(QStringLiteral("AI commit message ready")), 4000);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::generateAICommitMessage() {
    if (aiGenerating_.load() || !gitFeature_ || workspaceRoot_.isEmpty()) return;
    auto settings = loadAISettings();
    if (settings.providers.empty()) {
        const auto configured = configureAISettings();
        if (!configured) return;
        settings = *configured;
    }
    const auto gitState = gitFeature_->state();
    if (!gitState.status || gitState.isLoadingStatus) {
        statusBar()->showMessage(QStringLiteral("Refresh Git status before generating a message"),
                                 5000);
        return;
    }
    std::vector<std::string> stagedPaths;
    std::map<std::string, std::string> changeKinds;
    for (const auto& change : gitState.status->changes) {
        if (!change.staged) continue;
        stagedPaths.push_back(change.path);
        changeKinds.emplace(change.path, change.status);
    }
    if (stagedPaths.empty()) {
    statusBar()->showMessage(uiText(QStringLiteral("There are no staged changes")), 5000);
        return;
    }
    const auto workspaceEpoch = workspaceEpoch_;
    gitFeature_->loadStagedDiffs(std::move(stagedPaths),
        [this, workspaceEpoch, settings = std::move(settings),
         changeKinds = std::move(changeKinds)](
            std::vector<app::GitStagedDiff> diffs, std::optional<CoreError> error) mutable {
        QMetaObject::invokeMethod(this, [this, workspaceEpoch, diffs = std::move(diffs),
                                          error = std::move(error),
                                          settings = std::move(settings),
                                          changeKinds = std::move(changeKinds)]() mutable {
            if (workspaceEpoch_ != workspaceEpoch) return;
            if (error) {
                showFeatureError(error, QStringLiteral("Could not load staged diff"));
                return;
            }
            app::AICommitInput input;
            for (const auto& stagedDiff : diffs) {
                if (stagedDiff.diff.patch.empty()) continue;
                if (stagedDiffContainsSensitiveFile(stagedDiff.diff.patch)) {
                    statusBar()->showMessage(
                        QStringLiteral("The staged diff contains a sensitive file; AI generation was blocked"),
                        7000);
                    return;
                }
                const auto& path = stagedDiff.path;
                const auto kind = changeKinds.contains(path)
                    ? changeKinds.at(path)
                    : std::string("modified");
                input.files.push_back({path, kind, stagedDiff.diff.patch});
            }
            if (input.files.empty()) {
    statusBar()->showMessage(uiText(QStringLiteral("There is no staged textual diff")), 5000);
                return;
            }
            startAIGeneration(std::move(input), std::move(settings));
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::checkForUpdates() {
    if (updateBusy_.exchange(true)) return;
    if (updateWorker_.joinable()) updateWorker_.join();
    statusBar()->showMessage(uiText(QStringLiteral("Checking for Windows updates...")));
    updateWorker_ = std::thread([this] {
        constexpr std::string_view CurrentVersion = "0.1.11";
        app::WindowsUpdateError error;
        auto release = updateService_.checkLatest("1lck/Lithe-IDEA",
                                                  std::string(CurrentVersion), error);
        std::optional<app::WindowsReleaseAsset> asset;
        if (release) asset = updateService_.selectAsset(*release, "x64", error);
        updateBusy_.store(false);
        QMetaObject::invokeMethod(this, [this, release = std::move(release),
                                          asset = std::move(asset),
                                          error = std::move(error)]() mutable {
            if (!release || !asset) {
                if (error.code == app::WindowsUpdateErrorCode::NoPublishedRelease) {
    statusBar()->showMessage(uiText(QStringLiteral("Lithe is up to date")), 4000);
                } else {
                    statusBar()->showMessage(uiText(QStringLiteral("Update check failed: ")) +
                                                 fromUtf8(error.message), 8000);
                }
                return;
            }
             const auto answer = QMessageBox::question(
                 this, uiText(QStringLiteral("Windows update available")),
                 uiText(QStringLiteral("Lithe %1 is available. Download the verified installer?"))
                    .arg(fromUtf8(release->version)),
                QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
            if (answer != QMessageBox::Yes) return;
            const auto cache = QString::fromUtf8(storage_->cacheDirectory().data());
            QDir().mkpath(cache);
            const auto filename = QString::fromUtf8(asset->name.data());
            const auto destination = QFileDialog::getSaveFileName(
                 this, uiText(QStringLiteral("Save Windows installer")), QDir(cache).filePath(filename),
                QStringLiteral("Windows installer (*.exe *.msi)"));
            if (!destination.isEmpty()) downloadUpdate(*asset, destination);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::downloadUpdate(const app::WindowsReleaseAsset& asset,
                                     const QString& destination) {
    if (updateBusy_.exchange(true)) return;
    if (updateWorker_.joinable()) updateWorker_.join();
    const auto path = destination;
    updateWorker_ = std::thread([this, asset, path] {
        app::WindowsUpdateError error;
        auto success = updateService_.downloadAndVerify(
            asset, std::filesystem::path(path.toStdWString()), error);
        if (success) {
            std::string signatureError;
            success = authenticodeVerifier_.verify(
                std::filesystem::path(path.toStdWString()), signatureError);
            if (!success) {
                error.code = app::WindowsUpdateErrorCode::SignatureVerificationFailed;
                error.message = std::move(signatureError);
            }
        }
        updateBusy_.store(false);
        QMetaObject::invokeMethod(this, [this, success, path,
                                          error = std::move(error)]() mutable {
            if (!success) {
                 statusBar()->showMessage(uiText(QStringLiteral("Update download failed: ")) +
                                             fromUtf8(error.message), 8000);
                return;
            }
             statusBar()->showMessage(uiText(QStringLiteral("Verified installer downloaded")), 5000);
            const auto answer = QMessageBox::question(
                 this, uiText(QStringLiteral("Installer ready")),
                 uiText(QStringLiteral("The SHA-256 verified installer is ready. Launch it now?")),
                QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
            if (answer != QMessageBox::Yes) return;
            const auto helper = QDir(QCoreApplication::applicationDirPath())
                .filePath(QStringLiteral("lithe_windows_update_helper.exe"));
            const QStringList arguments{
                QStringLiteral("--pid"),
                QString::number(QCoreApplication::applicationPid()),
                QStringLiteral("--installer"),
                path,
            };
            if (!QFileInfo(helper).isExecutable() ||
                !QProcess::startDetached(helper, arguments, QFileInfo(helper).absolutePath())) {
                 statusBar()->showMessage(uiText(QStringLiteral("Could not launch the Windows update helper")),
                                         6000);
                return;
            }
             statusBar()->showMessage(uiText(QStringLiteral("Closing Lithe to install the update")), 5000);
            QCoreApplication::quit();
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::openHistoryItem(QListWidgetItem* item) {
    if (item == nullptr) return;
    const auto contentPath = item->data(HistoryContentPathRole).toString();
    if (contentPath.isEmpty()) return;
    historyContentSelectionPending_ = true;
    historyFeature_->loadContent(contentPath.toUtf8().toStdString(),
        [this](app::HistoryFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyHistoryState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::applyHistoryState(const app::HistoryFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("History request failed"));
        return;
    }
    if (state.isLoadingEntries) return;
    if (state.entries) {
        history_->clear();
        for (const auto& entry : state.entries->entries) {
            auto* item = new QListWidgetItem(
                QString("%1  %2  %3")
                    .arg(fromUtf8(entry.relativePath))
                    .arg(fromUtf8(entry.reason))
                    .arg(QString::number(static_cast<qlonglong>(entry.timestamp))),
                history_);
            item->setData(RelativePathRole, fromUtf8(entry.relativePath));
            item->setData(HistoryContentPathRole, fromUtf8(entry.contentPath));
        }
        history_->setVisible(history_->count() > 0);
    }
    if (historyContentSelectionPending_ && !state.isLoadingContent && state.content) {
        const auto wasSuppressed = suppressEditorChange_;
        suppressEditorChange_ = true;
        editor_->setPlainText(fromUtf8(state.content->text));
        suppressEditorChange_ = wasSuppressed;
        historyContentSelectionPending_ = false;
        statusBar()->showMessage("Local history snapshot loaded", 3000);
    }
}

void WorkbenchWindow::applyShelfState(const app::ShelfFeatureState& state) {
    if (state.error) {
        setShelfActionsEnabled(true);
        showFeatureError(state.error, uiText(QStringLiteral("Shelf request failed")));
        return;
    }
    if (state.isLoading || gitShelves_ == nullptr) return;
    if (state.shelves) {
        gitShelves_->clear();
        for (const auto& shelf : state.shelves->shelves) {
            auto* item = new QListWidgetItem(
                uiText(QStringLiteral("%1  staged:%2  worktree:%3"))
                    .arg(fromUtf8(shelf.label))
                    .arg(static_cast<qulonglong>(shelf.stagedByteCount))
                    .arg(static_cast<qulonglong>(shelf.workingTreeByteCount)),
                gitShelves_);
            item->setData(ShelfIdRole, fromUtf8(shelf.id));
            if (shelf.id == selectedShelf_.toStdString()) gitShelves_->setCurrentItem(item);
        }
        gitShelves_->setVisible(true);
        gitShelfActions_->setVisible(true);
        setShelfActionsEnabled(true);
        statusBar()->showMessage(
            uiText(QStringLiteral("%1 Shelves")).arg(gitShelves_->count()), 3000);
    }
}

void WorkbenchWindow::applyMavenJavaState(const app::MavenJavaFeatureState& state,
                                          bool renderCodeVision,
                                          bool renderStructure) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Project analysis failed"));
        return;
    }
    QStringList parts;
    if (state.maven && state.maven->scan) {
        parts.push_back(QString("Maven %1 (%2)")
            .arg(fromUtf8(state.maven->scan->artifactId))
            .arg(fromUtf8(state.maven->scan->packaging)));
    } else if (state.maven && !state.maven->scan) {
        parts.push_back(uiText(QStringLiteral("No Maven project")));
    }
    if (state.runConfigurations) {
        parts.push_back(uiText(QStringLiteral("%1 run configurations"))
            .arg(static_cast<qulonglong>(state.runConfigurations->configurations.size())));
    }
    if (state.codeVision) {
        parts.push_back(uiText(QStringLiteral("%1 code vision hints"))
            .arg(static_cast<qulonglong>(state.codeVision->hints.size())));
    }
    if (state.structure) {
        parts.push_back(uiText(QStringLiteral("%1 fold regions"))
            .arg(static_cast<qulonglong>(state.structure->foldRegions.size())));
    }
    if (editor_ && activePath_.endsWith(QStringLiteral(".java"), Qt::CaseInsensitive) &&
        (renderCodeVision || renderStructure)) {
        if (renderCodeVision) {
            std::vector<EditorCodeVisionAnnotation> annotations;
            if (appSettings_.showCodeVision && state.codeVision) {
                annotations.reserve(state.codeVision->hints.size());
                for (const auto& hint : state.codeVision->hints) {
                    annotations.push_back({
                        static_cast<int>(hint.line),
                        QStringLiteral("%1 usages  %2")
                            .arg(static_cast<qulonglong>(hint.usageCount))
                            .arg(fromUtf8(hint.symbol)),
                    });
                }
            }
            editor_->setCodeVision(std::move(annotations));
        }
        if (renderStructure) {
            std::vector<EditorCodeVisionAnnotation> markers;
            std::vector<EditorInlayAnnotation> inlays;
            if (state.structure) {
                if (appSettings_.showCodeVision) {
                    markers.reserve(state.structure->implementationMarkers.size());
                    for (const auto& marker : state.structure->implementationMarkers) {
                        markers.push_back({
                            static_cast<int>(marker.line),
                            QStringLiteral("%1 implementations %2")
                                .arg(static_cast<qulonglong>(marker.implementationCount))
                                .arg(marker.direction == "up" ? QStringLiteral("(up)")
                                                                : QStringLiteral("(down)")),
                        });
                    }
                }
                if (appSettings_.showInlayHints) {
                    inlays.reserve(state.structure->inlayHints.size());
                    for (const auto& hint : state.structure->inlayHints) {
                        inlays.push_back({static_cast<int>(hint.line),
                                          static_cast<int>(hint.utf16Column),
                                          QStringLiteral("<%1>").arg(fromUtf8(hint.label))});
                    }
                }
            }
            editor_->setImplementationMarkers(std::move(markers));
            editor_->setInlayHints(std::move(inlays));
        }
    }
    if (!parts.isEmpty()) analysisStatus_->setText(parts.join(QStringLiteral("  |  ")));
    synchronizeJavaRunProject();
}

void WorkbenchWindow::runMavenPhase(const QString& phase) {
    if (workspaceRoot_.isEmpty() || phase.trimmed().isEmpty()) return;
    showToolWindow(BottomToolKind::Build);
    if (mavenSession_ && mavenSession_->isRunning()) mavenSession_->stop();

    app::MavenBuildRequest request;
    request.projectRoot = std::filesystem::path(workspaceRoot_.toStdWString());
    request.phase = phase.toStdString();
    std::string error;
    const auto process = mavenBuildService_.makeRequest(request, error);
    mavenOutput_->clear();
    if (!process) {
        appendMavenOutput(QStringLiteral("Unable to start Maven: ") + fromUtf8(error) +
                          QStringLiteral("\n"));
    statusBar()->showMessage(uiText(QStringLiteral("Maven could not start")), 5000);
        return;
    }

    QStringList arguments;
    for (const auto& argument : process->arguments) arguments.push_back(fromUtf8(argument));
    appendMavenOutput(QStringLiteral("$ ") + fromUtf8(process->executablePath) +
                      QStringLiteral(" ") + arguments.join(QStringLiteral(" ")) +
                      QStringLiteral("\n\n"));
    mavenSession_->start(*process);
    statusBar()->showMessage(uiText(QStringLiteral("Maven %1 is running")).arg(phase));
}

void WorkbenchWindow::stopMavenBuild() {
    if (!mavenSession_ || !mavenSession_->isRunning()) return;
    appendMavenOutput(QStringLiteral("\nStopping Maven...\n"));
    mavenSession_->stop();
}

void WorkbenchWindow::appendMavenOutput(const QString& text) {
    if (mavenOutput_ == nullptr || text.isEmpty()) return;
    mavenOutput_->moveCursor(QTextCursor::End);
    mavenOutput_->insertPlainText(text);
    constexpr int maximumOutputCharacters = 500000;
    const auto value = mavenOutput_->toPlainText();
    if (value.size() > maximumOutputCharacters) {
        mavenOutput_->setPlainText(value.right(maximumOutputCharacters));
        mavenOutput_->moveCursor(QTextCursor::End);
    }
}

void WorkbenchWindow::applyMavenLifecycle(const ProcessLifecycleEvent& event) {
    switch (event.state) {
    case ProcessLifecycleState::Starting:
    statusBar()->showMessage(uiText(QStringLiteral("Starting Maven")));
        break;
    case ProcessLifecycleState::Running:
    statusBar()->showMessage(uiText(QStringLiteral("Maven is running")));
        break;
    case ProcessLifecycleState::Stopping:
    statusBar()->showMessage(uiText(QStringLiteral("Stopping Maven")));
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") + fromUtf8(event.message) +
                                                      QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Failed:
    statusBar()->showMessage(uiText(QStringLiteral("Maven failed to start")), 5000);
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") + fromUtf8(event.message) +
                                                      QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Finished:
        statusBar()->showMessage(uiText(QStringLiteral("Maven finished with exit code %1"))
                                     .arg(event.exitCode.value_or(1)), 5000);
        appendMavenOutput(QStringLiteral("\nMaven finished with exit code ") +
                          QString::number(event.exitCode.value_or(1)) + QStringLiteral("\n"));
        if (!workspaceRoot_.isEmpty()) {
            mavenJavaFeature_->parseMavenDiagnostics(
                mavenOutput_->toPlainText().toUtf8().toStdString(),
                [this](app::MavenJavaFeatureState state) {
                    QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                        applyMavenJavaState(state);
                    }, Qt::QueuedConnection);
                });
        }
        break;
    }
}

void WorkbenchWindow::synchronizeJavaRunProject() {
    if (workspaceRoot_.isEmpty() || !javaRunService_) return;
    app::JavaRunProject project;
    project.root = std::filesystem::path(workspaceRoot_.toStdWString());
    const auto workspaceState = workspaceFeature_->state();
    if (workspaceState.snapshot) {
        project.files.reserve(workspaceState.snapshot->files.size());
        for (const auto& path : workspaceState.snapshot->files) {
            project.files.push_back(project.root /
                std::filesystem::path(QString::fromUtf8(path.data(),
                    static_cast<qsizetype>(path.size())).toStdWString()));
        }
    }
    const auto analysisState = mavenJavaFeature_->state();
    if (analysisState.maven && analysisState.maven->scan) {
        project.maven = *analysisState.maven->scan;
    }
    if (analysisState.runConfigurations) {
        project.configurations = analysisState.runConfigurations->configurations;
    }
    javaRunService_->setProject(std::move(project));
}

void WorkbenchWindow::runCurrentJava() {
    const JavaRunConfigurationDto configuration{
        "current-file", "Current File", "currentFile", std::nullopt, std::nullopt};
    runJavaConfiguration(configuration);
}

void WorkbenchWindow::runSpringBoot() {
    synchronizeJavaRunProject();
    const auto& project = javaRunService_->project();
    const auto found = std::find_if(project.configurations.begin(), project.configurations.end(),
        [](const JavaRunConfigurationDto& configuration) {
            return configuration.kind == "springBoot";
        });
    if (found == project.configurations.end()) {
    statusBar()->showMessage(uiText(QStringLiteral("No Spring Boot run configuration was detected")),
                                 5000);
        return;
    }
    runJavaConfiguration(*found);
}

void WorkbenchWindow::runJavaConfiguration(const JavaRunConfigurationDto& configuration) {
    if (workspaceRoot_.isEmpty() || !javaRunService_ || !javaSession_) return;
    if (javaSession_->isRunning()) javaSession_->stop();
    synchronizeJavaRunProject();
    std::optional<std::filesystem::path> currentFile;
    if (configuration.kind == "currentFile") {
        if (activePath_.isEmpty()) {
    statusBar()->showMessage(uiText(QStringLiteral("Open a Java file before running it")), 5000);
            return;
        }
        currentFile = std::filesystem::path(workspaceRoot_.toStdWString()) /
                      std::filesystem::path(activePath_.toStdWString());
    }
    std::string error;
    const app::JavaRunOptions options;
    const auto process = javaRunService_->makeRequest(
        configuration, options, std::move(currentFile), error);
    mavenOutput_->clear();
    if (!process) {
        appendMavenOutput(QStringLiteral("Unable to run Java: ") + fromUtf8(error) +
                          QStringLiteral("\n"));
    statusBar()->showMessage(uiText(QStringLiteral("Java run could not start")), 5000);
        return;
    }
    QStringList arguments;
    for (const auto& argument : process->arguments) arguments.push_back(fromUtf8(argument));
    appendMavenOutput(QStringLiteral("$ ") + fromUtf8(process->executablePath) +
                      QStringLiteral(" ") + arguments.join(QStringLiteral(" ")) +
                      QStringLiteral("\n\n"));
    javaSession_->start(*process);
        statusBar()->showMessage(uiText(QStringLiteral("%1 is running"))
                                 .arg(fromUtf8(configuration.name)));
}

void WorkbenchWindow::stopJavaRun() {
    if (!javaSession_ || !javaSession_->isRunning()) return;
    appendMavenOutput(QStringLiteral("\nStopping Java...\n"));
    javaSession_->stop();
}

void WorkbenchWindow::applyJavaLifecycle(const ProcessLifecycleEvent& event) {
    switch (event.state) {
    case ProcessLifecycleState::Starting:
    statusBar()->showMessage(uiText(QStringLiteral("Starting Java")));
        break;
    case ProcessLifecycleState::Running:
    statusBar()->showMessage(uiText(QStringLiteral("Java is running")));
        break;
    case ProcessLifecycleState::Stopping:
    statusBar()->showMessage(uiText(QStringLiteral("Stopping Java")));
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") +
                                                       fromUtf8(event.message) +
                                                       QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Failed:
    statusBar()->showMessage(uiText(QStringLiteral("Java failed to start")), 5000);
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") +
                                                       fromUtf8(event.message) +
                                                       QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Finished:
        statusBar()->showMessage(uiText(QStringLiteral("Java finished with exit code %1"))
                                     .arg(event.exitCode.value_or(1)), 5000);
        appendMavenOutput(QStringLiteral("\nJava finished with exit code ") +
                          QString::number(event.exitCode.value_or(1)) + QStringLiteral("\n"));
        break;
    }
}

void WorkbenchWindow::debugCurrentJava() {
    if (workspaceRoot_.isEmpty() || activePath_.isEmpty() ||
        !activePath_.endsWith(QStringLiteral(".java"), Qt::CaseInsensitive)) {
    statusBar()->showMessage(uiText(QStringLiteral("Open a Java file before debugging it")), 5000);
        return;
    }
    showToolWindow(BottomToolKind::Debug);
    const auto file = std::filesystem::path(workspaceRoot_.toStdWString()) /
                      std::filesystem::path(activePath_.toStdWString());
    javaDebugService_->startCurrentFile(file, editor_->toPlainText().toUtf8().toStdString(), {});
}

void WorkbenchWindow::debugSpringBoot() {
    synchronizeJavaRunProject();
    const auto& project = javaRunService_->project();
    const auto found = std::find_if(project.configurations.begin(), project.configurations.end(),
        [](const JavaRunConfigurationDto& configuration) {
            return configuration.kind == "springBoot";
        });
    if (found == project.configurations.end()) {
        statusBar()->showMessage(QStringLiteral("No Spring Boot run configuration was detected"),
                                 5000);
        return;
    }
    showToolWindow(BottomToolKind::Debug);
    javaDebugService_->startMaven(*found, {});
}

void WorkbenchWindow::attachRemoteDebugger() {
    bool accepted = false;
    const auto host = QInputDialog::getText(this, QStringLiteral("Attach to JDWP"),
                                            QStringLiteral("Host:"), QLineEdit::Normal,
                                            QStringLiteral("127.0.0.1"), &accepted);
    if (!accepted || host.trimmed().isEmpty()) return;
    const auto port = QInputDialog::getInt(this, QStringLiteral("Attach to JDWP"),
                                           QStringLiteral("Port:"), 5005, 1, 65535, 1,
                                           &accepted);
    if (!accepted) return;
    showToolWindow(BottomToolKind::Debug);
    javaDebugService_->attachRemote(host.trimmed().toStdString(),
                                    static_cast<std::uint16_t>(port));
}

void WorkbenchWindow::stopDebugger() {
    if (!javaDebugService_) return;
    javaDebugService_->stop();
    applyJavaDebugState();
}

void WorkbenchWindow::continueDebugger() {
    if (javaDebugService_) javaDebugService_->continueExecution();
}

void WorkbenchWindow::pauseDebugger() {
    if (javaDebugService_) javaDebugService_->pause();
}

void WorkbenchWindow::stepIntoDebugger() {
    if (javaDebugService_) javaDebugService_->stepInto();
}

void WorkbenchWindow::stepOverDebugger() {
    if (javaDebugService_) javaDebugService_->stepOver();
}

void WorkbenchWindow::stepOutDebugger() {
    if (javaDebugService_) javaDebugService_->stepOut();
}

void WorkbenchWindow::toggleBreakpoint() {
    if (!javaDebugService_ || workspaceRoot_.isEmpty() || activePath_.isEmpty() ||
        !activePath_.endsWith(QStringLiteral(".java"), Qt::CaseInsensitive)) {
    statusBar()->showMessage(uiText(QStringLiteral("Open a Java file before adding a breakpoint")),
                                 5000);
        return;
    }
    const auto file = std::filesystem::path(workspaceRoot_.toStdWString()) /
                      std::filesystem::path(activePath_.toStdWString());
    const auto cursor = editor_->textCursor();
    const auto className = app::JavaDebugService::classNameFor(
        file, editor_->toPlainText().toUtf8().toStdString());
    javaDebugService_->toggleBreakpoint(file, cursor.blockNumber() + 1, className);
}

void WorkbenchWindow::inspectDebuggerThreads() {
    if (javaDebugService_) javaDebugService_->inspectThreads();
}

void WorkbenchWindow::inspectDebuggerStack() {
    if (javaDebugService_) javaDebugService_->inspectStack();
}

void WorkbenchWindow::inspectDebuggerVariables() {
    if (javaDebugService_) javaDebugService_->inspectVariables();
}

void WorkbenchWindow::evaluateDebuggerExpression() {
    if (!javaDebugService_ || debugExpression_ == nullptr) return;
    const auto expression = debugExpression_->text().trimmed();
    if (expression.isEmpty()) return;
    javaDebugService_->evaluate(expression.toUtf8().toStdString());
    debugExpression_->clear();
}

void WorkbenchWindow::toggleDebuggerVariable(QListWidgetItem* item) {
    if (!javaDebugService_ || item == nullptr) return;
    const auto id = item->data(Qt::UserRole).toString().toStdString();
    const auto snapshot = javaDebugService_->snapshot();
    std::function<const app::JavaDebugVariable*(
        const std::vector<app::JavaDebugVariable>&)> find =
        [&](const auto& values) -> const app::JavaDebugVariable* {
            for (const auto& value : values) {
                if (value.id == id) return &value;
                if (const auto* child = find(value.children)) return child;
            }
            return nullptr;
        };
    if (const auto* variable = find(snapshot.variables)) {
        javaDebugService_->toggleVariable(*variable);
    }
}

void WorkbenchWindow::applyJavaDebugState() {
    if (!javaDebugService_) return;
    const auto snapshot = javaDebugService_->snapshot();
    const auto stateText = [&snapshot] {
        switch (snapshot.state) {
        case app::JavaDebugSessionState::Idle: return QStringLiteral("idle");
        case app::JavaDebugSessionState::Launching: return QStringLiteral("launching");
        case app::JavaDebugSessionState::Running: return QStringLiteral("running");
        case app::JavaDebugSessionState::Paused: return QStringLiteral("paused");
        case app::JavaDebugSessionState::Finished: return QStringLiteral("finished");
        case app::JavaDebugSessionState::Failed: return QStringLiteral("failed");
        }
        return QStringLiteral("unknown");
    }();
    const auto title = snapshot.runningTargetTitle.empty()
        ? QStringLiteral("Debugger") : fromUtf8(snapshot.runningTargetTitle);
    if (editor_ != nullptr) {
        std::vector<int> breakpointLines;
        const auto currentFile = activePath_.isEmpty()
            ? QString()
            : QFileInfo(QDir(workspaceRoot_).filePath(activePath_)).absoluteFilePath();
        for (const auto& breakpoint : snapshot.breakpoints) {
            const auto breakpointFile = QDir::cleanPath(
                QDir::fromNativeSeparators(fromUtf8(breakpoint.filePath)));
            if (!currentFile.isEmpty() &&
                breakpointFile == QDir::cleanPath(currentFile) && breakpoint.line > 0) {
                breakpointLines.push_back(breakpoint.line - 1);
            }
        }
        editor_->setBreakpoints(std::move(breakpointLines));
    }
    if (debugPanel_ != nullptr) {
        debugPanel_->setVisible(snapshot.state != app::JavaDebugSessionState::Idle ||
                                !snapshot.output.empty());
    }
    if (debugOutput_ != nullptr) {
        debugOutput_->setPlainText(fromUtf8(snapshot.output));
        debugOutput_->moveCursor(QTextCursor::End);
    }
    if (debugVariables_ != nullptr) {
        debugVariables_->clear();
        for (const auto& variable : snapshot.variables) appendDebugVariable(variable, 0);
    }
    if (debugThreads_ != nullptr) {
        debugThreads_->clear();
        for (const auto& thread : snapshot.threads) {
            auto* item = new QListWidgetItem(
                QString("%1%2  %3")
                    .arg(thread.isCurrent ? QStringLiteral("* ") : QString())
                    .arg(fromUtf8(thread.name))
                    .arg(fromUtf8(thread.status)), debugThreads_);
            item->setData(Qt::UserRole, fromUtf8(thread.id));
        }
    }
    if (debugStack_ != nullptr) {
        debugStack_->clear();
        for (const auto& frame : snapshot.callStack) {
            new QListWidgetItem(
                QString("[%1] %2").arg(frame.level).arg(fromUtf8(frame.description)),
                debugStack_);
        }
    }
    if (snapshot.exceptionMessage) {
        statusBar()->showMessage(QStringLiteral("%1: %2")
                                     .arg(title, fromUtf8(*snapshot.exceptionMessage)), 8000);
    } else {
        statusBar()->showMessage(QStringLiteral("%1: %2 (%3 breakpoints)")
                                     .arg(title, stateText)
                                     .arg(static_cast<qulonglong>(snapshot.breakpoints.size())));
    }
}

void WorkbenchWindow::appendDebugVariable(const app::JavaDebugVariable& variable, int depth) {
    if (debugVariables_ == nullptr) return;
    const auto prefix = QString(depth * 2, QLatin1Char(' '));
    const auto marker = variable.canExpand()
        ? (variable.isExpanded ? QStringLiteral("- ") : QStringLiteral("+ "))
        : QStringLiteral("  ");
    auto* item = new QListWidgetItem(
        prefix + marker + fromUtf8(variable.name) + QStringLiteral(" = ") +
            fromUtf8(variable.value), debugVariables_);
    item->setData(Qt::UserRole, fromUtf8(variable.id));
    for (const auto& child : variable.children) appendDebugVariable(child, depth + 1);
}

void WorkbenchWindow::gotoJavaDefinition() {
    if (!languageServer_ || !languageServer_->isReady() || languageServerUri_.empty()) {
    statusBar()->showMessage(uiText(QStringLiteral("Java language server is not ready")), 5000);
        return;
    }
    const auto cursor = editor_->textCursor();
    languageServer_->requestJavaNavigation("textDocument/definition", JsonValue(JsonValue::Object{
        {"textDocument", JsonValue(JsonValue::Object{{"uri", languageServerUri_}})},
        {"position", JsonValue(JsonValue::Object{
            {"line", static_cast<std::int64_t>(cursor.blockNumber())},
            {"character", static_cast<std::int64_t>(cursor.positionInBlock())}})}}),
        languageServerText_,
        static_cast<std::uint64_t>(cursor.blockNumber()),
        static_cast<std::uint64_t>(cursor.positionInBlock()),
        [this](std::optional<JsonValue> result, std::optional<app::LspRpcError> error) {
            QMetaObject::invokeMethod(this, [this, result = std::move(result),
                                              error = std::move(error)]() mutable {
                applyJavaNavigation(result, error, QStringLiteral("Java definitions"));
            }, Qt::QueuedConnection);
        });
}

void WorkbenchWindow::findJavaUsages() {
    if (!languageServer_ || !languageServer_->isReady() || languageServerUri_.empty()) {
        statusBar()->showMessage(QStringLiteral("Java language server is not ready"), 5000);
        return;
    }
    const auto cursor = editor_->textCursor();
    languageServer_->requestJavaNavigation("textDocument/references", JsonValue(JsonValue::Object{
        {"textDocument", JsonValue(JsonValue::Object{{"uri", languageServerUri_}})},
        {"position", JsonValue(JsonValue::Object{
            {"line", static_cast<std::int64_t>(cursor.blockNumber())},
            {"character", static_cast<std::int64_t>(cursor.positionInBlock())}})},
        {"context", JsonValue(JsonValue::Object{{"includeDeclaration", false}})}}),
        languageServerText_,
        static_cast<std::uint64_t>(cursor.blockNumber()),
        static_cast<std::uint64_t>(cursor.positionInBlock()),
        [this](std::optional<JsonValue> result, std::optional<app::LspRpcError> error) {
            QMetaObject::invokeMethod(this, [this, result = std::move(result),
                                              error = std::move(error)]() mutable {
                applyJavaNavigation(result, error, QStringLiteral("Java usages"));
            }, Qt::QueuedConnection);
        });
}

void WorkbenchWindow::applyJavaNavigation(const std::optional<JsonValue>& result,
                                          const std::optional<app::LspRpcError>& error,
                                          const QString& title) {
    if (error) {
        statusBar()->showMessage(title + QStringLiteral(": ") + fromUtf8(error->message), 5000);
        return;
    }
    if (!navigation_) return;
    navigation_->clear();
    if (!result || result->isNull()) {
        navigation_->setVisible(false);
        statusBar()->showMessage(title + QStringLiteral(": no results"), 3000);
        return;
    }
    std::vector<const JsonValue*> locations;
    if (result->isArray()) {
        for (const auto& location : *result->asArray()) locations.push_back(&location);
    } else if (result->isObject()) {
        locations.push_back(&*result);
    }
    for (const auto* location : locations) {
        const auto* uriValue = objectValue(*location, "uri");
        if (uriValue == nullptr) uriValue = objectValue(*location, "targetUri");
        if (uriValue == nullptr || !uriValue->asString()) continue;
        const auto* range = objectValue(*location, "range");
        if (range == nullptr) range = objectValue(*location, "targetSelectionRange");
        if (range == nullptr) range = objectValue(*location, "targetRange");
        const auto* start = range == nullptr ? nullptr : objectValue(*range, "start");
        const auto line = start == nullptr || !objectValue(*start, "line")
            ? 0 : objectValue(*start, "line")->asUInt().value_or(0);
        const auto column = start == nullptr || !objectValue(*start, "character")
            ? 0 : objectValue(*start, "character")->asUInt().value_or(0);
        const auto uri = *uriValue->asString();
        const auto localPath = QDir::fromNativeSeparators(
            QUrl::fromEncoded(QByteArray::fromStdString(uri)).toLocalFile());
        const auto relativeCandidate = localPath.isEmpty()
            ? QString() : normalizedRelativePath(QDir(workspaceRoot_).relativeFilePath(localPath));
        const auto relative = relativeCandidate == QStringLiteral("..") ||
                              relativeCandidate.startsWith(QStringLiteral("../"))
            ? QString() : relativeCandidate;
        const auto displayPath = relative.isEmpty()
            ? (localPath.isEmpty() ? fromUtf8(uri) : localPath) : relative;
        auto* item = new QListWidgetItem(
            QString("%1:%2:%3").arg(displayPath)
                                 .arg(static_cast<qulonglong>(line + 1))
                                 .arg(static_cast<qulonglong>(column + 1)), navigation_);
        if (!relative.isEmpty()) item->setData(RelativePathRole, relative);
        if (relative.isEmpty() && !localPath.isEmpty() && QFileInfo(localPath).isFile()) {
            item->setData(NavigationAbsolutePathRole, QFileInfo(localPath).absoluteFilePath());
        }
        item->setData(NavigationLineRole, static_cast<qulonglong>(line));
        item->setData(NavigationColumnRole, static_cast<qulonglong>(column));
    }
    navigation_->setVisible(navigation_->count() > 0);
    statusBar()->showMessage(QString("%1: %2 results").arg(title)
                                 .arg(navigation_->count()), 4000);
}

void WorkbenchWindow::applyLanguageServerState(bool ready, const std::string& message) {
    if (!ready) {
        if (!message.empty()) statusBar()->showMessage(fromUtf8(message), 5000);
        diagnostics_->clear();
        diagnostics_->setVisible(false);
        return;
    }
    statusBar()->showMessage(fromUtf8(message), 3000);
    synchronizeLanguageServerDocument();
}

void WorkbenchWindow::applyLanguageServerDiagnostics(const std::string& uri,
                                                     const JsonValue& diagnostics) {
    if (uri != languageServerUri_ || diagnostics_ == nullptr) return;
    diagnostics_->clear();
    const auto* entries = diagnostics.asArray();
    if (entries != nullptr) {
        for (const auto& entry : *entries) {
            const auto* range = objectValue(entry, "range");
            const auto* start = range == nullptr ? nullptr : objectValue(*range, "start");
            const auto line = start == nullptr ? std::optional<std::uint64_t>{}
                                               : objectValue(*start, "line")
                                                     ? objectValue(*start, "line")->asUInt()
                                                     : std::nullopt;
            const auto column = start == nullptr ? std::optional<std::uint64_t>{}
                                                 : objectValue(*start, "character")
                                                       ? objectValue(*start, "character")->asUInt()
                                                       : std::nullopt;
            const auto* message = objectValue(entry, "message");
            if (message == nullptr || !message->asString()) continue;
            const auto severity = objectValue(entry, "severity") == nullptr
                ? std::optional<std::uint64_t>{}
                : objectValue(entry, "severity")->asUInt();
            const QString severityText = !severity ? QStringLiteral("info")
                : *severity == 1 ? QStringLiteral("error")
                : *severity == 2 ? QStringLiteral("warning")
                : *severity == 3 ? QStringLiteral("info")
                : QStringLiteral("hint");
            const auto lineText = line ? QString::number(*line + 1) : QStringLiteral("-");
            const auto columnText = column ? QString::number(*column + 1) : QStringLiteral("-");
            auto* item = new QListWidgetItem(QString("[%1] %2:%3  %4")
                .arg(severityText)
                .arg(lineText)
                .arg(columnText)
                .arg(fromUtf8(*message->asString())), diagnostics_);
            item->setData(RelativePathRole, activePath_);
            if (line) item->setData(NavigationLineRole, static_cast<qulonglong>(*line));
            if (column) item->setData(NavigationColumnRole, static_cast<qulonglong>(*column));
        }
    }
    diagnostics_->setVisible(diagnostics_->count() > 0);
    if (diagnostics_->count() > 0) {
    statusBar()->showMessage(uiText(QStringLiteral("%1 Java diagnostics"))
                                     .arg(diagnostics_->count()), 5000);
    }
}

void WorkbenchWindow::ensureJavaLanguageServer() {
    if (workspaceRoot_.isEmpty() || !languageServer_ || !languageServerSession_) return;
    const auto projectRoot = javaProjectRoot(workspaceRoot_, activePath_);
    if (languageServerRoot_ == projectRoot &&
        (languageServer_->isReady() || languageServer_->isStarting())) return;
    languageServerRoot_.clear();
    if (languageServerSession_->isRunning()) languageServer_->stop();
    std::string error;
    const auto root = std::filesystem::path(projectRoot.toStdWString());
    if (!languageServer_->start(root, error)) {
    statusBar()->showMessage(uiText(QStringLiteral("Java language server unavailable: ")) +
                                     fromUtf8(error), 5000);
        return;
    }
    languageServerRoot_ = projectRoot;
}

void WorkbenchWindow::closeLanguageServerDocument() {
    if (languageServerDocumentOpen_ && languageServer_ && languageServer_->isReady() &&
        !languageServerUri_.empty()) {
        languageServer_->didClose(languageServerUri_);
    }
    languageServerDocumentOpen_ = false;
    languageServerPath_.clear();
    languageServerUri_.clear();
    languageServerText_.clear();
    if (diagnostics_ != nullptr) {
        diagnostics_->clear();
        diagnostics_->setVisible(false);
    }
}

void WorkbenchWindow::synchronizeLanguageServerDocument() {
    if (!languageServer_ || !languageServer_->isReady() || languageServerPath_.isEmpty()) return;
    const auto filePath = QFileInfo(QDir(workspaceRoot_).filePath(languageServerPath_))
                              .absoluteFilePath();
    languageServerUri_ = QUrl::fromLocalFile(filePath)
                             .toString(QUrl::FullyEncoded)
                             .toUtf8().toStdString();
    if (languageServerDocumentOpen_) return;
    languageServer_->didOpen(languageServerUri_, "java", 1, languageServerText_);
    languageServerDocumentOpen_ = true;
}

void WorkbenchWindow::startTerminal() {
    if (workspaceRoot_.isEmpty() || !terminal_) return;
    showToolWindow(BottomToolKind::Terminal);
    terminalPanel_->setVisible(true);
    if (terminal_->isRunning()) {
        terminalInput_->setFocus();
        return;
    }
    terminalOutput_->clear();
    const auto environment = runtimeLocator_.environment();
    std::string shell = appSettings_.terminalShellPath;
    if (shell.empty()) {
        shell = "cmd.exe";
        for (const auto& [key, value] : environment) {
            if (key.size() == 7 && std::equal(key.begin(), key.end(), "ComSpec",
                    [](char left, char right) {
                        return std::tolower(static_cast<unsigned char>(left)) ==
                               std::tolower(static_cast<unsigned char>(right));
                    })) {
                shell = value;
                break;
            }
        }
    }
    ProcessRequest request;
    request.operationID = "windows-terminal-" +
        std::to_string(static_cast<unsigned long long>(QDateTime::currentMSecsSinceEpoch()));
    request.executablePath = shell;
    request.workingDirectory = workspaceRoot_.toStdString();
    request.environment = environment;
    terminal_->start(request);
    terminalInput_->setFocus();
    statusBar()->showMessage(uiText(QStringLiteral("Terminal started")), 3000);
}

void WorkbenchWindow::stopTerminal() {
    if (terminal_) terminal_->stop();
    if (terminalPanel_) terminalPanel_->setVisible(false);
}

void WorkbenchWindow::saveDocument() {
    if (workspaceRoot_.isEmpty() || activePath_.isEmpty() || editor_->isReadOnly()) return;
    const auto savedPath = activePath_;
    documentFeature_->setText(editor_->toPlainText().toUtf8().toStdString());
    documentFeature_->save([this, savedPath](app::DocumentFeatureState state) {
        QMetaObject::invokeMethod(this, [this, savedPath,
                                          state = std::move(state)]() mutable {
            if (!sameRelativePath(savedPath, activePath_) ||
                !sameRelativePath(savedPath, fromUtf8(state.relativePath))) return;
            applySaveState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::applySaveState(const app::DocumentFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("File save failed"));
        return;
    }
    if (state.isSaving || state.relativePath.empty()) return;
    activePath_ = fromUtf8(state.relativePath);
    statusBar()->showMessage(uiText(QStringLiteral("Saved %1")).arg(activePath_), 3000);
    const auto savedPath = activePath_;
    historyFeature_->record(
        activePath_.toUtf8().toStdString(), "saved", state.text, true,
        [this, savedPath](app::HistoryFeatureState historyState) {
        QMetaObject::invokeMethod(this, [this, savedPath,
                                          historyState = std::move(historyState)]() mutable {
            if (!sameRelativePath(savedPath, activePath_)) return;
            applyHistoryState(historyState);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::showFeatureError(const std::optional<CoreError>& error,
                                       const QString& fallback) {
    const auto message = error && !error->message.empty()
        ? fromUtf8(error->message)
        : fallback;
    statusBar()->showMessage(message, 5000);
}

} // namespace lithe::windows
