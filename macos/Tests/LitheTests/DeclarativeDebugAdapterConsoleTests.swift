import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Declarative debug adapter console commands")
struct DeclarativeDebugAdapterConsoleTests {
    @Test
    func hostReceivesTheCommandsTheCoreNormalizedFromTheContractFixture() throws {
        let fixture = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/debug-adapter.plugin.json")
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
}
