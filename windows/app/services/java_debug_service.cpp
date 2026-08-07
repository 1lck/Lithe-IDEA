#include "java_debug_service.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <sstream>
#include <utility>

namespace lithe::windows::app {
namespace {

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](char character) {
        return static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    });
    return value;
}

std::string trimView(std::string_view value) {
    std::size_t start = 0;
    while (start < value.size() &&
           std::isspace(static_cast<unsigned char>(value[start])) != 0) {
        ++start;
    }
    std::size_t end = value.size();
    while (end > start &&
           std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
        --end;
    }
    return std::string(value.substr(start, end - start));
}

} // namespace

JavaDebugService::JavaDebugService(ProjectRuntimeService& runtime,
                                   JavaRunService& javaRun,
                                   FileStorage& storage,
                                   SessionFactory sessionFactory)
    : runtime_(runtime),
      javaRun_(javaRun),
      storage_(storage),
      sessionFactory_(std::move(sessionFactory)),
      debuggee_(sessionFactory_()),
      jdb_(sessionFactory_()) {
    configureProcesses();
}

JavaDebugService::~JavaDebugService() {
    stop();
}

void JavaDebugService::setRuntimeSettings(ProjectRuntimeSettings settings) {
    std::lock_guard lock(mutex_);
    runtimeSettings_ = std::move(settings);
}

void JavaDebugService::setStateHandler(StateHandler handler) {
    std::lock_guard lock(mutex_);
    stateHandler_ = std::move(handler);
}

JavaDebugSnapshot JavaDebugService::snapshot() const {
    std::lock_guard lock(mutex_);
    return snapshot_;
}

bool JavaDebugService::canControl() const {
    return jdb_ != nullptr && jdb_->isRunning();
}

void JavaDebugService::startCurrentFile(const std::filesystem::path& file,
                                        const std::string& sourceText,
                                        const JavaRunOptions& options) {
    stop();
    if (lower(file.extension().string()) != ".java") {
        fail("Select a Java file before starting Debug.");
        return;
    }
    const auto jdb = runtime_.jdbExecutable(
        runtimeSettings_, RuntimeProcessKind::Java, options.javaHomePath);
    if (!jdb) {
        fail("No JDK with jdb was found. Set JDK Home or JAVA_HOME.");
        return;
    }

    const auto port = static_cast<std::uint16_t>(
        49152 + (std::hash<std::string>{}(pathText(file) + nextID("port")) % 10849));
    const auto className = classNameFor(file, sourceText);
    const JavaRunConfigurationDto configuration{
        "debug-current-file", "Debug Current File", "currentFile", std::nullopt, std::nullopt};
    auto debugOptions = options;
    debugOptions.vmArguments =
        "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:" +
        std::to_string(port) + " -Duser.language=en -Duser.country=US " +
        options.vmArguments;
    std::string error;
    const auto request = javaRun_.makeRequest(configuration, debugOptions, file, error);
    if (!request) {
        fail(error.empty() ? "Unable to construct the Java debug process." : error);
        return;
    }

    prepareSession(JavaDebugTargetKind::CurrentFile, port, "127.0.0.1",
                   file.filename().string(), true);
    {
        std::lock_guard lock(mutex_);
        debugClassName_ = className;
        activeJDBPath_ = *jdb;
        activeJavaHomePath_ = options.javaHomePath;
    }
    auto process = *request;
    process.operationID = nextID("windows-debuggee");
    startDebuggee(std::move(process), "127.0.0.1", port);
}

void JavaDebugService::startMaven(const JavaRunConfigurationDto& configuration,
                                  const JavaRunOptions& options) {
    stop();
    if (configuration.kind != "springBoot" && configuration.kind != "mavenModule") {
        fail("Select a Spring Boot or Maven Module configuration before starting Debug.");
        return;
    }
    const auto jdb = runtime_.jdbExecutable(
        runtimeSettings_, RuntimeProcessKind::Maven, options.javaHomePath);
    if (!jdb) {
        fail("No JDK with jdb was found. Set JDK Home or JAVA_HOME.");
        return;
    }

    const auto port = static_cast<std::uint16_t>(
        49152 + (std::hash<std::string>{}(configuration.id + nextID("port")) % 10849));
    auto debugOptions = options;
    debugOptions.vmArguments =
        "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:" +
        std::to_string(port) + " " + options.vmArguments;
    std::string error;
    const auto request = javaRun_.makeRequest(
        configuration, debugOptions, std::nullopt, error);
    if (!request) {
        fail(error.empty() ? "Unable to construct the Maven debug process." : error);
        return;
    }

    prepareSession(JavaDebugTargetKind::RunConfiguration, port, "127.0.0.1",
                   configuration.name, true);
    {
        std::lock_guard lock(mutex_);
        activeJDBPath_ = *jdb;
        activeJavaHomePath_ = options.javaHomePath;
    }
    auto process = *request;
    process.operationID = nextID("windows-debuggee");
    startDebuggee(std::move(process), "127.0.0.1", port);
}

