import AppKit
import SwiftUI
import Testing
@testable import Lithe

/// Keeps one native settings hierarchy mounted across shrink, grow and divider drags.
@Suite("Toolchain settings native resize", .serialized)
@MainActor
struct ToolchainSettingsLayoutTests {
    @Test
    func nestedSettingsPanelsKeepTheirBoundsAndDocumentOrderAcrossRepeatedResize() async throws {
        let fixture = try await ToolchainLayoutFixture()
        defer { fixture.close() }
        let sizes: [NSSize] = [
            .init(width: 900, height: 668), .init(width: 1180, height: 820),
            .init(width: 1400, height: 900), .init(width: 900, height: 668),
            .init(width: 1180, height: 820)
        ]
        var firstNarrow: ToolchainLayoutGeometry?
        for size in sizes {
            fixture.resize(to: size)
            let geometry = try await fixture.settledGeometry()
            geometry.assertValid(host: fixture.host, size: size)
            #expect(fixture.model.selectedDirectoryID == ".")
            #expect(fixture.model.expandedToolIDs == ["compiler"])
            if size.width == 900 {
                if let previous = firstNarrow {
                    #expect(abs(previous.viewport.minX - geometry.viewport.minX) <= 1)
                    #expect(abs(previous.viewport.width - geometry.viewport.width) <= 1)
                    #expect(abs(previous.firstHeader.minY - geometry.firstHeader.minY) <= 1,
                            "Returning to the same width must not accumulate a vertical layout offset")
                } else { firstNarrow = geometry }
            }
        }
    }

    @Test
    func nativeDirectoryDividerDragReflowsCardsWithoutChangingDirectoryOrSelection() async throws {
        let fixture = try await ToolchainLayoutFixture()
        defer { fixture.close() }
        fixture.resize(to: .init(width: 1180, height: 820))
        let before = try await fixture.settledGeometry()
        let handles = fixture.nativeViews.compactMap { $0 as? SplitHandleInteractionView }
            .filter { $0.axis == .horizontal && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: fixture.host).midX < $1.convert($1.bounds, to: fixture.host).midX }
        let inner = try #require(handles.last, "The environment directory divider must be mounted")
        #expect(handles.count >= 2, "The fixture must exercise nested settings and directory splitters")
        let origin = inner.convert(NSPoint(x: inner.bounds.midX, y: inner.bounds.midY), to: nil)
        for (type, delta) in [(NSEvent.EventType.leftMouseDown, CGFloat(0)), (.leftMouseDragged, CGFloat(60)), (.leftMouseUp, CGFloat(60))] {
            let event = try #require(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: origin.x + delta, y: origin.y), modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            fixture.window.sendEvent(event)
        }
        let after = try await fixture.settledGeometry()
        #expect(after.viewport.minX > before.viewport.minX + 20,
                "Window-dispatched drag must move the actual native pane boundary")
        after.assertValid(host: fixture.host, size: .init(width: 1180, height: 820))
        fixture.resize(to: .init(width: 900, height: 668))
        let narrow = try await fixture.settledGeometry()
        narrow.assertValid(host: fixture.host, size: .init(width: 900, height: 668))
        #expect(fixture.model.selectedDirectoryID == ".")
        #expect(fixture.model.expandedToolIDs == ["compiler"])
        #expect(fixture.model.tools.first?.pin?.version == "24.10.2")
    }

    @Test
    func sourcesPageKeepsLoginShellAndProviderRowsInsideRepeatedViewportWidths() async throws {
        let fixture = try await ToolchainLayoutFixture(sourcesPage: true)
        defer { fixture.close() }
        let original = fixture.model.snapshot
        var firstNarrow: [NSRect]?
        for width: CGFloat in [500, 666, 946, 500] {
            fixture.resize(to: .init(width: width, height: 1400))
            let frames = try await fixture.settledSourceFrames()
            #expect(frames.count >= 10, "The actual source labels and native controls must be mounted")
            for frame in frames {
                #expect(frame.minX >= -1 && frame.maxX <= width + 1,
                        "Source controls and tool/provider labels overflow the \(width)pt viewport: \(frame)")
            }
            #expect(fixture.model.snapshot == original, "Resizing must not modify provider or tool facts")
            if width == 500 {
                if let previous = firstNarrow {
                    #expect(previous == frames, "Returning to the same source viewport must not accumulate flow offsets")
                } else { firstNarrow = frames }
            }
        }
    }

    @Test
    func sourcesPageCountsOnlyVersionFilesTheLoaderFound() async throws {
        let fixture = try await ToolchainLayoutFixture(sourcesPage: true)
        defer { fixture.close() }
        fixture.resize(to: .init(width: 666, height: 1400))
        _ = try await fixture.settledSourceFrames()
        let values = fixture.sourceTextValues
        #expect(values.contains("1 version files"))
        #expect(values.contains("Not used in this project"))
        #expect(values.contains("/bin/zsh"))
        #expect(values.contains("2 directories"))
    }
}

