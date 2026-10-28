import Foundation
import LitheModuleAPI

/// Core orders these before native discovery. Other plugin launch adapters can
/// reuse the sources without adopting Build's protocol or trust policy.
package enum ExecutableCandidate: Equatable, Sendable {
    case projectFile(path: String, requires: [String])
    case environment(variable: String, path: String)
    case command(String)
    case runtime(String)
    /// Nil is deliberately unconfigured. Core rejects invalid stored values.
    case setting(id: String, path: String?)
}

package struct ResolvedExecutableCandidate: Equatable, Sendable {
    package let url: URL
    package let executesProjectCode: Bool
    package let terminal: Bool
}

package enum ExecutableResolution: Equatable, Sendable {
    case skip
    case resolved([ResolvedExecutableCandidate])
    case terminalFailure(String)
}

/// Pure native candidate lookup, supplied with capabilities by the platform.
/// No process runs here; each consumer keeps its own probing/trust constraints.
@MainActor
package struct ExecutableCandidateResolver {
    package let fileExists: (URL) -> Bool
    package let isExecutable: (URL) -> Bool
    package let commands: (String) -> [URL]
    package let runtimes: (String) -> URL?

    package init(fileExists: @escaping (URL) -> Bool, isExecutable: @escaping (URL) -> Bool,
                 commands: @escaping (String) -> [URL], runtimes: @escaping (String) -> URL?) {
        self.fileExists = fileExists; self.isExecutable = isExecutable
        self.commands = commands; self.runtimes = runtimes
    }

    package func resolve(_ candidate: ExecutableCandidate, workspaceURL: URL,
                         environment: [String: String], environmentInputs: [String]) -> ExecutableResolution {
        func found(_ urls: [URL], project: Bool = false, terminal: Bool = false) -> ExecutableResolution {
            let selected = urls.filter(isExecutable).map {
                ResolvedExecutableCandidate(url: $0, executesProjectCode: project, terminal: terminal)
            }
            return selected.isEmpty ? .skip : .resolved(selected)
        }
        switch candidate {
        case .projectFile(let path, let requires):
            guard requires.allSatisfy({ fileExists(workspaceURL.appendingPathComponent($0)) }) else { return .skip }
            return found([workspaceURL.appendingPathComponent(path).standardizedFileURL], project: true)
        case .environment(let variable, let path):
            guard environmentInputs.contains(variable), let base = environment[variable], base.hasPrefix("/") else { return .skip }
            return found([URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL])
        case .command(let command): return found(commands(command))
        case .runtime(let id): return found(runtimes(id).map { [$0] } ?? [])
        case .setting(_, let path):
            guard let path, !path.isEmpty else { return .skip }
            guard path.hasPrefix("/"), path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  isExecutable(URL(fileURLWithPath: path)) else {
                return .terminalFailure(L10n.string("The configured build tool is not executable: \(path)"))
            }
            return found([URL(fileURLWithPath: path)], terminal: true)
        }
    }
}
