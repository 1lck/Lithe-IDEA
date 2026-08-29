import Foundation
import LitheApplicationKernel
@testable import LitheGitModule
import LitheModuleAPI
import Testing

@MainActor
struct GitModuleTests {
    @Test
    func treeStatusProjectsExactFilesAndHighestPriorityDirectories() {
        let root = URL(fileURLWithPath: "/workspace")
        let projection = GitTreeStatusProjection(changes: [
            GitChange(
                repositoryRoot: root,
                path: "Sources/Modified.swift",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "M"
            ),
            GitChange(
                repositoryRoot: root,
                path: "Sources/Feature/Added.swift",
                originalPath: nil,
                indexStatus: "?",
                workTreeStatus: "?"
            ),
            GitChange(
                repositoryRoot: root,
                path: "Sources/Feature/Conflict.swift",
                originalPath: nil,
                indexStatus: "U",
                workTreeStatus: "U"
            )
        ])

        #expect(projection.kind(relativePath: "Sources/Modified.swift", isDirectory: false) == .modified)
        #expect(projection.kind(relativePath: "Sources/Feature", isDirectory: true) == .conflicted)
        #expect(projection.kind(relativePath: "Sources", isDirectory: true) == .conflicted)
        #expect(projection.kind(relativePath: "Tests", isDirectory: true) == nil)
        #expect(projection.kind(relativePath: "", isDirectory: true) == .conflicted)
    }

    @Test
    func treeStatusNormalizesSeparatorsWithoutMatchingSiblingPrefixes() {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "src/main/App.java",
            originalPath: nil,
            indexStatus: "A",
            workTreeStatus: " "
        )
        let projection = GitTreeStatusProjection(changes: [change])

