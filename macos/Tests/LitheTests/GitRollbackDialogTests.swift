import AppKit
import SwiftUI
import LitheGitModule
import Testing
@testable import Lithe

@MainActor
@Suite("Git rollback dialog", .serialized)
struct GitRollbackDialogTests {
    @Test(arguments: [false, true], ["en", "zh-Hans"])
    func rollbackDialogRendersReviewedFilesAndKeepsCloseSeparateFromConfirmation(dark: Bool, language: String) async throws {
        MacBundledFontRegistry.registerFonts()
        let root = URL(fileURLWithPath: "/workspace")
        let changes = ["Sources/First.swift", "Sources/Second.swift"].map {
            GitChange(repositoryRoot: root, path: $0, originalPath: nil, indexStatus: "M", workTreeStatus: "M")
        }
        let selection = GitRollbackSelection(contextID: UUID(), changes: changes, included: [changes[0]])
        var closed = 0
        var confirmed: [GitRollbackSelection] = []
        let host = NSHostingView(rootView: GitRollbackDialog(selection: selection,
            onClose: { closed += 1 }, onRollback: { confirmed.append($0) })
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: language)))
        host.sizingOptions = []
        let window = RollbackDialogTestWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = application.accessibilityAttributeValue(attribute)
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let bitmap = try nativeSRGBCapture(host)
        if let directory = ProcessInfo.processInfo.environment["LITHE_ROLLBACK_CAPTURE_DIR"] {
            #expect(Bundle.main.path(forResource: language, ofType: "lproj") != nil)
            #expect(LitheIcons.ideaImage(resourcePath: "commit/checkBoxSelected.svg") != nil)
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                destination.appendingPathComponent("rollback-\(language)-\(dark ? "dark" : "light").png"))
        }
        func elements(_ element: Any) -> [AnyObject] {
            let object = element as AnyObject
            let children = object.accessibilityChildren?() ?? []
            let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
            return [object] + descendants.flatMap(elements)
        }
        for id in ["git-rollback-confirm", "git-rollback-close"] {
            #expect(try await AgentNativeControlTestSupport.isEnabled(id, in: host))
            #expect(host.bounds.contains(try await AgentNativeControlTestSupport.frame(of: id, in: host)))
        }
        if ProcessInfo.processInfo.environment["LITHE_ROLLBACK_CAPTURE_DIR"] != nil {
            let label = try #require(elements(host).first { $0.accessibilityIdentifier?() == "git-rollback-confirm" })
            #expect(label.accessibilityLabel?() == (language == "zh-Hans" ? "回滚" : "Rollback"))
        }
        let close = try #require(elements(host).first { $0.accessibilityIdentifier?() == "git-rollback-close" })
        #expect(close.accessibilityPerformPress?() == true)
        #expect(closed == 1 && confirmed.isEmpty)
        let first = try #require(elements(host).first { $0.accessibilityIdentifier?() == "git-rollback-include-" + changes[0].id })
        #expect(first.accessibilityPerformPress?() == true)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(try await !AgentNativeControlTestSupport.isEnabled("git-rollback-confirm", in: host))
        let second = try #require(elements(host).first { $0.accessibilityIdentifier?() == "git-rollback-include-" + changes[1].id })
        #expect(second.accessibilityPerformPress?() == true)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(try await AgentNativeControlTestSupport.isEnabled("git-rollback-confirm", in: host))
        let confirm = try #require(elements(host).first { $0.accessibilityIdentifier?() == "git-rollback-confirm" })
        #expect(confirm.accessibilityPerformPress?() == true)
        #expect(confirmed.count == 1 && confirmed.first?.includedChanges == [changes[1]])
        #expect(selection.includedChanges == [changes[0]] && changes.allSatisfy(\.isStaged))
    }

    @Test
    func emptyRollbackDraftDisablesDestructiveConfirmation() async throws {
        let selection = GitRollbackSelection(contextID: UUID(), changes: [], included: [])
        let host = NSHostingView(rootView: GitRollbackDialog(selection: selection, onClose: {}, onRollback: { _ in
            Issue.record("Empty rollback must not execute")
        }))
        let window = RollbackDialogTestWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(try await !AgentNativeControlTestSupport.isEnabled("git-rollback-confirm", in: host))
        #expect(try await AgentNativeControlTestSupport.isEnabled("git-rollback-close", in: host))
    }
}

@MainActor
private final class RollbackDialogTestWindow: NSWindow {
    // Native focus behavior is tested without taking the user's desktop focus.
    override var isKeyWindow: Bool { true }
}