void JavaDebugService::attachRemote(const std::string& host,
                                    std::uint16_t port,
                                    const std::string& javaHomePath) {
    stop();
    if (host.empty() || port == 0) {
        fail("Enter a valid JDWP host and port.");
        return;
    }
    const auto jdb = runtime_.jdbExecutable(
        runtimeSettings_, RuntimeProcessKind::Java, javaHomePath);
    if (!jdb) {
        fail("No local JDK with jdb was found for the attach session.");
        return;
    }

    prepareSession(JavaDebugTargetKind::Remote, port, host,
                   host + ":" + std::to_string(port), false);
    {
        std::lock_guard lock(mutex_);
        activeJDBPath_ = *jdb;
        activeJavaHomePath_ = javaHomePath;
    }
    startJDB(*jdb, host, port, RuntimeProcessKind::Java, javaHomePath);
}

void JavaDebugService::toggleBreakpoint(const std::filesystem::path& file,
                                        std::int32_t line,
                                        const std::string& className) {
    if (line <= 0) return;
    const auto normalized = file.lexically_normal();
    const auto id = pathText(normalized) + ":" + std::to_string(line);
    std::optional<JavaDebugBreakpoint> removed;
    {
        std::lock_guard lock(mutex_);
        const auto found = std::find_if(snapshot_.breakpoints.begin(),
                                        snapshot_.breakpoints.end(),
                                        [&](const JavaDebugBreakpoint& value) {
                                            return value.id == id;
                                        });
        if (found != snapshot_.breakpoints.end()) {
            removed = *found;
            snapshot_.breakpoints.erase(found);
        } else {
            snapshot_.breakpoints.push_back({id, pathText(normalized), line, className});
            std::sort(snapshot_.breakpoints.begin(), snapshot_.breakpoints.end(),
                      [](const auto& left, const auto& right) {
                          if (left.filePath != right.filePath) return left.filePath < right.filePath;
                          return left.line < right.line;
                      });
        }
    }
    if (removed && canControl()) {
        sendCommand("clear " + removed->className + ":" + std::to_string(removed->line));
    } else if (!removed && canControl()) {
        sendCommand("stop at " + className + ":" + std::to_string(line));
    }
    notifyState();
}

void JavaDebugService::continueExecution() {
    if (!canControl()) return;
    sendCommand("cont");
    {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Running;
    }
    notifyState();
}

void JavaDebugService::pause() {
    if (!canControl()) return;
    sendCommand("halt");
    {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Paused;
    }
    notifyState();
}

void JavaDebugService::stepInto() {
    if (!canControl()) return;
    sendCommand("step");
    {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Running;
    }
    notifyState();
}

void JavaDebugService::stepOver() {
    if (!canControl()) return;
    sendCommand("next");
    {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Running;
    }
    notifyState();
}

void JavaDebugService::stepOut() {
    if (!canControl()) return;
    sendCommand("step up");
    {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Running;
    }
    notifyState();
}

void JavaDebugService::inspectThreads() {
    inspect("Threads", "threads", InspectionKind::Threads);
}

void JavaDebugService::inspectStack() {
    inspect("Call Stack", "where all", InspectionKind::Stack);
}

void JavaDebugService::inspectVariables() {
    inspect("Local Variables", "locals", InspectionKind::Locals);
}

void JavaDebugService::evaluate(const std::string& expression) {
    const auto value = trim(expression);
    if (value.empty()) return;
    {
        std::lock_guard lock(mutex_);
        snapshot_.inspectionTitle = "Evaluate";
        snapshot_.inspectionOutput = "> print " + value + "\n";
        inspectionKind_ = InspectionKind::Evaluate;
    }
    if (canControl()) sendCommand("print " + value);
    else {
        std::lock_guard lock(mutex_);
        snapshot_.inspectionOutput =
            "Start or pause a debug session before evaluating an expression.\n";
    }
    notifyState();
}

