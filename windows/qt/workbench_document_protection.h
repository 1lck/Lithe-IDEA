#pragma once

#include <QMessageBox>

#include <cstddef>

namespace lithe::windows {

enum class DocumentTransitionDecision {
    Proceed,
    SaveThenProceed,
    Block,
};

inline DocumentTransitionDecision documentTransitionDecision(
    bool operationInProgress, std::size_t dirtyDocumentCount,
    QMessageBox::StandardButton choice = QMessageBox::Cancel) {
    if (operationInProgress) return DocumentTransitionDecision::Block;
    if (dirtyDocumentCount == 0) return DocumentTransitionDecision::Proceed;
    if (choice == QMessageBox::SaveAll) return DocumentTransitionDecision::SaveThenProceed;
    if (choice == QMessageBox::Discard) return DocumentTransitionDecision::Proceed;
    return DocumentTransitionDecision::Block;
}

inline DocumentTransitionDecision documentCloseDecision(
    bool operationInProgress, bool isDirty,
    QMessageBox::StandardButton choice = QMessageBox::Cancel) {
    if (operationInProgress) return DocumentTransitionDecision::Block;
    if (!isDirty) return DocumentTransitionDecision::Proceed;
    if (choice == QMessageBox::Save) return DocumentTransitionDecision::SaveThenProceed;
    if (choice == QMessageBox::Discard) return DocumentTransitionDecision::Proceed;
    return DocumentTransitionDecision::Block;
}

} // namespace lithe::windows
