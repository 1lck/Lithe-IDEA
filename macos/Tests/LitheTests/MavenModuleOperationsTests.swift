import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct MavenModuleOperationsTests {
    private func configuration(
        _ id: String, reactor: String? = "services/alpha", module: String = ".",
        execution: RunConfigurationExecution = .application, debug: String? = "jdwp",
        disabled: Bool = false
    ) -> RunConfiguration {
        RunConfiguration(id: id, name: id, kind: .javaMain, execution: execution,
                         modulePath: module, mainClass: "example.Main",
                         mavenReactorPath: reactor, debugAdapter: debug, disabled: disabled)
    }

    @Test
    func menusKeepReactorAndModuleOwnershipBeforePreference() {
        let alpha = configuration("alpha")
        let beta = configuration("beta", reactor: "services/beta")
        let child = configuration("child", module: "child")
        let candidates = [beta, child, .currentFile, alpha, configuration("standalone", reactor: nil)]
        #expect(MavenModuleOperations.configuration(
            in: candidates, preferredID: beta.id, reactorPath: "services/alpha", modulePath: ".", debug: false
        ) == alpha)
        #expect(MavenModuleOperations.configuration(
            in: candidates, preferredID: alpha.id, reactorPath: "services/alpha", modulePath: "child", debug: true
        ) == child)
    }

    @Test
    func ambiguousAndDisabledEntriesNeverLaunchAnArbitraryApplication() {
        let a = configuration("a")
        let b = configuration("b")
        func select(_ values: [RunConfiguration], preferred: String? = nil, debug: Bool = false) -> RunConfiguration? {
            MavenModuleOperations.configuration(in: values, preferredID: preferred,
                reactorPath: "services/alpha", modulePath: ".", debug: debug)
        }
        #expect(select([a, b]) == nil)
        #expect(select([a, b], preferred: b.id) == b)
        let service = configuration("service", execution: .service)
        #expect(select([a, b, service]) == service)
        #expect(select([configuration("disabled", disabled: true), configuration("task", execution: .task)]) == nil)
        #expect(select([configuration("no-adapter", debug: nil)], debug: true) == nil)
    }

    @Test
    func debugSourceStaysInsideDetectedReactorDespiteDuplicateClasses() {
        let root = URL(fileURLWithPath: "/workspace")
        let alpha = root.appendingPathComponent("services/alpha/src/main/java/example/Main.java")
        let beta = root.appendingPathComponent("services/beta/src/main/java/example/Main.java")
        let resolver = DebugLaunchSourceResolver()
        #expect(resolver.resolve(configuration: configuration("alpha"), activeDocumentURL: beta,
                                 projectFiles: [beta, alpha], workspaceURL: root) == alpha)
        #expect(resolver.resolve(configuration: configuration("alpha"), activeDocumentURL: beta,
                                 projectFiles: [beta], workspaceURL: root) == nil)
    }

    @Test
    func bridgeDecodesReadOnlyMavenOwnershipWithoutUsingCwd() throws {
        let json = #"{"module":".","reactorPath":"services/alpha"}"#
        let maven = try JSONDecoder().decode(
            RustCoreBridge.RunConfigurationPayload.Configuration.Maven.self, from: Data(json.utf8))
        #expect(maven.reactorPath == "services/alpha")
        #expect(maven.module == ".")
        let legacy = try JSONDecoder().decode(
            RustCoreBridge.RunConfigurationPayload.Configuration.Maven.self, from: Data(#"{"module":"."}"#.utf8))
        #expect(legacy.reactorPath == nil)
    }
}
