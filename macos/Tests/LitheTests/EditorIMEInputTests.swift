import AppKit
import SwiftUI
import Testing
@testable import Lithe

/// Regression coverage for AppKit marked-text edits from Chinese/Japanese/Korean IMEs.
@MainActor
@Suite("Editor IME input")
struct EditorIMEInputTests {
    @Test
    func markedTextDefersKeyAndModifierShortcuts() {
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        #expect(view.hasMarkedText())
        #expect(MacShortcutInputPolicy.shouldDeferToMarkedText(view))

        view.unmarkText()
        #expect(!MacShortcutInputPolicy.shouldDeferToMarkedText(view))
    }

    @Test(arguments: ["ni", "nihao"])
    func inputMethodCommitPreservesFollowingCode(pinyin: String) throws {
        let store = IMEInputTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let source = "// 🚀\npublic record Test {}"
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/IME.java"), text: source, modificationDate: nil)
        let coordinator = CodeEditorView.Coordinator(
            document: document, model: model, isDarkAppearance: true, colorTheme: .lithe,
            markdownScrollPosition: nil, viewportStore: EditorViewportStore()
        )
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.string = source
        view.rebuildLineIndex()
        view.delegate = coordinator
        coordinator.textView = view
        defer { view.delegate = nil }
        let offset = ("// 🚀\n" as NSString).length
        view.setSelectedRange(NSRange(location: offset, length: 0))

        // AppKit emits multiple shouldChange callbacks for marked text,
        // then only one textDidChange when the input method commits.
        for count in 1...pinyin.count {
            let marked = String(pinyin.prefix(count))
            view.setMarkedText(marked, selectedRange: NSRange(location: count, length: 0),
                               replacementRange: count == 1
                                   ? NSRange(location: offset, length: 0)
                                   : NSRange(location: NSNotFound, length: 0))
        }
        view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(view.string == "// 🚀\n你好public record Test {}")
        #expect(document.text == view.string)
        #expect(view.selectedRange() == NSRange(location: offset + 2, length: 0))
        let changes = document.takePendingLanguageServerChanges()
        #expect(changes.count == 1)
        #expect(changes.first?.start.utf16Column == 0)
        #expect(changes.first?.end.utf16Column == 0)
        #expect(changes.first?.text == "你好")
    }
}

private final class IMEInputTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