void JavaDebugService::toggleVariable(const JavaDebugVariable& variable) {
    if (!variable.canExpand()) return;
    if (variable.isExpanded) {
        updateVariable(variable.id, [](JavaDebugVariable& value) {
            value.isExpanded = false;
        });
        return;
    }
    if (!canControl()) return;
    {
        std::lock_guard lock(mutex_);
        updateVariable(variable.id, [](JavaDebugVariable& value) {
            value.isExpanded = true;
        });
        snapshot_.expandingVariableID = variable.id;
        snapshot_.inspectionTitle = "Local Variables";
        snapshot_.inspectionOutput = "> dump " + variable.expression + "\n";
        inspectionKind_ = InspectionKind::Dump;
        inspectionVariableID_ = variable.id;
    }
    sendCommand("dump " + variable.expression);
    notifyState();
}

void JavaDebugService::clearOutput() {
    {
        std::lock_guard lock(mutex_);
        snapshot_.output.clear();
        snapshot_.inspectionOutput.clear();
        snapshot_.variables.clear();
        snapshot_.threads.clear();
        snapshot_.callStack.clear();
        snapshot_.expandingVariableID.reset();
        snapshot_.exceptionMessage.reset();
    }
    notifyState();
}

void JavaDebugService::stop() {
    {
        std::lock_guard lock(mutex_);
        sessionID_ = nextID("stopped");
        attachDeadlineActive_ = false;
        bootstrapDeadlineActive_ = false;
    }
    if (jdb_ != nullptr && jdb_->isRunning()) {
        jdb_->send("quit\n");
        jdb_->stop();
    }
    if (debuggee_ != nullptr && debuggee_->isRunning()) debuggee_->stop();
    {
        std::lock_guard lock(mutex_);
        debuggeeOperationID_.clear();
        jdbOperationID_.clear();
        debugClassName_.clear();
        activeJDBPath_.clear();
        activeJavaHomePath_.clear();
        activeJDBHost_ = "127.0.0.1";
        launchesDebuggee_ = false;
        didBootstrap_ = false;
        inspectionKind_.reset();
        inspectionVariableID_.reset();
        snapshot_.state = JavaDebugSessionState::Idle;
        snapshot_.inspectionTitle.reset();
        snapshot_.inspectionOutput.clear();
        snapshot_.variables.clear();
        snapshot_.threads.clear();
        snapshot_.callStack.clear();
        snapshot_.expandingVariableID.reset();
        snapshot_.exceptionMessage.reset();
        snapshot_.port.reset();
        snapshot_.runningTargetTitle.clear();
    }
    notifyState();
}

void JavaDebugService::poll() {
    bool shouldAttach = false;
    bool shouldBootstrap = false;
    std::string executable;
    std::string host;
    std::string javaHomePath;
    std::uint16_t port = 0;
    {
        std::lock_guard lock(mutex_);
        const auto now = std::chrono::steady_clock::now();
        if (attachDeadlineActive_ && now >= attachDeadline_ &&
            !jdb_->isRunning() && debuggee_->isRunning() && snapshot_.port) {
            shouldAttach = true;
            attachDeadlineActive_ = false;
            executable = activeJDBPath_;
            host = activeJDBHost_;
            javaHomePath = activeJavaHomePath_;
            port = *snapshot_.port;
        }
        if (bootstrapDeadlineActive_ && now >= bootstrapDeadline_ &&
            jdb_->isRunning()) {
            shouldBootstrap = true;
            bootstrapDeadlineActive_ = false;
        }
    }
    if (shouldAttach && !executable.empty()) {
        startJDB(executable, host, port,
                 snapshot().targetKind == JavaDebugTargetKind::RunConfiguration
                     ? RuntimeProcessKind::Maven : RuntimeProcessKind::Java,
                 javaHomePath);
    }
    if (shouldBootstrap) bootstrapJDB();
}

std::string JavaDebugService::classNameFor(const std::filesystem::path& file,
                                           const std::string& sourceText) {
    const auto simpleName = file.stem().string();
    const auto packageStart = sourceText.find("package");
    if (packageStart == std::string::npos) return simpleName;
    const auto semicolon = sourceText.find(';', packageStart);
    if (semicolon == std::string::npos) return simpleName;
    auto packageName = trimView(sourceText.substr(packageStart + 7,
                                                  semicolon - packageStart - 7));
    if (packageName.empty()) return simpleName;
    return packageName + "." + simpleName;
}

