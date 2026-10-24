import AppKit
import SwiftUI
import Foundation
import Testing
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

@MainActor
private struct NativePanelDockFixture: View {
    let visible: Set<String>
    let panel: (String) -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if visible.contains("left") { panel("left") }
                if visible.contains("right") { panel("right") }
            }
            if visible.contains("bottom") { panel("bottom") }
        }
    }
}

@MainActor
@Suite("Native plugin UI", .serialized)
struct PluginNativeUITests {
    private func declaration(kind: String = "tree") throws -> PluginNativeUI {
        try JSONDecoder().decode(PluginNativeUI.self, from: Data("""
        {"schemaVersion":1,"id":"explorer","kind":"\(kind)","nodes":[],
         "source":{"buildSystemID":"sample","function":"ui.nodes"},
         "actions":[{"id":"refresh","title":"Refresh","kind":"refresh","requiresSelection":false},
         {"id":"inspect","title":"Inspect","kind":"invoke","function":"ui.inspect","requiresSelection":true}],
         "toolbar":["refresh","inspect"],"contextMenu":["inspect"]}
        """.utf8))
    }
    private var data: ToolingJSONValue {
        .object(["nodes": .array([.object(["id": .string("parent"), "label": .string("Parent"),
            "children": .array([.object(["id": .string("child"), "label": .string("Child")])])])])])
    }
    private var instances: ToolingJSONValue {
        .object(["instances": .array([.object(["id": .string("own"), "buildSystemID": .string("sample")])])])
    }