        #expect(projection.change(relativePath: "\\src\\main\\App.java") == change)
        #expect(projection.kind(relativePath: "src/mai", isDirectory: true) == nil)
    }

    @Test
    func lineChangeProjectionMapsAdditionsChangesAndMiddleDeletions() {
        let markers = GitLineChangeProjection.markers(from: [
            DiffRow(oldLine: 1, newLine: 1, left: "same", right: "same", kind: .context, hunkID: "h1"),
            DiffRow(oldLine: nil, newLine: 2, left: nil, right: "added", kind: .addition, hunkID: "h1"),
            DiffRow(oldLine: 2, newLine: 3, left: "old", right: "new", kind: .changed, hunkID: "h1"),
            DiffRow(oldLine: 3, newLine: nil, left: "removed", right: nil, kind: .removal, hunkID: "h2"),
            DiffRow(oldLine: 4, newLine: 4, left: "next", right: "next", kind: .context, hunkID: "h2")
        ])

        #expect(markers == [
            GitLineChangeMarker(line: 1, kind: .added, hunkID: "h1"),
            GitLineChangeMarker(line: 2, kind: .modified, hunkID: "h1"),
            GitLineChangeMarker(line: 3, kind: .deleted, hunkID: "h2")
        ])
    }

    @Test
    func lineChangeProjectionAnchorsEndDeletionAndUsesSameLinePriority() {
        let markers = GitLineChangeProjection.markers(from: [
            DiffRow(oldLine: 1, newLine: 1, left: "same", right: "same", kind: .context, hunkID: "context"),
            DiffRow(oldLine: nil, newLine: 2, left: nil, right: "added", kind: .addition, hunkID: "added"),
            DiffRow(oldLine: 2, newLine: 2, left: "old", right: "new", kind: .changed, hunkID: "modified"),
            DiffRow(oldLine: 3, newLine: nil, left: "removed", right: nil, kind: .removal, hunkID: "deleted")
        ])

        #expect(markers == [
            GitLineChangeMarker(line: 1, kind: .modified, hunkID: "modified")
        ])
    }

    @Test
    func gitLogQueryParsesStructuredFiltersAndQuotedValues() {
        let query = GitLogQuery.parse(
            #"fix login me author:"Ada Lovelace" branch:origin/main path:'Sources/Auth Flow'"#
        )

        #expect(query.textTerms == ["fix", "login"])
        #expect(query.currentUserOnly)
        #expect(query.authors == ["Ada Lovelace"])
        #expect(query.branches == ["origin/main"])
        #expect(query.paths == ["Sources/Auth Flow"])
    }

    @Test
    func gitLogQueryMatchesIdentityAuthorTextAndPaths() {
        let commit = GitCommit(
            hash: "0123456789abcdef",
            shortHash: "0123456",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026/08/16 00:00",
            subject: "Fix login redirect",
            decorations: "HEAD -> main"
        )
        let query = GitLogQuery.parse("me author:ada fix path:AuthController")

        #expect(query.matchesMetadata(
            commit,
            identity: GitIdentity(name: nil, email: "ada@example.com")
        ))
        #expect(query.matchesPaths(["src/main/java/demo/AuthController.java"]))
        #expect(!query.matchesPaths(["src/main/java/demo/HomeController.java"]))
        #expect(!query.matchesMetadata(
            commit,
            identity: GitIdentity(name: "Grace Hopper", email: "grace@example.com")
        ))
    }

    @Test
    func gitLogStructuredFiltersPreserveQuotedPathsAndMatchSelectedAuthorExactly() {
        let selectedAuthor = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "dev@example.com",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Update quoted path",
            decorations: ""
        )
        let similarAuthor = GitCommit(
            hash: "2222222222222222",
            shortHash: "2222222",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "dev@example.com.invalid",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Update quoted path",
            decorations: ""
        )
        let path = #"Sources/It's a "quoted" file.swift"#
        let query = GitLogQuery.parse("Update").addingStructuredFilters(
            exactAuthor: GitIdentity(name: selectedAuthor.authorName, email: selectedAuthor.authorEmail),
            paths: [path]
        )

        #expect(query.paths == [path])
        #expect(query.matchesMetadata(selectedAuthor, identity: nil))
        #expect(!query.matchesMetadata(similarAuthor, identity: nil))
        #expect(query.matchesPaths([path]))
        #expect(!query.matchesPaths([#"Sources/Its a "quoted" file.swift"#]))
    }

    @Test
    func gitLogStructuredAuthorFallsBackToExactNameWhenEmailIsBlank() {
        let exactName = GitCommit(
            hash: "3333333333333333",
            shortHash: "3333333",
            parentHashes: [],
            authorName: "Alice",
            authorEmail: "",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Exact author",
            decorations: ""
        )
        let similarName = GitCommit(
            hash: "4444444444444444",
            shortHash: "4444444",
            parentHashes: [],
            authorName: "Alice Smith",
            authorEmail: "",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Similar author",
            decorations: ""
        )
        let query = GitLogQuery(exactAuthor: GitIdentity(name: "Alice", email: nil))

        #expect(query.matchesMetadata(exactName, identity: nil))
        #expect(!query.matchesMetadata(similarName, identity: nil))
    }

    @Test
    func gitLogQueryMatchesInclusiveAfterAndExclusiveBeforeDates() {
        let insideRange = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-16T09:30:00+08:00",
            subject: "Inside range",
            decorations: ""
        )
        let atExclusiveEnd = GitCommit(
            hash: "2222222222222222",
            shortHash: "2222222",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-18T00:00:00Z",
            subject: "Outside range",
            decorations: ""
        )
        let query = GitLogQuery.parse("after:2026-08-16 before:2026-08-18")

        #expect(!query.isEmpty)
        #expect(query.afterDate != nil)
        #expect(query.beforeDate != nil)
        #expect(query.matchesMetadata(insideRange, identity: nil))
        #expect(!query.matchesMetadata(atExclusiveEnd, identity: nil))
    }

    @Test
    func gitConsoleCommandFormatterQuotesArgumentsAndRedactsURLCredentials() {
        let commandLine = GitConsoleCommandFormatter.commandLine(arguments: [
            "push",
            "feature branch",
            "John's change\nnext line",
            "https://alice:secret@example.com/org/repository.git",
            ""
        ])

        #expect(commandLine.hasPrefix("git push 'feature branch'"))
        #expect(commandLine.contains(#"'John'\''s change\nnext line'"#))
        #expect(commandLine.contains("redacted"))
        #expect(!commandLine.contains("alice"))
        #expect(!commandLine.contains("secret"))
        #expect(commandLine.hasSuffix(" ''"))
    }

    @Test
    func gitConsoleRedactsCredentialsFromArgumentsAndProcessStreams() {
        let secret = "FAKE_SUPER_SECRET_TOKEN"
        let credentialURL = "https://alice:password@example.com/repository.git?access_token=\(secret)&mode=test"
        let tokenURL = "https://example.com/repository.git?token=\(secret)"
        let entry = GitConsoleEntry(
            workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["fetch", credentialURL],
            output: "warning: request failed for \(tokenURL)\nfatal: unable to access '\(credentialURL)'\n",
            standardOutput: "warning: request failed for \(tokenURL)\n",
            standardError: "fatal: unable to access '\(credentialURL)'\n",
            exitCode: 1
        )

        let visibleText = [
            entry.arguments.joined(separator: " "),
            entry.output,
            entry.standardOutput ?? "",
            entry.standardError ?? "",
            entry.commandLine,
            entry.copyText,
            entry.outputLines.map(\.text).joined(separator: "\n")
        ].joined(separator: "\n")
        #expect(visibleText.contains("redacted"))
        #expect(!visibleText.contains(secret))
        #expect(!visibleText.contains("alice"))
        #expect(!visibleText.contains("password"))
    }

    @Test
    func gitConsoleRecordsEveryInvocationFromCompositeOperations() async {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "README.md",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            stageResult: GitProcessResult(
                arguments: ["checkout", "HEAD", "--", "README.md"],
                output: "",
                exitCode: 0,
                invocations: [
                    GitProcessInvocation(
                        arguments: ["status", "--porcelain", "--", "README.md"],
                        standardOutput: " M README.md\n",
                        standardError: "",
                        exitCode: 0
                    ),
                    GitProcessInvocation(
                        arguments: ["checkout", "HEAD", "--", "README.md"],
                        standardOutput: "",
                        standardError: "",
                        exitCode: 0
                    )
                ]
            )
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectChange(change)
        await feature.stageSelectedChange()

        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["status", "--porcelain", "--", "README.md"],
            ["checkout", "HEAD", "--", "README.md"]
        ])
    }

    @Test
    func postInvocationOperationErrorFailsWhileKeepingConsoleTrace() async {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "README.md",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let operationError = "Invalid Git reference"
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            stageResult: GitProcessResult(
                arguments: ["stash", "push", "--include-untracked"],
                output: operationError,
                standardOutput: "No local changes to save\n",
                standardError: "",
                exitCode: 0,
                invocations: [
                    GitProcessInvocation(
                        arguments: ["stash", "push", "--include-untracked"],
                        standardOutput: "No local changes to save\n",
                        standardError: "",
                        exitCode: 0
                    )
                ],
                operationErrorMessage: operationError
            )
        ))
        let feature = GitFeatureModel(service: service)
        var notifications: [String] = []
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { notifications.append($0) },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectChange(change)
        await feature.stageSelectedChange()

        let result = await service.stage(change)
        #expect(!result.succeeded)
        #expect(notifications == [operationError])
        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["stash", "push", "--include-untracked"]
        ])
        #expect(feature.gitConsoleEntries.first?.succeeded == true)
    }

    @Test
    func gitServicePreservesExecutedArgumentsAndWorkingDirectory() async {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "README.md",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let service = GitService(operations: TestGitOperations(
            stageResult: GitProcessResult(
                arguments: ["add", "--", "README.md"],
                output: "staged",
                exitCode: 0
            )
        ))

        let result = await service.stage(change)

        #expect(result.workingDirectory == root)
        #expect(result.arguments == ["add", "--", "README.md"])
        #expect(result.output == "staged")
        #expect(result.succeeded)
    }

    @Test
    func gitConsoleLoadsGitVersionOnlyOnce() async {
        let root = URL(fileURLWithPath: "/workspace")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.loadGitConsoleIfNeeded()
        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.first?.workingDirectory == root)
        #expect(feature.gitConsoleEntries.first?.arguments == ["version"])
        #expect(feature.gitConsoleEntries.first?.output == "git version 2.55.0\n")
    }

    @Test
    func commitSelectionLoadsFilesWithoutSelectingTheFirstFile() async {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:00:00+08:00",
            subject: "Selected commit",
            decorations: ""
        )
        let nextCommit = GitCommit(
            hash: "2222222222222222",
            shortHash: "2222222",
            parentHashes: [commit.hash],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:01:00+08:00",
            subject: "Next commit",
            decorations: ""
        )
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesValue: files
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectGitCommit(commit)

        #expect(feature.selectedGitCommit == commit)
        #expect(feature.selectedGitCommitFiles == files)
        #expect(feature.selectedGitCommitFile == nil)

        feature.previewGitCommitSelection(nextCommit)

        #expect(feature.selectedGitCommit == nextCommit)
        #expect(feature.selectedGitCommitFiles.isEmpty)
        #expect(feature.selectedGitCommitFile == nil)
        #expect(feature.selectedGitCommitDiffContext == nil)
    }

    @Test
    func repeatedCommitSelectionReusesCachedFilesAndResetInvalidatesCache() async {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:00:00+08:00",
            subject: "Cached commit",
            decorations: ""
        )
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let filesRecorder = GitFilesCallRecorder()
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesValue: files,
            filesRecorder: filesRecorder
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectGitCommit(commit)
        await feature.selectGitCommit(commit)

        #expect(filesRecorder.callCount == 1)
        #expect(feature.selectedGitCommitFiles == files)

        feature.reset()
        await feature.refreshGit()
        await feature.selectGitCommit(commit)

        #expect(filesRecorder.callCount == 2)
        #expect(feature.selectedGitCommitFiles == files)
    }

    @Test
    func resetSupersedesInFlightReadAndRetriesSameCommitInNewGeneration() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:00:00+08:00",
            subject: "Reset during commit file read",
            decorations: ""
        )
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let readGate = GitCommitFilesReadGate()
        let filesRecorder = GitFilesCallRecorder()
        let service = GitService(operations: TestGitOperations(
            filesValue: files,
            filesRecorder: filesRecorder,
            filesReadGate: readGate
        ))
        let loader = GitCommitFilesLoader(service: service)

        let firstRequest = loader.requestSelectedFiles(for: commit, at: root)
        defer {
            firstRequest.cancel()
            readGate.releaseFirstRead()
        }

        try #require(await readGate.waitUntilFirstReadStarts())
        loader.reset()
        let secondRequest = loader.requestSelectedFiles(for: commit, at: root)
        defer { secondRequest.cancel() }

        let firstOutcome = try #require(await waitForGitCommitFilesOutcome(firstRequest))
        #expect(firstOutcome == .superseded)

        readGate.releaseFirstRead()
        let secondOutcome = try #require(await waitForGitCommitFilesOutcome(secondRequest))
        #expect(secondOutcome == .ready(files))
        #expect(filesRecorder.callCount == 2)
        #expect(!readGate.didTimeout)
    }

    @Test
    func commitFilesPrefetchPrioritizesTheNextOlderAndNewerCommits() {
        let commits = (0..<6).map { index in
            let hash = String(index)
            return GitCommit(
                hash: hash,
                shortHash: hash,
                parentHashes: [],
                authorName: "Test Author",
                authorEmail: "author@example.com",
                date: "2026-08-28T16:00:00+08:00",
                subject: hash,
                decorations: ""
            )
        }

        let candidates = GitCommitFilesPrefetchPlan.candidates(
            in: commits,
            centeredAt: "2",
            radius: 3
        )

        #expect(candidates.map(\.hash) == ["3", "1", "4", "0", "5"])
        #expect(GitCommitFilesPrefetchPlan.candidates(
            in: commits,
            centeredAt: "missing",
            radius: 3
        ).isEmpty)
    }

    @Test
    func clearingGitConsoleDoesNotTriggerInitialLoadAgain() async {
        let root = URL(fileURLWithPath: "/workspace")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.loadGitConsoleIfNeeded()
        feature.clearGitConsole()
        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.isEmpty)
    }

    @Test
    func switchingRepositoriesDiscardsStaleInitialGitConsoleOutput() async {
        let firstRoot = URL(fileURLWithPath: "/first-workspace")
        let secondRoot = URL(fileURLWithPath: "/second-workspace")
        let runGate = TestGitRunGate()
        let service = GitService(operations: TestGitOperations(runGate: runGate))
        let feature = GitFeatureModel(
            service: service,
            snapshotProvider: { root in
                GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
            }
        )
        var workspaceURL = firstRoot
        feature.configure(
            workspaceURLProvider: { workspaceURL },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        let initialLoad = Task { await feature.loadGitConsoleIfNeeded() }
        await runGate.waitUntilFirstRunStarts()
        workspaceURL = secondRoot
        await feature.refreshGit()
        runGate.releaseFirstRun()
        await initialLoad.value

        #expect(feature.gitConsoleEntries.isEmpty)

        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.first?.workingDirectory == secondRoot)
    }

    @Test
    func gitConsolePreservesStandardErrorColorForSuccessfulCommands() {
        let entry = GitConsoleEntry(
            workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["checkout", "-b", "feature"],
            output: "Switched to a new branch 'feature'\n",
            standardOutput: "",
            standardError: "Switched to a new branch 'feature'\n",
            exitCode: 0
        )

        #expect(entry.succeeded)
        #expect(entry.outputLines == [
            GitConsoleOutputLine(
                stream: .standardError,
                text: "Switched to a new branch 'feature'"
            )
        ])
    }


    @Test
    func workingTreeComparisonMergesTrackedAndUntrackedFiles() async {
        let root = URL(fileURLWithPath: "/workspace")
        let reference = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: "origin/main"
        )
        let snapshot = GitSnapshot(repositoryRoot: root, branch: "main", changes: [
            GitChange(
                repositoryRoot: root,
                path: "README.md",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "M"
            ),
            GitChange(
                repositoryRoot: root,
                path: "src/UserRepository.java",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "D"
            ),
            GitChange(
                repositoryRoot: root,
                path: "qa-untracked.txt",
                originalPath: nil,
                indexStatus: "?",
                workTreeStatus: "?"
            )
        ])
        let trackedComparison = GitBranchComparison(reference: reference, files: [
            GitBranchComparisonFile(status: "D", path: "src/UserRepository.java"),
            GitBranchComparisonFile(status: "M", path: "README.md")
        ])
        let service = GitService(operations: TestGitOperations(
            snapshotValue: snapshot,
            comparisonValue: trackedComparison
        ))

        let comparison = await service.comparisonWithWorkingTree(for: reference, at: root)

        #expect(comparison.files.map(\.path) == [
            "README.md",
            "qa-untracked.txt",
            "src/UserRepository.java"
        ])
        #expect(comparison.files.count == 3)
        #expect(comparison.files.first(where: { $0.path == "qa-untracked.txt" })?.isUntracked == true)
        #expect(comparison.files.first(where: { $0.path == "README.md" })?.isUntracked == false)
    }

    @Test
    func untrackedComparisonFileUsesUntrackedDiffDocument() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let reference = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let untrackedDocument = DiffDocument(rows: [
            DiffRow(
                oldLine: nil,
                newLine: 1,
                left: nil,
                right: "untracked contents",
                kind: .addition
            )
        ], hunks: [])
        let comparisonDocument = DiffDocument(rows: [
            DiffRow(
                oldLine: 1,
                newLine: 1,
                left: "before",
                right: "tracked contents",
                kind: .changed
            )
        ], hunks: [])
        let service = GitService(operations: TestGitOperations(
            untrackedDiffDocumentValue: untrackedDocument,
            comparisonDiffDocumentValue: comparisonDocument
        ))

        let untrackedRows = await service.diff(
            for: GitBranchComparisonFile(
                status: "A",
                path: "qa-untracked.txt",
                isUntracked: true
            ),
            against: reference,
            at: root
        )
        let trackedRows = await service.diff(
            for: GitBranchComparisonFile(status: "M", path: "README.md"),
            against: reference,
            at: root
        )

        #expect(try #require(untrackedRows.first).rightText == "untracked contents")
        #expect(try #require(untrackedRows.first).kind == .addition)
        #expect(try #require(trackedRows.first).rightText == "tracked contents")
    }

    @Test
    func referenceComparisonDoesNotIncludeWorkingTreeUntrackedFiles() async {
        let root = URL(fileURLWithPath: "/workspace")
        let source = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let target = GitReference(
            fullName: "refs/remotes/origin/main",
            shortName: "origin/main",
            kind: .remote,
            isCurrent: false,
            upstreamShortName: nil
        )
        let snapshot = GitSnapshot(repositoryRoot: root, branch: "main", changes: [
            GitChange(
                repositoryRoot: root,
                path: "qa-untracked.txt",
                originalPath: nil,
                indexStatus: "?",
                workTreeStatus: "?"
            )
        ])
        let payload = GitBranchComparison(reference: source, files: [
            GitBranchComparisonFile(status: "M", path: "src/Tracked.java")
        ])
        let service = GitService(operations: TestGitOperations(
            snapshotValue: snapshot,
            comparisonValue: payload
        ))

        let comparison = await service.comparison(from: source, to: target, at: root)

        #expect(comparison.files.map(\.path) == ["src/Tracked.java"])
        #expect(comparison.targetReference == target)
    }

    @Test
    func disabledGitDoesNotConstructFactoryOrServiceGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: GitModule.moduleManifest, contributions: GitModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.git)) {
            _ = try await runtime.activateCapability(.gitWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.storageFactoryCalls == 0)
        #expect(try !runtime.snapshot(for: .git).isInstantiated)
    }

    @Test
    func sleepReleasesFeatureAndWakeCreatesANewGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: GitModule.moduleManifest, contributions: GitModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        })

        var first: GitFeatureModel? = try #require(
            (try await runtime.activateCapability(.gitWorkspace) as? GitModuleCapability)?.feature
        )
        weak var released = first
        first = nil
        try await runtime.sleep(.git)

        #expect(released == nil)
        #expect(runtime.capability(.gitWorkspace) == nil)
        #expect(try runtime.snapshot(for: .git).activity.activeResourceCount == 0)

        let second = try #require(
            (try await runtime.activateCapability(.gitWorkspace) as? GitModuleCapability)?.feature
        )
        #expect(second !== released)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.storageFactoryCalls == 2)
    }

    private func makeModule(recorder: Recorder) -> GitModule {
        recorder.storageFactoryCalls += 1
        return GitModule(operations: TestGitOperations(), shelfStorage: TestShelfStorage())
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyWorkspaceModule()
        }
    }
}

