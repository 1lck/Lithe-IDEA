import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Agent Hook settings appearance")
@MainActor
struct AgentHooksAppearanceTests {
    @Test(arguments: [false, true])
    func nativeSettingsShowCommandsAndKeepControlsWithinTheWindow(_ dark: Bool) async throws {
        let service = HookTestService()
        let feature = AgentHooksFeatureModel(service: service)
        await feature.load()
        for language in ["en", "zh-Hans"] {
            let resources = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("macos/Resources")
            let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
            for width in [CGFloat(500), CGFloat(800)] {
                let expectedReads = await service.reads + 1
                let root = SettingsAppearanceContainer(themePreference: dark ? .dark : .light) {
                    ScrollView { AgentHooksSettingsView(localizationBundle: bundle, feature: feature).padding(16) }
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
                // Mounting schedules a view-owned refresh. Wait until that
                // observable request completes before inspecting enabled controls.
                while clock.now < deadline {
                    if await service.reads >= expectedReads, feature.phase == .ready { break }
                    await Task.yield()
                }
                #expect(await service.reads >= expectedReads && feature.phase == .ready)
                host.layoutSubtreeIfNeeded()
                // ViewThatFits has a larger ideal width; protect the actual
                // interactive field geometry instead of its unconstrained ideal.
                let fields = editableFields(host)
                #expect(!fields.isEmpty)
                for field in fields {
                    let rect = field.convert(field.bounds, to: host)
                    #expect(rect.minX >= 0 && rect.maxX <= width + 1)
                }
                #expect(feature.entries.first?.hook.command == "printf done")
                let folder = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/test-stability/hooks-ui")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("hooks-\(dark ? "dark" : "light")-\(language)-\(Int(width)).png"))
            }
        }
    }

    @Test(arguments: [false, true])
    func nativeEditorShowsSelectedEventAndKeepsUnicodeDraftUntilSave(_ dark: Bool) async throws {
        for language in ["en", "zh-Hans"] {
            let service = HookTestService()
            let feature = AgentHooksFeatureModel(service: service)
            await feature.load()
            feature.draft = AgentHook(name: "custom_notify", description: "文件编辑后处理", event: .afterTool,
                                      matcher: .edit, command: "printf done", timeoutSeconds: 30)
            let resources = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("macos/Resources")
            let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
            let root = SettingsAppearanceContainer(themePreference: dark ? .dark : .light) {
                AgentHooksSettingsView(localizationBundle: bundle, feature: feature).padding(16)
            }.environment(\.locale, Locale(identifier: language))
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer {
                for sheet in window.sheets { window.endSheet(sheet); sheet.close() }
                window.contentView = nil; window.close()
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while window.sheets.isEmpty && clock.now < deadline { await Task.yield() }
            let sheet = try #require(window.sheets.first)
            while clock.now < deadline {
                if await service.reads >= 2, feature.phase == .ready { break }
                await Task.yield()
            }
            #expect(await service.reads >= 2 && feature.phase == .ready)
            let content = try #require(sheet.contentView)
            content.layoutSubtreeIfNeeded()
            let editor = try #require(textViews(content).first { $0.string == "printf done" })
            let description = try #require(textViews(content).first { $0.string == "文件编辑后处理" })
            let name = try #require(editableFields(content).first { $0.stringValue == "custom_notify" })
            let descriptionScroll = try #require(description.enclosingScrollView)
            let commandScroll = try #require(editor.enclosingScrollView)
            let nameRect = name.convert(name.bounds, to: content)
            let descriptionRect = descriptionScroll.convert(descriptionScroll.bounds, to: content)
            let commandRect = commandScroll.convert(commandScroll.bounds, to: content)
            #expect(abs(descriptionRect.minX - commandRect.minX) < 1)
            #expect(abs(nameRect.minX - descriptionRect.minX) <= 10)
            #expect(descriptionRect.height > commandRect.height)
            for rect in [nameRect, descriptionRect, commandRect] {
                #expect(rect.minX >= 0 && rect.maxX <= content.bounds.width + 1)
            }
            #expect(editor.isEditable)
            #expect(feature.draft?.event == .afterTool && feature.draft?.matcher == .edit)
            sheet.makeFirstResponder(editor)
            editor.insertText(" 中文", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            let typingDeadline = clock.now.advanced(by: .seconds(2))
            while feature.draft?.command != "printf done 中文" && clock.now < typingDeadline { await Task.yield() }
            #expect(feature.draft?.command == "printf done 中文")
            sheet.makeFirstResponder(description)
            description.insertText("\n第二行说明", replacementRange: NSRange(location: description.string.utf16.count, length: 0))
            let descriptionDeadline = clock.now.advanced(by: .seconds(2))
            while feature.draft?.description != "文件编辑后处理\n第二行说明" && clock.now < descriptionDeadline { await Task.yield() }
            #expect(feature.draft?.description == "文件编辑后处理\n第二行说明")
            #expect(feature.canSave)
            #expect(feature.library?.hooks.count == 1, "native typing must not save automatically")
            let folder = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/test-stability/hooks-ui")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("hook-editor-\(dark ? "dark" : "light")-\(language).png"))
        }
    }

    private func editableFields(_ view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap(editableFields)
    }
    private func textViews(_ view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap(textViews)
    }
}
