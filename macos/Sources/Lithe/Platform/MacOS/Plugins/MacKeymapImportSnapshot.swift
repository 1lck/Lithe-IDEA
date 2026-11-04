import Darwin
import Foundation
import CryptoKit

/// A short-lived, read-only view of Core-planned files under one selected root.
/// Construct and read it off the main actor; its owner must close it when the
/// import completes, is cancelled, or its plugin session ends.
final class MacKeymapImportSnapshot: @unchecked Sendable {
    struct File: Equatable, Sendable {
        let id: String
        let path: String
        let byteCount: Int
    }

    enum Failure: Error {
        case invalidPlan, limitExceeded, closed, unknownFile, invalidRange, sourceChanged
    }

    private struct OpenFile {
        let file: File
        let descriptor: Int32
        let components: [String]
        let status: Darwin.stat
    }

    let files: [File]
    private let lock = NSLock()
    private let rootDescriptor: Int32
    private let maximumChunkBytes: Int
    private var openFiles: [String: OpenFile]
    private var isClosed = false

    init(root: URL, plan: KeymapImportSourcePlan) throws {
        let limits = plan.limits
        guard !plan.inputs.isEmpty, plan.inputs.count <= limits.selectors,
              limits.files > 0, limits.fileBytes > 0, limits.totalBytes > 0,
              limits.chunkBytes > 0, limits.directoryEntries > 0, limits.directoryMatches > 0 else {
            throw Failure.invalidPlan
        }
        let rootFD = try MacWorkspaceSecurePath.openRoot(root)
        var opened: [(path: String, components: [String], fd: Int32, status: Darwin.stat)] = []
        var committed = false
        defer {
            if !committed {
                opened.forEach { Darwin.close($0.fd) }
                Darwin.close(rootFD)
            }
        }
        var seen: Set<String> = []
        var totalBytes = 0

        func add(_ components: [String]) throws {
            try Task.checkCancellation()
            let path = components.joined(separator: "/")
            guard let name = components.last, seen.insert(path).inserted else { return }
            do {
                let parent = try MacWorkspaceSecurePath.openDirectory(components.dropLast(), below: rootFD)
                defer { Darwin.close(parent) }
                let file = try MacWorkspaceSecurePath.openRegularFile(named: name, in: parent)
                let size = file.status.st_size
                let (sum, overflow) = totalBytes.addingReportingOverflow(Int(size))
                guard size >= 0, size <= off_t(limits.fileBytes), !overflow,
                      opened.count < limits.files, sum <= limits.totalBytes else {
                    Darwin.close(file.descriptor)
                    throw Failure.limitExceeded
                }
                totalBytes = sum
                opened.append((path, components, file.descriptor, file.status))
            } catch PluginWorkspaceFileError.notFound {
                // A declared optional source is allowed to be absent.
            }
        }

        for selector in plan.inputs {
            try Task.checkCancellation()
            let components = try MacWorkspaceSecurePath.components(of: selector.path)
            guard !components.isEmpty else { throw Failure.invalidPlan }
            switch selector.kind {
            case .file:
                guard selector.fileExtension == nil else { throw Failure.invalidPlan }
                try add(components)
            case .directory:
                guard let ext = selector.fileExtension, !ext.isEmpty else { throw Failure.invalidPlan }
                do {
                    let directory = try MacWorkspaceSecurePath.openDirectory(components[...], below: rootFD)
                    defer { Darwin.close(directory) }
                    let names = try Self.names(in: directory, maximum: limits.directoryEntries).filter { $0.hasSuffix("." + ext) }.sorted()
                    guard names.count <= limits.directoryMatches else { throw Failure.limitExceeded }
                    for name in names {
                        let normalized = try MacWorkspaceSecurePath.components(of: (components + [name]).joined(separator: "/"))
                        try add(normalized)
                    }
                } catch PluginWorkspaceFileError.notFound {
                    // An absent directory contributes no files.
                }
            }
        }

        opened.sort { $0.path < $1.path }
        var byID: [String: OpenFile] = [:]
        var listed: [File] = []
        for (index, item) in opened.enumerated() {
            let file = File(id: "file-\(index)", path: item.path, byteCount: Int(item.status.st_size))
            listed.append(file)
            byID[file.id] = OpenFile(file: file, descriptor: item.fd, components: item.components, status: item.status)
        }
        rootDescriptor = rootFD
        maximumChunkBytes = limits.chunkBytes
        openFiles = byID
        files = listed
        committed = true
    }

    deinit { close() }

