#include "workbench_window.h"

#include "diff_collapse.h"
#include "diff_split_layout.h"
#include "diff_split_widget.h"
#include "workbench_code_editor.h"
#include "workbench_icons.h"
#include "workbench_ui_theme.h"
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
#include <QToolButton>
#include <QButtonGroup>
#include <QStackedWidget>
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
constexpr int NavigationLineRole = Qt::UserRole + 4;
constexpr int NavigationColumnRole = Qt::UserRole + 5;
constexpr int GitCommitHashRole = Qt::UserRole + 7;
constexpr int GitStashReferenceRole = Qt::UserRole + 8;
constexpr int NavigationAbsolutePathRole = Qt::UserRole + 10;

algorithms::DiffRowKind diffRowKind(std::string_view kind) {
    if (kind == "changed") return algorithms::DiffRowKind::Changed;
    if (kind == "addition") return algorithms::DiffRowKind::Addition;
    if (kind == "removal") return algorithms::DiffRowKind::Removal;
    if (kind == "information") return algorithms::DiffRowKind::Information;
    return algorithms::DiffRowKind::Context;
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

} // namespace

WorkbenchWindow::WorkbenchWindow(std::unique_ptr<DirectoryChangeSource> watcher,
                                 QWidget* parent)
    : QMainWindow(parent),
      keyValueStore_(),
      recentProjectsStore_(keyValueStore_),
      workspaceSessionStore_(keyValueStore_),
      appSettingsStore_(keyValueStore_),
      appSettings_(appSettingsStore_.load()),
      runtimeLocator_(),
      runtimeService_(runtimeLocator_),
      mavenRunner_(),
      archiveRunner_(),
      archiveReader_(archiveRunner_),
      mavenBuildService_(runtimeService_, mavenRunner_),
      coordinator_(std::make_unique<app::WorkbenchCoordinator>()),
      storage_(std::make_unique<Win32FileStorage>()),
      dirtyDocuments_(std::make_unique<app::FakeDirtyDocumentsPort>()),
      shelveService_(std::make_unique<app::ShelveService>(*storage_)),
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
      gitFeature_(std::make_unique<app::GitFeatureModel>(
          *coordinator_, dirtyDocuments_.get(), shelveService_.get())),
      historyFeature_(std::make_unique<app::HistoryFeatureModel>(*coordinator_, *storage_)),
      mavenJavaFeature_(std::make_unique<app::MavenJavaFeatureModel>(*coordinator_)),
      mavenSession_(std::make_unique<Win32ProcessSession>()),
      javaSession_(std::make_unique<Win32ProcessSession>()),
      languageServerSession_(std::make_unique<Win32ProcessSession>()),
      languageServer_(std::make_unique<app::JavaLanguageServerClient>(
          runtimeService_, *storage_, *languageServerSession_, &archiveReader_)),
      watcher_(std::move(watcher)),
      terminal_(std::make_unique<Win32TerminalTransport>()) {
    if (qApp != nullptr) qApp->installEventFilter(this);
    setWindowTitle("Lithe");
    resize(1280, 800);

    gitFeature_->setOperationLifecycleHandlers(
        [this] { gitWatcherFreeze_.begin(); },
        [this] { gitWatcherFreeze_.end(); });
    gitWatcherFreeze_.setFlushHandler(
        [this](std::vector<DirectoryChangeSource::Change> changes) {
            // Match macOS: only catch up the workspace after Git already refreshed
            // under freeze. Empty pending means nothing to flush. Skip a second Git
            // status refresh here — it raced with Abort cleanup when freeze ended
            // before refreshWorkflow completed.
            if (changes.empty()) return;
            QMetaObject::invokeMethod(this, [this, changes = std::move(changes)]() mutable {
                scheduleWorkspaceRefresh();
                if (activePath_.isEmpty() || documentFeature_ == nullptr) return;
                bool activeTouched = false;
                for (const auto& change : changes) {
                    const auto path = normalizedRelativePath(fromUtf8(change.path));
                    if (path.isEmpty() || !sameRelativePath(path, activePath_)) continue;
                    activeTouched = true;
                    break;
                }
                if (!activeTouched) return;
                const auto state = documentFeature_->state();
                if (state.isDirty || state.isLoading || state.isSaving) return;
                const auto expectedPath = activePath_;
                documentFeature_->open(expectedPath.toUtf8().toStdString(),
                    [this, expectedPath](app::DocumentFeatureState next) {
                    QMetaObject::invokeMethod(this, [this, expectedPath,
                                                      next = std::move(next)]() mutable {
                        if (!sameRelativePath(expectedPath, activePath_) ||
                            !sameRelativePath(expectedPath, fromUtf8(next.relativePath))) {
                            return;
                        }
                        applyDocumentState(next);
                    }, Qt::QueuedConnection);
                });
            }, Qt::QueuedConnection);
        });

    auto* central = new QWidget(this);
    central->setObjectName(QStringLiteral("WorkbenchCentral"));
    central->setStyleSheet(QStringLiteral(
        "QWidget#WorkbenchCentral {"
        "  background-color: %1;"
        "  color: %2;"
        "}"
        "QSplitter::handle {"
        "  background-color: %3;"
        "}"
        "QSplitter::handle:hover {"
        "  background-color: rgba(79, 148, 250, 90);"
        "}"
        "QStatusBar {"
        "  background-color: %4;"
        "  color: %5;"
        "}"
        "QTabBar::tab {"
        "  background: %4;"
        "  color: %5;"
        "  padding: 6px 12px;"
        "  border: none;"
        "  border-top-left-radius: 4px;"
        "  border-top-right-radius: 4px;"
        "  margin-right: 2px;"
        "}"
        "QTabBar::tab:selected {"
        "  background: %6;"
        "  color: %2;"
        "  border-bottom: 2px solid %7;"
        "}")
        .arg(ui::Theme::rgba(ui::Theme::sidebar()),
             ui::Theme::rgba(ui::Theme::primaryText()),
             ui::Theme::rgba(ui::Theme::divider()),
             ui::Theme::rgba(ui::Theme::toolHeader()),
             ui::Theme::rgba(ui::Theme::secondaryText()),
             ui::Theme::rgba(ui::Theme::editor()),
             ui::Theme::rgba(ui::Theme::accent())));
    auto* layout = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    auto* mainSplitter = new QSplitter(Qt::Horizontal, central);

    auto* activityBar = new QWidget(mainSplitter);
    activityBar->setObjectName(QStringLiteral("ActivityBar"));
    activityBar->setFixedWidth(48);
    activityBar->setStyleSheet(QStringLiteral(
        "QWidget#ActivityBar {"
        "  background-color: %1;"
        "  border-right: 1px solid %2;"
        "}"
        "QWidget#ActivityBar QToolButton {"
        "  background: transparent;"
        "  border: none;"
        "  border-radius: 8px;"
        "  color: %3;"
        "  font-size: 15px;"
        "}"
        "QWidget#ActivityBar QToolButton:hover {"
        "  background-color: rgba(255, 255, 255, 14);"
        "  color: %4;"
        "}"
        "QWidget#ActivityBar QToolButton:checked {"
        "  background-color: %5;"
        "  color: %4;"
        "}")
        .arg(ui::Theme::rgba(ui::Theme::toolHeader()),
             ui::Theme::rgba(ui::Theme::divider()),
             ui::Theme::rgba(ui::Theme::secondaryText()),
             ui::Theme::rgba(ui::Theme::primaryText()),
             ui::Theme::rgba(ui::Theme::subtleSelection())));
    auto* activityLayout = new QVBoxLayout(activityBar);
    activityLayout->setContentsMargins(6, 10, 6, 10);
    activityLayout->setSpacing(8);
    projectSidebarButton_ = new QToolButton(activityBar);
    projectSidebarButton_->setToolTip(QStringLiteral("Project"));
    projectSidebarButton_->setCheckable(true);
    projectSidebarButton_->setChecked(true);
    projectSidebarButton_->setFixedSize(40, 34);
    projectSidebarButton_->setAutoRaise(true);
    projectSidebarButton_->setFocusPolicy(Qt::NoFocus);
    ui::IdeaIcons::applyToToolButton(
        projectSidebarButton_,
        QStringLiteral("toolwindows/toolWindowProject.svg"),
        16,
        ui::Theme::primaryText());
    changesSidebarButton_ = new QToolButton(activityBar);
    changesSidebarButton_->setToolTip(QStringLiteral("Commit / Shelf"));
    changesSidebarButton_->setCheckable(true);
    changesSidebarButton_->setFixedSize(40, 34);
    changesSidebarButton_->setAutoRaise(true);
    changesSidebarButton_->setFocusPolicy(Qt::NoFocus);
    // macOS SidebarDestination.changes → toolwindows/toolWindowCommit.svg
    ui::IdeaIcons::applyToToolButton(
        changesSidebarButton_,
        QStringLiteral("toolwindows/toolWindowCommit.svg"),
        16,
        ui::Theme::secondaryText());
    gitLogButton_ = new QToolButton(activityBar);
    gitLogButton_->setToolTip(QStringLiteral("Git Log"));
    gitLogButton_->setCheckable(true);
    gitLogButton_->setFixedSize(40, 34);
    gitLogButton_->setAutoRaise(true);
    gitLogButton_->setFocusPolicy(Qt::NoFocus);
    // macOS activity Git tool → toolwindows/toolWindowVcs.svg
    ui::IdeaIcons::applyToToolButton(
        gitLogButton_,
        QStringLiteral("toolwindows/toolWindowVcs.svg"),
        16,
        ui::Theme::secondaryText());
    activityLayout->addWidget(projectSidebarButton_);
    activityLayout->addWidget(changesSidebarButton_);
    activityLayout->addWidget(gitLogButton_);
    activityLayout->addStretch(1);
    // Do not put Git Log into the exclusive group — it toggles the bottom tool
    // window independently of the left sidebar destination (same as macOS).
    auto* sidebarGroup = new QButtonGroup(activityBar);
    sidebarGroup->setExclusive(true);
    sidebarGroup->addButton(projectSidebarButton_, 0);
    sidebarGroup->addButton(changesSidebarButton_, 1);
    mainSplitter->addWidget(activityBar);

    leftSidebarStack_ = new QStackedWidget(mainSplitter);
    tree_ = new QTreeWidget(leftSidebarStack_);
    tree_->setHeaderLabel("Workspace");
    tree_->setMinimumWidth(240);
    connect(tree_, &QTreeWidget::itemDoubleClicked, this, [this](QTreeWidgetItem* item, int column) {
        presentDiffReview_ = false;
        if (editorStack_ != nullptr && editorPage_ != nullptr) {
            editorStack_->setCurrentWidget(editorPage_);
        }
        openTreeItem(item, column);
    });
    tree_->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(tree_, &QTreeWidget::customContextMenuRequested,
            this, &WorkbenchWindow::showTreeContextMenu);
    leftSidebarStack_->addWidget(tree_);

    gitChangesPanel_ = new GitChangesPanel(leftSidebarStack_);
    leftSidebarStack_->addWidget(gitChangesPanel_);
    leftSidebarStack_->setMinimumWidth(280);
    mainSplitter->addWidget(leftSidebarStack_);

    contentSplitter_ = new QSplitter(Qt::Vertical, mainSplitter);
    auto* right = new QWidget(contentSplitter_);
    auto* rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(8, 8, 8, 8);
    searchField_ = new QLineEdit(right);
    searchField_->setPlaceholderText("Search workspace");
    connect(searchField_, &QLineEdit::returnPressed, this, &WorkbenchWindow::searchWorkspace);
    rightLayout->addWidget(searchField_);

    findBar_ = new QWidget(right);
    auto* findLayout = new QHBoxLayout(findBar_);
    findLayout->setContentsMargins(0, 0, 0, 0);
    findField_ = new QLineEdit(findBar_);
    findField_->setPlaceholderText(QStringLiteral("Find in editor"));
    findLayout->addWidget(findField_, 1);
    auto* previousFind = new QPushButton(QStringLiteral("Previous"), findBar_);
    auto* nextFind = new QPushButton(QStringLiteral("Next"), findBar_);
    auto* closeFind = new QPushButton(QStringLiteral("Close"), findBar_);
    findStatus_ = new QLabel(findBar_);
    findStatus_->setMinimumWidth(72);
    findLayout->addWidget(previousFind);
    findLayout->addWidget(nextFind);
    findLayout->addWidget(findStatus_);
    findLayout->addWidget(closeFind);
    connect(findField_, &QLineEdit::textChanged, this,
            &WorkbenchWindow::updateFindHighlights);
    connect(findField_, &QLineEdit::returnPressed, this, &WorkbenchWindow::findNext);
    connect(previousFind, &QPushButton::clicked, this, &WorkbenchWindow::findPrevious);
    connect(nextFind, &QPushButton::clicked, this, &WorkbenchWindow::findNext);
    connect(closeFind, &QPushButton::clicked, this, &WorkbenchWindow::hideFindBar);
    findBar_->setVisible(false);
    rightLayout->addWidget(findBar_);

    analysisStatus_ = new QLabel(right);
    analysisStatus_->setText("Project analysis idle");
    rightLayout->addWidget(analysisStatus_);

    diagnostics_ = new QListWidget(right);
    diagnostics_->setMaximumHeight(140);
    diagnostics_->setVisible(false);
    connect(diagnostics_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openSearchResult(item); });
    rightLayout->addWidget(diagnostics_);

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

    mavenControls_ = new QWidget(right);
    mavenControls_->setObjectName(QStringLiteral("MavenControls"));
    auto* mavenLayout = new QHBoxLayout(mavenControls_);
    mavenLayout->setContentsMargins(0, 0, 0, 0);
    auto* mavenLabel = new QLabel("Maven", mavenControls_);
    mavenLayout->addWidget(mavenLabel);
    for (const auto& phase : {QStringLiteral("clean"), QStringLiteral("test"),
                              QStringLiteral("package"), QStringLiteral("verify")}) {
        auto* action = new QPushButton(phase, mavenControls_);
        mavenLayout->addWidget(action);
        connect(action, &QPushButton::clicked, this, [this, phase] {
            runMavenPhase(phase);
        });
    }
    auto* stopMaven = new QPushButton("Stop", mavenControls_);
    mavenLayout->addWidget(stopMaven);
    connect(stopMaven, &QPushButton::clicked, this, &WorkbenchWindow::stopMavenBuild);
    auto* runJava = new QPushButton("Run Java", mavenControls_);
    mavenLayout->addWidget(runJava);
    connect(runJava, &QPushButton::clicked, this, &WorkbenchWindow::runCurrentJava);
    auto* runSpring = new QPushButton("Run Spring", mavenControls_);
    mavenLayout->addWidget(runSpring);
    connect(runSpring, &QPushButton::clicked, this, &WorkbenchWindow::runSpringBoot);
    auto* stopJava = new QPushButton("Stop Java", mavenControls_);
    mavenLayout->addWidget(stopJava);
    connect(stopJava, &QPushButton::clicked, this, &WorkbenchWindow::stopJavaRun);
    mavenLayout->addStretch(1);
    rightLayout->addWidget(mavenControls_);

    mavenOutput_ = new QPlainTextEdit(right);
    mavenOutput_->setReadOnly(true);
    mavenOutput_->setLineWrapMode(QPlainTextEdit::NoWrap);
    mavenOutput_->setMaximumHeight(160);
    mavenOutput_->setPlaceholderText("Maven output");
    rightLayout->addWidget(mavenOutput_);

    debugPanel_ = new QWidget(right);
    auto* debugLayout = new QVBoxLayout(debugPanel_);
    debugLayout->setContentsMargins(0, 0, 0, 0);
    auto* debugInspectControls = new QHBoxLayout();
    auto* threads = new QPushButton("Threads", debugPanel_);
    auto* stack = new QPushButton("Stack", debugPanel_);
    auto* variables = new QPushButton("Variables", debugPanel_);
    debugInspectControls->addWidget(threads);
    debugInspectControls->addWidget(stack);
    debugInspectControls->addWidget(variables);
    debugExpression_ = new QLineEdit(debugPanel_);
    debugExpression_->setPlaceholderText("Evaluate expression");
    debugInspectControls->addWidget(debugExpression_, 1);
    debugLayout->addLayout(debugInspectControls);

    auto* debugViews = new QSplitter(Qt::Horizontal, debugPanel_);
    debugVariables_ = new QListWidget(debugViews);
    debugVariables_->setToolTip("Double-click a variable to expand or collapse it");
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
    debugOutput_->setPlaceholderText("Debugger output");
    debugLayout->addWidget(debugOutput_);
    debugPanel_->setVisible(false);
    rightLayout->addWidget(debugPanel_);

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

    terminalPanel_ = new QWidget(right);
    auto* terminalLayout = new QVBoxLayout(terminalPanel_);
    terminalLayout->setContentsMargins(0, 0, 0, 0);
    terminalOutput_ = new QPlainTextEdit(terminalPanel_);
    terminalOutput_->setReadOnly(true);
    terminalOutput_->setLineWrapMode(QPlainTextEdit::NoWrap);
    terminalOutput_->setMaximumHeight(190);
    terminalOutput_->setPlaceholderText("Terminal output");
    terminalLayout->addWidget(terminalOutput_);
    terminalInput_ = new QLineEdit(terminalPanel_);
    terminalInput_->setPlaceholderText("Enter terminal command");
    connect(terminalInput_, &QLineEdit::returnPressed, this, [this] {
        if (!terminal_ || !terminal_->isRunning()) return;
        terminal_->send(terminalInput_->text().toUtf8().toStdString() + "\r\n");
        terminalInput_->clear();
    });
    terminalLayout->addWidget(terminalInput_);
    terminalPanel_->setVisible(false);
    rightLayout->addWidget(terminalPanel_);

    editor_ = new WorkbenchCodeEditor(right);
    editor_->setPlaceholderText("Open a file from the workspace tree");
    auto editorFont = editor_->font();
    editorFont.setPointSizeF(appSettings_.editorFontSize);
    editor_->setFont(editorFont);
    editorTabs_ = new QTabBar(right);
    editorTabs_->setTabsClosable(true);
    editorTabs_->setMovable(true);
    editorTabs_->setExpanding(false);
    connect(editorTabs_, &QTabBar::currentChanged,
            this, &WorkbenchWindow::switchEditorTab);
    connect(editorTabs_, &QTabBar::tabCloseRequested,
            this, &WorkbenchWindow::closeEditorTab);
    connect(editor_, &QPlainTextEdit::textChanged, this, [this] {
        if (suppressEditorChange_ || activePath_.isEmpty()) return;
        languageServerText_ = editor_->toPlainText().toUtf8().toStdString();
        documentFeature_->setText(languageServerText_);
        syncDirtyDocumentsPort(documentFeature_->state());
        if (languageServerPath_.isEmpty()) return;
        if (languageServer_ && languageServer_->isReady() && !languageServerUri_.empty()) {
            languageServer_->didChange(languageServerUri_, languageServerText_);
        }
        if (findBar_ != nullptr && findBar_->isVisible()) updateFindHighlights();
    });

    editorStack_ = new QStackedWidget(right);
    editorPage_ = new QWidget(editorStack_);
    auto* editorPageLayout = new QVBoxLayout(editorPage_);
    editorPageLayout->setContentsMargins(0, 0, 0, 0);
    editorPageLayout->setSpacing(0);
    editorPageLayout->addWidget(editorTabs_);
    editorPageLayout->addWidget(editor_, 1);
    editorStack_->addWidget(editorPage_);

    diffReviewPanel_ = new QWidget(editorStack_);
    auto* diffReviewLayout = new QVBoxLayout(diffReviewPanel_);
    diffReviewLayout->setContentsMargins(0, 0, 0, 0);
    diffReviewLayout->setSpacing(0);
    diffSplit_ = new DiffSplitWidget(diffReviewPanel_);
    connect(diffSplit_, &DiffSplitWidget::hunkSelected, this, [this](const QString& hunkId) {
        selectedDiffHunk_ = hunkId;
    });
    connect(diffSplit_, &DiffSplitWidget::expandRegionRequested, this,
            [this](const QString& regionId) {
        if (regionId.isEmpty()) return;
        expandedDiffRegions_.insert(regionId.toStdString());
        renderDiffReview();
    });
    connect(diffSplit_, &DiffSplitWidget::closeRequested, this,
            &WorkbenchWindow::closeDiffReview);
    connect(diffSplit_, &DiffSplitWidget::stageHunkRequested,
            this, &WorkbenchWindow::stageSelectedHunk);
    connect(diffSplit_, &DiffSplitWidget::unstageHunkRequested,
            this, &WorkbenchWindow::unstageSelectedHunk);
    connect(diffSplit_, &DiffSplitWidget::discardHunkRequested,
            this, &WorkbenchWindow::discardSelectedHunk);
    diffReviewLayout->addWidget(diffSplit_, 1);
    editorStack_->addWidget(diffReviewPanel_);
    editorStack_->setCurrentWidget(editorPage_);
    rightLayout->addWidget(editorStack_, 1);

    results_ = new QListWidget(right);
    results_->setMaximumHeight(170);
    results_->setVisible(false);
    connect(results_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openSearchResult(item); });
    rightLayout->addWidget(results_);

    navigation_ = new QListWidget(right);
    navigation_->setMaximumHeight(170);
    navigation_->setVisible(false);
    connect(navigation_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openJavaNavigationItem(item); });
    rightLayout->addWidget(navigation_);

    history_ = new QListWidget(right);
    history_->setMaximumHeight(190);
    history_->setVisible(false);
    connect(history_, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem* item) { openHistoryItem(item); });
    rightLayout->addWidget(history_);

    contentSplitter_->addWidget(right);

    gitLogPanel_ = new GitLogPanel(contentSplitter_);
    gitLogPanel_->setVisible(false);
    gitLogPanel_->setMinimumHeight(220);
    contentSplitter_->addWidget(gitLogPanel_);
    contentSplitter_->setStretchFactor(0, 3);
    contentSplitter_->setStretchFactor(1, 2);

    mainSplitter->addWidget(contentSplitter_);
    mainSplitter->setStretchFactor(0, 0);
    mainSplitter->setStretchFactor(1, 0);
    mainSplitter->setStretchFactor(2, 1);
    layout->addWidget(mainSplitter);
    setCentralWidget(central);
    connectGitPanels();
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
            statusBar()->showMessage(QStringLiteral("Terminal exited"), 3000);
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

    statusBar()->showMessage(QString("Rust Core %1")
                                 .arg(fromUtf8(coordinator_->coreVersion())));
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
    saveWorkspaceSession();
    if (coordinator_) coordinator_->shutdown();
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
    auto* toolbar = addToolBar("Workspace");
    auto* open = toolbar->addAction("Open");
    open->setShortcut(QKeySequence::Open);
    connect(open, &QAction::triggered, this, &WorkbenchWindow::chooseWorkspace);
    auto* refresh = toolbar->addAction("Refresh");
    connect(refresh, &QAction::triggered, this, &WorkbenchWindow::refreshWorkspace);
    auto* save = toolbar->addAction("Save");
    save->setShortcut(QKeySequence::Save);
    connect(save, &QAction::triggered, this, &WorkbenchWindow::saveDocument);

    auto* fileMenu = menuBar()->addMenu("File");
    fileMenu->addAction(open);
    fileMenu->addAction(save);
    fileMenu->addAction(refresh);
    auto* welcome = fileMenu->addAction("Welcome / Switch Workspace");
    connect(welcome, &QAction::triggered, this, &WorkbenchWindow::showWelcomeDialog);
    auto* markdownPreview = fileMenu->addAction("Preview Markdown");
    connect(markdownPreview, &QAction::triggered, this, &WorkbenchWindow::showMarkdownPreview);

    auto* searchMenu = menuBar()->addMenu("Search");
    auto* find = searchMenu->addAction("Find in Editor");
    find->setShortcut(QKeySequence::Find);
    connect(find, &QAction::triggered, this, &WorkbenchWindow::showFindBar);
    auto* everywhere = searchMenu->addAction("Search Everywhere...");
    everywhere->setShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_E));
    connect(everywhere, &QAction::triggered, this, &WorkbenchWindow::showSearchEverywhere);

    auto* gitMenu = menuBar()->addMenu("Git");
    auto* blame = gitMenu->addAction("Toggle Blame");
    connect(blame, &QAction::triggered, this, &WorkbenchWindow::toggleBlame);
    gitMenu->addSeparator();
    auto* gitLog = gitMenu->addAction("Git Log");
    connect(gitLog, &QAction::triggered, this, &WorkbenchWindow::toggleGitLogPanel);
    auto* gitStashes = gitMenu->addAction("Stashes");
    connect(gitStashes, &QAction::triggered, this, &WorkbenchWindow::loadGitStashes);
    auto* gitCompare = gitMenu->addAction("Compare Reference...");
    connect(gitCompare, &QAction::triggered, this, &WorkbenchWindow::compareGitReference);
    auto* switchBranch = gitMenu->addAction("Switch Branch...");
    connect(switchBranch, &QAction::triggered, this, &WorkbenchWindow::switchGitReference);
    auto* createBranch = gitMenu->addAction("New Branch...");
    connect(createBranch, &QAction::triggered, this, &WorkbenchWindow::createGitBranch);

    auto* mavenMenu = menuBar()->addMenu("Maven");
    for (const auto& phase : {QStringLiteral("clean"), QStringLiteral("test"),
                              QStringLiteral("package"), QStringLiteral("verify")}) {
        auto* action = mavenMenu->addAction(phase);
        connect(action, &QAction::triggered, this, [this, phase] {
            runMavenPhase(phase);
        });
    }
    auto* stop = mavenMenu->addAction("Stop");
    connect(stop, &QAction::triggered, this, &WorkbenchWindow::stopMavenBuild);

    auto* runMenu = menuBar()->addMenu("Run");
    auto* runJava = runMenu->addAction("Run Current Java File");
    connect(runJava, &QAction::triggered, this, &WorkbenchWindow::runCurrentJava);
    auto* runSpring = runMenu->addAction("Run Spring Boot");
    connect(runSpring, &QAction::triggered, this, &WorkbenchWindow::runSpringBoot);
    auto* stopJava = runMenu->addAction("Stop Java");
    connect(stopJava, &QAction::triggered, this, &WorkbenchWindow::stopJavaRun);
    auto* definition = runMenu->addAction("Go to Java Definition");
    definition->setShortcut(QKeySequence(Qt::CTRL | Qt::Key_B));
    connect(definition, &QAction::triggered, this, &WorkbenchWindow::gotoJavaDefinition);
    auto* usages = runMenu->addAction("Find Java Usages");
    usages->setShortcut(QKeySequence(Qt::ALT | Qt::Key_F7));
    connect(usages, &QAction::triggered, this, &WorkbenchWindow::findJavaUsages);

    auto* debugMenu = menuBar()->addMenu("Debug");
    auto* debugJava = debugMenu->addAction("Debug Current Java File");
    connect(debugJava, &QAction::triggered, this, &WorkbenchWindow::debugCurrentJava);
    auto* debugSpring = debugMenu->addAction("Debug Spring Boot");
    connect(debugSpring, &QAction::triggered, this, &WorkbenchWindow::debugSpringBoot);
    auto* attach = debugMenu->addAction("Attach to JDWP...");
    connect(attach, &QAction::triggered, this, &WorkbenchWindow::attachRemoteDebugger);
    debugMenu->addSeparator();
    auto* toggle = debugMenu->addAction("Toggle Breakpoint");
    toggle->setShortcut(QKeySequence(Qt::Key_F9));
    connect(toggle, &QAction::triggered, this, &WorkbenchWindow::toggleBreakpoint);
    auto* continueAction = debugMenu->addAction("Continue");
    continueAction->setShortcut(QKeySequence(Qt::Key_F5));
    connect(continueAction, &QAction::triggered, this, &WorkbenchWindow::continueDebugger);
    auto* pauseAction = debugMenu->addAction("Pause");
    connect(pauseAction, &QAction::triggered, this, &WorkbenchWindow::pauseDebugger);
    auto* stepInto = debugMenu->addAction("Step Into");
    stepInto->setShortcut(QKeySequence(Qt::Key_F7));
    connect(stepInto, &QAction::triggered, this, &WorkbenchWindow::stepIntoDebugger);
    auto* stepOver = debugMenu->addAction("Step Over");
    stepOver->setShortcut(QKeySequence(Qt::Key_F8));
    connect(stepOver, &QAction::triggered, this, &WorkbenchWindow::stepOverDebugger);
    auto* stepOut = debugMenu->addAction("Step Out");
    connect(stepOut, &QAction::triggered, this, &WorkbenchWindow::stepOutDebugger);
    auto* stopDebuggerAction = debugMenu->addAction("Stop Debugger");
    connect(stopDebuggerAction, &QAction::triggered, this, &WorkbenchWindow::stopDebugger);

    auto* terminalMenu = menuBar()->addMenu("Terminal");
    auto* openTerminal = terminalMenu->addAction("Open Terminal");
    connect(openTerminal, &QAction::triggered, this, &WorkbenchWindow::startTerminal);
    auto* stopTerminalAction = terminalMenu->addAction("Stop Terminal");
    connect(stopTerminalAction, &QAction::triggered, this, &WorkbenchWindow::stopTerminal);

    auto* toolsMenu = menuBar()->addMenu("Tools");
    auto* commandPalette = toolsMenu->addAction("Command Palette...");
    commandPalette->setShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_P));
    connect(commandPalette, &QAction::triggered, this, &WorkbenchWindow::showCommandPalette);
    auto* settings = toolsMenu->addAction("Settings...");
    connect(settings, &QAction::triggered, this, &WorkbenchWindow::showSettings);
    toolsMenu->addSeparator();
    auto* aiMessage = toolsMenu->addAction("Generate AI Commit Message");
    connect(aiMessage, &QAction::triggered,
            this, &WorkbenchWindow::generateAICommitMessage);
    auto* update = toolsMenu->addAction("Check for Updates");
    connect(update, &QAction::triggered, this, &WorkbenchWindow::checkForUpdates);
}

