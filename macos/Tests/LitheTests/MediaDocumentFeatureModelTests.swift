import Foundation
import Testing
@testable import Lithe

@Suite("Media document tabs")
@MainActor
struct MediaDocumentFeatureModelTests {
    @Test
    func recognizesSupportedImageAndVideoExtensionsCaseInsensitively() {
        #expect(MediaDocumentKind.from(fileExtension: "PNG") == .image)
        #expect(MediaDocumentKind.from(url: URL(fileURLWithPath: "/tmp/preview.Mp4")) == .video)
        #expect(MediaDocumentKind.from(fileExtension: "svg") == nil)
        #expect(MediaDocumentKind.from(fileExtension: "bin") == nil)
    }

    @Test
    func openingTheSamePathReusesTheExistingMediaDocument() {
        let feature = MediaDocumentFeatureModel()
        let first = feature.open(
            url: URL(fileURLWithPath: "/tmp/assets/icon.png"),
            kind: .image
        )
        let reopened = feature.open(
            url: URL(fileURLWithPath: "/tmp/assets/./icon.png"),
            kind: .image
        )

        #expect(reopened.id == first.id)
        #expect(feature.openMediaDocuments.count == 1)
        #expect(feature.activeMediaDocumentID == first.id)
    }

    @Test
    func closingTheActiveMediaSelectsTheNextDocumentOrLastRemainingDocument() {
        let feature = MediaDocumentFeatureModel()
        let first = feature.open(url: URL(fileURLWithPath: "/tmp/first.png"), kind: .image)
        let second = feature.open(url: URL(fileURLWithPath: "/tmp/second.mp4"), kind: .video)
        let third = feature.open(url: URL(fileURLWithPath: "/tmp/third.png"), kind: .image)

        feature.select(second)
        feature.close(second)
        #expect(feature.activeMediaDocumentID == third.id)

        feature.close(third)
        #expect(feature.activeMediaDocumentID == first.id)

        feature.close(first)
        #expect(feature.openMediaDocuments.isEmpty)
        #expect(feature.activeMediaDocumentID == nil)
    }

    @Test
    func selectingUnknownOrDeactivatingDoesNotMutateOpenDocuments() {
        let feature = MediaDocumentFeatureModel()
        let document = feature.open(url: URL(fileURLWithPath: "/tmp/image.jpg"), kind: .image)
        let unknown = MediaDocument(url: URL(fileURLWithPath: "/tmp/unknown.jpg"), kind: .image)

        feature.select(unknown)
        #expect(feature.activeMediaDocumentID == document.id)
        #expect(feature.openMediaDocuments.count == 1)

        feature.deactivate()
        #expect(feature.activeMediaDocument == nil)
        #expect(feature.openMediaDocuments.count == 1)
    }

    @Test
    func resetClosesAllMediaDocumentsAndClearsSelection() {
        let feature = MediaDocumentFeatureModel()
        _ = feature.open(url: URL(fileURLWithPath: "/tmp/image.png"), kind: .image)
        _ = feature.open(url: URL(fileURLWithPath: "/tmp/video.mov"), kind: .video)

        feature.reset()

        #expect(feature.openMediaDocuments.isEmpty)
        #expect(feature.activeMediaDocumentID == nil)
    }
}
