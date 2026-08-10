#include "core_dto.h"

#include <algorithm>
#include <limits>
#include <string_view>

namespace lithe::windows {
namespace {

std::optional<std::string> requiredString(const JsonValue& object, std::string_view key) {
    const auto* value = objectValue(object, key);
    if (value == nullptr || value->asString() == nullptr) return std::nullopt;
    return *value->asString();
}

std::optional<bool> requiredBool(const JsonValue& object, std::string_view key) {
    const auto* value = objectValue(object, key);
    if (value == nullptr || value->asBool() == nullptr) return std::nullopt;
    return *value->asBool();
}

std::optional<std::uint64_t> requiredUInt(const JsonValue& object, std::string_view key) {
    const auto* value = objectValue(object, key);
    return value == nullptr ? std::nullopt : value->asUInt();
}

std::optional<std::int64_t> requiredInt(const JsonValue& object, std::string_view key) {
    const auto* value = objectValue(object, key);
    return value == nullptr ? std::nullopt : value->asInt();
}

std::optional<std::string> optionalString(const JsonValue& object, std::string_view key) {
    const auto* value = objectValue(object, key);
    if (value == nullptr || value->isNull()) return std::nullopt;
    return value->asString() == nullptr ? std::nullopt : std::optional<std::string>(*value->asString());
}

std::optional<std::vector<std::string>> stringArray(const JsonValue& object,
                                                     std::string_view key) {
    const auto* value = objectValue(object, key);
    if (value == nullptr || value->asArray() == nullptr) return std::nullopt;
    std::vector<std::string> result;
    result.reserve(value->asArray()->size());
    for (const auto& item : *value->asArray()) {
        if (item.asString() == nullptr) return std::nullopt;
        result.push_back(*item.asString());
    }
    return result;
}

std::optional<std::vector<const JsonValue*>> objectArray(const JsonValue& object,
                                                          std::string_view key) {
    const auto* value = objectValue(object, key);
    if (value == nullptr || value->asArray() == nullptr) return std::nullopt;
    std::vector<const JsonValue*> result;
    result.reserve(value->asArray()->size());
    for (const auto& item : *value->asArray()) result.push_back(&item);
    return result;
}

CoreErrorCode errorCode(std::string_view value) {
    if (value == "invalid_request") return CoreErrorCode::InvalidRequest;
    if (value == "workspace_not_found") return CoreErrorCode::WorkspaceNotFound;
    if (value == "permission_denied") return CoreErrorCode::PermissionDenied;
    if (value == "external_conflict") return CoreErrorCode::ExternalConflict;
    if (value == "not_supported") return CoreErrorCode::NotSupported;
    if (value == "runtime_missing") return CoreErrorCode::RuntimeMissing;
    if (value == "process_start_failed") return CoreErrorCode::ProcessStartFailed;
    if (value == "process_failed") return CoreErrorCode::ProcessFailed;
    if (value == "parse_failed") return CoreErrorCode::ParseFailed;
    if (value == "cancelled") return CoreErrorCode::Cancelled;
    if (value == "timed_out") return CoreErrorCode::TimedOut;
    return CoreErrorCode::Unknown;
}

std::optional<WorkspaceNodeDto> decodeNode(const JsonValue& value) {
    if (!value.isObject()) return std::nullopt;
    const auto path = requiredString(value, "path");
    const auto name = requiredString(value, "name");
    const auto directory = requiredBool(value, "isDirectory");
    if (!path || !name || !directory) return std::nullopt;
    WorkspaceNodeDto result{*path, *name, *directory, {}};
    const auto* children = objectValue(value, "children");
    if (children == nullptr) return result;
    if (children->asArray() == nullptr) return std::nullopt;
    result.children.reserve(children->asArray()->size());
    for (const auto& child : *children->asArray()) {
        auto decoded = decodeNode(child);
        if (!decoded) return std::nullopt;
        result.children.push_back(std::move(*decoded));
    }
    return result;
}

std::optional<HistoryEntryDto> decodeHistoryEntry(const JsonValue& value) {
    const auto id = requiredString(value, "id");
    const auto timestamp = requiredInt(value, "timestamp");
    const auto relativePath = requiredString(value, "relativePath");
    const auto reason = requiredString(value, "reason");
    const auto contentPath = requiredString(value, "contentPath");
    const auto byteCount = requiredUInt(value, "byteCount");
    if (!id || !timestamp || !relativePath || !reason || !contentPath || !byteCount) {
        return std::nullopt;
    }
    return HistoryEntryDto{*id, *timestamp, *relativePath, *reason, *contentPath, *byteCount};
}

std::optional<ShelfSummaryDto> decodeShelfSummary(const JsonValue& value) {
    const auto id = requiredString(value, "id");
    const auto workspaceRoot = requiredString(value, "workspaceRoot");
    const auto label = requiredString(value, "label");
    const auto createdAt = requiredInt(value, "createdAt");
    const auto stagedByteCount = requiredUInt(value, "stagedByteCount");
    const auto workingTreeByteCount = requiredUInt(value, "workingTreeByteCount");
    if (!id || !workspaceRoot || !label || !createdAt ||
        !stagedByteCount || !workingTreeByteCount) return std::nullopt;
    return ShelfSummaryDto{*id, *workspaceRoot, *label, *createdAt,
                           *stagedByteCount, *workingTreeByteCount};
}

std::optional<MavenModuleDto> decodeMavenModule(const JsonValue& value) {
    const auto relativePath = requiredString(value, "relativePath");
    const auto groupId = objectValue(value, "groupId");
    const auto artifactId = requiredString(value, "artifactId");
    const auto version = objectValue(value, "version");
    const auto packaging = requiredString(value, "packaging");
    const auto modules = objectArray(value, "modules");
    if (!relativePath || groupId == nullptr || !artifactId || version == nullptr ||
        !packaging || !modules) return std::nullopt;
    const auto decodedGroupId = groupId->isNull()
        ? std::optional<std::string>{} : optionalString(value, "groupId");
    const auto decodedVersion = version->isNull()
        ? std::optional<std::string>{} : optionalString(value, "version");
    if ((!groupId->isNull() && !decodedGroupId) || (!version->isNull() && !decodedVersion)) {
        return std::nullopt;
    }
    MavenModuleDto result{*relativePath, decodedGroupId, *artifactId, decodedVersion,
                          *packaging, {}};
    result.modules.reserve(modules->size());
    for (const auto* module : *modules) {
        const auto decoded = decodeMavenModule(*module);
        if (!decoded) return std::nullopt;
        result.modules.push_back(*decoded);
    }
    return result;
}

std::optional<JavaMainClassDto> decodeJavaMainClass(const JsonValue& value) {
    const auto path = requiredString(value, "path");
    const auto qualifiedName = requiredString(value, "qualifiedName");
    const auto simpleName = requiredString(value, "simpleName");
    const auto springBoot = requiredBool(value, "isSpringBoot");
    if (!path || !qualifiedName || !simpleName || !springBoot) return std::nullopt;
    return JavaMainClassDto{*path, *qualifiedName, *simpleName, *springBoot};
}

std::optional<JavaRunConfigurationDto> decodeJavaRunConfiguration(const JsonValue& value) {
    const auto id = requiredString(value, "id");
    const auto name = requiredString(value, "name");
    const auto kind = requiredString(value, "kind");
    const auto modulePath = objectValue(value, "modulePath");
    const auto mainClass = objectValue(value, "mainClass");
    if (!id || !name || !kind || modulePath == nullptr || mainClass == nullptr) return std::nullopt;
    const auto decodedModulePath = modulePath->isNull()
        ? std::optional<std::string>{} : optionalString(value, "modulePath");
    const auto decodedMainClass = mainClass->isNull()
        ? std::optional<std::string>{} : optionalString(value, "mainClass");
    if ((!modulePath->isNull() && !decodedModulePath) ||
        (!mainClass->isNull() && !decodedMainClass)) return std::nullopt;
    return JavaRunConfigurationDto{*id, *name, *kind, decodedModulePath, decodedMainClass};
}

std::optional<JavaFoldRegionDto> decodeJavaFoldRegion(const JsonValue& value) {
    const auto kind = requiredString(value, "kind");
    const auto startLine = requiredUInt(value, "startLine");
    const auto endLine = requiredUInt(value, "endLine");
    const auto hiddenStart = requiredUInt(value, "hiddenStart");
    const auto hiddenLength = requiredUInt(value, "hiddenLength");
    if (!kind || !startLine || !endLine || !hiddenStart || !hiddenLength) return std::nullopt;
    return JavaFoldRegionDto{*kind, *startLine, *endLine, *hiddenStart, *hiddenLength};
}

std::optional<JavaImplementationMarkerDto> decodeJavaImplementationMarker(const JsonValue& value) {
    const auto line = requiredUInt(value, "line");
    const auto column = requiredUInt(value, "utf16Column");
    const auto count = requiredUInt(value, "implementationCount");
    const auto direction = requiredString(value, "direction");
    if (!line || !column || !count || !direction) return std::nullopt;
    return JavaImplementationMarkerDto{*line, *column, *count, *direction};
}

std::optional<JavaInlayHintDto> decodeJavaInlayHint(const JsonValue& value) {
    const auto line = requiredUInt(value, "line");
    const auto column = requiredUInt(value, "utf16Column");
    const auto label = requiredString(value, "label");
    if (!line || !column || !label) return std::nullopt;
    return JavaInlayHintDto{*line, *column, *label};
}

std::optional<GitCommitDto> decodeGitCommitValue(const JsonValue& value) {
    const auto hash = requiredString(value, "hash");
    const auto shortHash = requiredString(value, "shortHash");
    const auto parents = stringArray(value, "parentHashes");
    const auto authorName = requiredString(value, "authorName");
    const auto authorEmail = requiredString(value, "authorEmail");
    const auto date = requiredString(value, "date");
    const auto subject = requiredString(value, "subject");
    const auto decorations = requiredString(value, "decorations");
    if (!hash || !shortHash || !parents || !authorName || !authorEmail || !date ||
        !subject || !decorations) return std::nullopt;
    return GitCommitDto{*hash, *shortHash, *parents, *authorName, *authorEmail,
                        *date, *subject, *decorations};
}

std::optional<GitFileDto> decodeGitFileValue(const JsonValue& value) {
    const auto status = requiredString(value, "status");
    const auto path = requiredString(value, "path");
    if (!status || !path) return std::nullopt;
    return GitFileDto{*status, *path};
}

std::optional<GitStashDto> decodeGitStashValue(const JsonValue& value) {
    const auto reference = requiredString(value, "reference");
    const auto message = requiredString(value, "message");
    const auto branch = objectValue(value, "branch");
    const auto date = requiredString(value, "date");
    if (!reference || !message || branch == nullptr || !date) return std::nullopt;
    const auto decodedBranch = branch->isNull()
        ? std::optional<std::string>{} : optionalString(value, "branch");
    if (!branch->isNull() && !decodedBranch) return std::nullopt;
    return GitStashDto{*reference, *message, decodedBranch, *date};
}

std::optional<GitBlameLineDto> decodeGitBlameLineValue(const JsonValue& value) {
    const auto line = requiredUInt(value, "line");
    const auto commitHash = requiredString(value, "commitHash");
    const auto authorName = requiredString(value, "authorName");
    const auto authorTime = requiredInt(value, "authorTime");
    if (!line || !commitHash || !authorName || !authorTime) return std::nullopt;
    return GitBlameLineDto{*line, *commitHash, *authorName, *authorTime};
}

std::optional<GitStashRestoreDto> decodeGitStashRestoreValue(const JsonValue& value) {
    if (!value.isObject()) return std::nullopt;
    const auto stashReference = requiredString(value, "stashReference");
    const auto conflictedPaths = stringArray(value, "conflictedPaths");
    if (!stashReference || !conflictedPaths) return std::nullopt;
    return GitStashRestoreDto{*stashReference, *conflictedPaths};
}

const JsonValue* responseObjectData(const CoreEnvelope& envelope) {
    if (!envelope.ok || !envelope.hasData || !envelope.data.isObject()) return nullptr;
    return &envelope.data;
}

} // namespace

CoreResult<CoreEnvelope> decodeCoreEnvelope(const CoreResponse& response) {
    return decodeCoreEnvelope(response.json);
}

CoreResult<CoreEnvelope> decodeCoreEnvelope(std::string_view json) {
    const auto parsed = parseJson(json);
    if (!parsed.succeeded()) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::ParseFailed, "Core response is not valid JSON", parsed.error));
    }
    if (!parsed.value->isObject()) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::ParseFailed, "Core response envelope is not a JSON object"));
    }
    const auto& object = *parsed.value;
    const auto* okValue = objectValue(object, "ok");
    if (okValue == nullptr || okValue->asBool() == nullptr) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::ParseFailed, "Core response envelope has no boolean ok field"));
    }

    CoreEnvelope result;
    result.ok = *okValue->asBool();
    const auto* idValue = objectValue(object, "id");
    if (idValue == nullptr) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::ParseFailed, "Core response envelope has no id field"));
    }
    if (idValue != nullptr && !idValue->isNull()) {
        if (idValue->asString() == nullptr) {
            return std::unexpected(makeCoreError(
                CoreErrorCode::ParseFailed, "Core response id is not a string or null"));
        }
        result.id = *idValue->asString();
    }
    if (const auto* data = objectValue(object, "data")) {
        result.hasData = true;
        result.data = *data;
    }
    if (const auto* error = objectValue(object, "error")) {
        if (!error->isObject()) {
            return std::unexpected(makeCoreError(
                CoreErrorCode::ParseFailed, "Core response error is not a JSON object"));
        }
        const auto code = requiredString(*error, "code");
        const auto message = requiredString(*error, "message");
        if (!code || !message) {
            return std::unexpected(makeCoreError(
                CoreErrorCode::ParseFailed, "Core response error has invalid code or message"));
        }
        result.hasError = true;
        result.error.code = errorCode(*code);
        result.error.message = *message;
        result.error.details = optionalString(*error, "details");
    }
    if (result.ok && result.hasError) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::ParseFailed, "Successful Core response contains an error"));
    }
    if (!result.ok && !result.hasError) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::ParseFailed, "Failed Core response has no error"));
    }
    return result;
}

