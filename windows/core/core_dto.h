#pragma once

#include "core_client.h"
#include "core_error.h"
#include "json_value.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows {

struct CoreEnvelope {
    std::optional<std::string> id;
    bool ok = false;
    bool hasData = false;
    JsonValue data;
    bool hasError = false;
    CoreError error;
};

CoreResult<CoreEnvelope> decodeCoreEnvelope(const CoreResponse& response);
CoreResult<CoreEnvelope> decodeCoreEnvelope(std::string_view json);

struct CorePingDto {
    std::uint64_t protocolVersion = 0;
    std::string coreVersion;
};

struct WorkspaceNodeDto {
    std::string path;
    std::string name;
    bool isDirectory = false;
    // The key is absent for file nodes.  Empty and absent are equivalent after
    // decoding, but the decoder never invents a child for a missing key.
    std::vector<WorkspaceNodeDto> children;
};

struct WorkspaceSnapshotDto {
    WorkspaceNodeDto root;
    std::vector<std::string> files;
};

struct SearchMatchDto {
    std::string kind;
    std::string path;
    std::optional<std::uint64_t> line;
    std::string preview;
    std::optional<std::string> symbolName;
};

struct SearchResponseDto {
    std::vector<SearchMatchDto> matches;
};

struct ReplacementMatchDto {
    std::uint64_t line = 0;
    std::string before;
    std::string after;
    std::uint64_t occurrenceCount = 0;
};

struct ReplacementFileDto {
    std::string path;
    std::vector<ReplacementMatchDto> matches;
    std::string originalText;
    std::string replacementText;
};

struct ReplacementPreviewDto {
    std::vector<ReplacementFileDto> files;
};

struct FileReadDto {
    std::string path;
    std::string text;
};

struct MarkdownRenderDto {
    std::string html;
};

struct FileWriteDto {
    std::string path;
    std::uint64_t bytesWritten = 0;
};

struct HistoryEntryDto {
    std::string id;
    std::int64_t timestamp = 0;
    std::string relativePath;
    std::string reason;
    std::string contentPath;
    std::uint64_t byteCount = 0;
};

struct HistoryRecordDto {
    std::optional<HistoryEntryDto> entry;
};

struct HistoryEntriesDto {
    std::vector<HistoryEntryDto> entries;
};

struct HistoryContentDto {
    std::string text;
};

struct HistoryRelocateDto {
    bool relocated = false;
};

struct ShelfSummaryDto {
    std::string id;
    std::string workspaceRoot;
    std::string label;
    std::int64_t createdAt = 0;
    std::uint64_t stagedByteCount = 0;
    std::uint64_t workingTreeByteCount = 0;
};

struct ShelfCreateDto {
    ShelfSummaryDto shelf;
};

struct ShelfListDto {
    std::vector<ShelfSummaryDto> shelves;
};

struct ShelfRestoreDto {
    std::string id;
    std::string stagedPatch;
    std::string workingTreePatch;
};

struct ShelfDeleteDto {
    bool deleted = false;
};

struct MavenProfileDto {
    std::string id;
    bool isActiveByDefault = false;
};

struct MavenModuleDto {
    std::string relativePath;
    std::optional<std::string> groupId;
    std::string artifactId;
    std::optional<std::string> version;
    std::string packaging;
    std::vector<MavenModuleDto> modules;
};

struct MavenScanDto {
    std::optional<std::string> groupId;
    std::string artifactId;
    std::optional<std::string> version;
    std::string packaging;
    std::vector<MavenModuleDto> modules;
    std::vector<MavenProfileDto> profiles;
    bool hasWrapper = false;
};

struct MavenScanResultDto {
    std::optional<MavenScanDto> scan;
};

struct MavenDiagnosticDto {
    std::string path;
    std::uint64_t line = 0;
    std::optional<std::uint64_t> column;
    std::string severity;
    std::string message;
};

struct MavenDiagnosticsDto {
    std::vector<MavenDiagnosticDto> issues;
};

struct JavaMainClassDto {
    std::string path;
    std::string qualifiedName;
    std::string simpleName;
    bool isSpringBoot = false;
};

struct JavaRunConfigurationDto {
    std::string id;
    std::string name;
    std::string kind;
    std::optional<std::string> modulePath;
    std::optional<std::string> mainClass;
};

struct JavaRunConfigurationsDto {
    std::vector<JavaMainClassDto> mainClasses;
    std::vector<JavaRunConfigurationDto> configurations;
};

