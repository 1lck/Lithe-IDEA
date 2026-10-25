import Testing
@testable import Lithe

@Suite("Context size text")
struct AgentContextTokenTextTests {
    @Test(arguments: [
        ("200K", 200_000), ("200k", 200_000), ("1M", 1_000_000), ("1.5m", 1_500_000),
        ("258.4K", 258_400), ("200000", 200_000), ("200,000", 200_000), (" 190K ", 190_000),
    ] as [(String, UInt64)])
    func parsesTheWaysPeopleWriteTokenCounts(text: String, tokens: UInt64) {
        #expect(AgentContextTokenText.parse(text) == .value(tokens))
    }

    @Test(arguments: ["", "   "])
    func emptyTextClearsTheLimit(text: String) {
        #expect(AgentContextTokenText.parse(text) == .cleared)
    }

    @Test(arguments: ["abc", "0", "-5K", "5K", "9999", "11M", "1e9", "K", "1.2.3M", "inf"])
    func rejectsTyposAndSizesNoAgentCouldUse(text: String) {
        #expect(AgentContextTokenText.parse(text) == .invalid)
    }

    @Test(arguments: [200_000, 190_000, 258_400, 1_000_000, 1_500_000, 10_000, 123_456, 1_234_567] as [UInt64])
    func printedTextReadsBackToTheSameNumber(tokens: UInt64) {
        #expect(AgentContextTokenText.parse(AgentContextTokenText.format(tokens)) == .value(tokens))
    }

    @Test
    func printsShortSuffixedFormsWhereExact() {
        #expect(AgentContextTokenText.format(200_000) == "200K")
        #expect(AgentContextTokenText.format(258_400) == "258.4K")
        #expect(AgentContextTokenText.format(1_000_000) == "1M")
        #expect(AgentContextTokenText.format(1_500_000) == "1.5M")
        #expect(AgentContextTokenText.format(123_456) == "123456")
    }
}