std::optional<WorkspaceSnapshotDto> decodeWorkspaceSnapshot(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* root = objectValue(*data, "root");
    const auto files = stringArray(*data, "files");
    if (root == nullptr || !files) return std::nullopt;
    const auto decodedRoot = decodeNode(*root);
    if (!decodedRoot) return std::nullopt;
    return WorkspaceSnapshotDto{*decodedRoot, *files};
}

std::optional<CorePingDto> decodeCorePing(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto protocolVersion = requiredUInt(*data, "protocolVersion");
    const auto coreVersion = requiredString(*data, "coreVersion");
    if (!protocolVersion || !coreVersion) return std::nullopt;
    return CorePingDto{*protocolVersion, *coreVersion};
}

std::optional<SearchResponseDto> decodeSearchResponse(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* matches = objectValue(*data, "matches");
    if (matches == nullptr || matches->asArray() == nullptr) return std::nullopt;
    SearchResponseDto result;
    result.matches.reserve(matches->asArray()->size());
    for (const auto& value : *matches->asArray()) {
        const auto kind = requiredString(value, "kind");
        const auto path = requiredString(value, "path");
        const auto preview = requiredString(value, "preview");
        const auto* line = objectValue(value, "line");
        if (!kind || !path || !preview || line == nullptr) return std::nullopt;
        SearchMatchDto match{*kind, *path, line->isNull() ? std::nullopt : line->asUInt(), *preview,
                             optionalString(value, "symbolName")};
        if (!line->isNull() && !match.line) return std::nullopt;
        result.matches.push_back(std::move(match));
    }
    return result;
}

