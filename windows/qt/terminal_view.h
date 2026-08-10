#pragma once

#include "terminal_model.h"
#include "terminal_surface.h"

#include <QString>
#include <QWidget>

namespace lithe::windows::app {
class TerminalModel;
}

// Renders a single terminal session: a TerminalSurface bound to the session's
// emulator. The view itself holds no terminal state — refresh() asks the
// surface to re-read the emulator (the session remains the single source of
// truth; the UI only renders and forwards input).
class TerminalView : public QWidget {
    Q_OBJECT

public:
    explicit TerminalView(QWidget* parent = nullptr);

    void bind(lithe::windows::app::TerminalModel* model, const QString& sessionId);
    void refresh();
    void requestInputFocus();
    QString sessionId() const { return sessionId_; }
    QString text() const;

private:
    lithe::windows::app::TerminalModel* model_ = nullptr;
    QString sessionId_;
    TerminalSurface* surface_;
};
