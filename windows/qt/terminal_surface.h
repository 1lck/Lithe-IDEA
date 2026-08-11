#pragma once

#include <QSize>
#include <QString>
#include <QWidget>

class QByteArray;
class QPainter;
class QScrollBar;

namespace lithe::windows::algorithms {
struct TerminalCell;
}
namespace lithe::windows::app {
class TerminalModel;
class TerminalSession;
}

// A grid terminal surface. It renders one session's TerminalEmulator cell grid
// (glyph + SGR colors + bold/inverse + caret) with QPainter, translates
// keystrokes/IME/paste into input bytes, resizes the PTY with the widget, and
// owns a vertical scrollbar for scrollback. It holds no terminal state itself —
// it reads the emulator owned by the session and forwards input to it.
class TerminalSurface : public QWidget {
    Q_OBJECT

public:
    explicit TerminalSurface(QWidget* parent = nullptr);

    void bind(lithe::windows::app::TerminalModel* model, const QString& sessionId);
    // Re-reads the session's emulator (called on the panel's queued refresh).
    void refresh();

    QString sessionId() const { return sessionId_; }
    // Plain-text snapshot of the session's visible screen, for tests.
    QString text() const;

    // Cell geometry computed from the current size and font metrics.
    int columns() const;
    int rows() const;

    QSize sizeHint() const override;

protected:
    void paintEvent(QPaintEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void inputMethodEvent(QInputMethodEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void wheelEvent(QWheelEvent* event) override;

private:
    lithe::windows::app::TerminalModel* model_ = nullptr;
    QString sessionId_;
    QScrollBar* scrollbar_ = nullptr;
    int lastColumns_ = 0;
    int lastRows_ = 0;

    lithe::windows::app::TerminalSession* session() const;
    int contentWidth() const;
    void sendBytes(const QByteArray& bytes);
    void updateScrollbar();
    void onScrollbarChanged(int value);
    void drawCell(QPainter& painter, const lithe::windows::algorithms::TerminalCell& cell,
                  int row, int col, int cellWidth, int cellHeight);
};
