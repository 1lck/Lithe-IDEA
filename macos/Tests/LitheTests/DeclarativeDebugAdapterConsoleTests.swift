import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Declarative debug adapter console commands")
struct DeclarativeDebugAdapterConsoleTests {
    @Test
    func hostReceivesTheCommandsTheCoreNormalizedFromTheContractFixture() throws {
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/debug-adapters/debug-adapter.plugin.json")
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: fixture)
        )

        let adapter = try #require(descriptor.debugAdapters.first)

        // The Core sorts declared commands, so the host never depends on the author's order.
        #expect(adapter.consoleCommands == [
            DebugConsoleCommand(name: "breakpoint set", detail: "Set a breakpoint"),
            DebugConsoleCommand(name: "frame variable", detail: nil)
        ])
        #expect(adapter.consoleCommandPrefix == "`")
    }

    @Test
    func hostReadsTheFeaturesAndDefaultsOfTheFeaturesFixtureForCore() throws {
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/debug-adapters/debug-adapter-features.plugin.json")
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: fixture)
        )

        let declared = try #require(descriptor.debugAdapters.first).declaredBehavior

        #expect(declared.features?.hotCodeReplace?.request == "script.reload")
        #expect(declared.features?.hotCodeReplace?.event == "script.reloaded")
        #expect(declared.features?.hotCodeReplace?.changedField == "modules")
        #expect(declared.features?.hotCodeReplace?.errorField == "error")
        #expect(declared.features?.stepFilters?.argument == "stepFilters")
        #expect(declared.defaults?.stepFilters?.classNameFilters == ["_vendor.*"])
        #expect(declared.defaults?.stepFilters?.skipSynthetics == true)
        #expect(declared.defaults?.stepFilters?.skipConstructors == false)
    }

    @Test
    func anAdapterThatDeclaresNothingKeepsNoDeclaredBehavior() throws {
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/debug-adapters/debug-adapter.plugin.json")
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: fixture)
        )

        #expect(try #require(descriptor.debugAdapters.first).declaredBehavior == DebugAdapterDeclaredBehavior.none)
    }
}
