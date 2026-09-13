import AppKit
import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Editor line editing shortcuts")
struct LineEditingShortcutTests {
    private func keyDownEvent(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func shortcut(for event: NSEvent) -> CodeTextView.LineEditingAction? {
        CodeTextView.lineEditingShortcut(
            modifiers: event.modifierFlags,
            character: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        )
    }

    /// Regression: arrow keys are function keys and their events carry the
    /// `.function` flag (and `.numericPad` for keypad keys); strict equality
    /// against `[.option, .shift]` never matched, so the shortcuts fell
    /// through to the system paragraph-selection behavior.
    @Test
    func optionShiftArrowsMatchDespiteFunctionFlag() {
        let up = keyDownEvent(
            modifierFlags: [.function, .option, .shift],
            keyCode: 126,
            characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}"
        )
        #expect(shortcut(for: up) == .moveUp)

        let down = keyDownEvent(
            modifierFlags: [.function, .numericPad, .option, .shift],
            keyCode: 125,
            characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}"
        )
        #expect(shortcut(for: down) == .moveDown)
    }

    /// Regression: with Caps Lock enabled the events also carry `.capsLock`;
    /// the matcher must keep matching all three shortcuts.
    @Test
    func shortcutsMatchWithCapsLockEngaged() {
        let slash = keyDownEvent(
            modifierFlags: [.capsLock, .command],
            keyCode: 44,
            characters: "/",
            charactersIgnoringModifiers: "/"
        )
        #expect(shortcut(for: slash) == .toggleLineComment)

        let duplicate = keyDownEvent(
            modifierFlags: [.capsLock, .command],
            keyCode: 2,
            characters: "d",
            charactersIgnoringModifiers: "d"
        )
        #expect(shortcut(for: duplicate) == .duplicate)

        let moveUp = keyDownEvent(
            modifierFlags: [.capsLock, .function, .option, .shift],
            keyCode: 126,
            characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}"
        )
        #expect(shortcut(for: moveUp) == .moveUp)

        let moveDown = keyDownEvent(
            modifierFlags: [.capsLock, .function, .numericPad, .option, .shift],
            keyCode: 125,
            characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}"
        )
        #expect(shortcut(for: moveDown) == .moveDown)
    }

    @Test
    func commandSlashAndCommandDMatchWithoutExtraFlags() {
        #expect(
            CodeTextView.lineEditingShortcut(
                modifiers: .command,
                character: "/",
                keyCode: 44
            ) == .toggleLineComment
        )
        #expect(
            CodeTextView.lineEditingShortcut(
                modifiers: .command,
                character: "d",
                keyCode: 2
            ) == .duplicate
        )
    }

    @Test
    func nonMatchingCombinationsReturnNil() {
        // Only Shift or only Option keeps the system arrow behavior.
        #expect(
            CodeTextView.lineEditingShortcut(
                modifiers: [.function, .shift],
                character: "\u{F700}",
                keyCode: 126
            ) == nil
        )
        #expect(
            CodeTextView.lineEditingShortcut(
                modifiers: [.function, .option],
                character: "\u{F700}",
                keyCode: 126
            ) == nil
        )
        // Unmodified arrows stay with the system.
        #expect(
            CodeTextView.lineEditingShortcut(
                modifiers: [.function],
                character: "\u{F700}",
                keyCode: 126
            ) == nil
        )
        // Other command chords stay with the system.
        #expect(
            CodeTextView.lineEditingShortcut(
                modifiers: .command,
                character: "x",
                keyCode: 7
            ) == nil
        )
    }
}

@MainActor
@Suite("Editor line editing coordinator")
struct EditorLineEditingCoordinatorTests {
    private struct FakeLineEditing: EditorLineEditing {
        let token: String?

        func lineEdit(
            _: EditorLineEditOperation,
            source _: String,
            selection _: NSRange
        ) -> EditorLineEditResult? {
            nil
        }

        func lineCommentToken(forIdentifier _: String) -> String? {
            token
        }
    }

    /// Thread-safe recorder for the queried identifier.
    private final class IdentifierRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func record(_ identifier: String) {
            lock.lock()
            defer { lock.unlock() }
            value = identifier
        }

        var recorded: String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct RecordingLineEditing: EditorLineEditing {
        let recorder: IdentifierRecorder
        let token: String?

        func lineEdit(
            _: EditorLineEditOperation,
            source _: String,
            selection _: NSRange
        ) -> EditorLineEditResult? {
            nil
        }

        func lineCommentToken(forIdentifier identifier: String) -> String? {
            recorder.record(identifier)
            return token
        }
    }

    /// Regression: the comment token was cached once in makeNSView, so
    /// renaming an open document (relocate(to:) updates the URL in place
    /// while the editor keeps the same document id) left the old extension's
    /// token active. The token must be resolved from the current name at
    /// action time.
    @Test
    func renamedDocumentResolvesTokenFromCurrentExtension() {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/Foo.swift"),
            text: "",
            modificationDate: nil
        )

        let swiftToken = CodeEditorView.Coordinator.lineCommentToken(
            for: document,
            using: FakeLineEditing(token: "//")
        )
        #expect(swiftToken == "//")

        document.relocate(to: URL(fileURLWithPath: "/tmp/Foo.py"))

        let pythonToken = CodeEditorView.Coordinator.lineCommentToken(
            for: document,
            using: FakeLineEditing(token: "#")
        )
        #expect(pythonToken == "#")
    }

    /// Regression: Foundation reports an empty pathExtension for dotfiles,
    /// so the coordinator must pass the full last path component and Core
    /// resolves the basename (`.env` → `#`).
    @Test
    func dotfileDocumentResolvesTokenThroughBasename() {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/.env"),
            text: "",
            modificationDate: nil
        )

        let recorder = IdentifierRecorder()
        let recording = RecordingLineEditing(recorder: recorder, token: "#")
        let token = CodeEditorView.Coordinator.lineCommentToken(
            for: document,
            using: recording
        )

        #expect(token == "#")
        #expect(recorder.recorded == ".env")
    }
}
