import AppKit
import LitheCoreContracts
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Agent context settings lifecycle", .serialized)
struct AgentContextLimitsSettingsTests {
    @Test(arguments: [false, true])
    func restoreDefaultsSurvivesImmediatePageExitAndReopen(closeWindow: Bool) async throws {
        try await withForm { form in
            try await form.waitFor("initial empty context fields") { form.fieldValues == ["", ""] }
            try await form.editField(0, text: "200K")
            #expect(form.window.makeFirstResponder(nil))
            try await form.waitFor("context length saved on focus loss") {
                form.settings.agentContextLimits["codex-acp"]?.windowTokens == 200_000
            }
            try await form.editField(1, text: "150K")
            #expect(form.window.makeFirstResponder(nil))
            try await form.waitFor("compaction threshold saved on focus loss") {
                form.settings.agentContextLimits["codex-acp"]?.autoCompactTokens == 150_000
            }

            // No yield between reset and unmount: onDisappear may precede onChange.
            form.settings.restoreDefaults()
            if closeWindow { form.window.close() }
            form.host.rootView = AnyView(Text("Other settings page"))
            try await form.waitFor("context page removed") { form.fields.isEmpty }
            #expect(form.settings.agentContextLimits.isEmpty)
            #expect(AppSettings(store: form.store).agentContextLimits.isEmpty)

            form.showAgent("codex-acp")
            if closeWindow { form.window.makeKeyAndOrderFront(nil) }
            try await form.waitFor("reopened form uses Agent defaults") { form.fieldValues == ["", ""] }
            #expect(form.settings.agentContextLimits.isEmpty)
        }
    }

    @Test(arguments: ["300K", "invalid"], [false, true])
    func restoreDefaultsDiscardsDirtyDraftBeforeImmediateFocusLoss(draft: String, hasSavedLimits: Bool) async throws {
        try await withForm { form in
            let saved: AgentContextLimits? = hasSavedLimits
                ? AgentContextLimits(windowTokens: 200_000, autoCompactTokens: 150_000) : nil
            form.settings.agentContextLimits["codex-acp"] = saved
            try await form.waitFor("saved limits populate both fields") {
                form.fieldValues == (hasSavedLimits ? ["200K", "150K"] : ["", ""])
            }
            try await form.editField(0, text: draft)
            #expect(form.settings.agentContextLimits["codex-acp"] == saved)

            form.settings.restoreDefaults()
            #expect(form.window.makeFirstResponder(nil))
            try await form.waitFor("reset clears dirty and saved field values") { form.fieldValues == ["", ""] }
            #expect(form.settings.agentContextLimits.isEmpty)
            #expect(AppSettings(store: form.store).agentContextLimits.isEmpty)
        }
    }

    @Test
    func externalChangesRefreshOnlyTheirAgentAndSubsequentEditsStillSave() async throws {
        try await withForm { form in
            form.settings.agentContextLimits["codex-acp"] = AgentContextLimits(windowTokens: 200_000)
            try await form.waitFor("initial Codex limits") { form.fieldValues == ["200K", ""] }
            try await form.editField(0, text: "300K")
            form.settings.agentContextLimits["claude-acp"] = AgentContextLimits(windowTokens: 1_000_000)
            // A different Agent's update must not discard this Agent's uncommitted edit.
            #expect(form.window.makeFirstResponder(nil))
            try await form.waitFor("Codex draft survives unrelated settings update") {
                form.settings.agentContextLimits["codex-acp"]?.windowTokens == 300_000
            }
            form.settings.agentContextLimits["codex-acp"] = AgentContextLimits(windowTokens: 400_000)
            try await form.waitFor("same Agent external update refreshes the form") { form.fieldValues == ["400K", ""] }
            try await form.editField(1, text: "100K")
            #expect(form.window.makeFirstResponder(nil))
            try await form.waitFor("edits after external refresh still save") {
                form.settings.agentContextLimits["codex-acp"] == AgentContextLimits(
                    windowTokens: 400_000, autoCompactTokens: 100_000)
            }

            form.showAgent("claude-acp")
            try await form.waitFor("changing Agent loads its own values") { form.fieldValues == ["1M", ""] }
            #expect(form.settings.agentContextLimits["codex-acp"]?.autoCompactTokens == 100_000)
        }
    }

    private func withForm(_ test: (ContextLimitsForm) async throws -> Void) async throws {
        let form = ContextLimitsForm()
        defer {
            form.window.makeFirstResponder(nil)
            form.window.contentView = nil
            form.window.close()
        }
        do { try await test(form) }
        catch { await form.model.shutdownProjectSession(); throw error }
        await form.model.shutdownProjectSession()
    }
}

@MainActor
private final class ContextLimitsForm {
    let store = ContextLimitsSettingsStore()
    let settings: AppSettings
    let model: AppModel
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        settings = AppSettings(store: store)
        model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        window.isReleasedWhenClosed = false
        window.contentView = host
        showAgent("codex-acp")
        window.makeKeyAndOrderFront(nil)
    }

    var fields: [NSTextField] {
        func descendants(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap(descendants)
        }
        return descendants(host).sorted {
            let a = $0.convert($0.bounds, to: host).minY
            let b = $1.convert($1.bounds, to: host).minY
            return host.isFlipped ? a < b : a > b
        }
    }

    var fieldValues: [String] { fields.map { ($0.currentEditor() as? NSTextView)?.string ?? $0.stringValue } }

    func showAgent(_ agentID: String) {
        host.rootView = AnyView(AgentContextLimitsSettings(agentID: agentID, model: model, settings: settings)
            .id(agentID)
            .padding(16).frame(width: 760, height: 300, alignment: .topLeading))
    }

    func editField(_ index: Int, text: String) async throws {
        let field = try #require(fields.indices.contains(index) ? fields[index] : nil)
        try #require(window.makeFirstResponder(field))
        // Focus and typing are separate native UI transactions, just as in the product.
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await waitFor("native field editing \(text)") {
            field.currentEditor() === window.firstResponder && fieldValues[index] == text
        }
    }

    func waitFor(_ description: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Timed out waiting for \(description); displayed values: \(fieldValues)")
        throw FormTimeout()
    }

    private struct FormTimeout: Error {}
}

private final class ContextLimitsSettingsStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
