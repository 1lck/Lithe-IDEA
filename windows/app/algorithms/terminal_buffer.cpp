#include "terminal_buffer.h"

#include <algorithm>
#include <cctype>
#include <charconv>

namespace lithe::windows::algorithms {
namespace {

std::string encode(std::uint32_t value) {
    if (value <= 0x7f) return std::string(1, static_cast<char>(value));
    if (value <= 0x7ff) {
        return {static_cast<char>(0xc0 | (value >> 6)),
                static_cast<char>(0x80 | (value & 0x3f))};
    }
    if (value <= 0xffff) {
        return {static_cast<char>(0xe0 | (value >> 12)),
                static_cast<char>(0x80 | ((value >> 6) & 0x3f)),
                static_cast<char>(0x80 | (value & 0x3f))};
    }
    return {static_cast<char>(0xf0 | (value >> 18)),
            static_cast<char>(0x80 | ((value >> 12) & 0x3f)),
            static_cast<char>(0x80 | ((value >> 6) & 0x3f)),
            static_cast<char>(0x80 | (value & 0x3f))};
}

bool isWhitespace(const std::string& value) {
    return value.size() == 1 && std::isspace(static_cast<unsigned char>(value[0]));
}

} // namespace

TerminalBuffer::TerminalBuffer() {
    reset();
}

void TerminalBuffer::reset() {
    lines_ = {std::vector<Cell>{}};
    row_ = 0;
    column_ = 0;
    savedRow_ = 0;
    savedColumn_ = 0;
    escapeMode_ = EscapeMode::Normal;
    csiParameters_.clear();
    foreground_ = -1;
    bold_ = false;
    underline_ = false;
}

void TerminalBuffer::append(std::string_view value) {
    for (std::size_t index = 0; index < value.size();) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t length = 1;
        std::uint32_t scalar = first;
        if (first >= 0xc2 && first <= 0xdf) length = 2;
        else if (first >= 0xe0 && first <= 0xef) length = 3;
        else if (first >= 0xf0 && first <= 0xf4) length = 4;
        if (length > 1 && index + length <= value.size()) {
            scalar = first & ((1u << (8 - length - 1)) - 1u);
            bool valid = true;
            for (std::size_t offset = 1; offset < length; ++offset) {
                const auto byte = static_cast<unsigned char>(value[index + offset]);
                if ((byte & 0xc0) != 0x80) valid = false;
                scalar = (scalar << 6) | (byte & 0x3f);
            }
            if (length == 3) {
                const auto second = static_cast<unsigned char>(value[index + 1]);
                if ((first == 0xe0 && second < 0xa0) ||
                    (first == 0xed && second >= 0xa0)) valid = false;
            }
            if (length == 4) {
                const auto second = static_cast<unsigned char>(value[index + 1]);
                if ((first == 0xf0 && second < 0x90) ||
                    (first == 0xf4 && second >= 0x90)) valid = false;
            }
            if (!valid || scalar > 0x10ffff) {
                length = 1;
                scalar = 0xfffd;
            }
        } else if (length > 1) {
            length = 1;
            scalar = 0xfffd;
        } else if (first >= 0x80) {
            scalar = 0xfffd;
        }
        consume(scalar);
        index += length;
    }
}

std::string TerminalBuffer::render(std::size_t maxCharacters) const {
    const auto spans = styledRender(maxCharacters);
    std::string result;
    for (const auto& span : spans) result += span.text;
    return result;
}

