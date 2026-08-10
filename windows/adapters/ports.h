#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace lithe::windows {

struct ProcessRequest {
    std::string operationID;
    std::string executablePath;
    std::vector<std::string> arguments;
    std::optional<std::string> workingDirectory;
    std::map<std::string, std::string> environment;
    std::optional<std::string> standardInput;
    bool keepsStandardInputOpen = false;
    std::optional<std::uint64_t> timeoutMilliseconds;
};

enum class ProcessLifecycleState {
    Starting,
    Running,
    Stopping,
    Finished,
    Failed,
};

struct ProcessLifecycleEvent {
    std::string operationID;
    ProcessLifecycleState state;
    std::optional<std::int32_t> exitCode;
    std::string message;
};

struct ProcessResult {
    std::string output;
    std::int32_t exitCode = 1;
    bool started = false;
};

class ProcessRunner {
public:
    virtual ~ProcessRunner() = default;
    virtual ProcessResult run(const ProcessRequest& request) = 0;
};

class ProcessSession {
public:
    using OutputHandler = std::function<void(const std::string&)>;
    using ErrorHandler = std::function<void(const std::string&)>;
    using LifecycleHandler = std::function<void(const ProcessLifecycleEvent&)>;

    virtual ~ProcessSession() = default;
    virtual void start(const ProcessRequest& request) = 0;
    virtual void send(const std::string& input) = 0;
    virtual void closeInput() = 0;
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;
    virtual void setOutputHandler(OutputHandler handler) = 0;
    virtual void setErrorHandler(ErrorHandler handler) = 0;
    virtual void setLifecycleHandler(LifecycleHandler handler) = 0;
};

class TerminalTransport {
public:
    using OutputHandler = std::function<void(const std::string&)>;
    using ErrorHandler = std::function<void(const std::string&)>;
    using ExitHandler = std::function<void()>;

    virtual ~TerminalTransport() = default;
    virtual void start(const ProcessRequest& request) = 0;
    virtual void send(const std::string& input) = 0;
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;
    virtual void resize(int columns, int rows) = 0;
    virtual void setOutputHandler(OutputHandler handler) = 0;
    virtual void setErrorHandler(ErrorHandler handler) = 0;
    virtual void setExitHandler(ExitHandler handler) = 0;
};

// Implementations belong in this directory and may use Win32 APIs. Core
// feature models should depend on these ports, never on Win32 handles or
// ConPTY types.
class DirectoryChangeSource {
public:
    enum class ChangeKind {
        Added,
        Removed,
        Modified,
        RenamedOldName,
        RenamedNewName,
        RescanRequired,
    };

    struct Change {
        std::string path;
        ChangeKind kind = ChangeKind::Modified;
    };

    using ChangeHandler = std::function<void(const std::vector<Change>&)>;
    using ErrorHandler = std::function<void(const std::string&)>;

    virtual ~DirectoryChangeSource() = default;
    virtual void start(const std::string& root,
                       ChangeHandler handler,
                       ErrorHandler errorHandler = {}) = 0;
    virtual void stop() = 0;
};

struct FileReadResult {
    bool succeeded = false;
    std::string text;
    std::string error;
};

class WorkspaceFileSystem {
public:
    virtual ~WorkspaceFileSystem() = default;
    virtual FileReadResult readUtf8(const std::string& path) = 0;
    virtual bool writeAtomic(const std::string& path,
                             const std::string& text,
                             std::string& error) = 0;
    virtual bool move(const std::string& source,
                      const std::string& destination,
                      std::string& error) = 0;
    virtual bool remove(const std::string& path, std::string& error) = 0;
};

struct RuntimeCandidate {
    std::string homePath;
    std::string executablePath;
    std::string version;
};

struct RuntimeDiscoveryResult {
    std::vector<RuntimeCandidate> javaRuntimes;
    std::vector<RuntimeCandidate> mavenRuntimes;
};

class RuntimeLocator {
public:
    virtual ~RuntimeLocator() = default;
    virtual std::map<std::string, std::string> environment() const = 0;
    virtual RuntimeDiscoveryResult discover() const = 0;
    virtual std::optional<std::string> validJavaHome(const std::string& path) const = 0;
    virtual bool isExecutable(const std::string& path) const = 0;
    virtual std::optional<std::string> systemMavenExecutable() const = 0;
    virtual std::optional<std::string> mavenExecutableForHomePath(const std::string& path) const = 0;
    virtual std::optional<std::string> systemJDBExecutable() const = 0;
    virtual std::optional<std::string> javaLanguageServerExecutable() const = 0;
};

