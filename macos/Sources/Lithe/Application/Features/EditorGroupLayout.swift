import Foundation

/// Editor groups own tab placement and selection; documents and sessions keep their existing owners.
indirect enum EditorGroupLayout: Equatable {
    case group(UUID)
    case split(id: UUID, vertical: Bool, first: EditorGroupLayout, second: EditorGroupLayout)

    var groups: [UUID] {
        switch self {
        case .group(let id): [id]
        case .split(_, _, let first, let second): first.groups + second.groups
        }
    }

    func replacing(_ id: UUID, with replacement: EditorGroupLayout) -> EditorGroupLayout {
        switch self {
        case .group(let current): current == id ? replacement : self
        case .split(let splitID, let vertical, let first, let second):
            .split(id: splitID, vertical: vertical, first: first.replacing(id, with: replacement), second: second.replacing(id, with: replacement))
        }
    }

    /// Splits `id` along `side`; a leading edge puts the new group first.
    func splitting(_ id: UUID, by side: EditorGroupDropSide, newGroup: UUID) -> EditorGroupLayout {
        let new = Self.group(newGroup), old = Self.group(id)
        let leading = side == .left || side == .top
        let layout = Self.split(id: UUID(), vertical: side.isVertical, first: leading ? new : old, second: leading ? old : new)
        return replacing(id, with: layout)
    }

    func keeping(_ ids: Set<UUID>) -> EditorGroupLayout? {
        switch self {
        case .group(let id): return ids.contains(id) ? self : nil
        case .split(let id, let vertical, let first, let second):
            let a = first.keeping(ids), b = second.keeping(ids)
            if let a, let b { return .split(id: id, vertical: vertical, first: a, second: b) }
            return a ?? b
        }
    }
}

enum EditorGroupDropSide: CaseIterable {
    case center, left, right, top, bottom

    var isVertical: Bool { self == .top || self == .bottom }
}