@MainActor
private final class ToolchainLayoutFixture {
    let model: ToolchainSettingsFeatureModel
    let host: NSHostingView<AnyView>
    let window: NSWindow
    private let application = NSApplication.shared
    private let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousAccessibility: Any?

    init(sourcesPage: Bool = false) async throws {
        var snapshot = Self.snapshot()
        if sourcesPage {
            snapshot.providers = [
                .init(id: "dev.lithe.fixture.provider:first", title: "Fixture version manager with a long provider title",
                      pluginID: "dev.lithe.fixture.provider", pluginName: "Provider support", tools: ["compiler", "renderer"],
                      watchFiles: ["configuration-with-a-long-filename/tools.fixture", ".fixture-versions"]),
                .init(id: "dev.lithe.fixture.alternative:second", title: "Another fixture provider with a long descriptive title",
                      pluginID: "dev.lithe.fixture.alternative", pluginName: "Alternative support", tools: ["renderer", "compiler"],
                      watchFiles: ["nested-configuration/location/long-tool-versions.fixture"])
            ]
            snapshot.directories[0].versionFiles = [.init(path: ".fixture-versions", providerIDs: ["dev.lithe.fixture.provider:first"])]
        }
        let feature = ToolchainSettingsFeatureModel(loader: ToolchainLayoutLoader(snapshot: snapshot),
                                                    loginShell: ToolchainLayoutLoginShell())
        await feature.load(workspace: snapshot.workspaceURL)
        feature.toggleExpanded("compiler")
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute)
        app.accessibilitySetValue(true, forAttribute: attribute)
        let content: AnyView = sourcesPage
            ? AnyView(ToolchainSourcesSettingsView(feature: feature, onOpenPlugins: {})
                .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en")))
            : AnyView(ToolchainLayoutRoot(model: feature))
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        let nativeWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 668),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.contentView = hosting
        nativeWindow.orderFront(nil)
        model = feature
        host = hosting
        window = nativeWindow
        previousAccessibility = previous
    }

    var nativeViews: [NSView] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(host)
    }

    func resize(to size: NSSize) {
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.needsLayout = true
    }

    /// SwiftUI exposes no AX layout callback, so observe native geometry with a local deadline.
    func settledGeometry() async throws -> ToolchainLayoutGeometry {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var previous: ToolchainLayoutGeometry?
        var stableTurns = 0
        repeat {
            host.layoutSubtreeIfNeeded()
            if let geometry = geometry() {
                stableTurns = geometry == previous ? stableTurns + 1 : 0
                previous = geometry
                if stableTurns >= 2 { return geometry }
            }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Toolchain native layout did not publish stable pane/card frames within two seconds")
        throw LayoutFailure.missingGeometry
    }

    /// Observe all on-screen source labels/buttons, including clipped horizontal overflows.
    func settledSourceFrames() async throws -> [NSRect] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var previous: [NSRect] = []
        var stableTurns = 0
        repeat {
            host.layoutSubtreeIfNeeded()
            let nodes = accessibleElements(host)
            let frames = nodes.compactMap { node -> NSRect? in
                guard node.accessibilityRole?() == .button || node.accessibilityRole?() == .staticText,
                      let screen = node.accessibilityFrame?(), !screen.isEmpty else { return nil }
                let native = host.convert(window.convertFromScreen(screen), from: nil)
                let frame = host.isFlipped ? native : NSRect(x: native.minX, y: host.bounds.height - native.maxY,
                                                           width: native.width, height: native.height)
                guard frame.maxY > 0 && frame.minY < host.bounds.height else { return nil }
                return frame
            }.sorted { left, right in
                left.minY == right.minY ? left.minX < right.minX : left.minY < right.minY
            }
            if frames.count >= 10 {
                stableTurns = frames == previous ? stableTurns + 1 : 0
                previous = frames
                if stableTurns >= 2 { return frames }
            }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Source labels and native buttons did not settle within two seconds")
        throw LayoutFailure.missingGeometry
    }

    var sourceTextValues: [String] {
        accessibleElements(host).flatMap { node -> [String] in
            let value: String? = node.accessibilityValue?()
            return [node.accessibilityLabel?(), node.accessibilityTitle?(), value].compactMap { $0 }
        }
    }

    private func geometry() -> ToolchainLayoutGeometry? {
        let elements = accessibleElements(host)
        func frame(of node: AnyObject?) -> NSRect? {
            guard let node, let screen = node.accessibilityFrame?(), !screen.isEmpty else { return nil }
            let native = host.convert(window.convertFromScreen(screen), from: nil)
            // Normalize native hosts to top-origin coordinates for vertical order assertions.
            return host.isFlipped ? native : .init(x: native.minX, y: host.bounds.height - native.maxY,
                                                  width: native.width, height: native.height)
        }
        func frame(_ id: String) -> NSRect? {
            frame(of: elements.first(where: { $0.accessibilityIdentifier?() == id }))
        }
        let toolsHeading = elements.first { element in
            guard element.accessibilityRole?() == .staticText else { return false }
            let value: String? = element.accessibilityValue?()
            return element.accessibilityLabel?() == "Tools"
                || element.accessibilityTitle?() == "Tools"
                || value == "Tools"
        }
        guard let directories = frame("toolchain-directory-list"),
              let viewport = frame("environment-detail-viewport"),
              let heading = frame(of: toolsHeading),
              let first = frame("toolchain-tool-header:compiler"),
              let resolution = frame("toolchain-resolution:compiler"),
              let second = frame("toolchain-tool-header:renderer") else { return nil }
        let steps = ["pinned", "project", "global", "automatic"].compactMap { frame("toolchain-step:compiler:\($0)") }
        guard steps.count == 4 else { return nil }
        return .init(directories: directories, viewport: viewport, heading: heading,
                     firstHeader: first, resolution: resolution, secondHeader: second, steps: steps)
    }

    private func accessibleElements(_ value: Any, depth: Int = 0) -> [AnyObject] {
        guard depth < 48 else { return [] }
        let object = value as AnyObject
        let children = object.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((value as? NSView)?.subviews ?? []) : children
        return [object] + descendants.flatMap { accessibleElements($0, depth: depth + 1) }
    }

    func close() {
        model.close()
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        application.accessibilitySetValue(previousAccessibility, forAttribute: accessibilityAttribute)
    }

    private static func snapshot() -> ToolchainSettingsSnapshot {
        let root = URL(fileURLWithPath: "/fixture/very-long-workspace-name/services/rendering-and-compilation")
        let installation = "/fixture/installations/a-long-vendor-directory/complete-toolchain-with-a-long-home-name/24.10.2"
        let provider = "dev.lithe.fixture.provider:first"
        let file = ToolchainSettingsSnapshot.VersionFile(path: "configuration-with-a-long-name/tools/versions.fixture", providerIDs: [provider])
        return .init(workspaceURL: root, directories: [.init(id: ".", title: "Fixture workspace"),
            .init(id: "modules", title: "modules", depth: 1), .init(id: "modules/renderer", title: "renderer", depth: 2)],
            tools: [
                .init(id: "compiler", displayName: "Fixture compiler", pluginID: "dev.lithe.fixture.compiler", pluginName: "Compiler support",
                      pin: .init(version: "24.10.2", home: installation), versionFiles: [file],
                      candidate: .init(executable: "/fixture/system/a-long-bin-directory/compiler", origin: .variable("FIXTURE_HOME"))),
                .init(id: "renderer", displayName: "Fixture renderer", pluginID: "dev.lithe.fixture.renderer", pluginName: "Renderer support",
                      candidate: .init(executable: "/fixture/renderers/12.3.0/bin/renderer", origin: .path))
            ],
            providers: [.init(id: provider, title: "Fixture provider", pluginID: "dev.lithe.fixture.provider",
                              pluginName: "Provider support", tools: ["compiler"], watchFiles: ["versions.fixture"])])
    }

    private enum LayoutFailure: Error { case missingGeometry }
}