std::optional<ReplacementPreviewDto> decodeReplacementPreview(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto files = objectArray(*data, "files");
    if (!files) return std::nullopt;
    ReplacementPreviewDto result;
    result.files.reserve(files->size());
    for (const auto* file : *files) {
        const auto path = requiredString(*file, "path");
        const auto matches = objectArray(*file, "matches");
        const auto replacementText = requiredString(*file, "replacementText");
        if (!path || !matches || !replacementText) return std::nullopt;
        ReplacementFileDto decodedFile{*path, {}, *replacementText};
        decodedFile.matches.reserve(matches->size());
        for (const auto* match : *matches) {
            const auto line = requiredUInt(*match, "line");
            const auto before = requiredString(*match, "before");
            const auto after = requiredString(*match, "after");
            const auto count = requiredUInt(*match, "occurrenceCount");
            if (!line || !before || !after || !count) return std::nullopt;
            decodedFile.matches.push_back({*line, *before, *after, *count});
        }
        result.files.push_back(std::move(decodedFile));
    }
    return result;
}

std::optional<FileReadDto> decodeFileRead(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto path = requiredString(*data, "path");
    const auto text = requiredString(*data, "text");
    const auto version = requiredString(*data, "version");
    const auto lineEnding = requiredString(*data, "lineEnding");
    const auto hasUtf8Bom = requiredBool(*data, "hasUtf8Bom");
    if (!path || !text || !version || !lineEnding || !hasUtf8Bom) return std::nullopt;
    if (*lineEnding != "lf" && *lineEnding != "crlf") return std::nullopt;
    return FileReadDto{*path, *text, *version, *lineEnding, *hasUtf8Bom};
}