@MainActor private final class Recorder { var factoryCalls = 0; var storageFactoryCalls = 0 }
@MainActor private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct TestShelfStorage: GitShelfStorage {
    func applicationSupportDirectory() -> URL { URL(fileURLWithPath: "/tmp/lithe-git-module-test") }
    func fileExists(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readData(from url: URL) throws -> Data { Data() }
    func writeData(_ data: Data, to url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func removeItem(at url: URL) throws {}
}

private final class TestGitRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstRunRelease = DispatchSemaphore(value: 0)
    private var hasBlockedFirstRun = false
    private var firstRunWaiter: CheckedContinuation<Void, Never>?

    func blockFirstRun() {
        lock.lock()
        let shouldBlock = !hasBlockedFirstRun
        hasBlockedFirstRun = true
        let waiter = shouldBlock ? firstRunWaiter : nil
        firstRunWaiter = nil
        lock.unlock()
        guard shouldBlock else { return }
        waiter?.resume()
        firstRunRelease.wait()
    }

    func waitUntilFirstRunStarts() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasBlockedFirstRun {
                lock.unlock()
                continuation.resume()
            } else {
                firstRunWaiter = continuation
                lock.unlock()
            }
        }
    }

    func releaseFirstRun() {
        firstRunRelease.signal()
    }
}

