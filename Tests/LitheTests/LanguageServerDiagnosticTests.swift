import Foundation
import Testing
@testable import Lithe

@Suite("Language server diagnostics")
struct LanguageServerDiagnosticTests {
    @Test
    func bridgePreservesMissingSeverityTagsAndRelatedInformation() throws {
        let payload = try JSONDecoder().decode(
            RustCoreBridge.LspClientDiagnosticPayload.self,
            from: Data(#"""
            {
              "range": {
                "start": { "line": 2, "utf16Column": 4 },
                "end": { "line": 2, "utf16Column": 9 }
              },
              "message": "Example diagnostic",
              "source": "pyright",
              "code": "reportGeneralTypeIssues",
              "tags": [1, 2, 99],
              "relatedInformation": [{
                "location": {
                  "uri": "file:///tmp/project/types.py",
                  "range": {
                    "start": { "line": 8, "utf16Column": 2 },
                    "end": { "line": 8, "utf16Column": 7 }
                  }
                },
                "message": "Type declared here"
              }]
            }
            """#.utf8)
        )

        let diagnostic = payload.makeModel()

        #expect(diagnostic.severity == nil)
        #expect(diagnostic.tags == [1, 2, 99])
        #expect(diagnostic.relatedInformation.count == 1)
        #expect(diagnostic.relatedInformation[0].fileURL.path == "/tmp/project/types.py")
        #expect(diagnostic.relatedInformation[0].range.start.line == 8)
        #expect(diagnostic.relatedInformation[0].range.start.utf16Column == 2)
        #expect(diagnostic.relatedInformation[0].message == "Type declared here")
    }

    @Test
    func editorDiagnosticMapsMissingSeverityToUnknownAndKnownTagsToUIModels() {
        let fileURL = URL(fileURLWithPath: "/tmp/project/main.py")
        let relatedURL = URL(fileURLWithPath: "/tmp/project/types.py")
        let diagnostic = LanguageServerDiagnostic(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 2, utf16Column: 4),
                end: LanguageServerPosition(line: 2, utf16Column: 9)
            ),
            severity: nil,
            message: "Example diagnostic",
            source: "pyright",
            code: "reportGeneralTypeIssues",
            tags: [1, 2, 99],
            relatedInformation: [
                LanguageServerDiagnosticRelatedInformation(
                    fileURL: relatedURL,
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: 8, utf16Column: 2),
                        end: LanguageServerPosition(line: 8, utf16Column: 7)
                    ),
                    message: "Type declared here"
                )
            ]
        )

        let editorDiagnostic = EditorDiagnostic(
            languageServerDiagnostic: diagnostic,
            fileURL: fileURL
        )

        #expect(editorDiagnostic.severity == .unknown)
        #expect(editorDiagnostic.tags == [.unnecessary, .deprecated])
        #expect(editorDiagnostic.relatedInformation.count == 1)
        #expect(editorDiagnostic.relatedInformation[0].fileURL == relatedURL.standardizedFileURL)
        #expect(editorDiagnostic.relatedInformation[0].line == 8)
        #expect(editorDiagnostic.relatedInformation[0].utf16Column == 2)
        #expect(editorDiagnostic.relatedInformation[0].message == "Type declared here")
    }

    @Test(arguments: [Optional<Int>.none, .some(0), .some(5), .some(99)])
    func missingAndUnsupportedSeveritiesNeverBecomeErrors(_ rawSeverity: Int?) {
        let diagnostic = LanguageServerDiagnostic(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 0, utf16Column: 0),
                end: LanguageServerPosition(line: 0, utf16Column: 1)
            ),
            severity: rawSeverity,
            message: "Unknown severity",
            source: "test",
            code: nil
        )

        let editorDiagnostic = EditorDiagnostic(
            languageServerDiagnostic: diagnostic,
            fileURL: URL(fileURLWithPath: "/tmp/project/main.py")
        )

        #expect(editorDiagnostic.severity == .unknown)
        #expect(editorDiagnostic.severity != .error)
    }
}
