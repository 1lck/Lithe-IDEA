import Foundation
import Testing
@testable import Lithe

@Suite("Language server navigation payload")
struct LanguageServerNavigationPayloadTests {
    @Test
    func virtualURIWithoutFilePathDecodesAsReadOnlyLocation() throws {
        let data = Data("""
        {
            "locations": [{
                "uri": "virtual://contents/lib/core/Item.txt",
                "filePath": null,
                "range": {
                    "start": { "line": 10, "utf16Column": 4 },
                    "end": { "line": 10, "utf16Column": 10 }
                },
                "isReadOnly": true,
                "displayPath": "lib/core/Item.txt"
            }]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(
            RustCoreBridge.BuiltinNavigationPayload.self,
            from: data
        )
        let location = try #require(payload.makeModels().first)

        #expect(location.url.absoluteString == "virtual://contents/lib/core/Item.txt")
        #expect(location.isReadOnly)
        #expect(location.displayPath == "lib/core/Item.txt")
    }
}
