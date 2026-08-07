#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

class TerminalBuffer final {
public:
    TerminalBuffer();

    void reset();
    void append(std::string_view value);
    std::string render(std::size_t maxCharacters) const;

private:
    enum class EscapeMode {
        Normal,
        Escape,
        CSI,
        OSC,
        OSCEscape,
    };

    std::vector<std::vector<std::string>> lines_;
    std::size_t row_ = 0;
    std::size_t column_ = 0;
    std::size_t savedRow_ = 0;
    std::size_t savedColumn_ = 0;
    EscapeMode escapeMode_ = EscapeMode::Normal;
    std::string csiParameters_;

    static constexpr std::size_t MaximumRows = 2000;
    static constexpr std::size_t MaximumColumns = 240;

    void consume(std::uint32_t scalar);
    void consumeEscape(std::uint32_t scalar);
    void consumeText(std::uint32_t scalar);
    void write(std::string character);
    void ensureRow();
    void handleCSI(std::uint32_t final);
    void eraseDisplay(int mode);
    void eraseLine(int mode);
};

} // namespace lithe::windows::algorithms
