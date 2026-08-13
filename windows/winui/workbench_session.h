#pragma once

#include "app_persistence.h"
#include "ai_commit_service.h"
#include "document_feature.h"
#include "git_feature.h"
#include "history_feature.h"
#include "java_debug_service.h"
#include "java_language_server.h"
#include "java_run_service.h"
#include "maven_build_service.h"
#include "maven_java_feature.h"
#include "project_detection_service.h"
#include "project_runtime_service.h"
#include "replacement_feature.h"
#include "search_feature.h"
#include "shelf_feature.h"
#include "terminal_feature.h"
#include "workbench_layout_persistence.h"
#include "workspace_feature.h"
#include "workspace_write_lifecycle.h"
#include "win32_directory_watcher.h"
#include "win32_archive_entry_reader.h"
#include "win32_authenticode_verifier.h"
#include "win32_file_storage.h"
#include "win32_http_transport.h"
#include "win32_key_value_store.h"
#include "win32_process_runner.h"
#include "win32_process_session.h"
#include "win32_runtime_locator.h"
#include "win32_secure_store.h"
#include "win32_terminal_transport.h"
#include "windows_update_service.h"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace lithe::windows::winui {

struct JavaNavigationLocation {
    std::string displayPath;
    std::string relativePath;
    std::optional<std::filesystem::path> absolutePath;
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;
};

struct JavaNavigationResult {
    std::string title;
    std::vector<JavaNavigationLocation> locations;
    std::string error;
};

struct JavaDiagnosticItem {
    std::string severity;
    std::string message;
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;
};

struct JavaDiagnosticsResult {
    std::string relativePath;
    std::vector<JavaDiagnosticItem> items;
};

struct AICommitGenerationResult {
    std::string message;
    std::string error;
};

struct WindowsUpdateCheckResult {
    std::optional<app::WindowsRelease> release;
    std::optional<app::WindowsReleaseAsset> asset;
    std::string error;
    bool upToDate = false;
};

struct WindowsUpdateDownloadResult {
    std::filesystem::path destination;
    std::string error;
    bool succeeded = false;
};

struct ProjectInspection {
    app::ProjectDetectionResult detection;
    bool jdkReady = false;
    bool mavenReady = false;
    bool wrapperReady = false;
};

struct ProjectReplacementApplyResult {
    std::vector<ReplacementFileDto> appliedFiles;
    std::vector<std::string> changedSincePreview;
    std::vector<std::string> failedPaths;
};

struct MarkdownRenderResult {
    std::string html;
    std::string error;
};

struct WorkbenchCallbacks {
    std::function<void(app::WorkspaceFeatureState)> workspaceChanged;
    std::function<void(std::vector<DirectoryChangeSource::Change>)> filesChanged;
    std::function<void(app::DocumentFeatureState)> documentChanged;
    std::function<void(app::SearchFeatureState)> searchChanged;
    std::function<void(app::SearchEverywhereFeatureState)> searchEverywhereChanged;
    std::function<void(app::ReplacementFeatureState)> replacementChanged;
    std::function<void(ProjectReplacementApplyResult)> replacementApplied;
    std::function<void(MarkdownRenderResult)> markdownRendered;
    std::function<void(app::GitFeatureState)> gitChanged;
    std::function<void(app::GitPendingCheckout, std::vector<std::string>)> checkoutBlocked;
    std::function<void(app::GitPendingIntegration, std::vector<std::string>, bool)>
        integrationBlocked;
    std::function<void(app::HistoryFeatureState)> historyChanged;
    std::function<void(app::ShelfFeatureState)> shelfChanged;
    std::function<void(app::MavenJavaFeatureState)> analysisChanged;
    std::function<void(std::string)> terminalOutputChanged;
    std::function<void(app::TerminalFeatureState)> terminalsChanged;
    std::function<void(std::string)> buildOutput;
    std::function<void(app::JavaDebugSnapshot)> javaDebugChanged;
    std::function<void(bool, std::string)> languageServerChanged;
    std::function<void(JavaDiagnosticsResult)> javaDiagnosticsChanged;
    std::function<void(JavaNavigationResult)> javaNavigationChanged;
    std::function<void(AICommitGenerationResult)> aiCommitFinished;
    std::function<void(WindowsUpdateCheckResult)> updateCheckFinished;
    std::function<void(WindowsUpdateDownloadResult)> updateDownloadFinished;
    std::function<void(std::string)> statusChanged;
};

class WorkbenchSession final {
public:
    explicit WorkbenchSession(WorkbenchCallbacks callbacks);
    ~WorkbenchSession();

