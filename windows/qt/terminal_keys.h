#pragma once

#include <QKeyEvent>

#include <string>

namespace lithe::windows::qt {

// Maps a QKeyEvent to the terminal input bytes it should produce. Returns true
// when the event is a terminal key (and `output` holds the bytes to send) and
// false for keys the surface should ignore (plain modifier presses, layout keys,
// etc.).
//
// Supported set (the common shell-input keys; exotic combos such as Ctrl+arrow
// and Meta+key are deferred to a follow-up change):
//   - printable UTF-8 as-is (Shift produces the shifted character)
//   - Enter -> \r, Backspace -> \x7f, Tab -> \t, Delete -> CSI 3~
//   - Ctrl+A..Z -> the control byte (Ctrl+C -> \x03, Ctrl+D -> \x04, ...)
//   - Up/Down/Right/Left/Home/End/PgUp/PgDn -> the CSI sequences
//   - F1..F12 -> the SS3/CSI sequences
//   - Alt+printable -> ESC + the printable
bool translateKeyEvent(const QKeyEvent& event, std::string& output);

} // namespace lithe::windows::qt
