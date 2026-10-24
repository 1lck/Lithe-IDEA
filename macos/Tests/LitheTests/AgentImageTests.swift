import Foundation
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@Suite("Agent images and task notifications")
struct AgentImageTests {
    private static let pixel = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

    private func imageBlock(_ data: Data = pixel, mime: String = "image/png") -> [String: Any] {
        ["type": "content", "content": ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]]
    }

    @Test
    func toolResultImageBecomesAThumbnailSourceInsteadOfAPlaceholderRow() {
        var details = AgentToolDetails()
        details.merge(["kind": "read", "locations": [["path": "/tmp/box-light.png"]],
                       "content": [imageBlock()]])
        #expect(details.images.count == 1)
        #expect(details.images[0].title == "box-light.png")
        #expect(details.content.isEmpty, "An image must not also surface as an 'image' text row")
        #expect(!details.isEmpty)
    }

    @Test
    func laterUpdateWithoutPicturesKeepsEarlierOnes() {
        var details = AgentToolDetails()
        details.merge(["content": [imageBlock()]])
        details.merge(["content": [["type": "content", "content": ["type": "text", "text": "done"]]]])
        #expect(details.images.count == 1)
    }

    @Test
    func readingAnImageFileWithoutInlineDataShowsTheFile() {
        var details = AgentToolDetails()
        details.merge(["kind": "read", "locations": [["path": "/tmp/shot.PNG"], ["path": "/tmp/notes.txt"]]])
        #expect(details.images.map(\.title) == ["shot.PNG"])
        var edit = AgentToolDetails()
        edit.merge(["kind": "edit", "locations": [["path": "/tmp/shot.png"]]])
        #expect(edit.images.isEmpty, "Only a read implies viewing the file")
    }

    @Test
    func invalidOrOversizedImageBlocksAreRejected() {
        #expect(AgentImage.parse(block: ["type": "image", "data": "!!!", "mimeType": "image/png"]) == nil)
        #expect(AgentImage.parse(block: ["type": "image", "data": Self.pixel.base64EncodedString(), "mimeType": "text/plain"]) == nil)
        let huge = String(repeating: "A", count: AgentImage.maximumBytes / 3 * 4 + 4)
        #expect(AgentImage.parse(block: ["type": "image", "data": huge, "mimeType": "image/png"]) == nil)
    }

    @Test
    func identicalBytesShareAnIdentity() {
        #expect(AgentImage(data: Self.pixel).id == AgentImage(data: Self.pixel).id)
        #expect(AgentImage(data: Self.pixel).id != AgentImage(data: Data([1, 2, 3])).id)
    }

    @Test
    func composerAttachmentLinesBecomeImagesAndOtherLinesStayText() {
        let content = AgentUserMessageContent.parse("看看这个\n\n📎 /tmp/Pasted image.png\n\n📎 /tmp/report.pdf")
        #expect(content.images.map(\.title) == ["Pasted image.png"])
        #expect(content.text == "看看这个\n\n📎 /tmp/report.pdf")
        let plain = AgentUserMessageContent.parse("no attachments")
        #expect(plain == AgentUserMessageContent(text: "no attachments", images: []))
    }

    @Test
    func replayedFileLinksBecomeThumbnailsInsteadOfRawAddresses() {
        let content = AgentUserMessageContent.parse(
            "看这个 [@shot one.png](file:///tmp/shot%20one.png)\n\nfile:///tmp/two.jpg\n\n[@notes.txt](file:///tmp/notes.txt)")
        #expect(content.images.map(\.title) == ["shot one.png", "two.jpg"])
        #expect(content.text == "看这个\n\n[@notes.txt](file:///tmp/notes.txt)")
        #expect(AgentUserMessageContent.parse("see file:///tmp/a.txt").images.isEmpty)
    }

    @Test
    func taskNotificationIsParsedFromTheWholeMessageOnly() throws {
        let markup = """
        <task-notification>
        <task-id>abc</task-id>
        <status>completed</status>
        <summary>Agent "Explore" finished</summary>
        <output-file>/tmp/abc.output</output-file>
        </task-notification>
        """
        let parsed = try #require(AgentTaskNotification.parse(markup + "\n" + markup))
        #expect(parsed.count == 2)
        #expect(parsed[0].summary == "Agent \"Explore\" finished")
        #expect(parsed[0].status == "completed")
        #expect(AgentTaskNotification.parse("Please explain <task-notification> tags") == nil)
        #expect(AgentTaskNotification.parse(markup + " and some typed words") == nil)
    }

    @Test
    func blankAgentRepliesAreDroppedAndKeepToolRunsTogether() {
        let messages = [
            AgentConversationMessage(id: "u", role: .user, text: "go"),
            AgentConversationMessage(id: "t1", role: .tool, text: "Read", toolStatus: .completed),
            AgentConversationMessage(id: "blank", role: .agent, text: "\n  "),
            AgentConversationMessage(id: "t2", role: .tool, text: "Read", toolStatus: .completed),
        ]
        let items = AgentTranscriptItem.grouped(messages)
        #expect(items.count == 2)
        if case .processGroup(let process) = items[1] {
            #expect(AgentTranscriptItem.processContents(process).count == 1)
        } else {
            Issue.record("Expected one process group after the user message")
        }
    }

    @Test
    func claudeCodeCommandOutputShellAndInterruptMarkupGetOwnEntries() throws {
        let command = try #require(AgentClaudeCodeMarkup.parse("""
        <command-name>/clear</command-name>
                    <command-message>clear</command-message>
                    <command-args>now</command-args>
        """))
        #expect(command == [.command(name: "/clear", arguments: "now")])
        #expect(AgentClaudeCodeMarkup.parse("<local-command-stdout>done</local-command-stdout>") == [.output("done", isError: false)])
        #expect(AgentClaudeCodeMarkup.parse("<bash-input>ls</bash-input><bash-stdout>a</bash-stdout><bash-stderr>boom</bash-stderr>")
            == [.shell("ls"), .output("a", isError: false), .output("boom", isError: true)])
        #expect(AgentClaudeCodeMarkup.parse("[Request interrupted by user for tool use]") == [.interrupted("Request interrupted by user for tool use")])
    }

    @Test
    func modelOnlyMarkupIsHiddenAndTypedTextIsNeverTreatedAsMarkup() {
        #expect(AgentClaudeCodeMarkup.parse("<local-command-caveat>Caveat: ignore</local-command-caveat>") == [])
        #expect(AgentClaudeCodeMarkup.parse("<system-reminder>x</system-reminder>\n<local-command-stdout></local-command-stdout>") == [])
        #expect(AgentClaudeCodeMarkup.parse("what does <command-name> mean?") == nil)
        #expect(AgentClaudeCodeMarkup.parse("<unknown>x</unknown>") == nil)
        #expect(AgentClaudeCodeMarkup.parse("<bash-input>ls</bash-input> trailing words") == nil)
        let hidden = [AgentConversationMessage(id: "u", role: .user, text: "<local-command-caveat>x</local-command-caveat>")]
        #expect(AgentTranscriptItem.grouped(hidden).isEmpty)
    }

    @Test
    func compactionSummarySkillAndHostContextAreCollapsedEntries() throws {
        let recap = """
        This session is being continued from a previous conversation that ran out of context.
        <tools-used-before-summary>Bash, Edit, Read</tools-used-before-summary>
        Summary:
        1. Primary Request
        """
        let summary = try #require(AgentClaudeCodeMarkup.parse(recap))
        #expect(summary == [.summary("This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n1. Primary Request", tools: "Bash, Edit, Read")])
        let skill = try #require(AgentClaudeCodeMarkup.parse("Base directory for this skill: /Users/x/.claude/skills/deploy\n\n# Deploy"))
        #expect(skill == [.skill(name: "deploy", body: "Base directory for this skill: /Users/x/.claude/skills/deploy\n\n# Deploy")])
        let context = try #require(AgentClaudeCodeMarkup.parse("<lithe_workspace_context>cwd</lithe_workspace_context>"))
        #expect(context == [.context(name: "lithe_workspace_context", body: "cwd")])
    }

    @Test
    func remindersAppendedToTypedTextAreRemovedWithoutTouchingTheText() {
        let message = "继续\n<system-reminder>be brief</system-reminder>"
        #expect(AgentClaudeCodeMarkup.removingModelOnlyBlocks(message) == "继续")
        #expect(AgentClaudeCodeMarkup.parse(message) == nil, "Typed text stays an ordinary message")
        #expect(AgentClaudeCodeMarkup.removingModelOnlyBlocks("plain") == "plain")
    }

    @Test
    func claudeCodeImagePlaceholdersBecomeThumbnailsAndDropTheSizeNote() {
        let content = AgentUserMessageContent.parse("""
        [Image: source: /private/tmp/claude/images/1.png]
        [Image: original 3840x2486, displayed at 2000x1295. Multiply coordinates by 1.92 to map to original image.]
        看一下这个
        """)
        #expect(content.images.map(\.title) == ["1.png"])
        #expect(content.text == "看一下这个")
        #expect(AgentUserMessageContent.parse("[Image #1] 看这个").images.isEmpty)
    }

    @Test
    func claudeCodeMarkupMessagesDoNotBecomeNavigationPrompts() {
        let messages = [
            AgentConversationMessage(id: "caveat", role: .user, text: "<local-command-caveat>x</local-command-caveat>"),
            AgentConversationMessage(id: "real", role: .user, text: "hello"),
            AgentConversationMessage(id: "note", role: .user, text: "<task-notification><status>completed</status></task-notification>"),
            AgentConversationMessage(id: "reply", role: .agent, text: "hi"),
        ]
        let content = AgentTranscriptNavigationContent(messages: messages)
        #expect(content.entries.map(\.id) == ["real"])
        #expect(content.turnByMessageID["reply"] == "real")
    }
}
