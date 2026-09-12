import Combine
import Foundation
import LitheApplicationKernel
@testable import LitheGitModule
import LitheModuleAPI
import Testing

@MainActor
struct GitModuleTests {
    @Test
    func consoleIncludesCommandsFromOtherFeaturesBeforeItWasOpened() async {
        let root = URL(fileURLWithPath: "/workspace")
        let journal = GitExecutionJournal()
        journal.receive(GitExecutionEvent(operationId: "github", type: "started", invocationId: 1,
            workingDirectory: root.path, arguments: ["push", "origin", "feature"]))
        journal.receive(GitExecutionEvent(operationId: "github", type: "finished", invocationId: 1, exitCode: 0))
        journal.receive(GitExecutionEvent(operationId: "github", type: "requestFinished"))
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []))),
            executionJournal: journal)
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["push", "origin", "feature"]])
        await feature.loadGitConsoleIfNeeded()
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["push", "origin", "feature"]])
        feature.clearGitConsole()
        await feature.loadGitConsoleIfNeeded()
        #expect(feature.gitConsoleEntries.isEmpty)
        #expect(journal.snapshot.isEmpty)
    }

    @Test
    func fetchProgressOnStderrRemainsReadableAndDoesNotImplyFailure() {
        let progress = "Receiving objects: 10%\rReceiving objects: 100%\r\n"
        let entry = GitConsoleEntry(workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["fetch", "--progress"], output: progress,
            standardError: progress, exitCode: 0, operationTitle: "Fetch")
        #expect(entry.succeeded)
        #expect(entry.outputLines.map(\.text) == ["Receiving objects: 10%", "Receiving objects: 100%"])
        #expect(entry.outputLines.allSatisfy { $0.stream == .standardError })
    }

    @Test(arguments: [Int32(0), Int32(128)])
    func fetchRecordsPlanBeforeExecutionAndKeepsTheActualExitStatus(exitCode: Int32) async {
        let root = URL(fileURLWithPath: "/workspace")
        let options = GitFetchOptions(remote: "team/origin", prune: false, submodules: .no)
        let planned = ["fetch", "--progress", "--no-prune", "--", "team/origin"]
        let actual = ["--no-pager"] + planned
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            fetchPlan: GitFetchPlan(options: options, arguments: planned),
            fetchHandler: { receivedOptions, operationID in
                #expect(receivedOptions == options)
                #expect(UUID(uuidString: operationID) != nil)
                return GitProcessResult(arguments: actual, output: "remote output", exitCode: exitCode,
                    invocations: [GitProcessInvocation(arguments: actual, standardOutput: "",
                        standardError: "remote output", exitCode: exitCode)])
            }
        )))
        defer { feature.reset() }
        var observedStart = false
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {}, onGitOperationBegan: {
                observedStart = true
                #expect(feature.gitConsoleEntries.last?.state == .planned)
                #expect(feature.gitConsoleEntries.last?.arguments == planned)
                #expect(feature.gitConsoleEntries.last?.succeeded == false)
            })
        await feature.refreshGit()
        await feature.fetchGit(options: options)
        #expect(observedStart)
        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.last?.arguments == actual)
        #expect(feature.gitConsoleEntries.last?.exitCode == exitCode)
        #expect(feature.gitConsoleEntries.last?.standardError == "remote output")
        #expect(feature.gitConsoleEntries.last?.succeeded == (exitCode == 0))
        #expect(feature.gitConsoleEntries.last?.state == .completed)
        #expect(feature.gitConsoleEntries.last?.durationMilliseconds != nil)
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test(arguments: [false, true])
    func fetchDoesNotRestoreClearedOrPreviousRepositoryConsole(resetRepository: Bool) async {
        let root = URL(fileURLWithPath: "/workspace")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            fetchPlan: GitFetchPlan(options: GitFetchOptions(), arguments: ["fetch", "--all"]),
            fetchHandler: { _, _ in GitProcessResult(output: "fetch failed", exitCode: 1) }
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {}, onGitOperationBegan: {
                // The lifecycle callback gives the test an exact boundary before
                // execution; neither sleeps nor a blocking process double is needed.
                if resetRepository { feature.reset() } else { feature.clearGitConsole() }
            })
        await feature.refreshGit()
        await feature.fetchGit()
        #expect(feature.gitConsoleEntries.isEmpty)
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test
    func fetchWithoutAnInvocationKeepsItsCommandExplicitlyUnconfirmed() async {
        let root = URL(fileURLWithPath: "/workspace")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            fetchPlan: GitFetchPlan(options: GitFetchOptions(), arguments: ["fetch", "--all"]),
            fetchHandler: { _, _ in GitProcessResult(output: "Could not start Git", exitCode: 1) }
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.fetchGit()
        #expect(feature.gitConsoleEntries.last?.state == .unconfirmed)
        #expect(feature.gitConsoleEntries.last?.succeeded == false)
        #expect(feature.gitConsoleEntries.last?.copyText.contains("No completed Git invocation") == true)
    }
    @Test
    func patchDiscoveryKeepsFilesSelectableAfterAnEncodingFailure() async throws {
        let good = GitPatchFile(path: "good.txt", originalPath: nil, additions: 1, deletions: 0)
        let legacy = GitPatchFile(path: "legacy.txt", originalPath: nil, additions: 1, deletions: 0)
        let service = GitService(operations: TestGitOperations(exportPatchHandler: { paths, metadataOnly in
            if metadataOnly { return .success(GitPatchExport(patch: "", files: [good, legacy], byteLength: 0)) }
            if paths.contains("legacy.txt") { return .failure(GitPatchFailure("Non-UTF-8 patch")) }
            return .success(GitPatchExport(patch: "selected UTF-8 patch", files: [good], byteLength: 20))
        }))
        let feature = GitPatchFeatureModel(service: service) { _, _, _, _ in nil }
        defer { feature.reset() }
        feature.beginExport(at: URL(fileURLWithPath: "/workspace"))
        // Observe the public busy boundary with the existing bounded helper;
        // reset owns task cancellation even when an assertion fails.
        try #require(await waitForGitWorkToBecomeIdle { feature.isBusy })
        #expect(feature.files == [good, legacy])
        #expect(feature.exportPreview == nil)
        #expect(feature.canGenerateExport)
        feature.generateExport()
        try #require(await waitForGitWorkToBecomeIdle { feature.isBusy })
        #expect(feature.errorMessage == "Non-UTF-8 patch")
        #expect(feature.files == [good, legacy])
        feature.selectPath("legacy.txt", included: false)
        feature.generateExport()
        try #require(await waitForGitWorkToBecomeIdle { feature.isBusy })
        #expect(feature.errorMessage == nil)
        #expect(feature.exportPreview?.files == [good])
        #expect(feature.canSave)
    }

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
    func gitRefreshCombinesChangesFromDiscoveredWorkspaceRepositories() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let firstRoot = workspace.appendingPathComponent("service-a", isDirectory: true)
        let secondRoot = workspace.appendingPathComponent("service-b", isDirectory: true)
        let firstChange = GitChange(
            repositoryRoot: firstRoot,
            path: "src/App.swift",
            originalPath: nil,
            indexStatus: "M",
            workTreeStatus: "M"
        )
        let secondChange = GitChange(
            repositoryRoot: secondRoot,
            path: "src/App.swift",
            originalPath: nil,
            indexStatus: "U",
            workTreeStatus: "U"
        )
        let service = GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                firstRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: firstRoot,
                    branch: "main",
                    changes: [firstChange]
                ),
                secondRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: secondRoot,
                    branch: "develop",
                    changes: [secondChange]
                )
            ],
            repositoryRoots: [firstRoot, secondRoot],
            commitResult: GitProcessResult(arguments: ["commit"], output: "committed", exitCode: 0)
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { workspace },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()

        #expect(feature.availableRepositoryRoots == [firstRoot, secondRoot])
        #expect(feature.gitChanges == [firstChange, secondChange])
        #expect(feature.currentBranch == "main")
        #expect(feature.activeRepositoryChanges == [firstChange])
        // A conflict or staged entry in another repository must not block this commit.
        #expect(await feature.commitStagedChanges(message: "First repository", amend: false))
        #expect(firstChange.id != secondChange.id)
        #expect(feature.gitTreeStatus.change(relativePath: firstChange.url.path) == firstChange)
        #expect(feature.gitTreeStatus.change(relativePath: secondChange.url.path) == secondChange)
        await feature.selectRepository(secondRoot)
        #expect(feature.gitRepositoryRoot == secondRoot)
        #expect(feature.currentBranch == "develop")
        #expect(feature.activeRepositoryChanges == [secondChange])
        #expect(await !feature.commitStagedChanges(message: "Conflicted repository", amend: false))
        #expect(feature.gitChanges == [firstChange, secondChange])
    }

    @Test
    func gitServiceRecordsElapsedTimeForHistoryOperations() async {
        let root = URL(fileURLWithPath: "/workspace")
        let logger = GitPerformanceLogRecorder()
        let service = GitService(
            operations: TestGitOperations(historyValue: GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [],
                hasMore: false
            )),
            performanceLogger: logger
        )

        _ = await service.history(at: root, limit: 30)

        let messages = logger.messages
        #expect(messages.count == 1)
        #expect(messages.first?.contains("operation=history") == true)
        #expect(messages.first?.contains("duration_ms=") == true)
        #expect(messages.first?.contains("status=success") == true)
    }

    @Test
    func gitHistoryPublishesRecentReferencesInCoreOrder() async {
        let root = URL(fileURLWithPath: "/workspace")
        let main = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: "origin/main"
        )
        let featureBranch = GitReference(
            fullName: "refs/heads/feature/recent",
            shortName: "feature/recent",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            historyValue: GitHistorySnapshot(
                references: [featureBranch, main],
                recentReferences: [main, featureBranch],
                commits: [],
                hasMore: false
            )
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()

        #expect(feature.recentGitReferences.map(\.shortName) == ["main", "feature/recent"])
    }

    @Test
    func gitHistoryAppendsTheNextPageWithoutReplacingEarlierCommits() async {
        let root = URL(fileURLWithPath: "/workspace")
        let commits = (0..<3).map { index in
            GitCommit(
                hash: "hash-\(index)",
                shortHash: "short-\(index)",
                parentHashes: [],
                authorName: "Lithe Test",
                authorEmail: "test@example.com",
                date: "2026/09/01 10:0\(index)",
                subject: "commit-\(index)",
                decorations: ""
            )
        }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            referencesValue: GitReferenceSnapshot(
                references: [],
                recentReferences: [],
                identity: GitIdentity(name: "Lithe Test", email: "test@example.com")
            ),
            historyPageValues: [
                "": GitHistoryPage(
                    commits: Array(commits.prefix(2)),
                    nextCursor: "cursor-2",
                    hasMore: true
                ),
                "cursor-2": GitHistoryPage(
                    commits: [commits[2]],
                    nextCursor: nil,
                    hasMore: false
                )
            ]
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        #expect(feature.gitCommits.map(\.hash) == ["hash-0", "hash-1"])
        #expect(feature.canLoadMoreGitHistory)

        await feature.loadMoreGitHistory()

        #expect(feature.gitCommits.map(\.hash) == ["hash-0", "hash-1", "hash-2"])
        #expect(!feature.canLoadMoreGitHistory)
    }

    @Test
    func repositoryGraphIsSeparateFromVisiblePagingAndReleasesItsCursor() async {
        let root = URL(fileURLWithPath: "/workspace")
        let probe = GitGraphHistoryProbe()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }

        await feature.refreshGit()
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(feature.gitGraphRepositoryCommits.map(\.hash) == ["other-branch", "visible"])
        #expect(feature.canLoadMoreGitHistory)
        #expect(probe.closedCursors == ["graph-cursor"])
        #expect(probe.requestedAllReferences)
        let version = feature.gitGraphRepositoryVersion
        await feature.loadMoreGitHistory()
        #expect(feature.gitCommits.map(\.hash) == ["visible", "older"])
        #expect(feature.gitGraphRepositoryVersion == version)

        probe.failGraphRequest()
        await feature.refreshGitHistory()
        #expect(feature.gitGraphRepositoryCommits.isEmpty)
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(feature.gitGraphRepositoryVersion > version)
    }

    @Test
    func visibleHistoryPublishesBeforeRepositoryGraphCompletes() async {
        let root = URL(fileURLWithPath: "/workspace")
        let probe = GitGraphHistoryProbe(blockGraph: true)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        let visiblePublished = GitModuleTestGate()
        let observation = feature.$gitCommits.sink { commits in
            if commits.map(\.hash) == ["visible"] { visiblePublished.open() }
        }
        let refresh = Task { await feature.refreshGit() }
        defer { observation.cancel(); probe.release.open(); refresh.cancel(); feature.reset() }

        #expect(await probe.started.waitUntilOpen())
        #expect(await visiblePublished.waitUntilOpen())
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(!feature.isLoadingGitHistory)
        #expect(feature.canLoadMoreGitHistory)
        #expect(feature.gitGraphRepositoryCommits.isEmpty)
        // Paging remains usable while the repository context is on its worker.
        await feature.loadMoreGitHistory()
        #expect(feature.gitCommits.map(\.hash) == ["visible", "older"])
        probe.release.open()
        await refresh.value
        #expect(!probe.didTimeOut)
        #expect(feature.gitGraphRepositoryCommits.map(\.hash) == ["other-branch", "visible"])
        #expect(feature.gitCommits.map(\.hash) == ["visible", "older"])
        #expect(probe.closedCursors == ["graph-cursor"])
    }

    @Test
    func supersededRepositoryGraphCannotReplaceNewContext() async {
        let root = URL(fileURLWithPath: "/workspace")
        // The first worker deliberately returns after cancellation and after
        // the second refresh, as a native operation racing cancellation can.
        let probe = GitGraphHistoryProbe(blockGraph: true, releaseOnCancel: false)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        let refresh = Task { await feature.refreshGit() }
        defer { probe.release.open(); refresh.cancel(); feature.reset() }
        #expect(await probe.started.waitUntilOpen())

        await feature.showAllGitReferences()
        #expect(feature.isShowingAllGitReferences)
        #expect(feature.gitGraphRepositoryCommits.map(\.hash) == ["other-branch", "visible"])
        let version = feature.gitGraphRepositoryVersion
        probe.release.open()
        await refresh.value
        #expect(!probe.didTimeOut)
        #expect(feature.gitGraphRepositoryVersion == version)
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(probe.closedCursors.filter { $0 == "graph-cursor" }.count == 2)
    }

    @Test
    func cancelledRepositoryGraphCannotPublishIntoAResetWorkspace() async {
        let root = URL(fileURLWithPath: "/workspace")
        let probe = GitGraphHistoryProbe(blockGraph: true)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        let refresh = Task { await feature.refreshGit() }
        defer { probe.release.open(); refresh.cancel(); feature.reset() }
        let started = await probe.started.waitUntilOpen()
        feature.reset()
        probe.release.open()
        await refresh.value
        #expect(started)
        #expect(!probe.didTimeOut)
        #expect(probe.graphWasCancelled)
        #expect(Set(probe.closedCursors) == ["graph-cursor", "visible-cursor"])
        #expect(feature.gitGraphRepositoryCommits.isEmpty)
        #expect(feature.gitCommits.isEmpty)
    }

    @Test
    func successfulRevertRefreshesVisibleGitHistoryAndFocusesCurrentHead() async {
        let root = URL(fileURLWithPath: "/workspace")
        let revertedCommit = makeTestCommit(hash: "original-commit", subject: "Original change")
        let revertCommit = makeTestCommit(hash: "revert-commit", subject: "Revert original change")
        let controller = GitHistoryMutationController(
            before: [revertedCommit],
            after: [revertCommit, revertedCommit]
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            historyPageHandler: { controller.historyPage() },
            revertHandler: { hash in controller.revert(hash) }
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        #expect(feature.gitCommits.map(\.hash) == [revertedCommit.hash])
        await feature.showAllGitReferences()
        #expect(feature.isShowingAllGitReferences)

        await feature.revert(revertedCommit)

        #expect(feature.gitCommits.map(\.hash) == [revertCommit.hash, revertedCommit.hash])
        #expect(!feature.isShowingAllGitReferences)
        #expect(feature.selectedGitCommit?.hash == revertCommit.hash)
        #expect(controller.revertedHashes == [revertedCommit.hash])
        // Each refresh loads the visible page and independent repository graph.
        #expect(controller.historyCallCount == 8)
    }

    @Test
    func remoteReferenceActionsPreserveIdentityAndPullStrategy() async {
        let root = URL(fileURLWithPath: "/workspace")
        let reference = GitReference(
            fullName: "refs/remotes/origin/feature/demo",
            shortName: "origin/feature/demo",
            kind: .remote,
            isCurrent: false,
            upstreamShortName: nil
        )
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
        await feature.checkoutAndRebase(reference)
        await feature.pullRemoteReference(reference, strategy: .rebase)
        await feature.pullRemoteReference(reference, strategy: .merge)

        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["checkoutAndRebase", reference.fullName],
            ["pull", "rebase", reference.fullName],
            ["pull", "merge", reference.fullName]
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

    @Test(arguments: [false, true])
    func confirmedDiscardSurvivesDialogDismissal(untracked: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil,
                               indexStatus: untracked ? "?" : " ", workTreeStatus: untracked ? "?" : "M")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            discardHandler: { target in
                GitProcessResult(arguments: ["discard", target.path], output: "", standardOutput: "",
                                 standardError: "", exitCode: 0)
            }
        ))
        let feature = GitFeatureModel(service: service)
        var notifications: [String] = []
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { notifications.append($0) }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.clearGitConsole()
        feature.requestDiscardChange(change)
        let confirmed = try #require(feature.pendingDiscardChange)
        // SwiftUI dismisses the dialog before the button's asynchronous operation starts.
        feature.cancelDiscardChange()
        #expect(feature.gitConsoleEntries.isEmpty)
        await feature.confirmDiscardChange(confirmed)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["discard", "target.txt"]])
        #expect(notifications == ["Discarded target.txt"])
        #expect(feature.pendingDiscardChange == nil)
        #expect(feature.gitChanges.isEmpty)
    }

    @Test
    func confirmedDiscardHunkSurvivesDialogDismissalAndReportsFailure() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let hunk = DiffHunk(id: "h1", header: "@@ -1 +1 @@", patch: "confirmed patch")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            applyPatchHandler: { patch, _, mode in
                GitProcessResult(arguments: [mode, patch], output: "Patch no longer applies",
                                 standardOutput: "", standardError: "Patch no longer applies", exitCode: 1)
            }
        ))
        let feature = GitFeatureModel(service: service)
        var notifications: [String] = []
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { notifications.append($0) }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.clearGitConsole()
        feature.requestDiscardHunk(hunk, in: change)
        let confirmed = try #require(feature.pendingDiscardHunk)
        feature.cancelDiscardHunk()
        #expect(feature.gitConsoleEntries.isEmpty)
        await feature.confirmDiscardHunk(confirmed)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["discard", "confirmed patch"]])
        #expect(notifications == ["Patch no longer applies"])
        #expect(feature.pendingDiscardHunk == nil)
        #expect(feature.gitChanges == [change])
    }

    // MARK: Tag management

    @Test
    func gitTagDeletionCapabilityRequiresACommitTarget() {
        let commitTag = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            peelsToCommit: true,
            isCurrent: false,
            upstreamShortName: nil
        )
        let treeTag = GitReference(
            fullName: "refs/tags/tree-tag",
            shortName: "tree-tag",
            kind: .tag,
            peelsToCommit: false,
            isCurrent: false,
            upstreamShortName: nil
        )

        #expect(commitTag.supportsTagDeletion)
        #expect(!treeTag.supportsTagDeletion)
    }

    private func makeTagTestFeature(
        _ operations: TestGitOperations,
        onNotify: @escaping @MainActor (String) -> Void = { _ in }
    ) -> (GitFeatureModel, URL) {
        let root = URL(fileURLWithPath: "/workspace")
        let service = GitService(operations: operations)
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: onNotify,
            onStateRefreshed: {}
        )
        return (feature, root)
    }

    private func makeTagCommit() -> GitCommit {
        GitCommit(
            hash: "abc123def456",
            shortHash: "abc123d",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026/08/30 10:00",
            subject: "Initial",
            decorations: ""
        )
    }

    @Test
    func gitTagNameValidationMatchesTheSharedContractFixture() throws {
        struct TagNames: Decodable {
            let valid: [String]
            let invalid: [String]
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LitheGitModuleTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("shared/fixtures/git/tag-names.json")
        let fixture = try JSONDecoder().decode(TagNames.self, from: Data(contentsOf: fixtureURL))

        for name in fixture.valid {
            #expect(GitTagNameValidator.isValid(name), "expected valid tag name: \(name)")
        }
        for name in fixture.invalid {
            #expect(!GitTagNameValidator.isValid(name), "expected invalid tag name: \(name)")
        }
    }

    @Test
    func gitTagDeletionRequiresKindAndMessageToDescribeTheSameTagForm() {
        #expect(GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .lightweight,
            message: nil
        ).hasConsistentKindAndMessage)
        #expect(GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .annotated,
            message: ""
        ).hasConsistentKindAndMessage)
        #expect(!GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .lightweight,
            message: "release"
        ).hasConsistentKindAndMessage)
        #expect(!GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .annotated,
            message: nil
        ).hasConsistentKindAndMessage)
    }

    @Test
    func gitTagCreationSucceedsSilentlyForTheDialogAndNotifiesOnSuccess() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(arguments: ["tag", "v1.0", "abc123def456"], output: "", exitCode: 0)
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        // An empty result would mean the dialog shows a generic failure, so a
        // successful create must return nil and notify instead.
        let error = await feature.createTag(at: makeTagCommit(), name: "v1.0", message: "")

        #expect(error == nil)
        #expect(notifications == ["Created tag v1.0"])
    }

    @Test
    func gitTagCreationReturnsTheFailureToTheDialogWithoutNotifying() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: [])
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        let error = await feature.createTag(at: makeTagCommit(), name: "v1.0", message: "")

        #expect(error == "Rust Core Git operation failed")
        #expect(notifications.isEmpty)
    }

    @Test
    func gitTagDeletionKeepsARestorableSessionRecord() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .annotated,
                        message: "release"
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)

        #expect(feature.recentlyDeletedTag == GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .annotated,
            message: "release"
        ))
        #expect(notifications == ["Deleted tag v1.0"])

        feature.dismissDeletedTagBanner()
        #expect(feature.recentlyDeletedTag == nil)
    }

    @Test
    func gitTagDeletionFailureRecordsNothingAndNotifiesTheError() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "The tag 'v1.0' does not exist",
                    exitCode: 1
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)

        #expect(feature.recentlyDeletedTag == nil)
        #expect(notifications == ["The tag 'v1.0' does not exist"])
    }

    @Test
    func gitTagDeletionFailureKeepsThePreviousRecoveryRecord() async {
        var notifications: [String] = []
        let results = GitProcessResultQueue([
            GitProcessResult(
                arguments: ["tag", "-d", "v1.0"],
                output: "Deleted tag 'v1.0'\n",
                exitCode: 0,
                tagDeletion: GitTagDeletion(
                    name: "v1.0",
                    deletedTarget: "abc123def456",
                    kind: .lightweight,
                    message: nil
                )
            ),
            GitProcessResult(
                arguments: ["tag", "-d", "missing"],
                output: "The tag 'missing' does not exist",
                exitCode: 1
            )
        ])
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResults: results
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        for name in ["v1.0", "missing"] {
            await feature.deleteTag(GitReference(
                fullName: "refs/tags/\(name)",
                shortName: name,
                kind: .tag,
                isCurrent: false,
                upstreamShortName: nil
            ))
        }

        #expect(feature.recentlyDeletedTag?.name == "v1.0")
        #expect(notifications == ["Deleted tag v1.0", "The tag 'missing' does not exist"])
    }

    @Test
    func gitTagRestoreReplaysRecordedNameTargetAndMessage() async {
        var notifications: [String] = []
        let recorder = TagCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(arguments: ["tag", "-a", "v1.0", "-m", "release", "abc123def456"], output: "", exitCode: 0),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .annotated,
                        message: "release"
                    )
                ),
                tagCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        await feature.restoreRecentlyDeletedTag()

        // Exactly one delete and one restore create must have run, and the
        // restore must replay exactly the recorded deletion record so the
        // rebuilt annotated tag points at the original commit with its
        // message. The delete itself records no revision.
        #expect(recorder.recorded.count == 2)
        #expect(recorder.recorded.first?.name == "v1.0")
        #expect(recorder.recorded.last == TagCallRecorder.Call(
            name: "v1.0",
            revision: "abc123def456",
            message: "release"
        ))
        #expect(feature.recentlyDeletedTag == nil)
        #expect(notifications == ["Deleted tag v1.0", "Restored tag v1.0"])
    }

    @Test
    func gitTagRestoreFailureKeepsTheRecordForARetry() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(
                    arguments: ["tag", "v1.0", "abc123def456"],
                    output: "A tag named 'v1.0' already exists",
                    exitCode: 1
                ),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .lightweight,
                        message: nil
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        await feature.restoreRecentlyDeletedTag()

        // The user can retry after fixing the conflict, or close the banner.
        #expect(feature.recentlyDeletedTag?.name == "v1.0")
        #expect(notifications == ["Deleted tag v1.0", "A tag named 'v1.0' already exists"])
    }

    @Test
    func gitTagRestoreRejectsAnInconsistentRecoveryRecord() async {
        var notifications: [String] = []
        let recorder = TagCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(arguments: ["tag", "v1.0"], output: "", exitCode: 0),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .lightweight,
                        message: "unexpected annotation"
                    )
                ),
                tagCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        await feature.restoreRecentlyDeletedTag()

        #expect(feature.recentlyDeletedTag == nil)
        #expect(recorder.recorded.count == 1, "invalid recovery data must not issue createTag")
        #expect(notifications == ["Deleted tag v1.0", "The deleted tag recovery record is invalid"])
    }

    @Test
    func gitFeatureModelResetClearsTheRestorableTagRecord() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .lightweight,
                        message: nil
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        #expect(feature.recentlyDeletedTag != nil)

        // Project close resets the model; the deletion record must not survive
        // into the next session.
        feature.reset()
        #expect(feature.recentlyDeletedTag == nil)
    }

    // MARK: Branch deletion restore

    @Test
    func gitBranchDeletionKeepsARestorableSessionRecord() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteBranchResult: GitProcessResult(
                    arguments: ["branch", "-d", "--", "feature/short-lived"],
                    output: "Deleted branch feature/short-lived\n",
                    exitCode: 0,
                    branchDeletion: GitBranchDeletion(
                        name: "feature/short-lived",
                        deletedTarget: "abc123def456"
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/heads/feature/short-lived",
            shortName: "feature/short-lived",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteBranch(reference)

        #expect(feature.recentlyDeletedBranch == GitBranchDeletion(
            name: "feature/short-lived",
            deletedTarget: "abc123def456"
        ))
        #expect(notifications == ["Deleted branch feature/short-lived"])

        feature.dismissDeletedBranchBanner()
        #expect(feature.recentlyDeletedBranch == nil)
    }

    @Test
    func gitBranchConfigCleanupFailureKeepsTheRestorableDeletionRecord() async {
        var notifications: [String] = []
        let warning = "Could not remove configuration for deleted branch 'feature/short-lived'"
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteBranchResult: GitProcessResult(
                    arguments: ["update-ref", "-d", "refs/heads/feature/short-lived"],
                    output: "",
                    exitCode: 0,
                    branchDeletion: GitBranchDeletion(
                        name: "feature/short-lived",
                        deletedTarget: "abc123def456"
                    ),
                    warnings: [GitOperationWarning(
                        code: "branch_config_cleanup_failed",
                        message: warning
                    )]
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/heads/feature/short-lived",
            shortName: "feature/short-lived",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteBranch(reference)

        #expect(feature.recentlyDeletedBranch == GitBranchDeletion(
            name: "feature/short-lived",
            deletedTarget: "abc123def456"
        ))
        #expect(notifications == ["Deleted branch feature/short-lived: \(warning)"])
    }

    @Test
    func gitBranchDeletionFailureKeepsThePreviousRecoveryRecord() async {
        var notifications: [String] = []
        let results = GitProcessResultQueue([
            GitProcessResult(
                arguments: ["branch", "-d", "--", "feature/a"],
                output: "Deleted branch feature/a\n",
                exitCode: 0,
                branchDeletion: GitBranchDeletion(name: "feature/a", deletedTarget: "abc123def456")
            ),
            GitProcessResult(
                arguments: ["branch", "-d", "--", "feature/b"],
                output: "The branch 'feature/b' does not exist",
                exitCode: 1
            )
        ])
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteBranchResults: results
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        await feature.deleteBranch(GitReference(
            fullName: "refs/heads/feature/a",
            shortName: "feature/a",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        ))
        #expect(feature.recentlyDeletedBranch?.name == "feature/a")

        await feature.deleteBranch(GitReference(
            fullName: "refs/heads/feature/b",
            shortName: "feature/b",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        ))

        #expect(feature.recentlyDeletedBranch?.name == "feature/a")
        #expect(notifications == ["Deleted branch feature/a", "The branch 'feature/b' does not exist"])
    }

    @Test
    func gitTagAndBranchRecoveryRecordsCanCoexist() async {
        let (feature, _) = makeTagTestFeature(TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
            deleteTagResult: GitProcessResult(
                arguments: ["tag", "-d", "v1.0"],
                output: "Deleted tag 'v1.0'\n",
                exitCode: 0,
                tagDeletion: GitTagDeletion(
                    name: "v1.0",
                    deletedTarget: "abc123def456",
                    kind: .lightweight,
                    message: nil
                )
            ),
            deleteBranchResult: GitProcessResult(
                arguments: ["branch", "-d", "--", "feature/a"],
                output: "Deleted branch feature/a\n",
                exitCode: 0,
                branchDeletion: GitBranchDeletion(name: "feature/a", deletedTarget: "abc123def456")
            )
        ))
        await feature.refreshGit()

        await feature.deleteTag(GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        ))
        await feature.deleteBranch(GitReference(
            fullName: "refs/heads/feature/a",
            shortName: "feature/a",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        ))

        #expect(feature.recentlyDeletedTag?.name == "v1.0")
        #expect(feature.recentlyDeletedBranch?.name == "feature/a")
    }

    @Test
    func gitBranchRestoreReplaysRecordedNameAndTarget() async {
        var notifications: [String] = []
        let recorder = BranchCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createBranchResult: GitProcessResult(arguments: ["branch", "feature/short-lived", "abc123def456"], output: "", exitCode: 0),
                deleteBranchResult: GitProcessResult(
                    arguments: ["branch", "-d", "--", "feature/short-lived"],
                    output: "Deleted branch feature/short-lived\n",
                    exitCode: 0,
                    branchDeletion: GitBranchDeletion(
                        name: "feature/short-lived",
                        deletedTarget: "abc123def456"
                    )
                ),
                branchCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/heads/feature/short-lived",
            shortName: "feature/short-lived",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteBranch(reference)
        await feature.restoreRecentlyDeletedBranch()

        // The restore replays createBranch against the recorded commit without
        // checking the branch out.
        #expect(Array(recorder.recorded.suffix(1)) == [
            BranchCallRecorder.Call(name: "feature/short-lived", reference: "abc123def456", checkout: false)
        ])
        #expect(feature.recentlyDeletedBranch == nil)
        #expect(notifications == ["Deleted branch feature/short-lived", "Restored branch feature/short-lived"])

        // Project close drops the restorable record as well.
        feature.reset()
        #expect(feature.recentlyDeletedBranch == nil)
    }

    @Test
    func gitServicePreservesExecutedArgumentsAndWorkingDirectory() async {        let root = URL(fileURLWithPath: "/workspace")
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
                exitCode: 0,
                warnings: [
                    GitOperationWarning(
                        code: "git_follow_up_failed",
                        message: "The main operation succeeded",
                        details: "follow-up diagnostic"
                    )
                ]
            )
        ))

        let result = await service.stage(change)

        #expect(result.workingDirectory == root)
        #expect(result.arguments == ["add", "--", "README.md"])
        #expect(result.output == "staged")
        #expect(result.succeeded)
        #expect(result.warnings == [
            GitOperationWarning(
                code: "git_follow_up_failed",
                message: "The main operation succeeded",
                details: "follow-up diagnostic"
            )
        ])
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
    func commitSelectionLoadsFilesWithoutSelectingTheFirstFile() async throws {
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
        #expect(feature.selectedGitCommitFilesLoadState == .ready)
        #expect(feature.selectedGitCommitFile == nil)

        feature.previewGitCommitSelection(nextCommit)

        #expect(feature.selectedGitCommit == nextCommit)
        #expect(feature.selectedGitCommitFiles.isEmpty)
        #expect(feature.selectedGitCommitFilesLoadState == .loading)
        #expect(feature.selectedGitCommitFile == nil)
        #expect(feature.selectedGitCommitDiffContext == nil)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func failedCommitFileReadIsNotCachedAndRetryRecovers() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = makeTestCommit(hash: "1111111111111111", subject: "Retry commit")
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let filesGate = GitFilesLoadGate(results: [nil, files])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesGate: filesGate
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        feature.previewGitCommitSelection(commit)
        #expect(feature.selectedGitCommitFilesLoadState == .loading)

        let failedLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: commit)
        }
        defer { failedLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(0))
        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        try #require(await waitForGitTaskCompletion(failedLoad))

        #expect(feature.selectedGitCommitFiles.isEmpty)
        #expect(feature.selectedGitCommitFilesLoadState == .failed)

        let retryLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: commit)
        }
        defer { retryLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(1))
        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        try #require(await waitForGitTaskCompletion(retryLoad))

        #expect(!filesGate.didTimeOut)
        #expect(filesGate.callHashes == [commit.hash, commit.hash])
        #expect(feature.selectedGitCommitFiles == files)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func repeatedCommitSelectionReusesCachedFilesAndResetInvalidatesCache() async throws {
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
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func selectedAndQueryDemandCoalescesWhilePrefetchRemainsBounded() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let blocker = makeTestCommit(hash: "1111111111111111", subject: "Blocker")
        let shared = makeTestCommit(hash: "2222222222222222", subject: "Shared demand")
        let trailing = makeTestCommit(hash: "3333333333333333", subject: "Trailing prefetch")
        let blockerFiles = [GitCommitFile(status: "M", path: "blocker.txt")]
        let sharedFiles = [GitCommitFile(status: "A", path: "shared.txt")]
        let trailingFiles = [GitCommitFile(status: "D", path: "trailing.txt")]
        let filesGate = GitFilesLoadGate(results: [blockerFiles, sharedFiles, trailingFiles])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            filesGate: filesGate
        ))
        let loader = GitCommitFilesLoader(service: service)

        loader.replacePrefetchCandidates([blocker, shared], at: root)
        try #require(await filesGate.waitUntilCallStarts(0))

        let queryLoad = Task { @MainActor in
            await loader.loadQueryFiles(for: shared, at: root)
        }
        defer { queryLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(1))

        let selectedLoad = loader.requestSelectedFiles(for: shared, at: root)
        defer { selectedLoad.cancel() }
        loader.replacePrefetchCandidates([trailing], at: root)

        #expect(filesGate.callHashes == [blocker.hash, shared.hash])
        #expect(filesGate.maximumConcurrentCalls == 2)

        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        let queryOutcome = try #require(await waitForGitCommitFilesOutcome(queryLoad))
        let selectedOutcome = try #require(await waitForGitCommitFilesOutcome(selectedLoad))
        #expect(queryOutcome == .ready(sharedFiles))
        #expect(selectedOutcome == .ready(sharedFiles))

        // The active speculative read keeps the next prefetch queued, so the
        // loader never spends both physical slots on cache warming.
        #expect(filesGate.callCount == 2)
        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        try #require(await filesGate.waitUntilCallStarts(2))
        #expect(filesGate.callHashes == [blocker.hash, shared.hash, trailing.hash])
        #expect(filesGate.maximumConcurrentCalls == 2)
        filesGate.releaseCall(2)
        try #require(await filesGate.waitUntilCallFinishes(2))

        #expect(!filesGate.didTimeOut)
        #expect(filesGate.callCount == 3)
        #expect(loader.cachedFiles(for: shared, at: root) == sharedFiles)
        try #require(await waitForGitWorkToBecomeIdle {
            loader.hasActiveWork
        })
    }

    @Test
    func latestSelectionStartsBeforeBlockedPreviousSelectionFinishes() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let previous = makeTestCommit(hash: "1111111111111111", subject: "Previous")
        let latest = makeTestCommit(hash: "2222222222222222", subject: "Latest")
        let previousFiles = [GitCommitFile(status: "M", path: "previous.txt")]
        let latestFiles = [GitCommitFile(status: "A", path: "latest.txt")]
        let filesGate = GitFilesLoadGate(results: [previousFiles, latestFiles])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesGate: filesGate
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        feature.previewGitCommitSelection(previous)
        let previousLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: previous)
        }
        defer { previousLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(0))

        feature.previewGitCommitSelection(latest)
        let latestLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: latest)
        }
        defer { latestLoad.cancel() }

        // The second selection must consume the free physical slot instead of
        // waiting for the stale synchronous read to return.
        try #require(await filesGate.waitUntilCallStarts(1))
        #expect(filesGate.callHashes == [previous.hash, latest.hash])
        #expect(filesGate.maximumConcurrentCalls == 2)

        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        try #require(await waitForGitTaskCompletion(latestLoad))
        #expect(feature.selectedGitCommit == latest)
        #expect(feature.selectedGitCommitFiles == latestFiles)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)

        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        try #require(await waitForGitTaskCompletion(previousLoad))
        #expect(feature.selectedGitCommit == latest)
        #expect(feature.selectedGitCommitFiles == latestFiles)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)
        #expect(!filesGate.didTimeOut)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func resetSupersedesStaleGenerationAndRetriesWithinPhysicalLimit() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = makeTestCommit(hash: "1111111111111111", subject: "Reset commit")
        let staleFiles = [GitCommitFile(status: "M", path: "stale.txt")]
        let replacementFiles = [GitCommitFile(status: "A", path: "replacement.txt")]
        let filesGate = GitFilesLoadGate(results: [staleFiles, replacementFiles])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            filesGate: filesGate
        ))
        let loader = GitCommitFilesLoader(service: service)

        let staleLoad = loader.requestSelectedFiles(for: commit, at: root)
        defer { staleLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(0))

        loader.reset()
        let replacementLoad = loader.requestSelectedFiles(for: commit, at: root)
        defer { replacementLoad.cancel() }

        let staleOutcome = try #require(await waitForGitCommitFilesOutcome(staleLoad))
        #expect(staleOutcome == .superseded)
        try #require(await filesGate.waitUntilCallStarts(1))
        #expect(filesGate.maximumConcurrentCalls == 2)

        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        let replacementOutcome = try #require(await waitForGitCommitFilesOutcome(replacementLoad))
        #expect(replacementOutcome == .ready(replacementFiles))

        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        #expect(!filesGate.didTimeOut)
        #expect(filesGate.callHashes == [commit.hash, commit.hash])
        #expect(loader.cachedFiles(for: commit, at: root) == replacementFiles)
        try #require(await waitForGitWorkToBecomeIdle {
            loader.hasActiveWork
        })
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
    func switchingRepositoriesDiscardsStaleInitialGitConsoleOutput() async throws {
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
        let initialLoad = Task { @MainActor in await feature.loadGitConsoleIfNeeded() }
        defer {
            initialLoad.cancel()
            runGate.releaseFirstRun()
        }
        try #require(await runGate.waitUntilFirstRunStarts())
        workspaceURL = secondRoot
        await feature.refreshGit()
        runGate.releaseFirstRun()
        try #require(await waitForGitTaskCompletion(initialLoad))
        #expect(!runGate.didTimeOut)

        #expect(feature.gitConsoleEntries.isEmpty)

        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.first?.workingDirectory == secondRoot)
    }

    @Test
    func worktreeInspectionPublishesHistoryBeforeStatusScanFinishes() async throws {
        let worktree = makeTestWorktree(path: "/workspace-feature", branch: "feature/history")
        let change = GitChange(
            repositoryRoot: URL(fileURLWithPath: worktree.path),
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let commit = makeTestCommit(hash: "history-commit", subject: "Show history first")
        let snapshotGate = GitModuleTestGate()
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(
                repositoryRoot: URL(fileURLWithPath: worktree.path),
                branch: "feature/history",
                changes: [change]
            ),
            historyValue: GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [commit],
                hasMore: false
            ),
            snapshotGate: snapshotGate
        ))
        let feature = GitFeatureModel(service: service)
        let inspectionTask = Task { @MainActor in
            await feature.inspectWorktree(worktree)
        }
        defer {
            inspectionTask.cancel()
            snapshotGate.open()
        }

        let partialInspection = await waitForGitWorktreeInspection(feature)
        try #require(partialInspection != nil)
        #expect(partialInspection?.commits == [commit])
        #expect(partialInspection?.hasLoadedChanges == false)
        #expect(partialInspection?.changes.isEmpty == true)

        snapshotGate.open()
        try #require(await waitForGitTaskCompletion(inspectionTask))
        #expect(feature.gitWorktreeInspection?.changes == [change])
        #expect(feature.gitWorktreeInspection?.hasLoadedChanges == true)
    }

    @Test
    func staleWorktreeInspectionCannotClearNewLoadingState() async throws {
        let oldWorktree = makeTestWorktree(path: "/workspace-old", branch: "feature/old")
        let newWorktree = makeTestWorktree(path: "/workspace-new", branch: "feature/new")
        let controller = GitHistoryLoadController(results: [
            GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [makeTestCommit(hash: "old-history", subject: "Old")],
                hasMore: false
            ),
            GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [makeTestCommit(hash: "new-history", subject: "New")],
                hasMore: false
            )
        ])
        let feature = GitFeatureModel(service: GitService(
            operations: TestGitOperations(historyController: controller)
        ))
        let oldInspection = Task { @MainActor in
            await feature.inspectWorktree(oldWorktree)
        }
        defer {
            oldInspection.cancel()
            controller.releaseAll()
        }

        try #require(await controller.waitUntilCallStarts(0))
        let newInspection = Task { @MainActor in
            await feature.inspectWorktree(newWorktree)
        }
        defer { newInspection.cancel() }
        try #require(await controller.waitUntilCallStarts(1))
        #expect(feature.gitWorktreeInspectionLoadState == .loading)

        controller.releaseCall(0)
        try #require(await waitForGitTaskCompletion(oldInspection))
        #expect(feature.gitWorktreeInspectionLoadState == .loading)

        controller.releaseCall(1)
        try #require(await waitForGitTaskCompletion(newInspection))
        #expect(feature.gitWorktreeInspectionLoadState == .ready)
        #expect(feature.gitWorktreeInspection?.worktreeID == newWorktree.id)
        #expect(!controller.didTimeOut)
    }

    @Test
    func newerWorktreeRefreshWinsWhenAnOlderRequestFinishesLast() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let oldWorktree = makeTestWorktree(path: "/workspace-old", branch: "feature/old")
        let newWorktree = makeTestWorktree(path: "/workspace-new", branch: "feature/new")
        let loader = GitWorktreeLoadController(results: [[oldWorktree], [newWorktree]])
        let feature = GitFeatureModel(
            service: GitService(operations: TestGitOperations()),
            snapshotProvider: { root in
                GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
            },
            worktreesProvider: { root in await loader.load(root) }
        )
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )
        await feature.refreshGit()

        let firstRefresh = Task { @MainActor in await feature.refreshWorktrees() }
        try #require(await loader.waitUntilCallStarts(0))
        let secondRefresh = Task { @MainActor in await feature.refreshWorktrees() }
        defer {
            firstRefresh.cancel()
            secondRefresh.cancel()
            loader.releaseAll()
        }
        try #require(await loader.waitUntilCallStarts(1))
        loader.releaseCall(1)
        try #require(await waitForGitTaskCompletion(secondRefresh))
        loader.releaseCall(0)
        try #require(await waitForGitTaskCompletion(firstRefresh))

        #expect(!loader.didTimeOut)
        #expect(feature.gitWorktreeLoadState == .ready)
        #expect(feature.gitWorktrees == [newWorktree])
    }

    @Test
    func successfulWorktreeRemovalResetsItsLogScopeAndRefreshesGitState() async {
        let root = URL(fileURLWithPath: "/workspace")
        let removedWorktree = makeTestWorktree(path: "/workspace-maim", branch: "maim")
        let remainingWorktree = GitWorktree(
            path: root.path,
            head: "2222222222222222222222222222222222222222",
            branch: "refs/heads/preview",
            isCurrent: true,
            isPrimary: true,
            isBare: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            pruneReason: nil
        )
        let preview = GitReference(
            fullName: "refs/heads/preview",
            shortName: "preview",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let maim = GitReference(
            fullName: "refs/heads/maim",
            shortName: "maim",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )
        let currentCommit = makeTestCommit(
            hash: "2222222222222222",
            subject: "Current checkout history"
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "preview", changes: []),
            referencesValue: GitReferenceSnapshot(
                references: [preview, maim],
                recentReferences: [preview, maim]
            ),
            historyPageValues: [
                "": GitHistoryPage(
                    commits: [currentCommit],
                    nextCursor: nil,
                    hasMore: false
                )
            ],
            removeWorktreeResult: GitProcessResult(
                arguments: ["worktree", "remove", "--", removedWorktree.path],
                output: "",
                exitCode: 0
            )
        ))
        let feature = GitFeatureModel(
            service: service,
            worktreesProvider: { _ in [remainingWorktree] }
        )
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )
        await feature.refreshGit()
        feature.selectedGitReference = maim

        await feature.removeWorktree(removedWorktree, force: false)

        #expect(feature.selectedGitReference == nil)
        #expect(!feature.isShowingAllGitReferences)
        #expect(feature.gitWorktrees == [remainingWorktree])
        #expect(feature.gitReferences == [preview, maim])
        #expect(feature.gitCommits == [currentCommit])
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
            typedComparisonValue: payload
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
    private let firstRunStarted = GitModuleTestGate()
    private let firstRunRelease = GitModuleTestGate()
    private var hasBlockedFirstRun = false
    private var didTimeOutValue = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOutValue
    }

    func blockFirstRun() {
        lock.lock()
        let shouldBlock = !hasBlockedFirstRun
        hasBlockedFirstRun = true
        lock.unlock()
        guard shouldBlock else { return }
        firstRunStarted.open()
        guard firstRunRelease.waitSynchronously() else {
            lock.lock()
            didTimeOutValue = true
            lock.unlock()
            return
        }
    }

    func waitUntilFirstRunStarts() async -> Bool {
        await firstRunStarted.waitUntilOpen()
    }

    func releaseFirstRun() {
        firstRunRelease.open()
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

private func makeTestCommit(hash: String, subject: String) -> GitCommit {
    GitCommit(
        hash: hash,
        shortHash: String(hash.prefix(7)),
        parentHashes: [],
        authorName: "Test Author",
        authorEmail: "author@example.com",
        date: "2026-08-28T16:00:00+08:00",
        subject: subject,
        decorations: ""
    )
}

private final class GitHistoryMutationController: @unchecked Sendable {
    private let lock = NSLock()
    private let before: [GitCommit]
    private let after: [GitCommit]
    private var didMutate = false
    private var historyCalls = 0
    private var revertedHashValues: [String] = []

    init(before: [GitCommit], after: [GitCommit]) {
        self.before = before
        self.after = after
    }

    var historyCallCount: Int {
        lock.withLock { historyCalls }
    }

    var revertedHashes: [String] {
        lock.withLock { revertedHashValues }
    }

    func historyPage() -> GitHistoryPage {
        lock.withLock {
            historyCalls += 1
            return GitHistoryPage(
                commits: didMutate ? after : before,
                nextCursor: nil,
                hasMore: false
            )
        }
    }

    func revert(_ hash: String) -> GitProcessResult {
        lock.withLock {
            revertedHashValues.append(hash)
            didMutate = true
        }
        return GitProcessResult(arguments: ["revert", hash], output: "", exitCode: 0)
    }
}

private func makeTestWorktree(path: String, branch: String) -> GitWorktree {
    GitWorktree(
        path: path,
        head: "1111111111111111111111111111111111111111",
        branch: "refs/heads/\(branch)",
        isCurrent: false,
        isPrimary: false,
        isBare: false,
        isDetached: false,
        isLocked: false,
        lockReason: nil,
        isPrunable: false,
        pruneReason: nil
    )
}

private final class GitModuleTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var asyncWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func open() {
        condition.lock()
        isOpen = true
        let waiters = Array(asyncWaiters.values)
        let tasks = Array(timeoutTasks.values)
        asyncWaiters.removeAll()
        timeoutTasks.removeAll()
        condition.broadcast()
        condition.unlock()
        tasks.forEach { $0.cancel() }
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitSynchronously(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isOpen {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func waitUntilOpen(timeout: Duration = .seconds(2)) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                guard !isOpen else {
                    condition.unlock()
                    continuation.resume(returning: true)
                    return
                }
                asyncWaiters[waiterID] = continuation
                condition.unlock()

                let timeoutTask = Task { [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog bounds a failed event-driven Git test without controlling successful execution order.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishAsyncWaiter(waiterID, result: false)
                }
                condition.lock()
                if asyncWaiters[waiterID] == nil {
                    condition.unlock()
                    timeoutTask.cancel()
                } else {
                    timeoutTasks[waiterID] = timeoutTask
                    condition.unlock()
                }
                if Task.isCancelled {
                    finishAsyncWaiter(waiterID, result: false)
                }
            }
        } onCancel: {
            finishAsyncWaiter(waiterID, result: false)
        }
    }

    private func finishAsyncWaiter(_ waiterID: UUID, result: Bool) {
        condition.lock()
        let waiter = asyncWaiters.removeValue(forKey: waiterID)
        let timeoutTask = timeoutTasks.removeValue(forKey: waiterID)
        condition.unlock()
        timeoutTask?.cancel()
        waiter?.resume(returning: result)
    }
}

private final class GitHistoryLoadController: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [GitHistorySnapshot]
    private let startedGates: [GitModuleTestGate]
    private let releaseGates: [GitModuleTestGate]
    private var calls = 0
    private var timedOut = false

    init(results: [GitHistorySnapshot]) {
        self.results = results
        startedGates = results.map { _ in GitModuleTestGate() }
        releaseGates = results.map { _ in GitModuleTestGate() }
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? {
        let callIndex: Int
        lock.lock()
        callIndex = calls
        calls += 1
        lock.unlock()
        guard results.indices.contains(callIndex) else { return nil }
        startedGates[callIndex].open()
        guard releaseGates[callIndex].waitSynchronously() else {
            lock.lock()
            timedOut = true
            lock.unlock()
            return nil
        }
        return results[callIndex]
    }

    func waitUntilCallStarts(_ index: Int) async -> Bool {
        guard startedGates.indices.contains(index) else { return false }
        return await startedGates[index].waitUntilOpen()
    }

    func releaseCall(_ index: Int) {
        guard releaseGates.indices.contains(index) else { return }
        releaseGates[index].open()
    }

    func releaseAll() {
        releaseGates.forEach { $0.open() }
    }
}

private final class GitWorktreeLoadController: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [[GitWorktree]?]
    private let startedGates: [GitModuleTestGate]
    private let releaseGates: [GitModuleTestGate]
    private var calls = 0
    private var timedOut = false

    init(results: [[GitWorktree]?]) {
        self.results = results
        startedGates = results.map { _ in GitModuleTestGate() }
        releaseGates = results.map { _ in GitModuleTestGate() }
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func load(_ root: URL) async -> [GitWorktree]? {
        let callIndex = reserveCall()
        guard results.indices.contains(callIndex) else { return nil }
        startedGates[callIndex].open()
        guard await releaseGates[callIndex].waitUntilOpen() else {
            recordTimeout()
            return nil
        }
        return results[callIndex]
    }

    func waitUntilCallStarts(_ index: Int) async -> Bool {
        guard startedGates.indices.contains(index) else { return false }
        return await startedGates[index].waitUntilOpen()
    }

    func releaseCall(_ index: Int) {
        guard releaseGates.indices.contains(index) else { return }
        releaseGates[index].open()
    }

    func releaseAll() {
        releaseGates.forEach { $0.open() }
    }

    private func reserveCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let callIndex = calls
        calls += 1
        return callIndex
    }

    private func recordTimeout() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private final class GitFilesLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [[GitCommitFile]?]
    private let startedGates: [GitModuleTestGate]
    private let releaseGates: [GitModuleTestGate]
    private let finishedGates: [GitModuleTestGate]
    private var calls = 0
    private var activeCalls = 0
    private var peakConcurrentCalls = 0
    private var hashes: [String] = []
    private var timedOut = false

    init(results: [[GitCommitFile]?]) {
        self.results = results
        startedGates = results.map { _ in GitModuleTestGate() }
        releaseGates = results.map { _ in GitModuleTestGate() }
        finishedGates = results.map { _ in GitModuleTestGate() }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakConcurrentCalls
    }

    var callHashes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hashes
    }

    func loadFiles(for commit: GitCommit) -> [GitCommitFile]? {
        lock.lock()
        let callIndex = calls
        calls += 1
        activeCalls += 1
        peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
        hashes.append(commit.hash)
        lock.unlock()

        guard results.indices.contains(callIndex) else {
            finishCall(callIndex, timedOut: true)
            return nil
        }
        startedGates[callIndex].open()
        guard releaseGates[callIndex].waitSynchronously() else {
            finishCall(callIndex, timedOut: true)
            return nil
        }
        let result = results[callIndex]
        finishCall(callIndex, timedOut: false)
        return result
    }

    func waitUntilCallStarts(_ index: Int) async -> Bool {
        guard startedGates.indices.contains(index) else { return false }
        return await startedGates[index].waitUntilOpen()
    }

    func waitUntilCallFinishes(_ index: Int) async -> Bool {
        guard finishedGates.indices.contains(index) else { return false }
        return await finishedGates[index].waitUntilOpen()
    }

    func releaseCall(_ index: Int) {
        guard releaseGates.indices.contains(index) else { return }
        releaseGates[index].open()
    }

    func releaseAll() {
        releaseGates.forEach { $0.open() }
    }

    private func finishCall(_ index: Int, timedOut: Bool) {
        lock.lock()
        activeCalls = max(0, activeCalls - 1)
        self.timedOut = self.timedOut || timedOut
        lock.unlock()
        guard finishedGates.indices.contains(index) else { return }
        finishedGates[index].open()
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

private func waitForGitTaskCompletion(
    _ task: Task<Void, Never>,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for an event-driven Git task.
            try? await Task.sleep(for: timeout)
            task.cancel()
            return false
        }
        let completed = await group.next() ?? false
        if !completed {
            task.cancel()
        }
        group.cancelAll()
        return completed
    }
}