private final class GitFilesCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

/// Blocks only the first synchronous commit-file read so reset ordering can be
/// asserted without relying on task scheduling or wall-clock delays.
private final class GitCommitFilesReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadRelease = DispatchSemaphore(value: 0)
    private let firstReadStarted = GitAsyncTestSignal()
    private var hasBlockedFirstRead = false
    private var released = false
    private var didTimeoutValue = false

    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeoutValue
    }

    func blockFirstRead() {
        lock.lock()
        let shouldBlock = !hasBlockedFirstRead
        hasBlockedFirstRead = true
        lock.unlock()

        guard shouldBlock else { return }
        firstReadStarted.signal()

        // GitService invokes this synchronous port on its detached read worker;
        // the finite deadline prevents a failed test from pinning that worker.
        let result = firstReadRelease.wait(timeout: .now() + 5)
        if result == .timedOut {
            lock.lock()
            didTimeoutValue = true
            lock.unlock()
        }
    }

    func waitUntilFirstReadStarts(timeout: Duration = .seconds(2)) async -> Bool {
        await firstReadStarted.waitUntilSignaled(timeout: timeout)
    }

    func releaseFirstRead() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        firstReadRelease.signal()
    }
}

private final class GitAsyncTestSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func signal() {
        continuation.yield()
        continuation.finish()
    }

    func waitUntilSignaled(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for an event-driven test signal.
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private func waitForGitCommitFilesOutcome(
    _ task: Task<GitCommitFilesLoadOutcome, Never>,
    timeout: Duration = .seconds(2)
) async -> GitCommitFilesLoadOutcome? {
    await withTaskGroup(of: GitCommitFilesLoadOutcome?.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for a loader outcome.
            try? await Task.sleep(for: timeout)
            task.cancel()
            return nil
        }
        let result = await group.next() ?? nil
        if result == nil {
            task.cancel()
        }
        group.cancelAll()
        return result
    }
}

