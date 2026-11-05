import Foundation

/// Editor group split tree as returned by Rust Core (`editor.workbenchState.reduce`).
/// Core owns how the tree splits and collapses; this type only presents it.
indirect enum EditorGroupLayout: Equatable {
    case group(UUID)
    case split(id: UUID, vertical: Bool, first: EditorGroupLayout, second: EditorGroupLayout)

    var groups: [UUID] {
        switch self {
        case .group(let id): [id]
        case .split(_, _, let first, let second): first.groups + second.groups
        }
    }
}

extension EditorGroupLayout: Codable {
    private struct Split: Codable {
        let id: UUID
        let orientation: String
        let first: EditorGroupLayout
        let second: EditorGroupLayout
    }

    private enum CodingKeys: String, CodingKey { case group, split }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .group) {
            self = .group(id)
            return
        }
        let split = try container.decode(Split.self, forKey: .split)
        self = .split(id: split.id, vertical: split.orientation == "vertical", first: split.first, second: split.second)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let id):
            try container.encode(id, forKey: .group)
        case .split(let id, let vertical, let first, let second):
            try container.encode(
                Split(id: id, orientation: vertical ? "vertical" : "horizontal", first: first, second: second),
                forKey: .split)
        }
    }
}

enum EditorGroupDropSide: String, CaseIterable, Encodable {
    case center, left, right, top, bottom
}
