// Unit tests for TerminalEmulator (the libvterm wrapper).
//
// Platform-independent: a plain main() with assert, feeding raw VT byte
// sequences and asserting the resulting rendered grid. Builds and runs
// off-Windows with g++ (and on Windows CI) with no Win32 or Qt includes.

#include "terminal_emulator.h"

#include <cassert>
#include <string>

namespace {

using lithe::windows::algorithms::TerminalCell;
using lithe::windows::algorithms::TerminalEmulator;

void testSGRColors() {
    TerminalEmulator emulator(2, 40);
    // Standard foreground red, then a reset, then uncolored text.
    emulator.write("\x1b[31mRED\x1b[0mplain\r\n");
    TerminalCell red = emulator.cell(0, 0);
    assert(red.glyph == "R");
    assert(!red.fgDefault);
    assert(red.fgRed == 224 && red.fgGreen == 0 && red.fgBlue == 0);
    // After SGR reset the attribute is gone.
    TerminalCell reset = emulator.cell(0, 3);
    assert(reset.glyph == "p");
    assert(reset.fgDefault);

    // Standard background blue on the next row.
    emulator.write("\x1b[44mX\x1b[0m");
    TerminalCell bg = emulator.cell(1, 0);
    assert(!bg.bgDefault);
    assert(bg.bgRed == 0 && bg.bgGreen == 0 && bg.bgBlue == 224);
}

void test256ColorAndTruecolor() {
    TerminalEmulator emulator(2, 40);
    // 256-color index 196 resolves to (255, 0, 0) in the standard palette.
    emulator.write("\x1b[38;5;196mX\x1b[0m");
    TerminalCell indexed = emulator.cell(0, 0);
    assert(!indexed.fgDefault);
    assert(indexed.fgRed == 255 && indexed.fgGreen == 0 && indexed.fgBlue == 0);

    // Truecolor SGR 38;2;r;g;b (cursor is at (0,1) after the first write).
    emulator.write("\x1b[38;2;10;20;30mY\x1b[0m");
    TerminalCell trueColor = emulator.cell(0, 1);
    assert(!trueColor.fgDefault);
    assert(trueColor.fgRed == 10 && trueColor.fgGreen == 20 && trueColor.fgBlue == 30);
}

void testBoldAndInverse() {
    TerminalEmulator emulator(2, 40);
    emulator.write("\x1b[1mbold\x1b[0m \x1b[7minverse\x1b[0m");
    assert(emulator.cell(0, 0).bold);
    assert(!emulator.cell(0, 4).bold);  // space after reset
    assert(emulator.cell(0, 6).reverse);
    assert(emulator.cell(0, 5).bold == false);
}

void testCursorPositioning() {
    TerminalEmulator emulator(5, 20);
    emulator.write("A");
    assert(emulator.cursorRow() == 0 && emulator.cursorCol() == 1);
    emulator.write("\x1b[3;5HZ");
    assert(emulator.cursorRow() == 2 && emulator.cursorCol() == 5);
    assert(emulator.cell(2, 4).glyph == "Z");
    // Relative movement: down one, right one, then type Q.
    emulator.write("\x1b[1B\x1b[1CQ");
    assert(emulator.cursorRow() == 3 && emulator.cursorCol() == 7);
    assert(emulator.cell(3, 6).glyph == "Q");
}

void testLineAndDisplayErase() {
    TerminalEmulator emulator(3, 20);
    emulator.write("hello");
    emulator.write("\r\x1b[2K");  // return to col 0, erase the whole current line
    emulator.write("ok");
    assert(emulator.cell(0, 0).glyph == "o");
    assert(emulator.cell(0, 1).glyph == "k");
    assert(emulator.cell(0, 2).glyph.empty());

    emulator.write("abc\r\ndef\r\nghi");
    emulator.write("\x1b[2J");  // erase whole display
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 20; ++col) {
            assert(emulator.cell(row, col).glyph.empty());
        }
    }
}

void testAlternateScreenEnterLeave() {
    TerminalEmulator emulator(3, 20);
    emulator.write("main-screen\n");
    assert(!emulator.altScreen());
    emulator.write("\x1b[?1049h");  // enter alternate screen
    assert(emulator.altScreen());
    emulator.write("\x1b[Halt-content\n");  // home, then write on the alt buffer
    assert(emulator.cell(0, 0).glyph == "a");
    emulator.write("\x1b[?1049l");  // leave alternate screen
    assert(!emulator.altScreen());
    // The primary buffer is restored.
    assert(emulator.cell(0, 0).glyph == "m");
    assert(emulator.cell(0, 3).glyph == "n");
    assert(emulator.cell(0, 4).glyph == "-");
}

