import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Global instruction settings appearance")
@MainActor
struct AgentInstructionsAppearanceTests {
    @Test(arguments: [false, true])
    func nativeEditorFitsSettingsAndPreservesUnicode(_ dark: Bool) async throws {
        let feature = AgentInstructionsFeatureModel(service: AppearanceInstructions())
        await feature.load()
        for language in ["en", "zh-Hans"] {
            let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources")
            let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
            #expect(AgentLocalization.string("Instructions", locale: Locale(identifier: language), bundle: bundle)
                    == (language == "en" ? "Instructions" : "指令"))
            for width in [CGFloat(500), CGFloat(760)] {
                let root = SettingsAppearanceContainer(themePreference: dark ? .dark : .light) {
                    ScrollView { AgentInstructionsSettingsView(localizationBundle: bundle, feature: feature).padding(16) }
                }.environment(\.locale, Locale(identifier: language))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 660),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.contentView = nil; window.close() }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                var editors: [NSTextView] = []
                while clock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    editors = textViews(host).filter { $0.string == AppearanceInstructions.text }
                    if !editors.isEmpty { break }
                    await Task.yield()
                }
                let editor = try #require(editors.first, "the shared editor must host native UTF-8 text")
                let rect = editor.convert(editor.bounds, to: host)
                #expect(rect.minX >= 0 && rect.maxX <= width + 1)
                #expect(editor.isEditable)
                #expect(feature.file?.path == "/fixture/user/.codex/AGENTS.md")
                if let folder = ProcessInfo.processInfo.environment["LITHE_INSTRUCTIONS_SCREENSHOTS"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let path = URL(fileURLWithPath: folder).appendingPathComponent("instructions-\(dark ? "dark" : "light")-\(language)-\(Int(width)).png")
                    try png.write(to: path)
                }
                // Exercise native typing through SwiftUI's binding, not just model.edit.
                window.makeFirstResponder(editor)
                editor.insertText("\n原生输入", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                let typingDeadline = clock.now.advanced(by: .seconds(2))
                while !feature.draft.hasSuffix("原生输入") && clock.now < typingDeadline { await Task.yield() }
                #expect(feature.draft == AppearanceInstructions.text + "\n原生输入")
                #expect(feature.canSave)
                #expect(feature.file?.content == AppearanceInstructions.text, "typing must not save automatically")
                feature.edit(AppearanceInstructions.text)
            }
        }
    }

    private func textViews(_ view: NSView) -> [NSTextView] {
        if let editor = view as? NSTextView { return [editor] }
        return view.subviews.flatMap(textViews)
    }
}

private struct AppearanceInstructions: AgentInstructionsService {
    static let text = "# 全局指令\n\n使用简体中文回复。\n保留代码标识符和命令的原始拼写。\n"
    func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile {
        AgentInstructionFile(agentId: agent.rawValue, path: "/fixture/user/.codex/AGENTS.md",
                             content: Self.text, exists: true, revision: "fixture")
    }
    func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile { file }
}

@Suite("Global instruction contract")
struct AgentInstructionsContractTests {
    @Test func sharedSnapshotsDecodeOnBothPlatforms() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let file: AgentInstructionFile; let windowsFile: AgentInstructionFile }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/agent-instructions-v1.json")))
        #expect(fixture.file.agentId == "codex-acp")
        #expect(fixture.file.revision.count == 64)
        #expect(fixture.windowsFile.agentId == "claude-acp")
        #expect(fixture.windowsFile.path == "C:\\Users\\fixture\\.claude\\CLAUDE.md")
    }
}
