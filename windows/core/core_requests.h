#pragma once

#include "json_value.h"

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows {

struct WorkspaceSnapshotRequestDto {
    std::string root;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
};

struct SearchRequestDto {
    std::string root;
    std::string query;
    bool caseSensitive = false;
    bool wholeWords = false;
    bool regularExpression = false;
    std::uint64_t maxResults = 200;
    std::optional<std::uint64_t> maxFileResults;
    std::optional<std::uint64_t> maxContentResults;
    std::optional<std::uint64_t> maxSymbolResults;
    std::string fileMask;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
};

struct ReplacementPreviewRequestDto {
    std::string root;
    std::string query;
    std::string replacement;
    bool caseSensitive = false;
    bool wholeWords = false;
    bool regularExpression = false;
    bool preserveCase = false;
    std::string fileMask;
    std::vector<std::string> paths;
    std::map<std::string, std::string> textOverrides;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
};

struct FileReadRequestDto {
    std::string root;
    std::string path;
};

struct FileWriteRequestDto {
    std::string root;
    std::string path;
    std::string text;
};

struct HistoryRecordRequestDto {
    std::string workspaceRoot;
    std::string storageRoot;
    std::string path;
    std::string reason;
    std::optional<std::string> content;
    bool pruneExpired = false;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
};

struct HistoryEntriesRequestDto {
    std::string workspaceRoot;
    std::string storageRoot;
    std::optional<std::string> path;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
};

struct HistoryContentRequestDto {
    std::string storageRoot;
    std::string contentPath;
};

struct HistoryRelocateRequestDto {
    std::string storageRoot;
    std::string sourcePath;
    std::string destinationPath;
};

struct MavenScanRequestDto {
    std::string root;
};

struct MavenDiagnosticsRequestDto {
    std::string root;
    std::string output;
};

struct JavaRunConfigurationsRequestDto {
    std::string root;
    std::vector<std::string> paths;
    std::vector<std::string> modulePaths;
};

struct JavaCodeVisionRequestDto {
    std::string root;
    std::string targetPath;
    std::vector<std::string> paths;
};

struct JavaClassNameRequestDto {
    std::string source;
    std::string simpleName;
};

struct JavaSourceDefinitionRequestDto {
    std::string source;
    std::string declarationName;
    std::optional<std::string> memberName;
};

struct JavaServerPortRequestDto {
    std::string content;
    std::string fileExtension;
};

struct JavaStructureRequestDto {
    std::string source;
    std::vector<std::string> declarationSources;
};

struct GitStatusRequestDto {
    std::string root;
};

struct GitDiffRequestDto {
    std::string root;
    std::vector<std::string> pathspecs;
    std::optional<std::string> reference;
    std::optional<std::string> commit;
    bool staged = false;
    bool untracked = false;
    std::uint64_t contextLines = 80;
    bool ignoreAllWhitespace = false;
};

struct GitApplyRequestDto {
    std::string root;
    std::string patch;
    std::string mode;
};

struct GitCommandRequestDto {
    std::string root;
    std::vector<std::string> arguments;
    std::optional<std::string> input;
};

struct GitWriteRequestDto {
    std::string root;
    std::string operation;
    std::vector<std::string> paths;
    std::optional<std::string> reference;
    std::optional<std::string> referenceKind;
    std::optional<std::string> revision;
    std::optional<std::string> name;
    std::optional<std::string> message;
    std::optional<std::string> remote;
    std::optional<std::string> destination;
    std::optional<std::string> mode;
    bool includeUntracked = false;
    bool checkout = false;
    bool amend = false;
    bool force = false;
    bool autoStash = false;
};

struct GitCheckoutPreflightRequestDto {
    std::string root;
    std::string reference;
};

struct GitConflictMarkersRequestDto {
    std::string root;
};

struct GitIntegrationPreflightRequestDto {
    std::string root;
    std::string reference;
    std::string operation;
};

struct GitPullPreflightRequestDto {
    std::string root;
};

struct GitOperationStateRequestDto {
    std::string root;
};

struct GitHistoryRequestDto {
    std::string root;
    std::optional<std::string> reference;
    std::uint64_t limit = 300;
};

struct GitCommitRequestDto {
    std::string root;
    std::string commit;
};

struct GitCommitFilesRequestDto {
    std::string root;
    std::string commit;
};

struct GitComparisonRequestDto {
    std::string root;
    std::string reference;
};

struct GitStashesRequestDto {
    std::string root;
};

struct GitBlameRequestDto {
    std::string root;
    std::string path;
};

std::string encodeWorkspaceSnapshotRequest(const WorkspaceSnapshotRequestDto& request);
std::string encodeSearchRequest(const SearchRequestDto& request);
std::string encodeReplacementPreviewRequest(const ReplacementPreviewRequestDto& request);
std::string encodeFileReadRequest(const FileReadRequestDto& request);
std::string encodeFileWriteRequest(const FileWriteRequestDto& request);
std::string encodeHistoryRecordRequest(const HistoryRecordRequestDto& request);
std::string encodeHistoryEntriesRequest(const HistoryEntriesRequestDto& request);
std::string encodeHistoryContentRequest(const HistoryContentRequestDto& request);
std::string encodeHistoryRelocateRequest(const HistoryRelocateRequestDto& request);
std::string encodeMavenScanRequest(const MavenScanRequestDto& request);
std::string encodeMavenDiagnosticsRequest(const MavenDiagnosticsRequestDto& request);
std::string encodeJavaRunConfigurationsRequest(const JavaRunConfigurationsRequestDto& request);
std::string encodeJavaCodeVisionRequest(const JavaCodeVisionRequestDto& request);
std::string encodeJavaClassNameRequest(const JavaClassNameRequestDto& request);
std::string encodeJavaSourceDefinitionRequest(const JavaSourceDefinitionRequestDto& request);
std::string encodeJavaServerPortRequest(const JavaServerPortRequestDto& request);
std::string encodeJavaStructureRequest(const JavaStructureRequestDto& request);
std::string encodeGitStatusRequest(const GitStatusRequestDto& request);
std::string encodeGitDiffRequest(const GitDiffRequestDto& request);
std::string encodeGitApplyRequest(const GitApplyRequestDto& request);
std::string encodeGitCommandRequest(const GitCommandRequestDto& request);
std::string encodeGitWriteRequest(const GitWriteRequestDto& request);
std::string encodeGitCheckoutPreflightRequest(const GitCheckoutPreflightRequestDto& request);
std::string encodeGitConflictMarkersRequest(const GitConflictMarkersRequestDto& request);
std::string encodeGitIntegrationPreflightRequest(const GitIntegrationPreflightRequestDto& request);
std::string encodeGitPullPreflightRequest(const GitPullPreflightRequestDto& request);
std::string encodeGitOperationStateRequest(const GitOperationStateRequestDto& request);
std::string encodeGitHistoryRequest(const GitHistoryRequestDto& request);
std::string encodeGitCommitRequest(const GitCommitRequestDto& request);
std::string encodeGitCommitFilesRequest(const GitCommitFilesRequestDto& request);
std::string encodeGitComparisonRequest(const GitComparisonRequestDto& request);
std::string encodeGitStashesRequest(const GitStashesRequestDto& request);
std::string encodeGitBlameRequest(const GitBlameRequestDto& request);

} // namespace lithe::windows
