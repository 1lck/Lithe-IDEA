import Foundation
import Testing
@testable import Lithe

@Suite("Lithe core logic")
struct LitheCoreLogicTests {
    @Test
    func updateDownloadProgressReportsKnownAndUnknownTotals() {
        let progress = UpdateDownloadProgress(downloadedBytes: 512, totalBytes: 2_048)

        #expect(progress.fractionCompleted == 0.25)
        #expect(progress.percentage == 25)
        #expect(UpdateDownloadProgress.initial.fractionCompleted == nil)
        #expect(UpdateDownloadProgress.initial.percentage == nil)
    }

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
            row.kind == .changed && row.left == "old text" && row.rightText == "new text"
        })
    }

    @Test
    func diffParserStoresSharedContextTextOnceAndKeepsRowIdentityStable() {
        let patch = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,3 +1,3 @@
         title
        -old text
        +new text
         footer
        """

        let first = DiffParser.parseDocument(patch)
        let context = first.rows.filter { $0.kind == .context }
        #expect(context.count == 2)

        // Context rows carry identical text on both sides, so only `left` is
        // stored and `rightText` falls back to it.
        for row in context {
            #expect(row.storedRight == nil)
            #expect(row.rightText == row.left)
        }

        // Hunks no longer duplicate rows; grouping happens via hunkID.
        #expect(first.rows.allSatisfy { $0.hunkID == "hunk-0" })

        // Row identity is derived, not random, so re-parsing keeps scroll and
        // selection state anchored across a refresh.
        let second = DiffParser.parseDocument(patch)
        #expect(first.rows.map(\.id) == second.rows.map(\.id))
        #expect(Set(first.rows.map(\.id)).count == first.rows.count)
    }

    @Test
    func diffContentWidthGrowsPastViewportSoLongLinesStayReachable() {
        let longLine = String(repeating: "x", count: 400)
        let rows = [
            DiffRow(oldLine: 1, newLine: 1, left: "short", right: nil, kind: .context, sequence: 0),
            DiffRow(
                oldLine: nil,
                newLine: 2,
                left: nil,
                right: longLine,
                kind: .addition,
                sequence: 1
            )
        ]

        // A wide window used to clamp content width to the viewport, which left
        // the tail of a long line truncated and unreachable.
        let viewport: CGFloat = 1_600
        let width = DiffLayoutMetrics.contentWidth(
            rows: rows,
            viewportWidth: viewport,
            minimumWidth: 980,
            paneCount: 2
        )
        #expect(width > viewport)

        let expectedText = CGFloat(400) * DiffLayoutMetrics.characterWidth
        let expected = (DiffLayoutMetrics.paneChromeWidth + expectedText) * 2
            + DiffLayoutMetrics.centerGutterWidth
        #expect(abs(width - expected) < 0.5)

        // Short content still fills the viewport rather than collapsing.
        let shortRows = [
            DiffRow(oldLine: 1, newLine: 1, left: "hi", right: nil, kind: .context, sequence: 0)
        ]
        #expect(
            DiffLayoutMetrics.contentWidth(
                rows: shortRows,
                viewportWidth: viewport,
                minimumWidth: 980,
                paneCount: 2
            ) == viewport
        )
    }

    @Test
    func diffContentWidthCountsTabsAsFourColumns() {
        let rows = [
            DiffRow(oldLine: 1, newLine: 1, left: "\t\tend", right: nil, kind: .context, sequence: 0)
        ]

        // Two tabs plus three characters render as 11 columns, not 5.
        #expect(DiffLayoutMetrics.longestLineLength(rows: rows) == 11)
    }

    @Test
    func diffCollapseFoldsLongUnchangedRunsAndKeepsSurroundingContext() {
        var rows: [DiffRow] = []
        for line in 1...40 {
            rows.append(
                DiffRow(
                    oldLine: line,
                    newLine: line,
                    left: "line \(line)",
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                )
            )
        }
        rows.append(
            DiffRow(oldLine: 41, newLine: 41, left: "old", right: "new", kind: .changed, sequence: 40)
        )

        let plan = DiffCollapse.plan(rows: rows)
        let bands = plan.compactMap { row -> DiffCollapsedRegion? in
            guard case let .collapsed(region) = row else { return nil }
            return region
        }

        #expect(bands.count == 1)
        // Leading run starts the file, so only trailing context is retained.
        #expect(bands[0].startIndex == 0)
        #expect(bands[0].endIndex == 37)
        #expect(bands[0].hiddenRowCount == 37)

        // Three context rows plus the change survive alongside the band.
        #expect(plan.count == 5)
        guard case let .row(lastRow, lastIndex) = plan[4] else {
            Issue.record("Expected the changed row to stay visible")
            return
        }
        #expect(lastRow.kind == .changed)
        // The carried index still points at the row's slot in the source list.
        #expect(lastIndex == rows.count - 1)

        // Expanding the band restores every row.
        let expanded = DiffCollapse.plan(rows: rows, expandedRegionIDs: [bands[0].id])
        #expect(expanded.count == rows.count)
        #expect(!expanded.contains { if case .collapsed = $0 { return true } else { return false } })
    }

    @Test
    func diffCollapseKeepsPinnedRowsRenderedSoNavigationCanReachThem() {
        var rows: [DiffRow] = []
        for line in 1...40 {
            rows.append(
                DiffRow(
                    oldLine: line,
                    newLine: line,
                    left: "line \(line)",
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                )
            )
        }

        // Row 20 sits well inside the fold; a search hit there must not be hidden.
        let target = rows[19]
        let plan = DiffCollapse.plan(rows: rows, pinnedRowIDs: [target.id])

        #expect(!plan.contains { if case .collapsed = $0 { return true } else { return false } })
        #expect(plan.count == rows.count)
    }

    @Test
    func diffCollapseLeavesShortRunsAndHunkHeadersAlone() {
        var rows = [
            DiffRow(oldLine: nil, newLine: nil, left: "@@ -1,4 +1,4 @@", right: nil, kind: .information, sequence: 0)
        ]
        for line in 1...6 {
            rows.append(
                DiffRow(
                    oldLine: line,
                    newLine: line,
                    left: "line \(line)",
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                )
            )
        }

        // Six unchanged lines fall under the threshold, so nothing folds and the
        // `@@` header is never swallowed.
        let plan = DiffCollapse.plan(rows: rows)
        #expect(plan.count == rows.count)
        #expect(!plan.contains { if case .collapsed = $0 { return true } else { return false } })
    }

    @Test
    func localHistoryDiffBuilderProducesChangedRow() {
        let rows = LocalHistoryDiffBuilder.rows(old: "before\n", current: "after\n")

        #expect(rows.count == 1)
        #expect(rows[0].kind == .changed)
        #expect(rows[0].left == "before")
        #expect(rows[0].rightText == "after")
    }

    @Test
    func localHistoryDiffPairsSimilarLinesAndSeparatesUnrelatedOnes() {
        // The added comment used to be paired positionally with the statement,
        // labelling two unrelated lines as one modification.
        let rows = LocalHistoryDiffBuilder.rows(
            old: "let total = compute(a, b)\n",
            current: "// recompute\nlet total = compute(a, b, c)\n"
        )

        #expect(rows.map(\.kind) == [.addition, .changed])
        #expect(rows[1].left == "let total = compute(a, b)")
        #expect(rows[1].rightText == "let total = compute(a, b, c)")
    }

    @Test
    func diffPairingMatchesRustSimilarityRules() {
        // Single-line replacements always read as a modification.
        #expect(DiffPairing.pairs(removed: ["before"], added: ["after"]).count == 1)

        // Nothing clears the floor, so no pair keeps both sides.
        let unrelated = DiffPairing.pairs(
            removed: ["import Foundation", "import AppKit"],
            added: ["let x = 1", "let y = 2", "let z = 3"]
        )
        #expect(unrelated.count == 5)
        #expect(unrelated.allSatisfy { $0.0 == nil || $0.1 == nil })

        // Reindentation alone is a perfect match; empty against text is none.
        #expect(DiffPairing.similarity("    return value", "\t\treturn value") == 1)
        #expect(DiffPairing.similarity("abc", "") == 0)
    }

    @Test
    @MainActor
    func diffMapGroupsAdjacentChangesAndKeepsSingleLinesVisible() {
        var rows: [DiffRow] = []
        func append(_ kind: DiffRowKind, count: Int) {
            for _ in 0..<count {
                rows.append(
                    DiffRow(
                        oldLine: rows.count + 1,
                        newLine: rows.count + 1,
                        left: "l",
                        right: "r",
                        kind: kind,
                        sequence: rows.count
                    )
                )
            }
        }

        append(.context, count: 40)
        append(.addition, count: 3)
        append(.context, count: 50)
        append(.removal, count: 1)
        append(.context, count: 6)

        let markers = DiffMapView(rows: rows) { _ in }.markers

        // A three-line run is one band, not three ticks.
        #expect(markers.count == 2)
        #expect(markers.map(\.kind) == [.addition, .removal])
        #expect(abs(markers[0].start - 40.0 / 100.0) < 0.001)
        #expect(abs(markers[0].extent - 3.0 / 100.0) < 0.001)

        // A single removal is floored so it stays clickable rather than
        // collapsing to a sub-pixel sliver.
        #expect(markers[1].extent >= DiffMapView.minimumExtent)
        #expect(markers[1].id == rows[93].id)
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

    @Test
    func gitCommitFileTreePreservesHierarchyAndCompactsSingleChildPaths() {
        let tree = GitCommitFileTreeNode.build(
            from: [
                GitCommitFile(status: "M", path: "README.md"),
                GitCommitFile(status: "M", path: "docs/README.md"),
                GitCommitFile(status: "M", path: "docs/architecture/repository-layout.md"),
                GitCommitFile(status: "A", path: "src/main/java/example/App.java"),
                GitCommitFile(status: "A", path: "service/Service.java"),
                GitCommitFile(status: "A", path: "service/impl/ServiceImpl.java")
            ],
            rootName: "Lithe-IDEA"
        )

        #expect(tree.name == "Lithe-IDEA")
        #expect(tree.fileCount == 6)
        #expect(tree.files.map(\.path) == ["README.md"])
        #expect(tree.directories.map(\.name) == ["docs", "service", "src/main/java/example"])

        let docs = tree.directories[0]
        #expect(docs.fileCount == 2)
        #expect(docs.files.map(\.path) == ["docs/README.md"])
        #expect(docs.directories.map(\.name) == ["architecture"])

        let service = tree.directories[1]
        #expect(service.fileCount == 2)
        #expect(service.files.map(\.path) == ["service/Service.java"])
        #expect(service.directories.map(\.name) == ["impl"])
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
