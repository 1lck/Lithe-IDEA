#include "workbench_session.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <map>
#include <system_error>
#include <string_view>
#include <utility>
#include <variant>

#ifndef LITHE_VERSION
#define LITHE_VERSION "0.1.11"
#endif

namespace lithe::windows::winui {
namespace {

bool equalIgnoreCase(std::string_view left, std::string_view right) {
    if (left.size() != right.size()) return false;
    for (std::size_t index = 0; index < left.size(); ++index) {
        if (std::tolower(static_cast<unsigned char>(left[index])) !=
            std::tolower(static_cast<unsigned char>(right[index]))) {
            return false;
        }
    }
    return true;
}

std::string pathUtf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::filesystem::path pathFromUtf8(std::string_view value) {
    std::u8string converted;
    converted.assign(reinterpret_cast<const char8_t*>(value.data()),
                     reinterpret_cast<const char8_t*>(value.data() + value.size()));
    return std::filesystem::path(converted);
}

template <typename T>
std::optional<T> storedValue(const KeyValueStore& store, const char* key) {
    const auto value = store.readValue(key);
    if (!value || !std::holds_alternative<T>(*value)) return std::nullopt;
    return std::get<T>(*value);
}

int storedIndex(const KeyValueStore& store, const char* key, int maximum) {
    const auto value = store.read(key);
    if (!value) return 0;
    try {
        const auto parsed = std::stoi(*value);
        return parsed >= 0 && parsed <= maximum ? parsed : 0;
    } catch (...) {
        return 0;
    }
}

std::string percentDecode(std::string_view value) {
    const auto hex = [](char character) -> int {
        if (character >= '0' && character <= '9') return character - '0';
        if (character >= 'a' && character <= 'f') return character - 'a' + 10;
        if (character >= 'A' && character <= 'F') return character - 'A' + 10;
        return -1;
    };
    std::string result;
    result.reserve(value.size());
    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] == '%' && index + 2 < value.size()) {
            const auto high = hex(value[index + 1]);
            const auto low = hex(value[index + 2]);
            if (high >= 0 && low >= 0) {
                result.push_back(static_cast<char>((high << 4) | low));
                index += 2;
                continue;
            }
        }
        result.push_back(value[index]);
    }
    return result;
}

std::string normalizedSlashes(std::string value) {
    std::replace(value.begin(), value.end(), '\\', '/');
    return value;
}

bool isInside(const std::filesystem::path& path, const std::filesystem::path& root) {
    if (root.empty()) return false;
    const auto relative = path.lexically_normal().lexically_relative(root.lexically_normal());
    if (relative.empty()) return path.lexically_normal() == root.lexically_normal();
    for (const auto& component : relative) {
        if (component == "..") return false;
    }
    return true;
}

}

WorkbenchSession::WorkbenchSession(WorkbenchCallbacks callbacks)
    : callbacks_(std::move(callbacks)),
      keyValueStore_(),
      recentProjectsStore_(keyValueStore_),
      workspaceSessionStore_(keyValueStore_),
      settingsStore_(keyValueStore_),
      layoutPersistence_(keyValueStore_),
      settings_(settingsStore_.load()),
      runtimeLocator_(),
      runtimeService_(runtimeLocator_),
      processRunner_(),
      archiveRunner_(),
      archiveReader_(archiveRunner_),
      mavenBuildService_(runtimeService_, processRunner_),
      coordinator_(std::make_unique<app::WorkbenchCoordinator>()),
      storage_(std::make_unique<Win32FileStorage>()),
      secureStore_(),
      httpTransport_(),
      authenticodeVerifier_(),
      aiCommitService_(httpTransport_, secureStore_),
      updateService_(httpTransport_, *storage_),
      javaRunService_(std::make_unique<app::JavaRunService>(runtimeService_, *storage_)),
      javaDebugService_(std::make_unique<app::JavaDebugService>(
          runtimeService_, *javaRunService_, *storage_, [] {
              return std::make_unique<Win32ProcessSession>();
          })),
      workspaceFeature_(std::make_unique<app::WorkspaceFeatureModel>(*coordinator_)),
      documentFeature_(std::make_unique<app::DocumentFeatureModel>(*coordinator_)),
      searchFeature_(std::make_unique<app::SearchFeatureModel>(*coordinator_)),
      replacementFeature_(std::make_unique<app::ReplacementFeatureModel>(*coordinator_)),
      gitFeature_(std::make_unique<app::GitFeatureModel>(*coordinator_)),
      historyFeature_(std::make_unique<app::HistoryFeatureModel>(*coordinator_, *storage_)),
      shelfFeature_(std::make_unique<app::ShelfFeatureModel>(
          *coordinator_, *storage_, settings_.dataDirectory)),
      mavenJavaFeature_(std::make_unique<app::MavenJavaFeatureModel>(*coordinator_)),
      terminalFeature_(std::make_unique<app::TerminalFeatureModel>()),
      writeLifecycle_(std::make_unique<app::WorkspaceWriteLifecycle>()),
      watcher_(std::make_unique<Win32DirectoryChangeSource>()),
      buildSession_(std::make_unique<Win32ProcessSession>()),
      javaSession_(std::make_unique<Win32ProcessSession>()),
      languageServerSession_(std::make_unique<Win32ProcessSession>()),
      languageServer_(std::make_unique<app::JavaLanguageServerClient>(
          runtimeService_, *storage_, *languageServerSession_, &archiveReader_)) {
    coordinator_->setWorkspaceVisibility(
        settings_.hiddenDirectoryNames, settings_.hiddenFilePatterns);
    historyFeature_->setVisibilityRules(
        settings_.hiddenDirectoryNames, settings_.hiddenFilePatterns);
    configureProcessCallbacks();
    configureJavaCallbacks();
    if (callbacks_.statusChanged) {
        callbacks_.statusChanged("Rust Core " + coordinator_->coreVersion());
    }
}

WorkbenchSession::~WorkbenchSession() {
    closeJavaDocument();
    if (languageServer_) languageServer_->stop();
    if (javaDebugService_) javaDebugService_->stop();
    if (javaSession_) javaSession_->stop();
    if (watcher_) watcher_->stop();
    for (auto& [id, terminal] : terminals_) terminal->stop();
    if (buildSession_) buildSession_->stop();
    if (coordinator_) coordinator_->shutdown();
    if (aiWorker_.joinable()) aiWorker_.join();
    if (updateWorker_.joinable()) updateWorker_.join();
}

void WorkbenchSession::configureProcessCallbacks() {
    buildSession_->setOutputHandler([this](const std::string& output) {
        if (callbacks_.buildOutput) callbacks_.buildOutput(output);
    });
    buildSession_->setErrorHandler([this](const std::string& error) {
        if (callbacks_.buildOutput) callbacks_.buildOutput("[stderr] " + error);
    });
    buildSession_->setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        if (!callbacks_.statusChanged) return;
        switch (event.state) {
        case ProcessLifecycleState::Starting:
            callbacks_.statusChanged("Starting build");
            break;
        case ProcessLifecycleState::Running:
            callbacks_.statusChanged("Build is running");
            break;
        case ProcessLifecycleState::Stopping:
            callbacks_.statusChanged("Stopping build");
            break;
        case ProcessLifecycleState::Finished:
            callbacks_.statusChanged(
                "Build finished with exit code " + std::to_string(event.exitCode.value_or(1)));
            break;
        case ProcessLifecycleState::Failed:
            callbacks_.statusChanged(event.message.empty() ? "Build failed" : event.message);
            break;
        }
    });
}

void WorkbenchSession::configureJavaCallbacks() {
    javaSession_->setOutputHandler([this](const std::string& output) {
        if (callbacks_.buildOutput) callbacks_.buildOutput(output);
    });
    javaSession_->setErrorHandler([this](const std::string& error) {
        if (callbacks_.buildOutput) callbacks_.buildOutput("[stderr] " + error);
    });
    javaSession_->setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        switch (event.state) {
        case ProcessLifecycleState::Starting:
            reportStatus("Starting Java");
            break;
        case ProcessLifecycleState::Running:
            reportStatus("Java is running");
            break;
        case ProcessLifecycleState::Stopping:
            reportStatus("Stopping Java");
            if (!event.message.empty() && callbacks_.buildOutput) {
                callbacks_.buildOutput("\n" + event.message + "\n");
            }
            break;
        case ProcessLifecycleState::Finished:
            reportStatus("Java finished with exit code " +
                         std::to_string(event.exitCode.value_or(1)));
            if (callbacks_.buildOutput) {
                callbacks_.buildOutput("\nJava finished with exit code " +
                    std::to_string(event.exitCode.value_or(1)) + "\n");
            }
            break;
        case ProcessLifecycleState::Failed:
            reportStatus(event.message.empty() ? "Java failed to start" : event.message);
            if (!event.message.empty() && callbacks_.buildOutput) {
                callbacks_.buildOutput("\n" + event.message + "\n");
            }
            break;
        }
    });

    javaDebugService_->setStateHandler([this] {
        if (callbacks_.javaDebugChanged) {
            callbacks_.javaDebugChanged(javaDebugService_->snapshot());
        }
    });
    languageServer_->setStateHandler([this](bool ready, const std::string& message) {
        if (callbacks_.languageServerChanged) {
            callbacks_.languageServerChanged(ready, message);
        }
        if (ready) synchronizeJavaLanguageDocument();
    });
    languageServer_->setDiagnosticsHandler(
        [this](const std::string& uri, const JsonValue& diagnostics) {
            auto parsed = parseJavaDiagnostics(uri, diagnostics);
            if (!parsed.relativePath.empty() && callbacks_.javaDiagnosticsChanged) {
                callbacks_.javaDiagnosticsChanged(std::move(parsed));
            }
        });
}

void WorkbenchSession::resetWorkspaceModels() {
    for (auto& [id, terminal] : terminals_) terminal->stop();
    terminals_.clear();
    terminalFeature_->reset();
    publishTerminalState();
    writeLifecycle_->reset();
    checkoutWriteToken_.reset();
    deferredShelfId_.reset();
    deferredShelfRestoreBusy_ = false;
    closeJavaDocument();
    if (languageServer_) languageServer_->stop();
    languageServerRoot_.clear();
    if (javaDebugService_) javaDebugService_->stop();
    if (javaSession_ && javaSession_->isRunning()) javaSession_->stop();
    workspaceFeature_->resetForWorkspace();
    documentFeature_->resetForWorkspace();
    searchFeature_->resetForWorkspace();
    replacementFeature_->resetForWorkspace();
    gitFeature_->resetForWorkspace();
    historyFeature_->resetForWorkspace();
    shelfFeature_->resetForWorkspace();
    mavenJavaFeature_->resetForWorkspace();
}

void WorkbenchSession::openWorkspace(std::filesystem::path root) {
    std::error_code error;
    root = std::filesystem::weakly_canonical(std::filesystem::absolute(root, error), error);
    if (error || root.empty() || !std::filesystem::is_directory(root, error)) {
        if (callbacks_.statusChanged) callbacks_.statusChanged("The selected workspace is unavailable");
        return;
    }

    if (watcher_) watcher_->stop();
    coordinator_->closeWorkspace();
    resetWorkspaceModels();
    workspaceRoot_ = std::move(root);
    ++workspaceEpoch_;
    const auto persistedSession = workspaceSessionStore_.load(pathUtf8(workspaceRoot_));
    if (!persistedSession.deferredShelfId.empty()) {
        deferredShelfId_ = persistedSession.deferredShelfId;
    }

    std::string persistenceError;
    recentProjectsStore_.record(pathUtf8(workspaceRoot_), persistenceError);
    if (!persistenceError.empty() && callbacks_.statusChanged) {
        callbacks_.statusChanged(persistenceError);
    }

    const auto watchedRoot = pathUtf8(workspaceRoot_);
    watcher_->start(
        watchedRoot,
        [this, watchedRoot](const std::vector<DirectoryChangeSource::Change>& changes) {
            if (pathUtf8(workspaceRoot_) != watchedRoot) return;
            std::vector<DirectoryChangeSource::Change> workspaceChanges;
            workspaceChanges.reserve(changes.size());
            std::copy_if(changes.begin(), changes.end(),
                         std::back_inserter(workspaceChanges), [](const auto& change) {
                const auto normalized = normalizedSlashes(change.path);
                return normalized != ".git" && !normalized.starts_with(".git/");
            });
            if (workspaceChanges.empty()) return;
            auto visibleChanges = writeLifecycle_->observeChanges(std::move(workspaceChanges));
            if (!visibleChanges) return;
            if (callbacks_.filesChanged) callbacks_.filesChanged(std::move(*visibleChanges));
            refreshAfterWrite();
        },
        [this](const std::string& watcherError) {
            if (callbacks_.statusChanged) callbacks_.statusChanged(watcherError);
        });

    workspaceFeature_->open(workspaceRoot_, [this](app::WorkspaceFeatureState state) {
        reportError(state.error, "Workspace request failed");
        if (callbacks_.workspaceChanged) callbacks_.workspaceChanged(std::move(state));
    });
    refreshGit();
    loadHistory();
    scanProject();
}

void WorkbenchSession::closeWorkspace() {
    if (watcher_) watcher_->stop();
    coordinator_->closeWorkspace();
    resetWorkspaceModels();
    workspaceRoot_.clear();
    ++workspaceEpoch_;
    reportStatus("Project closed");
}

ProjectInspection WorkbenchSession::inspectProject(
    const std::filesystem::path& root) const {
    ProjectInspection inspection;
    Win32FileStorage storage;
    app::ProjectDetectionService detection(storage);
    inspection.detection = detection.detect(root);

    Win32RuntimeLocator runtimeLocator;
    app::ProjectRuntimeService runtime(runtimeLocator);
    const auto discovered = runtime.discover();
    inspection.jdkReady = !discovered.javaRuntimes.empty();

    const auto* candidate = inspection.detection.candidates.empty()
        ? nullptr : &inspection.detection.candidates.front();
    inspection.wrapperReady = candidate != nullptr &&
        (candidate->hasMavenWrapper || candidate->hasGradleWrapper);
    inspection.mavenReady = runtime.mavenExecutable(root, {}).has_value();
    if (!inspection.mavenReady) {
        inspection.mavenReady = !discovered.mavenRuntimes.empty();
    }
    return inspection;
}

