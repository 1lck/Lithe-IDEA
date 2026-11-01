import AppKit
import UniformTypeIdentifiers

enum TerminalTabDragPayload {
    static let type = UTType(exportedAs: "com.lithe.terminal-tab")
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    private static let activeDrag = ActiveTerminalTabDrag()
    private static let dragState = TerminalTabDragState()

    static var activeSessionID: UUID? { activeDrag.sessionID }
    static var isDragging: Bool { dragState.isDragging }

    /// AppKit drags own the session for the gesture; drops read the pasteboard and fall back here.
    static func beginDrag(_ sessionID: UUID) {
        activeDrag.store(sessionID)
        dragState.set(true)
    }

    static func endDrag() {
        dragState.set(false)
        activeDrag.clear()
    }

    static func sessionID(from data: Data) -> UUID? {
        String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
    }

    static func sessionID(from pasteboard: NSPasteboard) -> UUID? {
        if let value = pasteboard.string(forType: pasteboardType),
           let sessionID = UUID(uuidString: value) {
            return sessionID
        }
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

private final class TerminalTabDragState: @unchecked Sendable {
    private let lock = NSLock()
    private var dragging = false

    var isDragging: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dragging
    }

    func set(_ value: Bool) {
        lock.lock()
        dragging = value
        lock.unlock()
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

    func clear() {
        lock.lock()
        storedSessionID = nil
        lock.unlock()
    }
}