std::optional<FileWriteDto> decodeFileWrite(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto path = requiredString(*data, "path");
    const auto bytes = requiredUInt(*data, "bytesWritten");
    const auto newVersion = requiredString(*data, "newVersion");
    if (!path || !bytes || !newVersion) return std::nullopt;
    return FileWriteDto{*path, *bytes, *newVersion};
}

std::optional<HistoryRecordDto> decodeHistoryRecord(const CoreEnvelope& envelope) {
    if (!envelope.ok || !envelope.hasData) return std::nullopt;
    if (envelope.data.isNull()) return HistoryRecordDto{std::nullopt};
    const auto decoded = decodeHistoryEntry(envelope.data);
    return decoded ? std::optional<HistoryRecordDto>(HistoryRecordDto{*decoded}) : std::nullopt;
}

std::optional<HistoryEntriesDto> decodeHistoryEntries(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto entries = objectArray(*data, "entries");
    if (!entries) return std::nullopt;
    HistoryEntriesDto result;
    result.entries.reserve(entries->size());
    for (const auto* entry : *entries) {
        const auto decoded = decodeHistoryEntry(*entry);
        if (!decoded) return std::nullopt;
        result.entries.push_back(*decoded);
    }
    return result;
}

std::optional<HistoryContentDto> decodeHistoryContent(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto text = requiredString(*data, "text");
    return text ? std::optional<HistoryContentDto>(HistoryContentDto{*text}) : std::nullopt;
}

std::optional<HistoryRelocateDto> decodeHistoryRelocate(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto relocated = requiredBool(*data, "relocated");
    return relocated ? std::optional<HistoryRelocateDto>(HistoryRelocateDto{*relocated}) : std::nullopt;
}

std::optional<ShelfCreateDto> decodeShelfCreate(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto shelf = decodeShelfSummary(*data);
    return shelf ? std::optional<ShelfCreateDto>(ShelfCreateDto{*shelf}) : std::nullopt;
}

std::optional<ShelfListDto> decodeShelfList(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto shelves = objectArray(*data, "shelves");
    if (!shelves) return std::nullopt;
    ShelfListDto result;
    result.shelves.reserve(shelves->size());
    for (const auto* shelf : *shelves) {
        const auto decoded = decodeShelfSummary(*shelf);
        if (!decoded) return std::nullopt;
        result.shelves.push_back(*decoded);
    }
    return result;
}

