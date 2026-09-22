import Foundation
import LitheCoreContracts
import Testing

/// The caret rule behind the editor's Run context menu and keyboard shortcut.
/// It mirrors `frontend/editor/src/run-markers.ts`, which the macOS Monaco
/// host uses for the same decision.
struct JavaRunMarkerTests {
    private let markers = [
        JavaRunMarker(line: 2, endLine: 2, kind: .main, label: "App.main()", mainClass: "demo.App"),
        JavaRunMarker(line: 5, endLine: 14, kind: .testClass, label: "OrderTest", testClass: "demo.OrderTest"),
        JavaRunMarker(line: 7, endLine: 7, kind: .testMethod, label: "OrderTest.creates", testClass: "demo.OrderTest", testMethod: "creates"),
        JavaRunMarker(line: 10, endLine: 13, kind: .testClass, label: "Refunds", testClass: "demo.OrderTest$Refunds"),
    ]

    @Test
    func caretPicksTheInnermostTestDeclaration() {
        #expect(JavaRunMarker.forLine(7, in: markers)?.label == "OrderTest.creates")
        #expect(JavaRunMarker.forLine(11, in: markers)?.label == "Refunds")
        #expect(JavaRunMarker.forLine(14, in: markers)?.label == "OrderTest")
    }

    @Test
    func caretOutsideTestsFallsBackToTheFilesMain() {
        #expect(JavaRunMarker.forLine(0, in: markers)?.label == "App.main()")
        #expect(JavaRunMarker.forLine(1, in: []) == nil)
    }

    // Debugging re-resolves the Java Test item, whose names carry parameter
    // lists (`OrderTest#creates()`); only its JDT id matches reliably.
    @Test
    func testMethodsRunByMavenSelectorAndDebugByJavaTestItem() {
        let method = JavaRunMarker(
            line: 7, endLine: 7, kind: .testMethod, label: "OrderTest.creates",
            testClass: "demo.OrderTest", testMethod: "creates", testItemId: "app@demo.OrderTest#creates()"
        )
        #expect(method.testIdentifier(forDebugging: false) == "demo.OrderTest#creates")
        #expect(method.testIdentifier(forDebugging: true) == "app@demo.OrderTest#creates()")
        let nested = JavaRunMarker(
            line: 10, endLine: 13, kind: .testClass, label: "Refunds", testClass: "demo.OrderTest$Refunds"
        )
        #expect(nested.testIdentifier(forDebugging: false) == "demo.OrderTest$Refunds")
        #expect(nested.testIdentifier(forDebugging: true) == "demo.OrderTest$Refunds")
        #expect(markers[0].testIdentifier(forDebugging: false) == nil)
    }

    @Test
    func coreMarkerPayloadDecodes() throws {
        let data = Data(#"{"line":3,"endLine":3,"kind":"main","label":"App.main()","mainClass":"demo.App","status":"none"}"#.utf8)
        let marker = try JSONDecoder().decode(JavaRunMarker.self, from: data)
        #expect(marker == JavaRunMarker(line: 3, endLine: 3, kind: .main, label: "App.main()", mainClass: "demo.App"))
    }
}
