import Foundation
import Testing
@testable import Lithe

@Suite("Language navigation preview")
struct LanguageNavigationPreviewTests {
    @Test
    func extractsTrimmedUTF16SafeSourceLines() {
        let source = "type AgentEvent struct {\n    Message string // 消息😀\n}\n"

        #expect(
            LanguageNavigationPreview.line(in: source, at: 1)
                == "Message string // 消息😀"
        )
    }

    @Test
    func buildsPreviewsOncePerFileAndKeysThemByLocation() {
        let url = URL(fileURLWithPath: "/workspace/agent.go")
        let first = LanguageNavigationLocation(url: url, line: 0, utf16Column: 5)
        let second = LanguageNavigationLocation(url: url, line: 1, utf16Column: 2)
        var readCount = 0

        let previews = LanguageNavigationPreview.build(
            locations: [first, second],
            openSources: [:],
            readSource: { _ in
                readCount += 1
                return "type AgentEvent struct {\nlisteners map[int]func(AgentEvent)\n"
            }
        )

        #expect(readCount == 1)
        #expect(previews[first.id] == "type AgentEvent struct {")
        #expect(previews[second.id] == "listeners map[int]func(AgentEvent)")
    }
}
