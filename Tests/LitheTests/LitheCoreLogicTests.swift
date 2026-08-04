import Foundation
import Testing
@testable import Lithe

@Suite("Lithe core logic")
struct LitheCoreLogicTests {
    @Test
    func textFilePolicyRecognizesMarkdownAndExtensionlessFiles() {
        #expect(WorkspaceTextFilePolicy.isReadableTextFile(URL(fileURLWithPath: "/tmp/README.MD")))
        #expect(WorkspaceTextFilePolicy.isReadableTextFile(URL(fileURLWithPath: "/tmp/Makefile")))
        #expect(!WorkspaceTextFilePolicy.isReadableTextFile(URL(fileURLWithPath: "/tmp/archive.png")))
    }

    @Test
    func fileVisibilityRulesHideBuiltInAndCustomPatterns() {
        let root = URL(fileURLWithPath: "/tmp/lithe-visibility-tests")
        let rules = FileVisibilityRules(hiddenDirectoryNames: ["generated"], hiddenFilePatterns: ["*.generated.swift"])

        #expect(
            rules.isHidden(
                root.appendingPathComponent(".git/config"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent("Sources/generated"),
                relativeTo: root,
                isDirectory: true
            )
        )
        #expect(
            rules.isHidden(
                root.appendingPathComponent("Sources/Model.generated.swift"),
                relativeTo: root,
                isDirectory: false
            )
        )
        #expect(
            !rules.isHidden(
                root.appendingPathComponent("Sources/Model.swift"),
                relativeTo: root,
                isDirectory: false
            )
        )
    }

    @Test
    func diffParserPairsChangedRowsAndTracksHunk() {
        let patch = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,2 +1,2 @@
         title
        -old text
        +new text
        """

        let document = DiffParser.parseDocument(patch)
        #expect(document.hunks.count == 1)
        #expect(document.hunks[0].id == "hunk-0")
        #expect(document.rows.contains { row in
            row.kind == .changed && row.left == "old text" && row.right == "new text"
        })
    }

    @Test
    func localHistoryDiffBuilderProducesChangedRow() {
        let rows = LocalHistoryDiffBuilder.rows(old: "before\n", current: "after\n")

        #expect(rows.count == 1)
        #expect(rows[0].kind == .changed)
        #expect(rows[0].left == "before")
        #expect(rows[0].right == "after")
    }

    @Test
    func markdownParserBuildsPreviewBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        # Title

        A **paragraph** with a [link](https://example.com).

        - One
        - Two

        ```swift
        print("hello")
        ```
        """)

        #expect(blocks.count == 4)
        guard case let .heading(level, text) = blocks[0] else {
            Issue.record("Expected a heading block")
            return
        }
        #expect(level == 1)
        #expect(text == "Title")

        guard case let .paragraph(text) = blocks[1] else {
            Issue.record("Expected a paragraph block")
            return
        }
        #expect(text.contains("**paragraph**"))

        guard case let .unorderedList(items) = blocks[2] else {
            Issue.record("Expected an unordered list block")
            return
        }
        #expect(items == ["One", "Two"])

        guard case let .code(language, text) = blocks[3] else {
            Issue.record("Expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(text == "print(\"hello\")")
    }
}

@Suite("Editor documents")
@MainActor
struct EditorDocumentTests {
    @Test
    func documentTracksDirtyStateAndSaves() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-editor-document-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let document = EditorDocument(url: url, text: "before", modificationDate: nil)
        #expect(!document.isDirty)

        document.text = "after"
        #expect(document.isDirty)
        try document.save()

        #expect(!document.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after")
    }

    @Test
    func readOnlyDocumentRejectsSave() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-read-only-\(UUID().uuidString).txt")
        let document = EditorDocument(
            url: url,
            text: "content",
            modificationDate: nil,
            isReadOnly: true
        )

        #expect(throws: EditorDocument.DocumentError.self) {
            try document.save()
        }
    }
}
