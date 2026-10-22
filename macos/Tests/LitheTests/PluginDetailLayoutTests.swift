import AppKit
import LitheCoreContracts
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

/// A real plugin form must respect the same edge as the split handle when resized.
@MainActor
@Suite(.serialized)
struct PluginDetailLayoutTests {
    @Test(arguments: [false, true])
    func settingsStayBesideTheDividerWhenTheWindowShrinks(dark: Bool) throws {
        let descriptor = try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")
        var plugin = PluginManagementSnapshot(
            manifest: descriptor.pluginManifest, origin: .bundled, installationStatus: .installed,
            isEnabled: true, isRequired: false, isRunning: false, isQuarantined: false,
            isSuppressedBySafeMode: false, requiresRestart: false, canRollback: false,
            statusMessage: "Enabled", marketplace: nil
        )
        plugin.settings = descriptor.settings.map { .resolve($0, global: nil, project: nil) }
        let markers = PluginDetailLayoutMarkers()
        let host = NSHostingView(rootView: LitheSplitPaneView(
            axis: .horizontal, placement: .leading, defaultSize: 420,
            minimum: PluginManagementView.listMinimumWidth, maximum: PluginManagementView.listMaximumWidth,
            flexibleMinimum: PluginManagementView.detailMinimumWidth,
            sized: {
                Text("Installed plugins").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PluginDetailLayoutMarker { markers.sidebar = $0 })
            },
            flexible: {
                PluginDetailView(
                    plugin: plugin, summary: "", isEnabled: true, hasPendingChange: false,
                    isBusy: false, isApplyingChanges: false, updateVersion: nil, sourceName: nil, error: nil,
                    actions: PluginDetailActions(
                        toggleEnabled: {}, update: nil, reinstall: nil, uninstall: {}, restore: nil, rollback: nil,
                        settings: PluginSettingsHandlers(setValue: { _, _, _ in nil },
                            restartLanguageServers: {}, runAction: { _ in }, choosePath: { _ in nil }),
                        hasProject: true, openSettings: { _ in }
                    ), tab: .constant(.settings)
                ) {
                    Image(systemName: "cup.and.saucer").frame(width: 48, height: 48)
                }
                .background(PluginDetailLayoutMarker { markers.detail = $0 })
            }
        ).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let originalField = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        var initialTopInset: CGFloat?
        for (width, height) in [(1100.0, 650.0), (900, 500), (700, 700), (1000, 650)] {
            window.setContentSize(CGSize(width: width, height: height))
            host.layoutSubtreeIfNeeded()
            let sidebar = try #require(markers.sidebar)
            let detail = try #require(markers.detail)
            let left = sidebar.convert(sidebar.bounds, to: host)
            let right = detail.convert(detail.bounds, to: host)
            let divider = left.maxX + SplitHandleView.thickness
            #expect(abs(right.minX - divider) < 1, "\(width): detail \(right) must start after sidebar \(left)")
            #expect(right.maxX <= host.bounds.maxX + 1)
            for field in descendants(host).compactMap({ $0 as? NSTextField }).filter(\.isEditable) {
                let frame = field.convert(field.bounds, to: host)
                #expect(frame.minX >= divider)
                #expect(field === originalField)
            }
            let scroller = try #require(descendants(host).compactMap { $0 as? NSScrollView }.last {
                $0.hasHorizontalScroller && $0.hasVerticalScroller
            })
            let document = try #require(scroller.documentView)
            let fieldFrame = originalField.convert(originalField.bounds, to: host)
            let viewport = scroller.convert(scroller.bounds, to: host)
            let topInset = host.isFlipped ? fieldFrame.minY - viewport.minY : viewport.maxY - fieldFrame.maxY
            if let initialTopInset {
                #expect(abs(topInset - initialTopInset) < 1, "A short form stays at the top when the pane height changes")
            } else {
                initialTopInset = topInset
            }
            scroller.contentView.scroll(to: CGPoint(x: document.bounds.maxX - scroller.contentView.bounds.width, y: 0))
            scroller.reflectScrolledClipView(scroller.contentView)
            #expect(abs(scroller.contentView.bounds.maxX - document.bounds.maxX) < 1,
                    "The trailing settings remain reachable rather than being clipped")
            if let directory = ProcessInfo.processInfo.environment["LITHE_PLUGIN_DETAIL_LAYOUT_CAPTURES"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try data.write(to: output.appendingPathComponent("detail-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private final class PluginDetailLayoutMarkers {
    weak var sidebar: NSView?
    weak var detail: NSView?
}

private struct PluginDetailLayoutMarker: NSViewRepresentable {
    let record: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        record(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