std::vector<TerminalSpan> TerminalBuffer::styledRender(std::size_t maxCharacters) const {
    std::vector<TerminalSpan> tokens;
    for (std::size_t line = 0; line < lines_.size(); ++line) {
        std::size_t start = 0;
        std::size_t end = lines_[line].size();
        while (start < end && isWhitespace(lines_[line][start].text)) ++start;
        while (end > start && isWhitespace(lines_[line][end - 1].text)) --end;
        for (std::size_t index = start; index < end; ++index) {
            const auto& cell = lines_[line][index];
            if (!tokens.empty() && tokens.back().foreground == cell.foreground &&
                tokens.back().bold == cell.bold &&
                tokens.back().underline == cell.underline) {
                tokens.back().text += cell.text;
            } else {
                tokens.push_back(TerminalSpan{
                    cell.text, cell.foreground, cell.bold, cell.underline});
            }
        }
        if (line + 1 < lines_.size()) {
            if (!tokens.empty() && tokens.back().foreground == -1 &&
                !tokens.back().bold && !tokens.back().underline) {
                tokens.back().text += '\n';
            } else {
                tokens.push_back(TerminalSpan{"\n", -1, false, false});
            }
        }
    }
    if (maxCharacters == 0 || tokens.empty()) return {};

    std::size_t characterCount = 0;
    for (const auto& token : tokens) {
        for (std::size_t offset = 0; offset < token.text.size();) {
            const auto byte = static_cast<unsigned char>(token.text[offset]);
            const auto length = byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4;
            offset += std::min<std::size_t>(static_cast<std::size_t>(length),
                                            token.text.size() - offset);
            ++characterCount;
        }
    }
    if (characterCount <= maxCharacters) return tokens;

    std::size_t toSkip = characterCount - maxCharacters;
    std::size_t index = 0;
    while (index < tokens.size()) {
        std::size_t tokenCharacters = 0;
        for (std::size_t offset = 0; offset < tokens[index].text.size();) {
            const auto byte = static_cast<unsigned char>(tokens[index].text[offset]);
            const auto length = byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4;
            offset += std::min<std::size_t>(static_cast<std::size_t>(length),
                                            tokens[index].text.size() - offset);
            ++tokenCharacters;
        }
        if (toSkip < tokenCharacters) break;
        toSkip -= tokenCharacters;
        ++index;
    }
    if (index == tokens.size()) return {};
    while (toSkip > 0 && !tokens[index].text.empty()) {
        const auto byte = static_cast<unsigned char>(tokens[index].text[0]);
        const auto length = byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4;
        tokens[index].text.erase(
            0, std::min<std::size_t>(static_cast<std::size_t>(length),
                                     tokens[index].text.size()));
        --toSkip;
    }
    tokens.erase(tokens.begin(), tokens.begin() + static_cast<std::ptrdiff_t>(index));
    return tokens;
}

void TerminalBuffer::consume(std::uint32_t scalar) {
    switch (escapeMode_) {
    case EscapeMode::Escape:
        consumeEscape(scalar);
        break;
    case EscapeMode::CSI:
        if (scalar >= 64 && scalar <= 126) {
            handleCSI(scalar);
            escapeMode_ = EscapeMode::Normal;
            csiParameters_.clear();
        } else {
            csiParameters_ += encode(scalar);
        }
        break;
    case EscapeMode::OSC:
        if (scalar == 7) escapeMode_ = EscapeMode::Normal;
        else if (scalar == 27) escapeMode_ = EscapeMode::OSCEscape;
        break;
    case EscapeMode::OSCEscape:
        escapeMode_ = scalar == '\\' ? EscapeMode::Normal : EscapeMode::OSC;
        break;
    case EscapeMode::Normal:
        consumeText(scalar);
        break;
    }
}

void TerminalBuffer::consumeEscape(std::uint32_t scalar) {
    switch (scalar) {
    case '[': escapeMode_ = EscapeMode::CSI; csiParameters_.clear(); break;
    case ']': escapeMode_ = EscapeMode::OSC; break;
    case '7': savedRow_ = row_; savedColumn_ = column_; escapeMode_ = EscapeMode::Normal; break;
    case '8': row_ = savedRow_; column_ = savedColumn_; ensureRow(); escapeMode_ = EscapeMode::Normal; break;
    case 'c': reset(); break;
    default: escapeMode_ = EscapeMode::Normal; break;
    }
}

void TerminalBuffer::consumeText(std::uint32_t scalar) {
    switch (scalar) {
    case 0x1b: escapeMode_ = EscapeMode::Escape; break;
    case 8:
    case 127: column_ = column_ == 0 ? 0 : column_ - 1; break;
    case 9: column_ = ((column_ / 8) + 1) * 8; break;
    case 10: ++row_; column_ = 0; ensureRow(); break;
    case 13: column_ = 0; break;
    default:
        if (scalar < 32) break;
        write(encode(scalar));
        break;
    }
}

void TerminalBuffer::write(std::string character) {
    ensureRow();
    while (lines_[row_].size() < column_) {
        lines_[row_].push_back(Cell{" ", foreground_, bold_, underline_});
    }
    Cell cell{std::move(character), foreground_, bold_, underline_};
    if (column_ == lines_[row_].size()) lines_[row_].push_back(std::move(cell));
    else lines_[row_][column_] = std::move(cell);
    ++column_;
    if (column_ >= MaximumColumns) {
        column_ = 0;
        ++row_;
        ensureRow();
    }
}

