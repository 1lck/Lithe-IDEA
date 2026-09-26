import Foundation
import Testing
@testable import LitheAgentConversationModule

struct AgentFileReferenceTests {
    @Test
    func repeatedDropsDeduplicateStandardizedURLsAndPreserveOrder() throws {
        let first = URL(fileURLWithPath: "/example/project/中文 File.swift")
        let second = URL(fileURLWithPath: "/example/project/image.png")
        let files = try AgentFileReference.adding([first, second], to: [])
        let repeated = try AgentFileReference.adding([
            URL(fileURLWithPath: "/example/project/sub/../中文 File.swift"), first
        ], to: files)
        #expect(repeated == files)
        #expect(files.map(\.name) == ["中文 File.swift", "image.png"])
        #expect(URL(string: files[0].id)?.path == first.path)
        let removed = repeated.filter { $0.id != files[0].id }
        #expect(try AgentFileReference.adding([first], to: removed).map(\.name) == ["image.png", "中文 File.swift"])
    }

    @Test
    func invalidOrOversizedBatchKeepsExistingDraftIntact() throws {
        let urls = (0..<AgentFileReference.maximumCount).map { URL(fileURLWithPath: "/example/project/file\($0).txt") }
        let existing = try AgentFileReference.adding(urls, to: [])
        #expect(throws: AgentFileReferenceError.self) {
            try AgentFileReference.adding([URL(fileURLWithPath: "/example/project/extra.txt")], to: existing)
        }
        #expect(try AgentFileReference.adding(urls, to: existing) == existing)
        #expect(throws: AgentFileReferenceError.self) {
            try AgentFileReference.adding([URL(string: "https://example.com/file.txt")!], to: existing)
        }
        #expect(existing.count == AgentFileReference.maximumCount)
    }
}