std::vector<std::string> JavaDebugService::parseArguments(std::string_view input) {
    std::vector<std::string> result;
    std::string current;
    char quote = '\0';
    bool escaped = false;
    for (const char character : input) {
        if (escaped) {
            current.push_back(character);
            escaped = false;
            continue;
        }
        if (character == '\\' && quote != '\'') {
            escaped = true;
            continue;
        }
        if (character == '\'' || character == '"') {
            if (quote == character) quote = '\0';
            else if (quote == '\0') quote = character;
            else current.push_back(character);
            continue;
        }
        if (std::isspace(static_cast<unsigned char>(character)) != 0 && quote == '\0') {
            if (!current.empty()) {
                result.push_back(std::move(current));
                current.clear();
            }
            continue;
        }
        current.push_back(character);
    }
    if (escaped) current.push_back('\\');
    if (!current.empty()) result.push_back(std::move(current));
    return result;
}

std::vector<JavaDebugVariable> JavaDebugService::parseVariables(std::string_view text) {
    std::vector<JavaDebugVariable> result;
    for (const auto& line : lines(text)) {
        const auto assignment = parseAssignment(line);
        if (!assignment || std::any_of(result.begin(), result.end(),
                                       [&](const auto& value) {
                                           return value.id == assignment->first;
                                       })) {
            continue;
        }
        result.push_back({assignment->first, assignment->first, assignment->first,
                          assignment->second, {}, false, looksExpandable(assignment->second)});
    }
    return result;
}

std::vector<JavaDebugVariable> JavaDebugService::parseDumpChildren(
    std::string_view text, const JavaDebugVariable& parent) {
    std::vector<JavaDebugVariable> result;
    for (const auto& line : lines(text)) {
        const auto assignment = parseAssignment(line);
        if (!assignment || assignment->first == parent.name ||
            assignment->first == parent.expression) {
            continue;
        }
        const auto expression = !assignment->first.empty() && assignment->first.front() == '['
            ? parent.expression + assignment->first
            : parent.expression + "." + assignment->first;
        if (std::any_of(result.begin(), result.end(), [&](const auto& value) {
                return value.id == expression;
            })) {
            continue;
        }
        result.push_back({expression, assignment->first, expression, assignment->second,
                          {}, false, looksExpandable(assignment->second)});
    }
    return result;
}

std::vector<JavaDebugThread> JavaDebugService::parseThreads(std::string_view text) {
    std::vector<JavaDebugThread> result;
    for (const auto& rawLine : lines(text)) {
        const auto line = trimView(rawLine);
        if (line.empty() || lower(line).starts_with("group ")) continue;
        std::string id;
        std::string name;
        std::string status;
        const auto colon = line.find(':');
        if (colon != std::string::npos) {
            const auto candidate = trimView(line.substr(0, colon));
            if (!candidate.empty() &&
                std::all_of(candidate.begin(), candidate.end(), [](char value) {
                    return std::isdigit(static_cast<unsigned char>(value)) != 0;
                })) {
                id = candidate;
                auto remainder = trimView(line.substr(colon + 1));
                if (!remainder.empty() && remainder.front() == '"') {
                    const auto closing = remainder.find('"', 1);
                    if (closing != std::string::npos) {
                        name = remainder.substr(1, closing - 1);
                        status = trimView(remainder.substr(closing + 1));
                    }
                }
                if (name.empty()) {
                    const auto split = remainder.find_first_of(" \t");
                    name = split == std::string::npos ? remainder : remainder.substr(0, split);
                    status = split == std::string::npos ? "" : trimView(remainder.substr(split + 1));
                }
            }
        } else if (!line.empty() && line.front() == '(') {
            const auto closing = line.find(')');
            if (closing != std::string::npos) {
                const auto remainder = trimView(line.substr(closing + 1));
                const auto split = remainder.find_first_of(" \t");
                id = split == std::string::npos ? remainder : remainder.substr(0, split);
                name = split == std::string::npos ? line.substr(0, closing + 1)
                                                  : remainder.substr(split + 1);
            }
        }
        if (id.empty() || std::any_of(result.begin(), result.end(),
                                      [&](const auto& value) { return value.id == id; })) {
            continue;
        }
        result.push_back({id, name.empty() ? "Thread " + id : name, status,
                          line.find('*') != std::string::npos ||
                              lower(status).find("current") != std::string::npos});
    }
    return result;
}

