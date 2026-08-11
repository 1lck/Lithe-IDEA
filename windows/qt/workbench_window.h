#pragma once

#include "document_feature.h"
#include "dirty_documents_port.h"
#include "diff_split_widget.h"
#include "git_changes_panel.h"
#include "git_feature.h"
#include "git_log_panel.h"
#include "git_watcher_freeze.h"
#include "git_workflow_dialogs.h"
#include "git_workflow_ui.h"
#include "history_feature.h"
#include "java_debug_service.h"
#include "java_language_server.h"
#include "java_run_service.h"
#include "maven_build_service.h"
#include "maven_java_feature.h"
#include "ai_commit_service.h"
#include "app_persistence.h"
#include "project_runtime_service.h"
#include "search_feature.h"
#include "shelve_service.h"
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
#include <unordered_set>

class QLineEdit;
class QLabel;
class QPoint;
class QObject;
class QDialog;
class QEvent;
class QListWidget;
class QListWidgetItem;
class QPlainTextEdit;
class QPushButton;
class QSplitter;
class QStackedWidget;
class QTimer;
class QTreeWidget;
class QTreeWidgetItem;
class QTableWidget;
class QTableWidgetItem;
class QTabBar;
class QTextBrowser;
class QToolButton;
class QWidget;

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
    void compareGitReference();
    void switchGitReference();
    void createGitBranch();
    void fetchGitRemote();
    void pushGitReference();
    void mergeGitReference();
    void rebaseGitReference();
    void pullGitRemote();
    void applySelectedStash();
    void popSelectedStash();
    void dropSelectedStash();
    void stageSelectedHunk();
    void unstageSelectedHunk();
    void discardSelectedHunk();
    void stageAllChanges();
    void commitChanges();
    void commitAndPushChanges();
    void continueGitOperation();
    void abortGitOperation();
    void skipGitOperation();
    void filterGitConflicts();
    void clearGitConflictFilter();
    void filterStashRestoreConflicts();
    void dismissStashRestoreNotice();
    void showChangesSidebar();
    void showProjectSidebar();
    void toggleGitLogPanel();
    void stageGitPath(const QString& path);
    void unstageGitPath(const QString& path);
    void applyShelfById(const QString& shelfId);
    void dropShelfById(const QString& shelfId);
    void applyStashByReference(const QString& reference);
    void popStashByReference(const QString& reference);
    void dropStashByReference(const QString& reference);
    void checkoutGitReference(const QString& fullName,
                              const QString& kind,
                              const QString& shortName);
    void selectGitCommit(const QString& hash);
    void openGitCommitFile(const QString& path);
    void openGitChangeDiff(const QString& path, bool staged, bool untracked);
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
    void closeDiffReview();
    void applySelectedHunk(const QString& mode);
    QTreeWidgetItem* findTreeItem(const QString& relativePath) const;
    void applyWorkspaceState(const app::WorkspaceFeatureState& state);
    void applyDocumentState(const app::DocumentFeatureState& state);
    void applySearchState(const app::SearchFeatureState& state);
    void applySearchEverywhereState(const app::SearchEverywhereFeatureState& state);
    void openSearchResult(QListWidgetItem* item);
    void openJavaNavigationItem(QListWidgetItem* item);
    void applyGitState(const app::GitFeatureState& state);
    void presentPendingGitDialogs(const app::GitFeatureState& state);
    void syncDirtyDocumentsPort(const app::DocumentFeatureState& state);
    void applyGitStateAsync(app::GitFeatureState state);
    void connectGitPanels();
    void setLeftSidebarIndex(int index);
    void setGitLogVisible(bool visible);
    void updateWorkbenchChromeForFocus();
    std::optional<GitReferenceDto> pickGitReference(const QString& title);
    void pickGitReferenceAsync(const QString& title,
                               std::function<void(std::optional<GitReferenceDto>)> onPicked);
    void applyHistoryState(const app::HistoryFeatureState& state);
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
    app::AppSettings appSettings_;
    Win32RuntimeLocator runtimeLocator_;
    app::ProjectRuntimeService runtimeService_;
    Win32ProcessRunner mavenRunner_;
    Win32ProcessRunner archiveRunner_;
    Win32ArchiveEntryReader archiveReader_;
    app::MavenBuildService mavenBuildService_;
    std::unique_ptr<app::WorkbenchCoordinator> coordinator_;
    std::unique_ptr<FileStorage> storage_;
    std::unique_ptr<app::FakeDirtyDocumentsPort> dirtyDocuments_;
    std::unique_ptr<app::ShelveService> shelveService_;
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
    app::GitWatcherFreezeController gitWatcherFreeze_;
    std::unique_ptr<app::HistoryFeatureModel> historyFeature_;
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
    bool handlingGitDialog_ = false;
    QToolButton* projectSidebarButton_ = nullptr;
    QToolButton* changesSidebarButton_ = nullptr;
    QToolButton* gitLogButton_ = nullptr;
    QStackedWidget* leftSidebarStack_ = nullptr;
    QSplitter* contentSplitter_ = nullptr;
    QTreeWidget* tree_ = nullptr;
    GitChangesPanel* gitChangesPanel_ = nullptr;
    GitLogPanel* gitLogPanel_ = nullptr;
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
    DiffSplitWidget* diffSplit_ = nullptr;
    QStackedWidget* editorStack_ = nullptr;
    QWidget* editorPage_ = nullptr;
    QListWidget* history_ = nullptr;
    QLabel* analysisStatus_ = nullptr;
    QListWidget* diagnostics_ = nullptr;
    QWidget* mavenControls_ = nullptr;
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
    QTimer* workspaceRefreshTimer_ = nullptr;
    QTimer* gitRefreshTimer_ = nullptr;
    QTimer* debugPollTimer_ = nullptr;
    bool historyContentSelectionPending_ = false;
    std::optional<app::WorkspaceSession> pendingWorkspaceSession_;
    QString selectedDiffHunk_;
    std::optional<GitDiffDto> diffReview_;
    std::unordered_set<std::string> expandedDiffRegions_;
    QString selectedGitCommit_;
    QString selectedGitStash_;
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
    bool presentDiffReview_ = false;
    std::chrono::steady_clock::time_point lastShiftPress_{};
    std::unique_ptr<Win32TerminalTransport> terminal_;
    std::thread aiWorker_;
    std::thread updateWorker_;
    std::atomic<bool> aiGenerating_{false};
    std::atomic<bool> updateBusy_{false};
};

} // namespace lithe::windows
