#include "terminal_keys.h"

#include <QByteArray>
#include <QtGlobal>

namespace lithe::windows::qt {

bool translateKeyEvent(const QKeyEvent& event, std::string& output) {
    const Qt::KeyboardModifiers mods = event.modifiers();
    const bool ctrl = mods.testFlag(Qt::ControlModifier);
    const bool alt = mods.testFlag(Qt::AltModifier);
    const int key = event.key();

    // Ctrl+letter -> the control byte (0x01..0x1a): Ctrl+C is ETX (0x03),
    // Ctrl+Z is SUB (0x1a), and so on. This is the raw-PTY convention shells
    // expect; it must win over the printable fallback below.
    if (ctrl && !alt && key >= Qt::Key_A && key <= Qt::Key_Z) {
        output.assign(1, static_cast<char>(key - Qt::Key_A + 1));
        return true;
    }

    switch (key) {
        case Qt::Key_Return:
        case Qt::Key_Enter:
            output = "\r";
            return true;
        case Qt::Key_Backspace:
            output.assign(1, '\x7f');
            return true;
        case Qt::Key_Tab:
            output = "\t";
            return true;
        case Qt::Key_Delete:
            output = "\x1b[3~";
            return true;
        case Qt::Key_Up:
            output = "\x1b[A";
            return true;
        case Qt::Key_Down:
            output = "\x1b[B";
            return true;
        case Qt::Key_Right:
            output = "\x1b[C";
            return true;
        case Qt::Key_Left:
            output = "\x1b[D";
            return true;
        case Qt::Key_Home:
            output = "\x1b[H";
            return true;
        case Qt::Key_End:
            output = "\x1b[F";
            return true;
        case Qt::Key_PageUp:
            output = "\x1b[5~";
            return true;
        case Qt::Key_PageDown:
            output = "\x1b[6~";
            return true;
        case Qt::Key_F1: output = "\x1bOP";   return true;
        case Qt::Key_F2: output = "\x1bOQ";   return true;
        case Qt::Key_F3: output = "\x1bOR";   return true;
        case Qt::Key_F4: output = "\x1bOS";   return true;
        case Qt::Key_F5: output = "\x1b[15~"; return true;
        case Qt::Key_F6: output = "\x1b[17~"; return true;
        case Qt::Key_F7: output = "\x1b[18~"; return true;
        case Qt::Key_F8: output = "\x1b[19~"; return true;
        case Qt::Key_F9: output = "\x1b[20~"; return true;
        case Qt::Key_F10: output = "\x1b[21~"; return true;
        case Qt::Key_F11: output = "\x1b[23~"; return true;
        case Qt::Key_F12: output = "\x1b[24~"; return true;
        default: break;
    }

    // Printables fall through to the key's Unicode text. Ctrl is excluded (the
    // control-byte branch handles it); Alt prefixes an ESC per the terminal
    // convention.
    if (!ctrl && !event.text().isEmpty()) {
        const QByteArray utf8 = event.text().toUtf8();
        output.clear();
        if (alt) output.push_back('\x1b');
        output.append(utf8.constData(), static_cast<std::size_t>(utf8.size()));
        return true;
    }

    return false;
}

} // namespace lithe::windows::qt
