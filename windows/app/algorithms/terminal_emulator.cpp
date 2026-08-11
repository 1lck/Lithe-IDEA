#include "terminal_emulator.h"

#include "vterm.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <set>
#include <utility>

namespace lithe::windows::algorithms {

namespace {

void appendUtf8(std::string& out, std::uint32_t value) {
    if (value <= 0x7f) {
        out.push_back(static_cast<char>(value));
    } else if (value <= 0x7ff) {
        out.push_back(static_cast<char>(0xc0 | (value >> 6)));
        out.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else if (value <= 0xffff) {
        out.push_back(static_cast<char>(0xe0 | (value >> 12)));
        out.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else {
        out.push_back(static_cast<char>(0xf0 | (value >> 18)));
        out.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    }
}

// libvterm's convert-to-rgb resets every metadata flag, including the
// "default foreground/background" bits, so those must be captured first.
void convertCell(const VTermScreen* screen, const VTermScreenCell& cell, TerminalCell& out) {
    const bool fgDefault = VTERM_COLOR_IS_DEFAULT_FG(&cell.fg);
    const bool bgDefault = VTERM_COLOR_IS_DEFAULT_BG(&cell.bg);

    VTermColor fg = cell.fg;
    VTermColor bg = cell.bg;
    vterm_screen_convert_color_to_rgb(screen, &fg);
    vterm_screen_convert_color_to_rgb(screen, &bg);

    std::string glyph;
    for (int index = 0; index < VTERM_MAX_CHARS_PER_CELL; ++index) {
        const std::uint32_t codepoint = cell.chars[index];
        if (codepoint == 0) break;
        if (codepoint == static_cast<std::uint32_t>(-1)) continue;  // gap behind a wide char
        appendUtf8(glyph, codepoint);
    }

    out.glyph = std::move(glyph);
    out.bold = cell.attrs.bold != 0;
    out.italic = cell.attrs.italic != 0;
    out.underline = cell.attrs.underline != 0;
    out.reverse = cell.attrs.reverse != 0;
    out.strike = cell.attrs.strike != 0;
    out.blink = cell.attrs.blink != 0;
    out.conceal = cell.attrs.conceal != 0;
    out.fgDefault = fgDefault;
    out.bgDefault = bgDefault;
    if (!fgDefault) {
        out.fgRed = fg.rgb.red;
        out.fgGreen = fg.rgb.green;
        out.fgBlue = fg.rgb.blue;
    }
    if (!bgDefault) {
        out.bgRed = bg.rgb.red;
        out.bgGreen = bg.rgb.green;
        out.bgBlue = bg.rgb.blue;
    }
    out.width = cell.width == 2 ? 2 : (cell.chars[0] == 0 ? 0 : 1);
}

} // namespace

struct TerminalEmulator::Impl {
    VTerm* vt = nullptr;
    VTermScreen* screen = nullptr;
    int rows = 0;
    int cols = 0;
    // Oldest line at index 0; the newest sits at the back, just above the
    // visible screen. libvterm's own screen is only the visible viewport, so
    // this ring buffer is the scrollback.
    std::vector<std::vector<VTermScreenCell>> scrollback;
    int scrollOffset = 0;
    int cursorRow = 0;
    int cursorCol = 0;
    bool cursorVisible = true;
    bool altScreen = false;
    std::set<int> damageRows;
    std::uint64_t version = 0;

    explicit Impl(int rows_, int cols_) { init(rows_, cols_); }

    ~Impl() {
        if (vt != nullptr) vterm_free(vt);
    }

    void init(int rows_, int cols_) {
        vt = vterm_new(rows_, cols_);
        vterm_set_utf8(vt, 1);
        rows = rows_;
        cols = cols_;
        screen = vterm_obtain_screen(vt);
        vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_ROW);
        vterm_screen_enable_altscreen(screen, 1);
        vterm_screen_enable_reflow(screen, true);

        VTermColor fg;
        vterm_color_rgb(&fg, 0xff, 0xff, 0xff);
        VTermColor bg;
        vterm_color_rgb(&bg, 0x00, 0x00, 0x00);
        vterm_screen_set_default_colors(screen, &fg, &bg);

        static const VTermScreenCallbacks callbacks = {
            .damage = &Impl::onDamage,
            .moverect = nullptr,
            .movecursor = &Impl::onMoveCursor,
            .settermprop = &Impl::onSetTermProp,
            .bell = nullptr,
            .resize = &Impl::onScreenResize,
            .sb_pushline = &Impl::onSbPushLine,
            .sb_popline = &Impl::onSbPopLine,
            .sb_clear = &Impl::onSbClear,
        };
        vterm_screen_set_callbacks(screen, &callbacks, this);

        // libvterm keeps the state's pen/encoding/tabstop tables uninitialized
        // until the screen is reset; this is the canonical first-use step.
        vterm_screen_reset(screen, 1);
    }

    void feed(std::string_view bytes) {
        if (bytes.empty()) return;
        vterm_input_write(vt, bytes.data(), bytes.size());
        vterm_screen_flush_damage(screen);
        ++version;
    }

    void markAllVisibleRowsDamaged() {
        for (int row = 0; row < rows; ++row) damageRows.insert(row);
    }

    static int onDamage(VTermRect rect, void* user) {
        auto* impl = static_cast<Impl*>(user);
        for (int row = rect.start_row; row < rect.end_row; ++row) impl->damageRows.insert(row);
        return 1;
    }

    static int onMoveCursor(VTermPos pos, VTermPos oldPos, int visible, void* user) {
        (void)oldPos;
        (void)visible;
        auto* impl = static_cast<Impl*>(user);
        impl->cursorRow = pos.row;
        impl->cursorCol = pos.col;
        return 1;
    }

    static int onSetTermProp(VTermProp prop, VTermValue* value, void* user) {
        auto* impl = static_cast<Impl*>(user);
        switch (prop) {
        case VTERM_PROP_ALTSCREEN: impl->altScreen = value->boolean != 0; break;
        case VTERM_PROP_CURSORVISIBLE: impl->cursorVisible = value->boolean != 0; break;
        default: break;
        }
        return 1;
    }

    static int onSbPushLine(int cols, const VTermScreenCell* cells, void* user) {
        auto* impl = static_cast<Impl*>(user);
        impl->pushScrollback(cols, cells);
        return 1;
    }

    static int onSbPopLine(int cols, VTermScreenCell* cells, void* user) {
        auto* impl = static_cast<Impl*>(user);
        return impl->popScrollback(cols, cells);
    }

    static int onSbClear(void* user) {
        auto* impl = static_cast<Impl*>(user);
        impl->scrollback.clear();
        impl->scrollOffset = 0;
        impl->markAllVisibleRowsDamaged();
        ++impl->version;
        return 1;
    }

    static int onScreenResize(int rows, int cols, void* user) {
        auto* impl = static_cast<Impl*>(user);
        impl->rows = rows;
        impl->cols = cols;
        impl->scrollOffset = 0;
        impl->markAllVisibleRowsDamaged();
        ++impl->version;
        return 1;
    }

    void pushScrollback(int cols, const VTermScreenCell* cells) {
        std::vector<VTermScreenCell> row(cells, cells + cols);
        if (scrollback.size() >= MaximumScrollbackRows) {
            scrollback.erase(scrollback.begin());  // evict the oldest
        }
        scrollback.push_back(std::move(row));
        if (scrollback.size() > MaximumScrollbackRows) {
            scrollback.erase(scrollback.begin());
        }
        markAllVisibleRowsDamaged();
        ++version;
    }

    int popScrollback(int cols, VTermScreenCell* cells) {
        if (scrollback.empty()) return 0;
        const auto& row = scrollback.back();
        const int count = std::min(cols, static_cast<int>(row.size()));
        for (int index = 0; index < count; ++index) cells[index] = row[index];
        scrollback.pop_back();
        if (scrollOffset > 0) --scrollOffset;
        markAllVisibleRowsDamaged();
        ++version;
        return count;
    }
};

TerminalEmulator::TerminalEmulator()
    : TerminalEmulator(DefaultRows, DefaultColumns) {
}

TerminalEmulator::TerminalEmulator(int rows, int cols)
    : impl_(std::make_unique<Impl>(rows, cols)) {
}

TerminalEmulator::~TerminalEmulator() = default;

void TerminalEmulator::write(std::string_view bytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    impl_->feed(bytes);
}

void TerminalEmulator::resize(int cols, int rows) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (cols <= 0 || rows <= 0) return;
    if (cols == impl_->cols && rows == impl_->rows) return;
    vterm_set_size(impl_->vt, rows, cols);
    vterm_screen_flush_damage(impl_->screen);
    impl_->markAllVisibleRowsDamaged();
    ++impl_->version;
}

void TerminalEmulator::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    vterm_screen_reset(impl_->screen, 1);
    impl_->scrollback.clear();
    impl_->scrollOffset = 0;
    impl_->cursorRow = 0;
    impl_->cursorCol = 0;
    impl_->cursorVisible = true;
    impl_->altScreen = false;
    impl_->markAllVisibleRowsDamaged();
    ++impl_->version;
}

