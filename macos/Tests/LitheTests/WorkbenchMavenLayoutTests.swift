import CoreGraphics
import Foundation
import Testing
@testable import Lithe

@Suite("Workbench Maven layout")
@MainActor
struct WorkbenchMavenLayoutTests {
    @Test func legacyLayoutStillDecodes() throws {
        let data = Data(#"{"sidebarWidth":320,"topPaneHeight":280}"#.utf8)
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: data)
        #expect(layout.sidebarWidth == 320)
        #expect(layout.topPaneHeight == 280)
        #expect(layout.mavenPaneWidth == nil)
        #expect(layout.branchPopupWidth == nil)
        #expect(layout.branchPopupHeight == nil)
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

    @Test func branchPopupSizeIsRestoredPerWorkspace() {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let first = URL(fileURLWithPath: "/fixture/branch-popup/first")
        let second = URL(fileURLWithPath: "/fixture/branch-popup/second")
        store.save(WorkbenchLayout(sidebarWidth: 300, topPaneHeight: 280,
                                   mavenPaneWidth: 410, branchPopupWidth: 620, branchPopupHeight: 560), for: first)
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, branchPopupWidth: 480, branchPopupHeight: 420), for: second)
        #expect(store.load(for: first).branchPopupWidth == 620)
        #expect(store.load(for: first).branchPopupHeight == 560)
        #expect(store.load(for: second).branchPopupHeight == 420)
        #expect(store.load(for: second).branchPopupWidth == 480)
        #expect(store.load(for: first).mavenPaneWidth == 410)
        #expect(store.load(for: first).topPaneHeight == 280)
    }

    @Test(arguments: [-1.0, 0.0, .infinity])
    func invalidBranchPopupWidthsFallBackToDefault(width: Double) {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/branch-popup/invalid")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, branchPopupWidth: width), for: workspace)
        #expect(store.load(for: workspace).branchPopupWidth == nil)
    }

    @Test(arguments: [-1.0, 0.0, .infinity])
    func invalidBranchPopupHeightsFallBackToDefault(height: Double) {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/branch-popup/invalid-height")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, branchPopupHeight: height), for: workspace)
        #expect(store.load(for: workspace).branchPopupHeight == nil)
    }

    @Test(arguments: [30.0, 219.0])
    func narrowSidebarWidthIsRestoredWithOtherLayoutValues(width: Double) {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/narrow-sidebar")
        store.save(WorkbenchLayout(sidebarWidth: width, topPaneHeight: 280, mavenPaneWidth: 410), for: workspace)

        let restored = store.load(for: workspace)
        #expect(restored.sidebarWidth == width)
        #expect(restored.topPaneHeight == 280)
        #expect(restored.mavenPaneWidth == 410)
    }

    @Test(arguments: [-1.0, 0.0, 29.0, .infinity])
    func invalidPersistedWidthsFallBackToDefault(width: Double) {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/project")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, mavenPaneWidth: width), for: workspace)
        #expect(store.load(for: workspace).mavenPaneWidth == nil)
    }

    @Test(arguments: [0.0, 40.0, 640.0, 760.0, 1024.0, 1440.0])
    func narrowWindowsNeverProduceNegativeOrOverflowingWidths(available: Double) {
        let maximum = WorkbenchRightToolGeometry.maximumWidth(in: available, sidebarWidth: 320, isSidebarVisible: true)
        let minimum = WorkbenchRightToolGeometry.minimumWidth(in: available, sidebarWidth: 320, isSidebarVisible: true)
        let resolved = WorkbenchRightToolGeometry.resolvedWidth(520, in: available, sidebarWidth: 320, isSidebarVisible: true)
        #expect(minimum >= 0)
        #expect(maximum >= minimum)
        #expect(resolved >= minimum)
        #expect(resolved <= maximum)
        #expect(resolved <= available)
        let reservedWidth = WorkbenchRightToolGeometry.minimumWorkspaceWidth(sidebarWidth: 320, isSidebarVisible: true)
        if available >= reservedWidth + SplitHandleView.thickness {
            #expect(available - resolved - SplitHandleView.thickness >= reservedWidth)
        }
    }

    @Test func narrowWindowDividerMouseUpDoesNotOverwritePreferredWidth() throws {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/project")
        store.save(WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, mavenPaneWidth: 410), for: workspace)
        let preferred = CGFloat(try #require(store.load(for: workspace).mavenPaneWidth))
        let narrowWidth = WorkbenchRightToolGeometry.resolvedWidth(preferred, in: 400, sidebarWidth: 320, isSidebarVisible: true)
        #expect(narrowWidth < preferred)

        if let committedWidth = WorkbenchRightToolGeometry.committedWidth(
            narrowWidth, preferredWidth: preferred, in: 400, sidebarWidth: 320, isSidebarVisible: true
        ) {
            store.save(
                WorkbenchLayout(sidebarWidth: 320, topPaneHeight: nil, mavenPaneWidth: Double(committedWidth)),
                for: workspace
            )
        }

        let restored = CGFloat(try #require(store.load(for: workspace).mavenPaneWidth))
        #expect(restored == preferred)
        #expect(WorkbenchRightToolGeometry.resolvedWidth(restored, in: 1440, sidebarWidth: 320, isSidebarVisible: true) == preferred)
        #expect(WorkbenchRightToolGeometry.committedWidth(
            380, preferredWidth: preferred, in: 1440, sidebarWidth: 320, isSidebarVisible: true
        ) == 380)
        #expect(WorkbenchRightToolGeometry.resolvedWidth(10, in: 1440, sidebarWidth: 320, isSidebarVisible: true) == 30)
        #expect(WorkbenchRightToolGeometry.resolvedWidth(900, in: 1440, sidebarWidth: 320, isSidebarVisible: true) == 900)
        #expect(WorkbenchRightToolGeometry.maximumWidth(in: 1440, sidebarWidth: 320, isSidebarVisible: true)
            == 1440 - 320 - 30 - SplitHandleView.thickness * 2)
        #expect(WorkbenchRightToolGeometry.maximumWidth(in: 1440, sidebarWidth: 320, isSidebarVisible: false)
            == 1440 - 30 - SplitHandleView.thickness)
        #expect(WorkbenchRightToolGeometry.maximumWidth(in: 1440, sidebarWidth: 500, isSidebarVisible: true)
            == 1440 - 500 - 30 - SplitHandleView.thickness * 2)
    }

    @Test func paneWidthsAboveTheOldFixedCapsRemainPersisted() {
        let store = WorkbenchLayoutStore(store: MavenLayoutTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/maven-layout/wide-pane")
        store.save(WorkbenchLayout(sidebarWidth: 800, topPaneHeight: nil, mavenPaneWidth: 900), for: workspace)
        #expect(store.load(for: workspace).sidebarWidth == 800)
        #expect(store.load(for: workspace).mavenPaneWidth == 900)
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
