import Foundation

@MainActor
final class EditorDocument: ObservableObject, Identifiable, @unchecked Sendable {
    enum DocumentError: LocalizedError {
        case readOnly

        var errorDescription: String? {
            switch self {
            case .readOnly:
                "This document is read-only"
            }
        }
    }

    let id = UUID()
    private(set) var url: URL
    let isReadOnly: Bool
    let displayPath: String?
    @Published var text: String
    @Published private(set) var savedText: String
    @Published var hasExternalConflict = false
    private(set) var lastKnownModificationDate: Date?

    init(
        url: URL,
        text: String,
        modificationDate: Date?,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        self.url = url
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
        self.text = text
        self.savedText = text
        self.lastKnownModificationDate = modificationDate
    }

    var displayName: String {
        displayPath?.split(separator: "/").last.map(String.init) ?? url.lastPathComponent
    }

    var isDirty: Bool { text != savedText }

    func save() throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
        lastKnownModificationDate = Self.modificationDate(for: url)
        hasExternalConflict = false
    }

    func reloadFromDisk() throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        text = contents
        savedText = contents
        lastKnownModificationDate = Self.modificationDate(for: url)
        hasExternalConflict = false
    }

    func keepEditorVersion() {
        lastKnownModificationDate = Self.modificationDate(for: url)
        hasExternalConflict = false
    }

    func processPossibleExternalChange() -> Bool {
        let currentDate = Self.modificationDate(for: url)
        guard currentDate != lastKnownModificationDate else { return false }

        if isDirty {
            hasExternalConflict = true
        } else {
            try? reloadFromDisk()
        }
        return true
    }

    func markSavedWithoutWriting() {
        savedText = text
    }

    func relocate(to newURL: URL) {
        objectWillChange.send()
        url = newURL.standardizedFileURL
        lastKnownModificationDate = Self.modificationDate(for: newURL)
    }

    static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