std::optional<ShelfRestoreDto> decodeShelfRestore(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto id = requiredString(*data, "id");
    const auto stagedPatch = requiredString(*data, "stagedPatch");
    const auto workingTreePatch = requiredString(*data, "workingTreePatch");
    if (!id || !stagedPatch || !workingTreePatch) return std::nullopt;
    return ShelfRestoreDto{*id, *stagedPatch, *workingTreePatch};
}

std::optional<ShelfDeleteDto> decodeShelfDelete(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto deleted = requiredBool(*data, "deleted");
    return deleted ? std::optional<ShelfDeleteDto>(ShelfDeleteDto{*deleted}) : std::nullopt;
}

std::optional<MavenScanResultDto> decodeMavenScan(const CoreEnvelope& envelope) {
    if (!envelope.ok || !envelope.hasData) return std::nullopt;
    if (envelope.data.isNull()) return MavenScanResultDto{std::nullopt};
    const auto groupId = objectValue(envelope.data, "groupId");
    const auto artifactId = requiredString(envelope.data, "artifactId");
    const auto version = objectValue(envelope.data, "version");
    const auto packaging = requiredString(envelope.data, "packaging");
    const auto modules = objectArray(envelope.data, "modules");
    const auto profiles = objectArray(envelope.data, "profiles");
    const auto wrapper = requiredBool(envelope.data, "hasWrapper");
    if (groupId == nullptr || !artifactId || version == nullptr || !packaging ||
        !modules || !profiles || !wrapper) return std::nullopt;
    const auto decodedGroupId = groupId->isNull()
        ? std::optional<std::string>{} : optionalString(envelope.data, "groupId");
    const auto decodedVersion = version->isNull()
        ? std::optional<std::string>{} : optionalString(envelope.data, "version");
    if ((!groupId->isNull() && !decodedGroupId) || (!version->isNull() && !decodedVersion)) {
        return std::nullopt;
    }
    MavenScanDto result{decodedGroupId, *artifactId, decodedVersion, *packaging, {}, {}, *wrapper};
    result.modules.reserve(modules->size());
    for (const auto* module : *modules) {
        const auto decoded = decodeMavenModule(*module);
        if (!decoded) return std::nullopt;
        result.modules.push_back(*decoded);
    }
    result.profiles.reserve(profiles->size());
    for (const auto* profile : *profiles) {
        const auto id = requiredString(*profile, "id");
        const auto active = requiredBool(*profile, "isActiveByDefault");
        if (!id || !active) return std::nullopt;
        result.profiles.push_back({*id, *active});
    }
    return MavenScanResultDto{std::move(result)};
}

std::optional<MavenDiagnosticsDto> decodeMavenDiagnostics(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto issues = objectArray(*data, "issues");
    if (!issues) return std::nullopt;
    MavenDiagnosticsDto result;
    result.issues.reserve(issues->size());
    for (const auto* issue : *issues) {
        const auto path = requiredString(*issue, "path");
        const auto line = requiredUInt(*issue, "line");
        const auto column = objectValue(*issue, "column");
        const auto severity = requiredString(*issue, "severity");
        const auto message = requiredString(*issue, "message");
        if (!path || !line || column == nullptr || !severity || !message) return std::nullopt;
        const auto decodedColumn = column->isNull()
            ? std::optional<std::uint64_t>{} : column->asUInt();
        if (!column->isNull() && !decodedColumn) return std::nullopt;
        result.issues.push_back({*path, *line, decodedColumn, *severity, *message});
    }
    return result;
}

std::optional<JavaRunConfigurationsDto> decodeJavaRunConfigurations(
    const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto mainClasses = objectArray(*data, "mainClasses");
    const auto configurations = objectArray(*data, "configurations");
    if (!mainClasses || !configurations) return std::nullopt;
    JavaRunConfigurationsDto result;
    result.mainClasses.reserve(mainClasses->size());
    for (const auto* value : *mainClasses) {
        const auto decoded = decodeJavaMainClass(*value);
        if (!decoded) return std::nullopt;
        result.mainClasses.push_back(*decoded);
    }
    result.configurations.reserve(configurations->size());
    for (const auto* value : *configurations) {
        const auto decoded = decodeJavaRunConfiguration(*value);
        if (!decoded) return std::nullopt;
        result.configurations.push_back(*decoded);
    }
    return result;
}

std::optional<JavaCodeVisionDto> decodeJavaCodeVision(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto hints = objectArray(*data, "hints");
    if (!hints) return std::nullopt;
    JavaCodeVisionDto result;
    result.hints.reserve(hints->size());
    for (const auto* value : *hints) {
        const auto line = requiredUInt(*value, "line");
        const auto column = requiredUInt(*value, "utf16Column");
        const auto symbol = requiredString(*value, "symbol");
        const auto count = requiredUInt(*value, "usageCount");
        if (!line || !column || !symbol || !count) return std::nullopt;
        result.hints.push_back({*line, *column, *symbol, *count});
    }
    return result;
}

