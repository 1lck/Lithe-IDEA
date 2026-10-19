import Foundation

/// Reads `.git/HEAD` directly so recent-project metadata can record the branch
/// without launching Git. Only the last checked-out branch is captured; later
/// checkouts refresh it the next time the project is opened.
struct MacRecentProjectBranchReader: RecentProjectBranchReading {
    let storage: any FileStorage

    func branch(forProjectAt url: URL) -> String? {
        guard let gitDirectory = gitDirectory(for: url),
              let data = try? storage.readPrefix(
                  from: gitDirectory.appendingPathComponent("HEAD"),
                  byteCount: 4096
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            let reference = String(line.dropFirst("ref: ".count))
            guard reference.hasPrefix("refs/heads/") else { return nil }
            return String(reference.dropFirst("refs/heads/".count))
        }
        // A detached HEAD stores a commit hash; show the same short id Git
        // shows so the row still describes the checkout.
        let shortID = String(line.prefix(8))
        return shortID.isEmpty ? nil : shortID
    }

    private func gitDirectory(for url: URL) -> URL? {
        let dotGit = url.appendingPathComponent(".git")
        guard let metadata = storage.metadata(for: dotGit) else { return nil }
        if metadata.isDirectory {
            return dotGit
        }
        guard metadata.isRegularFile,
              let data = try? storage.readPrefix(from: dotGit, byteCount: 4096),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Linked worktrees and submodules store a `gitdir: <path>` pointer.
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        // Relative pointers are resolved against the workspace directory;
        // `URL(fileURLWithPath:relativeTo:)` would treat it as a file and drop
        // its last component.
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return url.appendingPathComponent(path).standardizedFileURL
    }
}
