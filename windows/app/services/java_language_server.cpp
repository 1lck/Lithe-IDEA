#include "java_language_server.h"

#include "json_value.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <iomanip>
#include <memory>
#include <sstream>
#include <utility>

namespace lithe::windows::app {
namespace {

const JsonValue* value(const JsonValue& object, std::string_view key) {
    return objectValue(object, key);
}

std::optional<std::uint64_t> messageID(const JsonValue& message) {
    const auto* id = value(message, "id");
    return id == nullptr ? std::nullopt : id->asUInt();
}

std::string pathText(const std::filesystem::path& path) {
    const auto text = path.u8string();
    return {reinterpret_cast<const char*>(text.data()), text.size()};
}

std::filesystem::path pathFromText(const std::string& path) {
    const auto* data = reinterpret_cast<const char8_t*>(path.data());
    return std::filesystem::path(std::u8string(data, data + path.size()));
}

std::string replaceAll(std::string value, char from, char to) {
    std::replace(value.begin(), value.end(), from, to);
    return value;
}

std::string percentDecode(std::string value) {
    std::string decoded;
    decoded.reserve(value.size());
    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] != '%' || index + 2 >= value.size()) {
            decoded.push_back(value[index]);
            continue;
        }
        const auto hex = [](char character) -> int {
            if (character >= '0' && character <= '9') return character - '0';
            if (character >= 'a' && character <= 'f') return character - 'a' + 10;
            if (character >= 'A' && character <= 'F') return character - 'A' + 10;
            return -1;
        };
        const auto high = hex(value[index + 1]);
        const auto low = hex(value[index + 2]);
        if (high < 0 || low < 0) {
            decoded.push_back(value[index]);
            continue;
        }
        decoded.push_back(static_cast<char>((high << 4) | low));
        index += 2;
    }
    return decoded;
}

std::string uriPath(std::string_view uri) {
    const auto scheme = uri.find("://");
    const auto pathStart = scheme == std::string_view::npos
        ? uri.find('/')
        : uri.find('/', scheme + 3);
    if (pathStart == std::string_view::npos) return {};
    auto path = uri.substr(pathStart + 1);
    const auto query = path.find_first_of("?#");
    if (query != std::string_view::npos) path = path.substr(0, query);
    return percentDecode(std::string(path));
}

std::uint32_t decodeUtf8(std::string_view text, std::size_t& index) {
    if (index >= text.size()) return 0xfffd;
    const auto first = static_cast<unsigned char>(text[index++]);
    if (first < 0x80) return first;
    std::size_t length = 0;
    std::uint32_t value = 0;
    if (first >= 0xc2 && first <= 0xdf) {
        length = 1;
        value = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
        length = 2;
        value = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
        length = 3;
        value = first & 0x07;
    } else {
        return 0xfffd;
    }
    if (index + length > text.size()) {
        index = text.size();
        return 0xfffd;
    }
    for (std::size_t offset = 0; offset < length; ++offset) {
        const auto byte = static_cast<unsigned char>(text[index++]);
        if ((byte & 0xc0) != 0x80) return 0xfffd;
        value = (value << 6) | (byte & 0x3f);
    }
    return value;
}

bool isJavaIdentifierCodePoint(std::uint32_t value) {
    return (value >= '0' && value <= '9') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= 'a' && value <= 'z') || value == '_' || value == '$' || value >= 0x80;
}

std::uint64_t utf16Units(std::uint32_t value) {
    return value > 0xffff ? 2 : 1;
}

std::uint64_t utf16Length(std::string_view text) {
    std::uint64_t result = 0;
    for (std::size_t index = 0; index < text.size();) {
        result += utf16Units(decodeUtf8(text, index));
    }
    return result;
}

void appendHoverText(const JsonValue& value, std::string& output) {
    if (const auto* text = value.asString()) {
        if (!output.empty()) output.push_back('\n');
        output += *text;
        return;
    }
    if (const auto* array = value.asArray()) {
        for (const auto& item : *array) appendHoverText(item, output);
        return;
    }
    const auto* object = value.asObject();
    if (object == nullptr) return;
    if (const auto found = object->find("value"); found != object->end()) {
        appendHoverText(found->second, output);
    }
    if (const auto found = object->find("contents"); found != object->end()) {
        appendHoverText(found->second, output);
    }
}

std::optional<std::string> decompiledText(const JsonValue& value) {
    if (const auto* text = value.asString(); text != nullptr && !text->empty()) {
        return *text;
    }
    if (const auto* object = value.asObject()) {
        const auto found = object->find("content");
        if (found != object->end() && found->second.asString() != nullptr) {
            return *found->second.asString();
        }
    }
    return std::nullopt;
}

JsonValue locationAt(const std::string& uri,
                     std::uint64_t line,
                     std::uint64_t character) {
    JsonValue::Object start{{"line", line}, {"character", character}};
    JsonValue::Object end{{"line", line}, {"character", character}};
    JsonValue::Object range{
        {"start", JsonValue(std::move(start))},
        {"end", JsonValue(std::move(end))},
    };
    return JsonValue(JsonValue::Object{
        {"uri", uri},
        {"range", JsonValue(std::move(range))},
    });
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](char character) {
        return static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    });
    return value;
}

