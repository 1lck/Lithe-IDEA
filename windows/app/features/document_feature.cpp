#include "document_feature.h"

#include <algorithm>
#include <cctype>
#include <utility>

namespace lithe::windows::app {
namespace {

class CoordinatorDocumentOperations final : public DocumentOperations {
public:
    explicit CoordinatorDocumentOperations(WorkbenchCoordinator& coordinator)
        : coordinator_(coordinator) {}

    void read(std::string relativePath, Handler handler) override {
        coordinator_.readFile(std::move(relativePath), std::move(handler));
    }

    void write(FileWriteRequestDto request, Handler handler) override {
        coordinator_.writeFile(std::move(request), std::move(handler));
    }

private:
    WorkbenchCoordinator& coordinator_;
};

CoreError fallbackError(const WorkspaceOperationResult& result, std::string message) {
    if (const auto error = result.coreError()) return *error;
    return CoreError{CoreErrorCode::Unknown, std::move(message), std::nullopt};
}

} // namespace

DocumentFeatureModel::DocumentFeatureModel(WorkbenchCoordinator& coordinator)
    : ownedOperations_(std::make_unique<CoordinatorDocumentOperations>(coordinator)),
      operations_(ownedOperations_.get()) {}

DocumentFeatureModel::DocumentFeatureModel(DocumentOperations& operations)
    : operations_(&operations) {}

DocumentFeatureModel::~DocumentFeatureModel() {
    const auto lifetime = lifetime_;
    std::lock_guard lock(lifetime->mutex);
    lifetime->alive = false;
    lifetime_.reset();
}

void DocumentFeatureModel::open(std::string relativePath, StateHandler handler) {
    const auto key = pathKey(relativePath);
    std::uint64_t workspaceEpoch;
    std::uint64_t openGeneration;
    std::string pathToRead;
    std::optional<DocumentFeatureState> existing;
    {
        std::lock_guard lock(mutex_);
        activeKey_ = key;
        if (const auto* document = findLocked(key)) {
            existing = document->state;
        } else {
            DocumentRecord record;
            record.key = key;
            record.state.relativePath = std::move(relativePath);
            record.state.isLoading = true;
            record.state.openGeneration = 1;
            documents_.push_back(std::move(record));
        }
        workspaceEpoch = workspaceEpoch_;
        const auto* document = findLocked(key);
        openGeneration = document->state.openGeneration;
        pathToRead = document->state.relativePath;
    }
    if (existing) {
        if (handler) handler(std::move(*existing));
        return;
    }
    const auto weakLifetime = std::weak_ptr<LifetimeGuard>(lifetime_);
    operations_->read(std::move(pathToRead),
        [this, weakLifetime, key, workspaceEpoch, openGeneration,
         handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        const auto lifetime = weakLifetime.lock();
        if (!lifetime) return;
        std::lock_guard lifetimeLock(lifetime->mutex);
        if (!lifetime->alive) return;
        applyRead(key, workspaceEpoch, openGeneration, std::move(result), std::move(handler));
    });
}

bool DocumentFeatureModel::activate(const std::string& relativePath) {
    std::lock_guard lock(mutex_);
    const auto key = pathKey(relativePath);
    if (!findLocked(key)) return false;
    activeKey_ = key;
    return true;
}

void DocumentFeatureModel::setText(std::string text) {
    std::lock_guard lock(mutex_);
    auto* document = findLocked(activeKey_);
    if (!document || document->state.isLoading || document->state.isReadOnly) return;
    document->state.text = std::move(text);
    document->state.isDirty = document->state.text != document->state.savedText;
    document->state.error.reset();
}

void DocumentFeatureModel::setText(const std::string& relativePath, std::string text) {
    std::lock_guard lock(mutex_);
    auto* document = findLocked(pathKey(relativePath));
    if (!document || document->state.isLoading || document->state.isReadOnly) return;
    document->state.text = std::move(text);
    document->state.isDirty = document->state.text != document->state.savedText;
    document->state.error.reset();
}

void DocumentFeatureModel::setReadOnly(const std::string& relativePath, bool readOnly) {
    std::lock_guard lock(mutex_);
    if (auto* document = findLocked(pathKey(relativePath))) {
        document->state.isReadOnly = readOnly;
    }
}

void DocumentFeatureModel::save(StateHandler handler) {
    std::string path;
    {
        std::lock_guard lock(mutex_);
        const auto* document = findLocked(activeKey_);
        if (document) path = document->state.relativePath;
    }
    if (!path.empty()) save(path, std::move(handler));
}

void DocumentFeatureModel::save(const std::string& relativePath, StateHandler handler) {
    FileWriteRequestDto request;
    std::uint64_t workspaceEpoch = 0;
    std::uint64_t operationGeneration = 0;
    std::string key = pathKey(relativePath);
    std::optional<DocumentFeatureState> immediate;
    std::vector<StateHandler> immediateHandlers;
    {
        std::lock_guard lock(mutex_);
        auto* document = findLocked(key);
        if (!document) return;
        if (handler) document->saveHandlers.push_back(std::move(handler));
        if (document->state.isLoading || document->state.isReadOnly ||
            (!document->state.isDirty &&
             document->state.externalState != DocumentExternalState::Deleted)) {
            immediate = document->state;
            immediateHandlers = std::move(document->saveHandlers);
            document->saveHandlers.clear();
        } else if (document->state.isSaving) {
            document->saveQueued = true;
        } else {
            beginSaveLocked(*document, request, workspaceEpoch, operationGeneration);
        }
    }
    for (auto& pending : immediateHandlers) if (pending) pending(*immediate);
    if (immediate || operationGeneration == 0) return;
    dispatchSave(std::move(key), std::move(request), workspaceEpoch, operationGeneration);
}

void DocumentFeatureModel::externalModified(const std::string& relativePath,
                                            StateHandler handler) {
    const auto key = pathKey(relativePath);
    std::uint64_t workspaceEpoch;
    std::uint64_t externalGeneration;
    std::string path;
    {
        std::lock_guard lock(mutex_);
        auto* document = findLocked(key);
        if (!document || document->state.isLoading || document->state.isSaving) return;
        workspaceEpoch = workspaceEpoch_;
        externalGeneration = ++document->state.externalGeneration;
        path = document->state.relativePath;
    }
    const auto weakLifetime = std::weak_ptr<LifetimeGuard>(lifetime_);
    operations_->read(std::move(path),
        [this, weakLifetime, key, workspaceEpoch, externalGeneration,
         handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        const auto lifetime = weakLifetime.lock();
        if (!lifetime) return;
        std::lock_guard lifetimeLock(lifetime->mutex);
        if (!lifetime->alive) return;
        applyExternalRead(key, workspaceEpoch, externalGeneration,
                          std::move(result), std::move(handler));
    });
}

void DocumentFeatureModel::externalDeleted(const std::string& relativePath) {
    std::lock_guard lock(mutex_);
    auto* document = findLocked(pathKey(relativePath));
    if (!document) return;
    ++document->state.externalGeneration;
    document->state.externalState = DocumentExternalState::Deleted;
    document->state.externalText.clear();
    document->state.externalVersion.clear();
    document->state.error.reset();
}

bool DocumentFeatureModel::keepEditorVersion(const std::string& relativePath) {
    std::lock_guard lock(mutex_);
    auto* document = findLocked(pathKey(relativePath));
    if (!document || document->state.externalState != DocumentExternalState::Modified ||
        document->state.externalVersion.empty()) return false;
    document->state.diskVersion = std::move(document->state.externalVersion);
    document->state.externalText.clear();
    document->state.externalLineEnding = "lf";
    document->state.externalHasUtf8Bom = false;
    document->state.externalState = DocumentExternalState::None;
    document->state.isDirty = true;
    return true;
}

bool DocumentFeatureModel::loadExternalVersion(const std::string& relativePath) {
    std::lock_guard lock(mutex_);
    auto* document = findLocked(pathKey(relativePath));
    if (!document || document->state.externalState != DocumentExternalState::Modified ||
        document->state.externalVersion.empty()) return false;
    document->state.text = std::move(document->state.externalText);
    document->state.savedText = document->state.text;
    document->state.diskVersion = std::move(document->state.externalVersion);
    document->state.lineEnding = std::move(document->state.externalLineEnding);
    document->state.hasUtf8Bom = document->state.externalHasUtf8Bom;
    document->state.externalHasUtf8Bom = false;
    document->state.externalState = DocumentExternalState::None;
    document->state.isDirty = false;
    document->state.error.reset();
    return true;
}

bool DocumentFeatureModel::rename(const std::string& sourcePath,
                                  const std::string& destinationPath) {
    std::lock_guard lock(mutex_);
    const auto sourceKey = pathKey(sourcePath);
    const auto destinationKey = pathKey(destinationPath);
    auto* document = findLocked(sourceKey);
    if (!document || (sourceKey != destinationKey && findLocked(destinationKey)) ||
        document->state.isLoading || document->state.isSaving) return false;
    document->key = destinationKey;
    document->state.relativePath = destinationPath;
    if (activeKey_ == sourceKey) activeKey_ = destinationKey;
    return true;
}

bool DocumentFeatureModel::close(const std::string& relativePath, bool discardDirty) {
    std::lock_guard lock(mutex_);
    const auto key = pathKey(relativePath);
    const auto iterator = std::find_if(documents_.begin(), documents_.end(),
        [&](const auto& document) { return document.key == key; });
    if (iterator == documents_.end()) return true;
    if (iterator->state.isLoading || iterator->state.isSaving) return false;
    if (iterator->state.isDirty && !discardDirty) return false;
    const auto wasActive = activeKey_ == key;
    const auto index = static_cast<std::size_t>(std::distance(documents_.begin(), iterator));
    documents_.erase(iterator);
    if (wasActive) {
        if (documents_.empty()) activeKey_.clear();
        else activeKey_ = documents_[std::min(index, documents_.size() - 1)].key;
    }
    return true;
}

void DocumentFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    ++workspaceEpoch_;
    documents_.clear();
    activeKey_.clear();
}

