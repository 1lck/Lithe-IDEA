#include "shelve_service.h"

#include "json_value.h"

#include <algorithm>
#include <chrono>
#include <random>
#include <sstream>

namespace lithe::windows::app {
namespace {

constexpr int kFormatVersion = 1;

std::string joinPath(std::string left, const std::string& right) {
    if (left.empty()) return right;
    const char last = left.back();
    if (last != '\\' && last != '/') left.push_back('\\');
    left += right;
    return left;
}

std::string makeShelfId() {
    static std::mt19937_64 rng{std::random_device{}()};
    std::uniform_int_distribution<std::uint64_t> dist;
    const auto now = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
    std::ostringstream out;
    out << std::hex << now << '-' << dist(rng);
    return out.str();
}

std::optional<GitShelfEntry> decodeEntry(const JsonValue& value) {
    if (!value.isObject()) return std::nullopt;
    const auto* version = objectValue(value, "formatVersion");
    if (version == nullptr || !version->asInt() || *version->asInt() != kFormatVersion) {
        return std::nullopt;
    }
    const auto* id = objectValue(value, "id");
    const auto* message = objectValue(value, "message");
    const auto* createdAt = objectValue(value, "createdAt");
    const auto* paths = objectValue(value, "paths");
    const auto* stagedPatch = objectValue(value, "stagedPatch");
    const auto* workingPatch = objectValue(value, "workingPatch");
    if (id == nullptr || id->asString() == nullptr ||
        message == nullptr || message->asString() == nullptr ||
        createdAt == nullptr || !createdAt->asInt() ||
        paths == nullptr || paths->asArray() == nullptr ||
        stagedPatch == nullptr || stagedPatch->asString() == nullptr ||
        workingPatch == nullptr || workingPatch->asString() == nullptr) {
        return std::nullopt;
    }
    GitShelfEntry entry;
    entry.id = *id->asString();
    entry.message = *message->asString();
    entry.createdAt = *createdAt->asInt();
    entry.stagedPatch = *stagedPatch->asString();
    entry.workingPatch = *workingPatch->asString();
    entry.paths.reserve(paths->asArray()->size());
    for (const auto& path : *paths->asArray()) {
        if (path.asString() == nullptr) return std::nullopt;
        entry.paths.push_back(*path.asString());
    }
    return entry;
}

} // namespace

ShelveService::ShelveService(FileStorage& storage) : storage_(storage) {}

std::string ShelveService::stableIdentifier(const std::string& repositoryRoot) {
    std::uint64_t hash = 14'695'981'039'346'656'037ULL;
    for (unsigned char byte : repositoryRoot) {
        hash ^= byte;
        hash *= 1'099'511'628'211ULL;
    }
    std::ostringstream out;
    out << std::hex << hash;
    return out.str();
}

std::string ShelveService::directoryPath(const std::string& repositoryRoot) const {
    // Win32FileStorage::applicationSupportDirectory already ends with "Lithe".
    return joinPath(
        joinPath(storage_.applicationSupportDirectory(), "Shelves"),
        stableIdentifier(repositoryRoot));
}

std::string ShelveService::filePath(const std::string& repositoryRoot,
                                    const std::string& id) const {
    return joinPath(directoryPath(repositoryRoot), id + ".json");
}

std::vector<GitShelfEntry> ShelveService::entries(const std::string& repositoryRoot) const {
    std::vector<GitShelfEntry> result;
    const auto directory = directoryPath(repositoryRoot);
    for (const auto& listed : storage_.listDirectory(directory)) {
        // Win32 listDirectory returns absolute paths; tests may return filenames.
        const bool absolute = listed.find(':') != std::string::npos ||
                              (!listed.empty() && (listed[0] == '/' || listed[0] == '\\'));
        const auto path = absolute ? listed : joinPath(directory, listed);
        if (path.size() < 5 || path.substr(path.size() - 5) != ".json") continue;
        std::string error;
        const auto data = storage_.readData(path, error);
        if (!data) continue;
        const std::string text(data->begin(), data->end());
        const auto parsed = parseJson(text);
        if (!parsed.succeeded() || !parsed.value) continue;
        auto entry = decodeEntry(*parsed.value);
        if (!entry) continue;
        result.push_back(std::move(*entry));
    }
    std::sort(result.begin(), result.end(),
              [](const GitShelfEntry& left, const GitShelfEntry& right) {
                  return left.createdAt > right.createdAt;
              });
    return result;
}

std::optional<GitShelfEntry> ShelveService::save(const std::string& repositoryRoot,
                                                 std::string message,
                                                 std::vector<std::string> paths,
                                                 std::string stagedPatch,
                                                 std::string workingPatch) {
    while (!message.empty() &&
           (message.front() == ' ' || message.front() == '\t')) {
        message.erase(message.begin());
    }
    while (!message.empty() &&
           (message.back() == ' ' || message.back() == '\t')) {
        message.pop_back();
    }
    if (message.empty()) message = "WIP";

    GitShelfEntry entry;
    entry.id = makeShelfId();
    entry.message = std::move(message);
    entry.createdAt = std::chrono::duration_cast<std::chrono::seconds>(
                          std::chrono::system_clock::now().time_since_epoch())
                          .count();
    entry.paths = std::move(paths);
    entry.stagedPatch = std::move(stagedPatch);
    entry.workingPatch = std::move(workingPatch);

    JsonValue::Array pathValues;
    pathValues.reserve(entry.paths.size());
    for (const auto& path : entry.paths) pathValues.emplace_back(path);

    const JsonValue document{JsonValue::Object{
        {"formatVersion", static_cast<std::int64_t>(kFormatVersion)},
        {"id", entry.id},
        {"message", entry.message},
        {"createdAt", entry.createdAt},
        {"paths", std::move(pathValues)},
        {"stagedPatch", entry.stagedPatch},
        {"workingPatch", entry.workingPatch},
    }};
    const auto encoded = serializeJson(document);
    const auto directory = directoryPath(repositoryRoot);
    std::string error;
    if (!storage_.createDirectory(directory, true, error)) return std::nullopt;
    const auto path = filePath(repositoryRoot, entry.id);
    const std::vector<std::uint8_t> bytes(encoded.begin(), encoded.end());
    if (!storage_.writeData(path, bytes, error)) return std::nullopt;
    return entry;
}

bool ShelveService::remove(const std::string& repositoryRoot, const GitShelfEntry& entry) {
    const auto path = filePath(repositoryRoot, entry.id);
    if (!storage_.fileExists(path)) return true;
    std::string error;
    return storage_.removeItem(path, error);
}

} // namespace lithe::windows::app
