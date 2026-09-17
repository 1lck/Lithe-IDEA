import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Editor close preparation")
struct EditorClosingPreparationTests {
    private func document(_ name: String) -> EditorDocument {
        EditorDocument(url: URL(fileURLWithPath: "/workspace/\(name)"), text: "text", modificationDate: nil)
    }

    @Test
    func holdsAllDocumentsUntilExplicitReleaseAndReleasesOnlyOnce() async throws {
        let first = document("first.java"), second = document("second.java")
        var held: [String] = []
        var released: [String] = []
        first.holdEditorForClose = { completion in
            held.append("first")
            completion(.success { released.append("first") })
        }
        second.holdEditorForClose = { completion in
            held.append("second")
            completion(.success { released.append("second") })
        }
        let preparation = try await EditorClosingPreparation.acquire([first, second])
        defer { preparation.release() }
        #expect(held == ["first", "second"])
        #expect(released.isEmpty)
        #expect(preparation.matches([second, first]))
        #expect(!preparation.matches([first]))
        #expect(!preparation.matches([first, document("second.java")]))
        preparation.release()
        preparation.release()
        #expect(released == ["second", "first"])
    }

    @Test
    func failedAcquisitionReleasesEarlierDocuments() async {
        let first = document("first.java"), second = document("second.java")
        var releases = 0
        first.holdEditorForClose = { completion in
            completion(.success { releases += 1 })
        }
        second.holdEditorForClose = { completion in
            completion(.failure(EditorDocument.DocumentError.editorNotSynchronized))
        }
        do {
            let unexpected = try await EditorClosingPreparation.acquire([first, second])
            unexpected.release()
            Issue.record("Failed editor acquisition unexpectedly succeeded")
        } catch {
            #expect(error is EditorDocument.DocumentError)
        }
        #expect(releases == 1)
    }
}
