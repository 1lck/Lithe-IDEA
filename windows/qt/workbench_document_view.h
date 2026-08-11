#pragma once

#include <QPlainTextEdit>
#include <QScrollBar>
#include <QTextCursor>

#include <algorithm>

namespace lithe::windows {

inline void replaceDocumentTextPreservingView(QPlainTextEdit& editor,
                                               const QString& nextText) {
    if (editor.toPlainText() == nextText) return;
    const auto previousCursor = editor.textCursor();
    const auto previousAnchor = previousCursor.anchor();
    const auto previousPosition = previousCursor.position();
    const auto verticalScroll = editor.verticalScrollBar()->value();
    const auto horizontalScroll = editor.horizontalScrollBar()->value();
    editor.setPlainText(nextText);
    const auto maximum = std::max(0, editor.document()->characterCount() - 1);
    QTextCursor restoredCursor(editor.document());
    restoredCursor.setPosition(std::clamp(previousAnchor, 0, maximum));
    restoredCursor.setPosition(std::clamp(previousPosition, 0, maximum),
                               QTextCursor::KeepAnchor);
    editor.setTextCursor(restoredCursor);
    editor.verticalScrollBar()->setValue(verticalScroll);
    editor.horizontalScrollBar()->setValue(horizontalScroll);
}

} // namespace lithe::windows