    WorkbenchSession(const WorkbenchSession&) = delete;
    WorkbenchSession& operator=(const WorkbenchSession&) = delete;

    void openWorkspace(std::filesystem::path root);
    void closeWorkspace();
    ProjectInspection inspectProject(const std::filesystem::path& root) const;
    void openMostRecentWorkspace();
    void refreshWorkspace();
    bool createWorkspaceItem(std::string parentRelativePath,
                             std::string name,
                             bool directory);
    using WorkspaceMutationHandler = std::function<void(bool, std::string)>;
    void renameWorkspaceItem(std::string relativePath,
                             std::string name,
                             WorkspaceMutationHandler handler = {});
    bool duplicateWorkspaceItem(std::string relativePath, std::string name);
    void deleteWorkspaceItem(std::string relativePath,
                             WorkspaceMutationHandler handler = {});
    std::optional<std::filesystem::path> absoluteWorkspacePath(
        std::string_view relativePath) const;
    void openDocument(std::string relativePath);
    void setDocumentText(std::string text);
    void markDocumentExternalConflict(std::string relativePath);
    void keepDocumentEditorVersion();
    void saveDocument();
    using DocumentSaveHandler = std::function<void(bool, std::string)>;
    void saveDocument(std::string relativePath,
                      std::string text,
                      DocumentSaveHandler handler);
    void restoreHistorySnapshot(std::string relativePath,
                                std::string snapshotText,
                                std::string currentText,
                                DocumentSaveHandler handler);
    std::optional<std::string> readExternalDocument(
        const std::filesystem::path& path, std::string& error) const;

    void search(std::string query);
    void searchEverywhere(std::string query);
    void previewProjectReplacement(ReplacementPreviewRequestDto request);
    void renderMarkdown(std::string source);
    void applyProjectReplacements(
        std::vector<ReplacementFileDto> files,
        std::unordered_map<std::string, std::string> openDocumentTexts);
    void refreshGit();
    void fetch();
    void push();
    void pull(std::string strategy = "ffOnly");
    void integrate(std::string reference, std::string operation);
    void autoStashIntegration();
    void autoShelfIntegration();
    void cancelIntegrationConflict();
    void replayCommit(std::string revision, std::string operation);
    void resetToRevision(std::string revision, std::string mode);
    void resolveGitOperation(std::string action);
    void loadDiff(std::vector<std::string> paths, bool staged = false);
    void loadGitHistory();
    void loadGitCommit(std::string hash);
    void loadGitCommitDiff(std::string hash, std::string path);
    void loadGitComparison(std::string reference);
    void loadGitStashes();
    void loadGitBlame(std::string relativePath);
    void stage(std::vector<std::string> paths);
    void unstage(std::vector<std::string> paths);
    void discard(std::vector<std::string> paths);
    void rollbackConflictPath(std::string path,
                              WorkspaceMutationHandler handler = {});
    void stageAll();
    void commit(std::string message, bool amend);
    void commitAndPush(std::string message, bool amend);
    void checkout(std::string reference, std::string kind);
    void resolveCheckoutConflict(std::string strategy);
    void cancelCheckoutConflict();
    void createBranch(std::string name);
    void renameBranch(std::string reference, std::string name);
    void deleteBranch(std::string reference);
    void stash(std::string message, bool includeUntracked);
    void applyStash(std::string reference);
    void popStash(std::string reference);
    void dropStash(std::string reference);
    void applyHunk(std::string hunkID, std::string mode);
    void cloneRepository(std::string remote,
                         std::filesystem::path parentDirectory,
                         std::string folderName,
                         WorkspaceMutationHandler handler = {});
    void loadHistory(std::optional<std::string> relativePath = std::nullopt);
    void loadHistoryContent(std::string contentPath);
    void loadShelves();
    void createShelf(std::string label);
    void restoreShelf(std::string id);
    void deleteShelf(std::string id);
    void scanProject();
    void analyzeJavaDocument(std::string relativePath, std::string sourceText);

    std::string createTerminal();
    void selectTerminal(std::string id);
    void setTerminalShell(std::string id, std::string shellPath);
    void clearTerminal(std::string id);
    app::TerminalFeatureState terminalState() const;
    std::string terminalOutput(std::string_view id) const;
    std::vector<lithe::windows::algorithms::TerminalSpan> terminalOutputSpans(
        std::string_view id) const;
    void startTerminal(std::string id);
    void sendTerminal(std::string id, std::string input);
    void sendTerminalText(std::string id, std::string input);
    void interruptTerminal(std::string id);
    void resizeTerminal(std::string id, int columns, int rows);
    void stopTerminal(std::string id);
    void closeTerminal(std::string id);
    void runMaven(std::string phase);
    void stopBuild();

