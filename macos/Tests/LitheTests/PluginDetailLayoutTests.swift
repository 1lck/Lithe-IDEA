import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

@MainActor
@Suite("Plugin detail action layout", .serialized)
struct PluginDetailLayoutTests {
    @Test(arguments: ["en", "zh-Hans"], [ColorScheme.dark, .light])
    func longVersionAndAllActionsFitTheMinimumSettingsWindow(language: String, scheme: ColorScheme) async throws {
        MacBundledFontRegistry.registerFonts()
        let manifest = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(version: PluginVersion(major: 1, minor: 0, patch: 0))
        ).pluginManifest
        var plugin = PluginManagementSnapshot(manifest: manifest, origin: .community,
            installationStatus: .installed, isEnabled: true, isRequired: false, isRunning: true,
            isQuarantined: false, isSuppressedBySafeMode: false, requiresRestart: true,
            canRollback: false, statusMessage: "Running", marketplace: nil)
        plugin.hasChangesPendingRestart = true
        var updates = 0
        let actions = PluginDetailActions(toggleEnabled: {}, update: { updates += 1 }, reinstall: {},
            uninstall: {}, restore: nil, rollback: nil,
            settings: PluginSettingsHandlers(setValue: { _, _, _ in nil }, restartLanguageServers: {},
                runAction: { _ in }, choosePath: { _ in nil }),
            hasProject: false, openSettings: { _ in })
        let host = NSHostingView(rootView: PluginDetailView(plugin: plugin, summary: "", isEnabled: true,
            hasPendingChange: false, isBusy: false, isApplyingChanges: false,
            updateVersion: "2026.10.22-preview.1234567890", sourceName: nil, error: nil,
            actions: actions, tab: .constant(.overview), icon: { Color.clear.frame(width: 48, height: 48) })
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
            .environment(\.restartApplication, ApplicationRestartAction(perform: {})))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 668),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        // The 900pt Settings window shares width with its category sidebar and
        // plugin list. Also exercise the actual detail splitter's 160pt limit.
        let detailWidth = 900 - SettingsView.categoryMinimumWidth - PluginManagementView.listMinimumWidth
            - 2 * SplitHandleView.thickness
        for width in [CGFloat(1000), detailWidth, PluginManagementView.detailMinimumWidth, CGFloat(1000)] {
            host.setFrameSize(NSSize(width: width, height: 668))
            host.layoutSubtreeIfNeeded()
            var frames: [NSRect] = []
            for identifier in ["toggle", "update", "reinstall", "remove", "restart"] {
                let frame = try await AgentNativeControlTestSupport.frame(of: "plugin-detail-\(identifier)", in: host)
                #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5, "\(identifier) overflows \(width)pt")
                #expect(frame.minY >= 0 && frame.maxY <= host.bounds.height)
                #expect(abs(frame.height - LitheTheme.ActionButton.height) < 0.5)
                #expect(frame.width >= LitheTheme.ActionButton.minimumWidth - 0.5)
                #expect(frames.allSatisfy { !$0.intersects(frame) })
                frames.append(frame)
            }
            if width == 1000 {
                #expect(Set(frames.map { Int($0.midY.rounded()) }).count == 1, "Wide actions should stay in one row")
                #expect(frames[1].width > 200, "Wide update action must show the full target version")
            }
            if width == PluginManagementView.detailMinimumWidth {
                #expect(Set(frames.map { Int($0.midY.rounded()) }).count == 5, "All actions must stack")
                // The compact label still invokes the original update action.
                let frame = frames[1]
                let point = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                #expect(updates == 1)
            }
        }
    }
}
