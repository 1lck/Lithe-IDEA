#include "win32_key_value_store.h"

#include "win32_file_system.h"

#include <charconv>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <limits>
#include <mutex>
#include <sstream>
#include <shared_mutex>
#include <string_view>
#include <system_error>
#include <type_traits>
#include <utility>

#ifdef _WIN32
#include <shlobj.h>
#include <windows.h>
#endif

namespace lithe::windows {
namespace {

std::shared_mutex storeMutex;

std::filesystem::path defaultRoot() {
#ifdef _WIN32
    PWSTR value = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT,
                                      nullptr, &value)) && value != nullptr) {
        std::filesystem::path root(value);
        CoTaskMemFree(value);
        return root / "Lithe" / "state";
    }
    if (value != nullptr) CoTaskMemFree(value);
#endif
    const auto* home = std::getenv("HOME");
    if (home != nullptr && *home != '\0') {
        return std::filesystem::path(home) / ".config" / "Lithe" / "state";
    }
    return std::filesystem::temp_directory_path() / "Lithe" / "state";
}

std::string hexKey(const std::string& key) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string result = "k";
    result.reserve(1 + key.size() * 2);
    for (const auto byte : key) {
        const auto value = static_cast<unsigned char>(byte);
        result.push_back(digits[value >> 4]);
        result.push_back(digits[value & 0x0f]);
    }
    return result;
}

std::string jsonEscape(std::string_view value) {
    std::string result;
    result.reserve(value.size() + 8);
    for (const auto character : value) {
        switch (character) {
        case '\\': result += "\\\\"; break;
        case '"': result += "\\\""; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (static_cast<unsigned char>(character) < 0x20) {
                std::ostringstream escaped;
                escaped << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                        << static_cast<int>(static_cast<unsigned char>(character));
                result += escaped.str();
            } else {
                result.push_back(character);
            }
        }
    }
    return result;
}

std::string jsonString(std::string_view value) {
    return "\"" + jsonEscape(value) + "\"";
}

std::string hexData(const std::vector<std::uint8_t>& value) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(value.size() * 2);
    for (const auto byte : value) {
        result.push_back(digits[byte >> 4]);
        result.push_back(digits[byte & 0x0f]);
    }
    return result;
}

std::optional<std::uint8_t> hexDigit(char value) {
    if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
    if (value >= 'a' && value <= 'f') return static_cast<std::uint8_t>(value - 'a' + 10);
    if (value >= 'A' && value <= 'F') return static_cast<std::uint8_t>(value - 'A' + 10);
    return std::nullopt;
}

std::optional<std::vector<std::uint8_t>> decodeHex(std::string_view value) {
    if (value.size() % 2 != 0) return std::nullopt;
    std::vector<std::uint8_t> result;
    result.reserve(value.size() / 2);
    for (std::size_t index = 0; index < value.size(); index += 2) {
        const auto high = hexDigit(value[index]);
        const auto low = hexDigit(value[index + 1]);
        if (!high || !low) return std::nullopt;
        result.push_back(static_cast<std::uint8_t>((*high << 4) | *low));
    }
    return result;
}

void skipWhitespace(std::string_view text, std::size_t& index) {
    while (index < text.size() && (text[index] == ' ' || text[index] == '\n' ||
                                   text[index] == '\r' || text[index] == '\t')) {
        ++index;
    }
}

std::optional<std::string> parseJsonString(std::string_view text, std::size_t& index) {
    skipWhitespace(text, index);
    if (index >= text.size() || text[index] != '"') return std::nullopt;
    ++index;
    std::string result;
    while (index < text.size()) {
        const auto character = text[index++];
        if (character == '"') return result;
        if (character != '\\') {
            result.push_back(character);
            continue;
        }
        if (index >= text.size()) return std::nullopt;
        switch (text[index++]) {
        case '"': result.push_back('"'); break;
        case '\\': result.push_back('\\'); break;
        case '/': result.push_back('/'); break;
        case 'b': result.push_back('\b'); break;
        case 'f': result.push_back('\f'); break;
        case 'n': result.push_back('\n'); break;
        case 'r': result.push_back('\r'); break;
        case 't': result.push_back('\t'); break;
        case 'u': {
            if (index + 4 > text.size()) return std::nullopt;
            std::uint32_t codePoint = 0;
            for (int digit = 0; digit < 4; ++digit) {
                const auto value = hexDigit(text[index++]);
                if (!value) return std::nullopt;
                codePoint = (codePoint << 4) | *value;
            }
            if (codePoint <= 0x7f) result.push_back(static_cast<char>(codePoint));
            else if (codePoint <= 0x7ff) {
                result.push_back(static_cast<char>(0xc0 | (codePoint >> 6)));
                result.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
            } else {
                result.push_back(static_cast<char>(0xe0 | (codePoint >> 12)));
                result.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f)));
                result.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
            }
            break;
        }
        default: return std::nullopt;
        }
    }
    return std::nullopt;
}

std::optional<std::string> fieldString(std::string_view text, std::string_view field) {
    const auto marker = "\"" + std::string(field) + "\":";
    const auto position = text.find(marker);
    if (position == std::string_view::npos) return std::nullopt;
    std::size_t index = position + marker.size();
    return parseJsonString(text, index);
}

