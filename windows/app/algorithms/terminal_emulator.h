#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

// A single renderable cell: the glyph (UTF-8, may be empty) plus the SGR
// attributes and colors libvterm resolved for it. Colors are always expanded
// to 24-bit RGB so the Qt surface never has to resolve an indexed palette.
struct TerminalCell {
    std::string glyph;
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool reverse = false;
    bool strike = false;
    bool blink = false;
    bool conceal = false;
    bool fgDefault = true;
    bool bgDefault = true;
    std::uint8_t fgRed = 0;
    std::uint8_t fgGreen = 0;
    std::uint8_t fgBlue = 0;
    std::uint8_t bgRed = 0;
    std::uint8_t bgGreen = 0;
    std::uint8_t bgBlue = 0;
    // 1 = single-width, 2 = wide char (spans 2 columns), 0 = continuation
    // column behind a wide char.
    std::int8_t width = 1;
};

// A real VT/ANSI terminal emulator backed by libvterm (pure C, vendored under
// windows/third_party/libvterm). It parses ConPTY output into a cell grid and
// keeps a bounded scrollback ring buffer of its own (libvterm's screen is only
// the visible viewport). Owned by TerminalSession and read by the Qt surface;
// every public method is internally synchronized so the transport worker thread
// (write/resize) and the UI thread (cell/render) never race.
//
// Cell addressing uses *display* rows: row 0 is the oldest scrollback line and
// the bottom `rows()` display rows are the visible screen. This lets the
// surface draw scrollback and live screen through one indexing scheme.
class TerminalEmulator final {
public:
    TerminalEmulator();
    explicit TerminalEmulator(int rows, int cols);
    ~TerminalEmulator();

    TerminalEmulator(const TerminalEmulator&) = delete;
    TerminalEmulator& operator=(const TerminalEmulator&) = delete;

    // Feeds raw terminal output bytes (e.g. a ConPTY read) into the parser.
    void write(std::string_view bytes);
    void resize(int cols, int rows);
    void reset();

    int rows() const;
    int cols() const;

    // Scrollback above the visible screen, in display rows.
    int scrollbackLineCount() const;
    int scrollOffset() const;
    // Offset is clamped to [0, scrollbackLineCount()]. 0 shows the most recent
    // output (viewport flush at the bottom).
    void setScrollOffset(int offset);
    void scrollBy(int deltaLines);

    // displayRow in [0, scrollbackLineCount() + rows()).
    TerminalCell cell(int displayRow, int displayCol) const;

    // Plain-text snapshot of the visible screen. Kept for backward-compatible
    // assertions and debugging; the surface renders cells, not this text.
    std::string renderText(std::size_t maxCharacters) const;

    int cursorRow() const;
    int cursorCol() const;
    bool cursorVisible() const;
    bool altScreen() const;

    // Visible-screen row indexes damaged since the last call. Drained, so the
    // surface can repaint only the changed rows each frame.
    std::vector<int> drainDamagedRows();
    // Bumped on every change (write/resize/scrollback mutation). Lets the
    // surface cheaply decide whether to re-layout the scrollbar.
    std::uint64_t version() const;

    static constexpr int DefaultRows = 40;      // matches the transport's ConPTY size
    static constexpr int DefaultColumns = 120;
    static constexpr std::size_t MaximumScrollbackRows = 2000;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    mutable std::mutex mutex_;
};

} // namespace lithe::windows::algorithms
