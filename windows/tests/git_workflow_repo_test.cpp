#include "core_client.h"
#include "core_dto.h"
#include "core_requests.h"
#include "git_watcher_freeze.h"
#include "git_workflow_ui.h"
#include "shelve_service.h"
#include "win32_file_storage.h"

#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#ifdef _WIN32
#include <stdlib.h>
#endif

namespace {

using lithe::windows::CoreClient;
using lithe::windows::GitCommandDto;
using lithe::windows::GitOperationStateDto;
using lithe::windows::GitStatusDto;
using lithe::windows::GitWriteRequestDto;
using lithe::windows::Win32FileStorage;
using lithe::windows::app::GitOperationState;
using lithe::windows::app::GitWatcherFreezeController;
using lithe::windows::app::ShelveService;
using lithe::windows::app::makeOperationBarModel;
using lithe::windows::decodeCoreEnvelope;
using lithe::windows::decodeGitCommand;
using lithe::windows::decodeGitOperationState;
using lithe::windows::decodeGitStatus;
using lithe::windows::encodeGitOperationStateRequest;
using lithe::windows::encodeGitStatusRequest;
using lithe::windows::encodeGitWriteRequest;

std::filesystem::path uniqueTempRoot() {
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    auto root = std::filesystem::temp_directory_path() /
        ("lithe-git-repo-" + std::to_string(stamp));
    std::filesystem::create_directories(root);
    return root;
}

int runGitCode(const std::filesystem::path& repo, const std::string& args) {
    const auto command = "git -C \"" + repo.string() +
        "\" -c core.editor=true -c sequence.editor=true " + args + " >NUL 2>&1";
    return std::system(command.c_str());
}

void runGit(const std::filesystem::path& repo, const std::string& args) {
    const auto code = runGitCode(repo, args);
    if (code != 0) {
        std::cerr << "git failed: " << args << " code=" << code << std::endl;
        assert(false);
    }
}

void writeFile(const std::filesystem::path& path, const std::string& text) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    assert(out.good());
    out << text;
}

std::string rootUtf8(const std::filesystem::path& repo) {
    return repo.string();
}

std::filesystem::path makeRepo(const std::filesystem::path& root) {
    const auto repo = root / "repo";
    std::filesystem::create_directories(repo);
    runGit(repo, "init");
    runGit(repo, "config user.email lithe@example.com");
    runGit(repo, "config user.name Lithe");
    // Normalize branch name across Git versions.
    runGit(repo, "checkout -B main");
    writeFile(repo / "file.txt", "base\n");
    runGit(repo, "add file.txt");
    runGit(repo, "commit -m init");
    runGit(repo, "checkout -b feature");
    writeFile(repo / "file.txt", "feature\n");
    runGit(repo, "commit -am feature");
    runGit(repo, "checkout main");
    writeFile(repo / "file.txt", "main\n");
    runGit(repo, "commit -am main");
    return repo;
}

GitStatusDto statusAt(CoreClient& core, const std::string& root) {
    const auto response = core.execute("git.status", encodeGitStatusRequest({root}), 15000);
    assert(response);
    const auto envelope = decodeCoreEnvelope(*response);
    assert(envelope && envelope->ok);
    auto status = decodeGitStatus(*envelope);
    assert(status);
    return *status;
}

GitOperationStateDto operationStateAt(CoreClient& core, const std::string& root) {
    const auto response = core.execute(
        "git.operationState", encodeGitOperationStateRequest({root}), 15000);
    assert(response);
    const auto envelope = decodeCoreEnvelope(*response);
    assert(envelope && envelope->ok);
    auto state = decodeGitOperationState(*envelope);
    assert(state);
    return *state;
}

GitCommandDto writeAt(CoreClient& core, GitWriteRequestDto request) {
    const auto response = core.execute("git.write", encodeGitWriteRequest(request), 30000);
    assert(response);
    const auto envelope = decodeCoreEnvelope(*response);
    assert(envelope && envelope->ok);
    auto command = decodeGitCommand(*envelope);
    assert(command);
    return *command;
}

} // namespace

