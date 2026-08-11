#include "dirty_documents_port.h"
#include "git_feature.h"
#include "workbench_coordinator.h"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

std::mutex requestMutex;
std::condition_variable requestCondition;
std::vector<std::string> requests;

std::string checkoutBlocking = R"([])";
std::string integrationBlocking = R"([])";
bool integrationBlocksEntirely = false;
std::string operationKind;
std::string writeExitCode = "0";
std::string writeStashRestore;
bool pullDiverged = false;
std::string lastWriteOperation;
std::string conflictMarkersPaths = R"([])";
std::string statusChanges = R"([])";
bool holdConflictMarkers = false;
std::mutex conflictMarkersHoldMutex;
std::condition_variable conflictMarkersHoldCv;

std::string requestValue(const std::string& request, const std::string& key) {
    const auto marker = "\"" + key + "\":\"";
    const auto start = request.find(marker);
    if (start == std::string::npos) return {};
    const auto valueStart = start + marker.size();
    const auto valueEnd = request.find('"', valueStart);
    return valueEnd == std::string::npos
        ? std::string{}
        : request.substr(valueStart, valueEnd - valueStart);
}

bool waitFor(const std::function<bool()>& predicate) {
    for (int attempt = 0; attempt < 200; ++attempt) {
        if (predicate()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

} // namespace

extern "C" {

const char* lithe_core_version(void) {
    return "git-workflow-test-core";
}

char* lithe_core_execute_json(const char* request) {
    const std::string value = request == nullptr ? std::string{} : std::string(request);
    {
        std::lock_guard lock(requestMutex);
        requests.push_back(value);
    }
    const auto command = requestValue(value, "command");
    std::string response;
    if (command == "git.checkoutPreflight") {
        response = "{\"id\":\"t\",\"ok\":true,\"data\":{\"blockingPaths\":" + checkoutBlocking + "}}";
    } else if (command == "git.integrationPreflight") {
        response = std::string("{\"id\":\"t\",\"ok\":true,\"data\":{\"blockingPaths\":")
            + integrationBlocking + ",\"blocksEntirely\":"
            + (integrationBlocksEntirely ? "true" : "false") + "}}";
    } else if (command == "git.pullPreflight") {
        response = std::string("{\"id\":\"t\",\"ok\":true,\"data\":{\"upstream\":\"origin/main\",")
            + "\"ahead\":1,\"behind\":2,\"diverged\":"
            + (pullDiverged ? "true" : "false") + ",\"hasLocalChanges\":false}}";
    } else if (command == "git.operationState") {
        response = std::string("{\"id\":\"t\",\"ok\":true,\"data\":{\"kind\":\"")
            + operationKind + "\",\"reference\":null,\"step\":null,\"total\":null,"
            + "\"conflictedPaths\":[]}}";
    } else if (command == "git.conflictMarkers") {
        if (holdConflictMarkers) {
            std::unique_lock lock(conflictMarkersHoldMutex);
            conflictMarkersHoldCv.wait_for(lock, std::chrono::seconds(5), [] {
                return !holdConflictMarkers;
            });
        }
        response = std::string("{\"id\":\"t\",\"ok\":true,\"data\":{\"paths\":")
            + conflictMarkersPaths + "}}";
    } else if (command == "git.status") {
        response =
            std::string("{\"id\":\"t\",\"ok\":true,\"data\":{\"repositoryRoot\":\"/repo\","
                        "\"branch\":\"main\",\"changes\":")
            + statusChanges + "}}";
    } else if (command == "git.stashes") {
        response = "{\"id\":\"t\",\"ok\":true,\"data\":{\"stashes\":[]}}";
    } else if (command == "git.write") {
        lastWriteOperation = requestValue(value, "operation");
        response = std::string("{\"id\":\"t\",\"ok\":true,\"data\":{\"output\":\"ok\",\"exitCode\":")
            + writeExitCode;
        if (!writeStashRestore.empty()) {
            response += ",\"stashRestore\":" + writeStashRestore;
        }
        response += "}}";
    } else if (command == "git.diff") {
        response =
            "{\"id\":\"t\",\"ok\":true,\"data\":{\"patch\":\"\",\"rows\":[],\"hunks\":[]}}";
    } else if (command == "git.apply") {
        response = "{\"id\":\"t\",\"ok\":true,\"data\":{\"output\":\"\",\"exitCode\":0}}";
    } else if (command == "workspace.snapshot") {
        response =
            "{\"id\":\"t\",\"ok\":true,\"data\":{\"root\":{\"path\":\".\",\"name\":\"repo\","
            "\"isDirectory\":true,\"children\":[]},\"files\":[]}}";
    } else {
        response = "{\"id\":\"t\",\"ok\":false,\"error\":{\"code\":\"not_supported\","
                   "\"message\":\"unexpected\"}}";
    }
    auto* copy = static_cast<char*>(std::malloc(response.size() + 1));
    std::memcpy(copy, response.data(), response.size() + 1);
    return copy;
}

std::int32_t lithe_core_cancel(const char*) {
    return 1;
}

void lithe_core_free_string(char* value) {
    std::free(value);
}

} // extern "C"

int main() {
    using lithe::windows::app::FakeDirtyDocumentsPort;
    using lithe::windows::app::GitCheckoutConflictStrategy;
    using lithe::windows::app::GitFeatureModel;
    using lithe::windows::app::GitFeatureState;
    using lithe::windows::app::GitPullStrategy;
    using lithe::windows::app::WorkbenchCoordinator;

    WorkbenchCoordinator coordinator(2);
    FakeDirtyDocumentsPort dirty;
    GitFeatureModel feature(coordinator, &dirty, nullptr);

    int began = 0;
    int ended = 0;
    feature.setOperationLifecycleHandlers([&] { ++began; }, [&] { ++ended; });

    coordinator.openWorkspace(std::filesystem::path("/repo"), [](auto) {});
    assert(waitFor([&] {
        std::lock_guard lock(requestMutex);
        return !requests.empty();
    }));

    // Dirty documents block checkout before Rust preflight.
    dirty.setDirtyPaths({"src/Main.java"});
    checkoutBlocking = R"([])";
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.checkoutReference("refs/heads/feature", "local", "feature",
            [&](GitFeatureState next) {
                std::lock_guard lock(doneMutex);
                state = std::move(next);
                done = true;
                doneCv.notify_all();
            });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(2), [&] { return done; });
        }
        assert(state.pendingCheckoutConflict.has_value());
        assert(!state.pendingCheckoutConflict->dirtyDocumentPaths.empty());
        feature.cancelCheckoutConflict();
    }
    dirty.clear();

    // Preflight blocking paths produce pending context.
    checkoutBlocking = R"(["src/Main.java"])";
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.checkoutReference("refs/heads/feature", "local", "feature",
            [&](GitFeatureState next) {
                std::lock_guard lock(doneMutex);
                state = std::move(next);
                done = true;
                doneCv.notify_all();
            });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(2), [&] { return done; });
        }
        assert(state.pendingCheckoutConflict.has_value());
        assert(state.pendingCheckoutConflict->blockingPaths.size() == 1);
    }

    // Resolve pending checkout with Smart strategy; lifecycle begin/end pair.
    began = ended = 0;
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        feature.resolveCheckoutConflict(GitCheckoutConflictStrategy::Smart,
            [&](GitFeatureState) {
                std::lock_guard lock(doneMutex);
                done = true;
                doneCv.notify_all();
            });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(began >= 1);
        assert(ended >= 1);
        assert(lastWriteOperation == "checkout");
    }

    // Clear preflight allows direct checkout write.
    checkoutBlocking = R"([])";
    lastWriteOperation.clear();
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        feature.checkoutReference("refs/heads/feature", "local", "feature",
            [&](GitFeatureState) {
                std::lock_guard lock(doneMutex);
                done = true;
                doneCv.notify_all();
            });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(lastWriteOperation == "checkout");
    }

    // Integration rebase blocksEntirely pending.
    integrationBlocking = R"(["a.txt"])";
    integrationBlocksEntirely = true;
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.rebaseOnto("refs/heads/main", "main", [&](GitFeatureState next) {
            std::lock_guard lock(doneMutex);
            state = std::move(next);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(2), [&] { return done; });
        }
        assert(state.pendingIntegrationConflict.has_value());
        assert(state.pendingIntegrationConflict->blocksEntirely);
        feature.cancelIntegrationConflict();
    }

    // Pull diverged creates pending strategy.
    pullDiverged = true;
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.pull([&](GitFeatureState next) {
            std::lock_guard lock(doneMutex);
            state = std::move(next);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(2), [&] { return done; });
        }
        assert(state.pendingPullStrategy.has_value());
        feature.cancelPullStrategy();
    }
    pullDiverged = false;

    // Non-zero exit with stashRestore is not treated as clean success.
    writeExitCode = "1";
    writeStashRestore =
        R"({"stashReference":"stash@{0}","conflictedPaths":["conflict.txt"]})";
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.applyStash("stash@{0}", [&](GitFeatureState next) {
            std::lock_guard lock(doneMutex);
            state = std::move(next);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(state.pendingStashRestoreConflict.has_value());
        assert(state.pendingStashRestoreConflict->stashReference == "stash@{0}");
        assert(state.error.has_value() || state.stashRestoreNoticeVisible);
    }
    writeExitCode = "0";
    writeStashRestore.clear();

    // Continue/abort/skip ops emit correct write operation ids.
    lastWriteOperation.clear();
    operationKind = "merge";
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        feature.continueOperation([&](GitFeatureState) {
            std::lock_guard lock(doneMutex);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(lastWriteOperation == "operationContinue");
    }
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        feature.abortOperation([&](GitFeatureState) {
            std::lock_guard lock(doneMutex);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(lastWriteOperation == "operationAbort");
    }
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        feature.skipOperation([&](GitFeatureState) {
            std::lock_guard lock(doneMutex);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(lastWriteOperation == "operationSkip");
    }

    // Conflict markers block commit.
    conflictMarkersPaths = R"(["a.txt"])";
    lastWriteOperation.clear();
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.commit("message", false, [&](GitFeatureState next) {
            std::lock_guard lock(doneMutex);
            state = std::move(next);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(state.notifyMessage.has_value());
        assert(state.notifyMessage->find("Conflict markers") != std::string::npos);
        assert(lastWriteOperation.empty());
    }
    conflictMarkersPaths = R"([])";

    // Unmerged status blocks commit.
    statusChanges =
        R"([{"path":"a.txt","status":"UU","staged":true,"worktree":true,"untracked":false}])";
    lastWriteOperation.clear();
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.commit("message", false, [&](GitFeatureState next) {
            std::lock_guard lock(doneMutex);
            state = std::move(next);
            done = true;
            doneCv.notify_all();
        });
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(3), [&] { return done; });
        }
        assert(state.notifyMessage.has_value());
        assert(state.notifyMessage->find("Resolve the conflicts first") != std::string::npos);
        assert(lastWriteOperation.empty());
    }
    statusChanges = R"([])";

    // Stale mid-flight response clears loading and does not invent pending conflicts.
    {
        std::lock_guard lock(requestMutex);
        requests.clear();
    }
    holdConflictMarkers = true;
    checkoutBlocking = R"([])";
    {
        std::mutex doneMutex;
        std::condition_variable doneCv;
        bool done = false;
        GitFeatureState state;
        feature.checkoutReference("refs/heads/stale", "local", "stale",
            [&](GitFeatureState next) {
                std::lock_guard lock(doneMutex);
                state = std::move(next);
                done = true;
                doneCv.notify_all();
            });
        assert(waitFor([&] {
            std::lock_guard lock(requestMutex);
            for (const auto& request : requests) {
                if (requestValue(request, "command") == "git.conflictMarkers") return true;
            }
            return false;
        }));
        coordinator.openWorkspace(std::filesystem::path("/repo-stale"), [](auto) {});
        {
            std::lock_guard lock(conflictMarkersHoldMutex);
            holdConflictMarkers = false;
        }
        conflictMarkersHoldCv.notify_all();
        {
            std::unique_lock lock(doneMutex);
            doneCv.wait_for(lock, std::chrono::seconds(5), [&] { return done; });
        }
        assert(done);
        assert(!state.pendingCheckoutConflict.has_value());
        assert(!state.isPerformingBranchOperation);
        assert(!state.isLoadingStatus);
    }

    // Workspace switch clears pending workflow state.
    feature.resetForWorkspace();
    const auto cleared = feature.state();
    assert(!cleared.pendingCheckoutConflict);
    assert(!cleared.pendingIntegrationConflict);
    assert(!cleared.pendingPullStrategy);
    assert(!cleared.pendingStashRestoreConflict);
    assert(!cleared.operationState);

    coordinator.shutdown();
    return 0;
}
