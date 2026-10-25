import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

/// The cached derivation must give exactly what regrouping the whole conversation
/// gives, at every point while a conversation grows and when earlier messages change.
@MainActor
@Suite("Transcript derivation cache")
struct AgentTranscriptDerivationTests {
    private static let notification = "<task-notification><status>completed</status></task-notification>"
    private static let modelOnly = "<system-reminder>Only for the model.</system-reminder>"

    private var conversation: [AgentConversationMessage] {
        [
            .init(id: "u1", role: .user, text: "First question"),
            .init(id: "t1", role: .thought, text: "Thinking"),
            .init(id: "tool1", role: .tool, text: "Run command"),
            .init(id: "a1", role: .agent, text: "First answer"),
            // A finished background task joins the next process; it opens no turn.
            .init(id: "n1", role: .user, text: Self.notification),
            .init(id: "tool2", role: .tool, text: "Follow-up command"),
            .init(id: "a2", role: .agent, text: "Follow-up answer"),
            .init(id: "hidden", role: .user, text: Self.modelOnly),
            .init(id: "u2", role: .user, text: "Second question"),
            .init(id: "a3", role: .agent, text: "Second answer"),
            .init(id: "u3", role: .user, text: "Third question"),
            .init(id: "tool3", role: .tool, text: "Third command"),
            .init(id: "a4", role: .agent, text: "Third answer"),
        ]
    }

    private func turns(endingAt ids: [String]) -> [AgentTurnStatistics] {
        let start = ContinuousClock.Instant.now
        return ids.map { id in
            var turn = AgentTurnStatistics(id: "turn-\(id)", startedAt: start)
            turn.finish(at: start.advanced(by: .seconds(1)), endingMessageID: id, usage: nil)
            return turn
        }
    }

    private func expectSame(_ derivation: AgentTranscriptDerivation, _ messages: [AgentConversationMessage],
                            turns: [AgentTurnStatistics]) {
        let expected = AgentTranscriptItem.grouped(messages, turns: turns)
        #expect(derivation.items(messages, turns: turns).map(\.id) == expected.map(\.id))
        let plain = AgentTranscriptNavigationContent(messages: messages)
        let cached = derivation.navigation(messages: messages)
        #expect(cached.entries == plain.entries)
        #expect(cached.turnByMessageID == plain.turnByMessageID)
        for message in messages { #expect(cached.turnID(forMessage: message.id) == plain.turnByMessageID[message.id]) }
    }

    @Test
    func everyPrefixOfAGrowingConversationMatchesRegrouping() {
        let derivation = AgentTranscriptDerivation()
        let all = conversation
        for count in 0...all.count {
            expectSame(derivation, Array(all.prefix(count)), turns: [])
        }
        // The same conversation again is served from the cache and still matches.
        expectSame(derivation, all, turns: turns(endingAt: ["a1", "a3"]))
        expectSame(derivation, all, turns: turns(endingAt: ["a1", "a3", "a4"]))
    }

    @Test
    func streamingTheLastReplyOnlyChangesTheTail() {
        let derivation = AgentTranscriptDerivation()
        var messages = conversation
        expectSame(derivation, messages, turns: [])
        for chunk in ["x", "xy", "xyz and more"] {
            messages[messages.count - 1].text = "Third answer " + chunk
            expectSame(derivation, messages, turns: [])
        }
    }

    @Test
    func changingAnEarlierMessageInvalidatesTheSettledPart() {
        let derivation = AgentTranscriptDerivation()
        var messages = conversation
        expectSame(derivation, messages, turns: [])
        // A tool result arriving late edits a message inside a finished turn.
        messages[2].text = "Run command (failed)"
        expectSame(derivation, messages, turns: [])
        // Removing earlier history (a closed or reloaded session) is also seen.
        messages.removeFirst(4)
        expectSame(derivation, messages, turns: [])
        expectSame(derivation, [], turns: [])
    }

    @Test
    func aConversationWithoutAPlainPromptIsNeverSplit() {
        let derivation = AgentTranscriptDerivation()
        let messages: [AgentConversationMessage] = [
            .init(id: "n", role: .user, text: Self.notification),
            .init(id: "tool", role: .tool, text: "Run"),
            .init(id: "a", role: .agent, text: "Done"),
        ]
        #expect(AgentTranscriptDerivation.splitIndex(messages) == 0)
        expectSame(derivation, messages, turns: [])
    }
}
