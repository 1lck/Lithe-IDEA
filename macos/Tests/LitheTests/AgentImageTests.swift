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
        #expect(content.text == "看看这个\n\n\n📎 /tmp/report.pdf")
        let plain = AgentUserMessageContent.parse("no attachments")
        #expect(plain == AgentUserMessageContent(text: "no attachments", images: []))
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
}