std::string jdkModuleForQualifiedName(std::string_view qualifiedName) {
    // The fallback command returns a qualified name rather than the original
    // jdt:// URI.  These package-to-module mappings cover the standard JDK
    // modules whose sources are not stored under java.base in src.zip.
    static constexpr std::array<std::pair<std::string_view, std::string_view>, 29> mappings{{
        {"java.awt.", "java.desktop"},
        {"java.applet.", "java.desktop"},
        {"java.beans.", "java.desktop"},
        {"java.sound.", "java.desktop"},
        {"javax.accessibility.", "java.desktop"},
        {"javax.imageio.", "java.desktop"},
        {"javax.print.", "java.desktop"},
        {"javax.swing.", "java.desktop"},
        {"java.util.logging.", "java.logging"},
        {"java.lang.instrument.", "java.instrument"},
        {"java.lang.management.", "java.management"},
        {"javax.management.", "java.management"},
        {"javax.naming.", "java.naming"},
        {"java.net.http.", "java.net.http"},
        {"java.rmi.", "java.rmi"},
        {"javax.rmi.", "java.rmi"},
        {"java.scripting.", "java.scripting"},
        {"javax.script.", "java.scripting"},
        {"java.sql.", "java.sql"},
        {"javax.sql.", "java.sql"},
        {"javax.transaction.xa.", "java.transaction"},
        {"javax.security.auth.kerberos.", "java.security.jgss"},
        {"org.ietf.jgss.", "java.security.jgss"},
        {"javax.tools.", "jdk.compiler"},
        {"com.sun.source.", "jdk.compiler"},
        {"com.sun.javadoc.", "jdk.javadoc"},
        {"jdk.javadoc.", "jdk.javadoc"},
        {"jdk.jshell.", "jdk.jshell"},
        {"sun.", "jdk.unsupported"},
    }};
    for (const auto& [prefix, module] : mappings) {
        if (qualifiedName.starts_with(prefix)) return std::string(module);
    }
    return "java.base";
}

std::string hexHash(const std::string& value) {
    std::uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char character : value) {
        hash ^= character;
        hash *= 1099511628211ULL;
    }
    std::ostringstream stream;
    stream << std::hex << std::setfill('0') << std::setw(16) << hash;
    return stream.str();
}

JsonValue changeMessage(const std::string& uri,
                        std::int64_t version,
                        const std::string& text) {
    JsonValue::Object document{{"uri", uri}, {"version", version}};
    JsonValue::Array changes;
    changes.emplace_back(JsonValue(JsonValue::Object{{"text", text}}));
    return JsonValue(JsonValue::Object{
        {"jsonrpc", "2.0"},
        {"method", "textDocument/didChange"},
        {"params", JsonValue(JsonValue::Object{
            {"textDocument", JsonValue(std::move(document))},
            {"contentChanges", JsonValue(std::move(changes))}})}});
}

} // namespace

std::vector<std::string> LspFrameDecoder::feed(std::string_view bytes) {
    std::vector<std::string> result;
    if (!error_.empty()) return result;
    buffer_.append(bytes);
    for (;;) {
        const auto headerEnd = buffer_.find("\r\n\r\n");
        if (headerEnd == std::string::npos) return result;
        const auto length = contentLength();
        if (!length) {
            error_ = "LSP frame has no valid Content-Length header";
            buffer_.erase(0, headerEnd + 4);
            return result;
        }
        const auto bodyStart = headerEnd + 4;
        if (*length > buffer_.size() - bodyStart) return result;
        result.emplace_back(buffer_.substr(bodyStart, *length));
        buffer_.erase(0, bodyStart + *length);
    }
}

std::optional<std::string> LspFrameDecoder::finish() {
    if (buffer_.empty()) return std::nullopt;
    return std::exchange(buffer_, std::string{});
}

const std::string& LspFrameDecoder::error() const {
    return error_;
}

std::optional<std::size_t> LspFrameDecoder::contentLength() const {
    const auto headerEnd = buffer_.find("\r\n\r\n");
    if (headerEnd == std::string::npos) return std::nullopt;
    const auto header = std::string_view(buffer_).substr(0, headerEnd);
    std::size_t lineStart = 0;
    while (lineStart <= header.size()) {
        const auto lineEnd = header.find("\r\n", lineStart);
        const auto line = header.substr(lineStart,
            lineEnd == std::string_view::npos ? header.size() - lineStart : lineEnd - lineStart);
        const auto colon = line.find(':');
        if (colon != std::string_view::npos) {
            auto name = std::string(line.substr(0, colon));
            std::transform(name.begin(), name.end(), name.begin(), [](char character) {
                return static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
            });
            if (name == "content-length") {
                const auto text = std::string(line.substr(colon + 1));
                try {
                    std::size_t consumed = 0;
                    const auto parsed = std::stoull(text, &consumed);
                    while (consumed < text.size() &&
                           std::isspace(static_cast<unsigned char>(text[consumed]))) ++consumed;
                    if (consumed == text.size()) return static_cast<std::size_t>(parsed);
                } catch (...) {
                    return std::nullopt;
                }
                return std::nullopt;
            }
        }
        if (lineEnd == std::string_view::npos) break;
        lineStart = lineEnd + 2;
    }
    return std::nullopt;
}

std::string frameLspMessage(std::string_view body) {
    return "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" +
           std::string(body);
}

JavaLanguageServerClient::JavaLanguageServerClient(ProjectRuntimeService& runtime,
                                                   FileStorage& storage,
                                                   ProcessSession& process,
                                                   ArchiveEntryReader* archiveReader)
    : runtime_(runtime), storage_(storage), process_(process), archiveReader_(archiveReader) {
    process_.setOutputHandler([this](const std::string& bytes) { receive(bytes); });
    process_.setErrorHandler([](const std::string&) {});
    process_.setLifecycleHandler([this](const ProcessLifecycleEvent& event) {
        if (event.state == ProcessLifecycleState::Running) {
            std::filesystem::path root;
            bool initializeNow = false;
            {
                std::lock_guard lock(mutex_);
                if (starting_ && !initializationSent_) {
                    initializationSent_ = true;
                    root = pendingRoot_;
                    initializeNow = true;
                }
            }
            if (initializeNow) initialize(root);
        } else if (event.state == ProcessLifecycleState::Failed ||
                   event.state == ProcessLifecycleState::Finished) {
            finishReady(false, event.message.empty() ?
                "Java language server exited" : event.message);
        }
    });
    startChangeWorker();
}

