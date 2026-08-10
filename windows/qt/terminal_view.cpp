#include "terminal_view.h"

#include "terminal_model.h"
#include "terminal_session.h"

#include <QFont>
#include <QFontDatabase>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QVBoxLayout>

TerminalView::TerminalView(QWidget* parent)
    : QWidget(parent), output_(new QPlainTextEdit(this)), input_(new QLineEdit(this)) {
    output_->setReadOnly(true);
    output_->setLineWrapMode(QPlainTextEdit::NoWrap);
    output_->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    input_->setPlaceholderText(TerminalView::tr("Enter terminal command"));

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    layout->addWidget(output_);
    layout->addWidget(input_);

    connect(input_, &QLineEdit::returnPressed, this, &TerminalView::submitInput);
}

void TerminalView::bind(lithe::windows::app::TerminalModel* model, const QString& sessionId) {
    model_ = model;
    sessionId_ = sessionId;
    refresh();
}

void TerminalView::refresh() {
    if (!model_ || sessionId_.isEmpty()) {
        output_->clear();
        return;
    }
    const auto* session = model_->find(sessionId_.toStdString());
    if (session == nullptr) {
        output_->clear();
        return;
    }
    // Cap the rendered snapshot so a runaway buffer never copies an unbounded
    // payload into the widget on each refresh.
    output_->setPlainText(QString::fromStdString(session->render(65536)));
}

QString TerminalView::text() const {
    return output_->toPlainText();
}

void TerminalView::submitInput() {
    if (!model_ || sessionId_.isEmpty()) return;
    const auto text = input_->text();
    input_->clear();
    if (text.isEmpty()) return;
    model_->send(sessionId_.toStdString(), (text + "\r\n").toStdString());
}