private struct TestGitOperations: GitOperations {
    private let snapshotValue: GitSnapshot?
    private let comparisonValue: GitBranchComparison?
    private let filesValue: [GitCommitFile]?
    private let untrackedDiffDocumentValue: DiffDocument?
    private let comparisonDiffDocumentValue: DiffDocument?
    private let stageResult: GitProcessResult?
    private let runGate: TestGitRunGate?
    private let filesRecorder: GitFilesCallRecorder?
    private let filesReadGate: GitCommitFilesReadGate?

    init(
        snapshotValue: GitSnapshot? = nil,
        comparisonValue: GitBranchComparison? = nil,
        filesValue: [GitCommitFile]? = nil,
        untrackedDiffDocumentValue: DiffDocument? = nil,
        comparisonDiffDocumentValue: DiffDocument? = nil,
        stageResult: GitProcessResult? = nil,
        runGate: TestGitRunGate? = nil,
        filesRecorder: GitFilesCallRecorder? = nil,
        filesReadGate: GitCommitFilesReadGate? = nil
    ) {
        self.snapshotValue = snapshotValue
        self.comparisonValue = comparisonValue
        self.filesValue = filesValue
        self.untrackedDiffDocumentValue = untrackedDiffDocumentValue
        self.comparisonDiffDocumentValue = comparisonDiffDocumentValue
        self.stageResult = stageResult
        self.runGate = runGate
        self.filesRecorder = filesRecorder
        self.filesReadGate = filesReadGate
    }

