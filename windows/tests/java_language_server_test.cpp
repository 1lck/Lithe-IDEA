#include "java_language_server.h"

#include <cassert>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace {

using namespace lithe::windows;
using namespace lithe::windows::app;

std::string pathText(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

class FakeRuntimeLocator final : public lithe::windows::RuntimeLocator {
public:
    std::map<std::string, std::string> values;
    std::set<std::string> homes;
    std::set<std::string> executables;
    std::optional<std::string> languageServer;

    std::map<std::string, std::string> environment() const override { return values; }
    lithe::windows::RuntimeDiscoveryResult discover() const override { return {}; }
    std::optional<std::string> validJavaHome(const std::string& path) const override {
        return homes.contains(path) ? std::optional(path) : std::nullopt;
    }
    bool isExecutable(const std::string& path) const override {
        return executables.contains(path);
    }
    std::optional<std::string> systemMavenExecutable() const override { return std::nullopt; }
    std::optional<std::string> mavenExecutableForHomePath(
        const std::string&) const override { return std::nullopt; }
    std::optional<std::string> systemJDBExecutable() const override { return std::nullopt; }
    std::optional<std::string> javaLanguageServerExecutable() const override {
        return languageServer;
    }
};

class FakeStorage final : public lithe::windows::FileStorage {
public:
    std::string cache = "/tmp/lithe-lsp-cache";

    std::string homeDirectory() const override { return "/tmp"; }
    std::string cacheDirectory() const override { return cache; }
    std::string applicationSupportDirectory() const override { return "/tmp/lithe"; }
    std::optional<lithe::windows::FileMetadata> metadata(
        const std::string&) const override { return std::nullopt; }
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

class FakeProcess final : public lithe::windows::ProcessSession {
public:
    ProcessRequest request;
    std::vector<std::string> sends;
    OutputHandler output;
    ErrorHandler error;
    LifecycleHandler lifecycle;
    bool running = false;

    void start(const ProcessRequest& value) override {
        request = value;
        running = true;
    }
    void send(const std::string& input) override { sends.push_back(input); }
    void closeInput() override {}
    void stop() override { running = false; }
    bool isRunning() const override { return running; }
    void setOutputHandler(OutputHandler value) override { output = std::move(value); }
    void setErrorHandler(ErrorHandler value) override { error = std::move(value); }
    void setLifecycleHandler(LifecycleHandler value) override { lifecycle = std::move(value); }

    void feed(const std::string& bytes) { if (output) output(bytes); }
    void emitRunning() {
        if (lifecycle) lifecycle({request.operationID, ProcessLifecycleState::Running,
                                  std::nullopt, {}});
    }
};

JsonValue bodyFromFrame(const std::string& frame) {
    lithe::windows::app::LspFrameDecoder decoder;
    const auto bodies = decoder.feed(frame);
    assert(bodies.size() == 1);
    const auto parsed = lithe::windows::parseJson(bodies[0]);
    assert(parsed.value);
    return *parsed.value;
}

std::string jsonFrame(const std::string& value) {
    return lithe::windows::app::frameLspMessage(value);
}

} // namespace

int main() {
    using namespace lithe::windows;
    using namespace lithe::windows::app;

    LspFrameDecoder decoder;
    assert(decoder.feed("Content-Length: 5\r\n\r\nhe").empty());
    auto frames = decoder.feed("lloContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
                               "Content-Length: 4\r\n\r\none!Content-Length: 3\r\n\r\nbye");
    assert((frames == std::vector<std::string>{"hello", "one!", "bye"}));
    assert(frameLspMessage("abc") == "Content-Length: 3\r\n\r\nabc");

    FakeRuntimeLocator locator;
    const auto javaHome = pathText(std::filesystem::path("/tmp/jdk"));
    locator.values = {{"JAVA_HOME", javaHome}, {"PATH", "/usr/bin"}};
    locator.homes.insert(javaHome);
    locator.executables.insert(pathText(std::filesystem::path(javaHome) / "bin" / "java"));
    locator.languageServer = "/tmp/jdtls/jdtls";
    FakeStorage storage;
    FakeProcess process;
    ProjectRuntimeService runtime(locator);
    JavaLanguageServerClient client(runtime, storage, process);

    bool ready = false;
    client.setStateHandler([&](bool value, const std::string&) { ready = value; });
    std::vector<std::pair<std::string, JsonValue>> diagnostics;
    client.setDiagnosticsHandler([&](const std::string& uri, const JsonValue& value) {
        diagnostics.emplace_back(uri, value);
    });

    std::string error;
    assert(client.start(std::filesystem::path("/tmp/project"), error));
    assert(error.empty());
    assert(client.isStarting());
    assert(process.request.keepsStandardInputOpen);
    assert(process.sends.empty());
    process.emitRunning();
    assert(process.sends.size() == 1);
    auto initialize = bodyFromFrame(process.sends[0]);
    assert(objectValue(initialize, "method") != nullptr);
    assert(*objectValue(initialize, "method")->asString() == "initialize");
    const auto initializeID = objectValue(initialize, "id")->asUInt();
    assert(initializeID);
    process.feed(jsonFrame("{\"jsonrpc\":\"2.0\",\"id\":" +
                           std::to_string(*initializeID) + ",\"result\":{}}"));
    assert(ready);
    assert(!client.isStarting());

    const auto uri = "file:///tmp/project/src/Main.java";
    client.didOpen(uri, "java", 1, "class Main {}\n");
    client.didChange(uri, "class Main { int value; }\n");
    client.flushChanges();
    bool sawChange = false;
    for (const auto& sent : process.sends) {
        const auto message = bodyFromFrame(sent);
        const auto* method = objectValue(message, "method");
        if (method && method->asString() && *method->asString() == "textDocument/didChange") {
            sawChange = true;
        }
    }
    assert(sawChange);

    bool responseReceived = false;
    client.request("textDocument/definition", JsonValue(JsonValue::Object{}),
        [&](std::optional<JsonValue> result, std::optional<LspRpcError> rpcError) {
            responseReceived = result.has_value() && !rpcError.has_value();
        });
    const auto requestMessage = bodyFromFrame(process.sends.back());
    const auto requestID = objectValue(requestMessage, "id")->asUInt();
    assert(requestID);
    process.feed(jsonFrame("{\"jsonrpc\":\"2.0\",\"id\":" +
                           std::to_string(*requestID) + ",\"result\":null}"));
    assert(responseReceived);

    process.feed(jsonFrame(
        "{\"jsonrpc\":\"2.0\",\"id\":55,\"method\":\"workspace/configuration\","
        "\"params\":{\"items\":[{\"section\":\"java\"},{\"section\":\"java.inlayHints\"},"
        "{\"section\":\"java.inlayHints.parameterNames\"},"
        "{\"section\":\"java.inlayHints.parameterNames.enabled\"}]}}"));
    const auto configurationResponse = bodyFromFrame(process.sends.back());
    const auto* configurationResult = objectValue(configurationResponse, "result");
    assert(configurationResult && configurationResult->asArray() &&
           configurationResult->asArray()->size() == 4);
    assert((*configurationResult->asArray())[3].asString() != nullptr);

    process.feed(jsonFrame(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
        "\"params\":{\"uri\":\"file:///tmp/project/src/Main.java\",\"diagnostics\":[]}}"));
    assert(diagnostics.size() == 1);
    client.stop();
    assert(!client.isReady());
    return 0;
}
