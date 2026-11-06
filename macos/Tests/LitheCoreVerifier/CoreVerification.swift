import LitheGitTestSupport
import Foundation
import LitheCoreContracts
import LitheGitModule
import LitheSearchModule

@main
struct CoreVerification {
    static func main() async {
        verifySharedContractFixtures()
        verifyDiffParser()
        verifyWhitespaceModes()
        verifySearchOptions()
        print("Core verification passed: shared fixtures, diff, search options, and whitespace modes")
    }

    private struct SearchFixture: Decodable {
        struct File: Decodable {
            let path: String
            let content: String
        }

        struct Request: Decodable {
            let query: String
            let caseSensitive: Bool
            let wholeWords: Bool
            let regularExpression: Bool
        }

        struct Match: Decodable, Equatable {
            let kind: String
            let path: String
            let line: Int?
            let preview: String
        }

        struct Case: Decodable {
            let name: String
            let request: Request
            let expected: [Match]
        }

        let files: [File]
        let cases: [Case]
    }


    private struct GitCommandFixture: Decodable {
        struct Invocation: Decodable {
            let arguments: [String]
            let stdout: String
            let stderr: String
            let exitCode: Int32
        }

        struct OperationError: Decodable {
            let code: String
            let message: String
            let details: String?
        }

        let arguments: [String]
        let output: String
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let invocations: [Invocation]
        let operationError: OperationError?
    }

    private static func verifySharedContractFixtures() {
        let searchURL = URL(fileURLWithPath: "shared/fixtures/search/basic.json")
        guard let searchData = try? Data(contentsOf: searchURL),
              let searchFixture = try? JSONDecoder().decode(SearchFixture.self, from: searchData) else {
            require(false, "search contract fixture could not be decoded")
            return
        }

        // Hidden-path rules live in Rust Core, which this verifier does not link; they are
        // verified by shared/fixtures/workspace/visibility-v1.json. The only hidden file in this
        // fixture is the linked-worktree copy, so the verifier leaves out that folder itself.
        let files = searchFixture.files
            .filter { !$0.path.hasPrefix(".worktree/") }
            .sorted { $0.path < $1.path }
        for fixtureCase in searchFixture.cases {
            var actual: [SearchFixture.Match] = []
            var options = ProjectSearchOptions.default
            options.caseSensitive = fixtureCase.request.caseSensitive
            options.wholeWords = fixtureCase.request.wholeWords
            options.regularExpression = fixtureCase.request.regularExpression

            for file in files where options.matches(file.path, query: fixtureCase.request.query) {
                actual.append(SearchFixture.Match(
                    kind: "file",
                    path: file.path,
                    line: nil,
                    preview: file.path
                ))
            }
            for file in files {
                for (index, line) in file.content
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                where options.matches(String(line), query: fixtureCase.request.query) {
                    actual.append(SearchFixture.Match(
                        kind: "content",
                        path: file.path,
                        line: index + 1,
                        preview: line.trimmingCharacters(in: .whitespaces)
                    ))
                }
            }
            require(actual == fixtureCase.expected, "search fixture case failed: \(fixtureCase.name)")
        }

        let commandURL = URL(fileURLWithPath: "shared/fixtures/git/command-response-v1.json")
        guard let commandData = try? Data(contentsOf: commandURL),
              let commandFixture = try? JSONDecoder().decode(GitCommandFixture.self, from: commandData) else {
            require(false, "Git command response fixture could not be decoded")
            return
        }
        let invocations = commandFixture.invocations.map { invocation in
            GitProcessInvocation(
                arguments: invocation.arguments,
                standardOutput: invocation.stdout,
                standardError: invocation.stderr,
                exitCode: invocation.exitCode
            )
        }
        require(invocations.count == 2, "Git command fixture invocation count changed")
        require(invocations.first?.arguments.first == "status", "Git command fixture lost its first invocation")
        require(invocations.last?.arguments.first == "checkout", "Git command fixture lost its final invocation")
        require(
            commandFixture.output == commandFixture.stdout + commandFixture.stderr,
            "Git command fixture compatibility output changed"
        )
        require(commandFixture.arguments == invocations.last?.arguments, "Git command fixture final arguments changed")
        require(commandFixture.exitCode == invocations.last?.exitCode, "Git command fixture final exit code changed")

        let commandErrorURL = URL(fileURLWithPath: "shared/fixtures/git/command-error-response-v1.json")
        guard let commandErrorData = try? Data(contentsOf: commandErrorURL),
              let commandErrorFixture = try? JSONDecoder().decode(GitCommandFixture.self, from: commandErrorData),
              let finalErrorInvocation = commandErrorFixture.invocations.last else {
            require(false, "Git command error response fixture could not be decoded")
            return
        }
        require(commandErrorFixture.operationError?.code == "invalid_request", "Git command error fixture code changed")
        require(commandErrorFixture.operationError?.message == "Invalid Git reference", "Git command error fixture message changed")
        require(commandErrorFixture.operationError?.details == nil, "Git command error fixture details changed")
        require(commandErrorFixture.arguments == finalErrorInvocation.arguments, "Git command error fixture final arguments changed")
        require(commandErrorFixture.stdout == finalErrorInvocation.stdout, "Git command error fixture final stdout changed")
        require(commandErrorFixture.stderr == finalErrorInvocation.stderr, "Git command error fixture final stderr changed")
        require(commandErrorFixture.exitCode == finalErrorInvocation.exitCode, "Git command error fixture final exit code changed")
        require(
            commandErrorFixture.output == finalErrorInvocation.stdout + finalErrorInvocation.stderr,
            "Git command error fixture compatibility output changed"
        )
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
        require(
            document.rows.allSatisfy { $0.hunkID == document.hunks.first?.id },
            "every row must belong to the single parsed hunk"
        )
        require(
            document.rows.first { $0.kind == .context }?.rightText != nil,
            "context rows must expose shared text on the right side"
        )
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

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Core verification failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
