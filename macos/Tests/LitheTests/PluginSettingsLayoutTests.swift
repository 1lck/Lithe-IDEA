import AppKit
import LitheCoreContracts
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

/// A file picker remains a usable native button when plugin details are narrow.
@Suite("Plugin settings path layout", .serialized)
@MainActor
struct PluginSettingsLayoutTests {
    @Test(arguments: [480.0, 640.0, 900.0], [false, true])
    func pathPickerFitsAndStillWritesTheSelectedPath(width: Double, dark: Bool) async throws {
        var pickedDirectory: Bool?
        var saved: ToolingJSONValue?
        let selected = URL(fileURLWithPath: "/fixture/custom tools/build-tool")
        let declaration = DeclarativePluginSetting(
            id: "toolPath", title: "Build executable", summary: "Select a file or leave empty for discovery.",
            kind: .path(directory: false, placeholder: "Automatic"), defaultValue: .string(""),
            scope: .global, effect: .reload
        )
        let view = PluginSettingsSection(
            settings: [.resolve(declaration, global: nil, project: nil)], hasProject: true,
            handlers: PluginSettingsHandlers(
                setValue: { id, value, layer in
                    #expect(id == "toolPath" && layer == .global)
                    saved = value
                    return nil
                },
                restartLanguageServers: {}, runAction: { _ in },
                choosePath: { directory in pickedDirectory = directory; return selected }
            )
        )
        .padding(14)
        .frame(width: width, height: 180, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        host.layoutSubtreeIfNeeded()
        let button = try #require(await chooseButton(in: host))
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let screenFrame = try #require(button.accessibilityFrame?())
        let buttonFrame = host.convert(window.convertFromScreen(screenFrame), from: nil)
        let fieldFrame = field.convert(field.bounds, to: host)
        let titleWidth = (String(localized: "Choose…") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
        #expect(buttonFrame.width >= titleWidth)
        #expect(buttonFrame.minX >= fieldFrame.maxX)
        #expect(host.bounds.contains(buttonFrame))
        #expect(host.bounds.contains(fieldFrame))
        #expect(fieldFrame.width > 0)
        #expect(button.accessibilityPerformPress?() == true)
        #expect(pickedDirectory == false)
        #expect(saved == .string(selected.path))

        if let directory = ProcessInfo.processInfo.environment["LITHE_PLUGIN_SETTINGS_LAYOUT_CAPTURES"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("path-\(Int(width))-\(dark ? "dark" : "light").png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func chooseButton(in host: NSView) async -> AnyObject? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if let button = accessibleElements(in: host).first(where: {
                $0.accessibilityRole?() == .button
                    && ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == String(localized: "Choose…")
            }) { return button }
            await Task.yield()
        } while clock.now < deadline
        return nil
    }

    private func accessibleElements(in element: Any) -> [AnyObject] {
        let accessible = element as AnyObject
        let children = accessible.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return [accessible] + descendants.flatMap { accessibleElements(in: $0) }
    }
}
