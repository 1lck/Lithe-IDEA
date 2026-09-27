import Darwin
import Foundation
import LitheCoreContracts

/// Scratch files the Maven dependency plugin writes one module's tree to.
///
/// Several Lithe builds can run at the same time, so each process uses its own
/// directory named after its process identifier and, when created, removes only
/// the directories of processes that have exited. Dependency operations remove
/// their own files; that cleanup covers a crash, or a tree Maven finished
/// writing after its operation was stopped.
///
/// Note: the data-source decision is recorded in .agents/notes/implemented/architecture/2026-09-26-maven-dependency-tree-output-file.md
struct MacMavenDependencyOutputStore: MavenDependencyOutputStoring {
    private let directoryURL: URL

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("maven-dependency-trees", isDirectory: true),
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        isProcessRunning: (pid_t) -> Bool = MacMavenDependencyOutputStore.isProcessRunning
    ) {
        directoryURL = rootURL.appendingPathComponent(String(processIdentifier), isDirectory: true)
        Self.removeAbandonedDirectories(
            in: rootURL,
            keeping: processIdentifier,
            isProcessRunning: isProcessRunning
        )
    }

    func makeDependencyOutputFile(operationID: String) throws -> URL {
        // Operation IDs become file names; accept only UUID-style identifiers.
        guard !operationID.isEmpty,
              operationID.count <= 128,
              operationID.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
              }) else {
            throw MavenOperationError(
                code: "invalid_request",
                message: "The Maven dependency operation is invalid."
            )
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(operationID + ".txt", isDirectory: false)
        // Core must only ever read what this operation's Maven wrote.
        try removeIfPresent(fileURL)
        return fileURL
    }

    func removeDependencyOutputFile(_ fileURL: URL) {
        do {
            try removeIfPresent(fileURL)
        } catch {
            NSLog("[maven] Could not remove dependency-tree scratch file: \(error.localizedDescription)")
        }
    }

    private func removeIfPresent(_ fileURL: URL) throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private static func removeAbandonedDirectories(
        in rootURL: URL,
        keeping processIdentifier: pid_t,
        isProcessRunning: (pid_t) -> Bool
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            // A missing root means no earlier process created scratch files.
            return
        }
        for entry in entries {
            guard let owner = pid_t(entry.lastPathComponent),
                  owner != processIdentifier,
                  !isProcessRunning(owner) else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                NSLog("[maven] Could not remove abandoned dependency-tree files: \(error.localizedDescription)")
            }
        }
    }

    static func isProcessRunning(_ processIdentifier: pid_t) -> Bool {
        // Signal 0 checks for existence only. EPERM means the process exists
        // but belongs to another user, which still owns its directory.
        Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
    }
}
