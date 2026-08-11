// Offscreen Qt tests for TerminalSurface + terminal_keys: keystroke->byte
// translation reaches the fake transport, and resizing the widget forwards the
// computed cell geometry to transport.resize. The surface holds no terminal
// state, so each case drives it against a fresh model+session via a fake
// transport (same pattern as the panel test).

#include "fake_terminal_transport.h"
#include "terminal_model.h"
#include "terminal_surface.h"

#include <QApplication>
#include <QColor>
#include <QCoreApplication>
#include <QImage>
#include <QKeyEvent>
#include <QString>

#include <cassert>
#include <memory>
#include <string>
#include <vector>

namespace {

using lithe::windows::TerminalTransport;
using lithe::windows::app::TerminalModel;
using lithe::windows::app::TerminalShellSpec;
using lithe::windows::tests::FakeTerminalTransport;

void sendKey(QWidget* widget, int key,
             Qt::KeyboardModifiers mods = Qt::NoModifier,
             const QString& text = {}) {
    QKeyEvent press(QEvent::KeyPress, key, mods, text);
    QCoreApplication::sendEvent(widget, &press);
}

struct Harness {
    FakeTerminalTransport* fake = nullptr;
    std::unique_ptr<TerminalModel> model;
    std::unique_ptr<TerminalSurface> surface;
    QString sessionId;

    Harness() {
        model = std::make_unique<TerminalModel>([this]() -> std::unique_ptr<TerminalTransport> {
            auto* raw = new FakeTerminalTransport();
            fake = raw;
            return std::unique_ptr<TerminalTransport>(raw);
        });
        TerminalShellSpec shell;
        shell.executablePath = "C:/Windows/System32/cmd.exe";
        sessionId = QString::fromStdString(model->create(shell, "C:/proj", {}));
        surface = std::make_unique<TerminalSurface>();
        surface->bind(model.get(), sessionId);
    }
};

void testPrintableKeySendsText() {
    Harness h;
    sendKey(h.surface.get(), Qt::Key_A, Qt::NoModifier, QStringLiteral("a"));
    assert(h.fake->sends.size() == 1);
    assert(h.fake->sends.back() == "a");
    sendKey(h.surface.get(), Qt::Key_A, Qt::ShiftModifier, QStringLiteral("A"));
    assert(h.fake->sends.back() == "A");
    // Non-ASCII printables go out as UTF-8 (U+4E2D).
    sendKey(h.surface.get(), Qt::Key_O, Qt::NoModifier, QStringLiteral("中"));
    assert(h.fake->sends.back() == "\xe4\xb8\xad");
}

void testControlKeysMapToBytes() {
    Harness h;
    sendKey(h.surface.get(), Qt::Key_C, Qt::ControlModifier);
    assert(h.fake->sends.back() == std::string{'\x03'});
    sendKey(h.surface.get(), Qt::Key_Z, Qt::ControlModifier);
    assert(h.fake->sends.back() == std::string{'\x1a'});
    sendKey(h.surface.get(), Qt::Key_Return);
    assert(h.fake->sends.back() == "\r");
    sendKey(h.surface.get(), Qt::Key_Backspace);
    assert(h.fake->sends.back() == std::string{'\x7f'});
    sendKey(h.surface.get(), Qt::Key_Tab);
    assert(h.fake->sends.back() == "\t");
}

void testNavigationKeysMapToCsi() {
    Harness h;
    sendKey(h.surface.get(), Qt::Key_Up);
    assert(h.fake->sends.back() == "\x1b[A");
    sendKey(h.surface.get(), Qt::Key_Down);
    assert(h.fake->sends.back() == "\x1b[B");
    sendKey(h.surface.get(), Qt::Key_Right);
    assert(h.fake->sends.back() == "\x1b[C");
    sendKey(h.surface.get(), Qt::Key_Left);
    assert(h.fake->sends.back() == "\x1b[D");
    sendKey(h.surface.get(), Qt::Key_Home);
    assert(h.fake->sends.back() == "\x1b[H");
    sendKey(h.surface.get(), Qt::Key_End);
    assert(h.fake->sends.back() == "\x1b[F");
    sendKey(h.surface.get(), Qt::Key_PageUp);
    assert(h.fake->sends.back() == "\x1b[5~");
    sendKey(h.surface.get(), Qt::Key_PageDown);
    assert(h.fake->sends.back() == "\x1b[6~");
    sendKey(h.surface.get(), Qt::Key_Delete);
    assert(h.fake->sends.back() == "\x1b[3~");
    sendKey(h.surface.get(), Qt::Key_F5);
    assert(h.fake->sends.back() == "\x1b[15~");
    sendKey(h.surface.get(), Qt::Key_F12);
    assert(h.fake->sends.back() == "\x1b[24~");
}

void testUnhandledKeyIsNotSent() {
    Harness h;
    sendKey(h.surface.get(), Qt::Key_Control, Qt::ControlModifier);
    assert(h.fake->sends.empty());
}

void testResizeForwardsToTransport() {
    Harness h;
    h.surface->show();
    QCoreApplication::processEvents(QEventLoop::AllEvents);
    h.surface->resize(800, 400);
    QCoreApplication::processEvents(QEventLoop::AllEvents);
    assert(h.fake->resizeColumns == h.surface->columns());
    assert(h.fake->resizeRows == h.surface->rows());
    assert(h.fake->resizeColumns > 0);
    assert(h.fake->resizeRows > 0);
}

// Chrome parity: the default canvas background is the macOS terminal color
// (#121315), not pure black. The caret sits on cell (0,0), so sample the
// center of the widget.
void testCanvasBackgroundColor() {
    Harness h;
    h.surface->resize(400, 200);
    const QImage image = h.surface->grab().toImage();
    const QColor center = image.pixelColor(image.width() / 2, image.height() / 2);
    assert(center == QColor(0x12, 0x13, 0x15));
}

// Chrome parity: an explicit SGR background still wins over the canvas color
// on its cell (a space cell carries the red background; no glyph pixels).
void testExplicitCellBackgroundWins() {
    Harness h;
    h.fake->feed("\x1b[41m ");
    h.surface->resize(400, 200);
    const QImage image = h.surface->grab().toImage();
    const QColor cell00 = image.pixelColor(2, 2);  // interior of cell (0,0)
    assert(cell00.red() > cell00.green() + 40);
    assert(cell00.red() > cell00.blue() + 40);
}

} // namespace

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    testPrintableKeySendsText();
    testControlKeysMapToBytes();
    testNavigationKeysMapToCsi();
    testUnhandledKeyIsNotSent();
    testResizeForwardsToTransport();
    testCanvasBackgroundColor();
    testExplicitCellBackgroundWins();
    return 0;
}
