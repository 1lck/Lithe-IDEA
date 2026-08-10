#include "terminal_surface.h"

#include "terminal_emulator.h"
#include "terminal_keys.h"
#include "terminal_model.h"
#include "terminal_session.h"

#include <QClipboard>
#include <QColor>
#include <QFontDatabase>
#include <QFontMetrics>
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QPainter>
#include <QResizeEvent>
#include <QScrollBar>
#include <QWheelEvent>

#include <algorithm>
#include <string>
#include <utility>

namespace {

// Default cell colors used when a cell carries no explicit SGR color. The
// background matches the macOS terminal canvas (nativeBackgroundColor
// 0.071/0.075/0.081); explicit SGR backgrounds are painted per cell.
QColor backgroundColor() { return QColor(0x12, 0x13, 0x15); }
QColor foregroundColor() { return QColor(0xff, 0xff, 0xff); }
QColor caretColor() { return QColor(0xe8, 0xe8, 0xe8); }

int cellWidthFor(const QFontMetrics& fm) {
    return fm.horizontalAdvance(QLatin1Char('W'));
}

int cellHeightFor(const QFontMetrics& fm) {
    return fm.height();
}

} // namespace

TerminalSurface::TerminalSurface(QWidget* parent)
    : QWidget(parent), scrollbar_(new QScrollBar(Qt::Vertical, this)) {
    setFocusPolicy(Qt::StrongFocus);
    setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    scrollbar_->setRange(0, 0);
    connect(scrollbar_, &QScrollBar::valueChanged, this, &TerminalSurface::onScrollbarChanged);
}

void TerminalSurface::bind(lithe::windows::app::TerminalModel* model, const QString& sessionId) {
    model_ = model;
    sessionId_ = sessionId;
    refresh();
}

void TerminalSurface::refresh() {
    updateScrollbar();
    update();
}

QString TerminalSurface::text() const {
    const auto* s = session();
    if (s == nullptr) return {};
    return QString::fromStdString(s->render(65536));
}

int TerminalSurface::columns() const {
    const int cw = cellWidthFor(fontMetrics());
    return cw <= 0 ? 1 : std::max(1, contentWidth() / cw);
}

int TerminalSurface::rows() const {
    const int ch = cellHeightFor(fontMetrics());
    return ch <= 0 ? 1 : std::max(1, height() / ch);
}

QSize TerminalSurface::sizeHint() const {
    const QFontMetrics fm = fontMetrics();
    return QSize(lithe::windows::algorithms::TerminalEmulator::DefaultColumns * cellWidthFor(fm),
                 lithe::windows::algorithms::TerminalEmulator::DefaultRows * cellHeightFor(fm));
}

lithe::windows::app::TerminalSession* TerminalSurface::session() const {
    if (model_ == nullptr || sessionId_.isEmpty()) return nullptr;
    return model_->find(sessionId_.toStdString());
}

int TerminalSurface::contentWidth() const {
    return std::max(0, width() - scrollbar_->sizeHint().width());
}

void TerminalSurface::sendBytes(const QByteArray& bytes) {
    if (auto* s = session()) s->send(bytes.toStdString());
}

void TerminalSurface::updateScrollbar() {
    const auto* s = session();
    if (s == nullptr) {
        scrollbar_->setRange(0, 0);
        return;
    }
    const auto& emulator = s->emulator();
    const int count = emulator.scrollbackLineCount();
    const int offset = emulator.scrollOffset();
    // Scrollbar value 0 = oldest scrollback, max = live bottom. The emulator's
    // offset is 0 at the bottom, so the scrollbar value is count - offset.
    scrollbar_->setRange(0, count);
    scrollbar_->setValue(count - offset);
}

void TerminalSurface::onScrollbarChanged(int value) {
    if (auto* s = session()) s->setScrollOffset(scrollbar_->maximum() - value);
    update();
}