JavaLanguageServerClient::~JavaLanguageServerClient() {
    stop();
    {
        std::lock_guard lock(mutex_);
        stopChangeWorker_ = true;
    }
    changeCondition_.notify_all();
    if (changeWorker_.joinable()) changeWorker_.join();
}

bool JavaLanguageServerClient::start(const std::filesystem::path& root, std::string& error) {
    stop();
    const auto normalizedRoot = root.lexically_normal();
    const auto executable = runtime_.javaLanguageServerExecutable();
    if (!executable) {
        error = "Java language server executable was not found";
        finishReady(false, error);
        return false;
    }
    const auto cache = storage_.cacheDirectory();
    if (cache.empty()) {
        error = "Windows cache directory is unavailable";
        finishReady(false, error);
        return false;
    }
    const auto dataDirectory = pathFromText(cache) / "jdtls" /
                               dataDirectoryName(normalizedRoot);
    if (!storage_.createDirectory(pathText(dataDirectory), true, error)) {
        finishReady(false, error);
        return false;
    }
    ProcessRequest request;
    request.operationID = "windows-jdtls-" + dataDirectoryName(normalizedRoot);
    request.executablePath = *executable;
    if (const auto java = runtime_.javaExecutable({}, {})) {
        request.arguments = {"--java-executable", *java};
    }
    request.arguments.insert(request.arguments.end(), {
        "--jvm-arg=-Xms256m", "--jvm-arg=-Xmx1024m", "-data", pathText(dataDirectory)});
    request.workingDirectory = pathText(normalizedRoot);
    request.environment = runtime_.environment({}, RuntimeProcessKind::Java);
    request.keepsStandardInputOpen = true;
    {
        std::lock_guard lock(mutex_);
        rootURI_ = pathToURI(normalizedRoot);
        ready_ = false;
        starting_ = true;
        initializationSent_ = false;
        pendingRoot_ = normalizedRoot;
        decoder_ = {};
    }
    reportState(false, "Starting Java language server");
    process_.start(request);
    return true;
}

void JavaLanguageServerClient::stop() {
    process_.stop();
    std::map<std::uint64_t, ResponseHandler> pending;
    {
        std::lock_guard lock(mutex_);
        pending.swap(pendingRequests_);
        pendingChanges_.clear();
        ++changeGeneration_;
        documentVersions_.clear();
        ready_ = false;
        starting_ = false;
    }
    changeCondition_.notify_all();
    for (auto& [id, handler] : pending) {
        if (handler) handler(std::nullopt, LspRpcError{-32800, "Language server stopped", {}});
    }
    reportState(false, "Java language server stopped");
}

bool JavaLanguageServerClient::isReady() const {
    std::lock_guard lock(mutex_);
    return ready_;
}

bool JavaLanguageServerClient::isStarting() const {
    std::lock_guard lock(mutex_);
    return starting_;
}

void JavaLanguageServerClient::setStateHandler(StateHandler handler) {
    std::lock_guard lock(mutex_);
    stateHandler_ = std::move(handler);
}

void JavaLanguageServerClient::setDiagnosticsHandler(DiagnosticsHandler handler) {
    std::lock_guard lock(mutex_);
    diagnosticsHandler_ = std::move(handler);
}

void JavaLanguageServerClient::request(const std::string& method,
                                       JsonValue params,
                                       ResponseHandler handler) {
    std::uint64_t id = 0;
    {
        std::lock_guard lock(mutex_);
        id = nextRequestID_++;
        pendingRequests_[id] = std::move(handler);
    }
    JsonValue::Object message;
    message.emplace("jsonrpc", "2.0");
    message.emplace("id", id);
    message.emplace("method", method);
    message.emplace("params", std::move(params));
    send(JsonValue(std::move(message)));
}

void JavaLanguageServerClient::requestJavaNavigation(
    const std::string& method,
    JsonValue params,
    std::string documentText,
    std::uint64_t line,
    std::uint64_t utf16Column,
    ResponseHandler handler) {
    const auto originalParams = params;
    request(method, std::move(params),
        [this, method, originalParams, documentText = std::move(documentText), line,
         utf16Column, handler = std::move(handler)](
            std::optional<JsonValue> result,
            std::optional<LspRpcError> error) mutable {
            if (error) {
                if (handler) handler(std::nullopt, std::move(error));
                return;
            }
            resolveNavigationResult(
                method, originalParams, documentText, line, utf16Column,
                result ? std::move(*result) : JsonValue(nullptr), std::move(handler));
        });
}

void JavaLanguageServerClient::notify(const std::string& method, JsonValue params) {
    JsonValue::Object message;
    message.emplace("jsonrpc", "2.0");
    message.emplace("method", method);
    message.emplace("params", std::move(params));
    send(JsonValue(std::move(message)));
}

void JavaLanguageServerClient::didOpen(const std::string& uri,
                                       const std::string& languageID,
                                       std::int64_t version,
                                       const std::string& text) {
    {
        std::lock_guard lock(mutex_);
        documentVersions_[uri] = version;
    }
    notify("textDocument/didOpen", JsonValue(JsonValue::Object{
        {"textDocument", JsonValue(JsonValue::Object{
            {"uri", uri}, {"languageId", languageID}, {"version", version}, {"text", text}})}}));
}

