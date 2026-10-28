import CryptoKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Generic native-file boundary. The provider owns source discovery and field
/// bindings; Core edits only approved XML nodes; this adapter owns filesystem
/// validation and conditional publication. No Maven precedence lives here.
struct MacBuildNativeConfigurationStore: BuildNativeConfigurationStoring {
    let storage: any FileStorage
    let planner: any BuildSystemPlanning
    let immutableRoots: [URL]
    private let maximumBytes = 2 * 1024 * 1024

    func prepare(target: BuildSystemTarget, snapshot: BuildNativeConfiguration,
                 edits: BuildNativeConfigurationEdits) throws -> BuildNativeConfigurationPreparedWrite? {
        guard let source = snapshot.sources.first(where: { $0.id == edits.sourceID }),
              source.writable, source.scope != .installation,
              let uri = URL(string: source.uri), uri.isFileURL,
              uri.query == nil, uri.fragment == nil, uri.user == nil, uri.password == nil else {
            throw NativeConfigurationFileError.readOnly
        }
        let url = try validatedTarget(uri)
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
        let document = existing.map { String(decoding: $0, as: UTF8.self) }
        guard document?.data(using: .utf8) == existing else { throw NativeConfigurationFileError.unreadable }
        let edited = try planner.editConfigurationDocument(target, snapshot: snapshot, edits: edits, document: document)
        guard edited.changed else { return nil }
        guard let document = edited.document, let data = document.data(using: .utf8), data.count <= maximumBytes else {
            throw NativeConfigurationFileError.unreadable
        }
        return BuildNativeConfigurationPreparedWrite(url: url, sourceURL: uri, expected: existing, replacement: data, revision: edited.revision)
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
        case .unreadable: L10n.string("The native configuration must be a writable UTF-8 XML file smaller than 2 MB.")
        }
    }
}
