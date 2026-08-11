#include "terminal_view.h"

#include "terminal_model.h"
#include "terminal_surface.h"

#include <QColor>
#include <QPalette>
#include <QVBoxLayout>

TerminalView::TerminalView(QWidget* parent)
    : QWidget(parent), surface_(new TerminalSurface(this)) {
    // Mac canvas: the surface floats inside 8px of padding on the terminal's
    // dark background (#121315, macOS nativeBackgroundColor).
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(0);
    layout->addWidget(surface_);
    QPalette canvasPalette = palette();
    canvasPalette.setColor(QPalette::Window, QColor(0x12, 0x13, 0x15));
    setPalette(canvasPalette);
    setAutoFillBackground(true);
}

void TerminalView::bind(lithe::windows::app::TerminalModel* model, const QString& sessionId) {
    model_ = model;
    sessionId_ = sessionId;
    surface_->bind(model, sessionId);
    refresh();
}

void TerminalView::refresh() {
    surface_->refresh();
}

void TerminalView::requestInputFocus() {
    surface_->setFocus();
}

QString TerminalView::text() const {
    return surface_->text();
}