using KeyValueValue = std::variant<
    bool,
    std::int64_t,
    double,
    std::string,
    std::vector<std::string>,
    std::vector<std::uint8_t>>;

class KeyValueStore {
public:
    virtual ~KeyValueStore() = default;
    virtual std::optional<KeyValueValue> readValue(const std::string& key) const = 0;
    virtual bool writeValue(const std::string& key,
                            const KeyValueValue& value,
                            std::string& error) = 0;
    virtual bool remove(const std::string& key, std::string& error) = 0;

    std::optional<std::string> read(const std::string& key) const;
    bool write(const std::string& key,
               const std::string& value,
               std::string& error);
};

class SecureStore {
public:
    virtual ~SecureStore() = default;
    virtual std::optional<std::string> read(const std::string& key) const = 0;
    virtual bool write(const std::string& key,
                      const std::string& value,
                      std::string& error) = 0;
    virtual bool remove(const std::string& key, std::string& error) = 0;
};

struct HTTPRequest {
    std::string method = "POST";
    std::string url;
    std::map<std::string, std::string> headers;
    std::string body;
    std::uint64_t timeoutMilliseconds = 30000;
    bool allowsInsecureHTTP = false;
};

struct HTTPResponse {
    std::int32_t statusCode = 0;
    std::string body;
};

class AIHTTPTransport {
public:
    virtual ~AIHTTPTransport() = default;
    virtual std::optional<HTTPResponse> send(const HTTPRequest& request,
                                             std::string& error) = 0;
};

class AIConfigurationSource {
public:
    virtual ~AIConfigurationSource() = default;
    // Returns the provider configuration as UTF-8 JSON. Keeping this port
    // JSON-shaped avoids coupling the adapter layer to application models.
    virtual std::optional<std::string> load() const = 0;
};

class ArchiveEntryReader {
public:
    virtual ~ArchiveEntryReader() = default;
    virtual std::optional<std::string> read(const std::string& archivePath,
                                            const std::string& entry) const = 0;
};

class PlatformUI {
public:
    virtual ~PlatformUI() = default;
    virtual std::optional<std::string> chooseDirectory(const std::string& title,
                                                       const std::string& prompt) = 0;
    virtual void revealInFileBrowser(const std::string& path) = 0;
    virtual void copyToClipboard(const std::string& value) = 0;
};

class ShortcutDetector {
public:
    using DoubleTapHandler = std::function<void()>;

    virtual ~ShortcutDetector() = default;
    virtual void start(DoubleTapHandler handler) = 0;
    virtual void stop() = 0;
};

struct FileMetadata {
    std::optional<std::uint64_t> byteCount;
    std::optional<std::int64_t> modificationTime;
    bool isRegularFile = false;
    bool isDirectory = false;
    bool isWritable = true;
};

class FileStorage {
public:
    virtual ~FileStorage() = default;
    virtual std::string homeDirectory() const = 0;
    virtual std::string cacheDirectory() const = 0;
    virtual std::string applicationSupportDirectory() const = 0;
    virtual std::optional<FileMetadata> metadata(const std::string& path) const = 0;
    virtual bool fileExists(const std::string& path) const = 0;
    virtual bool isExecutable(const std::string& path) const = 0;
    virtual std::vector<std::string> listDirectory(const std::string& path) const = 0;
    virtual std::optional<std::vector<std::uint8_t>> readData(
        const std::string& path, std::string& error) const = 0;
    virtual bool writeData(const std::string& path,
                           const std::vector<std::uint8_t>& data,
                           std::string& error) = 0;
    virtual bool createDirectory(const std::string& path,
                                 bool withIntermediateDirectories,
                                 std::string& error) = 0;
    virtual bool removeItem(const std::string& path, std::string& error) = 0;
    virtual bool moveItem(const std::string& source,
                          const std::string& destination,
                          std::string& error) = 0;
};

inline std::optional<std::string> KeyValueStore::read(const std::string& key) const {
    const auto value = readValue(key);
    if (!value || !std::holds_alternative<std::string>(*value)) return std::nullopt;
    return std::get<std::string>(*value);
}

inline bool KeyValueStore::write(const std::string& key,
                                 const std::string& value,
                                 std::string& error) {
    return writeValue(key, KeyValueValue{value}, error);
}

} // namespace lithe::windows
