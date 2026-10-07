import AppKit
import SwiftUI
import Testing
@testable import Lithe

/// Drives the searchable settings selector through a real window and real key
/// events.
///
/// Filtering, the popup height and the keyboard selection all live in one popup
/// state object, so a string-level test cannot show that typing narrows the list
/// or that Return applies the row the filter left highlighted. These tests use
/// the observable boundaries instead of private state: the popup frame, the
/// bound selection value and whether the popup is still on screen.
///
/// The empty-result placeholder copy is intentionally not asserted here: SwiftUI
/// draws `Text` without publishing it through an `NSView` string, so a view-tree
/// search would only test SwiftUI's internals. The behaviour that matters — the
/// popup collapses, stays open and applies nothing — is covered below, and the
/// visible copy belongs to the packaged-app visual check.
@Suite("Searchable settings select", .serialized)
@MainActor
struct SearchableSettingsSelectTests {
    @Test func filteringShrinksThePopupAndReturnAppliesTheFilteredRow() async throws {
        let session = try await SearchableSelectSession(
            options: ["Alpha Mono", "Beta Mono", "Gamma Sans"],
            selection: "Alpha Mono"
        )
        defer { session.tearDown() }

        let unfilteredHeight = try #require(session.popupHeight)
        #expect(unfilteredHeight > 0)

        try session.type("beta")
        #expect(
            await session.waitUntil { session.popupHeight.map { $0 < unfilteredHeight } ?? false },
            "filtering must shrink the popup to the remaining rows"
        )

        // The filter leaves exactly one row, and highlight follows the filtered
        // list, so Return applies that row without any arrow key.
        try session.sendKey(.returnKey)
        #expect(session.selection.value == "Beta Mono")
    }

    @Test func arrowKeysMoveWithinTheFilteredRows() async throws {
        let session = try await SearchableSelectSession(
            options: ["Alpha Mono", "Beta Mono", "Gamma Sans"],
            selection: "Alpha Mono"
        )
        defer { session.tearDown() }

        try session.type("mono")
        #expect(await session.waitUntil { (session.popupHeight ?? 0) > 0 })

        // Highlight starts on the selected row ("Alpha Mono"), so one Down lands
        // on the other match rather than on the first row of the full list.
        try session.sendKey(.downArrow)
        try session.sendKey(.returnKey)
        #expect(session.selection.value == "Beta Mono")
    }

    @Test func clearingTheQueryRestoresEveryRow() async throws {
        let session = try await SearchableSelectSession(
            options: ["Alpha Mono", "Beta Mono", "Gamma Sans"],
            selection: "Alpha Mono"
        )
        defer { session.tearDown() }

        let unfilteredHeight = try #require(session.popupHeight)

        try session.type("beta")
        #expect(
            await session.waitUntil { session.popupHeight.map { $0 < unfilteredHeight } ?? false },
            "filtering must shrink the popup"
        )

        try session.clearQuery()
        #expect(
            await session.waitUntil { session.popupHeight == unfilteredHeight },
            "clearing the field must restore every row, got \(String(describing: session.popupHeight))"
        )
    }

    @Test func noMatchKeepsThePopupUsableAndReturnChangesNothing() async throws {
        let session = try await SearchableSelectSession(
            options: ["Alpha Mono", "Beta Mono", "Gamma Sans"],
            selection: "Alpha Mono"
        )
        defer { session.tearDown() }

        let unfilteredHeight = try #require(session.popupHeight)

        try session.type("zzzz")
        #expect(
            await session.waitUntil { session.popupHeight.map { $0 < unfilteredHeight } ?? false },
            "a query with no match must collapse the popup instead of leaving empty rows"
        )

        // An empty filtered list must not apply anything.
        try session.sendKey(.returnKey)
        #expect(session.selection.value == "Alpha Mono")
        #expect(session.popupHeight != nil, "the popup stays open so the user can edit the query")
    }

    @Test func escapeDismissesTheSearchablePopup() async throws {
        let session = try await SearchableSelectSession(
            options: ["Alpha Mono", "Beta Mono", "Gamma Sans"],
            selection: "Alpha Mono"
        )
        defer { session.tearDown() }

        #expect(session.popupHeight != nil)
        try session.sendKey(.escape)
        #expect(
            await session.waitUntil { session.popupHeight == nil },
            "Escape must close the searchable popup"
        )
        #expect(session.selection.value == "Alpha Mono", "Escape must not apply anything")
    }

    /// While an input method composes text the navigation keys belong to the
    /// field editor, so Return must not commit a row and wipe the composition.
    @Test func composingTextKeepsNavigationKeysInTheFieldEditor() async throws {
        let session = try await SearchableSelectSession(
            options: ["Alpha Mono", "Beta Mono", "Gamma Sans"],
            selection: "Alpha Mono"
        )
        defer { session.tearDown() }

        let editor = try #require(session.searchEditor, "the search field must own the field editor")
        editor.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(editor.hasMarkedText())

        try session.sendKey(.returnKey)
        #expect(session.selection.value == "Alpha Mono", "a composing Return must not choose a row")
        #expect(session.popupHeight != nil, "the popup must stay open while composing")
    }
}