DocumentFeatureState DocumentFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    const auto* document = findLocked(activeKey_);
    return document ? document->state : DocumentFeatureState{};
}

std::optional<DocumentFeatureState> DocumentFeatureModel::state(
    const std::string& relativePath) const {
    std::lock_guard lock(mutex_);
    const auto* document = findLocked(pathKey(relativePath));
    return document ? std::optional(document->state) : std::nullopt;
}

std::vector<DocumentFeatureState> DocumentFeatureModel::states() const {
    std::lock_guard lock(mutex_);
    std::vector<DocumentFeatureState> result;
    result.reserve(documents_.size());
    for (const auto& document : documents_) result.push_back(document.state);
    return result;
}

std::vector<std::string> DocumentFeatureModel::openPaths() const {
    std::lock_guard lock(mutex_);
    std::vector<std::string> result;
    result.reserve(documents_.size());
    for (const auto& document : documents_) result.push_back(document.state.relativePath);
    return result;
}

DocumentSafetySnapshot DocumentFeatureModel::documentSafetySnapshot() const {
    std::lock_guard lock(mutex_);
    DocumentSafetySnapshot snapshot;
    for (const auto& document : documents_) {
        if (document.state.isDirty) snapshot.dirtyPaths.push_back(document.state.relativePath);
        snapshot.isSaving = snapshot.isSaving || document.state.isSaving;
        snapshot.hasFailures = snapshot.hasFailures || document.state.error.has_value();
        snapshot.hasConflicts = snapshot.hasConflicts ||
            document.state.externalState != DocumentExternalState::None ||
            (document.state.error &&
             document.state.error->code == CoreErrorCode::ExternalConflict);
    }
    return snapshot;
}

