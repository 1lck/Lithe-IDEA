import AppKit
import Combine
import Testing
import WebKit
@testable import Lithe

/// The application keymap reads a key press before AppKit offers it to any view, so a
/// focused HTML preview page keeps its own find, zoom and print chords only if the
/// keymap steps aside for them.
@MainActor
@Suite("HTML preview page shortcut policy")
struct HTMLPreviewPageShortcutPolicyTests {
    private typealias Chord = (key: String, modifiers: NSEvent.ModifierFlags)

    private func makePage() -> HTMLPreviewWebViewSurface {
        HTMLPreviewWebViewSurface(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: WKWebViewConfiguration()
        )
    }

    private func defers(_ responder: NSResponder?, _ chord: Chord) -> Bool {
        MacShortcutInputPolicy.shouldDeferToPreviewPage(
            responder,
            charactersIgnoringModifiers: chord.key,
            modifierFlags: chord.modifiers
        )
    }

    @Test
    func focusedPageDefersEveryChordItAnswers() {
        let page = makePage()
        let chords: [Chord] = [
            ("f", .command), ("g", .command), ("G", [.command, .shift]), ("p", .command),
            ("=", .command), ("+", [.command, .shift]), ("-", .command), ("0", .command),
            // Caps Lock upper-cases the letter without changing the shortcut.
            ("F", [.command, .capsLock])
        ]
        for chord in chords {
            #expect(defers(page, chord), "\(chord.modifiers) \(chord.key) must reach the focused page")
        }
    }

    @Test
    func chordsThePageDoesNotAnswerStayWithTheKeymap() {
        let page = makePage()
        let chords: [Chord] = [
            ("s", .command), ("o", .command), (",", .command), ("w", [.command, .shift]),
            // Search in project and similar commands keep their ⇧⌘ chords.
            ("f", [.command, .shift]), ("p", [.command, .shift]),
            ("f", [.command, .option]), ("g", [.command, .control]), ("f", .control),
            // Typing into the page is not a shortcut.
            ("f", []), ("p", [])
        ]
        for chord in chords {
            #expect(!defers(page, chord), "\(chord.modifiers) \(chord.key) belongs to the application keymap")
        }
        #expect(HTMLPreviewPageShortcut(charactersIgnoringModifiers: nil, modifierFlags: .command) == nil)
    }

    @Test
    func viewsInsideThePageCountAsThePage() {
        let page = makePage()
        let inner = NSView(frame: .zero)
        let deeper = NSView(frame: .zero)
        page.addSubview(inner)
        inner.addSubview(deeper)
        // WebKit keeps views of its own inside the web view and focuses one of them.
        #expect(defers(inner, ("f", .command)))
        #expect(defers(deeper, ("f", .command)))
        #expect(HTMLPreviewWebViewSurface.containing(deeper) === page)
    }

    @Test
    func respondersOutsideThePageKeepTheKeymap() {
        let page = makePage()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let findField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        host.addSubview(page)
        host.addSubview(findField)
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))

        // The page's own parent and its sibling views are not the page.
        let outside: [NSView] = [host, findField, editor, terminal]
        for responder in outside {
            #expect(!defers(responder, ("f", .command)), "\(type(of: responder)) is not the page")
        }
        #expect(!defers(nil, ("f", .command)))
    }
}

/// Drives the real key monitor with a real preview page in the window, through
/// `NSApplication.sendEvent` as AppKit does, so the monitor's own use of the policy is
/// covered and not only the policy.
@MainActor
@Suite("HTML preview page shortcuts through the key monitor")
struct HTMLPreviewPageShortcutMonitorTests {
    private typealias Chord = (key: String, modifiers: NSEvent.ModifierFlags)

    /// The keymap commands the monitor dispatched, in order, observable without sleeping.
    @MainActor
    private final class KeymapCommands: ObservableObject {
        private(set) var ids: [String] = []

        func record(_ id: String) {
            ids.append(id)
            objectWillChange.send()
        }

        func waitForCount(_ count: Int) async -> Bool {
            await waitForChanges([objectWillChange.eraseToAnyPublisher()], timeout: .seconds(5)) { [self] in
                ids.count >= count
            }
        }
    }