    func run(arguments: [String], workingDirectory: String, input: String?) -> GitProcessResult {
        runGate?.blockFirstRun()
        return GitProcessResult(
            arguments: arguments,
            output: "git version 2.55.0\n",
            standardOutput: "git version 2.55.0\n",
            standardError: "",
            exitCode: 0
        )
    }

    func snapshot(at rootURL: URL) -> GitSnapshot? { snapshotValue }
    func watchContext(at rootURL: URL) -> GitWatchContext? { nil }
    func diffDocument(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> DiffDocument? {
        untracked ? untrackedDiffDocumentValue : nil
    }
    func diffPatch(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> String? { nil }
    func commitDiffDocument(at rootURL: URL, commit: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { comparisonDiffDocumentValue }
    func applyPatch(_ patch: String, at rootURL: URL, mode: String) -> GitProcessResult? { nil }
    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? { nil }
    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? {
        filesRecorder?.recordCall()
        filesReadGate?.blockFirstRead()
        return filesValue
    }
    func commit(at rootURL: URL, hash: String) -> GitCommit? { nil }
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison? { comparisonValue }
    func stashes(at rootURL: URL) -> [GitStash]? { nil }
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? { nil }
    func stage(_ change: GitChange) -> GitProcessResult? { stageResult }
    func unstage(_ change: GitChange) -> GitProcessResult? { nil }
    func discard(_ change: GitChange) -> GitProcessResult? { nil }
    func discardAll(_ change: GitChange) -> GitProcessResult? { nil }
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? { nil }
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? { nil }
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? { nil }
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult? { nil }
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? { nil }
    func conflictMarkerPaths(at rootURL: URL) -> [String] { [] }
    func integrationPreflight(for target: GitIntegrationTarget, operation: GitIntegrationOperation, at rootURL: URL) -> GitIntegrationPreflightState? { nil }
    func fetch(at rootURL: URL) -> GitProcessResult? { nil }
    func checkout(_ reference: GitReference, at rootURL: URL, force: Bool, autoStash: Bool) -> GitProcessResult? { nil }
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String] { [] }
    func operationState(at rootURL: URL) -> GitOperationState? { nil }
    func continueOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func abortOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func skipOperationStep(at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult? { nil }
    func push(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult? { nil }
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func stageAll(at rootURL: URL) -> GitProcessResult? { nil }
}