std::vector<JavaDebugStackFrame> JavaDebugService::parseStackFrames(std::string_view text) {
    std::vector<JavaDebugStackFrame> result;
    for (const auto& rawLine : lines(text)) {
        const auto line = trimView(rawLine);
        if (line.size() < 4 || line.front() != '[') continue;
        const auto closing = line.find(']');
        if (closing == std::string::npos) continue;
        try {
            const auto level = std::stoi(line.substr(1, closing - 1));
            const auto description = trimView(line.substr(closing + 1));
            if (!description.empty()) result.push_back({level, description});
        } catch (...) {
        }
    }
    return result;
}

bool JavaDebugService::containsException(std::string_view text) {
    for (const auto& rawLine : lines(text)) {
        const auto line = trimView(rawLine);
        const auto value = lower(line);
        if ((value.find("exception") != std::string::npos &&
             (value.find("exception occurred") != std::string::npos ||
              value.find("exception in thread") != std::string::npos ||
              value.find("uncaught exception") != std::string::npos)) ||
            value.starts_with("caused by:")) {
            return true;
        }
    }
    return false;
}

std::string JavaDebugService::nextID(std::string_view prefix) {
    static std::atomic<std::uint64_t> sequence{0};
    return std::string(prefix) + "-" + std::to_string(++sequence);
}

std::string JavaDebugService::pathText(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

std::filesystem::path JavaDebugService::pathFromText(const std::string& path) {
    const auto* data = reinterpret_cast<const char8_t*>(path.data());
    return std::filesystem::path(std::u8string(data, data + path.size()));
}

bool JavaDebugService::isInside(const std::filesystem::path& path,
                                const std::filesystem::path& root) {
    const auto relative = path.lexically_normal().lexically_relative(root.lexically_normal());
    if (relative.empty()) return false;
    for (const auto& component : relative) {
        if (component == "..") return false;
    }
    return true;
}

std::string JavaDebugService::trim(std::string value) {
    return trimView(value);
}

bool JavaDebugService::isValidVariableName(std::string_view name) {
    if (name.size() >= 2 && name.front() == '[' && name.back() == ']') return true;
    if (name.empty()) return false;
    const auto first = static_cast<unsigned char>(name.front());
    if (std::isalpha(first) == 0 && name.front() != '_' && name.front() != '$') return false;
    return std::all_of(name.begin() + 1, name.end(), [](char value) {
        const auto character = static_cast<unsigned char>(value);
        return std::isalnum(character) != 0 || value == '_' || value == '$';
    });
}

bool JavaDebugService::looksExpandable(std::string_view value) {
    const auto lowerValue = lower(std::string(value));
    return (!value.empty() && value.back() == '{') ||
        lowerValue.find("instance of ") != std::string::npos ||
        lowerValue.find("[length") != std::string::npos ||
        lowerValue.find("array") != std::string::npos;
}

std::optional<std::pair<std::string, std::string>> JavaDebugService::parseAssignment(
    std::string_view line) {
    const auto value = trimView(line);
    if (value.empty() || value.front() == '>' || value.back() == ':') return std::nullopt;
    const auto separator = value.find(" = ");
    if (separator == std::string::npos) return std::nullopt;
    const auto name = trimView(value.substr(0, separator));
    const auto assigned = trimView(value.substr(separator + 3));
    if (!isValidVariableName(name) || assigned.empty()) return std::nullopt;
    return std::pair{name, assigned};
}

std::vector<std::string> JavaDebugService::lines(std::string_view text) {
    std::vector<std::string> result;
    std::size_t start = 0;
    for (;;) {
        const auto end = text.find('\n', start);
        auto line = std::string(text.substr(start,
            end == std::string_view::npos ? text.size() - start : end - start));
        if (!line.empty() && line.back() == '\r') line.pop_back();
        result.push_back(std::move(line));
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return result;
}

void JavaDebugService::configureProcesses() {
    debuggee_->setOutputHandler([this](const std::string& value) {
        appendDebuggeeOutput(value);
    });
    debuggee_->setErrorHandler([this](const std::string& value) {
        handleProcessError(value, ProcessKind::Debuggee);
    });
    debuggee_->setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        handleLifecycle(event, ProcessKind::Debuggee);
    });
    jdb_->setOutputHandler([this](const std::string& value) {
        appendJDBOutput(value);
    });
    jdb_->setErrorHandler([this](const std::string& value) {
        handleProcessError(value, ProcessKind::JDB);
    });
    jdb_->setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        handleLifecycle(event, ProcessKind::JDB);
    });
}