struct JavaCodeVisionHintDto {
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;
    std::string symbol;
    std::uint64_t usageCount = 0;
};

struct JavaCodeVisionDto {
    std::vector<JavaCodeVisionHintDto> hints;
};

struct JavaClassNameDto {
    std::string className;
};

struct JavaSourceDefinitionDto {
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;
};

struct JavaSourceDefinitionResultDto {
    std::optional<JavaSourceDefinitionDto> definition;
};

struct JavaServerPortDto {
    std::optional<std::uint64_t> port;
};

struct JavaFoldRegionDto {
    std::string kind;
    std::uint64_t startLine = 0;
    std::uint64_t endLine = 0;
    std::uint64_t hiddenStart = 0;
    std::uint64_t hiddenLength = 0;
};

struct JavaImplementationMarkerDto {
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;
    std::uint64_t implementationCount = 0;
    std::string direction;
};

struct JavaInlayHintDto {
    std::uint64_t line = 0;
    std::uint64_t utf16Column = 0;
    std::string label;
};

struct JavaStructureDto {
    std::vector<JavaFoldRegionDto> foldRegions;
    std::vector<JavaImplementationMarkerDto> implementationMarkers;
    std::vector<JavaInlayHintDto> inlayHints;
};

struct GitDiffRowDto {
    std::optional<std::uint64_t> oldLine;
    std::optional<std::uint64_t> newLine;
    std::optional<std::string> left;
    // The right key disappears for context/information rows.  Keep that
    // distinction instead of treating it as an explicit JSON null.
    bool hasRight = false;
    std::optional<std::string> right;
    std::string kind;
    std::optional<std::string> hunkId;
};

struct GitDiffHunkDto {
    std::string id;
    std::string header;
    std::string patch;
};

struct GitDiffDto {
    std::string patch;
    std::vector<GitDiffRowDto> rows;
    std::vector<GitDiffHunkDto> hunks;
};

struct GitShelfPatchesDto {
    std::string stagedPatch;
    std::string workingTreePatch;
};

struct GitChangeDto {
    std::string path;
    std::optional<std::string> originalPath;
    std::string status;
    bool staged = false;
    bool worktree = false;
    bool untracked = false;
};

struct GitStatusDto {
    std::optional<std::string> repositoryRoot;
    std::optional<std::string> branch;
    std::vector<GitChangeDto> changes;
};

struct GitStashRestoreDto {
    std::string stashReference;
    std::vector<std::string> conflictedPaths;
    bool deferred = false;
};

struct GitCommandDto {
    std::string output;
    std::int32_t exitCode = 0;
    std::optional<GitStashRestoreDto> stashRestore;
};

struct GitCheckoutPreflightDto {
    std::vector<std::string> blockingPaths;
};

struct GitConflictMarkersDto {
    std::vector<std::string> paths;
};

struct GitIntegrationPreflightDto {
    std::vector<std::string> blockingPaths;
    bool blocksEntirely = false;
};

struct GitPullPreflightDto {
    std::optional<std::string> upstream;
    std::uint64_t ahead = 0;
    std::uint64_t behind = 0;
    bool diverged = false;
    bool hasLocalChanges = false;
};

struct GitOperationStateDto {
    std::string kind;
    std::optional<std::string> reference;
    std::optional<std::uint64_t> step;
    std::optional<std::uint64_t> total;
    std::vector<std::string> conflictedPaths;
    std::optional<std::string> autoStashReference;
};

struct GitReferenceDto {
    std::string fullName;
    std::string shortName;
    std::string kind;
    bool isCurrent = false;
    std::optional<std::string> upstreamShortName;
};

struct GitCommitDto {
    std::string hash;
    std::string shortHash;
    std::vector<std::string> parentHashes;
    std::string authorName;
    std::string authorEmail;
    std::string date;
    std::string subject;
    std::string decorations;
};

struct GitHistoryDto {
    std::vector<GitReferenceDto> references;
    std::vector<GitCommitDto> commits;
    bool hasMore = false;
};

struct GitFileDto {
    std::string status;
    std::string path;
};

struct GitCommitLookupDto {
    GitCommitDto commit;
};

struct GitFilesResponseDto {
    std::vector<GitFileDto> files;
};

struct GitComparisonDto {
    std::vector<GitFileDto> files;
};

struct GitStashDto {
    std::string reference;
    std::string message;
    std::optional<std::string> branch;
    std::string date;
};

struct GitBlameLineDto {
    std::uint64_t line = 0;
    std::string commitHash;
    std::string authorName;
    std::int64_t authorTime = 0;
};

