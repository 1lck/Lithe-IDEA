#include "json_value.h"

#include <charconv>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <string>

namespace lithe::windows {

bool JsonValue::isNull() const noexcept { return std::holds_alternative<std::nullptr_t>(value_); }
bool JsonValue::isBool() const noexcept { return std::holds_alternative<bool>(value_); }
bool JsonValue::isNumber() const noexcept {
    return std::holds_alternative<std::int64_t>(value_) ||
        std::holds_alternative<std::uint64_t>(value_) ||
        std::holds_alternative<double>(value_);
}
bool JsonValue::isString() const noexcept { return std::holds_alternative<std::string>(value_); }
bool JsonValue::isArray() const noexcept { return std::holds_alternative<Array>(value_); }
bool JsonValue::isObject() const noexcept { return std::holds_alternative<Object>(value_); }

const bool* JsonValue::asBool() const noexcept { return std::get_if<bool>(&value_); }
const std::int64_t* JsonValue::asSignedInteger() const noexcept {
    return std::get_if<std::int64_t>(&value_);
}
const std::uint64_t* JsonValue::asUnsignedInteger() const noexcept {
    return std::get_if<std::uint64_t>(&value_);
}
const double* JsonValue::asFloatingPoint() const noexcept {
    return std::get_if<double>(&value_);
}

std::optional<std::int64_t> JsonValue::asInt() const noexcept {
    if (const auto* value = std::get_if<std::int64_t>(&value_)) return *value;
    if (const auto* value = std::get_if<std::uint64_t>(&value_)) {
        if (*value <= static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
            return static_cast<std::int64_t>(*value);
        }
        return std::nullopt;
    }
    if (const auto* value = std::get_if<double>(&value_)) {
        if (std::isfinite(*value) && std::floor(*value) == *value &&
            *value >= static_cast<double>(std::numeric_limits<std::int64_t>::min()) &&
            *value <= static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
            return static_cast<std::int64_t>(*value);
        }
    }
    return std::nullopt;
}

std::optional<std::uint64_t> JsonValue::asUInt() const noexcept {
    if (const auto* value = std::get_if<std::uint64_t>(&value_)) return *value;
    if (const auto* value = std::get_if<std::int64_t>(&value_)) {
        if (*value >= 0) return static_cast<std::uint64_t>(*value);
        return std::nullopt;
    }
    if (const auto* value = std::get_if<double>(&value_)) {
        if (std::isfinite(*value) && std::floor(*value) == *value && *value >= 0 &&
            *value <= static_cast<double>(std::numeric_limits<std::uint64_t>::max())) {
            return static_cast<std::uint64_t>(*value);
        }
    }
    return std::nullopt;
}

std::optional<double> JsonValue::asDouble() const noexcept {
    if (const auto* value = std::get_if<double>(&value_)) return *value;
    if (const auto* value = std::get_if<std::int64_t>(&value_)) return static_cast<double>(*value);
    if (const auto* value = std::get_if<std::uint64_t>(&value_)) return static_cast<double>(*value);
    return std::nullopt;
}

const std::string* JsonValue::asString() const noexcept { return std::get_if<std::string>(&value_); }
const JsonValue::Array* JsonValue::asArray() const noexcept { return std::get_if<Array>(&value_); }
const JsonValue::Object* JsonValue::asObject() const noexcept { return std::get_if<Object>(&value_); }

namespace {

class Parser final {
public:
    explicit Parser(std::string_view input) : input_(input) {}

    JsonParseResult parse() {
        skipWhitespace();
        auto value = parseValue();
        if (!value) return failure_;
        skipWhitespace();
        if (position_ != input_.size()) return fail("Trailing JSON data");
        return {std::move(value), 0, {}};
    }

private:
    std::string_view input_;
    std::size_t position_ = 0;
    JsonParseResult failure_;

    JsonParseResult fail(std::string message) {
        failure_.value.reset();
        failure_.errorOffset = position_;
        failure_.error = std::move(message);
        return failure_;
    }

