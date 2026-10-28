import Foundation
import Testing
@testable import Lithe

@Suite("Debug automatic expressions")
struct DebugAutomaticExpressionProjectionTests {
    @Test
    func javaAutomaticDebugExpressionsKeepReceiversAndSkipMethods() {
        let source = "return service.listUsers();" as NSString

        let expressions = DebugAutomaticExpressionProjection.javaExpressions(
            forLine: 0,
            in: source
        )

        #expect(expressions == ["service"])
    }

    @Test
    func javaAutomaticDebugExpressionsAreBoundedAndSourceOrdered() {
        let source = "a + b + c + d + e + f + g + h + i + j" as NSString

        let expressions = DebugAutomaticExpressionProjection.javaExpressions(
            forLine: 0,
            in: source
        )

        #expect(expressions == ["a", "b", "c", "d", "e", "f", "g", "h"])
    }
}
