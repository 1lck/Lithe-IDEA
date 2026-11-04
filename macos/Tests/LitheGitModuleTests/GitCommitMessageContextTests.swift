import Foundation
import Testing
@testable import LitheGitModule

struct GitCommitMessageContextTests {
    @Test func sharedCaptureFixtureDecodesOriginalLengthAndToken() throws {
        struct Fixture: Decodable { let captureResponse: GitCommitMessageCoreCapture }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/git/commit-message-context-v1.json"))
        let response = try JSONDecoder().decode(Fixture.self, from: data).captureResponse
        #expect(response.files.count == 1)
        #expect(response.files[0].path == "text.txt")
        #expect(response.files[0].originalCharacters == 8 && !response.files[0].truncated)
        #expect(response.token.count == 64)
    }
}
