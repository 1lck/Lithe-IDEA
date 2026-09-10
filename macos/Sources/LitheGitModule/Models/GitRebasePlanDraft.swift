import Foundation

/// Local todo presentation separates predicted squash text from an explicit user override.
package struct GitRebasePlanDraft: Sendable {
    package private(set) var steps: [GitRebaseStep]
    private let originalMessages: [String: String]
    private var rewordMessages: [String: String] = [:]
    private var squashMessages: [String: String] = [:]

    package init(commits: [GitHistoryRewriteCommit] = []) {
        originalMessages = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0.message) })
        steps = commits.map { GitRebaseStep(hash: $0.hash, action: .pick, message: $0.message) }
    }

    package var wireSteps: [GitRebaseStep] {
        steps.map { step in
            let message: String?
            switch step.action {
            case .reword: message = step.message
            case .squash: message = squashMessages[step.hash]
            case .pick, .edit, .fixup, .drop: message = nil
            }
            return GitRebaseStep(hash: step.hash, action: step.action, message: message)
        }
    }

    package var outputCommitCount: Int { steps.filter { [.pick, .reword, .edit].contains($0.action) }.count }

    package var validationMessage: String? {
        var hasPrecedingCommit = false
        for step in steps {
            if step.action == .drop { continue }
            if step.action == .squash || step.action == .fixup {
                if !hasPrecedingCommit { return "Squash and Fixup need a preceding commit that is not dropped." }
            } else {
                hasPrecedingCommit = true
            }
            if step.action == .reword, (step.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Every Reword step needs a commit message."
            }
            if step.action == .squash, let custom = squashMessages[step.hash],
               custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a Squash message or use the default combined messages."
            }
        }
        return nil
    }

    package func subject(for hash: String) -> String {
        (originalMessages[hash] ?? hash).components(separatedBy: "\n").first ?? hash
    }

    package mutating func setAction(_ action: GitRebaseAction, for hash: String) {
        guard let index = steps.firstIndex(where: { $0.hash == hash }) else { return }
        steps[index].action = action
        rebuildMessages()
    }

    package mutating func setMessage(_ message: String, for hash: String) {
        guard let step = steps.first(where: { $0.hash == hash }) else { return }
        switch step.action {
        case .reword: rewordMessages[hash] = message
        case .squash: squashMessages[hash] = message
        default: return
        }
        rebuildMessages()
    }

    package mutating func useDefaultSquashMessage(for hash: String) {
        squashMessages[hash] = nil
        rebuildMessages()
    }

    package mutating func move(_ hash: String, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.hash == hash }), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
        rebuildMessages()
    }

    private mutating func rebuildMessages() {
        var precedingMessage: String?
        for index in steps.indices {
            let hash = steps[index].hash
            let original = originalMessages[hash] ?? ""
            switch steps[index].action {
            case .pick, .edit:
                steps[index].message = original
                precedingMessage = original
            case .reword:
                steps[index].message = rewordMessages[hash] ?? original
                precedingMessage = steps[index].message
            case .squash:
                let predicted = [precedingMessage, original].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                steps[index].message = squashMessages[hash] ?? predicted
                precedingMessage = steps[index].message
            case .fixup, .drop:
                steps[index].message = original
            }
        }
    }
}