void WorkbenchSession::openMostRecentWorkspace() {
    std::error_code error;
    for (const auto& path : recentProjectsStore_.load()) {
        const auto candidate = pathFromUtf8(path);
        if (std::filesystem::is_directory(candidate, error)) {
            openWorkspace(candidate);
            return;
        }
        error.clear();
    }
}

void WorkbenchSession::refreshWorkspace() {
    if (workspaceRoot_.empty()) return;
    workspaceFeature_->refresh([this](app::WorkspaceFeatureState state) {
        reportError(state.error, "Workspace refresh failed");
        if (callbacks_.workspaceChanged) callbacks_.workspaceChanged(std::move(state));
    });
    refreshGit();
    loadHistory();
}

bool WorkbenchSession::createWorkspaceItem(std::string parentRelativePath,
                                           std::string name,
                                           bool directory) {
    if (workspaceRoot_.empty() || !validLeafName(name)) {
        reportStatus("Invalid workspace item name");
        return false;
    }
    if (!parentRelativePath.empty() && parentRelativePath != ".") {
        parentRelativePath += "/";
    } else {
        parentRelativePath.clear();
    }
    const auto relativePath = parentRelativePath + name;
    const auto absolute = absoluteWorkspacePath(relativePath);
    if (!absolute) {
        reportStatus("Invalid workspace path");
        return false;
    }
    const auto writeToken = beginWorkspaceWrite(false);
    std::string error;
    const bool succeeded = directory
        ? storage_->createDirectory(pathUtf8(*absolute), false, error)
        : storage_->writeData(pathUtf8(*absolute), {}, error);
    if (!succeeded) {
        finishWorkspaceWrite(writeToken, false);
        reportStatus("Could not create item: " + error);
        return false;
    }
    reportStatus("Created " + relativePath);
    finishWorkspaceWrite(writeToken);
    return true;
}

std::vector<std::string> WorkbenchSession::workspaceFilesForHistory(
    const std::string& relativePath) const {
    std::vector<std::string> result;
    const auto absolute = absoluteWorkspacePath(relativePath);
    const auto paths = coordinator_->workspacePaths();
    if (!absolute || !paths) return result;
    std::error_code error;
    if (std::filesystem::is_regular_file(*absolute, error)) return {relativePath};
    error.clear();
    if (!std::filesystem::is_directory(*absolute, error)) return result;
    std::filesystem::recursive_directory_iterator iterator(
        *absolute, std::filesystem::directory_options::skip_permission_denied, error);
    const std::filesystem::recursive_directory_iterator end;
    while (!error && iterator != end) {
        const auto entry = *iterator;
        if (!entry.is_symlink(error) && entry.is_regular_file(error)) {
            if (const auto relative = paths->toRelative(entry.path())) result.push_back(*relative);
        }
        error.clear();
        iterator.increment(error);
    }
    std::sort(result.begin(), result.end());
    return result;
}

void WorkbenchSession::recordWorkspaceFiles(
    std::vector<std::string> relativePaths,
    const char* reason,
    WorkspaceMutationHandler handler) {
    recordNextWorkspaceFile(std::make_shared<HistoryRecordSequence>(
        HistoryRecordSequence{
            std::move(relativePaths), std::string(reason), std::move(handler), 0}));
}

void WorkbenchSession::recordNextWorkspaceFile(
    std::shared_ptr<HistoryRecordSequence> state) {
    if (state->index >= state->paths.size()) {
        if (state->handler) state->handler(true, {});
        return;
    }
    const auto path = state->paths[state->index++];
    const auto reason = state->reason;
    const bool pruneExpired = state->index == state->paths.size();
    historyFeature_->record(path, reason, std::nullopt, pruneExpired,
        [this, path, state = std::move(state)](app::HistoryFeatureState history) mutable {
            if (callbacks_.historyChanged) callbacks_.historyChanged(history);
            if (history.error) {
                const auto message = history.error->message.empty()
                    ? "Could not preserve " + path + " in Local History"
                    : history.error->message;
                if (state->handler) state->handler(false, message);
                return;
            }
            recordNextWorkspaceFile(std::move(state));
        });
}

void WorkbenchSession::relocateHistoryPaths(
    std::vector<std::pair<std::string, std::string>> relativePaths,
    WorkspaceMutationHandler handler) {
    relocateNextHistoryPath(std::make_shared<HistoryRelocateSequence>(
        HistoryRelocateSequence{std::move(relativePaths), std::move(handler), 0}));
}

void WorkbenchSession::relocateNextHistoryPath(
    std::shared_ptr<HistoryRelocateSequence> state) {
    if (state->index >= state->paths.size()) {
        if (state->handler) state->handler(true, {});
        return;
    }
    const auto [source, destination] = state->paths[state->index++];
    historyFeature_->relocate(source, destination,
        [this, source, state = std::move(state)](app::HistoryFeatureState history) mutable {
            if (callbacks_.historyChanged) callbacks_.historyChanged(history);
            if (history.error) {
                const auto message = history.error->message.empty()
                    ? "Could not relocate Local History for " + source
                    : history.error->message;
                if (state->handler) state->handler(false, message);
                return;
            }
            relocateNextHistoryPath(std::move(state));
        });
}

void WorkbenchSession::renameWorkspaceItem(
    std::string relativePath, std::string name, WorkspaceMutationHandler handler) {
    if (relativePath.empty() || !validLeafName(name)) {
        reportStatus("Invalid workspace item name");
        if (handler) handler(false, "Invalid workspace item name");
        return;
    }
    const auto source = absoluteWorkspacePath(relativePath);
    if (!source) {
        reportStatus("Invalid workspace path");
        if (handler) handler(false, "Invalid workspace path");
        return;
    }
    const auto destination = source->parent_path() / pathFromUtf8(name);
    const auto paths = coordinator_->workspacePaths();
    if (!paths || !paths->contains(destination)) {
        reportStatus("Invalid workspace path");
        if (handler) handler(false, "Invalid workspace path");
        return;
    }
    const auto destinationRelative = paths->toRelative(destination).value_or(name);
    const auto historyPaths = workspaceFilesForHistory(relativePath);
    const auto writeToken = beginWorkspaceWrite(false);
    recordWorkspaceFiles(historyPaths, app::HistoryReason::BeforeRename,
        [this, relativePath = std::move(relativePath), destinationRelative,
         source = *source, destination, historyPaths,
         handler = std::move(handler), writeToken](bool recorded, std::string message) mutable {
            if (!recorded) {
                finishWorkspaceWrite(writeToken, false);
                reportStatus(message);
                if (handler) handler(false, std::move(message));
                return;
            }
            std::string error;
            if (!storage_->moveItem(pathUtf8(source), pathUtf8(destination), error)) {
                finishWorkspaceWrite(writeToken, false);
                message = "Could not rename item: " + error;
                reportStatus(message);
                if (handler) handler(false, std::move(message));
                return;
            }
            std::vector<std::pair<std::string, std::string>> relocations;
            relocations.reserve(historyPaths.size());
            for (const auto& path : historyPaths) {
                const auto suffix = path == relativePath
                    ? std::string{} : path.substr(relativePath.size());
                relocations.emplace_back(path, destinationRelative + suffix);
            }
            relocateHistoryPaths(std::move(relocations),
                [this, destinationRelative, handler = std::move(handler), writeToken](
                    bool relocated, std::string relocateError) mutable {
                    reportStatus(relocated
                        ? "Renamed to " + destinationRelative
                        : "Renamed, but " + relocateError);
                    finishWorkspaceWrite(writeToken);
                    if (handler) handler(true, std::move(relocateError));
                });
        });
}

bool WorkbenchSession::duplicateWorkspaceItem(std::string relativePath, std::string name) {
    if (relativePath.empty() || !validLeafName(name)) {
        reportStatus("Invalid workspace item name");
        return false;
    }
    const auto source = absoluteWorkspacePath(relativePath);
    if (!source) {
        reportStatus("Invalid workspace path");
        return false;
    }
    const auto destination = source->parent_path() / pathFromUtf8(name);
    const auto paths = coordinator_->workspacePaths();
    if (!paths || !paths->contains(destination)) {
        reportStatus("Invalid workspace path");
        return false;
    }
    std::error_code error;
    if (std::filesystem::exists(destination, error)) {
        reportStatus("Destination already exists");
        return false;
    }
    const auto writeToken = beginWorkspaceWrite(false);
    error.clear();
    if (std::filesystem::is_directory(*source, error)) {
        std::filesystem::copy(*source, destination,
                              std::filesystem::copy_options::recursive, error);
    } else {
        std::filesystem::copy_file(*source, destination,
                                   std::filesystem::copy_options::none, error);
    }
    if (error) {
        finishWorkspaceWrite(writeToken, false);
        reportStatus("Could not duplicate item: " + error.message());
        return false;
    }
    reportStatus("Duplicated as " + paths->toRelative(destination).value_or(name));
    finishWorkspaceWrite(writeToken);
    return true;
}

void WorkbenchSession::deleteWorkspaceItem(
    std::string relativePath, WorkspaceMutationHandler handler) {
    if (relativePath.empty()) {
        reportStatus("The workspace root cannot be deleted");
        if (handler) handler(false, "The workspace root cannot be deleted");
        return;
    }
    const auto absolute = absoluteWorkspacePath(relativePath);
    if (!absolute) {
        reportStatus("Invalid workspace path");
        if (handler) handler(false, "Invalid workspace path");
        return;
    }
    const auto historyPaths = workspaceFilesForHistory(relativePath);
    const auto writeToken = beginWorkspaceWrite(false);
    recordWorkspaceFiles(historyPaths, app::HistoryReason::BeforeDelete,
        [this, relativePath = std::move(relativePath), absolute = *absolute,
         handler = std::move(handler), writeToken](bool recorded, std::string message) mutable {
            if (!recorded) {
                finishWorkspaceWrite(writeToken, false);
                reportStatus(message);
                if (handler) handler(false, std::move(message));
                return;
            }
            std::string error;
            if (!storage_->removeItem(pathUtf8(absolute), error)) {
                finishWorkspaceWrite(writeToken, false);
                message = "Could not delete item: " + error;
                reportStatus(message);
                if (handler) handler(false, std::move(message));
                return;
            }
            reportStatus("Deleted " + relativePath);
            finishWorkspaceWrite(writeToken);
            if (handler) handler(true, {});
        });
}

std::optional<std::filesystem::path> WorkbenchSession::absoluteWorkspacePath(
    std::string_view relativePath) const {
    const auto paths = coordinator_->workspacePaths();
    if (!paths) return std::nullopt;
    try {
        return paths->toAbsolute(relativePath);
    } catch (const std::invalid_argument&) {
        return std::nullopt;
    }
}

void WorkbenchSession::openDocument(std::string relativePath) {
    if (workspaceRoot_.empty() || relativePath.empty()) return;
    documentFeature_->open(relativePath, [this](app::DocumentFeatureState state) {
        reportError(state.error, "File request failed");
        if (callbacks_.documentChanged) callbacks_.documentChanged(std::move(state));
    });
    loadDiff({relativePath});
    loadHistory(relativePath);
}

void WorkbenchSession::setDocumentText(std::string text) {
    documentFeature_->setText(std::move(text));
}

void WorkbenchSession::markDocumentExternalConflict(std::string relativePath) {
    documentFeature_->markExternalConflict(std::move(relativePath),
        [this](app::DocumentFeatureState state) {
            if (callbacks_.documentChanged) callbacks_.documentChanged(std::move(state));
        });
}

void WorkbenchSession::keepDocumentEditorVersion() {
    documentFeature_->keepEditorVersion([this](app::DocumentFeatureState state) {
        if (callbacks_.documentChanged) callbacks_.documentChanged(std::move(state));
    });
}

void WorkbenchSession::saveDocument() {
    const auto writeToken = beginWorkspaceWrite(false);
    documentFeature_->save([this, writeToken](app::DocumentFeatureState state) {
        reportError(state.error, "File save failed");
        if (!state.error && !state.isSaving && !state.relativePath.empty()) {
            historyFeature_->record(state.relativePath, app::HistoryReason::Saved, state.text, true,
                [this, writeToken](app::HistoryFeatureState historyState) {
                    if (callbacks_.historyChanged) {
                        callbacks_.historyChanged(std::move(historyState));
                    }
                    finishWorkspaceWrite(writeToken);
                });
        } else {
            finishWorkspaceWrite(writeToken, false);
        }
        if (callbacks_.documentChanged) callbacks_.documentChanged(std::move(state));
    });
}

void WorkbenchSession::saveDocument(std::string relativePath,
                                    std::string text,
                                    DocumentSaveHandler handler) {
    if (workspaceRoot_.empty() || relativePath.empty()) {
        if (handler) handler(false, "No workspace document was selected");
        return;
    }
    auto savedPath = relativePath;
    auto savedText = text;
    const auto writeToken = beginWorkspaceWrite(false);
    coordinator_->writeFile(std::move(relativePath), std::move(text),
        [this, relativePath = std::move(savedPath), text = std::move(savedText),
         handler = std::move(handler), writeToken](app::WorkspaceOperationResult result) mutable {
            const bool succeeded = !result.stale && result.envelope &&
                result.envelope->ok && decodeFileWrite(*result.envelope).has_value();
            std::string message;
            std::optional<CoreError> error;
            if (!succeeded) {
                error = result.coreError();
                message = error && !error->message.empty()
                    ? error->message : "File save failed";
                reportStatus(message);
            }
            if (callbacks_.documentChanged) {
                app::DocumentFeatureState state;
                state.relativePath = relativePath;
                state.text = text;
                state.error = std::move(error);
                state.isDirty = !succeeded;
                callbacks_.documentChanged(std::move(state));
            }
            if (!succeeded) {
                finishWorkspaceWrite(writeToken, false);
                if (handler) handler(false, std::move(message));
                return;
            }
            historyFeature_->record(relativePath, app::HistoryReason::Saved, text, true,
                [this, handler = std::move(handler), writeToken](
                    app::HistoryFeatureState historyState) mutable {
                    const auto historyError = historyState.error;
                    if (callbacks_.historyChanged) {
                        callbacks_.historyChanged(std::move(historyState));
                    }
                    finishWorkspaceWrite(writeToken);
                    if (handler) handler(true, historyError
                        ? historyError->message : std::string{});
                });
        });
}