int main() {
#ifdef _WIN32
    _putenv("GIT_EDITOR=true");
    _putenv("GIT_SEQUENCE_EDITOR=true");
    _putenv("GIT_TERMINAL_PROMPT=0");
#endif

    std::cout << "repo-test:start" << std::endl;
    const auto root = uniqueTempRoot();
    const auto repo = makeRepo(root);
    const auto rootPath = rootUtf8(repo);
    CoreClient core;

    // Baseline status.
    auto status = statusAt(core, rootPath);
    assert(status.branch && *status.branch == "main");

    // Merge conflict → operationState → abort.
    assert(runGitCode(repo, "merge feature") != 0);
    auto op = operationStateAt(core, rootPath);
    assert(op.kind == "merge");
    assert(!op.conflictedPaths.empty());
    auto bar = makeOperationBarModel(
        lithe::windows::app::toOperationState(op), false, false);
    assert(bar.visible);
    assert(!bar.canContinue);
    assert(bar.canAbort);
    assert(!bar.canSkip);

    GitWriteRequestDto abortReq;
    abortReq.root = rootPath;
    abortReq.operation = "operationAbort";
    auto aborted = writeAt(core, abortReq);
    assert(aborted.exitCode == 0);
    op = operationStateAt(core, rootPath);
    assert(op.kind.empty());

    // Rebase conflict → abort (skip covered when canSkip).
    runGit(repo, "checkout -B rebase-base main");
    writeFile(repo / "file.txt", "rebase-base\n");
    runGit(repo, "commit -am rebase-base");
    runGit(repo, "checkout -B rebase-topic feature");
    writeFile(repo / "file.txt", "rebase-topic\n");
    runGit(repo, "commit -am rebase-topic");
    assert(runGitCode(repo, "rebase rebase-base") != 0);
    op = operationStateAt(core, rootPath);
    assert(op.kind == "rebase");
    bar = makeOperationBarModel(lithe::windows::app::toOperationState(op), false, false);
    assert(bar.canSkip);
    abortReq.operation = "operationAbort";
    aborted = writeAt(core, abortReq);
    assert(aborted.exitCode == 0);

    // Merge → resolve → continue.
    runGit(repo, "checkout main");
    runGit(repo, "reset --hard");
    assert(runGitCode(repo, "merge feature") != 0);
    writeFile(repo / "file.txt", "resolved\n");
    runGit(repo, "add file.txt");
    GitWriteRequestDto continueReq;
    continueReq.root = rootPath;
    continueReq.operation = "operationContinue";
    auto continued = writeAt(core, continueReq);
    assert(continued.exitCode == 0);
    op = operationStateAt(core, rootPath);
    assert(op.kind.empty());

    // Stash apply conflict keeps stashRestore metadata.
    runGit(repo, "reset --hard");
    writeFile(repo / "file.txt", "stash-me\n");
    runGit(repo, "stash push -u -m lithe-stash");
    writeFile(repo / "file.txt", "worktree\n");
    runGit(repo, "commit -am worktree");
    GitWriteRequestDto applyReq;
    applyReq.root = rootPath;
    applyReq.operation = "stashApply";
    applyReq.reference = "stash@{0}";
    auto applied = writeAt(core, applyReq);
    assert(applied.exitCode != 0);
    assert(applied.stashRestore.has_value());
    assert(!applied.stashRestore->stashReference.empty());
    assert(!applied.stashRestore->conflictedPaths.empty());

    // Shelf staged/working separation + keep on failure + repo isolation.
    Win32FileStorage storage;
    ShelveService shelves(storage);
    auto saved = shelves.save(rootPath, "wip", {"file.txt"}, "STAGED", "WORKING");
    assert(saved);
    assert(saved->stagedPatch == "STAGED");
    assert(saved->workingPatch == "WORKING");
    const auto otherRoot = rootUtf8(root / "other-repo");
    std::filesystem::create_directories(root / "other-repo");
    assert(shelves.entries(otherRoot).empty());
    assert(shelves.entries(rootPath).size() == 1);
    // Keep-on-failure: do not delete until explicit remove.
    assert(shelves.entries(rootPath).size() == 1);
    assert(shelves.remove(rootPath, *saved));
    assert(shelves.entries(rootPath).empty());

    // Nested watcher freeze flushes once.
    GitWatcherFreezeController freeze;
    int flushes = 0;
    freeze.setFlushHandler([&](auto) { ++flushes; });
    freeze.begin();
    freeze.begin();
    freeze.noteChanges({{"a", lithe::windows::DirectoryChangeSource::ChangeKind::Modified}});
    assert(!freeze.end());
    assert(flushes == 0);
    assert(freeze.end());
    assert(flushes == 1);

    std::error_code ec;
    std::filesystem::remove_all(root, ec);
    std::cout << "repo-test:ok" << std::endl;
    return 0;
}
