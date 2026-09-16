import Foundation
import LitheCoreContracts
import Testing

@Suite("Language server semantic token contract")
struct LanguageServerSemanticTokensTests {
    @Test
    func sharedFixturePreservesUTF16PositionsAndLegend() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/lsp/semantic-tokens-v1.json"))
        struct Fixture: Decodable { let expectedResult: LanguageServerSemanticTokens }
        let tokens = try JSONDecoder().decode(Fixture.self, from: data).expectedResult
        #expect(tokens.tokenTypes == ["class", "method"])
        #expect(tokens.tokens.count == 3)
        #expect(tokens.tokens[2].line == 2)
        #expect(tokens.tokens[2].startChar == 11)
        #expect(tokens.tokens[0].tokenModifiers == 1)
        #expect(try JSONDecoder().decode(LanguageServerSemanticTokens.self,
            from: JSONEncoder().encode(tokens)) == tokens)
    }
}
