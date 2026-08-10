#pragma once

#include "document_feature.h"
#include "git_graph_layout.h"
#include "git_feature.h"
#include "history_feature.h"
#include "shelf_feature.h"
#include "java_debug_service.h"
#include "java_language_server.h"
#include "java_run_service.h"
#include "maven_build_service.h"
#include "maven_java_feature.h"
#include "ai_commit_service.h"
#include "app_persistence.h"
#include "workbench_editor_area.h"
#include "workbench_layout_persistence.h"
#include "workbench_sidebar.h"
#include "workbench_tool_window.h"
#include "project_runtime_service.h"
#include "search_feature.h"
#include "workspace_feature.h"
#include "ports.h"
#include "win32_key_value_store.h"
#include "win32_http_transport.h"
#include "win32_authenticode_verifier.h"
#include "win32_archive_entry_reader.h"
#include "win32_process_runner.h"
#include "win32_process_session.h"
#include "win32_runtime_locator.h"
#include "win32_secure_store.h"
#include "win32_terminal_transport.h"
#include "windows_update_service.h"

#include <QMainWindow>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>

class QLineEdit;
class QLabel;
class QCheckBox;
class QPoint;
class QObject;
class QDialog;
class QEvent;
class QCloseEvent;
class QListWidget;
class QListWidgetItem;
class QPlainTextEdit;
class QPushButton;
class QTimer;
class QTreeWidget;
class QTreeWidgetItem;
class QTableWidget;
class QTableWidgetItem;
class QTabBar;
class QTextBrowser;
class QWidget;
class QSplitter;

namespace lithe::windows {

class WorkbenchCodeEditor;

class WorkbenchWindow final : public QMainWindow {
    Q_OBJECT

public:
    explicit WorkbenchWindow(std::unique_ptr<DirectoryChangeSource> watcher,
                             QWidget* parent = nullptr);
    ~WorkbenchWindow() override;

private slots:
    void chooseWorkspace();
    void refreshWorkspace();
    void openTreeItem(QTreeWidgetItem* item, int column);
    void switchEditorTab(int index);
    void closeEditorTab(int index);
    void openChangeItem(QListWidgetItem* item);
    void openHistoryItem(QListWidgetItem* item);
    void openCommitFile(QListWidgetItem* item);
    void loadGitHistory();
    void openGitHistoryItem(QListWidgetItem* item);
    void loadGitStashes();
    void loadShelves();
    void createShelf();
    void restoreSelectedShelf();
    void deleteSelectedShelf();
    void setShelfActionsEnabled(bool enabled);
    void compareGitReference();
    void switchGitReference();
    void createGitBranch();
    void applySelectedStash();
    void popSelectedStash();
    void dropSelectedStash();
    void stageSelectedHunk();
    void unstageSelectedHunk();
    void discardSelectedHunk();
    void stageAllChanges();
    void commitChanges();
    void toggleBlame();
    void generateAICommitMessage();
    void checkForUpdates();
    void showSettings();
    void showCommandPalette();
    void showWelcomeDialog();
    void showFindBar();
    void hideFindBar();
    void findNext();
    void findPrevious();
    void showMarkdownPreview();
    void searchWorkspace();
    void showSearchEverywhere();
    void searchEverywhere();
    void saveDocument();
    void stopMavenBuild();
    void runCurrentJava();
    void runSpringBoot();
    void stopJavaRun();
    void debugCurrentJava();
    void debugSpringBoot();
    void attachRemoteDebugger();
    void stopDebugger();
    void continueDebugger();
    void pauseDebugger();
    void stepIntoDebugger();
    void stepOverDebugger();
    void stepOutDebugger();
    void toggleBreakpoint();
    void inspectDebuggerThreads();
    void inspectDebuggerStack();
    void inspectDebuggerVariables();
    void evaluateDebuggerExpression();
    void toggleDebuggerVariable(QListWidgetItem* item);
    void gotoJavaDefinition();
    void findJavaUsages();
    void startTerminal();
    void stopTerminal();

private:
    bool eventFilter(QObject* watched, QEvent* event) override;
    void closeEvent(QCloseEvent* event) override;

