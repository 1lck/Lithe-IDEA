#pragma once

#include "workbench_coordinator.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

enum class DocumentExternalState {
    None,
    Modified,
    Deleted,
};

struct DocumentFeatureState {
    std::string relativePath;
    std::string text;
    std::string savedText;
    std::string diskVersion;
    std::string externalText;
    std::string externalVersion;
    std::string externalLineEnding = "lf";
    std::string lineEnding = "lf";
    std::optional<CoreError> error;
    DocumentExternalState externalState = DocumentExternalState::None;
    std::uint64_t openGeneration = 0;
    std::uint64_t operationGeneration = 0;
    std::uint64_t externalGeneration = 0;
    bool hasUtf8Bom = false;
    bool externalHasUtf8Bom = false;
    bool isLoading = false;
    bool isSaving = false;
    bool isDirty = false;
    bool isReadOnly = false;
};

struct DocumentSafetySnapshot {
    std::vector<std::string> dirtyPaths;
    bool isSaving = false;
    bool hasFailures = false;
    bool hasConflicts = false;
};

class DocumentSafetySnapshotProvider {
public:
    virtual ~DocumentSafetySnapshotProvider() = default;
    virtual DocumentSafetySnapshot documentSafetySnapshot() const = 0;
};

class DocumentOperations {
public:
    using Handler = std::function<void(WorkspaceOperationResult)>;

    virtual ~DocumentOperations() = default;
    virtual void read(std::string relativePath, Handler handler) = 0;
    virtual void write(FileWriteRequestDto request, Handler handler) = 0;
};

class DocumentFeatureModel final : public DocumentSafetySnapshotProvider {
public:
    using StateHandler = std::function<void(DocumentFeatureState)>;

    explicit DocumentFeatureModel(WorkbenchCoordinator& coordinator);
    explicit DocumentFeatureModel(DocumentOperations& operations);
    ~DocumentFeatureModel();

    DocumentFeatureModel(const DocumentFeatureModel&) = delete;
    DocumentFeatureModel& operator=(const DocumentFeatureModel&) = delete;

    void open(std::string relativePath, StateHandler handler = {});
    bool activate(const std::string& relativePath);
    void setText(std::string text);
    void setText(const std::string& relativePath, std::string text);
    void setReadOnly(const std::string& relativePath, bool readOnly);
    void save(StateHandler handler = {});
    void save(const std::string& relativePath, StateHandler handler = {});
    void externalModified(const std::string& relativePath, StateHandler handler = {});
    void externalDeleted(const std::string& relativePath);
    bool keepEditorVersion(const std::string& relativePath);
    bool loadExternalVersion(const std::string& relativePath);
    bool rename(const std::string& sourcePath, const std::string& destinationPath);
    bool close(const std::string& relativePath, bool discardDirty = false);
    void resetForWorkspace();

    DocumentFeatureState state() const;
    std::optional<DocumentFeatureState> state(const std::string& relativePath) const;
    std::vector<DocumentFeatureState> states() const;
    std::vector<std::string> openPaths() const;
    DocumentSafetySnapshot documentSafetySnapshot() const override;

private:
    struct DocumentRecord {
        DocumentFeatureState state;
        std::string key;
        std::string savingText;
        bool saveQueued = false;
        std::vector<StateHandler> saveHandlers;
    };

    struct LifetimeGuard {
        std::mutex mutex;
        bool alive = true;
    };

    std::unique_ptr<DocumentOperations> ownedOperations_;
    DocumentOperations* operations_ = nullptr;
    mutable std::mutex mutex_;
    std::vector<DocumentRecord> documents_;
    std::string activeKey_;
    std::uint64_t workspaceEpoch_ = 0;
    std::shared_ptr<LifetimeGuard> lifetime_ = std::make_shared<LifetimeGuard>();

    static std::string pathKey(const std::string& relativePath);
    DocumentRecord* findLocked(const std::string& key);
    const DocumentRecord* findLocked(const std::string& key) const;
    void beginSaveLocked(DocumentRecord& document, FileWriteRequestDto& request,
                         std::uint64_t& workspaceEpoch, std::uint64_t& operationGeneration);
    void dispatchSave(std::string key, FileWriteRequestDto request,
                      std::uint64_t workspaceEpoch, std::uint64_t operationGeneration);
    void applyRead(std::string key, std::uint64_t workspaceEpoch,
                   std::uint64_t openGeneration, WorkspaceOperationResult result,
                   StateHandler handler);
    void applyWrite(std::string key, std::uint64_t workspaceEpoch,
                    std::uint64_t operationGeneration, WorkspaceOperationResult result);
    void applyExternalRead(std::string key, std::uint64_t workspaceEpoch,
                           std::uint64_t externalGeneration, WorkspaceOperationResult result,
                           StateHandler handler);
};

} // namespace lithe::windows::app
