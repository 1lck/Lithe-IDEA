import AppKit
import UniformTypeIdentifiers

enum TerminalTabDragPayload {
    static let type = UTType(exportedAs: "com.lithe.terminal-tab")
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    private static let activeDrag = ActiveTerminalTabDrag()

    static var activeSessionID: UUID? { activeDrag.sessionID }

    static func provider(for sessionID: UUID) -> NSItemProvider {
        activeDrag.store(sessionID)
        let data = Data(sessionID.uuidString.utf8)
        // AppKit needs a concrete standard representation to establish the
        // native drag session. CodeTextView explicitly rejects providers that
        // also advertise the private terminal-tab type.
        let provider = NSItemProvider(object: "Terminal" as NSString)
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func sessionID(from data: Data) -> UUID? {
        String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
    }

    static func sessionID(from pasteboard: NSPasteboard) -> UUID? {
        if let data = pasteboard.data(forType: pasteboardType),
           let sessionID = sessionID(from: data) {
            return sessionID
        }
        // SwiftUI advertises NSItemProvider types before their promised data is
        // necessarily available to synchronous AppKit pasteboard readers.
        guard pasteboard.availableType(from: [pasteboardType]) != nil else { return nil }
        return activeDrag.sessionID
    }

    @discardableResult
    static func loadSessionID(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (UUID) -> Void
    ) -> Bool {
        guard !providers.isEmpty else { return false }
        // Terminal tab drags are process-local and only one native drag can be
        // active at a time. Resolve that identity immediately so a promised
        // representation cannot turn a valid drop into a silent no-op.
        if let sessionID = activeDrag.sessionID {
            MainActor.assumeIsolated {
                completion(sessionID)
            }
            return true
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(type.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let sessionID = sessionID(from: data) else { return }
            Task { @MainActor in
                completion(sessionID)
            }
        }
        return true
    }
}

private final class ActiveTerminalTabDrag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionID: UUID?

    var sessionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedSessionID
    }

    func store(_ sessionID: UUID) {
        lock.lock()
        storedSessionID = sessionID
        lock.unlock()
    }
}
