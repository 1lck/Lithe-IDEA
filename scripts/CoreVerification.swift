import Foundation

@main
struct CoreVerification {
    static func main() async {
        verifyDiffParser()
        verifyVisibilityRules()
        verifyGitGraph()
        verifyWhitespaceModes()
        verifySearchOptions()
        await verifyGitWhitespaceFiltering()
        await verifyGitStashAndClone()
        print("Core verification passed: diff, visibility, graph, search options, whitespace modes, stash, clone, and Git filtering")
    }

    private static func verifyDiffParser() {
        let patch = """
        diff --git a/Example.java b/Example.java
        --- a/Example.java
        +++ b/Example.java
        @@ -1,3 +1,4 @@
         class Example {
        -    return 1;
        +    return 2;
        +    // added
         }
        """
        let document = DiffParser.parseDocument(patch)
        require(document.hunks.count == 1, "expected one diff hunk")
        require(document.rows.first?.kind == .information, "expected hunk header row")
        require(document.rows.contains { $0.kind == .changed }, "expected changed row")
        require(document.rows.contains { $0.kind == .addition }, "expected added row")
        require(document.hunks.first?.rows.count == document.rows.count, "hunk rows must match document rows")
    }

    private static func verifyVisibilityRules() {
        let root = URL(fileURLWithPath: "/tmp/lithe-test-project")
        let rules = FileVisibilityRules.default
        require(
            rules.isHidden(
                root.appendingPathComponent(".build/debug/Lithe"),
                relativeTo: root,
                isDirectory: false
            ),
            "build artifacts should be hidden"
        )
        require(
            !rules.isHidden(
                root.appendingPathComponent("src/main.swift"),
                relativeTo: root,
                isDirectory: false
            ),
            "source files should remain visible"
        )
    }

    private static func verifyGitGraph() {
        let root = commit(hash: "root", parents: [], subject: "root", decorations: "")
        let side = commit(hash: "side", parents: ["root"], subject: "side", decorations: "feature/orders")
        let main = commit(
            hash: "main",
            parents: ["side", "root"],
            subject: "merge",
            decorations: "HEAD -> main"
        )
        let layout = GitGraphLayoutService.layout(commits: [main, side, root])
        require(layout.rows.count == 3, "expected three graph rows")
        require(layout.rows[0].isMerge, "expected merge commit")
        require(layout.rows[0].parentEdges.count == 2, "expected two merge parent edges")
        require(layout.rows[0].parentEdges.allSatisfy { !$0.isMissing }, "merge parents should be present")
        require(layout.rows[0].labels.contains { $0.kind == .head }, "HEAD label should be parsed")
    }

    private static func verifyWhitespaceModes() {
        require(GitDiffWhitespaceMode.allCases.count == 2, "expected two whitespace modes")
        require(GitDiffWhitespaceMode.doNotIgnore.title == "Do not ignore", "default whitespace label changed")
        require(GitDiffWhitespaceMode.ignoreAllWhitespace.title == "Ignore whitespace", "ignore label changed")
    }

    private static func verifySearchOptions() {
        let standard = ProjectSearchOptions.default
        require(standard.matches("Hello Lithe", query: "lithe"), "default search should ignore case")
        require(!standard.matches("Hello Lithe", query: "world"), "default search should reject missing text")

        var caseSensitive = standard
        caseSensitive.caseSensitive = true
        require(!caseSensitive.matches("Hello Lithe", query: "lithe"), "case-sensitive search should honor case")
        require(caseSensitive.matches("Hello Lithe", query: "Lithe"), "case-sensitive search should find exact case")

        var wholeWords = standard
        wholeWords.wholeWords = true
        require(wholeWords.matches("format(value)", query: "format"), "whole-word search should find a symbol")
        require(!wholeWords.matches("formatter", query: "format"), "whole-word search should reject a prefix")

        var regularExpression = standard
        regularExpression.regularExpression = true
        require(regularExpression.matches("UserService42", query: "UserService\\d+"), "regex search should match a pattern")
    }

