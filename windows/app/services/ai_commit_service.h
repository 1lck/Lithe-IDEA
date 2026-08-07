#pragma once

#include "ports.h"
#include "json_value.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::app {

enum class AICommitAPIProtocol {
    Responses,
    ChatCompletions,
    AnthropicMessages,
};

enum class AICommitAuthentication {
    Bearer,
    APIKey,
};

enum class AICommitFormat {
    Conventional,
    Concise,
    Imperative,
    Descriptive,
    ReleaseNote,
    Custom,
};

enum class AICommitLanguage {
    English,
    SimplifiedChinese,
};

struct AICommitProvider {
    std::string id;
    std::string name;
    std::string endpoint;
    std::string model;
    AICommitAPIProtocol protocol = AICommitAPIProtocol::Responses;
    AICommitAuthentication authentication = AICommitAuthentication::Bearer;
    bool allowsInsecureHTTP = false;
    std::string apiKeyIdentifier;
    bool requiresAPIKey = true;
};

struct AICommitSettings {
    std::vector<AICommitProvider> providers;
    std::string activeProviderID;
    AICommitLanguage language = AICommitLanguage::English;
    AICommitFormat format = AICommitFormat::Conventional;
    std::string customInstructions;
    bool includeBody = false;
    std::size_t subjectMaximumLength = 72;
    std::size_t maximumDiffCharacters = 32000;
    std::string reasoningEffort = "low";
};

struct AICommitFile {
    std::string path;
    std::string changeKind;
    std::string diff;
};

struct AICommitInput {
    std::vector<AICommitFile> files;
};

enum class AICommitErrorCode {
    NoProviderConfigured,
    InvalidProvider,
    InsecureEndpoint,
    MissingAPIKey,
    EmptyDiff,
    SensitiveFileExcluded,
    HTTPFailure,
    TransportFailure,
    InvalidResponse,
    EmptyResponse,
};

struct AICommitError {
    AICommitErrorCode code = AICommitErrorCode::InvalidProvider;
    std::string message;
    std::int32_t statusCode = 0;
};

class AICommitMessageService final {
public:
    AICommitMessageService(AIHTTPTransport& transport, SecureStore& secureStore);

    std::string generate(const AICommitInput& input,
                         const AICommitSettings& settings,
                         AICommitError& error) const;

    static std::string endpointFor(const AICommitProvider& provider);
    static std::string renderPrompt(const AICommitInput& input,
                                    const AICommitSettings& settings);
    static std::string normalizeMessage(std::string value);
    static bool isSensitivePath(std::string_view path);
    static std::string decodeResponse(AICommitAPIProtocol protocol,
                                      std::string_view body,
                                      AICommitError& error);

private:
    AIHTTPTransport& transport_;
    SecureStore& secureStore_;

    static const AICommitProvider* activeProvider(const AICommitSettings& settings);
    static std::string systemPrompt(const AICommitSettings& settings);
    static std::string renderFileDiffs(const AICommitInput& input,
                                       std::size_t maximumCharacters);
    static JsonValue responsesBody(const AICommitProvider& provider,
                                   const AICommitSettings& settings,
                                   const std::string& system,
                                   const std::string& user);
    static JsonValue chatBody(const AICommitProvider& provider,
                              const AICommitSettings& settings,
                              const std::string& system,
                              const std::string& user);
    static JsonValue anthropicBody(const AICommitProvider& provider,
                                   const std::string& system,
                                   const std::string& user);
};

} // namespace lithe::windows::app