std::optional<std::string_view> fieldValue(std::string_view text, std::string_view field) {
    const auto marker = "\"" + std::string(field) + "\":";
    const auto position = text.find(marker);
    if (position == std::string_view::npos) return std::nullopt;
    std::size_t start = position + marker.size();
    skipWhitespace(text, start);
    std::size_t end = start;
    if (start < text.size() && text[start] == '"') {
        ++end;
        while (end < text.size()) {
            if (text[end] == '\\') { end += 2; continue; }
            if (text[end++] == '"') break;
        }
    } else if (start < text.size() && text[start] == '[') {
        int depth = 0;
        bool quoted = false;
        for (; end < text.size(); ++end) {
            const auto character = text[end];
            if (character == '\\' && quoted) { ++end; continue; }
            if (character == '"') quoted = !quoted;
            if (quoted) continue;
            if (character == '[') ++depth;
            if (character == ']' && --depth == 0) { ++end; break; }
        }
    } else {
        while (end < text.size() && text[end] != ',' && text[end] != '}') ++end;
    }
    return text.substr(start, end - start);
}

std::string serialize(const KeyValueValue& value) {
    return std::visit([](const auto& value) -> std::string {
        using T = std::decay_t<decltype(value)>;
        if constexpr (std::is_same_v<T, bool>) {
            return std::string("{\"type\":\"bool\",\"value\":") +
                (value ? "true}" : "false}");
        } else if constexpr (std::is_same_v<T, std::int64_t>) {
            return "{\"type\":\"int\",\"value\":" + std::to_string(value) + "}";
        } else if constexpr (std::is_same_v<T, double>) {
            std::ostringstream stream;
            stream.precision(std::numeric_limits<double>::max_digits10);
            stream << value;
            return "{\"type\":\"double\",\"value\":" + stream.str() + "}";
        } else if constexpr (std::is_same_v<T, std::string>) {
            return "{\"type\":\"string\",\"value\":" + jsonString(value) + "}";
        } else if constexpr (std::is_same_v<T, std::vector<std::string>>) {
            std::string result = "{\"type\":\"stringArray\",\"value\":[";
            for (std::size_t index = 0; index < value.size(); ++index) {
                if (index != 0) result += ',';
                result += jsonString(value[index]);
            }
            return result + "]}";
        } else {
            return "{\"type\":\"data\",\"value\":" +
                jsonString(hexData(value)) + "}";
        }
    }, value);
}

std::optional<std::vector<std::string>> parseStringArray(std::string_view value) {
    std::size_t index = 0;
    skipWhitespace(value, index);
    if (index >= value.size() || value[index++] != '[') return std::nullopt;
    std::vector<std::string> result;
    for (;;) {
        skipWhitespace(value, index);
        if (index < value.size() && value[index] == ']') return result;
        auto item = parseJsonString(value, index);
        if (!item) return std::nullopt;
        result.push_back(std::move(*item));
        skipWhitespace(value, index);
        if (index >= value.size()) return std::nullopt;
        if (value[index] == ']') return result;
        if (value[index++] != ',') return std::nullopt;
    }
}

std::optional<KeyValueValue> parseValue(std::string_view text) {
    const auto type = fieldString(text, "type");
    const auto value = fieldValue(text, "value");
    if (!type || !value) return std::nullopt;
    if (*type == "bool") {
        if (*value == "true") return KeyValueValue{true};
        if (*value == "false") return KeyValueValue{false};
    } else if (*type == "int") {
        std::int64_t parsed = 0;
        const auto begin = value->data();
        const auto end = begin + value->size();
        if (std::from_chars(begin, end, parsed).ec == std::errc{}) return KeyValueValue{parsed};
    } else if (*type == "double") {
        std::string copy(*value);
        char* end = nullptr;
        const auto parsed = std::strtod(copy.c_str(), &end);
        if (end != copy.c_str() && *end == '\0') return KeyValueValue{parsed};
    } else if (*type == "string") {
        std::size_t index = 0;
        if (auto parsed = parseJsonString(*value, index)) return KeyValueValue{std::move(*parsed)};
    } else if (*type == "stringArray") {
        if (auto parsed = parseStringArray(*value)) return KeyValueValue{std::move(*parsed)};
    } else if (*type == "data") {
        std::size_t index = 0;
        if (auto encoded = parseJsonString(*value, index)) {
            if (auto parsed = decodeHex(*encoded)) return KeyValueValue{std::move(*parsed)};
        }
    }
    return std::nullopt;
}

} // namespace

Win32KeyValueStore::Win32KeyValueStore(std::filesystem::path root)
    : root_(root.empty() ? defaultRoot() : std::move(root)) {}

std::filesystem::path Win32KeyValueStore::pathForKey(const std::string& key) const {
    return root_ / (hexKey(key) + ".json");
}

std::optional<KeyValueValue> Win32KeyValueStore::readValue(const std::string& key) const {
    std::shared_lock lock(storeMutex);
    Win32FileSystem files;
    const auto path = pathForKey(key).u8string();
    const auto pathUtf8 = std::string(reinterpret_cast<const char*>(path.data()), path.size());
    const auto result = files.readUtf8(pathUtf8);
    if (!result.succeeded) return std::nullopt;
    return parseValue(result.text);
}

bool Win32KeyValueStore::writeValue(const std::string& key,
                                    const KeyValueValue& value,
                                    std::string& error) {
    std::unique_lock lock(storeMutex);
    Win32FileSystem files;
    const auto path = pathForKey(key).u8string();
    const auto pathUtf8 = std::string(reinterpret_cast<const char*>(path.data()), path.size());
    return files.writeAtomic(pathUtf8, serialize(value), error);
}

bool Win32KeyValueStore::remove(const std::string& key, std::string& error) {
    std::unique_lock lock(storeMutex);
    Win32FileSystem files;
    const auto path = pathForKey(key).u8string();
    const auto pathUtf8 = std::string(reinterpret_cast<const char*>(path.data()), path.size());
    return files.remove(pathUtf8, error);
}

} // namespace lithe::windows
