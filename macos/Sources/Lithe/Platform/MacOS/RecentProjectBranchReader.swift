import Foundation

/// Reads `.git/HEAD` directly so recent-project metadata can record the branch
/// without launching Git. Only the last checked-out branch is captured; later
/// checkouts refresh it the next time the project is opened.
struct MacRecentProjectBranchReader: RecentProjectBranchReading {
    let storage: any FileStorage
    let core: RustCoreBridge

    init(storage: any FileStorage, core: RustCoreBridge = RustCoreBridge()) {
        self.storage = storage
        self.core = core
    }

    private struct TextRequest: Encodable { let text: String }
    private struct CheckoutResult: Decodable { let branch: String? }
    private struct PointerResult: Decodable { let path: String? }

    func branch(forProjectAt url: URL) -> String? {
        guard let gitDirectory = gitDirectory(for: url),
              let data = try? storage.readPrefix(
                  from: gitDirectory.appendingPathComponent("HEAD"),
                  byteCount: 4096
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let result: CheckoutResult? = try? core.executeResult(
            command: "git.parseCheckoutMetadata", payload: TextRequest(text: text)
        ).get()
        return result?.branch
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
        // Core interprets the bounded pointer; this host resolves its path.
        let result: PointerResult? = try? core.executeResult(
            command: "git.parseGitdirPointer", payload: TextRequest(text: text)
        ).get()
        guard let path = result?.path else { return nil }
        // Relative pointers are resolved against the workspace directory;
        // `URL(fileURLWithPath:relativeTo:)` would treat it as a file and drop
        // its last component.
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return url.appendingPathComponent(path).standardizedFileURL
    }
}
