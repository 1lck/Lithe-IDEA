import AppKit
import Combine
import Foundation
import Testing
import SwiftUI
@testable import Lithe

@Suite("Media document tabs")
@MainActor
struct MediaDocumentFeatureModelTests {
    @Test
    func recognizesSupportedImageAndVideoExtensionsCaseInsensitively() {
        #expect(MediaDocumentKind.from(fileExtension: "PNG") == .image)
        #expect(MediaDocumentKind.from(url: URL(fileURLWithPath: "/tmp/preview.Mp4")) == .video)
        #expect(MediaDocumentKind.from(fileExtension: "svg") == nil)
        #expect(MediaDocumentKind.from(fileExtension: "SVG") == nil)
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

    @Test(arguments: [false, true])
    func svgOpeningKeepsTheEditableDocument(standalone: Bool) async throws {
        let appModel = makeAppModel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let svgURL = directory.appendingPathComponent("icon.SVG")
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>"
        try source.write(to: svgURL, atomically: true, encoding: .utf8)
        let opened = TestGate()
        let subscription = appModel.documentFeature.$activeDocumentID.compactMap { $0 }.sink { _ in
            opened.open()
        }
        defer {
            subscription.cancel()
            opened.open()
            appModel.documentFeature.reset()
        }
        if standalone {
            appModel.openStandaloneFile(svgURL)
        } else {
            // Seed a real text document without starting workspace watchers or language servers.
            appModel.documentFeature.openStandaloneFile(svgURL)
        }
        #expect(await opened.waitUntilOpen(), "SVG text document should finish opening")
        let document = try #require(appModel.activeDocument)
        if !standalone {
            appModel.openFile(svgURL)
            #expect(appModel.activeDocument?.id == document.id)
        }
        #expect(document.url == svgURL)
        #expect(document.text == source)
        #expect(!document.isReadOnly)
        #expect(appModel.activeMediaDocument == nil)
        document.text = source.replacingOccurrences(of: "20", with: "30")
        try document.save()
        #expect(try String(contentsOf: svgURL, encoding: .utf8) == document.text)
        #expect(!document.isDirty)
    }

    @Test
    func svgLiveEditsNotifyPreviewAfterEveryEditWithoutRepeatedPageInvalidation() {
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/lithe-fixture/icon.svg"),
            text: "<svg/>", modificationDate: nil
        )
        var previewUpdates = 0
        var pageUpdates = 0
        let preview = document.textDidChange.sink { previewUpdates += 1 }
        let page = document.objectWillChange.sink { pageUpdates += 1 }
        defer { preview.cancel(); page.cancel() }
        document.applyLiveEditorText("<svg>first</svg>")
        document.applyLiveEditorText("<svg>second</svg>")
        #expect(previewUpdates == 2)
        #expect(pageUpdates == 1)
        #expect(document.text == "<svg>second</svg>")
        #expect(document.isDirty)
    }

    @Test
    func svgPreviewDecodesUnsavedSourceAndRejectsInvalidXML() throws {
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"30\"><rect width=\"20\" height=\"30\" fill=\"red\"/></svg>"
        let image = try #require(NSImage(data: Data(source.utf8)))
        #expect(image.size.width == 20)
        #expect(image.size.height == 30)
        #expect(NSImage(data: Data("not XML".utf8)) == nil)
    }

    @Test(arguments: [false, true])
    func svgPreviewMountsImageAndKeepsEditorHeaderAtTop(split: Bool) async throws {
        let appModel = makeAppModel()
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/tmp/lithe-fixture/execute.svg"),
            text: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><path d=\"M3 2L14 8L3 14Z\" fill=\"green\"/></svg>",
            modificationDate: nil
        )
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            Text("Editor tabs").frame(height: 30)
            if split {
                SVGEditorSplitView(editor: Color.clear, document: document)
            } else {
                SVGPreviewView(document: document)
            }
        }.environmentObject(appModel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func imageView(in view: NSView) -> NSImageView? {
            if let image = view as? NSImageView, image.image != nil { return image }
            return view.subviews.lazy.compactMap { imageView(in: $0) }.first
        }
        let image = try #require(imageView(in: hosting), "Preview must mount a native image on its first layout")
        #expect(image.image?.size == NSSize(width: 16, height: 16))
        let scroll = try #require(image.enclosingScrollView)
        #expect(scroll.bounds.height > 400, "Preview must fill the area below the editor tabs")
        let source = document.text
        var previousPixels = try #require(image.image?.tiffRepresentation)
        for color in ["red", "blue"] {
            document.applyLiveEditorText(source.replacingOccurrences(of: "green", with: color))
            // The native image update is the observable rendering boundary. Bound
            // polling by a monotonic deadline; no sleep is used to synchronize it.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while imageView(in: hosting)?.image?.tiffRepresentation == previousPixels,
                  clock.now < deadline {
                await Task.yield()
                hosting.layoutSubtreeIfNeeded()
            }
            let pixels = try #require(imageView(in: hosting)?.image?.tiffRepresentation)
            #expect(pixels != previousPixels, "Successive unsaved edits must update the native image")
            previousPixels = pixels
        }
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