    void skipWhitespace() {
        while (position_ < input_.size()) {
            const auto character = static_cast<unsigned char>(input_[position_]);
            if (character != ' ' && character != '\t' && character != '\r' && character != '\n') break;
            ++position_;
        }
    }

    std::optional<JsonValue> parseValue() {
        skipWhitespace();
        if (position_ >= input_.size()) {
            fail("Unexpected end of JSON");
            return std::nullopt;
        }
        switch (input_[position_]) {
        case 'n': return parseLiteral("null", JsonValue(nullptr));
        case 't': return parseLiteral("true", JsonValue(true));
        case 'f': return parseLiteral("false", JsonValue(false));
        case '"': {
            const auto value = parseString();
            return value ? std::optional<JsonValue>(JsonValue(std::move(*value))) : std::nullopt;
        }
        case '[': return parseArray();
        case '{': return parseObject();
        default:
            if (input_[position_] == '-' ||
                (input_[position_] >= '0' && input_[position_] <= '9')) return parseNumber();
            fail("Unexpected JSON value");
            return std::nullopt;
        }
    }

    std::optional<JsonValue> parseLiteral(std::string_view literal, JsonValue value) {
        if (input_.substr(position_, literal.size()) != literal) {
            fail("Invalid JSON literal");
            return std::nullopt;
        }
        position_ += literal.size();
        return value;
    }

    std::optional<std::string> parseString() {
        if (input_[position_] != '"') {
            fail("Expected JSON string");
            return std::nullopt;
        }
        ++position_;
        std::string result;
        while (position_ < input_.size()) {
            const auto character = static_cast<unsigned char>(input_[position_++]);
            if (character == '"') return result;
            if (character < 0x20) {
                fail("Control character in JSON string");
                return std::nullopt;
            }
            if (character != '\\') {
                result.push_back(static_cast<char>(character));
                continue;
            }
            if (position_ >= input_.size()) break;
            const auto escaped = input_[position_++];
            switch (escaped) {
            case '"': result.push_back('"'); break;
            case '\\': result.push_back('\\'); break;
            case '/': result.push_back('/'); break;
            case 'b': result.push_back('\b'); break;
            case 'f': result.push_back('\f'); break;
            case 'n': result.push_back('\n'); break;
            case 'r': result.push_back('\r'); break;
            case 't': result.push_back('\t'); break;
            case 'u':
                if (!appendUnicodeEscape(result)) return std::nullopt;
                break;
            default:
                fail("Invalid JSON escape");
                return std::nullopt;
            }
        }
        fail("Unterminated JSON string");
        return std::nullopt;
    }

    static bool hexDigit(char value, std::uint32_t& result) {
        if (value >= '0' && value <= '9') result = static_cast<std::uint32_t>(value - '0');
        else if (value >= 'a' && value <= 'f') result = static_cast<std::uint32_t>(value - 'a' + 10);
        else if (value >= 'A' && value <= 'F') result = static_cast<std::uint32_t>(value - 'A' + 10);
        else return false;
        return true;
    }