    void runCurrentJava(std::string relativePath);
    void runSpringBoot(std::string relativePath = {});
    void runJavaConfiguration(std::string configurationID,
                              std::string relativePath = {});
    void stopJava();

    void debugCurrentJava(std::string relativePath, std::string sourceText);
    void debugSpringBoot();
    void debugJavaConfiguration(std::string configurationID);
    void attachDebugger(std::string host, std::uint16_t port);
    void toggleBreakpoint(std::string relativePath,
                          std::string sourceText,
                          std::uint64_t zeroBasedLine);
    void continueDebugger();
    void pauseDebugger();
    void stepIntoDebugger();
    void stepOverDebugger();
    void stepOutDebugger();
    void inspectDebuggerThreads();
    void inspectDebuggerStack();
    void inspectDebuggerVariables();
    void evaluateDebugger(std::string expression);
    void toggleDebuggerVariable(std::string variableID);
    void stopDebugger();
    void pollDebugger();

    void activateJavaDocument(std::string relativePath, std::string text);
    void changeJavaDocument(std::string relativePath, std::string text);
    void closeJavaDocument();
    void goToJavaDefinition(std::string relativePath,
                            std::string text,
                            std::uint64_t line,
                            std::uint64_t utf16Column);
    void findJavaUsages(std::string relativePath,
                        std::string text,
                        std::uint64_t line,
                        std::uint64_t utf16Column);
    void findJavaImplementations(std::string relativePath,
                                 std::string text,
                                 std::uint64_t line,
                                 std::uint64_t utf16Column);

    app::AICommitSettings loadAICommitSettings() const;
    bool saveAICommitSettings(const app::AICommitSettings& settings,
                              std::string apiKey,
                              std::string& error);
    void generateAICommitMessage(app::AICommitSettings settings);
    void checkForUpdates(std::string architecture = "x64");
    void downloadUpdate(app::WindowsReleaseAsset asset,
                        std::filesystem::path destination);

    const std::filesystem::path& workspaceRoot() const;
    const app::AppSettings& settings() const;
    bool saveSettings(app::AppSettings settings);
    std::vector<std::string> recentProjects() const;
    bool removeRecentProject(std::string path);
    std::string coreVersion() const;
    app::WorkspaceSession loadWorkspaceSession() const;
    bool saveWorkspaceSession(const app::WorkspaceSession& state);
    WorkbenchLayoutState loadLayout(int availableWidth, int availableHeight) const;
    bool saveLayout(const WorkbenchLayoutState& state);
    app::GitFeatureState gitState() const;

private:
    struct ReplacementApplyState {
        std::vector<ReplacementFileDto> files;
        std::unordered_map<std::string, std::string> openDocumentTexts;
        ProjectReplacementApplyResult result;
        std::size_t index = 0;
        std::uint64_t workspaceEpoch = 0;
        app::WorkspaceWriteLifecycle::Token writeToken = 0;
    };
    struct HistoryRecordSequence {
        std::vector<std::string> paths;
        std::string reason;
        WorkspaceMutationHandler handler;
        std::size_t index = 0;
    };
    struct HistoryRelocateSequence {
        std::vector<std::pair<std::string, std::string>> paths;
        WorkspaceMutationHandler handler;
        std::size_t index = 0;
    };

