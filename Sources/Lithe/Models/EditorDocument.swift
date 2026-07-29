import Foundation

@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var text: String
    @Published private(set) var savedText: String
    @Published var hasExternalConflict = false
    private(set) var lastKnownModificationDate: Date?

    init(url: URL, text: String, modificationDate: Date?) {
        self.url = url
        self.text = text
        self.savedText = text
        self.lastKnownModificationDate = modificationDate
    }

    var isDirty: Bool { text != savedText }

    func save() throws {
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

    static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
