import Darwin
import Foundation

/// Checks only declared metadata below a source root, without reading files or
/// starting a backend. Recognition is repeated when the import is started.
enum MacKeymapImportRecognition {
    static func matches(root: URL, plan: KeymapImportSourcePlan,
                        userConfigRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")) throws -> Bool {
        guard !plan.recognition.isEmpty, plan.recognition.count <= plan.limits.probes else {
            throw MacKeymapImportSnapshot.Failure.invalidPlan
        }
        let rootFD = try MacWorkspaceSecurePath.openRoot(root)
        defer { Darwin.close(rootFD) }
        for probe in plan.recognition {
            try Task.checkCancellation()
            let path: String
            let expectedKind: mode_t
            switch probe {
            case .root(base: .userConfig, components: let expected):
                let base = userConfigRoot.standardizedFileURL.pathComponents
                let candidate = root.standardizedFileURL.pathComponents
                if candidate.starts(with: base), candidate.count == base.count + expected.count,
                   zip(candidate.dropFirst(base.count), expected).allSatisfy({ $0.1 == "*" || $0.0 == $0.1 }) {
                    return true
                }
                continue
            case .file(path: let value): path = value; expectedKind = mode_t(S_IFREG)
            case .directory(path: let value): path = value; expectedKind = mode_t(S_IFDIR)
            }
            let components = try MacWorkspaceSecurePath.components(of: path)
            guard let name = components.last else { throw MacKeymapImportSnapshot.Failure.invalidPlan }
            do {
                let parent = try MacWorkspaceSecurePath.openDirectory(components.dropLast(), below: rootFD)
                defer { Darwin.close(parent) }
                let status = try MacWorkspaceSecurePath.status(of: name, in: parent)
                let kind = status.st_mode & S_IFMT
                guard kind != S_IFLNK else { throw MacKeymapImportSnapshot.Failure.invalidPlan }
                if kind == expectedKind { return true }
            // log-exempt: 预期的缺失：可选识别标记不存在时继续检查其他标记
            } catch PluginWorkspaceFileError.notFound {
                continue
            }
        }
        return false
    }
}
