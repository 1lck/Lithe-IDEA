import AppKit
import SwiftUI
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
    @MainActor
    func tableCellsGrowToShowFullHeadersAndBody() {
        let chinese = String(repeating: "两数之和 → 合并两个有序数组 → 三数之和 → 字母异位词分组。", count: 5)
        let unbroken = String(repeating: "veryLongIdentifier", count: 24)
        for width: CGFloat in [360, 720, 1100] {
            for dark in [false, true] {
                func height(header: String, body: String) -> CGFloat {
                    let source = "| 顺序 | \(header) | 目标 |\n| --- | --- | --- |\n| 1 | \(body) | 完整尾部 |"
                    let host = NSHostingView(rootView: AgentMarkdownMessage(text: source)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .lineLimit(1)
                        .frame(width: width))
                    return host.fittingSize.height
                }
                let compact = height(header: "题目顺序", body: "两数之和")
                for content in ["**\(chinese)**", unbroken] {
                    #expect(height(header: "题目顺序", body: content) > compact + 60,
                            "Long body must wrap and grow at width \(width), dark=\(dark)")
                    #expect(height(header: content, body: "两数之和") > compact + 60,
                            "Long header must wrap and grow at width \(width), dark=\(dark)")
                }
            }
        }
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

extension AgentMarkdownTests {
    private func paragraph(_ source: String) throws -> AttributedString {
        let blocks = AgentMarkdownBlock.parse(source)
        guard case .paragraph(let text) = try #require(blocks.first) else {
            Issue.record("expected paragraph: \(blocks)")
            return AttributedString()
        }
        return text
    }

    private func isBold(_ text: AttributedString, _ word: String) throws -> Bool {
        let range = try #require(text.range(of: word))
        return text[range].runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
    }

    @Test
    func boldClosedByCJKPunctuationBeforeCJKTextStillRenders() throws {
        // CommonMark leaves `**` literal when a closing delimiter follows
        // punctuation and precedes a letter, which is common in Chinese replies.
        let text = try paragraph("**状态：**仍开放，**结论。**继续")
        #expect(plain(text) == "状态：仍开放，结论。继续")
        #expect(try isBold(text, "状态："))
        #expect(try isBold(text, "结论。"))
        #expect(try !isBold(text, "仍开放"))

        let code = try paragraph("Use `a**b**c` and **ok**")
        #expect(plain(code) == "Use a**b**c and ok")
        let unpaired = try paragraph("2 ** 3 is power")
        #expect(plain(unpaired) == "2 ** 3 is power")
        let operators = try paragraph("2 ** 3 and 4 ** 5")
        #expect(plain(operators) == "2 ** 3 and 4 ** 5")
        let mixed = try paragraph("2 ** 3 是幂，**注意：**别混淆")
        #expect(plain(mixed) == "2 ** 3 是幂，注意：别混淆")
        #expect(try isBold(mixed, "注意："))
        let escaped = try paragraph(#"Show \*\*literal\*\* markers"#)
        #expect(plain(escaped) == "Show **literal** markers")
        #expect(try !isBold(escaped, "literal"))
    }

    @Test(arguments: ["tests/foo.swift", "src/foo.swift"])
    func strongRepairKeepsIndependentLinkLabelsLiteral(_ destination: String) throws {
        let text = try paragraph("[src/**/foo.swift](src/foo.swift) 和 [tests/**/foo.swift](\(destination))")
        #expect(plain(text) == "src/**/foo.swift 和 tests/**/foo.swift")
        #expect(try !isBold(text, " 和 "))
        let first = try #require(text.range(of: "src/**/foo.swift"))
        let second = try #require(text.range(of: "tests/**/foo.swift"))
        #expect(text[first].link == URL(string: "src/foo.swift"))
        #expect(text[second].link == URL(string: destination))
    }

    @Test
    func strongRepairAroundALinkPreservesItsDestination() throws {
        let text = try paragraph("**参考 [源码](src/foo.swift)：**继续")
        #expect(plain(text) == "参考 源码：继续")
        #expect(try isBold(text, "参考 源码："))
        #expect(try !isBold(text, "继续"))
        let link = try #require(text.range(of: "源码"))
        #expect(text[link].link == URL(string: "src/foo.swift"))
    }

    @Test(arguments: ["&#42;", "&#00042;", "&#x2a;", "&#X002A;", "&ast;", "&midast;"])
    func entityAsterisksRemainLiteral(_ entity: String) throws {
        let text = try paragraph("Show \(entity)\(entity)literal\(entity)\(entity) markers")
        #expect(plain(text) == "Show **literal** markers")
        #expect(try !isBold(text, "literal"))
    }

    @Test
    func linksAreClassifiedByDestination() throws {
        func link(_ string: String) throws -> AgentMarkdownLink { AgentMarkdownLink(try #require(URL(string: string))) }
        #expect(try link("https://github.com/1lck/Lithe-IDEA/issues/1249") == .github)
        #expect(try link("https://gist.github.com/x") == .github)
        #expect(try link("https://example.com/a") == .web)
        #expect(try link("mailto:a@example.com") == .web)
        #expect(try link("macos/Sources/App.swift:42") == .file(.init(path: "macos/Sources/App.swift", line: 42), isDocument: false))
        #expect(try link("README.md:12") == .file(.init(path: "README.md", line: 12), isDocument: true))
        #expect(try link("docs/My%20Notes.md#L7") == .file(.init(path: "docs/My Notes.md", line: 7), isDocument: true))
        #expect(try link("file:///tmp/a.rs:3:9") == .file(.init(path: "/tmp/a.rs", line: 3), isDocument: false))
        #expect(try link("file:///tmp/a%2520b.swift#L7") == .file(.init(path: "/tmp/a%20b.swift", line: 7), isDocument: false))
        #expect(try link("file:///tmp/a%252Fb.swift") == .file(.init(path: "/tmp/a%2Fb.swift", line: nil), isDocument: false))
        #expect(try link("file:///tmp/a%23b.swift#L7") == .file(.init(path: "/tmp/a#b.swift", line: 7), isDocument: false))
        #expect(try link("docs/a%2520b.swift#L7") == .file(.init(path: "docs/a%20b.swift", line: 7), isDocument: false))
        #expect(try link("Makefile") == .file(.init(path: "Makefile", line: nil), isDocument: true))
        #expect(try link("Makefile:12") == .file(.init(path: "Makefile", line: 12), isDocument: true))
        #expect(try link("Dockerfile:3:1") == .file(.init(path: "Dockerfile", line: 3), isDocument: true))
        #expect(try link("tel:10086") == .web)
    }

    @Test
    func exportedTableKeepsLiteralInlineSyntaxWhenParsedAgain() throws {
        let source = #"""
        | `**Name**` | `[link](file.swift)` |
        | --- | --- |
        | `**literal** _word_ ~~strike~~` | `[text](https://example.com) ![image](x)` |
        | `a\b \\| **尾巴：**` | `&copy; &#42; <b>tag</b>` |
        | a&#10;b&#13;c&#13;&#10;d | &#32; padded &#32; |
        | `https://example.com` | `www.example.com` |
        """#
        guard case .table(let header, let rows) = try #require(AgentMarkdownBlock.parse(source).first) else {
            Issue.record("expected original table")
            return
        }
        let exported = AgentMarkdownTableExport.markdown(header: header, rows: rows)
        guard case .table(let copiedHeader, let copiedRows) = try #require(AgentMarkdownBlock.parse(exported).first) else {
            Issue.record("expected exported table: \(exported)")
            return
        }
        #expect(copiedHeader.map(plain) == header.map(plain))
        #expect(copiedRows.map { $0.map(plain) } == rows.map { $0.map(plain) })
        for cell in copiedHeader + copiedRows.flatMap({ $0 }) {
            #expect(cell.runs.allSatisfy { ($0.inlinePresentationIntent ?? []).isEmpty && $0.link == nil },
                    "Unexpected inline formatting: \(cell)")
        }
    }

    @Test
    func tableExportsAsMarkdownAndHTML() throws {
        let blocks = AgentMarkdownBlock.parse("""
        | Name | Note |
        | --- | --- |
        | a\\|b | <x> & y |
        | short |
        """)
        guard case .table(let header, let rows) = try #require(blocks.first) else {
            Issue.record("expected table: \(blocks)")
            return
        }
        #expect(AgentMarkdownTableExport.markdown(header: header, rows: rows) == #"""
        | Name | Note |
        | --- | --- |
        | a\|b | \<x\> \& y |
        | short |  |
        """#)
        #expect(AgentMarkdownTableExport.html(header: header, rows: rows)
                == "<table><thead><tr><th>Name</th><th>Note</th></tr></thead><tbody>"
                + "<tr><td>a|b</td><td>&lt;x&gt; &amp; y</td></tr><tr><td>short</td><td></td></tr></tbody></table>")
    }
}