@MainActor
private func waitForGitWorktreeInspection(
    _ feature: GitFeatureModel,
    timeout: Duration = .seconds(2)
) async -> GitWorktreeInspection? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while feature.gitWorktreeInspection == nil, clock.now < deadline {
        await Task.yield()
    }
    return feature.gitWorktreeInspection
}

@MainActor
private func waitForGitWorkToBecomeIdle(
    timeout: Duration = .seconds(2),
    isActive: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while isActive(), clock.now < deadline {
        await Task.yield()
    }
    return !isActive()
}

private final class GitPerformanceLogRecorder: GitPerformanceLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }

    func record(_ message: String) {
        lock.lock()
        recordedMessages.append(message)
        lock.unlock()
    }
}

/// Records tag create/delete arguments so restore flows can be asserted on
/// the exact parameters the feature model replays.
private final class TagCallRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let revision: String
        let message: String?
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Records branch create/delete arguments for the branch restore flow.
private final class BranchCallRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let reference: String
        let checkout: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Supplies deterministic per-call results for consecutive Git mutations.
private final class GitProcessResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [GitProcessResult]

    init(_ results: [GitProcessResult]) {
        self.results = results
    }

    func next() -> GitProcessResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }
}

/// Controls the native synchronous operation boundary on GitService's worker
/// queue. The existing gate bounds failures and exposes an async start event.
private final class GitGraphHistoryProbe: @unchecked Sendable {
    let started = GitModuleTestGate()
    let release = GitModuleTestGate()
    private let lock = NSLock()
    private let blockGraph: Bool
    private let releaseOnCancel: Bool
    private var graphRequests = 0
    private var failed = false
    private var closed: [String] = []
    private var cancelled: [String] = []
    private var graphOperationID: String?
    private var allReferences = false
    private var timedOut = false