std::optional<JavaClassNameDto> decodeJavaClassName(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto className = requiredString(*data, "className");
    return className ? std::optional<JavaClassNameDto>(JavaClassNameDto{*className}) : std::nullopt;
}

std::optional<JavaSourceDefinitionResultDto> decodeJavaSourceDefinition(
    const CoreEnvelope& envelope) {
    if (!envelope.ok || !envelope.hasData) return std::nullopt;
    if (envelope.data.isNull()) return JavaSourceDefinitionResultDto{std::nullopt};
    const auto line = requiredUInt(envelope.data, "line");
    const auto column = requiredUInt(envelope.data, "utf16Column");
    if (!line || !column) return std::nullopt;
    return JavaSourceDefinitionResultDto{JavaSourceDefinitionDto{*line, *column}};
}

std::optional<JavaServerPortDto> decodeJavaServerPort(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto port = objectValue(*data, "port");
    if (port == nullptr) return std::nullopt;
    const auto decoded = port->isNull() ? std::optional<std::uint64_t>{} : port->asUInt();
    if (!port->isNull() && !decoded) return std::nullopt;
    return JavaServerPortDto{decoded};
}

std::optional<JavaStructureDto> decodeJavaStructure(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto folds = objectArray(*data, "foldRegions");
    const auto markers = objectArray(*data, "implementationMarkers");
    const auto inlays = objectArray(*data, "inlayHints");
    if (!folds || !markers || !inlays) return std::nullopt;
    JavaStructureDto result;
    result.foldRegions.reserve(folds->size());
    for (const auto* value : *folds) {
        const auto decoded = decodeJavaFoldRegion(*value);
        if (!decoded) return std::nullopt;
        result.foldRegions.push_back(*decoded);
    }
    result.implementationMarkers.reserve(markers->size());
    for (const auto* value : *markers) {
        const auto decoded = decodeJavaImplementationMarker(*value);
        if (!decoded) return std::nullopt;
        result.implementationMarkers.push_back(*decoded);
    }
    result.inlayHints.reserve(inlays->size());
    for (const auto* value : *inlays) {
        const auto decoded = decodeJavaInlayHint(*value);
        if (!decoded) return std::nullopt;
        result.inlayHints.push_back(*decoded);
    }
    return result;
}

std::optional<GitDiffDto> decodeGitDiff(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto patch = requiredString(*data, "patch");
    const auto* rows = objectValue(*data, "rows");
    const auto* hunks = objectValue(*data, "hunks");
    if (!patch || rows == nullptr || rows->asArray() == nullptr ||
        hunks == nullptr || hunks->asArray() == nullptr) return std::nullopt;

    GitDiffDto result{*patch, {}, {}};
    result.rows.reserve(rows->asArray()->size());
    for (const auto& value : *rows->asArray()) {
        const auto* oldLine = objectValue(value, "oldLine");
        const auto* newLine = objectValue(value, "newLine");
        const auto kind = requiredString(value, "kind");
        const auto hunkId = objectValue(value, "hunkId");
        if (oldLine == nullptr || newLine == nullptr || !kind || hunkId == nullptr) return std::nullopt;
        const auto* left = objectValue(value, "left");
        const auto* right = objectValue(value, "right");
        GitDiffRowDto row{
            oldLine->isNull() ? std::nullopt : oldLine->asUInt(),
            newLine->isNull() ? std::nullopt : newLine->asUInt(),
            left == nullptr || left->isNull() ? std::nullopt : optionalString(value, "left"),
            right != nullptr,
            right == nullptr || right->isNull() ? std::nullopt : optionalString(value, "right"),
            *kind,
            hunkId->isNull() ? std::nullopt : optionalString(value, "hunkId"),
        };
        if ((!oldLine->isNull() && !row.oldLine) || (!newLine->isNull() && !row.newLine) ||
            (left != nullptr && !left->isNull() && !row.left) ||
            (right != nullptr && !right->isNull() && !row.right) ||
            (!hunkId->isNull() && !row.hunkId)) return std::nullopt;
        result.rows.push_back(std::move(row));
    }
    for (const auto& value : *hunks->asArray()) {
        const auto id = requiredString(value, "id");
        const auto header = requiredString(value, "header");
        const auto hunkPatch = requiredString(value, "patch");
        if (!id || !header || !hunkPatch) return std::nullopt;
        result.hunks.push_back({*id, *header, *hunkPatch});
    }
    return result;
}

std::optional<GitShelfPatchesDto> decodeGitShelfPatches(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto stagedPatch = requiredString(*data, "stagedPatch");
    const auto workingTreePatch = requiredString(*data, "workingTreePatch");
    if (!stagedPatch || !workingTreePatch) return std::nullopt;
    return GitShelfPatchesDto{*stagedPatch, *workingTreePatch};
}

