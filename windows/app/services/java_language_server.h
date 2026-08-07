#pragma once

#include "json_value.h"
#include "project_runtime_service.h"

#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace lithe::windows::app {

class LspFrameDecoder final {
public:
    std::vector<std::string> feed(std::string_view bytes);
    std::optional<std::string> finish();
    const std::string& error() const;

private:
    std::string buffer_;
    std::string error_;
    std::optional<std::size_t> contentLength() const;
};

std::string frameLspMessage(std::string_view body);

struct LspRpcError {
    std::int64_t code = 0;
    std::string message;
    JsonValue data;
};

class JavaLanguageServerClient final {
public:
    using ResponseHandler = std::function<void(
        std::optional<JsonValue>, std::optional<LspRpcError>)>;
    using StateHandler = std::function<void(bool ready, const std::string& message)>;
    using DiagnosticsHandler = std::function<void(
        const std::string& uri, const JsonValue& diagnostics)>;

    JavaLanguageServerClient(ProjectRuntimeService& runtime,
                             FileStorage& storage,
                             ProcessSession& process,
                             ArchiveEntryReader* archiveReader = nullptr);
    ~JavaLanguageServerClient();

    bool start(const std::filesystem::path& root, std::string& error);
    void stop();
    bool isReady() const;
    bool isStarting() const;

    void setStateHandler(StateHandler handler);
    void setDiagnosticsHandler(DiagnosticsHandler handler);

    void request(const std::string& method,
                 JsonValue params,
                 ResponseHandler handler);
    // Sends a definition/reference request and normalizes JDT's external
    // locations into local, read-only source files when possible.  The
    // document text is used only for the JDK definition fallback.
    void requestJavaNavigation(const std::string& method,
                               JsonValue params,
                               std::string documentText,
                               std::uint64_t line,
                               std::uint64_t utf16Column,
                               ResponseHandler handler);
    void notify(const std::string& method, JsonValue params);

    void didOpen(const std::string& uri,
                 const std::string& languageID,
                 std::int64_t version,
                 const std::string& text);
    void didChange(const std::string& uri, const std::string& text);
    void didClose(const std::string& uri);

    // Exposed for deterministic tests and shutdown paths. Normal callers let
    // the 300 ms background debounce worker flush pending changes.
    void flushChanges();

private:
    struct PendingChange {
        std::int64_t version = 0;
        std::string text;
    };

    ProjectRuntimeService& runtime_;
    FileStorage& storage_;
    ProcessSession& process_;
    ArchiveEntryReader* archiveReader_ = nullptr;
    mutable std::mutex mutex_;
    std::condition_variable changeCondition_;
    std::thread changeWorker_;
    bool stopChangeWorker_ = false;
    std::uint64_t changeGeneration_ = 0;
    std::map<std::string, PendingChange> pendingChanges_;
    std::map<std::uint64_t, ResponseHandler> pendingRequests_;
    std::map<std::string, std::int64_t> documentVersions_;
    std::uint64_t nextRequestID_ = 1;
    bool ready_ = false;
    bool starting_ = false;
    bool initializationSent_ = false;
    std::filesystem::path pendingRoot_;
    std::string rootURI_;
    LspFrameDecoder decoder_;
    StateHandler stateHandler_;
    DiagnosticsHandler diagnosticsHandler_;

    void startChangeWorker();
    void changeLoop();
    void receive(const std::string& bytes);
    void handle(const JsonValue& message);
    void send(JsonValue message);
    void sendResponse(std::uint64_t id, JsonValue result);
    void initialize(const std::filesystem::path& root);
    void finishReady(bool success, std::string message);
    void reportState(bool ready, const std::string& message);
    void resolveNavigationResult(const std::string& method,
                                 const JsonValue& params,
                                 const std::string& documentText,
                                 std::uint64_t line,
                                 std::uint64_t utf16Column,
                                 JsonValue result,
                                 ResponseHandler handler);
    void resolveExternalLocations(JsonValue result, ResponseHandler handler);
    void resolveMissingDefinition(const JsonValue& params,
                                  const std::string& documentText,
                                  std::uint64_t line,
                                  std::uint64_t utf16Column,
                                  ResponseHandler handler);
    void executeCommand(const std::string& command,
                        JsonValue::Array arguments,
                        ResponseHandler handler);
    void handleServerRequest(std::uint64_t id,
                             const std::string& method,
                             const JsonValue& params);
    std::optional<std::string> jdkSourceForURI(const std::string& uri) const;
    std::optional<std::string> materializeLibrarySource(
        const std::string& content, const std::string& uri) const;
    std::optional<JsonValue> jdkDefinitionLocation(
        const std::string& qualifiedName,
        const std::string& symbol,
        const std::string& documentText,
        std::uint64_t line,
        std::uint64_t utf16Column) const;
    static std::optional<std::string> jdkURIForQualifiedName(
        const std::string& qualifiedName);
    static std::vector<JsonValue> navigationLocations(const JsonValue& result);
    static std::optional<std::string> qualifiedNameFromHover(
        const JsonValue& hover, const std::string& symbol);
    static std::optional<std::string> symbolAt(
        const std::string& text, std::uint64_t line, std::uint64_t utf16Column);
    static std::optional<std::pair<std::uint64_t, std::uint64_t>> sourcePosition(
        const std::string& source, const std::string& symbol);
    static std::string pathToURI(const std::filesystem::path& path);
    static std::string dataDirectoryName(const std::filesystem::path& root);
};

} // namespace lithe::windows::app