    bool appendUnicodeEscape(std::string& result) {
        auto parseUnit = [&](std::uint32_t& unit) {
            unit = 0;
            if (position_ + 4 > input_.size()) return false;
            for (std::size_t index = 0; index < 4; ++index) {
                std::uint32_t digit = 0;
                if (!hexDigit(input_[position_++], digit)) return false;
                unit = (unit << 4) | digit;
            }
            return true;
        };
        std::uint32_t unit = 0;
        if (!parseUnit(unit)) {
            fail("Invalid Unicode escape");
            return false;
        }
        std::uint32_t scalar = unit;
        if (unit >= 0xd800 && unit <= 0xdbff) {
            if (position_ + 6 > input_.size() || input_[position_] != '\\' || input_[position_ + 1] != 'u') {
                fail("Unpaired Unicode surrogate");
                return false;
            }
            position_ += 2;
            std::uint32_t low = 0;
            if (!parseUnit(low) || low < 0xdc00 || low > 0xdfff) {
                fail("Invalid Unicode surrogate pair");
                return false;
            }
            scalar = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            fail("Unpaired Unicode surrogate");
            return false;
        }
        if (scalar <= 0x7f) result.push_back(static_cast<char>(scalar));
        else if (scalar <= 0x7ff) {
            result.push_back(static_cast<char>(0xc0 | (scalar >> 6)));
            result.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
        } else if (scalar <= 0xffff) {
            result.push_back(static_cast<char>(0xe0 | (scalar >> 12)));
            result.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3f)));
            result.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
        } else {
            result.push_back(static_cast<char>(0xf0 | (scalar >> 18)));
            result.push_back(static_cast<char>(0x80 | ((scalar >> 12) & 0x3f)));
            result.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3f)));
            result.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
        }
        return true;
    }

    std::optional<JsonValue> parseNumber() {
        const auto start = position_;
        if (input_[position_] == '-') ++position_;
        if (position_ >= input_.size()) {
            fail("Invalid JSON number");
            return std::nullopt;
        }
        if (input_[position_] == '0') {
            ++position_;
        } else if (input_[position_] >= '1' && input_[position_] <= '9') {
            while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') ++position_;
        } else {
            fail("Invalid JSON number");
            return std::nullopt;
        }
        bool fractional = false;
        if (position_ < input_.size() && input_[position_] == '.') {
            fractional = true;
            ++position_;
            const auto fractionStart = position_;
            while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') ++position_;
            if (position_ == fractionStart) {
                fail("Invalid JSON fraction");
                return std::nullopt;
            }
        }
        if (position_ < input_.size() && (input_[position_] == 'e' || input_[position_] == 'E')) {
            fractional = true;
            ++position_;
            if (position_ < input_.size() && (input_[position_] == '+' || input_[position_] == '-')) ++position_;
            const auto exponentStart = position_;
            while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') ++position_;
            if (position_ == exponentStart) {
                fail("Invalid JSON exponent");
                return std::nullopt;
            }
        }
        const auto value = input_.substr(start, position_ - start);
        if (!fractional) {
            if (!value.empty() && value.front() == '-') {
                std::int64_t parsed = 0;
                const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
                if (result.ec == std::errc{} && result.ptr == value.data() + value.size()) return JsonValue(parsed);
            } else {
                std::uint64_t parsed = 0;
                const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
                if (result.ec == std::errc{} && result.ptr == value.data() + value.size()) return JsonValue(parsed);
            }
            fail("JSON integer out of range");
            return std::nullopt;
        }
        std::string copy(value);
        char* end = nullptr;
        const auto parsed = std::strtod(copy.c_str(), &end);
        if (end != copy.c_str() + copy.size() || !std::isfinite(parsed)) {
            fail("JSON number out of range");
            return std::nullopt;
        }
        return JsonValue(parsed);
    }

    std::optional<JsonValue> parseArray() {
        ++position_;
        JsonValue::Array result;
        skipWhitespace();
        if (position_ < input_.size() && input_[position_] == ']') {
            ++position_;
            return JsonValue(std::move(result));
        }
        while (position_ < input_.size()) {
            auto value = parseValue();
            if (!value) return std::nullopt;
            result.push_back(std::move(*value));
            skipWhitespace();
            if (position_ < input_.size() && input_[position_] == ']') {
                ++position_;
                return JsonValue(std::move(result));
            }
            if (position_ >= input_.size() || input_[position_] != ',') {
                fail("Expected comma in JSON array");
                return std::nullopt;
            }
            ++position_;
            skipWhitespace();
        }
        fail("Unterminated JSON array");
        return std::nullopt;
    }

    std::optional<JsonValue> parseObject() {
        ++position_;
        JsonValue::Object result;
        skipWhitespace();
        if (position_ < input_.size() && input_[position_] == '}') {
            ++position_;
            return JsonValue(std::move(result));
        }
        while (position_ < input_.size()) {
            if (input_[position_] != '"') {
                fail("Expected JSON object key");
                return std::nullopt;
            }
            auto key = parseString();
            if (!key) return std::nullopt;
            skipWhitespace();
            if (position_ >= input_.size() || input_[position_] != ':') {
                fail("Expected colon after JSON key");
                return std::nullopt;
            }
            ++position_;
            auto value = parseValue();
            if (!value) return std::nullopt;
            result[*key] = std::move(*value);
            skipWhitespace();
            if (position_ < input_.size() && input_[position_] == '}') {
                ++position_;
                return JsonValue(std::move(result));
            }
            if (position_ >= input_.size() || input_[position_] != ',') {
                fail("Expected comma in JSON object");
                return std::nullopt;
            }
            ++position_;
            skipWhitespace();
        }
        fail("Unterminated JSON object");
        return std::nullopt;
    }
};

} // namespace

