import Foundation

/// The editable todo list. Core (`git.rebasePlanPreview`) validates it and
/// derives every message; the draft only keeps the user's order, actions, and
/// explicit message overrides, and shows the last preview Core returned.
package struct GitRebasePlanDraft: Sendable {
    package private(set) var steps: [GitRebaseStep]
    private let commits: [GitHistoryRewriteCommit]
    private let originalMessages: [String: String]
    private var rewordMessages: [String: String] = [:]
    private var squashMessages: [String: String] = [:]
    private var preview: GitRebasePlanPreview?

    package init(commits: [GitHistoryRewriteCommit] = []) {
        self.commits = commits
        originalMessages = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0.message) })
        steps = commits.map { GitRebaseStep(hash: $0.hash, action: .pick, message: $0.message) }
    }

    /// The draft as Core receives it: only explicit overrides carry a message.
    package var previewRequest: GitRebasePreviewRequest {
        GitRebasePreviewRequest(
            commits: commits.map { .init(hash: $0.hash, message: $0.message) },
            steps: steps.map { step in
                switch step.action {
                case .reword: GitRebaseStep(hash: step.hash, action: .reword, message: rewordMessages[step.hash])
                case .squash: GitRebaseStep(hash: step.hash, action: .squash, message: squashMessages[step.hash])
                default: GitRebaseStep(hash: step.hash, action: step.action)
                }
            })
    }

    /// Shows Core's answer for `request`; a stale answer for an older draft is ignored.
    package mutating func apply(_ plan: GitRebasePlanPreview, for request: GitRebasePreviewRequest) {
        guard request == previewRequest else { return }
        preview = plan
        for index in steps.indices {
            if let row = plan.steps.first(where: { $0.hash == steps[index].hash }) { steps[index].message = row.message }
        }
    }

    /// Exact steps for `git.rebaseStart`; empty until Core has answered for the current draft.
    package var wireSteps: [GitRebaseStep] { preview?.startSteps ?? [] }

    package var outputCommitCount: Int { preview?.outputCommitCount ?? 0 }

    /// True once Core has validated the current draft.
    package var isPlanned: Bool { preview != nil }

    package var issue: GitRebasePlanPreview.Issue? { preview?.issue }

    package func subject(for hash: String) -> String {
        (originalMessages[hash] ?? hash).components(separatedBy: "\n").first ?? hash
    }

    package mutating func setAction(_ action: GitRebaseAction, for hash: String) {
        guard let index = steps.firstIndex(where: { $0.hash == hash }) else { return }
        steps[index].action = action
        invalidate()
    }

    package mutating func setMessage(_ message: String, for hash: String) {
        guard let step = steps.first(where: { $0.hash == hash }) else { return }
        switch step.action {
        case .reword: rewordMessages[hash] = message
        case .squash: squashMessages[hash] = message
        default: return
        }
        invalidate()
    }

    package mutating func useDefaultSquashMessage(for hash: String) {
        squashMessages[hash] = nil
        invalidate()
    }

    package mutating func move(_ hash: String, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.hash == hash }), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
        invalidate()
    }

    /// Edits show the user's text immediately; Core's derivation replaces the rest when it answers.
    private mutating func invalidate() {
        preview = nil
        for index in steps.indices {
            let hash = steps[index].hash
            switch steps[index].action {
            case .reword: steps[index].message = rewordMessages[hash] ?? originalMessages[hash]
            case .squash: if let custom = squashMessages[hash] { steps[index].message = custom }
            default: steps[index].message = originalMessages[hash]
            }
        }
    }
}
