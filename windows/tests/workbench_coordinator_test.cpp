#include "workbench_coordinator.h"
#include "document_feature.h"
#include "git_feature.h"
#include "history_feature.h"
#include "maven_java_feature.h"
#include "replacement_feature.h"
#include "shelf_feature.h"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

std::mutex requestMutex;
std::condition_variable requestCondition;
std::vector<std::string> requests;
bool blockNextSnapshot = false;
bool snapshotStarted = false;
bool releaseSnapshot = false;
bool blockNextFileWrite = false;
bool fileWriteStarted = false;
bool releaseFileWrite = false;

std::string requestValue(const std::string& request, const std::string& key) {
    const auto marker = "\"" + key + "\":\"";
    const auto start = request.find(marker);
    if (start == std::string::npos) return {};
    const auto valueStart = start + marker.size();
    const auto valueEnd = request.find('"', valueStart);
    return valueEnd == std::string::npos ? std::string{} : request.substr(valueStart, valueEnd - valueStart);
}

} // namespace

extern "C" {

const char* lithe_core_version(void) {
    return "coordinator-test-core";
}

char* lithe_core_execute_json(const char* request) {
    const std::string value = request == nullptr ? std::string{} : std::string(request);
    {
        std::lock_guard lock(requestMutex);
        requests.push_back(value);
    }
    const auto command = requestValue(value, "command");
    if (command == "workspace.snapshot") {
        std::unique_lock lock(requestMutex);
        if (blockNextSnapshot) {
            blockNextSnapshot = false;
            snapshotStarted = true;
            requestCondition.notify_all();
            requestCondition.wait(lock, [] { return releaseSnapshot; });
        }
    }
    if (command == "file.write") {
        std::unique_lock lock(requestMutex);
        if (blockNextFileWrite) {
            blockNextFileWrite = false;
            fileWriteStarted = true;
            requestCondition.notify_all();
            requestCondition.wait(lock, [] { return releaseFileWrite; });
        }
    }
    std::string response = command == "file.read"
        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"path\":\"src/Main.java\",\"text\":\"hello\"}}"
        : command == "file.write"
        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"path\":\"src/Main.java\",\"bytesWritten\":11}}"
        : command == "workspace.search"
        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"matches\":[]}}"
        : command == "workspace.searchEverywhere"
        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"matches\":["
          "{\"kind\":\"file\",\"path\":\"src/Main.java\",\"line\":null,\"preview\":\"src/Main.java\"},"
          "{\"kind\":\"type\",\"path\":\"src/Main.java\",\"line\":1,\"preview\":\"class Main\",\"symbolName\":\"Main\"},"
          "{\"kind\":\"content\",\"path\":\"src/Main.java\",\"line\":1,\"preview\":\"class Main\"}]}}"
        : command == "workspace.replacePreview"
            ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"files\":[]}}"
        : command == "markdown.render"
            ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"html\":\"<h1>Preview</h1>\"}}"
        : command == "git.status"
                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"repositoryRoot\":null,\"branch\":\"main\",\"changes\":[]}}"
                : command == "git.diff"
                    ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"patch\":\"@@\",\"rows\":[{\"oldLine\":1,\"newLine\":1,\"left\":\"old\",\"right\":\"new\",\"kind\":\"changed\",\"hunkId\":\"hunk-0\"}],\"hunks\":[{\"id\":\"hunk-0\",\"header\":\"@@\",\"patch\":\"@@\"}]}}"
                    : command == "git.apply"
                        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"\",\"exitCode\":0}}"
                    : command == "git.write"
                            ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"written\",\"exitCode\":0}}"
                            : command == "git.command"
                                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"command output\",\"exitCode\":0}}"
                            : command == "git.history"
                                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"references\":[],\"commits\":[{\"hash\":\"abc\",\"shortHash\":\"abc\",\"parentHashes\":[],\"authorName\":\"A\",\"authorEmail\":\"a@b\",\"date\":\"2026/08/05 12:00\",\"subject\":\"Initial\",\"decorations\":\"\"}],\"hasMore\":false}}"
                                : command == "git.commit"
                                    ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"commit\":{\"hash\":\"abc\",\"shortHash\":\"abc\",\"parentHashes\":[],\"authorName\":\"A\",\"authorEmail\":\"a@b\",\"date\":\"2026/08/05 12:00\",\"subject\":\"Initial\",\"decorations\":\"\"}}}"
                                    : command == "git.commitFiles"
                                        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"files\":[{\"status\":\"M\",\"path\":\"src/Main.java\"}]}}"
                                        : command == "git.comparison"
                                            ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"files\":[{\"status\":\"M\",\"path\":\"src/Main.java\"}]}}"
                                            : command == "git.stashes"
                                                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"stashes\":[{\"reference\":\"stash@{0}\",\"message\":\"work\",\"branch\":null,\"date\":\"2026-08-05\"}]}}"
                                                : command == "git.blame"
                                                    ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"lines\":[{\"line\":1,\"commitHash\":\"abc\",\"authorName\":\"A\",\"authorTime\":1720000000}]}}"
                                                    : command == "maven.scan"
                                                        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"groupId\":\"com.example\",\"artifactId\":\"app\",\"version\":\"1.0\",\"packaging\":\"jar\",\"modules\":[],\"profiles\":[],\"hasWrapper\":true}}"
                                                        : command == "maven.diagnostics"
                                                            ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"issues\":[{\"path\":\"src/Main.java\",\"line\":4,\"column\":null,\"severity\":\"error\",\"message\":\"bad\"}]}}"
                                                            : command == "java.runConfigurations"
                                                                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"mainClasses\":[],\"configurations\":[]}}"
                                                                : command == "java.codeVision"
                                                                    ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"hints\":[{\"line\":0,\"utf16Column\":2,\"symbol\":\"run\",\"usageCount\":1}]}}"
                                                                    : command == "java.className"
                                                                        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"className\":\"com.example.Main\"}}"
                                                                        : command == "java.sourceDefinition"
                                                                            ? "{\"id\":\"test\",\"ok\":true,\"data\":null}"
                                                                            : command == "java.serverPort"
                                                                                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"port\":8080}}"
                                                                                : command == "java.structure"
                                                                                    ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"foldRegions\":[],\"implementationMarkers\":[],\"inlayHints\":[]}}"
                        : command == "history.record"
                            ? value.find("\"content\":") == std::string::npos
                                ? "{\"id\":\"test\",\"ok\":true,\"data\":null}"
                                : "{\"id\":\"test\",\"ok\":true,\"data\":{\"id\":\"entry-1\",\"timestamp\":1720000000,\"relativePath\":\"src/Main.java\",\"reason\":\"saved\",\"contentPath\":\"src-Main.java/entry-1.snapshot\",\"byteCount\":5}}"
                            : command == "history.entries"
                                ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"entries\":[{\"id\":\"entry-1\",\"timestamp\":1720000000,\"relativePath\":\"src/Main.java\",\"reason\":\"saved\",\"contentPath\":\"src-Main.java/entry-1.snapshot\",\"byteCount\":5}]}}"
                                : command == "history.content"
                                    ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"text\":\"hello history\"}}"
                        : command == "history.relocate"
                                        ? "{\"id\":\"test\",\"ok\":true,\"data\":{\"relocated\":true}}"
                        : "{\"id\":\"test\",\"ok\":true,\"data\":{\"root\":{\"path\":\"\",\"name\":\"project\",\"isDirectory\":true,\"children\":[]},\"files\":[]}}";
    if (command == "git.write" && value.find("\"operation\":\"testFailure\"") != std::string::npos) {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"checkout failed\",\"exitCode\":7}}";
    }
    if (command == "shelf.create") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"id\":\"shelf-1\",\"workspaceRoot\":\"/tmp/project\",\"label\":\"before checkout\",\"createdAt\":1720000000000,\"stagedByteCount\":6,\"workingTreeByteCount\":7}}";
    } else if (command == "git.shelfPatches") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"stagedPatch\":\"staged\",\"workingTreePatch\":\"working\"}}";
    } else if (command == "git.shelfClean") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"\",\"exitCode\":0}}";
    } else if (command == "shelf.list") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"shelves\":[]}}";
    } else if (command == "shelf.restore") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"id\":\"shelf-1\",\"stagedPatch\":\"staged\",\"workingTreePatch\":\"working\"}}";
    } else if (command == "shelf.delete") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"deleted\":true}}";
    }
    if (command == "git.checkoutPreflight") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"blockingPaths\":[\"README.md\"]}}";
    } else if (command == "git.pullPreflight") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"upstream\":\"origin/main\",\"ahead\":1,\"behind\":2,\"diverged\":true,\"hasLocalChanges\":true}}";
    } else if (command == "git.integrationPreflight") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"blockingPaths\":[\"src/Conflict.java\"],\"blocksEntirely\":true}}";
    } else if (command == "git.conflictMarkers") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"paths\":[\"src/Conflict.java\"]}}";
    } else if (command == "git.operationState") {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"kind\":\"rebase\",\"reference\":\"main\",\"step\":2,\"total\":4,\"conflictedPaths\":[\"src/Conflict.java\"]}}";
    } else if (command == "git.write" &&
               value.find("\"operation\":\"testStashConflict\"") != std::string::npos) {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"conflicts\",\"exitCode\":1,\"stashRestore\":{\"stashReference\":\"stash@{0}\",\"conflictedPaths\":[\"src/Stash.java\"]}}}";
    } else if (command == "git.write" &&
               value.find("\"operation\":\"testDeferredRestore\"") != std::string::npos) {
        response = "{\"id\":\"test\",\"ok\":true,\"data\":{\"output\":\"paused\",\"exitCode\":1,\"stashRestore\":{\"stashReference\":\"stash@{1}\",\"conflictedPaths\":[],\"deferred\":true}}}";
    }
    auto* result = static_cast<char*>(std::malloc(response.size() + 1));
    assert(result != nullptr);
    std::memcpy(result, response.c_str(), response.size() + 1);
    return result;
}