private struct ToolchainLayoutLoader: ToolchainSettingsLoading {
    let snapshot: ToolchainSettingsSnapshot
    func load(workspace: URL?) async throws -> ToolchainSettingsSnapshot { snapshot }
}

/// A finished login-shell read with a mixed `PATH`; nothing runs a shell.
private struct ToolchainLayoutLoginShell: LoginShellEnvironmentInspecting {
    private let snapshot = LoginShellEnvironmentSnapshot(
        shell: "/bin/zsh", state: .read, variableCount: 42, durationMilliseconds: 120,
        processPath: [.init(path: "/fixture/login-shell/a-long-directory-name/bin", origin: .loginShell),
                      .init(path: "/fixture/launch/bin", origin: .inherited)])

    func inspect() -> LoginShellEnvironmentSnapshot { snapshot }
    func reread() async -> LoginShellEnvironmentSnapshot { snapshot }
}

private struct ToolchainLayoutRoot: View {
    @ObservedObject var model: ToolchainSettingsFeatureModel
    @State private var sidebarWidth: CGFloat = 234

    var body: some View {
        VStack(spacing: 0) {
            LitheSplitPaneView(axis: .horizontal, placement: .leading,
                defaultSize: sidebarWidth, minimum: 234, maximum: 480, flexibleMinimum: 500,
                onCommit: { sidebarWidth = $0 },
                sized: { Color.clear },
                flexible: { ToolchainEnvironmentSettingsView(feature: model, onOpenPlugins: {}) })
            Rectangle().fill(Color.clear).frame(height: 46)
        }
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "en"))
    }
}

