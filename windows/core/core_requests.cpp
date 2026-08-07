#include "core_requests.h"

#include <utility>

namespace lithe::windows {
namespace {

JsonValue::Array strings(const std::vector<std::string>& values) {
    JsonValue::Array result;
    result.reserve(values.size());
    for (const auto& value : values) result.emplace_back(value);
    return result;
}

void addOptional(JsonValue::Object& object, std::string key,
                 const std::optional<std::string>& value) {
    if (value) object.emplace(std::move(key), *value);
}

void addOptional(JsonValue::Object& object, std::string key,
                 const std::optional<std::uint64_t>& value) {
    if (value) object.emplace(std::move(key), *value);
}

std::string encode(JsonValue::Object object) {
    return serializeJson(JsonValue(std::move(object)));
}

void addSearchFields(JsonValue::Object& object, const SearchRequestDto& request) {
    object.emplace("root", request.root);
    object.emplace("query", request.query);
    object.emplace("caseSensitive", request.caseSensitive);
    object.emplace("wholeWords", request.wholeWords);
    object.emplace("regularExpression", request.regularExpression);
    object.emplace("maxResults", request.maxResults);
    addOptional(object, "maxFileResults", request.maxFileResults);
    addOptional(object, "maxContentResults", request.maxContentResults);
    addOptional(object, "maxSymbolResults", request.maxSymbolResults);
    object.emplace("fileMask", request.fileMask);
    object.emplace("hiddenDirectoryNames", strings(request.hiddenDirectoryNames));
    object.emplace("hiddenFilePatterns", strings(request.hiddenFilePatterns));
}

} // namespace

std::string encodeWorkspaceSnapshotRequest(const WorkspaceSnapshotRequestDto& request) {
    return encode({
        {"root", request.root},
        {"hiddenDirectoryNames", strings(request.hiddenDirectoryNames)},
        {"hiddenFilePatterns", strings(request.hiddenFilePatterns)},
    });
}

std::string encodeSearchRequest(const SearchRequestDto& request) {
    JsonValue::Object object;
    addSearchFields(object, request);
    return encode(std::move(object));
}

std::string encodeReplacementPreviewRequest(const ReplacementPreviewRequestDto& request) {
    JsonValue::Object overrides;
    for (const auto& [path, text] : request.textOverrides) overrides.emplace(path, text);
    return encode({
        {"root", request.root},
        {"query", request.query},
        {"replacement", request.replacement},
        {"caseSensitive", request.caseSensitive},
        {"wholeWords", request.wholeWords},
        {"regularExpression", request.regularExpression},
        {"preserveCase", request.preserveCase},
        {"fileMask", request.fileMask},
        {"paths", strings(request.paths)},
        {"textOverrides", std::move(overrides)},
        {"hiddenDirectoryNames", strings(request.hiddenDirectoryNames)},
        {"hiddenFilePatterns", strings(request.hiddenFilePatterns)},
    });
}

std::string encodeFileReadRequest(const FileReadRequestDto& request) {
    return encode({{"root", request.root}, {"path", request.path}});
}

std::string encodeFileWriteRequest(const FileWriteRequestDto& request) {
    return encode({{"root", request.root}, {"path", request.path}, {"text", request.text}});
}

std::string encodeHistoryRecordRequest(const HistoryRecordRequestDto& request) {
    JsonValue::Object object{
        {"workspaceRoot", request.workspaceRoot},
        {"storageRoot", request.storageRoot},
        {"path", request.path},
        {"reason", request.reason},
        {"pruneExpired", request.pruneExpired},
        {"hiddenDirectoryNames", strings(request.hiddenDirectoryNames)},
        {"hiddenFilePatterns", strings(request.hiddenFilePatterns)},
    };
    addOptional(object, "content", request.content);
    return encode(std::move(object));
}

std::string encodeHistoryEntriesRequest(const HistoryEntriesRequestDto& request) {
    JsonValue::Object object{
        {"workspaceRoot", request.workspaceRoot},
        {"storageRoot", request.storageRoot},
        {"hiddenDirectoryNames", strings(request.hiddenDirectoryNames)},
        {"hiddenFilePatterns", strings(request.hiddenFilePatterns)},
    };
    addOptional(object, "path", request.path);
    return encode(std::move(object));
}

std::string encodeHistoryContentRequest(const HistoryContentRequestDto& request) {
    return encode({{"storageRoot", request.storageRoot}, {"contentPath", request.contentPath}});
}

std::string encodeHistoryRelocateRequest(const HistoryRelocateRequestDto& request) {
    return encode({{"storageRoot", request.storageRoot},
                   {"sourcePath", request.sourcePath},
                   {"destinationPath", request.destinationPath}});
}

std::string encodeMavenScanRequest(const MavenScanRequestDto& request) {
    return encode({{"root", request.root}});
}

std::string encodeMavenDiagnosticsRequest(const MavenDiagnosticsRequestDto& request) {
    return encode({{"root", request.root}, {"output", request.output}});
}

std::string encodeJavaRunConfigurationsRequest(const JavaRunConfigurationsRequestDto& request) {
    return encode({{"root", request.root},
                   {"paths", strings(request.paths)},
                   {"modulePaths", strings(request.modulePaths)}});
}

std::string encodeJavaCodeVisionRequest(const JavaCodeVisionRequestDto& request) {
    return encode({{"root", request.root},
                   {"targetPath", request.targetPath},
                   {"paths", strings(request.paths)}});
}

std::string encodeJavaClassNameRequest(const JavaClassNameRequestDto& request) {
    return encode({{"source", request.source}, {"simpleName", request.simpleName}});
}

std::string encodeJavaSourceDefinitionRequest(const JavaSourceDefinitionRequestDto& request) {
    JsonValue::Object object{{"source", request.source}, {"declarationName", request.declarationName}};
    addOptional(object, "memberName", request.memberName);
    return encode(std::move(object));
}

std::string encodeJavaServerPortRequest(const JavaServerPortRequestDto& request) {
    return encode({{"content", request.content}, {"fileExtension", request.fileExtension}});
}

std::string encodeJavaStructureRequest(const JavaStructureRequestDto& request) {
    return encode({{"source", request.source},
                   {"declarationSources", strings(request.declarationSources)}});
}

std::string encodeGitStatusRequest(const GitStatusRequestDto& request) {
    return encode({{"root", request.root}});
}

std::string encodeGitDiffRequest(const GitDiffRequestDto& request) {
    JsonValue::Object object{
        {"root", request.root},
        {"pathspecs", strings(request.pathspecs)},
        {"staged", request.staged},
        {"untracked", request.untracked},
        {"contextLines", request.contextLines},
        {"ignoreAllWhitespace", request.ignoreAllWhitespace},
    };
    addOptional(object, "reference", request.reference);
    addOptional(object, "commit", request.commit);
    return encode(std::move(object));
}

std::string encodeGitApplyRequest(const GitApplyRequestDto& request) {
    return encode({{"root", request.root}, {"patch", request.patch}, {"mode", request.mode}});
}

std::string encodeGitCommandRequest(const GitCommandRequestDto& request) {
    JsonValue::Object object{{"root", request.root}, {"arguments", strings(request.arguments)}};
    addOptional(object, "input", request.input);
    return encode(std::move(object));
}

std::string encodeGitWriteRequest(const GitWriteRequestDto& request) {
    JsonValue::Object object{
        {"root", request.root},
        {"operation", request.operation},
        {"paths", strings(request.paths)},
        {"includeUntracked", request.includeUntracked},
        {"checkout", request.checkout},
        {"amend", request.amend},
        {"force", request.force},
        {"autoStash", request.autoStash},
    };
    addOptional(object, "reference", request.reference);
    addOptional(object, "referenceKind", request.referenceKind);
    addOptional(object, "revision", request.revision);
    addOptional(object, "name", request.name);
    addOptional(object, "message", request.message);
    addOptional(object, "remote", request.remote);
    addOptional(object, "destination", request.destination);
    addOptional(object, "mode", request.mode);
    return encode(std::move(object));
}

std::string encodeGitCheckoutPreflightRequest(const GitCheckoutPreflightRequestDto& request) {
    return encode({{"root", request.root}, {"reference", request.reference}});
}

std::string encodeGitPullPreflightRequest(const GitPullPreflightRequestDto& request) {
    return encode({{"root", request.root}});
}

std::string encodeGitIntegrationPreflightRequest(
    const GitIntegrationPreflightRequestDto& request) {
    return encode({{"root", request.root},
                   {"reference", request.reference},
                   {"operation", request.operation}});
}

std::string encodeGitConflictMarkersRequest(const GitConflictMarkersRequestDto& request) {
    return encode({{"root", request.root}});
}

std::string encodeGitOperationStateRequest(const GitOperationStateRequestDto& request) {
    return encode({{"root", request.root}});
}

std::string encodeGitHistoryRequest(const GitHistoryRequestDto& request) {
    JsonValue::Object object{{"root", request.root}, {"limit", request.limit}};
    addOptional(object, "reference", request.reference);
    return encode(std::move(object));
}

std::string encodeGitCommitRequest(const GitCommitRequestDto& request) {
    return encode({{"root", request.root}, {"commit", request.commit}});
}

std::string encodeGitCommitFilesRequest(const GitCommitFilesRequestDto& request) {
    return encode({{"root", request.root}, {"commit", request.commit}});
}

std::string encodeGitComparisonRequest(const GitComparisonRequestDto& request) {
    return encode({{"root", request.root}, {"reference", request.reference}});
}

std::string encodeGitStashesRequest(const GitStashesRequestDto& request) {
    return encode({{"root", request.root}});
}

std::string encodeGitBlameRequest(const GitBlameRequestDto& request) {
    return encode({{"root", request.root}, {"path", request.path}});
}

} // namespace lithe::windows
