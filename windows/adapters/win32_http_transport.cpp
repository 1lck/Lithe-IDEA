#include "win32_http_transport.h"

#include <algorithm>
#include <limits>
#include <string>

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>
#endif

namespace lithe::windows {
namespace {

#ifdef _WIN32

std::string errorText(DWORD code = GetLastError()) {
    char* buffer = nullptr;
    const auto length = FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<LPSTR>(&buffer), 0, nullptr);
    std::string result = length > 0 && buffer != nullptr
        ? std::string(buffer, length)
        : "WinHTTP error " + std::to_string(code);
    if (buffer != nullptr) LocalFree(buffer);
    while (!result.empty() && (result.back() == '\r' || result.back() == '\n')) result.pop_back();
    return result;
}

std::optional<std::wstring> wide(std::string_view value) {
    const auto length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                            value.data(), static_cast<int>(value.size()),
                                            nullptr, 0);
    if (length <= 0) return std::nullopt;
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(), length) != length) {
        return std::nullopt;
    }
    return result;
}

class Handle final {
public:
    explicit Handle(HINTERNET value = nullptr) : value_(value) {}
    ~Handle() { if (value_ != nullptr) WinHttpCloseHandle(value_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    HINTERNET get() const { return value_; }
    explicit operator bool() const { return value_ != nullptr; }

private:
    HINTERNET value_ = nullptr;
};

#endif

} // namespace

std::optional<HTTPResponse> Win32HttpTransport::send(const HTTPRequest& request,
                                                     std::string& error) {
#ifndef _WIN32
    (void)request;
    error = "Win32 HTTP transport requires Windows";
    return std::nullopt;
#else
    const auto url = wide(request.url);
    if (!url || url->empty()) {
        error = "HTTP request URL is not valid UTF-8";
        return std::nullopt;
    }
    URL_COMPONENTS components{sizeof(URL_COMPONENTS)};
    components.dwSchemeLength = static_cast<DWORD>(-1);
    components.dwHostNameLength = static_cast<DWORD>(-1);
    components.dwUrlPathLength = static_cast<DWORD>(-1);
    components.dwExtraInfoLength = static_cast<DWORD>(-1);
    auto mutableURL = *url;
    if (!WinHttpCrackUrl(mutableURL.data(), static_cast<DWORD>(mutableURL.size()), 0,
                         &components)) {
        error = "Invalid HTTP URL: " + errorText();
        return std::nullopt;
    }
    const bool secure = components.nScheme == INTERNET_SCHEME_HTTPS;
    if (components.nScheme != INTERNET_SCHEME_HTTP && !secure) {
        error = "Only HTTP and HTTPS URLs are supported";
        return std::nullopt;
    }
    if (!secure && !request.allowsInsecureHTTP) {
        error = "HTTP is disabled for this request";
        return std::nullopt;
    }
    const std::wstring host(components.lpszHostName, components.dwHostNameLength);
    std::wstring path;
    if (components.lpszUrlPath != nullptr) {
        path.assign(components.lpszUrlPath, components.dwUrlPathLength);
    }
    if (path.empty()) path = L"/";
    if (components.lpszExtraInfo != nullptr) {
        path.append(components.lpszExtraInfo, components.dwExtraInfoLength);
    }
    if (host.empty()) {
        error = "HTTP URL has no host";
        return std::nullopt;
    }

    Handle session(WinHttpOpen(L"Lithe Windows/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                               WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!session) {
        error = "Could not open WinHTTP session: " + errorText();
        return std::nullopt;
    }
    const auto timeout = static_cast<DWORD>(std::min<std::uint64_t>(
        request.timeoutMilliseconds, std::numeric_limits<DWORD>::max()));
    WinHttpSetTimeouts(session.get(), timeout, timeout, timeout, timeout);
    Handle connection(WinHttpConnect(session.get(), host.c_str(), components.nPort, 0));
    if (!connection) {
        error = "Could not connect to HTTP host: " + errorText();
        return std::nullopt;
    }
    const auto flags = secure ? WINHTTP_FLAG_SECURE : 0;
    const auto method = wide(request.method.empty() ? "POST" : request.method);
    if (!method) {
        error = "HTTP method is not valid UTF-8";
        return std::nullopt;
    }
    Handle httpRequest(WinHttpOpenRequest(connection.get(), method->c_str(), path.c_str(), nullptr,
                                          WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                          flags));
    if (!httpRequest) {
        error = "Could not create HTTP request: " + errorText();
        return std::nullopt;
    }
    for (const auto& [key, value] : request.headers) {
        const auto header = wide(key + ": " + value + "\r\n");
        if (!header || !WinHttpAddRequestHeaders(httpRequest.get(), header->c_str(),
                                                   static_cast<DWORD>(-1),
                                                   WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE)) {
            error = "Could not add HTTP request header: " + errorText();
            return std::nullopt;
        }
    }
    if (request.body.size() > std::numeric_limits<DWORD>::max()) {
        error = "HTTP request body is too large";
        return std::nullopt;
    }
    auto* body = request.body.empty() ? WINHTTP_NO_REQUEST_DATA
                                      : const_cast<char*>(request.body.data());
    if (!WinHttpSendRequest(httpRequest.get(), WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            body, static_cast<DWORD>(request.body.size()),
                            static_cast<DWORD>(request.body.size()), 0) ||
        !WinHttpReceiveResponse(httpRequest.get(), nullptr)) {
        error = "HTTP request failed: " + errorText();
        return std::nullopt;
    }
    DWORD status = 0;
    DWORD statusSize = sizeof(status);
    if (!WinHttpQueryHeaders(httpRequest.get(),
                              WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                              WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusSize,
                              WINHTTP_NO_HEADER_INDEX)) {
        error = "Could not read HTTP response status: " + errorText();
        return std::nullopt;
    }
    HTTPResponse response;
    response.statusCode = static_cast<std::int32_t>(status);
    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(httpRequest.get(), &available)) {
            error = "Could not read HTTP response: " + errorText();
            return std::nullopt;
        }
        if (available == 0) break;
        std::string buffer(available, '\0');
        DWORD read = 0;
        if (!WinHttpReadData(httpRequest.get(), buffer.data(), available, &read)) {
            error = "Could not read HTTP response body: " + errorText();
            return std::nullopt;
        }
        response.body.append(buffer.data(), read);
    }
    return response;
#endif
}

} // namespace lithe::windows