void WorkbenchWindow::showSettings() {
    QDialog dialog(this);
    dialog.setWindowTitle(QStringLiteral("Settings"));
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
        QStringLiteral("Windows-specific preferences for the Lithe workbench."), general));
    auto* generalForm = new QFormLayout();
    generalForm->addRow(QStringLiteral("Workspace"),
                        new QLabel(workspaceRoot_.isEmpty()
                                       ? QStringLiteral("No workspace open") : workspaceRoot_,
                                   general));
    generalForm->addRow(QStringLiteral("Rust Core"),
                        new QLabel(fromUtf8(coordinator_->coreVersion()), general));
    generalLayout->addLayout(generalForm);
    generalLayout->addStretch(1);
    tabs->addTab(general, QStringLiteral("General"));

    auto* editorPage = new QWidget(tabs);
    auto* editorForm = new QFormLayout(editorPage);
    auto* fontSize = new QDoubleSpinBox(editorPage);
    fontSize->setRange(9.0, 32.0);
    fontSize->setSingleStep(0.5);
    fontSize->setDecimals(1);
    fontSize->setValue(appSettings_.editorFontSize);
    auto* codeVision = new QCheckBox(QStringLiteral("Show code vision and implementation markers"),
                                     editorPage);
    codeVision->setChecked(appSettings_.showCodeVision);
    auto* inlayHints = new QCheckBox(QStringLiteral("Show Java inlay hints"), editorPage);
    inlayHints->setChecked(appSettings_.showInlayHints);
    editorForm->addRow(QStringLiteral("Editor font size"), fontSize);
    editorForm->addRow(codeVision);
    editorForm->addRow(inlayHints);
    tabs->addTab(editorPage, QStringLiteral("Editor"));

    auto* projectPage = new QWidget(tabs);
    auto* projectForm = new QFormLayout(projectPage);
    auto* hiddenDirectories = new QLineEdit(projectPage);
    hiddenDirectories->setText(joinValues(appSettings_.hiddenDirectoryNames));
    hiddenDirectories->setPlaceholderText(QStringLiteral(".git, build, target"));
    auto* hiddenFiles = new QLineEdit(projectPage);
    hiddenFiles->setText(joinValues(appSettings_.hiddenFilePatterns));
    hiddenFiles->setPlaceholderText(QStringLiteral(".DS_Store, *.class"));
    projectForm->addRow(QStringLiteral("Hidden directories"), hiddenDirectories);
    projectForm->addRow(QStringLiteral("Hidden file patterns"), hiddenFiles);
    projectForm->addRow(new QLabel(
        QStringLiteral("Values are comma-separated and apply after the workspace is refreshed."),
        projectPage));
    tabs->addTab(projectPage, QStringLiteral("Project"));

    auto* terminalPage = new QWidget(tabs);
    auto* terminalForm = new QFormLayout(terminalPage);
    auto* shellPath = new QLineEdit(terminalPage);
    shellPath->setText(fromUtf8(appSettings_.terminalShellPath));
    shellPath->setPlaceholderText(QStringLiteral("Automatic: ComSpec or cmd.exe"));
    terminalForm->addRow(QStringLiteral("Shell executable"), shellPath);
    tabs->addTab(terminalPage, QStringLiteral("Terminal"));

    auto* aiPage = new QWidget(tabs);
    auto* aiLayout = new QVBoxLayout(aiPage);
    auto* aiStatus = new QLabel(aiPage);
    aiStatus->setWordWrap(true);
    const auto updateAIStatus = [this, aiStatus] {
        const auto settings = loadAISettings();
        if (settings.providers.empty()) {
            aiStatus->setText(QStringLiteral("No AI commit-message provider configured."));
        } else {
            aiStatus->setText(QStringLiteral("Provider: %1  Model: %2")
                                  .arg(fromUtf8(settings.providers.front().name))
                                  .arg(fromUtf8(settings.providers.front().model)));
        }
    };
    updateAIStatus();
    aiLayout->addWidget(aiStatus);
    auto* configureAI = new QPushButton(QStringLiteral("Configure AI commit messages..."), aiPage);
    aiLayout->addWidget(configureAI);
    connect(configureAI, &QPushButton::clicked, this, [this, updateAIStatus] {
        if (configureAISettings()) updateAIStatus();
    });
    aiLayout->addStretch(1);
    tabs->addTab(aiPage, QStringLiteral("AI & Commit"));

    auto* updatesPage = new QWidget(tabs);
    auto* updatesLayout = new QVBoxLayout(updatesPage);
    auto* updatesInfo = new QLabel(
        QStringLiteral("Windows releases are checked on GitHub and downloaded only after "
                       "SHA-256 and Authenticode verification."), updatesPage);
    updatesInfo->setWordWrap(true);
    updatesLayout->addWidget(updatesInfo);
    auto* checkUpdates = new QPushButton(QStringLiteral("Check for updates"), updatesPage);
    updatesLayout->addWidget(checkUpdates);
    connect(checkUpdates, &QPushButton::clicked, this, &WorkbenchWindow::checkForUpdates);
    updatesLayout->addStretch(1);
    tabs->addTab(updatesPage, QStringLiteral("Updates"));

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel,
                                         &dialog);
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
    next.hiddenDirectoryNames = splitValues(hiddenDirectories->text());
    next.hiddenFilePatterns = splitValues(hiddenFiles->text());
    next.terminalShellPath = shellPath->text().trimmed().toUtf8().toStdString();
    std::string error;
    if (!appSettingsStore_.save(next, error)) {
        statusBar()->showMessage(QStringLiteral("Could not save settings: ") + fromUtf8(error),
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
    statusBar()->showMessage(QStringLiteral("Settings saved"), 3000);
}

void WorkbenchWindow::showCommandPalette() {
    struct Command {
        QString title;
        std::function<void()> action;
    };
    const std::vector<Command> commands{
        {QStringLiteral("Open Workspace"), [this] { chooseWorkspace(); }},
        {QStringLiteral("Welcome / Switch Workspace"), [this] { showWelcomeDialog(); }},
        {QStringLiteral("Refresh Workspace"), [this] { refreshWorkspace(); }},
        {QStringLiteral("Save Document"), [this] { saveDocument(); }},
        {QStringLiteral("Find in Editor"), [this] { showFindBar(); }},
        {QStringLiteral("Preview Markdown"), [this] { showMarkdownPreview(); }},
        {QStringLiteral("Search Workspace"), [this] { searchWorkspace(); }},
        {QStringLiteral("Search Everywhere"), [this] { showSearchEverywhere(); }},
        {QStringLiteral("Git Log"), [this] { toggleGitLogPanel(); }},
        {QStringLiteral("Git Stashes"), [this] { loadGitStashes(); }},
        {QStringLiteral("Compare Git Reference"), [this] { compareGitReference(); }},
        {QStringLiteral("Switch Git Branch"), [this] { switchGitReference(); }},
        {QStringLiteral("Create Git Branch"), [this] { createGitBranch(); }},
        {QStringLiteral("Stage All Changes"), [this] { stageAllChanges(); }},
        {QStringLiteral("Commit Changes"), [this] { commitChanges(); }},
        {QStringLiteral("Generate AI Commit Message"), [this] { generateAICommitMessage(); }},
        {QStringLiteral("Run Current Java File"), [this] { runCurrentJava(); }},
        {QStringLiteral("Run Spring Boot"), [this] { runSpringBoot(); }},
        {QStringLiteral("Stop Java"), [this] { stopJavaRun(); }},
        {QStringLiteral("Debug Current Java File"), [this] { debugCurrentJava(); }},
        {QStringLiteral("Stop Debugger"), [this] { stopDebugger(); }},
        {QStringLiteral("Open Terminal"), [this] { startTerminal(); }},
        {QStringLiteral("Stop Terminal"), [this] { stopTerminal(); }},
        {QStringLiteral("Settings"), [this] { showSettings(); }},
        {QStringLiteral("Check for Updates"), [this] { checkForUpdates(); }},
    };

    QDialog dialog(this);
    dialog.setWindowTitle(QStringLiteral("Command Palette"));
    dialog.resize(620, 420);
    auto* layout = new QVBoxLayout(&dialog);
    auto* input = new QLineEdit(&dialog);
    input->setPlaceholderText(QStringLiteral("Type a command"));
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
    dialog.setWindowTitle(QStringLiteral("Welcome to Lithe"));
    dialog.resize(760, 520);
    auto* outer = new QVBoxLayout(&dialog);

    auto* title = new QLabel(QStringLiteral("Welcome to Lithe"), &dialog);
    auto titleFont = title->font();
    titleFont.setPointSize(titleFont.pointSize() + 4);
    titleFont.setBold(true);
    title->setFont(titleFont);
    outer->addWidget(title);
    outer->addWidget(new QLabel(
        QStringLiteral("Open a recent project, choose a folder, or clone a repository."),
        &dialog));

    auto* filter = new QLineEdit(&dialog);
    filter->setPlaceholderText(QStringLiteral("Search recent projects"));
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
        auto* item = new QListWidgetItem(QStringLiteral("No recent projects"), projects);
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
    auto* openSelected = new QPushButton(QStringLiteral("Open Selected"), &dialog);
    auto* openFolder = new QPushButton(QStringLiteral("Open Folder..."), &dialog);
    auto* clone = new QPushButton(QStringLiteral("Clone..."), &dialog);
    auto* settings = new QPushButton(QStringLiteral("Settings..."), &dialog);
    auto* reveal = new QPushButton(QStringLiteral("Show in Explorer"), &dialog);
    auto* cancel = new QPushButton(QStringLiteral("Close"), &dialog);
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
        const auto root = QFileDialog::getExistingDirectory(
            &dialog, QStringLiteral("Open Workspace"), workspaceRoot_);
        if (root.isEmpty()) return;
        dialog.accept();
        openWorkspaceRoot(root);
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
        statusBar()->showMessage(QStringLiteral("Open a Markdown file before previewing it"), 5000);
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
    const auto root = QFileDialog::getExistingDirectory(this, "Open Workspace", workspaceRoot_);
    if (root.isEmpty()) return;
    openWorkspaceRoot(root);
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
    // Align freeze depth with operationDepth_ = 0 so a mid-op workspace switch
    // cannot leave the watcher permanently frozen.
    gitWatcherFreeze_.reset();
    suppressPendingGitDialog_ = false;
    if (dirtyDocuments_) dirtyDocuments_->clear();
    historyFeature_->resetForWorkspace();
    mavenJavaFeature_->resetForWorkspace();
    workspaceRoot_ = root;
    activePath_.clear();
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

    gitWatcherFreeze_.noteChanges(changes);
    if (gitWatcherFreeze_.isFrozen()) return;

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
            statusBar()->showMessage(QStringLiteral("The open file was removed"), 5000);
        } else {
            statusBar()->showMessage(
                QStringLiteral("The open file was removed; unsaved changes were kept"), 6000);
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
    selectedGitCommit_.clear();
    diffIsCommitReview_ = false;
    if (gitLogPanel_ != nullptr) {
        gitLogPanel_->setVisible(true);
        gitLogPanel_->prepareForHistoryLoad();
        if (gitLogButton_ != nullptr) gitLogButton_->setChecked(true);
    }
    gitFeature_->refreshHistory(std::nullopt, 300,
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::openGitHistoryItem(QListWidgetItem* item) {
    if (item == nullptr) return;
    selectGitCommit(item->data(GitCommitHashRole).toString());
}

void WorkbenchWindow::openCommitFile(QListWidgetItem* item) {
    if (item == nullptr) return;
    openGitCommitFile(item->data(RelativePathRole).toString());
}

void WorkbenchWindow::selectGitCommit(const QString& hash) {
    if (hash.isEmpty() || !gitFeature_) return;
    selectedGitCommit_ = hash;
    if (gitLogPanel_ != nullptr) gitLogPanel_->setSelectedCommitHash(hash);
    diffIsCommitReview_ = false;
    const auto applyState = [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    };
    gitFeature_->loadCommit(hash.toStdString(), applyState);
    gitFeature_->loadCommitFiles(hash.toStdString(), applyState);
}

void WorkbenchWindow::openGitCommitFile(const QString& path) {
    if (path.isEmpty() || !gitFeature_ || selectedGitCommit_.isEmpty()) return;
    diffIsCommitReview_ = true;
    presentDiffReview_ = true;
    selectedDiffHunk_.clear();
    activePath_ = path;
    statusBar()->showMessage(QStringLiteral("Loading commit file diff..."));
    gitFeature_->loadCommitDiff(
        selectedGitCommit_.toStdString(), {path.toUtf8().toStdString()},
        [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::loadGitStashes() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    selectedGitStash_.clear();
    showChangesSidebar();
    gitFeature_->refreshStashes([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
    gitFeature_->refreshShelves([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::compareGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    const auto referenceOpt = showGitTextInputDialog(
        this,
        QStringLiteral("Compare Git Reference"),
        QStringLiteral("Reference (branch, tag, or commit):"),
        QStringLiteral("HEAD~1"));
    if (!referenceOpt) return;
    const auto reference = *referenceOpt;
    diffIsCommitReview_ = false;
    gitFeature_->loadComparison(reference.toStdString(),
        [this, reference](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, reference,
                                          state = std::move(state)]() mutable {
            if (!state.error && !state.isLoadingComparison && state.comparison) {
                statusBar()->showMessage(
                    QString("Comparison with %1 loaded").arg(reference), 3000);
            }
            applyGitState(state);
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::switchGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    pickGitReferenceAsync(QStringLiteral("Switch Git Reference"),
        [this](std::optional<GitReferenceDto> reference) {
        if (!reference) return;
        gitFeature_->checkoutReference(reference->fullName, reference->kind, reference->shortName,
            [this](app::GitFeatureState next) {
            QMetaObject::invokeMethod(this, [this, next = std::move(next)]() mutable {
                applyGitState(next);
                if (next.error || next.isWriting || next.isPerformingBranchOperation) return;
                if (next.pendingCheckoutConflict) return;
                statusBar()->showMessage(QStringLiteral("Git reference switched"), 4000);
                loadSnapshot();
                loadGitHistory();
            }, Qt::QueuedConnection);
        });
    });
}

void WorkbenchWindow::createGitBranch() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    const auto nameOpt = showGitTextInputDialog(
        this,
        QStringLiteral("Create Git Branch"),
        QStringLiteral("Branch name:"));
    if (!nameOpt) return;
    const auto name = *nameOpt;

    GitWriteRequestDto request;
    request.operation = "createBranch";
    request.name = name.toStdString();
    request.reference = "HEAD";
    request.checkout = true;
    gitFeature_->write(std::move(request), [this, name](app::GitFeatureState next) {
        QMetaObject::invokeMethod(this, [this, name,
                                          next = std::move(next)]() mutable {
            applyGitState(next);
            if (next.error || next.isWriting) return;
            statusBar()->showMessage(QString("Created branch %1").arg(name), 4000);
            loadSnapshot();
            loadGitHistory();
        }, Qt::QueuedConnection);
    });
}

std::optional<GitReferenceDto> WorkbenchWindow::pickGitReference(const QString& title) {
    if (!gitFeature_) return std::nullopt;
    const auto state = gitFeature_->state();
    if (!state.history || state.history->references.empty()) {
        return std::nullopt;
    }

    const bool excludeCurrent =
        title.contains(QStringLiteral("Merge"), Qt::CaseInsensitive) ||
        title.contains(QStringLiteral("Rebase"), Qt::CaseInsensitive);

    QStringList choices;
    std::vector<std::size_t> choiceIndexes;
    int currentIndex = 0;
    int preferredIndex = -1;
    for (std::size_t i = 0; i < state.history->references.size(); ++i) {
        const auto& reference = state.history->references[i];
        if (excludeCurrent && reference.isCurrent) continue;
        if (preferredIndex < 0) preferredIndex = static_cast<int>(choiceIndexes.size());
        choices.push_back(QString("%1  [%2]")
                              .arg(fromUtf8(reference.shortName))
                              .arg(fromUtf8(reference.kind)));
        choiceIndexes.push_back(i);
        if (!excludeCurrent && reference.isCurrent) {
            currentIndex = static_cast<int>(choiceIndexes.size()) - 1;
        }
    }
    if (choices.isEmpty()) {
        statusBar()->showMessage(
            QStringLiteral("No other Git references available to %1")
                .arg(title.contains(QStringLiteral("Rebase"), Qt::CaseInsensitive)
                         ? QStringLiteral("rebase onto")
                         : QStringLiteral("merge")),
            6000);
        return std::nullopt;
    }
    if (excludeCurrent && preferredIndex >= 0) currentIndex = preferredIndex;

    const auto picked = showGitReferencePickerDialog(
        this,
        title,
        QStringLiteral("Choose a Git reference to continue."),
        choices,
        currentIndex);
    if (!picked || *picked < 0 || *picked >= static_cast<int>(choiceIndexes.size())) {
        return std::nullopt;
    }
    return state.history->references[choiceIndexes[static_cast<std::size_t>(*picked)]];
}

void WorkbenchWindow::pickGitReferenceAsync(
    const QString& title,
    std::function<void(std::optional<GitReferenceDto>)> onPicked) {
    if (!gitFeature_ || !onPicked) return;
    const auto state = gitFeature_->state();
    if (state.history && !state.history->references.empty()) {
        onPicked(pickGitReference(title));
        return;
    }
    statusBar()->showMessage(QStringLiteral("Loading Git references..."), 4000);
    gitFeature_->refreshHistory(std::nullopt, 300,
        [this, title, onPicked = std::move(onPicked)](app::GitFeatureState next) mutable {
        QMetaObject::invokeMethod(this, [this, title, onPicked = std::move(onPicked),
                                          next = std::move(next)]() mutable {
            applyGitState(next);
            if (next.error) {
                showFeatureError(next.error, QStringLiteral("Could not load Git references"));
                onPicked(std::nullopt);
                return;
            }
            onPicked(pickGitReference(title));
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::applyGitStateAsync(app::GitFeatureState state) {
    QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
        applyGitState(state);
    }, Qt::QueuedConnection);
}

void WorkbenchWindow::fetchGitRemote() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    gitFeature_->fetch([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::pushGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    const auto state = gitFeature_->state();
    std::string reference;
    std::string shortName;
    if (state.history) {
        for (const auto& item : state.history->references) {
            if (item.isCurrent) {
                reference = item.fullName;
                shortName = item.shortName;
                break;
            }
        }
    }
    if (reference.empty() && state.status && state.status->branch) {
        reference = *state.status->branch;
        shortName = *state.status->branch;
    }
    if (reference.empty()) {
        const auto picked = pickGitReference(QStringLiteral("Push Git Reference"));
        if (!picked) return;
        reference = picked->fullName;
        shortName = picked->shortName;
    }
    if (QMessageBox::question(
            this,
            QStringLiteral("Push"),
            QStringLiteral("Push '%1' to its configured remote?")
                .arg(fromUtf8(shortName))) != QMessageBox::Yes) {
        return;
    }
    gitFeature_->push(std::move(reference), std::move(shortName),
        [this](app::GitFeatureState next) {
        applyGitStateAsync(std::move(next));
    });
}

void WorkbenchWindow::mergeGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    pickGitReferenceAsync(QStringLiteral("Merge Git Reference"),
        [this](std::optional<GitReferenceDto> reference) {
        if (!reference) return;
        if (reference->isCurrent) {
            QMessageBox::warning(
                this,
                QStringLiteral("Merge"),
                QStringLiteral("Cannot merge the current branch into itself. Pick another reference."));
            return;
        }
        gitFeature_->mergeReference(reference->fullName, reference->shortName,
            [this](app::GitFeatureState state) {
            applyGitStateAsync(std::move(state));
        });
    });
}

void WorkbenchWindow::rebaseGitReference() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    pickGitReferenceAsync(QStringLiteral("Rebase Onto"),
        [this](std::optional<GitReferenceDto> reference) {
        if (!reference) return;
        if (reference->isCurrent) {
            QMessageBox::warning(
                this,
                QStringLiteral("Rebase"),
                QStringLiteral("Cannot rebase onto the current branch. Pick another reference."));
            return;
        }
        gitFeature_->rebaseOnto(reference->fullName, reference->shortName,
            [this](app::GitFeatureState state) {
            applyGitStateAsync(std::move(state));
        });
    });
}

void WorkbenchWindow::pullGitRemote() {
    if (workspaceRoot_.isEmpty() || !gitFeature_) return;
    gitFeature_->pull([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::continueGitOperation() {
    if (!gitFeature_) return;
    gitFeature_->continueOperation([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::abortGitOperation() {
    if (!gitFeature_) return;
    if (!confirmDestructiveGitAction(
            this,
            QStringLiteral("Abort Git Operation"),
            QStringLiteral("Abort the in-progress Git operation?"))) {
        return;
    }
    gitFeature_->abortOperation([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::skipGitOperation() {
    if (!gitFeature_) return;
    gitFeature_->skipOperation([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::filterGitConflicts() {
    if (!gitFeature_) return;
    const auto state = gitFeature_->state();
    if (!state.operationState) return;
    gitFeature_->setConflictFilterPaths(state.operationState->conflictedPaths,
        [this](app::GitFeatureState next) {
        applyGitStateAsync(std::move(next));
    });
}

void WorkbenchWindow::clearGitConflictFilter() {
    if (!gitFeature_) return;
    gitFeature_->clearConflictFilterPaths([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::filterStashRestoreConflicts() {
    if (!gitFeature_) return;
    const auto state = gitFeature_->state();
    if (!state.pendingStashRestoreConflict) return;
    gitFeature_->setConflictFilterPaths(state.pendingStashRestoreConflict->conflictedPaths,
        [this](app::GitFeatureState next) {
        applyGitStateAsync(std::move(next));
    });
}

void WorkbenchWindow::dismissStashRestoreNotice() {
    if (!gitFeature_) return;
    gitFeature_->dismissStashRestoreNotice([this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::applyStashOperation(const QString& operation) {
    if (workspaceRoot_.isEmpty() || !gitFeature_ || selectedGitStash_.isEmpty()) {
        statusBar()->showMessage(QStringLiteral("Select a stash first"), 4000);
        return;
    }
    if (operation == QStringLiteral("stashDrop") &&
        QMessageBox::question(this, QStringLiteral("Drop Stash"),
                              QString("Drop %1?").arg(selectedGitStash_)) != QMessageBox::Yes) {
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
    auto* newFile = menu.addAction(QStringLiteral("New File..."));
    auto* newDirectory = menu.addAction(QStringLiteral("New Directory..."));
    menu.addSeparator();
    auto* rename = menu.addAction(QStringLiteral("Rename..."));
    auto* copy = menu.addAction(QStringLiteral("Duplicate..."));
    auto* remove = menu.addAction(QStringLiteral("Delete"));
    menu.addSeparator();
    auto* copyRelative = menu.addAction(QStringLiteral("Copy Relative Path"));
    auto* copyAbsolute = menu.addAction(QStringLiteral("Copy Absolute Path"));
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
        this, directory ? QStringLiteral("New Directory") : QStringLiteral("New File"),
        QStringLiteral("Name"), QLineEdit::Normal, QString(), &accepted).trimmed();
    const auto normalizedName = QDir::fromNativeSeparators(name);
    if (!accepted || normalizedName.isEmpty() || normalizedName == QStringLiteral(".") ||
        normalizedName == QStringLiteral("..") ||
        QFileInfo(normalizedName).fileName() != normalizedName) {
        if (accepted) statusBar()->showMessage(QStringLiteral("Invalid workspace item name"), 4000);
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
        statusBar()->showMessage(QStringLiteral("Invalid workspace path"), 4000);
        return;
    }
    std::string error;
    const auto success = directory
        ? storage_->createDirectory(pathUtf8(absolute), false, error)
        : storage_->writeData(pathUtf8(absolute), {}, error);
    if (!success) {
        statusBar()->showMessage(QStringLiteral("Could not create item: ") + fromUtf8(error), 6000);
        return;
    }
    scheduleWorkspaceRefresh();
    scheduleGitRefresh();
    statusBar()->showMessage(QStringLiteral("Created %1").arg(relative), 3000);
}

void WorkbenchWindow::renameWorkspaceItem() {
    if (tree_ == nullptr || coordinator_ == nullptr || storage_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto oldRelative = item->data(0, RelativePathRole).toString();
    if (oldRelative.isEmpty()) return;
    bool accepted = false;
    const auto name = QInputDialog::getText(
        this, QStringLiteral("Rename Workspace Item"), QStringLiteral("Name"),
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
        statusBar()->showMessage(QStringLiteral("Could not rename item: ") + fromUtf8(error), 6000);
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
    statusBar()->showMessage(QStringLiteral("Renamed to %1").arg(newRelative), 3000);
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
    const auto name = QInputDialog::getText(this, QStringLiteral("Duplicate Workspace Item"),
                                            QStringLiteral("Name"), QLineEdit::Normal,
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
        statusBar()->showMessage(QStringLiteral("Destination already exists"), 5000);
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
        statusBar()->showMessage(QStringLiteral("Could not duplicate item: ") +
                                     fromUtf8(filesystemError.message()), 6000);
        return;
    }
    scheduleWorkspaceRefresh();
    scheduleGitRefresh();
    statusBar()->showMessage(QStringLiteral("Duplicated as %1").arg(destinationRelative), 3000);
}

void WorkbenchWindow::deleteWorkspaceItem() {
    if (tree_ == nullptr || coordinator_ == nullptr || storage_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto relative = item->data(0, RelativePathRole).toString();
    if (relative.isEmpty()) return;
    if (QMessageBox::question(this, QStringLiteral("Delete Workspace Item"),
                              QStringLiteral("Delete %1 permanently?").arg(relative),
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
        statusBar()->showMessage(QStringLiteral("Could not delete item: ") + fromUtf8(error), 6000);
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
    statusBar()->showMessage(QStringLiteral("Deleted %1").arg(relative), 3000);
}

void WorkbenchWindow::copyWorkspacePath(bool absolute) {
    if (tree_ == nullptr) return;
    auto* item = tree_->currentItem();
    if (item == nullptr) return;
    const auto relative = item->data(0, RelativePathRole).toString();
    const auto value = absolute ? QDir(workspaceRoot_).filePath(relative) : relative;
    QApplication::clipboard()->setText(value);
    statusBar()->showMessage(QStringLiteral("Copied path"), 2000);
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
    restoreWorkspaceSession();
    statusBar()->showMessage(QString("Workspace loaded with %1 files").arg(
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
    return index;
}

void WorkbenchWindow::switchEditorTab(int index) {
    if (editorTabs_ == nullptr || index < 0 || index >= editorTabs_->count()) return;
    const auto path = editorTabs_->tabData(index).toString();
    if (path.isEmpty() || (!librarySourcePreview_ && sameRelativePath(path, activePath_))) return;
    presentDiffReview_ = false;
    if (editorStack_ != nullptr && editorPage_ != nullptr) {
        editorStack_->setCurrentWidget(editorPage_);
    }
    if (auto* item = findTreeItem(path)) {
        openTreeItem(item, 0);
    } else {
        statusBar()->showMessage(QStringLiteral("The tab file is no longer in the workspace"), 5000);
    }
}

void WorkbenchWindow::closeEditorTab(int index) {
    if (editorTabs_ == nullptr || index < 0 || index >= editorTabs_->count()) return;
    const auto path = editorTabs_->tabData(index).toString();
    if (sameRelativePath(path, activePath_) && documentFeature_->state().isDirty) {
        const auto choice = QMessageBox::warning(
            this, QStringLiteral("Unsaved Changes"),
            QStringLiteral("Save changes to %1 before closing?").arg(path),
            QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel,
            QMessageBox::Save);
        if (choice == QMessageBox::Cancel) return;
        if (choice == QMessageBox::Save) saveDocument();
    }
    if (dirtyDocuments_ && !path.isEmpty()) {
        auto paths = dirtyDocuments_->dirtyRelativePaths();
        const auto closed = path.toUtf8().toStdString();
        paths.erase(std::remove(paths.begin(), paths.end(), closed), paths.end());
        dirtyDocuments_->setDirtyPaths(std::move(paths));
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
    if (editorTabs_->count() == 0) return;
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
    const auto nextPath = item->data(0, RelativePathRole).toString();
    // Until W1 owns multi-buffer editors, switching tabs reloads from disk and
    // discards the previous buffer — drop its dirty mark so preflight stays honest.
    if (dirtyDocuments_ && documentFeature_ && documentFeature_->state().isDirty &&
        !activePath_.isEmpty() && !sameRelativePath(activePath_, nextPath)) {
        auto paths = dirtyDocuments_->dirtyRelativePaths();
        const auto discarded = activePath_.toUtf8().toStdString();
        paths.erase(std::remove(paths.begin(), paths.end(), discarded), paths.end());
        dirtyDocuments_->setDirtyPaths(std::move(paths));
    }
    activePath_ = nextPath;
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
    // Only auto-load working-tree diff when opening from the project tree and
    // the Diff review surface is already being presented.
    if (presentDiffReview_) {
        gitFeature_->loadDiff({activePath_.toUtf8().toStdString()}, false, false,
            [this](app::GitFeatureState state) {
            QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                applyGitState(state);
            }, Qt::QueuedConnection);
        });
    }
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

void WorkbenchWindow::openGitChangeDiff(const QString& path, bool staged, bool untracked) {
    if (path.isEmpty() || !gitFeature_ || workspaceRoot_.isEmpty()) return;
    presentDiffReview_ = true;
    diffIsCommitReview_ = false;
    selectedDiffHunk_.clear();
    expandedDiffRegions_.clear();
    activePath_ = path;
    if (editorTabs_ != nullptr) {
        const auto tab = ensureEditorTab(path);
        if (tab >= 0) {
            QSignalBlocker blocker(editorTabs_);
            editorTabs_->setCurrentIndex(tab);
        }
    }
    // Open the document for context when it exists; deleted/untracked files may fail.
    if (auto* item = findTreeItem(path)) {
        if (!item->data(0, DirectoryRole).toBool()) {
            documentFeature_->open(path.toUtf8().toStdString(),
                [this, path](app::DocumentFeatureState state) {
                QMetaObject::invokeMethod(this, [this, path,
                                                  state = std::move(state)]() mutable {
                    if (!sameRelativePath(path, activePath_)) return;
                    applyDocumentState(state);
                }, Qt::QueuedConnection);
            });
        }
    }
    gitFeature_->loadDiff({path.toUtf8().toStdString()}, staged, untracked,
        [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
    if (leftSidebarStack_ != nullptr && leftSidebarStack_->currentIndex() != 1) {
        setLeftSidebarIndex(1);
    }
    if (gitLogPanel_ != nullptr && !gitLogPanel_->isVisible()) {
        setGitLogVisible(true);
    }
    updateWorkbenchChromeForFocus();
}

void WorkbenchWindow::toggleBlame() {
    if (editor_ == nullptr || gitFeature_ == nullptr || activePath_.isEmpty()) {
        statusBar()->showMessage(QStringLiteral("Open a file before showing Git blame"), 5000);
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
    syncDirtyDocumentsPort(state);
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
    searchFeature_->search(searchField_->text().toUtf8().toStdString(),
        [this](app::SearchFeatureState state) {
            QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
                applySearchState(state);
            }, Qt::QueuedConnection);
        });
}

void WorkbenchWindow::showSearchEverywhere() {
    if (workspaceRoot_.isEmpty()) {
        statusBar()->showMessage(QStringLiteral("Open a workspace before searching"), 5000);
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
        statusBar()->showMessage(QStringLiteral("Enter a search query"), 3000);
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
    statusBar()->showMessage(QString("%1 search results").arg(results_->count()));
}

void WorkbenchWindow::applySearchEverywhereState(
    const app::SearchEverywhereFeatureState& state) {
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Search Everywhere request failed"));
        return;
    }
    if (state.isLoading || searchEverywhereResults_ == nullptr) {
        statusBar()->showMessage(QStringLiteral("Searching Everywhere..."));
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
    statusBar()->showMessage(QString("%1 Search Everywhere results")
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
    statusBar()->showMessage(QStringLiteral("Search result is no longer in the workspace"), 5000);
}

void WorkbenchWindow::applyGitState(const app::GitFeatureState& state) {
    if (state.notifyMessage && !state.notifyMessage->empty()) {
        statusBar()->showMessage(fromUtf8(*state.notifyMessage), 6000);
    }
    if (state.error) {
        showFeatureError(state.error, QStringLiteral("Git request failed"));
    }
    if (gitChangesPanel_ != nullptr) {
        gitChangesPanel_->applyState(state);
    }
    if (gitLogPanel_ != nullptr && gitLogPanel_->isVisible()) {
        gitLogPanel_->applyState(state);
    }
    if (state.diff && !state.isLoadingDiff) {
        if (!diffReview_ || diffReview_->patch != state.diff->patch) {
            expandedDiffRegions_.clear();
            selectedDiffHunk_.clear();
        }
        diffReview_ = *state.diff;
        renderDiffReview();
        const auto path = activePath_.isEmpty() ? QStringLiteral("") : activePath_;
        const auto fileName = [&] {
            const auto slash = path.lastIndexOf(QLatin1Char('/'));
            return slash >= 0 ? path.mid(slash + 1) : path;
        }();
        if (diffSplit_ != nullptr) {
            QString statusBadge = QStringLiteral("MODIFIED");
            QString modeBadge = QStringLiteral("WORKING TREE");
            bool stagedOnly = false;
            if (state.status) {
                for (const auto& change : state.status->changes) {
                    if (fromUtf8(change.path) != path) continue;
                    const auto status = fromUtf8(change.status).toUpper();
                    if (status.startsWith(QLatin1Char('A')) || change.untracked) {
                        statusBadge = QStringLiteral("ADDED");
                    } else if (status.startsWith(QLatin1Char('D'))) {
                        statusBadge = QStringLiteral("DELETED");
                    } else if (status.contains(QLatin1Char('U')) ||
                               status == QStringLiteral("AA") ||
                               status == QStringLiteral("DD")) {
                        statusBadge = QStringLiteral("CONFLICT");
                    } else {
                        statusBadge = QStringLiteral("MODIFIED");
                    }
                    stagedOnly = change.staged && !change.untracked;
                    break;
                }
            }
            if (diffIsCommitReview_) {
                modeBadge = QStringLiteral("DIFF");
                diffSplit_->setFileChrome(fileName, statusBadge, modeBadge);
                diffSplit_->setVersionTitles(
                    QStringLiteral("Parent version"), path,
                    QStringLiteral("Commit version"), path);
                QString subject;
                if (state.commit) subject = fromUtf8(state.commit->commit.subject);
                diffSplit_->setCommitContext(
                    selectedGitCommit_.left(7), subject);
                diffSplit_->setHunkActionsVisible(false);
            } else {
                modeBadge = stagedOnly ? QStringLiteral("STAGED")
                                       : QStringLiteral("WORKING TREE");
                diffSplit_->setFileChrome(fileName, statusBadge, modeBadge);
                diffSplit_->setVersionTitles(
                    QStringLiteral("Repository version"), path,
                    QStringLiteral("Local changes"), path);
                diffSplit_->setCommitContext({}, {});
                diffSplit_->setHunkActionsVisible(true);
            }
        }
        updateWorkbenchChromeForFocus();
        statusBar()->showMessage(QString("%1 diff hunks").arg(
            static_cast<qulonglong>(state.diff->hunks.size())));
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

    if (!state.pendingCheckoutConflict && !state.pendingIntegrationConflict &&
        !state.pendingPullStrategy) {
        suppressPendingGitDialog_ = false;
    }
    if (!handlingGitDialog_ && !suppressPendingGitDialog_) {
        presentPendingGitDialogs(state);
    }
}

void WorkbenchWindow::connectGitPanels() {
    connect(projectSidebarButton_, &QToolButton::clicked, this, [this](bool) {
        showProjectSidebar();
    });
    connect(changesSidebarButton_, &QToolButton::clicked, this, [this](bool) {
        showChangesSidebar();
    });
    connect(gitLogButton_, &QToolButton::clicked, this, [this](bool checked) {
        // Use the post-toggle checked state from the checkable button so we do
        // not invert visibility twice.
        setGitLogVisible(checked);
        if (checked && leftSidebarStack_ != nullptr &&
            leftSidebarStack_->currentIndex() != 1) {
            setLeftSidebarIndex(1);
            refreshGitStatus();
        }
    });

    connect(gitChangesPanel_, &GitChangesPanel::changeSelected, this,
            [this](const QString& path, bool staged, bool untracked) {
        openGitChangeDiff(path, staged, untracked);
    });
    // changeActivated kept for legacy listeners; single/double click both use
    // changeSelected with staged/untracked (macOS selectChange parity).
    connect(gitChangesPanel_, &GitChangesPanel::previewFirstChangeRequested, this, [this] {
        if (!gitFeature_) return;
        const auto state = gitFeature_->state();
        if (!state.status || state.status->changes.empty()) return;
        const auto& first = state.status->changes.front();
        openGitChangeDiff(fromUtf8(first.path), first.staged, first.untracked);
    });
    connect(gitChangesPanel_, &GitChangesPanel::stagePathRequested,
            this, &WorkbenchWindow::stageGitPath);
    connect(gitChangesPanel_, &GitChangesPanel::unstagePathRequested,
            this, &WorkbenchWindow::unstageGitPath);
    connect(gitChangesPanel_, &GitChangesPanel::stageAllRequested,
            this, &WorkbenchWindow::stageAllChanges);
    connect(gitChangesPanel_, &GitChangesPanel::commitRequested,
            this, &WorkbenchWindow::commitChanges);
    connect(gitChangesPanel_, &GitChangesPanel::commitAndPushRequested,
            this, &WorkbenchWindow::commitAndPushChanges);
    connect(gitChangesPanel_, &GitChangesPanel::generateAiMessageRequested,
            this, &WorkbenchWindow::generateAICommitMessage);
    connect(gitChangesPanel_, &GitChangesPanel::refreshRequested,
            this, &WorkbenchWindow::refreshGitStatus);
    connect(gitChangesPanel_, &GitChangesPanel::settingsRequested,
            this, &WorkbenchWindow::showSettings);
    connect(gitChangesPanel_, &GitChangesPanel::discardPathRequested, this,
            [this](const QString& path) {
        if (!gitFeature_ || path.isEmpty()) return;
        if (QMessageBox::question(
                this,
                QStringLiteral("Discard Changes"),
                QStringLiteral("Discard local changes in %1?").arg(path),
                QMessageBox::Yes | QMessageBox::No,
                QMessageBox::No) != QMessageBox::Yes) {
            return;
        }
        gitFeature_->discard({path.toUtf8().toStdString()},
            [this](app::GitFeatureState state) {
            applyGitStateAsync(std::move(state));
        });
    });
    connect(gitChangesPanel_, &GitChangesPanel::continueOperationRequested,
            this, &WorkbenchWindow::continueGitOperation);
    connect(gitChangesPanel_, &GitChangesPanel::abortOperationRequested,
            this, &WorkbenchWindow::abortGitOperation);
    connect(gitChangesPanel_, &GitChangesPanel::skipOperationRequested,
            this, &WorkbenchWindow::skipGitOperation);
    connect(gitChangesPanel_, &GitChangesPanel::filterConflictsRequested,
            this, &WorkbenchWindow::filterGitConflicts);
    connect(gitChangesPanel_, &GitChangesPanel::clearConflictFilterRequested,
            this, &WorkbenchWindow::clearGitConflictFilter);
    connect(gitChangesPanel_, &GitChangesPanel::filterStashRestoreConflictsRequested,
            this, &WorkbenchWindow::filterStashRestoreConflicts);
    connect(gitChangesPanel_, &GitChangesPanel::dismissStashRestoreNoticeRequested,
            this, &WorkbenchWindow::dismissStashRestoreNotice);
    connect(gitChangesPanel_, &GitChangesPanel::applyShelfRequested,
            this, &WorkbenchWindow::applyShelfById);
    connect(gitChangesPanel_, &GitChangesPanel::dropShelfRequested,
            this, &WorkbenchWindow::dropShelfById);
    connect(gitChangesPanel_, &GitChangesPanel::applyStashRequested,
            this, &WorkbenchWindow::applyStashByReference);
    connect(gitChangesPanel_, &GitChangesPanel::popStashRequested,
            this, &WorkbenchWindow::popStashByReference);
    connect(gitChangesPanel_, &GitChangesPanel::dropStashRequested,
            this, &WorkbenchWindow::dropStashByReference);
    connect(gitChangesPanel_, &GitChangesPanel::createStashRequested, this,
            [this](const QString& message, bool includeUntracked) {
        if (!gitFeature_) return;
        gitFeature_->stash(message.toStdString(), includeUntracked,
            [this](app::GitFeatureState state) { applyGitStateAsync(std::move(state)); });
    });
    connect(gitChangesPanel_, &GitChangesPanel::createShelfRequested, this,
            [this](const QString& message) {
        if (!gitFeature_) return;
        gitFeature_->shelveWorkingTree(message.toStdString(),
            [this](app::GitFeatureState state) { applyGitStateAsync(std::move(state)); });
    });
    connect(gitChangesPanel_, &GitChangesPanel::refreshShelvesRequested, this, [this] {
        if (!gitFeature_) return;
        gitFeature_->refreshShelves([this](app::GitFeatureState state) {
            applyGitStateAsync(std::move(state));
        });
    });
    connect(gitChangesPanel_, &GitChangesPanel::refreshStashesRequested, this, [this] {
        if (!gitFeature_) return;
        gitFeature_->refreshStashes([this](app::GitFeatureState state) {
            applyGitStateAsync(std::move(state));
        });
    });

    connect(gitLogPanel_, &GitLogPanel::refreshRequested, this, &WorkbenchWindow::loadGitHistory);
    connect(gitLogPanel_, &GitLogPanel::fetchRequested, this, &WorkbenchWindow::fetchGitRemote);
    connect(gitLogPanel_, &GitLogPanel::pushRequested, this, &WorkbenchWindow::pushGitReference);
    connect(gitLogPanel_, &GitLogPanel::mergeRequested, this, &WorkbenchWindow::mergeGitReference);
    connect(gitLogPanel_, &GitLogPanel::rebaseRequested, this, &WorkbenchWindow::rebaseGitReference);
    connect(gitLogPanel_, &GitLogPanel::pullRequested, this, &WorkbenchWindow::pullGitRemote);
    connect(gitLogPanel_, &GitLogPanel::compareRequested, this, &WorkbenchWindow::compareGitReference);
    connect(gitLogPanel_, &GitLogPanel::showAllReferencesRequested, this, [this] {
        loadGitHistory();
    });
    connect(gitLogPanel_, &GitLogPanel::checkoutReferenceRequested,
            this, &WorkbenchWindow::checkoutGitReference);
    connect(gitLogPanel_, &GitLogPanel::commitSelected, this, &WorkbenchWindow::selectGitCommit);
    connect(gitLogPanel_, &GitLogPanel::commitFileActivated,
            this, &WorkbenchWindow::openGitCommitFile);
}

void WorkbenchWindow::setLeftSidebarIndex(int index) {
    if (leftSidebarStack_ == nullptr) return;
    leftSidebarStack_->setCurrentIndex(index);
    if (projectSidebarButton_ != nullptr) {
        projectSidebarButton_->setChecked(index == 0);
        ui::IdeaIcons::applyToToolButton(
            projectSidebarButton_,
            QStringLiteral("toolwindows/toolWindowProject.svg"),
            16,
            index == 0 ? ui::Theme::primaryText() : ui::Theme::secondaryText());
    }
    if (changesSidebarButton_ != nullptr) {
        changesSidebarButton_->setChecked(index == 1);
        ui::IdeaIcons::applyToToolButton(
            changesSidebarButton_,
            QStringLiteral("toolwindows/toolWindowCommit.svg"),
            16,
            index == 1 ? ui::Theme::primaryText() : ui::Theme::secondaryText());
    }
    updateWorkbenchChromeForFocus();
}

void WorkbenchWindow::setGitLogVisible(bool visible) {
    if (gitLogPanel_ == nullptr) return;
    gitLogPanel_->setVisible(visible);
    if (gitLogButton_ != nullptr) {
        QSignalBlocker blocker(gitLogButton_);
        gitLogButton_->setChecked(visible);
        ui::IdeaIcons::applyToToolButton(
            gitLogButton_,
            QStringLiteral("toolwindows/toolWindowVcs.svg"),
            16,
            visible ? ui::Theme::primaryText() : ui::Theme::secondaryText());
    }
    if (visible) loadGitHistory();
    updateWorkbenchChromeForFocus();
}

void WorkbenchWindow::updateWorkbenchChromeForFocus() {
    const bool gitFocus = leftSidebarStack_ != nullptr &&
        leftSidebarStack_->currentIndex() == 1;
    const bool hideAux = gitFocus ||
        (diffReviewPanel_ != nullptr && editorStack_ != nullptr &&
         editorStack_->currentWidget() == diffReviewPanel_);
    if (mavenControls_ != nullptr) mavenControls_->setVisible(!hideAux);
    if (mavenOutput_ != nullptr) mavenOutput_->setVisible(!hideAux);
    if (searchField_ != nullptr) searchField_->setVisible(!hideAux);
    if (analysisStatus_ != nullptr) analysisStatus_->setVisible(!hideAux);
    if (diagnostics_ != nullptr && hideAux) diagnostics_->setVisible(false);
}

void WorkbenchWindow::showProjectSidebar() {
    setLeftSidebarIndex(0);
}

void WorkbenchWindow::showChangesSidebar() {
    setLeftSidebarIndex(1);
    setGitLogVisible(true);
    refreshGitStatus();
    if (gitFeature_) {
        gitFeature_->refreshShelves([this](app::GitFeatureState state) {
            applyGitStateAsync(std::move(state));
        });
    }
}

void WorkbenchWindow::toggleGitLogPanel() {
    const bool visible = gitLogPanel_ != nullptr && !gitLogPanel_->isVisible();
    setGitLogVisible(visible);
}

void WorkbenchWindow::presentPendingGitDialogs(const app::GitFeatureState& state) {
    if (!gitFeature_ || handlingGitDialog_) return;

    if (state.pendingCheckoutConflict) {
        handlingGitDialog_ = true;
        const auto request = *state.pendingCheckoutConflict;
        const auto result = showGitCheckoutConflictDialog(this, request);
        handlingGitDialog_ = false;
        switch (result.decision) {
        case app::GitCheckoutDialogDecision::Smart:
            suppressPendingGitDialog_ = false;
            gitFeature_->resolveCheckoutConflict(app::GitCheckoutConflictStrategy::Smart,
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        case app::GitCheckoutDialogDecision::Force:
            suppressPendingGitDialog_ = false;
            gitFeature_->resolveCheckoutConflict(app::GitCheckoutConflictStrategy::Force,
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        case app::GitCheckoutDialogDecision::OpenDiff:
            if (!result.selectedPath.isEmpty()) {
                suppressPendingGitDialog_ = true;
                openGitChangeDiff(result.selectedPath, false, false);
            }
            return;
        case app::GitCheckoutDialogDecision::DiscardAndRetry:
            if (!result.selectedPath.isEmpty()) {
                suppressPendingGitDialog_ = false;
                gitFeature_->discardConflictPath(result.selectedPath.toUtf8().toStdString(),
                    [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            }
            return;
        case app::GitCheckoutDialogDecision::Cancel:
            suppressPendingGitDialog_ = false;
            gitFeature_->cancelCheckoutConflict(
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        }
    }

    if (state.pendingIntegrationConflict) {
        handlingGitDialog_ = true;
        const auto request = *state.pendingIntegrationConflict;
        const auto result = showGitIntegrationConflictDialog(this, request);
        handlingGitDialog_ = false;
        switch (result.decision) {
        case app::GitIntegrationDialogDecision::SaveAndContinue:
            suppressPendingGitDialog_ = false;
            gitFeature_->resolveIntegrationConflict(
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        case app::GitIntegrationDialogDecision::OpenDiff:
            if (!result.selectedPath.isEmpty()) {
                suppressPendingGitDialog_ = true;
                openGitChangeDiff(result.selectedPath, false, false);
            }
            return;
        case app::GitIntegrationDialogDecision::DiscardAndRetry:
            if (!result.selectedPath.isEmpty()) {
                suppressPendingGitDialog_ = false;
                gitFeature_->discardConflictPath(result.selectedPath.toUtf8().toStdString(),
                    [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            }
            return;
        case app::GitIntegrationDialogDecision::Cancel:
            suppressPendingGitDialog_ = false;
            gitFeature_->cancelIntegrationConflict(
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        }
    }

    if (state.pendingPullStrategy) {
        handlingGitDialog_ = true;
        const auto request = *state.pendingPullStrategy;
        const auto result = showGitPullStrategyDialog(this, request);
        handlingGitDialog_ = false;
        switch (result.decision) {
        case app::GitPullDialogDecision::FfOnly:
            gitFeature_->resolvePullStrategy(app::GitPullStrategy::FfOnly,
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        case app::GitPullDialogDecision::Merge:
            gitFeature_->resolvePullStrategy(app::GitPullStrategy::Merge,
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        case app::GitPullDialogDecision::Rebase:
            gitFeature_->resolvePullStrategy(app::GitPullStrategy::Rebase,
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        case app::GitPullDialogDecision::Cancel:
            gitFeature_->cancelPullStrategy(
                [this](app::GitFeatureState next) { applyGitStateAsync(std::move(next)); });
            return;
        }
    }
}

void WorkbenchWindow::syncDirtyDocumentsPort(const app::DocumentFeatureState& state) {
    if (!dirtyDocuments_ || state.relativePath.empty()) return;
    // Upsert the current document only so other dirty tabs stay visible to
    // preflight until W1 owns a real multi-buffer dirty port.
    auto paths = dirtyDocuments_->dirtyRelativePaths();
    paths.erase(std::remove(paths.begin(), paths.end(), state.relativePath), paths.end());
    if (state.isDirty) {
        paths.push_back(state.relativePath);
    }
    dirtyDocuments_->setDirtyPaths(std::move(paths));
}

void WorkbenchWindow::renderDiffReview() {
    if (diffSplit_ == nullptr) return;
    if (!diffReview_) {
        closeDiffReview();
        return;
    }

    std::vector<algorithms::DiffRow> rows;
    rows.reserve(diffReview_->rows.size());
    for (std::size_t index = 0; index < diffReview_->rows.size(); ++index) {
        const auto& source = diffReview_->rows[index];
        std::optional<std::size_t> oldLine;
        std::optional<std::size_t> newLine;
        if (source.oldLine) oldLine = static_cast<std::size_t>(*source.oldLine);
        if (source.newLine) newLine = static_cast<std::size_t>(*source.newLine);
        rows.push_back({oldLine,
                        newLine,
                        source.left,
                        source.right,
                        diffRowKind(source.kind),
                        source.hunkId.value_or(std::string{}),
                        index});
    }
    diffSplit_->setDiff(rows, expandedDiffRegions_);
    if (!selectedDiffHunk_.isEmpty()) {
        diffSplit_->setSelectedHunkId(selectedDiffHunk_);
    }
    const bool hasRows = !diffReview_->rows.empty();
    if (editorStack_ != nullptr) {
        if (presentDiffReview_ && hasRows) {
            editorStack_->setCurrentWidget(diffReviewPanel_);
        } else if (!presentDiffReview_) {
            editorStack_->setCurrentWidget(editorPage_);
        }
    }
    updateWorkbenchChromeForFocus();
}

void WorkbenchWindow::closeDiffReview() {
    presentDiffReview_ = false;
    diffReview_.reset();
    selectedDiffHunk_.clear();
    if (diffSplit_ != nullptr) diffSplit_->clear();
    if (editorStack_ != nullptr && editorPage_ != nullptr) {
        editorStack_->setCurrentWidget(editorPage_);
    }
    updateWorkbenchChromeForFocus();
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
            statusBar()->showMessage(QStringLiteral("All changes staged"), 3000);
            loadSnapshot();
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::commitChanges() {
    if (!gitFeature_ || workspaceRoot_.isEmpty() || gitChangesPanel_ == nullptr) return;
    const auto current = gitFeature_->state();
    if (app::commitBlockedByConflicts(current.status, {})) {
        statusBar()->showMessage(
            QStringLiteral("Resolve Git conflicts before committing"), 5000);
        return;
    }
    const auto message = gitChangesPanel_->commitMessage().trimmed();
    if (message.isEmpty()) {
        statusBar()->showMessage(QStringLiteral("Enter a commit message first"), 4000);
        gitChangesPanel_->focusCommitMessage();
        return;
    }
    const auto amend = gitChangesPanel_->isAmendChecked();
    gitFeature_->commit(message.toUtf8().toStdString(), amend,
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            if (state.error) {
                showFeatureError(state.error, QStringLiteral("Commit failed"));
                return;
            }
            if (state.isWriting) return;
            if (gitChangesPanel_ != nullptr) gitChangesPanel_->clearCommitMessage();
            statusBar()->showMessage(QStringLiteral("Commit created"), 4000);
            loadSnapshot();
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::commitAndPushChanges() {
    if (!gitFeature_ || workspaceRoot_.isEmpty() || gitChangesPanel_ == nullptr) return;
    const auto current = gitFeature_->state();
    if (app::commitBlockedByConflicts(current.status, {})) {
        statusBar()->showMessage(
            QStringLiteral("Resolve Git conflicts before committing"), 5000);
        return;
    }
    const auto message = gitChangesPanel_->commitMessage().trimmed();
    if (message.isEmpty()) {
        statusBar()->showMessage(QStringLiteral("Enter a commit message first"), 4000);
        gitChangesPanel_->focusCommitMessage();
        return;
    }
    if (!confirmDestructiveGitAction(
            this,
            QStringLiteral("Commit and Push"),
            QStringLiteral("The staged changes will be committed and the current branch will be pushed to its configured remote."))) {
        return;
    }
    const auto amend = gitChangesPanel_->isAmendChecked();
    gitFeature_->commitAndPush(message.toUtf8().toStdString(), amend,
        [this](app::GitFeatureState state) {
        QMetaObject::invokeMethod(this, [this, state = std::move(state)]() mutable {
            applyGitState(state);
            if (state.error || state.isWriting || state.isPerformingBranchOperation) return;
            if (gitChangesPanel_ != nullptr) gitChangesPanel_->clearCommitMessage();
            statusBar()->showMessage(QStringLiteral("Commit created and pushed"), 4000);
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
        statusBar()->showMessage(QStringLiteral("AI endpoint and model are required"), 5000);
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
    statusBar()->showMessage(QStringLiteral("Generating commit message..."));
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
            if (gitChangesPanel_ != nullptr) gitChangesPanel_->setCommitMessage(fromUtf8(message));
            statusBar()->showMessage(QStringLiteral("AI commit message ready"), 4000);
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
        statusBar()->showMessage(QStringLiteral("There are no staged changes"), 5000);
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
                statusBar()->showMessage(QStringLiteral("There is no staged textual diff"), 5000);
                return;
            }
            startAIGeneration(std::move(input), std::move(settings));
        }, Qt::QueuedConnection);
    });
}

void WorkbenchWindow::checkForUpdates() {
    if (updateBusy_.exchange(true)) return;
    if (updateWorker_.joinable()) updateWorker_.join();
    statusBar()->showMessage(QStringLiteral("Checking for Windows updates..."));
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
                    statusBar()->showMessage(QStringLiteral("Lithe is up to date"), 4000);
                } else {
                    statusBar()->showMessage(QStringLiteral("Update check failed: ") +
                                                 fromUtf8(error.message), 8000);
                }
                return;
            }
            const auto answer = QMessageBox::question(
                this, QStringLiteral("Windows update available"),
                QStringLiteral("Lithe %1 is available. Download the verified installer?")
                    .arg(fromUtf8(release->version)),
                QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
            if (answer != QMessageBox::Yes) return;
            const auto cache = QString::fromUtf8(storage_->cacheDirectory().data());
            QDir().mkpath(cache);
            const auto filename = QString::fromUtf8(asset->name.data());
            const auto destination = QFileDialog::getSaveFileName(
                this, QStringLiteral("Save Windows installer"), QDir(cache).filePath(filename),
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
                statusBar()->showMessage(QStringLiteral("Update download failed: ") +
                                             fromUtf8(error.message), 8000);
                return;
            }
            statusBar()->showMessage(QStringLiteral("Verified installer downloaded"), 5000);
            const auto answer = QMessageBox::question(
                this, QStringLiteral("Installer ready"),
                QStringLiteral("The SHA-256 verified installer is ready. Launch it now?"),
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
                statusBar()->showMessage(QStringLiteral("Could not launch the Windows update helper"),
                                         6000);
                return;
            }
            statusBar()->showMessage(QStringLiteral("Closing Lithe to install the update"), 5000);
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
        parts.push_back(QStringLiteral("No Maven project"));
    }
    if (state.runConfigurations) {
        parts.push_back(QString("%1 run configurations")
            .arg(static_cast<qulonglong>(state.runConfigurations->configurations.size())));
    }
    if (state.codeVision) {
        parts.push_back(QString("%1 code vision hints")
            .arg(static_cast<qulonglong>(state.codeVision->hints.size())));
    }
    if (state.structure) {
        parts.push_back(QString("%1 fold regions")
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
        statusBar()->showMessage(QStringLiteral("Maven could not start"), 5000);
        return;
    }

    QStringList arguments;
    for (const auto& argument : process->arguments) arguments.push_back(fromUtf8(argument));
    appendMavenOutput(QStringLiteral("$ ") + fromUtf8(process->executablePath) +
                      QStringLiteral(" ") + arguments.join(QStringLiteral(" ")) +
                      QStringLiteral("\n\n"));
    mavenSession_->start(*process);
    statusBar()->showMessage(QStringLiteral("Maven %1 is running").arg(phase));
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
        statusBar()->showMessage(QStringLiteral("Starting Maven"));
        break;
    case ProcessLifecycleState::Running:
        statusBar()->showMessage(QStringLiteral("Maven is running"));
        break;
    case ProcessLifecycleState::Stopping:
        statusBar()->showMessage(QStringLiteral("Stopping Maven"));
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") + fromUtf8(event.message) +
                                                      QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Failed:
        statusBar()->showMessage(QStringLiteral("Maven failed to start"), 5000);
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") + fromUtf8(event.message) +
                                                      QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Finished:
        statusBar()->showMessage(QStringLiteral("Maven finished with exit code %1")
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
        statusBar()->showMessage(QStringLiteral("No Spring Boot run configuration was detected"),
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
            statusBar()->showMessage(QStringLiteral("Open a Java file before running it"), 5000);
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
        statusBar()->showMessage(QStringLiteral("Java run could not start"), 5000);
        return;
    }
    QStringList arguments;
    for (const auto& argument : process->arguments) arguments.push_back(fromUtf8(argument));
    appendMavenOutput(QStringLiteral("$ ") + fromUtf8(process->executablePath) +
                      QStringLiteral(" ") + arguments.join(QStringLiteral(" ")) +
                      QStringLiteral("\n\n"));
    javaSession_->start(*process);
    statusBar()->showMessage(QStringLiteral("%1 is running")
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
        statusBar()->showMessage(QStringLiteral("Starting Java"));
        break;
    case ProcessLifecycleState::Running:
        statusBar()->showMessage(QStringLiteral("Java is running"));
        break;
    case ProcessLifecycleState::Stopping:
        statusBar()->showMessage(QStringLiteral("Stopping Java"));
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") +
                                                       fromUtf8(event.message) +
                                                       QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Failed:
        statusBar()->showMessage(QStringLiteral("Java failed to start"), 5000);
        if (!event.message.empty()) appendMavenOutput(QStringLiteral("\n") +
                                                       fromUtf8(event.message) +
                                                       QStringLiteral("\n"));
        break;
    case ProcessLifecycleState::Finished:
        statusBar()->showMessage(QStringLiteral("Java finished with exit code %1")
                                     .arg(event.exitCode.value_or(1)), 5000);
        appendMavenOutput(QStringLiteral("\nJava finished with exit code ") +
                          QString::number(event.exitCode.value_or(1)) + QStringLiteral("\n"));
        break;
    }
}

void WorkbenchWindow::debugCurrentJava() {
    if (workspaceRoot_.isEmpty() || activePath_.isEmpty() ||
        !activePath_.endsWith(QStringLiteral(".java"), Qt::CaseInsensitive)) {
        statusBar()->showMessage(QStringLiteral("Open a Java file before debugging it"), 5000);
        return;
    }
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
        statusBar()->showMessage(QStringLiteral("Open a Java file before adding a breakpoint"),
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
        statusBar()->showMessage(QStringLiteral("Java language server is not ready"), 5000);
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
        statusBar()->showMessage(QString("%1 Java diagnostics")
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
        statusBar()->showMessage(QStringLiteral("Java language server unavailable: ") +
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
    statusBar()->showMessage(QStringLiteral("Terminal started"), 3000);
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
    syncDirtyDocumentsPort(state);
    statusBar()->showMessage(QString("Saved %1").arg(activePath_), 3000);
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
    QString detail = message;
    if (error && error->details && !error->details->empty()) {
        detail += QStringLiteral(" — ") + fromUtf8(*error->details);
    }
    statusBar()->showMessage(detail, 10000);
}


void WorkbenchWindow::stageGitPath(const QString& path) {
    if (!gitFeature_ || path.isEmpty()) return;
    gitFeature_->stage({path.toUtf8().toStdString()}, [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::unstageGitPath(const QString& path) {
    if (!gitFeature_ || path.isEmpty()) return;
    gitFeature_->unstage({path.toUtf8().toStdString()}, [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::applyShelfById(const QString& shelfId) {
    if (!gitFeature_ || shelfId.isEmpty()) return;
    const auto state = gitFeature_->state();
    for (const auto& shelf : state.shelves) {
        if (shelf.id != shelfId.toStdString()) continue;
        gitFeature_->applyShelf(shelf, [this](app::GitFeatureState next) {
            applyGitStateAsync(std::move(next));
            loadSnapshot();
        });
        return;
    }
}

void WorkbenchWindow::dropShelfById(const QString& shelfId) {
    if (!gitFeature_ || shelfId.isEmpty()) return;
    if (!confirmDestructiveGitAction(
            this, QStringLiteral("Drop Shelf"),
            QStringLiteral("This removes the saved patch from Lithe and cannot be undone."))) {
        return;
    }
    const auto state = gitFeature_->state();
    for (const auto& shelf : state.shelves) {
        if (shelf.id != shelfId.toStdString()) continue;
        gitFeature_->dropShelf(shelf, [this](app::GitFeatureState next) {
            applyGitStateAsync(std::move(next));
        });
        return;
    }
}

void WorkbenchWindow::applyStashByReference(const QString& reference) {
    if (!gitFeature_ || reference.isEmpty()) return;
    selectedGitStash_ = reference;
    gitFeature_->applyStash(reference.toStdString(), [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
        loadSnapshot();
    });
}

void WorkbenchWindow::popStashByReference(const QString& reference) {
    if (!gitFeature_ || reference.isEmpty()) return;
    selectedGitStash_ = reference;
    gitFeature_->popStash(reference.toStdString(), [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
        loadSnapshot();
    });
}

void WorkbenchWindow::dropStashByReference(const QString& reference) {
    if (!gitFeature_ || reference.isEmpty()) return;
    if (!confirmDestructiveGitAction(
            this, QStringLiteral("Drop Stash"),
            QStringLiteral("This removes the stash from Git and cannot be undone."))) {
        return;
    }
    selectedGitStash_ = reference;
    gitFeature_->dropStash(reference.toStdString(), [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
    });
}

void WorkbenchWindow::checkoutGitReference(const QString& fullName,
                                          const QString& kind,
                                          const QString& shortName) {
    if (!gitFeature_ || fullName.isEmpty()) return;
    gitFeature_->checkoutReference(
        fullName.toStdString(), kind.toStdString(), shortName.toStdString(),
        [this](app::GitFeatureState state) {
        applyGitStateAsync(std::move(state));
        loadSnapshot();
    });
}

} // namespace lithe::windows