    void buildActions();
    void loadSnapshot();
    void showTreeContextMenu(const QPoint& position);
    void createWorkspaceItem(bool directory);
    void renameWorkspaceItem();
    void copyWorkspaceItem();
    void deleteWorkspaceItem();
    void copyWorkspacePath(bool absolute);
    void restoreRecentWorkspace();
    void showCloneRepositoryDialog();
    void openWorkspaceRoot(const QString& root);
    void restoreWorkspaceSession();
    void saveWorkspaceSession();
    void loadProjectAnalysis();
    void scheduleWorkspaceRefresh();
    void scheduleGitRefresh();
    void handleDirectoryChanges(
        const std::vector<DirectoryChangeSource::Change>& changes);
    void refreshGitStatus();
    void applyStashOperation(const QString& operation);
    void renderDiffReview();
    void applySelectedHunk(const QString& mode);
    QTreeWidgetItem* findTreeItem(const QString& relativePath) const;
    void applyWorkspaceState(const app::WorkspaceFeatureState& state);
    void applyDocumentState(const app::DocumentFeatureState& state);
    void connectDocumentEditor(WorkbenchCodeEditor* editor);
    void updateDocumentTabState(const QString& relativePath);
    bool requestDocumentTransition(std::function<void()> transition);
    void finishDocumentTransitionSave(const QString& relativePath,
                                      const app::DocumentFeatureState& state);
    bool ensureDocumentsSafeForGit();
    void applySearchState(const app::SearchFeatureState& state);
    void applySearchEverywhereState(const app::SearchEverywhereFeatureState& state);
    void openSearchResult(QListWidgetItem* item);
    void openJavaNavigationItem(QListWidgetItem* item);
    void applyGitState(const app::GitFeatureState& state);
    void applyHistoryState(const app::HistoryFeatureState& state);
    void applyShelfState(const app::ShelfFeatureState& state);
    void applyMavenJavaState(const app::MavenJavaFeatureState& state,
                             bool renderCodeVision = false,
                             bool renderStructure = false);
    void applySaveState(const app::DocumentFeatureState& state);
    void updateFindHighlights();
    void findInEditor(bool forward);
    void runMavenPhase(const QString& phase);
    void synchronizeJavaRunProject();
    void runJavaConfiguration(const JavaRunConfigurationDto& configuration);
    void appendMavenOutput(const QString& text);
    void applyMavenLifecycle(const ProcessLifecycleEvent& event);
    void applyJavaLifecycle(const ProcessLifecycleEvent& event);
    void applyJavaDebugState();
    void appendDebugVariable(const app::JavaDebugVariable& variable, int depth);
    void applyJavaNavigation(const std::optional<JsonValue>& result,
                             const std::optional<app::LspRpcError>& error,
                             const QString& title);
    void applyLanguageServerState(bool ready, const std::string& message);
    void applyLanguageServerDiagnostics(const std::string& uri,
                                       const JsonValue& diagnostics);
    void ensureJavaLanguageServer();
    void closeLanguageServerDocument();
    void synchronizeLanguageServerDocument();
    void restoreWorkbenchLayout();
    void saveWorkbenchLayout();
    void scheduleWorkbenchLayoutSave();
    void showToolWindow(BottomToolKind kind);
    void appendTreeNode(QTreeWidgetItem* parent, const WorkspaceNodeDto& node);
    int ensureEditorTab(const QString& relativePath);
    void showFeatureError(const std::optional<CoreError>& error, const QString& fallback);
    std::optional<app::AICommitSettings> configureAISettings();
    app::AICommitSettings loadAISettings() const;
    bool saveAISettings(const app::AICommitSettings& settings, std::string& error);
    void startAIGeneration(app::AICommitInput input, app::AICommitSettings settings);
    void downloadUpdate(const app::WindowsReleaseAsset& asset, const QString& destination);

