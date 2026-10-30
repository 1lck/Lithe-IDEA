import AppKit
import Foundation
import LitheCoreContracts
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Commit file deletion", .serialized)
struct CommitFileDeletionTests {
    @Test func cancellationReplacementAndRepeatedConfirmationNeverReplayConsent() async throws {
        let files = DeletionTestFiles()
        var deleted: [[URL]] = []
        let feature = makeFeature(files)
        defer { feature.reset() }
        func request(_ name: String) {
            feature.request([root.appendingPathComponent(name)], root: root, isCurrent: { true },
                            delete: { deleted.append($0); return true }, refresh: {})
        }
        request("first.txt")
        let cancelled = try #require(feature.pending)
        feature.cancel()
        await feature.confirm(cancelled)
        request("second.txt")
        let replaced = try #require(feature.pending)
        request("third.txt")
        await feature.confirm(replaced)
        let confirmed = try #require(feature.pending)
        let task = try #require(feature.beginConfirmation(confirmed))
        defer { task.cancel() }
        #expect(feature.pending == nil && feature.isDeleting)
        feature.cancel() // Native presenter dismisses after consuming consent.
        await task.value
        await feature.confirm(confirmed)
        #expect(deleted == [[root.appendingPathComponent("third.txt")]])
        #expect(!feature.isDeleting && files.trashed.isEmpty)
    }

    @Test(arguments: ["dirty", "stale", "ineligible", "cancelled", "flush-failed"])
    func editorSynchronizationRechecksEveryMutationPrecondition(outcome: String) async throws {
        let files = DeletionTestFiles(), reached = TestGate(), release = TestGate()
        var dirty = false, current = true, eligible = true, writes = 0
        let feature = CommitFileDeletionFeatureModel(files: files, hasUnsavedEdits: { _ in dirty },
            closeCleanDocuments: { _ in }, synchronizeEditors: { _ in
                reached.open()
                let released = await release.waitUntilOpen()
                #expect(released || Task.isCancelled)
                if outcome == "flush-failed" { throw CocoaError(.fileReadUnknown) }
            }, notify: { _ in })
        feature.request([root.appendingPathComponent("target.txt")], root: root,
            isCurrent: { current }, isEligible: { eligible }, delete: { _ in writes += 1; return true }, refresh: {})
        let request = try #require(feature.pending)
        let task = try #require(feature.beginConfirmation(request))
        defer { release.open(); task.cancel(); feature.reset() }
        try #require(await reached.waitUntilOpen())
        #expect(feature.isDeleting)
        switch outcome {
        case "dirty": dirty = true
        case "stale": current = false
        case "ineligible": eligible = false
        case "cancelled": feature.reset()
        default: break
        }
        release.open()
        await task.value
        #expect(writes == 0 && files.trashed.isEmpty && !feature.isDeleting)
    }

