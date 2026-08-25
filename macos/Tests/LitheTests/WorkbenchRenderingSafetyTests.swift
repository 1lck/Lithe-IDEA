import Foundation
import Testing

@Suite("Workbench rendering safety")
struct WorkbenchRenderingSafetyTests {
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
}