void JavaLanguageServerClient::didChange(const std::string& uri, const std::string& text) {
    {
        std::lock_guard lock(mutex_);
        const auto version = ++documentVersions_[uri];
        pendingChanges_[uri] = {version, text};
        ++changeGeneration_;
    }
    changeCondition_.notify_all();
}

void JavaLanguageServerClient::didClose(const std::string& uri) {
    {
        std::lock_guard lock(mutex_);
        documentVersions_.erase(uri);
        pendingChanges_.erase(uri);
    }
    notify("textDocument/didClose", JsonValue(JsonValue::Object{
        {"textDocument", JsonValue(JsonValue::Object{{"uri", uri}})}}));
}

void JavaLanguageServerClient::flushChanges() {
    std::map<std::string, PendingChange> changes;
    {
        std::lock_guard lock(mutex_);
        changes.swap(pendingChanges_);
        ++changeGeneration_;
    }
    for (const auto& [uri, change] : changes) {
        process_.send(frameLspMessage(serializeJson(changeMessage(
            uri, change.version, change.text))));
    }
}

void JavaLanguageServerClient::startChangeWorker() {
    changeWorker_ = std::thread([this] { changeLoop(); });
}

void JavaLanguageServerClient::changeLoop() {
    std::unique_lock lock(mutex_);
    while (!stopChangeWorker_) {
        changeCondition_.wait(lock, [this] {
            return stopChangeWorker_ || !pendingChanges_.empty();
        });
        if (stopChangeWorker_) break;
        const auto generation = changeGeneration_;
        if (changeCondition_.wait_for(lock, std::chrono::milliseconds(300), [this, generation] {
                return stopChangeWorker_ || changeGeneration_ != generation;
            })) continue;
        std::map<std::string, PendingChange> changes;
        changes.swap(pendingChanges_);
        lock.unlock();
        for (const auto& [uri, change] : changes) {
            process_.send(frameLspMessage(serializeJson(changeMessage(
                uri, change.version, change.text))));
        }
        lock.lock();
    }
}

void JavaLanguageServerClient::receive(const std::string& bytes) {
    const auto frames = decoder_.feed(bytes);
    for (const auto& frame : frames) {
        const auto parsed = parseJson(frame);
        if (parsed.value) handle(*parsed.value);
    }
    if (!decoder_.error().empty()) finishReady(false, decoder_.error());
}

void JavaLanguageServerClient::handle(const JsonValue& message) {
    if (!message.isObject()) return;
    const auto id = messageID(message);
    const auto* methodValue = value(message, "method");
    if (id && methodValue == nullptr) {
        ResponseHandler handler;
        {
            std::lock_guard lock(mutex_);
            const auto found = pendingRequests_.find(*id);
            if (found == pendingRequests_.end()) return;
            handler = std::move(found->second);
            pendingRequests_.erase(found);
        }
        const auto* error = value(message, "error");
        if (error && error->isObject()) {
            const auto* code = value(*error, "code");
            const auto* text = value(*error, "message");
            handler(std::nullopt, LspRpcError{
                code && code->asInt() ? *code->asInt() : 0,
                text && text->asString() ? *text->asString() : "LSP request failed", {}});
        } else {
            const auto* result = value(message, "result");
            handler(result ? std::optional<JsonValue>(*result) : std::optional<JsonValue>(nullptr),
                    std::nullopt);
        }
        return;
    }
    if (!methodValue || !methodValue->asString()) return;
    const auto method = *methodValue->asString();
    if (id) {
        handleServerRequest(*id, method, value(message, "params") ?
            *value(message, "params") : JsonValue(JsonValue::Object{}));
        return;
    }
    if (method == "textDocument/publishDiagnostics") {
        const auto* params = value(message, "params");
        if (!params || !params->isObject()) return;
        const auto* uri = value(*params, "uri");
        const auto* diagnostics = value(*params, "diagnostics");
        DiagnosticsHandler handler;
        {
            std::lock_guard lock(mutex_);
            handler = diagnosticsHandler_;
        }
        if (handler && uri && uri->asString() && diagnostics) handler(*uri->asString(), *diagnostics);
    }
}

void JavaLanguageServerClient::send(JsonValue message) {
    const auto body = serializeJson(message);
    process_.send(frameLspMessage(body));
}

void JavaLanguageServerClient::sendResponse(std::uint64_t id, JsonValue result) {
    JsonValue::Object response{
        {"jsonrpc", "2.0"}, {"id", id}, {"result", std::move(result)}};
    send(JsonValue(std::move(response)));
}

