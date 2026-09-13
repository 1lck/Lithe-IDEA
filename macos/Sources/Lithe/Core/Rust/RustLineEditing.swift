import Foundation

/// Rust Core-backed implementation of the line-editing port. The transforms
/// themselves live in `rust/lithe-core/src/editor`; this adapter only encodes
/// the request and maps the JSON outcome back into the port's result type.
struct RustLineEditing: EditorLineEditing {
    private let core: RustCoreBridge

    init(core: RustCoreBridge = RustCoreBridge()) {
        self.core = core
    }

    func lineEdit(
        _ operation: EditorLineEditOperation,
        source: String,
        selection: NSRange
    ) -> EditorLineEditResult? {
        core.editorLineEdit(operation, source: source, selection: selection)
    }

    func lineCommentToken(forIdentifier identifier: String) -> String? {
        core.editorLineCommentToken(forIdentifier: identifier)
    }
}