struct GitStashesResponseDto {
    std::vector<GitStashDto> stashes;
};

struct GitBlameResponseDto {
    std::vector<GitBlameLineDto> lines;
};

std::optional<CorePingDto> decodeCorePing(const CoreEnvelope& envelope);
std::optional<WorkspaceSnapshotDto> decodeWorkspaceSnapshot(const CoreEnvelope& envelope);
std::optional<SearchResponseDto> decodeSearchResponse(const CoreEnvelope& envelope);
std::optional<ReplacementPreviewDto> decodeReplacementPreview(const CoreEnvelope& envelope);
std::optional<FileReadDto> decodeFileRead(const CoreEnvelope& envelope);
std::optional<MarkdownRenderDto> decodeMarkdownRender(const CoreEnvelope& envelope);
std::optional<FileWriteDto> decodeFileWrite(const CoreEnvelope& envelope);
std::optional<HistoryRecordDto> decodeHistoryRecord(const CoreEnvelope& envelope);
std::optional<HistoryEntriesDto> decodeHistoryEntries(const CoreEnvelope& envelope);
std::optional<HistoryContentDto> decodeHistoryContent(const CoreEnvelope& envelope);
std::optional<HistoryRelocateDto> decodeHistoryRelocate(const CoreEnvelope& envelope);
std::optional<ShelfCreateDto> decodeShelfCreate(const CoreEnvelope& envelope);
std::optional<ShelfListDto> decodeShelfList(const CoreEnvelope& envelope);
std::optional<ShelfRestoreDto> decodeShelfRestore(const CoreEnvelope& envelope);
std::optional<ShelfDeleteDto> decodeShelfDelete(const CoreEnvelope& envelope);
std::optional<MavenScanResultDto> decodeMavenScan(const CoreEnvelope& envelope);
std::optional<MavenDiagnosticsDto> decodeMavenDiagnostics(const CoreEnvelope& envelope);
std::optional<JavaRunConfigurationsDto> decodeJavaRunConfigurations(const CoreEnvelope& envelope);
std::optional<JavaCodeVisionDto> decodeJavaCodeVision(const CoreEnvelope& envelope);
std::optional<JavaClassNameDto> decodeJavaClassName(const CoreEnvelope& envelope);
std::optional<JavaSourceDefinitionResultDto> decodeJavaSourceDefinition(const CoreEnvelope& envelope);
std::optional<JavaServerPortDto> decodeJavaServerPort(const CoreEnvelope& envelope);
std::optional<JavaStructureDto> decodeJavaStructure(const CoreEnvelope& envelope);
std::optional<GitDiffDto> decodeGitDiff(const CoreEnvelope& envelope);
std::optional<GitShelfPatchesDto> decodeGitShelfPatches(const CoreEnvelope& envelope);
std::optional<GitStatusDto> decodeGitStatus(const CoreEnvelope& envelope);
std::optional<GitCommandDto> decodeGitCommand(const CoreEnvelope& envelope);
std::optional<GitCheckoutPreflightDto> decodeGitCheckoutPreflight(const CoreEnvelope& envelope);
std::optional<GitPullPreflightDto> decodeGitPullPreflight(const CoreEnvelope& envelope);
std::optional<GitIntegrationPreflightDto> decodeGitIntegrationPreflight(
    const CoreEnvelope& envelope);
std::optional<GitConflictMarkersDto> decodeGitConflictMarkers(const CoreEnvelope& envelope);
std::optional<GitOperationStateDto> decodeGitOperationState(const CoreEnvelope& envelope);
std::optional<GitHistoryDto> decodeGitHistory(const CoreEnvelope& envelope);
std::optional<GitCommitLookupDto> decodeGitCommit(const CoreEnvelope& envelope);
std::optional<GitFilesResponseDto> decodeGitCommitFiles(const CoreEnvelope& envelope);
std::optional<GitComparisonDto> decodeGitComparison(const CoreEnvelope& envelope);
std::optional<GitStashesResponseDto> decodeGitStashesResponse(const CoreEnvelope& envelope);
std::optional<GitBlameResponseDto> decodeGitBlameResponse(const CoreEnvelope& envelope);
std::optional<std::vector<GitFileDto>> decodeGitFiles(const CoreEnvelope& envelope);
std::optional<std::vector<GitStashDto>> decodeGitStashes(const CoreEnvelope& envelope);
std::optional<std::vector<GitBlameLineDto>> decodeGitBlame(const CoreEnvelope& envelope);

} // namespace lithe::windows
