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
    func backgroundMediaOpenPreservesTheCurrentSelection() {
        let feature = MediaDocumentFeatureModel()
        let active = feature.open(url: URL(fileURLWithPath: "/tmp/active.png"), kind: .image)
        let background = feature.open(
            url: URL(fileURLWithPath: "/tmp/background.png"),
            kind: .image,
            activateWhenReady: false
        )

        #expect(feature.openMediaDocuments.map(\.id) == [active.id, background.id])
        #expect(feature.activeMediaDocumentID == active.id)
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

    @Test
    func selectingATextDocumentClearsTheActiveMediaDocument() throws {
        let appModel = makeAppModel()
        appModel.openMediaFile(URL(fileURLWithPath: "/tmp/image.png"), kind: .image)
        let documentURL = try #require(URL(string: "lithe-test://documents/Example.swift"))

        appModel.documentFeature.openVirtualDocument(
            documentURL,
            text: "let value = 1",
            displayPath: nil
        )

        #expect(appModel.activeDocument?.url == documentURL)
        #expect(appModel.activeMediaDocument == nil)
    }

    @Test
    func closingAStandaloneMediaDocumentClosesTheStandaloneFile() throws {
        let appModel = makeAppModel()
        let mediaURL = URL(fileURLWithPath: "/tmp/preview.png")
        appModel.openStandaloneFile(mediaURL)
        let media = try #require(appModel.activeMediaDocument)

        appModel.closeMediaDocument(media)

        #expect(appModel.standaloneFileURL == nil)
        #expect(appModel.openMediaDocuments.isEmpty)
    }

    private func makeAppModel() -> AppModel {
        let store = MediaDocumentTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        return AppModel(settings: settings, services: services)
    }
}

private final class MediaDocumentTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
