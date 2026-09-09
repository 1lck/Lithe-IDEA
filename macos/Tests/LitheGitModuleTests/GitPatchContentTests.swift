import Foundation
@testable import LitheGitModule
import Testing

struct GitPatchContentTests {
    @Test
    func patchTextPreservesEveryUTF8ByteIncludingBinaryPatchEncoding() throws {
        let patch = "diff --git a/图.png b/图.png\nGIT binary patch\nliteral 1\nIc${Nk000310RR91\n\n"
        let bytes = Data(patch.utf8)
        #expect(Data(try GitPatchContent.decode(bytes).utf8) == bytes)
        #expect(try GitPatchContent.decode(Data()).isEmpty)
    }

    @Test
    func invalidUTF8AndOversizedPatchFilesAreRejectedWithoutLossyConversion() {
        #expect(throws: GitPatchFailure.self) { try GitPatchContent.decode(Data([0xff, 0xfe, 0x80])) }
        let oversized = Data(repeating: 0x61, count: GitPatchContent.maximumByteCount + 1)
        #expect(throws: GitPatchFailure.self) { try GitPatchContent.decode(oversized) }
    }
}