void WorkbenchSession::restoreHistorySnapshot(std::string relativePath,
                                              std::string snapshotText,
                                              std::string currentText,
                                              DocumentSaveHandler handler) {
    if (workspaceRoot_.empty() || relativePath.empty()) {
        if (handler) handler(false, "No workspace document was selected");
        return;
    }
    historyFeature_->record(
        relativePath, app::HistoryReason::Restored, std::move(currentText), true,
        [this, relativePath = std::move(relativePath),
         snapshotText = std::move(snapshotText),
         handler = std::move(handler)](app::HistoryFeatureState state) mutable {
            if (callbacks_.historyChanged) callbacks_.historyChanged(state);
            if (state.error) {
                if (handler) handler(false, state.error->message.empty()
                    ? "Could not preserve the current file before restoring history"
                    : state.error->message);
                return;
            }
            saveDocument(std::move(relativePath), std::move(snapshotText), std::move(handler));
        });
}

std::optional<std::string> WorkbenchSession::readExternalDocument(
    const std::filesystem::path& path, std::string& error) const {
    const auto metadata = storage_->metadata(pathUtf8(path));
    if (!metadata || !metadata->isRegularFile) {
        error = "The navigation target is not a readable file";
        return std::nullopt;
    }
    constexpr std::uint64_t maximumPreviewBytes = 8 * 1024 * 1024;
    if (metadata->byteCount && *metadata->byteCount > maximumPreviewBytes) {
        error = "The navigation target is too large to preview";
        return std::nullopt;
    }
    auto data = storage_->readData(pathUtf8(path), error);
    if (!data) return std::nullopt;
    std::string result(reinterpret_cast<const char*>(data->data()), data->size());
    if (result.starts_with("\xef\xbb\xbf")) result.erase(0, 3);
    return result;
}

void WorkbenchSession::search(std::string query) {
    if (workspaceRoot_.empty() || query.empty()) return;
    searchFeature_->search(std::move(query), [this](app::SearchFeatureState state) {
        reportError(state.error, "Search failed");
        if (callbacks_.searchChanged) callbacks_.searchChanged(std::move(state));
    });
}

void WorkbenchSession::searchEverywhere(std::string query) {
    if (workspaceRoot_.empty() || query.empty()) return;
    searchFeature_->searchEverywhere(
        std::move(query), [this](app::SearchEverywhereFeatureState state) {
            reportError(state.error, "Search Everywhere failed");
            if (callbacks_.searchEverywhereChanged) {
                callbacks_.searchEverywhereChanged(std::move(state));
            }
        });
}

void WorkbenchSession::previewProjectReplacement(ReplacementPreviewRequestDto request) {
    if (workspaceRoot_.empty() || request.query.empty()) return;
    replacementFeature_->preview(std::move(request),
        [this](app::ReplacementFeatureState state) {
            reportError(state.error, "Replacement preview failed");
            if (callbacks_.replacementChanged) {
                callbacks_.replacementChanged(std::move(state));
            }
        });
}

void WorkbenchSession::renderMarkdown(std::string source) {
    if (workspaceRoot_.empty()) return;
    coordinator_->markdownRender(std::move(source),
        [this](app::WorkspaceOperationResult result) {
            if (result.stale) return;
            MarkdownRenderResult rendered;
            if (result.envelope && result.envelope->ok) {
                if (const auto decoded = decodeMarkdownRender(*result.envelope)) {
                    rendered.html = decoded->html;
                } else {
                    rendered.error = "Invalid Markdown render response";
                }
            } else if (const auto error = result.coreError()) {
                rendered.error = error->message;
            } else {
                rendered.error = "Markdown rendering failed";
            }
            if (callbacks_.markdownRendered) {
                callbacks_.markdownRendered(std::move(rendered));
            }
        });
}

void WorkbenchSession::applyProjectReplacements(
    std::vector<ReplacementFileDto> files,
    std::unordered_map<std::string, std::string> openDocumentTexts) {
    if (workspaceRoot_.empty() || files.empty()) return;
    auto state = std::make_shared<ReplacementApplyState>();
    state->files = std::move(files);
    state->openDocumentTexts = std::move(openDocumentTexts);
    state->workspaceEpoch = workspaceEpoch_.load();
    state->writeToken = beginWorkspaceWrite(false);
    applyNextProjectReplacement(std::move(state));
}

void WorkbenchSession::applyNextProjectReplacement(
    std::shared_ptr<ReplacementApplyState> state) {
    if (state->workspaceEpoch != workspaceEpoch_.load()) {
        finishWorkspaceWrite(state->writeToken, false);
        return;
    }
    if (state->index >= state->files.size()) {
        const auto changed = state->result.appliedFiles.size();
        const auto failed = state->result.failedPaths.size() +
                            state->result.changedSincePreview.size();
        reportStatus("Project replace updated " + std::to_string(changed) +
                     " file(s)" + (failed ? "; skipped " + std::to_string(failed) : ""));
        if (callbacks_.replacementApplied) {
            callbacks_.replacementApplied(std::move(state->result));
        }
        finishWorkspaceWrite(state->writeToken, changed > 0);
        return;
    }
    const auto file = state->files[state->index];
    std::optional<std::string> currentText;
    if (const auto found = state->openDocumentTexts.find(file.path);
        found != state->openDocumentTexts.end()) {
        currentText = found->second;
    } else if (const auto absolute = absoluteWorkspacePath(file.path)) {
        std::string error;
        if (auto data = storage_->readData(pathUtf8(*absolute), error)) {
            // Preserve the exact bytes used by the Rust preview (including a UTF-8
            // BOM) so the stale-preview guard compares like for like.
            currentText = std::string(
                reinterpret_cast<const char*>(data->data()), data->size());
        }
    }
    if (!currentText) {
        state->result.failedPaths.push_back(file.path);
        ++state->index;
        applyNextProjectReplacement(std::move(state));
        return;
    }
    if (*currentText != file.originalText) {
        state->result.changedSincePreview.push_back(file.path);
        ++state->index;
        applyNextProjectReplacement(std::move(state));
        return;
    }
    if (file.replacementText == *currentText) {
        ++state->index;
        applyNextProjectReplacement(std::move(state));
        return;
    }
    historyFeature_->record(file.path, app::HistoryReason::BeforeBatchReplace, *currentText, true,
        [this, state = std::move(state), file](app::HistoryFeatureState history) mutable {
            if (callbacks_.historyChanged) callbacks_.historyChanged(history);
            if (history.error) {
                state->result.failedPaths.push_back(file.path);
                ++state->index;
                applyNextProjectReplacement(std::move(state));
                return;
            }
            coordinator_->writeFile(file.path, file.replacementText,
                [this, state = std::move(state), file](
                    app::WorkspaceOperationResult write) mutable {
                    const bool succeeded = !write.stale && write.envelope &&
                        write.envelope->ok && decodeFileWrite(*write.envelope).has_value();
                    if (succeeded) state->result.appliedFiles.push_back(file);
                    else state->result.failedPaths.push_back(file.path);
                    ++state->index;
                    applyNextProjectReplacement(std::move(state));
                });
        });
}