void JavaLanguageServerClient::initialize(const std::filesystem::path& root) {
    const auto rootURI = pathToURI(root);
    JsonValue::Object definition{{"dynamicRegistration", false}, {"linkSupport", true}};
    JsonValue::Object references{{"dynamicRegistration", false}};
    JsonValue::Object implementation{{"dynamicRegistration", false}, {"linkSupport", true}};
    JsonValue::Object hover{{"dynamicRegistration", false}, {"contentFormat", JsonValue(JsonValue::Array{"markdown", "plaintext"})}};
    JsonValue::Object inlayHint{{"dynamicRegistration", false}};
    JsonValue::Object diagnostics{{"relatedInformation", true}};
    JsonValue::Object textDocument{
        {"definition", JsonValue(std::move(definition))},
        {"references", JsonValue(std::move(references))},
        {"implementation", JsonValue(std::move(implementation))},
        {"hover", JsonValue(std::move(hover))},
        {"inlayHint", JsonValue(std::move(inlayHint))},
        {"publishDiagnostics", JsonValue(std::move(diagnostics))}};
    JsonValue::Object workspace{{"workspaceFolders", true}, {"configuration", true},
                                {"symbol", JsonValue(JsonValue::Object{{"dynamicRegistration", false}})}};
    JsonValue::Object capabilities{
        {"textDocument", JsonValue(std::move(textDocument))},
        {"workspace", JsonValue(std::move(workspace))}};
    JsonValue::Object clientInfo{{"name", "Lithe"}, {"version", "0.1.0"}};
    JsonValue::Object folder{{"uri", rootURI}, {"name", pathText(root.filename())}};
    JsonValue::Array folders;
    folders.emplace_back(JsonValue(std::move(folder)));
    JsonValue::Object parameters{
        {"processId", nullptr},
        {"clientInfo", JsonValue(std::move(clientInfo))},
        {"rootUri", rootURI},
        {"capabilities", JsonValue(std::move(capabilities))},
        {"workspaceFolders", JsonValue(std::move(folders))}};
    request("initialize", JsonValue(std::move(parameters)),
        [this](std::optional<JsonValue>, std::optional<LspRpcError> error) {
            if (error) {
                finishReady(false, error->message);
                return;
            }
            notify("initialized", JsonValue(JsonValue::Object{}));
            JsonValue::Object parameterNames{{"enabled", "all"}};
            JsonValue::Object inlayHints{
                {"parameterNames", JsonValue(std::move(parameterNames))}};
            JsonValue::Object java{{"inlayHints", JsonValue(std::move(inlayHints))}};
            JsonValue::Object settings{{"java", JsonValue(std::move(java))}};
            notify("workspace/didChangeConfiguration", JsonValue(JsonValue::Object{
                {"settings", JsonValue(std::move(settings))}}));
            finishReady(true, "Java language server ready");
        });
}

void JavaLanguageServerClient::finishReady(bool success, std::string message) {
    {
        std::lock_guard lock(mutex_);
        ready_ = success;
        starting_ = false;
    }
    reportState(success, message);
}

void JavaLanguageServerClient::reportState(bool ready, const std::string& message) {
    StateHandler handler;
    {
        std::lock_guard lock(mutex_);
        handler = stateHandler_;
    }
    if (handler) handler(ready, message);
}

std::vector<JsonValue> JavaLanguageServerClient::navigationLocations(
    const JsonValue& result) {
    if (const auto* array = result.asArray()) return *array;
    if (const auto* object = result.asObject()) {
        if (object->contains("uri") || object->contains("targetUri")) return {result};
    }
    return {};
}

void JavaLanguageServerClient::resolveNavigationResult(
    const std::string& method,
    const JsonValue& params,
    const std::string& documentText,
    std::uint64_t line,
    std::uint64_t utf16Column,
    JsonValue result,
    ResponseHandler handler) {
    if (method == "textDocument/definition" && navigationLocations(result).empty()) {
        resolveMissingDefinition(params, documentText, line, utf16Column, std::move(handler));
        return;
    }
    resolveExternalLocations(std::move(result), std::move(handler));
}

void JavaLanguageServerClient::resolveExternalLocations(JsonValue result,
                                                         ResponseHandler handler) {
    auto locations = navigationLocations(result);
    auto resolved = std::make_shared<JsonValue::Array>();
    auto next = std::make_shared<std::function<void(std::size_t)>>();
    *next = [this, locations = std::move(locations), resolved,
             handler = std::move(handler), next](std::size_t index) mutable {
        if (index >= locations.size()) {
            if (handler) handler(JsonValue(std::move(*resolved)), std::nullopt);
            return;
        }

        const auto location = locations[index];
        const auto* uriValue = objectValue(location, "uri");
        if (uriValue == nullptr) uriValue = objectValue(location, "targetUri");
        if (uriValue == nullptr || uriValue->asString() == nullptr) {
            resolved->push_back(location);
            (*next)(index + 1);
            return;
        }
        const auto uri = *uriValue->asString();
        const auto schemeEnd = uri.find("://");
        const auto scheme = lower(schemeEnd == std::string::npos
                                       ? std::string{}
                                       : uri.substr(0, schemeEnd));
        if (scheme.empty() || scheme == "file") {
            resolved->push_back(location);
            (*next)(index + 1);
            return;
        }

        if (const auto source = jdkSourceForURI(uri)) {
            if (const auto materialized = materializeLibrarySource(*source, uri)) {
                auto normalized = location.asObject() == nullptr
                    ? JsonValue::Object{}
                    : *location.asObject();
                normalized["uri"] = pathToURI(pathFromText(*materialized));
                resolved->emplace_back(JsonValue(std::move(normalized)));
                (*next)(index + 1);
                return;
            }
        }

        executeCommand("java.decompile", JsonValue::Array{JsonValue(uri)},
            [this, location, uri, index, resolved, next](
                std::optional<JsonValue> decompiled,
                std::optional<LspRpcError> error) mutable {
                if (!error && decompiled) {
                    if (const auto content = decompiledText(*decompiled)) {
                        if (const auto materialized = materializeLibrarySource(*content, uri)) {
                            auto normalized = location.asObject() == nullptr
                                ? JsonValue::Object{}
                                : *location.asObject();
                            normalized["uri"] = pathToURI(pathFromText(*materialized));
                            resolved->emplace_back(JsonValue(std::move(normalized)));
                            (*next)(index + 1);
                            return;
                        }
                    }
                }
                // Keep the original external location when neither source.zip
                // nor the JDT decompiler is available. This preserves a useful
                // result for clients that know how to open the URI themselves.
                resolved->push_back(location);
                (*next)(index + 1);
            });
    };
    (*next)(0);
}

