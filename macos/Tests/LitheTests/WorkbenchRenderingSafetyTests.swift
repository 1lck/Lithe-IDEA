import Foundation
import Testing
@testable import Lithe

@Suite("Workbench rendering safety")
struct WorkbenchRenderingSafetyTests {
    @Test
    func workspaceReservesTheRightActivityBar() {
        #expect(WorkbenchLayoutMetrics.workspaceTrailingInset == WorkbenchLayoutMetrics.rightActivityBarWidth)
    }

    @Test
    func workbenchDoesNotFlattenPlatformBackedViews() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbenchURL = repositoryRoot.appendingPathComponent(
            "Sources/Lithe/Views/Workbench/WorkbenchView.swift"
        )
        let source = try String(contentsOf: workbenchURL, encoding: .utf8)

        #expect(
            source.range(of: #"\.drawingGroup\b"#, options: .regularExpression) == nil,
            "WorkbenchView contains NSViewRepresentable content and must not be flattened with drawingGroup()."
        )
    }

    @Test
    func workbenchKeepsCustomSwitchersAlongsideExecutionControls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbenchURL = repositoryRoot.appendingPathComponent(
            "Sources/Lithe/Views/Workbench/WorkbenchView.swift"
        )
        let source = try String(contentsOf: workbenchURL, encoding: .utf8)

        #expect(source.contains(".overlayPreferenceValue(ProjectSwitcherButtonBoundsPreferenceKey.self)"))
        #expect(source.contains(".overlayPreferenceValue(BranchSwitcherButtonBoundsPreferenceKey.self)"))
        #expect(source.contains(".sheet(item: $pendingTopBarPushReference)"))
        #expect(source.contains("GitPushDialog("))
        #expect(source.contains("run-selected-run-configuration"))
        #expect(source.contains("debug-selected-run-configuration"))
        #expect(!source.contains(".popover(isPresented: $isProjectSwitcherPresented"))
        #expect(!source.contains(".popover(isPresented: $isBranchSwitcherPresented"))
    }
}