    private func formDeclaration(dynamic: Bool = false, disabled: Bool = false) throws -> PluginNativeUI {
        let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/native-form.plugin.json"))
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: data)
        let form = try #require(descriptor.pluginManifest.modules.flatMap(\.contributions).first { $0.nativeUI != nil }?.nativeUI)
        guard dynamic || disabled else { return form }
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(form)) as? [String: Any])
        value["source"] = ["buildSystemID": "sample", "function": "form.nodes"]
        value["actions"] = [["id": "changed", "title": "Changed", "kind": "invoke", "function": "form.changed", "requiresSelection": false]]
        var controls = try #require(value["controls"] as? [[String: Any]])
        controls[0]["onCommit"] = "changed"
        if disabled { controls = controls.map { $0.merging(["enabled": false]) { _, new in new } } }
        value["controls"] = controls
        return try JSONDecoder().decode(PluginNativeUI.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func formValuesRestoreWithCurrentTypesOptionsAndBudgets() throws {
        let declaration = try formDeclaration()
        // States saved before forms were added must remain decodable.
        let old = try JSONDecoder().decode(PluginNativeUIFeature.State.self, from: Data("{\"expanded\":[]}".utf8))
        #expect(old.values == nil)
        let state = PluginNativeUIFeature.State(values: ["name": .text("保存的中文 😀"), "environment": .text("removed"),
                                                       "notify": .text("wrong type"), "stale": .checked(true)])
        var saves = 0
        let feature = PluginNativeUIFeature(declaration: declaration, state: state,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes,
            request: { _, _ in .null }, saveState: { _ in saves += 1 })
        defer { feature.close() }
        let name = try #require(declaration.controls?.first { $0.id == "name" })
        let environment = try #require(declaration.controls?.first { $0.id == "environment" })
        let notify = try #require(declaration.controls?.first { $0.id == "notify" })
        #expect(feature.value(for: name) == .text("保存的中文 😀"))
        #expect(feature.value(for: environment) == .text("dev"))
        #expect(feature.value(for: notify) == .checked(true))
        #expect(feature.state.values?.count == 1)
        #expect(!feature.setValue(.checked(false), for: name))
        #expect(!feature.setValue(.text("not-an-option"), for: environment))
        #expect(!feature.setValue(.text(String(repeating: "😀", count: 257)), for: name))
        #expect(feature.setValue(.text("更新 English / 中文 / 😀"), for: name))
        #expect(saves == 1)
        feature.close()
        #expect(!feature.setValue(.text("after-close"), for: name))
        #expect(saves == 1)
    }

    @Test func disabledFormControlsCannotEditOrCommit() throws {
        let declaration = try formDeclaration(dynamic: true, disabled: true)
        let feature = PluginNativeUIFeature(declaration: declaration,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes,
            request: { _, _ in Issue.record("Disabled controls must not invoke the bridge"); return .null })
        defer { feature.close() }
        for control in declaration.controls ?? [] {
            let changed: PluginNativeUI.ControlValue = control.kind == .checkbox ? .checked(false) : .text("test")
            #expect(!feature.setValue(changed, for: control))
            #expect(feature.commit(control) == nil)
            #expect(feature.value(for: control) == control.value)
        }
    }

    @Test func formCommitUsesExistingBridgeAndCapturesAllCurrentValues() async throws {
        let declaration = try formDeclaration(dynamic: true)
        var calls: [ToolingJSONValue] = []
        let feature = PluginNativeUIFeature(declaration: declaration,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, params in
                if method == "build.instances" { return instances }
                calls.append(params)
                if case .object(let body) = params, body["function"] == .string("form.changed") {
                    return .object(["value": .object(["message": .string("Received")])])
                }
                return .object(["value": .object(["nodes": .array([])])])
            })
        defer { feature.close() }
        let controls = try #require(declaration.controls)
        let name = try #require(controls.first { $0.id == "name" })
        let environment = try #require(controls.first { $0.id == "environment" })
        let notify = try #require(controls.first { $0.id == "notify" })
        #expect(feature.setValue(.text("中文 😀"), for: name))
        #expect(feature.setValue(.text("prod"), for: environment))
        #expect(feature.setValue(.checked(false), for: notify))
        let pending = try #require(feature.commit(name))
        #expect(!feature.setValue(.text("while-busy"), for: name))
        await pending.value
        let values: ToolingJSONValue = .object(["name": .string("中文 😀"), "query": .string(""),
                                              "environment": .string("prod"), "notify": .bool(false)])
        #expect(calls == [
            .object(["instance": .string("own"), "function": .string("form.changed"),
                     "params": .object(["selectedID": .null, "values": values])]),
            .object(["instance": .string("own"), "function": .string("form.nodes"), "params": .object(["values": values])]),
        ])
        #expect(feature.message == "Received")
        #expect(feature.error == nil)
        let restored = try JSONDecoder().decode(PluginNativeUIFeature.State.self, from: JSONEncoder().encode(feature.state))
        #expect(restored.values?["name"] == .text("中文 😀"))
    }

    @Test func mountedFormUsesNativeFieldsSelectorAndCheckbox() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        let declaration = try formDeclaration()
        let feature = PluginNativeUIFeature(declaration: declaration,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { _, _ in .null })
        let host = NSHostingView(rootView: PluginNativePanel(
            contribution: ModuleContribution(id: "example.form", kind: .toolWindow, title: "Form", nativeUI: declaration),
            feature: feature, onMinimize: {}).frame(width: 400, height: 420))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { feature.close(); window.contentView = nil; window.close() }
        func find(_ value: Any, role: NSAccessibility.Role) -> AnyObject? {
            let item = value as AnyObject
            if item.accessibilityRole?() == role { return item }
            return (item.accessibilityChildren?() ?? []).lazy.compactMap { find($0, role: role) }.first
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        var checkbox: AnyObject?
        repeat {
            host.layoutSubtreeIfNeeded()
            checkbox = find(host, role: .checkBox)
            if checkbox != nil { break }
            await Task.yield()
        } while clock.now < deadline
        #expect(find(host, role: .textField) != nil)
        let check = try #require(checkbox)
        #expect(check.accessibilityPerformPress?() == true)
        let notify = try #require(declaration.controls?.first { $0.id == "notify" })
        #expect(feature.value(for: notify) == .checked(false))
        // The selector's trigger is a real shared button, rather than a drawn dropdown.
        func hasSelector(_ value: Any) -> Bool {
            let item = value as AnyObject
            if item.accessibilityRole?() == .button, item.accessibilityLabel?() == "环境（切换后自动提交）" { return true }
            return (item.accessibilityChildren?() ?? []).contains { hasSelector($0) }
        }
        #expect(hasSelector(host))
    }

    private func publicControlsDeclaration() throws -> PluginNativeUI {
        let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/native-controls.plugin.json"))
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: data)
        return try #require(descriptor.pluginManifest.modules.flatMap(\.contributions).compactMap(\.nativeUI).first)
    }

    @Test func publicControlsKeepTypedStateAndButtonsInvokeWithoutBecomingValues() async throws {
        let declaration = try publicControlsDeclaration()
        var calls: [ToolingJSONValue] = []
        let feature = PluginNativeUIFeature(declaration: declaration,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, params in
                if method == "build.instances" { return instances }
                calls.append(params)
                return .object(["value": .object(["nodes": .array([]), "message": .string("Done")])])
            })
        defer { feature.close() }
        let controls = try #require(declaration.controls)
        let editor = try #require(controls.first { $0.kind == .editor })
        let segmented = try #require(controls.first { $0.kind == .segmented })
        let stepper = try #require(controls.first { $0.kind == .stepper })
        #expect(feature.setValue(.text("中文\nEnglish 😀"), for: editor))
        #expect(feature.commit(editor) == nil)
        #expect(feature.setValue(.text("debug"), for: segmented))
        #expect(!feature.setValue(.text("missing"), for: segmented))
        #expect(!feature.setValue(.number(.infinity), for: stepper))
        #expect(!feature.setValue(.number(9), for: stepper))
        #expect(feature.setValue(.number(3), for: stepper))
        let buttons = try #require(declaration.buttons)
        let disabled = try #require(buttons.first { $0.enabled == false })
        #expect(!feature.canPerform(disabled))
        #expect(feature.perform(disabled) == nil)
        #expect(calls.isEmpty)
        let submit = try #require(buttons.first)
        let pending = try #require(feature.perform(submit))
        #expect(!feature.canPerform(submit))
        await pending.value
        let first = try #require(calls.first)
        guard case .object(let invoke) = first, case .object(let params)? = invoke["params"],
              case .object(let values)? = params["values"] else {
            Issue.record("Form buttons must use the existing function envelope"); return
        }
        #expect(values[editor.id] == .string("中文\nEnglish 😀"))
        #expect(values[stepper.id] == .number(3))
        #expect(values[segmented.id] == .string("debug"))
        #expect(values.count == controls.count)
        #expect(buttons.allSatisfy { values[$0.id] == nil })
        let restored = try JSONDecoder().decode(PluginNativeUIFeature.State.self, from: JSONEncoder().encode(feature.state))
        #expect(restored.values?[stepper.id] == .number(3))
        feature.close()
        #expect(feature.perform(submit) == nil)
    }

    @Test func mountedPublicControlsExposeInfoAndAllSharedControlKinds() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        let declaration = try publicControlsDeclaration()
        let feature = PluginNativeUIFeature(declaration: declaration,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { _, _ in .null })
        let host = NSHostingView(rootView: PluginNativePanel(
            contribution: ModuleContribution(id: "example.controls", kind: .toolWindow, title: "Controls", nativeUI: declaration),
            feature: feature, onMinimize: {}).frame(width: 1000, height: 1400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { feature.close(); window.contentView = nil; window.close() }
        func descendants(_ value: Any) -> [AnyObject] {
            let item = value as AnyObject
            return [item] + (item.accessibilityChildren?() ?? []).flatMap { descendants($0) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        var elements: [AnyObject] = []
        repeat {
            host.layoutSubtreeIfNeeded()
            elements = descendants(host)
            if elements.contains(where: { $0.accessibilityIdentifier?() == "native-button-secondary-fill" }) { break }
            await Task.yield()
        } while clock.now < deadline
        #expect(elements.contains { $0.accessibilityRole?() == .textArea })
        #expect(elements.contains { $0.accessibilityHelp?() == declaration.controls?.first?.info })
        for id in ["search", "notes", "mode", "concurrency"] {
            #expect(elements.contains { $0.accessibilityIdentifier?() == "native-control-" + id })
        }
        let legacyFill = try #require(elements.first {
            $0.accessibilityIdentifier?() == "native-button-secondary-fill" && $0.accessibilityRole?() == .button
        })
        let buttonFrame = try #require(legacyFill.accessibilityFrame?())
        #expect(buttonFrame.height == 28, "Declarative actions must not reintroduce the old 3pt external inset")
        #expect(buttonFrame.width >= 72 && buttonFrame.width < 300, "Legacy fill hints must not stretch shared buttons")
        let disabled = try #require(elements.first {
            $0.accessibilityIdentifier?() == "native-button-disabled-button" && $0.accessibilityRole?() == .button
        })
        #expect(disabled.isAccessibilityEnabled?() == false)
        // Disabled controls must not disable the separate explanatory buttons.
        let disabledHints = Set((declaration.controls ?? []).filter { $0.enabled == false }.compactMap(\.info))
        let tips = elements.filter { $0.accessibilityRole?() == .button && disabledHints.contains($0.accessibilityHelp?() ?? "") }
        #expect(tips.count >= disabledHints.count)
        #expect(tips.allSatisfy { $0.isAccessibilityEnabled?() == true })
        let tip = try #require(tips.first)
        #expect(tip.accessibilityPerformPress?() == true)
        let tipDeadline = clock.now.advanced(by: .seconds(1))
        while window.childWindows?.contains(where: \.isVisible) != true && clock.now < tipDeadline { await Task.yield() }
        #expect(window.childWindows?.contains(where: \.isVisible) == true)
        #expect(tip.accessibilityPerformPress?() == true)
    }

    @Test func sharedFixtureRegistersItsNativeRenderer() throws {
        let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/native-panel.plugin.json"))
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: data)
        let window = try #require(descriptor.pluginManifest.modules.flatMap(\.contributions)
            .first(where: { $0.nativeUI != nil }))
        #expect(window.hasDeclarativeContent)
        #expect(window.nativeUI?.source?.buildSystemID == "sample")
        let catalog = try ValidatedPluginCatalog(manifests: BuiltInPluginCatalog.manifests + [descriptor.pluginManifest],
            hostVersion: BuiltInPluginCatalog.hostVersion)
        let registry = try WorkbenchModuleUIComposition.registry(for: catalog)
        #expect(registry.renderer(for: window) != nil)
    }

    @Test func mountedPanelKeepsItsFeatureWhenInitialContentAppears() async throws {
        let loaded = TestGate()
        defer { loaded.open() }
        let declaration = try declaration()
        var creations = 0
        var releases = 0
        var feature: PluginNativeUIFeature?
        let contribution = ModuleContribution(id: "example.panel", kind: .toolWindow, title: "Sample Explorer", nativeUI: declaration)
        let view = PluginNativeToolWindowView(contribution: contribution, makeFeature: {
            creations += 1
            let created = PluginNativeUIFeature(declaration: declaration,
                validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, _ in
                    if method == "build.instances" { return instances }
                    return .object(["value": data])
                }, saveState: { _ in loaded.open() })
            feature = created
            return created
        }, releaseFeature: { releases += 1; $0.close() }, onMinimize: {})
        let host = NSHostingView(rootView: AnyView(VStack(spacing: 0) { view }))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { feature?.close(); host.rootView = AnyView(EmptyView()); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(await loaded.waitUntilOpen())
        // Publishing the feature changes the child from empty to a real panel;
        // that must not tear down the window's own request lifecycle.
        host.layoutSubtreeIfNeeded()
        #expect(creations == 1)
        #expect(releases == 0)
        #expect(feature?.rows.map(\.id) == ["parent"])
        #expect(feature?.error == nil)
    }

    @Test func switchingNativePanelsInOneDockSlotReleasesTheCorrectWindow() async throws {
        let pages = PluginWebPages()
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { host.rootView = AnyView(EmptyView()); pages.closeAll(); window.contentView = nil; window.close() }
        var previousRelease: TestGate?
        var failures: [String] = []
        var gates: [TestGate] = []
        defer { gates.forEach { $0.open() } }
        // All panels use the same SwiftUI renderer type in a reused dock slot.
        // A single-panel mount cannot detect release using a different window ID.
        for id in ["tree", "static-tree", "list", "empty", "tree", "static-tree"] {
            let appeared = TestGate()
            let released = TestGate()
            gates += [appeared, released]
            let declaration = try JSONDecoder().decode(PluginNativeUI.self, from: Data("""
                {"schemaVersion":1,"id":"\(id)","kind":"list","nodes":[{"id":"item","label":"\(id)"}],
                "actions":[],"toolbar":[],"contextMenu":[]}
                """.utf8))
            let contribution = ModuleContribution(id: "example.\(id)", kind: .toolWindow, title: id, nativeUI: declaration)
            let view = PluginNativeToolWindowView(contribution: contribution, makeFeature: {
                defer { appeared.open() }
                let feature = PluginNativeUIFeature(declaration: declaration,
                    validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { _, _ in .null })
                guard pages.registerNative(feature, windowID: contribution.id, pluginID: "example") else {
                    feature.close()
                    failures.append(id)
                    throw PluginWebBridgeFailure.unavailable("Duplicate panel registration")
                }
                return feature
            }, releaseFeature: {
                pages.releaseNative($0, windowID: contribution.id)
                released.open()
            }, onMinimize: {})
            host.rootView = AnyView(VStack(spacing: 0) { view })
            host.layoutSubtreeIfNeeded()
            #expect(await appeared.waitUntilOpen())
            if let previousRelease { #expect(await previousRelease.waitUntilOpen()) }
            #expect(pages.openWindowIDs == [contribution.id])
            #expect(failures.isEmpty)
            previousRelease = released
        }
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        if let previousRelease { #expect(await previousRelease.waitUntilOpen()) }
        #expect(pages.openWindowIDs.isEmpty)
    }

    @Test func threeDockedPanelsCanHideAndReopenWithoutLeakingRegistrations() async throws {
        let pages = PluginWebPages()
        let declaration = try JSONDecoder().decode(PluginNativeUI.self, from: Data("""
            {"schemaVersion":1,"id":"static","kind":"list","nodes":[{"id":"item","label":"Item"}],
            "actions":[],"toolbar":[],"contextMenu":[]}
            """.utf8))
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { host.rootView = AnyView(EmptyView()); pages.closeAll(); window.contentView = nil; window.close() }
        var appearances: [String: TestGate] = [:]
        var releases: [String: TestGate] = [:]
        var gates: [TestGate] = []
        var failures: [String] = []
        defer { gates.forEach { $0.open() } }
        func panel(_ id: String) -> AnyView {
            let contribution = ModuleContribution(id: id, kind: .toolWindow, title: id, nativeUI: declaration)
            return AnyView(PluginNativeToolWindowView(contribution: contribution, makeFeature: {
                defer { appearances[id]?.open() }
                let feature = PluginNativeUIFeature(declaration: declaration,
                    validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { _, _ in .null })
                guard pages.registerNative(feature, windowID: id, pluginID: "example") else {
                    feature.close()
                    failures.append(id)
                    throw PluginWebBridgeFailure.unavailable("Duplicate panel registration")
                }
                return feature
            }, releaseFeature: {
                pages.releaseNative($0, windowID: id)
                releases[id]?.open()
            }, onMinimize: {}))
        }
        var previous: Set<String> = []
        let scenarios: [Set<String>] = [
            ["left", "right", "bottom"], ["right", "bottom"], ["left", "right", "bottom"],
            ["left", "bottom"], ["left", "right", "bottom"], [], ["left", "right", "bottom"], []
        ]
        for visible in scenarios {
            let added = visible.subtracting(previous)
            let removed = previous.subtracting(visible)
            for id in added { let gate = TestGate(); appearances[id] = gate; gates.append(gate) }
            for id in removed { let gate = TestGate(); releases[id] = gate; gates.append(gate) }
            host.rootView = AnyView(NativePanelDockFixture(visible: visible, panel: panel))
            host.layoutSubtreeIfNeeded()
            for id in added { #expect(await appearances[id]!.waitUntilOpen()) }
            for id in removed { #expect(await releases[id]!.waitUntilOpen()) }
            #expect(pages.openWindowIDs == visible)
            #expect(failures.isEmpty)
            previous = visible
        }
    }

    @Test func nativePanelsRenderInBothAppearances() async throws {
        for kind in ["tree", "list"] {
            let flat: ToolingJSONValue = .object(["nodes": .array([
                .object(["id": .string("first"), "label": .string("First item")]),
                .object(["id": .string("second"), "label": .string("Second item")])])])
            let feature = PluginNativeUIFeature(declaration: try declaration(kind: kind), validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, _ in
                if method == "build.instances" { return instances }
                return .object(["value": kind == "tree" ? data : flat])
            })
            defer { feature.close() }
            await feature.refresh()?.value
            if kind == "tree" { feature.toggle("parent") }
            feature.select(kind == "tree" ? "child" : "first")
            for dark in [false, true] {
                let contribution = ModuleContribution(id: "example.panel", kind: .toolWindow, title: "Sample Explorer",
                    nativeUI: feature.declaration)
                let host = NSHostingView(rootView: PluginNativePanel(contribution: contribution,
                    feature: feature, onMinimize: {}).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width > 0 && host.fittingSize.height > 0)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let selectedY = LitheTheme.Metrics.toolWindowHeaderHeight + LitheTheme.Tree.verticalInset
                    + LitheTheme.Tree.rowHeight * (kind == "tree" ? 1.5 : 0.5)
                let leftX = Int(LitheTheme.Tree.horizontalInset / 2 * scale)
                let rightX = bitmap.pixelsWide - leftX - 1
                let y = Int(selectedY * scale)
                let background = try #require(bitmap.colorAt(x: leftX, y: bitmap.pixelsHigh - 8))
                // The shared hover/selection background must leave both outer gutters clear.
                #expect(bitmap.colorAt(x: leftX, y: y) == background)
                #expect(bitmap.colorAt(x: rightX, y: y) == background)
                #expect(bitmap.colorAt(x: Int((LitheTheme.Tree.horizontalInset + 4) * scale), y: y) != background)
                if let directory = ProcessInfo.processInfo.environment["LITHE_NATIVE_UI_CAPTURE_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-\(kind)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test(arguments: [false, true]) func sharedHeaderOwnsCurrentHeightWithoutTitleIconsOrBorders(dark: Bool) throws {
        let host = NSHostingView(rootView: LitheToolWindowHeader(title: "UI Lab", usesWorkbenchSurface: false) {
            EmptyView()
        }.environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 41)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == 41)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let bottom = bitmap.pixelsHigh - 1
        let innerX = Int(4 * scale)
        // A title-only header has no icon, outline or bottom rule.
        #expect(bitmap.colorAt(x: innerX, y: bottom) == bitmap.colorAt(x: 0, y: bottom))
        #expect(bitmap.colorAt(x: innerX, y: bottom) == bitmap.colorAt(x: innerX, y: bottom - Int(2 * scale)))
        #expect(bitmap.colorAt(x: 0, y: bottom) == bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bottom))
    }

    @Test func refreshSelectionActionAndExpansionUseStableIDs() async throws {
        var calls: [ToolingJSONValue] = []
        var saved = PluginNativeUIFeature.State()
        let feature = PluginNativeUIFeature(declaration: try declaration(), validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, params in
            if method == "build.instances" { return instances }
            calls.append(params)
            if case .object(let body) = params, body["function"] == .string("ui.inspect") {
                return .object(["value": .object(["message": .string("Done")])])
            }
            return .object(["value": data])
        }, saveState: { saved = $0 })
        defer { feature.close() }
        let inspect = try #require(feature.declaration.actions.last)
        #expect(!feature.canPerform(inspect))
        await feature.refresh()?.value
        #expect(feature.rows.map(\.id) == ["parent"])
        feature.toggle("parent")
        feature.select("child")
        #expect(feature.canPerform(inspect))
        await feature.perform(inspect)?.value
        #expect(calls.count == 3)
        #expect(calls[1] == .object(["instance": .string("own"), "function": .string("ui.inspect"),
            "params": .object(["selectedID": .string("child")])]))
        #expect(feature.message == "Done")
        #expect(saved.selection == "child")
        feature.toggle("parent")
        #expect(feature.state.selection == "parent")
    }

    @Test func invalidAndOversizedDataNeverReplaceDisplayedRows() async throws {
        let valid = try DeclarativePluginTestSupport.operations.validateNativeNodes(ui: declaration(), data: data)
        #expect(valid.count == 1)
        #expect(throws: (any Error).self) { try DeclarativePluginTestSupport.operations.validateNativeNodes(ui: declaration(kind: "list"), data: data) }
        let duplicate: ToolingJSONValue = .object(["nodes": .array([
            .object(["id": .string("same"), "label": .string("One")]),
            .object(["id": .string("same"), "label": .string("Two")])])])
        #expect(throws: (any Error).self) { try DeclarativePluginTestSupport.operations.validateNativeNodes(ui: declaration(), data: duplicate) }
        var fail = false
        let feature = PluginNativeUIFeature(declaration: try declaration(), validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, _ in
            if method == "build.instances" { return instances }
            return .object(["value": fail ? duplicate : data])
        })
        defer { feature.close() }
        await feature.refresh()?.value
        fail = true
        await feature.refresh()?.value
        #expect(feature.nodes == valid)
        #expect(feature.error != nil)
        let oversized: ToolingJSONValue = .object(["nodes": .array((0..<2001).map {
            .object(["id": .string("node.\($0)"), "label": .string("X")])
        })])
        #expect(throws: (any Error).self) { try DeclarativePluginTestSupport.operations.validateNativeNodes(ui: declaration(), data: oversized) }
    }

    @Test(arguments: [0, 2]) func ambiguousOrMissingInstancesNeverInvokeAFunction(count: Int) async throws {
        var invocations = 0
        let feature = PluginNativeUIFeature(declaration: try declaration(),
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, _ in
                guard method == "build.instances" else { invocations += 1; return .null }
                return .object(["instances": .array((0..<count).map {
                    .object(["id": .string("instance.\($0)"), "buildSystemID": .string("sample")])
                })])
            })
        defer { feature.close() }
        await feature.refresh()?.value
        #expect(invocations == 0)
        #expect(feature.error != nil)
    }

    @Test func closingDuringARequestDiscardsItsLateResultAndReleasesLifecycle() async throws {
        let started = TestGate()
        let release = TestGate()
        defer { started.open(); release.open() }
        let pages = PluginWebPages()
        var closed = false
        let feature = PluginNativeUIFeature(declaration: try declaration(), validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes, request: { method, _ in
            if method == "build.instances" { return instances }
            started.open()
            _ = await release.waitUntilOpen()
            return .object(["value": data])
        }, close: { closed = true })
        defer { pages.closeAll() }
        #expect(pages.registerNative(feature, windowID: "panel", pluginID: "example"))
        let finished = try #require(feature.refresh())
        defer { finished.cancel() }
        #expect(await started.waitUntilOpen())
        pages.closePages(of: ["example"])
        release.open()
        await finished.value
        #expect(closed)
        #expect(feature.nodes.isEmpty)
        #expect(!feature.isBusy)
        #expect(!pages.registerNative(feature, windowID: "panel", pluginID: "example"))
        #expect(pages.openWindowIDs.isEmpty)
    }

    @Test func replacementMountCanRegisterBeforeTheOldSplitBranchDisappears() throws {
        let pages = PluginWebPages()
        defer { pages.closeAll() }
        var oldClosed = 0
        var newClosed = 0
        let ui = try declaration()
        let old = PluginNativeUIFeature(declaration: ui,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes,
            request: { _, _ in .null }, close: { oldClosed += 1 })
        let replacement = PluginNativeUIFeature(declaration: ui,
            validateNodes: DeclarativePluginTestSupport.operations.validateNativeNodes,
            request: { _, _ in .null }, close: { newClosed += 1 })
        #expect(pages.registerNative(old, windowID: "panel", pluginID: "example"))
        // Opening another dock changes the split's structural branch. SwiftUI
        // can mount its replacement before delivering the old disappearance.
        #expect(pages.registerNative(replacement, windowID: "panel", pluginID: "example"))
        #expect(oldClosed == 1)
        pages.releaseNative(old, windowID: "panel")
        #expect(pages.openWindowIDs == ["panel"])
        #expect(newClosed == 0)
        #expect(!pages.registerNative(old, windowID: "panel", pluginID: "different-owner"))
        pages.closePages(of: ["example"])
        #expect(newClosed == 1)
        #expect(!pages.registerNative(old, windowID: "panel", pluginID: "example"))
    }
}