private struct ToolchainLayoutGeometry: Equatable {
    let directories: NSRect
    let viewport: NSRect
    let heading: NSRect
    let firstHeader: NSRect
    let resolution: NSRect
    let secondHeader: NSRect
    let steps: [NSRect]

    @MainActor
    func assertValid(host: NSView, size: NSSize) {
        #expect(directories.width >= 149 && viewport.width >= 339, "directories \(directories), detail \(viewport)")
        #expect(directories.maxX <= viewport.minX + 1, "Directory and detail panes must not overlap")
        #expect(viewport.maxX <= size.width + 1 && viewport.maxY <= size.height - 45)
        #expect(directories.minY >= -1 && viewport.minY >= -1)
        #expect(heading.maxY <= firstHeader.minY + 1, "Tools heading must remain above its first row")
        #expect(firstHeader.maxY <= resolution.minY + 1, "Expanded resolution must remain below its header")
        #expect(resolution.maxY <= secondHeader.minY + 1, "The following tool row must not overlap the expanded resolution")
        for frame in [heading, firstHeader, resolution, secondHeader] + steps {
            #expect(frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite)
            #expect(frame.minX >= viewport.minX - 1 && frame.maxX <= viewport.maxX + 1,
                    "Cards must reflow inside the native detail viewport rather than overflow when narrowed")
        }
        for (index, first) in steps.enumerated() {
            for (offset, second) in steps.dropFirst(index + 1).enumerated() {
                let overlap = first.intersection(second)
                #expect(overlap.isNull || overlap.width <= 1 || overlap.height <= 1,
                        "Adaptive steps \(index)/\(index + offset + 1) overlap: \(first), \(second), viewport: \(viewport)")
            }
        }
        #expect(abs(host.bounds.width - size.width) <= 1 && abs(host.bounds.height - size.height) <= 1)
    }
}
