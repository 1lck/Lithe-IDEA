import Foundation

/// Thin adapter over Core's `editor.workbenchState.reduce`. Which tab belongs to which editor group,
/// which tab a group shows, and what happens to that when tabs move, close or have no home yet are
/// rules in rust/lithe-core-rules; the Windows frontend runs the same Rust source as wasm. This type
/// only converts model values to the canonical state and back. Each call is one synchronous FFI round
/// trip on a user action (opening, closing, moving or dropping a tab), never during drags or resizes.
///
/// macOS has no MRU list, pinned tabs or preview tab, so those canonical fields are always empty
/// here and Core returns them unchanged.
struct RustEditorWorkbenchState {
    struct Group: Codable, Equatable {
        var id: String
        var members: [String]
        var selected: String?
        var mru: [String] = []
        var pinned: [String] = []
        var preview: String?
    }

    struct State: Codable, Equatable {
        var groups: [Group]
        var focusedGroup: String?
    }

    struct Reduction: Decodable {
        let state: State
        let removedGroupIds: [String]
    }

    /// The only two transitions the macOS model asks for. Empty groups are always removed (keeping
    /// the first so the editor never has zero groups), and a vanished selection falls back to the
    /// group's first tab.
    enum Action: Encodable {
        /// Repairs every group; `unplaced` tabs join the focused group.
        case normalize(unplaced: [String])
        /// Moves or repositions a tab; `before` / `after` name an anchor tab in the destination.
        case move(member: String, from: String, to: String, before: String?, after: String?)

        private enum Keys: String, CodingKey {
            case kind, unplaced, member, from, to, before, after, activate, emptyGroups, selectionFallback
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode("removeKeepingFirst", forKey: .emptyGroups)
            switch self {
            case let .normalize(unplaced):
                try container.encode("normalize", forKey: .kind)
                try container.encode(unplaced, forKey: .unplaced)
            case let .move(member, from, to, before, after):
                try container.encode("move", forKey: .kind)
                try container.encode(member, forKey: .member)
                try container.encode(from, forKey: .from)
                try container.encode(to, forKey: .to)
                try container.encodeIfPresent(before, forKey: .before)
                try container.encodeIfPresent(after, forKey: .after)
                // The model selects through `focus`, so a move itself never changes the selection.
                try container.encode(false, forKey: .activate)
                try container.encode("first", forKey: .selectionFallback)
            }
        }
    }

    private struct Request: Encodable {
        let state: State
        let action: Action
    }

    private let core: RustCoreBridge

    init(core: RustCoreBridge = RustCoreBridge()) {
        self.core = core
    }

    /// Returns nil only if the linked Core rejects a well-formed request, which means Core is
    /// broken; there is no second implementation to fall back to, so the model stays unchanged.
    func reduce(_ state: State, _ action: Action) -> Reduction? {
        let result: Result<Reduction, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "editor.workbenchState.reduce",
            payload: Request(state: state, action: action)
        )
        switch result {
        case let .success(reduction): return reduction
        case .failure:
            assertionFailure("editor.workbenchState.reduce failed")
            return nil
        }
    }
}

extension EditorTabItem {
    /// Stable string Core uses to name this tab; the model maps results back with a lookup table.
    var workbenchKey: String {
        switch self {
        case .document(let id): "document:\(id.uuidString)"
        case .terminal(let id): "terminal:\(id.uuidString)"
        case .media(let id): "media:\(id.uuidString)"
        case .repositoryDiff(let id): "repositoryDiff:\(id.uuidString)"
        case .languageLogs: "languageLogs"
        case .agentConversation(let id): "agentConversation:\(id.uuidString)"
        }
    }
}