void TerminalSurface::paintEvent(QPaintEvent*) {
    QPainter painter(this);
    const auto* s = session();
    if (s == nullptr) {
        painter.fillRect(rect(), backgroundColor());
        return;
    }
    const auto& emulator = s->emulator();
    const QFontMetrics fm = fontMetrics();
    const int cw = cellWidthFor(fm);
    const int ch = cellHeightFor(fm);
    if (cw <= 0 || ch <= 0) return;

    const int viewRows = std::min(emulator.rows(), std::max(0, height() / ch));
    const int viewCols = std::min(emulator.cols(), std::max(0, contentWidth() / cw));
    const int firstDisplayRow = emulator.scrollbackLineCount() - emulator.scrollOffset();

    painter.fillRect(rect(), backgroundColor());

    for (int row = 0; row < viewRows; ++row) {
        for (int col = 0; col < viewCols; ++col) {
            drawCell(painter, emulator.cell(firstDisplayRow + row, col), row, col, cw, ch);
        }
    }

    // The caret lives on the visible screen; it is off-viewport when scrolled up.
    if (emulator.cursorVisible() && emulator.scrollOffset() == 0) {
        painter.fillRect(QRect(emulator.cursorCol() * cw, emulator.cursorRow() * ch, cw, ch),
                         caretColor());
    }
}

void TerminalSurface::drawCell(QPainter& painter,
                               const lithe::windows::algorithms::TerminalCell& cell,
                               int row, int col, int cellWidth, int cellHeight) {
    const int x = col * cellWidth;
    const int y = row * cellHeight;
    QColor fg = cell.fgDefault ? foregroundColor()
                               : QColor(cell.fgRed, cell.fgGreen, cell.fgBlue);
    QColor bg = cell.bgDefault ? backgroundColor()
                               : QColor(cell.bgRed, cell.bgGreen, cell.bgBlue);
    if (cell.reverse) std::swap(fg, bg);

    if (!cell.bgDefault || cell.reverse) {
        painter.fillRect(x, y, cellWidth, cellHeight, bg);
    }

    if (cell.glyph.empty() || cell.conceal) return;

    if (cell.bold || cell.italic || cell.underline || cell.strike) {
        QFont f = painter.font();
        if (cell.bold) f.setWeight(QFont::Bold);
        if (cell.italic) f.setItalic(true);
        if (cell.underline) f.setUnderline(true);
        if (cell.strike) f.setStrikeOut(true);
        painter.setFont(f);
    } else {
        painter.setFont(font());
    }
    painter.setPen(fg);
    const int glyphWidth = cell.width == 2 ? 2 * cellWidth : cellWidth;
    painter.drawText(QRect(x, y, glyphWidth, cellHeight),
                     Qt::AlignLeft | Qt::AlignVCenter,
                     QString::fromUtf8(cell.glyph));
}

void TerminalSurface::keyPressEvent(QKeyEvent* event) {
    // Ctrl+V is paste (the conventional Windows terminal binding), ahead of the
    // literal 0x16 control byte the raw translation would produce.
    if (event->modifiers() == Qt::ControlModifier && event->key() == Qt::Key_V) {
        const QString text = QGuiApplication::clipboard()->text();
        if (!text.isEmpty()) sendBytes(text.toUtf8());
        event->accept();
        return;
    }
    std::string bytes;
    if (lithe::windows::qt::translateKeyEvent(*event, bytes)) {
        sendBytes(QByteArray(bytes.data(), static_cast<int>(bytes.size())));
        event->accept();
        return;
    }
    QWidget::keyPressEvent(event);
}

void TerminalSurface::inputMethodEvent(QInputMethodEvent* event) {
    const QString commit = event->commitString();
    if (!commit.isEmpty()) sendBytes(commit.toUtf8());
    event->accept();
}

void TerminalSurface::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    const int sb = scrollbar_->sizeHint().width();
    scrollbar_->setGeometry(width() - sb, 0, sb, height());
    const int cols = columns();
    const int rows = this->rows();
    if (cols != lastColumns_ || rows != lastRows_) {
        lastColumns_ = cols;
        lastRows_ = rows;
        if (auto* s = session()) s->resize(cols, rows);
    }
    updateScrollbar();
    update();
}

void TerminalSurface::wheelEvent(QWheelEvent* event) {
    if (auto* s = session()) {
        // Each wheel notch scrolls three lines into the scrollback.
        s->scrollBy(-(event->angleDelta().y() / 120) * 3);
        updateScrollbar();
        update();
        event->accept();
        return;
    }
    QWidget::wheelEvent(event);
}
