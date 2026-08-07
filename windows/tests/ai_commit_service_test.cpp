#include "ai_commit_service.h"

#include <cassert>
#include <map>
#include <string>
#include <vector>

namespace {

using namespace lithe::windows;
using namespace lithe::windows::app;

class FakeSecureStore final : public SecureStore {
public:
    std::map<std::string, std::string> values;

    std::optional<std::string> read(const std::string& key) const override {
        const auto found = values.find(key);
        return found == values.end() ? std::nullopt : std::optional(found->second);
    }
    bool write(const std::string&, const std::string&, std::string&) override { return true; }
    bool remove(const std::string&, std::string&) override { return true; }
};

class FakeTransport final : public AIHTTPTransport {
public:
    HTTPRequest request;
    HTTPResponse response{200, {}};

    std::optional<HTTPResponse> send(const HTTPRequest& value, std::string&) override {
        request = value;
        return response;
    }
};

AICommitProvider provider(AICommitAPIProtocol protocol) {
    return {"provider", "Test", "https://api.example.test/v1", "test-model", protocol,
            protocol == AICommitAPIProtocol::AnthropicMessages
                ? AICommitAuthentication::APIKey : AICommitAuthentication::Bearer,
            false, "test-key", true};
}

AICommitInput input() {
    return {{{"src/Main.java", "modified", "@@ -1 +1 @@\n-old\n+new\n"}}};
}

} // namespace

int main() {
    using namespace lithe::windows::app;

    assert(AICommitMessageService::endpointFor(provider(AICommitAPIProtocol::Responses)) ==
           "https://api.example.test/v1/responses");
    auto anthropic = provider(AICommitAPIProtocol::AnthropicMessages);
    anthropic.endpoint = "https://api.example.test";
    assert(AICommitMessageService::endpointFor(anthropic) ==
           "https://api.example.test/v1/messages");
    assert(AICommitMessageService::isSensitivePath(".env.local"));
    assert(AICommitMessageService::isSensitivePath("certs/client.P12"));
    assert(!AICommitMessageService::isSensitivePath("src/Main.java"));
    assert(AICommitMessageService::normalizeMessage("```text\nCommit message: fix it\n```") ==
           "fix it");

    FakeSecureStore secureStore;
    secureStore.values["test-key"] = "secret";
    FakeTransport transport;
    AICommitMessageService service(transport, secureStore);
    AICommitSettings settings;
    settings.providers = {provider(AICommitAPIProtocol::Responses)};
    settings.activeProviderID = "provider";
    AICommitError error;

    transport.response.body = R"({"output_text":"feat: add Java change"})";
    assert(service.generate(input(), settings, error) == "feat: add Java change");
    assert(transport.request.url == "https://api.example.test/v1/responses");
    assert(transport.request.headers.at("Authorization") == "Bearer secret");
    assert(transport.request.body.find("test-model") != std::string::npos);

    settings.providers = {provider(AICommitAPIProtocol::ChatCompletions)};
    transport.response.body = R"({"choices":[{"message":{"content":"fix: chat"}}]})";
    assert(service.generate(input(), settings, error) == "fix: chat");
    assert(transport.request.url.ends_with("/v1/chat/completions"));

    settings.providers = {provider(AICommitAPIProtocol::AnthropicMessages)};
    transport.response.body = R"({"content":[{"type":"text","text":"fix: Claude"}]})";
    assert(service.generate(input(), settings, error) == "fix: Claude");
    assert(transport.request.headers.at("x-api-key") == "secret");
    assert(transport.request.headers.at("anthropic-version") == "2023-06-01");

    auto unsafe = settings;
    unsafe.providers[0].endpoint = "http://api.example.test";
    assert(service.generate(input(), unsafe, error).empty());
    assert(error.code == AICommitErrorCode::InsecureEndpoint);

    auto sensitive = input();
    sensitive.files[0].path = ".env.production";
    assert(service.generate(sensitive, settings, error).empty());
    assert(error.code == AICommitErrorCode::SensitiveFileExcluded);
    return 0;
}