void JavaDebugService::notifyState() {
    StateHandler handler;
    {
        std::lock_guard lock(mutex_);
        handler = stateHandler_;
    }
    if (handler) handler();
}

void JavaDebugService::prepareSession(JavaDebugTargetKind target,
                                      std::optional<std::uint16_t> port,
                                      std::string host,
                                      std::string title,
                                      bool launchesDebuggee) {
    std::lock_guard lock(mutex_);
    sessionID_ = nextID("debug-session");
    snapshot_.targetKind = target;
    snapshot_.state = JavaDebugSessionState::Launching;
    snapshot_.output.clear();
    snapshot_.inspectionTitle.reset();
    snapshot_.inspectionOutput.clear();
    snapshot_.variables.clear();
    snapshot_.threads.clear();
    snapshot_.callStack.clear();
    snapshot_.expandingVariableID.reset();
    snapshot_.exceptionMessage.reset();
    snapshot_.port = port;
    snapshot_.runningTargetTitle = std::move(title);
    activeJDBHost_ = std::move(host);
    launchesDebuggee_ = launchesDebuggee;
    didBootstrap_ = false;
    inspectionKind_.reset();
    inspectionVariableID_.reset();
    attachDeadlineActive_ = false;
    bootstrapDeadlineActive_ = false;
}

void JavaDebugService::startDebuggee(ProcessRequest request,
                                     const std::string& host,
                                     std::uint16_t port) {
    {
        std::lock_guard lock(mutex_);
        debuggeeOperationID_ = request.operationID;
        attachDeadline_ = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        attachDeadlineActive_ = true;
        activeJDBHost_ = host;
        snapshot_.port = port;
    }
    std::string command = "$ " + request.executablePath;
    for (const auto& argument : request.arguments) command += " " + argument;
    appendOutput(command + "\n\n");
    debuggee_->start(request);
    notifyState();
}

void JavaDebugService::startJDB(const std::string& executable,
                                const std::string& host,
                                std::uint16_t port,
                                RuntimeProcessKind processKind,
                                const std::string& javaHomePath) {
    if (executable.empty() || jdb_->isRunning()) return;
    std::string operationID;
    {
        std::lock_guard lock(mutex_);
        attachDeadlineActive_ = false;
        jdbOperationID_ = nextID("windows-jdb");
        operationID = jdbOperationID_;
        bootstrapDeadline_ = std::chrono::steady_clock::now() +
                             std::chrono::milliseconds(900);
        bootstrapDeadlineActive_ = true;
        activeJDBHost_ = host;
        activeJDBPath_ = executable;
        snapshot_.port = port;
    }
    ProcessRequest request;
    request.operationID = operationID;
    request.executablePath = executable;
    request.arguments = {
        "-J-Duser.language=en", "-J-Duser.country=US",
        "-attach", host + ":" + std::to_string(port)};
    request.environment = runtime_.environment(runtimeSettings_, processKind, javaHomePath);
    request.keepsStandardInputOpen = true;
    appendOutput("Attach jdb to " + host + ":" + std::to_string(port) + "\n\n");
    jdb_->start(request);
    notifyState();
}

void JavaDebugService::bootstrapJDB() {
    std::vector<JavaDebugBreakpoint> breakpoints;
    bool launches = false;
    {
        std::lock_guard lock(mutex_);
        if (didBootstrap_) return;
        didBootstrap_ = true;
        bootstrapDeadlineActive_ = false;
        breakpoints = snapshot_.breakpoints;
        launches = launchesDebuggee_;
    }
    for (const auto& breakpoint : breakpoints) {
        sendCommand("stop at " + breakpoint.className + ":" +
                    std::to_string(breakpoint.line));
    }
    if (launches) {
        sendCommand("run");
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Running;
    } else {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Paused;
    }
    notifyState();
}

void JavaDebugService::sendCommand(const std::string& command) {
    if (jdb_ == nullptr || !jdb_->isRunning()) return;
    jdb_->send(command + "\n");
}

