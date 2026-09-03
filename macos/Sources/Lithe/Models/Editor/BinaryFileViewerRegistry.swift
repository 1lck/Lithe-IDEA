import Foundation

/// A byte pattern used to recognize a binary format without trusting its
/// filename. Patterns may start at a non-zero offset for formats whose marker
/// is not located at the first byte.
struct BinaryFileMagicSignature: Sendable, Equatable {
    let offset: Int
    let bytes: Data

    init(offset: Int = 0, bytes: Data) {
        precondition(offset >= 0, "A magic signature offset cannot be negative")
        precondition(!bytes.isEmpty, "A magic signature cannot be empty")
        self.offset = offset
        self.bytes = bytes
    }

    func matches(_ header: Data) -> Bool {
        guard offset <= header.count, bytes.count <= header.count - offset else { return false }
        let start = header.index(header.startIndex, offsetBy: offset)
        let end = header.index(start, offsetBy: bytes.count)
        return header[start..<end].elementsEqual(bytes)
    }
}

enum BinaryFileViewerMatch: Sendable, Equatable {
    case magicSignature
    case fileExtension(String)
}

struct BinaryFileOpenRequest: Sendable {
    let url: URL
    let viewerIdentifier: String
    let match: BinaryFileViewerMatch
    let activateWhenReady: Bool
}

/// Describes an optional binary-file viewer; constructing this value does not
/// enable a format until it is explicitly added to `BinaryFileViewerRegistry`.
struct BinaryFileViewerRegistration {
    let identifier: String
    let fileExtensions: Set<String>
    let magicSignatures: [BinaryFileMagicSignature]
    let open: @MainActor @Sendable (BinaryFileOpenRequest) async -> Void

    init(
        identifier: String,
        fileExtensions: Set<String> = [],
        magicSignatures: [BinaryFileMagicSignature] = [],
        open: @escaping @MainActor @Sendable (BinaryFileOpenRequest) async -> Void
    ) {
        precondition(!identifier.isEmpty, "A binary viewer identifier cannot be empty")
        let normalizedExtensions = Set(fileExtensions.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }.filter { !$0.isEmpty })
        precondition(
            !normalizedExtensions.isEmpty || !magicSignatures.isEmpty,
            "A binary viewer must declare an extension or magic signature"
        )
        self.identifier = identifier
        self.fileExtensions = normalizedExtensions
        self.magicSignatures = magicSignatures
        self.open = open
    }
}

@MainActor
final class BinaryFileViewerRegistry {
    /// Format detection is intentionally bounded. A future viewer whose magic
    /// marker lies beyond this prefix must opt into a larger probing design.
    nonisolated static let headerByteCount = 4 * 1024

    // The application starts with this array empty. No binary format is built
    // in; composition roots may explicitly register viewers in the future.
    private var registrations: [BinaryFileViewerRegistration] = []

    /// Re-registering an identifier replaces its previous format rules.
    func register(_ registration: BinaryFileViewerRegistration) {
        registrations.removeAll { $0.identifier == registration.identifier }
        registrations.append(registration)
    }

    func unregister(identifier: String) {
        registrations.removeAll { $0.identifier == identifier }
    }

    /// Magic signatures win over extensions across the whole registry. This
    /// lets a strongly identified format beat a misleading filename suffix.
    @discardableResult
    func openIfSupported(
        url: URL,
        header: Data,
        activateWhenReady: Bool = true
    ) async -> Bool {
        if let registration = registrations.first(where: { registration in
            registration.magicSignatures.contains { $0.matches(header) }
        }) {
            await registration.open(BinaryFileOpenRequest(
                url: url,
                viewerIdentifier: registration.identifier,
                match: .magicSignature,
                activateWhenReady: activateWhenReady
            ))
            return true
        }

        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              let registration = registrations.first(where: {
                  $0.fileExtensions.contains(fileExtension)
              }) else { return false }
        await registration.open(BinaryFileOpenRequest(
            url: url,
            viewerIdentifier: registration.identifier,
            match: .fileExtension(fileExtension),
            activateWhenReady: activateWhenReady
        ))
        return true
    }
}