    Win32KeyValueStore keyValueStore_;
    app::RecentProjectsStore recentProjectsStore_;
    app::WorkspaceSessionStore workspaceSessionStore_;
    app::AppSettingsStore appSettingsStore_;
    WorkbenchLayoutPersistence layoutPersistence_;
    app::AppSettings appSettings_;
    Win32RuntimeLocator runtimeLocator_;
    app::ProjectRuntimeService runtimeService_;
    Win32ProcessRunner mavenRunner_;
    Win32ProcessRunner archiveRunner_;
    Win32ArchiveEntryReader archiveReader_;
    app::MavenBuildService mavenBuildService_;
    std::unique_ptr<app::WorkbenchCoordinator> coordinator_;
    std::unique_ptr<FileStorage> storage_;
    Win32SecureStore secureStore_;
    Win32HttpTransport httpTransport_;
    Win32AuthenticodeVerifier authenticodeVerifier_;
    app::AICommitMessageService aiCommitService_;
    app::WindowsUpdateService updateService_;
    std::unique_ptr<app::JavaRunService> javaRunService_;
    std::unique_ptr<app::JavaDebugService> javaDebugService_;
    std::unique_ptr<app::WorkspaceFeatureModel> workspaceFeature_;
    std::unique_ptr<app::DocumentFeatureModel> documentFeature_;
    std::unique_ptr<app::SearchFeatureModel> searchFeature_;
    std::unique_ptr<app::GitFeatureModel> gitFeature_;
    std::unique_ptr<app::HistoryFeatureModel> historyFeature_;
    std::unique_ptr<app::ShelfFeatureModel> shelfFeature_;
    std::unique_ptr<app::MavenJavaFeatureModel> mavenJavaFeature_;
    std::unique_ptr<Win32ProcessSession> mavenSession_;
    std::unique_ptr<Win32ProcessSession> javaSession_;
    std::unique_ptr<Win32ProcessSession> languageServerSession_;
    std::unique_ptr<app::JavaLanguageServerClient> languageServer_;
    std::unique_ptr<DirectoryChangeSource> watcher_;
    QString workspaceRoot_;
    std::uint64_t workspaceEpoch_ = 0;
    QString activePath_;
    bool librarySourcePreview_ = false;
    QTreeWidget* tree_ = nullptr;
    WorkbenchCodeEditor* editor_ = nullptr;
    QTabBar* editorTabs_ = nullptr;
    QLineEdit* searchField_ = nullptr;
    QWidget* findBar_ = nullptr;
    QLineEdit* findField_ = nullptr;
    QLabel* findStatus_ = nullptr;
    QListWidget* results_ = nullptr;
    QDialog* searchEverywhereDialog_ = nullptr;
    QLineEdit* searchEverywhereField_ = nullptr;
    QListWidget* searchEverywhereResults_ = nullptr;
    QListWidget* navigation_ = nullptr;
    QListWidget* changes_ = nullptr;
    QListWidget* gitHistory_ = nullptr;
    QListWidget* gitStashes_ = nullptr;
    QWidget* gitStashActions_ = nullptr;
    QListWidget* gitShelves_ = nullptr;
    QWidget* gitShelfActions_ = nullptr;
    QPushButton* createShelfButton_ = nullptr;
    QPushButton* restoreShelfButton_ = nullptr;
    QPushButton* deleteShelfButton_ = nullptr;
    QPlainTextEdit* gitDetails_ = nullptr;
    QListWidget* commitFiles_ = nullptr;
    QPlainTextEdit* commitEditor_ = nullptr;
    QCheckBox* amendCommit_ = nullptr;
    QWidget* diffActions_ = nullptr;
    QTableWidget* diff_ = nullptr;
    QListWidget* history_ = nullptr;
    QLabel* analysisStatus_ = nullptr;
    QListWidget* diagnostics_ = nullptr;
    QPlainTextEdit* mavenOutput_ = nullptr;
    QWidget* debugPanel_ = nullptr;
    QPlainTextEdit* debugOutput_ = nullptr;
    QLineEdit* debugExpression_ = nullptr;
    QListWidget* debugVariables_ = nullptr;
    QListWidget* debugThreads_ = nullptr;
    QListWidget* debugStack_ = nullptr;
    QWidget* terminalPanel_ = nullptr;
    QPlainTextEdit* terminalOutput_ = nullptr;
    QLineEdit* terminalInput_ = nullptr;
    QWidget* diffReviewPanel_ = nullptr;
    QListWidget* diffOverview_ = nullptr;
    QTimer* workspaceRefreshTimer_ = nullptr;
    QTimer* gitRefreshTimer_ = nullptr;
    QTimer* layoutSaveTimer_ = nullptr;
    QTimer* debugPollTimer_ = nullptr;
    bool historyContentSelectionPending_ = false;
    std::optional<app::WorkspaceSession> pendingWorkspaceSession_;
    std::unordered_map<std::string, app::WorkspaceSession::DocumentView> pendingDocumentViews_;
    QString selectedDiffHunk_;
    std::optional<GitDiffDto> diffReview_;
    algorithms::GitGraphLayout gitHistoryGraph_;
    std::unordered_set<std::string> expandedDiffRegions_;
    std::function<void()> pendingDocumentTransition_;
    std::unordered_set<std::string> pendingDocumentSavePaths_;
    bool documentTransitionSaveFailed_ = false;
    QString selectedGitCommit_;
    QString selectedGitStash_;
    QString selectedShelf_;
    QString blamePath_;
    std::optional<std::uint64_t> pendingNavigationLine_;
    std::optional<std::uint64_t> pendingNavigationColumn_;
    QString languageServerRoot_;
    QString languageServerPath_;
    std::string languageServerUri_;
    std::string languageServerText_;
    bool suppressEditorChange_ = false;
    bool languageServerDocumentOpen_ = false;
    bool diffIsCommitReview_ = false;
    std::chrono::steady_clock::time_point lastShiftPress_{};
    std::unique_ptr<Win32TerminalTransport> terminal_;
    std::thread aiWorker_;
    std::thread updateWorker_;
    std::atomic<bool> aiGenerating_{false};
    std::atomic<bool> updateBusy_{false};
    WorkbenchSidebar* sidebar_ = nullptr;
    WorkbenchEditorArea* editorArea_ = nullptr;
    WorkbenchToolWindow* toolWindow_ = nullptr;
    QSplitter* shellSplitter_ = nullptr;
    QSplitter* editorToolSplitter_ = nullptr;
    WorkbenchLayoutState layoutState_;
};

} // namespace lithe::windows
