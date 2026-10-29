import Foundation
import LitheModuleAPI

extension RustCoreBridge {
    /// Only schema-owned root fields select a host. Commit messages, command
    /// arguments and user text must never be interpreted as filesystem paths.
    func remoteWorkspace<Payload: Encodable>(
        for command: String, payload: Payload
    ) throws -> RemoteWorkspace? {
        guard let remoteWorkspaces,
              command.hasPrefix("git.") || command.hasPrefix("build.") || [
                "workspace.repositories", "workspace.snapshot", "workspace.listDirectories",
                "workspace.search", "workspace.searchEverywhere", "file.read", "file.write",
                "workspace.searchIndex.warm", "workspace.searchIndex.update", "workspace.searchIndex.invalidate",
                "workspace.replacePreview", "runConfig.selectJava", "lsp.startServer"
              ].contains(command) else { return nil }
        let encoded = try JSONEncoder().encode(payload)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return nil }
        var roots = [String]()
        if let root = object["root"] as? String, !root.isEmpty { roots.append(root) }
        if command.hasPrefix("build.") {
            if let root = object["workspaceRoot"] as? String { roots.append(root) }
            if let request = object["request"] as? [String: Any],
               let root = request["workspaceRoot"] as? String { roots.append(root) }
        }
        if command == "lsp.startServer", let root = object["workingDirectory"] as? String {
            roots.append(root)
        }
        roots.append(contentsOf: object["repositoryRoots"] as? [String] ?? [])
        func appendRepositories(_ object: [String: Any]) {
            let repositories = object["repositories"] as? [[String: Any]] ?? []
            roots.append(contentsOf: repositories.compactMap { $0["root"] as? String })
        }
        appendRepositories(object)
        if let session = object["session"] as? [String: Any],
           let plan = session["plan"] as? [String: Any] { appendRepositories(plan) }
        if let plan = object["plan"] as? [String: Any] { appendRepositories(plan) }
        if let previous = object["previous"] as? [String: Any],
           let plan = previous["plan"] as? [String: Any] { appendRepositories(plan) }
        if let reviewed = object["reviewed"] as? [String: Any] { appendRepositories(reviewed) }
        var selected: RemoteWorkspace?
        var includesLocal = false
        for root in roots {
            guard let resolved = remoteWorkspaces.resolve(URL(fileURLWithPath: root)) else {
                includesLocal = true
                continue
            }
            let candidate = RemoteWorkspace(sessionId: resolved.binding.sessionID,
                localRoot: resolved.binding.root.standardizedFileURL.path,
                remoteRoot: resolved.binding.remoteRoot)
            if let selected, selected != candidate {
                throw CoreCallError(code: "not_supported",
                    message: L10n.string("A Git operation cannot span different workspace hosts."), details: nil)
            }
            selected = candidate
        }
        if selected != nil && includesLocal {
            throw CoreCallError(code: "not_supported",
                message: L10n.string("A Git operation cannot span local and remote workspaces."), details: nil)
        }
        return selected
    }
}
