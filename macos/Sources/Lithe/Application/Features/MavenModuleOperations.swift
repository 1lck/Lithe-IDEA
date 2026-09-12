import Foundation
import LitheCoreContracts

/// Projects resolved configuration ownership into the Maven tree's native actions.
enum MavenModuleOperations {
    static func configuration(
        in configurations: [RunConfiguration], preferredID: String?,
        reactorPath: String, modulePath: String, debug: Bool
    ) -> RunConfiguration? {
        let candidates = configurations.filter {
            !$0.disabled && !$0.usesCurrentEditorFile
                && ($0.execution == .application || $0.execution == .service)
                && $0.mavenReactorPath.map(normalize) == normalize(reactorPath)
                && normalize($0.modulePath ?? ".") == normalize(modulePath)
                && (!debug || $0.debugAdapter == "jdwp")
        }
        if let preferred = candidates.first(where: { $0.id == preferredID }) { return preferred }
        if candidates.count == 1 { return candidates[0] }
        let services = candidates.filter { $0.execution == .service }
        if services.count == 1 { return services[0] }
        let applications = candidates.filter { $0.execution == .application }
        return applications.count == 1 ? applications[0] : nil
    }

    private static func normalize(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "." : value
    }
}
