#pragma once

#include "java_run_service.h"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace lithe::windows::app {

enum class JavaDebugTargetKind {
    CurrentFile,
    RunConfiguration,
    Remote,
};

enum class JavaDebugSessionState {
    Idle,
    Launching,
    Running,
    Paused,
    Finished,
    Failed,
};

struct JavaDebugBreakpoint {
    std::string id;
    std::string filePath;
    std::int32_t line = 0;
    std::string className;
};

struct JavaDebugVariable {
    std::string id;
    std::string name;
    std::string expression;
    std::string value;
    std::vector<JavaDebugVariable> children;
    bool isExpanded = false;
    bool isExpandable = false;

    bool canExpand() const { return isExpandable || !children.empty(); }
};

struct JavaDebugThread {
    std::string id;
    std::string name;
    std::string status;
    bool isCurrent = false;
};

struct JavaDebugStackFrame {
    std::int32_t level = 0;
    std::string description;
};

struct JavaDebugSnapshot {
    JavaDebugSessionState state = JavaDebugSessionState::Idle;
    JavaDebugTargetKind targetKind = JavaDebugTargetKind::CurrentFile;
    std::string output;
    std::optional<std::string> inspectionTitle;
    std::string inspectionOutput;
    std::vector<JavaDebugVariable> variables;
    std::vector<JavaDebugThread> threads;
    std::vector<JavaDebugStackFrame> callStack;
    std::optional<std::string> expandingVariableID;
    std::optional<std::string> exceptionMessage;
    std::optional<std::uint16_t> port;
    std::vector<JavaDebugBreakpoint> breakpoints;
    std::string runningTargetTitle;
};

class JavaDebugService final {
public:
    using SessionFactory = std::function<std::unique_ptr<ProcessSession>()>;
    using StateHandler = std::function<void()>;

    JavaDebugService(ProjectRuntimeService& runtime,
                     JavaRunService& javaRun,
                     FileStorage& storage,
                     SessionFactory sessionFactory);
    ~JavaDebugService();

    void setRuntimeSettings(ProjectRuntimeSettings settings);
    void setStateHandler(StateHandler handler);

    JavaDebugSnapshot snapshot() const;
    bool canControl() const;

    void startCurrentFile(const std::filesystem::path& file,
                          const std::string& sourceText,
                          const JavaRunOptions& options);
    void startMaven(const JavaRunConfigurationDto& configuration,
                    const JavaRunOptions& options);
    void attachRemote(const std::string& host,
                      std::uint16_t port,
                      const std::string& javaHomePath = {});

    void toggleBreakpoint(const std::filesystem::path& file,
                          std::int32_t line,
                          const std::string& className);
    void continueExecution();
    void pause();
    void stepInto();
    void stepOver();
    void stepOut();
    void inspectThreads();
    void inspectStack();
    void inspectVariables();
    void evaluate(const std::string& expression);
    void toggleVariable(const JavaDebugVariable& variable);
    void clearOutput();
    void stop();

    // Call from the UI timer. This keeps attach/bootstrap delays out of Qt
    // and makes the timing deterministic in tests.
    void poll();

    static std::string classNameFor(const std::filesystem::path& file,
                                    const std::string& sourceText);
    static std::vector<std::string> parseArguments(std::string_view input);
    static std::vector<JavaDebugVariable> parseVariables(std::string_view text);
    static std::vector<JavaDebugVariable> parseDumpChildren(
        std::string_view text, const JavaDebugVariable& parent);
    static std::vector<JavaDebugThread> parseThreads(std::string_view text);
    static std::vector<JavaDebugStackFrame> parseStackFrames(std::string_view text);
    static bool containsException(std::string_view text);

private:
    enum class ProcessKind {
        Debuggee,
        JDB,
    };

    enum class InspectionKind {
        Threads,
        Stack,
        Locals,
        Dump,
        Evaluate,
    };

    ProjectRuntimeService& runtime_;
    JavaRunService& javaRun_;
    FileStorage& storage_;
    SessionFactory sessionFactory_;
    std::unique_ptr<ProcessSession> debuggee_;
    std::unique_ptr<ProcessSession> jdb_;

    mutable std::mutex mutex_;
    StateHandler stateHandler_;
    ProjectRuntimeSettings runtimeSettings_;
    JavaDebugSnapshot snapshot_;
    std::string sessionID_;
    std::string debuggeeOperationID_;
    std::string jdbOperationID_;
    std::string debugClassName_;
    std::string activeJDBHost_;
    std::string activeJDBPath_;
    std::string activeJavaHomePath_;
    bool launchesDebuggee_ = false;
    bool didBootstrap_ = false;
    std::optional<InspectionKind> inspectionKind_;
    std::optional<std::string> inspectionVariableID_;
    std::chrono::steady_clock::time_point attachDeadline_{};
    std::chrono::steady_clock::time_point bootstrapDeadline_{};
    bool attachDeadlineActive_ = false;
    bool bootstrapDeadlineActive_ = false;

    static std::string nextID(std::string_view prefix);
    static std::string pathText(const std::filesystem::path& path);
    static std::filesystem::path pathFromText(const std::string& path);
    static bool isInside(const std::filesystem::path& path,
                         const std::filesystem::path& root);
    static std::string trim(std::string value);
    static bool isValidVariableName(std::string_view name);
    static bool looksExpandable(std::string_view value);
    static std::optional<std::pair<std::string, std::string>> parseAssignment(
        std::string_view line);
    static std::vector<std::string> lines(std::string_view text);

    void configureProcesses();
    void notifyState();
    void prepareSession(JavaDebugTargetKind target,
                        std::optional<std::uint16_t> port,
                        std::string host,
                        std::string title,
                        bool launchesDebuggee);
    void startDebuggee(ProcessRequest request,
                       const std::string& host,
                       std::uint16_t port);
    void startJDB(const std::string& executable,
                  const std::string& host,
                  std::uint16_t port,
                  RuntimeProcessKind processKind,
                  const std::string& javaHomePath);
    void bootstrapJDB();
    void sendCommand(const std::string& command);
    void inspect(const std::string& title,
                 const std::string& command,
                 InspectionKind kind);
    void refreshInspectionData();
    void appendOutput(const std::string& value);
    void appendDebuggeeOutput(const std::string& value);
    void appendJDBOutput(const std::string& value);
    void handleLifecycle(const ProcessLifecycleEvent& event, ProcessKind kind);
    void handleProcessError(const std::string& value, ProcessKind kind);
    void fail(std::string message);
    void updateVariable(const std::string& id,
                        const std::function<void(JavaDebugVariable&)>& update);
    JavaDebugVariable* findVariable(std::vector<JavaDebugVariable>& values,
                                    const std::string& id);
    const JavaDebugVariable* findVariable(
        const std::vector<JavaDebugVariable>& values,
        const std::string& id) const;
    std::filesystem::path workingDirectory(const std::string& requested,
                                            const std::filesystem::path& fallback) const;
};

} // namespace lithe::windows::app