    /// Reads one bounded chunk and refuses a file replaced or modified since the snapshot.
    func read(fileID: String, offset: Int, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, maximumBytes > 0, maximumBytes <= maximumChunkBytes else { throw Failure.invalidRange }
        lock.lock()
        guard !isClosed else { lock.unlock(); throw Failure.closed }
        guard let file = openFiles[fileID] else { lock.unlock(); throw Failure.unknownFile }
        let rootFD = dup(rootDescriptor)
        guard rootFD >= 0 else {
            let error = errno
            lock.unlock()
            throw MacWorkspaceSecurePath.map(error)
        }
        let fileFD = dup(file.descriptor)
        guard fileFD >= 0 else {
            let error = errno
            lock.unlock()
            Darwin.close(rootFD)
            throw MacWorkspaceSecurePath.map(error)
        }
        lock.unlock()
        defer { Darwin.close(rootFD); Darwin.close(fileFD) }
        guard offset <= file.file.byteCount else { throw Failure.invalidRange }
        try Self.check(file: file, rootFD: rootFD, fileFD: fileFD)
        let wanted = min(maximumBytes, file.file.byteCount - offset)
        var data = Data(count: wanted)
        let count = try data.withUnsafeMutableBytes { bytes -> Int in
            if wanted == 0 { return 0 }
            while true {
                try Task.checkCancellation()
                let result = pread(fileFD, bytes.baseAddress, wanted, off_t(offset))
                if result >= 0 { return result }
                if errno != EINTR { throw MacWorkspaceSecurePath.map(errno) }
            }
        }
        guard count > 0 || wanted == 0 else { throw Failure.sourceChanged }
        data.count = count
        try Self.check(file: file, rootFD: rootFD, fileFD: fileFD)
        try Task.checkCancellation()
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { throw Failure.closed }
        return data
    }

    /// Rechecks every captured file, including files the provider did not read.
    /// The caller must repeat its source checks at the point of applying changes.
    func validate() throws {
        for file in files {
            try Task.checkCancellation()
            _ = try read(fileID: file.id, offset: 0, maximumBytes: 1)
        }
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { throw Failure.closed }
    }

    /// A source revision for the preview/apply check, computed off the main
    /// actor from every captured file and its relative name.
    func contentDigest() throws -> String {
        var hash = SHA256()
        for file in files {
            try Task.checkCancellation()
            hash.update(data: Data(file.path.utf8))
            hash.update(data: Data([0]))
            var size = UInt64(file.byteCount).bigEndian
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            var offset = 0
            while offset < file.byteCount {
                let data = try read(fileID: file.id, offset: offset, maximumBytes: min(maximumChunkBytes, file.byteCount - offset))
                guard !data.isEmpty else { throw Failure.sourceChanged }
                hash.update(data: data)
                offset += data.count
            }
        }
        try validate()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Revokes future reads and releases every descriptor; safe to call twice.
    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let descriptors = openFiles.values.map(\.descriptor)
        openFiles.removeAll()
        lock.unlock()
        descriptors.forEach { Darwin.close($0) }
        Darwin.close(rootDescriptor)
    }

    private static func check(file: OpenFile, rootFD: Int32, fileFD: Int32) throws {
        var status = Darwin.stat()
        guard fstat(fileFD, &status) == 0 else { throw MacWorkspaceSecurePath.map(errno) }
        guard sameFile(status, file.status) else { throw Failure.sourceChanged }
        do {
            let parent = try MacWorkspaceSecurePath.openDirectory(file.components.dropLast(), below: rootFD)
            defer { Darwin.close(parent) }
            let current = try MacWorkspaceSecurePath.status(of: file.components.last!, in: parent)
            guard sameFile(current, file.status) else { throw Failure.sourceChanged }
        } catch {
            throw Failure.sourceChanged
        }
    }

    private static func sameFile(_ left: Darwin.stat, _ right: Darwin.stat) -> Bool {
        left.st_mode & S_IFMT == S_IFREG && left.st_dev == right.st_dev && left.st_ino == right.st_ino
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    private static func names(in directory: Int32, maximum: Int) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw MacWorkspaceSecurePath.map(errno) }
        guard let stream = fdopendir(copy) else {
            let error = errno
            Darwin.close(copy)
            throw MacWorkspaceSecurePath.map(error)
        }
        defer { closedir(stream) }
        var result: [String] = []
        var scanned = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw MacWorkspaceSecurePath.map(errno) }
                return result
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard scanned < maximum else { throw Failure.limitExceeded }
            scanned += 1
            if scanned % 128 == 0 { try Task.checkCancellation() }
            guard let name else { continue }
            result.append(name.precomposedStringWithCanonicalMapping)
        }
    }
}
