import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Agent and Maven appearance", .serialized)
struct AgentMavenAppearanceTests {
    @Test func agentSurfacesFollowThemeChangesInBothAppearances() throws {
        let original = AppThemeRuntime.shared.activeTheme
        defer { AppThemeRuntime.shared.activate(original) }
        for theme in AppColorTheme.allCases {
            AppThemeRuntime.shared.activate(theme)
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                appearance.performAsCurrentDrawingAppearance {
                    for (agent, shared) in [
                        (AgentPanelStyle.canvas, LitheTheme.editor),
                        (AgentPanelStyle.header, LitheTheme.toolHeader),
                        (AgentPanelStyle.context, LitheTheme.raised),
                        (AgentPanelStyle.toolbar, LitheTheme.editor),
                        (AgentPanelStyle.border, LitheTheme.panelBorder)
                    ] {
                        #expect(NSColor(agent).usingColorSpace(.sRGB) == NSColor(shared).usingColorSpace(.sRGB))
                    }
                }
            }
        }
    }

    @Test func mavenSVGsHaveNativeGeometryAndVisiblePixels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/IDEAIcons")
        for path in ["expui/run/run.svg", "expui/run/stop.svg", "expui/run/showIgnored.svg",
                     "expui/general/runAnything.svg", "expui/general/refresh.svg",
                     "expui/general/collapseAll.svg", "expui/general/settings.svg",
                     "expui/build/taskGroup.svg", "expui/nodes/library.svg",
                     "expui/nodes/libraryFolder.svg", "maven/expui/build/mavenProject.svg",
                     "maven/expui/build/mavenProfiles.svg", "maven/expui/toolwindow/maven.svg", "maven/task.svg"] {
            for resource in [path, LitheIcons.darkIdeaAssetPath(for: path)] {
                let icon = try #require(NSImage(contentsOf: root.appendingPathComponent(resource)), "Missing \(resource)")
                let width: CGFloat = path == "maven/expui/build/mavenProfiles.svg" ? 17 : 16
                #expect(icon.size == NSSize(width: width, height: 16), "Native SVG geometry: \(resource)")
                let tiff = try #require(icon.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                #expect((0..<bitmap.pixelsWide).contains { x in
                    (0..<bitmap.pixelsHigh).contains { y in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                    }
                }, "Empty SVG render: \(resource)")
            }
        }
    }
}