std::string DocumentFeatureModel::pathKey(const std::string& relativePath) {
    auto key = relativePath;
    std::replace(key.begin(), key.end(), '\\', '/');
    std::transform(key.begin(), key.end(), key.begin(),
        [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
    return key;
}

DocumentFeatureModel::DocumentRecord* DocumentFeatureModel::findLocked(const std::string& key) {
    const auto iterator = std::find_if(documents_.begin(), documents_.end(),
        [&](const auto& document) { return document.key == key; });
    return iterator == documents_.end() ? nullptr : &*iterator;
}

const DocumentFeatureModel::DocumentRecord* DocumentFeatureModel::findLocked(
    const std::string& key) const {
    const auto iterator = std::find_if(documents_.begin(), documents_.end(),
        [&](const auto& document) { return document.key == key; });
    return iterator == documents_.end() ? nullptr : &*iterator;
}

void DocumentFeatureModel::beginSaveLocked(DocumentRecord& document,
                                           FileWriteRequestDto& request,
                                           std::uint64_t& workspaceEpoch,
                                           std::uint64_t& operationGeneration) {
    document.state.isSaving = true;
    document.state.error.reset();
    document.savingText = document.state.text;
    operationGeneration = ++document.state.operationGeneration;
    workspaceEpoch = workspaceEpoch_;
    request.path = document.state.relativePath;
    request.text = document.savingText;
    request.expectedVersion = document.state.diskVersion.empty()
        ? std::nullopt : std::optional(document.state.diskVersion);
    request.lineEnding = document.state.lineEnding;
    request.hasUtf8Bom = document.state.hasUtf8Bom;
    request.createOnly = document.state.externalState == DocumentExternalState::Deleted;
}

void DocumentFeatureModel::dispatchSave(std::string key, FileWriteRequestDto request,
                                        std::uint64_t workspaceEpoch,
                                        std::uint64_t operationGeneration) {
    const auto weakLifetime = std::weak_ptr<LifetimeGuard>(lifetime_);
    operations_->write(std::move(request),
        [this, weakLifetime, key = std::move(key), workspaceEpoch, operationGeneration](
            WorkspaceOperationResult result) mutable {
        const auto lifetime = weakLifetime.lock();
        if (!lifetime) return;
        std::lock_guard lifetimeLock(lifetime->mutex);
        if (!lifetime->alive) return;
        applyWrite(std::move(key), workspaceEpoch, operationGeneration, std::move(result));
    });
}

void DocumentFeatureModel::applyRead(std::string key, std::uint64_t workspaceEpoch,
                                     std::uint64_t openGeneration,
                                     WorkspaceOperationResult result, StateHandler handler) {
    DocumentFeatureState next;
    {
        std::lock_guard lock(mutex_);
        auto* document = findLocked(key);
        if (!document || workspaceEpoch != workspaceEpoch_ ||
            openGeneration != document->state.openGeneration || result.stale) return;
        document->state.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            if (auto file = decodeFileRead(*result.envelope)) {
                document->state.relativePath = std::move(file->path);
                document->state.text = std::move(file->text);
                document->state.savedText = document->state.text;
                document->state.diskVersion = std::move(file->version);
                document->state.lineEnding = std::move(file->lineEnding);
                document->state.hasUtf8Bom = file->hasUtf8Bom;
                document->state.isDirty = false;
                document->state.externalState = DocumentExternalState::None;
                document->state.error.reset();
            } else {
                document->state.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid file response", std::nullopt};
            }
        } else {
            document->state.error = fallbackError(result, "File read failed");
        }
        next = document->state;
    }
    if (handler) handler(std::move(next));
}

void DocumentFeatureModel::applyWrite(std::string key, std::uint64_t workspaceEpoch,
                                      std::uint64_t operationGeneration,
                                      WorkspaceOperationResult result) {
    FileWriteRequestDto followUpRequest;
    std::uint64_t followUpEpoch = 0;
    std::uint64_t followUpGeneration = 0;
    bool dispatchFollowUp = false;
    DocumentFeatureState next;
    std::vector<StateHandler> handlers;
    {
        std::lock_guard lock(mutex_);
        auto* document = findLocked(key);
        if (!document || workspaceEpoch != workspaceEpoch_ ||
            operationGeneration != document->state.operationGeneration || result.stale) return;
        document->state.isSaving = false;
        if (result.envelope && result.envelope->ok) {
            if (auto file = decodeFileWrite(*result.envelope)) {
                document->state.savedText = document->savingText;
                document->state.diskVersion = std::move(file->newVersion);
                document->state.isDirty = document->state.text != document->state.savedText;
                document->state.externalState = DocumentExternalState::None;
                document->state.error.reset();
            } else {
                document->state.error = CoreError{CoreErrorCode::ParseFailed,
                    "Invalid file write response", std::nullopt};
            }
        } else {
            document->state.error = fallbackError(result, "File write failed");
        }
        if (document->saveQueued && document->state.isDirty && !document->state.error) {
            document->saveQueued = false;
            beginSaveLocked(*document, followUpRequest, followUpEpoch, followUpGeneration);
            dispatchFollowUp = true;
        } else {
            document->saveQueued = false;
            handlers = std::move(document->saveHandlers);
            document->saveHandlers.clear();
        }
        next = document->state;
    }
    for (auto& handler : handlers) if (handler) handler(next);
    if (dispatchFollowUp) {
        dispatchSave(std::move(key), std::move(followUpRequest),
                     followUpEpoch, followUpGeneration);
    }
}

void DocumentFeatureModel::applyExternalRead(std::string key,
                                             std::uint64_t workspaceEpoch,
                                             std::uint64_t externalGeneration,
                                             WorkspaceOperationResult result,
                                             StateHandler handler) {
    DocumentFeatureState next;
    {
        std::lock_guard lock(mutex_);
        auto* document = findLocked(key);
        if (!document || workspaceEpoch != workspaceEpoch_ ||
            externalGeneration != document->state.externalGeneration || result.stale) return;
        if (result.envelope && result.envelope->ok) {
            if (auto file = decodeFileRead(*result.envelope)) {
                if (file->version != document->state.diskVersion) {
                    if (document->state.isDirty) {
                        document->state.externalState = DocumentExternalState::Modified;
                        document->state.externalText = std::move(file->text);
                        document->state.externalVersion = std::move(file->version);
                        document->state.externalLineEnding = std::move(file->lineEnding);
                        document->state.externalHasUtf8Bom = file->hasUtf8Bom;
                    } else {
                        document->state.text = std::move(file->text);
                        document->state.savedText = document->state.text;
                        document->state.diskVersion = std::move(file->version);
                        document->state.lineEnding = std::move(file->lineEnding);
                        document->state.hasUtf8Bom = file->hasUtf8Bom;
                        document->state.externalState = DocumentExternalState::None;
                    }
                }
                document->state.error.reset();
            } else {
                document->state.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid file response", std::nullopt};
            }
        } else {
            document->state.error = fallbackError(result, "Could not check external file change");
        }
        next = document->state;
    }
    if (handler) handler(std::move(next));
}

} // namespace lithe::windows::app