int TerminalEmulator::rows() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->rows;
}

int TerminalEmulator::cols() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->cols;
}

int TerminalEmulator::scrollbackLineCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return static_cast<int>(impl_->scrollback.size());
}

int TerminalEmulator::scrollOffset() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->scrollOffset;
}

void TerminalEmulator::setScrollOffset(int offset) {
    std::lock_guard<std::mutex> lock(mutex_);
    const int maximum = std::max(0, static_cast<int>(impl_->scrollback.size()));
    impl_->scrollOffset = std::clamp(offset, 0, maximum);
}

void TerminalEmulator::scrollBy(int deltaLines) {
    setScrollOffset(scrollOffset() + deltaLines);
}

TerminalCell TerminalEmulator::cell(int displayRow, int displayCol) const {
    std::lock_guard<std::mutex> lock(mutex_);
    TerminalCell out;
    if (displayRow < 0 || displayCol < 0 || displayCol >= impl_->cols) return out;
    const int scrollbackCount = static_cast<int>(impl_->scrollback.size());
    if (displayRow < scrollbackCount) {
        const auto& row = impl_->scrollback[static_cast<std::size_t>(displayRow)];
        if (displayCol < static_cast<int>(row.size())) {
            convertCell(impl_->screen, row[displayCol], out);
        }
        return out;
    }
    const int visibleRow = displayRow - scrollbackCount;
    if (visibleRow >= impl_->rows) return out;
    VTermPos pos;
    pos.row = visibleRow;
    pos.col = displayCol;
    VTermScreenCell cell;
    if (vterm_screen_get_cell(impl_->screen, pos, &cell) == 0) return out;
    convertCell(impl_->screen, cell, out);
    return out;
}

