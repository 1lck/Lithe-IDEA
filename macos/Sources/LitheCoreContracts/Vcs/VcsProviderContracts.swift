import Foundation

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// A VCS provider a declarative plugin adds (`vcsProviders` capability).
/// Rust Core owns its root detection, launch plan, requests, and reply
/// validation; the host only needs to know which VCS it is and its name.
public struct DeclarativeVcsProvider: Equatable, Sendable {
    /// The VCS ID, such as `svn`, that roots and replies carry.
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
