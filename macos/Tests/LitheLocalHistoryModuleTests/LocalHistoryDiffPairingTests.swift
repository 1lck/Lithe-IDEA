import Testing
@testable import LitheLocalHistoryModule

struct LocalHistoryDiffPairingTests {
    @Test
    func diffPairingMatchesRustSimilarityRules() {
        // Single-line replacements always read as a modification.
        #expect(LocalHistoryDiffPairing.pairs(removed: ["before"], added: ["after"]).count == 1)

        // Nothing clears the floor, so no pair keeps both sides.
        let unrelated = LocalHistoryDiffPairing.pairs(
            removed: ["import Foundation", "import AppKit"],
            added: ["let x = 1", "let y = 2", "let z = 3"]
        )
        #expect(unrelated.count == 5)
        #expect(unrelated.allSatisfy { $0.0 == nil || $0.1 == nil })

        // Reindentation alone is a perfect match; empty against text is none.
        #expect(LocalHistoryDiffPairing.similarity("    return value", "\t\treturn value") == 1)
        #expect(LocalHistoryDiffPairing.similarity("abc", "") == 0)
    }
}
