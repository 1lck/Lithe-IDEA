#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows {

struct ProcessRequest {
    std::string operationID;
    std::string executablePath;
    std::vector<std::string> arguments;
    std::optional<std::string> workingDirectory;
    std::map<std::string, std::string> environment;
    std::optional<std::uint32_t> timeoutMilliseconds;
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
    using LifecycleHandler = std::function<void(const ProcessLifecycleEvent&)>;

    virtual ~ProcessSession() = default;
    virtual void start(const ProcessRequest& request) = 0;
    virtual void send(const std::string& input) = 0;
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;
    virtual void setOutputHandler(OutputHandler handler) = 0;
    virtual void setLifecycleHandler(LifecycleHandler handler) = 0;
};

class TerminalTransport {
public:
    using OutputHandler = std::function<void(const std::string&)>;
    using ExitHandler = std::function<void()>;

    virtual ~TerminalTransport() = default;
    virtual void start(const ProcessRequest& request) = 0;
    virtual void send(const std::string& input) = 0;
    virtual void stop() = 0;
    virtual void resize(int columns, int rows) = 0;
    virtual void setOutputHandler(OutputHandler handler) = 0;
    virtual void setExitHandler(ExitHandler handler) = 0;
};

// Implementations belong in this directory and may use Win32 APIs. Core
// feature models should depend on these ports, never on Win32 handles or
// ConPTY types.
class DirectoryChangeSource {
public:
    using ChangeHandler = std::function<void(const std::vector<std::string>&)>;

    virtual ~DirectoryChangeSource() = default;
    virtual void start(const std::string& root, ChangeHandler handler) = 0;
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
    virtual RuntimeDiscoveryResult discover() const = 0;
};

class KeyValueStore {
public:
    virtual ~KeyValueStore() = default;
    virtual std::optional<std::string> read(const std::string& key) const = 0;
    virtual bool write(const std::string& key,
                      const std::string& value,
                      std::string& error) = 0;
    virtual bool remove(const std::string& key, std::string& error) = 0;
};

} // namespace lithe::windows
