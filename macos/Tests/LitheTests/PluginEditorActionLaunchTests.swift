import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// Toolbar Run/Debug for plugin-owned languages picks one of the plugin's
/// editor actions; these tests pin the choice and the routing guard.
@Suite("Plugin editor action launch")
@MainActor
struct PluginEditorActionLaunchTests {
    private let registration = PluginEditorActionRegistration(
        lease: UUID(), pluginID: "io.example.lang", sessionID: "s1",
        context: PluginWorkspaceContextReference(contextID: "w1", generation: 1),
        id: "actions", functionID: "lang.collect", fileExtensions: ["lang"], fileNames: []
    )

    private func action(_ id: String, line: Int, column: Int = 1, icon: String,
                        alternatives: [(id: String, icon: String)] = []) throws -> PluginEditorActionItem {
        let alternatives = alternatives.map {
            """
            {"id":"\($0.id)","title":"\($0.id)","icon":"\($0.icon)","invoke":{"functionID":"lang.\($0.id)","params":{"alt":"\($0.id)"}}}
            """
        }.joined(separator: ",")
        let json = """
        {"id":"\(id)","range":{"start":{"line":\(line),"column":\(column)},"end":{"line":\(line),"column":\(column + 1)}},
         "title":"\(id)","icon":"\(icon)","invoke":{"functionID":"lang.\(id)","params":{"main":"\(id)"}},
         "alternatives":[\(alternatives)]}
        """
        let decoded = try JSONDecoder().decode(PluginEditorAction.self, from: Data(json.utf8))
        return PluginEditorActionItem(registration: registration, action: decoded)
    }

    @Test("Run picks the first run-icon action by document position")
    func runPicksFirstRunActionByPosition() throws {
        let items = [
            try action("later", line: 20, icon: "run"),
            try action("test", line: 3, icon: "test"),
            try action("sameLine", line: 5, column: 9, icon: "run-all"),
            try action("first", line: 5, column: 2, icon: "run"),
        ]
        let choice = try #require(PluginEditorActionLaunchSelection.choose(items, intent: .run))
        #expect(choice.item.action.id == "first")
        #expect(choice.invocation.functionID == "lang.first")
        #expect(choice.alternativeID == nil)
    }

    @Test("Debug prefers the run action's debug alternative")
    func debugPrefersAlternativeOfRunAction() throws {
        let items = [
            try action("debugOnly", line: 9, icon: "debug"),
            try action("main", line: 4, icon: "run", alternatives: [(id: "dbg", icon: "debug"), (id: "cov", icon: "test")]),
        ]
        let choice = try #require(PluginEditorActionLaunchSelection.choose(items, intent: .debug))
        #expect(choice.item.action.id == "main")
        #expect(choice.alternativeID == "dbg")
        #expect(choice.invocation.functionID == "lang.dbg")
        #expect(choice.invocation.params == .object(["alt": .string("dbg")]))
    }

    @Test("Debug falls back to an action whose own icon is debug")
    func debugFallsBackToDebugIconAction() throws {
        let items = [
            try action("main", line: 2, icon: "run", alternatives: [(id: "cov", icon: "test")]),
            try action("attach", line: 8, icon: "debug"),
        ]
        let choice = try #require(PluginEditorActionLaunchSelection.choose(items, intent: .debug))
        #expect(choice.item.action.id == "attach")
        #expect(choice.alternativeID == nil)
    }

    @Test("No matching icon yields no choice")
    func noMatchingIconYieldsNil() throws {
        let items = [try action("test", line: 1, icon: "test"), try action("nav", line: 2, icon: "navigate-super")]
        #expect(PluginEditorActionLaunchSelection.choose(items, intent: .run) == nil)
        #expect(PluginEditorActionLaunchSelection.choose(items, intent: .debug) == nil)
        #expect(PluginEditorActionLaunchSelection.choose([], intent: .run) == nil)
    }

    private func support(
        execution: Bool = false, debug: Bool = false, testing: Bool = false,
        hostCapabilities: Set<LanguageHostCapability> = []
    ) -> LanguageSupportDeclaration {
        LanguageSupportDeclaration(
            id: "lang", displayName: "Lang", fileExtensions: ["lang"], projectFileNames: [],
            languageServerModuleID: .languageServerExtension("lang"),
            executionModuleID: execution ? .languageExecutionExtension("lang") : nil,
            testingModuleID: testing ? .languageExecutionExtension("lang") : nil,
            debugModuleID: debug ? .debugAdaptersExtension("io.example.lang") : nil,
            hostCapabilities: hostCapabilities
        )
    }

