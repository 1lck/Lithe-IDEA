import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Problems panel presentation", .serialized)
struct ProblemsPanelPresentationTests {
    @Test(arguments: ["fileTypes/yaml.svg", "nodes/class.svg", "expui/nodes/runnableMark.svg"])
    func fileIconsHaveDistinctThemeVariantsAtNativeSize(path: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        let light = try #require(NSImage(contentsOf: root.appendingPathComponent(path)))
        let dark = try #require(NSImage(contentsOf: root.appendingPathComponent(LitheIcons.darkIdeaAssetPath(for: path))))
        #expect(light.size == NSSize(width: 16, height: 16))
        #expect(dark.size == light.size)
        #expect(try #require(light.tiffRepresentation) != #require(dark.tiffRepresentation))
    }

    @Test func fileScopeClearsForAgentEditorAndRestoresTextDocument() throws {
        let domain = "Lithe.ProblemsSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let url = try #require(URL(string: "lithe-fixture://workspace/Main.java"))
        model.documentFeature.openVirtualDocument(url, text: "class Main {}", displayPath: nil)
        let document = try #require(model.activeDocument)
        #expect(ProblemsPanelScope.currentFileURL(in: model) == url)
        model.showAgentChatsInEditor()
        #expect(model.isAgentEditorSelected)
        #expect(model.activeDocument === document, "Agent selection retains the previous document")
        #expect(ProblemsPanelScope.currentFileURL(in: model) == nil)
        model.selectEditorTab(.document(document.id))
        #expect(!model.isAgentEditorSelected)
        #expect(ProblemsPanelScope.currentFileURL(in: model) == url)
    }

    @Test
    func fileScopeFollowsSelectedURLAndKeepsWorkspaceDiagnostics() {
        let first = URL(fileURLWithPath: "/workspace/one/Main.java")
        let second = URL(fileURLWithPath: "/workspace/two/Main.java")
        let store = EditorDiagnosticsStore()
        let problem = EditorDiagnostic(id: "second", fileURL: second, line: 5, utf16Column: 2,
            endLine: 5, endUTF16Column: 3, severity: .warning, message: "Example warning",
            source: "test", code: nil, tags: [], relatedInformation: [])
        store.replace([first: [], second: [problem]])

        #expect(ProblemsPanelScope.file.diagnostics(in: store.diagnosticsByURL, currentFileURL: first).isEmpty)
        #expect(ProblemsPanelScope.file.diagnostics(in: store.diagnosticsByURL,
            currentFileURL: second.deletingLastPathComponent().appendingPathComponent("./Main.java")) == [problem])
        // No selected text editor must not fall back to the first file with diagnostics.
        #expect(ProblemsPanelScope.file.diagnostics(in: store.diagnosticsByURL, currentFileURL: nil).isEmpty)
        #expect(ProblemsPanelScope.projectErrors.diagnostics(in: store.diagnosticsByURL, currentFileURL: nil) == [problem])
        #expect(store.diagnostics(for: second) == [problem])
    }

    #if DEBUG
    @Test func demoCoversEverySeverityTagsRelatedInformationAndLongMessages() {
        let root = URL(fileURLWithPath: "/demo")
        let groups = ProblemsDemoData.diagnostics(at: root)
        let diagnostics = groups.values.flatMap { $0 }
        #expect(Set(diagnostics.map(\.severity)) == Set(DiagnosticSeverity.allCases))
        #expect(diagnostics.contains { $0.tags.contains(.unnecessary) })
        #expect(diagnostics.contains { $0.tags.contains(.deprecated) })
        #expect(diagnostics.contains { !$0.relatedInformation.isEmpty })
        #expect(diagnostics.contains { $0.message.contains("\n") && $0.message.count > 160 })
        #expect(groups.count > 1)
        for diagnostic in diagnostics {
            let path = diagnostic.fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = ProblemsDemoData.files[path]
            #expect(source != nil)
            #expect(diagnostic.line < (source?.components(separatedBy: "\n").count ?? 0))
        }
    }
    #endif

    @Test(arguments: ["en", "zh-Hans"])
    func problemsTextFollowsInterfaceLocale(language: String) throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(url: resources))
        let english = try #require(Bundle(url: resources.appendingPathComponent("en.lproj")))
        let file = URL(fileURLWithPath: "/workspace/Main.java")
        let chinese = language == "zh-Hans"
        let cases: [(LocalizedStringKey, String)] = [
            (ProblemsPanelScope.projectErrors.title, chinese ? "项目错误" : "Project Errors"),
            (ProblemsPanelScope.file.emptyTitle(currentFileURL: nil),
             chinese ? "在编辑器中打开文件以查看问题" : "Open file in editor to see problems"),
            (ProblemsPanelScope.file.emptyTitle(currentFileURL: file),
             chinese ? "Main.java 中没有问题" : "No problems in Main.java"),
            ("Problems could be filtered out", chinese ? "问题可能已被筛选隐藏" : "Problems could be filtered out"),
            ("Could not load file preview", chinese ? "无法加载文件预览" : "Could not load file preview")
        ]
        func render(_ title: LocalizedStringKey, bundle: Bundle, locale: Locale) throws -> Data {
            let renderer = ImageRenderer(content: ProblemsEmptyState(title: title, details: nil, bundle: bundle)
                .frame(width: 650, height: 180).environment(\.locale, locale))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        for (key, expected) in cases {
            let actual = try render(key, bundle: bundle, locale: Locale(identifier: language))
            // Pin the reference to English resources so Chinese reference text stays verbatim.
            let reference = try render(LocalizedStringKey(expected), bundle: english, locale: Locale(identifier: "en"))
            #expect(actual == reference, "Wrong interface language for: \(expected)")
        }
    }

    @Test(arguments: [ColorScheme.dark, .light], [CGFloat(320), 900])
    func emptyStatusUsesUpperThirdAndSharedMutedText(scheme: ColorScheme, width: CGFloat) throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/Inter-Regular.otf")
        let ownsFont = NSFont(name: "Inter-Regular", size: 13) == nil
        if ownsFont {
            #expect(CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil))
        }
        defer {
            if ownsFont { CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, nil) }
        }
        #expect(LitheTheme.uiNSFont(size: 13).fontName == "Inter-Regular")
        let content = ProblemsEmptyState(title: "No problems in Main.java", details: nil)
            .frame(width: width, height: 300)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var points: [(Int, Int)] = []
        var solidPixel: Int?
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                guard pixels[offset + 3] == 255 else { continue }
                points.append((x, y))
                solidPixel = offset
            }
        }
        let minX = try #require(points.map(\.0).min())
        let maxX = try #require(points.map(\.0).max())
        let minY = try #require(points.map(\.1).min())
        let maxY = try #require(points.map(\.1).max())
        #expect(abs(CGFloat(minX + maxX) / 2 - width / 2) < 3)
        #expect(minY >= 90 && maxY <= 120)
        let offset = try #require(solidPixel)
        #expect(abs(Int(pixels[offset]) - 115) <= 2)
        #expect(abs(Int(pixels[offset + 1]) - 118) <= 2)
        #expect(abs(Int(pixels[offset + 2]) - 124) <= 2)
        if let directory = ProcessInfo.processInfo.environment["LITHE_PROBLEMS_SNAPSHOT_DIR"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let preview = ImageRenderer(content: content.background(LitheTheme.editor)
                .environment(\.colorScheme, scheme))
            preview.scale = 2
            let previewImage = try #require(preview.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: previewImage)
                .representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("empty-\(scheme)-\(Int(width)).png"))
        }
    }
}