void TerminalBuffer::ensureRow() {
    while (lines_.size() <= row_) lines_.emplace_back();
    if (lines_.size() > MaximumRows) {
        const auto removeCount = lines_.size() - MaximumRows;
        lines_.erase(lines_.begin(), lines_.begin() + static_cast<std::ptrdiff_t>(removeCount));
        row_ = row_ >= removeCount ? row_ - removeCount : 0;
        savedRow_ = savedRow_ >= removeCount ? savedRow_ - removeCount : 0;
    }
}

void TerminalBuffer::handleCSI(std::uint32_t final) {
    std::vector<int> values;
    std::string value;
    const auto flush = [&] {
        if (value.empty()) {
            values.push_back(0);
        } else {
            int parsed = 0;
            const auto begin = value.data();
            const auto end = begin + value.size();
            const auto parsedResult = std::from_chars(begin, end, parsed);
            values.push_back(parsedResult.ec == std::errc{} ? parsed : 0);
        }
        value.clear();
    };
    for (const auto character : csiParameters_) {
        if (character == '?' || character == ' ' || character == '>') continue;
        if (character == ';') flush();
        else if (character >= '0' && character <= '9') value.push_back(character);
    }
    if (!value.empty() || (!csiParameters_.empty() && csiParameters_.back() == ';')) flush();
    const auto first = values.empty() || values.front() == 0 ? 1 : values.front();
    const auto second = values.size() > 1 && values[1] != 0 ? values[1] : 1;
    if (final == 'm') {
        if (values.empty()) values.push_back(0);
        for (std::size_t index = 0; index < values.size(); ++index) {
            const auto value = values[index];
            if (value == 0) {
                foreground_ = -1;
                bold_ = false;
                underline_ = false;
            } else if (value == 1) {
                bold_ = true;
            } else if (value == 22) {
                bold_ = false;
            } else if (value == 4) {
                underline_ = true;
            } else if (value == 24) {
                underline_ = false;
            } else if (value == 39) {
                foreground_ = -1;
            } else if (value >= 30 && value <= 37) {
                foreground_ = value - 30;
            } else if (value >= 90 && value <= 97) {
                foreground_ = value - 90 + 8;
            } else if (value == 38 && index + 2 < values.size() && values[index + 1] == 5) {
                foreground_ = std::clamp(values[index + 2], 0, 255);
                index += 2;
            }
        }
        return;
    }
    switch (final) {
    case 'A': row_ = row_ > static_cast<std::size_t>(first) ? row_ - first : 0; break;
    case 'B':
    case 'e': row_ += first; ensureRow(); break;
    case 'C':
    case 'a': column_ += first; break;
    case 'D': column_ = column_ > static_cast<std::size_t>(first) ? column_ - first : 0; break;
    case 'G': column_ = first > 0 ? static_cast<std::size_t>(first - 1) : 0; break;
    case 'd': row_ = first > 0 ? static_cast<std::size_t>(first - 1) : 0; ensureRow(); break;
    case 'H':
    case 'f':
        row_ = first > 0 ? static_cast<std::size_t>(first - 1) : 0;
        column_ = second > 0 ? static_cast<std::size_t>(second - 1) : 0;
        ensureRow();
        break;
    case 'J': eraseDisplay(values.empty() ? 0 : values.front()); break;
    case 'K': eraseLine(values.empty() ? 0 : values.front()); break;
    case 's': savedRow_ = row_; savedColumn_ = column_; break;
    case 'u': row_ = savedRow_; column_ = savedColumn_; ensureRow(); break;
    default: break;
    }
}

void TerminalBuffer::eraseDisplay(int mode) {
    if (mode == 2 || mode == 3) {
        reset();
        return;
    }
    if (lines_.empty()) return;
    const auto current = std::min(row_, lines_.size() - 1);
    if (mode == 1) {
        for (std::size_t index = 0; index <= current; ++index) lines_[index].clear();
        row_ = current;
        column_ = 0;
        return;
    }
    lines_[current].resize(std::min(column_, lines_[current].size()));
    if (current + 1 < lines_.size()) lines_.erase(lines_.begin() + static_cast<std::ptrdiff_t>(current + 1), lines_.end());
}

void TerminalBuffer::eraseLine(int mode) {
    ensureRow();
    if (mode == 1) {
        const auto count = std::min(column_, lines_[row_].size());
        lines_[row_].erase(lines_[row_].begin(), lines_[row_].begin() + static_cast<std::ptrdiff_t>(count));
        column_ = 0;
    } else if (mode == 2) {
        lines_[row_].clear();
        column_ = 0;
    } else if (column_ < lines_[row_].size()) {
        lines_[row_].erase(lines_[row_].begin() + static_cast<std::ptrdiff_t>(column_), lines_[row_].end());
    }
}

} // namespace lithe::windows::algorithms