    private let currentFile = RunConfiguration(id: RunConfiguration.currentFileID, name: "Current File", kind: .currentFile)
    private let fileURL = URL(fileURLWithPath: "/workspace/Main.lang")

    @Test("Routing applies only to current-file configurations with a module-less language")
    func routingRequiresCurrentFileAndMissingModule() {
        let coordinator = makeRunWorkflowCoordinator()
        let plain = support()
        let routed = coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in plain }, hostLaunchesFiles: { _ in true })
        #expect(routed?.id == "lang")
        #expect(coordinator.languageSupportRoutingToEditorActions(.debug, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in plain }, hostLaunchesFiles: { _ in true })?.id == "lang")
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: nil, languageSupportForFile: { _ in plain }, hostLaunchesFiles: { _ in true }) == nil)
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in nil }, hostLaunchesFiles: { _ in true }) == nil)

        let named = RunConfiguration(id: "named", name: "Named", kind: .process(provider: "fixture.main"))
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: named, currentFileURL: fileURL, languageSupportForFile: { _ in plain }, hostLaunchesFiles: { _ in true }) == nil)
    }

    @Test("Languages with their own module or host capability keep the module path")
    func routingSkipsLanguagesWithModulesOrHostCapabilities() {
        let coordinator = makeRunWorkflowCoordinator()
        let withExecution = support(execution: true)
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in withExecution }, hostLaunchesFiles: { _ in true }) == nil)
        // Debug is still routed when only the execution module exists.
        #expect(coordinator.languageSupportRoutingToEditorActions(.debug, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in withExecution }, hostLaunchesFiles: { _ in true })?.id == "lang")

        let withDebugger = support(debug: true)
        #expect(coordinator.languageSupportRoutingToEditorActions(.debug, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in withDebugger }, hostLaunchesFiles: { _ in true }) == nil)
        // An adapter that only attaches leaves the Debug button nothing to launch.
        #expect(coordinator.languageSupportRoutingToEditorActions(.debug, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in withDebugger }, hostLaunchesFiles: { _ in false })?.id == "lang")
        let named = RunConfiguration(id: "named", name: "Named", kind: .process(provider: "fixture.main"))
        #expect(coordinator.languageSupportRoutingToEditorActions(.debug, for: named, currentFileURL: fileURL, languageSupportForFile: { _ in withDebugger }, hostLaunchesFiles: { _ in false }) == nil)
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in withDebugger }, hostLaunchesFiles: { _ in true })?.id == "lang")

        let hostRun = support(hostCapabilities: [.run])
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in hostRun }, hostLaunchesFiles: { _ in true }) == nil)
        #expect(coordinator.languageSupportRoutingToEditorActions(.debug, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in hostRun }, hostLaunchesFiles: { _ in true })?.id == "lang")

        let withTesting = support(testing: true)
        #expect(coordinator.languageSupportRoutingToEditorActions(.testing, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in withTesting }, hostLaunchesFiles: { _ in true }) == nil)
    }

    @Test("Debug-only and editor-only declarations are never routed")
    func routingSkipsDebugOnlyAndEditorOnly() {
        let coordinator = makeRunWorkflowCoordinator()
        let debugOnly = LanguageSupportDeclaration(
            id: "lang", displayName: "Lang", fileExtensions: ["lang"],
            debugModuleID: .debugAdaptersExtension("io.example.debugger")
        )
        #expect(debugOnly.isDebugOnly)
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in debugOnly }, hostLaunchesFiles: { _ in true }) == nil)
        let editorOnly = LanguageSupportDeclaration(
            id: "lang", displayName: "Lang", fileExtensions: ["lang"],
            editorModuleID: .grammarsExtension("io.example.grammar")
        )
        #expect(editorOnly.isEditorOnly)
        #expect(coordinator.languageSupportRoutingToEditorActions(.run, for: currentFile, currentFileURL: fileURL, languageSupportForFile: { _ in editorOnly }, hostLaunchesFiles: { _ in true }) == nil)
    }
}
