import CryptoKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Generic native-file boundary. The provider owns source discovery and field
/// edits; this adapter owns private staging, filesystem
/// validation and conditional publication. No build-tool precedence lives here.
struct MacBuildNativeConfigurationStore: BuildNativeConfigurationStoring {
    let storage: any FileStorage
    let planner: any BuildSystemPlanning
    let immutableRoots: [URL]
    private let maximumBytes = 2 * 1024 * 1024

    func prepare(target: BuildSystemTarget, snapshot: BuildNativeConfiguration,
                 edits: BuildNativeConfigurationEdits, stateDirectory: URL) throws -> BuildNativeConfigurationStaging? {
        guard let source = snapshot.sources.first(where: { $0.id == edits.sourceID }),
              source.writable, source.scope != .installation,
              let uri = URL(string: source.uri), uri.isFileURL,
              uri.query == nil, uri.fragment == nil, uri.user == nil, uri.password == nil else {
            throw NativeConfigurationFileError.readOnly
        }
        let url = try validatedTarget(uri)
        guard !snapshot.sources.contains(where: { other in
            guard other.id != source.id, let alias = URL(string: other.uri) else { return false }
            return alias.standardizedFileURL.resolvingSymlinksInPath() == url
        }) else { throw NativeConfigurationFileError.readOnly }
        let existing: Data?
        if storage.fileExists(at: url) {
            guard let metadata = storage.metadata(for: url), metadata.isRegularFile,
                  metadata.isWritable, let count = metadata.byteCount, count <= maximumBytes else {
                throw NativeConfigurationFileError.unreadable
            }
            let data = try storage.readData(from: url, options: [])
            guard data.count <= maximumBytes else { throw NativeConfigurationFileError.unreadable }
            existing = data
        } else { existing = nil }
        let revision = existing.map { "sha256:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
        guard revision == source.revision, revision == edits.revision else { throw NativeConfigurationFileError.conflict }
        _ = try planner.decodeConfiguration(target, result: JSONDecoder().decode(ToolingJSONValue.self, from: JSONEncoder().encode(snapshot)))
        guard edits.values.contains(where: { id, value in source.fields.first(where: { $0.id == id })?.value != value }) else { return nil }
        let outputs = try validatedTarget(stateDirectory.appendingPathComponent("outputs", isDirectory: true))
        try storage.createDirectory(at: outputs, withIntermediateDirectories: true)
        let output = outputs.appendingPathComponent(UUID().uuidString + ".json")
        // Existing output-file lifecycle, private mode 0600. Providers must open
        // without CREATE: cancellation can unlink it before a late write starts.
        guard try storage.replaceDataPreservingMetadata(Data(), at: output, expecting: nil) else {
            throw NativeConfigurationFileError.conflict
        }
        return BuildNativeConfigurationStaging(sourceID: source.id, sourceURL: uri, url: url, expected: existing, outputFile: output)
    }

    func complete(_ staging: BuildNativeConfigurationStaging, receipt: BuildNativeConfigurationEditReceipt) throws -> BuildNativeConfigurationPreparedWrite? {
        guard receipt.sourceID == staging.sourceID else { throw NativeConfigurationFileError.conflict }
        guard receipt.changed else { return nil }
        guard staging.outputFile.standardizedFileURL.resolvingSymlinksInPath() == staging.outputFile,
              let metadata = storage.metadata(for: staging.outputFile), metadata.isRegularFile,
              let count = metadata.byteCount, count <= maximumBytes else { throw NativeConfigurationFileError.unreadable }
        let data = try storage.readData(from: staging.outputFile, options: [])
        guard data.count <= maximumBytes,
              receipt.revision == "sha256:" + SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
            throw NativeConfigurationFileError.conflict
        }
        if data == staging.expected { return nil }
        return BuildNativeConfigurationPreparedWrite(url: staging.url, sourceURL: staging.sourceURL, expected: staging.expected,
            replacement: data, revision: receipt.revision)
    }

    func discard(_ staging: BuildNativeConfigurationStaging) throws {
        if storage.fileExists(at: staging.outputFile) {
            guard storage.metadata(for: staging.outputFile)?.isDirectory != true else { throw NativeConfigurationFileError.unreadable }
            try storage.removeItem(at: staging.outputFile)
        }
    }

    func commit(_ write: BuildNativeConfigurationPreparedWrite) throws {
        let url = try validatedTarget(write.sourceURL)
        guard url == write.url else { throw NativeConfigurationFileError.conflict }
        if let metadata = storage.metadata(for: url), !metadata.isRegularFile || !metadata.isWritable {
            throw NativeConfigurationFileError.readOnly
        }
        try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try storage.replaceDataPreservingMetadata(write.replacement, at: url, expecting: write.expected) else {
            throw NativeConfigurationFileError.conflict
        }
    }

    private func validatedTarget(_ source: URL) throws -> URL {
        let target = source.standardizedFileURL.resolvingSymlinksInPath()
        guard target.isFileURL, !target.path.contains("\0"), !target.lastPathComponent.isEmpty else {
            throw NativeConfigurationFileError.readOnly
        }
        for root in immutableRoots {
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            if target.path == path || target.path.hasPrefix(path + "/") { throw NativeConfigurationFileError.readOnly }
        }
        return target
    }
}

private enum NativeConfigurationFileError: LocalizedError {
    case conflict, readOnly, unreadable
    var errorDescription: String? {
        switch self {
        case .conflict: L10n.string("Native configuration changed on disk. Reload before saving; your draft has been kept.")
        case .readOnly: L10n.string("This native configuration source is read-only. Installed applications and plugin packages cannot be edited.")
        case .unreadable: L10n.string("The native configuration must be a writable file smaller than 2 MB.")
        }
    }
}