    init(blockGraph: Bool = false, releaseOnCancel: Bool = true) {
        self.blockGraph = blockGraph
        self.releaseOnCancel = releaseOnCancel
    }
    var closedCursors: [String] { lock.withLock { closed } }
    var requestedAllReferences: Bool { lock.withLock { allReferences } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    var graphWasCancelled: Bool { lock.withLock { graphOperationID.map(cancelled.contains) ?? false } }
    func failGraphRequest() { lock.withLock { failed = true } }
    func close(cursor: String) { lock.withLock { closed.append(cursor) } }
    func cancel(operationID: String) {
        lock.withLock { cancelled.append(operationID) }
        if releaseOnCancel { release.open() }
    }

    func page(reference: GitReference?, cursor: String?, limit: Int, operationID: String) -> GitHistoryPage? {
        if limit == 5_000 {
            let shouldBlock = lock.withLock {
                graphOperationID = operationID
                allReferences = reference == nil && cursor == nil
                graphRequests += 1
                return blockGraph && graphRequests == 1
            }
            started.open()
            if shouldBlock, !release.waitSynchronously() { lock.withLock { timedOut = true } }
            guard !lock.withLock({ failed }) else { return nil }
            return GitHistoryPage(commits: [makeTestCommit(hash: "other-branch", subject: "Other branch"),
                                           makeTestCommit(hash: "visible", subject: "Visible")],
                                  nextCursor: "graph-cursor", hasMore: true)
        }
        return GitHistoryPage(commits: [makeTestCommit(hash: cursor == nil ? "visible" : "older", subject: "Visible history")],
                              nextCursor: cursor == nil ? "visible-cursor" : nil, hasMore: cursor == nil)
    }
}

private struct TestGitOperations: GitOperations {
    private let snapshotValue: GitSnapshot?
    private let snapshotsByRoot: [String: GitSnapshot]
    private let repositoryRoots: [URL]?
    private let comparisonValue: GitBranchComparison?
    private let typedComparisonValue: GitBranchComparison?
    private let filesValue: [GitCommitFile]?
    private let untrackedDiffDocumentValue: DiffDocument?
    private let comparisonDiffDocumentValue: DiffDocument?
    private let typedComparisonDiffDocumentValue: DiffDocument?
    private let historyValue: GitHistorySnapshot?
    private let referencesValue: GitReferenceSnapshot?
    private let historyPageValues: [String: GitHistoryPage]?
    private let historyPageHandler: (@Sendable () -> GitHistoryPage?)?
    private let graphHistoryProbe: GitGraphHistoryProbe?
    private let historyController: GitHistoryLoadController?
    private let snapshotGate: GitModuleTestGate?
    private let discardHandler: (@Sendable (GitChange) -> GitProcessResult?)?
    private let applyPatchHandler: (@Sendable (String, URL, String) -> GitProcessResult?)?
    private let stageResult: GitProcessResult?
    private let commitResult: GitProcessResult?
    private let revertHandler: (@Sendable (String) -> GitProcessResult?)?
    private let runGate: TestGitRunGate?
    private let filesRecorder: GitFilesCallRecorder?
    private let filesGate: GitFilesLoadGate?
    private let createTagResult: GitProcessResult?
    private let deleteTagResult: GitProcessResult?
    private let deleteTagResults: GitProcessResultQueue?
    private let tagCallRecorder: TagCallRecorder?
    private let createBranchResult: GitProcessResult?
    private let deleteBranchResult: GitProcessResult?
    private let deleteBranchResults: GitProcessResultQueue?
    private let branchCallRecorder: BranchCallRecorder?
    private let exportPatchHandler: (@Sendable ([String], Bool) -> Result<GitPatchExport, GitPatchFailure>)?
    private let removeWorktreeResult: GitProcessResult?
    private let fetchPlanValue: GitFetchPlan?
    private let fetchHandler: (@Sendable (GitFetchOptions, String) -> GitProcessResult?)?

