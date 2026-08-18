import Combine
import Foundation
import Testing
@testable import Lithe

@MainActor
struct EditorDiagnosticsStoreTests {
    @Test
    func unchangedDiagnosticsDoNotPublish() {
        let store = EditorDiagnosticsStore()
        let url = URL(fileURLWithPath: "/workspace/App.java")
        let diagnostic = EditorDiagnostic(
            id: "d1",
            fileURL: url,
            line: 1,
            utf16Column: 0,
            endLine: 1,
            endUTF16Column: 4,
            severity: .warning,
            message: "unused",
            source: nil,
            code: nil,
            tags: [],
            relatedInformation: []
        )
        store.replace([url: [diagnostic]])

        var publishCount = 0
        let observation = store.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        store.replace([url: [diagnostic]])
        #expect(publishCount == 0)

        store.replace([:])
        #expect(publishCount == 1)
        #expect(store.diagnostics(for: url).isEmpty)
    }
}