std::string TerminalEmulator::renderText(std::size_t maxCharacters) const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> lines;
    lines.reserve(static_cast<std::size_t>(impl_->rows));
    for (int row = 0; row < impl_->rows; ++row) {
        std::string line;
        for (int col = 0; col < impl_->cols; ++col) {
            VTermPos pos;
            pos.row = row;
            pos.col = col;
            VTermScreenCell cell;
            if (vterm_screen_get_cell(impl_->screen, pos, &cell) == 0) continue;
            if (cell.width == 0) continue;  // continuation column behind a wide char
            for (int index = 0; index < VTERM_MAX_CHARS_PER_CELL; ++index) {
                const std::uint32_t codepoint = cell.chars[index];
                if (codepoint == 0 || codepoint == static_cast<std::uint32_t>(-1)) break;
                appendUtf8(line, codepoint);
            }
        }
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t')) line.pop_back();
        lines.push_back(std::move(line));
    }
    // Trailing blank rows are not content (a render snapshot never grows lines
    // for them).
    while (!lines.empty() && lines.back().empty()) lines.pop_back();
    std::string result;
    for (std::size_t row = 0; row < lines.size(); ++row) {
        result += lines[row];
        if (row + 1 < lines.size()) result.push_back('\n');
    }
    if (maxCharacters == 0 || result.size() <= maxCharacters) return result;
    return result.substr(result.size() - maxCharacters);
}

int TerminalEmulator::cursorRow() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->cursorRow;
}

int TerminalEmulator::cursorCol() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->cursorCol;
}

bool TerminalEmulator::cursorVisible() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->cursorVisible;
}

bool TerminalEmulator::altScreen() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->altScreen;
}

std::vector<int> TerminalEmulator::drainDamagedRows() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<int> rows(impl_->damageRows.begin(), impl_->damageRows.end());
    impl_->damageRows.clear();
    return rows;
}

std::uint64_t TerminalEmulator::version() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return impl_->version;
}

} // namespace lithe::windows::algorithms
