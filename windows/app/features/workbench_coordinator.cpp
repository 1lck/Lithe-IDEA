#include "workbench_coordinator.h"

#include "core_requests.h"

#include <algorithm>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace lithe::windows::app {
namespace {

constexpr std::uint64_t WorkspaceTimeoutMilliseconds = 30000;
constexpr std::uint64_t InteractiveTimeoutMilliseconds = 5000;

bool isRegexMeta(char value) {
    return value == '\\' || value == '^' || value == '$' || value == '.' ||
        value == '*' || value == '+' || value == '?' || value == '(' ||
        value == ')' || value == '[' || value == ']' || value == '{' ||
        value == '}' || value == '|';
}

std::string fuzzyRegex(std::string_view query) {
    std::string result = ".*";
    for (std::size_t index = 0; index < query.size();) {
        const auto first = static_cast<unsigned char>(query[index]);
        std::size_t length = 1;
        if (first >= 0xc2 && first <= 0xdf) length = 2;
        else if (first >= 0xe0 && first <= 0xef) length = 3;
        else if (first >= 0xf0 && first <= 0xf4) length = 4;
        if (index + length > query.size()) length = 1;
        const auto codePoint = query.substr(index, length);
        if (length == 1 && isRegexMeta(codePoint.front())) result.push_back('\\');
        result.append(codePoint);
        result += ".*";
        index += length;
    }
    return result;
}

WorkspaceOperationResult coordinatorFailure(CoreError error) {
    return WorkspaceOperationResult{
        CoreResponse{}, std::unexpected(std::move(error)), 0, false};
}

} // namespace

WorkbenchCoordinator::WorkbenchCoordinator(std::size_t workerCount)
    : workers_(workerCount) {}

WorkbenchCoordinator::~WorkbenchCoordinator() {
    shutdown();
}

std::string WorkbenchCoordinator::pathUtf8(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return std::string(reinterpret_cast<const char*>(value.data()), value.size());
}

std::optional<std::string> WorkbenchCoordinator::workspaceRootUtf8() const {
    std::lock_guard lock(stateMutex_);
    if (!workspacePaths_) return std::nullopt;
    return pathUtf8(workspacePaths_->root());
}

