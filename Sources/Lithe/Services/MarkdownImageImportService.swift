import Foundation

struct MarkdownImageImportService: MarkdownImageImporting {
    private static let maximumImageByteCount = 100 * 1_024 * 1_024
    private static let maximumFilenameAttempts = 10_000

    private let storage: any FileStorage

    init(storage: any FileStorage) {
        self.storage = storage
    }

    func importImage(
        _ source: MarkdownImageSource,
        forDocumentAt documentURL: URL,
        workspaceRoot: URL
    ) async throws -> MarkdownImageImportResult {
        let storage = self.storage
        return try await Task.detached(priority: .userInitiated) {
            try Self.importImageSynchronously(
                source,
                forDocumentAt: documentURL,
                workspaceRoot: workspaceRoot,
                storage: storage
            )
        }.value
    }

    private static func importImageSynchronously(
        _ source: MarkdownImageSource,
        forDocumentAt documentURL: URL,
        workspaceRoot: URL,
        storage: any FileStorage
    ) throws -> MarkdownImageImportResult {
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let document = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        let documentDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        guard contains(document, in: root),
              contains(documentDirectory.resolvingSymlinksInPath(), in: root) else {
            throw MarkdownImageImportError.destinationOutsideWorkspace
        }

        let (data, format, suggestedName) = try imageData(for: source, storage: storage)
        guard !data.isEmpty else { throw MarkdownImageImportError.emptyImage }
        guard data.count <= maximumImageByteCount else {
            throw MarkdownImageImportError.imageTooLarge
        }

        let assetDirectory = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        let resolvedAssetDirectory = assetDirectory.resolvingSymlinksInPath()
        guard contains(resolvedAssetDirectory, in: root) else {
            throw MarkdownImageImportError.destinationOutsideWorkspace
        }
        if storage.fileExists(at: assetDirectory) {
            guard storage.metadata(for: resolvedAssetDirectory)?.isDirectory == true else {
                throw MarkdownImageImportError.invalidAssetDirectory
            }
        } else {
            try storage.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        }
        guard contains(assetDirectory.resolvingSymlinksInPath(), in: root) else {
            throw MarkdownImageImportError.destinationOutsideWorkspace
        }

        let baseName = sanitizedBaseName(suggestedName)
        for attempt in 1...maximumFilenameAttempts {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let filename = "\(baseName)\(suffix).\(format.fileExtension)"
            let destination = assetDirectory.appendingPathComponent(filename, isDirectory: false)
            guard contains(destination.resolvingSymlinksInPath(), in: root) else {
                throw MarkdownImageImportError.destinationOutsideWorkspace
            }
            guard !storage.fileExists(at: destination) else { continue }
            do {
                try storage.writeData(data, to: destination, options: .withoutOverwriting)
            } catch {
                if storage.fileExists(at: destination) { continue }
                throw error
            }
            let relativePath = "assets/\(filename)"
            let altText = baseName.replacingOccurrences(of: "-", with: " ")
            return MarkdownImageImportResult(
                fileURL: destination,
                relativePath: relativePath,
                markdownReference: "![\(altText)](\(relativePath))"
            )
        }

        throw MarkdownImageImportError.couldNotChooseFilename
    }

    private static func imageData(
        for source: MarkdownImageSource,
        storage: any FileStorage
    ) throws -> (Data, MarkdownImageFormat, String?) {
        switch source {
        case let .encoded(data, format, suggestedName):
            return (data, format, suggestedName)
        case let .file(url, format):
            if let byteCount = storage.metadata(for: url)?.byteCount,
               byteCount > maximumImageByteCount {
                throw MarkdownImageImportError.imageTooLarge
            }
            do {
                let data = try storage.readData(from: url, options: .mappedIfSafe)
                return (data, format, url.deletingPathExtension().lastPathComponent)
            } catch {
                throw MarkdownImageImportError.couldNotReadImage
            }
        }
    }

    private static func sanitizedBaseName(_ rawValue: String?) -> String {
        let source = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var result = ""
        var previousWasSeparator = false
        for scalar in source.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
            if result.count >= 48 { break }
        }
        let cleaned = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).lowercased()
        return cleaned.isEmpty ? "pasted-image" : cleaned
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
