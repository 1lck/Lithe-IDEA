import Testing
@testable import Lithe

@MainActor
struct DocumentSaveBatchTests {
    private final class Owner: UnsavedDocumentHandling {
        var closingDocuments: [EditorDocument] { [] }
        var hasUnsavedDocuments = true
        var unsavedDocumentNames: [String] { hasUnsavedDocuments ? ["fixture.txt"] : [] }
        var onSave: (() async -> Bool)?
        var saveCount = 0

        func saveAllDocuments() async -> Bool {
            saveCount += 1
            hasUnsavedDocuments = false
            return await onSave?() ?? true
        }
    }

    @Test func laterSaveCannotAuthorizeClosingAnEarlierOwnerWithNewEdits() async {
        let first = Owner()
        let second = Owner()
        second.onSave = {
            #expect(first.saveCount == 1)
            #expect(!first.hasUnsavedDocuments)
            // Input (or a formatting response) arrives after A saved, while B saves.
            first.hasUnsavedDocuments = true
            return true
        }

        #expect(await !DocumentSaveBatch.save { [first, second] })
        #expect(first.hasUnsavedDocuments)
        #expect(second.saveCount == 1)
    }

    @Test func newDirtySessionDuringSavePreventsClose() async {
        let first = Owner()
        let newSession = Owner()
        var owners = [first]
        first.onSave = { owners.append(newSession); return true }
        defer { first.onSave = nil }

        #expect(await !DocumentSaveBatch.save { owners })
        #expect(newSession.saveCount == 0)
        #expect(newSession.hasUnsavedDocuments)
    }

    @Test func successfulSaveOnlyChecksTheRequestedWindowScope() async {
        let scoped = Owner()
        let otherWindow = Owner()

        #expect(await DocumentSaveBatch.save { [scoped] })
        #expect(!scoped.hasUnsavedDocuments)
        #expect(otherWindow.saveCount == 0)
        #expect(otherWindow.hasUnsavedDocuments)
    }

    @Test func failedSavePreventsCloseEvenIfOwnerIsNowClean() async {
        let owner = Owner()
        owner.onSave = { false }
        #expect(await !DocumentSaveBatch.save { [owner] })
    }
}