std::int32_t lithe_core_cancel(const char*) {
    return 1;
}

void lithe_core_free_string(char* value) {
    std::free(value);
}

} // extern "C"

int main() {
    lithe::windows::app::WorkbenchCoordinator coordinator(32);
    assert(coordinator.coreVersion() == "coordinator-test-core");

    std::mutex mutex;
    std::condition_variable condition;
    std::optional<lithe::windows::app::WorkspaceOperationResult> snapshot;
    const auto root = std::filesystem::temp_directory_path() / "lithe-coordinator-test";
    coordinator.openWorkspace(root, [&](auto result) {
        std::lock_guard lock(mutex);
        snapshot = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] { return snapshot.has_value(); }));
    }
    assert(snapshot && !snapshot->stale && snapshot->response.isValid());
    assert(snapshot->envelope && snapshot->envelope->ok);
    assert(!coordinator.isLoading());
    assert(coordinator.workspacePaths().has_value());
    {
        std::lock_guard lock(requestMutex);
        assert(!requests.empty());
        assert(requests.back().find("\"command\":\"workspace.snapshot\"") != std::string::npos);
        assert(requests.back().find("\"timeoutMilliseconds\":30000") != std::string::npos);
        assert(requests.back().find("\"root\":\"") != std::string::npos);
        assert(requests.back().find("\"root\":\"\"") == std::string::npos);
    }

    std::optional<lithe::windows::app::WorkspaceOperationResult> shelfCreate;
    coordinator.shelfCreate("C:/state", "before checkout", "staged", "working", [&](auto result) {
        std::lock_guard lock(mutex);
        shelfCreate = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfCreate.has_value();
        }));
    }
    assert(shelfCreate && !shelfCreate->stale && shelfCreate->envelope);
    const auto shelf = lithe::windows::decodeShelfCreate(*shelfCreate->envelope);
    assert(shelf && shelf->shelf.id == "shelf-1" && shelf->shelf.stagedByteCount == 6);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"shelf.create\"") != std::string::npos);
        assert(requests.back().find("\"stagedPatch\":\"staged\"") != std::string::npos);
        assert(requests.back().find("\"workingTreePatch\":\"working\"") != std::string::npos);
    }

    std::optional<lithe::windows::app::WorkspaceOperationResult> shelfPatches;
    coordinator.gitShelfPatches([&](auto result) {
        std::lock_guard lock(mutex);
        shelfPatches = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfPatches.has_value();
        }));
    }
    assert(shelfPatches && !shelfPatches->stale && shelfPatches->envelope);
    const auto collectedPatches = lithe::windows::decodeGitShelfPatches(*shelfPatches->envelope);
    assert(collectedPatches && collectedPatches->stagedPatch == "staged" &&
           collectedPatches->workingTreePatch == "working");
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.shelfPatches\"") != std::string::npos);
    }

    std::optional<lithe::windows::app::WorkspaceOperationResult> shelfClean;
    coordinator.gitShelfClean("staged", "working", [&](auto result) {
        std::lock_guard lock(mutex);
        shelfClean = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfClean.has_value();
        }));
    }
    assert(shelfClean && !shelfClean->stale && shelfClean->envelope);
    const auto cleaned = lithe::windows::decodeGitCommand(*shelfClean->envelope);
    assert(cleaned && cleaned->exitCode == 0);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.shelfClean\"") != std::string::npos);
        assert(requests.back().find("\"stagedPatch\":\"staged\"") != std::string::npos);
        assert(requests.back().find("\"workingTreePatch\":\"working\"") != std::string::npos);
    }

    std::optional<lithe::windows::app::WorkspaceOperationResult> shelfList;
    coordinator.shelfList("C:/state", [&](auto result) {
        std::lock_guard lock(mutex);
        shelfList = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfList.has_value();
        }));
    }
    assert(shelfList && !shelfList->stale && shelfList->envelope);
    const auto shelves = lithe::windows::decodeShelfList(*shelfList->envelope);
    assert(shelves && shelves->shelves.empty());

    std::optional<lithe::windows::app::WorkspaceOperationResult> shelfRestore;
    coordinator.shelfRestore("C:/state", "shelf-1", [&](auto result) {
        std::lock_guard lock(mutex);
        shelfRestore = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfRestore.has_value();
        }));
    }
    assert(shelfRestore && !shelfRestore->stale && shelfRestore->envelope);
    const auto restored = lithe::windows::decodeShelfRestore(*shelfRestore->envelope);
    assert(restored && restored->stagedPatch == "staged" && restored->workingTreePatch == "working");

    std::optional<lithe::windows::app::WorkspaceOperationResult> shelfDelete;
    coordinator.shelfDelete("C:/state", "shelf-1", [&](auto result) {
        std::lock_guard lock(mutex);
        shelfDelete = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfDelete.has_value();
        }));
    }
    assert(shelfDelete && !shelfDelete->stale && shelfDelete->envelope);
    const auto deleted = lithe::windows::decodeShelfDelete(*shelfDelete->envelope);
    assert(deleted && deleted->deleted);

    std::optional<lithe::windows::app::WorkspaceOperationResult> read;
    coordinator.readFile("src/Main.java", [&](auto result) {
        std::lock_guard lock(mutex);
        read = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] { return read.has_value(); }));
    }
    assert(read && !read->stale);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"file.read\"") != std::string::npos);
        assert(requests.back().find("\"path\":\"src/Main.java\"") != std::string::npos);
        assert(requests.back().find("\"timeoutMilliseconds\":5000") != std::string::npos);
    }

    lithe::windows::app::DocumentFeatureModel documentFeature(coordinator);
    std::optional<lithe::windows::app::DocumentFeatureState> documentState;
    documentFeature.open("src/Main.java", [&](auto state) {
        std::lock_guard lock(mutex);
        documentState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return documentState.has_value();
        }));
    }
    assert(documentState->text == "hello" && documentState->diskFingerprint);
    assert(!documentState->isDirty && !documentState->hasExternalConflict);
    documentFeature.setText("local draft");
    documentFeature.markExternalConflict("src/Main.java", [&](auto state) {
        documentState = std::move(state);
    });
    assert(documentState->isDirty && documentState->hasExternalConflict);
    documentFeature.keepEditorVersion([&](auto state) {
        documentState = std::move(state);
    });
    assert(documentState->isDirty && !documentState->hasExternalConflict);

    {
        std::lock_guard lock(requestMutex);
        blockNextFileWrite = true;
        fileWriteStarted = false;
        releaseFileWrite = false;
    }
    documentState.reset();
    documentFeature.save([&](auto state) {
        std::lock_guard lock(mutex);
        documentState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(requestMutex);
        assert(requestCondition.wait_for(lock, std::chrono::seconds(2), [] {
            return fileWriteStarted;
        }));
    }
    documentFeature.setText("newer draft");
    {
        std::lock_guard lock(requestMutex);
        releaseFileWrite = true;
        requestCondition.notify_all();
    }
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return documentState.has_value();
        }));
    }
    assert(documentState->text == "newer draft" && documentState->isDirty);
    assert(!documentState->isSaving && !documentState->hasExternalConflict);
    documentFeature.setText("local draft");
    assert(!documentFeature.state().isDirty);

    lithe::windows::app::ReplacementFeatureModel replacementFeature(coordinator);
    std::optional<lithe::windows::app::ReplacementFeatureState> replacementState;
    lithe::windows::ReplacementPreviewRequestDto replacementRequest;
    replacementRequest.query = "hello";
    replacementRequest.replacement = "world";
    replacementFeature.preview(std::move(replacementRequest), [&](auto state) {
        std::lock_guard lock(mutex);
        replacementState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return replacementState.has_value();
        }));
    }
    assert(replacementState && replacementState->preview &&
           replacementState->preview->files.empty());

    std::optional<lithe::windows::app::WorkspaceOperationResult> markdownState;
    coordinator.markdownRender("# Preview", [&](auto state) {
        std::lock_guard lock(mutex);
        markdownState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return markdownState.has_value();
        }));
    }
    assert(markdownState && markdownState->envelope &&
           lithe::windows::decodeMarkdownRender(*markdownState->envelope)->html ==
               "<h1>Preview</h1>");
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"markdown.render\"") !=
               std::string::npos);
    }

    lithe::windows::app::GitFeatureModel gitFeature(coordinator);
    std::optional<lithe::windows::app::GitFeatureState> gitState;
    gitFeature.refreshStatus([&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->status && !gitState->isLoadingStatus);
    assert(!gitState->status->branch.has_value() || *gitState->status->branch == "main");

    gitState.reset();
    gitFeature.loadDiff({"src/Main.java"}, false, false, [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->diff && gitState->diff->rows.size() == 1);
    assert(gitState->diff->rows[0].hunkId == "hunk-0");

    gitState.reset();
    gitFeature.apply("@@", "stage", [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && !gitState->isApplying && !gitState->error);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.apply\"") != std::string::npos);
        assert(requests.back().find("\"mode\":\"stage\"") != std::string::npos);
    }

    gitState.reset();
    lithe::windows::GitWriteRequestDto failedWrite;
    failedWrite.operation = "testFailure";
    gitFeature.write(std::move(failedWrite), [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->command && gitState->command->exitCode == 7);
    assert(gitState->error &&
           gitState->error->code == lithe::windows::CoreErrorCode::ProcessFailed);

    gitState.reset();
    gitFeature.refreshHistory(std::nullopt, 300, [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->history && gitState->history->commits.size() == 1);

    gitState.reset();
    gitFeature.loadCommit("abc", [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->commit && gitState->commit->commit.hash == "abc");

    gitState.reset();
    gitFeature.loadCommitFiles("abc", [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->commitFiles && gitState->commitFiles->files.size() == 1);

    gitState.reset();
    gitFeature.loadComparison("refs/heads/main", [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->comparison && gitState->comparison->files.size() == 1);

    gitState.reset();
    gitFeature.refreshStashes([&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->stashes && gitState->stashes->stashes.size() == 1);

    gitState.reset();
    gitFeature.loadBlame("src/Main.java", [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->blame && gitState->blame->lines.size() == 1);

    const auto awaitGitState = [&](auto start) {
        gitState.reset();
        start([&](auto state) {
            std::lock_guard lock(mutex);
            gitState = std::move(state);
            condition.notify_one();
        });
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    };

    awaitGitState([&](auto handler) {
        gitFeature.preflightCheckout("refs/heads/feature", std::move(handler));
    });
    assert(gitState->checkoutPreflight &&
           gitState->checkoutPreflight->blockingPaths == std::vector<std::string>{"README.md"});
    assert(!gitState->isLoadingCheckoutPreflight);
    const auto requestCountAfterPreflight = [&] {
        std::lock_guard lock(requestMutex);
        return requests.size();
    }();
    awaitGitState([&](auto handler) {
        gitFeature.checkout("refs/heads/feature", "local", std::move(handler));
    });
    assert(gitState->checkoutPreflight &&
           gitState->checkoutPreflight->blockingPaths == std::vector<std::string>{"README.md"});
    assert(gitState->pendingCheckout &&
           gitState->pendingCheckout->reference == "refs/heads/feature" &&
           gitState->pendingCheckout->referenceKind == "local");
    {
        std::lock_guard lock(requestMutex);
        assert(requests.size() == requestCountAfterPreflight + 1);
        assert(requests.back().find("\"command\":\"git.checkoutPreflight\"") !=
               std::string::npos);
    }
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.checkoutPreflight\"") !=
               std::string::npos);
        assert(requests.back().find("\"reference\":\"refs/heads/feature\"") !=
               std::string::npos);
    }

    awaitGitState([&](auto handler) {
        gitFeature.resolveCheckoutConflict("smart", std::move(handler));
    });
    assert(!gitState->pendingCheckout && gitState->command &&
           gitState->command->exitCode == 0);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.write\"") != std::string::npos);
        assert(requests.back().find("\"operation\":\"checkout\"") != std::string::npos);
        assert(requests.back().find("\"autoStash\":true") != std::string::npos);
        assert(requests.back().find("\"force\":false") != std::string::npos);
    }

    awaitGitState([&](auto handler) {
        gitFeature.checkout("refs/heads/feature", "local", std::move(handler));
    });
    assert(gitState->pendingCheckout);
    awaitGitState([&](auto handler) {
        gitFeature.resolveCheckoutConflict("force", std::move(handler));
    });
    assert(!gitState->pendingCheckout && gitState->command &&
           gitState->command->exitCode == 0);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"autoStash\":false") != std::string::npos);
        assert(requests.back().find("\"force\":true") != std::string::npos);
    }

    awaitGitState([&](auto handler) {
        gitFeature.checkout("refs/heads/feature", "local", std::move(handler));
    });
    assert(gitFeature.state().pendingCheckout);
    gitFeature.cancelCheckoutConflict();
    assert(!gitFeature.state().pendingCheckout);

    awaitGitState([&](auto handler) { gitFeature.preflightPull(std::move(handler)); });
    assert(gitState->pullPreflight && gitState->pullPreflight->upstream == "origin/main" &&
           gitState->pullPreflight->diverged && gitState->pullPreflight->ahead == 1 &&
           gitState->pullPreflight->behind == 2 && gitState->pullPreflight->hasLocalChanges);

    awaitGitState([&](auto handler) {
        gitFeature.preflightIntegration(
            "refs/heads/feature", "rebase", std::move(handler));
    });
    assert(gitState->integrationPreflight &&
           gitState->integrationPreflight->blocksEntirely &&
           gitState->integrationPreflight->blockingPaths.size() == 1);
    assert(gitState->pendingIntegration &&
           gitState->pendingIntegration->reference == "refs/heads/feature" &&
           gitState->pendingIntegration->operation == "rebase");
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.integrationPreflight\"") !=
               std::string::npos);
        assert(requests.back().find("\"operation\":\"rebase\"") != std::string::npos);
    }
    gitFeature.cancelIntegrationConflict();
    assert(!gitFeature.state().pendingIntegration &&
           !gitFeature.state().integrationPreflight);

    awaitGitState([&](auto handler) {
        gitFeature.preflightCommit(std::move(handler));
    });
    assert(gitState->status && gitState->conflictMarkers &&
           !gitState->isLoadingStatus && !gitState->isLoadingConflictMarkers);
    const auto markerSafety = lithe::windows::app::evaluateGitCommitSafety(
        *gitState->status, *gitState->conflictMarkers);
    assert(markerSafety.unmergedPaths.empty());
    assert(markerSafety.blockingPaths ==
           std::vector<std::string>{"src/Conflict.java"});
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.conflictMarkers\"") !=
               std::string::npos);
    }

    lithe::windows::GitStatusDto conflictedStatus;
    conflictedStatus.changes = {
        {"src/Both.java", std::nullopt, "UU", true, true, false},
        {"src/Added.java", std::nullopt, "AA", true, true, false},
        {"src/Clean.java", std::nullopt, "M ", true, false, false},
    };
    const auto combinedSafety = lithe::windows::app::evaluateGitCommitSafety(
        conflictedStatus,
        lithe::windows::GitConflictMarkersDto{{"src/Marker.java", "src/Both.java"}});
    assert(combinedSafety.unmergedPaths ==
           (std::vector<std::string>{"src/Added.java", "src/Both.java"}));
    assert(combinedSafety.conflictMarkerPaths ==
           (std::vector<std::string>{"src/Both.java", "src/Marker.java"}));
    assert(combinedSafety.blockingPaths ==
           (std::vector<std::string>{
               "src/Added.java", "src/Both.java", "src/Marker.java"}));

    awaitGitState([&](auto handler) {
        gitFeature.refreshConflictMarkers(std::move(handler));
    });
    assert(gitState->conflictMarkers && gitState->conflictMarkers->paths.size() == 1);
    assert(gitState->conflictFilterPaths == std::vector<std::string>{"src/Conflict.java"});

    awaitGitState([&](auto handler) {
        gitFeature.refreshOperationState(std::move(handler));
    });
    assert(gitState->operationState && gitState->operationState->kind == "rebase" &&
           gitState->operationState->step == 2 && gitState->operationState->total == 4);
    assert(gitState->conflictFilterPaths == std::vector<std::string>{"src/Conflict.java"});

    lithe::windows::GitWriteRequestDto stashConflictRequest;
    stashConflictRequest.operation = "testStashConflict";
    awaitGitState([&](auto handler) {
        gitFeature.write(std::move(stashConflictRequest), std::move(handler));
    });
    assert(gitState->stashRestoreConflict &&
           gitState->stashRestoreConflict->stashReference == "stash@{0}");
    assert(gitState->conflictFilterPaths ==
           (std::vector<std::string>{"src/Conflict.java", "src/Stash.java"}));
    gitFeature.clearStashRestoreConflict();
    assert(!gitFeature.state().stashRestoreConflict &&
           gitFeature.state().conflictFilterPaths ==
               std::vector<std::string>{"src/Conflict.java"});

    lithe::windows::GitWriteRequestDto deferredRestoreRequest;
    deferredRestoreRequest.operation = "testDeferredRestore";
    awaitGitState([&](auto handler) {
        gitFeature.write(std::move(deferredRestoreRequest), std::move(handler));
    });
    assert(gitState->stashRestoreConflict &&
           gitState->stashRestoreConflict->stashReference == "stash@{1}" &&
           gitState->stashRestoreConflict->conflictedPaths.empty() &&
           gitState->stashRestoreConflict->deferred);
    assert(gitState->conflictFilterPaths ==
           std::vector<std::string>{"src/Conflict.java"});
    gitFeature.clearStashRestoreConflict();

    gitState.reset();
    lithe::windows::GitWriteRequestDto writeRequest;
    writeRequest.operation = "stage";
    writeRequest.paths = {"src/Main.java"};
    gitFeature.write(std::move(writeRequest), [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->command && gitState->command->output == "written");
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.write\"") != std::string::npos);
        assert(requests.back().find("\"operation\":\"stage\"") != std::string::npos);
        assert(requests.back().find("\"root\":\"" + root.generic_string()) != std::string::npos);
    }

    gitState.reset();
    gitFeature.runCommand({"status", "--short"}, std::nullopt, [&](auto state) {
        std::lock_guard lock(mutex);
        gitState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return gitState.has_value();
        }));
    }
    assert(gitState && gitState->command && gitState->command->output == "command output");
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"git.command\"") != std::string::npos);
        assert(requests.back().find("\"arguments\":[\"status\",\"--short\"]") != std::string::npos);
    }

    lithe::windows::app::MavenJavaFeatureModel mavenJavaFeature(coordinator);
    std::optional<lithe::windows::app::MavenJavaFeatureState> mavenJavaState;
    mavenJavaFeature.scanMaven([&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->maven && mavenJavaState->maven->scan);
    assert(mavenJavaState->maven->scan->artifactId == "app");

    mavenJavaState.reset();
    mavenJavaFeature.parseMavenDiagnostics("[ERROR] src/Main.java:[4] bad", [&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->diagnostics &&
           mavenJavaState->diagnostics->issues.size() == 1);

    mavenJavaState.reset();
    mavenJavaFeature.loadRunConfigurations({}, {}, [&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->runConfigurations);

    mavenJavaState.reset();
    mavenJavaFeature.loadCodeVision("src/Main.java", {}, [&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->codeVision &&
           mavenJavaState->codeVision->hints[0].utf16Column == 2);

    mavenJavaState.reset();
    mavenJavaFeature.resolveClassName("class Main {}", "Main", [&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->className &&
           mavenJavaState->className->className == "com.example.Main");

    mavenJavaState.reset();
    mavenJavaFeature.findSourceDefinition("class Main {}", "Main", std::nullopt,
        [&](auto state) {
            std::lock_guard lock(mutex);
            mavenJavaState = std::move(state);
            condition.notify_one();
        });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->sourceDefinition &&
           !mavenJavaState->sourceDefinition->definition);

    mavenJavaState.reset();
    mavenJavaFeature.findServerPort("server:\n  port: 8080", "yml", [&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->serverPort &&
           mavenJavaState->serverPort->port == 8080);

    mavenJavaState.reset();
    mavenJavaFeature.loadJavaStructure("class Main {}", {}, [&](auto state) {
        std::lock_guard lock(mutex);
        mavenJavaState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return mavenJavaState.has_value();
        }));
    }
    assert(mavenJavaState && mavenJavaState->structure &&
           mavenJavaState->structure->foldRegions.empty());

    class TestFileStorage final : public lithe::windows::FileStorage {
    public:
        std::string homeDirectory() const override { return "/tmp"; }
        std::string cacheDirectory() const override { return "/tmp/Lithe/cache"; }
        std::string applicationSupportDirectory() const override { return support; }
        std::optional<lithe::windows::FileMetadata> metadata(const std::string&) const override {
            return std::nullopt;
        }
        bool fileExists(const std::string&) const override { return false; }
        bool isExecutable(const std::string&) const override { return false; }
        std::vector<std::string> listDirectory(const std::string&) const override { return {}; }
        std::optional<std::vector<std::uint8_t>> readData(
            const std::string&, std::string&) const override { return std::nullopt; }
        bool writeData(const std::string&, const std::vector<std::uint8_t>&,
                       std::string&) override { return false; }
        bool createDirectory(const std::string&, bool, std::string&) override { return false; }
        bool removeItem(const std::string&, std::string&) override { return false; }
        bool moveItem(const std::string&, const std::string&, std::string&) override { return false; }
        std::string support = "/tmp/Lithe";
    } storage;
    lithe::windows::app::HistoryFeatureModel historyFeature(coordinator, storage);
    std::optional<lithe::windows::app::HistoryFeatureState> historyState;
    historyFeature.loadEntries(std::nullopt, [&](auto state) {
        std::lock_guard lock(mutex);
        historyState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return historyState.has_value();
        }));
    }
    assert(historyState && historyState->entries && historyState->entries->entries.size() == 1);

    historyState.reset();
    assert(std::string_view(lithe::windows::app::HistoryReason::BeforeRename) == "beforeRename");
    assert(std::string_view(lithe::windows::app::HistoryReason::BeforeDelete) == "beforeDelete");
    assert(std::string_view(lithe::windows::app::HistoryReason::BeforeBatchReplace) ==
           "beforeBatchReplace");
    assert(std::string_view(lithe::windows::app::HistoryReason::Restored) == "restored");
    historyFeature.record("src/Main.java", lithe::windows::app::HistoryReason::Saved,
                          std::string("hello"), true, [&](auto state) {
        std::lock_guard lock(mutex);
        historyState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return historyState.has_value();
        }));
    }
    assert(historyState && historyState->recordedEntry && !historyState->error);

    historyState.reset();
    historyFeature.record("src/Main.java", lithe::windows::app::HistoryReason::Saved,
                          std::nullopt, true, [&](auto state) {
        std::lock_guard lock(mutex);
        historyState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return historyState.has_value();
        }));
    }
    assert(historyState && !historyState->recordedEntry && !historyState->error);

    historyState.reset();
    historyFeature.loadContent("src-Main.java/entry-1.snapshot", [&](auto state) {
        std::lock_guard lock(mutex);
        historyState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return historyState.has_value();
        }));
    }
    assert(historyState && historyState->content && historyState->content->text == "hello history");

    historyState.reset();
    historyFeature.relocate("src/Main.java", "src/Renamed.java", [&](auto state) {
        std::lock_guard lock(mutex);
        historyState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return historyState.has_value();
        }));
    }
    assert(historyState && !historyState->isRelocating && !historyState->error);

    storage.support = std::string("C:/Users/") +
        "\xE7\x94\xA8\xE6\x88\xB7" +
        "/AppData/Roaming/Lithe";
    lithe::windows::app::ShelfFeatureModel shelfFeature(coordinator, storage);
    std::optional<lithe::windows::app::ShelfFeatureState> shelfState;
    shelfFeature.load([&](auto state) {
        std::lock_guard lock(mutex);
        shelfState = std::move(state);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return shelfState.has_value();
        }));
    }
    assert(shelfState && shelfState->shelves && !shelfState->error);
    const auto expectedShelfStorage = std::string("C:/Users/") +
        "\xE7\x94\xA8\xE6\x88\xB7" +
        "/AppData/Roaming/Lithe/lithe";
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"shelf.list\"") != std::string::npos);
        assert(requests.back().find(expectedShelfStorage) != std::string::npos);
    }

    std::optional<lithe::windows::app::WorkspaceOperationResult> everywhere;
    coordinator.searchEverywhere("Main", [&](auto result) {
        std::lock_guard lock(mutex);
        everywhere = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return everywhere.has_value();
        }));
    }
    assert(everywhere && !everywhere->stale && everywhere->envelope &&
           everywhere->envelope->ok);
    const auto everywhereResponse = lithe::windows::decodeSearchResponse(*everywhere->envelope);
    assert(everywhereResponse && everywhereResponse->matches.size() == 3);
    {
        std::lock_guard lock(requestMutex);
        assert(requests.back().find("\"command\":\"workspace.searchEverywhere\"") !=
               std::string::npos);
        assert(requests.back().find("\"maxSymbolResults\":50") != std::string::npos);
    }

    // Keep the three requests on different fixed workers so the test can
    // deterministically complete document and search work while a snapshot is blocked.
    std::uint64_t nextOperation = 0;
    const auto workerSlot = [](std::uint64_t operation, std::size_t workerCount) {
        return std::hash<std::string>{}("windows-" + std::to_string(operation)) % workerCount;
    };
    {
        std::lock_guard lock(requestMutex);
        assert(!requests.empty());
        const auto lastOperation = requestValue(requests.back(), "operationId");
        assert(lastOperation.starts_with("windows-"));
        nextOperation = std::stoull(lastOperation.substr(std::string("windows-").size())) + 1;
    }
    while (workerSlot(nextOperation, 32) == workerSlot(nextOperation + 1, 32) ||
           workerSlot(nextOperation, 32) == workerSlot(nextOperation + 2, 32) ||
           workerSlot(nextOperation + 1, 32) == workerSlot(nextOperation + 2, 32)) {
        std::optional<lithe::windows::app::WorkspaceOperationResult> advance;
        coordinator.search("advance", [&](auto result) {
            std::lock_guard lock(mutex);
            advance = std::move(result);
            condition.notify_one();
        });
        {
            std::unique_lock lock(mutex);
            assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
                return advance.has_value();
            }));
        }
        assert(advance && !advance->stale);
        ++nextOperation;
    }

    {
        std::lock_guard lock(requestMutex);
        blockNextSnapshot = true;
        snapshotStarted = false;
        releaseSnapshot = false;
    }
    std::optional<lithe::windows::app::WorkspaceOperationResult> concurrentSnapshot;
    std::optional<lithe::windows::app::WorkspaceOperationResult> concurrentRead;
    std::optional<lithe::windows::app::WorkspaceOperationResult> concurrentSearch;
    coordinator.openWorkspace(root / "second", [&](auto result) {
        std::lock_guard lock(mutex);
        concurrentSnapshot = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(requestMutex);
        assert(requestCondition.wait_for(lock, std::chrono::seconds(2), [] {
            return snapshotStarted;
        }));
    }
    coordinator.readFile("src/Main.java", [&](auto result) {
        std::lock_guard lock(mutex);
        concurrentRead = std::move(result);
        condition.notify_one();
    });
    coordinator.search("query", [&](auto result) {
        std::lock_guard lock(mutex);
        concurrentSearch = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return concurrentRead.has_value() && concurrentSearch.has_value();
        }));
    }
    assert(concurrentRead && !concurrentRead->stale);
    assert(concurrentSearch && !concurrentSearch->stale);

    {
        std::lock_guard lock(requestMutex);
        releaseSnapshot = true;
        requestCondition.notify_all();
    }
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return concurrentSnapshot.has_value();
        }));
    }
    assert(concurrentSnapshot && !concurrentSnapshot->stale);
    assert(!coordinator.isLoading());

    {
        std::lock_guard lock(requestMutex);
        blockNextSnapshot = true;
        snapshotStarted = false;
        releaseSnapshot = false;
    }
    std::optional<lithe::windows::app::WorkspaceOperationResult> closedSnapshot;
    coordinator.openWorkspace(root / "closing", [&](auto result) {
        std::lock_guard lock(mutex);
        closedSnapshot = std::move(result);
        condition.notify_one();
    });
    {
        std::unique_lock lock(requestMutex);
        assert(requestCondition.wait_for(lock, std::chrono::seconds(2), [] {
            return snapshotStarted;
        }));
    }
    coordinator.closeWorkspace();
    assert(!coordinator.workspacePaths());
    {
        std::lock_guard lock(requestMutex);
        releaseSnapshot = true;
        requestCondition.notify_all();
    }
    {
        std::unique_lock lock(mutex);
        assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return closedSnapshot.has_value();
        }));
    }
    assert(closedSnapshot && closedSnapshot->stale);
    assert(!coordinator.isLoading());
    std::optional<lithe::windows::app::WorkspaceOperationResult> closedRefresh;
    coordinator.refreshWorkspace([&](auto result) {
        closedRefresh = std::move(result);
    });
    assert(closedRefresh && closedRefresh->coreError() &&
           closedRefresh->coreError()->code == lithe::windows::CoreErrorCode::WorkspaceNotFound);
    coordinator.shutdown();
    return 0;
}