std::optional<GitStatusDto> decodeGitStatus(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* repositoryRoot = objectValue(*data, "repositoryRoot");
    const auto* branch = objectValue(*data, "branch");
    const auto* changes = objectValue(*data, "changes");
    if (repositoryRoot == nullptr || branch == nullptr || changes == nullptr ||
        changes->asArray() == nullptr) return std::nullopt;
    GitStatusDto result{
        repositoryRoot->isNull() ? std::nullopt : optionalString(*data, "repositoryRoot"),
        branch->isNull() ? std::nullopt : optionalString(*data, "branch"),
        {},
    };
    if ((!repositoryRoot->isNull() && !result.repositoryRoot) ||
        (!branch->isNull() && !result.branch)) return std::nullopt;
    result.changes.reserve(changes->asArray()->size());
    for (const auto& value : *changes->asArray()) {
        const auto path = requiredString(value, "path");
        const auto status = requiredString(value, "status");
        const auto staged = requiredBool(value, "staged");
        const auto worktree = requiredBool(value, "worktree");
        const auto untracked = requiredBool(value, "untracked");
        if (!path || !status || !staged || !worktree || !untracked) return std::nullopt;
        result.changes.push_back({*path, optionalString(value, "originalPath"), *status,
                                  *staged, *worktree, *untracked});
    }
    return result;
}

std::optional<GitCommandDto> decodeGitCommand(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto output = requiredString(*data, "output");
    const auto exitCode = requiredInt(*data, "exitCode");
    if (!output || !exitCode || *exitCode < std::numeric_limits<std::int32_t>::min() ||
        *exitCode > std::numeric_limits<std::int32_t>::max()) return std::nullopt;
    std::optional<GitStashRestoreDto> stashRestore;
    const auto* stashRestoreValue = objectValue(*data, "stashRestore");
    if (stashRestoreValue != nullptr) {
        stashRestore = decodeGitStashRestoreValue(*stashRestoreValue);
        if (!stashRestore) return std::nullopt;
    }
    return GitCommandDto{*output, static_cast<std::int32_t>(*exitCode), stashRestore};
}

std::optional<GitCheckoutPreflightDto> decodeGitCheckoutPreflight(
    const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto blockingPaths = stringArray(*data, "blockingPaths");
    return blockingPaths
        ? std::optional<GitCheckoutPreflightDto>(GitCheckoutPreflightDto{*blockingPaths})
        : std::nullopt;
}

std::optional<GitPullPreflightDto> decodeGitPullPreflight(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* upstream = objectValue(*data, "upstream");
    const auto ahead = requiredUInt(*data, "ahead");
    const auto behind = requiredUInt(*data, "behind");
    const auto diverged = requiredBool(*data, "diverged");
    const auto hasLocalChanges = requiredBool(*data, "hasLocalChanges");
    if (upstream == nullptr || !ahead || !behind || !diverged || !hasLocalChanges) {
        return std::nullopt;
    }
    const auto decodedUpstream = upstream->isNull()
        ? std::optional<std::string>{} : optionalString(*data, "upstream");
    if (!upstream->isNull() && !decodedUpstream) return std::nullopt;
    return GitPullPreflightDto{
        decodedUpstream, *ahead, *behind, *diverged, *hasLocalChanges,
    };
}

std::optional<GitIntegrationPreflightDto> decodeGitIntegrationPreflight(
    const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto blockingPaths = stringArray(*data, "blockingPaths");
    const auto blocksEntirely = requiredBool(*data, "blocksEntirely");
    if (!blockingPaths || !blocksEntirely) return std::nullopt;
    return GitIntegrationPreflightDto{*blockingPaths, *blocksEntirely};
}

std::optional<GitConflictMarkersDto> decodeGitConflictMarkers(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto paths = stringArray(*data, "paths");
    return paths ? std::optional<GitConflictMarkersDto>(GitConflictMarkersDto{*paths})
                 : std::nullopt;
}

std::optional<GitOperationStateDto> decodeGitOperationState(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto kind = requiredString(*data, "kind");
    const auto* reference = objectValue(*data, "reference");
    const auto* step = objectValue(*data, "step");
    const auto* total = objectValue(*data, "total");
    const auto conflictedPaths = stringArray(*data, "conflictedPaths");
    if (!kind || reference == nullptr || step == nullptr || total == nullptr ||
        !conflictedPaths) return std::nullopt;

    const auto decodedReference = reference->isNull()
        ? std::optional<std::string>{} : optionalString(*data, "reference");
    const auto decodedStep = step->isNull()
        ? std::optional<std::uint64_t>{} : step->asUInt();
    const auto decodedTotal = total->isNull()
        ? std::optional<std::uint64_t>{} : total->asUInt();
    if ((!reference->isNull() && !decodedReference) || (!step->isNull() && !decodedStep) ||
        (!total->isNull() && !decodedTotal)) return std::nullopt;
    return GitOperationStateDto{
        *kind, decodedReference, decodedStep, decodedTotal, *conflictedPaths,
    };
}