void testScrollbackBoundedAndEvicted() {
    TerminalEmulator emulator(3, 5);
    std::string chunk;
    chunk.reserve(2200 * 8);
    for (int index = 0; index < 2200; ++index) {
        chunk += "L";
        chunk += std::to_string(index);
        chunk += "\r\n";
    }
    emulator.write(chunk);

    // 2198 lines scrolled off; the cap keeps the 2000 newest.
    assert(emulator.scrollbackLineCount() == 2000);
    // The 198 oldest lines were evicted; the oldest survivor is L198.
    assert(emulator.cell(0, 0).glyph == "L");
    assert(emulator.cell(0, 1).glyph == "1");
    assert(emulator.cell(0, 2).glyph == "9");
    assert(emulator.cell(0, 3).glyph == "8");
    // Newest scrollback line sits just above the visible screen.
    assert(emulator.cell(1999, 0).glyph == "L");
    assert(emulator.cell(1999, 3).glyph == "9");
    assert(emulator.cell(1999, 4).glyph == "7");
    // The visible screen holds the last two lines plus the empty bottom row.
    assert(emulator.cell(2000, 0).glyph == "L");
    assert(emulator.cell(2000, 4).glyph == "8");
    assert(emulator.cell(2001, 0).glyph == "L");
    assert(emulator.cell(2002, 0).glyph.empty());
}

void testScrollOffsetClamped() {
    TerminalEmulator emulator(3, 20);
    emulator.write("one\ntwo\nthree\nfour");
    // Scrollback contains one line ("one"), visible holds two/three/four.
    assert(emulator.scrollbackLineCount() == 1);
    emulator.setScrollOffset(5);
    assert(emulator.scrollOffset() == 1);
    emulator.setScrollOffset(-1);
    assert(emulator.scrollOffset() == 0);
    emulator.scrollBy(-2);
    assert(emulator.scrollOffset() == 0);
}

void testRenderTextSnapshot() {
    TerminalEmulator emulator(2, 20);
    emulator.write("hello\r\nworld");
    assert(emulator.renderText(100) == "hello\nworld");
    assert(emulator.renderText(6) == "\nworld");
}

void testReset() {
    TerminalEmulator emulator(2, 20);
    emulator.write("abc");
    emulator.reset();
    assert(emulator.renderText(100).empty());
    assert(emulator.cursorRow() == 0 && emulator.cursorCol() == 0);
    assert(emulator.scrollbackLineCount() == 0);
}

// Cases migrated from the superseded TerminalBuffer unit test: behaviours real
// shells emit every day that the grid emulator must also get right.
void testMigratedFromTerminalBuffer() {
    // Cursor-left (CUB) then overwrite in place.
    TerminalEmulator emulator(2, 20);
    emulator.write("abc\x1b[2DXY");
    assert(emulator.renderText(100) == "aXY");
    assert(emulator.cursorCol() == 3);

    // OSC 0/2 window-title sequences (sent by every shell on startup) are
    // consumed and never leak into the grid; the BEL-terminated payload is
    // followed by normal text.
    // OSC 0/2 window-title sequences (sent by every shell on startup) are
    // consumed and never leak into the grid; the BEL-terminated payload is
    // followed by normal text.
    TerminalEmulator osc(2, 20);
    osc.write("\x1b]0;ignored title\x07ok");
    assert(osc.renderText(100) == "ok");
    assert(osc.cursorCol() == 2);

    // Multi-byte UTF-8 (width-2 CJK) renders both codepoints and advances the
    // cursor by their column widths.
    TerminalEmulator utf(1, 10);
    utf.write("你好");
    assert(utf.cell(0, 0).glyph == "你");
    assert(utf.cell(0, 2).glyph == "好");
    assert(utf.cursorCol() == 4);

    // A hostile/absurd CUF parameter must not overflow: the cursor clamps to the
    // right margin, the next glyph lands in the last column, and further text
    // wraps to the next row.
    TerminalEmulator wide(2, 20);
    wide.write("abc\x1b[999999999999Cde");
    assert(wide.cell(0, 0).glyph == "a");
    assert(wide.cell(0, 19).glyph == "d");
    assert(wide.cell(1, 0).glyph == "e");
    assert(wide.cursorRow() == 1 && wide.cursorCol() == 1);
}

} // namespace

int main() {
    testSGRColors();
    test256ColorAndTruecolor();
    testBoldAndInverse();
    testCursorPositioning();
    testLineAndDisplayErase();
    testAlternateScreenEnterLeave();
    testScrollbackBoundedAndEvicted();
    testScrollOffsetClamped();
    testRenderTextSnapshot();
    testReset();
    testMigratedFromTerminalBuffer();
    return 0;
}