    /// Every chord the focused page answers, with the keymap command bound to it below.
    private static let pageChords: [(chord: Chord, commandID: String)] = [
        (("f", .command), "find-in-file"),
        (("g", .command), "find-next"),
        (("G", [.command, .shift]), "find-previous"),
        (("p", .command), "custom-print"),
        (("=", .command), "custom-zoom-in"),
        (("-", .command), "custom-zoom-out"),
        (("0", .command), "custom-zoom-reset")
    ]

    /// The default bindings of the find commands the page's chords collide with, ⌘S as the
    /// chord only the keymap answers, and the print and zoom chords a customized keymap can
    /// bind. Nothing else is bound, so the monitor leaves other tests' key presses alone.
    private static var registrations: [KeyboardShortcutRegistration] {
        let preset = KeyboardShortcutPreset.macOS
        let defaults = LitheCommandCatalog.commands
            .filter { ["find-in-file", "find-next", "find-previous", "save"].contains($0.id) }
            .map { KeyboardShortcutRegistration(commandID: $0.id, bindings: preset.bindings(for: $0)) }
        let customized = [
            KeyboardShortcutRegistration(commandID: "custom-print", bindings: [.keyPress(key: "p", modifiers: [.command])]),
            KeyboardShortcutRegistration(commandID: "custom-zoom-in", bindings: [.keyPress(key: "=", modifiers: [.command])]),
            KeyboardShortcutRegistration(commandID: "custom-zoom-out", bindings: [.keyPress(key: "-", modifiers: [.command])]),
            KeyboardShortcutRegistration(commandID: "custom-zoom-reset", bindings: [.keyPress(key: "0", modifiers: [.command])])
        ]
        return defaults + customized
    }

    @Test
    func focusedPageKeepsTheChordsTheKeymapBinds() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        let page = try #require(harness.webView as? HTMLPreviewWebViewSurface)
        var zooms: [HTMLPreviewZoom.Command] = []
        var finds: [HTMLPreviewFind.Command] = []
        var prints: [HTMLPreviewPrint.Command] = []
        page.onZoomCommand = { zooms.append($0) }
        page.onFindCommand = { finds.append($0) }
        page.onPrintCommand = { prints.append($0) }
        // In the app the editor sits beside the preview.
        let editorStandIn = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        harness.window.contentView?.addSubview(editorStandIn)
        #expect(harness.window.makeFirstResponder(page))

        func event(_ chord: Chord) -> NSEvent {
            harness.keyEvent(chord.key, modifiers: chord.modifiers)
        }
        func pressEveryPageChord() {
            for entry in Self.pageChords { NSApplication.shared.sendEvent(event(entry.chord)) }
        }

        // The page answers each chord of the list. The test host never makes its window the
        // key window, so AppKit would not offer these events to the page; ask it directly.
        for entry in Self.pageChords {
            #expect(page.performKeyEquivalent(with: event(entry.chord)), "The focused page ignored \(entry.chord.key)")
        }
        #expect(finds == [.show, .next, .previous])
        #expect(prints == [.print])
        #expect(zooms == [.zoomIn, .zoomOut, .reset])

        let keymap = KeymapCommands()
        let detector = MacShortcutDetectorFactory().make { keymap.record($0) }
        defer { detector.stop() }
        detector.update(registrations: Self.registrations)
        detector.start()

        // With the page focused, the keymap stays out of its chords. ⌘S is only the keymap's,
        // which shows the monitor is live; commands arrive in press order, so a page chord the
        // monitor consumed would be listed before "save".
        pressEveryPageChord()
        NSApplication.shared.sendEvent(event(("s", .command)))
        try #require(await keymap.waitForCount(1), "The keymap never received ⌘S")
        try #require(keymap.ids == ["save"], "The keymap took chords from the focused page: \(keymap.ids)")

        // Typed anywhere else, the same chords are the keymap's. That is the collision the
        // monitor has to settle in the page's favour, and it is real.
        #expect(harness.window.makeFirstResponder(editorStandIn))
        pressEveryPageChord()
        let expected = Self.pageChords.map(\.commandID)
        try #require(
            await keymap.waitForCount(1 + expected.count),
            "The keymap never received the page chords typed outside the page: \(keymap.ids)"
        )
        #expect(keymap.ids.dropFirst().sorted() == expected.sorted())
    }
}
