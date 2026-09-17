import Foundation

/// Owns remote editor locks across confirmation, saving, and asynchronous teardown.
@MainActor
final class EditorClosingPreparation {
    private let documents: [EditorDocument]
    private var releases: [EditorDocument.EditorRelease] = []

    private init(documents: [EditorDocument]) { self.documents = documents }

    static func acquire(_ documents: [EditorDocument]) async throws -> EditorClosingPreparation {
        let preparation = EditorClosingPreparation(documents: documents)
        do {
            for document in documents {
                try Task.checkCancellation()
                guard let hold = document.holdEditorForClose else { continue }
                let result: Result<EditorDocument.EditorRelease, Error> = await withCheckedContinuation { continuation in
                    hold { continuation.resume(returning: $0) }
                }
                preparation.releases.append(try result.get())
            }
            try Task.checkCancellation()
            return preparation
        } catch {
            preparation.release()
            throw error
        }
    }

    func matches(_ current: [EditorDocument]) -> Bool {
        Set(documents.map(ObjectIdentifier.init)) == Set(current.map(ObjectIdentifier.init))
    }

    func release() {
        let pending = releases
        releases.removeAll()
        for release in pending.reversed() { release() }
    }
}
