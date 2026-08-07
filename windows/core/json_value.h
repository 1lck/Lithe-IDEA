#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>
#include <utility>

namespace lithe::windows {

class JsonValue final {
public:
    using Object = std::map<std::string, JsonValue>;
    using Array = std::vector<JsonValue>;
    using Storage = std::variant<std::nullptr_t, bool, std::int64_t, std::uint64_t,
                                 double, std::string, Array, Object>;

    JsonValue() : value_(nullptr) {}
    JsonValue(std::nullptr_t) : value_(nullptr) {}
    JsonValue(bool value) : value_(value) {}
    JsonValue(std::int64_t value) : value_(value) {}
    JsonValue(std::uint64_t value) : value_(value) {}
    JsonValue(double value) : value_(value) {}
    JsonValue(std::string value) : value_(std::move(value)) {}
    JsonValue(const char* value) : value_(std::string(value == nullptr ? "" : value)) {}
    JsonValue(Array value) : value_(std::move(value)) {}
    JsonValue(Object value) : value_(std::move(value)) {}

    bool isNull() const noexcept;
    bool isBool() const noexcept;
    bool isNumber() const noexcept;
    bool isString() const noexcept;
    bool isArray() const noexcept;
    bool isObject() const noexcept;

    const bool* asBool() const noexcept;
    const std::int64_t* asSignedInteger() const noexcept;
    const std::uint64_t* asUnsignedInteger() const noexcept;
    const double* asFloatingPoint() const noexcept;
    std::optional<std::int64_t> asInt() const noexcept;
    std::optional<std::uint64_t> asUInt() const noexcept;
    std::optional<double> asDouble() const noexcept;
    const std::string* asString() const noexcept;
    const Array* asArray() const noexcept;
    const Object* asObject() const noexcept;

private:
    Storage value_;
};

struct JsonParseResult {
    std::optional<JsonValue> value;
    std::size_t errorOffset = 0;
    std::string error;

    bool succeeded() const noexcept { return value.has_value(); }
};

JsonParseResult parseJson(std::string_view input);
std::string serializeJson(const JsonValue& value);
const JsonValue* objectValue(const JsonValue& object, std::string_view key) noexcept;

} // namespace lithe::windows