JsonParseResult parseJson(std::string_view input) {
    return Parser(input).parse();
}

namespace {

void appendEscapedString(std::string_view value, std::string& output) {
    output.push_back('"');
    constexpr char digits[] = "0123456789abcdef";
    for (const auto character : value) {
        const auto byte = static_cast<unsigned char>(character);
        switch (character) {
        case '"': output += "\\\""; break;
        case '\\': output += "\\\\"; break;
        case '\b': output += "\\b"; break;
        case '\f': output += "\\f"; break;
        case '\n': output += "\\n"; break;
        case '\r': output += "\\r"; break;
        case '\t': output += "\\t"; break;
        default:
            if (byte < 0x20) {
                output += "\\u00";
                output.push_back(digits[(byte >> 4) & 0x0f]);
                output.push_back(digits[byte & 0x0f]);
            } else {
                output.push_back(character);
            }
            break;
        }
    }
    output.push_back('"');
}

void appendJson(const JsonValue& value, std::string& output) {
    if (value.isNull()) {
        output += "null";
    } else if (const auto* boolean = value.asBool()) {
        output += *boolean ? "true" : "false";
    } else if (const auto* integer = value.asSignedInteger()) {
        output += std::to_string(*integer);
    } else if (const auto* unsignedInteger = value.asUnsignedInteger()) {
        output += std::to_string(*unsignedInteger);
    } else if (const auto* number = value.asFloatingPoint()) {
        char buffer[64]{};
        const auto converted = std::to_chars(
            buffer, buffer + sizeof(buffer), *number, std::chars_format::general,
            std::numeric_limits<double>::max_digits10);
        if (converted.ec != std::errc{}) {
            output += "null";
        } else {
            output.append(buffer, converted.ptr);
        }
    } else if (const auto* string = value.asString()) {
        appendEscapedString(*string, output);
    } else if (const auto* array = value.asArray()) {
        output.push_back('[');
        for (std::size_t index = 0; index < array->size(); ++index) {
            if (index != 0) output.push_back(',');
            appendJson((*array)[index], output);
        }
        output.push_back(']');
    } else if (const auto* object = value.asObject()) {
        output.push_back('{');
        std::size_t index = 0;
        for (const auto& [key, child] : *object) {
            if (index++ != 0) output.push_back(',');
            appendEscapedString(key, output);
            output.push_back(':');
            appendJson(child, output);
        }
        output.push_back('}');
    }
}

} // namespace

std::string serializeJson(const JsonValue& value) {
    std::string result;
    appendJson(value, result);
    return result;
}

const JsonValue* objectValue(const JsonValue& object, std::string_view key) noexcept {
    const auto* values = object.asObject();
    if (values == nullptr) return nullptr;
    const auto found = values->find(std::string(key));
    return found == values->end() ? nullptr : &found->second;
}

} // namespace lithe::windows
