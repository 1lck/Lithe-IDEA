import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Complete shared text inputs", .serialized)
struct LitheTextInputTests {
    @Test func productCallersCannotReassembleRetiredInputRecipes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Lithe/Views")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("litheSettingsTextField("), "Retired input recipe: \(file.lastPathComponent)")
            #expect(!source.contains("litheSettingsTextEditor("), "Retired editor recipe: \(file.lastPathComponent)")
            #expect(!source.contains("LitheSettingsSearchField"), "Retired search entry: \(file.lastPathComponent)")
            if file.lastPathComponent != "LitheSearchField.swift" {
                for line in source.components(separatedBy: .newlines) where line.contains("LitheSearchTextField(") {
                    // Multiline task composition is an editor, not a product search field.
                    #expect(line.contains("axis: .vertical"), "Use the complete search owner: \(file.lastPathComponent)")
                }
                #expect(!source.contains(".litheSearchField("), "Search chrome belongs to its owner: \(file.lastPathComponent)")
            }
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func commandFieldGrowsWithinItsLineLimit(scheme: ColorScheme) {
        func height(_ text: String) -> CGFloat {
            let host = NSHostingView(rootView:
                LitheTextField("Command", text: .constant(text), axis: .vertical)
                    .lineLimit(1...3).frame(width: 240)
                    .environment(\.colorScheme, scheme))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let single = height("command")
        let three = height("command\nargument\nvalue")
        #expect(single >= SettingsSelectMetrics.controlHeight)
        #expect(three > single)
        #expect(abs(height("command\nargument\nvalue\nmore\nlines") - three) < 1)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func searchFocusClearAndNativeEditorsSurviveTheCompleteOwner(scheme: ColorScheme) async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        var changes: [String] = []
        let host = NSHostingView(rootView: InputFixture(onChange: { changes.append($0) }).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        func elements(_ value: Any) -> [AnyObject] {
            let item = value as AnyObject
            return [item] + (item.accessibilityChildren?() ?? []).flatMap { elements($0) }
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        var accessible: [AnyObject] = []
        repeat {
            host.layoutSubtreeIfNeeded()
            accessible = elements(host)
            if accessible.contains(where: { $0.accessibilityLabel?() == "Focus search" }) { break }
            await Task.yield()
        } while clock.now < deadline
        let focusButton = try #require(accessible.first { $0.accessibilityLabel?() == "Focus search" })
        #expect(focusButton.accessibilityPerformPress?() == true)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let search = try #require(views(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == "typed" })
        #expect(search.currentEditor() === window.firstResponder)
        #expect(views(host).contains { $0 is NSSecureTextField })
        #expect(accessible.contains { $0.accessibilityRole?() == .textArea })
        let tip = try #require(accessible.first { $0.accessibilityHelp?() == "Disabled field explanation" })
        #expect(tip.isAccessibilityEnabled?() == true)
        let clear = try #require(accessible.first { $0.accessibilityLabel?() == "Clear search" })
        #expect(clear.accessibilityPerformPress?() == true)
        await Task.yield()
        #expect(changes.last == "")
        #expect(search.stringValue.isEmpty)
    }
}

private struct InputFixture: View {
    @State private var query = "typed"
    @State private var text = "draft"
    @State private var notes = "中文\nEnglish"
    @FocusState private var searchFocused: Bool
    let onChange: (String) -> Void
    var body: some View {
        VStack {
            LitheSearchField("Search", text: $query, focus: $searchFocused, onTextChanged: onChange)
            LitheTextField("Password", text: $text, secure: true)
            LitheTextEditor(text: $notes, height: 90)
            LitheTextField(verbatim: "", text: $text, label: "Disabled", info: "Disabled field explanation")
                .disabled(true)
            Button("Focus search") { searchFocused = true }
        }.padding(12)
    }
}