/// Owns the host window, the open popup and the events a test sends to it.
@MainActor
private final class SearchableSelectSession {
    final class Selection {
        var value: String
        init(_ value: String) { self.value = value }
    }

    enum Key: UInt16 {
        case returnKey = 36
        case escape = 53
        case downArrow = 125
        case upArrow = 126

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .escape: "\u{1b}"
            case .downArrow: "\u{f701}"
            case .upArrow: "\u{f700}"
            }
        }
    }

    let selection: Selection
    private let options: [String]
    private let window: NSWindow
    private let host: NSHostingView<AnyView>

    init(options: [String], selection: String) async throws {
        self.options = options
        self.selection = Selection(selection)

        let box = self.selection
        let select = LitheSettingsSelect(
            selection: Binding(get: { box.value }, set: { box.value = $0 }),
            options: options,
            width: 200,
            accessibilityLabel: "Font",
            title: { $0 },
            localizesTitles: false,
            searchPrompt: "Search fonts",
            searchText: { $0 }
        )
        .frame(width: 280, height: 120, alignment: .topLeading)

        host = NSHostingView(rootView: AnyView(select))
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        try clickTrigger()
        let opened = await waitUntil { self.popupPanel != nil }
        guard opened else {
            tearDown()
            throw SearchableSelectSessionError.popupDidNotOpen
        }
    }

    var popupHeight: CGFloat? { popupPanel?.frame.height }

    var searchEditor: NSTextView? {
        guard let field = searchField, let editor = field.currentEditor() as? NSTextView else { return nil }
        return editor
    }

    func type(_ text: String) throws {
        let editor = try requireEditor()
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func clearQuery() throws {
        let editor = try requireEditor()
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
    }

    func sendKey(_ key: Key) throws {
        guard let panel = popupPanel else { throw SearchableSelectSessionError.popupClosed }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.rawValue
        ) else { throw SearchableSelectSessionError.eventCreationFailed }
        NSApp.sendEvent(event)
    }

    @discardableResult
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    func tearDown() {
        if popupPanel != nil {
            try? sendKey(.escape)
        }
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Internals

    private var popupPanel: NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && NSStringFromClass(Swift.type(of: $0)).hasSuffix("LitheSettingsSelectPopupPanel")
        }
    }

    private var searchField: NSTextField? {
        guard let content = popupPanel?.contentView else { return nil }
        return Self.firstEditableField(in: content)
    }

    private func requireEditor() throws -> NSTextView {
        guard let editor = searchEditor else { throw SearchableSelectSessionError.searchFieldNotFocused }
        return editor
    }

    private func clickTrigger() throws {
        let point = NSPoint(x: 100, y: host.isFlipped ? 14 : host.bounds.height - 14)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { throw SearchableSelectSessionError.eventCreationFailed }
            NSApp.sendEvent(event)
        }
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        return view.subviews.lazy.compactMap { firstEditableField(in: $0) }.first
    }

    enum SearchableSelectSessionError: Error {
        case popupDidNotOpen
        case popupClosed
        case searchFieldNotFocused
        case eventCreationFailed
    }
}
