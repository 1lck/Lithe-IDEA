import Testing
@testable import Lithe

@Suite("Services browser selection and layout")
struct RunBrowserStateTests {
    private let node = RunConfiguration(id: "npm:web", name: "web", kind: .process(provider: "npm.script"), execution: .service, modulePath: nil, mainClass: nil)
    private let rust = RunConfiguration(id: "cargo:worker", name: "worker", kind: .process(provider: "cargo.run"), modulePath: nil, mainClass: nil)
    private let java = RunConfiguration(id: "java:api", name: "api", kind: .javaMain, modulePath: nil, mainClass: "demo.Api")
    private let spring = RunConfiguration(id: "spring:api", name: "api", kind: .springBoot, modulePath: nil, mainClass: "demo.Api")

    @Test func groupsApplicationFamiliesAcrossExecutionCategories() {
        let groups = RunBrowserState.groups(for: [spring, rust, .currentFile, node, java])
        #expect(groups.map(\.title) == ["Java", "Node", "Rust"])
        #expect(groups[0].configurations.map(\.id) == [java.id, spring.id])
        #expect(groups[1].configurations == [node])
        #expect(groups[2].configurations == [rust])
        #expect(RunBrowserState.groups(for: [java, node, rust, spring]).map(\.id) == groups.map(\.id))
    }

    @Test func unknownProvidersRemainVisible() {
        let unknown = RunConfiguration(id: "custom:run", name: "run", kind: .process(provider: "custom.launch"), modulePath: nil, mainClass: nil)
        let groups = RunBrowserState.groups(for: [unknown, node])
        #expect(groups.map(\.title) == ["Custom", "Node"])
        #expect(groups[0].configurations == [unknown])
    }

    @Test func overlappingScopesShareSelectionAndMixedState() {
        var browser = RunBrowserState()
        let all = [node, rust, java, spring, .currentFile]
        let services = browser.configurations(in: .execution(.service), from: all, pinnedIDs: [node.id])
        browser.toggle(services)
        #expect(browser.checkedIDs == [node.id, spring.id])
        #expect(browser.checkState(for: [java, spring]) == .mixed)
        browser.scope = .pinned
        let pinned = browser.configurations(in: .pinned, from: all, pinnedIDs: [node.id])
        #expect(browser.checkState(for: pinned) == .checked)
        browser.toggle([java, spring])
        #expect(browser.checkedIDs == [node.id, java.id, spring.id])
        browser.toggle(pinned)
        #expect(browser.checkedIDs == [java.id, spring.id])
        #expect(browser.checkState(for: services) == .mixed)
    }

    @Test func restoringSavedChoicesDropsRemovedConfigurations() {
        var browser = RunBrowserState()
        browser.restoreSelection([node.id, rust.id, "removed", RunConfiguration.currentFileID], configurations: [node, rust, .currentFile])
        #expect(browser.checkedIDs == [node.id, rust.id])
        #expect(browser.checkState(for: [node]) == .checked)
        browser.restoreSelection([], configurations: [node, rust])
        #expect(browser.checkedIDs.isEmpty)
    }

    @Test func pruningAndEmptyScopesNeverSelectCurrentFile() {
        var browser = RunBrowserState()
        browser.toggle([node, rust, .currentFile])
        browser.retainConfigurations([rust, java, .currentFile])
        #expect(browser.checkedIDs == [rust.id])
        browser.toggle([])
        #expect(browser.checkState(for: []) == .unchecked)
        browser.clearSelection()
        #expect(browser.checkedIDs.isEmpty)
    }

    @Test @MainActor func splitBoundsReserveUsableAdjacentColumns() {
        for collapsed in [false, true] {
            let minimum = RunServicesLayout.minimumWidth(isScopeCollapsed: collapsed)
            for available in [0.0, 320, 710, 1024, 1920] {
                let canvas = max(available, minimum)
                let scope = collapsed ? RunServicesLayout.collapsedScopeWidth : RunServicesLayout.scopeMaximum(in: canvas)
                let separator = collapsed ? 1.0 : SplitHandleView.thickness
                let remaining = canvas - scope - separator
                let configurations = RunServicesLayout.configurationMaximum(in: remaining)
                let output = remaining - configurations - SplitHandleView.thickness
                #expect(configurations >= RunServicesLayout.configurationMinimum)
                #expect(output >= RunServicesLayout.outputMinimum)
                #expect(scope >= (collapsed ? RunServicesLayout.collapsedScopeWidth : RunServicesLayout.scopeMinimum))
            }
        }
    }
}
