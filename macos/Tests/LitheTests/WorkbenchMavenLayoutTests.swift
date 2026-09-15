import CoreGraphics
import Foundation
import Testing
@testable import Lithe

@Suite("Workbench Maven layout")
struct WorkbenchMavenLayoutTests {
    @Test func legacyLayoutStillDecodes() throws {
        let data = Data(#"{"sidebarWidth":320,"topPaneHeight":280}"#.utf8)
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: data)
        #expect(layout.sidebarWidth == 320)
        #expect(layout.topPaneHeight == 280)
        #expect(layout.mavenPaneWidth == nil)
    }

    @Test func committedMavenWidthIsRestoredPerWorkspace() {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/project")
        store.save(WorkbenchLayout(sidebarWidth: 300, topPaneHeight: 280, mavenPaneWidth: 410), for: workspace)
        let restored = store.load(for: workspace)
        #expect(restored.mavenPaneWidth == 410)
        #expect(restored.sidebarWidth == 300)
        #expect(restored.topPaneHeight == 280)
        #expect(store.load(for: URL(fileURLWithPath: "/fixture/maven-layout/other")).mavenPaneWidth == nil)
    }

    @Test(arguments: [-1.0, 0.0, 521.0])
    func invalidPersistedWidthsFallBackToDefault(width: Double) {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/project")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, mavenPaneWidth: width), for: workspace)
        #expect(store.load(for: workspace).mavenPaneWidth == nil)
    }

    @Test(arguments: [0.0, 640.0, 760.0, 1024.0, 1440.0])
    func narrowWindowsNeverProduceNegativeOrOverflowingWidths(available: Double) {
        let maximum = WorkbenchRightToolGeometry.maximumWidth(in: available)
        let minimum = WorkbenchRightToolGeometry.minimumWidth(in: available)
        let resolved = WorkbenchRightToolGeometry.resolvedWidth(520, in: available)
        #expect(minimum >= 0)
        #expect(maximum >= minimum)
        #expect(resolved >= minimum)
        #expect(resolved <= maximum)
        #expect(resolved <= available)
        if available >= WorkbenchRightToolGeometry.minimumWorkspaceWidth + SplitHandleView.thickness {
            #expect(available - resolved - SplitHandleView.thickness >= WorkbenchRightToolGeometry.minimumWorkspaceWidth)
        }
    }

    @Test func narrowWindowDividerMouseUpDoesNotOverwritePreferredWidth() throws {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/project")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, mavenPaneWidth: 410), for: workspace)
        let preferred = CGFloat(try #require(store.load(for: workspace).mavenPaneWidth))
        let narrowWidth = WorkbenchRightToolGeometry.resolvedWidth(preferred, in: 760)
        #expect(narrowWidth < preferred)

        if let committedWidth = WorkbenchRightToolGeometry.committedWidth(narrowWidth, in: 760) {
            store.save(
                WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, mavenPaneWidth: Double(committedWidth)),
                for: workspace
            )
        }

        let restored = CGFloat(try #require(store.load(for: workspace).mavenPaneWidth))
        #expect(restored == preferred)
        #expect(WorkbenchRightToolGeometry.resolvedWidth(restored, in: 1440) == preferred)
        #expect(WorkbenchRightToolGeometry.committedWidth(380, in: 1440) == 380)
        #expect(WorkbenchRightToolGeometry.resolvedWidth(10, in: 1440) == 300)
        #expect(WorkbenchRightToolGeometry.resolvedWidth(900, in: 1440) == 520)
    }
}

private final class MavenLayoutTestStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
