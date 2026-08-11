#pragma once

#include "core_dto.h"
#include "core_requests.h"
#include "core_worker_pool.h"
#include "workspace_paths.h"

#include <cstdint>
#include <filesystem>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct WorkspaceOperationResult {
    CoreResponse response;
    CoreResult<CoreEnvelope> envelope = std::unexpected(makeCoreError(
        CoreErrorCode::Unknown, "No Core response was produced"));
    std::uint64_t generation = 0;
    bool stale = false;

    std::optional<CoreError> coreError() const {
        if (!envelope) return envelope.error();
        if (envelope->hasError) return envelope->error;
        return std::nullopt;
    }
};

class WorkbenchCoordinator final {
public:
    using ResponseHandler = std::function<void(WorkspaceOperationResult)>;

    explicit WorkbenchCoordinator(std::size_t workerCount = 4);
    ~WorkbenchCoordinator();

    WorkbenchCoordinator(const WorkbenchCoordinator&) = delete;
    WorkbenchCoordinator& operator=(const WorkbenchCoordinator&) = delete;

    void openWorkspace(std::filesystem::path root, ResponseHandler handler);
    void refreshWorkspace(ResponseHandler handler);
    void setWorkspaceVisibility(std::vector<std::string> hiddenDirectoryNames,
                                std::vector<std::string> hiddenFilePatterns);
    void readFile(std::string relativePath, ResponseHandler handler);
    void search(std::string query, ResponseHandler handler);
    void searchEverywhere(std::string query, ResponseHandler handler);
    void replacementPreview(ReplacementPreviewRequestDto request, ResponseHandler handler);
    void writeFile(std::string relativePath, std::string text, ResponseHandler handler);
    void gitStatus(ResponseHandler handler);
    void gitCheckoutPreflight(std::string reference, ResponseHandler handler);
    void gitConflictMarkers(ResponseHandler handler);
    void gitIntegrationPreflight(std::string reference,
                                 std::string operation,
                                 ResponseHandler handler);
    void gitPullPreflight(ResponseHandler handler);
    void gitOperationState(ResponseHandler handler);
    void gitDiff(std::vector<std::string> pathspecs,
                 bool staged,
                 bool untracked,
                 ResponseHandler handler);
    void gitShelfPatches(ResponseHandler handler);
    void gitCommitDiff(std::string commit,
                       std::vector<std::string> pathspecs,
                       ResponseHandler handler);
    void gitApply(std::string patch, std::string mode, ResponseHandler handler);
    void gitWrite(GitWriteRequestDto request, ResponseHandler handler);
    void gitCommand(GitCommandRequestDto request, ResponseHandler handler);
    void gitHistory(std::optional<std::string> reference,
                    std::uint64_t limit,
                    ResponseHandler handler);
    void gitCommit(std::string commit, ResponseHandler handler);
    void gitCommitFiles(std::string commit, ResponseHandler handler);
    void gitComparison(std::string reference, ResponseHandler handler);
    void gitStashes(ResponseHandler handler);
    void gitBlame(std::string relativePath, ResponseHandler handler);
    void historyRecord(std::string storageRoot,
                       std::string path,
                       std::string reason,
                       std::optional<std::string> content,
                       bool pruneExpired,
                       std::vector<std::string> hiddenDirectoryNames,
                       std::vector<std::string> hiddenFilePatterns,
                       ResponseHandler handler);
    void historyEntries(std::string storageRoot,
                        std::optional<std::string> path,
                        std::vector<std::string> hiddenDirectoryNames,
                        std::vector<std::string> hiddenFilePatterns,
                        ResponseHandler handler);
    void historyContent(std::string storageRoot,
                        std::string contentPath,
                        ResponseHandler handler);
    void historyRelocate(std::string storageRoot,
                         std::string sourcePath,
                         std::string destinationPath,
                         ResponseHandler handler);
    void shelfCreate(std::string storageRoot,
                     std::string label,
                     std::string stagedPatch,
                     std::string workingTreePatch,
                     ResponseHandler handler);
    void shelfList(std::string storageRoot, ResponseHandler handler);
    void shelfRestore(std::string storageRoot, std::string id, ResponseHandler handler);
    void shelfDelete(std::string storageRoot, std::string id, ResponseHandler handler);
    void mavenScan(ResponseHandler handler);
    void mavenDiagnostics(std::string output, ResponseHandler handler);
    void javaRunConfigurations(std::vector<std::string> paths,
                               std::vector<std::string> modulePaths,
                               ResponseHandler handler);
    void javaCodeVision(std::string targetPath,
                        std::vector<std::string> paths,
                        ResponseHandler handler);
    void javaClassName(std::string source,
                       std::string simpleName,
                       ResponseHandler handler);
    void javaSourceDefinition(std::string source,
                              std::string declarationName,
                              std::optional<std::string> memberName,
                              ResponseHandler handler);
    void javaServerPort(std::string content,
                        std::string fileExtension,
                        ResponseHandler handler);
    void javaStructure(std::string source,
                       std::vector<std::string> declarationSources,
                       ResponseHandler handler);