void JavaDebugService::inspect(const std::string& title,
                               const std::string& command,
                               InspectionKind kind) {
    {
        std::lock_guard lock(mutex_);
        snapshot_.inspectionTitle = title;
        snapshot_.inspectionOutput = "> " + command + "\n";
        inspectionKind_ = kind;
        inspectionVariableID_.reset();
        snapshot_.expandingVariableID.reset();
        if (kind == InspectionKind::Threads) snapshot_.threads.clear();
        if (kind == InspectionKind::Stack) snapshot_.callStack.clear();
        if (kind == InspectionKind::Locals) snapshot_.variables.clear();
    }
    sendCommand(command);
    notifyState();
}

void JavaDebugService::refreshInspectionData() {
    if (!inspectionKind_) return;
    switch (*inspectionKind_) {
    case InspectionKind::Threads:
        snapshot_.threads = parseThreads(snapshot_.inspectionOutput);
        break;
    case InspectionKind::Stack:
        snapshot_.callStack = parseStackFrames(snapshot_.inspectionOutput);
        break;
    case InspectionKind::Locals:
        snapshot_.variables = parseVariables(snapshot_.inspectionOutput);
        break;
    case InspectionKind::Dump: {
        if (!inspectionVariableID_) break;
        auto* parent = findVariable(snapshot_.variables, *inspectionVariableID_);
        if (parent == nullptr) break;
        const auto children = parseDumpChildren(snapshot_.inspectionOutput, *parent);
        if (!children.empty()) {
            parent->children = children;
            parent->isExpanded = true;
            snapshot_.expandingVariableID.reset();
        }
        break;
    }
    case InspectionKind::Evaluate:
        break;
    }
}

void JavaDebugService::appendOutput(const std::string& value) {
    if (value.empty()) return;
    {
        std::lock_guard lock(mutex_);
        snapshot_.output += value;
        std::replace(snapshot_.output.begin(), snapshot_.output.end(), '\r', '\0');
        snapshot_.output.erase(std::remove(snapshot_.output.begin(),
                                           snapshot_.output.end(), '\0'),
                               snapshot_.output.end());
        constexpr std::size_t maximum = 400000;
        if (snapshot_.output.size() > maximum) {
            snapshot_.output.erase(0, snapshot_.output.size() - maximum);
        }
    }
}

void JavaDebugService::appendDebuggeeOutput(const std::string& value) {
    bool listening = false;
    std::string executable;
    std::string host;
    std::string javaHomePath;
    std::uint16_t port = 0;
    JavaDebugTargetKind target = JavaDebugTargetKind::CurrentFile;
    {
        std::lock_guard lock(mutex_);
        const auto lowerValue = lower(value);
        listening = lowerValue.find("listening for transport") != std::string::npos;
        snapshot_.exceptionMessage = containsException(value)
            ? std::optional<std::string>(trimView(value)) : snapshot_.exceptionMessage;
        snapshot_.output += "[debuggee] " + value;
        constexpr std::size_t maximum = 400000;
        if (snapshot_.output.size() > maximum) {
            snapshot_.output.erase(0, snapshot_.output.size() - maximum);
        }
        if (listening && snapshot_.port && !jdb_->isRunning()) {
            executable = activeJDBPath_;
            host = activeJDBHost_;
            javaHomePath = activeJavaHomePath_;
            port = *snapshot_.port;
            target = snapshot_.targetKind;
        }
    }
    if (listening && !executable.empty()) {
        startJDB(executable, host, port,
                 target == JavaDebugTargetKind::RunConfiguration
                     ? RuntimeProcessKind::Maven : RuntimeProcessKind::Java,
                 javaHomePath);
    }
    notifyState();
}

void JavaDebugService::appendJDBOutput(const std::string& value) {
    bool paused = false;
    {
        std::lock_guard lock(mutex_);
        snapshot_.output += "[jdb] " + value;
        if (snapshot_.inspectionTitle) {
            snapshot_.inspectionOutput += value;
            constexpr std::size_t maximumInspection = 80000;
            if (snapshot_.inspectionOutput.size() > maximumInspection) {
                snapshot_.inspectionOutput.erase(
                    0, snapshot_.inspectionOutput.size() - maximumInspection);
            }
            refreshInspectionData();
        }
        if (containsException(value)) {
            snapshot_.exceptionMessage = trimView(value);
            paused = true;
        }
        const auto lowerValue = lower(value);
        paused = paused || value.find("Breakpoint hit:") != std::string::npos ||
                 value.find("Step completed:") != std::string::npos ||
                 value.find("Method entered:") != std::string::npos;
        if (paused) snapshot_.state = JavaDebugSessionState::Paused;
        constexpr std::size_t maximum = 400000;
        if (snapshot_.output.size() > maximum) {
            snapshot_.output.erase(0, snapshot_.output.size() - maximum);
        }
        (void)lowerValue;
    }
    notifyState();
}