void JavaLanguageServerClient::resolveMissingDefinition(
    const JsonValue& params,
    const std::string& documentText,
    std::uint64_t line,
    std::uint64_t utf16Column,
    ResponseHandler handler) {
    const auto symbol = symbolAt(documentText, line, utf16Column).value_or(std::string{});
    auto finish = [this, symbol, documentText, line, utf16Column,
                   handler = std::move(handler)](std::string qualifiedName) mutable {
        if (qualifiedName.empty() || symbol.empty()) {
            if (handler) handler(JsonValue(JsonValue::Array{}), std::nullopt);
            return;
        }
        if (const auto location = jdkDefinitionLocation(
                qualifiedName, symbol, documentText, line, utf16Column)) {
            if (handler) handler(JsonValue(JsonValue::Array{*location}), std::nullopt);
            return;
        }

        const auto sourceURI = jdkURIForQualifiedName(qualifiedName);
        if (!sourceURI) {
            if (handler) handler(JsonValue(JsonValue::Array{}), std::nullopt);
            return;
        }
        executeCommand("java.decompile", JsonValue::Array{JsonValue(*sourceURI)},
            [this, sourceURI = *sourceURI, symbol, handler = std::move(handler)](
                std::optional<JsonValue> decompiled,
                std::optional<LspRpcError> error) mutable {
                if (!error && decompiled) {
                    if (const auto content = decompiledText(*decompiled)) {
                        if (const auto materialized = materializeLibrarySource(*content, sourceURI)) {
                            const auto position = sourcePosition(*content, symbol)
                                .value_or(std::pair<std::uint64_t, std::uint64_t>{0, 0});
                            if (handler) handler(JsonValue(JsonValue::Array{
                                locationAt(pathToURI(pathFromText(*materialized)),
                                            position.first, position.second)}), std::nullopt);
                            return;
                        }
                    }
                }
                if (handler) handler(JsonValue(JsonValue::Array{}), std::nullopt);
            });
    };

    executeCommand("java.getFullyQualifiedName", JsonValue::Array{params},
        [this, params, symbol, finish = std::move(finish)](
            std::optional<JsonValue> qualified,
            std::optional<LspRpcError> error) mutable {
            if (!error && qualified && qualified->asString() != nullptr &&
                !qualified->asString()->empty()) {
                finish(*qualified->asString());
                return;
            }
            request("textDocument/hover", params,
                [this, symbol, finish = std::move(finish)](
                    std::optional<JsonValue> hover,
                    std::optional<LspRpcError> hoverError) mutable {
                    if (hoverError || !hover) {
                        finish({});
                        return;
                    }
                    finish(qualifiedNameFromHover(*hover, symbol).value_or(std::string{}));
                });
        });
}

void JavaLanguageServerClient::executeCommand(const std::string& command,
                                              JsonValue::Array arguments,
                                              ResponseHandler handler) {
    request("workspace/executeCommand", JsonValue(JsonValue::Object{
        {"command", command}, {"arguments", JsonValue(std::move(arguments))}}),
        std::move(handler));
}

void JavaLanguageServerClient::handleServerRequest(std::uint64_t id,
                                                   const std::string& method,
                                                   const JsonValue& params) {
    if (method != "workspace/configuration") {
        sendResponse(id, JsonValue(nullptr));
        return;
    }
    JsonValue::Array result;
    const auto* items = value(params, "items");
    if (items && items->asArray()) {
        for (const auto& item : *items->asArray()) {
            const auto* section = value(item, "section");
            const auto sectionName = section && section->asString()
                ? *section->asString() : std::string{};
            if (sectionName == "java") {
                result.emplace_back(JsonValue(JsonValue::Object{
                    {"inlayHints", JsonValue(JsonValue::Object{
                        {"parameterNames", JsonValue(JsonValue::Object{{"enabled", "all"}})}})}}));
            } else if (sectionName == "java.inlayHints") {
                result.emplace_back(JsonValue(JsonValue::Object{
                    {"parameterNames", JsonValue(JsonValue::Object{{"enabled", "all"}})}}));
            } else if (sectionName == "java.inlayHints.parameterNames") {
                result.emplace_back(JsonValue(JsonValue::Object{{"enabled", "all"}}));
            } else if (sectionName == "java.inlayHints.parameterNames.enabled") {
                result.emplace_back("all");
            } else {
                result.emplace_back(nullptr);
            }
        }
    }
    sendResponse(id, JsonValue(std::move(result)));
}

std::optional<std::string> JavaLanguageServerClient::jdkSourceForURI(
    const std::string& uri) const {
    const auto schemeEnd = uri.find("://");
    if (schemeEnd == std::string::npos || lower(uri.substr(0, schemeEnd)) != "jdt") {
        return std::nullopt;
    }
    auto entry = uriPath(uri);
    if (entry.empty()) return std::nullopt;
    std::replace(entry.begin(), entry.end(), '\\', '/');
    const auto classEnd = entry.rfind(".class");
    if (classEnd == std::string::npos || classEnd + 6 != entry.size()) return std::nullopt;
    entry.replace(classEnd, 6, ".java");

    const auto java = runtime_.javaExecutable({}, {});
    if (!java || archiveReader_ == nullptr) return std::nullopt;
    const auto javaHome = pathFromText(*java).parent_path().parent_path();
    const auto archiveCandidates = {
        javaHome / "lib" / "src.zip",
        javaHome / "src.zip",
    };
    std::vector<std::string> entries;
    const auto addEntry = [&entries](const std::string& candidate) {
        entries.push_back(candidate);
        const auto slash = candidate.rfind('/');
        const auto classNameStart = slash == std::string::npos ? 0 : slash + 1;
        const auto dollar = candidate.find('$', classNameStart);
        if (dollar != std::string::npos) {
            // Nested classes are compiled as Outer$Inner.class, while the
            // JDK source archive contains the enclosing Outer.java file.
            entries.push_back(candidate.substr(0, dollar) + ".java");
        }
    };
    addEntry(entry);
    const auto separator = entry.find('/');
    if (separator != std::string::npos) {
        const auto module = entry.substr(0, separator);
        const auto withoutModule = entry.substr(separator + 1);
        addEntry(withoutModule);
        if (module != "java.base") addEntry("java.base/" + withoutModule);
    } else {
        addEntry("java.base/" + entry);
    }

    for (const auto& archive : archiveCandidates) {
        const auto archivePath = pathText(archive);
        if (!storage_.fileExists(archivePath)) continue;
        for (const auto& candidate : entries) {
            if (const auto source = archiveReader_->read(archivePath, candidate);
                source && !source->empty()) {
                return source;
            }
        }
    }
    return std::nullopt;
}

