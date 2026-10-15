import Foundation
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@Suite("Agent Markdown")
struct AgentMarkdownTests {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    @Test
    func blockSyntaxBecomesStructuredBlocks() throws {
        let source = """
        # Title
        Some **bold** text
        continues here.

        - first
        - [x] done
          - nested
        1. one
        2) two

        > quoted

        ---
        | Name | Size |
        | :--- | ---: |
        | a | 1 |
        """
        let blocks = AgentMarkdownBlock.parse(source)
        #expect(blocks.count == 6)
        guard case .heading(1, let title) = blocks[0] else { Issue.record("heading: \(blocks[0])"); return }
        #expect(plain(title) == "Title")
        guard case .paragraph(let paragraph) = blocks[1] else { Issue.record("paragraph: \(blocks[1])"); return }
        #expect(plain(paragraph) == "Some bold text\ncontinues here.")
        guard case .list(let items) = blocks[2] else { Issue.record("list: \(blocks[2])"); return }
        #expect(items.map(\.marker) == ["•", "☑", "•", "1.", "2."])
        #expect(items.map(\.depth) == [0, 0, 1, 0, 0])
        #expect(plain(items[2].text) == "nested")
        guard case .quote(let quote) = blocks[3] else { Issue.record("quote: \(blocks[3])"); return }
        #expect(plain(quote) == "quoted")
        #expect(blocks[4] == .rule)
        guard case .table(let header, let rows) = blocks[5] else { Issue.record("table: \(blocks[5])"); return }
        #expect(header.map(plain) == ["Name", "Size"])
        #expect(rows.map { $0.map(plain) } == [["a", "1"]])
    }

    @Test
    func fencesKeepContentVerbatimAndUnclosedFenceIsCode() {
        let blocks = AgentMarkdownBlock.parse("Intro\n```swift\n# not a heading\n- not a list\n```\nAfter\n```\nstreaming")
        #expect(blocks.count == 4)
        #expect(blocks[1] == .code(language: "swift", code: "# not a heading\n- not a list"))
        #expect(blocks[3] == .code(language: "", code: "streaming"))
    }

    @Test
    func pipeLinesWithoutSeparatorStayParagraphs() {
        let blocks = AgentMarkdownBlock.parse("| a | b |\nnext")
        #expect(blocks.count == 2)
        guard case .paragraph = blocks[0] else { Issue.record("expected paragraph: \(blocks[0])"); return }
    }

    @Test
    @MainActor
    func inlineRunsUseExplicitFontsSoCJKKeepsItsFallback() throws {
        let source = try AttributedString(markdown: "普通 **加粗中文** *斜体* `代码`",
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let styled = AgentMarkdownInline.styled(source, size: 13)
        #expect(String(styled.characters) == String(source.characters))
        for run in styled.runs {
            #expect(run.inlinePresentationIntent == nil, "SwiftUI must not synthesize traits on the bundled font")
            #expect(run.swiftUI.font != nil)
        }
        let bold = try #require(styled.range(of: "加粗中文"))
        #expect(styled[bold].runs.first?.swiftUI.font == LitheTheme.uiFont(size: 13, weight: .semibold))
    }

    @Test
    func conversationExportKeepsPromptsRepliesAndToolsButNotReasoning() {
        let messages: [AgentConversationMessage] = [
            .init(role: .user, text: "Fix it"),
            .init(role: .thought, text: "private reasoning"),
            .init(role: .tool, text: "Read\nfile.swift"),
            .init(role: .agent, text: "Done.\n\n- changed"),
            .init(role: .agent, text: "  ")
        ]
        let markdown = AgentTranscriptExport.markdown(title: "Chat", messages: messages, locale: Locale(identifier: "en"))
        #expect(markdown == "# Chat\n\n**You:**\n\nFix it\n\n> Read file.swift\n\n**Agent:**\n\nDone.\n\n- changed")
    }
}

@Suite("Agent tool group presentation")
struct AgentToolGroupPresentationTests {
    private func tool(_ kind: String?) -> AgentConversationMessage {
        var message = AgentConversationMessage(role: .tool, text: "tool", toolStatus: .completed)
        message.toolDetails.kind = kind
        return message
    }

    @Test
    func summaryCountsByKindInAFixedOrder() {
        let english = Locale(identifier: "en")
        #expect(AgentToolGroupPresentation.summary([tool("execute"), tool("execute")], locale: english) == "Ran 2 commands")
        #expect(AgentToolGroupPresentation.summary([tool("read"), tool("execute"), tool("move"), tool(nil)], locale: english)
                == "Ran 1 command, Read 1 file, Edited 1 file, Used 1 tool")
        #expect(AgentToolGroupPresentation.summary([], locale: english) == "")
    }
}

@Suite("Agent tool evidence presentation")
struct AgentToolEvidencePresentationTests {
    @Test
    func shellCommandsAndResultsReadAsCommandAndOutput() {
        var details = AgentToolDetails()
        details.input = #"{"command": ["/bin/zsh", "-lc", "git log --oneline"], "cwd": "/repo"}"#
        details.output = #"{"exit_code": 0, "formatted_output": "a1 first\n", "stderr": ""}"#
        details.content = [.init(title: "Terminal", text: "exec-1"), .init(title: "Output", text: "a1 first")]
        let sections = AgentToolEvidencePresentation.sections(details)
        #expect(sections == [
            .init(title: "Command", detail: "/repo", text: "git log --oneline", style: .command),
            .init(title: "Output", exitCode: 0, text: "a1 first")
        ])
    }

    @Test
    func unknownShapesKeepTheirRawText() {
        var details = AgentToolDetails()
        details.input = #"{"path": "a.swift"}"#
        details.output = "plain result"
        let sections = AgentToolEvidencePresentation.sections(details)
        #expect(sections.map(\.title) == ["Input", "Result"])
        #expect(sections.last?.text == "plain result")
    }
}