    @Test func nativeTrashStopsAtTheFirstFailureAndOnlyClosesSuccessfullyDeletedCleanFiles() async throws {
        let files = DeletionTestFiles()
        files.failureName = "b.txt"
        var closed: [URL] = [], refreshed = 0, errors: [String] = []
        let feature = CommitFileDeletionFeatureModel(files: files, hasUnsavedEdits: { _ in false },
            closeCleanDocuments: { closed.append($0) }, notify: { errors.append($0) })
        defer { feature.reset() }
        feature.request(["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }, root: root,
                        isCurrent: { true }, refresh: { refreshed += 1 })
        await feature.confirm(try #require(feature.pending))
        #expect(files.trashed == ["a.txt", "b.txt"])
        #expect(closed == [root.appendingPathComponent("a.txt")])
        #expect(refreshed == 1 && errors.count == 1)
    }

    @Test func providerDeletionUsesExactlyTheConfirmedBatchAndRefreshesAfterStatusChanges() async throws {
        let files = DeletionTestFiles()
        var current = true, eligible = true, closed: [URL] = [], refreshed = 0, batches: [[URL]] = []
        let feature = CommitFileDeletionFeatureModel(files: files, hasUnsavedEdits: { _ in false },
            closeCleanDocuments: { closed.append($0) }, notify: { _ in })
        defer { feature.reset(); current = false }
        let target = root.appendingPathComponent("folder")
        feature.request([target.appendingPathComponent("child.txt"), target, target], root: root, usesVcs: true,
            isCurrent: { current }, isEligible: { eligible }, delete: { urls in
                batches.append(urls)
                eligible = false // Provider status no longer contains the removed paths.
                return true
            }, refresh: { refreshed += 1 })
        await feature.confirm(try #require(feature.pending))
        #expect(batches == [[target]] && closed == [target] && refreshed == 1)
        #expect(files.trashed.isEmpty, "Tracked deletion never falls back to the native filesystem")
    }

    @Test func refusesDirtyFilesAndPathsOutsideOrEqualToTheRoot() {
        let files = DeletionTestFiles()
        var dirty = false, warnings = 0
        let feature = CommitFileDeletionFeatureModel(files: files, hasUnsavedEdits: { _ in dirty },
            closeCleanDocuments: { _ in }, notify: { _ in warnings += 1 })
        defer { feature.reset() }
        for url in [root, URL(fileURLWithPath: "/outside/file.txt"), root.appendingPathComponent("../escaped.txt")] {
            feature.request([url], root: root, isCurrent: { true }, refresh: {})
            #expect(feature.pending == nil)
        }
        dirty = true
        feature.request([root.appendingPathComponent("dirty.txt")], root: root, isCurrent: { true }, refresh: {})
        #expect(feature.pending == nil && warnings == 1)
    }

    @Test(arguments: ["escape", "close"], [false, true])
    func nativeConfirmationDismissalNeverDeletesFiles(action: String, dark: Bool) async throws {
        let files = DeletionTestFiles(), feature = makeFeature(files)
        let host = NSHostingView(rootView: Color.clear.frame(width: 700, height: 450)
            .modifier(CommitFileDeletionPresentation(feature: feature))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = host; parent.center(); parent.orderFront(nil)
        defer { feature.reset(); parent.contentView = nil; parent.close() }
        feature.request([root.appendingPathComponent("target.txt")], root: root, isCurrent: { true }, refresh: {})
        let captured = try #require(feature.pending)
        func settle(_ predicate: () -> Bool) async -> Bool {
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                if predicate() { return true }
                await Task.yield()
            } while clock.now < deadline
            return predicate()
        }
        try #require(await settle {
            parent.childWindows?.contains { $0.isVisible && $0.contentView?.bounds.isEmpty == false } == true
        })
        let visiblePanel = parent.childWindows?.first { $0.isVisible }
        let panel = try #require(visiblePanel)
        #expect(panel.styleMask.contains(.titled) && panel.styleMask.contains(.closable))
        _ = try nativeSRGBCapture(try #require(panel.contentView))
        if action == "close" { panel.performClose(nil) }
        else {
            panel.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        }
        #expect(await settle { feature.pending == nil && !feature.isDeleting && panel.parent == nil })
        #expect(files.trashed.isEmpty)
        await feature.confirm(captured)
        #expect(files.trashed.isEmpty)
    }

    @Test(arguments: [false, true], ["en", "zh-Hans"])
    func nativeDialogButtonsCancelOrConfirmExactlyOnce(dark: Bool, language: String) async throws {
        MacBundledFontRegistry.registerFonts()
        for usesVcs in [false, true] {
            for confirm in [false, true] {
                try await exerciseDialogButtons(confirm: confirm, dark: dark, language: language, usesVcs: usesVcs)
            }
        }
    }

    private func exerciseDialogButtons(confirm: Bool, dark: Bool, language: String, usesVcs: Bool) async throws {
        let files = DeletionTestFiles(), feature = makeFeature(files)
        var providerDeleted: [URL] = []
        let delete: (@MainActor ([URL]) async -> Bool)?
        if usesVcs { delete = { providerDeleted.append(contentsOf: $0); return true } }
        else { delete = nil }
        feature.request([root.appendingPathComponent("target.txt")], root: root, usesVcs: usesVcs,
                        isCurrent: { true }, delete: delete, refresh: {})
        let request = try #require(feature.pending)
        var deletion: Task<Void, Never>?
        let host = NSHostingView(rootView: CommitFileDeletionDialog(request: request,
            onCancel: { feature.cancel() }, onDelete: { deletion = feature.beginConfirmation(request) })
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.center(); window.orderFront(nil)
        defer { deletion?.cancel(); feature.reset(); window.contentView = nil; window.close() }
        let app = NSApplication.shared, attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute)
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        func elements(_ value: Any) -> [AnyObject] {
            let object = value as AnyObject
            let children = object.accessibilityChildren?() ?? []
            let descendants: [Any] = children.isEmpty ? ((value as? NSView)?.subviews ?? []) : children
            return [object] + descendants.flatMap(elements)
        }
        for id in ["commit-files-delete-cancel", "commit-files-delete-confirm"] {
            #expect(host.bounds.contains(try await AgentNativeControlTestSupport.frame(of: id, in: host)))
        }
        if let folder = ProcessInfo.processInfo.environment["LITHE_COMMIT_DELETE_CAPTURE_DIR"], !confirm {
            #expect(Bundle.main.path(forResource: language, ofType: "lproj") != nil)
            let control = try #require(elements(host).first { $0.accessibilityIdentifier?() == "commit-files-delete-confirm" })
            #expect(control.accessibilityLabel?() == (language == "zh-Hans" ? "删除" : "Delete"))
            let warning = try #require(elements(host).first { $0.accessibilityIdentifier?() == "commit-files-delete-warning" })
            let expected: String
            if usesVcs {
                expected = language == "zh-Hans" ? "版本控制插件将删除这些文件并记录删除操作，文件可能不会移入废纸篓。"
                    : "The version control provider will delete these files and record their removal. They may not be moved to Trash."
            } else {
                expected = language == "zh-Hans" ? "这些文件将移到 macOS 废纸篓。"
                    : "These files will be moved to the macOS Trash."
            }
            let value: String? = warning.accessibilityValue?()
            #expect((value ?? warning.accessibilityLabel?()) == expected)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let bitmap = try nativeSRGBCapture(host)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: folder).appendingPathComponent("delete-\(usesVcs ? "vcs" : "trash")-\(language)-\(dark ? "dark" : "light").png"))
        }
        let id = confirm ? "commit-files-delete-confirm" : "commit-files-delete-cancel"
        let button = try #require(elements(host).first { $0.accessibilityIdentifier?() == id })
        #expect(button.accessibilityPerformPress?() == true)
        await deletion?.value
        #expect(feature.pending == nil && !feature.isDeleting)
        #expect(files.trashed == (confirm && !usesVcs ? ["target.txt"] : []))
        #expect(providerDeleted == (confirm && usesVcs ? [root.appendingPathComponent("target.txt")] : []))
        await feature.confirm(request)
        #expect(files.trashed == (confirm && !usesVcs ? ["target.txt"] : []))
        #expect(providerDeleted == (confirm && usesVcs ? [root.appendingPathComponent("target.txt")] : []))
    }

    private var root: URL { URL(fileURLWithPath: "/fixture/commit-deletion") }

    private func makeFeature(_ files: DeletionTestFiles) -> CommitFileDeletionFeatureModel {
        CommitFileDeletionFeatureModel(files: files, hasUnsavedEdits: { _ in false },
                                       closeCleanDocuments: { _ in }, notify: { _ in })
    }
}

private final class DeletionTestFiles: WorkspaceFileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var failureName: String?
    var trashed: [String] { lock.withLock { calls } }
    func fileExists(at url: URL) -> Bool { true }
    func isDirectory(at url: URL) -> Bool { false }
    func trashItem(at url: URL) throws {
        lock.withLock { calls.append(url.lastPathComponent) }
        if url.lastPathComponent == failureName { throw CocoaError(.fileWriteNoPermission) }
    }
    func createFile(at url: URL) throws { throw CocoaError(.featureUnsupported) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { throw CocoaError(.featureUnsupported) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.featureUnsupported) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.featureUnsupported) }
    func removeItem(at url: URL) throws { throw CocoaError(.featureUnsupported) }
    func writeText(_ text: String, to url: URL) throws { throw CocoaError(.featureUnsupported) }
    func readText(from url: URL) throws -> String { "" }
}
