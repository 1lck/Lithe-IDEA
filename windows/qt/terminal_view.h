#pragma once

#include "terminal_model.h"

#include <QString>
#include <QWidget>

class QPlainTextEdit;
class QLineEdit;

namespace lithe::windows::app {
class TerminalModel;
}

// Renders a single terminal session: a read-only bounded output area backed by
// the model's TerminalBuffer, plus a line input. The view itself holds no
// terminal state — refresh() reads a snapshot from the model so the model
// remains the single source of truth (the UI only renders and forwards input).
class TerminalView : public QWidget {
    Q_OBJECT

public:
    explicit TerminalView(QWidget* parent = nullptr);

    void bind(lithe::windows::app::TerminalModel* model, const QString& sessionId);
    void refresh();
    QString sessionId() const { return sessionId_; }
    QString text() const;

private slots:
    void submitInput();

private:
    lithe::windows::app::TerminalModel* model_ = nullptr;
    QString sessionId_;
    QPlainTextEdit* output_;
    QLineEdit* input_;
};