void WorkbenchSession::refreshGit() {
    if (workspaceRoot_.empty()) return;
    gitFeature_->refreshStatus([this](app::GitFeatureState state) {
        reportError(state.error, "Git status failed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
    gitFeature_->refreshOperationState([this](app::GitFeatureState state) {
        reportError(state.error, "Git operation state failed");
        resumeDeferredShelfIfReady(state);
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
    gitFeature_->refreshConflictMarkers([this](app::GitFeatureState state) {
        reportError(state.error, "Git conflict marker check failed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::performGitWrite(
    GitWriteRequestDto request,
    std::function<void(app::GitFeatureState)> handler) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->write(std::move(request),
        [this, writeToken, handler = std::move(handler)](
            app::GitFeatureState state) mutable {
            const bool finished = !state.isWriting;
            if (handler) handler(std::move(state));
            if (finished) finishWorkspaceWrite(writeToken);
        });
}

void WorkbenchSession::push() {
    GitWriteRequestDto request;
    request.operation = "push";
    performGitWrite(std::move(request), [this](app::GitFeatureState state) {
        reportError(state.error, "Git push failed");
        if (state.command && state.command->exitCode == 0) reportStatus("Git push completed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::fetch() {
    GitWriteRequestDto request;
    request.operation = "fetch";
    performGitWrite(std::move(request), [this](app::GitFeatureState state) {
        reportError(state.error, "Git fetch failed");
        if (state.command && state.command->exitCode == 0) reportStatus("Git fetch completed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::pull(std::string strategy) {
    if (strategy != "ffOnly" && strategy != "merge" && strategy != "rebase") {
        reportStatus("Unknown Git pull strategy");
        return;
    }
    gitFeature_->preflightPull([this, strategy = std::move(strategy)](app::GitFeatureState state) mutable {
        reportError(state.error, "Git pull preflight failed");
        if (state.error || !state.pullPreflight || state.isLoadingPullPreflight) {
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
            return;
        }
        const auto& preflight = *state.pullPreflight;
        if (preflight.hasLocalChanges || (preflight.diverged && strategy == "ffOnly")) {
            std::string message = preflight.hasLocalChanges
                ? "Git pull blocked by local changes"
                : "Git pull fast-forward only blocked by divergent history";
            reportStatus(std::move(message));
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
            return;
        }
        GitWriteRequestDto request;
        request.operation = "pull";
        request.mode = strategy;
        performGitWrite(std::move(request), [this](app::GitFeatureState result) {
            reportError(result.error, "Git pull failed");
            if (result.command && result.command->exitCode == 0) reportStatus("Git pull completed");
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(result));
        });
    });
}

void WorkbenchSession::integrate(std::string reference, std::string operation) {
    if (reference.empty() || (operation != "merge" && operation != "rebase")) {
        reportStatus("A valid Git reference and integration operation are required");
        return;
    }
    gitFeature_->preflightIntegration(reference, operation,
        [this, reference = std::move(reference), operation = std::move(operation)]
        (app::GitFeatureState state) mutable {
            reportError(state.error, "Git integration preflight failed");
            if (state.error || !state.integrationPreflight || state.isLoadingIntegrationPreflight) {
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
                return;
            }
            if (state.integrationPreflight->blocksEntirely ||
                !state.integrationPreflight->blockingPaths.empty()) {
                std::string message = "Git " + operation + " blocked by local changes";
                if (!state.integrationPreflight->blockingPaths.empty()) {
                    message += ": " + state.integrationPreflight->blockingPaths.front();
                }
                reportStatus(std::move(message));
                const auto pending = state.pendingIntegration;
                const auto blockingPaths = state.integrationPreflight->blockingPaths;
                const auto blocksEntirely = state.integrationPreflight->blocksEntirely;
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
                if (pending && callbacks_.integrationBlocked) {
                    callbacks_.integrationBlocked(
                        *pending, std::move(blockingPaths), blocksEntirely);
                }
                return;
            }
            GitWriteRequestDto request;
            request.operation = operation;
            request.reference = std::move(reference);
            performGitWrite(std::move(request), [this, operation](app::GitFeatureState result) {
                reportError(result.error, "Git integration failed");
                if (result.command && result.command->exitCode == 0) {
                    reportStatus("Git " + operation + " completed");
                }
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(result));
            });
        });
}

void WorkbenchSession::cancelIntegrationConflict() {
    gitFeature_->cancelIntegrationConflict();
    if (callbacks_.gitChanged) callbacks_.gitChanged(gitFeature_->state());
    reportStatus("Git integration cancelled");
}

void WorkbenchSession::autoStashIntegration() {
    const auto state = gitFeature_->state();
    if (!state.pendingIntegration) {
        reportStatus("No blocked Git integration is available");
        return;
    }
    const auto pending = *state.pendingIntegration;
    gitFeature_->cancelIntegrationConflict();
    gitFeature_->clearStashRestoreConflict();
    GitWriteRequestDto request;
    request.operation = pending.operation;
    request.autoStash = true;
    if (pending.operation == "merge" || pending.operation == "rebase") {
        request.reference = pending.reference;
    } else if (pending.operation == "cherryPick" || pending.operation == "revert") {
        request.revision = pending.reference;
    } else {
        reportStatus("Unsupported Git integration operation");
        return;
    }
    performGitWrite(std::move(request), [this, operation = pending.operation](
                                            app::GitFeatureState result) {
        const bool deferred = result.command && result.command->stashRestore &&
                              result.command->stashRestore->deferred;
        if (!deferred) reportError(result.error, "Git integration failed");
        if (deferred) {
            reportStatus("Git " + operation +
                         " paused; local changes remain safely stashed");
        } else if (result.command && result.command->exitCode == 0) {
            reportStatus("Git " + operation + " completed and local changes restored");
        }
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(result));
    });
}

void WorkbenchSession::autoShelfIntegration() {
    const auto state = gitFeature_->state();
    if (!state.pendingIntegration) {
        reportStatus("No blocked Git integration is available");
        return;
    }
    const auto pending = *state.pendingIntegration;
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->loadShelfPatches(
        [this, pending, writeToken](std::optional<app::GitShelfPatches> patches,
                                    std::optional<CoreError> error) mutable {
            if (error || !patches) {
                reportError(error, "Shelf patch request failed");
                finishWorkspaceWrite(writeToken, false);
                return;
            }
            if (patches->stagedPatch.empty() && patches->workingTreePatch.empty()) {
                reportStatus("No Git changes to shelve");
                finishWorkspaceWrite(writeToken, false);
                return;
            }
            const auto stagedPatch = patches->stagedPatch;
            const auto workingTreePatch = patches->workingTreePatch;
            shelfFeature_->create(
                "Automatic before Git " + pending.operation,
                stagedPatch, workingTreePatch,
                [this, pending, stagedPatch, workingTreePatch, writeToken](
                    app::ShelfFeatureState shelfState) mutable {
                    reportError(shelfState.error, "Could not create automatic Shelf");
                    if (callbacks_.shelfChanged) callbacks_.shelfChanged(shelfState);
                    if (shelfState.isCreating) return;
                    if (shelfState.error || !shelfState.created) {
                        finishWorkspaceWrite(writeToken, false);
                        return;
                    }
                    const auto shelfId = shelfState.created->shelf.id;
                    if (!persistDeferredShelf(shelfId)) {
                        reportStatus("Automatic Shelf was created but its recovery state could not be saved");
                        finishWorkspaceWrite(writeToken, false);
                        return;
                    }
                    gitFeature_->cleanShelf(
                        stagedPatch, workingTreePatch,
                        [this, pending, shelfId, writeToken](app::GitFeatureState cleanState) mutable {
                            reportError(cleanState.error, "Could not clean the saved Shelf changes");
                            if (callbacks_.gitChanged) callbacks_.gitChanged(cleanState);
                            if (cleanState.isApplying) return;
                            if (cleanState.error || !cleanState.command ||
                                cleanState.command->exitCode != 0) {
                                persistDeferredShelf(std::nullopt);
                                reportStatus("Automatic Shelf is preserved; local changes were not removed");
                                finishWorkspaceWrite(writeToken, false);
                                return;
                            }
                            gitFeature_->cancelIntegrationConflict();
                            GitWriteRequestDto request;
                            request.operation = pending.operation;
                            if (pending.operation == "merge" || pending.operation == "rebase") {
                                request.reference = pending.reference;
                            } else {
                                request.revision = pending.reference;
                            }
                            gitFeature_->write(
                                std::move(request),
                                [this, pending, shelfId, writeToken](app::GitFeatureState result) mutable {
                                    if (callbacks_.gitChanged) callbacks_.gitChanged(result);
                                    if (result.isWriting) return;
                                    gitFeature_->refreshOperationState(
                                        [this, pending, shelfId, writeToken](app::GitFeatureState operationState) mutable {
                                            if (callbacks_.gitChanged) callbacks_.gitChanged(operationState);
                                            if (operationState.isLoadingOperationState) return;
                                            if (operationState.operationState) {
                                                reportStatus("Git " + pending.operation +
                                                             " paused; local changes remain in Lithe Shelf");
                                                finishWorkspaceWrite(writeToken);
                                                return;
                                            }
                                            restoreAutomaticShelf(
                                                shelfId,
                                                [this, pending, writeToken](bool restored) {
                                                    reportStatus(restored
                                                        ? "Git " + pending.operation +
                                                              " ended and local changes were restored"
                                                        : "Git operation ended; Lithe Shelf recovery needs attention");
                                                    finishWorkspaceWrite(writeToken);
                                                });
                                        });
                                });
                        });
                });
        });
}

void WorkbenchSession::replayCommit(std::string revision, std::string operation) {
    if (revision.empty() || (operation != "cherryPick" && operation != "revert")) {
        reportStatus("A valid commit and replay operation are required");
        return;
    }
    gitFeature_->preflightIntegration(revision, operation,
        [this, revision = std::move(revision), operation = std::move(operation)]
        (app::GitFeatureState state) mutable {
            reportError(state.error, "Git replay preflight failed");
            if (state.error || !state.integrationPreflight || state.isLoadingIntegrationPreflight) {
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
                return;
            }
            if (state.integrationPreflight->blocksEntirely ||
                !state.integrationPreflight->blockingPaths.empty()) {
                std::string message = "Git " + operation + " blocked by local changes";
                if (!state.integrationPreflight->blockingPaths.empty()) {
                    message += ": " + state.integrationPreflight->blockingPaths.front();
                }
                reportStatus(std::move(message));
                const auto pending = state.pendingIntegration;
                const auto blockingPaths = state.integrationPreflight->blockingPaths;
                const auto blocksEntirely = state.integrationPreflight->blocksEntirely;
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
                if (pending && callbacks_.integrationBlocked) {
                    callbacks_.integrationBlocked(
                        *pending, std::move(blockingPaths), blocksEntirely);
                }
                return;
            }
            GitWriteRequestDto request;
            request.operation = operation;
            request.revision = std::move(revision);
            performGitWrite(std::move(request), [this, operation](app::GitFeatureState result) {
                reportError(result.error, "Git replay failed");
                if (result.command && result.command->exitCode == 0) {
                    reportStatus("Git " + operation + " completed");
                }
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(result));
            });
        });
}

void WorkbenchSession::resetToRevision(std::string revision, std::string mode) {
    if (revision.empty() || (mode != "--soft" && mode != "--mixed" && mode != "--hard")) {
        reportStatus("A valid revision and reset mode are required");
        return;
    }
    GitWriteRequestDto request;
    request.operation = "reset";
    request.revision = std::move(revision);
    request.mode = std::move(mode);
    performGitWrite(std::move(request), [this](app::GitFeatureState state) {
        reportError(state.error, "Git reset failed");
        if (state.command && state.command->exitCode == 0) reportStatus("Git reset completed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::resolveGitOperation(std::string action) {
    if (action != "operationContinue" && action != "operationAbort" &&
        action != "operationSkip") {
        reportStatus("Unknown Git operation action");
        return;
    }
    GitWriteRequestDto request;
    request.operation = std::move(action);
    const auto before = gitFeature_->state();
    const bool hasDeferredShelf = deferredShelfId_.has_value();
    const bool hasDeferredRestore = before.stashRestoreConflict &&
                                    before.stashRestoreConflict->deferred;
    if (hasDeferredRestore) {
        request.autoStash = true;
        request.reference = before.stashRestoreConflict->stashReference;
    }
    performGitWrite(std::move(request), [this, hasDeferredRestore, hasDeferredShelf](
                                            app::GitFeatureState state) {
        reportError(state.error, "Git operation resolution failed");
        if (hasDeferredRestore && state.command &&
            (!state.command->stashRestore || !state.command->stashRestore->deferred)) {
            if (!state.command->stashRestore) {
                gitFeature_->clearStashRestoreConflict();
                state = gitFeature_->state();
            }
            reportStatus(state.command && state.command->stashRestore
                ? "Git operation completed; restoring local changes needs attention"
                : state.command && state.command->exitCode == 0
                    ? "Git operation completed and local changes restored"
                    : "Git operation ended and local changes were restored");
        } else if (state.command && state.command->stashRestore &&
                   state.command->stashRestore->deferred) {
            reportStatus("Git operation is still in progress; local changes remain stashed");
        } else if (state.command && state.command->exitCode == 0) {
            reportStatus("Git operation updated");
        }
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (hasDeferredShelf) {
            gitFeature_->refreshOperationState([this](app::GitFeatureState operationState) {
                resumeDeferredShelfIfReady(operationState);
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(operationState));
            });
        }
    });
}

void WorkbenchSession::loadDiff(std::vector<std::string> paths, bool staged) {
    if (workspaceRoot_.empty()) return;
    gitFeature_->loadDiff(std::move(paths), staged, false,
        [this](app::GitFeatureState state) {
            reportError(state.error, "Diff request failed");
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        });
}

void WorkbenchSession::loadGitHistory() {
    if (workspaceRoot_.empty()) return;
    gitFeature_->refreshHistory(std::nullopt, 300, [this](app::GitFeatureState state) {
        reportError(state.error, "Git history failed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::loadGitCommit(std::string hash) {
    if (workspaceRoot_.empty() || hash.empty()) return;
    const auto deliver = [this](app::GitFeatureState state) {
        reportError(state.error, "Git commit request failed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    };
    gitFeature_->loadCommit(hash, deliver);
    gitFeature_->loadCommitFiles(std::move(hash), deliver);
}

void WorkbenchSession::loadGitCommitDiff(std::string hash, std::string path) {
    if (workspaceRoot_.empty() || hash.empty() || path.empty()) return;
    gitFeature_->loadCommitDiff(std::move(hash), {std::move(path)},
        [this](app::GitFeatureState state) {
            reportError(state.error, "Commit diff request failed");
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        });
}

void WorkbenchSession::loadGitComparison(std::string reference) {
    if (workspaceRoot_.empty() || reference.empty()) return;
    gitFeature_->loadComparison(std::move(reference), [this](app::GitFeatureState state) {
        reportError(state.error, "Git comparison failed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::loadGitStashes() {
    if (workspaceRoot_.empty()) return;
    gitFeature_->refreshStashes([this](app::GitFeatureState state) {
        reportError(state.error, "Git stashes failed");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::loadGitBlame(std::string relativePath) {
    if (relativePath.empty()) return;
    gitFeature_->loadBlame(std::move(relativePath), [this](app::GitFeatureState state) {
        reportError(state.error, "Could not load Git blame");
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
    });
}

void WorkbenchSession::stage(std::vector<std::string> paths) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->stage(std::move(paths), [this, writeToken](app::GitFeatureState state) {
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::unstage(std::vector<std::string> paths) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->unstage(std::move(paths), [this, writeToken](app::GitFeatureState state) {
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::discard(std::vector<std::string> paths) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->discard(std::move(paths), [this, writeToken](app::GitFeatureState state) {
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::rollbackConflictPath(std::string path,
                                            WorkspaceMutationHandler handler) {
    if (workspaceRoot_.empty() || path.empty()) {
        if (handler) handler(false, "Select one blocked path to roll back");
        return;
    }
    const auto state = gitFeature_->state();
    const auto contains = [&path](const std::vector<std::string>& paths) {
        return std::find(paths.begin(), paths.end(), path) != paths.end();
    };
    const bool operationBlocked = contains(state.conflictFilterPaths);
    const bool preflightBlocked = state.pendingIntegration && state.integrationPreflight &&
                                  contains(state.integrationPreflight->blockingPaths);
    if (!operationBlocked && !preflightBlocked) {
        if (handler) handler(false, "The selected path is no longer blocking a Git operation");
        return;
    }
    GitWriteRequestDto request;
    request.operation = "discardAll";
    request.paths = {std::move(path)};
    performGitWrite(
        std::move(request),
        [this, handler = std::move(handler)](app::GitFeatureState state) mutable {
            const bool succeeded = !state.error && state.command &&
                                   state.command->exitCode == 0;
            std::string error;
            if (!succeeded) {
                error = state.error ? state.error->message : "Could not roll back blocked path";
            }
            if (callbacks_.gitChanged) callbacks_.gitChanged(state);
            if (handler) handler(succeeded, std::move(error));
        });
}

void WorkbenchSession::stageAll() {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->stageAll([this, writeToken](app::GitFeatureState state) {
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::commit(std::string message, bool amend) {
    commitWithSafety(std::move(message), amend, false);
}

void WorkbenchSession::commitAndPush(std::string message, bool amend) {
    commitWithSafety(std::move(message), amend, true);
}

void WorkbenchSession::commitWithSafety(
    std::string message, bool amend, bool pushAfterCommit) {
    if (message.empty()) return;
    gitFeature_->preflightCommit(
        [this, message = std::move(message), amend, pushAfterCommit](
            app::GitFeatureState state) mutable {
        reportError(state.error, "Commit safety check failed");
        const bool ready = !state.error && !state.isLoadingStatus &&
                           !state.isLoadingConflictMarkers && state.status &&
                           state.conflictMarkers;
        std::optional<app::GitCommitSafety> safety;
        if (ready) {
            safety = app::evaluateGitCommitSafety(*state.status, *state.conflictMarkers);
        }
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (!ready) {
            reportStatus("Commit was not started because the safety check did not complete");
            return;
        }
        if (!safety->blockingPaths.empty()) {
            reportStatus("Commit blocked by unresolved conflicts: " +
                         safety->blockingPaths.front());
            return;
        }

        const auto writeToken = beginWorkspaceWrite(true);
        gitFeature_->commit(std::move(message), amend,
            [this, writeToken, pushAfterCommit](app::GitFeatureState commitState) {
            reportError(commitState.error, "Commit failed");
            const bool committed = !commitState.error && !commitState.isWriting &&
                                   commitState.command &&
                                   commitState.command->exitCode == 0;
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(commitState));
            if (!committed || !pushAfterCommit) {
                if (committed) reportStatus("Commit completed");
                finishWorkspaceWrite(writeToken);
                return;
            }
            reportStatus("Commit completed; pushing...");
            GitWriteRequestDto request;
            request.operation = "push";
            gitFeature_->write(std::move(request),
                [this, writeToken](app::GitFeatureState pushState) {
                reportError(pushState.error, "Git push failed");
                if (pushState.command && pushState.command->exitCode == 0) {
                    reportStatus("Committed and pushed");
                }
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(pushState));
                finishWorkspaceWrite(writeToken);
            });
        });
    });
}

void WorkbenchSession::checkout(std::string reference, std::string kind) {
    if (workspaceRoot_.empty() || reference.empty()) return;
    if (checkoutWriteToken_) {
        finishWorkspaceWrite(*checkoutWriteToken_, false);
        checkoutWriteToken_.reset();
    }
    const auto writeToken = beginWorkspaceWrite(true);
    checkoutWriteToken_ = writeToken;
    gitFeature_->checkout(std::move(reference), std::move(kind),
        [this, writeToken](app::GitFeatureState state) {
            reportError(state.error, "Could not switch Git reference");
            const bool blocked = !state.error && !state.isLoadingCheckoutPreflight &&
                state.checkoutPreflight && !state.checkoutPreflight->blockingPaths.empty() &&
                state.pendingCheckout.has_value();
            if (blocked) {
                reportStatus("Checkout blocked by " +
                             std::to_string(state.checkoutPreflight->blockingPaths.size()) +
                             " local path(s)");
            }
            const bool finished = !blocked && !state.isLoadingCheckoutPreflight &&
                                  !state.isWriting;
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
            if (blocked && callbacks_.checkoutBlocked) {
                const auto current = gitFeature_->state();
                if (current.pendingCheckout && current.checkoutPreflight) {
                    callbacks_.checkoutBlocked(*current.pendingCheckout,
                                               current.checkoutPreflight->blockingPaths);
                }
            }
            if (finished) {
                finishWorkspaceWrite(writeToken);
                if (checkoutWriteToken_ == writeToken) checkoutWriteToken_.reset();
            }
        });
}

void WorkbenchSession::resolveCheckoutConflict(std::string strategy) {
    const auto writeToken = checkoutWriteToken_
        ? *checkoutWriteToken_
        : beginWorkspaceWrite(true);
    checkoutWriteToken_ = writeToken;
    gitFeature_->resolveCheckoutConflict(std::move(strategy),
        [this, writeToken](app::GitFeatureState state) {
            reportError(state.error, "Could not switch Git reference");
            const bool finished = !state.isWriting && !state.pendingCheckout;
            if (state.command && state.command->exitCode == 0) {
                reportStatus("Checked out branch and applied the selected change strategy");
            }
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
            if (finished) {
                finishWorkspaceWrite(writeToken);
                if (checkoutWriteToken_ == writeToken) checkoutWriteToken_.reset();
            }
        });
}

void WorkbenchSession::cancelCheckoutConflict() {
    gitFeature_->cancelCheckoutConflict();
    if (checkoutWriteToken_) {
        finishWorkspaceWrite(*checkoutWriteToken_, false);
        checkoutWriteToken_.reset();
    }
    if (callbacks_.gitChanged) callbacks_.gitChanged(gitFeature_->state());
    reportStatus("Checkout cancelled");
}

void WorkbenchSession::createBranch(std::string name) {
    if (workspaceRoot_.empty() || name.empty()) return;
    GitWriteRequestDto request;
    request.operation = "createBranch";
    request.name = name;
    request.reference = "HEAD";
    request.checkout = true;
    performGitWrite(std::move(request), [this, name = std::move(name)](
                                                app::GitFeatureState state) {
        reportError(state.error, "Could not create branch");
        const bool finished = !state.error && !state.isWriting;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (finished) {
            reportStatus("Created branch " + name);
        }
    });
}

void WorkbenchSession::renameBranch(std::string reference, std::string name) {
    if (workspaceRoot_.empty() || reference.empty() || name.empty()) return;
    GitWriteRequestDto request;
    request.operation = "renameBranch";
    request.reference = std::move(reference);
    request.name = std::move(name);
    performGitWrite(std::move(request), [this](app::GitFeatureState state) {
        reportError(state.error, "Could not rename branch");
        const bool finished = !state.error && !state.isWriting;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (finished) {
            reportStatus("Branch renamed");
        }
    });
}

void WorkbenchSession::deleteBranch(std::string reference) {
    if (workspaceRoot_.empty() || reference.empty()) return;
    GitWriteRequestDto request;
    request.operation = "deleteBranch";
    request.reference = std::move(reference);
    performGitWrite(std::move(request), [this](app::GitFeatureState state) {
        reportError(state.error, "Could not delete branch");
        const bool finished = !state.error && !state.isWriting;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (finished) {
            reportStatus("Branch deleted");
        }
    });
}

void WorkbenchSession::stash(std::string message, bool includeUntracked) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->stash(std::move(message), includeUntracked,
        [this, writeToken](app::GitFeatureState state) {
            reportError(state.error, "Could not create stash");
            const bool finished = !state.isWriting;
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
            if (finished) finishWorkspaceWrite(writeToken);
        });
}

void WorkbenchSession::applyStash(std::string reference) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->applyStash(std::move(reference), [this, writeToken](app::GitFeatureState state) {
        reportError(state.error, "Could not apply stash");
        const bool finished = !state.isWriting;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (finished) finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::popStash(std::string reference) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->popStash(std::move(reference), [this, writeToken](app::GitFeatureState state) {
        reportError(state.error, "Could not pop stash");
        const bool finished = !state.isWriting;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (finished) finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::dropStash(std::string reference) {
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->dropStash(std::move(reference), [this, writeToken](app::GitFeatureState state) {
        reportError(state.error, "Could not drop stash");
        const bool finished = !state.isWriting;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
        if (finished) finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::applyHunk(std::string hunkID, std::string mode) {
    if (hunkID.empty() || mode.empty()) return;
    const auto state = gitFeature_->state();
    if (!state.diff || state.isApplying) return;
    const auto hunk = std::find_if(state.diff->hunks.begin(), state.diff->hunks.end(),
        [&hunkID](const GitDiffHunkDto& value) { return value.id == hunkID; });
    if (hunk == state.diff->hunks.end()) {
        reportStatus("The selected diff hunk is no longer available");
        return;
    }
    const auto writeToken = beginWorkspaceWrite(true);
    gitFeature_->apply(hunk->patch, std::move(mode), [this, writeToken](app::GitFeatureState next) {
        reportError(next.error, "Could not apply diff hunk");
        const bool finished = !next.isApplying;
        if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(next));
        if (finished) finishWorkspaceWrite(writeToken);
    });
}

void WorkbenchSession::cloneRepository(std::string remote,
                                       std::filesystem::path parentDirectory,
                                       std::string folderName,
                                       WorkspaceMutationHandler handler) {
    if (remote.empty() || !validLeafName(folderName)) {
        reportStatus("Repository URL and a valid folder name are required");
        if (handler) handler(false, "Repository URL and a valid folder name are required");
        return;
    }
    std::error_code error;
    parentDirectory = std::filesystem::weakly_canonical(
        std::filesystem::absolute(parentDirectory, error), error);
    if (error || !std::filesystem::is_directory(parentDirectory, error)) {
        reportStatus("The clone parent folder is unavailable");
        if (handler) handler(false, "The clone parent folder is unavailable");
        return;
    }
    const auto destination = parentDirectory / pathFromUtf8(folderName);
    if (std::filesystem::exists(destination, error)) {
        reportStatus("The clone destination already exists");
        if (handler) handler(false, "The clone destination already exists");
        return;
    }
    gitFeature_->cloneRepository(
        std::move(remote), pathUtf8(destination), pathUtf8(parentDirectory),
        [this, handler = std::move(handler)](app::GitFeatureState state) mutable {
            reportError(state.error, "Repository clone failed");
            const bool finished = !state.isWriting;
            const bool succeeded = finished && !state.error;
            const auto message = state.error
                ? (state.error->message.empty() ? "Repository clone failed" : state.error->message)
                : std::string{};
            if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(state));
            if (finished && handler) handler(succeeded, message);
        });
}

void WorkbenchSession::loadHistory(std::optional<std::string> relativePath) {
    if (workspaceRoot_.empty()) return;
    historyFeature_->loadEntries(std::move(relativePath), [this](app::HistoryFeatureState state) {
        reportError(state.error, "Local History failed");
        if (callbacks_.historyChanged) callbacks_.historyChanged(std::move(state));
    });
}

void WorkbenchSession::loadHistoryContent(std::string contentPath) {
    if (workspaceRoot_.empty() || contentPath.empty()) return;
    historyFeature_->loadContent(std::move(contentPath),
        [this](app::HistoryFeatureState state) {
            reportError(state.error, "Local History content failed");
            if (callbacks_.historyChanged) callbacks_.historyChanged(std::move(state));
        });
}

void WorkbenchSession::loadShelves() {
    if (workspaceRoot_.empty()) return;
    shelfFeature_->load([this](app::ShelfFeatureState state) {
        reportError(state.error, "Shelf request failed");
        if (callbacks_.shelfChanged) callbacks_.shelfChanged(std::move(state));
    });
}

void WorkbenchSession::createShelf(std::string label) {
    if (workspaceRoot_.empty() || label.empty()) return;
    gitFeature_->loadShelfPatches(
        [this, label = std::move(label)](
            std::optional<app::GitShelfPatches> patches,
            std::optional<CoreError> error) mutable {
            if (error) {
                reportError(error, "Shelf patch request failed");
                return;
            }
            if (!patches ||
                (patches->stagedPatch.empty() && patches->workingTreePatch.empty())) {
                reportStatus("No Git changes to shelve");
                return;
            }
            shelfFeature_->create(std::move(label), patches->stagedPatch,
                                  patches->workingTreePatch,
                [this](app::ShelfFeatureState state) {
                    reportError(state.error, "Could not create Shelf");
                    const bool finished = !state.error && !state.isCreating;
                    if (callbacks_.shelfChanged) callbacks_.shelfChanged(std::move(state));
                    if (finished) {
                        reportStatus("Shelf created");
                        loadShelves();
                    }
                });
        });
}

void WorkbenchSession::restoreShelf(std::string id) {
    if (workspaceRoot_.empty() || id.empty()) return;
    const auto writeToken = beginWorkspaceWrite(true);
    shelfFeature_->restore(std::move(id), [this, writeToken](app::ShelfFeatureState state) {
        reportError(state.error, "Could not read Shelf");
        if (callbacks_.shelfChanged) callbacks_.shelfChanged(state);
        if (state.isRestoring) return;
        if (state.error || !state.restored) {
            finishWorkspaceWrite(writeToken, false);
            return;
        }
        const auto workingTreePatch = state.restored->workingTreePatch;
        const auto applyWorkingTree = [this, writeToken, workingTreePatch]() {
            if (workingTreePatch.empty()) {
                reportStatus("Shelf restored");
                finishWorkspaceWrite(writeToken);
                return;
            }
            gitFeature_->apply(workingTreePatch, "worktree",
                [this, writeToken](app::GitFeatureState gitState) {
                    reportError(gitState.error, "Could not restore Shelf working tree");
                    const bool finished = !gitState.isApplying;
                    const bool succeeded = !gitState.error;
                    if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(gitState));
                    if (finished) {
                        if (succeeded) reportStatus("Shelf restored");
                        finishWorkspaceWrite(writeToken);
                    }
                });
        };
        if (state.restored->stagedPatch.empty()) {
            applyWorkingTree();
            return;
        }
        gitFeature_->apply(state.restored->stagedPatch, "restoreIndex",
            [this, writeToken, applyWorkingTree](app::GitFeatureState gitState) {
                reportError(gitState.error, "Could not restore Shelf index");
                const bool finished = !gitState.isApplying;
                const bool succeeded = !gitState.error;
                if (callbacks_.gitChanged) callbacks_.gitChanged(std::move(gitState));
                if (!finished) return;
                if (succeeded) applyWorkingTree();
                else finishWorkspaceWrite(writeToken);
            });
    });
}

bool WorkbenchSession::persistDeferredShelf(std::optional<std::string> id) {
    if (workspaceRoot_.empty()) return false;
    auto session = workspaceSessionStore_.load(pathUtf8(workspaceRoot_));
    session.deferredShelfId = id.value_or(std::string{});
    session = app::sanitizeWorkspaceSession(workspaceRoot_, std::move(session));
    std::string error;
    if (!workspaceSessionStore_.save(pathUtf8(workspaceRoot_), session, error)) {
        reportStatus("Could not save Shelf recovery state: " + error);
        return false;
    }
    deferredShelfId_ = std::move(id);
    return true;
}

void WorkbenchSession::restoreAutomaticShelf(std::string id,
                                             std::function<void(bool)> handler) {
    if (workspaceRoot_.empty() || id.empty() || deferredShelfRestoreBusy_) {
        if (handler) handler(false);
        return;
    }
    deferredShelfRestoreBusy_ = true;
    const std::function<void(bool)> finish =
        [this, handler = std::move(handler)](bool restored) {
        deferredShelfRestoreBusy_ = false;
        if (handler) handler(restored);
    };
    shelfFeature_->restore(
        id, [this, id = std::move(id), finish](app::ShelfFeatureState state) {
            reportError(state.error, "Could not read automatic Shelf");
            if (callbacks_.shelfChanged) callbacks_.shelfChanged(state);
            if (state.isRestoring) return;
            if (state.error || !state.restored) {
                finish(false);
                return;
            }
            const auto workingTreePatch = state.restored->workingTreePatch;
            const auto deleteAfterRestore =
                [this, id, finish](bool restored) {
                    if (!restored) {
                        finish(false);
                        return;
                    }
                    shelfFeature_->remove(
                        id, [this, finish](app::ShelfFeatureState deleteState) {
                            reportError(deleteState.error, "Could not remove restored automatic Shelf");
                            if (callbacks_.shelfChanged) callbacks_.shelfChanged(deleteState);
                            if (deleteState.isDeleting) return;
                            if (deleteState.error || !deleteState.deleted ||
                                !deleteState.deleted->deleted) {
                                finish(false);
                                return;
                            }
                            const bool persisted = persistDeferredShelf(std::nullopt);
                            loadShelves();
                            finish(persisted);
                        });
                };
            const auto applyWorkingTree =
                [this, workingTreePatch, deleteAfterRestore]() {
                    if (workingTreePatch.empty()) {
                        deleteAfterRestore(true);
                        return;
                    }
                    gitFeature_->apply(
                        workingTreePatch, "worktreeCheck",
                        [this, workingTreePatch, deleteAfterRestore](
                            app::GitFeatureState checkState) {
                            if (checkState.isApplying) return;
                            const bool alreadyApplied = checkState.command &&
                                checkState.command->exitCode == 0;
                            if (alreadyApplied) {
                                deleteAfterRestore(true);
                                return;
                            }
                            gitFeature_->apply(
                                workingTreePatch, "worktree",
                                [this, deleteAfterRestore](app::GitFeatureState gitState) {
                                    reportError(gitState.error,
                                                "Could not restore automatic Shelf working tree");
                                    const bool finished = !gitState.isApplying;
                                    const bool succeeded = !gitState.error && gitState.command &&
                                                           gitState.command->exitCode == 0;
                                    if (callbacks_.gitChanged) {
                                        callbacks_.gitChanged(std::move(gitState));
                                    }
                                    if (finished) deleteAfterRestore(succeeded);
                                });
                        });
                };
            if (state.restored->stagedPatch.empty()) {
                applyWorkingTree();
                return;
            }
            gitFeature_->apply(
                state.restored->stagedPatch, "restoreIndexCheck",
                [this, stagedPatch = state.restored->stagedPatch,
                 applyWorkingTree, finish](app::GitFeatureState checkState) {
                    if (checkState.isApplying) return;
                    const bool alreadyApplied = checkState.command &&
                        checkState.command->exitCode == 0;
                    if (alreadyApplied) {
                        applyWorkingTree();
                        return;
                    }
                    gitFeature_->apply(
                        stagedPatch, "restoreIndex",
                        [this, applyWorkingTree, finish](app::GitFeatureState gitState) {
                            reportError(gitState.error,
                                        "Could not restore automatic Shelf index");
                            const bool finished = !gitState.isApplying;
                            const bool succeeded = !gitState.error && gitState.command &&
                                                   gitState.command->exitCode == 0;
                            if (callbacks_.gitChanged) {
                                callbacks_.gitChanged(std::move(gitState));
                            }
                            if (!finished) return;
                            if (succeeded) applyWorkingTree();
                            else finish(false);
                        });
                });
        });
}

void WorkbenchSession::resumeDeferredShelfIfReady(const app::GitFeatureState& state) {
    if (state.error || state.isLoadingOperationState || state.operationState ||
        !deferredShelfId_ || deferredShelfRestoreBusy_) {
        return;
    }
    const auto id = *deferredShelfId_;
    reportStatus("Restoring deferred Lithe Shelf");
    restoreAutomaticShelf(id, [this](bool restored) {
        reportStatus(restored
            ? "Deferred Lithe Shelf restored"
            : "Deferred Lithe Shelf recovery needs attention");
    });
}

void WorkbenchSession::deleteShelf(std::string id) {
    if (workspaceRoot_.empty() || id.empty()) return;
    shelfFeature_->remove(std::move(id), [this](app::ShelfFeatureState state) {
        reportError(state.error, "Could not delete Shelf");
        const bool finished = !state.error && !state.isDeleting;
        if (callbacks_.shelfChanged) callbacks_.shelfChanged(std::move(state));
        if (finished) {
            reportStatus("Shelf deleted");
            loadShelves();
        }
    });
}

void WorkbenchSession::scanProject() {
    if (workspaceRoot_.empty()) return;
    mavenJavaFeature_->scanMaven([this](app::MavenJavaFeatureState state) {
        reportError(state.error, "Project analysis failed");
        if (callbacks_.analysisChanged) callbacks_.analysisChanged(std::move(state));
    });
    mavenJavaFeature_->loadRunConfigurations({}, {}, [this](app::MavenJavaFeatureState state) {
        if (callbacks_.analysisChanged) callbacks_.analysisChanged(std::move(state));
    });
}

void WorkbenchSession::analyzeJavaDocument(std::string relativePath,
                                           std::string sourceText) {
    if (relativePath.empty() || !relativePath.ends_with(".java")) return;
    mavenJavaFeature_->loadCodeVision(
        relativePath, {relativePath}, [this](app::MavenJavaFeatureState state) {
            reportError(state.error, "Java code vision failed");
            if (callbacks_.analysisChanged) callbacks_.analysisChanged(std::move(state));
        });
    mavenJavaFeature_->loadJavaStructure(
        std::move(sourceText), {}, [this](app::MavenJavaFeatureState state) {
            reportError(state.error, "Java structure analysis failed");
            if (callbacks_.analysisChanged) callbacks_.analysisChanged(std::move(state));
        });
}

std::string WorkbenchSession::createTerminal() {
    if (workspaceRoot_.empty()) return {};
    const auto id = terminalFeature_->create(
        defaultTerminalShell(), pathUtf8(workspaceRoot_));
    auto terminal = std::make_unique<Win32TerminalTransport>();
    terminal->setOutputHandler([this, id](const std::string& output) {
        if (terminalFeature_->appendOutput(id, output) && callbacks_.terminalOutputChanged) {
            callbacks_.terminalOutputChanged(id);
        }
    });
    terminal->setErrorHandler([this, id](const std::string& error) {
        if (terminalFeature_->appendOutput(id, error) && callbacks_.terminalOutputChanged) {
            callbacks_.terminalOutputChanged(id);
        }
    });
    terminal->setExitHandler([this, id] {
        if (!terminalFeature_->markExited(id)) return;
        terminalFeature_->appendOutput(id, "\r\n[Process exited]\r\n");
        if (callbacks_.terminalOutputChanged) callbacks_.terminalOutputChanged(id);
        publishTerminalState();
        if (callbacks_.statusChanged) callbacks_.statusChanged("Terminal exited");
    });
    terminals_.emplace(id, std::move(terminal));
    publishTerminalState();
    startTerminal(id);
    return id;
}

void WorkbenchSession::selectTerminal(std::string id) {
    if (terminalFeature_->select(id)) publishTerminalState();
}

void WorkbenchSession::setTerminalShell(std::string id, std::string shellPath) {
    if (shellPath.empty()) shellPath = defaultTerminalShell();
    if (!terminalFeature_->setShell(id, std::move(shellPath))) return;
    publishTerminalState();
    reportStatus("Terminal shell will be used on the next restart");
}

void WorkbenchSession::clearTerminal(std::string id) {
    if (!terminalFeature_->clearOutput(id)) return;
    if (callbacks_.terminalOutputChanged) callbacks_.terminalOutputChanged(std::move(id));
}

app::TerminalFeatureState WorkbenchSession::terminalState() const {
    return terminalFeature_->state();
}

std::string WorkbenchSession::terminalOutput(std::string_view id) const {
    return terminalFeature_->output(id);
}

std::string WorkbenchSession::defaultTerminalShell() const {
    if (!settings_.terminalShellPath.empty()) return settings_.terminalShellPath;
    const auto environment = runtimeLocator_.environment();
    for (const auto& [key, value] : environment) {
        if (equalIgnoreCase(key, "ComSpec")) return value;
    }
    return "cmd.exe";
}

void WorkbenchSession::publishTerminalState() const {
    if (callbacks_.terminalsChanged) callbacks_.terminalsChanged(terminalFeature_->state());
}

void WorkbenchSession::startTerminal(std::string id) {
    const auto found = terminals_.find(id);
    if (workspaceRoot_.empty() || found == terminals_.end() || found->second->isRunning()) return;
    const auto session = terminalFeature_->session(id);
    if (!session) return;
    const auto environment = runtimeLocator_.environment();
    terminalFeature_->markStarting(id);
    publishTerminalState();
    ProcessRequest request;
    request.operationID = operationID("windows-terminal");
    request.executablePath = session->shellPath;
    request.workingDirectory = session->workingDirectory;
    request.environment = environment;
    found->second->start(request);
    if (found->second->isRunning()) {
        terminalFeature_->markRunning(id);
    } else if (const auto current = terminalFeature_->session(id);
               current && current->status != app::TerminalSessionStatus::Exited) {
        terminalFeature_->markStopped(id);
    }
    publishTerminalState();
    if (callbacks_.statusChanged) callbacks_.statusChanged("Terminal started");
}

void WorkbenchSession::sendTerminal(std::string id, std::string input) {
    auto found = terminals_.find(id);
    if (found == terminals_.end()) return;
    if (!found->second->isRunning()) startTerminal(id);
    found = terminals_.find(id);
    if (found != terminals_.end() && found->second->isRunning()) {
        found->second->send(std::move(input) + "\r\n");
    }
}

void WorkbenchSession::interruptTerminal(std::string id) {
    const auto found = terminals_.find(id);
    if (found != terminals_.end() && found->second->isRunning()) {
        found->second->send(std::string(1, '\x03'));
    }
}

void WorkbenchSession::resizeTerminal(std::string id, int columns, int rows) {
    const auto found = terminals_.find(id);
    if (found != terminals_.end() && found->second->isRunning()) {
        found->second->resize(columns, rows);
    }
}

void WorkbenchSession::stopTerminal(std::string id) {
    const auto found = terminals_.find(id);
    if (found != terminals_.end()) {
        found->second->stop();
        terminalFeature_->markStopped(id);
        publishTerminalState();
    }
}

void WorkbenchSession::closeTerminal(std::string id) {
    const auto found = terminals_.find(id);
    if (found == terminals_.end()) return;
    found->second->stop();
    terminals_.erase(found);
    terminalFeature_->remove(id);
    publishTerminalState();
}

void WorkbenchSession::runMaven(std::string phase) {
    if (workspaceRoot_.empty() || phase.empty()) return;
    if (buildSession_->isRunning()) buildSession_->stop();
    app::MavenBuildRequest request;
    request.projectRoot = workspaceRoot_;
    request.phase = std::move(phase);
    std::string error;
    const auto process = mavenBuildService_.makeRequest(request, error);
    if (!process) {
        if (callbacks_.buildOutput) callbacks_.buildOutput("Unable to start Maven: " + error + "\n");
        reportError(std::nullopt, "Maven could not start");
        return;
    }
    if (callbacks_.buildOutput) {
        std::string command = "$ " + process->executablePath;
        for (const auto& argument : process->arguments) command += " " + argument;
        callbacks_.buildOutput(command + "\n\n");
    }
    buildSession_->start(*process);
}

void WorkbenchSession::stopBuild() {
    if (buildSession_->isRunning()) buildSession_->stop();
}

void WorkbenchSession::synchronizeJavaRunProject() {
    if (workspaceRoot_.empty()) return;
    app::JavaRunProject project;
    project.root = workspaceRoot_;
    const auto workspaceState = workspaceFeature_->state();
    if (workspaceState.snapshot) {
        project.files.reserve(workspaceState.snapshot->files.size());
        for (const auto& path : workspaceState.snapshot->files) {
            project.files.push_back(project.root / pathFromUtf8(path));
        }
    }
    const auto analysisState = mavenJavaFeature_->state();
    if (analysisState.maven && analysisState.maven->scan) {
        project.maven = *analysisState.maven->scan;
    }
    if (analysisState.runConfigurations) {
        project.configurations = analysisState.runConfigurations->configurations;
    }
    javaRunService_->setProject(std::move(project));
}

std::optional<JavaRunConfigurationDto> WorkbenchSession::javaConfiguration(
    std::string_view idOrKind) const {
    const auto& configurations = javaRunService_->project().configurations;
    const auto found = std::find_if(configurations.begin(), configurations.end(),
        [&](const JavaRunConfigurationDto& value) {
            return value.id == idOrKind || value.kind == idOrKind;
        });
    return found == configurations.end()
        ? std::nullopt : std::optional<JavaRunConfigurationDto>(*found);
}

void WorkbenchSession::runCurrentJava(std::string relativePath) {
    JavaRunConfigurationDto configuration;
    configuration.id = "current-file";
    configuration.name = "Current File";
    configuration.kind = "currentFile";
    runJavaConfiguration(configuration, std::move(relativePath));
}

void WorkbenchSession::runSpringBoot(std::string relativePath) {
    synchronizeJavaRunProject();
    const auto configuration = javaConfiguration("springBoot");
    if (!configuration) {
        reportStatus("No Spring Boot run configuration was detected");
        return;
    }
    runJavaConfiguration(*configuration, std::move(relativePath));
}

void WorkbenchSession::runJavaConfiguration(std::string configurationID,
                                            std::string relativePath) {
    synchronizeJavaRunProject();
    const auto configuration = javaConfiguration(configurationID);
    if (!configuration) {
        reportStatus("The selected Java run configuration is unavailable");
        return;
    }
    runJavaConfiguration(*configuration, std::move(relativePath));
}

void WorkbenchSession::runJavaConfiguration(
    const JavaRunConfigurationDto& configuration, std::string relativePath) {
    if (workspaceRoot_.empty()) {
        reportStatus("Open a workspace before running Java");
        return;
    }
    if (javaSession_->isRunning()) javaSession_->stop();
    synchronizeJavaRunProject();
    std::optional<std::filesystem::path> currentFile;
    if (configuration.kind == "currentFile") {
        if (relativePath.empty() || !relativePath.ends_with(".java")) {
            reportStatus("Open a Java file before running it");
            return;
        }
        currentFile = absoluteWorkspacePath(relativePath);
        if (!currentFile) {
            reportStatus("The selected Java file is outside the workspace");
            return;
        }
    }
    std::string error;
    const auto process = javaRunService_->makeRequest(
        configuration, app::JavaRunOptions{}, std::move(currentFile), error);
    if (!process) {
        if (callbacks_.buildOutput) {
            callbacks_.buildOutput("Unable to run Java: " + error + "\n");
        }
        reportStatus("Java run could not start");
        return;
    }
    if (callbacks_.buildOutput) {
        std::string command = "$ " + process->executablePath;
        for (const auto& argument : process->arguments) command += " " + argument;
        callbacks_.buildOutput(command + "\n\n");
    }
    javaSession_->start(*process);
    reportStatus(configuration.name + " is starting");
}

void WorkbenchSession::stopJava() {
    if (!javaSession_->isRunning()) {
        reportStatus("No Java process is running");
        return;
    }
    if (callbacks_.buildOutput) callbacks_.buildOutput("\nStopping Java...\n");
    javaSession_->stop();
}

void WorkbenchSession::debugCurrentJava(std::string relativePath,
                                        std::string sourceText) {
    if (relativePath.empty() || !relativePath.ends_with(".java")) {
        reportStatus("Open a Java file before debugging it");
        return;
    }
    const auto file = absoluteWorkspacePath(relativePath);
    if (!file) {
        reportStatus("The selected Java file is outside the workspace");
        return;
    }
    javaDebugService_->startCurrentFile(*file, sourceText, {});
}

void WorkbenchSession::debugSpringBoot() {
    synchronizeJavaRunProject();
    const auto configuration = javaConfiguration("springBoot");
    if (!configuration) {
        reportStatus("No Spring Boot run configuration was detected");
        return;
    }
    javaDebugService_->startMaven(*configuration, {});
}

void WorkbenchSession::debugJavaConfiguration(std::string configurationID) {
    synchronizeJavaRunProject();
    const auto configuration = javaConfiguration(configurationID);
    if (!configuration) {
        reportStatus("The selected Java debug configuration is unavailable");
        return;
    }
    if (configuration->kind == "currentFile") {
        reportStatus("Use Debug Current Java File for a current-file configuration");
        return;
    }
    javaDebugService_->startMaven(*configuration, {});
}

void WorkbenchSession::attachDebugger(std::string host, std::uint16_t port) {
    if (host.empty()) host = "127.0.0.1";
    javaDebugService_->attachRemote(host, port);
}

void WorkbenchSession::toggleBreakpoint(std::string relativePath,
                                        std::string sourceText,
                                        std::uint64_t zeroBasedLine) {
    if (relativePath.empty() || !relativePath.ends_with(".java")) {
        reportStatus("Open a Java file before adding a breakpoint");
        return;
    }
    const auto file = absoluteWorkspacePath(relativePath);
    if (!file) return;
    const auto className = app::JavaDebugService::classNameFor(*file, sourceText);
    javaDebugService_->toggleBreakpoint(
        *file, static_cast<std::int32_t>(zeroBasedLine + 1), className);
}

void WorkbenchSession::continueDebugger() { javaDebugService_->continueExecution(); }
void WorkbenchSession::pauseDebugger() { javaDebugService_->pause(); }
void WorkbenchSession::stepIntoDebugger() { javaDebugService_->stepInto(); }
void WorkbenchSession::stepOverDebugger() { javaDebugService_->stepOver(); }
void WorkbenchSession::stepOutDebugger() { javaDebugService_->stepOut(); }
void WorkbenchSession::inspectDebuggerThreads() { javaDebugService_->inspectThreads(); }
void WorkbenchSession::inspectDebuggerStack() { javaDebugService_->inspectStack(); }
void WorkbenchSession::inspectDebuggerVariables() { javaDebugService_->inspectVariables(); }
void WorkbenchSession::evaluateDebugger(std::string expression) {
    javaDebugService_->evaluate(expression);
}

void WorkbenchSession::toggleDebuggerVariable(std::string variableID) {
    const auto snapshot = javaDebugService_->snapshot();
    std::function<const app::JavaDebugVariable*(
        const std::vector<app::JavaDebugVariable>&)> find =
        [&](const std::vector<app::JavaDebugVariable>& values)
            -> const app::JavaDebugVariable* {
            for (const auto& value : values) {
                if (value.id == variableID) return &value;
                if (const auto* child = find(value.children)) return child;
            }
            return nullptr;
        };
    if (const auto* variable = find(snapshot.variables)) {
        javaDebugService_->toggleVariable(*variable);
    }
}

void WorkbenchSession::stopDebugger() { javaDebugService_->stop(); }
void WorkbenchSession::pollDebugger() { javaDebugService_->poll(); }

void WorkbenchSession::activateJavaDocument(std::string relativePath,
                                            std::string documentText) {
    if (!relativePath.ends_with(".java")) {
        closeJavaDocument();
        return;
    }
    bool changedDocument = false;
    {
        std::lock_guard lock(languageServerStateMutex_);
        changedDocument = languageServerPath_ != relativePath;
    }
    if (changedDocument) closeJavaDocument();
    std::string activePath;
    {
        std::lock_guard lock(languageServerStateMutex_);
        languageServerPath_ = std::move(relativePath);
        languageServerText_ = std::move(documentText);
        activePath = languageServerPath_;
    }
    ensureJavaLanguageServer(activePath);
    synchronizeJavaLanguageDocument();
}

void WorkbenchSession::changeJavaDocument(std::string relativePath,
                                          std::string documentText) {
    bool activate = false;
    bool send = false;
    std::string uri;
    {
        std::lock_guard lock(languageServerStateMutex_);
        activate = languageServerPath_ != relativePath;
        if (!activate) {
            languageServerText_ = documentText;
            send = languageServerDocumentOpen_ && languageServer_->isReady();
            uri = languageServerURI_;
        }
    }
    if (activate) {
        activateJavaDocument(std::move(relativePath), std::move(documentText));
    } else if (send) {
        languageServer_->didChange(uri, documentText);
    }
}

void WorkbenchSession::closeJavaDocument() {
    bool shouldClose = false;
    std::string uri;
    {
        std::lock_guard lock(languageServerStateMutex_);
        shouldClose = languageServerDocumentOpen_ && languageServer_ &&
            languageServer_->isReady() && !languageServerURI_.empty();
        uri = languageServerURI_;
        languageServerDocumentOpen_ = false;
        languageServerPath_.clear();
        languageServerURI_.clear();
        languageServerText_.clear();
    }
    if (shouldClose) languageServer_->didClose(uri);
}

void WorkbenchSession::ensureJavaLanguageServer(std::string_view relativePath) {
    if (workspaceRoot_.empty() || relativePath.empty()) return;
    const auto root = javaProjectRoot(workspaceRoot_, relativePath);
    bool alreadyActive = false;
    {
        std::lock_guard lock(languageServerStateMutex_);
        alreadyActive = languageServerRoot_ == root &&
            (languageServer_->isReady() || languageServer_->isStarting());
    }
    if (alreadyActive) return;
    if (languageServer_->isReady() || languageServer_->isStarting() ||
        languageServerSession_->isRunning()) {
        languageServer_->stop();
    }
    std::string error;
    if (!languageServer_->start(root, error)) {
        reportStatus("Java language server unavailable: " + error);
        return;
    }
    std::lock_guard lock(languageServerStateMutex_);
    languageServerRoot_ = root;
}

void WorkbenchSession::synchronizeJavaLanguageDocument() {
    std::string path;
    std::string source;
    std::string uri;
    {
        std::lock_guard lock(languageServerStateMutex_);
        if (!languageServer_->isReady() || languageServerPath_.empty() ||
            languageServerDocumentOpen_) {
            return;
        }
        path = languageServerPath_;
        source = languageServerText_;
        const auto absolute = absoluteWorkspacePath(path);
        if (!absolute) return;
        uri = fileURI(*absolute);
        languageServerURI_ = uri;
        languageServerDocumentOpen_ = true;
    }
    languageServer_->didOpen(uri, "java", 1, source);
}

void WorkbenchSession::goToJavaDefinition(std::string relativePath,
                                          std::string documentText,
                                          std::uint64_t line,
                                          std::uint64_t utf16Column) {
    requestJavaNavigation("textDocument/definition", "Java definitions",
                          std::move(relativePath), std::move(documentText),
                          line, utf16Column);
}

void WorkbenchSession::findJavaUsages(std::string relativePath,
                                      std::string documentText,
                                      std::uint64_t line,
                                      std::uint64_t utf16Column) {
    requestJavaNavigation("textDocument/references", "Java usages",
                          std::move(relativePath), std::move(documentText),
                          line, utf16Column);
}

void WorkbenchSession::findJavaImplementations(
    std::string relativePath,
    std::string documentText,
    std::uint64_t line,
    std::uint64_t utf16Column) {
    requestJavaNavigation("textDocument/implementation", "Java implementations",
                          std::move(relativePath), std::move(documentText),
                          line, utf16Column);
}

void WorkbenchSession::requestJavaNavigation(std::string method,
                                             std::string title,
                                             std::string relativePath,
                                             std::string documentText,
                                             std::uint64_t line,
                                             std::uint64_t utf16Column) {
    activateJavaDocument(relativePath, documentText);
    std::string uri;
    {
        std::lock_guard lock(languageServerStateMutex_);
        if (!languageServer_->isReady() || !languageServerDocumentOpen_) {
            if (callbacks_.javaNavigationChanged) {
                callbacks_.javaNavigationChanged(JavaNavigationResult{
                    std::move(title), {}, "Java language server is not ready"});
            }
            return;
        }
        uri = languageServerURI_;
    }
    JsonValue::Object params{
        {"textDocument", JsonValue(JsonValue::Object{{"uri", uri}})},
        {"position", JsonValue(JsonValue::Object{
            {"line", line}, {"character", utf16Column}})},
    };
    if (method == "textDocument/references") {
        params["context"] = JsonValue(JsonValue::Object{{"includeDeclaration", false}});
    }
    languageServer_->requestJavaNavigation(
        method, JsonValue(std::move(params)), documentText, line, utf16Column,
        [this, title = std::move(title)](
            std::optional<JsonValue> result,
            std::optional<app::LspRpcError> error) mutable {
            if (callbacks_.javaNavigationChanged) {
                callbacks_.javaNavigationChanged(parseJavaNavigation(
                    std::move(title), result, error));
            }
        });
}

JavaNavigationResult WorkbenchSession::parseJavaNavigation(
    std::string title,
    const std::optional<JsonValue>& result,
    const std::optional<app::LspRpcError>& error) const {
    JavaNavigationResult parsed;
    parsed.title = std::move(title);
    if (error) {
        parsed.error = error->message;
        return parsed;
    }
    if (!result || result->isNull()) return parsed;
    std::vector<const JsonValue*> locations;
    if (const auto* array = result->asArray()) {
        for (const auto& value : *array) locations.push_back(&value);
    } else if (result->isObject()) {
        locations.push_back(&*result);
    }
    for (const auto* location : locations) {
        const auto* uriValue = objectValue(*location, "uri");
        if (uriValue == nullptr) uriValue = objectValue(*location, "targetUri");
        if (uriValue == nullptr || uriValue->asString() == nullptr) continue;
        const auto* range = objectValue(*location, "range");
        if (range == nullptr) range = objectValue(*location, "targetSelectionRange");
        if (range == nullptr) range = objectValue(*location, "targetRange");
        const auto* start = range == nullptr ? nullptr : objectValue(*range, "start");
        const auto line = start && objectValue(*start, "line")
            ? objectValue(*start, "line")->asUInt().value_or(0) : 0;
        const auto column = start && objectValue(*start, "character")
            ? objectValue(*start, "character")->asUInt().value_or(0) : 0;
        JavaNavigationLocation target;
        target.line = line;
        target.utf16Column = column;
        const auto localPath = pathFromFileURI(*uriValue->asString());
        if (localPath) {
            const auto normalized = localPath->lexically_normal();
            if (isInside(normalized, workspaceRoot_)) {
                target.relativePath = normalizedSlashes(
                    pathUtf8(normalized.lexically_relative(workspaceRoot_)));
                target.displayPath = target.relativePath;
            } else {
                target.absolutePath = normalized;
                target.displayPath = pathUtf8(normalized);
            }
        } else {
            target.displayPath = *uriValue->asString();
        }
        if (target.displayPath.empty()) continue;
        parsed.locations.push_back(std::move(target));
    }
    return parsed;
}

JavaDiagnosticsResult WorkbenchSession::parseJavaDiagnostics(
    const std::string& uri, const JsonValue& diagnostics) const {
    JavaDiagnosticsResult result;
    {
        std::lock_guard lock(languageServerStateMutex_);
        if (uri != languageServerURI_) return result;
        result.relativePath = languageServerPath_;
    }
    const auto* entries = diagnostics.asArray();
    if (!entries) return result;
    for (const auto& entry : *entries) {
        const auto* message = objectValue(entry, "message");
        if (!message || !message->asString()) continue;
        const auto* range = objectValue(entry, "range");
        const auto* start = range ? objectValue(*range, "start") : nullptr;
        const auto line = start && objectValue(*start, "line")
            ? objectValue(*start, "line")->asUInt().value_or(0) : 0;
        const auto column = start && objectValue(*start, "character")
            ? objectValue(*start, "character")->asUInt().value_or(0) : 0;
        const auto severityValue = objectValue(entry, "severity");
        const auto severity = severityValue ? severityValue->asUInt().value_or(3) : 3;
        const char* severityText = severity == 1 ? "error"
            : severity == 2 ? "warning" : severity == 4 ? "hint" : "info";
        result.items.push_back({severityText, *message->asString(), line, column});
    }
    return result;
}

app::AICommitSettings WorkbenchSession::loadAICommitSettings() const {
    app::AICommitSettings settings;
    const auto endpoint = keyValueStore_.read("ai.commit.endpoint");
    const auto model = keyValueStore_.read("ai.commit.model");
    if (!endpoint || !model || endpoint->empty() || model->empty()) return settings;
    app::AICommitProvider provider;
    provider.id = "default";
    provider.name = "Default";
    provider.endpoint = *endpoint;
    provider.model = *model;
    provider.apiKeyIdentifier = "lithe/ai/default/api-key";
    provider.protocol = static_cast<app::AICommitAPIProtocol>(
        storedIndex(keyValueStore_, "ai.commit.protocol", 2));
    provider.authentication = static_cast<app::AICommitAuthentication>(
        storedIndex(keyValueStore_, "ai.commit.authentication", 1));
    provider.allowsInsecureHTTP =
        keyValueStore_.read("ai.commit.allowInsecureHTTP").value_or("0") == "1";
    settings.providers.push_back(std::move(provider));
    settings.activeProviderID = "default";
    settings.language = static_cast<app::AICommitLanguage>(
        storedIndex(keyValueStore_, "ai.commit.language", 1));
    settings.format = static_cast<app::AICommitFormat>(
        storedIndex(keyValueStore_, "ai.commit.format", 5));
    settings.customInstructions =
        keyValueStore_.read("ai.commit.customInstructions").value_or(std::string{});
    settings.includeBody = keyValueStore_.read("ai.commit.includeBody").value_or("0") == "1";
    if (const auto value = keyValueStore_.read("ai.commit.subjectMaximumLength")) {
        try { settings.subjectMaximumLength = std::max<std::size_t>(1, std::stoull(*value)); }
        catch (...) {}
    }
    if (const auto value = keyValueStore_.read("ai.commit.maximumDiffCharacters")) {
        try { settings.maximumDiffCharacters = std::max<std::size_t>(8000, std::stoull(*value)); }
        catch (...) {}
    }
    settings.reasoningEffort =
        keyValueStore_.read("ai.commit.reasoningEffort").value_or("low");
    return settings;
}

bool WorkbenchSession::saveAICommitSettings(const app::AICommitSettings& settings,
                                            std::string apiKey,
                                            std::string& error) {
    if (settings.providers.empty()) {
        error = "No AI provider is configured";
        return false;
    }
    const auto& provider = settings.providers.front();
    if (provider.endpoint.empty() || provider.model.empty()) {
        error = "AI endpoint and model are required";
        return false;
    }
    const auto write = [this, &error](const std::string& key, const std::string& value) {
        return keyValueStore_.write(key, value, error);
    };
    const bool saved = write("ai.commit.endpoint", provider.endpoint) &&
        write("ai.commit.model", provider.model) &&
        write("ai.commit.protocol", std::to_string(static_cast<int>(provider.protocol))) &&
        write("ai.commit.authentication",
              std::to_string(static_cast<int>(provider.authentication))) &&
        write("ai.commit.allowInsecureHTTP", provider.allowsInsecureHTTP ? "1" : "0") &&
        write("ai.commit.language", std::to_string(static_cast<int>(settings.language))) &&
        write("ai.commit.format", std::to_string(static_cast<int>(settings.format))) &&
        write("ai.commit.customInstructions", settings.customInstructions) &&
        write("ai.commit.includeBody", settings.includeBody ? "1" : "0") &&
        write("ai.commit.subjectMaximumLength",
              std::to_string(settings.subjectMaximumLength)) &&
        write("ai.commit.maximumDiffCharacters",
              std::to_string(settings.maximumDiffCharacters)) &&
        write("ai.commit.reasoningEffort", settings.reasoningEffort);
    if (!saved) return false;
    if (!apiKey.empty() &&
        !secureStore_.write(provider.apiKeyIdentifier, apiKey, error)) {
        return false;
    }
    reportStatus("AI commit settings saved");
    return true;
}

void WorkbenchSession::generateAICommitMessage(app::AICommitSettings settings) {
    if (workspaceRoot_.empty()) {
        reportStatus("Open a workspace before generating a commit message");
        return;
    }
    if (aiGenerating_.exchange(true)) {
        reportStatus("AI commit generation is already running");
        return;
    }
    const auto state = gitFeature_->state();
    if (!state.status || state.isLoadingStatus) {
        aiGenerating_.store(false);
        reportStatus("Refresh Git status before generating a message");
        return;
    }
    std::vector<std::string> stagedPaths;
    std::map<std::string, std::string> changeKinds;
    for (const auto& change : state.status->changes) {
        if (!change.staged) continue;
        stagedPaths.push_back(change.path);
        changeKinds.emplace(change.path, change.status);
    }
    if (stagedPaths.empty()) {
        aiGenerating_.store(false);
        reportStatus("There are no staged changes");
        return;
    }
    const auto epoch = workspaceEpoch_.load();
    reportStatus("Loading staged changes for AI commit generation");
    gitFeature_->loadStagedDiffs(std::move(stagedPaths),
        [this, epoch, settings = std::move(settings),
         changeKinds = std::move(changeKinds)](
            std::vector<app::GitStagedDiff> diffs,
            std::optional<CoreError> error) mutable {
            if (workspaceEpoch_.load() != epoch) {
                aiGenerating_.store(false);
                return;
            }
            if (error) {
                aiGenerating_.store(false);
                const auto message = error->message.empty()
                    ? "Could not load staged diff" : error->message;
                if (callbacks_.aiCommitFinished) {
                    callbacks_.aiCommitFinished({{}, message});
                }
                return;
            }
            app::AICommitInput input;
            for (const auto& stagedDiff : diffs) {
                if (stagedDiff.diff.patch.empty()) continue;
                if (app::AICommitMessageService::isSensitivePath(stagedDiff.path) ||
                    stagedDiffContainsSensitiveFile(stagedDiff.diff.patch)) {
                    aiGenerating_.store(false);
                    if (callbacks_.aiCommitFinished) {
                        callbacks_.aiCommitFinished({{},
                            "The staged diff contains a sensitive file; AI generation was blocked"});
                    }
                    return;
                }
                const auto kind = changeKinds.contains(stagedDiff.path)
                    ? changeKinds.at(stagedDiff.path) : std::string("modified");
                input.files.push_back({stagedDiff.path, kind, stagedDiff.diff.patch});
            }
            if (input.files.empty()) {
                aiGenerating_.store(false);
                if (callbacks_.aiCommitFinished) {
                    callbacks_.aiCommitFinished({{}, "There is no staged textual diff"});
                }
                return;
            }
            if (aiWorker_.joinable()) aiWorker_.join();
            reportStatus("Generating commit message...");
            aiWorker_ = std::thread(
                [this, epoch, input = std::move(input), settings = std::move(settings)] {
                    app::AICommitError generationError;
                    auto message = aiCommitService_.generate(input, settings, generationError);
                    aiGenerating_.store(false);
                    if (workspaceEpoch_.load() != epoch) return;
                    if (callbacks_.aiCommitFinished) {
                        callbacks_.aiCommitFinished({
                            std::move(message), std::move(generationError.message)});
                    }
                });
        });
}

void WorkbenchSession::checkForUpdates(std::string architecture) {
    if (updateBusy_.exchange(true)) {
        reportStatus("An update operation is already running");
        return;
    }
    if (updateWorker_.joinable()) updateWorker_.join();
    reportStatus("Checking for Windows updates...");
    updateWorker_ = std::thread([this, architecture = std::move(architecture)] {
        constexpr std::string_view currentVersion = LITHE_VERSION;
        app::WindowsUpdateError error;
        auto release = updateService_.checkLatest(
            "1lck/Lithe-IDEA", std::string(currentVersion), error);
        std::optional<app::WindowsReleaseAsset> asset;
        if (release) asset = updateService_.selectAsset(*release, architecture, error);
        WindowsUpdateCheckResult result;
        result.release = std::move(release);
        result.asset = std::move(asset);
        result.upToDate = !result.release &&
            error.code == app::WindowsUpdateErrorCode::NoPublishedRelease;
        if (!result.upToDate && (!result.release || !result.asset)) result.error = error.message;
        updateBusy_.store(false);
        if (callbacks_.updateCheckFinished) {
            callbacks_.updateCheckFinished(std::move(result));
        }
    });
}

void WorkbenchSession::downloadUpdate(app::WindowsReleaseAsset asset,
                                      std::filesystem::path destination) {
    if (updateBusy_.exchange(true)) {
        reportStatus("An update operation is already running");
        return;
    }
    if (updateWorker_.joinable()) updateWorker_.join();
    reportStatus("Downloading and verifying Windows installer...");
    updateWorker_ = std::thread(
        [this, asset = std::move(asset), destination = std::move(destination)]() mutable {
            app::WindowsUpdateError error;
            bool succeeded = updateService_.downloadAndVerify(asset, destination, error);
            if (succeeded) {
                std::string signatureError;
                succeeded = authenticodeVerifier_.verify(destination, signatureError);
                if (!succeeded) error.message = std::move(signatureError);
            }
            updateBusy_.store(false);
            if (callbacks_.updateDownloadFinished) {
                callbacks_.updateDownloadFinished({
                    std::move(destination), std::move(error.message), succeeded});
            }
        });
}

const std::filesystem::path& WorkbenchSession::workspaceRoot() const {
    return workspaceRoot_;
}

const app::AppSettings& WorkbenchSession::settings() const {
    return settings_;
}

bool WorkbenchSession::saveSettings(app::AppSettings settings) {
    std::string error;
    if (!settingsStore_.save(settings, error)) {
        reportStatus("Could not save settings: " + error);
        return false;
    }
    settings_ = std::move(settings);
    coordinator_->setWorkspaceVisibility(
        settings_.hiddenDirectoryNames, settings_.hiddenFilePatterns);
    historyFeature_->setVisibilityRules(
        settings_.hiddenDirectoryNames, settings_.hiddenFilePatterns);
    reportStatus("Settings saved");
    if (!workspaceRoot_.empty()) refreshWorkspace();
    return true;
}

std::vector<std::string> WorkbenchSession::recentProjects() const {
    return recentProjectsStore_.load();
}

bool WorkbenchSession::removeRecentProject(std::string path) {
    auto projects = recentProjectsStore_.load();
    const auto previousSize = projects.size();
    projects.erase(std::remove(projects.begin(), projects.end(), path), projects.end());
    if (projects.size() == previousSize) return true;
    std::string error;
    if (!recentProjectsStore_.replace(std::move(projects), error)) {
        reportStatus("Could not update recent projects: " + error);
        return false;
    }
    reportStatus("Recent project removed");
    return true;
}

std::string WorkbenchSession::coreVersion() const {
    return coordinator_->coreVersion();
}

app::WorkspaceSession WorkbenchSession::loadWorkspaceSession() const {
    return workspaceRoot_.empty()
        ? app::WorkspaceSession{}
        : app::sanitizeWorkspaceSession(
              workspaceRoot_, workspaceSessionStore_.load(pathUtf8(workspaceRoot_)));
}

bool WorkbenchSession::saveWorkspaceSession(const app::WorkspaceSession& state) {
    if (workspaceRoot_.empty()) return false;
    std::string error;
    const auto sanitized = app::sanitizeWorkspaceSession(workspaceRoot_, state);
    if (!workspaceSessionStore_.save(pathUtf8(workspaceRoot_), sanitized, error)) {
        reportStatus("Could not save workspace session: " + error);
        return false;
    }
    return true;
}

WorkbenchLayoutState WorkbenchSession::loadLayout(
    int availableWidth, int availableHeight) const {
    const auto root = workspaceRoot_.empty() ? std::string{} : pathUtf8(workspaceRoot_);
    return normalizeWorkbenchLayout(
        layoutPersistence_.load(root), availableWidth, availableHeight);
}

bool WorkbenchSession::saveLayout(const WorkbenchLayoutState& state) {
    if (workspaceRoot_.empty()) return false;
    std::string error;
    if (!layoutPersistence_.save(pathUtf8(workspaceRoot_), state, error)) {
        reportStatus("Could not save workbench layout: " + error);
        return false;
    }
    return true;
}

app::GitFeatureState WorkbenchSession::gitState() const {
    return gitFeature_->state();
}

void WorkbenchSession::reportError(
    const std::optional<CoreError>& error, std::string fallback) {
    if (!callbacks_.statusChanged || !error) return;
    callbacks_.statusChanged(error->message.empty() ? std::move(fallback) : error->message);
}

void WorkbenchSession::refreshAfterWrite() {
    if (!writeLifecycle_->requestRefresh()) return;
    refreshWorkspace();
    scanProject();
}

app::WorkspaceWriteLifecycle::Token WorkbenchSession::beginWorkspaceWrite(
    bool preserveDeferredChanges) {
    return writeLifecycle_->begin(preserveDeferredChanges);
}

void WorkbenchSession::finishWorkspaceWrite(
    app::WorkspaceWriteLifecycle::Token token, bool requestRefresh) {
    auto completion = writeLifecycle_->end(token, requestRefresh);
    if (!completion.deferredChanges.empty() && callbacks_.filesChanged) {
        callbacks_.filesChanged(std::move(completion.deferredChanges));
    }
    if (!completion.shouldRefresh) return;
    refreshWorkspace();
    scanProject();
}

void WorkbenchSession::reportStatus(std::string message) const {
    if (callbacks_.statusChanged) callbacks_.statusChanged(std::move(message));
}

std::filesystem::path WorkbenchSession::javaProjectRoot(
    const std::filesystem::path& workspace, std::string_view relativePath) {
    if (workspace.empty()) return workspace;
    auto current = (workspace / pathFromUtf8(relativePath)).parent_path();
    std::error_code error;
    for (;;) {
        const auto marker = [&](const char* name) {
            return std::filesystem::exists(current / name, error) && !error;
        };
        if (marker("pom.xml") || marker("build.gradle") ||
            marker("build.gradle.kts") || marker(".git")) {
            return current;
        }
        error.clear();
        if (current == workspace || current.empty() || current.parent_path() == current ||
            !isInside(current.parent_path(), workspace)) {
            break;
        }
        current = current.parent_path();
    }
    return workspace;
}

std::string WorkbenchSession::fileURI(const std::filesystem::path& path) {
    auto value = normalizedSlashes(pathUtf8(path.lexically_normal()));
    std::string uri;
    if (value.size() >= 2 && value[1] == ':') uri = "file:///" + value;
    else if (!value.empty() && value.front() == '/') uri = "file://" + value;
    else uri = "file:///" + value;
    std::string encoded;
    encoded.reserve(uri.size());
    constexpr char hexadecimal[] = "0123456789ABCDEF";
    for (const unsigned char character : uri) {
        const bool unreserved = std::isalnum(character) != 0 || character == '-' ||
            character == '_' || character == '.' || character == '~' ||
            character == '/' || character == ':';
        if (unreserved) {
            encoded.push_back(static_cast<char>(character));
        } else {
            encoded.push_back('%');
            encoded.push_back(hexadecimal[(character >> 4) & 0x0f]);
            encoded.push_back(hexadecimal[character & 0x0f]);
        }
    }
    return encoded;
}

std::optional<std::filesystem::path> WorkbenchSession::pathFromFileURI(
    std::string_view uri) {
    if (!uri.starts_with("file://")) return std::nullopt;
    auto value = percentDecode(uri.substr(7));
    if (value.size() >= 3 && value.front() == '/' && value[2] == ':') value.erase(0, 1);
    else if (!value.empty() && value.front() != '/') value = "//" + value;
    return pathFromUtf8(value);
}

bool WorkbenchSession::stagedDiffContainsSensitiveFile(std::string_view patch) {
    const auto sensitive = [](std::string_view path) {
        while (!path.empty() && (path.back() == '\r' || path.back() == '\n')) {
            path.remove_suffix(1);
        }
        const auto metadata = path.find_first_of("\t ");
        if (metadata != std::string_view::npos) path = path.substr(0, metadata);
        return path != "/dev/null" && app::AICommitMessageService::isSensitivePath(path);
    };
    std::size_t start = 0;
    while (start <= patch.size()) {
        const auto end = patch.find('\n', start);
        const auto line = patch.substr(start,
            end == std::string_view::npos ? patch.size() - start : end - start);
        if (line.starts_with("diff --git a/")) {
            const auto separator = line.find(" b/", 13);
            if (separator != std::string_view::npos &&
                (sensitive(line.substr(13, separator - 13)) ||
                 sensitive(line.substr(separator + 3)))) {
                return true;
            }
        }
        for (const auto prefix : {std::string_view("--- a/"), std::string_view("+++ b/")}) {
            if (line.starts_with(prefix) && sensitive(line.substr(prefix.size()))) return true;
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return false;
}

bool WorkbenchSession::validLeafName(std::string_view value) {
    if (value.empty() || value == "." || value == ".." ||
        value.back() == '.' || value.back() == ' ') {
        return false;
    }
    constexpr std::string_view invalid = "<>:\"/\\|?*";
    for (const unsigned char character : value) {
        if (character < 32 || invalid.find(static_cast<char>(character)) != std::string_view::npos) {
            return false;
        }
    }
    auto base = value.substr(0, value.find('.'));
    std::string upper;
    upper.reserve(base.size());
    for (const unsigned char character : base) {
        upper.push_back(static_cast<char>(std::toupper(character)));
    }
    if (upper == "CON" || upper == "PRN" || upper == "AUX" || upper == "NUL") return false;
    if (upper.size() == 4 &&
        (upper.starts_with("COM") || upper.starts_with("LPT")) &&
        upper[3] >= '1' && upper[3] <= '9') {
        return false;
    }
    return true;
}

std::string WorkbenchSession::operationID(std::string_view prefix) {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return std::string(prefix) + "-" +
        std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(now).count());
}

}