std::optional<GitHistoryDto> decodeGitHistory(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* references = objectValue(*data, "references");
    const auto* commits = objectValue(*data, "commits");
    const auto hasMore = requiredBool(*data, "hasMore");
    if (references == nullptr || commits == nullptr || !hasMore ||
        references->asArray() == nullptr || commits->asArray() == nullptr) return std::nullopt;
    GitHistoryDto result{{}, {}, *hasMore};
    result.references.reserve(references->asArray()->size());
    for (const auto& value : *references->asArray()) {
        const auto fullName = requiredString(value, "fullName");
        const auto shortName = requiredString(value, "shortName");
        const auto kind = requiredString(value, "kind");
        const auto current = requiredBool(value, "isCurrent");
        const auto upstream = objectValue(value, "upstreamShortName");
        if (!fullName || !shortName || !kind || !current || upstream == nullptr) return std::nullopt;
        const auto upstreamValue = upstream->isNull()
            ? std::optional<std::string>{} : optionalString(value, "upstreamShortName");
        if (!upstream->isNull() && !upstreamValue) return std::nullopt;
        result.references.push_back({*fullName, *shortName, *kind, *current, upstreamValue});
    }
    result.commits.reserve(commits->asArray()->size());
    for (const auto& value : *commits->asArray()) {
        const auto decoded = decodeGitCommitValue(value);
        if (!decoded) return std::nullopt;
        result.commits.push_back(*decoded);
    }
    return result;
}

std::optional<GitCommitLookupDto> decodeGitCommit(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* commit = objectValue(*data, "commit");
    if (commit == nullptr) return std::nullopt;
    const auto decoded = decodeGitCommitValue(*commit);
    return decoded ? std::optional<GitCommitLookupDto>(GitCommitLookupDto{*decoded}) : std::nullopt;
}

std::optional<GitFilesResponseDto> decodeGitCommitFiles(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto files = objectArray(*data, "files");
    if (!files) return std::nullopt;
    GitFilesResponseDto result;
    result.files.reserve(files->size());
    for (const auto* file : *files) {
        const auto decoded = decodeGitFileValue(*file);
        if (!decoded) return std::nullopt;
        result.files.push_back(*decoded);
    }
    return result;
}

std::optional<GitComparisonDto> decodeGitComparison(const CoreEnvelope& envelope) {
    const auto decoded = decodeGitCommitFiles(envelope);
    return decoded ? std::optional<GitComparisonDto>(GitComparisonDto{decoded->files}) : std::nullopt;
}

std::optional<GitStashesResponseDto> decodeGitStashesResponse(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto stashes = objectArray(*data, "stashes");
    if (!stashes) return std::nullopt;
    GitStashesResponseDto result;
    result.stashes.reserve(stashes->size());
    for (const auto* stash : *stashes) {
        const auto decoded = decodeGitStashValue(*stash);
        if (!decoded) return std::nullopt;
        result.stashes.push_back(*decoded);
    }
    return result;
}

std::optional<GitBlameResponseDto> decodeGitBlameResponse(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto lines = objectArray(*data, "lines");
    if (!lines) return std::nullopt;
    GitBlameResponseDto result;
    result.lines.reserve(lines->size());
    for (const auto* line : *lines) {
        const auto decoded = decodeGitBlameLineValue(*line);
        if (!decoded) return std::nullopt;
        result.lines.push_back(*decoded);
    }
    return result;
}

std::optional<std::vector<GitFileDto>> decodeGitFiles(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* files = objectValue(*data, "files");
    if (files == nullptr || files->asArray() == nullptr) return std::nullopt;
    std::vector<GitFileDto> result;
    result.reserve(files->asArray()->size());
    for (const auto& value : *files->asArray()) {
        const auto decoded = decodeGitFileValue(value);
        if (!decoded) return std::nullopt;
        result.push_back(*decoded);
    }
    return result;
}

std::optional<std::vector<GitStashDto>> decodeGitStashes(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* stashes = objectValue(*data, "stashes");
    if (stashes == nullptr || stashes->asArray() == nullptr) return std::nullopt;
    std::vector<GitStashDto> result;
    result.reserve(stashes->asArray()->size());
    for (const auto& value : *stashes->asArray()) {
        const auto decoded = decodeGitStashValue(value);
        if (!decoded) return std::nullopt;
        result.push_back(*decoded);
    }
    return result;
}

std::optional<std::vector<GitBlameLineDto>> decodeGitBlame(const CoreEnvelope& envelope) {
    const auto* data = responseObjectData(envelope);
    if (data == nullptr) return std::nullopt;
    const auto* lines = objectValue(*data, "lines");
    if (lines == nullptr || lines->asArray() == nullptr) return std::nullopt;
    std::vector<GitBlameLineDto> result;
    result.reserve(lines->asArray()->size());
    for (const auto& value : *lines->asArray()) {
        const auto decoded = decodeGitBlameLineValue(value);
        if (!decoded) return std::nullopt;
        result.push_back(*decoded);
    }
    return result;
}

} // namespace lithe::windows