    void cancelCurrentOperation();
    void shutdown();

    std::optional<WorkspacePaths> workspacePaths() const;
    bool isLoading() const;
    std::string coreVersion() const;

private:
    enum class OperationDomain {
        Workspace,
        Document,
        Search,
        SearchEverywhere,
        Replacement,
        GitStatus,
        GitCheckoutPreflight,
        GitConflictMarkers,
        GitIntegrationPreflight,
        GitPullPreflight,
        GitOperationState,
        GitDiff,
        GitShelfPatches,
        GitApply,
        GitWrite,
        GitCommand,
        GitHistory,
        GitCommit,
        GitCommitFiles,
        GitComparison,
        GitStashes,
        GitBlame,
        HistoryRecord,
        HistoryEntries,
        HistoryContent,
        HistoryRelocate,
        ShelfCreate,
        ShelfList,
        ShelfRestore,
        ShelfDelete,
        MavenScan,
        MavenDiagnostics,
        JavaRunConfigurations,
        JavaCodeVision,
        JavaClassName,
        JavaSourceDefinition,
        JavaServerPort,
        JavaStructure,
    };

    mutable std::mutex stateMutex_;
    CoreWorkerPool workers_;
    std::optional<WorkspacePaths> workspacePaths_;
    std::vector<std::string> hiddenDirectoryNames_;
    std::vector<std::string> hiddenFilePatterns_;
    std::optional<CoreCall> currentCall_;
    std::uint64_t workspaceEpoch_ = 0;
    std::uint64_t workspaceGeneration_ = 0;
    std::uint64_t documentGeneration_ = 0;
    std::uint64_t searchGeneration_ = 0;
    std::uint64_t searchEverywhereGeneration_ = 0;
    std::uint64_t replacementGeneration_ = 0;
    std::uint64_t gitStatusGeneration_ = 0;
    std::uint64_t gitCheckoutPreflightGeneration_ = 0;
    std::uint64_t gitConflictMarkersGeneration_ = 0;
    std::uint64_t gitIntegrationPreflightGeneration_ = 0;
    std::uint64_t gitPullPreflightGeneration_ = 0;
    std::uint64_t gitOperationStateGeneration_ = 0;
    std::uint64_t gitDiffGeneration_ = 0;
    std::uint64_t gitShelfPatchesGeneration_ = 0;
    std::uint64_t gitApplyGeneration_ = 0;
    std::uint64_t gitWriteGeneration_ = 0;
    std::uint64_t gitCommandGeneration_ = 0;
    std::uint64_t gitHistoryGeneration_ = 0;
    std::uint64_t gitCommitGeneration_ = 0;
    std::uint64_t gitCommitFilesGeneration_ = 0;
    std::uint64_t gitComparisonGeneration_ = 0;
    std::uint64_t gitStashesGeneration_ = 0;
    std::uint64_t gitBlameGeneration_ = 0;
    std::uint64_t historyRecordGeneration_ = 0;
    std::uint64_t historyEntriesGeneration_ = 0;
    std::uint64_t historyContentGeneration_ = 0;
    std::uint64_t historyRelocateGeneration_ = 0;
    std::uint64_t shelfCreateGeneration_ = 0;
    std::uint64_t shelfListGeneration_ = 0;
    std::uint64_t shelfRestoreGeneration_ = 0;
    std::uint64_t shelfDeleteGeneration_ = 0;
    std::uint64_t mavenScanGeneration_ = 0;
    std::uint64_t mavenDiagnosticsGeneration_ = 0;
    std::uint64_t javaRunConfigurationsGeneration_ = 0;
    std::uint64_t javaCodeVisionGeneration_ = 0;
    std::uint64_t javaClassNameGeneration_ = 0;
    std::uint64_t javaSourceDefinitionGeneration_ = 0;
    std::uint64_t javaServerPortGeneration_ = 0;
    std::uint64_t javaStructureGeneration_ = 0;
    bool loading_ = false;

    static std::string pathUtf8(const std::filesystem::path& path);
    std::optional<std::string> workspaceRootUtf8() const;
    void execute(std::string command,
                 std::string payload,
                 OperationDomain domain,
                 std::uint64_t workspaceEpoch,
                 std::uint64_t generation,
                 CoreCall call,
                 ResponseHandler handler);
    void complete(OperationDomain domain,
                  std::uint64_t workspaceEpoch,
                  std::uint64_t generation,
                  const CoreCall& call,
                  CoreResult<CoreResponse> response,
                  ResponseHandler handler);
};

} // namespace lithe::windows::app