    private static func verifyGitWhitespaceFiltering() async {
        let root = URL(fileURLWithPath: "/tmp/lithe-core-verification-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fileURL = root.appendingPathComponent("sample.txt")
            try "alpha\n".write(to: fileURL, atomically: true, encoding: .utf8)
            require(runCommand(at: root, arguments: ["init", "-q"]).succeeded, "git init failed")
            require(
                runCommand(
                    at: root,
                    arguments: [
                        "-c", "user.name=Lithe Verification",
                        "-c", "user.email=verification@example.com",
                        "add", "sample.txt"
                    ]
                ).succeeded,
                "git add failed"
            )
            require(
                runCommand(
                    at: root,
                    arguments: [
                        "-c", "user.name=Lithe Verification",
                        "-c", "user.email=verification@example.com",
                        "commit", "-qm", "initial"
                    ]
                ).succeeded,
                "git commit failed"
            )
            try " alpha \n".write(to: fileURL, atomically: true, encoding: .utf8)

            let change = GitChange(
                repositoryRoot: root,
                path: "sample.txt",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "M"
            )
            let normal = await GitService.diffDocument(for: change)
            let ignored = await GitService.diffDocument(
                for: change,
                whitespace: .ignoreAllWhitespace
            )
            require(normal.rows.contains { isDifference($0.kind) }, "normal diff should contain a change")
            require(
                !ignored.rows.contains { isDifference($0.kind) },
                "whitespace-only diff should disappear when filtering whitespace"
            )
        } catch {
            require(false, "Git whitespace verification failed: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func verifyGitStashAndClone() async {
        let root = URL(fileURLWithPath: "/tmp/lithe-git-verification-\(UUID().uuidString)")
        let clone = root.deletingLastPathComponent().appendingPathComponent("lithe-git-clone-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fileURL = root.appendingPathComponent("README.md")
            try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
            require(runCommand(at: root, arguments: ["init", "-q"]).succeeded, "stash repo init failed")
            require(runCommand(at: root, arguments: ["add", "README.md"]).succeeded, "stash add failed")
            require(
                runCommand(
                    at: root,
                    arguments: [
                        "-c", "user.name=Lithe Verification",
                        "-c", "user.email=verification@example.com",
                        "commit", "-qm", "initial"
                    ]
                ).succeeded,
                "stash commit failed"
            )
            try "changed\n".write(to: fileURL, atomically: true, encoding: .utf8)

            let stashResult = await GitService.stash(
                message: "core verification",
                includeUntracked: true,
                at: root
            )
            require(stashResult.succeeded, "git stash failed")
            let stashes = await GitService.stashes(at: root)
            require(stashes.count == 1, "expected one stash")
            require(stashes[0].message.contains("core verification"), "stash message was not parsed")
            require(stashes[0].branch == "master" || stashes[0].branch == "main", "stash branch was not parsed")
            let baseAfterStash = try String(contentsOf: fileURL, encoding: .utf8)
            require(baseAfterStash == "base\n", "stash should restore the working tree")

            let applyResult = await GitService.applyStash(stashes[0], at: root)
            require(applyResult.succeeded, "git stash apply failed")
            let changedAfterApply = try String(contentsOf: fileURL, encoding: .utf8)
            require(changedAfterApply == "changed\n", "stash apply should restore file content")
            try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
            let dropResult = await GitService.dropStash(stashes[0], at: root)
            require(dropResult.succeeded, "git stash drop failed")

            let cloneResult = await GitService.cloneRepository(from: root.path, to: clone)
            require(cloneResult.succeeded, "git clone failed")
            require(
                FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path),
                "cloned repository should contain .git"
            )
            require(
                FileManager.default.fileExists(atPath: clone.appendingPathComponent("README.md").path),
                "cloned repository should contain committed files"
            )
        } catch {
            require(false, "Git stash/clone verification failed: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: clone)
    }

    private static func commit(
        hash: String,
        parents: [String],
        subject: String,
        decorations: String
    ) -> GitCommit {
        GitCommit(
            hash: hash,
            shortHash: hash,
            parentHashes: parents,
            authorName: "Test",
            authorEmail: "test@example.com",
            date: "2026/08/02 10:00",
            subject: subject,
            decorations: decorations
        )
    }

    private static func runCommand(
        at directory: URL,
        arguments: [String]
    ) -> (output: String, succeeded: Bool) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                String(data: data, encoding: .utf8) ?? "",
                process.terminationStatus == 0
            )
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private static func isDifference(_ kind: DiffRowKind) -> Bool {
        switch kind {
        case .changed, .addition, .removal:
            return true
        case .context, .information:
            return false
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Core verification failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
