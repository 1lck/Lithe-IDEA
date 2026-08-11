#include "dirty_documents_port.h"
#include "git_watcher_freeze.h"
#include "git_workflow_ui.h"
#include "shelve_service.h"

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

namespace {

using lithe::windows::DirectoryChangeSource;
using lithe::windows::FileMetadata;
using lithe::windows::FileStorage;
using lithe::windows::GitChangeDto;
using lithe::windows::GitStatusDto;
using lithe::windows::app::FakeDirtyDocumentsPort;
using lithe::windows::app::GitOperationState;
using lithe::windows::app::GitShelfEntry;
using lithe::windows::app::GitStashRestoreConflictRequest;
using lithe::windows::app::GitWatcherFreezeController;
using lithe::windows::app::ShelveService;
using lithe::windows::app::commitBlockedByConflicts;
using lithe::windows::app::filterChangesByConflictPaths;
using lithe::windows::app::makeOperationBarModel;
using lithe::windows::app::makeStashRestoreNoticeModel;
using lithe::windows::app::shouldShowConflictFilterEmptyState;

class MemoryFileStorage final : public FileStorage {
public:
    explicit MemoryFileStorage(std::filesystem::path root) : root_(std::move(root)) {
        std::filesystem::create_directories(root_);
    }

    std::string homeDirectory() const override { return root_.string(); }
    std::string cacheDirectory() const override { return (root_ / "cache").string(); }
    std::string applicationSupportDirectory() const override {
        return (root_ / "support").string();
    }
    std::optional<FileMetadata> metadata(const std::string& path) const override {
        std::error_code error;
        if (!std::filesystem::exists(path, error)) return std::nullopt;
        FileMetadata meta;
        meta.isRegularFile = std::filesystem::is_regular_file(path, error);
        meta.isDirectory = std::filesystem::is_directory(path, error);
        if (meta.isRegularFile) {
            meta.byteCount = static_cast<std::uint64_t>(std::filesystem::file_size(path, error));
        }
        return meta;
    }
    bool fileExists(const std::string& path) const override {
        std::error_code error;
        return std::filesystem::exists(path, error);
    }
    bool isExecutable(const std::string& path) const override {
        return fileExists(path);
    }
    std::vector<std::string> listDirectory(const std::string& path) const override {
        std::vector<std::string> names;
        std::error_code error;
        if (!std::filesystem::exists(path, error)) return names;
        for (const auto& entry : std::filesystem::directory_iterator(path, error)) {
            names.push_back(entry.path().filename().string());
        }
        return names;
    }
    std::optional<std::vector<std::uint8_t>> readData(const std::string& path,
                                                      std::string& error) const override {
        std::error_code ec;
        if (!std::filesystem::exists(path, ec)) {
            error = "missing";
            return std::nullopt;
        }
        const auto size = static_cast<std::size_t>(std::filesystem::file_size(path, ec));
        std::vector<std::uint8_t> bytes(size);
        FILE* file = nullptr;
#ifdef _WIN32
        fopen_s(&file, path.c_str(), "rb");
#else
        file = std::fopen(path.c_str(), "rb");
#endif
        if (file == nullptr) {
            error = "open failed";
            return std::nullopt;
        }
        if (size > 0) {
            const auto read = std::fread(bytes.data(), 1, size, file);
            std::fclose(file);
            if (read != size) {
                error = "read failed";
                return std::nullopt;
            }
        } else {
            std::fclose(file);
        }
        return bytes;
    }
    bool writeData(const std::string& path,
                   const std::vector<std::uint8_t>& data,
                   std::string& error) override {
        FILE* file = nullptr;
#ifdef _WIN32
        fopen_s(&file, path.c_str(), "wb");
#else
        file = std::fopen(path.c_str(), "wb");
#endif
        if (file == nullptr) {
            error = "open failed";
            return false;
        }
        if (!data.empty()) {
            const auto written = std::fwrite(data.data(), 1, data.size(), file);
            std::fclose(file);
            if (written != data.size()) {
                error = "write failed";
                return false;
            }
        } else {
            std::fclose(file);
        }
        return true;
    }
    bool createDirectory(const std::string& path,
                         bool withIntermediateDirectories,
                         std::string& error) override {
        std::error_code ec;
        if (withIntermediateDirectories) {
            std::filesystem::create_directories(path, ec);
        } else {
            std::filesystem::create_directory(path, ec);
        }
        if (ec) {
            error = ec.message();
            return false;
        }
        return true;
    }
    bool removeItem(const std::string& path, std::string& error) override {
        std::error_code ec;
        std::filesystem::remove_all(path, ec);
        if (ec) {
            error = ec.message();
            return false;
        }
        return true;
    }
    bool moveItem(const std::string& source,
                  const std::string& destination,
                  std::string& error) override {
        std::error_code ec;
        std::filesystem::rename(source, destination, ec);
        if (ec) {
            error = ec.message();
            return false;
        }
        return true;
    }

private:
    std::filesystem::path root_;
};

void testWatcherFreezeNestedAndFailurePath() {
    GitWatcherFreezeController freeze;
    int flushCount = 0;
    std::vector<DirectoryChangeSource::Change> flushed;
    freeze.setFlushHandler([&](std::vector<DirectoryChangeSource::Change> changes) {
        ++flushCount;
        flushed = std::move(changes);
    });

    freeze.begin();
    freeze.begin();
    freeze.noteChanges({{"a.txt", DirectoryChangeSource::ChangeKind::Modified}});
    assert(freeze.isFrozen());
    assert(freeze.end() == false);
    assert(flushCount == 0);
    freeze.noteChanges({{"b.txt", DirectoryChangeSource::ChangeKind::Modified}});
    assert(freeze.end() == true);
    assert(flushCount == 1);
    assert(flushed.size() == 2);
    assert(!freeze.isFrozen());

    // Failure-style path: begin then end without changes still flushes once.
    freeze.begin();
    assert(freeze.end() == true);
    assert(flushCount == 2);
}

void testOperationBarAndConflictFilter() {
    GitOperationState state;
    state.kind = "rebase";
    state.step = 2;
    state.total = 5;
    state.conflictedPaths = {"src/A.java", "src/B.java"};
    auto bar = makeOperationBarModel(state, false, false);
    assert(bar.visible);
    assert(bar.canContinue == false);
    assert(bar.canAbort);
    assert(bar.canSkip);
    assert(bar.progress == "2/5");

    state.conflictedPaths.clear();
    bar = makeOperationBarModel(state, true, true);
    assert(bar.canContinue == false);
    assert(bar.canAbort == false);
    assert(bar.canSkip == false);
    assert(bar.filterActive);

    GitStashRestoreConflictRequest pending;
    pending.stashReference = "stash@{0}";
    pending.conflictedPaths = {"x.txt"};
    pending.operationTitle = "stash restore";
    auto notice = makeStashRestoreNoticeModel(pending, true);
    assert(notice.visible);
    assert(notice.stashReference == "stash@{0}");
    notice = makeStashRestoreNoticeModel(pending, false);
    assert(!notice.visible);

    GitStatusDto status;
    GitChangeDto modified;
    modified.path = "a.txt";
    modified.status = "M";
    modified.staged = true;
    modified.worktree = true;
    GitChangeDto unmerged;
    unmerged.path = "b.txt";
    unmerged.status = "U";
    unmerged.worktree = true;
    status.changes.push_back(modified);
    status.changes.push_back(unmerged);
    assert(commitBlockedByConflicts(status, {}));
    status.changes[1].status = "M";
    assert(!commitBlockedByConflicts(status, {}));
    assert(commitBlockedByConflicts(status, {"a.txt"}));

    const auto filtered = filterChangesByConflictPaths(status.changes, {"b.txt"});
    assert(filtered.size() == 1);
    assert(filtered[0] == "b.txt");
    assert(shouldShowConflictFilterEmptyState(true, 2, 0));
    assert(!shouldShowConflictFilterEmptyState(true, 2, 1));
    assert(!shouldShowConflictFilterEmptyState(false, 2, 0));
    assert(!shouldShowConflictFilterEmptyState(true, 0, 0));
}

void testShelfIsolationAndKeepOnDisk() {
    const auto root = std::filesystem::temp_directory_path() / "lithe-shelf-test";
    std::filesystem::remove_all(root);
    MemoryFileStorage storage(root);
    ShelveService service(storage);

    const auto repoA = (root / "repo-a").string();
    const auto repoB = (root / "repo-b").string();
    auto saved = service.save(repoA, "wip", {"a.txt"}, "staged", "working");
    assert(saved.has_value());
    assert(service.entries(repoA).size() == 1);
    assert(service.entries(repoB).empty());

    auto other = service.save(repoB, "other", {"b.txt"}, "s2", "w2");
    assert(other.has_value());
    assert(service.entries(repoA).size() == 1);
    assert(service.entries(repoB).size() == 1);
    assert(service.entries(repoA)[0].stagedPatch == "staged");
    assert(service.entries(repoA)[0].workingPatch == "working");

    // Keep on "failure": entry remains until explicit remove.
    assert(service.entries(repoA).size() == 1);
    assert(service.remove(repoA, *saved));
    assert(service.entries(repoA).empty());
    assert(service.entries(repoB).size() == 1);

    std::filesystem::remove_all(root);
}

void testFakeDirtyDocumentsPort() {
    FakeDirtyDocumentsPort port;
    assert(port.dirtyRelativePaths().empty());
    port.setDirtyPaths({"src/Main.java", "README.md"});
    assert(port.dirtyRelativePaths().size() == 2);
    port.clear();
    assert(port.dirtyRelativePaths().empty());
}

} // namespace

int main() {
    testWatcherFreezeNestedAndFailurePath();
    testOperationBarAndConflictFilter();
    testShelfIsolationAndKeepOnDisk();
    testFakeDirtyDocumentsPort();
    return 0;
}