    void applyNextProjectReplacement(std::shared_ptr<ReplacementApplyState> state);
    std::vector<std::string> workspaceFilesForHistory(
        const std::string& relativePath) const;
    void recordWorkspaceFiles(std::vector<std::string> relativePaths,
                              const char* reason,
                              WorkspaceMutationHandler handler);
    void recordNextWorkspaceFile(std::shared_ptr<HistoryRecordSequence> state);
    void relocateHistoryPaths(
        std::vector<std::pair<std::string, std::string>> paths,
        WorkspaceMutationHandler handler);
    void relocateNextHistoryPath(std::shared_ptr<HistoryRelocateSequence> state);
    void resetWorkspaceModels();
    void reportError(const std::optional<CoreError>& error, std::string fallback);
    void configureProcessCallbacks();
    void configureJavaCallbacks();
    void synchronizeJavaRunProject();
    void runJavaConfiguration(const JavaRunConfigurationDto& configuration,
                              std::string relativePath);
    std::optional<JavaRunConfigurationDto> javaConfiguration(
        std::string_view idOrKind) const;
    void ensureJavaLanguageServer(std::string_view relativePath);
    void synchronizeJavaLanguageDocument();
    void requestJavaNavigation(std::string method,
                               std::string title,
                               std::string relativePath,
                               std::string text,
                               std::uint64_t line,
                               std::uint64_t utf16Column);
    JavaNavigationResult parseJavaNavigation(
        std::string title,
        const std::optional<JsonValue>& result,
        const std::optional<app::LspRpcError>& error) const;
    JavaDiagnosticsResult parseJavaDiagnostics(
        const std::string& uri, const JsonValue& diagnostics) const;
    void refreshAfterWrite();
    app::WorkspaceWriteLifecycle::Token beginWorkspaceWrite(
        bool preserveDeferredChanges = true);
    void finishWorkspaceWrite(app::WorkspaceWriteLifecycle::Token token,
                              bool requestRefresh = true);
    void performGitWrite(
        GitWriteRequestDto request,
        std::function<void(app::GitFeatureState)> handler);
    bool persistDeferredShelf(std::optional<std::string> id);
    void restoreAutomaticShelf(std::string id,
                               std::function<void(bool)> handler = {});
    void resumeDeferredShelfIfReady(const app::GitFeatureState& state);
    void commitWithSafety(std::string message, bool amend, bool pushAfterCommit);
    void reportStatus(std::string message) const;
    std::string defaultTerminalShell() const;
    void publishTerminalState() const;
    static std::filesystem::path javaProjectRoot(
        const std::filesystem::path& workspace,
        std::string_view relativePath);
    static std::string fileURI(const std::filesystem::path& path);
    static std::optional<std::filesystem::path> pathFromFileURI(std::string_view uri);
    static bool stagedDiffContainsSensitiveFile(std::string_view patch);
    static bool validLeafName(std::string_view value);
    static std::string operationID(std::string_view prefix);

    WorkbenchCallbacks callbacks_;
    Win32KeyValueStore keyValueStore_;
    app::RecentProjectsStore recentProjectsStore_;
    app::WorkspaceSessionStore workspaceSessionStore_;
    app::AppSettingsStore settingsStore_;
    WorkbenchLayoutPersistence layoutPersistence_;
    app::AppSettings settings_;
    Win32RuntimeLocator runtimeLocator_;
    app::ProjectRuntimeService runtimeService_;
    Win32ProcessRunner processRunner_;
    Win32ProcessRunner archiveRunner_;
    Win32ArchiveEntryReader archiveReader_;
    app::MavenBuildService mavenBuildService_;
    std::unique_ptr<app::WorkbenchCoordinator> coordinator_;
    std::unique_ptr<Win32FileStorage> storage_;
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
    std::unique_ptr<app::ReplacementFeatureModel> replacementFeature_;
    std::unique_ptr<app::GitFeatureModel> gitFeature_;
    std::unique_ptr<app::HistoryFeatureModel> historyFeature_;
    std::unique_ptr<app::ShelfFeatureModel> shelfFeature_;
    std::unique_ptr<app::MavenJavaFeatureModel> mavenJavaFeature_;
    std::unique_ptr<app::TerminalFeatureModel> terminalFeature_;
    std::unique_ptr<app::WorkspaceWriteLifecycle> writeLifecycle_;
    std::optional<app::WorkspaceWriteLifecycle::Token> checkoutWriteToken_;
    std::optional<std::string> deferredShelfId_;
    bool deferredShelfRestoreBusy_ = false;
    std::unique_ptr<Win32DirectoryChangeSource> watcher_;
    std::unordered_map<std::string, std::unique_ptr<Win32TerminalTransport>> terminals_;
    std::unique_ptr<Win32ProcessSession> buildSession_;
    std::unique_ptr<Win32ProcessSession> javaSession_;
    std::unique_ptr<Win32ProcessSession> languageServerSession_;
    std::unique_ptr<app::JavaLanguageServerClient> languageServer_;
    std::filesystem::path workspaceRoot_;
    mutable std::mutex languageServerStateMutex_;
    std::filesystem::path languageServerRoot_;
    std::string languageServerPath_;
    std::string languageServerURI_;
    std::string languageServerText_;
    bool languageServerDocumentOpen_ = false;
    std::atomic_uint64_t workspaceEpoch_{0};
    std::atomic_bool aiGenerating_{false};
    std::atomic_bool updateBusy_{false};
    std::thread aiWorker_;
    std::thread updateWorker_;
};

}
