import AppKit
import LitheLocalHistoryModule
import SwiftUI
import Testing
@testable import Lithe

@Suite("Local history settings", .serialized)
@MainActor
struct LocalHistorySettingsTests {
    @Test(arguments: ["1e3", "-1000", "50abc00", "10.5", "+100", "", "MB", "100 MiB", "100 MB extra",
                      "999999999999999999999999999999"])
    func invalidLimitInputDoesNotBecomeAnotherNumber(input: String) {
        #expect(AppSettings.parseLocalHistoryStorageLimitMegabytes(input) == nil)
    }

    @Test(arguments: [("100", 100), ("100 MB", 100), (" 250 mb ", 250), ("1000MB", 1000), ("0", 0)])
    func wholeNumbersAcceptOnlyTheOptionalDisplayedUnit(input: String, expected: Int) {
        #expect(AppSettings.parseLocalHistoryStorageLimitMegabytes(input) == expected)
    }

    @Test(arguments: [("1e3", 100), ("-1000", 100), ("50abc00", 100), ("999999999999999999999999", 100),
                      ("250 MB", 250), ("6000", 5000), ("0", 50)], [false, true])
    func nativeLimitCommitRestoresInvalidDraftOrClampsValidInput(
        input: (String, Int), submit: Bool
    ) async throws {
        let form = HistoryLimitForm()
        defer { form.close() }
        try await form.waitFor("initial value") { form.field?.stringValue == "100 MB" }
        let field = try #require(form.field)
        try #require(form.window.makeFirstResponder(field))
        try await form.waitFor("field editor") { field.currentEditor() != nil }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(input.0, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await form.waitFor("dirty draft") { editor.string == input.0 }
        #expect(form.settings.localHistoryStorageLimitMegabytes == 100)
        if submit {
            editor.insertNewline(nil)
        } else {
            try #require(form.window.makeFirstResponder(nil))
        }
        try await form.waitFor("committed value and restored display") {
            form.settings.localHistoryStorageLimitMegabytes == input.1
                && (field.currentEditor()?.string ?? field.stringValue) == "\(input.1) MB"
        }
        #expect(AppSettings(store: form.store).localHistoryStorageLimitMegabytes == input.1)
    }

    @Test
    func failedClearReportsFailureAndRereadsUsageUntilRetrySucceeds() async {
        let model = LocalHistoryStorageSettingsModel()
        await model.refreshUsage { .init(usedBytes: 1024, limitBytes: 4096) }
        #expect(!model.clearFailed && !model.isClearing)
        var calls: [String] = []
        await model.clear(using: {
            #expect(model.isClearing && !model.clearFailed)
            calls.append("clear-failed")
            // Reentrant clicks must not start another deletion or usage read.
            await model.clear(using: { calls.append("duplicate"); return true }, readUsage: {
                calls.append("duplicate-usage"); return nil
            })
            return false
        }, readUsage: {
            calls.append("remaining-usage")
            return .init(usedBytes: 512, limitBytes: 4096)
        })
        #expect(calls == ["clear-failed", "remaining-usage"])
        #expect(model.clearFailed && !model.isClearing)
        #expect(model.usage?.usedBytes == 512)
        await model.clear(using: {
            #expect(model.isClearing && !model.clearFailed)
            calls.append("retry")
            return true
        }, readUsage: {
            calls.append("empty-usage")
            return .init(usedBytes: 0, limitBytes: 4096)
        })
        #expect(calls == ["clear-failed", "remaining-usage", "retry", "empty-usage"])
        #expect(!model.clearFailed && !model.isClearing)
        #expect(model.usage?.usedBytes == 0)
    }

    @Test
    func failedUsageReadDoesNotConcealClearFailureOrPreventRetry() async {
        let model = LocalHistoryStorageSettingsModel()
        await model.clear(using: { false }, readUsage: { nil })
        #expect(model.clearFailed && !model.isClearing && model.usage == nil)
        await model.clear(using: { true }, readUsage: { .init(usedBytes: 0, limitBytes: 4096) })
        #expect(!model.clearFailed && model.usage?.usedBytes == 0)
    }
}

@MainActor
private final class HistoryLimitForm {
    let store = HistorySettingsStore()
    let settings: AppSettings
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init() {
        let settings = AppSettings(store: store)
        self.settings = settings
        host = NSHostingView(rootView: AnyView(LitheSettingsStepper(
            value: Binding(get: { settings.localHistoryStorageLimitMegabytes },
                           set: { settings.localHistoryStorageLimitMegabytes = $0 }),
            in: AppSettings.localHistoryStorageLimitRange, step: 50, width: 180,
            accessibilityLabel: "Local history limit per project", title: { "\($0) MB" },
            parse: AppSettings.parseLocalHistoryStorageLimitMegabytes
        ).padding(20).frame(width: 300, height: 100)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    var field: NSTextField? {
        func editableField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { editableField(in: $0) }.first
        }
        return editableField(in: host)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    func waitFor(_ description: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Timed out waiting for \(description); field: \(field?.stringValue ?? "missing")")
        throw FormTimeout()
    }

    private struct FormTimeout: Error {}
}

private final class HistorySettingsStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
