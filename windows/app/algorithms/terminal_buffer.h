#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

struct TerminalSpan {
    std::string text;
    int foreground = -1;
    bool bold = false;
    bool underline = false;
};

class TerminalBuffer final {
public:
    TerminalBuffer();

    void reset();
    void append(std::string_view value);
    std::string render(std::size_t maxCharacters) const;
    std::vector<TerminalSpan> styledRender(std::size_t maxCharacters) const;

private:
    enum class EscapeMode {
        Normal,
        Escape,
        CSI,
        OSC,
        OSCEscape,
    };

    struct Cell {
        std::string text;
        int foreground = -1;
        bool bold = false;
        bool underline = false;
    };

    std::vector<std::vector<Cell>> lines_;
    std::size_t row_ = 0;
    std::size_t column_ = 0;
    std::size_t savedRow_ = 0;
    std::size_t savedColumn_ = 0;
    EscapeMode escapeMode_ = EscapeMode::Normal;
    std::string csiParameters_;
    int foreground_ = -1;
    bool bold_ = false;
    bool underline_ = false;

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
