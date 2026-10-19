import Darwin
import Foundation

protocol MacPluginDiskPackageImporting {
    func importPackage(at url: URL) async throws -> MacImportedPluginPackage
}

/// The service owns this snapshot after import and removes `temporaryDirectory`
/// on discard, failed review or completed installation. The source stays read-only.
struct MacImportedPluginPackage: Sendable {
    let packageURL: URL
    let temporaryDirectory: URL
    let fileName: String
    /// The actual ZIP snapshot's digest; unpacked directories have no archive.
    let archiveSHA256: String?
}

enum MacPluginDiskPackageImportError: Error, Equatable, LocalizedError {
    case unsupportedSource
    case unsafeEntry
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            "Choose a ZIP archive or an unpacked plugin directory."
        case .unsafeEntry:
            "Plugin packages cannot contain aliases, symbolic links or special files."
        case .sourceChanged:
            "The plugin package changed while it was being copied. Choose it again."
        }
    }
}

/// Native disk I/O only; declaration, signature and installation trust belong to
/// the package store and service. This nonisolated async entry runs off the UI
/// actor. No code from the selected package is executed.
final class MacPluginDiskPackageImporter: MacPluginDiskPackageImporting {
    private static let chunkBytes = 256 * 1024
    /// Bounds recursive frames and simultaneously open source descriptors.
    private static let maximumDirectoryDepth = 64
    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private let limits: MacPluginPackageDownloader.Limits

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        limits: MacPluginPackageDownloader.Limits = .standard
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
        self.limits = limits
    }

    func importPackage(at url: URL) async throws -> MacImportedPluginPackage {
        try Task.checkCancellation()
        guard url.isFileURL else { throw MacPluginDiskPackageImportError.unsupportedSource }
        // Canonicalize parents (including macOS /var -> /private/var), but never
        // resolve the selected object itself: a root symlink must be rejected.
        let sourceURL = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
        let source = try openSource(at: sourceURL)
        defer { Darwin.close(source) }
        let metadata = try statDescriptor(source)
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        guard isDirectory || (metadata.st_mode & S_IFMT == S_IFREG && url.pathExtension.lowercased() == "zip") else {
            throw MacPluginDiskPackageImportError.unsupportedSource
        }
        try rejectAlias(source)
        if isDirectory {
            let sourcePath = sourceURL.standardizedFileURL.path
            let temporaryPath = temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            guard sourcePath != "/", temporaryPath != sourcePath, !temporaryPath.hasPrefix(sourcePath + "/") else {
                // Creating the snapshot inside its own source would mutate the
                // source and recursively copy newly generated snapshot files.
                throw MacPluginDiskPackageImportError.unsupportedSource
            }
        }
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        // Runtime-only, private writable storage. Never inside a bundle or a
        // shared worktree cache; success transfers ownership to service.discard.
        let owned = temporaryDirectory.appendingPathComponent("lithe-plugin-disk-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let packageRoot = owned.appendingPathComponent("package", isDirectory: true)
            let archiveSHA256: String?
            if isDirectory {
                try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                var budget = CopyBudget()
                try copyDirectory(source, into: packageRoot, budget: &budget, ancestors: [])
                archiveSHA256 = nil
            } else {
                let archive = owned.appendingPathComponent("archive.zip")
                var budget = CopyBudget()
                try copyFile(source, metadata: metadata, to: archive, budget: &budget, archive: true)
                try Task.checkCancellation()
                archiveSHA256 = try MacPluginPackageDownloader.sha256(of: archive)
                try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try MacPluginPackageDownloader(fileManager: fileManager, limits: limits)
                    .extractArchive(archive, into: packageRoot)
            }
            try Task.checkCancellation()
            let packageURL = try validateSnapshot(in: packageRoot)
            try Task.checkCancellation()
            return MacImportedPluginPackage(
                packageURL: packageURL, temporaryDirectory: owned,
                fileName: url.lastPathComponent, archiveSHA256: archiveSHA256
            )
        } catch {
            try? fileManager.removeItem(at: owned)
            throw error
        }
    }

    private struct CopyBudget {
        var bytes: Int64 = 0
        var entries = 0
    }

    private struct DirectoryIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// O_NONBLOCK keeps a source swapped to a FIFO from hanging open(). Every
    /// subsequent operation is relative to an already-open directory, and
    /// O_NOFOLLOW/fstat reject both static links and check/open replacement races.
    private func openSource(at url: URL) throws -> Int32 {
        // A trailing slash would let open() follow a directory symlink despite
        // O_NOFOLLOW applying to the final component.
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw MacPluginDiskPackageImportError.unsafeEntry }
            throw posixError()
        }
        return descriptor
    }

    private func statDescriptor(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        return metadata
    }

    private func rejectAlias(_ descriptor: Int32) throws {
        // Finder aliases are regular files with kIsAlias in FinderInfo. Read
        // the opened inode's metadata instead of resolving an untrusted URL.
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let count = finderInfo.withUnsafeMutableBytes {
            fgetxattr(descriptor, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0)
        }
        if count == -1 {
            guard errno == ENOATTR || errno == ENOTSUP else { throw posixError() }
        } else if count >= 10, finderInfo[8] & 0x80 != 0 {
            throw MacPluginDiskPackageImportError.unsafeEntry
        }
    }

    private func countEntry(_ budget: inout CopyBudget) throws {
        try Task.checkCancellation()
        guard budget.entries < limits.entries else {
            throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(limits.entries) files")
        }
        budget.entries += 1
    }

    private func copyDirectory(
        _ source: Int32,
        into destination: URL,
        budget: inout CopyBudget,
        ancestors: Set<DirectoryIdentity>
    ) throws {
        try Task.checkCancellation()
        let before = try statDescriptor(source)
        let identity = DirectoryIdentity(device: before.st_dev, inode: before.st_ino)
        guard !ancestors.contains(identity) else { throw MacPluginDiskPackageImportError.unsafeEntry }
        guard ancestors.count < Self.maximumDirectoryDepth else {
            throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(Self.maximumDirectoryDepth) nested directories")
        }
        var ancestors = ancestors
        ancestors.insert(identity)
        let duplicate = dup(source)
        guard duplicate >= 0 else { throw posixError() }
        guard let directory = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw posixError()
        }
        defer { closedir(directory) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }
            let nameCapacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(validatingCString: $0) }
            }
            guard let name else { throw MacPluginDiskPackageImportError.unsafeEntry }
            if name == "." || name == ".." { continue }
            guard !name.contains("/"), !name.contains(":"), !name.contains("\\") else {
                throw MacPluginDiskPackageImportError.unsafeEntry
            }
            try countEntry(&budget)
            let child = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard child >= 0 else {
                if errno == ELOOP { throw MacPluginDiskPackageImportError.unsafeEntry }
                throw posixError()
            }
            defer { Darwin.close(child) }
            let metadata = try statDescriptor(child)
            guard metadata.st_mode & S_IFMT == S_IFDIR || metadata.st_mode & S_IFMT == S_IFREG else {
                throw MacPluginDiskPackageImportError.unsafeEntry
            }
            try rejectAlias(child)
            let target = destination.appendingPathComponent(name)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try copyDirectory(child, into: target, budget: &budget, ancestors: ancestors)
                // Keep owner traversal/write for later discard, retaining the
                // package's group/other and executable permission bits.
                try fileManager.setAttributes([.posixPermissions: Int(metadata.st_mode & 0o777) | 0o700], ofItemAtPath: target.path)
            case S_IFREG:
                try copyFile(child, metadata: metadata, to: target, budget: &budget, archive: false)
            default:
                throw MacPluginDiskPackageImportError.unsafeEntry
            }
        }
        try requireUnchanged(before, after: statDescriptor(source))
    }

    private func copyFile(
        _ source: Int32,
        metadata: stat,
        to destination: URL,
        budget: inout CopyBudget,
        archive: Bool
    ) throws {
        try Task.checkCancellation()
        let maximum = archive ? limits.archiveBytes : limits.extractedBytes
        func exceeded() -> MacPluginPackageDownloadError {
            archive ? .archiveTooLarge(maximum) : .extractionLimitExceeded("more than \(maximum) bytes")
        }
        guard metadata.st_size >= 0, maximum >= budget.bytes,
              metadata.st_size <= maximum - budget.bytes else { throw exceeded() }
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw posixError() }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        defer { Darwin.close(output) }
        let reader = FileHandle(fileDescriptor: source, closeOnDealloc: false)
        while true {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: Self.chunkBytes), !chunk.isEmpty else { break }
            guard Int64(chunk.count) <= maximum - budget.bytes else { throw exceeded() }
            try writer.write(contentsOf: chunk)
            budget.bytes += Int64(chunk.count)
        }
        try requireUnchanged(metadata, after: statDescriptor(source))
        // Retain executable resources while dropping setuid/setgid/sticky bits.
        guard fchmod(output, metadata.st_mode & 0o777) == 0 else { throw posixError() }
    }

    private func requireUnchanged(_ before: stat, after: stat) throws {
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw MacPluginDiskPackageImportError.sourceChanged
        }
    }

    /// Scan every entry, including hidden descendants. A second manifest makes
    /// the import ambiguous even if its ID is different or its JSON is invalid.
    private func validateSnapshot(in root: URL) throws -> URL {
        var scanError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey],
            options: [], errorHandler: { _, error in scanError = error; return false }
        ) else { throw MacPluginPackageDownloadError.invalidArchive }
        var budget = CopyBudget()
        var manifest: URL?
        for case let item as URL in enumerator {
            try countEntry(&budget)
            guard enumerator.level <= Self.maximumDirectoryDepth else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(Self.maximumDirectoryDepth) path components")
            }
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isAliasFile != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw MacPluginDiskPackageImportError.unsafeEntry
            }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                guard size >= 0, limits.extractedBytes >= budget.bytes, size <= limits.extractedBytes - budget.bytes else {
                    throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(limits.extractedBytes) bytes")
                }
                budget.bytes += size
            }
            if item.lastPathComponent.lowercased() == "plugin.json" {
                guard item.lastPathComponent == "plugin.json", values.isRegularFile == true, manifest == nil else {
                    throw MacPluginPackageDownloadError.invalidArchive
                }
                manifest = item
            }
        }
        if let scanError { throw scanError }
        guard let manifest else { throw MacPluginPackageDownloadError.invalidArchive }
        let package = manifest.deletingLastPathComponent().standardizedFileURL
        let root = root.standardizedFileURL
        guard package == root || package.deletingLastPathComponent() == root else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        return package
    }

    private func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
