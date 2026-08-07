#include "java_debug_service.h"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace lithe::windows;
using namespace lithe::windows::app;

class FakeRuntimeLocator final : public RuntimeLocator {
public:
    std::map<std::string, std::string> values{
        {"JAVA_HOME", "/tmp/jdk"},
        {"PATH", "/tmp/jdk/bin"},
        {"USERPROFILE", "/tmp/user"},
    };
    std::set<std::string> homes{"/tmp/jdk"};
    std::set<std::string> executables{
        "/tmp/jdk/bin/java", "/tmp/jdk/bin/jdb", "/tmp/jdk/bin/mvn",
    };

    std::map<std::string, std::string> environment() const override { return values; }
    RuntimeDiscoveryResult discover() const override { return {}; }
    std::optional<std::string> validJavaHome(const std::string& path) const override {
        return homes.contains(path) ? std::optional(path) : std::nullopt;
    }
    bool isExecutable(const std::string& path) const override {
        return executables.contains(path);
    }
    std::optional<std::string> systemMavenExecutable() const override {
        return "/tmp/jdk/bin/mvn";
    }
    std::optional<std::string> mavenExecutableForHomePath(
        const std::string&) const override {
        return "/tmp/jdk/bin/mvn";
    }
    std::optional<std::string> systemJDBExecutable() const override {
        return "/tmp/jdk/bin/jdb";
    }
    std::optional<std::string> javaLanguageServerExecutable() const override {
        return std::nullopt;
    }
};

class FakeStorage final : public FileStorage {
public:
    std::string homeDirectory() const override { return "/tmp/user"; }
    std::string cacheDirectory() const override { return "/tmp/cache"; }
    std::string applicationSupportDirectory() const override { return "/tmp/app"; }
    std::optional<FileMetadata> metadata(const std::string& path) const override {
        if (path == "/tmp/project" || path == "/tmp/project/src") {
            return FileMetadata{std::nullopt, std::nullopt, false, true};
        }
        return std::nullopt;
    }
    bool fileExists(const std::string&) const override { return false; }
    bool isExecutable(const std::string&) const override { return false; }
    std::vector<std::string> listDirectory(const std::string&) const override { return {}; }
    std::optional<std::vector<std::uint8_t>> readData(
        const std::string&, std::string&) const override { return std::nullopt; }
    bool writeData(const std::string&, const std::vector<std::uint8_t>&,
                   std::string&) override { return true; }
    bool createDirectory(const std::string&, bool, std::string&) override { return true; }
    bool removeItem(const std::string&, std::string&) override { return true; }
    bool moveItem(const std::string&, const std::string&, std::string&) override { return true; }
};

class FakeSession final : public ProcessSession {
public:
    ProcessRequest request;
    std::vector<std::string> sent;
    OutputHandler output;
    ErrorHandler error;
    LifecycleHandler lifecycle;
    bool running = false;

    void start(const ProcessRequest& value) override {
        request = value;
        running = true;
    }
    void send(const std::string& value) override { sent.push_back(value); }
    void closeInput() override {}
    void stop() override { running = false; }
    bool isRunning() const override { return running; }
    void setOutputHandler(OutputHandler value) override { output = std::move(value); }
    void setErrorHandler(ErrorHandler value) override { error = std::move(value); }
    void setLifecycleHandler(LifecycleHandler value) override {
        lifecycle = std::move(value);
    }

    void emitRunning() {
        if (lifecycle) lifecycle({request.operationID, ProcessLifecycleState::Running,
                                  std::nullopt, {}});
    }
    void emitOutput(const std::string& value) {
        if (output) output(value);
    }
};

bool contains(const std::vector<std::string>& values, const std::string& needle) {
    for (const auto& value : values) {
        if (value.find(needle) != std::string::npos) return true;
    }
    return false;
}

} // namespace

int main() {
    using namespace lithe::windows;
    using namespace lithe::windows::app;

    const auto variables = JavaDebugService::parseVariables(
        "i = 3\nobject = instance of Foo (id=1)\n> locals\n");
    assert(variables.size() == 2);
    assert(variables[0].id == "i");
    assert(variables[1].isExpandable);

    const auto children = JavaDebugService::parseDumpChildren(
        "object = instance of Foo (id=1)\n[0] = first\nfield = second\n",
        variables[1]);
    assert(children.size() == 2);
    assert(children[0].expression == "object[0]");
    assert(children[1].expression == "object.field");

    const auto threads = JavaDebugService::parseThreads(
        "1: \"main\" running\n2: \"worker\" waiting\n");
    assert(threads.size() == 2);
    assert(threads[0].name == "main");

    const auto stack = JavaDebugService::parseStackFrames(
        "[0] com.example.Main.main(Main.java:4)\n[1] java.lang.Thread.run\n");
    assert(stack.size() == 2);
    assert(stack[0].level == 0);
    assert(JavaDebugService::containsException(
        "Exception in thread \"main\" java.lang.IllegalStateException\n"));

    FakeRuntimeLocator locator;
    FakeStorage storage;
    ProjectRuntimeService runtime(locator);
    JavaRunService javaRun(runtime, storage);
    JavaRunProject project;
    project.root = "/tmp/project";
    project.files = {"/tmp/project/src/Main.java"};
    javaRun.setProject(project);

    std::vector<FakeSession*> sessions;
    JavaDebugService service(runtime, javaRun, storage, [&] {
        auto session = std::make_unique<FakeSession>();
        sessions.push_back(session.get());
        return session;
    });
    bool notified = false;
    service.setStateHandler([&] { notified = true; });
    service.startCurrentFile(
        "/tmp/project/src/Main.java",
        "package com.example;\npublic class Main { public static void main(String[] a) {} }\n",
        {});
    assert(sessions.size() == 2);
    assert(!sessions[0]->request.arguments.empty());
    assert(contains(sessions[0]->request.arguments, "-agentlib:jdwp="));
    assert(service.snapshot().state == JavaDebugSessionState::Launching);
    assert(notified);

    sessions[0]->emitRunning();
    sessions[0]->emitOutput("Listening for transport dt_socket at address: 54321\n");
    assert(sessions[1]->request.executablePath == "/tmp/jdk/bin/jdb");
    assert(contains(sessions[1]->request.arguments, "-J-Duser.language=en"));
    assert(contains(sessions[1]->request.arguments, "-J-Duser.country=US"));
    assert(sessions[1]->request.keepsStandardInputOpen);
    sessions[1]->emitRunning();
    std::this_thread::sleep_for(std::chrono::milliseconds(950));
    service.poll();
    assert(contains(sessions[1]->sent, "run\n"));
    assert(service.snapshot().state == JavaDebugSessionState::Running);

    service.toggleBreakpoint("/tmp/project/src/Main.java", 4, "com.example.Main");
    assert(contains(sessions[1]->sent, "stop at com.example.Main:4\n"));
    service.inspectVariables();
    sessions[1]->emitOutput("i = 3\nobject = instance of Foo (id=1)\n");
    assert(service.snapshot().variables.size() == 2);
    sessions[1]->emitOutput("Breakpoint hit: com.example.Main:4\n");
    assert(service.snapshot().state == JavaDebugSessionState::Paused);
    service.stop();
    assert(service.snapshot().state == JavaDebugSessionState::Idle);
    assert(!sessions[0]->running);
    assert(!sessions[1]->running);
    return 0;
}