void JavaDebugService::handleLifecycle(const ProcessLifecycleEvent& event,
                                       ProcessKind kind) {
    bool accepted = false;
    {
        std::lock_guard lock(mutex_);
        const auto& expected = kind == ProcessKind::Debuggee
            ? debuggeeOperationID_ : jdbOperationID_;
        if (expected.empty() || event.operationID != expected) return;
        accepted = true;
        if (event.state == ProcessLifecycleState::Starting) {
            snapshot_.state = JavaDebugSessionState::Launching;
        } else if (event.state == ProcessLifecycleState::Running) {
            if (kind == ProcessKind::JDB && didBootstrap_) {
                snapshot_.state = launchesDebuggee_
                    ? JavaDebugSessionState::Running
                    : JavaDebugSessionState::Paused;
            }
        } else if (event.state == ProcessLifecycleState::Failed) {
            snapshot_.state = JavaDebugSessionState::Failed;
            if (!event.message.empty()) {
                snapshot_.output += "["
                    + std::string(kind == ProcessKind::JDB ? "jdb" : "debuggee")
                    + ": " + event.message + "]\n";
            }
        } else if (event.state == ProcessLifecycleState::Finished &&
                   kind == ProcessKind::JDB &&
                   (snapshot_.state == JavaDebugSessionState::Launching ||
                    snapshot_.state == JavaDebugSessionState::Running)) {
            snapshot_.state = JavaDebugSessionState::Failed;
            snapshot_.output += "[jdb exited]\n";
        }
    }
    if (accepted) notifyState();
}

void JavaDebugService::handleProcessError(const std::string& value,
                                          ProcessKind kind) {
    appendOutput("[" + std::string(kind == ProcessKind::JDB ? "jdb stderr" : "debuggee stderr") +
                 "] " + value);
    notifyState();
}

void JavaDebugService::updateVariable(
    const std::string& id,
    const std::function<void(JavaDebugVariable&)>& update) {
    {
        std::lock_guard lock(mutex_);
        auto* value = findVariable(snapshot_.variables, id);
        if (value == nullptr) return;
        update(*value);
    }
    notifyState();
}

JavaDebugVariable* JavaDebugService::findVariable(
    std::vector<JavaDebugVariable>& values, const std::string& id) {
    for (auto& value : values) {
        if (value.id == id) return &value;
        if (auto* child = findVariable(value.children, id)) return child;
    }
    return nullptr;
}

const JavaDebugVariable* JavaDebugService::findVariable(
    const std::vector<JavaDebugVariable>& values, const std::string& id) const {
    for (const auto& value : values) {
        if (value.id == id) return &value;
        if (const auto* child = findVariable(value.children, id)) return child;
    }
    return nullptr;
}

std::filesystem::path JavaDebugService::workingDirectory(
    const std::string& requested,
    const std::filesystem::path& fallback) const {
    const auto value = trim(requested);
    if (value.empty()) return fallback;
    auto environment = runtime_.environment(runtimeSettings_, RuntimeProcessKind::Java);
    auto home = environment.find("USERPROFILE");
    if (home == environment.end()) home = environment.find("HOME");
    std::filesystem::path candidate;
    if (value == "~" || value.starts_with("~/") || value.starts_with("~\\")) {
        if (home != environment.end()) candidate = pathFromText(home->second) / value.substr(2);
    } else {
        candidate = pathFromText(value);
        if (!candidate.is_absolute()) candidate = fallback / candidate;
    }
    if (candidate.empty()) return fallback;
    const auto metadata = storage_.metadata(pathText(candidate.lexically_normal()));
    return metadata && metadata->isDirectory ? candidate.lexically_normal() : fallback;
}

void JavaDebugService::fail(std::string message) {
    if (message.empty()) message = "Java debug session failed";
    {
        std::lock_guard lock(mutex_);
        snapshot_.state = JavaDebugSessionState::Failed;
        snapshot_.output = std::move(message) + "\n";
    }
    if (debuggee_ != nullptr && debuggee_->isRunning()) debuggee_->stop();
    if (jdb_ != nullptr && jdb_->isRunning()) jdb_->stop();
    notifyState();
}

} // namespace lithe::windows::app
