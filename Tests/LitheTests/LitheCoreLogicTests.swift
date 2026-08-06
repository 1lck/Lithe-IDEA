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
    func splitDiffLayoutKeepsBothCodeStreamsDenseAcrossInsertionsAndDeletions() {
        let insertionRows = [
            DiffRow(oldLine: 1, newLine: 1, left: "before", right: nil, kind: .context, sequence: 0),
            DiffRow(oldLine: nil, newLine: 2, left: nil, right: "added 1", kind: .addition, sequence: 1),
            DiffRow(oldLine: nil, newLine: 3, left: nil, right: "added 2", kind: .addition, sequence: 2),
            DiffRow(oldLine: nil, newLine: 4, left: nil, right: "added 3", kind: .addition, sequence: 3),
            DiffRow(oldLine: 2, newLine: 5, left: "after", right: nil, kind: .context, sequence: 4)
        ]
        let insertionDisplay = insertionRows.enumerated().map {
            DiffDisplayRow.row($0.element, index: $0.offset)
        }
        let insertion = DiffSplitLayout.plan(
            displayRows: insertionDisplay,
            kinds: insertionRows.map(\.kind)
        )

        // The old side advances directly from `before` to `after`; it does not
        // receive three synthetic blank rows to match the new side.
        #expect(insertion.leftItems.map(\.top) == [0, 24])
        #expect(insertion.rightItems.map(\.top) == [0, 24, 48, 72, 96])
        #expect(insertion.leftHeight == 48)
        #expect(insertion.rightHeight == 120)
        #expect(insertion.transitions.count == 1)
        #expect(insertion.transitions[0].isAddition)
        #expect(insertion.transitions[0].leftRange == 24...24)
        #expect(insertion.transitions[0].rightRange == 24...96)

        let removalRows = insertionRows.map { row in
            switch row.kind {
            case .addition:
                return DiffRow(
                    oldLine: row.newLine,
                    newLine: nil,
                    left: row.rightText,
                    right: nil,
                    kind: .removal,
                    sequence: row.id.sequence
                )
            default:
                return row
            }
        }
        let removal = DiffSplitLayout.plan(
            displayRows: removalRows.enumerated().map {
                DiffDisplayRow.row($0.element, index: $0.offset)
            },
            kinds: removalRows.map(\.kind)
        )

        #expect(removal.leftItems.map(\.top) == [0, 24, 48, 72, 96])
        #expect(removal.rightItems.map(\.top) == [0, 24])
        #expect(removal.transitions.count == 1)
        #expect(removal.transitions[0].isRemoval)
        #expect(removal.transitions[0].leftRange == 24...96)
        #expect(removal.transitions[0].rightRange == 24...24)
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
    func workspaceTreeCompactsMiddlePackagesOnlyUnderSourceRoots() throws {
        // 目录树按 Rust core 实际发出的 JSON 形状构造，避免测试绕过解码路径。
        func dir(_ path: String, _ children: String...) -> String {
            let name = (path as NSString).lastPathComponent
            let list = children.joined(separator: ",")
            return "{\"path\":\"\(path)\",\"name\":\"\(name)\",\"isDirectory\":true,\"children\":[\(list)]}"
        }
        func file(_ path: String) -> String {
            let name = (path as NSString).lastPathComponent
            return "{\"path\":\"\(path)\",\"name\":\"\(name)\",\"isDirectory\":false}"
        }

        let aiPackage = dir(
            "src/main/java/com",
            dir(
                "src/main/java/com/alibaba",
                dir(
                    "src/main/java/com/alibaba/nacos",
                    dir(
                        "src/main/java/com/alibaba/nacos/ai",
                        file("src/main/java/com/alibaba/nacos/ai/App.java"),
                        dir("src/main/java/com/alibaba/nacos/ai/config")
                    )
                )
            )
        )
        // 有文件就不是空中间包，不该被压缩。
        let soloPackage = dir(
            "src/main/java/solo",
            file("src/main/java/solo/Solo.java"),
            dir("src/main/java/solo/inner")
        )
        let sourceTree = dir(
            "src",
            dir(
                "src/main",
                dir("src/main/java", aiPackage, soloPackage),
                dir("src/main/resources", dir("src/main/resources/META-INF"))
            )
        )
        // 源码根之外的单子目录链保持原样。
        let docsTree = dir("docs", dir("docs/guide"))
        let json = "{\"root\":\(dir("", sourceTree, docsTree)),\"files\":[]}"

        let payload = try JSONDecoder().decode(
            RustCoreBridge.WorkspaceSnapshotPayload.self,
            from: Data(json.utf8)
        )
        let root = URL(fileURLWithPath: "/tmp/lithe-workspace-tree")
        let tree = payload.makeSnapshot(at: root).root

        func child(_ node: FileNode, _ name: String) throws -> FileNode {
            let match = node.children?.first { $0.name == name }
            return try #require(match, "missing child '\(name)' in \(node.name)")
        }

        let javaRoot = try child(child(child(tree, "src"), "main"), "java")
        #expect(javaRoot.iconKind == .sourceFolder)

        // com/alibaba/nacos/ai 压缩成一行，url 仍指向最深的真实目录。
        let compacted = try child(javaRoot, "com.alibaba.nacos.ai")
        #expect(compacted.iconKind == .packageFolder)
        #expect(compacted.url.lastPathComponent == "ai")
        #expect(compacted.collapsedAncestorPaths.map { ($0 as NSString).lastPathComponent }
            == ["com", "alibaba", "nacos"])
        #expect(compacted.children?.map(\.name).sorted() == ["App.java", "config"])
        #expect(try child(compacted, "config").iconKind == .packageFolder)

        // 含文件的目录不是空中间包，不压缩。
        let solo = try child(javaRoot, "solo")
        #expect(solo.collapsedAncestorPaths.isEmpty)
        #expect(try child(solo, "inner").iconKind == .packageFolder)

        // 资源根用资源图标；META-INF 名字不是合法包名，保持普通文件夹。
        let resources = try child(child(child(tree, "src"), "main"), "resources")
        #expect(resources.iconKind == .resourceFolder)
        #expect(try child(resources, "META-INF").iconKind == .folder)

        // 源码根之外不压缩，也不用包图标。
        let docs = try child(tree, "docs")
        #expect(docs.iconKind == .folder)
        #expect(docs.collapsedAncestorPaths.isEmpty)
        #expect(try child(docs, "guide").iconKind == .folder)
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

    @Test
    func searchRelevanceRanksMatchFormsInOrder() {
        let root = "/tmp/project/src/"
        func result(_ name: String) -> FileSearchResult {
            FileSearchResult(
                url: URL(fileURLWithPath: root + name),
                line: nil,
                preview: "",
                kind: .file
            )
        }

        let query = "DeviceHandler"
        let exact = SearchRelevance.score(result("DeviceHandler.java"), query: query)
        let prefix = SearchRelevance.score(result("DeviceHandlerFactory.java"), query: query)
        let substring = SearchRelevance.score(result("AbstractDeviceHandlerBase.java"), query: query)
        let miss = SearchRelevance.score(result("PadController.java"), query: query)

        #expect(exact > prefix)
        #expect(prefix > substring)
        #expect(substring > 0)
        #expect(miss == 0)
    }

    @Test
    func searchRelevanceMatchesCamelCaseInitials() {
        let target = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/src/DeviceHandler.java"),
            line: nil,
            preview: "",
            kind: .file
        )
        let unrelated = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/src/PadController.java"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(target, query: "dh") > 0)
        #expect(SearchRelevance.score(unrelated, query: "dh") == 0)
    }

    @Test
    func searchRelevancePrefersNameMatchOverPathMatch() {
        let query = "handler"
        let byName = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/Handler.java"),
            line: nil,
            preview: "",
            kind: .file
        )
        let byPathOnly = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/handler/Pad.java"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(byName, query: query) > SearchRelevance.score(byPathOnly, query: query))
    }

    @Test
    func searchRelevancePrefersShallowerFiles() {
        let shallow = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/Device.java"),
            line: nil,
            preview: "",
            kind: .file
        )
        let deep = FileSearchResult(
            url: URL(fileURLWithPath: "/tmp/project/a/b/c/d/Device.java"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(shallow, query: "Device") > SearchRelevance.score(deep, query: "Device"))
    }

    @Test
    func searchRelevanceRanksTypeAboveContentForEqualNames() {
        let url = URL(fileURLWithPath: "/tmp/project/src/DeviceHandler.java")
        let type = FileSearchResult(
            url: url,
            line: 10,
            preview: "",
            kind: .type,
            symbolName: "DeviceHandler"
        )
        let content = FileSearchResult(
            url: url,
            line: 42,
            preview: "new DeviceHandler()",
            kind: .content,
            symbolName: "DeviceHandler"
        )

        #expect(
            SearchRelevance.score(type, query: "DeviceHandler")
                > SearchRelevance.score(content, query: "DeviceHandler")
        )
    }
}