    init(
        snapshotValue: GitSnapshot? = nil,
        snapshotsByRoot: [String: GitSnapshot] = [:],
        repositoryRoots: [URL]? = nil,
        comparisonValue: GitBranchComparison? = nil,
        typedComparisonValue: GitBranchComparison? = nil,
        historyValue: GitHistorySnapshot? = nil,
        referencesValue: GitReferenceSnapshot? = nil,
        historyPageValues: [String: GitHistoryPage]? = nil,
        historyPageHandler: (@Sendable () -> GitHistoryPage?)? = nil,
        graphHistoryProbe: GitGraphHistoryProbe? = nil,
        historyController: GitHistoryLoadController? = nil,
        filesValue: [GitCommitFile]? = nil,
        untrackedDiffDocumentValue: DiffDocument? = nil,
        comparisonDiffDocumentValue: DiffDocument? = nil,
        typedComparisonDiffDocumentValue: DiffDocument? = nil,
        snapshotGate: GitModuleTestGate? = nil,
        discardHandler: (@Sendable (GitChange) -> GitProcessResult?)? = nil,
        applyPatchHandler: (@Sendable (String, URL, String) -> GitProcessResult?)? = nil,
        stageResult: GitProcessResult? = nil,
        commitResult: GitProcessResult? = nil,
        revertHandler: (@Sendable (String) -> GitProcessResult?)? = nil,
        runGate: TestGitRunGate? = nil,
        filesRecorder: GitFilesCallRecorder? = nil,
        filesGate: GitFilesLoadGate? = nil,
        createTagResult: GitProcessResult? = nil,
        deleteTagResult: GitProcessResult? = nil,
        deleteTagResults: GitProcessResultQueue? = nil,
        tagCallRecorder: TagCallRecorder? = nil,
        createBranchResult: GitProcessResult? = nil,
        deleteBranchResult: GitProcessResult? = nil,
        deleteBranchResults: GitProcessResultQueue? = nil,
        branchCallRecorder: BranchCallRecorder? = nil,
        exportPatchHandler: (@Sendable ([String], Bool) -> Result<GitPatchExport, GitPatchFailure>)? = nil,
        removeWorktreeResult: GitProcessResult? = nil,
        fetchPlan: GitFetchPlan? = nil,
        fetchHandler: (@Sendable (GitFetchOptions, String) -> GitProcessResult?)? = nil
    ) {
        self.snapshotValue = snapshotValue
        self.snapshotsByRoot = snapshotsByRoot
        self.repositoryRoots = repositoryRoots
        self.comparisonValue = comparisonValue
        self.typedComparisonValue = typedComparisonValue
        self.historyValue = historyValue
        self.referencesValue = referencesValue
        self.historyPageValues = historyPageValues
        self.historyPageHandler = historyPageHandler
        self.graphHistoryProbe = graphHistoryProbe
        self.historyController = historyController
        self.filesValue = filesValue
        self.untrackedDiffDocumentValue = untrackedDiffDocumentValue
        self.comparisonDiffDocumentValue = comparisonDiffDocumentValue
        self.typedComparisonDiffDocumentValue = typedComparisonDiffDocumentValue
        self.snapshotGate = snapshotGate
        self.discardHandler = discardHandler
        self.applyPatchHandler = applyPatchHandler
        self.stageResult = stageResult
        self.commitResult = commitResult
        self.revertHandler = revertHandler
        self.runGate = runGate
        self.filesRecorder = filesRecorder
        self.filesGate = filesGate
        self.createTagResult = createTagResult
        self.deleteTagResult = deleteTagResult
        self.deleteTagResults = deleteTagResults
        self.tagCallRecorder = tagCallRecorder
        self.createBranchResult = createBranchResult
        self.deleteBranchResult = deleteBranchResult
        self.deleteBranchResults = deleteBranchResults
        self.branchCallRecorder = branchCallRecorder
        self.exportPatchHandler = exportPatchHandler
        self.removeWorktreeResult = removeWorktreeResult
        self.fetchPlanValue = fetchPlan
        self.fetchHandler = fetchHandler
    }