std::optional<std::string> JavaLanguageServerClient::materializeLibrarySource(
    const std::string& content,
    const std::string& uri) const {
    if (content.empty()) return std::nullopt;
    const auto cache = storage_.cacheDirectory();
    if (cache.empty()) return std::nullopt;
    const auto sourcePath = uriPath(uri);
    const auto sourceFile = pathFromText(sourcePath).filename().u8string();
    const std::string sourceFileText(
        reinterpret_cast<const char*>(sourceFile.data()), sourceFile.size());
    auto baseName = sourcePath.empty() || sourceFileText.empty()
        ? std::string("JavaLibrary") : sourceFileText;
    if (baseName.ends_with(".class")) baseName.erase(baseName.size() - 6);
    for (auto& character : baseName) {
        const auto safe = (character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') || character == '_' ||
            character == '$' || character == '-';
        if (!safe) character = '_';
    }
    if (baseName.empty()) baseName = "JavaLibrary";
    const auto destinationDirectory = pathFromText(cache) / "java-sources";
    std::string error;
    if (!storage_.createDirectory(pathText(destinationDirectory), true, error)) {
        return std::nullopt;
    }
    const auto destination = destinationDirectory /
        (baseName + "-" + hexHash(uri) + ".java");
    const auto bytes = std::vector<std::uint8_t>(content.begin(), content.end());
    if (!storage_.writeData(pathText(destination), bytes, error)) return std::nullopt;
    return pathText(destination);
}

std::optional<std::string> JavaLanguageServerClient::jdkURIForQualifiedName(
    const std::string& qualifiedName) {
    const auto partsEnd = qualifiedName.find_first_of("?#");
    const auto value = qualifiedName.substr(0, partsEnd);
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (start < value.size()) {
        const auto end = value.find('.', start);
        const auto componentEnd = end == std::string::npos ? value.size() : end;
        if (componentEnd > start) parts.emplace_back(value.substr(start, componentEnd - start));
        if (end == std::string::npos) break;
        start = end + 1;
    }
    if (parts.size() < 2 ||
        (parts.front() != "java" && parts.front() != "javax" &&
         parts.front() != "jdk" && parts.front() != "sun")) {
        return std::nullopt;
    }
    std::size_t typeIndex = std::string::npos;
    for (std::size_t index = 1; index < parts.size(); ++index) {
        if (!parts[index].empty() &&
            ((parts[index][0] >= 'A' && parts[index][0] <= 'Z') ||
             parts[index].find('$') != std::string::npos)) {
            typeIndex = index;
            break;
        }
    }
    if (typeIndex == std::string::npos) return std::nullopt;
    std::string sourcePath;
    for (std::size_t index = 0; index <= typeIndex; ++index) {
        if (!sourcePath.empty()) sourcePath.push_back('/');
        sourcePath += parts[index];
    }
    sourcePath += ".class";
    return "jdt://contents/" + jdkModuleForQualifiedName(value) + "/" + sourcePath;
}

std::optional<JsonValue> JavaLanguageServerClient::jdkDefinitionLocation(
    const std::string& qualifiedName,
    const std::string& symbol,
    const std::string& documentText,
    std::uint64_t line,
    std::uint64_t utf16Column) const {
    const auto sourceURI = jdkURIForQualifiedName(qualifiedName);
    if (!sourceURI) return std::nullopt;
    const auto source = jdkSourceForURI(*sourceURI);
    if (!source) return std::nullopt;
    const auto materialized = materializeLibrarySource(*source, *sourceURI);
    if (!materialized) return std::nullopt;

    auto target = symbol;
    if (target.empty()) target = symbolAt(documentText, line, utf16Column).value_or(std::string{});
    const auto position = sourcePosition(*source, target)
        .value_or(std::pair<std::uint64_t, std::uint64_t>{0, 0});
    return locationAt(pathToURI(pathFromText(*materialized)), position.first, position.second);
}

std::optional<std::string> JavaLanguageServerClient::qualifiedNameFromHover(
    const JsonValue& hover,
    const std::string& symbol) {
    std::string text;
    appendHoverText(hover, text);
    if (text.empty()) return std::nullopt;
    const std::array<std::string_view, 4> prefixes{"java.", "javax.", "jdk.", "sun."};
    std::vector<std::string> matches;
    for (std::size_t index = 0; index < text.size();) {
        std::optional<std::string_view> prefix;
        for (const auto candidate : prefixes) {
            if (text.compare(index, candidate.size(), candidate) == 0) {
                prefix = candidate;
                break;
            }
        }
        if (!prefix) {
            ++index;
            continue;
        }
        auto end = index + prefix->size();
        while (end < text.size()) {
            const auto character = static_cast<unsigned char>(text[end]);
            if (!((character >= 'A' && character <= 'Z') ||
                  (character >= 'a' && character <= 'z') ||
                  (character >= '0' && character <= '9') || character == '_' ||
                  character == '$' || character == '.')) break;
            ++end;
        }
        while (end > index && text[end - 1] == '.') --end;
        const auto candidate = text.substr(index, end - index);
        if (candidate.find('.') != std::string::npos) matches.push_back(candidate);
        index = std::max(end, index + 1);
    }
    if (matches.empty()) return std::nullopt;
    if (!symbol.empty()) {
        for (auto iterator = matches.rbegin(); iterator != matches.rend(); ++iterator) {
            const auto dot = iterator->rfind('.');
            if (dot != std::string::npos && iterator->substr(dot + 1) == symbol) {
                return *iterator;
            }
        }
    }
    return matches.front();
}

std::optional<std::string> JavaLanguageServerClient::symbolAt(
    const std::string& text,
    std::uint64_t requestedLine,
    std::uint64_t requestedColumn) {
    std::size_t lineStart = 0;
    std::uint64_t line = 0;
    for (; line < requestedLine && lineStart < text.size(); ++line) {
        const auto newline = text.find('\n', lineStart);
        if (newline == std::string::npos) return std::nullopt;
        lineStart = newline + 1;
    }
    if (line != requestedLine) return std::nullopt;
    const auto newline = text.find('\n', lineStart);
    const auto lineEnd = newline == std::string::npos ? text.size() : newline;
    const auto lineText = std::string_view(text).substr(lineStart, lineEnd - lineStart);
    struct Unit {
        std::size_t start = 0;
        std::size_t end = 0;
        std::uint64_t utf16Start = 0;
        std::uint64_t utf16End = 0;
        bool identifier = false;
    };
    std::vector<Unit> units;
    std::uint64_t utf16 = 0;
    for (std::size_t index = 0; index < lineText.size();) {
        const auto start = index;
        const auto codePoint = decodeUtf8(lineText, index);
        const auto width = utf16Units(codePoint);
        units.push_back({start, index, utf16, utf16 + width,
                         isJavaIdentifierCodePoint(codePoint)});
        utf16 += width;
    }
    if (units.empty()) return std::nullopt;
    std::size_t selected = units.size() - 1;
    for (std::size_t index = 0; index < units.size(); ++index) {
        if (requestedColumn >= units[index].utf16Start &&
            requestedColumn < units[index].utf16End) {
            selected = index;
            break;
        }
        if (requestedColumn < units[index].utf16Start) {
            selected = index == 0 ? 0 : index - 1;
            break;
        }
    }
    if (!units[selected].identifier && selected > 0 && units[selected - 1].identifier) {
        --selected;
    }
    if (!units[selected].identifier) return std::nullopt;
    auto first = selected;
    auto last = selected;
    while (first > 0 && units[first - 1].identifier) --first;
    while (last + 1 < units.size() && units[last + 1].identifier) ++last;
    return std::string(lineText.substr(units[first].start,
                                       units[last].end - units[first].start));
}

std::optional<std::pair<std::uint64_t, std::uint64_t>> JavaLanguageServerClient::sourcePosition(
    const std::string& source,
    const std::string& symbol) {
    if (symbol.empty()) return std::nullopt;
    std::uint64_t line = 0;
    std::size_t start = 0;
    while (start <= source.size()) {
        const auto end = source.find('\n', start);
        const auto lineEnd = end == std::string::npos ? source.size() : end;
        const auto value = std::string_view(source).substr(start, lineEnd - start);
        std::size_t position = value.find(symbol);
        while (position != std::string_view::npos) {
            const auto before = position == 0 ? '\0' : value[position - 1];
            const auto after = position + symbol.size() >= value.size()
                ? '\0' : value[position + symbol.size()];
            const auto identifier = [](char character) {
                return (character >= 'A' && character <= 'Z') ||
                    (character >= 'a' && character <= 'z') ||
                    (character >= '0' && character <= '9') || character == '_' ||
                    character == '$';
            };
            if (!identifier(before) && !identifier(after)) {
                return std::pair<std::uint64_t, std::uint64_t>{
                    line, utf16Length(value.substr(0, position))};
            }
            const auto next = position + 1;
            const auto found = value.find(symbol, next);
            position = found;
        }
        if (end == std::string::npos) break;
        start = end + 1;
        ++line;
    }
    return std::nullopt;
}

std::string JavaLanguageServerClient::pathToURI(const std::filesystem::path& path) {
    auto text = replaceAll(pathText(path.lexically_normal()), '\\', '/');
    std::string uri;
    if (text.size() >= 2 && text[1] == ':') uri = "file:///" + text;
    else if (!text.empty() && text.front() == '/') uri = "file://" + text;
    else uri = "file:///" + text;
    std::string encoded;
    constexpr char hex[] = "0123456789ABCDEF";
    for (std::size_t index = 0; index < uri.size(); ++index) {
        const auto character = static_cast<unsigned char>(uri[index]);
        const auto unreserved = (character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') || character == '-' ||
            character == '_' || character == '.' || character == '~' ||
            character == '/' || character == ':';
        if (unreserved) {
            encoded.push_back(static_cast<char>(character));
        } else {
            encoded.push_back('%');
            encoded.push_back(hex[(character >> 4) & 0x0f]);
            encoded.push_back(hex[character & 0x0f]);
        }
    }
    return encoded;
}

std::string JavaLanguageServerClient::dataDirectoryName(const std::filesystem::path& root) {
    return hexHash(pathText(root));
}

} // namespace lithe::windows::app
