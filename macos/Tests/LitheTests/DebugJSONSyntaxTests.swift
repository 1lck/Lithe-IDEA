import Foundation
import Testing
@testable import Lithe

@Suite("Debug JSON syntax")
struct DebugJSONSyntaxTests {
    private func kinds(_ line: String) -> [DebugJSONSyntax.Kind] {
        DebugJSONSyntax.tokens(line).filter { $0.kind != .plain }.map(\.kind)
    }

    @Test
    func keysAndStringValuesGetDifferentKinds() {
        #expect(kinds("    \"esr\" : \"0xf2000000\",") == [.key, .punctuation, .string, .punctuation])
    }

    @Test
    func scalarValuesAreClassified() {
        #expect(kinds("\"a\" : 12,") == [.key, .punctuation, .number, .punctuation])
        #expect(kinds("\"b\" : -1.5e3") == [.key, .punctuation, .number])
        #expect(kinds("\"c\" : true") == [.key, .punctuation, .boolean])
        #expect(kinds("\"d\" : null") == [.key, .punctuation, .null])
    }

    @Test
    func foldedLineKeepsTheKeyAndTheClosingPunctuation() {
        // key, then `:` `[` `…` `]` `,`
        #expect(kinds("\"orders\" : [ … ],") == [.key] + Array(repeating: .punctuation, count: 5))
    }

    @Test
    func escapedQuotesAndColonsInsideStringsStayOneString() {
        let tokens = DebugJSONSyntax.tokens("\"v\" : \"a \\\" : b\"")
        #expect(tokens.map(\.kind) == [.key, .plain, .punctuation, .plain, .string])
        #expect(tokens.last?.text == "\"a \\\" : b\"")
    }

    @Test
    func tokensRebuildTheOriginalLineExactly() {
        for line in ["{", "  \"k\" : [", "    1,", "\"x\" : \"unterminated", "plain text, not json", ""] {
            #expect(DebugJSONSyntax.tokens(line).map(\.text).joined() == line)
        }
    }
}