void WorkbenchCoordinator::openWorkspace(std::filesystem::path root,
                                         ResponseHandler handler) {
    WorkspacePaths paths(std::move(root));
    const auto rootValue = pathUtf8(paths.root());
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
    {
        std::lock_guard lock(stateMutex_);
        workspacePaths_ = std::move(paths);
        hiddenDirectoryNames = hiddenDirectoryNames_;
        hiddenFilePatterns = hiddenFilePatterns_;
        workspaceEpoch = ++workspaceEpoch_;
        generation = ++workspaceGeneration_;
        ++documentGeneration_;
        ++searchGeneration_;
        ++searchEverywhereGeneration_;
        ++replacementGeneration_;
        ++gitStatusGeneration_;
        ++gitCheckoutPreflightGeneration_;
        ++gitConflictMarkersGeneration_;
        ++gitIntegrationPreflightGeneration_;
        ++gitPullPreflightGeneration_;
        ++gitOperationStateGeneration_;
        ++gitDiffGeneration_;
        ++gitShelfPatchesGeneration_;
        ++gitApplyGeneration_;
        ++gitWriteGeneration_;
        ++gitCommandGeneration_;
        ++gitHistoryGeneration_;
        ++gitCommitGeneration_;
        ++gitCommitFilesGeneration_;
        ++gitComparisonGeneration_;
        ++gitStashesGeneration_;
        ++gitCheckoutPreflightGeneration_;
        ++gitPullPreflightGeneration_;
        ++gitIntegrationPreflightGeneration_;
        ++gitConflictMarkersGeneration_;
        ++gitOperationStateGeneration_;
        ++gitBlameGeneration_;
        ++historyRecordGeneration_;
        ++historyEntriesGeneration_;
        ++historyContentGeneration_;
        ++historyRelocateGeneration_;
        ++shelfCreateGeneration_;
        ++shelfListGeneration_;
        ++shelfRestoreGeneration_;
        ++shelfDeleteGeneration_;
        ++mavenScanGeneration_;
        ++mavenDiagnosticsGeneration_;
        ++javaRunConfigurationsGeneration_;
        ++javaCodeVisionGeneration_;
        ++javaClassNameGeneration_;
        ++javaSourceDefinitionGeneration_;
        ++javaServerPortGeneration_;
        ++javaStructureGeneration_;
        loading_ = true;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("workspace.snapshot",
            encodeWorkspaceSnapshotRequest(WorkspaceSnapshotRequestDto{
                rootValue, std::move(hiddenDirectoryNames), std::move(hiddenFilePatterns)}),
            OperationDomain::Workspace, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::refreshWorkspace(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        hiddenDirectoryNames = hiddenDirectoryNames_;
        hiddenFilePatterns = hiddenFilePatterns_;
        generation = ++workspaceGeneration_;
        loading_ = true;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("workspace.snapshot",
            encodeWorkspaceSnapshotRequest(WorkspaceSnapshotRequestDto{
                *root, std::move(hiddenDirectoryNames), std::move(hiddenFilePatterns)}),
            OperationDomain::Workspace,
            workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::setWorkspaceVisibility(
    std::vector<std::string> hiddenDirectoryNames,
    std::vector<std::string> hiddenFilePatterns) {
    std::lock_guard lock(stateMutex_);
    hiddenDirectoryNames_ = std::move(hiddenDirectoryNames);
    hiddenFilePatterns_ = std::move(hiddenFilePatterns);
}

void WorkbenchCoordinator::readFile(std::string relativePath, ResponseHandler handler) {
    bool missingWorkspace = false;
    bool invalidPath = false;
    try {
        {
            std::lock_guard lock(stateMutex_);
            if (!workspacePaths_) {
                missingWorkspace = true;
            } else {
                (void)workspacePaths_->toAbsolute(relativePath);
            }
        }
    } catch (const std::invalid_argument&) {
        invalidPath = true;
    }
    if (missingWorkspace) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    if (invalidPath) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::InvalidRequest, "Invalid workspace path")));
        return;
    }
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++documentGeneration_;
        loading_ = false;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("file.read", encodeFileReadRequest(FileReadRequestDto{*root, relativePath}),
            OperationDomain::Document,
            workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::search(std::string query, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++searchGeneration_;
        hiddenDirectoryNames = hiddenDirectoryNames_;
        hiddenFilePatterns = hiddenFilePatterns_;
        loading_ = false;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    SearchRequestDto request;
    request.root = *root;
    request.query = std::move(query);
    request.hiddenDirectoryNames = std::move(hiddenDirectoryNames);
    request.hiddenFilePatterns = std::move(hiddenFilePatterns);
    execute("workspace.search", encodeSearchRequest(request), OperationDomain::Search,
            workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::searchEverywhere(std::string query, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++searchEverywhereGeneration_;
        hiddenDirectoryNames = hiddenDirectoryNames_;
        hiddenFilePatterns = hiddenFilePatterns_;
        loading_ = false;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    SearchRequestDto request;
    request.root = *root;
    request.query = fuzzyRegex(query);
    request.regularExpression = true;
    request.hiddenDirectoryNames = std::move(hiddenDirectoryNames);
    request.hiddenFilePatterns = std::move(hiddenFilePatterns);
    request.maxSymbolResults = 50;
    execute("workspace.searchEverywhere", encodeSearchRequest(request),
            OperationDomain::SearchEverywhere, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::replacementPreview(ReplacementPreviewRequestDto request,
                                              ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++replacementGeneration_;
        request.hiddenDirectoryNames.insert(request.hiddenDirectoryNames.end(),
                                            hiddenDirectoryNames_.begin(),
                                            hiddenDirectoryNames_.end());
        request.hiddenFilePatterns.insert(request.hiddenFilePatterns.end(),
                                          hiddenFilePatterns_.begin(),
                                          hiddenFilePatterns_.end());
        request.root = *root;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("workspace.replacePreview", encodeReplacementPreviewRequest(request),
            OperationDomain::Replacement, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::writeFile(std::string relativePath,
                                     std::string text,
                                     ResponseHandler handler) {
    FileWriteRequestDto request;
    request.path = std::move(relativePath);
    request.text = std::move(text);
    writeFile(std::move(request), std::move(handler));
}

void WorkbenchCoordinator::writeFile(FileWriteRequestDto request,
                                     ResponseHandler handler) {
    bool missingWorkspace = false;
    bool invalidPath = false;
    try {
        std::lock_guard lock(stateMutex_);
        if (!workspacePaths_) missingWorkspace = true;
        else (void)workspacePaths_->toAbsolute(request.path);
    } catch (const std::invalid_argument&) {
        invalidPath = true;
    }
    if (missingWorkspace) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    if (invalidPath) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::InvalidRequest, "Invalid workspace path")));
        return;
    }
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++documentGeneration_;
        request.root = *root;
        loading_ = false;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("file.write", encodeFileWriteRequest(request),
            OperationDomain::Document,
            workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitStatus(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitStatusGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.status", encodeGitStatusRequest(GitStatusRequestDto{*root}),
            OperationDomain::GitStatus, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitCheckoutPreflight(std::string reference, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitCheckoutPreflightGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.checkoutPreflight",
            encodeGitCheckoutPreflightRequest(
                GitCheckoutPreflightRequestDto{*root, std::move(reference)}),
            OperationDomain::GitCheckoutPreflight, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::gitConflictMarkers(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitConflictMarkersGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.conflictMarkers",
            encodeGitConflictMarkersRequest(GitConflictMarkersRequestDto{*root}),
            OperationDomain::GitConflictMarkers, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::gitIntegrationPreflight(std::string reference,
                                                   std::string operation,
                                                   ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitIntegrationPreflightGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.integrationPreflight",
            encodeGitIntegrationPreflightRequest(GitIntegrationPreflightRequestDto{
                *root, std::move(reference), std::move(operation)}),
            OperationDomain::GitIntegrationPreflight, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::gitPullPreflight(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitPullPreflightGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.pullPreflight",
            encodeGitPullPreflightRequest(GitPullPreflightRequestDto{*root}),
            OperationDomain::GitPullPreflight, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::gitOperationState(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitOperationStateGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.operationState",
            encodeGitOperationStateRequest(GitOperationStateRequestDto{*root}),
            OperationDomain::GitOperationState, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::gitDiff(std::vector<std::string> pathspecs,
                                   bool staged,
                                   bool untracked,
                                   ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitDiffGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.diff", encodeGitDiffRequest(GitDiffRequestDto{
                *root, std::move(pathspecs), std::nullopt, std::nullopt,
                staged, untracked, 80, false}),
            OperationDomain::GitDiff, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitShelfPatches(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitShelfPatchesGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.shelfPatches", encodeGitShelfPatchesRequest(
                GitShelfPatchesRequestDto{*root}),
            OperationDomain::GitShelfPatches, workspaceEpoch, generation, call,
            std::move(handler));
}

void WorkbenchCoordinator::gitCommitDiff(std::string commit,
                                         std::vector<std::string> pathspecs,
                                         ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitDiffGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.diff", encodeGitDiffRequest(GitDiffRequestDto{
                *root, std::move(pathspecs), std::nullopt, std::move(commit),
                false, false, 80, false}),
            OperationDomain::GitDiff, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitApply(std::string patch,
                                    std::string mode,
                                    ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitApplyGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.apply", encodeGitApplyRequest(GitApplyRequestDto{
                *root, std::move(patch), std::move(mode)}),
            OperationDomain::GitApply, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitWrite(GitWriteRequestDto request, ResponseHandler handler) {
    const auto root = request.root.empty()
        ? workspaceRootUtf8()
        : std::optional<std::string>(request.root);
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitWriteGeneration_;
        if (request.root.empty()) request.root = *root;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.write", encodeGitWriteRequest(request),
            OperationDomain::GitWrite, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitCommand(GitCommandRequestDto request, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitCommandGeneration_;
        request.root = *root;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.command", encodeGitCommandRequest(request),
            OperationDomain::GitCommand, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitHistory(std::optional<std::string> reference,
                                      std::uint64_t limit,
                                      ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitHistoryGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.history", encodeGitHistoryRequest(
                GitHistoryRequestDto{*root, std::move(reference), limit}),
            OperationDomain::GitHistory, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitCommit(std::string commit, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitCommitGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.commit", encodeGitCommitRequest(GitCommitRequestDto{*root, std::move(commit)}),
            OperationDomain::GitCommit, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitCommitFiles(std::string commit, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitCommitFilesGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.commitFiles",
            encodeGitCommitFilesRequest(GitCommitFilesRequestDto{*root, std::move(commit)}),
            OperationDomain::GitCommitFiles, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitComparison(std::string reference, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitComparisonGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.comparison",
            encodeGitComparisonRequest(GitComparisonRequestDto{*root, std::move(reference)}),
            OperationDomain::GitComparison, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitStashes(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitStashesGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.stashes", encodeGitStashesRequest(GitStashesRequestDto{*root}),
            OperationDomain::GitStashes, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::gitBlame(std::string relativePath, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++gitBlameGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("git.blame", encodeGitBlameRequest(GitBlameRequestDto{*root, std::move(relativePath)}),
            OperationDomain::GitBlame, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::historyRecord(
    std::string storageRoot,
    std::string path,
    std::string reason,
    std::optional<std::string> content,
    bool pruneExpired,
    std::vector<std::string> hiddenDirectoryNames,
    std::vector<std::string> hiddenFilePatterns,
    ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++historyRecordGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("history.record", encodeHistoryRecordRequest(HistoryRecordRequestDto{
                *root, std::move(storageRoot), std::move(path), std::move(reason),
                std::move(content), pruneExpired, std::move(hiddenDirectoryNames),
                std::move(hiddenFilePatterns)}),
            OperationDomain::HistoryRecord, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::historyEntries(
    std::string storageRoot,
    std::optional<std::string> path,
    std::vector<std::string> hiddenDirectoryNames,
    std::vector<std::string> hiddenFilePatterns,
    ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++historyEntriesGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("history.entries", encodeHistoryEntriesRequest(HistoryEntriesRequestDto{
                *root, std::move(storageRoot), std::move(path),
                std::move(hiddenDirectoryNames), std::move(hiddenFilePatterns)}),
            OperationDomain::HistoryEntries, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::historyContent(std::string storageRoot,
                                          std::string contentPath,
                                          ResponseHandler handler) {
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++historyContentGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("history.content", encodeHistoryContentRequest(HistoryContentRequestDto{
                std::move(storageRoot), std::move(contentPath)}),
            OperationDomain::HistoryContent, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::historyRelocate(std::string storageRoot,
                                           std::string sourcePath,
                                           std::string destinationPath,
                                           ResponseHandler handler) {
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++historyRelocateGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("history.relocate", encodeHistoryRelocateRequest(HistoryRelocateRequestDto{
                std::move(storageRoot), std::move(sourcePath), std::move(destinationPath)}),
            OperationDomain::HistoryRelocate, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::shelfCreate(std::string storageRoot,
                                       std::string label,
                                       std::string stagedPatch,
                                       std::string workingTreePatch,
                                       ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++shelfCreateGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("shelf.create",
            encodeShelfCreateRequest(ShelfCreateRequestDto{
                *root, std::move(storageRoot), std::move(label),
                std::move(stagedPatch), std::move(workingTreePatch)}),
            OperationDomain::ShelfCreate, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::shelfList(std::string storageRoot, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++shelfListGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("shelf.list",
            encodeShelfListRequest(ShelfListRequestDto{*root, std::move(storageRoot)}),
            OperationDomain::ShelfList, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::shelfRestore(std::string storageRoot,
                                        std::string id,
                                        ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++shelfRestoreGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("shelf.restore",
            encodeShelfRestoreRequest(ShelfRestoreRequestDto{
                *root, std::move(storageRoot), std::move(id)}),
            OperationDomain::ShelfRestore, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::shelfDelete(std::string storageRoot,
                                       std::string id,
                                       ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++shelfDeleteGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("shelf.delete",
            encodeShelfDeleteRequest(ShelfDeleteRequestDto{
                *root, std::move(storageRoot), std::move(id)}),
            OperationDomain::ShelfDelete, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::mavenScan(ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++mavenScanGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("maven.scan", encodeMavenScanRequest(MavenScanRequestDto{*root}),
            OperationDomain::MavenScan, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::mavenDiagnostics(std::string output, ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++mavenDiagnosticsGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("maven.diagnostics", encodeMavenDiagnosticsRequest(
                MavenDiagnosticsRequestDto{*root, std::move(output)}),
            OperationDomain::MavenDiagnostics, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::javaRunConfigurations(std::vector<std::string> paths,
                                                 std::vector<std::string> modulePaths,
                                                 ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++javaRunConfigurationsGeneration_;
        call = workers_.makeCall(WorkspaceTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("java.runConfigurations", encodeJavaRunConfigurationsRequest(
                JavaRunConfigurationsRequestDto{*root, std::move(paths), std::move(modulePaths)}),
            OperationDomain::JavaRunConfigurations, workspaceEpoch, generation,
            call, std::move(handler));
}

void WorkbenchCoordinator::javaCodeVision(std::string targetPath,
                                          std::vector<std::string> paths,
                                          ResponseHandler handler) {
    const auto root = workspaceRootUtf8();
    if (!root) {
        if (handler) handler(coordinatorFailure(makeCoreError(
            CoreErrorCode::WorkspaceNotFound, "No workspace is open")));
        return;
    }
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++javaCodeVisionGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("java.codeVision", encodeJavaCodeVisionRequest(
                JavaCodeVisionRequestDto{*root, std::move(targetPath), std::move(paths)}),
            OperationDomain::JavaCodeVision, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::javaClassName(std::string source,
                                         std::string simpleName,
                                         ResponseHandler handler) {
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++javaClassNameGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("java.className", encodeJavaClassNameRequest(
                JavaClassNameRequestDto{std::move(source), std::move(simpleName)}),
            OperationDomain::JavaClassName, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::javaSourceDefinition(std::string source,
                                                std::string declarationName,
                                                std::optional<std::string> memberName,
                                                ResponseHandler handler) {
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++javaSourceDefinitionGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("java.sourceDefinition", encodeJavaSourceDefinitionRequest(
                JavaSourceDefinitionRequestDto{
                    std::move(source), std::move(declarationName), std::move(memberName)}),
            OperationDomain::JavaSourceDefinition, workspaceEpoch, generation,
            call, std::move(handler));
}

void WorkbenchCoordinator::javaServerPort(std::string content,
                                          std::string fileExtension,
                                          ResponseHandler handler) {
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++javaServerPortGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("java.serverPort", encodeJavaServerPortRequest(
                JavaServerPortRequestDto{std::move(content), std::move(fileExtension)}),
            OperationDomain::JavaServerPort, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::javaStructure(std::string source,
                                         std::vector<std::string> declarationSources,
                                         ResponseHandler handler) {
    CoreCall call;
    std::uint64_t workspaceEpoch;
    std::uint64_t generation;
    {
        std::lock_guard lock(stateMutex_);
        workspaceEpoch = workspaceEpoch_;
        generation = ++javaStructureGeneration_;
        call = workers_.makeCall(InteractiveTimeoutMilliseconds);
        currentCall_ = call;
    }
    execute("java.structure", encodeJavaStructureRequest(
                JavaStructureRequestDto{std::move(source), std::move(declarationSources)}),
            OperationDomain::JavaStructure, workspaceEpoch, generation, call, std::move(handler));
}

void WorkbenchCoordinator::execute(std::string command,
                                   std::string payload,
                                   OperationDomain domain,
                                   std::uint64_t workspaceEpoch,
                                   std::uint64_t generation,
                                   CoreCall call,
                                   ResponseHandler handler) {
    try {
        workers_.submit(call, std::move(command), std::move(payload),
                        [this, domain, workspaceEpoch, generation, call,
                         handler](CoreResult<CoreResponse> response) mutable {
                            complete(domain, workspaceEpoch, generation, call,
                                     std::move(response), std::move(handler));
                        });
    } catch (const std::exception& error) {
        complete(domain, workspaceEpoch, generation, call,
                 std::unexpected(makeCoreError(CoreErrorCode::Unknown, error.what())),
                 std::move(handler));
    }
}

void WorkbenchCoordinator::complete(OperationDomain domain,
                                    std::uint64_t workspaceEpoch,
                                    std::uint64_t generation,
                                    const CoreCall& call,
                                    CoreResult<CoreResponse> response,
                                    ResponseHandler handler) {
    bool stale = false;
    {
        std::lock_guard lock(stateMutex_);
        const auto currentGeneration = [this, domain] {
            switch (domain) {
            case OperationDomain::Workspace: return workspaceGeneration_;
            case OperationDomain::Document: return documentGeneration_;
            case OperationDomain::Search: return searchGeneration_;
            case OperationDomain::SearchEverywhere: return searchEverywhereGeneration_;
            case OperationDomain::Replacement: return replacementGeneration_;
            case OperationDomain::GitStatus: return gitStatusGeneration_;
            case OperationDomain::GitCheckoutPreflight: return gitCheckoutPreflightGeneration_;
            case OperationDomain::GitConflictMarkers: return gitConflictMarkersGeneration_;
            case OperationDomain::GitIntegrationPreflight: return gitIntegrationPreflightGeneration_;
            case OperationDomain::GitPullPreflight: return gitPullPreflightGeneration_;
            case OperationDomain::GitOperationState: return gitOperationStateGeneration_;
            case OperationDomain::GitDiff: return gitDiffGeneration_;
            case OperationDomain::GitShelfPatches: return gitShelfPatchesGeneration_;
            case OperationDomain::GitApply: return gitApplyGeneration_;
            case OperationDomain::GitWrite: return gitWriteGeneration_;
            case OperationDomain::GitCommand: return gitCommandGeneration_;
            case OperationDomain::GitHistory: return gitHistoryGeneration_;
            case OperationDomain::GitCommit: return gitCommitGeneration_;
            case OperationDomain::GitCommitFiles: return gitCommitFilesGeneration_;
            case OperationDomain::GitComparison: return gitComparisonGeneration_;
            case OperationDomain::GitStashes: return gitStashesGeneration_;
            case OperationDomain::GitBlame: return gitBlameGeneration_;
            case OperationDomain::HistoryRecord: return historyRecordGeneration_;
            case OperationDomain::HistoryEntries: return historyEntriesGeneration_;
            case OperationDomain::HistoryContent: return historyContentGeneration_;
            case OperationDomain::HistoryRelocate: return historyRelocateGeneration_;
            case OperationDomain::ShelfCreate: return shelfCreateGeneration_;
            case OperationDomain::ShelfList: return shelfListGeneration_;
            case OperationDomain::ShelfRestore: return shelfRestoreGeneration_;
            case OperationDomain::ShelfDelete: return shelfDeleteGeneration_;
            case OperationDomain::MavenScan: return mavenScanGeneration_;
            case OperationDomain::MavenDiagnostics: return mavenDiagnosticsGeneration_;
            case OperationDomain::JavaRunConfigurations: return javaRunConfigurationsGeneration_;
            case OperationDomain::JavaCodeVision: return javaCodeVisionGeneration_;
            case OperationDomain::JavaClassName: return javaClassNameGeneration_;
            case OperationDomain::JavaSourceDefinition: return javaSourceDefinitionGeneration_;
            case OperationDomain::JavaServerPort: return javaServerPortGeneration_;
            case OperationDomain::JavaStructure: return javaStructureGeneration_;
            }
            return std::uint64_t{};
        }();
        stale = workspaceEpoch != workspaceEpoch_ ||
            (domain != OperationDomain::Document && generation != currentGeneration);
        if (!stale) {
            if (domain == OperationDomain::Workspace) loading_ = false;
            if (currentCall_ && currentCall_->operationID == call.operationID) currentCall_.reset();
        }
    }
    CoreResponse rawResponse;
    CoreResult<CoreEnvelope> envelope = std::unexpected(makeCoreError(
        CoreErrorCode::Unknown, "No Core response was produced"));
    if (response) {
        rawResponse = std::move(*response);
        envelope = decodeCoreEnvelope(rawResponse);
    } else {
        envelope = std::unexpected(response.error());
    }
    if (handler) {
        handler({std::move(rawResponse), std::move(envelope), generation, stale});
    }
}

void WorkbenchCoordinator::cancelCurrentOperation() {
    std::optional<CoreCall> call;
    {
        std::lock_guard lock(stateMutex_);
        call = currentCall_;
    }
    if (call) workers_.cancel(*call);
}

void WorkbenchCoordinator::shutdown() {
    workers_.shutdown();
}

std::optional<WorkspacePaths> WorkbenchCoordinator::workspacePaths() const {
    std::lock_guard lock(stateMutex_);
    return workspacePaths_;
}

bool WorkbenchCoordinator::isLoading() const {
    std::lock_guard lock(stateMutex_);
    return loading_;
}

std::string WorkbenchCoordinator::coreVersion() const {
    return workers_.version();
}

} // namespace lithe::windows::app