    func exportPatch(at rootURL: URL, source: GitPatchSource, paths: [String], base: String?, target: String?, metadataOnly: Bool) -> Result<GitPatchExport, GitPatchFailure> {
        exportPatchHandler?(paths, metadataOnly) ?? .failure(GitPatchFailure("Patch export unavailable"))
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

    func snapshot(at rootURL: URL) -> GitSnapshot? {
        _ = snapshotGate?.waitSynchronously()
        if let snapshot = snapshotsByRoot[rootURL.standardizedFileURL.path] {
            return snapshot
        }
        return snapshotValue
    }
    func repositories(in workspaceURL: URL) -> [URL] {
        repositoryRoots ?? (snapshot(at: workspaceURL).map { [$0.repositoryRoot] } ?? [])
    }
    func watchContext(at rootURL: URL) -> GitWatchContext? { nil }
    func worktrees(at rootURL: URL) -> [GitWorktree]? { nil }
    func diffDocument(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> DiffDocument? {
        untracked ? untrackedDiffDocumentValue : nil
    }
    func diffPatch(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> String? { nil }
    func commitDiffDocument(at rootURL: URL, commit: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { comparisonDiffDocumentValue }
    func comparisonDiffDocument(at rootURL: URL, reference: GitReference, targetReference: GitReference?, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { typedComparisonDiffDocumentValue }
    func applyPatch(_ patch: String, at rootURL: URL, mode: String) -> GitProcessResult? {
        applyPatchHandler?(patch, rootURL, mode)
    }
    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? {
        if let historyController {
            return historyController.history(at: rootURL, reference: reference, limit: limit)
        }
        return historyValue
    }
    func references(at rootURL: URL, operationID: String) -> GitReferenceSnapshot? {
        if let referencesValue { return referencesValue }
        guard let historyValue else { return nil }
        return GitReferenceSnapshot(
            references: historyValue.references,
            recentReferences: historyValue.recentReferences,
            identity: historyValue.identity
        )
    }
    func historyPage(
        at rootURL: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) -> GitHistoryPage? {
        if let graphHistoryProbe {
            return graphHistoryProbe.page(reference: reference, cursor: cursor, limit: limit, operationID: operationID)
        }
        if let historyPageHandler { return historyPageHandler() }
        if let historyPageValues { return historyPageValues[cursor ?? ""] }
        guard let historyValue else { return nil }
        let offset = cursor.flatMap(Int.init) ?? 0
        let commits = Array(historyValue.commits.dropFirst(offset).prefix(limit))
        let hasMore = historyValue.commits.count > offset + commits.count || historyValue.hasMore
        return GitHistoryPage(
            commits: commits,
            nextCursor: hasMore ? String(offset + commits.count) : nil,
            hasMore: hasMore
        )
    }
    func closeHistoryCursor(at rootURL: URL, cursor: String) -> Bool {
        graphHistoryProbe?.close(cursor: cursor)
        return graphHistoryProbe != nil
    }
    func cancel(operationID: String) -> Bool {
        graphHistoryProbe?.cancel(operationID: operationID)
        return graphHistoryProbe != nil
    }
    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? {
        filesRecorder?.recordCall()
        if let filesGate {
            return filesGate.loadFiles(for: commit)
        }
        return filesValue
    }
    func commit(at rootURL: URL, hash: String) -> GitCommit? { nil }
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison? { comparisonValue }
    func comparison(from reference: GitReference, to target: GitReference, at rootURL: URL) -> GitBranchComparison? { typedComparisonValue }
    func stashes(at rootURL: URL) -> [GitStash]? { nil }
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? { nil }
    func stage(_ change: GitChange) -> GitProcessResult? { stageResult }
    func unstage(_ change: GitChange) -> GitProcessResult? { nil }
    func discard(_ change: GitChange) -> GitProcessResult? { discardHandler?(change) }
    func discardAll(_ change: GitChange) -> GitProcessResult? { nil }
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? { commitResult }
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? { revertHandler?(hash) }
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? { nil }
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? {
        branchCallRecorder?.record(BranchCallRecorder.Call(name: name, reference: reference.fullName, checkout: checkout))
        return createBranchResult
    }
    func createWorktree(named name: String, from reference: GitReference, revision: String?, at destination: URL, repositoryRoot: URL) -> GitProcessResult? { nil }
    func removeWorktree(_ worktree: GitWorktree, force: Bool, at rootURL: URL) -> GitProcessResult? {
        removeWorktreeResult
    }
    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func repairWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func pruneWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? { nil }
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        branchCallRecorder?.record(BranchCallRecorder.Call(name: reference.shortName, reference: reference.fullName, checkout: false))
        return deleteBranchResults?.next() ?? deleteBranchResult
    }
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        GitProcessResult(
            arguments: ["checkoutAndRebase", reference.fullName],
            output: "",
            exitCode: 0
        )
    }
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult? { nil }
    func pullRemoteReference(
        _ reference: GitReference,
        strategy: GitPullStrategy,
        at rootURL: URL
    ) -> GitProcessResult? {
        GitProcessResult(
            arguments: ["pull", strategy.rawValue, reference.fullName],
            output: "",
            exitCode: 0
        )
    }
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? { nil }
    func conflictMarkerPaths(at rootURL: URL) -> [String] { [] }
    func integrationPreflight(for target: GitIntegrationTarget, operation: GitIntegrationOperation, at rootURL: URL) -> GitIntegrationPreflightState? { nil }
    func fetch(at rootURL: URL) -> GitProcessResult? { fetchHandler?(fetchPlanValue?.options ?? GitFetchOptions(), "default-fetch-fixture") }
    func executionSettings(_ request: GitConfigurationEdit, save: Bool) -> Result<GitExecutionSettingsSnapshot, GitFetchFailure> {
        .success(GitExecutionSettingsSnapshot(executable: nil, version: "git fixture", scope: "local", entries: [], fields: [], temporaryConfig: [],
            fetchOptions: fetchPlanValue?.options ?? GitFetchOptions(), fetchError: nil, credentialHelperEnabled: true, interactiveAuthentication: false))
    }
    func fetchPlan(options: GitFetchOptions) -> Result<GitFetchPlan, GitFetchFailure> {
        fetchPlanValue.map(Result.success) ?? .failure(GitFetchFailure("Fetch preview unavailable"))
    }
    func fetch(at rootURL: URL, options: GitFetchOptions, operationID: String) -> GitProcessResult? {
        fetchHandler?(options, operationID)
    }
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
    func createTag(named name: String, at revision: String, message: String?, rootURL: URL) -> GitProcessResult? {
        tagCallRecorder?.record(TagCallRecorder.Call(name: name, revision: revision, message: message))
        return createTagResult
    }
    func deleteTag(named name: String, rootURL: URL) -> GitProcessResult? {
        tagCallRecorder?.record(TagCallRecorder.Call(name: name, revision: "", message: nil))
        return deleteTagResults?.next() ?? deleteTagResult
    }
}
